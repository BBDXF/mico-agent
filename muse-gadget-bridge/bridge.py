#!/usr/bin/env python3
"""Small authenticated HTTP bridge from mico-agent to Muse Gadget."""

import hmac
import json
import logging
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = os.environ.get("MUSE_BRIDGE_HOST", "0.0.0.0")
PORT = int(os.environ.get("MUSE_BRIDGE_PORT", "8765"))
WAIT_SECONDS = min(600, max(1, int(os.environ.get("MUSE_WAIT_SECONDS", "70"))))
TOKEN = os.environ.get("MUSE_BRIDGE_TOKEN", "")
MUSEGADGET = os.environ.get("MUSEGADGET_BIN", "/usr/local/bin/musegadget")
MAX_BODY = 16 * 1024
MAX_TEXT = 6000
request_lock = threading.Lock()

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s %(message)s")
log = logging.getLogger("mico-muse-bridge")


class Handler(BaseHTTPRequestHandler):
    server_version = "MicoMuseBridge/1.0"

    def log_message(self, _format, *_args):
        # Do not log requests, prompts, replies, or credentials.
        return

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/ask":
            log.warning("Rejected unknown path from %s", self.client_address[0])
            self.send_json(404, {"error": "not found"})
            return

        auth = self.headers.get("Authorization", "")
        expected = "Bearer " + TOKEN
        if not TOKEN or not hmac.compare_digest(auth, expected):
            log.warning("Rejected unauthenticated /ask request from %s", self.client_address[0])
            self.send_json(401, {"error": "unauthorized"})
            return
        log.info("Accepted authenticated /ask request from %s", self.client_address[0])

        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, {"error": "invalid content length"})
            return
        if size < 1 or size > MAX_BODY:
            self.send_json(413, {"error": "request body too large or empty"})
            return

        try:
            payload = json.loads(self.rfile.read(size))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.send_json(400, {"error": "invalid JSON"})
            return
        text = payload.get("text") if isinstance(payload, dict) else None
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
            self.send_json(400, {"error": "text must be a non-empty string under 6000 characters"})
            return

        if not request_lock.acquire(blocking=False):
            self.send_json(429, {"error": "Muse bridge is busy"})
            return
        try:
            try:
                result = subprocess.run(
                    [MUSEGADGET, "send-user-msg", "--wait", str(WAIT_SECONDS), text.strip()],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=WAIT_SECONDS + 10,
                )
            except subprocess.TimeoutExpired:
                log.warning("Muse request timed out")
                self.send_json(504, {"error": "Muse response timed out"})
                return

            reply = result.stdout.strip()
            if result.returncode != 0:
                # Avoid returning command output or arguments to the caller.
                log.warning("musegadget send-user-msg exited with status %d", result.returncode)
                self.send_json(504 if result.returncode == 3 else 502,
                               {"error": "Muse did not return a complete reply"})
                return
            if not reply:
                log.warning("Muse returned an empty reply")
                self.send_json(502, {"error": "Muse returned an empty reply"})
                return

            log.info("Muse reply returned successfully")
            self.send_json(200, {"reply": reply})
        finally:
            request_lock.release()


def main():
    if not TOKEN:
        raise SystemExit("MUSE_BRIDGE_TOKEN is required")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    log.info("Listening on %s:%d", HOST, PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
