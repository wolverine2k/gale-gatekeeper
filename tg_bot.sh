# Configuration: Telegram Bot API token and Chat ID from UCI config
# Read from environment variables (set by init script) or fall back to UCI
TOKEN="${GATEKEEPER_TOKEN:-$(uci -q get gatekeeper.@main[0].token)}"
CHAT_ID="${GATEKEEPER_CHAT_ID:-$(uci -q get gatekeeper.@main[0].chat_id)}"

# Validate configuration
if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    logger -t tg_bot "ERROR: TOKEN or CHAT_ID not configured. Set via UCI: uci set gatekeeper.@main[0].token='YOUR_TOKEN' && uci set gatekeeper.@main[0].chat_id='YOUR_CHAT_ID'"
    exit 1
fi

LOG_FILE="/tmp/gatekeeper.log"
NAME_MAP="/tmp/mac_names"
MAP_FILE="/tmp/mac_map"
OFFSET_FILE="/tmp/tg_offset"

OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

while true; do
    RESPONSE=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=30")
    [ -z "$RESPONSE" ] && sleep 2 && continue

    echo "$RESPONSE" | jq -c '.result[]' 2>/dev/null | while read -r row; do

        UPDATE_ID=$(echo "$row" | jq -r '.update_id')
        OFFSET=$((UPDATE_ID + 1))
        echo "$OFFSET" > "$OFFSET_FILE"

        # --- 1. CALLBACK HANDLER (APPROVE/DENY) ---
        CB_DATA=$(echo "$row" | jq -r '.callback_query.data // empty')
        if [ -n "$CB_DATA" ]; then
            C_ID=$(echo "$row" | jq -r '.callback_query.message.chat.id')
            M_ID=$(echo "$row" | jq -r '.callback_query.message.message_id')
            CB_ID=$(echo "$row" | jq -r '.callback_query.id')

            ACT=$(echo "$CB_DATA" | cut -d'_' -f1)
            MAC=$(echo "$CB_DATA" | cut -d'_' -f2-)

            if [ "$ACT" = "approve" ]; then
                nft "add element inet fw4 approved_macs { $MAC timeout 30m }"
                # FIX: Extract the 4th column (Hostname) from the gatekeeper log
                H_NAME=$(grep -i "$MAC" "$LOG_FILE" | tail -n 1 | awk '{print $4}')
                if [ -n "$H_NAME" ]; then
                    # Remove old entry if exists and add new one
                    sed -i "/$MAC/d" "$NAME_MAP" 2>/dev/null
                    echo "$MAC=$H_NAME" >> "$NAME_MAP"
                fi
                OUT="✅ Approved: ${H_NAME:-$MAC}"
            else
                nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
		nft "add element inet fw4 denied_macs { $MAC timeout 30m }"
                OUT="❌ Denied: $MAC"
            fi

            curl -s "https://api.telegram.org/bot$TOKEN/answerCallbackQuery?callback_query_id=$CB_ID" >/dev/null
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/editMessageText" -d "chat_id=$C_ID" -d "message_id=$M_ID" -d "text=$OUT"
            continue
        fi

        # --- 2. TEXT COMMAND HANDLER ---
        TEXT=$(echo "$row" | jq -r '.message.text // empty')
        U_ID=$(echo "$row" | jq -r '.message.chat.id // empty')
        [ "$U_ID" != "$CHAT_ID" ] && continue
        [ -z "$TEXT" ] && continue

        CMD=$(echo "$TEXT" | awk '{print toupper($1)}')
        ARG=$(echo "$TEXT" | awk '{print $2}')

        if [ "$CMD" = "STATUS" ]; then
            BYPASS=$(nft list set inet fw4 bypass_switch | grep -q "ff:ff:ff:ff:ff:ff" && echo "🔓 DISABLED" || echo "🛡️ ENABLED")
            RAW_LIST=$(nft list set inet fw4 approved_macs | grep "expires")
            RAW_LIST+=$'\n'$(nft list set inet fw4 denied_macs | grep "expires")

            MSG="🛡️ *Gatekeeper:* $BYPASS\n📋 *Active Guests:*\n"

            rm -f "$MAP_FILE"
            if [ -z "$RAW_LIST" ]; then
                MSG="${MSG}_None active_\n"
            else
                count=1
                while read -r line; do
                    M_ADDR=$(echo "$line" | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
                    M_TIME=$(echo "$line" | sed 's/.*expires //; s/s.*/s/; s/,//g')

                    # NAME LOOKUP PRIORITY:
                    # 1. Custom Name Map (Cached during Approval)
                    H_NAME=$(grep -i "$M_ADDR" "$NAME_MAP" | tail -n 1 | cut -d'=' -f2)
                    # 2. DHCP Leases
                    [ -z "$H_NAME" ] && H_NAME=$(grep -i "$M_ADDR" /tmp/dhcp.leases | awk '{print $4}')
                    # 3. Static UCI Config
                    [ -z "$H_NAME" ] || [ "$H_NAME" = "*" ] && H_NAME=$(uci show dhcp | grep -i "$M_ADDR" | cut -d. -f2 | xargs -I {} uci -q get dhcp.{}.name)
                    # 4. Fallback
                    [ -z "$H_NAME" ] && H_NAME="Guest"

                    echo "$count=$M_ADDR" >> "$MAP_FILE"
                    MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME})\n"
                    count=$((count + 1))
                done <<EOF
$RAW_LIST
EOF
                MSG="${MSG}\n💡 Reply \`Extend ID\` or \`Revoke ID\`"
            fi

            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"keyboard\":[[{\"text\":\"Status\"},{\"text\":\"Sync\"},{\"text\":\"Log\"}],[{\"text\":\"Enable\"},{\"text\":\"Disable\"},{\"text\":\"Clear\"}]],\"resize_keyboard\":true}}"

        elif [ "$CMD" = "EXTEND" ] && [ -n "$ARG" ]; then
            TARGET_MAC=$(grep "^$ARG=" "$MAP_FILE" | cut -d'=' -f2)
            if [ -n "$TARGET_MAC" ]; then
                nft "add element inet fw4 approved_macs { $TARGET_MAC timeout 30m }"
                MSG="⏳ Extended access for $TARGET_MAC"
            else
                MSG="❌ Invalid ID."
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        elif [ "$CMD" = "REVOKE" ] && [ -n "$ARG" ]; then
            TARGET_MAC=$(grep "^$ARG=" "$MAP_FILE" | cut -d'=' -f2)
            if [ -n "$TARGET_MAC" ]; then
                nft "delete element inet fw4 approved_macs { $TARGET_MAC }"
                MSG="🚫 Revoked access for $TARGET_MAC"
            else
                MSG="❌ Invalid ID."
            fi
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MSG"

        elif [ "$CMD" = "LOG" ]; then
            [ -f "$LOG_FILE" ] && LOGS=$(tail -n 10 "$LOG_FILE" | sed ':a;N;$!ba;s/\n/\\n/g') || LOGS="No logs."
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"📜 *Recent Logs:*\\n\`$LOGS\`\",\"parse_mode\":\"Markdown\"}"

        elif [ "$CMD" = "SYNC" ]; then
            nft flush set inet fw4 static_macs
            i=0; while M=$(uci -q get dhcp.@host[$i].mac); do
                for sm in $M; do nft "add element inet fw4 static_macs { $sm }"; done
                i=$((i+1))
            done
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🔄 Synced $i static leases."

        elif [ "$CMD" = "ENABLE" ]; then
            nft flush set inet fw4 bypass_switch
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🛡️ Enabled"

        elif [ "$CMD" = "DISABLE" ]; then
            nft "add element inet fw4 bypass_switch { ff:ff:ff:ff:ff:ff }"
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🔓 Disabled"

        elif [ "$CMD" = "CLEAR" ]; then
            > "$LOG_FILE"
            > "$NAME_MAP"
            curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" -d "chat_id=$CHAT_ID" -d "text=🗑️ Logs and name cache cleared."
        fi
    done
    [ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE")
done