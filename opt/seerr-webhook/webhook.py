#!/usr/bin/env python3

import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ["WEBHOOK_SECRET"]
PORT = int(os.environ.get("WEBHOOK_PORT", "5001"))
ENDPOINT = os.environ.get("WEBHOOK_ENDPOINT", "seerr-available")
SCRIPT = "/opt/seerr-webhook/scan_isos_and_send_pushover.py"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != f"/{ENDPOINT}":
            self.send_response(404)
            self.end_headers()
            return

        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {SECRET}":
            self.send_response(401)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""

        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
            print(f"Webhook received. notification_type={payload.get('notification_type')} event={payload.get('event')}")
        except Exception:
            print(f"Webhook received. Body length={len(body)}")

        result = subprocess.run(
            ["/usr/bin/python3", SCRIPT],
            capture_output=True,
            text=True,
            timeout=1800,
            env=os.environ.copy(),
        )

        print(result.stdout)
        if result.stderr:
            print(result.stderr)

        self.send_response(200 if result.returncode == 0 else 500)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({
            "status": "Script executed",
            "exitCode": result.returncode
        }).encode("utf-8"))

server = HTTPServer(("0.0.0.0", PORT), Handler)
print(f"Listening on 0.0.0.0:{PORT}/{ENDPOINT}")
server.serve_forever()
