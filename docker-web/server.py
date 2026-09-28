#!/usr/bin/env python3
"""Serve the road assistant UI and proxy same-origin Ollama API requests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from tts_backend import PiperSpeech, SpeechBusy, SpeechUnavailable, silence_wav, validate_request


WEB_ROOT = os.environ.get("WEB_ROOT", "/opt/road-assistant/web")
OLLAMA_BASE = os.environ.get("OLLAMA_BASE", "http://127.0.0.1:11434")
PORT = int(os.environ.get("PORT", "80"))
MAX_REQUEST_BYTES = 25 * 1024 * 1024
TTS_MODEL = os.environ.get("TTS_MODEL", str(Path(__file__).resolve().parent / "tts-models" / "zh_CN-huayan-medium.onnx"))
SPEECH = PiperSpeech(TTS_MODEL)
ALLOWED_API_ROUTES = {
    ("GET", "/api/version"),
    ("GET", "/api/tags"),
    ("POST", "/api/chat"),
}


class RoadAssistantHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_ROOT, **kwargs)

    def end_headers(self):
        """Prevent embedded mobile browsers from keeping stale HTML pages."""
        request_path = urllib.parse.urlsplit(self.path).path
        if request_path in ("", "/") or request_path.endswith(".html"):
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        route = urllib.parse.urlsplit(self.path).path
        if route == "/api/tts/status":
            self._json(200, {"available": SPEECH.available(), "voice": "服务器中文语音", "engine": "piper", "pitch_supported": False})
            return
        if route == "/api/tts/silence.wav":
            self._audio(silence_wav())
            return
        if self.path == "/healthz":
            self._json(200, {"status": "ok"})
            return
        if urllib.parse.urlsplit(self.path).path.startswith("/api/"):
            self._proxy()
            return
        super().do_GET()

    def do_POST(self):
        if urllib.parse.urlsplit(self.path).path == "/api/tts":
            self._speech()
            return
        if urllib.parse.urlsplit(self.path).path.startswith("/api/"):
            self._proxy()
            return
        self.send_error(404)

    def _speech(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._json(400, {"error": "请求长度无效。"})
            self.close_connection = True
            return
        if not 0 < length <= 12 * 1024:
            self._json(413, {"error": "语音请求大小超限。"})
            self.close_connection = True
            return
        try:
            payload = json.loads(self.rfile.read(length))
            text, rate = validate_request(payload)
        except (ValueError, UnicodeDecodeError):
            self._json(400, {"error": "语音文字或语速无效。"})
            return
        try:
            self._audio(SPEECH.synthesize(text, rate))
        except SpeechBusy as error:
            self._json(429, {"error": str(error)})
        except SpeechUnavailable as error:
            self._json(503, {"error": str(error)})
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception:
            self._json(503, {"error": "服务器语音生成失败，请稍后重试。"})

    def _audio(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

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
