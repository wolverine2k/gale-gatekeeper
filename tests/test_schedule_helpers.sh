#!/bin/sh
# Dev-only unit tests for schedule helper functions.
# These functions are duplicated verbatim into tg_bot.sh and gatekeeper.sh.
# When you change one, change all three. Run from repo root:
#   sh tests/test_schedule_helpers.sh

set -u
PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: got '$got' want '$want'"
    fi
}

# --- expand_days ----------------------------------------------------------
# Expands a UCI `days` value into a space-separated list of three-letter,
# lowercase day abbreviations.
expand_days() {
    case "$1" in
        daily)    echo "mon tue wed thu fri sat sun" ;;
        weekdays) echo "mon tue wed thu fri" ;;
        weekends) echo "sat sun" ;;
        *)        echo "$1" | tr ',' ' ' ;;
    esac
}

assert_eq "expand_days daily"     "$(expand_days daily)"     "mon tue wed thu fri sat sun"
assert_eq "expand_days weekdays"  "$(expand_days weekdays)"  "mon tue wed thu fri"
assert_eq "expand_days weekends"  "$(expand_days weekends)"  "sat sun"
assert_eq "expand_days mon"       "$(expand_days mon)"       "mon"
assert_eq "expand_days mon,wed"   "$(expand_days mon,wed)"   "mon wed"
assert_eq "expand_days mon,wed,fri" "$(expand_days mon,wed,fri)" "mon wed fri"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
