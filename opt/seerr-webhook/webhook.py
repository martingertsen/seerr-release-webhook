#!/usr/bin/env python3

import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ["WEBHOOK_SECRET"]
PORT = int(os.environ.get("WEBHOOK_PORT", "5001"))
ENDPOINT = os.environ.get("WEBHOOK_ENDPOINT", "seerr-available")

ISO_SCRIPT = "/opt/seerr-webhook/scan_isos_and_send_pushover.py"
FIND_PATH_SCRIPT = "/opt/seerr-webhook/find_media_path.py"
SUBS_CLEANUP_SCRIPT = "/mnt/nas/Media/plex-subs-cleanup.sh"


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
            print("Webhook received:")
            print(json.dumps(payload, indent=2, ensure_ascii=False))
        except Exception:
            payload = {}
            print(f"Webhook received. Body length={len(body)}")

        if payload.get("source") == "uptime-kuma":
            print("Ignoring Uptime Kuma health check.")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "Ignored Uptime Kuma health check"
            }).encode("utf-8"))
            return

        media_type = payload.get("media_type")
        media_id = None

        if media_type == "movie":
            media_id = payload.get("tmdbId")
        elif media_type == "tv":
            media_id = payload.get("tvdbId")

        if media_type not in ("movie", "tv") or not media_id:
            print(f"Skipping scripts. media_type={media_type}, media_id={media_id}")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "Skipped",
                "reason": "No usable media_type/media_id"
            }).encode("utf-8"))
            return

        path_result = subprocess.run(
            [
                "/usr/bin/python3",
                FIND_PATH_SCRIPT,
                media_type,
                media_id,
            ],
            capture_output=True,
            text=True,
            timeout=60,
            env=os.environ.copy(),
        )

        if path_result.returncode != 0:
            print("Could not resolve media path:")
            print(path_result.stderr)

            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "Failed",
                "reason": "Could not resolve media path",
                "exitCode": path_result.returncode
            }).encode("utf-8"))
            return

        media_path = path_result.stdout.strip()
        print(f"Resolved media path: {media_path}")

        iso_result = subprocess.run(
            [
                "/usr/bin/python3",
                ISO_SCRIPT,
                "--path",
                media_path,
            ],
            capture_output=True,
            text=True,
            timeout=1800,
            env=os.environ.copy(),
        )

        print(iso_result.stdout)
        if iso_result.stderr:
            print(iso_result.stderr)

        cleanup_result = subprocess.run(
            [
                SUBS_CLEANUP_SCRIPT,
                "fix",
                "--path",
                media_path,
                "--delete-backup",
            ],
            capture_output=True,
            text=True,
            timeout=1800,
            env=os.environ.copy(),
        )

        print(cleanup_result.stdout)
        if cleanup_result.stderr:
            print(cleanup_result.stderr)

        exit_code = 0
        if iso_result.returncode != 0:
            exit_code = iso_result.returncode
        if cleanup_result.returncode != 0:
            exit_code = cleanup_result.returncode

        self.send_response(200 if exit_code == 0 else 500)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({
            "status": "Scripts executed",
            "mediaPath": media_path,
            "isoExitCode": iso_result.returncode,
            "cleanupExitCode": cleanup_result.returncode
        }).encode("utf-8"))


server = HTTPServer(("0.0.0.0", PORT), Handler)
print(f"Listening on 0.0.0.0:{PORT}/{ENDPOINT}")
server.serve_forever()
