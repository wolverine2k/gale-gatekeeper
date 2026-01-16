#!/bin/sh
# --- JAIL-PROOF NOTIFICATION SCRIPT ---

EVENT="$1"
MAC="$2"
IP="$3"
HOST="$4"

# We write directly to /tmp because custom subdirectories are often hidden from the jail.
# The filename format 'tgq_MAC.notif' allows the bot to find it easily.
if [ "$EVENT" = "add" ] || [ "$EVENT" = "old" ]; then
    echo "$EVENT|$MAC|$IP|$HOST" > "/tmp/tgq_$MAC.notif"
fi
