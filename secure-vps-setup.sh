#!/bin/bash
# ============================================================
# Secure VPS Setup Script for Claude Code
# Installs & configures:
#   Security  : ClamAV, rkhunter, ufw, fail2ban

#   Terminal  : tmux (mobile-optimized for Termius)
#   Languages : Go, Java 25, Node.js/TypeScript, Python 3.12, Miniconda
#   LSP       : gopls, jdtls, pyright, typescript-language-server
#   Tools     : ripgrep, fd, bat, jq, shellcheck
#   Dev Tool  : Claude Code (native installer)
# Tested on: Ubuntu 22.04 / 24.04
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }

# ============================================================
# Pinned versions — bump these to upgrade, then rerun the script.
# Every install below reinstalls to the pinned version on rerun, so the
# only source of truth for what's on the machine is this block.
# ============================================================

# Go runtime + tools
GO_VERSION="go1.26.2"
GOPLS_VERSION="v0.21.1"
DELVE_VERSION="v1.26.1"
GOLANGCI_LINT_VERSION="v2.11.4"   # v2.x — module path is /v2/cmd/golangci-lint
AIR_VERSION="v1.65.1"
GOIMPORTS_VERSION="v0.44.0"
GOVULNCHECK_VERSION="v1.2.0"
CTM_VERSION="v0.0.4"   # RandomCodeSpace/ctm — tmux session manager for Claude Code

# JVM
TEMURIN_PKG="temurin-25-jdk"
GRADLE_VERSION="9.4.1"
JDTLS_VERSION="1.58.0"

# Node / TypeScript
NVM_VERSION="v0.40.4"
NODE_VERSION="24.15.0"   # Node.js 24 LTS (Krypton)
TS_VERSION="6.0.2"
TS_NODE_VERSION="10.9.2"
TSX_VERSION="4.21.0"
ESLINT_VERSION="10.2.0"
PRETTIER_VERSION="3.8.3"
NODE_TYPES_VERSION="24.12.2"   # Keep major aligned with NODE_VERSION
NODEMON_VERSION="3.1.14"
PNPM_VERSION="10.33.0"
YARN_VERSION="1.22.22"   # Yarn classic; modern yarn is enabled per-project via corepack
TS_LSP_VERSION="5.1.3"
NCU_VERSION="21.0.1"

# Python + pip packages
PYTHON_VERSION="3.14.4"   # 3.15 is still in alpha
RUFF_VERSION="0.15.10"
MYPY_VERSION="1.20.1"
BLACK_VERSION="26.3.1"
ISORT_VERSION="8.0.1"
PYTEST_VERSION="9.0.3"
HTTPIE_VERSION="3.2.4"
POETRY_VERSION="2.3.4"
PIPENV_VERSION="2026.5.2"
IPYTHON_VERSION="9.12.0"
VIRTUALENV_VERSION="21.2.4"
PYRIGHT_VERSION="1.1.408"
UV_VERSION="0.11.7"
PIPX_VERSION="1.11.1"
PRECOMMIT_VERSION="4.5.1"

# Miniconda
MINICONDA_VERSION="py312_26.1.1-1"

# --- Check root ---
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root: sudo bash secure-vps-setup.sh"
    exit 1
fi

echo ""
echo "========================================="
echo "  Secure VPS Setup for Claude Code"
echo "  Security + tmux + Claude Code"
echo "========================================="
echo ""

# --- Update system ---
print_status "Updating system packages..."
apt update -y && apt upgrade -y

# --- Save pre-existing package list (first run only) ---
MANIFEST_DIR="/var/lib/vps-setup"
mkdir -p "$MANIFEST_DIR"
if [ ! -f "$MANIFEST_DIR/pre-existing-packages.list" ]; then
    dpkg-query -W -f='${Package}\n' | sort > "$MANIFEST_DIR/pre-existing-packages.list"
    print_status "Saved pre-existing package list to $MANIFEST_DIR/pre-existing-packages.list"
fi

# ============================================================
# 0. Create 'dev' user — locked down, no sudo, SSH-key only
# ============================================================
DEV_USER="dev"

if id "$DEV_USER" &>/dev/null; then
    print_status "User '$DEV_USER' already exists"
else
    print_status "Creating user '$DEV_USER' (no sudo, no root access)..."
    adduser --disabled-password --gecos "Claude Code Dev User" "$DEV_USER"
fi

# Ensure no password login — SSH key auth only.
# Locks the password field in /etc/shadow (prefixes with '!'). Idempotent:
# - fresh users from --disabled-password are already locked
# - users left with a random password from older versions of this script
#   (chpasswd) get cleaned up on rerun
passwd -l "$DEV_USER" >/dev/null 2>&1 || true
print_status "Password locked for '$DEV_USER' — SSH key auth only"

# Ensure dev user is NOT in sudo group
deluser "$DEV_USER" sudo 2>/dev/null || true

# Create workspace directory
mkdir -p /home/$DEV_USER/projects
chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/projects

# Copy SSH authorized_keys from root so you can SSH in as dev
if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p /home/$DEV_USER/.ssh
    cp /root/.ssh/authorized_keys /home/$DEV_USER/.ssh/authorized_keys
    chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh
    chmod 700 /home/$DEV_USER/.ssh
    chmod 600 /home/$DEV_USER/.ssh/authorized_keys
    print_status "Copied SSH keys from root → $DEV_USER"
fi

# Generate SSH keypair for dev user (for GitHub, git, etc.)
if [ ! -f /home/$DEV_USER/.ssh/id_ed25519 ]; then
    su - "$DEV_USER" -c 'ssh-keygen -t ed25519 -C "dev@vps" -f ~/.ssh/id_ed25519 -N ""'
    print_status "SSH keypair generated for '$DEV_USER' (ed25519)"
else
    print_status "SSH keypair already exists for '$DEV_USER' — skipping"
fi

# SSH config for dev user (managed by setup script)
mkdir -p /home/$DEV_USER/.ssh
cat > /home/$DEV_USER/.ssh/config << 'SSHCONF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
SSHCONF
chmod 600 /home/$DEV_USER/.ssh/config
chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh
print_status "SSH config written for '$DEV_USER' (includes GitHub)"

# Disable strict host key checking for root (always update)
mkdir -p /root/.ssh
cat > /root/.ssh/config << 'SSHCONF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
SSHCONF
chmod 600 /root/.ssh/config
print_status "SSH host key checking disabled for root"

# Give dev user access to common dev ports (no sudo needed for 1024+)
# Also allow git, curl, wget without sudo
apt install -y git curl wget

# Git defaults — identity set later by: setup-github (pulls from GitHub)
su - "$DEV_USER" -c 'git config --global init.defaultBranch main'
print_status "User '$DEV_USER' created — no sudo, SSH keys copied, workspace ready"

# ============================================================
# 1. ClamAV - Antivirus
# ============================================================
print_status "Installing ClamAV..."
apt install -y clamav clamav-daemon clamav-freshclam

# Stop freshclam temporarily to update definitions manually
systemctl stop clamav-freshclam 2>/dev/null || true
print_status "Updating ClamAV virus definitions (this may take a minute)..."
freshclam || print_warning "freshclam update had warnings — this is usually fine on first run"
systemctl enable clamav-freshclam
systemctl start clamav-freshclam
systemctl enable clamav-daemon
systemctl start clamav-daemon

# Create daily scan cron job
cat > /etc/cron.daily/clamav-scan << 'CRON'
#!/bin/bash
LOG="/var/log/clamav/daily-scan.log"
echo "=== ClamAV Daily Scan: $(date) ===" >> "$LOG"
clamscan -r -i --exclude-dir="^/sys" --exclude-dir="^/proc" --exclude-dir="^/dev" /home /tmp /var/www 2>&1 >> "$LOG"
# Uncomment the next line to get email alerts (requires mailutils)
# tail -20 "$LOG" | mail -s "ClamAV Daily Scan Report" your@email.com
CRON
chmod +x /etc/cron.daily/clamav-scan

# Create scan log directory
mkdir -p /var/log/clamav
print_status "ClamAV installed — daily scans enabled for /home, /tmp, /var/www"

# ============================================================
# 2. rkhunter - Rootkit Scanner
# ============================================================
print_status "Installing rkhunter..."
apt install -y rkhunter

# Update rkhunter database
rkhunter --update || print_warning "rkhunter update had warnings — usually fine"
rkhunter --propupd

# Configure rkhunter for automatic weekly scans
cat > /etc/cron.weekly/rkhunter-scan << 'CRON'
#!/bin/bash
LOG="/var/log/rkhunter-weekly.log"
echo "=== rkhunter Weekly Scan: $(date) ===" >> "$LOG"
rkhunter --check --skip-keypress --report-warnings-only 2>&1 >> "$LOG"
CRON
chmod +x /etc/cron.weekly/rkhunter-scan

print_status "rkhunter installed — weekly scans enabled"

# ============================================================
# 3. UFW - Firewall
# ============================================================
print_status "Configuring UFW firewall..."
apt install -y ufw

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (important! don't lock yourself out)
ufw allow 22/tcp comment 'SSH'

# Allow HTTP/HTTPS (uncomment if you run a web server)
# ufw allow 80/tcp comment 'HTTP'
# ufw allow 443/tcp comment 'HTTPS'

# Enable firewall
echo "y" | ufw enable
ufw status verbose

print_status "UFW enabled — SSH (port 22) allowed, all other incoming blocked"
print_warning "If you need other ports (80, 443, etc.), run: sudo ufw allow <port>/tcp"

# ============================================================
# 4. fail2ban - Brute Force Protection
# ============================================================
print_status "Installing fail2ban..."
apt install -y fail2ban

# Create local config (overrides without touching defaults)
cat > /etc/fail2ban/jail.local << 'JAIL'
[DEFAULT]
# Ban for 1 hour after 5 failed attempts within 10 minutes
bantime  = 3600
findtime = 600
maxretry = 5
# Use systemd backend
backend = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 3
bantime  = 3600
JAIL

systemctl enable fail2ban
systemctl restart fail2ban

print_status "fail2ban installed — bans IPs after 3 failed SSH attempts for 1 hour"
# ============================================================
# 6. tmux - Session Persistence (optimized for Termius mobile)
# ============================================================
print_status "Installing tmux..."
apt install -y tmux

# Create tmux config for dev user (mobile-optimized)
cat > /home/$DEV_USER/.tmux.conf << 'TMUX'
# ─────────────────────────────────────────────────────────
# tmux config — optimized for Termius (iOS/Windows) + Claude Code
# ─────────────────────────────────────────────────────────

# ── Basics ──────────────────────────────────────────────
# Faster key response (crucial for mobile latency)
set -s escape-time 1

# 256 color support
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",*256col*:Tc"

# Set Termius tab title to session name
set -g set-titles on
set -g set-titles-string "#S - #(whoami)"

# Direct OSC title escape via hooks (bypasses broken client_termtype detection)
set-hook -g client-attached 'run-shell "printf \"\\033]0;#{session_name} - \$(whoami)\\007\" > #{client_tty}"'
set-hook -g client-session-changed 'run-shell "printf \"\\033]0;#{session_name} - \$(whoami)\\007\" > #{client_tty}"'
set-hook -g session-renamed 'run-shell "printf \"\\033]0;#{session_name} - \$(whoami)\\007\" > #{client_tty}"'

# Massive scrollback (Claude Code outputs a LOT)
set -g history-limit 50000

# Start numbering at 1 (0 is far away on mobile keyboard)
set -g base-index 1
setw -g pane-base-index 1

# Renumber windows when one is closed
set -g renumber-windows on

# ── Mouse Support (critical for Termius touch) ─────────
set -g mouse on

# Better mouse scrolling — scroll the terminal, not command history
bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
bind -n WheelDownPane select-pane -t= \; send-keys -M

# ── Prefix Key ─────────────────────────────────────────
# Keep Ctrl+b as prefix (Termius handles it well)
# Double-tap Ctrl+b sends literal Ctrl+b to shell
bind C-b send-prefix

# ── Window & Pane Management ──────────────────────────
# Split panes with | and - (easier to remember on mobile)
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# New windows open in current directory
bind c new-window -c "#{pane_current_path}"

# Switch panes with Alt+arrow (no prefix needed — great for mobile)
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# Switch windows with Shift+arrow (no prefix needed)
bind -n S-Left previous-window
bind -n S-Right next-window

# Resize panes with Ctrl+arrow (no prefix needed)
bind -n C-Left resize-pane -L 2
bind -n C-Right resize-pane -R 2
bind -n C-Up resize-pane -U 2
bind -n C-Down resize-pane -D 2

# Quick reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded!"

# ── Status Bar (clean, visible on small screens) ──────
set -g status-position bottom
set -g status-interval 5

# Colors — dark theme, high contrast for mobile
set -g status-style "fg=#a0a0a0,bg=#1a1a2e"

# Left: session name
set -g status-left-length 20
set -g status-left "#[fg=#16213e,bg=#0f3460,bold] #S #[fg=#0f3460,bg=#1a1a2e]"

# Right: time + hostname (useful when managing multiple VPS)
set -g status-right-length 40
set -g status-right "#[fg=#a0a0a0] %H:%M #[fg=#16213e,bg=#0f3460,bold] #H "

# Window tabs
setw -g window-status-format " #I:#W "
setw -g window-status-current-format "#[fg=#1a1a2e,bg=#e94560,bold] #I:#W "

# Pane borders
set -g pane-border-style "fg=#333333"
set -g pane-active-border-style "fg=#e94560"

# ── Copy Mode (for scrolling through Claude Code output) ─
setw -g mode-keys vi

# ── Activity Alerts ───────────────────────────────────
setw -g monitor-activity on
set -g visual-activity off

# ── Auto-attach / Detach behavior ─────────────────────
# Don't destroy session when last client detaches
set -g destroy-unattached off

# Aggressive resize — better for switching between
# desktop (wide) and phone (narrow)
setw -g aggressive-resize on
TMUX

chown $DEV_USER:$DEV_USER /home/$DEV_USER/.tmux.conf

# ── setup-github: interactive GitHub + SSH signing setup ─
mkdir -p /home/$DEV_USER/.local/bin
cat > /home/$DEV_USER/.local/bin/setup-github << 'SETUPGH'
#!/bin/bash
# ─────────────────────────────────────────────────────────
# setup-github — Interactive GitHub + SSH signing setup
#
# Uses the same ed25519 SSH key for both authentication and
# commit signing. GitHub accepts SSH-signed commits natively
# (no GPG required).
#
# Run once after VPS provisioning. Safe to rerun.
# ─────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

echo ""
echo -e "${BOLD}GitHub + SSH Signing Setup${NC}"
echo "─────────────────────────────────────────"
echo ""

# ── Step 1: GitHub CLI authentication ─────────────────────
echo -e "${BOLD}Step 1: GitHub Authentication${NC}"

if gh auth status &>/dev/null; then
    GH_USER=$(gh api user --jq .login 2>/dev/null)
    ok "Already authenticated as ${BOLD}$GH_USER${NC}"
else
    info "Logging in to GitHub..."
    echo -e "${DIM}A browser URL will be shown — open it on any device to authenticate.${NC}"
    echo ""
    # Request admin:public_key + admin:ssh_signing_key so we can upload both key types
    if ! gh auth login --git-protocol ssh --web \
            --scopes 'admin:public_key,admin:ssh_signing_key'; then
        err "GitHub login failed. Run 'setup-github' again to retry."
        exit 1
    fi
    GH_USER=$(gh api user --jq .login 2>/dev/null)
    ok "Authenticated as ${BOLD}$GH_USER${NC}"
fi

# Ensure we have the signing-key scope even if the user was already logged in
if ! gh auth status 2>&1 | grep -q 'admin:ssh_signing_key'; then
    info "Requesting admin:ssh_signing_key scope for commit signing..."
    gh auth refresh -h github.com -s admin:ssh_signing_key || \
        warn "Could not add signing-key scope — signing-key upload may fail"
fi
echo ""

# ── Step 2: Git identity ──────────────────────────────────
echo -e "${BOLD}Step 2: Git Identity${NC}"

CURRENT_NAME=$(git config --global user.name 2>/dev/null)
CURRENT_EMAIL=$(git config --global user.email 2>/dev/null)

# Fetch name from GitHub as default if current is placeholder
GH_NAME=$(gh api user --jq .name 2>/dev/null)
GH_EMAIL=$(gh api user --jq .email 2>/dev/null)

if [ "$CURRENT_NAME" = "dev" ] || [ -z "$CURRENT_NAME" ]; then
    DEFAULT_NAME="${GH_NAME:-}"
else
    DEFAULT_NAME="$CURRENT_NAME"
fi

if [ "$CURRENT_EMAIL" = "dev@vps.local" ] || [ -z "$CURRENT_EMAIL" ]; then
    DEFAULT_EMAIL="${GH_EMAIL:-}"
else
    DEFAULT_EMAIL="$CURRENT_EMAIL"
fi

read -rp "$(echo -e "${CYAN}Name${NC}  [${DEFAULT_NAME}]: ")" INPUT_NAME
INPUT_NAME="${INPUT_NAME:-$DEFAULT_NAME}"

read -rp "$(echo -e "${CYAN}Email${NC} [${DEFAULT_EMAIL}]: ")" INPUT_EMAIL
INPUT_EMAIL="${INPUT_EMAIL:-$DEFAULT_EMAIL}"

if [ -z "$INPUT_NAME" ] || [ -z "$INPUT_EMAIL" ]; then
    err "Name and email are required."
    exit 1
fi

git config --global user.name "$INPUT_NAME"
git config --global user.email "$INPUT_EMAIL"
ok "Git identity: $INPUT_NAME <$INPUT_EMAIL>"
echo ""

# ── Step 3: SSH key exists ────────────────────────────────
echo -e "${BOLD}Step 3: SSH Key${NC}"

SSH_PUB="$HOME/.ssh/id_ed25519.pub"
if [ ! -f "$SSH_PUB" ]; then
    err "No SSH public key found at $SSH_PUB"
    err "This should have been created by the VPS setup script."
    exit 1
fi

KEY_TITLE="VPS ($(hostname))"
LOCAL_FP=$(ssh-keygen -lf "$SSH_PUB" 2>/dev/null | awk '{print $2}')
ok "Local key: $LOCAL_FP"

# ── Step 4: Upload as AUTHENTICATION key ──────────────────
if gh ssh-key list 2>/dev/null | grep -q "$LOCAL_FP"; then
    ok "Auth key already on GitHub"
else
    info "Uploading SSH auth key to GitHub..."
    if gh ssh-key add "$SSH_PUB" --title "$KEY_TITLE"; then
        ok "Auth key uploaded: $KEY_TITLE"
    else
        err "Failed to upload auth key. Manually:"
        echo "  gh ssh-key add $SSH_PUB --title \"$KEY_TITLE\""
    fi
fi

# ── Step 5: Upload as SIGNING key (same key, separate entry) ──
if gh ssh-key list --type signing 2>/dev/null | grep -q "$LOCAL_FP"; then
    ok "Signing key already on GitHub"
else
    info "Uploading SSH signing key to GitHub..."
    if gh ssh-key add "$SSH_PUB" --title "$KEY_TITLE (signing)" --type signing; then
        ok "Signing key uploaded: $KEY_TITLE (signing)"
    else
        err "Failed to upload signing key. Manually:"
        echo "  gh ssh-key add $SSH_PUB --title \"$KEY_TITLE (signing)\" --type signing"
    fi
fi
echo ""

# ── Step 6: Configure git for SSH signing ─────────────────
echo -e "${BOLD}Step 4: Git SSH Signing Config${NC}"

# Drop any stale GPG-based signing config from previous installs
git config --global --unset-all gpg.program 2>/dev/null || true

git config --global gpg.format ssh
git config --global user.signingkey "$SSH_PUB"
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# Allowed signers file lets `git log --show-signature` verify local commits
ALLOWED_SIGNERS="$HOME/.ssh/allowed_signers"
PUBKEY_CONTENT=$(cat "$SSH_PUB")
touch "$ALLOWED_SIGNERS"
chmod 600 "$ALLOWED_SIGNERS"
# Remove any prior entry for this email, then append fresh
grep -v "^$INPUT_EMAIL " "$ALLOWED_SIGNERS" > "$ALLOWED_SIGNERS.tmp" 2>/dev/null || true
mv "$ALLOWED_SIGNERS.tmp" "$ALLOWED_SIGNERS" 2>/dev/null || true
echo "$INPUT_EMAIL $PUBKEY_CONTENT" >> "$ALLOWED_SIGNERS"
git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS"

ok "Git configured: sign commits & tags with SSH key"
ok "Allowed signers: $ALLOWED_SIGNERS"
echo ""

# ── Verify ────────────────────────────────────────────────
echo -e "${BOLD}Summary${NC}"
echo "─────────────────────────────────────────"
echo -e "  GitHub user : ${GREEN}$GH_USER${NC}"
echo -e "  Git name    : $INPUT_NAME"
echo -e "  Git email   : $INPUT_EMAIL"
echo -e "  SSH key     : $LOCAL_FP"
echo -e "  Signing     : ${GREEN}SSH${NC} (same key, uploaded as signing on GitHub)"
echo ""

info "Testing SSH connection to GitHub..."
ssh -T git@github.com 2>&1 | head -3
echo ""
ok "Setup complete!"
echo ""
SETUPGH
chmod +x /home/$DEV_USER/.local/bin/setup-github

# --- Legacy bashrc migration (one-time: strip old single-marker format) ---
_migrate_legacy_bashrc() {
    local file="/home/$DEV_USER/.bashrc"
    [ -f "$file" ] || return 0
    if grep -q '^# --- Claude Code VPS additions ---$' "$file" && \
       ! grep -q '^# --- Claude Code VPS additions START ---$' "$file"; then
        sed -i '/^# --- Claude Code VPS additions ---$/,$d' "$file"
        print_status "Migrated legacy .bashrc format (old markers removed)"
    fi
}
_migrate_legacy_bashrc

# Add .local/bin to dev user's PATH (delete-then-append for upgrades)
sed -i '/# --- Claude Code VPS additions START ---/,/# --- Claude Code VPS additions END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << 'BASHRC'

# --- Claude Code VPS additions START ---
export PATH="$HOME/.local/bin:$PATH"
# --- Claude Code VPS additions END ---
BASHRC

# ssh-agent auto-start (persists across tmux panes) — delete-then-append
sed -i '/# --- SSH Agent START ---/,/# --- SSH Agent END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << 'SSHAGENT'

# --- SSH Agent START ---
SSH_ENV="$HOME/.ssh/agent-env"
_start_ssh_agent() {
    eval "$(ssh-agent -s)" > /dev/null
    mkdir -p ~/.ssh
    echo "export SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > "$SSH_ENV"
    echo "export SSH_AGENT_PID=$SSH_AGENT_PID" >> "$SSH_ENV"
    chmod 600 "$SSH_ENV"
    ssh-add ~/.ssh/id_ed25519 2>/dev/null
}
if [ -z "$SSH_AUTH_SOCK" ] || ! ssh-add -l &>/dev/null; then
    if [ -f "$SSH_ENV" ]; then
        . "$SSH_ENV" > /dev/null
        if ! ssh-add -l &>/dev/null; then
            _start_ssh_agent
        fi
    else
        _start_ssh_agent
    fi
fi
# --- SSH Agent END ---
SSHAGENT

# Commit signing is done by SSH (git gpg.format ssh), configured by setup-github.
# Clean up any GPG-agent plumbing left behind by previous installs.
sed -i '/# --- GPG Agent START ---/,/# --- GPG Agent END ---/d' /home/$DEV_USER/.bashrc

chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.local
chown $DEV_USER:$DEV_USER /home/$DEV_USER/.bashrc

print_status "tmux installed — mobile-optimized"

# ============================================================
# 7. Dev Toolchains — Go, Java, TypeScript, Python
# ============================================================
print_status "Installing development toolchains..."

# ── System-level build essentials ───────────────────────
apt install -y build-essential pkg-config libssl-dev \
    unzip zip jq tree htop ripgrep fd-find bat \
    software-properties-common apt-transport-https ca-certificates

# Symlink fd and bat (Ubuntu names them differently)
ln -sf /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true

# ── Go (pinned tarball from go.dev) ─────────────────────
print_status "Installing Go ${GO_VERSION}..."
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz

# Go env for dev user (delete-then-append for upgrades)
sed -i '/# --- Go START ---/,/# --- Go END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << 'GOENV'

# --- Go START ---
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
export GOPATH="$HOME/go"
# --- Go END ---
GOENV

# Install Go tools as dev user (pinned; `go install pkg@VERSION` replaces
# any existing binary in $GOPATH/bin on rerun)
su - "$DEV_USER" -c "export PATH=/usr/local/go/bin:\$HOME/go/bin:\$PATH && export GOPATH=\$HOME/go && \
    go install golang.org/x/tools/gopls@${GOPLS_VERSION} && \
    go install github.com/go-delve/delve/cmd/dlv@${DELVE_VERSION} && \
    go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION} && \
    go install github.com/air-verse/air@${AIR_VERSION} && \
    go install golang.org/x/tools/cmd/goimports@${GOIMPORTS_VERSION} && \
    go install golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION} && \
    go install github.com/RandomCodeSpace/ctm@${CTM_VERSION}"

print_status "Go ${GO_VERSION} + gopls, delve, golangci-lint, air, goimports, govulncheck, ctm ${CTM_VERSION} installed"
print_warning "Run 'ctm install' as the dev user to finish ctm shell integration (one-time, interactive)"

# ── Java (Eclipse Temurin via Adoptium, pinned meta-package) ──
print_status "Installing Java (${TEMURIN_PKG})..."
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/adoptium.list
apt update -y
apt install -y "$TEMURIN_PKG"

# Install Maven (apt handles version) and pinned Gradle
apt install -y maven
curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip
# Clean up old Gradle versions before extracting new
find /opt -maxdepth 1 -name 'gradle-*' -type d \
    -not -name "gradle-${GRADLE_VERSION}" -exec rm -rf {} + 2>/dev/null || true
unzip -qo /tmp/gradle.zip -d /opt
ln -sf "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle
rm /tmp/gradle.zip

# Install jdtls (Eclipse JDT Language Server) — pinned milestone
print_status "Installing jdtls ${JDTLS_VERSION}..."
JDTLS_INSTALL_DIR="/opt/jdtls"
JDTLS_URL_BASE="https://download.eclipse.org/jdtls/milestones/${JDTLS_VERSION}"
# The milestone version dir contains a latest.txt pointing at the exact
# tarball filename (which includes a build timestamp). We pin the version
# but follow latest.txt within that version dir for the file to download.
JDTLS_FILENAME=$(curl -fsSL "${JDTLS_URL_BASE}/latest.txt" 2>/dev/null)
if [ -n "$JDTLS_FILENAME" ]; then
    curl -fsSL "${JDTLS_URL_BASE}/${JDTLS_FILENAME}" -o /tmp/jdtls.tar.gz
    rm -rf "$JDTLS_INSTALL_DIR"
    mkdir -p "$JDTLS_INSTALL_DIR"
    tar -xzf /tmp/jdtls.tar.gz -C "$JDTLS_INSTALL_DIR"
    rm /tmp/jdtls.tar.gz
    cat > /usr/local/bin/jdtls << 'JDTLS_LAUNCHER'
#!/bin/bash
exec /opt/jdtls/bin/jdtls "$@"
JDTLS_LAUNCHER
    chmod +x /usr/local/bin/jdtls
    print_status "jdtls ${JDTLS_VERSION} installed to ${JDTLS_INSTALL_DIR}"
else
    print_warning "Could not fetch jdtls ${JDTLS_VERSION}/latest.txt — skipping"
fi

JAVA_HOME_PATH="/usr/lib/jvm/${TEMURIN_PKG}-amd64"
sed -i '/# --- Java START ---/,/# --- Java END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << JAVAENV

# --- Java START ---
export JAVA_HOME="${JAVA_HOME_PATH}"
export PATH="\$JAVA_HOME/bin:\$PATH"
# --- Java END ---
JAVAENV

print_status "Java (${TEMURIN_PKG}) + Maven + Gradle ${GRADLE_VERSION} + jdtls ${JDTLS_VERSION} installed"

# ── Node.js + TypeScript (via nvm for dev user) ────────
print_status "Installing Node.js ${NODE_VERSION} + TypeScript ${TS_VERSION}..."

# Install/update nvm for dev user (installer clones to the pinned tag)
su - "$DEV_USER" -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"

# Install pinned Node + pinned global packages. npm install -g pkg@VERSION
# replaces any previously-installed version, so this is safe to rerun.
su - "$DEV_USER" -c "export NVM_DIR=\$HOME/.nvm && \
    [ -s \$NVM_DIR/nvm.sh ] && . \$NVM_DIR/nvm.sh && \
    nvm install ${NODE_VERSION} && \
    nvm alias default ${NODE_VERSION} && \
    nvm use default && \
    npm install -g \
        typescript@${TS_VERSION} \
        ts-node@${TS_NODE_VERSION} \
        tsx@${TSX_VERSION} \
        eslint@${ESLINT_VERSION} \
        prettier@${PRETTIER_VERSION} \
        @types/node@${NODE_TYPES_VERSION} \
        nodemon@${NODEMON_VERSION} \
        pnpm@${PNPM_VERSION} \
        yarn@${YARN_VERSION} \
        typescript-language-server@${TS_LSP_VERSION} \
        npm-check-updates@${NCU_VERSION}"

print_status "Node.js ${NODE_VERSION} + TS ${TS_VERSION} + pnpm ${PNPM_VERSION} + yarn ${YARN_VERSION} + ts-language-server ${TS_LSP_VERSION} + ncu ${NCU_VERSION} installed"

# ── Python (system + pyenv for version management) ─────
print_status "Installing Python toolchain..."

# Python build dependencies
apt install -y python3 python3-pip python3-venv python3-dev \
    libffi-dev libbz2-dev libreadline-dev libsqlite3-dev \
    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
    liblzma-dev zlib1g-dev

# Install or update pyenv for dev user
if [ -d "/home/$DEV_USER/.pyenv" ]; then
    su - "$DEV_USER" -c 'export PYENV_ROOT="$HOME/.pyenv" && export PATH="$PYENV_ROOT/bin:$PATH" && pyenv update' || true
else
    su - "$DEV_USER" -c 'curl -fsSL https://pyenv.run | bash'
fi

sed -i '/# --- Python START ---/,/# --- Python END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << 'PYENV'

# --- Python START ---
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv &>/dev/null; then
    eval "$(pyenv init -)"
fi
# --- Python END ---
PYENV

# Install pinned Python via pyenv + pinned pip packages.
# - `pyenv install -s` skips if the exact patch is already built; bumping
#   PYTHON_VERSION causes a fresh build on rerun.
# - `pip install --upgrade pkg==VERSION` forces the pinned version even if
#   a different one is already present.
su - "$DEV_USER" -c "export PYENV_ROOT=\$HOME/.pyenv && \
    export PATH=\$PYENV_ROOT/bin:\$PATH && \
    eval \"\$(pyenv init -)\" && \
    pyenv install -s ${PYTHON_VERSION} && \
    pyenv global ${PYTHON_VERSION} && \
    pip install --upgrade pip && \
    pip install --upgrade \
        ruff==${RUFF_VERSION} \
        mypy==${MYPY_VERSION} \
        black==${BLACK_VERSION} \
        isort==${ISORT_VERSION} \
        pytest==${PYTEST_VERSION} \
        httpie==${HTTPIE_VERSION} \
        poetry==${POETRY_VERSION} \
        pipenv==${PIPENV_VERSION} \
        ipython==${IPYTHON_VERSION} \
        virtualenv==${VIRTUALENV_VERSION} \
        pyright==${PYRIGHT_VERSION} \
        uv==${UV_VERSION} \
        pipx==${PIPX_VERSION} \
        pre-commit==${PRECOMMIT_VERSION}"

print_status "Python ${PYTHON_VERSION} + ruff ${RUFF_VERSION}, mypy ${MYPY_VERSION}, pytest ${PYTEST_VERSION}, poetry ${POETRY_VERSION}, pyright ${PYRIGHT_VERSION}, uv ${UV_VERSION}, pipx ${PIPX_VERSION}, pre-commit ${PRECOMMIT_VERSION} installed (via pyenv)"

# ── Miniconda (system-wide at /opt/miniconda3, pinned installer) ──
print_status "Installing Miniconda ${MINICONDA_VERSION} (system-wide)..."
MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-${MINICONDA_VERSION}-Linux-x86_64.sh"
curl -fsSL "$MINICONDA_URL" -o /tmp/miniconda.sh
# -b batch, -u update (replaces existing install at the prefix)
bash /tmp/miniconda.sh -b -u -p /opt/miniconda3
rm /tmp/miniconda.sh

# Make conda available to all users
ln -sf /opt/miniconda3/bin/conda /usr/local/bin/conda

# Clean existing conda init block before re-adding (safe for rerun)
sed -i '/# >>> conda initialize >>>/,/# <<< conda initialize <<</d' /home/$DEV_USER/.bashrc 2>/dev/null || true

# Initialize conda for dev user (adds shell hook to .bashrc)
su - "$DEV_USER" -c '/opt/miniconda3/bin/conda init bash'

# Disable auto-activate base — user must explicitly activate envs
su - "$DEV_USER" -c '/opt/miniconda3/bin/conda config --set auto_activate_base false'

print_status "Miniconda installed at /opt/miniconda3 (auto_activate_base=false)"

# ── Common CLI tools for Claude Code ────────────────────
# These help Claude Code work more effectively
apt install -y \
    shellcheck \
    make \
    cmake \
    sqlite3 \
    redis-tools \
    postgresql-client \
    inotify-tools

# ── GitHub CLI (gh) — always add repo + install/upgrade ──
print_status "Installing/updating GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
apt update -y
apt install -y gh
print_status "GitHub CLI (gh) installed"

# Fix ownership of everything in dev home
chown -R $DEV_USER:$DEV_USER /home/$DEV_USER

print_status "All dev toolchains installed"

# --- Write package manifest ---
CURRENT_PKGS=$(mktemp)
dpkg-query -W -f='${Package}\n' | sort > "$CURRENT_PKGS"
comm -13 "$MANIFEST_DIR/pre-existing-packages.list" "$CURRENT_PKGS" > "$MANIFEST_DIR/installed-packages.manifest"
rm -f "$CURRENT_PKGS"

# Save metadata
cat > "$MANIFEST_DIR/manifest-meta.txt" << METAMANIFEST
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
USER=$DEV_USER
GO_VERSION=${GO_VERSION}
GOPLS_VERSION=${GOPLS_VERSION}
DELVE_VERSION=${DELVE_VERSION}
GOLANGCI_LINT_VERSION=${GOLANGCI_LINT_VERSION}
AIR_VERSION=${AIR_VERSION}
GOIMPORTS_VERSION=${GOIMPORTS_VERSION}
GOVULNCHECK_VERSION=${GOVULNCHECK_VERSION}
CTM_VERSION=${CTM_VERSION}
TEMURIN_PKG=${TEMURIN_PKG}
GRADLE_VERSION=${GRADLE_VERSION}
JDTLS_VERSION=${JDTLS_VERSION}
NVM_VERSION=${NVM_VERSION}
NODE_VERSION=${NODE_VERSION}
TS_VERSION=${TS_VERSION}
PNPM_VERSION=${PNPM_VERSION}
YARN_VERSION=${YARN_VERSION}
NCU_VERSION=${NCU_VERSION}
PYTHON_VERSION=${PYTHON_VERSION}
RUFF_VERSION=${RUFF_VERSION}
MYPY_VERSION=${MYPY_VERSION}
POETRY_VERSION=${POETRY_VERSION}
PYRIGHT_VERSION=${PYRIGHT_VERSION}
UV_VERSION=${UV_VERSION}
PIPX_VERSION=${PIPX_VERSION}
PRECOMMIT_VERSION=${PRECOMMIT_VERSION}
MINICONDA_VERSION=${MINICONDA_VERSION}
METAMANIFEST
print_status "Package manifest written to $MANIFEST_DIR/"

# ============================================================
# 8. Claude Code - AI Coding Assistant (installed for 'dev')
# ============================================================
print_status "Installing Claude Code for user '$DEV_USER'..."
su - "$DEV_USER" -c 'curl -fsSL https://claude.ai/install.sh | bash'

# Set dev user's default shell to bash (ensures Claude Code works)
chsh -s /bin/bash "$DEV_USER"

print_status "Claude Code installed for '$DEV_USER'"

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================="
echo "  Setup Complete!"
echo "========================================="
echo ""
echo "  SECURITY"
echo "  ─────────────────────────────────────────"
echo "  ClamAV     : Active — daily scans at midnight"
echo "  rkhunter   : Active — weekly scans"
echo "  UFW        : Active — only SSH (22) open"
echo "  fail2ban   : Active — SSH brute-force protection"
echo ""
echo "  USER: dev"
echo "  ─────────────────────────────────────────"
echo "  Home       : /home/dev"
echo "  Workspace  : /home/dev/projects"
echo "  Sudo       : DISABLED (locked down)"
echo "  Shell      : /bin/bash"
echo ""
echo "  DEV TOOLCHAINS (all pinned — bump in VERSIONS block to upgrade)"
echo "  ─────────────────────────────────────────"
echo "  Go         : ${GO_VERSION}  (gopls, dlv, golangci-lint, air, goimports, govulncheck, ctm ${CTM_VERSION})"
echo "  Java       : ${TEMURIN_PKG}  (maven, gradle ${GRADLE_VERSION}, jdtls ${JDTLS_VERSION})"
echo "  Node.js    : ${NODE_VERSION}  (ts ${TS_VERSION}, tsx, pnpm ${PNPM_VERSION}, yarn, ts-language-server, ncu)"
echo "  Python     : ${PYTHON_VERSION}  (ruff ${RUFF_VERSION}, mypy, pytest, poetry, pyright, uv ${UV_VERSION}, pipx, pre-commit)"
echo "  Miniconda  : ${MINICONDA_VERSION}  (/opt/miniconda3, auto_activate_base=false)"
echo "  Extras     : ripgrep, fd, bat, jq, htop, shellcheck"
echo "  DEV TOOLS"
echo "  ─────────────────────────────────────────"
echo "  tmux         : Mobile-optimized"
echo "  Claude Code  : Installed for dev user (run 'claude' to start)"
echo ""
echo "  tmux SHORTCUTS:"
echo "  ─────────────────────────────────────────"
echo "  Split horizontal  : Prefix + |"
echo "  Split vertical    : Prefix + -"
echo "  Switch panes      : Alt + arrow keys"
echo "  Switch windows    : Shift + arrow keys"
echo "  Resize panes      : Ctrl + arrow keys"
echo "  Session picker    : Prefix + s"
echo "  Detach session    : Prefix + d"
echo "  Scroll up/down    : Touch scroll (mouse on)"
echo "  (Prefix = Ctrl+b)"
echo ""
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NEXT STEPS (run these manually):"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  1. Switch to dev user:"
echo "     su - dev"
echo ""
echo "  2. Start tmux and launch Claude Code:"
echo "     tmux new -s claude"
echo "     claude"
echo ""
echo "  3. First time only - authenticate Claude Code:"
echo "     (follow browser prompts)"
echo ""
echo "  4. Set up GitHub + SSH signing:"
echo "     setup-github"
echo "     (GitHub auth → git identity → SSH key → SSH commit signing)"
echo ""
echo "  5. Finish ctm (Claude Tmux Manager) shell integration:"
echo "     ctm install"
echo ""
echo "  Your SSH public key:"
echo "     cat ~/.ssh/id_ed25519.pub"
echo ""
echo "  Useful commands:"
echo "  ─────────────────────────────────────────"
echo "  Manual virus scan  : sudo clamscan -r -i /path"
echo "  Rootkit check      : sudo rkhunter --check"
echo "  Firewall status    : sudo ufw status"
echo "  Open a port        : sudo ufw allow <port>/tcp"
echo "  Banned IPs         : sudo fail2ban-client status sshd"
echo "  Unban an IP        : sudo fail2ban-client set sshd unbanip <IP>"
echo ""
echo "  Language tools:"
echo "  ─────────────────────────────────────────"
echo "  Go version         : go version"
echo "  Java version       : java -version"
echo "  Node version       : node -v"
echo "  Python version     : python --version"
echo "  Switch Python      : pyenv install 3.13 && pyenv global 3.13"
echo "  Switch Node        : nvm install 22 && nvm alias default 22"
echo "  New Go project     : mkdir app && cd app && go mod init app"
echo "  New TS project     : mkdir app && cd app && pnpm init"
echo "  New Python project : mkdir app && cd app && poetry init"
echo "  Conda envs         : conda create -n myenv python=3.12"
echo "  Activate env       : conda activate myenv"
echo ""
echo "  Scan logs          : /var/log/clamav/daily-scan.log"
echo "  rkhunter logs      : /var/log/rkhunter-weekly.log"
echo ""
print_warning "SECURITY TIP: Once you confirm 'ssh dev@<vps-ip>' works,"
print_warning "disable root SSH login (run this as root BEFORE logging out):"
echo "  sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config"
echo "  systemctl restart sshd"
echo ""
