# Seerr Release Webhook

Webhook service for Seerr/Overseerr/Jellyseerr that runs a local ISO scan when media becomes available and sends a Pushover notification if `.iso` files are found.
This is to detect bad releases containing such files instead of actual media files, so manual action can be taken to rectify the problem.

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
- runs `scan_isos_and_send_pushover.py`
- scans configured media paths for `.iso` files
- sends a Pushover notification if any are found

## Components
| Component	| Purpose |
| --------- | ------- |
| `/opt/seerr-webhook` | Webhook application source code |
| `/etc/seerr-webhook.env` | Environment variables |
| `/etc/systemd/system/seerr-webhook.service` | systemd service |
| `/var/log/seerr-webhook` | Log files |

## Requirements
 - No external Python packages are required
 - Ubuntu server
 - Accessible media storage (example: NAS mount)
 - Pushover account and application token
 - Python 3
 - Seerr
 - Network access between Seerr, the file storage, and the Ubuntu server

## Directory Structure
```text
/opt/seerr-webhook
/etc/seerr-webhook.env
/etc/systemd/system/seerr-webhook.service
/var/log/seerr-webhook
```

## Installation
### 1. Clone Repository
```bash
cd /opt
sudo git clone https://github.com/YOUR_USERNAME/seerr-release-webhook.git /opt/seerr-webhook
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
```
Note: the provided `MEDIA_PATHS` value is just an example.

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
Enable event:
 - Media Available
Method:
 - POST
Content-Type:
 - application/json

## Testing
### Basic Connectivity Test
```bash
curl http://<hostname>:5001/seerr-available
```

###Example POST Test
```bash
curl -X POST http://<hostname>:5001/seerr-available \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_WEBHOOK_SECRET_FOR_SEERR>" \
  -d '{}'
```

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
/opt/seerr-webhook
/etc/seerr-webhook.env
/etc/systemd/system/seerr-webhook.service
```

## Example Restore Procedure
```bash
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
