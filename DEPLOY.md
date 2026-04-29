# Deployment Guide

This guide explains how to deploy gatekeeper to your OpenWrt router.

## Quick Start

### 1. Make the deployment script executable (first time only)

```bash
chmod +x deploy.sh
```

### 2. Deploy to your router

Basic deployment (will prompt for SSH password if needed):

```bash
./deploy.sh 192.168.1.1
```

Or using hostname:

```bash
./deploy.sh router.local
```

### 3. Configure Telegram credentials on router

After deployment, SSH to your router and configure:

```bash
ssh root@192.168.1.1

# Configure bot token and chat ID
uci set gatekeeper.main.token='YOUR_TELEGRAM_BOT_TOKEN'
uci set gatekeeper.main.chat_id='YOUR_CHAT_ID'
uci commit gatekeeper

# Restart bot service
/etc/init.d/tg_gatekeeper restart
```

### 4. Test

Send "STATUS" to your Telegram bot to verify it's working.

---

## Deployment Options

### Dry Run (see what would be deployed without making changes)

```bash
./deploy.sh 192.168.1.1 --dry-run
```

### Deploy without restarting services

Useful if you want to restart manually later:

```bash
./deploy.sh 192.168.1.1 --no-restart
```

### Deploy only configuration file

```bash
./deploy.sh 192.168.1.1 --config-only
```

### Deploy only scripts (no config, no init scripts)

Useful for quick updates during development:

```bash
./deploy.sh 192.168.1.1 --scripts-only
```

### Deploy everything except the configuration file

Deploys scripts, firewall rules, and init scripts while preserving the existing `/etc/config/gatekeeper` on the router (e.g. to avoid overwriting credentials or custom settings):

```bash
./deploy.sh 192.168.1.1 --no-config
```

### Deploy LuCI app alongside the runtime

Deploys the runtime package AND the `luci-app-gatekeeper` files (rpcd backend, ACL, menu manifest, frontend views), then restarts `rpcd` so it discovers the new plugin:

```bash
./deploy.sh 192.168.1.1 --luci
```

### Deploy ONLY the LuCI app (skip the runtime)

Useful when iterating on the rpcd backend or frontend JS without touching the bot:

```bash
./deploy.sh 192.168.1.1 --luci-only
```

This skips all runtime files (scripts, firewall, init, config) and only restarts `rpcd`, not the bot or trigger listener.

### Type the router password once per run

If you haven't set up SSH key auth, every `ssh`/`scp` call prompts for the password. The `--ask-password` flag prompts once at the start and reuses that password for every call in the run. Combine with any other flags.

```bash
./deploy.sh 192.168.1.1 --ask-password           # prompts once, full deploy
./deploy.sh 192.168.1.1 --luci --ask-password    # works alongside other flags
```

Requires `sshpass`:
- macOS: `brew install hudochenkov/sshpass/sshpass`
- Debian/Ubuntu: `apt-get install sshpass`

The password is held in the script's `SSHPASS` env var only — it never appears in argv (so `ps aux` and shell history stay clean). For unattended/automated runs, prefer SSH keys (`ssh-copy-id root@<router>`) over a password — `--ask-password` is for interactive use.

---

## What Gets Deployed

### Scripts (`/usr/bin/`)
- `gatekeeper.sh` - Main approval handler
- `tg_bot.sh` - Telegram bot daemon
- `gatekeeper_trigger.sh` - Ubus event listener
- `dnsmasq_trigger.sh` - DHCP event bridge
- `gatekeeper_sync.sh` - Manual sync utility

### Shared Library (`/usr/lib/gatekeeper/`)
- `restore_helpers.sh` - Sourced by `tg_bot.sh` and (when installed) the LuCI rpcd backend; canonical home of `mac_hostname`, `is_valid_backup`, the BACKUP/RESTORE parser, and the merge engine

### Firewall Rules (`/etc/gatekeeper/`)
- `gatekeeper.nft` - nftables rules and set definitions

### Init Scripts (`/etc/init.d/`)
- `gatekeeper_init` - Static/blacklist MAC sync at boot
- `tg_gatekeeper` - Bot daemon manager
- `gatekeeper_trigger_listener` - Ubus listener daemon

### Configuration (`/etc/config/`)
- `gatekeeper` - UCI configuration file

---

## LuCI Web UI install (optional)

The runtime `gatekeeper` package handles only the bot + firewall. A separate sibling package, **`luci-app-gatekeeper`**, provides a complete browser-based admin interface that runs alongside (or instead of) the Telegram bot.

### Install on the router

```bash
# Copy the LuCI ipk over (or download from a tagged GitHub release).
# Substitute <version> with the actual version baked into the file you downloaded
# (e.g. 1.0.0-1, 1.2.3-1).
scp luci-app-gatekeeper_<version>_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/luci-app-gatekeeper_<version>_all.ipk"
```

Both `.ipk` files are produced by the project's GitHub Actions workflow on every push to `main` and on every tag. They're attached to GitHub Releases automatically — see `https://github.com/<owner>/gale-gatekeeper/releases`.

### Access

```
http://<router-ip>/cgi-bin/luci → Services → Gatekeeper
```

Auth uses your router's standard LuCI admin credentials.

### What gets installed

| Path | Purpose |
|------|---------|
| `/usr/libexec/rpcd/gatekeeper` | rpcd ubus backend (POSIX shell) |
| `/usr/share/luci/menu.d/luci-app-gatekeeper.json` | LuCI menu manifest |
| `/usr/share/rpcd/acl.d/luci-app-gatekeeper.json` | RBAC ACL definitions |
| `/www/luci-static/resources/view/gatekeeper/*.js` | 6 LuCI frontend views |

### Removing

```bash
opkg remove luci-app-gatekeeper
```

The runtime gatekeeper package is unaffected — the bot keeps working.

---

## SSH Setup

### Using SSH Keys (Recommended)

For password-less deployment, set up SSH key authentication:

```bash
# Generate SSH key if you don't have one
ssh-keygen -t ed25519

# Copy key to router
ssh-copy-id root@192.168.1.1
```

### Using Password Authentication

If SSH keys are not configured, you'll be prompted for the root password during deployment.

---

## Manual Deployment

If you prefer to deploy manually or the script doesn't work for your setup:

### 1. Copy files to router

```bash
# Scripts
scp gatekeeper.sh root@192.168.1.1:/usr/bin/
scp tg_bot.sh root@192.168.1.1:/usr/bin/
scp gatekeeper_trigger.sh root@192.168.1.1:/usr/bin/
scp dnsmasq_trigger.sh root@192.168.1.1:/usr/bin/
scp gatekeeper_sync.sh root@192.168.1.1:/usr/bin/

# Shared library (sourced by tg_bot.sh AND the LuCI rpcd backend)
# Skipping this leaves the bot non-functional — it sources this file at startup.
ssh root@192.168.1.1 "mkdir -p /usr/lib/gatekeeper"
scp opkg/usr/lib/gatekeeper/restore_helpers.sh root@192.168.1.1:/usr/lib/gatekeeper/

# Firewall rules
ssh root@192.168.1.1 "mkdir -p /etc/gatekeeper"
scp gatekeeper.nft root@192.168.1.1:/etc/gatekeeper/

# Init scripts
scp gatekeeper_init root@192.168.1.1:/etc/init.d/
scp tg_gatekeeper root@192.168.1.1:/etc/init.d/
scp gatekeeper_trigger_listener root@192.168.1.1:/etc/init.d/

# Configuration
scp opkg/etc/config/gatekeeper root@192.168.1.1:/etc/config/
```

### 2. Set permissions on router

```bash
ssh root@192.168.1.1 << 'EOF'
# Make scripts executable
chmod +x /usr/bin/gatekeeper.sh
chmod +x /usr/bin/tg_bot.sh
chmod +x /usr/bin/gatekeeper_trigger.sh
chmod +x /usr/bin/dnsmasq_trigger.sh
chmod +x /usr/bin/gatekeeper_sync.sh
chmod +x /etc/gatekeeper/gatekeeper.nft

# Make init scripts executable
chmod +x /etc/init.d/gatekeeper_init
chmod +x /etc/init.d/tg_gatekeeper
chmod +x /etc/init.d/gatekeeper_trigger_listener
EOF
```

### 3. Reload and restart services

```bash
ssh root@192.168.1.1 << 'EOF'
# Reload firewall
fw4 reload

# Restart services
/etc/init.d/gatekeeper_init restart
/etc/init.d/tg_gatekeeper restart
/etc/init.d/gatekeeper_trigger_listener restart
EOF
```

---

## Troubleshooting

### Deployment fails with "Connection refused"

- Check router IP address is correct
- Ensure SSH is enabled on the router
- Verify firewall allows SSH connections

### Scripts deployed but not running

Check service status:

```bash
ssh root@192.168.1.1
/etc/init.d/tg_gatekeeper status
/etc/init.d/gatekeeper_trigger_listener status
```

Check logs:

```bash
ssh root@192.168.1.1
logread -f | grep -E "gatekeeper|tg_bot"
```

### Bot not responding

1. Verify configuration:
   ```bash
   ssh root@192.168.1.1
   uci show gatekeeper
   ```

2. Check bot process:
   ```bash
   ps | grep tg_bot
   ```

3. Check logs:
   ```bash
   logread | grep tg_bot
   ```

### Firewall rules not applied

1. Check if gatekeeper.nft is registered as firewall include:
   ```bash
   uci show firewall | grep gatekeeper
   ```

2. If not, add it:
   ```bash
   uci add firewall include
   uci set firewall.@include[-1].path='/etc/gatekeeper/gatekeeper.nft'
   uci set firewall.@include[-1].type='script'
   uci commit firewall
   fw4 reload
   ```

3. Verify nftables sets exist:
   ```bash
   nft list set inet fw4 blacklist_macs
   nft list set inet fw4 approved_macs
   nft list set inet fw4 denied_macs
   nft list set inet fw4 static_macs
   ```

---

## Development Workflow

For active development, use the `--scripts-only` flag for faster iterations:

```bash
# Make changes to scripts
vim gatekeeper.sh

# Quick deploy (only scripts, no config or init scripts)
./deploy.sh 192.168.1.1 --scripts-only

# Manually restart affected service
ssh root@192.168.1.1 "/etc/init.d/tg_gatekeeper restart"
```

---

## Rollback

If you need to rollback to a previous version:

1. Keep backups of old versions:
   ```bash
   ssh root@192.168.1.1 "cp /usr/bin/gatekeeper.sh /usr/bin/gatekeeper.sh.backup"
   ```

2. Stop services:
   ```bash
   ssh root@192.168.1.1 << 'EOF'
   /etc/init.d/tg_gatekeeper stop
   /etc/init.d/gatekeeper_trigger_listener stop
   EOF
   ```

3. Restore old files and restart

---

## First Time Setup

If this is your first time setting up gatekeeper, see the main README.md for:
- Installing dependencies (jq, curl, etc.)
- Configuring dnsmasq DHCP script hook
- Enabling services on boot
- Getting Telegram bot token and chat ID
