#!/bin/sh

# 1. Flush the existing set to avoid duplicates or orphaned entries
nft flush set inet fw4 static_macs

# 2. Correctly iterate through UCI dhcp host sections to find MAC addresses
INDEX=0
while true; do
    MAC=$(uci -q get dhcp.@host[$INDEX].mac)
    [ -z "$MAC" ] && break

    # Add each MAC found to the nftables set
    nft add element inet fw4 static_macs { "$MAC" }
    INDEX=$((INDEX + 1))
done

echo "Successfully synchronized $INDEX static MAC addresses."
