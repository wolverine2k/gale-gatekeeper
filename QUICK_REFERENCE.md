# Gatekeeper Quick Reference

## 🚀 One-Line Deployment

```bash
./deploy.sh 192.168.1.1
```

## 📱 Most Used Telegram Commands

| Command | What It Does |
|---------|--------------|
| `STATUS` | Show active devices |
| `HELP` | List all commands |
| `BL_ON` | Enable blacklist mode (trust all except blacklist) |
| `BL_OFF` | Disable blacklist mode (require approval for all) |
| `BL_ADD aa:bb:cc:dd:ee:ff` | Add device to blacklist |
| `EXTEND 1` | Give device #1 more time (+30 min) |
| `REVOKE 1` | Kick device #1 off network |

## 🛠️ Common SSH Commands

### Check if services are running
```bash
ps | grep -E "tg_bot|gatekeeper_trigger"
```

### View live logs
```bash
logread -f | grep -E "gatekeeper|tg_bot"
```

### Restart services
```bash
/etc/init.d/tg_gatekeeper restart
/etc/init.d/gatekeeper_trigger_listener restart
```

### Check firewall sets
```bash
nft list set inet fw4 approved_macs
nft list set inet fw4 blacklist_macs
```

### View configuration
```bash
uci show gatekeeper
```

### Emergency disable
```bash
nft add element inet fw4 bypass_switch { ff:ff:ff:ff:ff:ff }
```

### Re-enable
```bash
nft flush set inet fw4 bypass_switch
```

## 🎯 Blacklist Mode Quick Guide

### When to use blacklist mode
- Home network with mostly trusted devices ✅
- Only a few devices need monitoring ✅
- You trust your network by default ✅

### How it works
- **OFF** (default): All devices need approval
- **ON**: Only blacklisted devices need approval, others auto-approved for 24h

### Quick setup
```bash
# In Telegram
BL_ON                           # Enable blacklist mode
BL_ADD aa:bb:cc:dd:ee:ff       # Add suspicious device to blacklist
BL_STATUS                       # Check status

# Now only aa:bb:cc:dd:ee:ff requires approval
# All other devices automatically approved for 24 hours
```

## 🚨 Troubleshooting Quick Fixes

### Bot not responding
```bash
ssh root@router
/etc/init.d/tg_gatekeeper restart
```

### Not getting notifications
```bash
ssh root@router
/etc/init.d/gatekeeper_trigger_listener restart
```

### Firewall not blocking
```bash
ssh root@router
fw4 reload
```

### Duplicate notifications
```bash
ssh root@router
rm -rf /tmp/dns_locks/*
/etc/init.d/gatekeeper_trigger_listener restart
```

## 📝 Configuration Files

| File | Purpose |
|------|---------|
| `/etc/config/gatekeeper` | Bot token, chat ID, blacklist mode |
| `/etc/gatekeeper/gatekeeper.nft` | Firewall rules |
| `/tmp/gatekeeper.log` | Activity logs |

## 🔑 First Time Setup Checklist

- [ ] Install dependencies: `opkg install jq curl coreutils coreutils-timeout`
- [ ] Get bot token from [@BotFather](https://t.me/botfather)
- [ ] Get chat ID from [@userinfobot](https://t.me/userinfobot)
- [ ] Deploy with `./deploy.sh ROUTER_IP`
- [ ] Configure: `uci set gatekeeper.main.token='...'`
- [ ] Configure: `uci set gatekeeper.main.chat_id='...'`
- [ ] Commit: `uci commit gatekeeper`
- [ ] Enable services on boot
- [ ] Configure dnsmasq trigger
- [ ] Configure firewall include
- [ ] Test with `STATUS` command

## 💡 Pro Tips

1. **Use blacklist mode for home networks** - Much easier than approving every device
2. **Add guest devices to blacklist temporarily** - They'll need approval while blacklist mode is on
3. **Use STATUS before extending** - See which device is which ID
4. **Set up SSH keys** - Makes deployment faster (no password prompt)
5. **Keep logs clean** - Send `CLEAR` periodically to clean up old data
6. **Check logs when debugging** - `logread -f` is your friend

## 🔗 Links

- Full documentation: [README.md](README.md)
- Deployment guide: [DEPLOY.md](DEPLOY.md)
- Technical docs: [CLAUDE.md](CLAUDE.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)

---

**Remember**: Send `HELP` to your Telegram bot anytime to see all available commands!
