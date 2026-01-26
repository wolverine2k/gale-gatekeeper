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

# Parse input parameters from ubus event listener
# ACTION: DHCP event type (add, old, del) - 'add' for new connections
# MAC: Device MAC address for identification
# IP: Assigned IP address
# HOSTNAME: Device hostname if available
ACTION=$1
MAC=$2
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
if nft list set inet fw4 denied_macs | grep  -q "$MAC"; then
    exit 0  # Silently exit for denied devices
fi

# Step 3: Input validation - Ensure valid MAC provided
if [[ -z "${MAC// }" ]]; then
    exit 0  # Invalid input, nothing to process
fi

# Step 4: For non-static devices with 'add' action, send notification
if [ "$is_static" -eq 0 ] && [ "$ACTION" = "add" ]; then
    # Configure Telegram inline keyboard with Approve/Deny buttons
    # Callback data format: action_MAC (e.g., "approve_00:11:22:33:44:55")
    KEYBOARD="{\"inline_keyboard\": [[{\"text\": \"✅ Approve\", \"callback_data\": \"approve_$MAC\"}, {\"text\": \"❌ Deny\", \"callback_data\": \"deny_$MAC\"}]]}"

    # Compose message with Markdown formatting
    # %0A is URL-encoded newline for Telegram API
    MESSAGE="⚠️ *New Device Connection*%0A*Host:* ${HOSTNAME:-Unknown}%0A*MAC:* $MAC%0A*IP:* $IP"

    # Send Notification via Telegram Bot API
    # curl options: -s silent, -X POST HTTP method, -d POST data
    SEND_RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
         -d "chat_id=$CHAT_ID" -d "text=$MESSAGE" -d "parse_mode=Markdown" -d "reply_markup=$KEYBOARD")

    # Extract message ID from response for tracking
    MSG_ID=$(echo "$SEND_RESPONSE" | jq '.result.message_id')

    # Step 5: 5 Minute Auto-Deny Timer (background process)
    # Waits 5 minutes, checks if MAC was added to approved_macs
    # If not approved, sends timeout message and adds to denied_macs
    (
        sleep 300  # Wait 5 minutes

        # Check if MAC still not in approved list
        if ! nft list set inet fw4 approved_macs | grep -q "$MAC"; then
            # Update message to show timeout
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/editMessageText" \
                 -d "chat_id=$CHAT_ID" -d "message_id=$MSG_ID" \
                 -d "text=⌛ *Auto-Denied (Timeout)*%0A$MAC remained unapproved." -d "parse_mode=Markdown"

            # Add MAC to denied list (30 minute timeout)
            # Prevents notification spam and allows retry after timeout
            nft "add element inet fw4 denied_macs { $MAC timeout 30m }"
        fi
    ) &  # Run in background to allow immediate script completion
fi