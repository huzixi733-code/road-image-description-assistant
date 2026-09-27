#!/usr/bin/env python3
"""Serve the road assistant UI and proxy same-origin Ollama API requests."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


WEB_ROOT = os.environ.get("WEB_ROOT", "/opt/road-assistant/web")
OLLAMA_BASE = os.environ.get("OLLAMA_BASE", "http://127.0.0.1:11434")
PORT = int(os.environ.get("PORT", "80"))
MAX_REQUEST_BYTES = 25 * 1024 * 1024
ALLOWED_API_ROUTES = {
    ("GET", "/api/version"),
    ("GET", "/api/tags"),
    ("POST", "/api/chat"),
}


class RoadAssistantHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_ROOT, **kwargs)

    def do_GET(self):
        if self.path == "/healthz":
            self._json(200, {"status": "ok"})
            return
        if urllib.parse.urlsplit(self.path).path.startswith("/api/"):
            self._proxy()
            return
        super().do_GET()

    def do_POST(self):
        if urllib.parse.urlsplit(self.path).path.startswith("/api/"):
            self._proxy()
            return
        self.send_error(404)

    def _proxy(self):
        route = urllib.parse.urlsplit(self.path).path
        if (self.command, route) not in ALLOWED_API_ROUTES:
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return
        if length > MAX_REQUEST_BYTES:
            self.send_error(413, "Image request is too large")
            return

        body = self.rfile.read(length) if length else None
        target = OLLAMA_BASE + self.path
        headers = {"Accept": self.headers.get("Accept", "application/json")}
        if self.headers.get("Content-Type"):
            headers["Content-Type"] = self.headers["Content-Type"]

        request = urllib.request.Request(
            target,
            data=body,
            headers=headers,
            method=self.command,
        )
        try:
            with urllib.request.urlopen(request, timeout=600) as response:
                payload = response.read()
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        except urllib.error.HTTPError as error:
            payload = error.read()
            self.send_response(error.code)
            self.send_header("Content-Type", error.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (urllib.error.URLError, TimeoutError) as error:
            self._json(502, {"error": f"模型服务不可用：{error}"})

    def _json(self, status, data):
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), RoadAssistantHandler)
    print(f"Road Assistant listening on http://0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
