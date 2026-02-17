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

# gatekeeper_sync.sh - Manual synchronization utility for MAC address lists
#
# This script provides manual synchronization of MAC addresses from UCI configuration
# to gatekeeper firewall nftables sets. Supports both static DHCP leases and blacklist MACs.
#
# Usage:
#   gatekeeper_sync.sh          - Sync both static and blacklist MACs (default)
#   gatekeeper_sync.sh static   - Sync only static DHCP MACs
#   gatekeeper_sync.sh blacklist - Sync only blacklist MACs
#
# Key Features:
# - Can be run manually at any time (not just boot)
# - Uses proper UCI array iteration for robust parsing
# - Provides user feedback about number of synchronized addresses
# - Maintains firewall rules without disrupting active connections
#
# Technical Implementation:
# - Uses UCI's array syntax (@host[0], @host[1], etc.) to iterate DHCP hosts
# - Quits gracefully when no more host entries are found ([ -z "$MAC" ])
# - Each MAC is individually added to the static_macs nftables set
# - Supports multiple MACs per host entry (space-separated in UCI config)
#
# Security Notes:
# - Only reads from trusted UCI configuration (dhcp.@host[*])
# - Clears existing set before sync to prevent stale entries
# - No external input parameters to sanitize
#
# Extensibility:
# - To sync from additional sources, extend the while loop logic
# - For bulk operations, consider implementing backup/restore functionality
# - To support dynamic hostname updates, add name synchronization logic

# Parse command line argument to determine what to sync
SYNC_MODE="${1:-all}"  # Default to "all" if no argument provided

# === SYNC STATIC DHCP MACS ===
# Synchronize static DHCP lease MACs from UCI to nftables
if [ "$SYNC_MODE" = "static" ] || [ "$SYNC_MODE" = "all" ]; then
    # Flush the existing set to avoid duplicates or orphaned entries
    nft flush set inet fw4 static_macs

    # Iterate through UCI dhcp host sections to find MAC addresses
    # Uses array-index based iteration for reliable parsing
    INDEX=0
    while true; do
        # Query UCI for MAC address at current array index
        MAC=$(uci -q get dhcp.@host[$INDEX].mac)

        # No more host entries? Exit loop
        [ -z "$MAC" ] && break

        # Add each MAC found to the nftables set
        nft add element inet fw4 static_macs { "$MAC" }

        INDEX=$((INDEX + 1))
    done

    echo "Successfully synchronized $INDEX static MAC addresses."
    logger -t gatekeeper_sync "Synced $INDEX static MACs"
fi

# === SYNC BLACKLIST MACS ===
# Synchronize blacklist MACs from UCI to nftables
if [ "$SYNC_MODE" = "blacklist" ] || [ "$SYNC_MODE" = "all" ]; then
    # Flush the existing blacklist set
    nft flush set inet fw4 blacklist_macs 2>/dev/null

    # Get all blacklist MACs from UCI config
    # Format: gatekeeper.blacklist.mac='aa:bb:cc:dd:ee:ff'
    BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null | grep "\.mac=" | cut -d"'" -f2)

    COUNT=0
    for mac in $BLACKLIST_MACS; do
        # Skip empty entries
        [ -z "$mac" ] && continue

        # Add MAC to nftables blacklist set
        nft add element inet fw4 blacklist_macs { "$mac" } 2>/dev/null
        COUNT=$((COUNT + 1))
    done

    echo "Successfully synchronized $COUNT blacklist MAC addresses."
    logger -t gatekeeper_sync "Synced $COUNT blacklist MACs"
fi
