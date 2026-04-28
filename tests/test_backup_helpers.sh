#!/bin/sh
# Dev-only unit tests for backup pure-text transforms.
# These transforms are inlined verbatim into the BACKUP handler in tg_bot.sh.
# When you change one, change both. Run from repo root:
#   sh tests/test_backup_helpers.sh

set -u
PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label"
        echo "----- got -----"
        printf '%s\n' "$got"
        echo "----- want -----"
        printf '%s\n' "$want"
        echo "----- end -----"
    fi
}

# --- Test 1: config host extractor ---------------------------------------
# The awk script in tg_bot.sh extracts only `config host` blocks from a
# /etc/config/dhcp-style input.

extract_hosts() {
    awk '/^config[[:space:]]/ { in_host = ($2 == "host") } in_host { print }'
}

DHCP_FIXTURE='config dnsmasq
	option domainneeded '\''1'\''
	option boguspriv '\''1'\''

config dhcp '\''lan'\''
	option interface '\''lan'\''

config host '\''kids'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option ip '\''192.168.1.50'\''
	option name '\''kids-tablet'\''

config host
	option mac '\''11:22:33:44:55:66'\''
	option ip '\''192.168.1.51'\''

config odhcpd '\''odhcpd'\''
	option maindhcp '\''0'\'''

EXPECTED_HOSTS='config host '\''kids'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option ip '\''192.168.1.50'\''
	option name '\''kids-tablet'\''

config host
	option mac '\''11:22:33:44:55:66'\''
	option ip '\''192.168.1.51'\'''

GOT=$(printf '%s\n' "$DHCP_FIXTURE" | extract_hosts)
assert_eq "extract_hosts: skips dnsmasq+dhcp+odhcpd, keeps both host blocks" \
    "$GOT" "$EXPECTED_HOSTS"

# Empty input -> empty output.
GOT=$(printf '' | extract_hosts)
assert_eq "extract_hosts: empty input" "$GOT" ""

# Input with no host blocks -> empty output.
NO_HOSTS='config dnsmasq
	option boguspriv '\''1'\''

config dhcp '\''lan'\''
	option interface '\''lan'\'''
GOT=$(printf '%s\n' "$NO_HOSTS" | extract_hosts)
assert_eq "extract_hosts: input with no host blocks" "$GOT" ""

# --- Test 2: secret stripper ---------------------------------------------
# The sed -E script in tg_bot.sh blanks the value of `option token` and
# `option chat_id` while leaving everything else untouched.

strip_secrets() {
    sed -E "s/^([[:space:]]*option (token|chat_id) ).*/\1''/"
}

GK_FIXTURE='package gatekeeper

config gatekeeper '\''main'\''
	option token '\''secret123:abcdef'\''
	option chat_id '\''987654321'\''
	option blacklist_mode '\''0'\''
	option disabled '\''0'\''

config schedule '\''sched_kids_eve'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option enabled '\''1'\'''

EXPECTED_STRIPPED='package gatekeeper

config gatekeeper '\''main'\''
	option token '\'\''
	option chat_id '\'\''
	option blacklist_mode '\''0'\''
	option disabled '\''0'\''

config schedule '\''sched_kids_eve'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option enabled '\''1'\'''

GOT=$(printf '%s\n' "$GK_FIXTURE" | strip_secrets)
assert_eq "strip_secrets: blanks token+chat_id, preserves others" \
    "$GOT" "$EXPECTED_STRIPPED"

# A line whose option name *contains* token/chat_id but isn't exactly
# "token" / "chat_id" must NOT be matched (e.g., "stoken_alt").
NEAR_FIXTURE='	option stoken_alt '\''nope'\''
	option chat_id_alt '\''also_nope'\''
	option token '\''real'\'''
EXPECTED_NEAR='	option stoken_alt '\''nope'\''
	option chat_id_alt '\''also_nope'\''
	option token '\'\'''
GOT=$(printf '%s\n' "$NEAR_FIXTURE" | strip_secrets)
assert_eq "strip_secrets: only matches exact token/chat_id keys" \
    "$GOT" "$EXPECTED_NEAR"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
