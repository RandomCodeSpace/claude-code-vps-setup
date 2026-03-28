# Windows SSHFS Mount — Design Spec

## Problem

Need to browse and edit VPS files from Windows using local tools (Explorer, VS Code, etc.). Currently the only access is via SSH terminal (Termius) or SFTP.

## Solution

Mount the full VPS filesystem (`/`) as drive `V:` on Windows using SSHFS-Win + WinFsp.

## Components

| Component | Purpose | Source |
|-----------|---------|--------|
| WinFsp | Windows kernel driver for userspace filesystems | https://github.com/winfsp/winfsp/releases |
| SSHFS-Win | SSHFS client built on WinFsp | https://github.com/winfsp/sshfs-win/releases |

## Configuration

- **VPS host:** Hostinger VPS (SSH on port 22)
- **Auth:** SSH key (`id_ed25519`, no passphrase)
- **User:** `dev`
- **Mount point:** `V:` drive
- **Remote path:** `/` (full filesystem)
- **Permissions:** Same as `dev` user — read/write to `/home/dev`, read-only elsewhere

## Setup Steps (Windows)

### 1. Install WinFsp

Download and run the latest `.msi` from the WinFsp GitHub releases page. Use default settings.

### 2. Install SSHFS-Win

Download and run the latest `.msi` from the SSHFS-Win GitHub releases page. Use default settings.

### 3. Map Network Drive

In Windows Explorer:
1. Right-click "This PC" > "Map network drive"
2. Drive: `V:`
3. Folder: `\\sshfs.r\dev@<VPS-IP>\`
   - `sshfs.r` = SSHFS with "raw" path mode (maps `/` as root)
   - Replace `<VPS-IP>` with actual VPS IP address
4. Check "Reconnect at sign-in" for auto-mount
5. Click Finish

The `.r` variant maps paths starting from `/`. Without `.r`, it maps from the user's home directory.

### Alternative: Command Line

```cmd
net use V: \\sshfs.r\dev@<VPS-IP>\ /persistent:yes
```

### 4. SSH Key Setup

SSHFS-Win uses the SSH key from `%USERPROFILE%\.ssh\id_ed25519`. If your Windows SSH key differs from the VPS key, copy the VPS-authorized private key to that location, or add the Windows key to `~/.ssh/authorized_keys` on the VPS.

## Behavior

- File operations go over SSH — expect network latency on large operations
- Drive disconnects if SSH drops; reconnects automatically on next access
- File watchers (VS Code, etc.) work but generate SSH traffic
- No VPS-side changes required — existing SSH config and `dev` user are sufficient

## Limitations

- No sudo access from Windows (same as terminal — `dev` has no sudo)
- Binary/large file operations will be slow over network
- Windows file locking semantics differ from Unix — avoid editing the same file from both Windows and VPS terminal simultaneously

## No VPS Changes

This is a Windows-only setup. The VPS already has:
- SSH on port 22 (allowed through ufw)
- `dev` user with SSH key auth
- No additional firewall rules or server software needed
