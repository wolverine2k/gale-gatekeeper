#!/bin/sh

LOCK_DIR="/tmp/dns_locks"
mkdir -p "$LOCK_DIR"

ubus monitor | while read -r line; do
    # Only process if our event is present
    case "$line" in
        *"dnsmasq.event"*)
            # 1. Extract values using grep and sed (Standard BusyBox tools)
            # These regexes find the "key":"value" and extract just the value
            ACTION=$(echo "$line" | grep -o '"action":"[^"]*' | cut -d'"' -f4)
            MAC=$(echo "$line" | grep -o '"mac":"[^"]*' | cut -d'"' -f4)
            IP=$(echo "$line" | grep -o '"ip":"[^"]*' | cut -d'"' -f4)
            HOST=$(echo "$line" | grep -o '"host":"[^"]*' | cut -d'"' -f4)

            # 2. Validation
            [ -z "$MAC" ] && continue

            # 3. Lock/Rate Limit Logic
            MAC_CLEAN=$(echo "$MAC" | tr -d ':')
            LOCK_FILE="$LOCK_DIR/$MAC_CLEAN"
            NOW=$(date +%s)

            if [ -f "$LOCK_FILE" ]; then
                LAST=$(cat "$LOCK_FILE")
                [ $((NOW - LAST)) -lt 60 ] && continue
            fi
            echo "$NOW" > "$LOCK_FILE"

            # 4. Trigger the unconstrained environment
            logger -t "DNS_LISTENER" "Triggering for $MAC ($HOST) at $IP"
            /usr/bin/gatekeeper.sh "add" "$MAC" "$IP" "$HOST" "$ACTION"
            ;;
    esac
done
