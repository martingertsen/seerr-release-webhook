# Seerr Release Webhook

Webhook service for Seerr/Overseerr/Jellyseerr that performs targeted post-processing when media becomes available.
This helps detect bad releases that contain ISO images instead of actual media files and automatically removes embedded subtitle formats known to cause Plex transcoding issues.

## Overview

This setup provides a lightweight webhook endpoint on the script host server:

```text
http://<hostname>:5001/seerr-available
```
Expected result: `HTTP 501` / Unsupported method (`GET`)
This shows the service is running, the 501 error is due to the service not accepting GET requests, but it is still an easy test to perform in a browser.

When Seerr marks a request as "available", it sends a webhook request to this endpoint.

The webhook service then:
- receives the Seerr payload
- validates the Authorization bearer token
- ignores Uptime Kuma health checks
- resolves the local media path using Radarr or Sonarr
- runs a targeted ISO scan against only that media path
- sends a Pushover notification if ISO files are found
- runs subtitle cleanup against only that media path
- removes embedded ASS, SSA, PGS and VobSub subtitle tracks
- automatically deletes temporary backup files after successful processing

## Components
| Component	| Purpose |
| --------- | ------- |
| `/opt/seerr-webhook` | Webhook application source code |
| `/etc/seerr-webhook.env` | Environment variables |
| `/etc/systemd/system/seerr-webhook.service` | systemd service |
| `/opt/seerr-webhook/find_media_path.py`   | Resolves Seerr payload to local media path via Radarr/Sonarr |
| `/opt/seerr-webhook/plex-subs-cleanup.sh` | Removes problematic embedded subtitle formats from newly available media |
| `/opt/seerr-webhook/scan_isos_and_send_pushover.py` | Scans media folders for ISO files and sends Pushover notifications |

## Requirements
 - No external Python packages are required
 - Ubuntu server
 - Accessible media storage (example: NAS mount)
 - Pushover account and application token
 - Python 3
 - Seerr
 - Network access between Seerr, the file storage, and the Ubuntu server
 - Radarr
 - Sonarr
 - mkvmerge (MKVToolNix)
 - ffprobe (ffmpeg)
 - jq

## Directory Structure
```text
/opt/seerr-webhook
├── webhook.py
├── find_media_path.py
├── scan_isos_and_send_pushover.py
├── plex-subs-cleanup.sh
├── systemd/
│   └── seerr-webhook.service

/etc/seerr-webhook.env
/etc/systemd/system/seerr-webhook.service
```

## Installation
### 1. Clone Repository
```bash
cd /opt
sudo git clone https://github.com/martingertsen/seerr-release-webhook.git /opt/seerr-webhook
```

### 2. Create Environment File
Create:
```bash
/etc/seerr-webhook.env
```
Example:
```text
WEBHOOK_SECRET='<YOUR_WEBHOOK_SECRET_FOR_SEERR>'
WEBHOOK_PORT='5001'
WEBHOOK_ENDPOINT='seerr-available'

PUSHOVER_USER_KEY='<YOUR_PUSHOVER_USER_KEY>'
PUSHOVER_APP_TOKEN='<YOUR_PUSHOVER_APP_TOKEN>'
PUSHOVER_DEVICE='<YOUR_PUSHOVER_DEVICE_NAME>'

MEDIA_PATHS='/mnt/nas/media/movies:/mnt/nas/media/tv'

RADARR_URL='http://docker.localdomain:7878'
RADARR_API_KEY='<RADARR_API_KEY>'

SONARR_URL='http://docker.localdomain:8989'
SONARR_API_KEY='<SONARR_API_KEY>'
```
Note: the provided `MEDIA_PATHS` value is just an example.
Note: Media Available events normally operate on the specific path resolved through Radarr/Sonarr. MEDIA_PATHS is primarily used for manual scans and fallback behaviour.

Protect the file:
```bash
sudo chmod 600 /etc/seerr-webhook.env
```

## Update service file
Adjust the `User=` value in the systemd service file to match the local Linux user running the service.
If you placed anything differently than expected here, the paths must also be updated.
```bash
sudo nano /opt/seerr-webhook/systemd/seerr-webhook.service
```
Example:
```text
[Unit]
Description=Seerr request available webhook
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=administrator
WorkingDirectory=/opt/seerr-webhook
EnvironmentFile=/etc/seerr-webhook.env
ExecStart=/usr/bin/python3 /opt/seerr-webhook/webhook.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Install systemd Service
Copy service file:
```bash
sudo cp systemd/seerr-webhook.service /etc/systemd/system/
```

Reload systemd:
```bash
sudo systemctl daemon-reload
```
Enable service:
```bash
sudo systemctl enable seerr-webhook
```
Start service:
```bash
sudo systemctl start seerr-webhook
```

## Service Management
Status
```bash
systemctl status seerr-webhook
```
Restart
```bash
sudo systemctl restart seerr-webhook
```
Follow Logs
```bash
journalctl -u seerr-webhook -f
```

## Verify Listening Port
Verify the webhook is listening:
```bash
sudo ss -tulpn | grep 5001
```
Expected:
```text
LISTEN 0 128 0.0.0.0:5001
```

## Seerr Configuration
In Seerr:

### Settings → Notifications → Webhook
Add webhook URL:
```text
http://<hostname>:5001/seerr-available
```
- Enable event:
  - Media Available
- Method:
  - POST
- Content-Type:
  - application/json
- Authorization Header:
  - Bearer <WEBHOOK_SECRET>

### Example JSON Payload
```json
{
  "notification_type": "{{notification_type}}",
  "event": "{{event}}",
  "subject": "{{subject}}",
  "media_type": "{{media_type}}",
  "tmdbId": "{{media_tmdbid}}",
  "tvdbId": "{{media_tvdbid}}"
}
```

## Testing
### Basic Connectivity Test
```bash
curl http://<hostname>:5001/seerr-available
```
Expected result:
Expected result:

```text
HTTP 501 Unsupported method ('GET')
```

### Example Media Available Test
```bash
set -a
source /etc/seerr-webhook.env
set +a

curl -X POST "http://localhost:${WEBHOOK_PORT:-5001}/${WEBHOOK_ENDPOINT:-seerr-available}" \
  -H "Authorization: Bearer $WEBHOOK_SECRET" \
  -H "Content-Type: application/json" \
  --data '{
    "notification_type": "MEDIA_AVAILABLE",
    "event": "Movie Request Now Available",
    "subject": "Example Movie",
    "media_type": "movie",
    "tmdbId": "575264",
    "tvdbId": ""
  }'
```

## Uptime Kuma
Example health check payload:
```json
{
  "source": "uptime-kuma"
}
```
Health checks are ignored and do not trigger ISO scans or subtitle cleanup.

## Troubleshooting
### Service Does Not Start
Check logs:
```bash
journalctl -u seerr-webhook -n 100
```

### Port Already In Use
Check:
```bash
sudo ss -tulpn | grep 5001
```

## Backup
Important files to back up:
```text
/opt/seerr-webhook/webhook.py
/opt/seerr-webhook/find_media_path.py
/opt/seerr-webhook/scan_isos_and_send_pushover.py
/opt/seerr-webhook/plex-subs-cleanup.sh
/etc/seerr-webhook.env
/etc/systemd/system/seerr-webhook.service
```

## Example Restore Procedure
```bash
sudo cp seerr-webhook.env /etc/
sudo cp seerr-webhook.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable seerr-webhook
sudo systemctl start seerr-webhook
```

Verify:
```bash
systemctl status seerr-webhook
```

## Security Notes
This webhook is intended for internal LAN use.

Recommended:
 - do not expose directly to the internet
 - use reverse proxy authentication if externally accessible
 - keep keys and tokens private
 - restrict firewall access where possible
