#!/bin/sh
# Dev-only unit tests for the OUI vendor enrichment helper (lookup_mac_vendor).
# The function is duplicated verbatim into gatekeeper.sh and this test file.
# When you change one, change both.
#
# The maclookup.app public API is stubbed via a fake `curl` on PATH so the
# tests run offline. Run from repo root:
#   sh tests/test_maclookup.sh

set -u
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required"; exit 2
fi

SANDBOX=$(mktemp -d -t gk-maclookup.XXXXXX) || exit 2
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/bin"

# Fake curl: emit canned maclookup.app JSON based on the MAC in the URL.
#   00:1c:b3... → real, vendor "Apple, Inc.", US
#   08:00:27... → real, vendor "Oracle Corporation", DE
#   02:11:22... → randomized (isRand:true, found:false)
#   aa:bb:cc... → API error (success:false) — must NOT cache, must retry
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in
    *"/macs/00:1c:b3"*)
        echo '{"success":true,"found":true,"macPrefix":"001CB3","company":"Apple, Inc.","address":"1 Infinite Loop, Cupertino CA 95014, US","country":"US","isRand":false,"isPrivate":false}'
        ;;
    *"/macs/08:00:27"*)
        echo '{"success":true,"found":true,"macPrefix":"080027","company":"Oracle Corporation","address":"","country":"DE","isRand":false,"isPrivate":false}'
        ;;
    *"/macs/02:11:22"*)
        echo '{"success":true,"found":false,"macPrefix":"","company":"","address":"","country":"","isRand":true,"isPrivate":false}'
        ;;
    *"/macs/aa:bb:cc"*)
        echo '{"success":false,"found":false}'
        ;;
    *)
        echo '{"success":true,"found":false,"isRand":true}'
        ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/curl"

export PATH="$SANDBOX/bin:$PATH"
export OUI_CACHE_DIR="$SANDBOX/oui_cache"

assert_eq() {
    label="$1"; got="$2"; want="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: got '$got' want '$want'"
    fi
}

# --- lookup_mac_vendor (copy of gatekeeper.sh) ---------------------------
lookup_mac_vendor() {
    mac=$(echo "$1" | tr 'A-Z' 'a-z')
    [ -n "$mac" ] || return 0
    oui=$(echo "$mac" | tr -d ':' | cut -c1-6)
    [ -n "$oui" ] || return 0

    mkdir -p "$OUI_CACHE_DIR" 2>/dev/null
    cache="$OUI_CACHE_DIR/$oui"

    is_rand=""; found=""; company=""; country=""
    if [ -f "$cache" ]; then
        is_rand=$(sed -n '1p' "$cache")
        found=$(sed -n '2p' "$cache")
        company=$(sed -n '3p' "$cache")
        country=$(sed -n '4p' "$cache")
    else
        # -m 4 bounds latency so a slow/unreachable API never blocks the
        # notification. Only cache definitive (success) answers so a
        # transient API error is retried on the next connection.
        resp=$(curl -s -m 4 --connect-timeout 3 \
            "https://api.maclookup.app/v2/macs/$mac" 2>/dev/null)
        success=$(printf '%s' "$resp" | jq -r '.success // false' 2>/dev/null)
        if [ "$success" = "true" ]; then
            is_rand=$(printf '%s' "$resp" | jq -r '(.isRand // false) | tostring' 2>/dev/null)
            found=$(printf '%s' "$resp" | jq -r '(.found // false) | tostring' 2>/dev/null)
            company=$(printf '%s' "$resp" | jq -r '.company // ""' 2>/dev/null)
            country=$(printf '%s' "$resp" | jq -r '.country // ""' 2>/dev/null)
            printf '%s\n%s\n%s\n%s\n' "$is_rand" "$found" "$company" "$country" \
                > "$cache" 2>/dev/null
        fi
    fi

    # Only surface vendor info for real (non-randomized), vendor-found MACs.
    if [ "$is_rand" = "false" ] && [ "$found" = "true" ] && [ -n "$company" ]; then
        printf '%s\n%s\n' "$company" "$country"
    fi
    return 0
}

# --- Real MAC → emits company + country -----------------------------------
OUT=$(lookup_mac_vendor "00:1C:B3:11:22:33")
COMPANY=$(echo "$OUT" | sed -n '1p')
COUNTRY=$(echo "$OUT" | sed -n '2p')
assert_eq "real mac company" "$COMPANY" "Apple, Inc."
assert_eq "real mac country" "$COUNTRY" "US"

# A second real MAC (different host, same OUI) must hit the cache (no curl).
OUT=$(lookup_mac_vendor "00:1c:b3:99:88:77")
assert_eq "cached real mac company" "$(echo "$OUT" | sed -n '1p')" "Apple, Inc."

# Different real OUI.
OUT=$(lookup_mac_vendor "08:00:27:aa:bb:cc")
assert_eq "oracle company" "$(echo "$OUT" | sed -n '1p')" "Oracle Corporation"
assert_eq "oracle country" "$(echo "$OUT" | sed -n '2p')" "DE"

# --- Randomized MAC → emits nothing --------------------------------------
OUT=$(lookup_mac_vendor "02:11:22:33:44:55")
assert_eq "randomized mac emits nothing" "$OUT" ""

# --- API error (success:false) → emits nothing, does NOT cache ------------
OUT=$(lookup_mac_vendor "aa:bb:cc:dd:ee:ff")
assert_eq "api error emits nothing" "$OUT" ""
# Cache file must NOT exist so the next call retries.
if [ -f "$OUI_CACHE_DIR/aabbcc" ]; then
    FAIL=$((FAIL+1)); echo "FAIL api error: should not cache a failed response"
else
    PASS=$((PASS+1))
fi

# --- Cache file content sanity ------------------------------------------
# Real OUI cache should hold 4 newline-delimited lines: isRand, found, co, cc.
if [ -f "$OUI_CACHE_DIR/001cb3" ]; then
    LINES=$(wc -l < "$OUI_CACHE_DIR/001cb3" | tr -d ' 	')
    assert_eq "cache file line count" "$LINES" "4"
    assert_eq "cache isRand line" "$(sed -n '1p' "$OUI_CACHE_DIR/001cb3")" "false"
    assert_eq "cache found line" "$(sed -n '2p' "$OUI_CACHE_DIR/001cb3")" "true"
else
    FAIL=$((FAIL+1)); echo "FAIL: real OUI cache file missing"
fi

# --- Empty / malformed input → emits nothing, exit 0 ---------------------
assert_eq "empty mac" "$(lookup_mac_vendor "")" ""
assert_eq "garbage mac" "$(lookup_mac_vendor "not-a-mac")" ""

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
