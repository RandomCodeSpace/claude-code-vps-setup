# VPS Setup Project — Claude Code Development Environment

## What This Is
A secure Hostinger VPS (Ubuntu 22.04/24.04) fully configured for Claude Code development, accessible from Termius on iOS and Windows. Everything runs under a locked-down non-root `dev` user.

## Architecture

```
Developer (Termius iOS/Windows)
  ↓ SSH (port 22, protected by fail2ban)
Hostinger VPS (Ubuntu 22.04/24.04)
  ├── User: dev (no sudo, locked down)
  ├── tmux (mobile-optimized)
  │   └── cc session manager (launch claude with 'cc')
  ├── Claude Code (native installer, runs as dev)
  ├── Security
  │   ├── ClamAV (antivirus, daily scans)
  │   ├── rkhunter (rootkit scanner, weekly scans)
  │   ├── ufw (firewall, only port 22 open)
  │   └── fail2ban (bans after 3 failed SSH attempts)
  ├── setup-github (interactive GitHub/SSH/GPG setup helper)
  └── Dev Toolchains
      ├── Go (latest stable + gopls, dlv, golangci-lint, air)
      ├── Java 21 Temurin (maven, gradle 8.12, jdtls)
      ├── Node.js LTS via nvm (typescript, tsx, pnpm, yarn, eslint, prettier, ts-language-server)
      ├── Python 3.12 via pyenv (ruff, mypy, black, pytest, poetry, pyright)
      ├── Miniconda (system-wide, /opt/miniconda3)
      ├── GitHub CLI (gh)
      └── CLI tools (ripgrep, fd, bat, jq, htop, shellcheck, make, cmake)
```

## Decisions Made

| Decision | Choice | Reason |
|----------|--------|--------|
| OS | Ubuntu 22.04/24.04 | Primary distro Anthropic tests Claude Code against |
| User | `dev` (no sudo) | Security — Claude Code should never run as root |
| Antivirus | ClamAV + rkhunter | Free, open source, no paid tiers, no telemetry |
| Firewall | ufw + fail2ban | Free, built into Ubuntu |
| Networking | Direct SSH (port 22) | Tailscale removed — excess for personal dev env |
| Terminal | tmux | Session persistence for mobile, start with `cc` |
| Docker | NOT installed | User preference — explicitly excluded |
| Tailscale | NOT installed | Removed — unnecessary for personal dev |
| Node.js | nvm (not system) | Version switching without sudo |
| Python | pyenv (not system) | Version switching without sudo |
| Java | Temurin 21 LTS | Free, open source JDK from Adoptium |
| Known hosts | Disabled | Both root and dev — no SSH prompts |
| SSH key | ed25519 (no passphrase) | Access already gated by SSH login to VPS |
| GPG | Default-on, user-generated | Interactive setup via `setup-github`, signing enabled by default |
| Git identity | From GitHub (no placeholders) | Set by `setup-github` via `gh api user` |
| Language servers | gopls, jdtls, pyright, ts-language-server | Full LSP support for all installed languages |
| Miniconda | System-wide (/opt/miniconda3) | Conda envs without conflicting with pyenv; no auto-activate |

## Script: secure-vps-setup.sh

### What It Installs (in order)
1. **User `dev`** — non-root, no sudo, SSH keys copied from root, ed25519 keypair generated, workspace at `/home/dev/projects`
2. **SSH config** — `StrictHostKeyChecking no` for both root and dev, GitHub host block for dev
3. **ClamAV** — antivirus daemon + daily cron scan of /home, /tmp, /var/www
4. **rkhunter** — rootkit scanner + weekly cron scan
5. **ufw** — firewall, deny all incoming except SSH (22)
6. **fail2ban** — bans IPs after 3 failed SSH attempts for 1 hour
7. **tmux** — mobile-optimized config (mouse on, touch scroll, high contrast status bar, aggressive resize)
8. **`cc` session manager** — full Claude Code session management with YOLO mode support
9. **`setup-github`** — interactive helper: GitHub auth, git identity, SSH key upload, GPG signing
10. **ssh-agent** — auto-starts in `.bashrc`, persists across tmux panes via `~/.ssh/agent-env`
11. **gpg-agent** — 8-hour cache, tty pinentry, `GPG_TTY` exported in `.bashrc`
12. **Go** — latest stable + gopls, delve, golangci-lint, air
13. **Java 21** — Temurin JDK + Maven + Gradle 8.12 + jdtls (Eclipse JDT Language Server)
14. **Node.js** — LTS via nvm + TypeScript, tsx, pnpm, yarn, eslint, prettier, typescript-language-server
15. **Python 3.12** — via pyenv + ruff, mypy, black, pytest, poetry, ipython, pyright
16. **Miniconda** — system-wide at /opt/miniconda3, conda init for dev user, auto_activate_base=false
17. **CLI tools** — ripgrep, fd, bat, jq, htop, shellcheck, make, cmake, sqlite3, redis-tools, postgresql-client, pinentry-tty
18. **GitHub CLI** — gh
19. **Claude Code** — native installer, installed for dev user

### Upgrade-by-Rerun
Script is safe to rerun and **updates everything on rerun**:
- All `.bashrc` blocks use `START`/`END` markers — `sed` deletes then re-appends fresh
- Legacy single-marker `.bashrc` format auto-migrates on first rerun
- nvm installer is idempotent — always runs to pick up updates
- pyenv runs `pyenv update` if already installed, fresh install otherwise
- GitHub CLI repo is always added — `apt install` handles upgrades
- Root SSH config and gpg-agent.conf are always overwritten
- Old Gradle versions are cleaned up before extracting new
- `pyenv install -s` skips if Python version already installed
- GPG key imports use `--yes` flag for silent overwrite
- User creation checks `id` before creating
- UFW silently ignores duplicate rules
- Package manifest saved to `/var/lib/vps-setup/` for reset script

### Run It
```bash
chmod +x secure-vps-setup.sh
sudo bash secure-vps-setup.sh
```

### Post-Install Steps
```bash
# 1. Switch to dev user
su - dev

# 2. Start a Claude Code session
cc

# 3. Authenticate Claude Code (first time only — follow browser prompts)

# 4. Set up GitHub, SSH & GPG (interactive — handles gh auth, SSH key upload, GPG)
setup-github

# 5. (Optional) Disable root SSH once dev access confirmed
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

## GitHub Setup: `setup-github`

Interactive post-install helper that configures GitHub access in one command. Run once after provisioning, safe to rerun.

### What It Does (in order)
1. **GitHub auth** — checks `gh auth status`, runs `gh auth login --git-protocol ssh --web` if needed
2. **Git identity** — prompts for name/email (pulls defaults from GitHub), updates `git config --global`
3. **SSH key upload** — uploads `~/.ssh/id_ed25519.pub` to GitHub via `gh ssh-key add` (skips if already there)
4. **GPG key** — offers to generate ed25519 GPG key; skips entirely if user declines
5. **Git signing** — configures `commit.gpgsign`, `tag.gpgsign`, `user.signingkey`
6. **GPG upload** — uploads public key to GitHub via `gh gpg-key add` (skips if already there)
7. **Verify** — prints summary, tests `ssh -T git@github.com`

### Usage
```bash
setup-github
```

## Session Manager: `cc`

The `cc` command manages tmux sessions with Claude Code embedded. All commands are tmux-aware — they use `switch-client` when inside tmux (no nesting).

### Session Commands
```
cc                  Start/attach default 'claude' session + launch claude
cc <n>           Start/attach named session + launch claude
cc ls               List all sessions (shows [YOLO] tag)
cc kill <n>      Kill a specific session
cc killall          Kill ALL sessions
cc new <n>       Force create new session (kills existing)
cc switch <n>    Switch to another session (inside tmux)
cc rename <n>    Rename current session
cc detach           Detach from current session
cc help             Show all commands
```

### YOLO Mode (--dangerously-skip-permissions)
```
cc yolo             Launch default session in YOLO mode
cc yolo <n>      Launch named session in YOLO mode
cc yolo! <n>     Kill existing + relaunch in YOLO mode
cc safe <n>      Kill existing + relaunch in SAFE mode
```

YOLO mode behavior:
- Skips ALL Claude Code permission prompts
- Auto-creates a git checkpoint before launching (`git add -A && git commit`)
- Rollback with: `git reset --hard HEAD~1`
- Cannot toggle a running session — must kill + relaunch (use `cc yolo!` or `cc safe`)
- `cc ls` shows `[YOLO]` next to sessions in skip-permissions mode

### Aliases
```
cls       → cc ls           List sessions
cks       → cc kill         Kill a session
cka       → cc killall      Kill all sessions
cn        → cc new          New session
cs        → cc switch       Switch session
ccy       → cc yolo         Launch YOLO
ccyf      → cc yolo!        Force relaunch YOLO
ccs       → cc safe         Switch back to safe
ccp <dir> → cd + start claude in that directory
ccyp <dir> → cd + start YOLO claude in that directory
```

### Tab Completion
`cc` has bash tab completion. Type `cc kill ` then Tab to autocomplete session names.

## tmux Config

Optimized for Termius mobile:
- **Mouse on** — touch scroll works, tap to select panes
- **Alt+arrows** — switch panes (no prefix needed)
- **Shift+arrows** — switch windows (no prefix needed)
- **Ctrl+arrows** — resize panes (no prefix needed)
- **Prefix + |** — split horizontal
- **Prefix + -** — split vertical
- **Prefix + s** — session picker
- **Prefix + d** — detach
- **Prefix = Ctrl+b**
- **50k line scrollback** — Claude Code is verbose
- **Aggressive resize** — auto-adjusts between phone and desktop
- **High contrast status bar** — readable on small screens
- **No forced auto-attach** — SSH gives a plain shell, use `cc` to start tmux+Claude

## File Locations

| File | Location | Purpose |
|------|----------|---------|
| Setup script | `./secure-vps-setup.sh` | Main installer (safe to rerun for upgrades) |
| Reset script | `./reset-vps-setup.sh` | Uninstall everything |
| Session manager | `/home/dev/.local/bin/cc` | Claude session management |
| tmux config | `/home/dev/.tmux.conf` | Mobile-optimized tmux |
| SSH keypair | `/home/dev/.ssh/id_ed25519` | Dev user's ed25519 key (for GitHub) |
| SSH agent env | `/home/dev/.ssh/agent-env` | ssh-agent socket/PID persistence |
| SSH config (dev) | `/home/dev/.ssh/config` | Host key checking + GitHub host block |
| SSH config (root) | `/root/.ssh/config` | No host key checking |
| GPG agent config | `/home/dev/.gnupg/gpg-agent.conf` | 8-hour cache, tty pinentry |
| GitHub setup | `/home/dev/.local/bin/setup-github` | Interactive GitHub/SSH/GPG helper |
| Workspace | `/home/dev/projects/` | Project files go here |
| ClamAV daily scan | `/etc/cron.daily/clamav-scan` | Runs at midnight |
| ClamAV scan log | `/var/log/clamav/daily-scan.log` | Daily scan results |
| rkhunter weekly scan | `/etc/cron.weekly/rkhunter-scan` | Runs weekly |
| rkhunter log | `/var/log/rkhunter-weekly.log` | Weekly scan results |
| fail2ban config | `/etc/fail2ban/jail.local` | SSH protection rules |
| Tab completion | `/home/dev/.local/share/bash-completion/completions/cc` | cc autocomplete |
| Package manifest | `/var/lib/vps-setup/installed-packages.manifest` | Packages installed by setup |
| Pre-existing packages | `/var/lib/vps-setup/pre-existing-packages.list` | Packages before first run |
| Manifest metadata | `/var/lib/vps-setup/manifest-meta.txt` | Versions, date, user |
| jdtls | `/opt/jdtls` | Eclipse JDT Language Server |
| jdtls launcher | `/usr/local/bin/jdtls` | Launcher script for jdtls |
| Miniconda | `/opt/miniconda3` | System-wide Miniconda install |

## Language Version Management

```bash
# Go — always latest (installed from go.dev tarball)
go version

# Java — Temurin 21 LTS (via apt)
java -version

# Node.js — switch versions with nvm
nvm install 22
nvm alias default 22
nvm ls

# Python — switch versions with pyenv
pyenv install 3.13
pyenv global 3.13
pyenv versions
```

## Security Quick Reference

```bash
# Manual virus scan
sudo clamscan -r -i /path/to/scan

# Rootkit check
sudo rkhunter --check

# Firewall
sudo ufw status
sudo ufw allow <port>/tcp
sudo ufw delete allow <port>/tcp

# Banned IPs
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <IP>

# Scan logs
cat /var/log/clamav/daily-scan.log
cat /var/log/rkhunter-weekly.log
```

## Reset / Uninstall

```bash
# Full reset — removes everything the setup script installed
sudo bash reset-vps-setup.sh

# What it does:
# - Prompts before proceeding (shows what will be removed)
# - Optionally deletes the dev user (asked separately)
# - Removes: Claude Code, Go, Gradle, nvm, pyenv, cc, setup-github
# - Removes: tmux config, SSH/GPG config, cron jobs
# - Disables: ufw, fail2ban, clamav
# - Purges apt packages from manifest (if available)
# - Cleans up apt repos (adoptium, github-cli)
```

## Typical Workflows

### Start a new project
```bash
mkdir ~/projects/myapp && cd ~/projects/myapp
git init
cc myapp
# Claude launches, you're coding
```

### Resume work on existing project
```bash
cc myapp
# Attaches to existing session, everything still running
```

### Autonomous coding session (YOLO)
```bash
cd ~/projects/myapp
ccy myapp
# Git checkpoint created automatically
# Claude runs with no permission prompts
# Rollback if needed: git reset --hard HEAD~1
```

### Switch between projects
```bash
cs myapp        # switch to myapp session
cs backend      # switch to backend session
cls             # see all sessions
```

### Clean up
```bash
cks myapp       # kill one session
cka             # kill everything
```

## What's NOT Installed (by design)
- **Docker** — excluded by user preference
- **Tailscale** — removed, unnecessary for personal dev
- **GUI tools** — this is a headless terminal environment
- **Web server** — no nginx/apache (add if needed: `sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`)
