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

# gatekeeper_sync.sh - Manual synchronization utility for static DHCP MAC addresses
#
# This script provides manual synchronization of static MAC addresses from 
# OpenWrt's UCI DHCP configuration to the gatekeeper firewall rules. It's designed
# to be called interactively or via the Telegram bot's SYNC command.
#
# Key Differences from gatekeeper_init:
# - Can be run manually at any time (not just boot)
# - Uses proper UCI array iteration (@host[$INDEX]) for robust parsing
# - Provides user feedback about number of synchronized addresses
# - Maintains firewall rules without disrupting active connections
#
# Usage: Run directly as /usr/bin/gatekeeper_sync.sh or via Telegram bot
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

# Step 1: Flush the existing set to avoid duplicates or orphaned entries
# This ensures a clean slate by removing all current static MAC entries
nft flush set inet fw4 static_macs

# Step 2: Correctly iterate through UCI dhcp host sections to find MAC addresses
# Uses array-index based iteration for reliable parsing across UCI versions
INDEX=0
while true; do
    # Query UCI for MAC address at current array index
    # -q flag suppresses errors for missing entries
    MAC=$(uci -q get dhcp.@host[$INDEX].mac)
    
    # No more host entries? Exit loop
    [ -z "$MAC" ] && break

    # Add each MAC found to the nftables set
    # Handles both single MACs and space-separated multiple MACs
    nft add element inet fw4 static_macs { "$MAC" }
    
    # Increment counter for next iteration
    INDEX=$((INDEX + 1))
done

# Provide user feedback about synchronization result
# Count includes all MACs processed (even if some were empty)
echo "Successfully synchronized $INDEX static MAC addresses."
