#!/bin/sh
# Variables from dnsmasq
ACTION="${1:-unknown}"
MAC="${2:-00:00:00:00:00:00}"
IP="${3:-0.0.0.0}"
HOST="${4:-no_hostname}"

# Use single quotes for the 'ubus send' argument to protect the inner JSON
ubus send dnsmasq.event '{"action":"'"$ACTION"'", "mac":"'"$MAC"'", "ip":"'"$IP"'", "host":"'"$HOST"'"}'
