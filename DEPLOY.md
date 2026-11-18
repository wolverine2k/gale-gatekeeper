# Deployment Guide

This guide explains how to deploy gatekeeper to your OpenWrt router.

## Package deployment

Use the native package manager for the installed OpenWrt release:

| Release | Package format | Deployment source |
| --- | --- | --- |
| 23.05 / 24.10 | IPK (`opkg`) | Matching runtime/LuCI files, `packages.tsv`, and `SHA256SUMS` from one release |
| 25.12 | APK v3 (`apk`) | A signed HTTPS package feed and its matching local release artifacts |

The package mode checks the router release, native package database, package
versions, ownership, architecture, and prerequisites before installation. Unknown
releases, snapshots, conflicting managers, tampered files, mismatched package
pairs, and unmanaged/direct-copy installations are refused. An explicit
`--package-manager` is an assertion, not an override for an incompatible release.

CI builds separate targets for OpenWrt **23.05**, **24.10**, and **25.12**. Every
published package filename starts with its base series; internal package names
remain `gatekeeper` and `luci-app-gatekeeper`:

```text
openwrt-23.05-gatekeeper_<version>-1_all.ipk
openwrt-23.05-luci-app-gatekeeper_<version>-1_all.ipk
openwrt-24.10-gatekeeper_<version>-1_all.ipk
openwrt-24.10-luci-app-gatekeeper_<version>-1_all.ipk
openwrt-25.12-gatekeeper-<version>-r1.apk
openwrt-25.12-luci-app-gatekeeper-<version>-r1.apk
```

For IPK deployment, extract the matching
`openwrt-23.05-gatekeeper-packages.tar.gz` or
`openwrt-24.10-gatekeeper-packages.tar.gz` into its own trusted artifact directory.
Each bundle includes its package pair plus standard `packages.tsv` and
`SHA256SUMS` files. Do not mix series in one artifact directory. The deployer
checks prefixed filenames against the router's base series, including 23.05
versus 24.10 even though both use opkg. Then preview before installing:

```sh
bash deploy.sh 192.168.1.1 --packages "$ARTIFACT_DIR" --luci --dry-run
bash deploy.sh 192.168.1.1 --packages "$ARTIFACT_DIR" --luci
```

The checksums detect corruption and mismatched downloads; obtain the release and
manifests from a trusted publisher. Package mode preserves existing configuration
through native conffile handling. Newly packaged credential configuration uses
mode 0600; existing edited files retain the native manager's upgrade semantics.
It does not use force-overwrite/force-maintainer
options, silently adopt files from SCP deployments, or fall back to raw copying.
Resolve unmanaged installations explicitly before switching deployment modes.

### OpenWrt 25.12 signed feed

Build the feed on Linux using the checksum-verified official OpenWrt 25.12.0 SDK.
Keep the publisher's private key outside the checkout and outside the output
directory. The output directory must be empty:

```sh
sh opkg/build-apk.sh --sdk "$OPENWRT_SDK" --output "$FEED_DIR" \
  --version "$VERSION" --release 1 --signing-key "$PRIVATE_KEY_FILE"
```

The output contains both APKs, `packages.adb`, `feed-public.pem`, `packages.tsv`,
and `SHA256SUMS`; only the public key is published. Publish this directory at an
administrator-controlled HTTPS URL, keeping the index and APK files together.
Pass the directory URL to `--feed-url`; the deployer appends `/packages.adb` for
the flat native APK v3 index. Its signed `pkgname-spec` resolves the
`openwrt-25.12-` package filenames. Do not rename APKs after indexing; regenerate
and sign the index when changing its filename pattern. The signed index and
package signatures are checked by native APK tools. Do not use `--allow-untrusted` or
disable TLS verification to make a feed work.

Before first use, the router administrator must independently verify the public
feed key's fingerprint and install that public key in `/etc/apk/keys/`. The
installer never enrolls a key or changes repository/trust configuration. Preserve
this trust setup through sysupgrade and plan key rotation before replacing a
publisher key. A hash served beside a public key is not an independent trust
bootstrap.

Set `FEED_URL` to the HTTPS directory containing the published signed index and
use the matching local feed artifacts for release verification:

```sh
bash deploy.sh 192.168.1.1 --packages "$FEED_DIR" --feed-url "$FEED_URL" --luci --dry-run
bash deploy.sh 192.168.1.1 --packages "$FEED_DIR" --feed-url "$FEED_URL" --luci
```

The installer binds the signed index and exact downloaded APK bytes to the local
manifest, verifies native metadata and signatures against only the expected
already-trusted publisher key, and installs those verified files offline. It does
not substitute another same-version build from a configured repository. It
rejects downgrades and runtime-only updates that would leave an installed LuCI
companion at a different version, then verifies the installed versions.

APK dry-runs create a private temporary directory on the router, download and
cryptographically verify the signed index and package pair, simulate installation,
and clean up. They do not install packages or make persistent configuration,
trust, repository, or service changes. IPK dry-runs use read-only preflights.
Required prerequisites, including `curl`, `jq`, and `sha256sum`, must already be
installed; package deployment does not bypass dependency failures or silently
bootstrap dependencies. Use release-matched official feeds to provision them.
SSH keys or an SSH agent are required for package mode; the legacy
`--ask-password` option is not supported there. Legacy SCP flags such as
`--config-only`, `--scripts-only`, and `--no-restart` cannot be combined with
`--packages`; native package lifecycle hooks govern package-mode restarts.

### Release CI and remaining router validation

CI validates IPKs with real OpenWrt 23.05.5 and 24.10.0 parsers and builds native
APKs using a pinned 25.12.0 SDK. Tagged releases require the maintainer-provided
`GATEKEEPER_APK_FEED_KEY` GitHub Actions secret. This must be the stable publisher
private key corresponding to the public key trusted by routers. Branch/PR builds
use disposable test keys and are marked test-only; never trust those keys on a
production router. Private keys are not included in feed artifacts.

The release job waits for all three base-series builds and tests before publishing
the six prefixed package files, the two IPK bundles, and
`openwrt-25.12-gatekeeper-apk-feed.tar.gz`. Checksums and manifests are bundled per
series so metadata filenames cannot collide. Extract the signed feed bundle on
your HTTPS hosting service; this workflow does not provision hosting, configure
GitHub Pages, or change router trust. No signing key or feed is created remotely
by running the deployment script.

Format/parser and isolated installation tests do not certify booted-router
behavior. Validate upgrades with an edited `/etc/config/gatekeeper`, LuCI/rpcd,
procd, dnsmasq events, and fw4 on the intended router before rollout. Firewall
include registration, DHCP-hook conflict resolution, credentials, and initial
activation remain explicit administrator steps from the README. Do not repeat
anonymous firewall includes or overwrite an existing dnsmasq script blindly.

## Quick Start

The following commands use the existing direct SSH/SCP development workflow,
not package-managed deployment. They retain their original behavior, including
copying the configuration template unless `--no-config` is supplied.

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
scp openwrt-23.05-luci-app-gatekeeper_<version>_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/openwrt-23.05-luci-app-gatekeeper_<version>_all.ipk"
```

The example above targets 23.05 and requires a matching installed runtime. Use
`openwrt-24.10-` on 24.10, or the signed APK feed on 25.12. The workflow produces
runtime/LuCI pairs for all three base series; branch builds are Actions artifacts,
and tagged builds publish the prefixed packages and per-series bundles to
[GitHub Releases](https://github.com/wolverine2k/gale-gatekeeper/releases). Prefer
[verified paired deployment](#package-deployment) when upgrading.

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
