#!/bin/bash
# SearXNG LXC Setup Script for TrueNAS with WireGuard VPN
# Auto-detects container management system (LXC/Incus)
# version 1.3

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Auto-detect container management system
if command -v incus >/dev/null 2>&1; then
    CONTAINER_CMD="incus"
    EXEC_CMD="incus exec"
    FILE_PUSH_CMD="incus file push"
elif command -v lxc >/dev/null 2>&1; then
    CONTAINER_CMD="lxc"
    EXEC_CMD="lxc exec"
    FILE_PUSH_CMD="lxc file push"
else
    echo "Error: Neither incus nor lxc command found. Please install container management tools." >&2
    exit 1
fi

echo "Using container management system: $CONTAINER_CMD"

# Prompt for WireGuard VPN configuration
echo -e "\nPaste your WireGuard VPN configuration below (press ENTER, then Ctrl+D when done):"
WG_TMP_FILE="/tmp/wg0.conf"
cat > "$WG_TMP_FILE"
chmod 600 "$WG_TMP_FILE"
echo "WireGuard config saved to $WG_TMP_FILE"

# Define variables
CONTAINER_NAME="searxng"
SEARXNG_PORT="8080"

# Test if container exists and is running
if ! $EXEC_CMD $CONTAINER_NAME -- echo "Container accessible" >/dev/null 2>&1; then
    echo "Error: Container '$CONTAINER_NAME' is not accessible. Please ensure it exists and is running." >&2
    exit 1
fi

echo "Container '$CONTAINER_NAME' is accessible. Proceeding with setup..."

# Ensure /etc/wireguard exists in container and push wg0.conf
$EXEC_CMD $CONTAINER_NAME -- mkdir -p /etc/wireguard
$FILE_PUSH_CMD "$WG_TMP_FILE" "$CONTAINER_NAME/etc/wireguard/wg0.conf"
$EXEC_CMD $CONTAINER_NAME -- chmod 600 /etc/wireguard/wg0.conf

# Enter container to set up everything
$EXEC_CMD $CONTAINER_NAME -- /bin/bash <<'EOF'
# Create apps user with UID:GID 568:568 if not present
if ! grep -q "^apps:" /etc/group; then
    groupadd -g 568 apps
fi
if ! id -u apps >/dev/null 2>&1; then
    useradd -u 568 -g apps -d /home/apps -m apps
fi

# Install required packages
apt update && apt upgrade -y
apt install -y wireguard nano curl wget git python3 python3-pip python3-venv nginx

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# Set up SearXNG
cd /home/apps
python3 -m venv searxng-venv
source searxng-venv/bin/activate
pip install --upgrade pip
pip install searxng[all]

# Generate secret key and create config
SECRET_KEY=$(openssl rand -hex 32)
mkdir -p /etc/searxng

cat > /etc/searxng/settings.yml << SEARXNG_EOF
use_default_settings: true
server:
  secret_key: "$SECRET_KEY"
  bind_address: "127.0.0.1"
  port: 8888
  base_url: false
  image_proxy: true

ui:
  default_locale: "en"
  default_theme: simple

search:
  safe_search: 0
  default_lang: "auto"
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

outgoing:
  request_timeout: 3.0
  max_request_timeout: 6.0
SEARXNG_EOF

# Create systemd service
cat > /etc/systemd/system/searxng.service << SVC_EOF
[Unit]
Description=SearXNG
After=wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
User=apps
Group=apps
WorkingDirectory=/home/apps
Environment=SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
ExecStart=/home/apps/searxng-venv/bin/python -m searxng.webapp
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

# Configure nginx
cat > /etc/nginx/sites-available/default << NGINX_EOF
server {
    listen 8080;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF

# Set permissions and start services
chown -R apps:apps /home/apps
chown apps:apps /etc/searxng/settings.yml
systemctl daemon-reload
systemctl enable --now nginx
systemctl enable --now searxng

echo "Services started. Checking status..."
systemctl status searxng --no-pager -l
systemctl status nginx --no-pager -l

EOF

# Get container IP and display info
CONTAINER_IP=$($EXEC_CMD $CONTAINER_NAME -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\\.\d+){3}' | head -1)

echo -e "\n✅ SearXNG with VPN Setup Complete!"
echo "Container: $CONTAINER_NAME"
echo "WebUI: http://$CONTAINER_IP:$SEARXNG_PORT"
echo "WireGuard VPN is active inside container."

# Test VPN connection
echo -e "\nTesting VPN connection..."
VPN_IP=$($EXEC_CMD $CONTAINER_NAME -- curl -s --max-time 10 ip.me || echo "Unable to get IP")
echo "Container IP (via VPN): $VPN_IP"

# Clean up
rm -f "$WG_TMP_FILE"

echo -e "\nSetup complete! If you see any service errors above, check logs with:"
echo "$EXEC_CMD $CONTAINER_NAME -- journalctl -u searxng -f"
