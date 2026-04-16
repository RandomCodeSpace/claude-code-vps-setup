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
- **ufw** — firewall (SSH 22/tcp, mosh 60000-61000/udp, HTTP 80/tcp, HTTPS 443/tcp for Caddy)
- **fail2ban** — bans IPs after 3 failed SSH attempts
- **mosh** — mobile shell for flaky/roaming connections (uses your SSH key, no extra auth)

### Terminal
- **tmux** — mobile-optimized (mouse, touch scroll, aggressive resize, 50k scrollback, Termius tab titles)

### Languages & Tools

All versions are pinned in a single `VERSIONS` block at the top of `secure-vps-setup.sh`. Bump a variable there and rerun the script to upgrade.

- **Go** — gopls, delve, golangci-lint, air, goimports, govulncheck, [ctm](https://github.com/RandomCodeSpace/ctm) (Claude tmux session manager)
- **Java** — Temurin 25 JDK + Maven + Gradle + jdtls (Eclipse JDT Language Server)
- **Node.js** — via nvm + TypeScript, ts-node, tsx, eslint, prettier, nodemon, pnpm, yarn, typescript-language-server, npm-check-updates, [bun](https://bun.sh) (alt JS runtime + package manager)
- **Python** — via pyenv + ruff, mypy, black, isort, pytest, poetry, pipenv, ipython, pyright, uv, pipx, pre-commit, httpie
- **Miniconda** — system-wide at `/opt/miniconda3` (no auto-activate)
- **.NET 10 LTS** — installed via Microsoft's `dotnet-install.sh` to `/usr/share/dotnet` and symlinked at `/usr/local/bin/dotnet` (works on both 22.04 and 24.04 — Microsoft's jammy apt feed doesn't ship 10.0 yet)
- **PowerShell** — `pwsh` 7.x via Microsoft's apt repo
- **Caddy** — auto-HTTPS reverse proxy / web server (Cloudsmith's stable apt repo). Edit `/etc/caddy/Caddyfile` + `systemctl reload caddy` to serve a site — Caddy handles Let's Encrypt certs automatically, no certbot needed
- **CLI** — ripgrep, fd, bat, jq, tree, htop, shellcheck, make, cmake, sqlite3, redis-tools, postgresql-client, gh
- **Claude Code productivity** — [rtk](https://github.com/rtk-ai/rtk) (LLM token compressor), fzf (fuzzy finder), yq, git-delta (colored diffs), zoxide (`z` dir jumping), direnv, tldr, entr

### Shell customization

Both `/root/.bashrc` and `/home/dev/.bashrc` get:
- **PS1** showing `user@<fqdn>:cwd$` (FQDN resolved once per shell)
- Common aliases (`ll`, `la`, `gs`, `gl`, `gd`, `gc`, `gp`, `..`, `rebash`, etc.)
- Tool integrations (fzf key-bindings, zoxide init, direnv hook, git-delta as default pager)

Root additionally gets Go PATH + `JAVA_HOME` + conda shell hook so troubleshooting as root can use the language runtimes. nvm/pyenv/bun remain dev-only by design (per-user installs).

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
Hostinger VPS (Ubuntu 22.04/24.04, amd64)
  ├── User: dev (no sudo, SSH-key only, password locked)
  ├── Connectivity: SSH (22/tcp) + mosh (60000-61000/udp)
  ├── tmux (mobile-optimized) → claude
  ├── setup-github (GitHub + SSH commit signing)
  ├── Security: ClamAV, rkhunter, ufw, fail2ban
  └── Toolchains:
       Go 1.26, Java 25, Node 24, Python 3.14, bun, .NET 10 LTS,
       PowerShell 7, Miniconda, rtk, ctm, gh
```

## Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| OS / arch | Ubuntu 22.04 / 24.04, amd64 | All major VPS providers default here |
| User | `dev` (no sudo, password locked) | Claude Code should never run as root |
| Auth | SSH key only | Password login disabled; access gated by SSH login to VPS |
| Remote shell | SSH + mosh | mosh survives roaming / flaky Wi-Fi; both use the same key |
| Commit signing | SSH (same ed25519 key as auth) | One key for auth + signing; GitHub supports SSH-signed commits natively |
| Git identity | From GitHub via `gh` | No placeholders, real identity only |
| Versions | All pinned in `VERSIONS` block | Reproducible installs; bump-and-rerun upgrade path |
| Node.js | nvm (per-user) | Version switching without sudo |
| Python | pyenv (per-user) | Version switching without sudo |
| uv | Standalone installer, not pip | Decouples uv from any specific Python |
| .NET | `dotnet-install.sh --channel 10.0` | Works on 22.04 + 24.04; Microsoft's jammy apt repo doesn't have 10.0 yet |
| Docker | Not installed | Excluded by preference |

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
