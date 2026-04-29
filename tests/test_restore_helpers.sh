#!/bin/sh
# Dev-only unit tests for restore pure-text transforms.
# Canonical implementation lives in opkg/usr/lib/gatekeeper/restore_helpers.sh
# (sourced by tg_bot.sh and the LuCI rpcd backend). This test file inlines
# its own copies of the parser awk and is_valid_backup so it can run on a
# dev machine without sourcing the runtime library; when you change the
# canonical version, mirror the change here too. Run from repo root:
#   sh tests/test_restore_helpers.sh

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

assert_rc() {
    local label="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: got rc=$got want rc=$want"
    fi
}

# --- Test 1: parser ------------------------------------------------------
# The awk script in tg_bot.sh emits tab-separated records:
#   section <type> <name>
#   option <type> <name> <key> <value>
#   list <type> <name> <key> <value>

restore_parse() {
    awk '
        BEGIN { in_section = 0; cur_type = ""; cur_name = ""; OFS = "\t" }
        /^# === \/etc\/config\/gatekeeper ===/ { in_section = 1; next }
        /^# === \/etc\/config\/dhcp/ { in_section = 0; next }
        !in_section { next }
        /^[[:space:]]*$/ { next }
        /^#/ { next }
        /^package / { next }
        /^config / {
            cur_type = $2
            cur_name = ""
            if (NF >= 3) {
                n = $3
                gsub(/^['\''""]/, "", n); gsub(/['\''"]$/, "", n)
                cur_name = n
            }
            print "section", cur_type, cur_name
            next
        }
        /^[[:space:]]+(option|list) / {
            kind = $1
            key  = $2
            q1 = index($0, "'\''")
            if (q1 == 0) next
            q2 = length($0)
            while (q2 > q1 && substr($0, q2, 1) != "'\''") q2--
            if (q2 <= q1) next
            val = substr($0, q1+1, q2-q1-1)
            print kind, cur_type, cur_name, key, val
        }
    '
}

TAB=$(printf '\t')

FIXTURE='# Gatekeeper backup
# Generated:        2026-04-28T14:32:11+02:00
# Hostname:         openwrt
# Schema:           v1
# Includes secrets: yes

# === /etc/config/gatekeeper ===
package gatekeeper

config gatekeeper '\''main'\''
	option token '\''abc:xyz'\''
	option chat_id '\''123'\''
	option blacklist_mode '\''1'\''

config blacklist '\''blacklist'\''
	list mac '\''aa:bb:cc:dd:ee:ff'\''
	list mac '\''11:22:33:44:55:66'\''

config schedule '\''sched_kids_eve'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option days '\''weekdays'\''
	option start '\''16:00'\''
	option stop '\''20:00'\''
	option label '\''Kids tablet evening'\''
	option enabled '\''1'\''

# === /etc/config/dhcp (host entries only) ===
config host
	option name '\''should-be-ignored'\''
	list mac '\''99:99:99:99:99:99'\'''

EXPECTED="section${TAB}gatekeeper${TAB}main
option${TAB}gatekeeper${TAB}main${TAB}token${TAB}abc:xyz
option${TAB}gatekeeper${TAB}main${TAB}chat_id${TAB}123
option${TAB}gatekeeper${TAB}main${TAB}blacklist_mode${TAB}1
section${TAB}blacklist${TAB}blacklist
list${TAB}blacklist${TAB}blacklist${TAB}mac${TAB}aa:bb:cc:dd:ee:ff
list${TAB}blacklist${TAB}blacklist${TAB}mac${TAB}11:22:33:44:55:66
section${TAB}schedule${TAB}sched_kids_eve
option${TAB}schedule${TAB}sched_kids_eve${TAB}mac${TAB}aa:bb:cc:dd:ee:ff
option${TAB}schedule${TAB}sched_kids_eve${TAB}days${TAB}weekdays
option${TAB}schedule${TAB}sched_kids_eve${TAB}start${TAB}16:00
option${TAB}schedule${TAB}sched_kids_eve${TAB}stop${TAB}20:00
option${TAB}schedule${TAB}sched_kids_eve${TAB}label${TAB}Kids tablet evening
option${TAB}schedule${TAB}sched_kids_eve${TAB}enabled${TAB}1"

GOT=$(printf '%s\n' "$FIXTURE" | restore_parse)
assert_eq "parser: full fixture, dhcp section ignored, value-with-spaces preserved" \
    "$GOT" "$EXPECTED"

# Empty input -> empty output.
GOT=$(printf '' | restore_parse)
assert_eq "parser: empty input" "$GOT" ""

# Input with no gatekeeper section -> empty output.
NO_GK='# === /etc/config/dhcp (host entries only) ===
config host
	list mac '\''99:99:99:99:99:99'\'''
GOT=$(printf '%s\n' "$NO_GK" | restore_parse)
assert_eq "parser: only dhcp section, no gatekeeper" "$GOT" ""

# --- Test 2: is_valid_backup ---------------------------------------------
# Predicate that gates restore on file structure.

is_valid_backup() {
    local p="$1"
    [ -f "$p" ] || return 1
    local sz
    sz=$(wc -c < "$p" 2>/dev/null)
    [ -z "$sz" ] && return 1
    [ "$sz" -gt 1048576 ] && return 1
    head -n 1 "$p" | grep -q '^# Gatekeeper backup$' || return 1
    grep -q '^# Schema:[[:space:]]*v1$' "$p" || return 1
    grep -q '^# === /etc/config/gatekeeper ===$' "$p" || return 1
    grep -q '^# === /etc/config/dhcp' "$p" || return 1
    grep -q '^package gatekeeper$' "$p" || return 1
    return 0
}

TMP=$(mktemp -t restore_validate.XXXXXX)
trap 'rm -f "$TMP"' EXIT

# Happy path
printf '%s\n' "$FIXTURE" > "$TMP"
is_valid_backup "$TMP"; rc=$?
assert_rc "is_valid_backup: happy path" "$rc" "0"

# Missing first-line header
sed '1d' "$TMP" > "$TMP.bad"
is_valid_backup "$TMP.bad"; rc=$?
assert_rc "is_valid_backup: missing header line" "$rc" "1"
rm -f "$TMP.bad"

# Wrong schema
sed 's/Schema:[[:space:]]*v1/Schema:           v2/' "$TMP" > "$TMP.bad"
is_valid_backup "$TMP.bad"; rc=$?
assert_rc "is_valid_backup: wrong schema" "$rc" "1"
rm -f "$TMP.bad"

# Missing dhcp section marker
sed '/=== \/etc\/config\/dhcp/d' "$TMP" > "$TMP.bad"
is_valid_backup "$TMP.bad"; rc=$?
assert_rc "is_valid_backup: missing dhcp marker" "$rc" "1"
rm -f "$TMP.bad"

# Missing package gatekeeper line
sed '/^package gatekeeper$/d' "$TMP" > "$TMP.bad"
is_valid_backup "$TMP.bad"; rc=$?
assert_rc "is_valid_backup: missing package line" "$rc" "1"
rm -f "$TMP.bad"

# Non-existent file
is_valid_backup "/tmp/definitely-not-here-$$"; rc=$?
assert_rc "is_valid_backup: missing file" "$rc" "1"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
