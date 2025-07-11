#!/bin/bash
# SearXNG LXC Setup Script for TrueNAS with WireGuard VPN
# Based on qbit-lxc.sh from ServersatHome
# version 1.0

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Prompt for WireGuard VPN configuration
echo -e "\nPaste your WireGuard VPN configuration below (press ENTER, then Ctrl+D when done):"
WG_TMP_FILE="/tmp/wg0.conf"
cat > "$WG_TMP_FILE"
chmod 600 "$WG_TMP_FILE"
echo "WireGuard config saved to $WG_TMP_FILE"

# Define variables
CONTAINER_NAME="searxng"
SEARXNG_PORT="8080"

# Ensure /etc/wireguard exists in container and push wg0.conf
incus exec $CONTAINER_NAME -- mkdir -p /etc/wireguard
incus file push "$WG_TMP_FILE" "$CONTAINER_NAME/etc/wireguard/wg0.conf"
incus exec $CONTAINER_NAME -- chmod 600 /etc/wireguard/wg0.conf

# Enter container to set up everything
incus exec $CONTAINER_NAME -- /bin/bash <<'EOF'
# Create apps user with UID:GID 568:568 if not present
if ! grep -q "^apps:" /etc/group; then
    groupadd -g 568 apps
fi
if ! id -u apps >/dev/null 2>&1; then
    useradd -u 568 -g apps -d /home/apps -m apps
fi

# Install required packages
apt update && apt upgrade -y
apt install -y wireguard nano curl wget git python3 python3-pip python3-venv nginx supervisor

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Create directories for SearXNG
mkdir -p /opt/searxng
mkdir -p /etc/searxng
mkdir -p /var/log/searxng

# Set up SearXNG
cd /opt/searxng
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install searxng[all]

# Generate secret key
SECRET_KEY=$(openssl rand -hex 32)

# Create SearXNG configuration
cat > /etc/searxng/settings.yml <<'SEARXNG_EOF'
use_default_settings: true
server:
  secret_key: "SECRET_KEY_PLACEHOLDER"
  bind_address: "127.0.0.1"
  port: 8888
  base_url: false
  image_proxy: true
  http_protocol_version: "1.1"
  method: "POST"
  default_http_headers:
    X-Content-Type-Options: nosniff
    X-XSS-Protection: 1; mode=block
    X-Download-Options: noopen
    X-Robots-Tag: noindex, nofollow
    Referrer-Policy: no-referrer

ui:
  static_use_hash: true
  default_locale: "en"
  query_in_title: false
  infinite_scroll: false
  center_alignment: false
  cache_url: uWSGI
  default_theme: simple
  theme_args:
    simple_style: auto

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "auto"
  ban_time_on_fail: 5
  max_ban_time_on_fail: 120
  formats:
    - html
    - json

engines:
  - name: google
    disabled: false
  - name: bing
    disabled: false
  - name: duckduckgo
    disabled: false
  - name: startpage
    disabled: false
  - name: qwant
    disabled: false

outgoing:
  request_timeout: 3.0
  max_request_timeout: 6.0
  useragent_suffix: ""
  pool_connections: 100
  pool_maxsize: 20
  enable_http2: true
SEARXNG_EOF

# Replace placeholder with actual secret key
sed -i "s/SECRET_KEY_PLACEHOLDER/$SECRET_KEY/g" /etc/searxng/settings.yml

# Create nginx configuration
cat > /etc/nginx/sites-available/searxng <<'NGINX_EOF'
server {
    listen 8080;
    server_name _;

    client_max_body_size 1M;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }

    location /static/ {
        alias /opt/searxng/venv/lib/python3.*/site-packages/searxng/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
NGINX_EOF

# Enable nginx site
ln -sf /etc/nginx/sites-available/searxng /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create systemd service for SearXNG
cat > /etc/systemd/system/searxng.service <<'SVC_EOF'
[Unit]
Description=SearXNG
After=wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
User=apps
Group=apps
WorkingDirectory=/opt/searxng
Environment=SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
ExecStart=/opt/searxng/venv/bin/python -m searxng.webapp
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC_EOF

# Set permissions
chown -R apps:apps /opt/searxng
chown -R apps:apps /var/log/searxng
chown apps:apps /etc/searxng/settings.yml

# Reload systemd and start services
systemctl daemon-reload
systemctl enable --now nginx
systemctl enable --now searxng

EOF

# Display access info
CONTAINER_IP=$(incus exec $CONTAINER_NAME -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\\.\d+){3}')

echo -e "\n✅ SearXNG with VPN Setup Complete!"
echo "WebUI: http://$CONTAINER_IP:$SEARXNG_PORT"
echo "WireGuard VPN is active inside container."
echo "All search traffic is routed through your VPN for privacy."

# Clean up temp file
rm -f "$WG_TMP_FILE"
