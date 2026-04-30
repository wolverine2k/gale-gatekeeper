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
# - LOG: Display last 20 entries from activity log
# - SYNC: Manually resynchronize static DHCP leases AND blacklist MACs from UCI to firewall
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

# Restore helpers (mac_hostname, is_valid_backup, restore_parse_to_records,
# restore_build_plan) and the RESTORE_* state-file constants for the
# BACKUP/RESTORE feature live in a shared library so the LuCI rpcd backend
# can also source them. NAME_MAP and LOG_FILE must already be defined above
# this line before sourcing.
. /usr/lib/gatekeeper/restore_helpers.sh

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

    # BusyBox `date -d` does NOT accept "today HH:MM" / "tomorrow HH:MM"
    # (only "hh:mm[:ss]", "YYYY-MM-DD hh:mm[:ss]", and "@epoch"). Use the
    # full YYYY-MM-DD form so this works on both BusyBox and GNU date.
    today_ymd=$(date +%Y-%m-%d)
    today_stop_epoch=$(date -d "${today_ymd} ${stop}:00" +%s)

    if [ "$start_m" -lt "$stop_m" ]; then
        # Same-day window
        echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" || return 0
        [ "$now_m" -ge "$start_m" ] || return 0
        [ "$now_m" -lt "$stop_m" ] || return 0
        echo "$today_stop_epoch"
    else
        # Cross-midnight: today $start -> tomorrow $stop
        # Derive yesterday from today_dow (no system clock dependency)
        yesterday_dow=$(echo "$today_dow" | awk '
            BEGIN { split("sun mon tue wed thu fri sat", d) }
            { for (i=1;i<=7;i++) if (d[i]==$1) { print d[(i+5)%7+1]; exit } }
        ')
        if echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" \
           && [ "$now_m" -ge "$start_m" ]; then
            echo $(( today_stop_epoch + 86400 ))
        elif echo "$expanded" | tr ' ' '\n' | grep -qx "$yesterday_dow" \
             && [ "$now_m" -lt "$stop_m" ]; then
            echo "$today_stop_epoch"
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
    DOW=$(date +%a | tr 'A-Z' 'a-z')
    HM=$(date +%H:%M)

    : > "${SCHED_ACTIVE_FILE}.tmp"

    # Iterate UCI schedule sections.
    for sec in $(uci show gatekeeper 2>/dev/null \
                 | sed -n 's/^gatekeeper\.\([^.=]*\)=schedule$/\1/p'); do
        enabled=$(uci -q get "gatekeeper.${sec}.enabled" || echo 1)
        [ "$enabled" = "1" ] || continue

        mac=$(uci -q get "gatekeeper.${sec}.mac" | tr 'A-Z' 'a-z')
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
            MAC=$(echo "$CB_DATA" | cut -d'_' -f2- | tr 'A-Z' 'a-z')  # Normalize to lowercase

            # Process APPROVE action
            if [ "$ACT" = "approve" ]; then
                # Add MAC to approved_macs set with 30-minute timeout.
                # Delete first because nftables won't update an existing
                # element's timeout via "add element" alone — if the MAC is
                # already present (e.g. from an active schedule), the new
                # timeout would silently no-op without the delete.
                nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
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

        # Reply-context fields used by RESTORE / YES handlers.
        REPLY_DOC_ID=$(echo "$row" | jq -r '.message.reply_to_message.document.file_id // empty')
        REPLY_DOC_NAME=$(echo "$row" | jq -r '.message.reply_to_message.document.file_name // empty')
        REPLY_DOC_SIZE=$(echo "$row" | jq -r '.message.reply_to_message.document.file_size // 0')
        REPLY_TO_MSGID=$(echo "$row" | jq -r '.message.reply_to_message.message_id // empty')

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
            MSG="${MSG}\`SYNC\` - Resync static DHCP leases AND blacklist MACs from UCI to firewall\n\n"
            MSG="${MSG}*Schedules:*\n"
            MSG="${MSG}\`SCHEDADD <mac> <days> <start>-<stop> [name]\` - Add auto-approve window\n"
            MSG="${MSG}\`SCHEDLIST [mac]\` - List schedules (filter by MAC optional)\n"
            MSG="${MSG}\`SCHEDSHOW <name>\` - Show schedule details\n"
            MSG="${MSG}\`SCHEDREMOVE <name>\` - Delete a schedule\n"
            MSG="${MSG}\`SCHEDOFF <name>\` / \`SCHEDON <name>\` - Pause/resume\n"
            MSG="${MSG}\`SCHEDNOTIFY ON|OFF|STATUS\` - Toggle schedule notifications\n"
            MSG="${MSG}_Days:_ daily | weekdays | weekends | mon,tue,...\n"
            MSG="${MSG}_Times:_ HH:MM (24h, local TZ). Stop ≤ start = crosses midnight.\n\n"
            MSG="${MSG}*Maintenance:*\n"
            MSG="${MSG}\`LOG\` - View recent activity logs\n"
            MSG="${MSG}\`CLEAR\` - Clear logs and name cache\n"
            MSG="${MSG}\`BACKUP [NOSECRETS]\` - Send config backup as a Telegram file\n"
            MSG="${MSG}\`RESTORE\` (reply to a backup file) - Restore config from a backup; \`YES\` to confirm\n"
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

                    # Tag entries that came from a scheduled push so the user can tell
                    # the difference between manual approvals and schedule-driven ones.
                    SCHED_TAG=""
                    if [ -f "$SCHED_ACTIVE_FILE" ]; then
                        SN=$(grep -i " ${M_ADDR} " "$SCHED_ACTIVE_FILE" | head -n 1 | awk '{print $1}')
                        [ -n "$SN" ] && SCHED_TAG=" ⏰ _${SN}_"
                    fi

                    # Format guest entry: ID. Hostname, MAC address, remaining time,
                    # absolute expiry, and (optional) schedule tag.
                    if [ -n "$EXPIRY_STR" ]; then
                        MSG="${MSG}${count}. *${H_NAME}*${SCHED_TAG}\n   └ \`${M_ADDR}\` (${M_TIME}, expires ${EXPIRY_STR})\n"
                    else
                        MSG="${MSG}${count}. *${H_NAME}*${SCHED_TAG}\n   └ \`${M_ADDR}\` (${M_TIME})\n"
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

                # Delete-before-add on approved_macs too: if the MAC is already
                # approved (e.g. via an active schedule), nftables won't update
                # the existing element's timeout via plain "add element".
                nft "delete element inet fw4 approved_macs { $TARGET_MAC }" 2>/dev/null

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
                # Delete-before-add on denied_macs too: if the MAC is already
                # denied (e.g. from an earlier auto-deny timer), nftables won't
                # refresh the timeout via plain "add element".
                nft "delete element inet fw4 denied_macs { $TARGET_MAC }" 2>/dev/null
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
        # Display last 20 entries from gatekeeper activity log
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
        # Manually resynchronize MAC sets from UCI to firewall — covers BOTH
        # static_macs (static DHCP leases in /etc/config/dhcp) AND blacklist_macs
        # (gatekeeper.blacklist.mac list in /etc/config/gatekeeper). Matches the
        # LuCI Settings page's "Sync MAC sets" button. Useful after editing
        # UCI directly without going through bot/UI commands.
        elif [ "$CMD" = "SYNC" ]; then
            if [ -x /usr/bin/gatekeeper_sync.sh ]; then
                SYNC_OUT=$(/usr/bin/gatekeeper_sync.sh all 2>&1)
                STATIC_COUNT=$(echo "$SYNC_OUT" | grep -oE 'synchronized [0-9]+ static' | grep -oE '[0-9]+' | head -1)
                BL_COUNT=$(echo "$SYNC_OUT" | grep -oE 'synchronized [0-9]+ blacklist' | grep -oE '[0-9]+' | head -1)
                STATIC_COUNT=${STATIC_COUNT:-0}
                BL_COUNT=${BL_COUNT:-0}
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🔄 Synced $STATIC_COUNT static and $BL_COUNT blacklist MACs."
            else
                # Fallback: in-bot static-only sync. Keeps SYNC working even if
                # the helper script is missing — but the user should reinstall.
                nft flush set inet fw4 static_macs
                i=0; while M=$(uci -q get dhcp.@host[$i].mac); do
                    for sm in $M; do nft "add element inet fw4 static_macs { $sm }"; done
                    i=$((i+1))
                done
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🔄 Synced $i static leases (blacklist sync unavailable: gatekeeper_sync.sh missing)."
            fi

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
                ADD_MAC=$(echo "$ARG" | tr 'A-Z' 'a-z')

                # Validate MAC format (basic check)
                if echo "$ADD_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                    # Check for duplicate in UCI config (authoritative source; nftables set may be
                    # empty after reboot if gatekeeper_init hasn't run yet)
                    EXISTING_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | tr 'A-Z' 'a-z')
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
                REMOVE_MAC=$(echo "$ARG" | tr 'A-Z' 'a-z')

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
            SCHED_MAC=$(echo "$TEXT" | awk '{print $2}' | tr 'A-Z' 'a-z')
            SCHED_DAYS=$(echo "$TEXT" | awk '{print $3}' | tr 'A-Z' 'a-z')
            SCHED_WIN=$(echo "$TEXT" | awk '{print $4}')
            SCHED_NAME=$(echo "$TEXT" | awk '{print $5}' | tr 'A-Z' 'a-z')

            # Validate MAC
            if ! echo "$SCHED_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                MSG="❌ Invalid MAC. Usage: SCHEDADD <mac> <days> <start>-<stop> [name]"
            # Validate days
            elif ! { [ "$SCHED_DAYS" = "daily" ] || [ "$SCHED_DAYS" = "weekdays" ] || [ "$SCHED_DAYS" = "weekends" ] \
                   || echo "$SCHED_DAYS" | grep -qE '^(mon|tue|wed|thu|fri|sat|sun)(,(mon|tue|wed|thu|fri|sat|sun))*$'; }; then
                MSG="❌ Invalid days. Use: daily | weekdays | weekends | mon,tue,wed,thu,fri,sat,sun"
            # Validate window
            elif ! echo "$SCHED_WIN" | grep -qE '^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]-(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$'; then
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
                        # If hyphens are the only problem, suggest the
                        # underscore version. UCI section names do not allow
                        # hyphens, so we cannot just accept them silently.
                        SUGGESTED=$(echo "$SCHED_NAME" | tr '-' '_')
                        if [ "$SUGGESTED" != "$SCHED_NAME" ] \
                           && echo "$SUGGESTED" | grep -qE '^[a-z0-9_]{1,32}$'; then
                            MSG="❌ Invalid name \`${SCHED_NAME}\` (UCI section names don't allow hyphens). Try: \`${SUGGESTED}\`"
                        else
                            MSG="❌ Invalid name \`${SCHED_NAME}\`. Use 1-32 chars of [a-z0-9_]"
                        fi
                        NAME_VALID=0
                    elif uci -q get "gatekeeper.${SCHED_NAME}" >/dev/null 2>&1; then
                        MSG="❌ Schedule '${SCHED_NAME}' already exists. Use SCHEDREMOVE first."
                        NAME_VALID=0
                    else
                        NAME_VALID=1
                    fi

                    if [ "$NAME_VALID" = "1" ]; then
                        # Static-lease check (warn-but-allow per decision 4d)
                        STATIC_LEASES=$(uci show dhcp 2>/dev/null | grep "\.mac=" | awk -F"='" '{print $2}' | tr -d "'" | tr 'A-Z' 'a-z')
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

        # === SCHEDREMOVE COMMAND ===
        # Delete a schedule by name.
        # Usage: SCHEDREMOVE <name>
        elif [ "$CMD" = "SCHEDREMOVE" ] && [ -n "$ARG" ]; then
            SCHED_NAME=$(echo "$ARG" | tr 'A-Z' 'a-z')
            SECTION_TYPE=$(uci -q get "gatekeeper.${SCHED_NAME}")
            if [ "$SECTION_TYPE" != "schedule" ]; then
                MSG="❌ No schedule named '${SCHED_NAME}'"
            else
                SCHED_MAC=$(uci -q get "gatekeeper.${SCHED_NAME}.mac")
                # If this schedule was the only thing keeping the MAC in
                # approved_macs, drop it now so the user sees instant effect.
                if [ -n "$SCHED_MAC" ] && [ -f "$SCHED_ACTIVE_FILE" ] \
                   && grep -q "^${SCHED_NAME} " "$SCHED_ACTIVE_FILE"; then
                    nft "delete element inet fw4 approved_macs { $SCHED_MAC }" 2>/dev/null
                fi
                uci delete "gatekeeper.${SCHED_NAME}" 2>/dev/null
                if uci commit gatekeeper; then
                    scheduler_tick
                    MSG="🗑️ Schedule *${SCHED_NAME}* removed."
                    echo "$(date '+%Y-%m-%dT%H:%M:%S') ${SCHED_MAC:--} - - sched-removed-${SCHED_NAME}" >> "$LOG_FILE"
                    logger -t tg_bot "Schedule removed: ${SCHED_NAME}"
                else
                    uci revert gatekeeper 2>/dev/null
                    MSG="❌ Failed to remove schedule (UCI commit error)"
                fi
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === SCHEDLIST COMMAND ===
        # List all schedules; optional MAC filter.
        # Usage: SCHEDLIST           - all schedules
        #        SCHEDLIST <mac>     - only schedules for that MAC
        elif [ "$CMD" = "SCHEDLIST" ]; then
            FILTER_MAC=""
            if [ -n "$ARG" ]; then
                FILTER_MAC=$(echo "$ARG" | tr 'A-Z' 'a-z')
                if ! echo "$FILTER_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                    MSG="❌ Invalid MAC filter. Use: SCHEDLIST [aa:bb:cc:dd:ee:ff]"
                    curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                         -H "Content-Type: application/json" \
                         -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                    continue
                fi
            fi

            MSG="📅 *Schedules"
            [ -n "$FILTER_MAC" ] && MSG="${MSG} for ${FILTER_MAC}"
            MSG="${MSG}:*\n"

            count=0
            for sec in $(uci show gatekeeper 2>/dev/null \
                         | sed -n 's/^gatekeeper\.\([^.=]*\)=schedule$/\1/p'); do
                mac=$(uci -q get "gatekeeper.${sec}.mac" | tr 'A-Z' 'a-z')
                [ -n "$FILTER_MAC" ] && [ "$mac" != "$FILTER_MAC" ] && continue

                days=$(uci -q get "gatekeeper.${sec}.days")
                start=$(uci -q get "gatekeeper.${sec}.start")
                stop=$(uci -q get "gatekeeper.${sec}.stop")
                label=$(uci -q get "gatekeeper.${sec}.label")
                enabled=$(uci -q get "gatekeeper.${sec}.enabled" || echo 1)

                count=$((count+1))

                STATE=""
                if [ "$enabled" != "1" ]; then
                    STATE=" *(paused)*"
                elif [ -f "$SCHED_ACTIVE_FILE" ] && grep -q "^${sec} " "$SCHED_ACTIVE_FILE"; then
                    end_epoch=$(grep "^${sec} " "$SCHED_ACTIVE_FILE" | awk '{print $3}')
                    end_str=$(date -d "@${end_epoch}" '+%H:%M' 2>/dev/null)
                    STATE=" ⏰ *active (until ${end_str})*"
                fi

                MSG="${MSG}\n*${sec}*${STATE}\n   └ \`${mac}\` ${days} ${start}–${stop}"
                [ -n "$label" ] && MSG="${MSG}\n   _${label}_"
            done

            if [ "$count" = "0" ]; then
                MSG="${MSG}\n_No schedules._"
            else
                MSG="${MSG}\n\n💡 SCHEDREMOVE <name> | SCHEDOFF <name> | SCHEDON <name>"
            fi

            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
        # === SCHEDSHOW COMMAND ===
        # Show full details of one schedule.
        # Usage: SCHEDSHOW <name>
        elif [ "$CMD" = "SCHEDSHOW" ] && [ -n "$ARG" ]; then
            SCHED_NAME=$(echo "$ARG" | tr 'A-Z' 'a-z')
            SECTION_TYPE=$(uci -q get "gatekeeper.${SCHED_NAME}")
            if [ "$SECTION_TYPE" != "schedule" ]; then
                MSG="❌ No schedule named '${SCHED_NAME}'"
            else
                mac=$(uci -q get "gatekeeper.${SCHED_NAME}.mac")
                days=$(uci -q get "gatekeeper.${SCHED_NAME}.days")
                start=$(uci -q get "gatekeeper.${SCHED_NAME}.start")
                stop=$(uci -q get "gatekeeper.${SCHED_NAME}.stop")
                label=$(uci -q get "gatekeeper.${SCHED_NAME}.label")
                enabled=$(uci -q get "gatekeeper.${SCHED_NAME}.enabled" || echo 1)

                STATE="paused"
                if [ "$enabled" = "1" ]; then
                    STATE="enabled"
                    if [ -f "$SCHED_ACTIVE_FILE" ] && grep -q "^${SCHED_NAME} " "$SCHED_ACTIVE_FILE"; then
                        end_epoch=$(grep "^${SCHED_NAME} " "$SCHED_ACTIVE_FILE" | awk '{print $3}')
                        end_str=$(date -d "@${end_epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null)
                        STATE="enabled, ⏰ active until ${end_str}"
                    fi
                fi

                MSG="📅 *Schedule:* ${SCHED_NAME}\n"
                MSG="${MSG}🔹 *MAC:* \`${mac}\`\n"
                MSG="${MSG}🔹 *Days:* ${days}\n"
                MSG="${MSG}🔹 *Window:* ${start}–${stop}\n"
                MSG="${MSG}🔹 *State:* ${STATE}\n"
                [ -n "$label" ] && MSG="${MSG}🔹 *Label:* ${label}\n"
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
        # === SCHEDOFF / SCHEDON COMMANDS ===
        # Toggle a schedule's enabled flag. SCHEDOFF pauses (window pops on next tick);
        # SCHEDON resumes (window pushes on next tick if currently in time-range).
        elif { [ "$CMD" = "SCHEDOFF" ] || [ "$CMD" = "SCHEDON" ]; } && [ -n "$ARG" ]; then
            SCHED_NAME=$(echo "$ARG" | tr 'A-Z' 'a-z')
            SECTION_TYPE=$(uci -q get "gatekeeper.${SCHED_NAME}")
            if [ "$SECTION_TYPE" != "schedule" ]; then
                MSG="❌ No schedule named '${SCHED_NAME}'"
            else
                if [ "$CMD" = "SCHEDOFF" ]; then
                    uci set "gatekeeper.${SCHED_NAME}.enabled=0"
                    NEW_STATE="paused"
                    EMOJI="⏸️"
                else
                    uci set "gatekeeper.${SCHED_NAME}.enabled=1"
                    NEW_STATE="enabled"
                    EMOJI="▶️"
                fi
                if uci commit gatekeeper; then
                    scheduler_tick
                    MSG="${EMOJI} Schedule *${SCHED_NAME}* ${NEW_STATE}."
                    echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - sched-${NEW_STATE}-${SCHED_NAME}" >> "$LOG_FILE"
                else
                    uci revert gatekeeper 2>/dev/null
                    MSG="❌ Failed to toggle schedule (UCI commit error)"
                fi
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
        # === SCHEDNOTIFY COMMAND ===
        # Toggle the optional info-message on schedule auto-approve.
        # Usage: SCHEDNOTIFY ON | OFF | STATUS
        elif [ "$CMD" = "SCHEDNOTIFY" ] && [ -n "$ARG" ]; then
            SUB=$(echo "$ARG" | tr 'a-z' 'A-Z')
            case "$SUB" in
                ON)
                    uci set gatekeeper.main.schedule_notify=1
                    if uci commit gatekeeper; then
                        MSG="🔔 Schedule notifications: *ENABLED*"
                    else
                        uci revert gatekeeper 2>/dev/null
                        MSG="❌ Failed to update setting (UCI commit error)"
                    fi
                    ;;
                OFF)
                    uci set gatekeeper.main.schedule_notify=0
                    if uci commit gatekeeper; then
                        MSG="🔕 Schedule notifications: *DISABLED*"
                    else
                        uci revert gatekeeper 2>/dev/null
                        MSG="❌ Failed to update setting (UCI commit error)"
                    fi
                    ;;
                STATUS)
                    SN=$(uci -q get gatekeeper.main.schedule_notify || echo 0)
                    if [ "$SN" = "1" ]; then
                        MSG="🔔 Schedule notifications: *ENABLED*"
                    else
                        MSG="🔕 Schedule notifications: *DISABLED*"
                    fi
                    ;;
                *)
                    MSG="❌ Usage: SCHEDNOTIFY ON | OFF | STATUS"
                    ;;
            esac
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
        # === BACKUP COMMAND ===
        # Generate a UCI-text backup of gatekeeper config + static DHCP hosts,
        # send it to Telegram as a document, delete the temp file.
        # Usage: BACKUP            - include token/chat_id
        #        BACKUP NOSECRETS  - blank out token/chat_id
        elif [ "$CMD" = "BACKUP" ]; then
            INCLUDE_SECRETS=1
            if [ -n "$ARG" ]; then
                if [ "$(echo "$ARG" | tr 'a-z' 'A-Z')" = "NOSECRETS" ]; then
                    INCLUDE_SECRETS=0
                else
                    MSG="❌ Usage: BACKUP [NOSECRETS]"
                    curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                         -H "Content-Type: application/json" \
                         -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                    continue
                fi
            fi

            BK_HOST=$(uci -q get system.@system[0].hostname \
                      || cat /proc/sys/kernel/hostname 2>/dev/null \
                      || echo openwrt)
            STAMP=$(date +%Y%m%d-%H%M)
            BACKUP_FILE="/tmp/gatekeeper-backup-${BK_HOST}-${STAMP}-$$.txt"
            if [ "$INCLUDE_SECRETS" = "1" ]; then
                SECRETS_LABEL="yes"
            else
                SECRETS_LABEL="no"
            fi

            # Build the file
            {
                echo "# Gatekeeper backup"
                echo "# Generated:        $(date -Iseconds 2>/dev/null || date)"
                echo "# Hostname:         $BK_HOST"
                echo "# Schema:           v1"
                echo "# Includes secrets: $SECRETS_LABEL"
                echo "# Source files:"
                echo "#   /etc/config/gatekeeper"
                echo "#   /etc/config/dhcp (host entries only)"
                echo ""
                echo "# === /etc/config/gatekeeper ==="
                if [ "$INCLUDE_SECRETS" = "1" ]; then
                    uci export gatekeeper
                else
                    uci export gatekeeper \
                        | sed -E "s/^([[:space:]]*option (token|chat_id) ).*/\1''/"
                fi
                echo ""
                echo "# === /etc/config/dhcp (host entries only) ==="
                awk '/^config[[:space:]]/ { in_host = ($2 == "host") } in_host { print }' \
                    /etc/config/dhcp 2>/dev/null
            } > "$BACKUP_FILE"

            # Multipart upload via sendDocument
            CAPTION="Gatekeeper backup from ${BK_HOST} (secrets: ${SECRETS_LABEL})"
            UPLOAD_RESP=$(curl -s --connect-timeout 10 --max-time 60 \
                -F "chat_id=$CHAT_ID" \
                -F "document=@${BACKUP_FILE}" \
                -F "caption=${CAPTION}" \
                "https://api.telegram.org/bot$TOKEN/sendDocument")

            if echo "$UPLOAD_RESP" | jq -e '.ok' >/dev/null 2>&1; then
                logger -t tg_bot "Backup sent: ${BACKUP_FILE} (secrets=${SECRETS_LABEL})"
                echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - backup-sent-${SECRETS_LABEL}" >> "$LOG_FILE"
            else
                MSG="❌ Backup upload failed. Check logs."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                logger -t tg_bot "Backup upload failed: $UPLOAD_RESP"
            fi

            rm -f "$BACKUP_FILE"

        # === RESTORE COMMAND ===
        # Begin a restore from a backup file. Must be sent as a reply to the
        # backup file message in the chat. Produces a preview; user confirms
        # by replying YES to the preview within 10 minutes.
        elif [ "$CMD" = "RESTORE" ]; then
            if [ -z "$REPLY_DOC_ID" ]; then
                MSG="❌ RESTORE must be sent as a reply to a backup file message."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                continue
            fi

            if [ "$REPLY_DOC_SIZE" -gt 1048576 ] 2>/dev/null; then
                MSG="❌ File too large (max 1 MB)."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                continue
            fi

            # Fetch file_path via getFile.
            GF_RESP=$(curl -s --connect-timeout 10 --max-time 30 \
                "https://api.telegram.org/bot$TOKEN/getFile?file_id=$REPLY_DOC_ID")
            FILE_PATH=$(echo "$GF_RESP" | jq -r '.result.file_path // empty')
            if [ -z "$FILE_PATH" ]; then
                MSG="❌ Couldn't fetch file from Telegram."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                logger -t tg_bot "Restore getFile failed: $GF_RESP"
                continue
            fi

            # Download to /tmp.
            rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"
            curl -s --connect-timeout 10 --max-time 30 \
                -o "$RESTORE_FILE" \
                "https://api.telegram.org/file/bot$TOKEN/$FILE_PATH"

            # Validate.
            if ! is_valid_backup "$RESTORE_FILE"; then
                MSG="❌ Backup file invalid (failed validation gate)."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE"
                continue
            fi

            # Parse + diff. restore_build_plan returns 0 if there's at least
            # one mutation, 1 if everything is already present.
            restore_parse_to_records "$RESTORE_FILE" "$RESTORE_RECORDS"
            if ! restore_build_plan "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"; then
                MSG="🔄 Restore preview — nothing to do.\nAll entries from this backup are already present."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"
                continue
            fi

            # Send preview, capture the new message_id, persist pending state.
            PREVIEW_BODY=$(printf '🔄 Restore preview from \`%s\`\n\n' "${REPLY_DOC_NAME:-unknown}")
            PREVIEW_BODY="${PREVIEW_BODY}$(cat "$RESTORE_PREVIEW")"
            # Real newline before the trailing prompt: PREVIEW_BODY is fed to
            # `jq -n --arg`, which JSON-encodes its input. A literal "\n" two-char
            # sequence here would survive jq as "\\n" in the JSON and render in
            # Telegram as literal backslash-n. A real LF is JSON-encoded to "\n"
            # which Telegram renders as a newline.
            PREVIEW_BODY="${PREVIEW_BODY}
Reply YES (within 10 minutes) to apply."
            PREVIEW_PAYLOAD=$(jq -n --arg c "$CHAT_ID" --arg t "$PREVIEW_BODY" \
                '{chat_id: $c, text: $t, parse_mode: "Markdown"}')
            PREVIEW_RESP=$(curl -s $CURL_OPTS -X POST \
                "https://api.telegram.org/bot$TOKEN/sendMessage" \
                -H "Content-Type: application/json" -d "$PREVIEW_PAYLOAD")
            PREVIEW_MSGID=$(echo "$PREVIEW_RESP" | jq -r '.result.message_id // empty')
            if [ -z "$PREVIEW_MSGID" ]; then
                logger -t tg_bot "Restore preview send failed: $PREVIEW_RESP"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"
                continue
            fi

            echo "$PREVIEW_MSGID $(date +%s)" > "$RESTORE_PENDING"
            logger -t tg_bot "Restore preview sent: msg_id=$PREVIEW_MSGID file=$REPLY_DOC_NAME"

        # === YES COMMAND ===
        # Confirm a pending restore. Must be sent as a reply to the preview
        # message and within 10 minutes.
        elif [ "$CMD" = "YES" ]; then
            # Strict gating: silently ignore unless this YES matches the pending preview.
            [ -z "$REPLY_TO_MSGID" ] && continue
            [ -f "$RESTORE_PENDING" ] || continue
            STORED_MSGID=$(awk '{print $1}' "$RESTORE_PENDING")
            STORED_EPOCH=$(awk '{print $2}' "$RESTORE_PENDING")
            [ "$REPLY_TO_MSGID" = "$STORED_MSGID" ] || continue

            NOW_EPOCH=$(date +%s)
            if [ $((NOW_EPOCH - STORED_EPOCH)) -gt 600 ]; then
                MSG="⌛ Pending restore expired (>10 min). Reply RESTORE to a backup file again."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
                continue
            fi

            if [ ! -s "$RESTORE_PLAN" ]; then
                MSG="❌ Plan file missing — restart restore by replying RESTORE to a backup file."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_PENDING"
                continue
            fi

            # Two-phase apply.
            FAILED_LINE=""
            while IFS= read -r line; do
                case "$line" in
                    ''|\#*) continue ;;
                esac
                if ! eval "$line"; then
                    FAILED_LINE="$line"
                    break
                fi
            done < "$RESTORE_PLAN"

            if [ -n "$FAILED_LINE" ]; then
                uci revert gatekeeper 2>/dev/null
                MSG="❌ Restore failed at: \`${FAILED_LINE}\`"
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
                continue
            fi

            if ! uci commit gatekeeper; then
                uci revert gatekeeper 2>/dev/null
                MSG="❌ Restore commit failed (UCI error)."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
                continue
            fi

            # Post-apply hooks.
            # Re-sync blacklist_macs nftables set from new UCI state.
            nft flush set inet fw4 blacklist_macs 2>/dev/null
            BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null \
                | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
            for mac in $BLACKLIST_MACS; do
                [ -z "$mac" ] && continue
                nft "add element inet fw4 blacklist_macs { $mac }" 2>/dev/null
            done
            # Push any newly-restored active schedules.
            scheduler_tick

            # Compose summary from the plan file.
            N_MAIN=$(grep -c '^uci set gatekeeper\.main\.' "$RESTORE_PLAN")
            N_BL=$(grep -c '^uci add_list gatekeeper\.blacklist\.mac=' "$RESTORE_PLAN")
            N_SCHED=$(grep -cE '^uci set gatekeeper\.[^.]+=schedule$' "$RESTORE_PLAN")
            N_TOTAL=$((N_MAIN + N_BL + N_SCHED))

            MSG="✅ Restore complete: ${N_TOTAL} change(s) applied.\n"
            [ "$N_MAIN"  -gt 0 ] && MSG="${MSG}• ${N_MAIN} main option(s) updated\n"
            [ "$N_BL"    -gt 0 ] && MSG="${MSG}• ${N_BL} blacklist MAC(s) added\n"
            [ "$N_SCHED" -gt 0 ] && MSG="${MSG}• ${N_SCHED} schedule(s) added\n"
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

            echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - restore-applied-${N_TOTAL}" >> "$LOG_FILE"
            logger -t tg_bot "Restore applied: $N_TOTAL changes (main=$N_MAIN bl=$N_BL sched=$N_SCHED)"

            rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
        fi
    done
done