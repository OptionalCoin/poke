#!/bin/bash

# SearXNG LXC Setup Script for TrueNAS with WireGuard VPN
# Based on the qBittorrent setup from wiki.serversatho.me

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  SearXNG LXC Setup with WireGuard VPN  ${NC}"
echo -e "${BLUE}========================================${NC}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

# Get LXC container name
read -p "Enter the LXC container name (default: searxng): " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-searxng}

# Check if container exists
if ! lxc-ls | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${RED}Container '${CONTAINER_NAME}' not found. Please create it first.${NC}"
    exit 1
fi

echo -e "${GREEN}Setting up SearXNG in container: ${CONTAINER_NAME}${NC}"

# Get WireGuard config
echo -e "${YELLOW}Please paste your WireGuard configuration below.${NC}"
echo -e "${YELLOW}Press CTRL+D when finished:${NC}"
WG_CONFIG=$(cat)

if [[ -z "$WG_CONFIG" ]]; then
    echo -e "${RED}No WireGuard configuration provided. Exiting.${NC}"
    exit 1
fi

# Execute setup inside the container
lxc-attach -n "$CONTAINER_NAME" -- bash << 'EOF'
set -e

# Update system
apt update && apt upgrade -y

# Install required packages
apt install -y curl wget git python3 python3-pip python3-venv nginx supervisor wireguard-tools iptables

# Create searxng user
useradd -r -s /bin/false -d /var/lib/searxng searxng || true

# Create directories
mkdir -p /var/lib/searxng
mkdir -p /etc/searxng
mkdir -p /var/log/searxng
mkdir -p /etc/wireguard

# Set permissions
chown searxng:searxng /var/lib/searxng
chown searxng:searxng /var/log/searxng

# Install SearXNG
cd /var/lib/searxng
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install searxng[all]

# Generate secret key
SECRET_KEY=$(openssl rand -hex 32)

# Create SearXNG configuration
cat > /etc/searxng/settings.yml << SEARXNG_EOF
use_default_settings: true
server:
  secret_key: "$SECRET_KEY"
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
  - name: searx
    disabled: true

outgoing:
  request_timeout: 3.0
  max_request_timeout: 6.0
  useragent_suffix: ""
  pool_connections: 100
  pool_maxsize: 20
  enable_http2: true
SEARXNG_EOF

# Create systemd service for SearXNG
cat > /etc/systemd/system/searxng.service << SERVICE_EOF
[Unit]
Description=SearXNG
After=network.target

[Service]
Type=simple
User=searxng
Group=searxng
WorkingDirectory=/var/lib/searxng
Environment=SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
ExecStart=/var/lib/searxng/venv/bin/python -m searxng.webapp
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Create nginx configuration
cat > /etc/nginx/sites-available/searxng << NGINX_EOF
server {
    listen 8080;
    server_name _;

    client_max_body_size 1M;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }

    location /static/ {
        alias /var/lib/searxng/venv/lib/python3.*/site-packages/searxng/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
NGINX_EOF

# Enable nginx site
ln -sf /etc/nginx/sites-available/searxng /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create WireGuard startup script
cat > /usr/local/bin/start-wireguard.sh << WG_SCRIPT_EOF
#!/bin/bash
set -e

# Start WireGuard
wg-quick up wg0

# Set up iptables rules to route traffic through VPN
iptables -t nat -A OUTPUT -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53
iptables -t nat -A OUTPUT -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53

# Allow local traffic
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -d 127.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT

# Allow traffic through VPN interface
iptables -A OUTPUT -o wg0 -j ACCEPT

# Block all other traffic
iptables -A OUTPUT -j REJECT

echo "WireGuard started and firewall configured"
WG_SCRIPT_EOF

chmod +x /usr/local/bin/start-wireguard.sh

# Create supervisor configuration for WireGuard
cat > /etc/supervisor/conf.d/wireguard.conf << SUPERVISOR_EOF
[program:wireguard]
command=/usr/local/bin/start-wireguard.sh
autostart=true
autorestart=false
startsecs=0
stdout_logfile=/var/log/wireguard.log
stderr_logfile=/var/log/wireguard.log
EOF

# Enable and start services
systemctl enable nginx
systemctl enable searxng
systemctl enable supervisor

echo "Setup completed inside container"
EOF

# Write WireGuard config to container
echo "$WG_CONFIG" | lxc-attach -n "$CONTAINER_NAME" -- tee /etc/wireguard/wg0.conf > /dev/null

# Set proper permissions for WireGuard config
lxc-attach -n "$CONTAINER_NAME" -- chmod 600 /etc/wireguard/wg0.conf

# Start services
echo -e "${YELLOW}Starting services...${NC}"
lxc-attach -n "$CONTAINER_NAME" -- systemctl start supervisor
lxc-attach -n "$CONTAINER_NAME" -- systemctl start searxng
lxc-attach -n "$CONTAINER_NAME" -- systemctl start nginx

# Get container IP
CONTAINER_IP=$(lxc-info -n "$CONTAINER_NAME" -iH)

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SearXNG Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Container: ${CONTAINER_NAME}${NC}"
echo -e "${GREEN}Web Interface: http://${CONTAINER_IP}:8080${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}Note: It may take a few moments for all services to start${NC}"
echo -e "${YELLOW}Check logs with: lxc-attach -n ${CONTAINER_NAME} -- journalctl -u searxng -f${NC}"

# Create a simple test script
cat > test-searxng-vpn.sh << 'TEST_EOF'
#!/bin/bash
CONTAINER_NAME="$1"
if [[ -z "$CONTAINER_NAME" ]]; then
    echo "Usage: $0 <container_name>"
    exit 1
fi

echo "Testing VPN connection..."
VPN_IP=$(lxc-attach -n "$CONTAINER_NAME" -- curl -s ip.me)
echo "Current IP (should be VPN): $VPN_IP"

echo "Testing SearXNG..."
CONTAINER_IP=$(lxc-info -n "$CONTAINER_NAME" -iH)
curl -s "http://${CONTAINER_IP}:8080" | grep -q "SearXNG" && echo "SearXNG is running!" || echo "SearXNG test failed"
TEST_EOF

chmod +x test-searxng-vpn.sh

echo -e "${BLUE}Test script created: ./test-searxng-vpn.sh ${CONTAINER_NAME}${NC}"
