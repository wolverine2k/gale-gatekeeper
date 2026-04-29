#!/bin/sh
# Dev-only unit tests for schedule helper functions.
# These functions are duplicated verbatim into tg_bot.sh and gatekeeper.sh.
# When you change one, change all three. Run from repo root:
#   sh tests/test_schedule_helpers.sh

set -u
PASS=0
FAIL=0

# `date -d "today 17:00"` syntax is a GNU coreutils extension; the macOS BSD
# `date` rejects it. On macOS, prefer `gdate` if installed (`brew install
# coreutils` ships it). Linux routers / CI runners use plain `date` and have
# the GNU implementation natively. Override with DATE_CMD=/path if needed.
if [ -z "${DATE_CMD:-}" ]; then
    if command -v gdate >/dev/null 2>&1; then
        DATE_CMD=gdate
    else
        DATE_CMD=date
    fi
fi
export DATE_CMD

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

# --- hm_to_min (HH:MM -> minutes since midnight) --------------------------
# Avoids BusyBox `[ ]` lacking string `<`/`>`, and avoids octal-arithmetic
# errors on values like "08", "09".
hm_to_min() {
    echo "$1" | awk -F: '{print $1 * 60 + $2}'
}

assert_eq "hm_to_min 00:00" "$(hm_to_min 00:00)" "0"
assert_eq "hm_to_min 08:30" "$(hm_to_min 08:30)" "510"
assert_eq "hm_to_min 09:00" "$(hm_to_min 09:00)" "540"
assert_eq "hm_to_min 23:59" "$(hm_to_min 23:59)" "1439"

# --- window_active_now ----------------------------------------------------
# Args: days start stop today_dow now_hm
# Echos the window-end epoch (date -d) if active; empty if not.
# Same-day:        start_m < stop_m  AND  today in days  AND  start_m <= now_m < stop_m
# Cross-midnight:  start_m >= stop_m
#   if today in days AND now_m >= start_m  -> end = tomorrow $stop
#   elif yesterday in days AND now_m < stop_m -> end = today $stop
window_active_now() {
    days="$1"; start="$2"; stop="$3"; today_dow="$4"; now_hm="$5"
    expanded=$(expand_days "$days")
    start_m=$(hm_to_min "$start")
    stop_m=$(hm_to_min "$stop")
    now_m=$(hm_to_min "$now_hm")

    if [ "$start_m" -lt "$stop_m" ]; then
        # Same-day window
        echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" || return 0
        [ "$now_m" -ge "$start_m" ] || return 0
        [ "$now_m" -lt "$stop_m" ] || return 0
        ${DATE_CMD:-date} -d "today $stop" +%s
    else
        # Cross-midnight: today $start -> tomorrow $stop
        # Derive yesterday from today_dow (no system clock dependency)
        yesterday_dow=$(echo "$today_dow" | awk '
            BEGIN { split("sun mon tue wed thu fri sat", d) }
            { for (i=1;i<=7;i++) if (d[i]==$1) { print d[(i+5)%7+1]; exit } }
        ')
        if echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" \
           && [ "$now_m" -ge "$start_m" ]; then
            ${DATE_CMD:-date} -d "tomorrow $stop" +%s
        elif echo "$expanded" | tr ' ' '\n' | grep -qx "$yesterday_dow" \
             && [ "$now_m" -lt "$stop_m" ]; then
            ${DATE_CMD:-date} -d "today $stop" +%s
        fi
    fi
}

# Test-only helper: turn an end-epoch (or empty) into ACTIVE / inactive for asserts.
# Not part of the three-copy contract — stays in this file only.
is_active() {
    if [ -n "$1" ]; then echo "ACTIVE"; else echo "inactive"; fi
}

# Same-day window 16:00-20:00 weekdays
assert_eq "weekday 15:59 mon" "$(is_active "$(window_active_now weekdays 16:00 20:00 mon 15:59)")" "inactive"
assert_eq "weekday 16:00 mon" "$(is_active "$(window_active_now weekdays 16:00 20:00 mon 16:00)")" "ACTIVE"
assert_eq "weekday 19:59 fri" "$(is_active "$(window_active_now weekdays 16:00 20:00 fri 19:59)")" "ACTIVE"
assert_eq "weekday 20:00 fri" "$(is_active "$(window_active_now weekdays 16:00 20:00 fri 20:00)")" "inactive"
assert_eq "weekday 17:00 sat" "$(is_active "$(window_active_now weekdays 16:00 20:00 sat 17:00)")" "inactive"

# Daily window 09:00-21:00
assert_eq "daily 09:00 sun"   "$(is_active "$(window_active_now daily 09:00 21:00 sun 09:00)")" "ACTIVE"
assert_eq "daily 08:59 sun"   "$(is_active "$(window_active_now daily 09:00 21:00 sun 08:59)")" "inactive"

# Cross-midnight window 22:00-06:00 daily
assert_eq "xnight 22:00 mon"  "$(is_active "$(window_active_now daily 22:00 06:00 mon 22:00)")" "ACTIVE"
assert_eq "xnight 23:59 mon"  "$(is_active "$(window_active_now daily 22:00 06:00 mon 23:59)")" "ACTIVE"
assert_eq "xnight 05:59 tue"  "$(is_active "$(window_active_now daily 22:00 06:00 tue 05:59)")" "ACTIVE"
assert_eq "xnight 06:00 tue"  "$(is_active "$(window_active_now daily 22:00 06:00 tue 06:00)")" "inactive"
assert_eq "xnight 21:59 mon"  "$(is_active "$(window_active_now daily 22:00 06:00 mon 21:59)")" "inactive"

# Cross-midnight, single day (mon 22:00-06:00) — Mon active 22:00, Tue active <06:00 only if Mon was a day
assert_eq "xnight mon-only mon 22:00" "$(is_active "$(window_active_now mon 22:00 06:00 mon 22:00)")" "ACTIVE"
assert_eq "xnight mon-only tue 05:00" "$(is_active "$(window_active_now mon 22:00 06:00 tue 05:00)")" "ACTIVE"
assert_eq "xnight mon-only tue 22:00" "$(is_active "$(window_active_now mon 22:00 06:00 tue 22:00)")" "inactive"
assert_eq "xnight mon-only wed 05:00" "$(is_active "$(window_active_now mon 22:00 06:00 wed 05:00)")" "inactive"

# Comma-list days
assert_eq "mwf 17:00 wed" "$(is_active "$(window_active_now mon,wed,fri 16:00 18:00 wed 17:00)")" "ACTIVE"
assert_eq "mwf 17:00 thu" "$(is_active "$(window_active_now mon,wed,fri 16:00 18:00 thu 17:00)")" "inactive"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
