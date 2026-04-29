# Gatekeeper Quick Reference

## 🚀 One-Line Deployment

```bash
./deploy.sh 192.168.1.1                  # runtime gatekeeper only
./deploy.sh 192.168.1.1 --luci           # runtime + LuCI app (restarts rpcd)
./deploy.sh 192.168.1.1 --luci-only      # iterate on LuCI files only
./deploy.sh 192.168.1.1 --no-config      # preserve existing /etc/config/gatekeeper
./deploy.sh 192.168.1.1 --ask-password   # prompt once for router password (needs sshpass)
```

## 🖥️ LuCI Web UI (optional)

Install the sibling ipk to get a browser-based admin interface:

```bash
scp luci-app-gatekeeper_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/luci-app-gatekeeper_*.ipk"
```

Then browse to `http://<router-ip>/cgi-bin/luci → Services → Gatekeeper`. Six pages:

| Page | Use it for |
|------|------------|
| Overview | Status cards, counts, live log tail |
| Devices | Approve / deny / extend / revoke active + denied devices |
| Blacklist | Toggle blacklist mode + edit MAC list |
| Schedules | Create / pause / delete time-window auto-approvals |
| Backup / Restore | Browser download / upload + preview-then-apply |
| Settings | Edit token / chat_id / mode flags + Test bot connection |

The LuCI app is independent of the Telegram bot — both can run, neither needs to.

## 📱 Most Used Telegram Commands

| Command | What It Does |
|---------|--------------|
| `STATUS` | Show active devices |
| `HELP` | List all commands |
| `BLON` | Enable blacklist mode (trust all except blacklist) |
| `BLOFF` | Disable blacklist mode (require approval for all) |
| `BLADD aa:bb:cc:dd:ee:ff` | Add device to blacklist |
| `EXTEND 1` | Give device #1 more time (+30 min default) |
| `EXTEND 1 2` | Give device #1 more time (+2 hours) |
| `REVOKE 1` | Kick device #1 off network |
| `SCHEDADD <mac> <days> <start>-<stop> [name]` | Add scheduled auto-approve |
| `SCHEDLIST [mac]` | List schedules |
| `SCHEDSHOW <name>` | Show schedule detail |
| `SCHEDREMOVE <name>` | Delete schedule |
| `SCHEDOFF <name>` / `SCHEDON <name>` | Pause/resume schedule |
| `SCHEDNOTIFY ON\|OFF\|STATUS` | Toggle schedule notifications |
| `BACKUP [NOSECRETS]` | Send config backup as Telegram file |
| `RESTORE` (reply to file) | Begin restore from backup file |
| `YES` (reply to preview) | Confirm pending restore |

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
# Via Telegram bot:
DISABLE
# Or directly on router:
nft flush chain inet fw4 gatekeeper_forward
```

### Re-enable
```bash
# Via Telegram bot:
ENABLE
# Or directly on router:
fw4 reload
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
BLON                           # Enable blacklist mode
BLADD aa:bb:cc:dd:ee:ff       # Add suspicious device to blacklist
BLSTATUS                       # Check status

# Now only aa:bb:cc:dd:ee:ff requires approval
# All other devices automatically approved for 24 hours
```

## ⏰ Scheduled Auto-Approval Quick Guide

### When to use scheduled approval
- Devices you want online only at specific times (kid's tablet, work laptop, IoT) ✅
- You're tired of tapping Approve every day at the same hour ✅
- You want a recurring window without managing it manually ✅

### How it works
- A `scheduler_tick` runs every ~30s in `tg_bot.sh`'s polling loop
- Inside an active window: MAC is auto-approved silently (and `STATUS` tags it `⏰ <name>`)
- At window end: MAC is removed from `approved_macs`; reconnect goes through normal approval
- Cross-midnight (`stop ≤ start`) is supported and anchored to the start day
- Multiple schedules per MAC are allowed

### Quick setup
```bash
# In Telegram (note: UCI section names use underscores, not hyphens)
SCHEDADD aa:bb:cc:dd:ee:ff weekdays 16:00-20:00 kids_eve
SCHEDADD aa:bb:cc:dd:ee:ff weekends 09:00-21:00            # name auto-generated
SCHEDLIST                                                    # see active windows tagged ⏰
SCHEDSHOW kids_eve                                           # full details
SCHEDOFF kids_eve                                            # pause without deleting
SCHEDON  kids_eve                                            # resume
SCHEDREMOVE kids_eve                                         # delete
SCHEDNOTIFY ON                                               # info message on each schedule auto-approve
```

## 💾 Backup & Restore Quick Guide

### Backup
```bash
# In Telegram
BACKUP                         # full snapshot, includes token + chat_id
BACKUP NOSECRETS               # token / chat_id blanked before upload
```
The bot replies with a `.txt` document. The temp file in `/tmp` is deleted after upload — Telegram chat history is the archive.

### Restore
```bash
# In Telegram
# 1. Reply RESTORE to a backup file message
RESTORE
# 2. Bot replies with a preview (additive merge plan)
# 3. Reply YES to that preview within 10 minutes to apply
YES
```
Restore is **additive only**: existing entries are skipped, missing ones added. `token` / `chat_id` are never overwritten. Failures during apply roll back via `uci revert`.

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
| `/etc/config/gatekeeper` | Bot token, chat ID, blacklist mode, `schedule_notify`, `disabled` flag, blacklist list, schedule sections |
| `/etc/config/dhcp` | Static DHCP host entries (read by gatekeeper for static-lease bypass) |
| `/etc/gatekeeper/gatekeeper.nft` | Firewall rules — includes definitions for the four nftables sets |
| `/tmp/gatekeeper.log` | Activity logs (auto-rotates at 1000 lines) |
| `/tmp/sched_active` | Currently-active schedules (rebuilt every `scheduler_tick`) |

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
3. **Use STATUS before extending** - See which device is which ID; STATUS also shows `⏰ <name>` for schedule-driven approvals
4. **Run `BACKUP` before major changes** - You can `RESTORE` if something goes wrong. Use `BACKUP NOSECRETS` if you plan to share the file outside your private chat
5. **UCI section names disallow hyphens** - `SCHEDADD … living-room-tv` will fail; use `living_room_tv` (the bot now suggests the corrected name automatically)
6. **Schedules persist; pending state doesn't** - Schedule definitions in UCI survive reboots. The pending RESTORE preview state in `/tmp` does not — reboot or wait > 10 min and the pending preview is gone
7. **Set up SSH keys** - Makes deployment faster (no password prompt)
8. **Keep logs clean** - Send `CLEAR` periodically to clean up old data
9. **Check logs when debugging** - `logread -f | grep -E "gatekeeper|tg_bot"` is your friend

## 🔗 Links

- Full documentation: [README.md](README.md)
- Deployment guide: [DEPLOY.md](DEPLOY.md)
- Technical docs: [CLAUDE.md](CLAUDE.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)

---

**Remember**: Send `HELP` to your Telegram bot anytime to see all available commands!
