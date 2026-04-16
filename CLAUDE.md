# VPS Setup Project — Claude Code Development Environment

## What This Is
A secure Hostinger VPS (Ubuntu 22.04/24.04) fully configured for Claude Code development, accessible from Termius on iOS and Windows. Everything runs under a locked-down non-root `dev` user.

## Architecture

```
Developer (Termius iOS/Windows)
  ↓ SSH (22/tcp) or mosh (UDP 60000-61000), SSH protected by fail2ban
Hostinger VPS (Ubuntu 22.04/24.04, amd64)
  ├── User: dev (no sudo, SSH-key only, password locked)
  ├── tmux (mobile-optimized, Termius tab titles)
  ├── Claude Code (native installer, runs as dev)
  ├── Security
  │   ├── ClamAV (antivirus, daily scans)
  │   ├── rkhunter (rootkit scanner, weekly scans)
  │   ├── ufw (firewall: SSH + mosh only)
  │   ├── fail2ban (bans after 3 failed SSH attempts)
  │   └── mosh (mobile shell, reuses SSH key auth)
  ├── setup-github (interactive GitHub + SSH signing helper)
  ├── Shell (root + dev both): PS1 user@<fqdn>, common aliases,
  │                           fzf/zoxide/direnv/git-delta integrations
  └── Dev Toolchains (all pinned in VERSIONS block)
      ├── Go 1.26 + gopls, dlv, golangci-lint, air, goimports, govulncheck, ctm
      ├── Java 25 Temurin + maven, gradle 9.4, jdtls
      ├── Node 24 LTS via nvm + typescript, ts-node, tsx, pnpm, yarn,
      │                   eslint, prettier, nodemon, ts-language-server,
      │                   @types/node, npm-check-updates
      ├── Bun 1.3 (per-user at ~/.bun)
      ├── Python 3.14 via pyenv + ruff, mypy, black, isort, pytest,
      │                   httpie, poetry, pipenv, ipython, virtualenv,
      │                   pyright, pipx, pre-commit
      ├── uv (standalone binary, not via pip — Astral's install.sh)
      ├── .NET 10 LTS (dotnet-install.sh → /usr/share/dotnet, system-wide)
      ├── PowerShell 7 (via Microsoft apt)
      ├── Miniconda (system-wide, /opt/miniconda3)
      ├── rtk (Rust Token Killer, apt .deb)
      ├── GitHub CLI (gh)
      └── CLI tools (ripgrep, fd, bat, jq, tree, htop, shellcheck,
                     make, cmake, sqlite3, redis-tools,
                     postgresql-client, inotify-tools,
                     fzf, yq, git-delta, zoxide, direnv, tldr, entr)
```

## Decisions Made

| Decision | Choice | Reason |
|----------|--------|--------|
| OS | Ubuntu 22.04/24.04 | Primary distro Anthropic tests Claude Code against |
| User | `dev` (no sudo) | Security — Claude Code should never run as root |
| Antivirus | ClamAV + rkhunter | Free, open source, no paid tiers, no telemetry |
| Firewall | ufw + fail2ban | Free, built into Ubuntu |
| Networking | SSH (22/tcp) + mosh (UDP 60000-61000) | mosh survives roaming / flaky Wi-Fi; both reuse the same SSH key |
| Terminal | tmux | Session persistence for mobile |
| Docker | NOT installed | User preference — explicitly excluded |
| Node.js | nvm (not system) | Version switching without sudo |
| Python | pyenv (not system) | Version switching without sudo |
| Java | Temurin 25 LTS | Free, open source JDK from Adoptium |
| Known hosts | Disabled | Both root and dev — no SSH prompts |
| SSH key | ed25519 (no passphrase) | Access already gated by SSH login to VPS |
| Commit signing | SSH (same ed25519 key as auth) | One key for auth + signing; GitHub supports SSH-signed commits natively, no GPG needed |
| Git identity | From GitHub (no placeholders) | Set by `setup-github` via `gh api user` |
| Language servers | gopls, jdtls, pyright, ts-language-server | Full LSP support for Go, Java, Python, TypeScript |
| Miniconda | System-wide (/opt/miniconda3) | Conda envs without conflicting with pyenv; no auto-activate |

## Script: secure-vps-setup.sh

### What It Installs (in order)
1. **Unattended hardening** — sets `DEBIAN_FRONTEND=noninteractive`, `DEBIAN_PRIORITY=critical`, writes `/etc/needrestart/conf.d/99-vps-setup.conf` so apt upgrades don't pop the "which services to restart?" TUI
2. **User `dev`** — non-root, no sudo, SSH keys copied from root, ed25519 keypair generated, password locked (`passwd -l`), workspace at `/home/dev/projects`
3. **SSH config** — `StrictHostKeyChecking no` for both root and dev, GitHub host block for dev
4. **ClamAV** — antivirus daemon + daily cron scan of /home, /tmp, /var/www
5. **rkhunter** — rootkit scanner + weekly cron scan
6. **ufw** — firewall: SSH (22/tcp) + mosh (60000-61000/udp), everything else denied, `--force enable`
7. **fail2ban** — bans IPs after 3 failed SSH attempts for 1 hour
8. **mosh** — mobile shell (apt); ensures a UTF-8 locale is generated
9. **tmux** — mobile-optimized config (mouse on, touch scroll, high-contrast status bar, aggressive resize, Termius tab titles)
10. **`setup-github`** — interactive helper: GitHub auth, git identity, SSH key upload (auth + signing), SSH-based commit signing
11. **ssh-agent** — auto-starts in `.bashrc`, persists across tmux panes via `~/.ssh/agent-env`
12. **Build essentials + productivity CLI tools** — `build-essential`, `pkg-config`, `libssl-dev`, `unzip`, `zip`, `jq`, `tree`, `htop`, `ripgrep`, `fd-find`, `bat`, **`fzf`, `yq`, `git-delta`, `zoxide`, `direnv`, `tldr`, `entr`**
13. **Go 1.26** — official tarball + gopls, delve, golangci-lint (v2), air, goimports, govulncheck, [ctm](https://github.com/RandomCodeSpace/ctm) (Claude tmux session manager)
14. **Java 25** — Temurin JDK + Maven + Gradle 9.4 + jdtls 1.58 (Eclipse JDT Language Server)
15. **Node 24 LTS** — via nvm + TypeScript, ts-node, tsx, eslint, prettier, nodemon, pnpm, yarn, `@types/node`, typescript-language-server, npm-check-updates
16. **Bun 1.3** — Oven's JS runtime + package manager, installed per-user at `~/.bun`
17. **Python 3.14** — via pyenv + ruff, mypy, black, isort, pytest, httpie, poetry, pipenv, ipython, virtualenv, pyright, pipx, pre-commit
18. **uv** — standalone binary via Astral's `install.sh` (pinned via URL path), lands at `~/.local/bin/uv`
19. **Miniconda** — system-wide at `/opt/miniconda3`, conda init for dev user, `auto_activate_base=false`
20. **CLI + dev services** — `shellcheck`, `make`, `cmake`, `sqlite3`, `redis-tools`, `postgresql-client`, `inotify-tools`
21. **rtk** — Rust Token Killer, upstream .deb (`apt install ./file.deb` so deps auto-resolve)
22. **GitHub CLI** — gh
23. **.NET 10 LTS** — via `dotnet-install.sh --channel 10.0` → `/usr/share/dotnet`, symlinked system-wide
24. **PowerShell 7** — via Microsoft's apt repo (added alongside the .NET install step)
25. **Shell customization** — PS1 (`user@<fqdn>:cwd`), common aliases, fzf/zoxide/direnv/git-delta integrations — written to BOTH `/root/.bashrc` and `/home/dev/.bashrc`; root additionally gets Go PATH, `JAVA_HOME`, `DOTNET_ROOT`, and the conda shell hook
26. **Claude Code** — native installer, installed for dev user

### Upgrade-by-Rerun
Script is safe to rerun and **updates everything on rerun**:
- All `.bashrc` blocks use `START`/`END` markers — `sed` deletes then re-appends fresh
- Legacy single-marker `.bashrc` format auto-migrates on first rerun
- nvm installer is idempotent — always runs to pick up updates
- pyenv runs `pyenv update` if already installed, fresh install otherwise
- GitHub CLI repo is always added — `apt install` handles upgrades
- Root SSH config is always overwritten
- Old Gradle versions are cleaned up before extracting new
- `pyenv install -s` skips if Python version already installed
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
# 1. Connect as the dev user (mosh or ssh — both use the key copied from root)
ssh  dev@<vps-ip>
# mosh dev@<vps-ip>      # install mosh locally first; survives roaming

# 2. Start tmux and launch Claude Code
tmux new -s claude
claude

# 3. Authenticate Claude Code (first time only — follow browser prompts)

# 4. Set up GitHub + SSH signing (interactive — gh auth, SSH key upload, commit signing)
setup-github

# 5. Finish ctm (Claude Tmux Manager) shell integration (one-time)
ctm install

# 6. (Optional) Disable root SSH once dev access confirmed
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

## GitHub Setup: `setup-github`

Interactive post-install helper that configures GitHub access in one command. Run once after provisioning, safe to rerun.

### What It Does (in order)
1. **GitHub auth** — checks `gh auth status`, runs `gh auth login --git-protocol ssh --web --scopes admin:public_key,admin:ssh_signing_key` if needed (refreshes to add signing-key scope if missing)
2. **Git identity** — prompts for name/email (pulls defaults from GitHub), updates `git config --global`
3. **SSH auth key upload** — uploads `~/.ssh/id_ed25519.pub` via `gh ssh-key add` (skips if already there)
4. **SSH signing key upload** — uploads the same key a second time via `gh ssh-key add --type signing` (GitHub stores auth and signing keys separately even when the content matches)
5. **Git SSH signing config** — sets `gpg.format ssh`, `user.signingkey=~/.ssh/id_ed25519.pub`, `commit.gpgsign=true`, `tag.gpgsign=true`
6. **Allowed signers file** — writes `~/.ssh/allowed_signers` and points `gpg.ssh.allowedSignersFile` at it so `git log --show-signature` can verify locally
7. **Verify** — prints summary, tests `ssh -T git@github.com`

No GPG involved. Same ed25519 key is used for SSH auth, git push, and commit signing.

### Usage
```bash
setup-github
```

## Running Claude Code

Start a persistent tmux session, then launch `claude`:

```bash
tmux new -s claude          # or: tmux attach -t claude
claude                      # safe mode (permission prompts on)
claude --dangerously-skip-permissions   # YOLO mode
```

- Detach without killing: `Ctrl+b d` (then `tmux attach -t claude` to return)
- List/switch sessions: `Ctrl+b s`
- Multiple projects: pick any session name, e.g. `tmux new -s myapp`
- Before YOLO, make a git checkpoint manually: `git add -A && git commit --allow-empty -m checkpoint`

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
- **No forced auto-attach** — SSH gives a plain shell, run `tmux` manually
- **Tab titles** — Termius tabs show session name + username (e.g. "myapp - dev")

## File Locations

| File | Location | Purpose |
|------|----------|---------|
| Setup script | `./secure-vps-setup.sh` | Main installer (safe to rerun for upgrades) |
| Reset script | `./reset-vps-setup.sh` | Uninstall everything |
| tmux config | `/home/dev/.tmux.conf` | Mobile-optimized tmux |
| SSH keypair | `/home/dev/.ssh/id_ed25519` | Dev user's ed25519 key (auth + commit signing) |
| SSH agent env | `/home/dev/.ssh/agent-env` | ssh-agent socket/PID persistence |
| SSH config (dev) | `/home/dev/.ssh/config` | Host key checking + GitHub host block |
| SSH config (root) | `/root/.ssh/config` | No host key checking |
| Allowed signers | `/home/dev/.ssh/allowed_signers` | Local verification of SSH-signed commits |
| GitHub setup | `/home/dev/.local/bin/setup-github` | Interactive GitHub + SSH signing helper |
| Workspace | `/home/dev/projects/` | Project files go here |
| ClamAV daily scan | `/etc/cron.daily/clamav-scan` | Runs at midnight |
| ClamAV scan log | `/var/log/clamav/daily-scan.log` | Daily scan results |
| rkhunter weekly scan | `/etc/cron.weekly/rkhunter-scan` | Runs weekly |
| rkhunter log | `/var/log/rkhunter-weekly.log` | Weekly scan results |
| fail2ban config | `/etc/fail2ban/jail.local` | SSH protection rules |
| Package manifest | `/var/lib/vps-setup/installed-packages.manifest` | Packages installed by setup |
| Pre-existing packages | `/var/lib/vps-setup/pre-existing-packages.list` | Packages before first run |
| Manifest metadata | `/var/lib/vps-setup/manifest-meta.txt` | Versions, date, user |
| Miniconda | `/opt/miniconda3` | System-wide Miniconda install |
| jdtls | `/opt/jdtls` | Eclipse JDT Language Server for Java |

## Language Version Management

```bash
# Go — always latest (installed from go.dev tarball)
go version

# Java — Temurin 25 LTS (via apt)
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
# - Removes: Claude Code, Go, Gradle, nvm, pyenv, setup-github
# - Removes: tmux config, SSH config, cron jobs
# - Disables: ufw, fail2ban, clamav
# - Purges apt packages from manifest (if available)
# - Cleans up apt repos (adoptium, github-cli)
```

## Typical Workflows

### Start a new project
```bash
mkdir ~/projects/myapp && cd ~/projects/myapp
git init
tmux new -s myapp
claude
```

### Resume work on existing project
```bash
tmux attach -t myapp
# Session still running with Claude where you left it
```

### Autonomous coding session (YOLO)
```bash
cd ~/projects/myapp
# Manual git checkpoint first:
git add -A && git commit --allow-empty -m "checkpoint: pre-yolo"
tmux new -s myapp
claude --dangerously-skip-permissions
# Rollback if needed: git reset --hard HEAD~1
```

### Switch between projects
```bash
# From inside tmux: Ctrl+b s → pick a session
# Or from a fresh shell:
tmux attach -t backend
tmux ls               # see all sessions
```

### Clean up
```bash
tmux kill-session -t myapp    # kill one session
tmux kill-server              # kill everything
```

## What's NOT Installed (by design)
- **Docker** — excluded by user preference
- **Tailscale** — removed, unnecessary for personal dev
- **GUI tools** — this is a headless terminal environment
- **Web server** — no nginx/apache (add if needed: `sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`)
