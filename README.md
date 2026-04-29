# Gatekeeper - Telegram Network Access Control for OpenWrt

A Telegram-based network access control system for OpenWrt routers. Get instant notifications when devices connect to your network and approve/deny access with a simple button press. An optional companion package, **`luci-app-gatekeeper`**, adds a full browser-based admin interface alongside the bot — install one, the other, or both.

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform: OpenWrt](https://img.shields.io/badge/Platform-OpenWrt-00B5E2)

## 🎯 Features

### Core Features
- **Interactive Telegram Notifications** - Get instant alerts with Approve/Deny buttons when new devices connect
- **Static Lease Detection** - Devices with static DHCP leases automatically bypass approval
- **Timeout-Based Access** - Approved devices get 30 minutes of network access (configurable)
- **Auto-Deny Timer** - Unapproved devices are automatically denied after 5 minutes
- **Rate Limiting** - Prevents notification spam from network flapping
- **Emergency Bypass** - Global off-switch for emergencies

### Advanced Features
- **LuCI Web UI** ⭐ NEW - Optional `luci-app-gatekeeper` sibling package adds a six-page browser admin interface (Overview, Devices, Blacklist, Schedules, Backup/Restore, Settings) under `Services → Gatekeeper`. Independent of the Telegram bot — both surfaces share the same UCI + nftables state, neither requires the other. Auth uses LuCI's standard ACL (router admin password). See the LuCI Web UI section below for details.
- **Scheduled Auto-Approval** ⭐ NEW - Time-window-based MAC auto-approval. Multiple schedules per MAC; per-day or daily/weekdays/weekends; cross-midnight windows supported. Hybrid push/pop (proactive at window start, reactive on mid-window DHCP events).
- **Configuration Backup** ⭐ NEW - One-command Telegram-driven UCI snapshot (`BACKUP`); optional `NOSECRETS` variant blanks token/chat_id; uploaded as a Telegram document.
- **Configuration Restore** ⭐ NEW - Reply `RESTORE` to a backup file, then `YES` to confirm. Additive merge (skip duplicates), two-phase apply with revert-on-failure, never overwrites token/chat_id.
- **Blacklist Mode** - Invert approval logic: only blacklisted MACs require approval, all others are auto-approved for 24 hours
- **Device Management** - Extend, revoke, and track active guests via Telegram commands
- **Denied Device Tracking** - Manage denied devices with timeout extension and removal
- **Custom Device Names** - Cache device hostnames for easier identification
- **Activity Logging** - Track all approval/denial events
- **Manual Sync** - Force synchronization of static leases and blacklist

### Technical Features
- **nftables Integration** - Uses modern nftables (fw4) for firewall rules
- **UCI Configuration** - Standard OpenWrt configuration management
- **procd Services** - Managed as system services with auto-restart
- **IPv6 Filtering** - Automatically filters IPv6 DHCP requests to reduce noise
- **Idempotent Operations** - Safe to run multiple times without side effects

## 📸 Screenshots

LuCI Web Interface
![Gatekeeper LuCI](https://github.com/wolverine2k/gale-gatekeeper/blob/main/luciScreen.png)

When a new device connects:
```
⚠️ New Device Connection
Host: Johns-iPhone
MAC: aa:bb:cc:dd:ee:ff
IP: 192.168.1.100

[✅ Approve] [❌ Deny]
```

Blacklist mode auto-approval:
```
✅ Auto-Approved (Blacklist Mode)

🔹 Device: Johns-iPhone
🔹 MAC: aa:bb:cc:dd:ee:ff
🔹 IP: 192.168.1.100
🔹 Access: 24 hours
```

## 🚀 Quick Start

### Prerequisites
- OpenWrt 22.03+ with fw4 (nftables)
- Telegram account and bot token ([get one from BotFather](https://t.me/botfather))
- SSH access to your router

### 1. Install Dependencies

SSH to your router and install required packages:

```bash
opkg update
opkg install jq curl coreutils coreutils-timeout
```

### 2. Get Telegram Credentials

1. **Bot Token**: Message [@BotFather](https://t.me/botfather) on Telegram
   - Send `/newbot` and follow prompts
   - Save the bot token (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

2. **Chat ID**: Message [@userinfobot](https://t.me/userinfobot)
   - It will reply with your chat ID (format: `123456789`)

### 3. Deploy with Auto-Deploy Script

From your development machine:

```bash
# Clone the repository
git clone https://github.com/wolverine2k/gale-gatekeeper.git
cd gale-gatekeeper

# Make deploy script executable
chmod +x deploy.sh

# Deploy to your router (replace with your router IP)
./deploy.sh 192.168.1.1
```

The script will:
- ✅ Copy all files to the correct locations
- ✅ Set proper permissions
- ✅ Reload firewall
- ✅ Restart all services

### 4. Configure Telegram Credentials

SSH to your router:

```bash
ssh root@192.168.1.1

# Set your bot token and chat ID
uci set gatekeeper.main.token='YOUR_BOT_TOKEN_HERE'
uci set gatekeeper.main.chat_id='YOUR_CHAT_ID_HERE'
uci commit gatekeeper

# Restart bot service
/etc/init.d/tg_gatekeeper restart
```

### 5. Enable Services (First Time Only)

```bash
# Enable services to start on boot
/etc/init.d/gatekeeper_init enable
/etc/init.d/tg_gatekeeper enable
/etc/init.d/gatekeeper_trigger_listener enable

# Configure dnsmasq to trigger on DHCP events
uci set dhcp.@dnsmasq[0].dhcpscript='/usr/bin/dnsmasq_trigger.sh'
uci commit dhcp

# Configure firewall to load gatekeeper rules
uci add firewall include
uci set firewall.@include[-1].path='/etc/gatekeeper/gatekeeper.nft'
uci set firewall.@include[-1].type='script'
uci commit firewall

# Restart services
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
```

### 6. Test

Send "**STATUS**" to your bot in Telegram. You should receive a status message with the current gatekeeper state.

## 🖥️ LuCI Web UI (optional)

Gatekeeper ships an optional companion package, **`luci-app-gatekeeper`**, that provides a full browser-based admin interface alongside the Telegram bot. The two surfaces are independent — both read/write the same UCI + nftables state — so you can run with the bot, the UI, neither, or both.

### Install

```bash
opkg install luci-app-gatekeeper_<version>_all.ipk
```

The LuCI app depends on the runtime `gatekeeper` package, `luci-base`, and `rpcd`. After install, navigate in your router's LuCI panel to:

```
Services → Gatekeeper
```

### What's there

- **Overview** — status cards (bot daemon, firewall chain, NTP clock, mode flags), 5 count cards (active / denied / static / blacklist / schedules), live tail of `/tmp/gatekeeper.log`. Optional auto-refresh every 5 s.
- **Devices** — three tables (active, denied, static) with per-row Approve / Deny / +30m / +1h / +4h / Revoke buttons. ⏰ tag marks schedule-driven approvals; hostnames resolved from the same chain `STATUS` uses.
- **Blacklist** — slide toggle for `blacklist_mode`, MAC list editor with online indicators (matched against `/tmp/dhcp.leases`), bulk Clear All.
- **Schedules** — table + modal CRUD with day-preset selector (Daily / Weekdays / Weekends / Custom), browser-native time pickers, hyphen-to-underscore name correction hints, Pause/Resume toggle, ⏰ tag for currently-active windows.
- **Backup / Restore** — direct browser download (with-secrets / NO-secrets) and drag-and-drop file upload. Two-step preview-then-apply restore flow with the same merge plan the Telegram `RESTORE` flow produces.
- **Settings** — form for bot token (masked + Show toggle), chat_id, blacklist_mode, schedule_notify, disabled flag. **"Test bot connection"** button calls Telegram `getMe` and shows username/first-name on success — useful for verifying credentials at first-time setup.

### Architecture

Browser ↔ uhttpd/LuCI RPC ↔ `rpcd` ↔ `/usr/libexec/rpcd/gatekeeper` (POSIX shell) ↔ `uci` / `nft` / `/tmp/*`

Auth uses LuCI's standard ACL — anyone with router admin credentials can use the UI. The LuCI app does NOT use the bot's `CHAT_ID` for authorization.

## 📱 Telegram Commands

### Device Management
| Command | Description |
|---------|-------------|
| `HELP` | Display all available commands |
| `STATUS` | Show active approved guests with IDs |
| `DSTATUS` | Show all denied devices |
| `EXTEND [ID] [hours]` | Extend timeout for guest by ID (+30 min default, or specify hours) |
| `REVOKE [ID]` | Immediately revoke network access |
| `DEXTEND [ID]` | Extend denial timeout (+30 min) |
| `DREVOKE [ID]` | Remove device from denied list |

### Blacklist Mode ⭐ NEW
| Command | Description |
|---------|-------------|
| `BLON` | Enable blacklist mode (only blacklisted MACs require approval) |
| `BLOFF` | Disable blacklist mode (return to normal mode) |
| `BLSTATUS` | Show blacklist mode status and list MACs |
| `BLADD [MAC]` | Add MAC to blacklist (e.g., `BLADD aa:bb:cc:dd:ee:ff`) |
| `BLREMOVE [MAC]` | Remove MAC from blacklist |
| `BLCLEAR` | Clear all MACs from blacklist |

### Schedules (Auto-Approve Windows)
| Command | Description |
|---------|-------------|
| `SCHEDADD <mac> <days> <start>-<stop> [name]` | Add a scheduled auto-approval window (`days`: `daily`, `weekdays`, `weekends`, or `mon,tue,...`) |
| `SCHEDLIST [mac]` | List all schedules; filter by MAC. Active schedules tagged ⏰ |
| `SCHEDSHOW <name>` | Show detail for a single schedule |
| `SCHEDREMOVE <name>` | Delete a schedule (removes from `approved_macs` if currently active) |
| `SCHEDOFF <name>` / `SCHEDON <name>` | Pause or resume a schedule without deleting it |
| `SCHEDNOTIFY ON\|OFF\|STATUS` | Toggle info message on schedule auto-approve (default OFF) |

### System Control
| Command | Description |
|---------|-------------|
| `SYNC` | Manually resync static DHCP **and** blacklist MACs from UCI to firewall |
| `ENABLE` | Re-enable gatekeeper (clear bypass) |
| `DISABLE` | Emergency disable (bypass all filtering) |
| `LOG` | Display recent activity logs |
| `CLEAR` | Clear logs and hostname cache |
| `BACKUP` / `BACKUP NOSECRETS` | Send a config backup file (UCI text) to the chat. `NOSECRETS` blanks token/chat_id |
| `RESTORE` (reply to backup file) / `YES` | Restore config from a backup file (additive merge; reply YES within 10 min to confirm) |

## 🎭 Blacklist Mode Explained

Blacklist mode inverts the approval logic for easier management of trusted networks.

### Normal Mode (Default)
- All new devices require approval
- Static DHCP leases bypass checks

### Blacklist Mode
- Only MACs in the blacklist require approval
- All other MACs are auto-approved for 24 hours
- Auto-approved devices send informational message (not approval request)
- Static DHCP leases still bypass all checks

### Use Cases
- ✅ Home networks where most devices are trusted
- ✅ Guest networks with a few restricted devices
- ✅ Simplified management when you have more trusted than untrusted devices

### Example Workflow
```bash
# Enable blacklist mode
Send: BLON

# Add suspicious device to blacklist
Send: BLADD aa:bb:cc:dd:ee:ff

# Check status
Send: BLSTATUS

# Now only aa:bb:cc:dd:ee:ff will require approval
# All other devices auto-approved for 24h
```

## 🏗️ Architecture

### Event Pipeline

```
Device Connects (DHCP)
        ↓
dnsmasq_trigger.sh (DHCP event → ubus)
        ↓
gatekeeper_trigger.sh (ubus listener + rate limiting)
        ↓
gatekeeper.sh — validation order:
  1. static lease?       → silent allow (static_macs)
  2. denied_macs?        → silent exit
  3. approved_macs?      → silent exit
  4. disabled flag?      → exit
  5. blacklist mode ON,
     MAC not blacklisted? → auto-approve 24h, info message
  6. active schedule?    → auto-approve until window end (silent
                            unless SCHEDNOTIFY ON)
  7. otherwise           → Telegram notification with Approve/Deny
        ↓
Telegram Notification (Approve/Deny buttons)   ← only if step 7
        ↓
tg_bot.sh (handles user response, callbacks, all bot commands)
        ↓
nftables (approved_macs or denied_macs)
```

In parallel, `tg_bot.sh`'s polling loop runs `scheduler_tick` every iteration (~30 s)
to push/pop `approved_macs` at schedule window boundaries — independent of any
DHCP event.

### Firewall Sets (nftables)

The system uses 4 nftables sets for access control:

| Set | Purpose | Timeout |
|-----|---------|---------|
| `static_macs` | Permanent whitelist (static DHCP leases) | None |
| `approved_macs` | Temporarily approved guests | 30 min (or 24h in blacklist mode) |
| `denied_macs` | Explicitly denied devices | 30 min |
| `blacklist_macs` | MACs requiring approval in blacklist mode | None |

### File Structure

```
/usr/bin/
├── gatekeeper.sh              # Main approval handler
├── tg_bot.sh                  # Telegram bot daemon
├── gatekeeper_trigger.sh      # Ubus event listener
├── dnsmasq_trigger.sh         # DHCP event bridge
└── gatekeeper_sync.sh         # Manual sync utility

/usr/lib/gatekeeper/
└── restore_helpers.sh         # Shared library — sourced by tg_bot.sh
                               # and (if installed) the LuCI rpcd backend

/etc/gatekeeper/
└── gatekeeper.nft             # Firewall rules & set definitions

/etc/init.d/
├── gatekeeper_init            # Static/blacklist MAC sync at boot
├── tg_gatekeeper              # Bot daemon manager
└── gatekeeper_trigger_listener # Ubus listener daemon

/etc/config/
└── gatekeeper                 # UCI configuration

/tmp/ (runtime state)
├── tg_offset                  # Telegram update tracking
├── gatekeeper.log             # Activity logs
├── mac_names                  # Device hostname cache
├── mac_map                    # Device ID mapping (STATUS/EXTEND/REVOKE)
├── denied_mac_map             # Denied device ID mapping (DSTATUS/DEXTEND/DREVOKE)
├── dns_locks/                 # Rate limiting timestamps (one file per MAC)
├── gatekeeper_timer_<MAC>     # Per-MAC 5-min auto-deny timer PID
├── sched_active               # Currently-active schedules (rebuilt every scheduler_tick)
└── sched_lock                 # flock guard for scheduler_tick single-flight

# Installed by the optional `luci-app-gatekeeper` ipk:
/usr/libexec/rpcd/
└── gatekeeper                 # rpcd ubus backend (POSIX shell, 31 methods)

/usr/share/luci/menu.d/
└── luci-app-gatekeeper.json   # LuCI menu manifest (Services → Gatekeeper)

/usr/share/rpcd/acl.d/
└── luci-app-gatekeeper.json   # rpcd ACL definitions

/www/luci-static/resources/view/gatekeeper/
├── overview.js                # Overview page (status cards + log tail)
├── devices.js                 # Devices page (active / denied / static tables)
├── blacklist.js               # Blacklist page (mode toggle + MAC editor)
├── schedules.js               # Schedules page (CRUD + day-preset modal)
├── backup_restore.js          # Backup / Restore page
└── settings.js                # Settings page (token / chat_id / Test bot)
```

## 🔧 Configuration

### UCI Configuration (`/etc/config/gatekeeper`)

```bash
config gatekeeper 'main'
    option token 'YOUR_TELEGRAM_BOT_TOKEN'
    option chat_id 'YOUR_TELEGRAM_CHAT_ID'
    option blacklist_mode '0'      # 0=OFF, 1=ON
    option disabled '0'            # 0=active, 1=emergency-disabled (set by DISABLE)
    option schedule_notify '0'     # 0=silent, 1=info message on schedule auto-approve

config blacklist 'blacklist'
    list mac 'aa:bb:cc:dd:ee:ff'   # Optional blacklist entries
    list mac '11:22:33:44:55:66'

# One section per scheduled auto-approval window. Multiple sections per MAC
# are allowed (e.g. weekday vs. weekend). Manage via SCHEDADD / SCHEDLIST /
# SCHEDREMOVE / SCHEDOFF / SCHEDON Telegram commands.
config schedule 'sched_kids_eve'
    option mac 'aa:bb:cc:dd:ee:ff'
    option days 'weekdays'         # daily | weekdays | weekends | mon,tue,...
    option start '16:00'            # HH:MM, router local TZ
    option stop '20:00'             # stop ≤ start ⇒ crosses midnight
    option label 'Kids tablet evening'  # optional, display-only
    option enabled '1'              # 0 ⇒ paused (toggled by SCHEDOFF/SCHEDON)
```

### View Current Configuration

```bash
uci show gatekeeper
```

### Modify Configuration

```bash
# Enable blacklist mode
uci set gatekeeper.main.blacklist_mode='1'
uci commit gatekeeper
/etc/init.d/tg_gatekeeper restart
```

## 🛠️ Maintenance Commands

| Action | Command |
|--------|---------|
| Apply firewall changes | `fw4 reload` |
| Restart bot | `/etc/init.d/tg_gatekeeper restart` |
| Restart trigger listener | `/etc/init.d/gatekeeper_trigger_listener restart` |
| View live logs | `logread -f \| grep -E "gatekeeper\|tg_bot"` |
| Check bot process | `ps \| grep tg_bot` |
| Check nftables sets | `nft list set inet fw4 approved_macs` |
| Manual MAC approval | `nft add element inet fw4 approved_macs { MAC timeout 30m }` |
| Emergency disable | Send `DISABLE` to bot, or `nft flush chain inet fw4 gatekeeper_forward` |
| Re-enable | Send `ENABLE` to bot, or `fw4 reload` |

## 🐛 Troubleshooting

### Bot not responding to commands

1. Check bot is running:
   ```bash
   ps | grep tg_bot
   ```

2. Check logs:
   ```bash
   logread | grep tg_bot
   ```

3. Verify configuration:
   ```bash
   uci show gatekeeper
   ```

4. Restart bot:
   ```bash
   /etc/init.d/tg_gatekeeper restart
   ```

### No notifications for new devices

1. Check trigger listener is running:
   ```bash
   ps | grep gatekeeper_trigger
   ```

2. Verify dnsmasq configuration:
   ```bash
   uci show dhcp.@dnsmasq[0].dhcpscript
   ```

3. Check logs:
   ```bash
   logread -f | grep -E "DNS_LISTENER|gatekeeper"
   ```

4. Test manually:
   ```bash
   /usr/bin/gatekeeper.sh "add" "aa:bb:cc:dd:ee:ff" "192.168.1.100" "test-device" "add"
   ```

### Firewall rules not working

1. Verify nftables sets exist:
   ```bash
   nft list sets | grep gatekeeper
   ```

2. Check firewall include is configured:
   ```bash
   uci show firewall | grep gatekeeper
   ```

3. Reload firewall:
   ```bash
   fw4 reload
   ```

4. Check rule statistics:
   ```bash
   nft list chain inet fw4 gatekeeper_forward
   ```

### Duplicate notifications

This is usually caused by rate limiting issues:

```bash
# Clear rate limit locks
rm -rf /tmp/dns_locks/*

# Restart trigger listener
/etc/init.d/gatekeeper_trigger_listener restart
```

## 📚 Additional Documentation

- **[DEPLOY.md](DEPLOY.md)** - Detailed deployment guide, including LuCI ipk install instructions
- **[QUICK_REFERENCE.md](QUICK_REFERENCE.md)** - Cheat sheet for the most common commands and workflows
- **[CHANGELOG.md](CHANGELOG.md)** - Release history and feature additions
- **[CLAUDE.md](CLAUDE.md)** - Technical documentation for developers and AI assistants
- **[deploy.sh](deploy.sh)** - Automated deployment script (runtime package; LuCI app installs separately via `opkg install`)

## 🔄 Updating

### Using Deploy Script

```bash
# Update code on your local machine (git pull, make changes, etc.)
git pull

# Deploy updates to router
./deploy.sh 192.168.1.1

# Deploy without overwriting existing config (preserves token/chat_id/settings)
./deploy.sh 192.168.1.1 --no-config

# Deploy runtime + the LuCI app (also restarts rpcd so the new plugin is picked up)
./deploy.sh 192.168.1.1 --luci

# Iterate on LuCI files only (skip runtime; faster for rpcd/frontend work)
./deploy.sh 192.168.1.1 --luci-only

# Prompt once for the router root password (requires `sshpass`); avoids
# repeated password prompts during the deploy. SSH keys are still preferred
# for unattended use (ssh-copy-id root@router).
./deploy.sh 192.168.1.1 --ask-password

# Services will be restarted automatically
```

### Manual Update

```bash
# Copy updated files
scp gatekeeper.sh root@192.168.1.1:/usr/bin/
scp tg_bot.sh root@192.168.1.1:/usr/bin/

# Restart services
ssh root@192.168.1.1 << 'EOF'
/etc/init.d/tg_gatekeeper restart
/etc/init.d/gatekeeper_trigger_listener restart
EOF
```

### Updating the LuCI app

The LuCI app ships as a separate ipk and updates independently of the runtime package. No service restart is needed — the new files are picked up on the next page load:

```bash
scp luci-app-gatekeeper_<new-version>_all.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/luci-app-gatekeeper_<new-version>_all.ipk"
```

The `.ipk` is built and attached to every tagged GitHub Release alongside the runtime package — see [CHANGELOG.md](CHANGELOG.md) for release notes.

## 🔐 Security Considerations

- **MAC Spoofing**: MAC addresses can be spoofed. This is Layer 2 security only.
- **Designed for Home/SMB**: Not suitable for enterprise security requirements
- **Telegram Security**: Uses HTTPS with token authentication
- **Access Control**: Only responds to configured chat ID
- **State Files**: `/tmp` files are cleared on reboot (non-persistent)

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Test on your OpenWrt router
4. Submit a pull request

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details

## 👤 Author

Naresh Mehta - [naresh.se](https://www.naresh.se/)

## 🙏 Acknowledgments

- OpenWrt community
- Telegram Bot API
- nftables developers

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/wolverine2k/gale-gatekeeper/issues)
- **Discussions**: [GitHub Discussions](https://github.com/wolverine2k/gale-gatekeeper/discussions)

---

⭐ If you find this project useful, please give it a star on GitHub!
