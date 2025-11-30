# Deploy FastAPI backend on Ubuntu 22.04

These steps target your server (Ubuntu Server 22.04 LTS, 2 vCPU, 4GB RAM, 50GB disk, public IP). Replace placeholders like `api.your-domain.com` with your actual domain or use the public IP if you do not have a domain.

## 1) Prepare system packages
```bash
sudo apt update && sudo apt install -y python3-venv python3-pip nginx
```

Optionally create a dedicated user (recommended):
```bash
sudo adduser --system --group app
sudo mkdir -p /opt/flutter_reader
sudo chown -R app:app /opt/flutter_reader
```

## 2) Upload project and create venv
```bash
# As root or the app user
cd /opt/flutter_reader
# Copy the server/ directory here (scp, rsync, or git clone)
# Example using rsync from local machine:
# rsync -av server/ user@SERVER_IP:/opt/flutter_reader/server/

python3 -m venv venv
source venv/bin/activate
pip install -r server/requirements.txt
```

## 3) Configure environment
```bash
cp server/.env.example server/.env
# Edit values
nano server/.env
```
Set `CORS_ORIGINS` to include your frontend origin(s), for example:
```
CORS_ORIGINS=https://your-frontend-domain.com,http://localhost:55119
```

## 4) Create systemd service
```bash
sudo cp server/deploy/flutter-reader-api.service /etc/systemd/system/flutter-reader-api.service
sudo sed -i 's|/opt/flutter_reader/server|/opt/flutter_reader/server|g' /etc/systemd/system/flutter-reader-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now flutter-reader-api
sudo systemctl status flutter-reader-api
```
The service runs Uvicorn at `127.0.0.1:8000`.

## 5) Configure Nginx reverse proxy
```bash
sudo cp server/deploy/nginx.conf.example /etc/nginx/sites-available/flutter-reader-api
sudo sed -i 's/api.your-domain.com/YOUR_DOMAIN_OR_IP/g' /etc/nginx/sites-available/flutter-reader-api
sudo ln -sf /etc/nginx/sites-available/flutter-reader-api /etc/nginx/sites-enabled/flutter-reader-api
sudo nginx -t && sudo systemctl reload nginx
```
If using a domain and you want HTTPS:
```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d api.your-domain.com --agree-tos -m you@example.com --redirect
```

## 6) Firewall (UFW)
```bash
sudo ufw allow 'Nginx Full'
# If UFW is disabled, enable it cautiously:
sudo ufw enable
```

## 7) Quick API test
```bash
curl -s http://YOUR_DOMAIN_OR_IP/auth/logout
curl -s -X POST http://YOUR_DOMAIN_OR_IP/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"test@example.com","password":"secret123"}'
```
You should receive a JSON with `accessToken` and `user`.

## 8) Frontend integration
- Build-time override in Flutter:
  - Use `--dart-define API_BASE_URL=https://YOUR_DOMAIN_OR_IP` and ensure `CORS_ORIGINS` contains that origin.
- Alternatively set `_baseUrl` directly in `lib/services/auth_service.dart`.

## 9) Operations
- Restart API: `sudo systemctl restart flutter-reader-api`
- View logs: `journalctl -u flutter-reader-api -f`
- Nginx logs: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`

## Notes
- Bandwidth is 5Mbps; large uploads/downloads may be slow. Consider tuning `client_max_body_size` in Nginx if you plan to upload bigger files.
- For persistent user data, consider changing `DATA_DIR` in `.env` to a durable path (e.g., `/var/lib/flutter_reader/data`).
