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

# gatekeeper.sh - Main notification and approval handler for new network devices
#
# This script receives device connection data from the gatekeeper_trigger.sh and
# sends interactive approval notifications to Telegram. It implements automatic
# denial after timeout period and maintains denied MACs list to prevent notifications
# for devices explicitly denied by the administrator.
#
# Architecture Overview:
# - Part of 4-stage gatekeeper pipeline: dnsmasq -> trigger_listener -> gatekeeper.sh -> tg_bot.sh
# - Called by ubus event listener with device MAC, IP, hostname, and action
# - Checks against static leases and denied list to filter notifications
# - Sends approval/denial requests to specified Telegram chat
# - Implements 5-minute auto-deny timer with timeout tracking
#
# Security Features:
# - Static lease detection: Devices with static DHCP leases get immediate access
# - Re-notification prevention: Denied MACs tracked in nftables 'denied_macs'
# - Telegram API validation: Uses validated bot token and controlled chat ID
# - Timeout enforcement: Denied entries auto-expire after 30 minutes to allow retries
#
# Integration Points:
# - Reads OpenWrt UCI DHCP configuration for static lease detection
# - Modifies 'approved_macs' and 'denied_macs' nftables sets
# - Telegram API communication via curl
# - Logging via standard logger to system logs
#
# Configuration Requirements:
# - TOKEN: Telegram Bot API token (from BotFather)
# - CHAT_ID: Target chat/channel ID for notifications
# - These should be configured at package installation time
#
# Exit Codes:
# - 0: Success (notification sent or suppressed appropriately)
# - Non-zero: Configuration issue or API failure
#
# Maintenance Notes:
# - Inline keyboard markup uses JSON format for interactive buttons
# - Markdown format supports basic formatting (%0A for newlines, etc.)
# - Auto-deny subprocess runs in background to avoid blocking
# - curl commands use -s for silent mode in production
#
# Extensibility:
# - Add additional device attributes to notification message
# - Implement whitelist for known good MACs (auto-approve)
# - Support multiple chat notifications (send to different CHAT_IDs)
# - Add more granular timeout settings per device type
#
# Troubleshooting:
# - Check Telegram token validity: curl output inspection
# - Verify nftables sets accessible: nft list sets
# - Monitor system logs: logread -f | grep gatekeeper

# Configuration: Telegram Bot API token and Chat ID from UCI config
# Read from /etc/config/gatekeeper or fall back to environment variables
TOKEN="${GATEKEEPER_TOKEN:-$(uci -q get gatekeeper.main.token)}"
CHAT_ID="${GATEKEEPER_CHAT_ID:-$(uci -q get gatekeeper.main.chat_id)}"

# Validate configuration
if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    logger -t gatekeeper "ERROR: TOKEN or CHAT_ID not configured. Set via UCI: uci set gatekeeper.@main[0].token='YOUR_TOKEN' && uci set gatekeeper.@main[0].chat_id='YOUR_CHAT_ID'"
    exit 1
fi

LOG_FILE="/tmp/gatekeeper.log"

# Schedule helpers — kept identical to copies in tg_bot.sh and the
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

# Returns the *latest* end-epoch across all enabled schedules whose mac equals
# $1 and whose window is active right now. Empty stdout = no active schedule.
check_active_schedule_for_mac() {
    target_mac=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    [ -n "$target_mac" ] || return 0
    [ "$(date +%Y)" -ge 2024 ] || return 0   # NTP guard

    today_dow=$(date +%a | tr '[:upper:]' '[:lower:]')
    now_hm=$(date +%H:%M)
    best_end=""

    for sec in $(uci show gatekeeper 2>/dev/null \
                 | sed -n 's/^gatekeeper\.\([^.=]*\)=schedule$/\1/p'); do
        enabled=$(uci -q get "gatekeeper.${sec}.enabled" || echo 1)
        [ "$enabled" = "1" ] || continue

        mac=$(uci -q get "gatekeeper.${sec}.mac" | tr '[:upper:]' '[:lower:]')
        [ "$mac" = "$target_mac" ] || continue

        days=$(uci -q get "gatekeeper.${sec}.days")
        start=$(uci -q get "gatekeeper.${sec}.start")
        stop=$(uci -q get "gatekeeper.${sec}.stop")
        [ -n "$days" ] && [ -n "$start" ] && [ -n "$stop" ] || continue

        end_epoch=$(window_active_now "$days" "$start" "$stop" "$today_dow" "$now_hm")
        [ -n "$end_epoch" ] || continue

        if [ -z "$best_end" ] || [ "$end_epoch" -gt "$best_end" ]; then
            best_end=$end_epoch
        fi
    done
    [ -n "$best_end" ] && echo "$best_end"
}

# curl timeout options — prevent indefinite hangs on network stalls
CURL_OPTS="--connect-timeout 10 --max-time 30"

# Rotate log to prevent /tmp (tmpfs) exhaustion — keep last 500 lines
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null)" -gt 1000 ]; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# Early exit if gatekeeper has been disabled via the DISABLE command.
# While disabled the firewall chain is empty so all traffic passes freely —
# we must not send approval notifications or start auto-deny timers, because
# the 5-minute timer could fire *after* ENABLE is called and silently add
# devices to denied_macs, preventing them from ever requesting approval.
GATEKEEPER_DISABLED=$(uci -q get gatekeeper.main.disabled || echo "0")
if [ "$GATEKEEPER_DISABLED" = "1" ]; then
    exit 0
fi

# Parse input parameters from ubus event listener
# ACTION: DHCP event type (add, old, del) - 'add' for new connections
# MAC: Device MAC address for identification
# IP: Assigned IP address
# HOSTNAME: Device hostname if available
ACTION=$1
MAC=$(echo "$2" | tr 'A-Z' 'a-z')  # Normalize to lowercase (nftables stores lowercase)
IP=$3
HOSTNAME=$4

# Step 1: Check for static lease by querying UCI DHCP configuration
# Reads all MAC addresses configured for static leases in dhcp.@host[*]
STATIC_LEASES=$(uci show dhcp | grep ".mac=" | awk -F"='" '{print $2}' | tr -d "'")
is_static=0

# Compare against static MACs (case-insensitive) using efficient loop
# Early exit if static match found (already has network access)
#for s_mac in $STATIC_LEASES; do [ "${s_mac,,}" = "${MAC,,}" ] && is_static=1; done
for s_mac in $STATIC_LEASES; do
   [ "$(echo "$s_mac" | tr 'A-Z' 'a-z')" = "$MAC" ] && is_static=1
done

# Step 2: Check for denied lease in nftables denied_macs set
# Don't send approval notification if device was previously denied
# This prevents notification spam for rejected devices
if nft list set inet fw4 denied_macs | grep -qi "$MAC"; then
    exit 0  # Silently exit for denied devices
fi

# Step 2.5: Check if already approved in nftables approved_macs set
# Don't send approval notification if device is already approved
# This prevents duplicate notifications when devices reconnect or renew DHCP
if nft list set inet fw4 approved_macs | grep -qi "$MAC"; then
    exit 0  # Silently exit for already-approved devices
fi

# Step 3: Input validation - Ensure valid MAC provided
if [ -z "$(echo "$MAC" | tr -d ' ')" ]; then
    exit 0  # Invalid input, nothing to process
fi

# Step 3.5: Check Blacklist Mode
# When blacklist mode is enabled, only MACs in the blacklist require approval
# All other MACs are auto-approved with 24-hour timeout
BLACKLIST_MODE=$(uci -q get gatekeeper.main.blacklist_mode || echo "0")

if [ "$is_static" -eq 0 ] && [ "$ACTION" = "add" ] && [ "$BLACKLIST_MODE" = "1" ]; then
    # Blacklist mode is ON - check if MAC is in blacklist
    if nft list set inet fw4 blacklist_macs | grep -qi "$MAC"; then
        # MAC IS in blacklist - fall through to normal approval request below
        :
    else
        # MAC is NOT in blacklist - auto-approve with 24h timeout
        nft add element inet fw4 approved_macs { $MAC timeout 24h }
        logger -t gatekeeper "Auto-approved (blacklist mode): $MAC ($HOSTNAME) - $IP"
        echo "$(date '+%Y-%m-%dT%H:%M:%S') $MAC $IP ${HOSTNAME:--} auto-approved-24h" >> "$LOG_FILE"

        # Send informational message to Telegram
        MESSAGE="✅ *Auto-Approved* (Blacklist Mode)%0A%0A"
        MESSAGE="${MESSAGE}🔹 *Device:* ${HOSTNAME:-Unknown}%0A"
        MESSAGE="${MESSAGE}🔹 *MAC:* ${MAC}%0A"
        MESSAGE="${MESSAGE}🔹 *IP:* ${IP}%0A"
        MESSAGE="${MESSAGE}🔹 *Access:* 24 hours"

        curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=${MESSAGE}" \
            -d "parse_mode=Markdown" > /dev/null

        exit 0  # Done - no approval needed
    fi
    # MAC is in blacklist - fall through to normal approval request below
fi

# Step 3.6: Active schedule auto-approve (hybrid catch for mid-window DHCP).
# A scheduled MAC connecting inside its window is silently auto-approved
# until the window's end. Decisions:
#   - Static lease (step 1) wins over schedules.
#   - denied_macs (step 2) wins over schedules.
#   - Schedule wins over the blacklist gate.
if [ "$is_static" -eq 0 ] && [ "$ACTION" = "add" ]; then
    SCHED_END=$(check_active_schedule_for_mac "$MAC")
    if [ -n "$SCHED_END" ]; then
        NOW_TS=$(date +%s)
        REMAINING=$(( SCHED_END - NOW_TS ))
        if [ "$REMAINING" -ge 60 ]; then
            nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
            nft "add element inet fw4 approved_macs { $MAC timeout ${REMAINING}s }" 2>/dev/null
            logger -t gatekeeper "Auto-approved (schedule): $MAC ($HOSTNAME) - $IP, ${REMAINING}s"
            echo "$(date '+%Y-%m-%dT%H:%M:%S') $MAC $IP ${HOSTNAME:--} schedule-approved-${REMAINING}s" >> "$LOG_FILE"

            SN=$(uci -q get gatekeeper.main.schedule_notify || echo 0)
            if [ "$SN" = "1" ]; then
                EXPIRY_STR=$(date -d "@${SCHED_END}" '+%Y-%m-%d %H:%M' 2>/dev/null)
                MESSAGE="✅ *Scheduled Auto-Approve*%0A%0A"
                MESSAGE="${MESSAGE}🔹 *Device:* ${HOSTNAME:-Unknown}%0A"
                MESSAGE="${MESSAGE}🔹 *MAC:* ${MAC}%0A"
                MESSAGE="${MESSAGE}🔹 *IP:* ${IP}%0A"
                MESSAGE="${MESSAGE}🔹 *Until:* ${EXPIRY_STR}"
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
                    -d "chat_id=${CHAT_ID}" \
                    -d "text=${MESSAGE}" \
                    -d "parse_mode=Markdown" > /dev/null
            fi
            exit 0
        fi
    fi
fi

# Step 4: For non-static devices with 'add' action, send notification
if [ "$is_static" -eq 0 ] && [ "$ACTION" = "add" ]; then
    # Configure Telegram inline keyboard with Approve/Deny buttons
    # Callback data format: action_MAC (e.g., "approve_00:11:22:33:44:55")
    KEYBOARD="{\"inline_keyboard\": [[{\"text\": \"✅ Approve\", \"callback_data\": \"approve_$MAC\"}, {\"text\": \"❌ Deny\", \"callback_data\": \"deny_$MAC\"}]]}"

    # Compose message with Markdown formatting
    # %0A is URL-encoded newline for Telegram API
    MESSAGE="⚠️ *New Device Connection*%0A*Host:* ${HOSTNAME:-Unknown}%0A*MAC:* $MAC%0A*IP:* $IP"

    # Log the connection event
    echo "$(date '+%Y-%m-%dT%H:%M:%S') $MAC $IP ${HOSTNAME:--} connected" >> "$LOG_FILE"

    # Send Notification via Telegram Bot API
    # curl options: -s silent, -X POST HTTP method, -d POST data
    SEND_RESPONSE=$(curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
         -d "chat_id=$CHAT_ID" -d "text=$MESSAGE" -d "parse_mode=Markdown" -d "reply_markup=$KEYBOARD")

    # Extract message ID from response for tracking
    MSG_ID=$(echo "$SEND_RESPONSE" | jq '.result.message_id')

    # Step 5: 5 Minute Auto-Deny Timer (background process)
    # One timer per MAC — cancel any previous timer before starting a new one.
    # Without this, rapid reconnects (DHCP renewal, network flap) accumulate
    # orphaned sleep+curl processes that all fire independently.
    TIMER_PID_FILE="/tmp/gatekeeper_timer_$(echo "$MAC" | tr -d ':')"
    if [ -f "$TIMER_PID_FILE" ]; then
        kill "$(cat "$TIMER_PID_FILE")" 2>/dev/null
        rm -f "$TIMER_PID_FILE"
    fi

    (
        sleep 300  # Wait 5 minutes

        rm -f "$TIMER_PID_FILE"  # Clean up PID file on natural expiry

        # Check if MAC still not in approved list
        if ! nft list set inet fw4 approved_macs | grep -qi "$MAC"; then
            # Update message to show timeout
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/editMessageText" \
                 -d "chat_id=$CHAT_ID" -d "message_id=$MSG_ID" \
                 -d "text=⌛ *Auto-Denied (Timeout)*%0A$MAC remained unapproved." -d "parse_mode=Markdown"

            # Add MAC to denied list (30 minute timeout)
            # Prevents notification spam and allows retry after timeout
            nft "add element inet fw4 denied_macs { $MAC timeout 30m }"
            echo "$(date '+%Y-%m-%dT%H:%M:%S') $MAC $IP ${HOSTNAME:--} auto-denied-timeout" >> "$LOG_FILE"
        fi
    ) &
    echo $! > "$TIMER_PID_FILE"  # Store PID so next invocation can cancel this timer
fi