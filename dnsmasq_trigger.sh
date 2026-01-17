#!/bin/sh

# 1. Capture Positional Arguments
ARG_ACTION="$1"
ARG_MAC="$2"
ARG_IP="$3"
ARG_HOST="$4"

# 2. Fallback to Environment Variables if arguments are empty
# dnsmasq sets DNSMASQ_INTERFACE, DNSMASQ_TIME, etc.
FINAL_ACTION="${ARG_ACTION:-$DNSMASQ_EVENT}"
FINAL_MAC="${ARG_MAC:-$DNSMASQ_CLIENT_ID}"
FINAL_IP="${ARG_IP:-$DNSMASQ_LEASE_IP}"
FINAL_HOST="${ARG_HOST:-$DNSMASQ_SUPPLIED_HOSTNAME}"

# 3. Clean up potential empty values to avoid JSON breakage
FINAL_ACTION="${FINAL_ACTION:-unknown}"
FINAL_MAC="${FINAL_MAC:-00:00:00:00:00:00}"
FINAL_IP="${FINAL_IP:-0.0.0.0}"
FINAL_HOST="${FINAL_HOST:-no_hostname}"

# 4. Send to ubus
ubus send dnsmasq.event "{
    \"action\":\"$FINAL_ACTION\",
    \"mac\":\"$FINAL_MAC\",
    \"ip\":\"$FINAL_IP\",
    \"host\":\"$FINAL_HOST\"
}"
