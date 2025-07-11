#!/bin/bash
# version 0.9
# SearXNG LXC Container Setup Script

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Ask for host data directory (optional for SearXNG)
read -p "Where would you like to store SearXNG data on the host? (e.g., /mnt/tank/searxng or press ENTER to skip): " HOST_DATA_DIR

# Verify directory exists if provided
if [ -n "$HOST_DATA_DIR" ] && [ ! -d "$HOST_DATA_DIR" ]; then
    echo "Error: Directory $HOST_DATA_DIR does not exist on the host." >&2
    exit 1
fi

# Prompt for WireGuard VPN configuration (optional for privacy)
echo -e "\nDo you want to configure WireGuard VPN for enhanced privacy? (y/n): "
read -p "" USE_VPN

WG_TMP_FILE=""
if [[ "$USE_VPN" =~ ^[Yy]$ ]]; then
    echo -e "\nPaste your WireGuard VPN configuration below (press ENTER, then Ctrl+D when done):"
    WG_TMP_FILE="/tmp/wg0.conf"
    cat > "$WG_TMP_FILE"
    chmod 600 "$WG_TMP_FILE"
    echo "WireGuard config saved to $WG_TMP_FILE"
fi

# Define variables
CONTAINER_NAME="searxng"
SEARXNG_PORT="8080"
CONTAINER_DATA_POINT="/data"

# Mount data directory into container if provided
if [ -n "$HOST_DATA_DIR" ]; then
    echo "Mounting host directory $HOST_DATA_DIR to container's $CONTAINER_DATA_POINT..."
    incus config device add $CONTAINER_NAME datadisk disk source="$HOST_DATA_DIR" path="$CONTAINER_DATA_POINT" shift=true
fi

# Set up WireGuard if requested
if [ -n "$WG_TMP_FILE" ]; then
    # Ensure /etc/wireguard exists in container and push wg0.conf
    incus exec $CONTAINER_NAME -- mkdir -p /etc/wireguard
    incus file push "$WG_TMP_FILE" "$CONTAINER_NAME/etc/wireguard/wg0.conf"
    incus exec $CONTAINER_NAME -- chmod 600 /etc/wireguard/wg0.conf
fi

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
apt install -y curl git python3 python3-pip python3-venv redis-server nginx nano

# Install WireGuard if VPN was configured
if [ -f /etc/wireguard/wg0.conf ]; then
    apt install -y wireguard
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
fi

# Create SearXNG directory
sudo -u apps mkdir -p /home/apps/searxng
cd /home/apps/searxng

# Clone SearXNG repository
sudo -u apps git clone https://github.com/searxng/searxng.git .

# Create Python virtual environment
sudo -u apps python3 -m venv venv
sudo -u apps ./venv/bin/pip install -U pip wheel setuptools
sudo -u apps ./venv/bin/pip install -e .

# Generate secret key
SECRET_KEY=$(openssl rand -hex 32)

# Create SearXNG settings
sudo -u apps mkdir -p /home/apps/searxng/searx
sudo -u apps bash -c "cat > /home/apps/searxng/searx/settings.yml" <<CFG_EOF
use_default_settings: true
server:
  secret_key: "$SECRET_KEY"
  bind_address: "0.0.0.0"
  port: 8080
  base_url: false
  image_proxy: true
ui:
  static_use_hash: true
search:
  safe_search: 0
  autocomplete: "duckduckgo"
  default_lang: "en"
redis:
  url: redis://localhost:6379/0
CFG_EOF

# Set permissions
chown -R apps:apps /home/apps/searxng

# Create systemd service for SearXNG
cat > /etc/systemd/system/searxng.service <<SVC_EOF
[Unit]
Description=SearXNG service
After=network.target redis.service
EOF

# Add WireGuard dependency if VPN is configured
if [ -f /etc/wireguard/wg0.conf ]; then
    echo "After=network.target redis.service wg-quick@wg0.service" >> /etc/systemd/system/searxng.service
fi

cat >> /etc/systemd/system/searxng.service <<SVC_EOF
Wants=network-online.target

[Service]
Type=simple
User=apps
Group=apps
WorkingDirectory=/home/apps/searxng
Environment=SEARXNG_SETTINGS_PATH=/home/apps/searxng/searx/settings.yml
ExecStart=/home/apps/searxng/venv/bin/python searx/webapp.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

# Start and enable Redis
systemctl enable --now redis-server

# Reload systemd and start services
systemctl daemon-reload
systemctl enable --now searxng

EOF

# Display access info
CONTAINER_IP=$(incus exec $CONTAINER_NAME -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "\n✅ SearXNG Setup Complete!"
echo "WebUI: http://$CONTAINER_IP:$SEARXNG_PORT"
echo "SearXNG is now running and ready to use"

if [ -n "$HOST_DATA_DIR" ]; then
    echo "Data directory: $CONTAINER_DATA_POINT (host path: $HOST_DATA_DIR)"
fi

if [ -n "$WG_TMP_FILE" ]; then
    echo "WireGuard VPN is active inside container for enhanced privacy"
fi

echo -e "\nNote: You can customize search engines and other settings by editing:"
echo "/home/apps/searxng/searx/settings.yml inside the container"
