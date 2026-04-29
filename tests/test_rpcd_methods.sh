#!/bin/sh
# Dev-only integration tests for the rpcd backend's method dispatch.
# Stubs uci/nft/logger so methods can run without a router. The primary goal
# is regression coverage for the delete-before-add invariant on every method
# that updates an nftables-set element's timeout — that bug class has bitten
# us multiple times. Run from repo root:
#   sh tests/test_rpcd_methods.sh

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

assert_lt() {
    label="$1"; a="$2"; b="$3"
    if [ "$a" -lt "$b" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: expected $a < $b"
    fi
}

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RPCD_SRC="$REPO_ROOT/opkg/luci/usr/libexec/rpcd/gatekeeper"
HELPERS_SRC="$REPO_ROOT/opkg/usr/lib/gatekeeper/restore_helpers.sh"

if [ ! -f "$RPCD_SRC" ] || [ ! -f "$HELPERS_SRC" ]; then
    echo "ERROR: rpcd plugin or restore_helpers.sh not found"; exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required"; exit 2
fi

SANDBOX=$(mktemp -d -t gk-rpc-stubs.XXXXXX) || exit 2
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

# --- Build a path-rewritten copy of the rpcd plugin in the sandbox -------
mkdir -p "$SANDBOX/usr/lib/gatekeeper" "$SANDBOX/usr/libexec/rpcd" "$SANDBOX/bin"
cp "$HELPERS_SRC" "$SANDBOX/usr/lib/gatekeeper/restore_helpers.sh"
sed "s#/usr/lib/gatekeeper/restore_helpers.sh#$SANDBOX/usr/lib/gatekeeper/restore_helpers.sh#" \
    "$RPCD_SRC" > "$SANDBOX/usr/libexec/rpcd/gatekeeper"
chmod +x "$SANDBOX/usr/libexec/rpcd/gatekeeper"

# --- Stub uci ------------------------------------------------------------
# Minimal flat-file KV store. Supports the operations the rpcd plugin uses.
UCI_STATE="$SANDBOX/uci_state"; : > "$UCI_STATE"
cat > "$SANDBOX/bin/uci" <<'STUB'
#!/bin/sh
QUIET=
[ "$1" = "-q" ] && { QUIET=1; shift; }
case "$1" in
    get)
        line=$(grep "^$2=" "$UCI_STATE" 2>/dev/null | tail -1)
        [ -z "$line" ] && { [ "$QUIET" = "1" ] && exit 1; echo "Entry not found" >&2; exit 1; }
        printf '%s\n' "${line#*=}"
        ;;
    set)
        key="${2%%=*}"; val="${2#*=}"
        # Replace any existing line for this key.
        grep -v "^$key=" "$UCI_STATE" 2>/dev/null > "$UCI_STATE.tmp" || :
        mv "$UCI_STATE.tmp" "$UCI_STATE"
        printf '%s=%s\n' "$key" "$val" >> "$UCI_STATE"
        ;;
    show)
        if [ -n "${2:-}" ]; then grep "^$2" "$UCI_STATE" 2>/dev/null || :; else cat "$UCI_STATE"; fi
        ;;
    add_list)
        key="${2%%=*}"; val="${2#*=}"
        printf '%s=%s\n' "$key" "$val" >> "$UCI_STATE"
        ;;
    commit|revert|delete|add|reorder|del_list|changes|export|import)
        : ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/uci"

# --- Stub nft ------------------------------------------------------------
# Records every invocation to NFT_LOG; returns canned output for `list set`.
NFT_LOG="$SANDBOX/nft.log"; : > "$NFT_LOG"
cat > "$SANDBOX/bin/nft" <<'STUB'
#!/bin/sh
echo "$@" >> "$NFT_LOG"
case "$*" in
    'list set inet fw4 '*) echo "table inet fw4 { set ${4:-x} { elements = { } } }" ;;
    'list ruleset'*) echo "" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$SANDBOX/bin/nft"

# --- Stub logger / fw4 ---------------------------------------------------
cat > "$SANDBOX/bin/logger" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$SANDBOX/bin/fw4" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$SANDBOX/bin/logger" "$SANDBOX/bin/fw4"

export PATH="$SANDBOX/bin:$PATH"
export UCI_STATE NFT_LOG SANDBOX

RPCD_BIN="$SANDBOX/usr/libexec/rpcd/gatekeeper"

# Helpers
nft_reset() { : > "$NFT_LOG"; }
rpcd_call() {
    method="$1"; body="$2"
    printf '%s' "$body" | "$RPCD_BIN" call "$method"
}

# === list method ========================================================
LIST_OUT=$("$RPCD_BIN" list 2>&1)
LIST_COUNT=$(echo "$LIST_OUT" | jq 'length' 2>/dev/null || echo "?")
assert_eq "list returns 31 methods" "$LIST_COUNT" "31"
# Ensure the dead sched_show method stays dead.
case "$LIST_OUT" in
    *sched_show*) FAIL=$((FAIL+1)); echo "FAIL list: sched_show should not be in the catalog" ;;
    *) PASS=$((PASS+1)) ;;
esac

# === approve: delete-before-add on approved_macs ========================
nft_reset
OUT=$(rpcd_call approve '{"mac":"aa:bb:cc:dd:ee:ff"}')
assert_eq "approve returns ok" "$OUT" '{"ok":true}'
DEL_LINE=$(grep -n "delete element inet fw4 approved_macs" "$NFT_LOG" | head -1 | cut -d: -f1)
ADD_LINE=$(grep -n "add element inet fw4 approved_macs.*timeout 30m" "$NFT_LOG" | head -1 | cut -d: -f1)
assert_eq "approve: 1 delete on approved_macs" "$(grep -c 'delete element inet fw4 approved_macs' "$NFT_LOG")" "1"
assert_eq "approve: 1 add on approved_macs"    "$(grep -c 'add element inet fw4 approved_macs.*timeout' "$NFT_LOG")" "1"
assert_lt "approve: delete precedes add" "${DEL_LINE:-99}" "${ADD_LINE:-0}"

# === deny: delete from BOTH sets before adding to denied_macs ===========
nft_reset
OUT=$(rpcd_call deny '{"mac":"aa:bb:cc:dd:ee:ff"}')
assert_eq "deny returns ok" "$OUT" '{"ok":true}'
assert_eq "deny: delete approved_macs" "$(grep -c 'delete element inet fw4 approved_macs' "$NFT_LOG")" "1"
assert_eq "deny: delete denied_macs"   "$(grep -c 'delete element inet fw4 denied_macs' "$NFT_LOG")" "1"
assert_eq "deny: add denied_macs"      "$(grep -c 'add element inet fw4 denied_macs.*timeout' "$NFT_LOG")" "1"

# === revoke: delete from BOTH sets before adding to denied_macs (regression) =
nft_reset
OUT=$(rpcd_call revoke '{"mac":"aa:bb:cc:dd:ee:ff"}')
assert_eq "revoke returns ok" "$OUT" '{"ok":true}'
assert_eq "revoke: delete approved_macs" "$(grep -c 'delete element inet fw4 approved_macs' "$NFT_LOG")" "1"
assert_eq "revoke: delete denied_macs"   "$(grep -c 'delete element inet fw4 denied_macs' "$NFT_LOG")" "1"
assert_eq "revoke: add denied_macs"      "$(grep -c 'add element inet fw4 denied_macs.*timeout 30m' "$NFT_LOG")" "1"
DEL_DENIED_LINE=$(grep -n "delete element inet fw4 denied_macs" "$NFT_LOG" | head -1 | cut -d: -f1)
ADD_DENIED_LINE=$(grep -n "add element inet fw4 denied_macs" "$NFT_LOG" | head -1 | cut -d: -f1)
assert_lt "revoke: delete denied precedes add denied" "${DEL_DENIED_LINE:-99}" "${ADD_DENIED_LINE:-0}"

# === denied_revoke_approve: delete from BOTH sets before adding to approved_macs (regression) =
nft_reset
OUT=$(rpcd_call denied_revoke_approve '{"mac":"aa:bb:cc:dd:ee:ff"}')
assert_eq "denied_revoke_approve returns ok" "$OUT" '{"ok":true}'
assert_eq "denied_revoke_approve: delete denied_macs"   "$(grep -c 'delete element inet fw4 denied_macs' "$NFT_LOG")" "1"
assert_eq "denied_revoke_approve: delete approved_macs" "$(grep -c 'delete element inet fw4 approved_macs' "$NFT_LOG")" "1"
assert_eq "denied_revoke_approve: add approved_macs"    "$(grep -c 'add element inet fw4 approved_macs.*timeout 30m' "$NFT_LOG")" "1"
DEL_APPROVED_LINE=$(grep -n "delete element inet fw4 approved_macs" "$NFT_LOG" | head -1 | cut -d: -f1)
ADD_APPROVED_LINE=$(grep -n "add element inet fw4 approved_macs" "$NFT_LOG" | head -1 | cut -d: -f1)
assert_lt "denied_revoke_approve: delete approved precedes add approved" "${DEL_APPROVED_LINE:-99}" "${ADD_APPROVED_LINE:-0}"

# === Invalid MAC → error from approve / deny / revoke ===================
OUT=$(rpcd_call approve '{"mac":"not-a-mac"}')
case "$OUT" in
    *'"error"'*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "FAIL approve invalid mac: expected error, got '$OUT'" ;;
esac
OUT=$(rpcd_call revoke '{"mac":""}')
case "$OUT" in
    *'"error"'*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "FAIL revoke empty mac: expected error, got '$OUT'" ;;
esac

# === Unknown method → error =============================================
OUT=$(rpcd_call totally_made_up_method '{}')
case "$OUT" in
    *'"error"'*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "FAIL unknown method: expected error, got '$OUT'" ;;
esac

# === bl_set_mode: writes UCI, runs fw4 reload ===========================
nft_reset
OUT=$(rpcd_call bl_set_mode '{"enabled":true}')
assert_eq "bl_set_mode true returns ok" "$OUT" '{"ok":true}'
MODE=$(grep "^gatekeeper.main.blacklist_mode=" "$UCI_STATE" | tail -1)
case "$MODE" in
    *=1) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "FAIL bl_set_mode: expected blacklist_mode=1, uci state: '$MODE'" ;;
esac

OUT=$(rpcd_call bl_set_mode '{"enabled":false}')
assert_eq "bl_set_mode false returns ok" "$OUT" '{"ok":true}'
MODE=$(grep "^gatekeeper.main.blacklist_mode=" "$UCI_STATE" | tail -1)
case "$MODE" in
    *=0) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "FAIL bl_set_mode: expected blacklist_mode=0, uci state: '$MODE'" ;;
esac

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
