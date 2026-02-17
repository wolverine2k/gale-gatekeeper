# Gatekeeper - Telegram Network Access Control for OpenWrt

A Telegram-based network access control system for OpenWrt routers. Get instant notifications when devices connect to your network and approve/deny access with a simple button press.

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
- **Blacklist Mode** ⭐ NEW - Invert approval logic: only blacklisted MACs require approval, all others are auto-approved for 24 hours
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
git clone https://github.com/yourusername/gale-gatekeeper.git
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

## 📱 Telegram Commands

### Device Management
| Command | Description |
|---------|-------------|
| `HELP` | Display all available commands |
| `STATUS` | Show active approved guests with IDs |
| `DSTATUS` | Show all denied devices |
| `EXTEND [ID]` | Extend timeout for guest by ID (+30 min) |
| `REVOKE [ID]` | Immediately revoke network access |
| `DEXTEND [ID]` | Extend denial timeout (+30 min) |
| `DREVOKE [ID]` | Remove device from denied list |

### Blacklist Mode ⭐ NEW
| Command | Description |
|---------|-------------|
| `BL_ON` | Enable blacklist mode (only blacklisted MACs require approval) |
| `BL_OFF` | Disable blacklist mode (return to normal mode) |
| `BL_STATUS` | Show blacklist mode status and list MACs |
| `BL_ADD [MAC]` | Add MAC to blacklist (e.g., `BL_ADD aa:bb:cc:dd:ee:ff`) |
| `BL_REMOVE [MAC]` | Remove MAC from blacklist |
| `BL_CLEAR` | Clear all MACs from blacklist |

### System Control
| Command | Description |
|---------|-------------|
| `SYNC` | Manually resync static DHCP MACs |
| `ENABLE` | Re-enable gatekeeper (clear bypass) |
| `DISABLE` | Emergency disable (bypass all filtering) |
| `LOG` | Display recent activity logs |
| `CLEAR` | Clear logs and hostname cache |

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
Send: BL_ON

# Add suspicious device to blacklist
Send: BL_ADD aa:bb:cc:dd:ee:ff

# Check status
Send: BL_STATUS

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
gatekeeper.sh (approval logic + blacklist mode)
        ↓
Telegram Notification (Approve/Deny buttons)
        ↓
tg_bot.sh (handles user response)
        ↓
nftables (approved_macs or denied_macs)
```

### Firewall Sets (nftables)

The system uses 5 nftables sets for access control:

| Set | Purpose | Timeout |
|-----|---------|---------|
| `static_macs` | Permanent whitelist (static DHCP leases) | None |
| `approved_macs` | Temporarily approved guests | 30 min (or 24h in blacklist mode) |
| `denied_macs` | Explicitly denied devices | 30 min |
| `bypass_switch` | Emergency global bypass | None |
| `blacklist_macs` | MACs requiring approval in blacklist mode | None |

### File Structure

```
/usr/bin/
├── gatekeeper.sh              # Main approval handler
├── tg_bot.sh                  # Telegram bot daemon
├── gatekeeper_trigger.sh      # Ubus event listener
├── dnsmasq_trigger.sh         # DHCP event bridge
└── gatekeeper_sync.sh         # Manual sync utility

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
├── mac_map                    # Device ID mapping
├── denied_mac_map             # Denied device ID mapping
└── dns_locks/                 # Rate limiting timestamps
```

## 🔧 Configuration

### UCI Configuration (`/etc/config/gatekeeper`)

```bash
config gatekeeper 'main'
    option token 'YOUR_TELEGRAM_BOT_TOKEN'
    option chat_id 'YOUR_TELEGRAM_CHAT_ID'
    option blacklist_mode '0'  # 0=OFF, 1=ON

config blacklist 'blacklist'
    list mac 'aa:bb:cc:dd:ee:ff'  # Optional blacklist entries
    list mac '11:22:33:44:55:66'
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
| Emergency disable | `nft add element inet fw4 bypass_switch { ff:ff:ff:ff:ff:ff }` |
| Re-enable | `nft flush set inet fw4 bypass_switch` |

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

- **[DEPLOY.md](DEPLOY.md)** - Detailed deployment guide with manual instructions
- **[CLAUDE.md](CLAUDE.md)** - Technical documentation for developers and AI assistants
- **[deploy.sh](deploy.sh)** - Automated deployment script

## 🔄 Updating

### Using Deploy Script

```bash
# Update code on your local machine (git pull, make changes, etc.)
git pull

# Deploy updates to router
./deploy.sh 192.168.1.1

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

- **Issues**: [GitHub Issues](https://github.com/yourusername/gale-gatekeeper/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/gale-gatekeeper/discussions)

---

⭐ If you find this project useful, please give it a star on GitHub!
