#!/usr/bin/env python3
"""Local test server for the CI walkthrough: plays the provider and slow websites.

  /<file>            files from the folder given as argv[2]
  /limited.yaml      429 Too Many Requests, Retry-After: 120
  /refused.yaml      403 with a "访问受限" page (like the user's provider)
  /slow              sends a byte every second for a minute (a long-lived connection)
  /flaky.yaml        503 for the first request, then sub.yaml
  /count?path=/x     how many times /x was requested
"""
import collections, http.server, os, sys, threading, time, urllib.parse

hits = collections.Counter()
lock = threading.Lock()
root = sys.argv[2]

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.headers.get("User-Agent", "-"), fmt % args))

    def send_text(self, status, text, headers=()):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        with lock:
            hits[url.path] += 1
        if url.path == "/count":
            path = urllib.parse.parse_qs(url.query).get("path", [""])[0]
            return self.send_text(200, str(hits[path]))
        if url.path == "/limited.yaml":
            return self.send_text(429, "Too Many Requests", [("Retry-After", "120")])
        if url.path == "/refused.yaml":
            return self.send_text(403, "访问受限 REF: CI-TEST")
        if url.path == "/flaky.yaml":
            if hits[url.path] <= 1:
                return self.send_text(503, "Service Unavailable")
            self.path = "/sub.yaml"
            return super().do_GET()
        if url.path == "/slow":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            try:
                for _ in range(60):
                    self.wfile.write(b".")
                    self.wfile.flush()
                    time.sleep(1)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        return super().do_GET()

server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.daemon_threads = True
server.serve_forever()
