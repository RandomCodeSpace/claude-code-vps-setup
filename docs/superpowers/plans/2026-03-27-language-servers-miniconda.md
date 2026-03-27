# Language Servers + Miniconda Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add language server installs (jdtls, pyright, typescript-language-server) and system-wide Miniconda to the setup/reset scripts.

**Architecture:** Each addition follows the existing script patterns — install in setup, remove in reset, update CLAUDE.md. Language servers are installed alongside their respective toolchains. Miniconda is system-wide at `/opt/miniconda3` with `conda init bash` for the dev user.

**Tech Stack:** Bash, apt, npm, pip, curl

---

### Task 1: Add `typescript-language-server` to Node.js globals

**Files:**
- Modify: `secure-vps-setup.sh:1060-1065` (npm install -g block)

- [ ] **Step 1: Add typescript-language-server to the npm install -g list**

In `secure-vps-setup.sh`, find the npm global install block (line 1060-1065) and add `typescript-language-server` to the list:

```bash
    npm install -g typescript ts-node tsx \
    eslint prettier \
    @types/node \
    nodemon \
    pnpm \
    yarn \
    typescript-language-server'
```

Note: `yarn` loses its trailing `'` and gains a `\`, and `typescript-language-server'` becomes the new last entry.

- [ ] **Step 2: Update the print_status line for Node.js**

Find line 1069:
```bash
print_status "Node.js ${NODE_VER} + TypeScript + pnpm + yarn installed (via nvm)"
```
Change to:
```bash
print_status "Node.js ${NODE_VER} + TypeScript + pnpm + yarn + ts-language-server installed (via nvm)"
```

- [ ] **Step 3: Commit**

```bash
git add secure-vps-setup.sh
git commit -m "feat: add typescript-language-server to Node.js globals"
```

---

### Task 2: Add `pyright` to Python pip packages

**Files:**
- Modify: `secure-vps-setup.sh:1106-1116` (pip install block)

- [ ] **Step 1: Add pyright to the pip install list**

In `secure-vps-setup.sh`, find the pip install block (line 1106-1116) and add `pyright`:

```bash
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
```

Note: `virtualenv` loses its trailing `'` and gains a ` \`, and `pyright'` becomes the new last entry.

- [ ] **Step 2: Update the print_status line for Python**

Find line 1119:
```bash
print_status "Python ${PYTHON_VER} + ruff, mypy, black, pytest, poetry installed (via pyenv)"
```
Change to:
```bash
print_status "Python ${PYTHON_VER} + ruff, mypy, black, pytest, poetry, pyright installed (via pyenv)"
```

- [ ] **Step 3: Commit**

```bash
git add secure-vps-setup.sh
git commit -m "feat: add pyright to Python pip packages"
```

---

### Task 3: Add `jdtls` (Eclipse JDT Language Server) install

**Files:**
- Modify: `secure-vps-setup.sh` — insert after Java section (after line 1047, before Node.js section)

- [ ] **Step 1: Add jdtls download and install block**

Insert after the `print_status "Java 21 (Temurin) + Maven + Gradle..."` line (line 1047), before the Node.js section comment:

```bash

# ── Eclipse JDT Language Server (jdtls) ──────────────────
print_status "Installing Eclipse JDT Language Server (jdtls)..."
JDTLS_VERSION=$(curl -fsSL "https://download.eclipse.org/jdtls/milestones/" | grep -oP 'href="\K[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
if [ -z "$JDTLS_VERSION" ]; then
    # Fallback version if scraping fails
    JDTLS_VERSION="1.43.0"
    print_warning "Could not detect latest jdtls version, using fallback ${JDTLS_VERSION}"
fi
JDTLS_TIMESTAMP=$(curl -fsSL "https://download.eclipse.org/jdtls/milestones/${JDTLS_VERSION}/" | grep -oP 'jdt-language-server-\K[0-9]+' | sort -n | tail -1)
JDTLS_URL="https://download.eclipse.org/jdtls/milestones/${JDTLS_VERSION}/jdt-language-server-${JDTLS_TIMESTAMP}.tar.gz"
curl -fsSL "$JDTLS_URL" -o /tmp/jdtls.tar.gz
rm -rf /opt/jdtls
mkdir -p /opt/jdtls
tar -xzf /tmp/jdtls.tar.gz -C /opt/jdtls
rm /tmp/jdtls.tar.gz

# Create launcher script
cat > /usr/local/bin/jdtls << 'JDTLS_LAUNCHER'
#!/bin/bash
# Eclipse JDT Language Server launcher
JDTLS_HOME="/opt/jdtls"
WORKSPACE="${1:-$HOME/.cache/jdtls-workspace}"
java \
    -Declipse.application=org.eclipse.jdt.ls.core.id1 \
    -Dosgi.bundles.defaultStartLevel=4 \
    -Declipse.product=org.eclipse.jdt.ls.core.product \
    -Dlog.level=ALL \
    -noverify \
    -Xmx1G \
    --add-modules=ALL-SYSTEM \
    --add-opens java.base/java.util=ALL-UNNAMED \
    --add-opens java.base/java.lang=ALL-UNNAMED \
    -jar "$JDTLS_HOME"/plugins/org.eclipse.equinox.launcher_*.jar \
    -configuration "$JDTLS_HOME/config_linux" \
    -data "$WORKSPACE"
JDTLS_LAUNCHER
chmod +x /usr/local/bin/jdtls

print_status "Eclipse JDT Language Server ${JDTLS_VERSION} installed (/opt/jdtls)"
```

- [ ] **Step 2: Commit**

```bash
git add secure-vps-setup.sh
git commit -m "feat: add jdtls (Eclipse JDT Language Server) install"
```

---

### Task 4: Add Miniconda system-wide install

**Files:**
- Modify: `secure-vps-setup.sh` — insert after Python section (after line 1119), before CLI tools section

- [ ] **Step 1: Add Miniconda install block**

Insert after the Python `print_status` line (line 1119), before the `# ── Common CLI tools` comment:

```bash

# ── Miniconda (system-wide at /opt/miniconda3) ──────────
print_status "Installing Miniconda (system-wide)..."
MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
curl -fsSL "$MINICONDA_URL" -o /tmp/miniconda.sh
bash /tmp/miniconda.sh -b -u -p /opt/miniconda3
rm /tmp/miniconda.sh

# Make conda available to all users
ln -sf /opt/miniconda3/bin/conda /usr/local/bin/conda

# Initialize conda for dev user (adds shell hook to .bashrc)
su - "$DEV_USER" -c '/opt/miniconda3/bin/conda init bash'

# Disable auto-activate base — user must explicitly activate envs
su - "$DEV_USER" -c '/opt/miniconda3/bin/conda config --set auto_activate_base false'

print_status "Miniconda installed at /opt/miniconda3 (auto_activate_base=false)"
```

- [ ] **Step 2: Commit**

```bash
git add secure-vps-setup.sh
git commit -m "feat: add system-wide Miniconda install"
```

---

### Task 5: Update reset script — add jdtls removal

**Files:**
- Modify: `reset-vps-setup.sh` — add section after Gradle removal (after line 121)

- [ ] **Step 1: Add jdtls removal block**

Insert after the Gradle removal section (after line 121), before the nvm section:

```bash

# ============================================================
# 6b. jdtls
# ============================================================
print_status "Removing jdtls..."
rm -rf /opt/jdtls 2>/dev/null || true
rm -f /usr/local/bin/jdtls 2>/dev/null || true
```

- [ ] **Step 2: Add jdtls to the "This will remove" list**

Find line 41:
```bash
echo "  - Gradle (/opt/gradle-*)"
```
Add after it:
```bash
echo "  - jdtls (/opt/jdtls)"
```

- [ ] **Step 3: Commit**

```bash
git add reset-vps-setup.sh
git commit -m "feat: add jdtls removal to reset script"
```

---

### Task 6: Update reset script — add Miniconda removal

**Files:**
- Modify: `reset-vps-setup.sh` — add section after pyenv removal (after line 136)

- [ ] **Step 1: Add Miniconda removal block**

Insert after the pyenv removal section (after line 136), before the cc + setup-github section:

```bash

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
```

- [ ] **Step 2: Add Miniconda to the "This will remove" list**

Find line 42 (or after the jdtls line added in Task 5):
```bash
echo "  - nvm (~/.nvm)"
```
Add before it:
```bash
echo "  - Miniconda (/opt/miniconda3)"
```

- [ ] **Step 3: Commit**

```bash
git add reset-vps-setup.sh
git commit -m "feat: add Miniconda removal to reset script"
```

---

### Task 7: Update summary output and CLAUDE.md

**Files:**
- Modify: `secure-vps-setup.sh:1197-1203` (summary DEV TOOLCHAINS block)
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the setup script summary output**

Find the DEV TOOLCHAINS summary section (around line 1197-1203) and update to include language servers and Miniconda:

```bash
echo "  DEV TOOLCHAINS"
echo "  ─────────────────────────────────────────"
echo "  Go         : /usr/local/go  (go, gopls, dlv, air)"
echo "  Java       : Temurin 21     (maven, gradle, jdtls)"
echo "  Node.js    : via nvm        (ts, tsx, pnpm, yarn, ts-language-server)"
echo "  Python     : via pyenv 3.12 (ruff, mypy, pytest, poetry, pyright)"
echo "  Miniconda  : /opt/miniconda3 (conda, auto_activate_base=false)"
echo "  Extras     : ripgrep, fd, bat, jq, htop, shellcheck"
```

- [ ] **Step 2: Update the "Language tools" section in the summary**

Find the "Language tools" section (around line 1282) and add after the Python entries:

```bash
echo "  Conda envs         : conda create -n myenv python=3.12"
echo "  Activate env       : conda activate myenv"
```

- [ ] **Step 3: Update CLAUDE.md architecture diagram**

In the Architecture section, update the `Dev Toolchains` block to include language servers and Miniconda. Under `Languages`, add LSP entries, and add a new Miniconda line.

- [ ] **Step 4: Update CLAUDE.md "What It Installs" section**

Add jdtls, pyright, typescript-language-server, and Miniconda to the appropriate numbered items. Add a new item for Miniconda.

- [ ] **Step 5: Update CLAUDE.md decisions table**

Add a row for Miniconda and language servers.

- [ ] **Step 6: Update CLAUDE.md file locations table**

Add entries for jdtls and Miniconda.

- [ ] **Step 7: Update the header comment in secure-vps-setup.sh**

Update lines 4-10 to mention language servers and Miniconda.

- [ ] **Step 8: Update manifest metadata**

Find the METAMANIFEST block (around line 1154-1161) and add:
```bash
JDTLS_VERSION=${JDTLS_VERSION:-unknown}
MINICONDA=system-wide
```

- [ ] **Step 9: Commit**

```bash
git add secure-vps-setup.sh reset-vps-setup.sh CLAUDE.md
git commit -m "docs: update summary, CLAUDE.md for language servers and Miniconda"
```
