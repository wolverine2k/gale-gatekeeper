#!/bin/sh
# Dev-only unit tests for the Anti-Randomization (block_randomized_macs)
# helper. The `is_randomized_mac` function is duplicated verbatim into
# gatekeeper.sh and this test file. When you change one, change both.
#
# Per IEEE 802.11, a MAC is locally administered (randomized) when its
# SECOND hex digit is 2, 6, A, or E. These tests pin that heuristic.
#
# Run from repo root:
#   sh tests/test_randomized_mac.sh

set -u
PASS=0
FAIL=0

assert_true() {
    label="$1"; mac="$2"
    if is_randomized_mac "$mac"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: expected randomized, got non-randomized for '$mac'"
    fi
}

assert_false() {
    label="$1"; mac="$2"
    if is_randomized_mac "$mac"; then
        FAIL=$((FAIL+1))
        echo "FAIL $label: expected non-randomized, got randomized for '$mac'"
    else
        PASS=$((PASS+1))
    fi
}

# --- is_randomized_mac -----------------------------------------------------
# Returns 0 (true) if $1 is a locally-administered (randomized) MAC address.
# Per IEEE 802.11, the "locally administered" bit is the second-least-
# significant bit of the first octet. In practice this means the SECOND hex
# digit of the MAC is 2, 6, A, or E (e.g. x2:xx:xx:xx:xx:xx). Devices that
# randomize their MAC (iOS Private Wi-Fi Address, Android MAC randomization)
# always set this bit, so this is a reliable heuristic for blocking
# privacy-randomized clients. Input is assumed already lowercased.
is_randomized_mac() {
    case "$1" in
        ?2:*|?6:*|?a:*|?e:*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Randomized second-digit cases (2/6/a/e) ------------------------------
assert_true "second digit 2"  "12:34:56:78:9a:bc"
assert_true "second digit 6"  "06:aa:bb:cc:dd:ee"
assert_true "second digit a"  "9a:11:22:33:44:55"
assert_true "second digit e"  "fe:00:00:00:00:01"
assert_true "first octet 02"  "02:00:00:00:00:00"
assert_true "first octet 06"  "06:00:00:00:00:00"
assert_true "first octet 0a"  "0a:00:00:00:00:00"
assert_true "first octet 0e"  "0e:00:00:00:00:00"
assert_true "first octet 12"  "12:00:00:00:00:00"
assert_true "first octant 1e" "1e:00:00:00:00:00"
assert_true "uppercase-ish a (lowercased)" "ba:00:00:00:00:00"
assert_true "uppercase-ish e (lowercased)" "ce:00:00:00:00:00"

# --- Non-randomized second-digit cases (0/4/8/c and others) ---------------
assert_false "second digit 0"  "00:11:22:33:44:55"
assert_false "second digit 4"  "04:11:22:33:44:55"
assert_false "second digit 8"  "08:11:22:33:44:55"
assert_false "second digit c"  "0c:11:22:33:44:55"
assert_false "second digit 1"  "01:11:22:33:44:55"
assert_false "second digit 3"  "13:11:22:33:44:55"
assert_false "second digit 5"  "f5:11:22:33:44:55"
assert_false "second digit 7"  "a7:11:22:33:44:55"
assert_false "second digit 9"  "99:11:22:33:44:55"
assert_false "second digit b"  "bb:11:22:33:44:55"
assert_false "second digit d"  "dd:11:22:33:44:55"
assert_false "second digit f"  "ff:11:22:33:44:55"
assert_false "all zeros"       "00:00:00:00:00:00"

# --- Edge cases -----------------------------------------------------------
assert_false "empty string"  ""
assert_false "no colons"     "023456789abc"
# The heuristic is purely positional on the second hex digit, so a short
# but well-formed prefix still classifies by that digit.
assert_true  "too short 2"    "02:00"
assert_false "too short 0"    "00:00"
# A non-randomized-looking but malformed value should NOT match.
assert_false "garbage"       "zz:xx:yy"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
