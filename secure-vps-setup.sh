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
# 0. Create 'dev' user — locked down, no sudo
# ============================================================
DEV_USER="sandbox"

if id "$DEV_USER" &>/dev/null; then
    print_warning "User '$DEV_USER' already exists — skipping creation"
else
    print_status "Creating user '$DEV_USER' (no sudo, no root access)..."
    adduser --disabled-password --gecos "Claude Code Dev User" "$DEV_USER"

    # Set a random password (login will be via SSH key)
    TEMP_PASS=$(openssl rand -base64 16)
    echo "${DEV_USER}:${TEMP_PASS}" | chpasswd
    print_warning "Temporary password for '$DEV_USER': $TEMP_PASS"
    print_warning "Save this now! Or set your own: sudo passwd $DEV_USER"
fi

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

# Create Claude Code session management toolkit
mkdir -p /home/$DEV_USER/.local/bin

cat > /home/$DEV_USER/.local/bin/cc << 'SCRIPT'
#!/bin/bash
# ─────────────────────────────────────────────────────────
# cc — Claude Code Session Manager
# ─────────────────────────────────────────────────────────
#
# SESSIONS:
#   cc                  → Start/attach default 'claude' session
#   cc <n>           → Start/attach named session
#   cc ls               → List all sessions (shows mode)
#   cc kill <n>      → Kill a specific session
#   cc killall          → Kill ALL sessions
#   cc new <n>       → Force new session
#   cc detach           → Detach from current session
#   cc rename <new>     → Rename current session
#   cc switch <n>    → Switch to another session
#
# YOLO MODE (--dangerously-skip-permissions):
#   cc yolo             → Launch YOLO mode (default session)
#   cc yolo <n>      → Launch YOLO mode (named session)
#   cc yolo! <n>     → Kill + relaunch in YOLO mode
#   cc safe <n>      → Kill + relaunch in SAFE mode
#
#   cc forget <n>    → Clear saved conversation mapping
#   cc help             → Show this help
# ─────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

CC_SESSION_DIR="$HOME/.claude/cc-sessions"

# Helper: switch or attach depending on whether we're inside tmux
_cc_go() {
    local target="$1"
    if [ -n "$TMUX" ]; then
        # Inside tmux: write title to the SSH tty (Termius), not the tmux pane
        local client_tty
        client_tty=$(tmux display-message -p '#{client_tty}')
        printf '\033]0;%s - %s\007' "$target" "$(whoami)" > "$client_tty"
        tmux switch-client -t "$target"
    else
        # Outside tmux: stdout goes directly to Termius
        printf '\033]0;%s - %s\007' "$target" "$(whoami)"
        tmux attach -t "$target"
    fi
}

# Get stored Claude session UUID for a cc session name
_cc_get_session_id() {
    local name="$1"
    local file="$CC_SESSION_DIR/$name"
    if [ -f "$file" ]; then
        cat "$file"
    fi
}

# Save Claude session UUID for a cc session name
_cc_save_session_id() {
    local name="$1"
    local uuid="$2"
    mkdir -p "$CC_SESSION_DIR"
    echo "$uuid" > "$CC_SESSION_DIR/$name"
}

# Clear stored Claude session UUID (for fresh start)
_cc_clear_session_id() {
    local name="$1"
    rm -f "$CC_SESSION_DIR/$name"
}

# Build the claude command with session resume support
_cc_build_cmd() {
    local mode="$1"
    local name="$2"
    local flags=""

    if [ "$mode" = "yolo" ]; then
        flags="--dangerously-skip-permissions"
    fi

    local stored_id
    stored_id=$(_cc_get_session_id "$name")

    if [ -n "$stored_id" ]; then
        echo "claude --resume $stored_id $flags"
    else
        local new_id
        new_id=$(uuidgen)
        _cc_save_session_id "$name" "$new_id"
        echo "claude --session-id $new_id -n $name $flags"
    fi
}

_cc_help() {
    echo ""
    echo -e "${CYAN}${BOLD}cc${NC} — Claude Code Session Manager"
    echo ""
    echo -e "  ${GREEN}SESSIONS${NC}"
    echo -e "  cc                  Start/attach default session"
    echo -e "  cc ${YELLOW}<n>${NC}           Start/attach named session"
    echo -e "  cc ls    ${DIM}(cls)${NC}     List all sessions"
    echo -e "  cc kill  ${DIM}(cks)${NC}     Kill a session"
    echo -e "  cc killall ${DIM}(cka)${NC}  Kill ALL sessions"
    echo -e "  cc new   ${DIM}(cn)${NC}      Force create new session"
    echo -e "  cc switch ${DIM}(cs)${NC}    Switch between sessions"
    echo -e "  cc rename           Rename current session"
    echo -e "  cc detach           Detach current session"
    echo -e "  cc forget ${YELLOW}<n>${NC}     Clear saved conversation (fresh start)"
    echo ""
    echo -e "  ${MAGENTA}YOLO MODE${NC} ${DIM}(--dangerously-skip-permissions)${NC}"
    echo -e "  cc yolo             Launch YOLO session (default)"
    echo -e "  cc yolo ${YELLOW}<n>${NC}      Launch YOLO named session"
    echo -e "  cc yolo! ${YELLOW}<n>${NC}     Kill + relaunch in YOLO"
    echo -e "  cc safe ${YELLOW}<n>${NC}       Kill + relaunch in SAFE mode"
    echo ""
    echo -e "  ${DIM}YOLO skips ALL permission prompts.${NC}"
    echo -e "  ${DIM}Auto-commits git checkpoint before launching.${NC}"
    echo -e "  ${DIM}Use 'cc safe' to switch back to normal mode.${NC}"
    echo ""
    echo -e "  ${GREEN}ALIASES${NC}"
    echo -e "  ccy               = cc yolo"
    echo -e "  ccp ${YELLOW}<dir>${NC}        = start claude in project dir"
    echo -e "  ccyp ${YELLOW}<dir>${NC}       = start YOLO claude in project dir"
    echo ""
    echo -e "  ${DIM}Ctrl+b d = detach  |  Ctrl+b s = session picker${NC}"
    echo -e "  ${DIM}Shift+Tab inside claude = cycle permission modes${NC}"
    echo ""
}

_cc_list() {
    if ! tmux list-sessions 2>/dev/null | grep -q .; then
        echo -e "${YELLOW}No active sessions${NC}"
        return
    fi
    echo ""
    echo -e "${CYAN}Active Claude Sessions:${NC}"
    echo "  ─────────────────────────────────────────"
    tmux list-sessions 2>/dev/null | while IFS= read -r line; do
        SESSION_NAME=$(echo "$line" | cut -d: -f1)
        WINDOW_COUNT=$(echo "$line" | grep -oP '\d+ windows' || echo "")
        ATTACHED=""
        if echo "$line" | grep -q "(attached)"; then
            ATTACHED=" ${GREEN}<- attached${NC}"
        fi
        MODE=""
        if tmux list-panes -t "$SESSION_NAME" -F "#{pane_start_command}" 2>/dev/null | grep -q "dangerously"; then
            MODE=" ${MAGENTA}[YOLO]${NC}"
        fi
        echo -e "  ${GREEN}*${NC} ${SESSION_NAME}${MODE}  ${DIM}${WINDOW_COUNT}${NC}${ATTACHED}"
    done
    echo ""
}

_cc_kill() {
    local target="$1"
    if [ -z "$target" ]; then
        echo -e "${RED}Usage: cc kill <session-name>${NC}"
        _cc_list
        return 1
    fi
    if tmux has-session -t "$target" 2>/dev/null; then
        tmux kill-session -t "$target"
        rm -f "$CC_SESSION_DIR/$target"
        echo -e "${GREEN}Killed session:${NC} $target"
    else
        echo -e "${RED}Session not found:${NC} $target"
        _cc_list
    fi
}

_cc_killall() {
    local count
    count=$(tmux list-sessions 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}No sessions to kill${NC}"
        return
    fi
    echo -e "${YELLOW}Killing $count session(s)...${NC}"
    tmux kill-server 2>/dev/null
    rm -f "$CC_SESSION_DIR"/*
    echo -e "${GREEN}All sessions killed${NC}"
}

_cc_git_checkpoint() {
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo -e "${YELLOW}Git checkpoint before YOLO...${NC}"
        git add -A 2>/dev/null
        git commit -m "checkpoint: pre-yolo $(date +%Y%m%d-%H%M%S)" --allow-empty -q 2>/dev/null
        echo -e "${GREEN}Saved. Rollback:${NC} git reset --hard HEAD~1"
    else
        echo -e "${DIM}Not a git repo - no checkpoint${NC}"
    fi
}

_cc_new() {
    local name="${1:-claude-$(date +%H%M)}"
    if tmux has-session -t "$name" 2>/dev/null; then
        echo -e "${YELLOW}Session '$name' exists - killing it first${NC}"
        tmux kill-session -t "$name"
    fi
    # Force fresh conversation
    _cc_clear_session_id "$name"
    local cmd
    cmd=$(_cc_build_cmd "safe" "$name")
    echo -e "${GREEN}Creating session:${NC} $name"
    tmux new-session -d -s "$name" -c "$(pwd)" "$cmd; bash"
    _cc_go "$name"
}

_cc_attach() {
    local name="${1:-claude}"
    if tmux has-session -t "$name" 2>/dev/null; then
        echo -e "${GREEN}Attaching to:${NC} $name"
        _cc_go "$name"
    else
        local cmd
        cmd=$(_cc_build_cmd "safe" "$name")
        echo -e "${CYAN}Creating session:${NC} $name"
        tmux new-session -d -s "$name" -c "$(pwd)" "$cmd; bash"
        _cc_go "$name"
    fi
}

_cc_yolo() {
    local name="${1:-claude}"
    _cc_git_checkpoint
    echo -e "${MAGENTA}${BOLD}>>> YOLO MODE${NC} - all permissions skipped"
    echo ""
    if tmux has-session -t "$name" 2>/dev/null; then
        echo -e "${GREEN}Attaching to existing:${NC} $name"
        _cc_go "$name"
    else
        local cmd
        cmd=$(_cc_build_cmd "yolo" "$name")
        tmux new-session -d -s "$name" -c "$(pwd)" "$cmd; bash"
        _cc_go "$name"
    fi
}

_cc_yolo_force() {
    local name="${1:-claude}"
    local session_dir="$(pwd)"
    if tmux has-session -t "$name" 2>/dev/null; then
        session_dir=$(tmux display-message -t "$name" -p '#{pane_current_path}' 2>/dev/null || echo "$(pwd)")
        echo -e "${YELLOW}Killing existing session:${NC} $name"
        tmux kill-session -t "$name"
    fi
    _cc_git_checkpoint
    echo -e "${MAGENTA}${BOLD}>>> YOLO MODE${NC} - all permissions skipped"
    echo ""
    local cmd
    cmd=$(_cc_build_cmd "yolo" "$name")
    tmux new-session -d -s "$name" -c "$session_dir" "$cmd; bash"
    _cc_go "$name"
}

_cc_safe() {
    local name="${1:-claude}"
    local session_dir="$(pwd)"
    if tmux has-session -t "$name" 2>/dev/null; then
        session_dir=$(tmux display-message -t "$name" -p '#{pane_current_path}' 2>/dev/null || echo "$(pwd)")
        echo -e "${YELLOW}Killing existing session:${NC} $name"
        tmux kill-session -t "$name"
    fi
    echo -e "${GREEN}${BOLD}>>> SAFE MODE${NC} - permissions enabled"
    echo ""
    local cmd
    cmd=$(_cc_build_cmd "safe" "$name")
    tmux new-session -d -s "$name" -c "$session_dir" "$cmd; bash"
    _cc_go "$name"
}

_cc_rename() {
    local newname="$1"
    if [ -z "$newname" ]; then
        echo -e "${RED}Usage: cc rename <new-name>${NC}"
        return 1
    fi
    if [ -z "$TMUX" ]; then
        echo -e "${RED}Not inside a tmux session${NC}"
        return 1
    fi
    local oldname
    oldname=$(tmux display-message -p '#S')
    tmux rename-session "$newname"
    # Move session mapping if it exists
    if [ -f "$CC_SESSION_DIR/$oldname" ]; then
        mkdir -p "$CC_SESSION_DIR"
        mv "$CC_SESSION_DIR/$oldname" "$CC_SESSION_DIR/$newname"
    fi
    echo -e "${GREEN}Session renamed to:${NC} $newname"
}

_cc_switch() {
    local target="$1"
    if [ -z "$target" ]; then
        if [ -n "$TMUX" ]; then
            tmux choose-session
        else
            _cc_list
        fi
        return
    fi
    if [ -z "$TMUX" ]; then
        _cc_attach "$target"
        return
    fi
    if tmux has-session -t "$target" 2>/dev/null; then
        tmux switch-client -t "$target"
    else
        echo -e "${RED}Session not found:${NC} $target"
        _cc_list
    fi
}

case "${1:-}" in
    help|-h|--help)  _cc_help ;;
    ls|list)         _cc_list ;;
    kill)            _cc_kill "$2" ;;
    killall)         _cc_killall ;;
    new)             _cc_new "$2" ;;
    forget)          _cc_clear_session_id "${2:-claude}"; echo -e "${GREEN}Cleared session mapping for:${NC} ${2:-claude}" ;;
    detach)
        if [ -n "$TMUX" ]; then tmux detach
        else echo -e "${RED}Not inside a tmux session${NC}"; fi ;;
    rename)          _cc_rename "$2" ;;
    switch|sw)       _cc_switch "$2" ;;
    yolo|y)          _cc_yolo "$2" ;;
    yolo!|y!)        _cc_yolo_force "$2" ;;
    safe)            _cc_safe "$2" ;;
    "")              _cc_attach "claude" ;;
    *)               _cc_attach "$1" ;;
esac
SCRIPT
chmod +x /home/$DEV_USER/.local/bin/cc

# ── setup-github: interactive GitHub/SSH/GPG setup ───────
cat > /home/$DEV_USER/.local/bin/setup-github << 'SETUPGH'
#!/bin/bash
# ─────────────────────────────────────────────────────────
# setup-github — Interactive GitHub, SSH & GPG setup
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
echo -e "${BOLD}GitHub, SSH & GPG Setup${NC}"
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
    if ! gh auth login --git-protocol ssh --web; then
        err "GitHub login failed. Run 'setup-github' again to retry."
        exit 1
    fi
    GH_USER=$(gh api user --jq .login 2>/dev/null)
    ok "Authenticated as ${BOLD}$GH_USER${NC}"
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

# ── Step 3: Upload SSH key to GitHub ──────────────────────
echo -e "${BOLD}Step 3: SSH Key${NC}"

SSH_PUB="$HOME/.ssh/id_ed25519.pub"
if [ ! -f "$SSH_PUB" ]; then
    err "No SSH public key found at $SSH_PUB"
    err "This should have been created by the VPS setup script."
    exit 1
fi

KEY_TITLE="VPS ($(hostname))"
# Check if this key is already on GitHub
LOCAL_FP=$(ssh-keygen -lf "$SSH_PUB" 2>/dev/null | awk '{print $2}')
EXISTING=$(gh ssh-key list 2>/dev/null | grep "$LOCAL_FP" || true)

if [ -n "$EXISTING" ]; then
    ok "SSH key already on GitHub"
else
    info "Uploading SSH key to GitHub..."
    if gh ssh-key add "$SSH_PUB" --title "$KEY_TITLE"; then
        ok "SSH key uploaded: $KEY_TITLE"
    else
        err "Failed to upload SSH key. You can do it manually:"
        echo "  gh ssh-key add $SSH_PUB --title \"$KEY_TITLE\""
    fi
fi
echo ""

# ── Step 4: GPG key (optional) ────────────────────────────
echo -e "${BOLD}Step 4: GPG Signing (optional)${NC}"

GPG_KEY_ID=""
EXISTING_KEYS=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -oP 'sec\s+ed25519/\K[A-F0-9]+' || true)

if [ -n "$EXISTING_KEYS" ]; then
    GPG_KEY_ID=$(echo "$EXISTING_KEYS" | head -1)
    GPG_UID=$(gpg --list-secret-keys --keyid-format long "$GPG_KEY_ID" 2>/dev/null | grep uid | head -1 | sed 's/.*] //')
    ok "Existing GPG key found: $GPG_KEY_ID"
    echo -e "  ${DIM}$GPG_UID${NC}"
    echo ""
    read -rp "$(echo -e "${CYAN}Use this key for commit signing? [Y/n]:${NC} ")" USE_EXISTING
    if [[ "$USE_EXISTING" =~ ^[Nn] ]]; then
        GPG_KEY_ID=""
    fi
fi

if [ -z "$GPG_KEY_ID" ]; then
    read -rp "$(echo -e "${CYAN}Generate a new GPG key for commit signing? [Y/n]:${NC} ")" GEN_GPG
    if [[ ! "$GEN_GPG" =~ ^[Nn] ]]; then
        GPG_EMAIL="$INPUT_EMAIL"
        info "Generating GPG key for $INPUT_NAME <$GPG_EMAIL>..."
        echo -e "${DIM}You will be prompted for a passphrase (can be empty).${NC}"

        gpg --batch --gen-key <<GPGGEN
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: $INPUT_NAME
Name-Email: $GPG_EMAIL
Expire-Date: 0
%commit
GPGGEN

        GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format long 2>/dev/null | grep -oP 'sec\s+ed25519/\K[A-F0-9]+' | tail -1)

        if [ -n "$GPG_KEY_ID" ]; then
            ok "GPG key generated: $GPG_KEY_ID"
        else
            err "GPG key generation failed."
        fi
    else
        warn "Commits will NOT be signed. Run 'setup-github' again to enable signing."
    fi
fi
echo ""

# ── Step 5: Git signing config ────────────────────────────
if [ -n "$GPG_KEY_ID" ]; then
    echo -e "${BOLD}Step 5: Git Signing Config${NC}"

    git config --global user.signingkey "$GPG_KEY_ID"
    git config --global commit.gpgsign true
    git config --global tag.gpgsign true
    ok "Git configured: sign commits & tags with $GPG_KEY_ID"

    # Warn if GPG email doesn't match git email
    GPG_EMAILS=$(gpg --list-secret-keys --keyid-format long "$GPG_KEY_ID" 2>/dev/null | grep -oP '<\K[^>]+')
    if ! echo "$GPG_EMAILS" | grep -qF "$INPUT_EMAIL"; then
        warn "GPG key email ($GPG_EMAILS) doesn't match git email ($INPUT_EMAIL)"
        warn "GitHub may show commits as 'Unverified'. Consider matching them."
    fi
    echo ""

    # ── Step 6: Upload GPG key to GitHub ──────────────────
    echo -e "${BOLD}Step 6: Upload GPG Key to GitHub${NC}"

    GPG_FP=$(gpg --list-secret-keys --with-colons "$GPG_KEY_ID" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    EXISTING_GH_GPG=$(gh gpg-key list 2>/dev/null | grep "${GPG_FP:-$GPG_KEY_ID}" || true)
    if [ -n "$EXISTING_GH_GPG" ]; then
        ok "GPG key already on GitHub"
    else
        info "Uploading GPG key to GitHub..."
        if gpg --armor --export "$GPG_KEY_ID" | gh gpg-key add -; then
            ok "GPG key uploaded to GitHub"
        else
            err "Failed to upload GPG key. You can do it manually:"
            echo "  gpg --armor --export $GPG_KEY_ID | gh gpg-key add -"
        fi
    fi
    echo ""
fi

# ── Verify ────────────────────────────────────────────────
echo -e "${BOLD}Summary${NC}"
echo "─────────────────────────────────────────"
echo -e "  GitHub user : ${GREEN}$GH_USER${NC}"
echo -e "  Git name    : $INPUT_NAME"
echo -e "  Git email   : $INPUT_EMAIL"
echo -e "  SSH key     : $(ssh-keygen -lf "$SSH_PUB" 2>/dev/null | awk '{print $2}')"
if [ -n "$GPG_KEY_ID" ]; then
    echo -e "  GPG key     : $GPG_KEY_ID (signing ${GREEN}enabled${NC})"
else
    echo -e "  GPG signing : ${DIM}not configured${NC}"
fi
echo ""

info "Testing SSH connection to GitHub..."
ssh -T git@github.com 2>&1 | head -3
echo ""
ok "Setup complete!"
echo ""
SETUPGH
chmod +x /home/$DEV_USER/.local/bin/setup-github

# ── Tab completion for cc ────────────────────────────────
mkdir -p /home/$DEV_USER/.local/share/bash-completion/completions
cat > /home/$DEV_USER/.local/share/bash-completion/completions/cc << 'COMPLETION'
_cc_completions() {
    local cur prev commands sessions
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="ls list kill killall new detach rename switch sw yolo yolo! safe forget help"

    case "$prev" in
        kill|switch|sw|yolo|yolo!|safe|forget)
            sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null)
            COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
            return
            ;;
        cc)
            sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null)
            COMPREPLY=($(compgen -W "$commands $sessions" -- "$cur"))
            return
            ;;
    esac
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
}
complete -F _cc_completions cc
COMPLETION

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

# Add .local/bin to dev user's PATH + aliases (delete-then-append for upgrades)
sed -i '/# --- Claude Code VPS additions START ---/,/# --- Claude Code VPS additions END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << 'BASHRC'

# --- Claude Code VPS additions START ---
export PATH="$HOME/.local/bin:$PATH"

# Claude Code aliases — sessions
alias cls='cc ls'                    # list sessions
alias cks='cc kill'                  # kill a session
alias cka='cc killall'               # kill all sessions
alias cn='cc new'                    # new session
alias cs='cc switch'                 # switch session

# Claude Code aliases — YOLO mode
alias ccy='cc yolo'                  # launch yolo
alias ccyf='cc yolo!'               # force relaunch yolo
alias ccs='cc safe'                  # switch back to safe

# Quick project starter — cd into dir + start claude
ccp() {
    local dir="${1:-.}"
    if [ "$dir" != "." ]; then
        mkdir -p "$dir" && cd "$dir" || return 1
    fi
    local name=$(basename "$(pwd)")
    if ! tmux has-session -t "$name" 2>/dev/null; then
        tmux new-session -d -s "$name" -c "$(pwd)" "claude; bash"
    fi
    if [ -n "$TMUX" ]; then tmux switch-client -t "$name"; else tmux attach -t "$name"; fi
}

# YOLO project starter — cd into dir + start claude in YOLO mode
ccyp() {
    local dir="${1:-.}"
    if [ "$dir" != "." ]; then
        mkdir -p "$dir" && cd "$dir" || return 1
    fi
    local name=$(basename "$(pwd)")
    # Git checkpoint
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        git add -A 2>/dev/null
        git commit -m "checkpoint: pre-yolo $(date +%Y%m%d-%H%M%S)" --allow-empty -q 2>/dev/null
    fi
    if tmux has-session -t "$name" 2>/dev/null; then
        tmux kill-session -t "$name"
    fi
    tmux new-session -d -s "$name" -c "$(pwd)" "claude --dangerously-skip-permissions; bash"
    if [ -n "$TMUX" ]; then tmux switch-client -t "$name"; else tmux attach -t "$name"; fi
}

# Load tab completion for cc
if [ -f "$HOME/.local/share/bash-completion/completions/cc" ]; then
    . "$HOME/.local/share/bash-completion/completions/cc"
fi
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

# GPG agent config for dev user (always update)
mkdir -p /home/$DEV_USER/.gnupg
chmod 700 /home/$DEV_USER/.gnupg
cat > /home/$DEV_USER/.gnupg/gpg-agent.conf << 'GPGAGENT'
default-cache-ttl 28800
max-cache-ttl 28800
pinentry-program /usr/bin/pinentry-tty
GPGAGENT
chown $DEV_USER:$DEV_USER /home/$DEV_USER/.gnupg/gpg-agent.conf
chmod 600 /home/$DEV_USER/.gnupg/gpg-agent.conf
chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.gnupg
print_status "gpg-agent configured (8-hour cache, tty pinentry)"

sed -i '/# --- GPG Agent START ---/,/# --- GPG Agent END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << 'GPGENV'

# --- GPG Agent START ---
export GPG_TTY=$(tty)
# --- GPG Agent END ---
GPGENV

chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.local
chown $DEV_USER:$DEV_USER /home/$DEV_USER/.bashrc

print_status "tmux installed — mobile-optimized, use 'cc' to start sessions"

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

# ── Go (latest stable via official tarball) ─────────────
print_status "Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
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

# Install common Go tools as dev user
su - "$DEV_USER" -c 'export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH" && export GOPATH="$HOME/go" && \
    go install golang.org/x/tools/gopls@latest && \
    go install github.com/go-delve/delve/cmd/dlv@latest && \
    go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest && \
    go install github.com/air-verse/air@latest'
print_status "Go ${GO_VERSION} installed + gopls, delve, golangci-lint, air"

# ── Java (Eclipse Temurin JDK 25 LTS via Adoptium) ─────
print_status "Installing Java (Temurin JDK 25)..."
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/adoptium.list
apt update -y
apt install -y temurin-25-jdk

# Install Maven and Gradle
apt install -y maven
GRADLE_VERSION="8.12"
curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o /tmp/gradle.zip
# Clean up old Gradle versions before extracting new
find /opt -maxdepth 1 -name 'gradle-*' -type d \
    -not -name "gradle-${GRADLE_VERSION}" -exec rm -rf {} + 2>/dev/null || true
unzip -qo /tmp/gradle.zip -d /opt
ln -sf "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle
rm /tmp/gradle.zip

# Install jdtls (Eclipse JDT Language Server) — latest milestone
print_status "Installing jdtls (Eclipse JDT Language Server)..."
JDTLS_INSTALL_DIR="/opt/jdtls"
JDTLS_MILESTONES_URL="https://download.eclipse.org/jdtls/milestones"
# Find latest version directory from milestones page
JDTLS_LATEST_VER=$(curl -fsSL "$JDTLS_MILESTONES_URL/" \
    | grep -oP 'href="\K[0-9]+\.[0-9]+\.[0-9]+(?=/")' \
    | sort -V | tail -1)
if [ -n "$JDTLS_LATEST_VER" ]; then
    # Get the exact filename from latest.txt
    JDTLS_FILENAME=$(curl -fsSL "$JDTLS_MILESTONES_URL/$JDTLS_LATEST_VER/latest.txt")
    if [ -n "$JDTLS_FILENAME" ]; then
        JDTLS_URL="$JDTLS_MILESTONES_URL/$JDTLS_LATEST_VER/$JDTLS_FILENAME"
        curl -fsSL "$JDTLS_URL" -o /tmp/jdtls.tar.gz
        rm -rf "$JDTLS_INSTALL_DIR"
        mkdir -p "$JDTLS_INSTALL_DIR"
        tar -xzf /tmp/jdtls.tar.gz -C "$JDTLS_INSTALL_DIR"
        rm /tmp/jdtls.tar.gz
        # Create launcher script
        cat > /usr/local/bin/jdtls << 'JDTLS_LAUNCHER'
#!/bin/bash
exec /opt/jdtls/bin/jdtls "$@"
JDTLS_LAUNCHER
        chmod +x /usr/local/bin/jdtls
        print_status "jdtls ${JDTLS_LATEST_VER} installed to ${JDTLS_INSTALL_DIR}"
    else
        print_warning "Could not determine jdtls filename from latest.txt — skipping"
    fi
else
    print_warning "Could not determine latest jdtls version — skipping"
fi

sed -i '/# --- Java START ---/,/# --- Java END ---/d' /home/$DEV_USER/.bashrc
cat >> /home/$DEV_USER/.bashrc << 'JAVAENV'

# --- Java START ---
export JAVA_HOME="/usr/lib/jvm/temurin-25-jdk-amd64"
export PATH="$JAVA_HOME/bin:$PATH"
# --- Java END ---
JAVAENV

print_status "Java 25 (Temurin) + Maven + Gradle ${GRADLE_VERSION} + jdtls installed"

# ── Node.js + TypeScript (via nvm for dev user) ────────
print_status "Installing Node.js + TypeScript..."

# Install/update nvm for dev user (installer is idempotent)
su - "$DEV_USER" -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'

# Install latest LTS Node + global packages
su - "$DEV_USER" -c 'export NVM_DIR="$HOME/.nvm" && \
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && \
    nvm install --lts && \
    nvm alias default lts/* && \
    npm install -g typescript ts-node tsx \
    eslint prettier \
    @types/node \
    nodemon \
    pnpm \
    yarn \
    typescript-language-server'

# Get installed Node version for display
NODE_VER=$(su - "$DEV_USER" -c 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && node --version' 2>/dev/null || echo "LTS")
print_status "Node.js ${NODE_VER} + TypeScript + pnpm + yarn + ts-language-server installed (via nvm)"

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

# Install latest Python 3.12 via pyenv + global tools
su - "$DEV_USER" -c 'export PYENV_ROOT="$HOME/.pyenv" && \
    export PATH="$PYENV_ROOT/bin:$PATH" && \
    eval "$(pyenv init -)" && \
    pyenv install -s 3.12 && \
    pyenv global 3.12 && \
    pip install --upgrade pip && \
    pip install \
        ruff \
        mypy \
        black \
        isort \
        pytest \
        httpie \
        poetry \
        pipenv \
        ipython \
        virtualenv \
        pyright'

PYTHON_VER=$(su - "$DEV_USER" -c 'export PYENV_ROOT="$HOME/.pyenv" && export PATH="$PYENV_ROOT/bin:$PATH" && eval "$(pyenv init -)" && python --version' 2>/dev/null || echo "3.12")
print_status "Python ${PYTHON_VER} + ruff, mypy, black, pytest, poetry, pyright installed (via pyenv)"

# ── Miniconda (system-wide at /opt/miniconda3) ──────────
print_status "Installing Miniconda (system-wide)..."
MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
curl -fsSL "$MINICONDA_URL" -o /tmp/miniconda.sh
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
    inotify-tools \
    pinentry-tty

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
GO_VERSION=${GO_VERSION:-unknown}
GRADLE_VERSION=${GRADLE_VERSION:-unknown}
NODE_VERSION=${NODE_VER:-unknown}
PYTHON_VERSION=${PYTHON_VER:-unknown}
MINICONDA=system-wide
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
echo "  DEV TOOLCHAINS"
echo "  ─────────────────────────────────────────"
echo "  Go         : /usr/local/go  (go, gopls, dlv, air)"
echo "  Java       : Temurin 25     (maven, gradle, jdtls)"
echo "  Node.js    : via nvm        (ts, tsx, pnpm, yarn, ts-language-server)"
echo "  Python     : via pyenv 3.12 (ruff, mypy, pytest, poetry, pyright)"
echo "  Miniconda  : /opt/miniconda3 (auto_activate_base=false)"
echo "  Extras     : ripgrep, fd, bat, jq, htop, shellcheck"
echo "  DEV TOOLS"
echo "  ─────────────────────────────────────────"
echo "  tmux         : Mobile-optimized, use 'cc' to start"
echo "  Claude Code  : Installed for dev user"
echo ""
echo "  CLAUDE SESSION MANAGER (cc):"
echo "  ─────────────────────────────────────────"
echo "  cc                Start/attach 'claude' session"
echo "  cc <name>         Start/attach named session"
echo "  cc ls    (cls)    List all sessions"
echo "  cc kill  (cks)    Kill a session"
echo "  cc killall (cka)  Kill ALL sessions"
echo "  cc new   (cn)     Force new session"
echo "  cc switch (cs)    Switch between sessions"
echo "  cc rename <name>  Rename current session"
echo "  cc forget <name>  Clear saved conversation"
echo "  cc help           Show all commands"
echo "  ccp <dir>         Start claude in project dir"
echo ""
echo "  YOLO MODE (skip permissions):"
echo "  ─────────────────────────────────────────"
echo "  cc yolo  (ccy)    Launch in YOLO mode"
echo "  cc yolo! (ccyf)   Kill + relaunch in YOLO"
echo "  cc safe  (ccs)    Kill + relaunch in SAFE mode"
echo "  ccyp <dir>        YOLO claude in project dir"
echo "  Auto git checkpoint before every YOLO launch"
echo "  Conversations persist across mode switches"
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
echo "  2. Start a Claude Code session:"
echo "     cc"
echo ""
echo "  3. First time only - authenticate Claude Code:"
echo "     (follow browser prompts)"
echo ""
echo "  4. Set up GitHub, SSH & GPG:"
echo "     setup-github"
echo "     (GitHub auth → git identity → SSH key → GPG signing)"
echo ""
echo "  Your SSH public key:"
echo "     cat ~/.ssh/id_ed25519.pub"
echo ""
echo "  Quick workflows:"
echo "     cc                      — default claude session"
echo "     cc myapi                — named session for a project"
echo "     ccp ~/projects/myapp    — cd into dir + start claude"
echo "     cls                     — see all running sessions"
echo "     cs myapi                — switch to another session"
echo "     cks myapi               — done with that session"
echo "     ccy myapi               — launch myapi in YOLO mode"
echo "     ccyf myapi              — switch running session to YOLO"
echo "     ccs myapi               — switch back to safe mode"
echo "     ccyp ~/projects/myapp   — YOLO claude in project dir"
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
