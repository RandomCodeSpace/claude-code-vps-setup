# Claude Code VPS Setup

One-command setup for a secure Hostinger VPS (Ubuntu 22.04/24.04) fully configured for [Claude Code](https://claude.ai) development.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/RandomCodeSpace/claude-code-vps-setup/main/secure-vps-setup.sh | sudo bash
```

Or download and review first:

```bash
curl -fsSL https://raw.githubusercontent.com/RandomCodeSpace/claude-code-vps-setup/main/secure-vps-setup.sh -o setup.sh
chmod +x setup.sh
sudo bash setup.sh
```

## Post-Install

```bash
# 1. Switch to dev user
su - dev

# 2. Start tmux and launch Claude Code
tmux new -s claude
claude

# 3. Authenticate Claude Code (follow browser prompts)

# 4. Set up GitHub, SSH & GPG
setup-github
```

`setup-github` handles everything in one interactive flow: GitHub CLI auth, git identity (pulled from your GitHub account), SSH key upload, GPG key generation, commit signing config, and GPG key upload to GitHub.

## What Gets Installed

### Security
- **ClamAV** — antivirus daemon + daily scans
- **rkhunter** — rootkit scanner + weekly scans
- **ufw** — firewall (only SSH port 22 open)
- **fail2ban** — bans IPs after 3 failed SSH attempts

### Terminal
- **tmux** — mobile-optimized (mouse, touch scroll, aggressive resize, 50k scrollback, Termius tab titles)

### Languages & Tools
- **Go** — latest stable + gopls, delve, golangci-lint, air
- **Java 21** — Temurin JDK + Maven + Gradle 8.12
- **Node.js** — LTS via nvm + TypeScript, tsx, pnpm, yarn, eslint, prettier
- **Python 3.12** — via pyenv + ruff, mypy, black, pytest, poetry
- **CLI** — ripgrep, fd, bat, jq, htop, shellcheck, make, cmake, gh

### Identity & Signing
- **SSH** — ed25519 keypair, agent persistence across tmux panes, GitHub host config
- **GPG** — agent with 8-hour cache, tty pinentry, commit signing enabled by default
- **Git** — identity from GitHub (no placeholders), signed commits and tags

### AI
- **Claude Code** — native installer, runs as non-root `dev` user

## Running Claude Code

Start a persistent tmux session so your work survives disconnects, then launch `claude`:

```bash
tmux new -s claude      # or: tmux attach -t claude
claude                  # safe mode
claude --dangerously-skip-permissions   # YOLO mode (skip permission prompts)
```

Detach with `Ctrl+b d`, re-attach with `tmux attach -t claude`. See `man tmux` for more.

## Architecture

```
Developer (Termius iOS/Windows)
  ↓ SSH (port 22, protected by fail2ban)
Hostinger VPS (Ubuntu 22.04/24.04)
  ├── User: dev (no sudo, locked down)
  ├── tmux (mobile-optimized) → claude
  ├── setup-github (GitHub/SSH/GPG setup)
  ├── Security: ClamAV, rkhunter, ufw, fail2ban
  └── Go, Java 21, Node.js/nvm, Python/pyenv, gh
```

## Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| User | `dev` (no sudo) | Claude Code should never run as root |
| SSH key | ed25519, no passphrase | Access gated by SSH login to VPS |
| GPG | Default-on, user-generated | Signed commits by default |
| Git identity | From GitHub via `gh` | No placeholders, real identity only |
| Node.js | nvm | Version switching without sudo |
| Python | pyenv | Version switching without sudo |
| Docker | Not installed | Excluded by preference |
| Tailscale | Not installed | Unnecessary for personal dev |

## Upgrade

Rerun the setup script to upgrade everything in place:

```bash
sudo bash secure-vps-setup.sh
```

All configs, toolchains, and packages are updated. Bashrc blocks use `START`/`END` markers so they're replaced cleanly. Old Gradle versions are removed. nvm and pyenv are updated.

## Reset / Uninstall

```bash
sudo bash reset-vps-setup.sh
```

Removes everything the setup script installed. Prompts before proceeding. Optionally deletes the `dev` user. Uses the package manifest (`/var/lib/vps-setup/`) to know which apt packages to purge.

## Requirements

- Ubuntu 22.04 or 24.04
- Root access (script runs as root, creates non-root `dev` user)
- SSH access to the VPS

## License

MIT
