# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Gatekeeper is a Telegram-based network access control system for OpenWrt routers. When a new device connects to the network via DHCP, the system sends a Telegram notification with interactive Approve/Deny buttons. Devices with static DHCP leases are automatically allowed. Temporary devices require manual approval and have timeout-based access (30 minutes default).

## Core Architecture

The system operates as a 4-stage event pipeline:

1. **dnsmasq** → Detects DHCP events (new device connections)
2. **dnsmasq_trigger.sh** → Bridges dnsmasq to ubus (sends ubus event); filters IPv6 — only IPv4 "add" events pass through
3. **gatekeeper_trigger.sh** → Listens to ubus events, implements rate limiting (60s per MAC via `/tmp/dns_locks/`), triggers gatekeeper.sh
4. **gatekeeper.sh** → Validates device state, sends Telegram notification, implements 5-minute auto-deny timer
5. **tg_bot.sh** → Continuous long-polling daemon for Telegram commands and inline button callbacks

**gatekeeper.sh validation order** (checked before sending any notification):
1. MAC in `static_macs`? → Auto-approve, exit
2. MAC in `denied_macs`? → Silently exit
3. MAC in `approved_macs`? → Silently exit
4. Blacklist mode ON + MAC not in `blacklist_macs`? → Auto-approve with 24h timeout, send info message
5. Otherwise → Send approval request to Telegram with Approve/Deny buttons + start 5-minute auto-deny background timer

### Firewall Integration (nftables)

Defined in `gatekeeper.nft`, using four nftables sets in the `gatekeeper_forward` chain (priority -10, runs before default filter):

| Set | Timeout | Purpose |
|-----|---------|---------|
| `static_macs` | none | Permanent whitelist from UCI static DHCP leases |
| `approved_macs` | 30 min (24h in blacklist mode) | Temporarily approved guests |
| `denied_macs` | 30 min | Explicitly denied devices (auto-expires to allow retry) |
| `blacklist_macs` | none | MACs requiring approval when blacklist mode is ON |

**Emergency Bypass:**
- `DISABLE`: Flushes `gatekeeper_forward` chain (all traffic allowed immediately, no reboot needed)
- `ENABLE`: Runs `fw4 reload` (restores all filtering rules)

### Blacklist Mode

Inverts the approval logic — useful when most devices are trusted.

- **OFF (default)**: All new devices require Telegram approval
- **ON**: Only `blacklist_macs` members require approval; all others get auto-approved with 24h timeout

State: `uci get gatekeeper.main.blacklist_mode` (0 or 1). MACs: `gatekeeper.blacklist.mac` list. Both persist across reboots.

### State Files (`/tmp` — non-persistent)

| File | Purpose |
|------|---------|
| `/tmp/tg_offset` | Telegram update ID (prevents duplicate processing) |
| `/tmp/gatekeeper.log` | Activity log |
| `/tmp/mac_names` | Custom hostname cache (MAC=Name, written during approval) |
| `/tmp/mac_map` | Session device ID→MAC mapping (STATUS/EXTEND/REVOKE) |
| `/tmp/denied_mac_map` | Session device ID→MAC mapping (DSTATUS/DEXTEND/DREVOKE) |
| `/tmp/dns_locks/` | Rate limiting timestamps (one file per MAC, no colons) |

### Hostname Resolution Priority

1. `/tmp/mac_names` — cached during approval
2. `/tmp/dhcp.leases` — current DHCP hostnames
3. UCI static config — configured hostname
4. Fallback: "Guest"

## Key Files

| File | Purpose |
|------|---------|
| `gatekeeper.nft` | Firewall rules and nftables set definitions |
| `gatekeeper.sh` | Main approval handler — notifications, auto-deny, blacklist mode |
| `tg_bot.sh` | Telegram bot daemon — commands, callbacks, blacklist management |
| `dnsmasq_trigger.sh` | Minimal DHCP event bridge to ubus |
| `gatekeeper_trigger.sh` | Ubus event listener with rate limiting |
| `gatekeeper_init` | Init script — syncs static and blacklist MACs at boot |
| `tg_gatekeeper` | Init script — procd-managed bot daemon |
| `gatekeeper_trigger_listener` | Init script — ubus listener daemon |
| `gatekeeper_sync.h` | Manual MAC sync utility (**note: file is named `.h` but is a shell script**) |
| `deploy.sh` | Automated SCP deployment to router |
| `opkg/Makefile` | OpenWrt SDK package definition |
| `opkg/etc/config/gatekeeper` | UCI config template |

> **Known naming issue:** The sync script file is `gatekeeper_sync.h` (not `.sh`) in the repo root. `deploy.sh` and GitHub Actions both reference `gatekeeper_sync.sh` — verify this file exists before deploying. `opkg/Makefile` line 62 also references `gatekeeper_sync.h` (correct for the actual filename but installs it as `.sh`).

## Development Workflow

**Deploy to router:**
```bash
./deploy.sh 192.168.1.1              # Full deploy + service restart
./deploy.sh 192.168.1.1 --dry-run   # Preview only
./deploy.sh 192.168.1.1 --no-restart
./deploy.sh 192.168.1.1 --scripts-only   # Skip config/init files
./deploy.sh 192.168.1.1 --config-only
```

**Quick script update:**
```bash
scp gatekeeper.sh tg_bot.sh root@192.168.1.1:/usr/bin/
ssh root@192.168.1.1 "/etc/init.d/tg_gatekeeper restart"
```

**Debugging on router:**
```bash
logread -f | grep -E "gatekeeper|tg_bot|DNS_LISTENER"

nft list set inet fw4 approved_macs
nft list set inet fw4 denied_macs
nft list set inet fw4 static_macs
nft list set inet fw4 blacklist_macs
nft list chain inet fw4 gatekeeper_forward

# Test pipeline manually
/usr/bin/dnsmasq_trigger.sh add aa:bb:cc:dd:ee:ff 192.168.1.100 test-device add
ubus listen dhcp.event
ls -la /tmp/dns_locks/
```

**Service management on router:**
```bash
/etc/init.d/tg_gatekeeper restart
/etc/init.d/gatekeeper_trigger_listener restart
/etc/init.d/gatekeeper_init start
fw4 reload    # Reload firewall rules without restarting services
```

## CI/CD and Releases

GitHub Actions (`.github/workflows/makefile.yml`) builds a `.ipk` package on every push to `main` and on pull requests. Tagged releases trigger a GitHub Release with the `.ipk` attached.

**To cut a release:**
```bash
git tag v1.2.3
git push origin v1.2.3
```

The workflow builds the `.ipk` directly (no OpenWrt SDK required) by assembling the `ar` archive structure manually. The built package is also uploaded as a GitHub Actions artifact on every build.

**Install from `.ipk` on router:**
```bash
opkg install gatekeeper_1.0.0-1_all.ipk
```

## Telegram Bot Commands

**Device Management:**
- `STATUS` / `DSTATUS` — List active/denied devices with session IDs
- `EXTEND ID` / `REVOKE ID` — Extend (30 min) or revoke approved device
- `DEXTEND ID` / `DREVOKE ID` — Extend (30 min) or remove denied device

**Blacklist Mode:**
- `BL_ON` / `BL_OFF` / `BL_STATUS`
- `BL_ADD aa:bb:cc:dd:ee:ff` / `BL_REMOVE aa:bb:cc:dd:ee:ff` / `BL_CLEAR`
- All commands also accept `BLACKLIST_` prefix

**System:**
- `HELP`, `LOG`, `SYNC`, `CLEAR`, `ENABLE`, `DISABLE`

**Inline button callbacks:** `approve_MAC` / `deny_MAC`

## Critical Implementation Details

### nftables Timeout Updates

You **cannot** update an existing element's timeout with `add element`. Always delete first:

```bash
# WRONG — timeout not updated:
nft "add element inet fw4 approved_macs { $MAC timeout 60m }"

# CORRECT:
nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
nft "add element inet fw4 approved_macs { $MAC timeout 60m }"
```

Always use `2>/dev/null` on the delete (element may not exist).

### Adding New Telegram Commands

1. Add handler in `tg_bot.sh` message processing loop (follow existing pattern)
2. Validate input before any firewall modification
3. Use the existing `send_message` function for responses
4. Update the `HELP` command text

### Adding New nftables Sets

1. Define in `gatekeeper.nft` with appropriate flags (`timeout`, `interval`, etc.)
2. Add boot-time population to `gatekeeper_init`
3. Update `gatekeeper_sync.h` for manual sync support

### Modifying Approval Logic

Always check all four nftables sets before sending a notification (order matters — check `denied_macs` before `approved_macs`). Use `grep -q` for silent exit-code-only matching.

## Configuration

```bash
uci set gatekeeper.main=gatekeeper
uci set gatekeeper.main.token='YOUR_BOT_TOKEN'
uci set gatekeeper.main.chat_id='YOUR_CHAT_ID'
uci commit gatekeeper
/etc/init.d/tg_gatekeeper restart
```

Config is read via UCI or environment variables `GATEKEEPER_TOKEN` / `GATEKEEPER_CHAT_ID`.

## Security Scope

MAC-based (Layer 2 only) — MACs can be spoofed. Designed for home/SMB use. Bot only responds to the configured `CHAT_ID`. All state in `/tmp` is cleared on reboot.
