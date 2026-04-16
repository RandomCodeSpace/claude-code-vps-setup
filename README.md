# Claude Code VPS Setup

One-command setup for a secure Hostinger VPS (Ubuntu 22.04/24.04) fully configured for [Claude Code](https://claude.ai) development.

## Quick Start

SSH into your VPS as root, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/RandomCodeSpace/claude-code-vps-setup/main/secure-vps-setup.sh | sudo bash
```

Or download and review first (recommended — it's long and does a lot):

```bash
curl -fsSL https://raw.githubusercontent.com/RandomCodeSpace/claude-code-vps-setup/main/secure-vps-setup.sh -o setup.sh
chmod +x setup.sh
sudo bash setup.sh
```

Or clone the whole repo if you want the reset script and docs alongside:

```bash
git clone https://github.com/RandomCodeSpace/claude-code-vps-setup.git
cd claude-code-vps-setup
sudo bash secure-vps-setup.sh
```

All three are safe to rerun — every install step replaces the pinned version on rerun, so upgrading is just a `git pull && sudo bash secure-vps-setup.sh`.

## Post-Install

```bash
# 1. Connect as the dev user (ssh or mosh — mosh survives roaming / flaky Wi-Fi)
ssh  dev@<vps-ip>
# mosh dev@<vps-ip>   # install mosh locally; uses your SSH key, no extra auth

# 2. Start tmux and launch Claude Code
tmux new -s claude
claude

# 3. Authenticate Claude Code (follow browser prompts)

# 4. Set up GitHub + SSH signing
setup-github

# 5. Finish ctm shell integration (one-time)
ctm install
```

`setup-github` handles everything in one interactive flow: GitHub CLI auth, git identity (pulled from your GitHub account), and SSH-based commit signing. The same ed25519 key is uploaded to GitHub as both an auth key and a signing key — GitHub supports SSH-signed commits natively, so no GPG is needed.

## What Gets Installed

### Security & Connectivity
- **ClamAV** — antivirus daemon + daily scans
- **rkhunter** — rootkit scanner + weekly scans
- **ufw** — firewall (SSH 22/tcp + mosh 60000-61000/udp)
- **fail2ban** — bans IPs after 3 failed SSH attempts
- **mosh** — mobile shell for flaky/roaming connections (uses your SSH key, no extra auth)

### Terminal
- **tmux** — mobile-optimized (mouse, touch scroll, aggressive resize, 50k scrollback, Termius tab titles)

### Languages & Tools

All versions are pinned in a single `VERSIONS` block at the top of `secure-vps-setup.sh`. Bump a variable there and rerun the script to upgrade.

- **Go** — gopls, delve, golangci-lint, air, goimports, govulncheck, [ctm](https://github.com/RandomCodeSpace/ctm) (Claude tmux session manager)
- **Java** — Temurin 25 JDK + Maven + Gradle + jdtls (Eclipse JDT Language Server)
- **Node.js** — via nvm + TypeScript, ts-node, tsx, eslint, prettier, nodemon, pnpm, yarn, typescript-language-server, npm-check-updates
- **Python** — via pyenv + ruff, mypy, black, isort, pytest, poetry, pipenv, ipython, pyright, uv, pipx, pre-commit, httpie
- **Miniconda** — system-wide at `/opt/miniconda3` (no auto-activate)
- **CLI** — ripgrep, fd, bat, jq, tree, htop, shellcheck, make, cmake, sqlite3, redis-tools, postgresql-client, gh, [rtk](https://github.com/rtk-ai/rtk) (LLM token compressor for shell output)

### Identity & Signing
- **SSH** — ed25519 keypair used for both authentication and commit signing (same key, two GitHub entries via `--type signing`)
- **Git** — identity from GitHub (no placeholders), `gpg.format ssh` + allowed-signers file, signed commits and tags enabled by default

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
  ├── setup-github (GitHub + SSH signing)
  ├── Security: ClamAV, rkhunter, ufw, fail2ban
  └── Go, Java 25, Node.js/nvm, Python/pyenv, gh
```

## Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| User | `dev` (no sudo) | Claude Code should never run as root |
| SSH key | ed25519, no passphrase | Access gated by SSH login to VPS |
| Commit signing | SSH (same ed25519 key as auth) | One key for auth + signing; GitHub supports SSH-signed commits natively |
| Git identity | From GitHub via `gh` | No placeholders, real identity only |
| Node.js | nvm | Version switching without sudo |
| Python | pyenv | Version switching without sudo |
| Docker | Not installed | Excluded by preference |
| Tailscale | Not installed | Unnecessary for personal dev |

## Upgrade

Edit the `VERSIONS` block at the top of `secure-vps-setup.sh`, bump any pin, then rerun:

```bash
sudo bash secure-vps-setup.sh
```

Every install step replaces the installed version with the pinned one — no floating `@latest` anywhere. `.bashrc` blocks use `START`/`END` markers so they're rewritten cleanly, old Gradle dirs are pruned before extract, and the package manifest in `/var/lib/vps-setup/` is refreshed.

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
