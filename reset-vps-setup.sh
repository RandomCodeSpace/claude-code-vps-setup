#!/bin/bash
# ============================================================
# Reset VPS Setup — Undo everything installed by secure-vps-setup.sh
# Run as root: sudo bash reset-vps-setup.sh
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }

# --- Check root ---
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root: sudo bash reset-vps-setup.sh"
    exit 1
fi

DEV_USER="dev"
DEV_HOME="/home/$DEV_USER"
MANIFEST="/var/lib/vps-setup/installed-packages.manifest"

# ============================================================
# 1. Show what will be removed and prompt for confirmation
# ============================================================
echo ""
echo "========================================="
echo "  Reset VPS Setup"
echo "  Undo secure-vps-setup.sh"
echo "========================================="
echo ""

echo "This will remove:"
echo "  - Claude Code binary and config"
echo "  - Bashrc marker blocks added by setup"
echo "  - Go toolchain (/usr/local/go, ~/go)"
echo "  - Gradle (/opt/gradle-*)"
echo "  - Miniconda (/opt/miniconda3)"
echo "  - nvm (~/.nvm)"
echo "  - pyenv (~/.pyenv)"
echo "  - setup-github helper"
echo "  - tmux config"
echo "  - SSH keys and config (dev + root)"
echo "  - GPG agent config"
echo "  - Cron jobs (ClamAV daily, rkhunter weekly)"
echo "  - fail2ban jail config"
echo "  - ufw firewall (disabled)"
echo "  - fd/bat symlinks"
echo "  - Apt repos (Adoptium, GitHub CLI)"
echo "  - Services (ClamAV, fail2ban)"

if [ -f "$MANIFEST" ]; then
    PKG_COUNT=$(wc -l < "$MANIFEST" 2>/dev/null || echo 0)
    echo "  - Apt packages from manifest ($PKG_COUNT packages)"
else
    echo "  - Apt packages: (no manifest found, will skip)"
fi

echo "  - Setup manifest (/var/lib/vps-setup)"
echo ""

read -rp "Proceed with reset? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_warning "Aborted."
    exit 0
fi

# ============================================================
# 2. Ask about dev user deletion (separate prompt)
# ============================================================
DELETE_DEV_USER="n"
if id "$DEV_USER" &>/dev/null; then
    echo ""
    read -rp "Also delete the '$DEV_USER' user and home directory? (y/N): " DELETE_DEV_USER
fi

echo ""
print_status "Starting reset..."
echo ""

# ============================================================
# 3. Claude Code
# ============================================================
print_status "Removing Claude Code..."
rm -f /usr/local/bin/claude
if [ -d "$DEV_HOME" ]; then
    rm -rf "$DEV_HOME/.claude"
fi

# ============================================================
# 4. Bashrc blocks
# ============================================================
if [ -f "$DEV_HOME/.bashrc" ]; then
    print_status "Removing setup blocks from .bashrc..."
    # Old format: everything from single marker to EOF
    sed -i '/^# --- Claude Code VPS additions ---$/,$d' "$DEV_HOME/.bashrc" 2>/dev/null || true
    # New format: START/END marker blocks
    sed -i '/# --- .* START ---/,/# --- .* END ---/d' "$DEV_HOME/.bashrc" 2>/dev/null || true
else
    print_warning "No .bashrc found — skipping"
fi

# ============================================================
# 5. Go
# ============================================================
print_status "Removing Go..."
rm -rf /usr/local/go 2>/dev/null || true
if [ -d "$DEV_HOME" ]; then
    rm -rf "$DEV_HOME/go" 2>/dev/null || true
fi

# ============================================================
# 6. Gradle
# ============================================================
print_status "Removing Gradle..."
rm -rf /opt/gradle-* 2>/dev/null || true
rm -f /usr/local/bin/gradle 2>/dev/null || true

# ============================================================
# 7. nvm
# ============================================================
print_status "Removing nvm..."
if [ -d "$DEV_HOME" ]; then
    rm -rf "$DEV_HOME/.nvm" 2>/dev/null || true
fi

# ============================================================
# 8. pyenv
# ============================================================
print_status "Removing pyenv..."
if [ -d "$DEV_HOME" ]; then
    rm -rf "$DEV_HOME/.pyenv" 2>/dev/null || true
fi

# ============================================================
# 8b. Miniconda
# ============================================================
print_status "Removing Miniconda..."
rm -rf /opt/miniconda3 2>/dev/null || true
rm -f /usr/local/bin/conda 2>/dev/null || true
# Remove conda init block from .bashrc
if [ -f "$DEV_HOME/.bashrc" ]; then
    sed -i '/# >>> conda initialize >>>/,/# <<< conda initialize <<</d' "$DEV_HOME/.bashrc" 2>/dev/null || true
fi

# ============================================================
# 9. setup-github + legacy cc session manager
# ============================================================
print_status "Removing setup-github (and legacy cc if present)..."
rm -f "$DEV_HOME/.local/bin/setup-github" 2>/dev/null || true
# Legacy cleanup: previous versions shipped a 'cc' session manager
rm -f "$DEV_HOME/.local/bin/cc" 2>/dev/null || true
rm -f "$DEV_HOME/.local/share/bash-completion/completions/cc" 2>/dev/null || true
rm -rf "$DEV_HOME/.claude/cc-sessions" 2>/dev/null || true

# ============================================================
# 10. tmux config
# ============================================================
print_status "Removing tmux config..."
rm -f "$DEV_HOME/.tmux.conf" 2>/dev/null || true

# ============================================================
# 11. SSH config
# ============================================================
print_status "Removing SSH keys and config..."
rm -f "$DEV_HOME/.ssh/id_ed25519" 2>/dev/null || true
rm -f "$DEV_HOME/.ssh/id_ed25519.pub" 2>/dev/null || true
rm -f "$DEV_HOME/.ssh/agent-env" 2>/dev/null || true
rm -f "$DEV_HOME/.ssh/config" 2>/dev/null || true
rm -f /root/.ssh/config 2>/dev/null || true

# ============================================================
# 12. GPG config
# ============================================================
print_status "Removing GPG agent config..."
rm -f "$DEV_HOME/.gnupg/gpg-agent.conf" 2>/dev/null || true

# ============================================================
# 13. Cron jobs
# ============================================================
print_status "Removing cron jobs..."
rm -f /etc/cron.daily/clamav-scan 2>/dev/null || true
rm -f /etc/cron.weekly/rkhunter-scan 2>/dev/null || true

# ============================================================
# 14. fail2ban
# ============================================================
print_status "Removing fail2ban jail config..."
rm -f /etc/fail2ban/jail.local 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

# ============================================================
# 15. ufw
# ============================================================
print_status "Disabling ufw..."
ufw disable 2>/dev/null || true

# ============================================================
# 16. Symlinks
# ============================================================
print_status "Removing symlinks..."
rm -f /usr/local/bin/fd 2>/dev/null || true
rm -f /usr/local/bin/bat 2>/dev/null || true

# ============================================================
# 17. Apt repos
# ============================================================
print_status "Removing apt repos and keys..."
rm -f /etc/apt/sources.list.d/adoptium.list 2>/dev/null || true
rm -f /etc/apt/sources.list.d/github-cli.list 2>/dev/null || true
rm -f /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
rm -f /etc/apt/sources.list.d/microsoft-prod.list 2>/dev/null || true
rm -f /etc/apt/keyrings/adoptium.gpg 2>/dev/null || true
rm -f /usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
# .NET installed via dotnet-install.sh (not apt), remove its dir + symlink
rm -rf /usr/share/dotnet 2>/dev/null || true
rm -f /usr/local/bin/dotnet 2>/dev/null || true

# ============================================================
# 18. Services
# ============================================================
print_status "Stopping and disabling services..."
systemctl stop clamav-daemon clamav-freshclam fail2ban caddy 2>/dev/null || true
systemctl disable clamav-daemon clamav-freshclam fail2ban caddy 2>/dev/null || true

# ============================================================
# 19. Apt packages
# ============================================================
if [ -f "$MANIFEST" ]; then
    PACKAGES=$(tr '\n' ' ' < "$MANIFEST" 2>/dev/null)
    if [ -n "$PACKAGES" ]; then
        print_status "Purging apt packages from manifest..."
        apt purge -y $PACKAGES 2>/dev/null || true
    else
        print_warning "Manifest is empty — skipping apt purge"
    fi
else
    print_warning "No manifest at $MANIFEST — skipping apt purge"
fi

# ============================================================
# 20. Dev user
# ============================================================
if [[ "$DELETE_DEV_USER" =~ ^[Yy]$ ]]; then
    print_status "Deleting user '$DEV_USER'..."
    pkill -u "$DEV_USER" 2>/dev/null || true
    userdel -r "$DEV_USER" 2>/dev/null || true
else
    print_warning "Keeping user '$DEV_USER'"
fi

# ============================================================
# 21. Manifest
# ============================================================
print_status "Removing setup manifest..."
rm -rf /var/lib/vps-setup 2>/dev/null || true

# ============================================================
# 22. apt autoremove
# ============================================================
print_status "Running apt autoremove..."
apt autoremove -y 2>/dev/null || true

echo ""
print_status "Reset complete."
echo ""
