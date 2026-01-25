# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Gatekeeper is a Telegram-based network access control system for OpenWrt routers. When a new device connects to the network via DHCP, the system sends a Telegram notification with interactive Approve/Deny buttons. Devices with static DHCP leases are automatically allowed. Temporary devices require manual approval and have timeout-based access (30 minutes default).

## Core Architecture

The system operates as a 4-stage event pipeline:

1. **dnsmasq** → Detects DHCP events (new device connections)
2. **dnsmasq_trigger.sh** → Bridges dnsmasq to ubus (sends ubus event)
3. **gatekeeper_trigger.sh** → Listens to ubus events, implements rate limiting (60s), triggers gatekeeper.sh
4. **gatekeeper.sh** → Checks static leases, sends Telegram notification, implements 5-minute auto-deny timer
5. **tg_bot.sh** → Continuous polling daemon for Telegram commands (Approve/Deny buttons + text commands)

### Firewall Integration (nftables)

The firewall logic is defined in `gatekeeper.nft` and uses four nftables sets:

- **static_macs**: Permanent whitelist from UCI static DHCP leases (no timeout)
- **approved_macs**: Temporary approved guests (30 minute timeout)
- **denied_macs**: Explicitly denied devices (30 minute timeout to allow retry)
- **bypass_switch**: Emergency global bypass (MAC ff:ff:ff:ff:ff:ff activates it)

Rule evaluation order (priority -10, runs before default filter):
1. Emergency bypass (if bypass_switch contains ff:ff:ff:ff:ff:ff)
2. Static VIPs (static_macs)
3. Approved guests (approved_macs)
4. Default block (drops all LAN→WAN traffic not in above sets)

### State Management

Key state files in `/tmp`:
- `/tmp/tg_offset`: Telegram update ID tracking (prevents duplicate message processing)
- `/tmp/gatekeeper.log`: Activity logs
- `/tmp/mac_names`: Custom hostname cache (MAC=Name pairs from approval)
- `/tmp/mac_map`: Temporary device ID-to-MAC mapping (for STATUS command)
- `/tmp/dns_locks/`: Rate limiting timestamp files (60-second cooldown per MAC)

### Hostname Resolution Priority

When displaying devices, the bot uses this lookup order:
1. Custom name map (`/tmp/mac_names`) - cached during approval
2. DHCP leases (`/tmp/dhcp.leases`) - current network hostnames
3. Static UCI config - hostname from UCI DHCP configuration
4. Fallback: "Guest"

## Key Files

| File | Purpose |
|------|---------|
| `gatekeeper.nft` | Firewall rules and nftables set definitions |
| `gatekeeper.sh` | Main approval handler - sends Telegram notifications, implements auto-deny |
| `tg_bot.sh` | Interactive bot daemon - handles commands and callbacks |
| `dnsmasq_trigger.sh` | Minimal DHCP event bridge to ubus |
| `gatekeeper_trigger.sh` | Ubus event listener with rate limiting |
| `gatekeeper_init` | Init script for static MAC sync at boot |
| `tg_gatekeeper` | Init script for bot daemon (procd-managed) |
| `gatekeeper_trigger_listener` | Init script for ubus listener daemon |
| `gatekeeper_sync.sh` | Manual static MAC sync utility |

## Telegram Bot Commands

Interactive commands (text-based):
- **STATUS**: Show gatekeeper status and active guests with IDs
- **EXTEND ID**: Extend timeout for approved guest by ID
- **REVOKE ID**: Immediately revoke network access
- **LOG**: Display recent activity logs
- **SYNC**: Manually resync static DHCP MACs from UCI config
- **ENABLE**: Re-enable gatekeeper (clear bypass switch)
- **DISABLE**: Emergency disable (add ff:ff:ff:ff:ff:ff to bypass_switch)
- **CLEAR**: Clear logs and hostname cache

Callback handlers (inline buttons):
- **approve_MAC**: Add MAC to approved_macs (30 min timeout)
- **deny_MAC**: Add MAC to denied_macs (30 min timeout)

## Development Environment

This is an OpenWrt package designed for deployment on routers (tested on Gale). Development is done on the host machine, then deployed to the router.

### Dependencies

Required on OpenWrt target:
- `jq` - JSON parsing
- `curl` - Telegram API communication
- `coreutils` and `coreutils-timeout` - Extended shell utilities
- `nftables` (fw4) - Firewall management
- `ubus` - Event messaging system

### Configuration Requirements

After installation, configure Telegram credentials via UCI:
```bash
# Configure Telegram Bot token (from BotFather: https://t.me/botfather)
uci set gatekeeper.main=gatekeeper
uci set gatekeeper.main.token='YOUR_TELEGRAM_BOT_TOKEN_HERE'

# Configure Telegram Chat ID (send message to @userinfobot to get your ID)
uci set gatekeeper.main.chat_id='YOUR_CHAT_ID_HERE'

# Save configuration
uci commit gatekeeper

# Restart services to apply
/etc/init.d/tg_gatekeeper restart
```

The configuration is stored in `/etc/config/gatekeeper` and is read by both `gatekeeper.sh` and `tg_bot.sh` via UCI or environment variables (`GATEKEEPER_TOKEN` and `GATEKEEPER_CHAT_ID`).

### Testing and Debugging

View system logs:
```bash
logread -f | grep gatekeeper
logread -f | grep tg_bot
logread -f | grep DNS_LISTENER
```

Check nftables sets:
```bash
nft list set inet fw4 approved_macs
nft list set inet fw4 denied_macs
nft list set inet fw4 static_macs
nft list set inet fw4 bypass_switch
```

Service management:
```bash
/etc/init.d/tg_gatekeeper restart
/etc/init.d/gatekeeper_trigger_listener restart
/etc/init.d/gatekeeper_init start
```

Firewall operations:
```bash
fw4 reload                    # Apply firewall config changes
nft list chain inet fw4 gatekeeper_forward  # View rule stats
```

Emergency disable:
```bash
nft add element inet fw4 bypass_switch { ff:ff:ff:ff:ff:ff }
```

Emergency enable:
```bash
nft flush set inet fw4 bypass_switch
```

### OpenWrt Package Build

The `opkg/Makefile` defines the OpenWrt package structure. Build using OpenWrt SDK:
```bash
# In OpenWrt buildroot
make package/gatekeeper/compile
```

## Important Implementation Details

### Rate Limiting
- `gatekeeper_trigger.sh` prevents duplicate triggers within 60 seconds per MAC
- Uses timestamp files in `/tmp/dns_locks/` with sanitized MAC (no colons)
- Protects against DHCP request spam and network flapping

### Auto-Deny Timer
- `gatekeeper.sh` spawns background process with 5-minute sleep
- After timeout, checks if MAC was approved
- If not approved, edits Telegram message and adds to denied_macs
- Prevents notification spam for ignored devices

### Duplicate Code Issue
Note: Both `gatekeeper.sh` and `tg_bot.sh` contain duplicated code sections (lines 77-151 duplicated at 152-194 in gatekeeper.sh, lines 85-289 duplicated at 291-438 in tg_bot.sh). This should be cleaned up.

### Security Considerations
- MAC addresses can be spoofed (Layer 2 security only)
- Designed for home/SMB use, not enterprise security
- Only responds to authorized CHAT_ID in Telegram
- Telegram API uses HTTPS with token authentication
- State files in `/tmp` are non-persistent (cleared on reboot)

## Installation Flow

1. Install dependencies: `opkg update && opkg install jq curl coreutils coreutils-timeout`
2. Copy files to appropriate locations (see README.md file structure)
3. Configure Telegram credentials via UCI:
   ```bash
   uci set gatekeeper.main=gatekeeper
   uci set gatekeeper.main.token='YOUR_BOT_TOKEN'
   uci set gatekeeper.main.chat_id='YOUR_CHAT_ID'
   uci commit gatekeeper
   ```
4. Set permissions: `chmod +x` on all `.sh` files and init scripts
5. Configure dnsmasq trigger: `uci set dhcp.@dnsmasq[0].dhcpscript='/usr/bin/dnsmasq_trigger.sh'`
6. Configure firewall include: `uci add firewall include && uci set firewall.@include[-1].path='/etc/gatekeeper.nft' && uci set firewall.@include[-1].type='script'`
7. Commit UCI changes: `uci commit dhcp && uci commit firewall`
8. Enable services: `/etc/init.d/tg_gatekeeper enable && /etc/init.d/gatekeeper_init enable && /etc/init.d/gatekeeper_trigger_listener enable`
9. Restart services: `/etc/init.d/firewall restart && /etc/init.d/dnsmasq restart`
10. Start gatekeeper services
11. Test with "Status" command in Telegram
