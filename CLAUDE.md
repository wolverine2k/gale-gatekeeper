# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Gatekeeper is a Telegram-based network access control system for OpenWrt routers. When a new device connects to the network via DHCP, the system sends a Telegram notification with interactive Approve/Deny buttons. Devices with static DHCP leases are automatically allowed. Temporary devices require manual approval and have timeout-based access (30 minutes default).

## Core Architecture

The system operates as a 5-stage event pipeline:

1. **dnsmasq** → Detects DHCP events (new device connections)
2. **dnsmasq_trigger.sh** → Minimal one-liner: forwards `action/mac/ip/host` from dnsmasq to `ubus send dnsmasq.event`. No filtering happens here.
3. **gatekeeper_trigger.sh** → `ubus monitor` listener. Filters IPv6 (skips addresses containing `:`), rate-limits 60s per MAC via `/tmp/dns_locks/`, GCs lock files older than 300s on each event, then invokes `gatekeeper.sh` with a hardcoded `"add"` action (original action is passed as $5 but ignored)
4. **gatekeeper.sh** → Validates device state, sends Telegram notification, implements 5-minute auto-deny timer
5. **tg_bot.sh** → Continuous long-polling daemon for Telegram commands and inline button callbacks

**gatekeeper.sh validation order** (checked before sending any notification):
1. MAC in UCI `dhcp.@host[*].mac`? → `is_static=1`, skip notification (access via static nftables rule)
2. MAC in `denied_macs` nftables set? → Silently exit
3. MAC in `approved_macs` nftables set? → Silently exit
4. `gatekeeper.main.disabled=1`? → Exit immediately (set by DISABLE command; checked first before input parsing)
5. Blacklist mode ON + MAC not in `blacklist_macs`? → Auto-approve with 24h timeout, send info message
6. Active schedule for MAC? → Auto-approve until window end, optionally notify (controlled by `gatekeeper.main.schedule_notify`)
7. Otherwise → Send approval request to Telegram with Approve/Deny buttons + start 5-minute auto-deny background timer

Note: Step 1 reads UCI directly (not the `static_macs` nftables set). The nftables set is a mirror populated by `gatekeeper_init` at boot **and** re-populated by `gatekeeper.nft` on every `fw4 reload` (including reloads triggered by WAN IP changes). The same is true for `blacklist_macs`. This dual-population is deliberate: automatic `fw4 reload` events would otherwise wipe the sets until a manual `SYNC`.

### Firewall Integration (nftables)

Defined in `gatekeeper.nft`, using four nftables sets in the `gatekeeper_forward` chain (priority -10, runs before default filter):

| Set | Timeout | Purpose |
|-----|---------|---------|
| `static_macs` | none | Permanent whitelist from UCI static DHCP leases |
| `approved_macs` | 30 min (24h in blacklist mode) | Temporarily approved guests |
| `denied_macs` | 30 min | Explicitly denied devices (auto-expires to allow retry) |
| `blacklist_macs` | none | MACs requiring approval when blacklist mode is ON |

**Emergency Bypass:**
- `DISABLE`: Sets `uci set gatekeeper.main.disabled=1` (persists across `fw4` reloads), then flushes `gatekeeper_forward` chain
- `ENABLE`: Clears `gatekeeper.main.disabled=0`, runs `fw4 reload`, re-syncs static and blacklist MACs
- `gatekeeper.nft` checks `gatekeeper.main.disabled` on every `fw4 reload` — if set, it creates the chain but leaves it empty so automatic firewall reloads (e.g., WAN IP changes) don't silently re-enable blocking

**Firewall Include Registration** (done once at install):
```bash
uci add firewall include
uci set firewall.@include[-1].path='/etc/gatekeeper/gatekeeper.nft'
uci set firewall.@include[-1].type='script'
uci commit firewall
```
`gatekeeper.nft` is a shell script (not nft syntax), executed on every `fw4 reload`.

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
| `/tmp/dns_locks/` | Rate-limit timestamps (one file per MAC, colons stripped). Stale files (>300s) GC'd on every event |
| `/tmp/gatekeeper_timer_<MAC-no-colons>` | PID of the per-MAC 5-minute auto-deny timer; re-invocation of `gatekeeper.sh` for the same MAC `kill`s any prior timer before starting a new one (prevents orphaned `sleep 300` processes on rapid DHCP flaps) |
| `/tmp/sched_active` | Schedule reconciliation snapshot (one line per active schedule: `name mac end-epoch`); rebuilt by `scheduler_tick` and read by `STATUS` for the ⏰ tag |
| `/tmp/sched_lock` | flock guard preventing overlapping `scheduler_tick` invocations |

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
| `gatekeeper_sync.sh` | Manual sync utility — syncs **both** static and blacklist MACs (accepts `static`, `blacklist`, or `all`) |
| `deploy.sh` | Automated SCP deployment to router |
| `.github/workflows/makefile.yml` | CI `.ipk` build (primary delivery path — hand-rolls the archive via `tar` + `ar rcs`, no SDK required) |
| `opkg/Makefile` | OpenWrt SDK package recipe (alternative build path for feed integration; CI does not use this) |
| `opkg/etc/config/gatekeeper` | UCI config template |

## Development Workflow

**Deploy to router:**
```bash
./deploy.sh 192.168.1.1              # Full deploy + service restart
./deploy.sh 192.168.1.1 --dry-run   # Preview only
./deploy.sh 192.168.1.1 --no-restart
./deploy.sh 192.168.1.1 --restart-only   # Only restart services, no file copy
./deploy.sh 192.168.1.1 --scripts-only   # Skip config/init files
./deploy.sh 192.168.1.1 --config-only
./deploy.sh 192.168.1.1 --no-config      # Deploy all files except config (preserves existing settings)
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
- `EXTEND ID [hours]` / `REVOKE ID` — Extend (30 min default, or specify hours) or revoke approved device
- `DEXTEND ID` — Extend denial timeout (+30 min)
- `DREVOKE ID` — Remove device from denied list **and** auto-approve it for 30 min (not a plain "remove")

**Blacklist Mode:**
- `BLON` / `BLOFF` / `BLSTATUS`
- `BLADD aa:bb:cc:dd:ee:ff` / `BLREMOVE aa:bb:cc:dd:ee:ff` / `BLCLEAR`
- All commands also accept `BLACKLIST_` prefix

**System:**
- `HELP`, `LOG`, `SYNC`, `CLEAR`, `ENABLE`, `DISABLE`
- `BACKUP` / `BACKUP NOSECRETS` — Send a plain-text UCI snapshot of `/etc/config/gatekeeper` plus the static DHCP host entries from `/etc/config/dhcp` to the configured chat as a Telegram document. `NOSECRETS` blanks the bot token and chat id before upload (default includes them). The temp file in `/tmp` is deleted after upload regardless of success or failure.
- `RESTORE` (as a reply to a backup file message) — Begin restoring config from a backup. The bot validates the file, computes an additive merge plan against current UCI (skip duplicates by MAC for blacklist, by section name for schedules; never touch `token`/`chat_id`), and replies with a preview. Reply `YES` to the preview within 10 minutes to apply. Restore is read-only against UCI until you confirm; failures during apply roll back via `uci revert`.

**Schedules (auto-approve windows):**
- `SCHEDADD <mac> <days> <start>-<stop> [name]` — Register an auto-approval window. `name` auto-generated if omitted (`sched_<last3octets>_<n>`). `days` = `daily` | `weekdays` | `weekends` | comma-separated `mon,tue,...,sun`. Times in `HH:MM` 24h, router local TZ. `stop ≤ start` = crosses midnight, anchored to the start day.
- `SCHEDLIST [mac]` — List all schedules; optional MAC filter. Active schedules tagged `⏰ active (until HH:MM)`.
- `SCHEDSHOW <name>` — Single-schedule detail view.
- `SCHEDREMOVE <name>` — Delete a schedule. If currently active, MAC is removed from `approved_macs` immediately.
- `SCHEDOFF <name>` / `SCHEDON <name>` — Pause/resume a schedule without deleting it.
- `SCHEDNOTIFY ON|OFF|STATUS` — Toggle the optional info message on schedule auto-approve (default OFF).

Schedule definitions live in UCI (`/etc/config/gatekeeper`) as `config schedule '<name>'` sections; they survive reboots. The `scheduler_tick()` function in `tg_bot.sh` reconciles `approved_macs` once per polling-loop iteration. `gatekeeper.sh` step 3.6 reactively auto-approves mid-window DHCP events. A manual `REVOKE` during an active window adds the MAC to `denied_macs` for 30 min; the scheduler skips re-push while the deny entry exists, so REVOKE remains effective for at least 30 minutes during a window.

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
3. Update `gatekeeper_sync.sh` for manual sync support (add a new `SYNC_MODE` branch)
4. Also update the repopulation block in `gatekeeper.nft` so the set survives automatic `fw4 reload`

### Modifying Approval Logic

Always check all four nftables sets before sending a notification (order matters — check `denied_macs` before `approved_macs`). Use `grep -q` for silent exit-code-only matching.

### Session ID Mapping

`STATUS` and `DSTATUS` write fresh `/tmp/mac_map` and `/tmp/denied_mac_map` each time they're called, overwriting previous mappings. IDs from a prior `STATUS` call are invalidated by any subsequent `STATUS` call. `REVOKE` removes from `approved_macs` **and** adds to `denied_macs` for 30 minutes to suppress reconnect notifications.

### Log Rotation

Both `gatekeeper.sh` and `tg_bot.sh` self-rotate `/tmp/gatekeeper.log`: when the file exceeds 1000 lines, they truncate to the last 500 (tail + mv). This runs on every invocation / every poll iteration — cheap, but don't rely on log entries older than ~500 events.

### Shell Compatibility Note

All scripts that run on the router (`gatekeeper.sh`, `tg_bot.sh`, `gatekeeper_trigger.sh`, `dnsmasq_trigger.sh`, `gatekeeper_sync.sh`, init scripts, `gatekeeper.nft`) must be POSIX `/bin/sh` compatible — OpenWrt ships BusyBox ash, not bash. **No bashisms**: avoid `[[ ]]`, `${var,,}` / `${var^^}`, arrays, `function` keyword, process substitution `<(...)`. Use `tr 'A-Z' 'a-z'` for case conversion (not `${var,,}`) — this pattern is already used throughout. `deploy.sh` is the one exception (runs on dev machine) and uses `#!/bin/bash` deliberately.

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
