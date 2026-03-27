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
# 1. Switch to dev user (tmux auto-starts + claude launches)
su - dev

# 2. Authenticate Claude Code (follow browser prompts)

# 3. Set up GitHub, SSH & GPG
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
- **tmux** — mobile-optimized (mouse, touch scroll, aggressive resize, 50k scrollback)
- **`cc` session manager** — Claude Code session management with YOLO mode

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

## Session Manager: `cc`

```
cc                  Start/attach default session + launch claude
cc <name>           Start/attach named session
cc ls               List all sessions
cc kill <name>      Kill a session
cc killall          Kill all sessions
cc yolo <name>      Launch in YOLO mode (skip all permission prompts)
cc yolo! <name>     Kill + relaunch in YOLO mode
cc safe <name>      Kill + relaunch in safe mode
cc help             Show all commands
```

### Aliases

| Alias | Expands to | Description |
|-------|-----------|-------------|
| `cls` | `cc ls` | List sessions |
| `cks` | `cc kill` | Kill a session |
| `cka` | `cc killall` | Kill all sessions |
| `ccy` | `cc yolo` | Launch YOLO |
| `ccyf` | `cc yolo!` | Force relaunch YOLO |
| `ccs` | `cc safe` | Switch to safe mode |
| `ccp <dir>` | cd + claude | Start claude in project dir |
| `ccyp <dir>` | cd + yolo claude | YOLO claude in project dir |

## Architecture

```
Developer (Termius iOS/Windows)
  ↓ SSH (port 22, protected by fail2ban)
Hostinger VPS (Ubuntu 22.04/24.04)
  ├── User: dev (no sudo, locked down)
  ├── tmux (auto-attaches on login)
  │   └── cc session manager → claude
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

## Requirements

- Ubuntu 22.04 or 24.04
- Root access (script runs as root, creates non-root `dev` user)
- SSH access to the VPS

## License

MIT
