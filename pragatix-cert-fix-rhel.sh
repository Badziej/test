#!/bin/bash
#
# pragatix-cert-fix-rhel.sh - make `prgx certificate install|sync` work on RHEL
#
# For Pragatix Linux installer 1.2.58, profile OfflineAISecuritySuite. Fixes two
# problems, each only when present:
#  1. `prgx certificate` reports "Installation configuration was not found:
#     /opt/pragatix/.pragatix_install_config.sh". The file is rebuilt; an
#     existing complete file is only made root:root 600 if it is not already.
#  2. On RHEL, /etc/ssl/certs is a symlink to /etc/pki/tls/certs, which the
#     certificate script rejects ("resolves outside the allowed SSL
#     directories"). /etc/pki/tls is added to its allowed directories.
#  3. `sudo prgx` reports "command not found" because RHEL's sudo path omits
#     /usr/local/bin. prgx, prg and pragatix are also linked into /usr/bin.
#
# Every value is read from files the installer already wrote on this server
# (docker.env and setup.properties.user). Nothing is downloaded, no container
# is touched, and no secret is printed. Secrets are stored encrypted, exactly
# as the installer stores them.
#
# Usage (as root):  bash pragatix-cert-fix-rhel.sh [/opt/pragatix]
#
set -euo pipefail
umask 077

INSTALL_DIR="${1:-/opt/pragatix}"
CONFIG_OK=false
TARGET="$INSTALL_DIR/.pragatix_install_config.sh"
ENV_FILE="$INSTALL_DIR/docker.env"
PROPS_FILE="$INSTALL_DIR/setup.properties.user"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo bash $0 $INSTALL_DIR)"
[ -f "$ENV_FILE" ] || die "docker.env not found: $ENV_FILE"
[ -f "$INSTALL_DIR/lib/env_obfuscation.sh" ] || die "installer library not found: $INSTALL_DIR/lib/env_obfuscation.sh"
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    # A failed `install.sh --resume` leaves a stub holding only a few keys.
    # Keep a complete file untouched; set an incomplete one aside.
    if [ ! -L "$TARGET" ] && grep -q '^export CONFIG_GATEWAY_PORT=' "$TARGET" && grep -q '^export CONFIG_ENCRYPTION_KEY=' "$TARGET"; then
        CONFIG_OK=true
    else
        mv -f "$TARGET" "$TARGET.incomplete-$(date +%Y%m%d-%H%M%S)"
        echo "Set aside incomplete $TARGET"
    fi
fi
command -v openssl >/dev/null || die "openssl is required"

restore_config() {
# shellcheck disable=SC1091
source "$INSTALL_DIR/lib/env_obfuscation.sh"

# Read one docker.env value without sourcing the file; decrypt if obfuscated.
env_get() {
    local line value
    line=$(grep -m1 -E "^$1=" "$ENV_FILE" 2>/dev/null) || { printf ''; return 0; }
    value="${line#*=}"
    if [ "${#value}" -ge 2 ]; then
        case "$value" in
            \"*\") value="${value:1:${#value}-2}" ;;
            \'*\') value="${value:1:${#value}-2}" ;;
        esac
    fi
    if agcrypt_is_obfuscated "$value"; then
        value=$(agcrypt_decrypt "$value") || die "could not decrypt $1 from docker.env"
    fi
    printf '%s' "$value"
}

props_get() {
    [ -f "$PROPS_FILE" ] || { printf ''; return 0; }
    sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROPS_FILE" | head -1 | tr -d '\r'
}

url_host() { local u="${1#*://}"; u="${u%%/*}"; printf '%s' "${u%%:*}"; }
url_port() { local u="${1#*://}"; u="${u%%/*}"; [[ "$u" == *:* ]] && printf '%s' "${u##*:}" || printf ''; }

profile=$(env_get DEPLOYMENT_PROFILE)
[ "$profile" = "OfflineAISecuritySuite" ] || die "this script is validated for DEPLOYMENT_PROFILE=OfflineAISecuritySuite only (found '${profile:-none}')"

# Same classification and serialization as the installer (lib/config_wizard.sh).
is_secret() {
    case "$1" in
        *_PASSWORD|*_SECRET|*_API_KEY|*_CONNECTION_STRING|CONFIG_ENCRYPTION_KEY|CONFIG_ENCRYPTION_IV|CONFIG_AWS_ACCESS_KEY_ID|CONFIG_HANDOFF_LDAP_PASSWORD|CONFIG_HANDOFF_ENTRA_CLIENT_SECRET|CONFIG_HANDOFF_GOOGLE_CLIENT_SECRET) return 0 ;;
        *) return 1 ;;
    esac
}

OUT=$(mktemp "$INSTALL_DIR/.pragatix_install_config.sh.XXXXXX")
trap 'rm -f "$OUT"' EXIT
{
    echo "# Pragatix Installation Configuration"
    echo "# Restored from docker.env by restore-install-config.sh: $(date)"
    echo ""
} > "$OUT"

put() {
    local key="$1" value="${2-}"
    if is_secret "$key" && [ -n "$value" ] && ! agcrypt_is_obfuscated "$value"; then
        value=$(agcrypt_encrypt "$value") || die "could not encrypt $key"
    fi
    printf 'export %s=%q\n' "$key" "$value" >> "$OUT"
}

db_server=$(env_get DBServer)
if [ "$db_server" = "sql_server_pragatix" ]; then
    database_mode=local; external_mssql=false
else
    database_mode=external; external_mssql=true
fi
case "$(uname -m)" in
    aarch64|arm64) platform=linux/arm64 ;;
    *) platform=linux/amd64 ;;
esac
ape_url=$(env_get AGENT_POLICY_ENGINE_API_URL)
aigpe_url=$(env_get AI_GATEWAY_POLICY_ENGINE_API_URL)
if grep -q 'AGCrypt:' "$PROPS_FILE" 2>/dev/null; then props_encrypted=true; else props_encrypted=false; fi
secret_obfuscation=$(env_get SECRET_OBFUSCATION_ENABLED); secret_obfuscation="${secret_obfuscation:-false}"

dash_db_name=$(env_get DASHBOARD_DB_NAME); dash_db_user=$(env_get DASHBOARD_DB_USER)
dash_db_password=$(env_get DASHBOARD_DB_PASSWORD); db_port=$(env_get DBPort)
data_source="${db_server:-sql_server_pragatix}"
if [ -n "$db_port" ] && [[ "$data_source" != *","* ]] && [[ "$data_source" != *"\\"* ]]; then
    data_source="$data_source,$db_port"
fi
# build_dashboard_db_connection_string + normalize_dashboard_db_connection_string
dash_conn="Provider=MSOLEDBSQL;Data Source=$data_source;Initial Catalog=${dash_db_name:-Dashboard};User ID=${dash_db_user:-dashboard_user};Password=$dash_db_password;MultipleActiveResultSets=True;Application Name=AgentSecurity;"

put CONFIG_PRODUCT_SUITE "$(env_get PRODUCT_SUITE)"
put CONFIG_DEPLOYMENT_PROFILE "$profile"
put CONFIG_TARGET_PLATFORM "$platform"
put CONFIG_OFFLINE_INSTALLATION "$(env_get OFFLINE_INSTALLATION)"
put CONFIG_PRIVACY_POLICY_ACCEPTED true
put CONFIG_CUSTOMER_NAME "$(env_get Customer)"
put CONFIG_INSTALLATION_MODE "$(env_get GATEWAY_RUNTIME_MODE)"
put CONFIG_DEPLOYMENT_MODE "$(env_get GATEWAY_RUNTIME_MODE)"
put CONFIG_DATABASE_MODE "$database_mode"
put CONFIG_EXTERNAL_MSSQL "$external_mssql"
put CONFIG_EXTERNAL_POSTGRES true
put CONFIG_ENABLE_ASG true
put CONFIG_ENABLE_AGENT_POLICY_ENGINE true
put CONFIG_ENABLE_AI_GATEWAY_POLICY_ENGINE true
put CONFIG_ENABLE_WORKFLOW_ORCHESTRATOR false
put CONFIG_ENABLE_DOC_LOADER false
put CONFIG_ENABLE_PYTHON_SANDBOX false
put CONFIG_SUPPORTED_CONTENT_TYPES ""
put CONFIG_ENABLE_PII_CLASSIFICATION false
put CONFIG_SAVE_DEBUG_INFO true
put CONFIG_SECRET_OBFUSCATION_ENABLED "$secret_obfuscation"
put CONFIG_ENCRYPT_USER_PROPERTIES_DB_PASSWORDS "$props_encrypted"
put CONFIG_EXTERNAL_LINUX_HOST "$(url_host "$ape_url")"
# docker.env keeps the install-time SSL_TYPE; a certificate installed or synced
# later is only recorded in the saved configuration. Judge by the served file.
ssl_type=$(env_get SSL_TYPE)
if [ "$ssl_type" = "self-signed" ] && [ -f "$(env_get SSL_CERT_PATH)" ] && \
   ! openssl x509 -in "$(env_get SSL_CERT_PATH)" -noout -issuer 2>/dev/null | grep -q 'Local Installation CA'; then
    ssl_type=custom
fi
put CONFIG_SSL_TYPE "$ssl_type"
put CONFIG_SSL_CERT_PATH "$(env_get SSL_CERT_PATH)"
put CONFIG_SSL_KEY_PATH "$(env_get SSL_KEY_PATH)"
put CONFIG_SSL_CERT_SOURCE_PATH ""
put CONFIG_SSL_KEY_SOURCE_PATH ""
put CONFIG_GATEWAY_PORT "$(env_get GATEWAY_PORT)"
put CONFIG_GATEWAY_PUBLIC_BASE_URL "$(env_get GATEWAY_PUBLIC_BASE_URL)"
put CONFIG_AI_GATEWAY_DOMAIN "$(env_get AI_GATEWAY_DOMAIN)"
put CONFIG_AI_GATEWAY_PORT "$(env_get AI_GATEWAY_PORT)"
put CONFIG_AI_GATEWAY_PUBLIC_BASE_URL "$(env_get AI_GATEWAY_PUBLIC_BASE_URL)"
for key in GATEWAY_QUEUE_DOCS_PORT GATEWAY_QUEUE_SITES_PORT AI_PROVIDER AI_SERVER_TYPE; do put "CONFIG_$key" ""; done
put CONFIG_AI_MODELS_JSON "[]"
put CONFIG_AI_SECURITY_GEMMA_VARIANT "$(env_get AI_SECURITY_GEMMA_VARIANT)"
put CONFIG_LLM_LOCATION cloud
for key in MODEL FAST_HELPER_MODEL FAST_HELPER_MODEL_PROVIDER; do put "CONFIG_$key" ""; done
put CONFIG_GEMMA4_LIGHTWEIGHT_ENABLED false
put CONFIG_GEMMA4_MODE ""
put CONFIG_GEMMA4_CPU_ENABLED false
put CONFIG_GEMMA4_CPU_ONLY false
for key in GEMMA4_CPU_IMAGE GEMMA4_VLLM_MODEL_PATH LLM_DOCKER_IMAGE LLM_USE_IMAGE_DEFAULT_COMMAND LLM_RUNTIME \
           LLM_MODEL_FILE LLM_GPU_DEVICE_IDS LLM_TENSOR_PARALLEL_SIZE LLM_MAX_MODEL_LEN LLM_GPU_LAYERS LLM_CACHE_RAM_MB \
           LLM_TENSOR_SPLIT LLM_EXPECTED_DIGEST LLM_EXPECTED_PLATFORM_DIGEST LLM_HEALTH_START_PERIOD ARM64_GEMMA_IMAGE \
           AWS_DEFAULT_REGION AWS_USE_INSTANCE_ROLE AWS_BEDROCK_COHERE_MODEL_ID EMBEDDER EMBEDDING_LOCATION EMBEDDING_HOST \
           EMBEDDING_PORT EMBEDDING_USE_HTTPS GPU_EMBEDDING_ENABLED GPU_EMBEDDING_LOCAL GPU_EMBEDDING_PROVIDER \
           GPU_EMBEDDING_USE_HTTPS GPU_EMBEDDING_BATCH_SIZE E5_GPU_IMAGE E5_GPU_MEMORY_UTIL; do
    put "CONFIG_$key" ""
done
put CONFIG_SKIP_LLM_IMAGE_DOWNLOAD true
put CONFIG_SKIP_EMBEDDING_IMAGE_DOWNLOAD true
put CONFIG_SKIP_GPU_EMBEDDING_IMAGE_DOWNLOAD true
put CONFIG_DB_NAME "$(env_get DBName)"
put CONFIG_DB_USER "$(env_get DBUser)"
put CONFIG_DB_PASSWORD "$(env_get DBPassword)"
put CONFIG_DB_PORT "$db_port"
put CONFIG_MSSQL_PID "$(env_get MSSQL_PID)"
put CONFIG_DASHBOARD_DB_NAME "$dash_db_name"
put CONFIG_DASHBOARD_DB_USER "$dash_db_user"
put CONFIG_DASHBOARD_DB_PASSWORD "$dash_db_password"
for key in POSTGRES_DB POSTGRES_USER POSTGRES_ADMIN_USER POSTGRES_ADMIN_PASSWORD POSTGRES_PORT; do put "CONFIG_$key" ""; done
put CONFIG_ASG_IMAGE "$(env_get ASG_IMAGE)"
put CONFIG_AI_GATEWAY_IMAGE "$(env_get AI_GATEWAY_IMAGE)"
put CONFIG_AUTOHEAL_IMAGE "$(env_get AUTOHEAL_IMAGE)"
put CONFIG_DOCKERUI_IMAGE "$(env_get DOCKERUI_IMAGE)"
put CONFIG_GATEWAY_TOOLS_IMAGE "$(env_get GATEWAY_TOOLS_IMAGE)"
put CONFIG_DEBUG_COLLECTOR_IMAGE "$(env_get DEBUG_COLLECTOR_IMAGE)"
put CONFIG_AGENT_POLICY_ENGINE_IMAGE "$(env_get AGENT_POLICY_ENGINE_IMAGE)"
put CONFIG_AI_GATEWAY_POLICY_ENGINE_IMAGE "$(env_get AI_GATEWAY_POLICY_ENGINE_IMAGE)"
put CONFIG_WORKFLOW_ORCHESTRATOR_IMAGE ""
put CONFIG_DASHBOARD_DB_CONNECTION_STRING "$dash_conn"
put CONFIG_ENCRYPTION_KEY "$(env_get ENCRYPTION_KEY)"
put CONFIG_ENCRYPTION_IV "$(env_get ENCRYPTION_IV)"
put CONFIG_AGENT_POLICY_ENGINE_API_KEY "$(env_get AGENT_POLICY_ENGINE_API_KEY)"
put CONFIG_AI_GATEWAY_POLICY_ENGINE_API_KEY "$(env_get AI_GATEWAY_POLICY_ENGINE_API_KEY)"
put CONFIG_AI_GATEWAY_SHARED_SECRET "$(env_get AI_GATEWAY_SHARED_SECRET)"
put CONFIG_ASG_DASHBOARD_BASE_URL "$(env_get PRAGATIX_DASHBOARD_BASE_URL)"
put CONFIG_GATEWAY_INTERNAL_BASE_URL "$(env_get GATEWAY_INTERNAL_BASE_URL)"
put CONFIG_AGENT_POLICY_ENGINE_API_URL "$ape_url"
put CONFIG_AI_GATEWAY_POLICY_ENGINE_API_URL "$aigpe_url"
put CONFIG_ASG_CORE_API_INTERNAL_BASE_URL "$(env_get CORE_API_INTERNAL_BASE_URL)"
put CONFIG_SHADOW_AI_ACCOUNT_DOMAIN "$(props_get bastionAccountDomain)"
put CONFIG_ASG_PUBLIC_BASE_URL "$(env_get AGENTSECURITY_PUBLIC_BASE_URL)"
put CONFIG_ASG_PUBLIC_BASE_URL_ALIASES "$(env_get AGENTSECURITY_PUBLIC_BASE_URL_ALIASES)"
put CONFIG_ASG_DOMAIN "$(env_get ASG_DOMAIN)"
put CONFIG_ASG_PORT "$(env_get ASG_PORT)"
ape_port=$(url_port "$ape_url"); aigpe_port=$(url_port "$aigpe_url")
put CONFIG_AGENT_POLICY_ENGINE_PORT "${ape_port:-8079}"
put CONFIG_AI_GATEWAY_POLICY_ENGINE_PORT "${aigpe_port:-8078}"
put CONFIG_WORKFLOW_ORCHESTRATOR_PORT 8095
put CONFIG_WORKFLOW_ORCHESTRATOR_THREADS 1
for key in HANDOFF_ENTRA_TENANT_ID HANDOFF_ENTRA_CLIENT_ID HANDOFF_ENTRA_CLIENT_SECRET HANDOFF_GOOGLE_CLIENT_ID \
           HANDOFF_GOOGLE_CLIENT_SECRET HANDOFF_LDAP_HOST HANDOFF_LDAP_BASE_DN HANDOFF_LDAP_USERNAME HANDOFF_LDAP_PASSWORD; do
    put "CONFIG_$key" ""
done
put CONFIG_INSTALL_DIR "$INSTALL_DIR"
put CONFIG_MSSQL_SA_PASSWORD "$(env_get MSSQL_SA_PASSWORD)"
put CONFIG_DB_SERVER "$db_server"
put CONFIG_NEXUS_VERSION "$(env_get NEXUS_VERSION)"
put CONFIG_DOMAIN "$(env_get GATEWAY_DOMAIN)"
put CONFIG_CLIENT_ID "$(env_get ClientId)"
put CONFIG_CLIENT_SECRET "$(env_get ClientSecret)"
put CONFIG_ASG_SECRET_KEY "$(env_get SECRET_KEY)"
put CONFIG_ASG_JWT_SECRET "$(env_get JWT_SECRET)"
put CONFIG_ASG_DASHBOARD_ACCOUNT_ID "$(env_get PRAGATIX_DASHBOARD_ACCOUNT_ID)"
put CONFIG_ASG_PRAGATIX_MCP_SERVER_URL ""

# Refuse to install a file missing a value the certificate commands depend on.
missing=$(
    set +u
    # shellcheck disable=SC1090
    source "$OUT"
    for key in CONFIG_DOMAIN CONFIG_AI_GATEWAY_DOMAIN CONFIG_ASG_DOMAIN CONFIG_GATEWAY_PORT CONFIG_SSL_CERT_PATH \
               CONFIG_SSL_KEY_PATH CONFIG_ENCRYPTION_KEY CONFIG_ENCRYPTION_IV CONFIG_DASHBOARD_DB_NAME \
               CONFIG_DASHBOARD_DB_USER CONFIG_DASHBOARD_DB_PASSWORD CONFIG_MSSQL_SA_PASSWORD CONFIG_DB_SERVER \
               CONFIG_EXTERNAL_LINUX_HOST CONFIG_NEXUS_VERSION; do
        [ -n "${!key:-}" ] || printf '%s ' "$key"
    done
)
[ -z "$missing" ] || die "docker.env did not provide: $missing- nothing was written"

chown root:root "$OUT"
chmod 600 "$OUT"
mv -f "$OUT" "$TARGET"
trap - EXIT
echo "Restored $TARGET ($(grep -c '^export ' "$TARGET") settings, root:root 600)."
}

if [ "$CONFIG_OK" = true ]; then
    # `prgx certificate` refuses a file that root does not own or that others can write
    # (installations made with sudo leave it with the sudo user).
    if [ "$(stat -c '%u:%a' "$TARGET")" != "0:600" ]; then
        chown root:root "$TARGET"
        chmod 600 "$TARGET"
        echo "Step 1: $TARGET is complete; ownership set to root:root 600."
    else
        echo "Step 1: $TARGET is present and complete; left unchanged."
    fi
else
    restore_config
fi

# Step 2: allow RHEL's real SSL directory in the certificate script.
CERT_SCRIPT="$INSTALL_DIR/pragatix-certificate.sh"
[ -f "$CERT_SCRIPT" ] || die "certificate script not found: $CERT_SCRIPT"
if grep -qF '/etc/ssl/*|/etc/nginx/*|/etc/pki/tls/*) ;;' "$CERT_SCRIPT"; then
    echo "Step 2: $CERT_SCRIPT already allows /etc/pki/tls; left unchanged."
elif [ "$(grep -cF '/etc/ssl/*|/etc/nginx/*) ;;' "$CERT_SCRIPT")" = 2 ]; then
    cp -p "$CERT_SCRIPT" "$CERT_SCRIPT.orig-$(date +%Y%m%d-%H%M%S)"
    sed -i 's#/etc/ssl/\*|/etc/nginx/\*) ;;#/etc/ssl/*|/etc/nginx/*|/etc/pki/tls/*) ;;#' "$CERT_SCRIPT"
    bash -n "$CERT_SCRIPT" || die "patched $CERT_SCRIPT failed a syntax check; restore it from $CERT_SCRIPT.orig-*"
    echo "Step 2: $CERT_SCRIPT now accepts /etc/pki/tls (backup kept as $(basename "$CERT_SCRIPT").orig-*)."
else
    die "$CERT_SCRIPT does not look like the 1.2.58 version; not patched"
fi

# Step 3: make `sudo prgx` work. RHEL's sudo secure_path omits /usr/local/bin,
# where the installer puts the shortcuts, so add links in /usr/bin as well.
# A name that already exists and points anywhere else is left untouched.
CLI_SCRIPT="$INSTALL_DIR/pragatix-cli.sh"
[ -x "$CLI_SCRIPT" ] || die "CLI not found: $CLI_SCRIPT"
for name in prgx prg pragatix; do
    link="/usr/bin/$name"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$CLI_SCRIPT" ]; then
        echo "Step 3: $link already points to $CLI_SCRIPT; left unchanged."
    elif [ -e "$link" ] || [ -L "$link" ]; then
        echo "Step 3: $link belongs to something else; left unchanged (use /usr/local/bin/$name)."
    else
        ln -s "$CLI_SCRIPT" "$link"
        echo "Step 3: linked $link -> $CLI_SCRIPT"
    fi
done
echo "Done. Next: sudo prgx certificate sync --check"
