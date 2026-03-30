#!/bin/bash
# ─────────────────────────────────────────────────────────
# setup-sandbox.sh — Create an isolated sandbox user
# ─────────────────────────────────────────────────────────
# Usage: sudo bash setup-sandbox.sh <sandbox-username> <owner-username>
# Example: sudo bash setup-sandbox.sh sandbox dev
# ─────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SANDBOX_USER="${1:-}"
OWNER_USER="${2:-}"

if [ -z "$SANDBOX_USER" ] || [ -z "$OWNER_USER" ]; then
    echo -e "${RED}Usage: sudo bash setup-sandbox.sh <sandbox-username> <owner-username>${NC}"
    echo "  Example: sudo bash setup-sandbox.sh sandbox dev"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Must run as root${NC}"
    exit 1
fi

if ! id "$OWNER_USER" &>/dev/null; then
    echo -e "${RED}Owner user '$OWNER_USER' does not exist${NC}"
    exit 1
fi

echo -e "${GREEN}Setting up sandbox user:${NC} $SANDBOX_USER (owner: $OWNER_USER)"
echo ""

# ── Create user ──────────────────────────────────────────
if id "$SANDBOX_USER" &>/dev/null; then
    echo -e "${YELLOW}User '$SANDBOX_USER' already exists — skipping creation${NC}"
else
    useradd -m -s /bin/bash "$SANDBOX_USER"
    echo -e "${GREEN}Created user:${NC} $SANDBOX_USER"
fi

# ── Lock down home dirs ──────────────────────────────────
chmod 700 "/home/$SANDBOX_USER"
chmod 700 "/home/$OWNER_USER"
echo -e "${GREEN}Home dirs locked:${NC} 700 on both /home/$SANDBOX_USER and /home/$OWNER_USER"

# ── Create workspace ─────────────────────────────────────
mkdir -p "/home/$SANDBOX_USER/projects"
chown "$SANDBOX_USER:$SANDBOX_USER" "/home/$SANDBOX_USER/projects"
echo -e "${GREEN}Workspace:${NC} /home/$SANDBOX_USER/projects"

# ── Allow owner to su to sandbox without password ────────
SUDOERS_FILE="/etc/sudoers.d/${OWNER_USER}-${SANDBOX_USER}"
echo "$OWNER_USER ALL=($SANDBOX_USER) NOPASSWD: ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
echo -e "${GREEN}Sudoers:${NC} $OWNER_USER can switch to $SANDBOX_USER without password"

# ── Disable direct SSH for sandbox ───────────────────────
if grep -q "^DenyUsers.*$SANDBOX_USER" /etc/ssh/sshd_config 2>/dev/null; then
    echo -e "${YELLOW}SSH deny already configured for $SANDBOX_USER${NC}"
elif grep -q "^DenyUsers" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i "s/^DenyUsers.*/& $SANDBOX_USER/" /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "${GREEN}SSH:${NC} Added $SANDBOX_USER to existing DenyUsers"
else
    echo "DenyUsers $SANDBOX_USER" >> /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "${GREEN}SSH:${NC} Direct SSH disabled for $SANDBOX_USER"
fi

# ── Network restrictions (iptables per-user) ─────────────
echo -e "${GREEN}Setting up network restrictions for $SANDBOX_USER...${NC}"
SANDBOX_UID=$(id -u "$SANDBOX_USER")

# Flush any existing rules for this user (idempotent rerun)
iptables -L OUTPUT --line-numbers -n 2>/dev/null | grep "owner UID match $SANDBOX_UID" | \
    awk '{print $1}' | sort -rn | while read -r line; do
    iptables -D OUTPUT "$line" 2>/dev/null || true
done

# Allow DNS (53), HTTP (80), HTTPS (443) — block everything else
iptables -A OUTPUT -m owner --uid-owner "$SANDBOX_UID" -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner "$SANDBOX_UID" -p tcp --dport 80 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner "$SANDBOX_UID" -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner "$SANDBOX_UID" -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner "$SANDBOX_UID" -j DROP

echo -e "${GREEN}Network:${NC} $SANDBOX_USER limited to HTTPS (443), HTTP (80), DNS (53)"

# ── Persist iptables rules ───────────────────────────────
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
else
    apt install -y iptables-persistent
    netfilter-persistent save
fi
echo -e "${GREEN}iptables rules persisted${NC}"

# ── Summary ──────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Sandbox '$SANDBOX_USER' is ready${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  Switch to sandbox:"
echo "    sudo -u $SANDBOX_USER -i"
echo ""
echo "  Verify isolation:"
echo "    ls /home/$OWNER_USER        # should fail"
echo "    whoami                       # $SANDBOX_USER"
echo ""
echo "  Network: outbound HTTPS + HTTP + DNS only"
echo "  SSH: direct login disabled"
echo "  Home: /home/$SANDBOX_USER (mode 700)"
echo ""
