#!/usr/bin/env python3

import os
import sys
import time
import argparse
from pathlib import Path
from urllib import request, parse, error

PUSHOVER_ENDPOINT = "https://api.pushover.net/1/messages.json"

MEDIA_PATHS = os.environ["MEDIA_PATHS"].split(":")
USER_KEY = os.environ["PUSHOVER_USER_KEY"]
APP_TOKEN = os.environ["PUSHOVER_APP_TOKEN"]
DEVICE = os.environ.get("PUSHOVER_DEVICE")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", help="Only scan this folder")
    return parser.parse_args()

def chunk_lines(lines, max_len=400):
    chunks = []
    current = ""

    for line in lines:
        if current and len(current) + len(line) + 1 > max_len:
            chunks.append(current)
            current = line
        else:
            current = f"{current}\n{line}" if current else line

    if current:
        chunks.append(current)

    return chunks


def send_pushover(text, title):
    chunks = chunk_lines(text.splitlines())
    total = len(chunks)

    for idx, chunk in enumerate(chunks, start=1):
        payload = {
            "token": APP_TOKEN,
            "user": USER_KEY,
            "message": chunk,
            "title": f"{title} - part {idx}/{total}" if total > 1 else title,
        }

        if DEVICE:
            payload["device"] = DEVICE

        data = parse.urlencode(payload).encode("utf-8")
        req = request.Request(PUSHOVER_ENDPOINT, data=data, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")

        try:
            with request.urlopen(req, timeout=15) as resp:
                resp.read()
        except error.HTTPError as e:
            print(f"Pushover HTTP error: {e.code} {e.reason}", file=sys.stderr)
            print(e.read().decode("utf-8", errors="replace"), file=sys.stderr)
            return False
        except Exception as ex:
            print(f"Pushover error: {ex}", file=sys.stderr)
            return False

        time.sleep(0.3)

    return True
	
def main():
    args = parse_args()
    found_dirs = set()

    scan_paths = [args.path] if args.path else MEDIA_PATHS

    for base in scan_paths:
        base_path = Path(base)

        if not base_path.exists():
            print(f"Path not found: {base}", file=sys.stderr)
            continue

        for root, dirs, files in os.walk(base):
            if any(f.lower().endswith(".iso") for f in files):
                found_dirs.add(Path(root))

    if not found_dirs:
        print(f"ISO scan completed. No .iso files found in: {', '.join(scan_paths)}")
        return 0

    lines = []
    for folder in sorted(found_dirs, key=lambda p: str(p).lower()):
        rel = None

        for base in MEDIA_PATHS:
            try:
                rel = folder.relative_to(base)
                break
            except ValueError:
                pass

        lines.append(f"- {rel if rel is not None else folder}")

    message = "ISO scan result. Folders with .iso files:\n\n" + "\n".join(lines)

    if send_pushover(message, "ISO scan - results"):
        print(message)
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
