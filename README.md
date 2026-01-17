## File structure in OpenWRT (Tested on Gale)

-------------
File: /etc/gatekeeper.nft
Purpose: Defines the blocking logic and the "Global Bypass" switch.
-------------
File: /usr/bin/gatekeeper.sh
Purpose: Detects new devices and sends "Approve/Deny" buttons to Telegram.
-------------
File: /usr/bin/tg_bot.sh
Purpose: Handles interactive commands (Status, Extend, Revoke, Enable/Disable).
-------------
File: /etc/init.d/gatekeeper_init
Purpose: Init script for starting gatekeeper for static IP Syncs
-------------
File: /etc/init.d/tg_gatekeeper
Purpose: Bot watchdog service.
-------------
File: /usr/bin/gatekeeper_sync.sh
Purpose: Keep the static mac address list synchronized on sync execution from bot.
-------------
File: /usr/bin/dnsmasq_trigger.sh
Purpose: dnsmasq triggers my script when it detects an event.
-------------
File: /usr/bin/gatekeeper_trigger.sh
Purpose: Trigger the gatekeeper.sh script after detecting the ubus event from dnsmasq_trigger.
-------------
File: /etc/init.d/gatekeeper_trigger_listener
Purpose: Start the listener trigger automatically on reboot
-------------

-------------
-------------


## Maintenance Commands

|Action|Command|
|------|-------|
|Apply Config Changes|fw4 reload|
|Restart the Bot|/etc/init.d/tg_gatekeeper restart|
|View System Log|logread -f|
|Manually Approve MAC|nft add element inet fw4 approved_macs { MAC timeout 30m }|
|Emergency Off|nft add element inet fw4 bypass_switch { ff:ff:ff:ff:ff:ff }|
|Emergency On|nft flush set inet fw4 bypass_switch|

## Installation Summary
- Install requirements: opkg update && opkg install jq curl.
- Create all files above with correct permissions (chmod +x).
- Set DHCP script: uci set dhcp.@dnsmasq[0].dhcp_script='/usr/bin/gatekeeper.sh' && uci commit dhcp.
- Add firewall include: 
``` 
uci add firewall include && uci set firewall.@include[-1].path='/etc/gatekeeper.nft' && uci set firewall.@include[-1].type='script' && uci commit firewall.
```
- Enable services: /etc/init.d/tg_gatekeeper enable && /etc/init.d/gatekeeper_init enable.
- Restart router.

## Deployment Checklist:
- Verify TOKEN and CHAT_ID in /usr/bin/gatekeeper.sh and /usr/bin/tg_bot.sh
- Ensure /etc/gatekeeper.nft has #!/bin/sh at the top
- Run: chmod +x /usr/bin/gatekeeper.sh /usr/bin/tg_bot.sh /etc/gatekeeper.nft
- Run: /etc/init.d/firewall restart
- Run: /etc/init.d/tg_gatekeeper start
- Test using 'Status' button in Telegram.
- 
# 1. Point dnsmasq to your notification script
uci set dhcp.@dnsmasq[0].dhcpscript='/usr/bin/dnsmasq_trigger.sh'
uci set dhcp.@dnsmasq[0].dhcp_script='/usr/bin/dnsmasq_trigger.sh'


# 2. Commit the changes to system config
uci commit dhcp

# 3. Restart the DHCP service to apply
/etc/init.d/dnsmasq restart
