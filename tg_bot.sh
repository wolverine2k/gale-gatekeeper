#!/bin/sh
#
# The MIT License (MIT)
# Copyright (c) 2026 Naresh Mehta (https://www.naresh.se/)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

# tg_bot.sh - Telegram Bot Interface for Gatekeeper Network Access Control
#
# This script provides an interactive Telegram bot interface for managing network
# access control in real-time. It continuously polls the Telegram Bot API for
# incoming commands and callback queries, allowing administrators to manage device
# access through a conversational interface.
#
# Key Responsibilities:
# - Poll Telegram API for updates (both text commands and inline button callbacks)
# - Process approve/deny button clicks from device notifications
# - Handle interactive text commands (STATUS, EXTEND, REVOKE, etc.)
# - Manage nftables firewall sets for access control
# - Maintain device hostname mappings and activity logs
# - Provide emergency bypass controls (ENABLE/DISABLE)
# - Sync static DHCP leases with firewall whitelist
#
# Architecture:
# - Runs as a continuous daemon managed by procd (via tg_gatekeeper init script)
# - Uses long polling (30s timeout) for efficient real-time updates
# - Maintains update offset to prevent duplicate message processing
# - Integrates with nftables sets: approved_macs, denied_macs, static_macs, blacklist_macs
#
# Command Interface:
# - HELP: Display list of all available commands with descriptions
# - STATUS: Display gatekeeper status and list active guests with temporary IDs
# - DSTATUS: Display all denied devices with hostnames and timeout information
# - EXTEND [ID] [hours]: Extend network access timeout for a specific guest (30 min default, or specify hours)
# - REVOKE [ID]: Immediately revoke network access for a specific guest
# - DEXTEND [ID]: Extend denial timeout for a specific denied device (30 min)
# - DREVOKE [ID]: Remove device from denied list and approve for 30 minutes
# - LOG: Display last 10 entries from activity log
# - SYNC: Manually resynchronize static DHCP leases from UCI to firewall
# - ENABLE: Re-enable gatekeeper (clear bypass switch)
# - DISABLE: Emergency disable gatekeeper (activate global bypass)
# - CLEAR: Clear activity logs and hostname cache
#
# Callback Handlers:
# - approve_[MAC]: Add device to approved_macs set (30 minute timeout)
# - deny_[MAC]: Add device to denied_macs set (30 minute timeout)
#
# State Management:
# - /tmp/tg_offset: Telegram update ID tracking (prevents duplicate processing)
# - /tmp/gatekeeper.log: Activity logs from gatekeeper.sh
# - /tmp/mac_names: Custom hostname cache (MAC=Name pairs)
# - /tmp/mac_map: Temporary device ID-to-MAC mapping (used by STATUS/EXTEND/REVOKE commands)
# - /tmp/denied_mac_map: Temporary device ID-to-MAC mapping (used by DSTATUS/DEXTEND/DREVOKE commands)
#
# Hostname Resolution Priority:
# When displaying device names in STATUS command:
# 1. Custom name map (/tmp/mac_names) - cached during approval
# 2. DHCP leases (/tmp/dhcp.leases) - current network hostnames
# 3. Static UCI config - hostname from UCI DHCP configuration
# 4. Fallback to "Guest" if no hostname found
#
# Security Considerations:
# - Only responds to messages from authorized CHAT_ID
# - All Telegram API communication uses HTTPS with token authentication
# - Validates command arguments before firewall modifications
# - State files in /tmp are non-persistent (cleared on reboot)
#
# Dependencies:
# - curl: Telegram Bot API communication
# - jq: JSON parsing for API responses
# - nft (nftables): Firewall rule management
# - uci: OpenWrt unified configuration interface
#
# Configuration:
# - TOKEN and CHAT_ID read from UCI config (/etc/config/gatekeeper)
# - Can also be provided via environment variables (GATEKEEPER_TOKEN, GATEKEEPER_CHAT_ID)
# - Set via: uci set gatekeeper.@main[0].token='YOUR_TOKEN'
#           uci set gatekeeper.@main[0].chat_id='YOUR_CHAT_ID'
#
# Usage:
# - Typically run as daemon: /etc/init.d/tg_gatekeeper start
# - Manual testing: /bin/sh /usr/bin/tg_bot.sh
# - View logs: logread -f | grep tg_bot
#
# Integration Points:
# - Works alongside gatekeeper.sh (sends initial approval notifications)
# - Reads logs written by gatekeeper.sh for hostname resolution
# - Manages same nftables sets used by gatekeeper.nft firewall rules
# - Controlled by tg_gatekeeper init script with procd management
#
# Error Handling:
# - Logs errors to system logger (logread)
# - Continues polling on network errors (2s retry delay)
# - Validates configuration on startup (exits if TOKEN/CHAT_ID missing)
# - Ignores malformed JSON responses (jq errors suppressed)

# Configuration: Telegram Bot API token and Chat ID from UCI config
# Read from environment variables (set by init script) or fall back to UCI
# Environment variables take precedence for init script compatibility
TOKEN="${GATEKEEPER_TOKEN:-$(uci -q get gatekeeper.main.token)}"
CHAT_ID="${GATEKEEPER_CHAT_ID:-$(uci -q get gatekeeper.main.chat_id)}"

# Validate configuration - exit early if credentials not configured
if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    logger -t tg_bot "ERROR: TOKEN or CHAT_ID not configured. Set via UCI: uci set gatekeeper.@main[0].token='YOUR_TOKEN' && uci set gatekeeper.@main[0].chat_id='YOUR_CHAT_ID'"
    exit 1
fi

# curl options applied to all Telegram API calls to prevent indefinite hangs.
# --connect-timeout: abort if TCP connection not established within 10 seconds.
# --max-time: hard cap on total transfer time (slightly above Telegram's 30s poll).
CURL_OPTS="--connect-timeout 10 --max-time 30"
CURL_POLL_OPTS="--connect-timeout 10 --max-time 60"

# State file paths in /tmp (non-persistent, cleared on reboot)
LOG_FILE="/tmp/gatekeeper.log"        # Activity logs from gatekeeper.sh
NAME_MAP="/tmp/mac_names"             # Custom hostname cache (MAC=Name pairs)
MAP_FILE="/tmp/mac_map"               # Temporary device ID-to-MAC mapping for STATUS
DENIED_MAP_FILE="/tmp/denied_mac_map" # Temporary device ID-to-MAC mapping for DSTATUS
OFFSET_FILE="/tmp/tg_offset"          # Telegram update ID tracking

# Convert an nftables remaining-time string (e.g. "29m59s", "1h2m3s",
# "1d23h59m59s", "59s") to total seconds on stdout. Always called via
# $(...) so variable assignments stay in the subshell.
#
# The `d` branch is important for timeouts ≥ 24h (blacklist-mode auto-approve,
# multi-hour EXTEND): without it the day component would be silently dropped
# and the caller would mis-render or mis-extend the timeout.
parse_remaining_secs() {
    t=$1
    d=0; h=0; m=0; s=0
    [ -n "$(echo "$t" | grep 'd')" ] && d=$(echo "$t" | sed 's/d.*//; s/[^0-9]//g')
    hms=$(echo "$t" | sed 's/^[0-9]*d//')
    [ -n "$(echo "$hms" | grep 'h')" ] && h=$(echo "$hms" | sed 's/h.*//; s/.*[^0-9]//')
    [ -n "$(echo "$hms" | grep 'm')" ] && m=$(echo "$hms" | sed 's/m.*//; s/.*h//; s/[^0-9]//g')
    s=$(echo "$hms" | sed 's/s.*//; s/.*m//; s/.*h//; s/[^0-9]//g')
    [ -z "$s" ] && s=0
    echo $((d * 86400 + h * 3600 + m * 60 + s))
}

# Schedule helpers — kept identical to copies in gatekeeper.sh and the
# unit-test file tests/test_schedule_helpers.sh. When you change one,
# change all three.
expand_days() {
    case "$1" in
        daily)    echo "mon tue wed thu fri sat sun" ;;
        weekdays) echo "mon tue wed thu fri" ;;
        weekends) echo "sat sun" ;;
        *)        echo "$1" | tr ',' ' ' ;;
    esac
}

hm_to_min() {
    echo "$1" | awk -F: '{print $1 * 60 + $2}'
}

window_active_now() {
    days="$1"; start="$2"; stop="$3"; today_dow="$4"; now_hm="$5"
    expanded=$(expand_days "$days")
    start_m=$(hm_to_min "$start")
    stop_m=$(hm_to_min "$stop")
    now_m=$(hm_to_min "$now_hm")

    if [ "$start_m" -lt "$stop_m" ]; then
        # Same-day window
        echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" || return 0
        [ "$now_m" -ge "$start_m" ] || return 0
        [ "$now_m" -lt "$stop_m" ] || return 0
        date -d "today $stop" +%s
    else
        # Cross-midnight: today $start -> tomorrow $stop
        # Derive yesterday from today_dow (no system clock dependency)
        yesterday_dow=$(echo "$today_dow" | awk '
            BEGIN { split("sun mon tue wed thu fri sat", d) }
            { for (i=1;i<=7;i++) if (d[i]==$1) { print d[(i+5)%7+1]; exit } }
        ')
        if echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" \
           && [ "$now_m" -ge "$start_m" ]; then
            date -d "tomorrow $stop" +%s
        elif echo "$expanded" | tr ' ' '\n' | grep -qx "$yesterday_dow" \
             && [ "$now_m" -lt "$stop_m" ]; then
            date -d "today $stop" +%s
        fi
    fi
}

# scheduler_tick — converge approved_macs toward the union of currently-active
# schedules. Called once per main-loop iteration. Idempotent and crash-safe:
# missed ticks are recovered by the next one.
SCHED_ACTIVE_FILE="/tmp/sched_active"
SCHED_LOCK_FILE="/tmp/sched_lock"

scheduler_tick() {
    # Function-local variables — stop pollution of the surrounding loop scope
    # (BusyBox ash supports `local`; helpers below stay sans-`local` because
    # they're always invoked via $(...) and run in their own subshell).
    local NOW_EPOCH DOW HM sec enabled mac days start stop
    local end_epoch remaining old_macs new_macs locked

    # Skip while gatekeeper is in emergency-disabled state.
    [ "$(uci -q get gatekeeper.main.disabled)" = "1" ] && return 0

    # Skip until NTP has set a sane date (first ~60 s after boot).
    [ "$(date +%Y)" -ge 2024 ] || return 0

    # Single-flight: skip if another tick is already running.
    locked=0
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$SCHED_LOCK_FILE"
        flock -n 9 || return 0
        locked=1
    fi

    NOW_EPOCH=$(date +%s)
    DOW=$(date +%a | tr '[:upper:]' '[:lower:]')
    HM=$(date +%H:%M)

    : > "${SCHED_ACTIVE_FILE}.tmp"

    # Iterate UCI schedule sections.
    for sec in $(uci show gatekeeper 2>/dev/null \
                 | sed -n 's/^gatekeeper\.\([^.=]*\)=schedule$/\1/p'); do
        enabled=$(uci -q get "gatekeeper.${sec}.enabled" || echo 1)
        [ "$enabled" = "1" ] || continue

        mac=$(uci -q get "gatekeeper.${sec}.mac" | tr '[:upper:]' '[:lower:]')
        days=$(uci -q get "gatekeeper.${sec}.days")
        start=$(uci -q get "gatekeeper.${sec}.start")
        stop=$(uci -q get "gatekeeper.${sec}.stop")

        [ -n "$mac" ] && [ -n "$days" ] && [ -n "$start" ] && [ -n "$stop" ] || continue

        end_epoch=$(window_active_now "$days" "$start" "$stop" "$DOW" "$HM")
        [ -n "$end_epoch" ] || continue

        # 4b: denied_macs wins.
        if nft list set inet fw4 denied_macs 2>/dev/null | grep -qi "$mac"; then
            continue
        fi

        remaining=$(( end_epoch - NOW_EPOCH ))
        [ "$remaining" -ge 60 ] || continue

        # Idempotent push (delete-then-add is required to update timeout).
        nft "delete element inet fw4 approved_macs { $mac }" 2>/dev/null
        nft "add element inet fw4 approved_macs { $mac timeout ${remaining}s }" 2>/dev/null

        echo "$sec $mac $end_epoch" >> "${SCHED_ACTIVE_FILE}.tmp"
    done

    # Window-end pop: any MAC active last tick but not now -> remove.
    if [ -f "$SCHED_ACTIVE_FILE" ]; then
        old_macs=$(awk '{print $2}' "$SCHED_ACTIVE_FILE" | sort -u)
        new_macs=$(awk '{print $2}' "${SCHED_ACTIVE_FILE}.tmp" | sort -u)
        for mac in $old_macs; do
            if ! echo "$new_macs" | grep -qx "$mac"; then
                nft "delete element inet fw4 approved_macs { $mac }" 2>/dev/null
                echo "$(date '+%Y-%m-%dT%H:%M:%S') $mac - - schedule-window-ended" >> "$LOG_FILE"
            fi
        done
    fi

    mv "${SCHED_ACTIVE_FILE}.tmp" "$SCHED_ACTIVE_FILE"

    # Release the lock fd so it isn't inherited by every child the main loop
    # spawns afterwards (curl, jq, nft, awk, etc.). Re-opened on the next tick.
    [ "$locked" = "1" ] && exec 9<&-
}

# Main event loop: Continuously poll Telegram API for updates
# Uses long polling with 30-second timeout for efficient real-time updates
while true; do
    # Re-read offset from file each iteration. The inner `while read` pipeline
    # runs in a subshell (BusyBox ash), so variable assignments inside it don't
    # propagate to this shell. The file is the authoritative offset store.
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

    # Poll Telegram API for new updates with long polling (30s timeout)
    # Long polling reduces server load compared to frequent short requests
    RESPONSE=$(curl -s $CURL_POLL_OPTS "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=30")
    
    # Skip processing if response is empty (connection timeout/error)
    # Sleep briefly and retry to avoid tight loop on network errors
    [ -z "$RESPONSE" ] && sleep 2 && continue

    # Guard against tight loop on bad API responses (e.g. {"ok":false} on auth
    # errors). RESPONSE is non-empty so the guard above won't fire, but
    # jq '.result[]' produces no output and the inner loop exits immediately,
    # causing the outer loop to spin with no delay and hammer the API.
    echo "$RESPONSE" | jq -e '.result' >/dev/null 2>&1 || { sleep 5; continue; }

    # Rotate log to prevent /tmp (tmpfs) exhaustion — keep last 500 lines
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 1000 ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi

    # Reconcile schedule-driven approvals before processing Telegram updates.
    # Tick is cheap (~tens of ms) and idempotent.
    scheduler_tick

    # Process each update in the response array
    # jq extracts individual update objects as separate lines for sequential processing
    echo "$RESPONSE" | jq -c '.result[]' 2>/dev/null | while read -r row; do

        # Extract and increment update ID to mark this update as processed
        # Prevents duplicate processing on next poll (updates with ID <= offset are excluded)
        UPDATE_ID=$(echo "$row" | jq -r '.update_id')
        OFFSET=$((UPDATE_ID + 1))
        echo "$OFFSET" > "$OFFSET_FILE"

        # === CALLBACK QUERY HANDLER (Inline Button Clicks) ===
        # Processes approve/deny button clicks from device approval notifications
        # Callback data format: "action_MAC" (e.g., "approve_00:11:22:33:44:55")
        CB_DATA=$(echo "$row" | jq -r '.callback_query.data // empty')
        if [ -n "$CB_DATA" ]; then
            # Extract callback context: chat ID, message ID, and callback query ID
            C_ID=$(echo "$row" | jq -r '.callback_query.message.chat.id')
            M_ID=$(echo "$row" | jq -r '.callback_query.message.message_id')
            CB_ID=$(echo "$row" | jq -r '.callback_query.id')

            # Parse callback data: action (approve/deny) and device MAC address
            ACT=$(echo "$CB_DATA" | cut -d'_' -f1)
            MAC=$(echo "$CB_DATA" | cut -d'_' -f2- | tr '[:upper:]' '[:lower:]')  # Normalize to lowercase

            # Process APPROVE action
            if [ "$ACT" = "approve" ]; then
                # Add MAC to approved_macs set with 30-minute timeout
                # Device gains network access immediately via firewall rules
                nft "add element inet fw4 approved_macs { $MAC timeout 30m }"
                
                # Extract hostname from gatekeeper log for display
                # Log format: TIMESTAMP MAC IP HOSTNAME ACTION  →  field 4 = hostname
                H_NAME=$(grep -i "^[^ ]* $MAC " "$LOG_FILE" | tail -n 1 | awk '{print $4}')
                [ "$H_NAME" = "-" ] && H_NAME=""

                # Cache hostname in name map for future STATUS lookups
                if [ -n "$H_NAME" ]; then
                    # Remove old entry if exists (prevents duplicates)
                    sed -i "/$MAC/d" "$NAME_MAP" 2>/dev/null
                    echo "$MAC=$H_NAME" >> "$NAME_MAP"
                fi
                echo "$(date '+%Y-%m-%dT%H:%M:%S') $MAC - ${H_NAME:--} approved" >> "$LOG_FILE"
                OUT="✅ Approved: ${H_NAME:-$MAC}"
            
            # Process DENY action
            else
                # Remove from approved list (if present) and add to denied list
                # 30-minute timeout prevents notification spam for denied devices
                nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
                nft "add element inet fw4 denied_macs { $MAC timeout 30m }"
                echo "$(date '+%Y-%m-%dT%H:%M:%S') $MAC - - denied" >> "$LOG_FILE"
                OUT="❌ Denied: $MAC"
            fi

            # Acknowledge callback query (removes loading indicator in Telegram UI)
            curl -s $CURL_OPTS "https://api.telegram.org/bot$TOKEN/answerCallbackQuery?callback_query_id=$CB_ID" >/dev/null
            
            # Update original message with approval/denial result
            # Replaces interactive buttons with static confirmation message
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/editMessageText" -d "chat_id=$C_ID" -d "message_id=$M_ID" -d "text=$OUT"
            continue
        fi

        # === TEXT COMMAND HANDLER ===
        # Processes text-based commands sent to the bot
        # Only processes commands from authorized CHAT_ID
        TEXT=$(echo "$row" | jq -r '.message.text // empty')
        U_ID=$(echo "$row" | jq -r '.message.chat.id // empty')
        
        # Security check: Ignore messages from unauthorized chats
        [ "$U_ID" != "$CHAT_ID" ] && continue
        
        # Skip empty messages
        [ -z "$TEXT" ] && continue

        # Parse command and optional arguments from message text
        # Convert command to uppercase for case-insensitive matching
        CMD=$(echo "$TEXT" | awk '{print toupper($1)}')
        ARG=$(echo "$TEXT" | awk '{print $2}')
        ARG2=$(echo "$TEXT" | awk '{print $3}')

        # === HELP COMMAND ===
        # Display list of all available commands with descriptions
        # Provides user with comprehensive command reference
        if [ "$CMD" = "HELP" ]; then
            MSG="📖 *Gatekeeper Commands*\n\n"
            MSG="${MSG}*Device Management:*\n"
            MSG="${MSG}\`STATUS\` - Show active approved guests\n"
            MSG="${MSG}\`DSTATUS\` - Show denied devices\n"
            MSG="${MSG}\`EXTEND [ID] [hours]\` - Extend guest timeout (+30m default, or specify hours)\n"
            MSG="${MSG}\`REVOKE [ID]\` - Revoke guest access\n"
            MSG="${MSG}\`DEXTEND [ID]\` - Extend denial timeout (+30m)\n"
            MSG="${MSG}\`DREVOKE [ID]\` - Approve denied device (+30m)\n\n"
            MSG="${MSG}*Blacklist Mode:*\n"
            MSG="${MSG}\`BLON\` - Enable blacklist mode\n"
            MSG="${MSG}\`BLOFF\` - Disable blacklist mode\n"
            MSG="${MSG}\`BLSTATUS\` - Show blacklist status\n"
            MSG="${MSG}\`BLADD [MAC]\` - Add MAC to blacklist\n"
            MSG="${MSG}\`BLREMOVE [MAC]\` - Remove from blacklist\n"
            MSG="${MSG}\`BLCLEAR\` - Clear all blacklist entries\n\n"
            MSG="${MSG}*System Control:*\n"
            MSG="${MSG}\`ENABLE\` - Enable gatekeeper filtering\n"
            MSG="${MSG}\`DISABLE\` - Disable gatekeeper (emergency)\n"
            MSG="${MSG}\`SYNC\` - Resync static DHCP leases\n\n"
            MSG="${MSG}*Maintenance:*\n"
            MSG="${MSG}\`LOG\` - View recent activity logs\n"
            MSG="${MSG}\`CLEAR\` - Clear logs and name cache\n"
            MSG="${MSG}\`HELP\` - Show this help message\n\n"
            MSG="${MSG}💡 _Use STATUS or DSTATUS first to get device IDs_"

            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === STATUS COMMAND ===
        # Display gatekeeper status and list all active guests
        # Shows bypass status, device list with hostnames, and command hints
        elif [ "$CMD" = "STATUS" ]; then
            # Check global bypass status by counting rules in gatekeeper_forward chain
            # If chain is empty (no drop/accept rules), gatekeeper is disabled
            RULE_COUNT=$(nft list chain inet fw4 gatekeeper_forward 2>/dev/null | grep -c "drop\|accept" || echo "0")
            if [ "$RULE_COUNT" = "0" ]; then
                BYPASS="🔓 DISABLED"
            else
                BYPASS="🛡️ ENABLED"
            fi
            
            # Query both approved and denied MAC lists for active timeouts
            # Only shows entries with "expires" timestamp (active timeouts)
            RAW_LIST=$(nft list set inet fw4 approved_macs | grep "expires")

            # Start building status message with bypass state
            MSG="🛡️ *Gatekeeper:* $BYPASS\n📋 *Active Guests:*\n"

            # Clear previous ID-to-MAC mapping (each STATUS creates fresh mapping)
            rm -f "$MAP_FILE"
            
            # Handle empty guest list
            if [ -z "$RAW_LIST" ]; then
                MSG="${MSG}_None active_\n"
            else
                # Process each active guest and assign temporary numeric ID
                count=1
                while read -r line; do
                    # Extract MAC address from nftables output using regex
                    M_ADDR=$(echo "$line" | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")

                    # Extract timeout expiry from nftables output (e.g., "29m59s", "1d2h3m4s")
                    M_TIME=$(echo "$line" | sed 's/.*expires //; s/s.*/s/; s/,//g')

                    # Render absolute expiry timestamp alongside relative remaining time.
                    EXPIRY_TS=$(( $(date +%s) + $(parse_remaining_secs "$M_TIME") ))
                    EXPIRY_STR=$(date -d "@$EXPIRY_TS" '+%Y-%m-%d %H:%M' 2>/dev/null)

                    # Hostname resolution with priority fallback
                    # 1. Custom Name Map (Cached during Approval)
                    H_NAME=$(grep -i "$M_ADDR" "$NAME_MAP" | tail -n 1 | cut -d'=' -f2)

                    # 2. DHCP Leases (Current network hostnames)
                    [ -z "$H_NAME" ] && H_NAME=$(grep -i "$M_ADDR" /tmp/dhcp.leases | awk '{print $4}')

                    # 3. Static UCI Config (Configured static lease hostnames)
                    [ -z "$H_NAME" ] || [ "$H_NAME" = "*" ] && H_NAME=$(uci show dhcp | grep -i "$M_ADDR" | cut -d. -f2 | xargs -I {} uci -q get dhcp.{}.name)

                    # 4. Fallback to "Guest" if no hostname found
                    [ -z "$H_NAME" ] && H_NAME="Guest"

                    # Store ID-to-MAC mapping for EXTEND/REVOKE commands
                    echo "$count=$M_ADDR" >> "$MAP_FILE"

                    # Format guest entry: ID. Hostname, MAC address, remaining time, and absolute expiry
                    if [ -n "$EXPIRY_STR" ]; then
                        MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME}, expires ${EXPIRY_STR})\n"
                    else
                        MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME})\n"
                    fi
                    count=$((count + 1))
                done <<EOF
$RAW_LIST
EOF
                # Add usage hint for managing guests by ID
                MSG="${MSG}\n💡 Reply \`Extend ID\` or \`Extend ID hours\` or \`Revoke ID\`"
            fi

            # Send status message with custom keyboard for quick commands
            # Keyboard provides buttons for common commands (Status, DStatus, Help, etc.)
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"keyboard\":[[{\"text\":\"Status\"},{\"text\":\"DStatus\"},{\"text\":\"Help\"}],[{\"text\":\"Sync\"},{\"text\":\"Enable\"},{\"text\":\"Disable\"}]],\"resize_keyboard\":true}}"

        # === DSTATUS COMMAND ===
        # Display all denied MACs with hostnames and timeout information
        # Shows devices that have been explicitly denied network access
        elif [ "$CMD" = "DSTATUS" ]; then
            # Query denied MAC list for active timeouts
            # Only shows entries with "expires" timestamp (active denials)
            DENIED_LIST=$(nft list set inet fw4 denied_macs | grep "expires")

            # Start building denied devices message
            MSG="🚫 *Denied Devices:*\n"

            # Clear previous denied ID-to-MAC mapping (each DSTATUS creates fresh mapping)
            rm -f "$DENIED_MAP_FILE"

            # Handle empty denied list
            if [ -z "$DENIED_LIST" ]; then
                MSG="${MSG}_No devices currently denied_\n"
            else
                # Process each denied device and assign temporary numeric ID
                count=1
                while read -r line; do
                    # Extract MAC address from nftables output using regex
                    M_ADDR=$(echo "$line" | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")

                    # Extract timeout expiry from nftables output (e.g., "29m59s", "1d2h3m4s")
                    M_TIME=$(echo "$line" | sed 's/.*expires //; s/s.*/s/; s/,//g')

                    # Render absolute expiry timestamp alongside relative remaining time.
                    EXPIRY_TS=$(( $(date +%s) + $(parse_remaining_secs "$M_TIME") ))
                    EXPIRY_STR=$(date -d "@$EXPIRY_TS" '+%Y-%m-%d %H:%M' 2>/dev/null)

                    # Hostname resolution with priority fallback
                    # 1. Custom Name Map (Cached during Approval)
                    H_NAME=$(grep -i "$M_ADDR" "$NAME_MAP" | tail -n 1 | cut -d'=' -f2)

                    # 2. DHCP Leases (Current network hostnames)
                    [ -z "$H_NAME" ] && H_NAME=$(grep -i "$M_ADDR" /tmp/dhcp.leases | awk '{print $4}')

                    # 3. Static UCI Config (Configured static lease hostnames)
                    [ -z "$H_NAME" ] || [ "$H_NAME" = "*" ] && H_NAME=$(uci show dhcp | grep -i "$M_ADDR" | cut -d. -f2 | xargs -I {} uci -q get dhcp.{}.name)

                    # 4. Fallback to "Unknown Device" if no hostname found
                    [ -z "$H_NAME" ] && H_NAME="Unknown Device"

                    # Store ID-to-MAC mapping for DEXTEND/DREVOKE commands
                    echo "$count=$M_ADDR" >> "$DENIED_MAP_FILE"

                    # Format denied device entry: count. Hostname, MAC address, remaining time, and absolute expiry
                    if [ -n "$EXPIRY_STR" ]; then
                        MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME}, expires ${EXPIRY_STR})\n"
                    else
                        MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME})\n"
                    fi
                    count=$((count + 1))
                done <<EOF
$DENIED_LIST
EOF
                # Add usage hint for managing denied devices by ID
                MSG="${MSG}\n💡 Reply \`Dextend ID\` or \`Drevoke ID\`"
            fi

            # Send denied devices message with markdown formatting
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === DEXTEND COMMAND ===
        # Extend denial timeout for a specific denied device
        # Usage: "DEXTEND 1" - extends denial for device ID 1 by 30 minutes
        elif [ "$CMD" = "DEXTEND" ] && [ -n "$ARG" ]; then
            # Lookup MAC address from denied device ID mapping created by DSTATUS
            TARGET_MAC=$(grep "^$ARG=" "$DENIED_MAP_FILE" | cut -d'=' -f2)

            if [ -n "$TARGET_MAC" ]; then
                # Get current remaining time from nftables
                CURRENT_LINE=$(nft list set inet fw4 denied_macs | grep "$TARGET_MAC" | grep "expires")

                if [ -n "$CURRENT_LINE" ]; then
                    # Parse remaining time (format: "29m59s", "15m30s", "59s", or "1d2h…")
                    TIME_STR=$(echo "$CURRENT_LINE" | sed 's/.*expires //; s/s.*/s/; s/,//g')
                    CURRENT_SECONDS=$(parse_remaining_secs "$TIME_STR")

                    # Calculate new timeout (current + 30 minutes = current + 1800 seconds)
                    TOTAL_SECONDS=$((CURRENT_SECONDS + 1800))

                    # Delete existing entry first (required to update timeout)
                    nft "delete element inet fw4 denied_macs { $TARGET_MAC }" 2>/dev/null

                    # Re-add MAC with extended timeout
                    nft "add element inet fw4 denied_macs { $TARGET_MAC timeout ${TOTAL_SECONDS}s }"
                    echo "$(date '+%Y-%m-%dT%H:%M:%S') $TARGET_MAC - - denial-extended+30m" >> "$LOG_FILE"
                    MSG="⏳ Extended denial timeout for $TARGET_MAC (+30m, now ${TOTAL_SECONDS}s total)"
                else
                    # MAC not found or already expired
                    MSG="❌ Device not found in denied list or already expired."
                fi
            else
                # Invalid ID (not in current DSTATUS mapping or DSTATUS not run)
                MSG="❌ Invalid ID. Run DSTATUS first to get denied device IDs."
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === DREVOKE COMMAND ===
        # Remove device from denied list and automatically approve for 30 minutes
        # Usage: "DREVOKE 1" - removes device ID 1 from denied list and grants network access
        elif [ "$CMD" = "DREVOKE" ] && [ -n "$ARG" ]; then
            # Lookup MAC address from denied device ID mapping created by DSTATUS
            TARGET_MAC=$(grep "^$ARG=" "$DENIED_MAP_FILE" | cut -d'=' -f2)

            if [ -n "$TARGET_MAC" ]; then
                # Remove MAC from denied_macs set
                nft "delete element inet fw4 denied_macs { $TARGET_MAC }" 2>/dev/null

                # Automatically approve device for 30 minutes
                nft "add element inet fw4 approved_macs { $TARGET_MAC timeout 30m }"
                echo "$(date '+%Y-%m-%dT%H:%M:%S') $TARGET_MAC - - denial-revoked-approved-30m" >> "$LOG_FILE"
                logger -t tg_bot "Denial revoked, approved 30m: $TARGET_MAC"
                MSG="✅ Removed $TARGET_MAC from denied list and approved for 30 minutes"
            else
                # Invalid ID (not in current DSTATUS mapping or DSTATUS not run)
                MSG="❌ Invalid ID. Run DSTATUS first to get denied device IDs."
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === EXTEND COMMAND ===
        # Extend network access timeout for a specific guest
        # Usage: "EXTEND 1" - extends access for guest ID 1 by 30 minutes (default)
        # Usage: "EXTEND 1 2" - extends access for guest ID 1 by 2 hours
        elif [ "$CMD" = "EXTEND" ] && [ -n "$ARG" ]; then
            # Lookup MAC address from temporary ID mapping created by STATUS
            TARGET_MAC=$(grep "^$ARG=" "$MAP_FILE" | cut -d'=' -f2)

            if [ -n "$TARGET_MAC" ]; then
                # Get current remaining time from nftables
                CURRENT_LINE=$(nft list set inet fw4 approved_macs | grep "$TARGET_MAC" | grep "expires")

                if [ -n "$CURRENT_LINE" ]; then
                    # Parse remaining time (format: "29m59s", "15m30s", "59s", or "1d2h…")
                    TIME_STR=$(echo "$CURRENT_LINE" | sed 's/.*expires //; s/s.*/s/; s/,//g')
                    CURRENT_SECONDS=$(parse_remaining_secs "$TIME_STR")

                    # Determine extension duration: use ARG2 hours if valid, else default 30 minutes
                    if [ -n "$ARG2" ] && echo "$ARG2" | grep -qE '^[0-9]+$' && [ "$ARG2" -gt 0 ]; then
                        EXTEND_SECONDS=$((ARG2 * 3600))
                        EXTEND_LABEL="+${ARG2}h"
                    else
                        EXTEND_SECONDS=1800
                        EXTEND_LABEL="+30m"
                    fi

                    # Calculate new timeout (current + extension)
                    TOTAL_SECONDS=$((CURRENT_SECONDS + EXTEND_SECONDS))

                    # Delete existing entry first (required to update timeout)
                    nft "delete element inet fw4 approved_macs { $TARGET_MAC }" 2>/dev/null

                    # Re-add MAC with extended timeout
                    nft "add element inet fw4 approved_macs { $TARGET_MAC timeout ${TOTAL_SECONDS}s }"
                    echo "$(date '+%Y-%m-%dT%H:%M:%S') $TARGET_MAC - - extended-${EXTEND_LABEL}" >> "$LOG_FILE"
                    MSG="⏳ Extended access for $TARGET_MAC (${EXTEND_LABEL}, now ${TOTAL_SECONDS}s total)"
                else
                    # MAC not found or already expired
                    MSG="❌ Device not found in approved list or already expired."
                fi
            else
                # Invalid ID (not in current STATUS mapping or STATUS not run)
                MSG="❌ Invalid ID."
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === REVOKE COMMAND ===
        # Immediately revoke network access for a specific guest
        # Usage: "REVOKE 1" - blocks guest ID 1 immediately
        elif [ "$CMD" = "REVOKE" ] && [ -n "$ARG" ]; then
            # Lookup MAC address from temporary ID mapping created by STATUS
            TARGET_MAC=$(grep "^$ARG=" "$MAP_FILE" | cut -d'=' -f2)
            
            if [ -n "$TARGET_MAC" ]; then
                # Remove MAC from approved_macs set (blocks network access immediately)
                nft "delete element inet fw4 approved_macs { $TARGET_MAC }" 2>/dev/null
                # Add to denied_macs for 30 minutes to suppress reconnect notifications
                nft "add element inet fw4 denied_macs { $TARGET_MAC timeout 30m }"
                echo "$(date '+%Y-%m-%dT%H:%M:%S') $TARGET_MAC - - revoked" >> "$LOG_FILE"
                logger -t tg_bot "Revoked: $TARGET_MAC"
                MSG="🚫 Revoked access for $TARGET_MAC"
            else
                # Invalid ID (not in current STATUS mapping or STATUS not run)
                MSG="❌ Invalid ID."
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === LOG COMMAND ===
        # Display last 10 entries from gatekeeper activity log
        # Log contains device connection events written by gatekeeper.sh
        elif [ "$CMD" = "LOG" ]; then
            # Read last 20 log entries; report empty state if log file absent or empty
            if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
                LOGS=$(tail -n 20 "$LOG_FILE" | awk '{printf "%s\\n", $0}')
            else
                LOGS="No logs yet."
            fi

            # Send log entries as monospace code block
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"📜 *Recent Logs:*\\n\`$LOGS\`\",\"parse_mode\":\"Markdown\"}"

        # === SYNC COMMAND ===
        # Manually resynchronize static DHCP leases from UCI to firewall
        # Useful after adding/removing static leases in UCI config
        elif [ "$CMD" = "SYNC" ]; then
            # Clear existing static_macs set before rebuilding
            nft flush set inet fw4 static_macs
            
            # Iterate through all UCI DHCP static hosts and add their MACs
            # Some hosts may have multiple MACs (space-separated)
            i=0; while M=$(uci -q get dhcp.@host[$i].mac); do
                for sm in $M; do nft "add element inet fw4 static_macs { $sm }"; done
                i=$((i+1))
            done
            
            # Report number of static leases synchronized
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🔄 Synced $i static leases."

        # === ENABLE COMMAND ===
        # Re-enable gatekeeper after emergency disable
        # Reloads firewall rules to restore normal filtering
        elif [ "$CMD" = "ENABLE" ]; then
            # Clear the persistent disabled flag so gatekeeper.nft re-adds
            # blocking rules on this and all future fw4 reloads.
            uci set gatekeeper.main.disabled='0'
            uci commit gatekeeper

            # Clear rate-limiting locks so devices that reconnect immediately
            # after ENABLE can trigger new approval notifications.
            rm -f /tmp/dns_locks/* 2>/dev/null

            # Reload firewall to restore gatekeeper rules
            # This recreates the gatekeeper_forward chain with all filter rules
            fw4 reload >/dev/null 2>&1

            # Re-sync static MACs (fw4 reload clears all nftables sets)
            nft flush set inet fw4 static_macs 2>/dev/null
            i=0; while SM=$(uci -q get dhcp.@host[$i].mac); do
                for sm in $SM; do nft "add element inet fw4 static_macs { $sm }" 2>/dev/null; done
                i=$((i+1))
            done

            # Re-sync blacklist MACs (fw4 reload clears all nftables sets)
            nft flush set inet fw4 blacklist_macs 2>/dev/null
            BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
            for mac in $BLACKLIST_MACS; do
                [ -z "$mac" ] && continue
                nft "add element inet fw4 blacklist_macs { $mac }" 2>/dev/null
            done

            # Verify that filtering was restored by checking if chain exists
            if nft list chain inet fw4 gatekeeper_forward >/dev/null 2>&1; then
                MSG="🛡️ *Gatekeeper Enabled*\n\nFiltering restored. All devices subject to approval."
            else
                MSG="⚠️ *Warning*\n\nFirewall reload completed but gatekeeper chain not found."
            fi
            echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - gatekeeper-enabled" >> "$LOG_FILE"
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === DISABLE COMMAND ===
        # Emergency disable gatekeeper (global bypass)
        # Allows all LAN→WAN traffic regardless of MAC address
        elif [ "$CMD" = "DISABLE" ]; then
            # Persist the disabled flag in UCI so that automatic fw4 reloads
            # (triggered by network interface events) do not silently re-enable
            # blocking via gatekeeper.nft.
            uci set gatekeeper.main.disabled='1'
            uci commit gatekeeper

            # Flush the gatekeeper_forward chain to remove all filter rules
            # This effectively disables filtering until ENABLE is called
            # The chain still exists but has no rules, so all traffic passes
            nft flush chain inet fw4 gatekeeper_forward 2>/dev/null

            # Verify that filtering was disabled by checking if chain is empty
            RULE_COUNT=$(nft list chain inet fw4 gatekeeper_forward 2>/dev/null | grep -c "drop\|accept" || echo "0")
            if [ "$RULE_COUNT" = "0" ]; then
                MSG="🔓 *Gatekeeper Disabled*\n\n⚠️ All devices now have network access.\n\nSend \`ENABLE\` to restore filtering."
            else
                MSG="⚠️ *Warning*\n\nDisable attempted but some rules remain.\n\nYou may need to manually reload firewall."
            fi
            echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - gatekeeper-disabled" >> "$LOG_FILE"
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === CLEAR COMMAND ===
        # Clear activity logs and hostname cache
        # Useful for privacy or troubleshooting
        elif [ "$CMD" = "CLEAR" ]; then
            # Truncate log file and name map (preserves files but clears content)
            > "$LOG_FILE"
            > "$NAME_MAP"
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🗑️ Logs and name cache cleared."

        # === BLON COMMAND ===
        # Enable blacklist mode - only MACs in blacklist require approval
        # All other MACs are auto-approved with 24-hour timeout
        elif [ "$CMD" = "BLON" ] || [ "$CMD" = "BLACKLIST_ON" ]; then
            # Set blacklist mode to enabled in UCI config
            uci set gatekeeper.main.blacklist_mode='1'
            uci commit gatekeeper

            # Sync blacklist to nftables (in case it's not synced yet)
            nft flush set inet fw4 blacklist_macs 2>/dev/null
            BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
            for mac in $BLACKLIST_MACS; do
                [ -z "$mac" ] && continue
                nft "add element inet fw4 blacklist_macs { $mac }" 2>/dev/null
            done

            echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - blacklist-mode-on" >> "$LOG_FILE"
            MSG="✅ *Blacklist Mode: ENABLED*\n\n"
            MSG="${MSG}Only devices in the blacklist will require approval.\n"
            MSG="${MSG}All other devices will be auto-approved for 24 hours."
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLOFF COMMAND ===
        # Disable blacklist mode - return to normal behavior (all require approval)
        elif [ "$CMD" = "BLOFF" ] || [ "$CMD" = "BLACKLIST_OFF" ]; then
            # Set blacklist mode to disabled in UCI config
            uci set gatekeeper.main.blacklist_mode='0'
            uci commit gatekeeper

            echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - blacklist-mode-off" >> "$LOG_FILE"
            MSG="✅ *Blacklist Mode: DISABLED*\n\n"
            MSG="${MSG}All devices will require approval (normal mode)."
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLSTATUS COMMAND ===
        # Show blacklist mode status and list all blacklisted MACs
        elif [ "$CMD" = "BLSTATUS" ] || [ "$CMD" = "BLACKLIST_STATUS" ]; then
            # Get blacklist mode status from UCI config
            MODE=$(uci -q get gatekeeper.main.blacklist_mode || echo "0")
            if [ "$MODE" = "1" ]; then
                STATUS="ENABLED ✅"
            else
                STATUS="DISABLED ❌"
            fi

            MSG="📋 *Blacklist Status*\n\n"
            MSG="${MSG}*Mode:* ${STATUS}\n\n"
            MSG="${MSG}*Blacklisted MACs:*\n"

            # Get blacklist from UCI config
            BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
            if [ -z "$BLACKLIST_MACS" ]; then
                MSG="${MSG}_(none)_\n"
            else
                count=1
                for mac in $BLACKLIST_MACS; do
                    [ -z "$mac" ] && continue
                    MSG="${MSG}${count}. \`${mac}\`\n"
                    count=$((count + 1))
                done
            fi

            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLADD COMMAND ===
        # Add a MAC address to the blacklist
        # Usage: "BLADD aa:bb:cc:dd:ee:ff"
        elif [ "$CMD" = "BLADD" ] || [ "$CMD" = "BLACKLIST_ADD" ]; then
            if [ -z "$ARG" ]; then
                MSG="❌ Usage: BLADD <MAC>\nExample: BLADD aa:bb:cc:dd:ee:ff"
            else
                # Convert MAC to lowercase for consistency
                ADD_MAC=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')

                # Validate MAC format (basic check)
                if echo "$ADD_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                    # Check for duplicate in UCI config (authoritative source; nftables set may be
                    # empty after reboot if gatekeeper_init hasn't run yet)
                    EXISTING_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | tr '[:upper:]' '[:lower:]')
                    if echo "$EXISTING_MACS" | grep -qx "$ADD_MAC"; then
                        MSG="ℹ️ \`${ADD_MAC}\` is already in the blacklist"
                    else
                        # Check if blacklist section exists, create if not
                        if ! uci -q get gatekeeper.blacklist >/dev/null 2>&1; then
                            uci set gatekeeper.blacklist=blacklist
                        fi

                        # Add to UCI blacklist
                        uci add_list gatekeeper.blacklist.mac="$ADD_MAC"
                        uci commit gatekeeper

                        # Add to nftables set; revoke any existing approval immediately
                        nft "add element inet fw4 blacklist_macs { $ADD_MAC }" 2>/dev/null
                        nft "delete element inet fw4 approved_macs { $ADD_MAC }" 2>/dev/null

                        echo "$(date '+%Y-%m-%dT%H:%M:%S') $ADD_MAC - - bl-added" >> "$LOG_FILE"
                        MSG="✅ Added to blacklist: \`${ADD_MAC}\`"
                        logger -t tg_bot "Added $ADD_MAC to blacklist"
                    fi
                else
                    MSG="❌ Invalid MAC format. Use: aa:bb:cc:dd:ee:ff"
                fi
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLREMOVE COMMAND ===
        # Remove a MAC address from the blacklist
        # Usage: "BLREMOVE aa:bb:cc:dd:ee:ff"
        elif [ "$CMD" = "BLREMOVE" ] || [ "$CMD" = "BLACKLIST_REMOVE" ]; then
            if [ -z "$ARG" ]; then
                MSG="❌ Usage: BLREMOVE <MAC>\nExample: BLREMOVE aa:bb:cc:dd:ee:ff"
            else
                # Convert MAC to lowercase for consistency
                REMOVE_MAC=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')

                # Remove from UCI blacklist
                uci del_list gatekeeper.blacklist.mac="$REMOVE_MAC" 2>/dev/null
                uci commit gatekeeper

                # Remove from nftables set (ignore errors if not present)
                nft "delete element inet fw4 blacklist_macs { $REMOVE_MAC }" 2>/dev/null

                echo "$(date '+%Y-%m-%dT%H:%M:%S') $REMOVE_MAC - - bl-removed" >> "$LOG_FILE"
                MSG="✅ Removed from blacklist: \`${REMOVE_MAC}\`"
                logger -t tg_bot "Removed $REMOVE_MAC from blacklist"
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLCLEAR COMMAND ===
        # Clear all MACs from the blacklist
        elif [ "$CMD" = "BLCLEAR" ] || [ "$CMD" = "BLACKLIST_CLEAR" ]; then
            # Delete and recreate blacklist section in UCI
            uci delete gatekeeper.blacklist 2>/dev/null
            uci set gatekeeper.blacklist=blacklist
            uci commit gatekeeper

            # Clear nftables blacklist set
            nft flush set inet fw4 blacklist_macs 2>/dev/null

            MSG="✅ Blacklist cleared - all MACs removed"
            logger -t tg_bot "Blacklist cleared"
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === SCHEDADD COMMAND ===
        # Add a scheduled auto-approval window.
        # Usage: SCHEDADD <mac> <days> <start>-<stop> [name]
        elif [ "$CMD" = "SCHEDADD" ]; then
            SCHED_MAC=$(echo "$TEXT" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
            SCHED_DAYS=$(echo "$TEXT" | awk '{print $3}' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
            SCHED_WIN=$(echo "$TEXT" | awk '{print $4}')
            SCHED_NAME=$(echo "$TEXT" | awk '{print $5}' | tr '[:upper:]' '[:lower:]')

            # Validate MAC
            if ! echo "$SCHED_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                MSG="❌ Invalid MAC. Usage: SCHEDADD <mac> <days> <start>-<stop> [name]"
            # Validate days
            elif ! { [ "$SCHED_DAYS" = "daily" ] || [ "$SCHED_DAYS" = "weekdays" ] || [ "$SCHED_DAYS" = "weekends" ] \
                   || echo "$SCHED_DAYS" | grep -qE '^(mon|tue|wed|thu|fri|sat|sun)(,(mon|tue|wed|thu|fri|sat|sun))*$'; }; then
                MSG="❌ Invalid days. Use: daily | weekdays | weekends | mon,tue,wed,thu,fri,sat,sun"
            # Validate window
            elif ! echo "$SCHED_WIN" | grep -qE '^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$'; then
                MSG="❌ Invalid window. Use: HH:MM-HH:MM (24h, e.g. 16:00-20:00)"
            else
                SCHED_START=${SCHED_WIN%-*}
                SCHED_STOP=${SCHED_WIN#*-}
                if [ "$SCHED_START" = "$SCHED_STOP" ]; then
                    MSG="❌ start and stop must differ"
                else
                    # Resolve name (auto-generate or validate)
                    if [ -z "$SCHED_NAME" ]; then
                        SUFFIX=$(echo "$SCHED_MAC" | tr -d ':' | cut -c7-12)
                        n=1
                        while uci -q get "gatekeeper.sched_${SUFFIX}_${n}" >/dev/null 2>&1; do
                            n=$((n+1))
                        done
                        SCHED_NAME="sched_${SUFFIX}_${n}"
                        NAME_VALID=1
                    elif ! echo "$SCHED_NAME" | grep -qE '^[a-z0-9_]{1,32}$'; then
                        MSG="❌ Invalid name. Use 1-32 chars of [a-z0-9_]"
                        NAME_VALID=0
                    elif uci -q get "gatekeeper.${SCHED_NAME}" >/dev/null 2>&1; then
                        MSG="❌ Schedule '${SCHED_NAME}' already exists. Use SCHEDREMOVE first."
                        NAME_VALID=0
                    else
                        NAME_VALID=1
                    fi

                    if [ "$NAME_VALID" = "1" ]; then
                        # Static-lease check (warn-but-allow per decision 4d)
                        STATIC_LEASES=$(uci show dhcp 2>/dev/null | grep "\.mac=" | awk -F"='" '{print $2}' | tr -d "'" | tr '[:upper:]' '[:lower:]')
                        WARN=""
                        for sm in $STATIC_LEASES; do
                            if [ "$sm" = "$SCHED_MAC" ]; then
                                WARN="⚠️ MAC has a static DHCP lease; this schedule will have no effect until the static lease is removed.\n\n"
                                break
                            fi
                        done

                        # Persist
                        uci set "gatekeeper.${SCHED_NAME}=schedule"
                        uci set "gatekeeper.${SCHED_NAME}.mac=${SCHED_MAC}"
                        uci set "gatekeeper.${SCHED_NAME}.days=${SCHED_DAYS}"
                        uci set "gatekeeper.${SCHED_NAME}.start=${SCHED_START}"
                        uci set "gatekeeper.${SCHED_NAME}.stop=${SCHED_STOP}"
                        uci set "gatekeeper.${SCHED_NAME}.enabled=1"
                        if uci commit gatekeeper; then
                            scheduler_tick
                            MSG="${WARN}✅ Schedule *${SCHED_NAME}* added: \`${SCHED_MAC}\` ${SCHED_DAYS} ${SCHED_START}–${SCHED_STOP}"
                            echo "$(date '+%Y-%m-%dT%H:%M:%S') ${SCHED_MAC} - - sched-added-${SCHED_NAME}" >> "$LOG_FILE"
                            logger -t tg_bot "Schedule added: ${SCHED_NAME} (${SCHED_MAC} ${SCHED_DAYS} ${SCHED_START}-${SCHED_STOP})"
                        else
                            uci revert gatekeeper 2>/dev/null
                            MSG="❌ Failed to save schedule (UCI commit error)"
                        fi
                    fi
                fi
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
        fi
    done
done