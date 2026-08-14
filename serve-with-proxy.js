#!/usr/bin/env node
// Serves the upload/ folder on port 20005 and reverse-proxies a Jellyfin server under /jellyfin,
// so the app and the Jellyfin API share the same origin (avoids cross-domain XHR issues on old
// browsers, see index.html / createCrossDomainGetRequest()).
//
// Usage: node serve-with-proxy.js <jellyfin-server-url>
// Example: node serve-with-proxy.js https://demo.jellyfin.org/unstable
//
// In JellyDinosaur, set the server address to: http://<this-machine>:20005/jellyfin
//
// Only relies on Node's built-in modules (no "npm install" needed).

var http = require("http");
var https = require("https");
var fs = require("fs");
var path = require("path");
var urlModule = require("url");

var PORT = 20005;
var PROXY_PREFIX = "/jellyfin";
var STATIC_DIR = path.join(__dirname, "upload");

var target = process.argv[2];
if (!target) {
    console.error("Usage: node serve-with-proxy.js <jellyfin-server-url>");
    console.error("Example: node serve-with-proxy.js https://demo.jellyfin.org/unstable");
    process.exit(1);
}

var targetUrl = urlModule.parse(target);
if (!targetUrl.protocol || !targetUrl.host) {
    console.error("Invalid Jellyfin server URL: " + target);
    process.exit(1);
}
// Base path of the target server (e.g. "/jf"), without a trailing slash, prefixed onto every
// proxied request: lets this target a Jellyfin instance that itself lives under a sub-path
// (upstream reverse proxy).
var targetBasePath = (targetUrl.pathname || "").replace(/\/+$/, "");
var targetIsHttps = targetUrl.protocol === "https:";
var targetModule = targetIsHttps ? https : http;

var MIME_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".swf": "application/x-shockwave-flash",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".ico": "image/x-icon",
    ".svg": "image/svg+xml"
};

function serveStatic(req, res, reqPath) {
    var relativePath = reqPath === "/" ? "/index.html" : reqPath;
    var filePath = path.join(STATIC_DIR, path.normalize(relativePath));

    // Prevents escaping upload/ via a "/../..." path in the requested URL.
    if (filePath.indexOf(STATIC_DIR) !== 0) {
        res.writeHead(403);
        res.end("Forbidden");
        return;
    }

    fs.readFile(filePath, function(err, data) {
        if (err) {
            res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
            res.end("Not found: " + reqPath);
            return;
        }
        var ext = path.extname(filePath).toLowerCase();
        res.writeHead(200, { "Content-Type": MIME_TYPES[ext] || "application/octet-stream" });
        res.end(data);
    });
}

function proxyToJellyfin(req, res, reqPath, query) {
    var forwardedPath = targetBasePath + reqPath.substring(PROXY_PREFIX.length) + (query ? "?" + query : "");

    var headers = {};
    for (var key in req.headers) {
        if (req.headers.hasOwnProperty(key)) {
            headers[key] = req.headers[key];
        }
    }
    headers.host = targetUrl.host;

    var proxyReq = targetModule.request({
        protocol: targetUrl.protocol,
        hostname: targetUrl.hostname,
        port: targetUrl.port || (targetIsHttps ? 443 : 80),
        path: forwardedPath,
        method: req.method,
        headers: headers
    }, function(proxyRes) {
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        proxyRes.pipe(res);
    });

    proxyReq.on("error", function(err) {
        res.writeHead(502, { "Content-Type": "text/plain; charset=utf-8" });
        res.end("Error contacting the Jellyfin server (" + target + "): " + err.message);
    });

    req.pipe(proxyReq);
}

var server = http.createServer(function(req, res) {
    var parsed = urlModule.parse(req.url);

    if (parsed.pathname === PROXY_PREFIX || parsed.pathname.indexOf(PROXY_PREFIX + "/") === 0) {
        proxyToJellyfin(req, res, parsed.pathname, parsed.query);
    } else {
        serveStatic(req, res, parsed.pathname);
    }
});

server.listen(PORT, function() {
    console.log("JellyDinosaur is available at http://localhost:" + PORT + "/");
    console.log("Jellyfin server (" + target + ") proxied under http://localhost:" + PORT + PROXY_PREFIX);
    console.log("In JellyDinosaur, use as server address: http://<this-machine>:" + PORT + PROXY_PREFIX);
});
