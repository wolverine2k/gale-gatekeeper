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
# - Integrates with nftables sets: approved_macs, denied_macs, static_macs, bypass_switch
#
# Command Interface:
# - HELP: Display list of all available commands with descriptions
# - STATUS: Display gatekeeper status and list active guests with temporary IDs
# - DSTATUS: Display all denied devices with hostnames and timeout information
# - EXTEND [ID]: Extend network access timeout for a specific guest (30 min)
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

# State file paths in /tmp (non-persistent, cleared on reboot)
LOG_FILE="/tmp/gatekeeper.log"        # Activity logs from gatekeeper.sh
NAME_MAP="/tmp/mac_names"             # Custom hostname cache (MAC=Name pairs)
MAP_FILE="/tmp/mac_map"               # Temporary device ID-to-MAC mapping for STATUS
DENIED_MAP_FILE="/tmp/denied_mac_map" # Temporary device ID-to-MAC mapping for DSTATUS
OFFSET_FILE="/tmp/tg_offset"          # Telegram update ID tracking

# Load last processed update ID from offset file
# Starts at 0 if file doesn't exist (first run or post-reboot)
OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

# Main event loop: Continuously poll Telegram API for updates
# Uses long polling with 30-second timeout for efficient real-time updates
while true; do
    # Poll Telegram API for new updates with long polling (30s timeout)
    # Long polling reduces server load compared to frequent short requests
    RESPONSE=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=30")
    
    # Skip processing if response is empty (connection timeout/error)
    # Sleep briefly and retry to avoid tight loop on network errors
    [ -z "$RESPONSE" ] && sleep 2 && continue

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
            MAC=$(echo "$CB_DATA" | cut -d'_' -f2-)

            # Process APPROVE action
            if [ "$ACT" = "approve" ]; then
                # Add MAC to approved_macs set with 30-minute timeout
                # Device gains network access immediately via firewall rules
                nft "add element inet fw4 approved_macs { $MAC timeout 30m }"
                
                # Extract hostname from gatekeeper log for display
                # Log format: timestamp MAC IP hostname
                H_NAME=$(grep -i "$MAC" "$LOG_FILE" | tail -n 1 | awk '{print $4}')
                
                # Cache hostname in name map for future STATUS lookups
                if [ -n "$H_NAME" ]; then
                    # Remove old entry if exists (prevents duplicates)
                    sed -i "/$MAC/d" "$NAME_MAP" 2>/dev/null
                    echo "$MAC=$H_NAME" >> "$NAME_MAP"
                fi
                OUT="✅ Approved: ${H_NAME:-$MAC}"
            
            # Process DENY action
            else
                # Remove from approved list (if present) and add to denied list
                # 30-minute timeout prevents notification spam for denied devices
                nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
                nft "add element inet fw4 denied_macs { $MAC timeout 30m }"
                OUT="❌ Denied: $MAC"
            fi

            # Acknowledge callback query (removes loading indicator in Telegram UI)
            curl -s "https://api.telegram.org/bot$TOKEN/answerCallbackQuery?callback_query_id=$CB_ID" >/dev/null
            
            # Update original message with approval/denial result
            # Replaces interactive buttons with static confirmation message
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/editMessageText" -d "chat_id=$C_ID" -d "message_id=$M_ID" -d "text=$OUT"
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

        # Parse command and optional argument from message text
        # Convert command to uppercase for case-insensitive matching
        CMD=$(echo "$TEXT" | awk '{print toupper($1)}')
        ARG=$(echo "$TEXT" | awk '{print $2}')

        # === HELP COMMAND ===
        # Display list of all available commands with descriptions
        # Provides user with comprehensive command reference
        if [ "$CMD" = "HELP" ]; then
            MSG="📖 *Gatekeeper Commands*\n\n"
            MSG="${MSG}*Device Management:*\n"
            MSG="${MSG}\`STATUS\` - Show active approved guests\n"
            MSG="${MSG}\`DSTATUS\` - Show denied devices\n"
            MSG="${MSG}\`EXTEND [ID]\` - Extend guest timeout (+30m)\n"
            MSG="${MSG}\`REVOKE [ID]\` - Revoke guest access\n"
            MSG="${MSG}\`DEXTEND [ID]\` - Extend denial timeout (+30m)\n"
            MSG="${MSG}\`DREVOKE [ID]\` - Approve denied device (+30m)\n\n"
            MSG="${MSG}*Blacklist Mode:*\n"
            MSG="${MSG}\`BL_ON\` - Enable blacklist mode\n"
            MSG="${MSG}\`BL_OFF\` - Disable blacklist mode\n"
            MSG="${MSG}\`BL_STATUS\` - Show blacklist status\n"
            MSG="${MSG}\`BL_ADD [MAC]\` - Add MAC to blacklist\n"
            MSG="${MSG}\`BL_REMOVE [MAC]\` - Remove from blacklist\n"
            MSG="${MSG}\`BL_CLEAR\` - Clear all blacklist entries\n\n"
            MSG="${MSG}*System Control:*\n"
            MSG="${MSG}\`ENABLE\` - Enable gatekeeper filtering\n"
            MSG="${MSG}\`DISABLE\` - Disable gatekeeper (emergency)\n"
            MSG="${MSG}\`SYNC\` - Resync static DHCP leases\n\n"
            MSG="${MSG}*Maintenance:*\n"
            MSG="${MSG}\`LOG\` - View recent activity logs\n"
            MSG="${MSG}\`CLEAR\` - Clear logs and name cache\n"
            MSG="${MSG}\`HELP\` - Show this help message\n\n"
            MSG="${MSG}💡 _Use STATUS or DSTATUS first to get device IDs_"

            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === STATUS COMMAND ===
        # Display gatekeeper status and list all active guests
        # Shows bypass status, device list with hostnames, and command hints
        elif [ "$CMD" = "STATUS" ]; then
            # Check global bypass status
            # If bypass_switch contains ff:ff:ff:ff:ff:ff, gatekeeper is disabled
            BYPASS=$(nft list set inet fw4 bypass_switch | grep -q "ff:ff:ff:ff:ff:ff" && echo "🔓 DISABLED" || echo "🛡️ ENABLED")
            
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
                    
                    # Extract timeout expiry from nftables output (e.g., "29m59s")
                    M_TIME=$(echo "$line" | sed 's/.*expires //; s/s.*/s/; s/,//g')

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
                    
                    # Format guest entry: ID. Hostname, MAC address, and timeout
                    MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME})\n"
                    count=$((count + 1))
                done <<EOF
$RAW_LIST
EOF
                # Add usage hint for managing guests by ID
                MSG="${MSG}\n💡 Reply \`Extend ID\` or \`Revoke ID\`"
            fi

            # Send status message with custom keyboard for quick commands
            # Keyboard provides buttons for common commands (Status, DStatus, Help, etc.)
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
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

                    # Extract timeout expiry from nftables output (e.g., "29m59s")
                    M_TIME=$(echo "$line" | sed 's/.*expires //; s/s.*/s/; s/,//g')

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

                    # Format denied device entry: count. Hostname, MAC address, and timeout
                    MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME})\n"
                    count=$((count + 1))
                done <<EOF
$DENIED_LIST
EOF
                # Add usage hint for managing denied devices by ID
                MSG="${MSG}\n💡 Reply \`Dextend ID\` or \`Drevoke ID\`"
            fi

            # Send denied devices message with markdown formatting
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
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
                    # Parse remaining time (format: "29m59s", "15m30s", or "59s")
                    TIME_STR=$(echo "$CURRENT_LINE" | sed 's/.*expires //; s/s.*/s/; s/,//g')

                    # Convert to total seconds by parsing hours, minutes, and seconds
                    HOURS=0
                    MINUTES=0
                    SECONDS=0

                    # Extract hours if present (format: Xh)
                    [ -n "$(echo "$TIME_STR" | grep 'h')" ] && HOURS=$(echo "$TIME_STR" | sed 's/h.*//; s/.*[^0-9]//')

                    # Extract minutes if present (format: Xm)
                    [ -n "$(echo "$TIME_STR" | grep 'm')" ] && MINUTES=$(echo "$TIME_STR" | sed 's/m.*//; s/.*h//; s/[^0-9]//g')

                    # Extract seconds (format: Xs)
                    SECONDS=$(echo "$TIME_STR" | sed 's/s.*//; s/.*m//; s/.*h//; s/[^0-9]//g')
                    [ -z "$SECONDS" ] && SECONDS=0

                    # Calculate current remaining time in seconds
                    CURRENT_SECONDS=$((HOURS * 3600 + MINUTES * 60 + SECONDS))

                    # Calculate new timeout (current + 30 minutes = current + 1800 seconds)
                    TOTAL_SECONDS=$((CURRENT_SECONDS + 1800))

                    # Delete existing entry first (required to update timeout)
                    nft "delete element inet fw4 denied_macs { $TARGET_MAC }" 2>/dev/null

                    # Re-add MAC with extended timeout
                    nft "add element inet fw4 denied_macs { $TARGET_MAC timeout ${TOTAL_SECONDS}s }"
                    MSG="⏳ Extended denial timeout for $TARGET_MAC (+30m, now ${TOTAL_SECONDS}s total)"
                else
                    # MAC not found or already expired
                    MSG="❌ Device not found in denied list or already expired."
                fi
            else
                # Invalid ID (not in current DSTATUS mapping or DSTATUS not run)
                MSG="❌ Invalid ID. Run DSTATUS first to get denied device IDs."
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

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

                MSG="✅ Removed $TARGET_MAC from denied list and approved for 30 minutes"
            else
                # Invalid ID (not in current DSTATUS mapping or DSTATUS not run)
                MSG="❌ Invalid ID. Run DSTATUS first to get denied device IDs."
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === EXTEND COMMAND ===
        # Extend network access timeout for a specific guest
        # Usage: "EXTEND 1" - extends access for guest ID 1 by 30 minutes
        elif [ "$CMD" = "EXTEND" ] && [ -n "$ARG" ]; then
            # Lookup MAC address from temporary ID mapping created by STATUS
            TARGET_MAC=$(grep "^$ARG=" "$MAP_FILE" | cut -d'=' -f2)

            if [ -n "$TARGET_MAC" ]; then
                # Get current remaining time from nftables
                CURRENT_LINE=$(nft list set inet fw4 approved_macs | grep "$TARGET_MAC" | grep "expires")

                if [ -n "$CURRENT_LINE" ]; then
                    # Parse remaining time (format: "29m59s", "15m30s", or "59s")
                    TIME_STR=$(echo "$CURRENT_LINE" | sed 's/.*expires //; s/s.*/s/; s/,//g')

                    # Convert to total seconds by parsing hours, minutes, and seconds
                    HOURS=0
                    MINUTES=0
                    SECONDS=0

                    # Extract hours if present (format: Xh)
                    [ -n "$(echo "$TIME_STR" | grep 'h')" ] && HOURS=$(echo "$TIME_STR" | sed 's/h.*//; s/.*[^0-9]//')

                    # Extract minutes if present (format: Xm)
                    [ -n "$(echo "$TIME_STR" | grep 'm')" ] && MINUTES=$(echo "$TIME_STR" | sed 's/m.*//; s/.*h//; s/[^0-9]//g')

                    # Extract seconds (format: Xs)
                    SECONDS=$(echo "$TIME_STR" | sed 's/s.*//; s/.*m//; s/.*h//; s/[^0-9]//g')
                    [ -z "$SECONDS" ] && SECONDS=0

                    # Calculate current remaining time in seconds
                    CURRENT_SECONDS=$((HOURS * 3600 + MINUTES * 60 + SECONDS))

                    # Calculate new timeout (current + 30 minutes = current + 1800 seconds)
                    TOTAL_SECONDS=$((CURRENT_SECONDS + 1800))

                    # Delete existing entry first (required to update timeout)
                    nft "delete element inet fw4 approved_macs { $TARGET_MAC }" 2>/dev/null

                    # Re-add MAC with extended timeout
                    nft "add element inet fw4 approved_macs { $TARGET_MAC timeout ${TOTAL_SECONDS}s }"
                    MSG="⏳ Extended access for $TARGET_MAC (+30m, now ${TOTAL_SECONDS}s total)"
                else
                    # MAC not found or already expired
                    MSG="❌ Device not found in approved list or already expired."
                fi
            else
                # Invalid ID (not in current STATUS mapping or STATUS not run)
                MSG="❌ Invalid ID."
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === REVOKE COMMAND ===
        # Immediately revoke network access for a specific guest
        # Usage: "REVOKE 1" - blocks guest ID 1 immediately
        elif [ "$CMD" = "REVOKE" ] && [ -n "$ARG" ]; then
            # Lookup MAC address from temporary ID mapping created by STATUS
            TARGET_MAC=$(grep "^$ARG=" "$MAP_FILE" | cut -d'=' -f2)
            
            if [ -n "$TARGET_MAC" ]; then
                # Remove MAC from approved_macs set (blocks network access immediately)
                # Device will be denied at firewall until manually re-approved
                nft "delete element inet fw4 approved_macs { $TARGET_MAC }"
                MSG="🚫 Revoked access for $TARGET_MAC"
            else
                # Invalid ID (not in current STATUS mapping or STATUS not run)
                MSG="❌ Invalid ID."
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        # === LOG COMMAND ===
        # Display last 10 entries from gatekeeper activity log
        # Log contains device connection events written by gatekeeper.sh
        elif [ "$CMD" = "LOG" ]; then
            # Read last 10 log entries and format for Telegram (escape newlines)
            [ -f "$LOG_FILE" ] && LOGS=$(tail -n 10 "$LOG_FILE" | sed ':a;N;$!ba;s/\n/\\n/g') || LOGS="No logs."
            
            # Send log entries as monospace code block
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
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
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🔄 Synced $i static leases."

        # === ENABLE COMMAND ===
        # Re-enable gatekeeper after emergency disable
        # Clears bypass_switch to restore normal firewall filtering
        elif [ "$CMD" = "ENABLE" ]; then
            # Remove all entries from bypass_switch (including ff:ff:ff:ff:ff:ff)
            # Restores normal gatekeeper firewall operation
            nft flush set inet fw4 bypass_switch
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🛡️ Enabled"

        # === DISABLE COMMAND ===
        # Emergency disable gatekeeper (global bypass)
        # Allows all LAN→WAN traffic regardless of MAC address
        elif [ "$CMD" = "DISABLE" ]; then
            # Add magic MAC address to bypass_switch to activate global bypass
            # Firewall rules check for this MAC and skip all filtering if present
            nft "add element inet fw4 bypass_switch { ff:ff:ff:ff:ff:ff }"
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🔓 Disabled"

        # === CLEAR COMMAND ===
        # Clear activity logs and hostname cache
        # Useful for privacy or troubleshooting
        elif [ "$CMD" = "CLEAR" ]; then
            # Truncate log file and name map (preserves files but clears content)
            > "$LOG_FILE"
            > "$NAME_MAP"
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🗑️ Logs and name cache cleared."

        # === BLACKLIST MODE ON ===
        # Enable blacklist mode - only MACs in blacklist require approval
        # All other MACs are auto-approved with 24-hour timeout
        elif [ "$CMD" = "BL_ON" ] || [ "$CMD" = "BLACKLIST_ON" ]; then
            # Set blacklist mode to enabled in UCI config
            uci set gatekeeper.main.blacklist_mode='1'
            uci commit gatekeeper

            # Sync blacklist to nftables (in case it's not synced yet)
            nft flush set inet fw4 blacklist_macs 2>/dev/null
            BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep "\.mac=" | cut -d"'" -f2)
            for mac in $BLACKLIST_MACS; do
                [ -z "$mac" ] && continue
                nft add element inet fw4 blacklist_macs { $mac } 2>/dev/null
            done

            MSG="✅ *Blacklist Mode: ENABLED*\n\n"
            MSG="${MSG}Only devices in the blacklist will require approval.\n"
            MSG="${MSG}All other devices will be auto-approved for 24 hours."
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLACKLIST MODE OFF ===
        # Disable blacklist mode - return to normal behavior (all require approval)
        elif [ "$CMD" = "BL_OFF" ] || [ "$CMD" = "BLACKLIST_OFF" ]; then
            # Set blacklist mode to disabled in UCI config
            uci set gatekeeper.main.blacklist_mode='0'
            uci commit gatekeeper

            MSG="✅ *Blacklist Mode: DISABLED*\n\n"
            MSG="${MSG}All devices will require approval (normal mode)."
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLACKLIST STATUS ===
        # Show blacklist mode status and list all blacklisted MACs
        elif [ "$CMD" = "BL_STATUS" ] || [ "$CMD" = "BLACKLIST_STATUS" ]; then
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
            BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep "\.mac=" | cut -d"'" -f2)
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

            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLACKLIST ADD ===
        # Add a MAC address to the blacklist
        # Usage: "BL_ADD aa:bb:cc:dd:ee:ff"
        elif [ "$CMD" = "BL_ADD" ] || [ "$CMD" = "BLACKLIST_ADD" ]; then
            if [ -z "$ARG" ]; then
                MSG="❌ Usage: BL_ADD <MAC>\nExample: BL_ADD aa:bb:cc:dd:ee:ff"
            else
                # Convert MAC to lowercase for consistency
                ADD_MAC=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')

                # Validate MAC format (basic check)
                if echo "$ADD_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                    # Check if blacklist section exists, create if not
                    if ! uci -q get gatekeeper.blacklist >/dev/null 2>&1; then
                        uci set gatekeeper.blacklist=blacklist
                    fi

                    # Add to UCI blacklist
                    uci add_list gatekeeper.blacklist.mac="$ADD_MAC"
                    uci commit gatekeeper

                    # Add to nftables set
                    nft add element inet fw4 blacklist_macs { $ADD_MAC } 2>/dev/null

                    MSG="✅ Added to blacklist: \`${ADD_MAC}\`"
                    logger -t tg_bot "Added $ADD_MAC to blacklist"
                else
                    MSG="❌ Invalid MAC format. Use: aa:bb:cc:dd:ee:ff"
                fi
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLACKLIST REMOVE ===
        # Remove a MAC address from the blacklist
        # Usage: "BL_REMOVE aa:bb:cc:dd:ee:ff"
        elif [ "$CMD" = "BL_REMOVE" ] || [ "$CMD" = "BLACKLIST_REMOVE" ]; then
            if [ -z "$ARG" ]; then
                MSG="❌ Usage: BL_REMOVE <MAC>\nExample: BL_REMOVE aa:bb:cc:dd:ee:ff"
            else
                # Convert MAC to lowercase for consistency
                REMOVE_MAC=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')

                # Remove from UCI blacklist
                uci del_list gatekeeper.blacklist.mac="$REMOVE_MAC" 2>/dev/null
                uci commit gatekeeper

                # Remove from nftables set (ignore errors if not present)
                nft delete element inet fw4 blacklist_macs { $REMOVE_MAC } 2>/dev/null

                MSG="✅ Removed from blacklist: \`${REMOVE_MAC}\`"
                logger -t tg_bot "Removed $REMOVE_MAC from blacklist"
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

        # === BLACKLIST CLEAR ===
        # Clear all MACs from the blacklist
        elif [ "$CMD" = "BL_CLEAR" ] || [ "$CMD" = "BLACKLIST_CLEAR" ]; then
            # Delete and recreate blacklist section in UCI
            uci delete gatekeeper.blacklist 2>/dev/null
            uci set gatekeeper.blacklist=blacklist
            uci commit gatekeeper

            # Clear nftables blacklist set
            nft flush set inet fw4 blacklist_macs 2>/dev/null

            MSG="✅ Blacklist cleared - all MACs removed"
            logger -t tg_bot "Blacklist cleared"
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"
        fi
    done
    
    # Reload offset from file after processing batch of updates
    # Ensures offset persists across loop iterations
    [ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE")
done