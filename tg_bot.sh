#!/bin/sh
TOKEN="YOUR_BOT_TOKEN"
CHAT_ID="YOUR_CHAT_ID"
LOG_FILE="/tmp/gatekeeper.log"
NAME_MAP="/tmp/mac_names"
OFFSET_FILE="/tmp/tg_offset"

OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

while true; do
    # 1. Check for files starting with tgq_ in /tmp
    for f in /tmp/tgq_*.notif; do
        [ -e "$f" ] || break
        DATA=$(cat "$f")
        rm "$f"

        EVENT=$(echo "$DATA" | cut -d'|' -f1)
        MAC=$(echo "$DATA" | cut -d'|' -f2)
        IP=$(echo "$DATA" | cut -d'|' -f3)
        HOST=$(echo "$DATA" | cut -d'|' -f4)

        JSON="{\"chat_id\":\"$CHAT_ID\",\"text\":\"🔔 *Unauthorized Connection*\n*Event:* $EVENT\n*Host:* $HOST\n*MAC:* $MAC\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"✅ Approve (30m)\",\"callback_data\":\"approve_$MAC\"},{\"text\":\"❌ Deny\",\"callback_data\":\"deny_$MAC\"}]]}}"
        curl -s -X POST "[https://api.telegram.org/bot$TOKEN/sendMessage](https://api.telegram.org/bot$TOKEN/sendMessage)" -H "Content-Type: application/json" -d "$JSON"
        echo "$(date) Notification sent for $MAC" >> "$LOG_FILE"
    done

    # 2. Check for Telegram Updates (Buttons/Commands)
    RESPONSE=$(curl -s "[https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=10](https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=10)")
    [ -z "$RESPONSE" ] && continue

    echo "$RESPONSE" | jq -c '.result[]' 2>/dev/null | while read -r row; do
        UPDATE_ID=$(echo "$row" | jq -r '.update_id')
        OFFSET=$((UPDATE_ID + 1))
        echo "$OFFSET" > "$OFFSET_FILE"

        CB_DATA=$(echo "$row" | jq -r '.callback_query.data // empty')
        if [ -n "$CB_DATA" ]; then
            C_ID=$(echo "$row" | jq -r '.callback_query.message.chat.id')
            M_ID=$(echo "$row" | jq -r '.callback_query.message.message_id')
            CB_ID=$(echo "$row" | jq -r '.callback_query.id')
            ACT=$(echo "$CB_DATA" | cut -d'_' -f1)
            MAC=$(echo "$CB_DATA" | cut -d'_' -f2-)

            if [ "$ACT" = "approve" ]; then
                nft "add element inet fw4 approved_macs { $MAC timeout 30m }"
                OUT="✅ Approved: $MAC"
            else
                nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
                OUT="❌ Denied: $MAC"
            fi
            curl -s "[https://api.telegram.org/bot$TOKEN/answerCallbackQuery?callback_query_id=$CB_ID](https://api.telegram.org/bot$TOKEN/answerCallbackQuery?callback_query_id=$CB_ID)" >/dev/null
            curl -s -X POST "[https://api.telegram.org/bot$TOKEN/editMessageText](https://api.telegram.org/bot$TOKEN/editMessageText)" -d "chat_id=$C_ID" -d "message_id=$M_ID" -d "text=$OUT"
        fi
    done
    sleep 2
done
