#!/bin/sh
# Dev-only unit tests for the rpcd backend's pure helper functions.
# Sources a path-rewritten copy of the rpcd plugin so we can call the helpers
# directly without launching the full ubus dispatch. Tests cover the helpers
# that don't depend on uci/nft/firewall state — those need integration tests
# with stubs (a separate file). Run from repo root:
#   sh tests/test_rpcd_helpers.sh

set -u
PASS=0
FAIL=0

assert_eq() {
    label="$1"; got="$2"; want="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: got '$got' want '$want'"
    fi
}

assert_contains() {
    label="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) PASS=$((PASS+1)) ;;
        *) FAIL=$((FAIL+1)); echo "FAIL $label: '$haystack' does not contain '$needle'" ;;
    esac
}

# Resolve repo paths and produce a temp copy of the rpcd plugin with the
# /usr/lib/gatekeeper/restore_helpers.sh source path rewritten to the dev
# checkout, so sourcing works on a machine that doesn't have the runtime
# package installed.
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RPCD_SRC="$REPO_ROOT/opkg/luci/usr/libexec/rpcd/gatekeeper"
HELPERS_SRC="$REPO_ROOT/opkg/usr/lib/gatekeeper/restore_helpers.sh"

if [ ! -f "$RPCD_SRC" ]; then
    echo "ERROR: rpcd plugin not found at $RPCD_SRC"
    exit 2
fi
if [ ! -f "$HELPERS_SRC" ]; then
    echo "ERROR: restore_helpers.sh not found at $HELPERS_SRC"
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required (the rpcd plugin's helpers depend on it)"
    exit 2
fi

TMP=$(mktemp -t gk-rpc-test.XXXXXX) || exit 2
trap 'rm -f "$TMP"' EXIT INT TERM

# Strip the dispatcher block (everything from `# ---- list method` to EOF)
# before sourcing — the dispatcher's default `*)` case calls `json_err` then
# `exit 1`, which would kill this test. We only want the helper-function
# definitions, all of which appear before the dispatcher marker.
# Use # as sed delimiter so the path's slashes don't need escaping.
awk '/# ---- list method/{exit} {print}' "$RPCD_SRC" \
    | sed "s#/usr/lib/gatekeeper/restore_helpers.sh#$HELPERS_SRC#" > "$TMP"

# shellcheck disable=SC1090
. "$TMP"

# --- normalize_mac --------------------------------------------------------
assert_eq "normalize_mac uppercase"     "$(normalize_mac 'AA:BB:CC:DD:EE:FF')" "aa:bb:cc:dd:ee:ff"
assert_eq "normalize_mac mixed case"    "$(normalize_mac 'Aa:bB:Cc:dD:Ee:fF')" "aa:bb:cc:dd:ee:ff"
assert_eq "normalize_mac lowercase OK"  "$(normalize_mac 'aa:bb:cc:dd:ee:ff')" "aa:bb:cc:dd:ee:ff"
assert_eq "normalize_mac invalid char"  "$(normalize_mac 'zz:bb:cc:dd:ee:ff')" ""
assert_eq "normalize_mac too short"     "$(normalize_mac 'aa:bb:cc:dd:ee')"    ""
assert_eq "normalize_mac empty"         "$(normalize_mac '')"                  ""
assert_eq "normalize_mac garbage"       "$(normalize_mac 'not-a-mac')"         ""

# --- json_escape ----------------------------------------------------------
# json_escape uses jq -Rs which slurps stdin and outputs a JSON-encoded string.
# Output includes the surrounding double quotes.
assert_eq "json_escape plain"      "$(json_escape 'hello')"     '"hello"'
assert_eq "json_escape with quote" "$(json_escape 'a"b')"       '"a\"b"'
assert_eq "json_escape backslash"  "$(json_escape 'a\b')"       '"a\\b"'
assert_eq "json_escape empty"      "$(json_escape '')"          '""'

# --- json_ok / json_err ---------------------------------------------------
assert_eq "json_ok"                "$(json_ok)"                 '{"ok":true}'
assert_contains "json_err output"  "$(json_err 'bad input')"    '"error":"bad input"'

# --- field (extracts JSON field via jq) -----------------------------------
INPUT_FILE=$(mktemp -t gk-rpc-test-input.XXXXXX) || exit 2
trap 'rm -f "$TMP" "$INPUT_FILE"' EXIT INT TERM
echo '{"mac":"aa:bb:cc:dd:ee:ff","hours":2,"flag":true,"missing":null}' > "$INPUT_FILE"
assert_eq "field string"           "$(field "$INPUT_FILE" .mac)"     "aa:bb:cc:dd:ee:ff"
assert_eq "field number"           "$(field "$INPUT_FILE" .hours)"   "2"
assert_eq "field absent"           "$(field "$INPUT_FILE" .nope)"    ""
assert_eq "field null"             "$(field "$INPUT_FILE" .missing)" ""
assert_eq "field_raw bool"         "$(field_raw "$INPUT_FILE" .flag)" "true"

# --- parse_remaining_secs -------------------------------------------------
# nft timeout strings: "30s", "1m30s", "1h2m3s", "1d23h59m59s"
assert_eq "parse 30s"              "$(parse_remaining_secs '30s')"          "30"
assert_eq "parse 1m30s"            "$(parse_remaining_secs '1m30s')"        "90"
assert_eq "parse 5m"               "$(parse_remaining_secs '5m0s')"         "300"
assert_eq "parse 1h"               "$(parse_remaining_secs '1h0m0s')"       "3600"
assert_eq "parse 1h2m3s"           "$(parse_remaining_secs '1h2m3s')"       "3723"
assert_eq "parse 1d"               "$(parse_remaining_secs '1d0h0m0s')"     "86400"
assert_eq "parse 1d2h"             "$(parse_remaining_secs '1d2h0m0s')"     "93600"
assert_eq "parse 23h59m59s"        "$(parse_remaining_secs '23h59m59s')"    "86399"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
