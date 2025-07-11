#!/bin/bash
set -e

# SearXNG + WireGuard install script for Ubuntu 24.04 (Noble)

# 1. Install dependencies
apt update
apt install -y git python3 python3-venv python3-pip redis nginx wireguard

# 2. Create a dedicated user
id searxng &>/dev/null || useradd -m -s /bin/bash searxng

# 3. Clone SearXNG
sudo -u searxng git clone https://github.com/searxng/searxng.git /home/searxng/searxng

# 4. Set up Python virtual environment
sudo -u searxng python3 -m venv /home/searxng/searxng/venv
sudo -u searxng /home/searxng/searxng/venv/bin/pip install -U pip wheel setuptools
sudo -u searxng /home/searxng/searxng/venv/bin/pip install -e /home/searxng/searxng

# 5. Generate secret key
SECRET_KEY=$(openssl rand -hex 32)

# 6. Create settings.yml
sudo -u searxng mkdir -p /home/searxng/searxng/searx
cat > /home/searxng/searxng/searx/settings.yml <<EOF
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
EOF

# 7. Prompt for WireGuard config
echo "Paste your WireGuard config (wg0.conf), then press Ctrl+D:"
cat > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# 8. Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# 9. Set up a kill switch (block all non-VPN traffic except local)
# This will drop all outbound traffic except via wg0 and localhost
iptables -I OUTPUT ! -o lo ! -o wg0 -m conntrack --ctstate NEW -j DROP

# To make this persistent, install iptables-persistent:
apt install -y iptables-persistent
netfilter-persistent save

# 10. Create systemd service for SearXNG (waits for VPN)
cat > /etc/systemd/system/searxng.service <<EOF
[Unit]
Description=SearXNG service
After=network.target redis.service wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=simple
User=searxng
Group=searxng
WorkingDirectory=/home/searxng/searxng
Environment=SEARXNG_SETTINGS_PATH=/home/searxng/searxng/searx/settings.yml
ExecStart=/home/searxng/searxng/venv/bin/python searx/webapp.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 11. Enable and start services
systemctl daemon-reload
systemctl enable --now redis
systemctl enable --now searxng

echo "✅ SearXNG is running on http://localhost:8080 (all traffic routed via WireGuard VPN)"
echo "You can edit /home/searxng/searxng/searx/settings.yml to customize your instance."
echo "WireGuard config is at /etc/wireguard/wg0.conf"
echo "Kill switch is active: all non-VPN traffic is blocked."
