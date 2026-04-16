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

# ── Unattended execution ─────────────────────────────────
# Keep apt and dpkg fully non-interactive. DEBIAN_FRONTEND alone isn't
# enough on 24.04 — needrestart prompts "Which services to restart?"
# during upgrades. Configure it to auto-restart everything.
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
if [ -d /etc/needrestart ]; then
    mkdir -p /etc/needrestart/conf.d
    cat > /etc/needrestart/conf.d/99-vps-setup.conf <<'NRCONF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
NRCONF
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }

# ── Apt wrappers ─────────────────────────────────────────
# `apt update` can race against Ubuntu mirror syncs and fail with
# "File has unexpected size (X != Y). Mirror sync in progress?".
# Retry with exponential backoff; clear the partial lists between
# attempts so the next try starts clean. Bail out loudly if it keeps
# failing — that's a real network issue, not a transient mirror race.
apt_update_retry() {
    local attempt=1
    local max=4
    while true; do
        if apt-get update -y; then
            return 0
        fi
        if [ "$attempt" -ge "$max" ]; then
            print_error "apt update failed after $max attempts"
            return 1
        fi
        local wait=$((attempt * 15))
        print_warning "apt update attempt $attempt/$max failed — retrying in ${wait}s (probably a mirror sync)"
        rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true
        sleep "$wait"
        attempt=$((attempt + 1))
    done
}

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
BUN_VERSION="bun-v1.3.12"   # Passed to bun.sh/install as the pin

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

# rtk (Rust Token Killer) — CLI output compressor, installed from upstream .deb
RTK_VERSION="v0.36.0"

# .NET + PowerShell (Microsoft apt repo handles point-level updates)
DOTNET_LTS_VERSION="10.0"   # Even majors are LTS per Microsoft's policy
PWSH_NOTE="7.6.x"           # apt 'powershell' package tracks Microsoft's latest 7.x

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
apt_update_retry && apt upgrade -y

# ============================================================
# Register all third-party apt repos up front so one apt update
# covers them all. Without this, each install section would trigger
# its own apt update (Adoptium, GitHub CLI, Microsoft, Caddy) —
# that's 4 extra mirror round-trips for no benefit.
# ============================================================
print_status "Registering third-party apt repos (Adoptium, GitHub CLI, Microsoft, Caddy)..."

# Prereqs for registering + verifying third-party repos
apt install -y curl gnupg ca-certificates apt-transport-https \
    debian-keyring debian-archive-keyring

# Adoptium (Temurin JDK) — provides temurin-<N>-jdk packages
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/adoptium.list

# GitHub CLI — provides `gh`
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list

# Microsoft — provides powershell (the packages-microsoft-prod.deb
# writes /etc/apt/sources.list.d/microsoft-prod.list itself)
UBUNTU_VER_ID=$(. /etc/os-release && echo "$VERSION_ID")
curl -fsSL "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VER_ID}/packages-microsoft-prod.deb" \
    -o /tmp/packages-microsoft-prod.deb
apt install -y /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb

# Caddy (Cloudsmith stable) — provides caddy
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list

# One update for all four repos
apt_update_retry

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

# Allow mosh (UDP 60000-61000, one port per concurrent session)
ufw allow 60000:61000/udp comment 'mosh'

# Allow HTTP/HTTPS — needed by Caddy (installed later in this script)
# to serve sites and to solve ACME HTTP-01 challenges for auto-TLS.
ufw allow 80/tcp comment 'HTTP (Caddy)'
ufw allow 443/tcp comment 'HTTPS (Caddy)'

# Enable firewall (--force skips the interactive "may disrupt existing
# ssh connections" confirmation; safe because SSH + mosh rules are
# already above this line)
ufw --force enable
ufw status verbose

print_status "UFW enabled — SSH (22), mosh (60000-61000/udp), HTTP (80), HTTPS (443) allowed"
print_warning "If you need other ports, run: sudo ufw allow <port>/tcp"

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
# 5. mosh - Mobile shell (survives roaming / flaky connections)
# ============================================================
# Mosh initiates over SSH (existing key auth — no extra credentials) and
# then switches to UDP on a port in the 60000-61000 range that UFW
# opened above. Client connects with: mosh dev@<vps-ip>
print_status "Installing mosh..."
apt install -y mosh
# Best-effort ensure UTF-8 locale (mosh refuses to start without it)
if ! locale -a 2>/dev/null | grep -qiE '^(C\.UTF-8|en_US\.utf-?8)$'; then
    apt install -y locales
    locale-gen en_US.UTF-8 2>/dev/null || true
    update-locale LANG=en_US.UTF-8 2>/dev/null || true
fi
print_status "mosh installed — connect with: mosh ${DEV_USER}@<vps-ip>"

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

# ── System-level build essentials + productivity tools ──
# Productivity adds (all help Claude Code sessions run faster / cheaper):
#   fzf       — fuzzy finder, Ctrl-R history, cuts exploration turns
#   yq        — YAML query, companion to jq, saves tokens vs grep-parsing
#   git-delta — paginated/colored git diff output (binary: `delta`)
#   zoxide    — `z <partial>` directory jump, cuts `cd long/path/…` tokens
#   direnv    — per-dir env vars, no repeated export boilerplate
#   tldr      — simplified man pages (huge token saver vs `man foo`)
#   entr      — re-run a command on file change (test-loop workflow)
apt install -y build-essential pkg-config libssl-dev \
    unzip zip jq tree htop ripgrep fd-find bat \
    fzf yq git-delta zoxide direnv tldr entr \
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
# Adoptium apt repo was registered up top; here we just install.
print_status "Installing Java (${TEMURIN_PKG})..."
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

# ── Bun (alt JS runtime + package manager, installs to ~/.bun) ──
# bun's installer is idempotent — grep-guarded writes to .bashrc — so
# rerunning with the same pinned version is a no-op, and bumping
# BUN_VERSION re-downloads the binary.
print_status "Installing ${BUN_VERSION}..."
su - "$DEV_USER" -c "curl -fsSL https://bun.sh/install | bash -s ${BUN_VERSION}" 2>/dev/null || \
    print_warning "bun install reported a warning — verify with 'bun --version' after reconnecting"
print_status "${BUN_VERSION} installed (binary at ~/.bun/bin/bun)"

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
        pipx==${PIPX_VERSION} \
        pre-commit==${PRECOMMIT_VERSION}"

# uv is installed as a standalone binary (not via pip) so it isn't
# coupled to pyenv's active Python. Astral publishes a per-version
# install.sh at https://astral.sh/uv/<version>/install.sh — that URL is
# the pinning mechanism. Binary lands in ~/.local/bin/uv (already on
# PATH via the Claude Code VPS additions block).
su - "$DEV_USER" -c "curl -LsSf https://astral.sh/uv/${UV_VERSION}/install.sh | sh"

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

# ── rtk (Rust Token Killer) — CLI output compressor ─────
# Installs the upstream .deb via `apt install ./file.deb` so apt
# auto-resolves any runtime dependencies instead of dpkg erroring out.
# dpkg handles upgrades cleanly on rerun via the normal Packages db.
print_status "Installing rtk ${RTK_VERSION}..."
RTK_DEB_FILE="rtk_${RTK_VERSION#v}-1_amd64.deb"
curl -fsSL "https://github.com/rtk-ai/rtk/releases/download/${RTK_VERSION}/${RTK_DEB_FILE}" -o /tmp/rtk.deb
apt install -y /tmp/rtk.deb
rm /tmp/rtk.deb
print_status "rtk ${RTK_VERSION} installed"

# ── GitHub CLI (gh) — always add repo + install/upgrade ──
# GitHub CLI apt repo was registered up top; here we just install.
print_status "Installing/updating GitHub CLI..."
apt install -y gh
print_status "GitHub CLI (gh) installed"

# ── PowerShell (apt) + .NET SDK LTS (official installer) ──
# PowerShell lives only in Microsoft's apt repo, but .NET 10 isn't in
# Microsoft's jammy (22.04) feed yet and the noble (24.04) naming lives
# in Ubuntu's universe — not Microsoft's. To install .NET 10 reliably
# on BOTH 22.04 and 24.04 we use Microsoft's official dotnet-install.sh
# which pulls signed binaries from dot.net/v1 and is version-pinned by
# --channel. PowerShell stays on apt since Ubuntu doesn't ship it.
print_status "Installing .NET ${DOTNET_LTS_VERSION} LTS + PowerShell..."

# Microsoft apt repo was registered up top; PowerShell is a plain install.
apt install -y powershell

# .NET SDK via dotnet-install.sh — installs to /usr/share/dotnet, then
# symlink exposes it system-wide so both root and $DEV_USER get `dotnet`
# on PATH. Re-running with the same --channel is idempotent (no-op when
# the latest patch is already installed; updates when a new one drops).
curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
/tmp/dotnet-install.sh --channel "${DOTNET_LTS_VERSION}" --install-dir /usr/share/dotnet
rm -f /tmp/dotnet-install.sh
ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet

print_status ".NET $(/usr/local/bin/dotnet --version 2>/dev/null || echo "${DOTNET_LTS_VERSION}.x") + PowerShell $(pwsh --version 2>/dev/null | head -1 || echo "${PWSH_NOTE}") installed"

# ── Caddy (auto-HTTPS reverse proxy / web server) ───────
# Installed from Cloudsmith's official Caddy stable apt repo. Caddy
# handles Let's Encrypt / ZeroSSL certs automatically on first request
# to a configured domain (no certbot needed). Config: /etc/caddy/Caddyfile.
# Default install serves a welcome page on :80 until the Caddyfile is
# edited. UFW already opened 80/tcp + 443/tcp above.
# Caddy apt repo was registered up top; here we just install + enable.
print_status "Installing Caddy..."
apt install -y caddy
systemctl enable caddy
systemctl restart caddy
print_status "Caddy $(caddy version 2>/dev/null | awk '{print $1}' || echo installed) — edit /etc/caddy/Caddyfile, then: systemctl reload caddy"

# ============================================================
# 9. Shell customization — PS1 + aliases + productivity init
# ============================================================
# Applied to BOTH /root/.bashrc and /home/$DEV_USER/.bashrc so the two
# users have a consistent workflow. Written via delete-then-append so
# reruns rewrite cleanly (no duplicate blocks).
print_status "Writing shell customization (PS1, aliases, tool integrations) to root + $DEV_USER..."

_write_common_bashrc() {
    local rc="$1"
    [ -f "$rc" ] || touch "$rc"

    # PS1 — show user@<fqdn>:cwd with colors
    sed -i '/# --- PS1 START ---/,/# --- PS1 END ---/d' "$rc"
    cat >> "$rc" <<'PS1_EOF'

# --- PS1 START ---
# Cache FQDN once on shell load — avoids spawning `hostname` per prompt.
# Triple fallback handles fresh VPS where /etc/hosts doesn't yet map
# the short name to an FQDN (hostname -f returns empty, not an error).
_HOSTNAME_FQDN=$(hostname -f 2>/dev/null)
[ -z "$_HOSTNAME_FQDN" ] && _HOSTNAME_FQDN=$(hostname 2>/dev/null)
[ -z "$_HOSTNAME_FQDN" ] && _HOSTNAME_FQDN="vps"
PS1="\[\033[01;32m\]\u@${_HOSTNAME_FQDN}\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "
# --- PS1 END ---
PS1_EOF

    # Aliases — common dev shortcuts
    sed -i '/# --- Aliases START ---/,/# --- Aliases END ---/d' "$rc"
    cat >> "$rc" <<'ALIASES_EOF'

# --- Aliases START ---
# ls / navigation
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ls='ls --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# grep with color
alias grep='grep --color=auto'
alias egrep='grep -E --color=auto'
alias fgrep='grep -F --color=auto'

# git shortcuts (widely expected muscle memory)
alias gs='git status'
alias gl='git log --oneline --graph --decorate --all'
alias gd='git diff'
alias gds='git diff --staged'
alias gc='git commit'
alias gca='git commit --amend'
alias gp='git push'
alias gpl='git pull'
alias gco='git checkout'
alias gb='git branch'

# misc
alias h='history'
alias c='clear'
alias rebash='source ~/.bashrc && echo "bashrc reloaded"'
alias ports='ss -tulpn'
alias myip='curl -s ifconfig.me; echo'
alias path='echo $PATH | tr : "\n"'

# cat → bat (Ubuntu installs as batcat; we symlinked /usr/local/bin/bat)
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never'
# ls → eza not installed by default; stick with ls

# Claude Code / rtk shortcut — prefix any verbose command with `rtk `
# to compress its output (e.g. `rtk git log`, `rtk cargo test`)
# --- Aliases END ---
ALIASES_EOF

    # Productivity tool shell integrations
    sed -i '/# --- Productivity START ---/,/# --- Productivity END ---/d' "$rc"
    cat >> "$rc" <<'PROD_EOF'

# --- Productivity START ---
# fzf — Ctrl-R history search, Ctrl-T file picker, Alt-C dir picker
if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
    . /usr/share/doc/fzf/examples/key-bindings.bash
fi
if [ -f /usr/share/bash-completion/completions/fzf ]; then
    . /usr/share/bash-completion/completions/fzf
fi

# zoxide — `z <fragment>` jumps to frequently-used dirs
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"

# direnv — auto-load .envrc per project dir
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"

# git-delta as default pager (colored word-diff)
if command -v delta >/dev/null 2>&1; then
    export GIT_PAGER='delta --line-numbers'
fi
# --- Productivity END ---
PROD_EOF
}

_write_common_bashrc /root/.bashrc
_write_common_bashrc /home/$DEV_USER/.bashrc

# Root gets a subset of the dev env so language runtimes work when root
# is troubleshooting. nvm/pyenv/bun stay dev-only by design (per-user).
sed -i '/# --- Root Toolchains START ---/,/# --- Root Toolchains END ---/d' /root/.bashrc
cat >> /root/.bashrc <<ROOT_TC
# --- Root Toolchains START ---
export PATH="/usr/local/go/bin:\$PATH"
export JAVA_HOME="${JAVA_HOME_PATH}"
export PATH="\$JAVA_HOME/bin:\$PATH"
# .NET was installed via dotnet-install.sh, not apt, so DOTNET_ROOT
# must be set for dotnet to find the shared framework.
export DOTNET_ROOT="/usr/share/dotnet"
# conda is symlinked to /usr/local/bin/conda so no PATH change needed;
# source the shell hook for activate/deactivate support.
if [ -f /opt/miniconda3/etc/profile.d/conda.sh ]; then
    . /opt/miniconda3/etc/profile.d/conda.sh
fi
# --- Root Toolchains END ---
ROOT_TC

# Same DOTNET_ROOT for the dev user
sed -i '/# --- Dotnet START ---/,/# --- Dotnet END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc <<'DOTNET_ENV'

# --- Dotnet START ---
export DOTNET_ROOT="/usr/share/dotnet"
# --- Dotnet END ---
DOTNET_ENV

# Fix ownership of everything in dev home
chown -R $DEV_USER:$DEV_USER /home/$DEV_USER

print_status "All dev toolchains installed + shell customization applied to root + $DEV_USER"

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
BUN_VERSION=${BUN_VERSION}
PYTHON_VERSION=${PYTHON_VERSION}
RUFF_VERSION=${RUFF_VERSION}
MYPY_VERSION=${MYPY_VERSION}
POETRY_VERSION=${POETRY_VERSION}
PYRIGHT_VERSION=${PYRIGHT_VERSION}
UV_VERSION=${UV_VERSION}
PIPX_VERSION=${PIPX_VERSION}
PRECOMMIT_VERSION=${PRECOMMIT_VERSION}
MINICONDA_VERSION=${MINICONDA_VERSION}
RTK_VERSION=${RTK_VERSION}
DOTNET_LTS_VERSION=${DOTNET_LTS_VERSION}
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
echo "  UFW        : Active — SSH (22/tcp), mosh (60000-61000/udp), HTTP (80/tcp), HTTPS (443/tcp)"
echo "  fail2ban   : Active — SSH brute-force protection"
echo "  mosh       : Installed — connect with: mosh ${DEV_USER}@<vps-ip>"
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
echo "  Node.js    : ${NODE_VERSION}  (ts ${TS_VERSION}, tsx, pnpm ${PNPM_VERSION}, yarn, ts-language-server, ncu, ${BUN_VERSION})"
echo "  Python     : ${PYTHON_VERSION}  (ruff ${RUFF_VERSION}, mypy, pytest, poetry, pyright, uv ${UV_VERSION}, pipx, pre-commit)"
echo "  Miniconda  : ${MINICONDA_VERSION}  (/opt/miniconda3, auto_activate_base=false)"
echo "  .NET LTS   : ${DOTNET_LTS_VERSION}  (via dotnet-install.sh, /usr/share/dotnet)"
echo "  PowerShell : pwsh (tracks Microsoft apt, latest 7.x)"
echo "  Caddy      : $(caddy version 2>/dev/null | awk '{print $1}' || echo installed) — auto-HTTPS, edit /etc/caddy/Caddyfile"
echo "  Extras     : ripgrep, fd, bat, jq, htop, shellcheck, rtk ${RTK_VERSION}"
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
echo "  1. Connect as the dev user (ssh or mosh — mosh survives roaming):"
echo "     ssh  dev@<vps-ip>"
echo "     mosh dev@<vps-ip>     # install mosh locally first"
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
