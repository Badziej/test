function FindProxyForURL(url, host) {
    // Route HTTP and HTTPS traffic through the proxy server
    if (url.substring(0, 5) == "http:" || url.substring(0, 6) == "https:") {
        return "PROXY web-wcg:8080";
    }

    // All other traffic goes direct
    return "DIRECT";
}
