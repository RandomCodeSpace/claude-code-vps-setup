#!/bin/bash
# ─────────────────────────────────────────────────────────
# setup-nginx-certbot.sh — Nginx reverse proxy + Let's Encrypt SSL
# ─────────────────────────────────────────────────────────
# Usage: sudo bash setup-nginx-certbot.sh <domain> <port>
# Example: sudo bash setup-nginx-certbot.sh paperclip.ossomni.com 3100
# ─────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DOMAIN="${1:-}"
PORT="${2:-}"

if [ -z "$DOMAIN" ] || [ -z "$PORT" ]; then
    echo -e "${RED}Usage: sudo bash setup-nginx-certbot.sh <domain> <port>${NC}"
    echo "  Example: sudo bash setup-nginx-certbot.sh paperclip.ossomni.com 3100"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Must run as root${NC}"
    exit 1
fi

echo -e "${GREEN}Setting up nginx + certbot for:${NC} $DOMAIN -> localhost:$PORT"
echo ""

# ── Install nginx + certbot ──────────────────────────────
echo -e "${GREEN}Installing nginx + certbot...${NC}"
apt update -y
apt install -y nginx certbot python3-certbot-nginx

# ── UFW rules ────────────────────────────────────────────
echo -e "${GREEN}Opening ports 80 and 443...${NC}"
ufw allow 80/tcp
ufw allow 443/tcp

# ── Nginx site config ────────────────────────────────────
SITE_FILE="/etc/nginx/sites-available/$DOMAIN"
echo -e "${GREEN}Writing nginx config:${NC} $SITE_FILE"

cat > "$SITE_FILE" << NGINX
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
NGINX

# ── Enable site ──────────────────────────────────────────
ln -sf "$SITE_FILE" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx
systemctl enable nginx
echo -e "${GREEN}Nginx configured and running${NC}"

# ── SSL certificate ──────────────────────────────────────
echo ""
echo -e "${YELLOW}Requesting SSL certificate...${NC}"
echo -e "${YELLOW}Make sure DNS A record exists: $DOMAIN -> $(curl -s ifconfig.me)${NC}"
echo ""

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect

# ── Verify ───────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN} HTTPS reverse proxy ready${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  Domain  : https://$DOMAIN"
echo "  Backend : http://127.0.0.1:$PORT"
echo "  Cert    : auto-renews via certbot timer"
echo ""
echo "  Test: curl -I https://$DOMAIN"
echo ""
echo "  To add another domain later:"
echo "    sudo bash setup-nginx-certbot.sh another.ossomni.com 3200"
echo ""
