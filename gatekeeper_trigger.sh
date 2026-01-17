#!/bin/sh
. /usr/share/libubox/jshn.sh

ubus monitor | while read -r line; do
    case "$line" in
        *"dnsmasq.event"*)
            # Debug: Print the raw line to system log
            logger -t "DNS_LISTENER" "Raw event received: $line"

            json_data=$(echo "$line" | sed 's/.*dnsmasq.event-> //')

            json_load "$json_data"
            json_get_var action action
            json_get_var mac mac
            json_get_var ip ip
            json_get_var host host

            /usr/bin/gatekeeper.sh  "$action" "$mac" "$ip" "$host"
            ;;
    esac
done
