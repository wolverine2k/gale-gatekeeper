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

# gatekeeper_trigger.sh - ubus event listener and triggering script
#
# This script continuously monitors ubus messages for dnsmasq DHCP events and
# triggers the main gatekeeper logic when network events occur. It implements
# rate limiting to prevent duplicate triggers for the same MAC within a short
# timeframe.
#
# Architecture:
# - Listens to ubus messages from dnsmasq_trigger.sh
# - Parses JSON-like ubus output using basic BusyBox tools (grep, cut) 
# - Maintains rate limiting via timestamp files in /tmp/dns_locks
# - Triggers gatekeeper.sh for final processing and Telegram notifications
#
# Rate Limiting Mechanism:
# - Creates timestamp files in /tmp/dns_locks using sanitized MAC (no colons)
# - Prevents re-triggering the same MAC within 60 seconds
# - Protects against duplicate DHCP requests and network flapping
#
# Key Features:
# - Uses only standard BusyBox utilities (no external dependencies)
# - Handles malformed or missing MAC addresses gracefully
# - Logs trigger events to system logger
# - Designed for continuous execution as a procd-managed service
#
# Requirements:
# - ubus monitoring capability
# - /tmp directory writable for lock files
# - gatekeeper.sh script installed at /usr/bin/gatekeeper.sh
#
# Usage:
# - Started automatically by gatekeeper_trigger_listener init script
# - Monitors continuously: use logread -f | grep DNS_LISTENER for debugging
# - Rate limiting info available in /tmp/dns_locks/ directory
#
# Maintenance Notes:
# - Lock files are automatically cleaned by tmp reaper or manual cleanup
# - Consider monitoring /tmp/dns_locks directory size for troubleshooting
# - For heavy network environments, adjust 60-second rate limit as needed

# Configuration: Lock directory for rate limiting timestamp files
LOCK_DIR="/tmp/dns_locks"
mkdir -p "$LOCK_DIR"

# Main listening loop: Monitor ubus messages continuously
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

            # 2. Validation: MAC is required for all gatekeeper operations
            [ -z "$MAC" ] && continue

            # 3. Lock/Rate Limit Logic: Prevent duplicate triggers within 60 seconds
            MAC_CLEAN=$(echo "$MAC" | tr -d ':')  # Remove colons for filename safety
            LOCK_FILE="$LOCK_DIR/$MAC_CLEAN"
            NOW=$(date +%s)  # Current Unix timestamp

            if [ -f "$LOCK_FILE" ]; then
                LAST=$(cat "$LOCK_FILE")
                # If less than 60 seconds since last trigger, skip this one
                [ $((NOW - LAST)) -lt 60 ] && continue
            fi
            
            # Update timestamp file for rate limiting
            echo "$NOW" > "$LOCK_FILE"

            # 4. Trigger the unconstrained environment for final processing
            logger -t "DNS_LISTENER" "Triggering for $MAC ($HOST) at $IP"
            /usr/bin/gatekeeper.sh "add" "$MAC" "$IP" "$HOST" "$ACTION"
            ;;
    esac
done
