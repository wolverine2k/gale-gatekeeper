#!/bin/sh
# Dev-only integration tests for Telegram system-control commands.
# Runs tg_bot.sh in a sandbox with stubbed router/Telegram commands so no real
# reboot or network access occurs. Run from repo root:
#   sh tests/test_reboot_command.sh

set -u
PASS=0
FAIL=0

assert_contains() {
    label="$1"; file="$2"; pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: missing pattern '$pattern' in $file"
        [ -f "$file" ] && sed -n '1,120p' "$file"
    fi
}

assert_not_contains() {
    label="$1"; file="$2"; pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: unexpected pattern '$pattern' in $file"
        sed -n '1,120p' "$file"
    fi
}

assert_not_exists() {
    label="$1"; path="$2"
    if [ ! -e "$path" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: $path exists"
        [ -f "$path" ] && cat "$path"
    fi
}

assert_exists() {
    label="$1"; path="$2"
    if [ -e "$path" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL $label: $path missing"
    fi
}

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOT_SRC="$REPO_ROOT/tg_bot.sh"
HELPERS_SRC="$REPO_ROOT/opkg/usr/lib/gatekeeper/restore_helpers.sh"

if [ ! -f "$BOT_SRC" ] || [ ! -f "$HELPERS_SRC" ]; then
    echo "ERROR: tg_bot.sh or restore_helpers.sh not found"; exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq required"; exit 2
fi

run_bot_scenario() {
    updates_json="$1"
    scenario="$2"
    SANDBOX=$(mktemp -d -t gk-reboot.XXXXXX) || exit 2
    mkdir -p "$SANDBOX/usr/lib/gatekeeper" "$SANDBOX/bin"
    cp "$HELPERS_SRC" "$SANDBOX/usr/lib/gatekeeper/restore_helpers.sh"
    sed "s#/usr/lib/gatekeeper/restore_helpers.sh#$SANDBOX/usr/lib/gatekeeper/restore_helpers.sh#" \
        "$BOT_SRC" > "$SANDBOX/tg_bot.sh"
    chmod +x "$SANDBOX/tg_bot.sh"

    printf '%s\n' "$updates_json" > "$SANDBOX/updates.json"
    : > "$SANDBOX/send.log"
    : > "$SANDBOX/reboot.log"
    : > "$SANDBOX/service.log"

    cat > "$SANDBOX/bin/uci" <<'STUB'
#!/bin/sh
[ "$1" = "-q" ] && shift
case "$1 $2" in
    "get gatekeeper.main.token") echo test-token ;;
    "get gatekeeper.main.chat_id") echo 123 ;;
    *) : ;;
esac
exit 0
STUB
    cat > "$SANDBOX/bin/curl" <<'STUB'
#!/bin/sh
case "$*" in
    *getUpdates*)
        count=0
        [ -f "$SANDBOX/curl_get_count" ] && count=$(cat "$SANDBOX/curl_get_count")
        count=$((count + 1))
        echo "$count" > "$SANDBOX/curl_get_count"
        if [ "$count" -eq 1 ]; then
            cat "$SANDBOX/updates.json"
        else
            /bin/sleep 1 2>/dev/null || :
            kill -TERM "$PPID" 2>/dev/null
            echo '{"ok":true,"result":[]}'
        fi
        ;;
    *sendMessage*)
        printf '%s\n' "$*" >> "$SANDBOX/send.log"
        echo '{"ok":true,"result":{"message_id":1001}}'
        ;;
    *)
        echo '{"ok":true}'
        ;;
esac
STUB
    cat > "$SANDBOX/bin/date" <<'STUB'
#!/bin/sh
case "$1" in
    +%s) echo 1000 ;;
    *) echo "2026-05-14T12:00:00" ;;
esac
STUB
    cat > "$SANDBOX/bin/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
    for cmd in nft fw4 logger; do
        cat > "$SANDBOX/bin/$cmd" <<'STUB'
#!/bin/sh
exit 0
STUB
    done
    cat > "$SANDBOX/bin/fake-reboot" <<'STUB'
#!/bin/sh
echo reboot-called >> "$SANDBOX/reboot.log"
STUB
    for svc in gatekeeper_init tg_gatekeeper gatekeeper_trigger_listener; do
        cat > "$SANDBOX/bin/$svc" <<'STUB'
#!/bin/sh
echo "$(basename "$0") $*" >> "$SANDBOX/service.log"
STUB
    done
    chmod +x "$SANDBOX/bin/"*

    if [ "$scenario" = "expired" ]; then
        echo "1001 1" > "$SANDBOX/reboot_pending"
    fi

    PATH="$SANDBOX/bin:$PATH" \
    SANDBOX="$SANDBOX" \
    GATEKEEPER_REBOOT_PENDING="$SANDBOX/reboot_pending" \
    GATEKEEPER_REBOOT_CMD="$SANDBOX/bin/fake-reboot" \
    GATEKEEPER_INIT_SERVICE="$SANDBOX/bin/gatekeeper_init" \
    TG_GATEKEEPER_SERVICE="$SANDBOX/bin/tg_gatekeeper" \
    GATEKEEPER_TRIGGER_SERVICE="$SANDBOX/bin/gatekeeper_trigger_listener" \
    GATEKEEPER_TOKEN="test-token" \
    GATEKEEPER_CHAT_ID="123" \
        "$SANDBOX/tg_bot.sh" >/dev/null 2>&1 || :

    printf '%s\n' "$SANDBOX"
}

PROMPT_UPDATES='{"ok":true,"result":[{"update_id":1,"message":{"message_id":50,"chat":{"id":"123"},"text":"REBOOT"}}]}'
PROMPT_BOX=$(run_bot_scenario "$PROMPT_UPDATES" prompt)
assert_contains "REBOOT prompt asks for REBOOT YES" "$PROMPT_BOX/send.log" "REBOOT YES"
assert_contains "REBOOT prompt explains expiry" "$PROMPT_BOX/send.log" "2 minutes"
assert_exists "REBOOT prompt records pending confirmation" "$PROMPT_BOX/reboot_pending"
assert_contains "REBOOT pending stores prompt message id" "$PROMPT_BOX/reboot_pending" "^1001 "
assert_not_contains "REBOOT prompt does not call reboot" "$PROMPT_BOX/reboot.log" "reboot-called"

CONFIRM_UPDATES='{"ok":true,"result":[{"update_id":1,"message":{"message_id":50,"chat":{"id":"123"},"text":"REBOOT"}},{"update_id":2,"message":{"message_id":51,"chat":{"id":"123"},"text":"REBOOT YES","reply_to_message":{"message_id":1001}}}]}'
CONFIRM_BOX=$(run_bot_scenario "$CONFIRM_UPDATES" confirm)
assert_contains "REBOOT confirmation sends final message" "$CONFIRM_BOX/send.log" "Rebooting router now"
assert_contains "REBOOT confirmation calls configured reboot command" "$CONFIRM_BOX/reboot.log" "reboot-called"
assert_not_exists "REBOOT confirmation clears pending state" "$CONFIRM_BOX/reboot_pending"

EXPIRED_UPDATES='{"ok":true,"result":[{"update_id":1,"message":{"message_id":60,"chat":{"id":"123"},"text":"REBOOT YES","reply_to_message":{"message_id":1001}}}]}'
EXPIRED_BOX=$(run_bot_scenario "$EXPIRED_UPDATES" expired)
assert_contains "Expired REBOOT confirmation is rejected" "$EXPIRED_BOX/send.log" "Pending reboot expired"
assert_not_contains "Expired REBOOT confirmation does not call reboot" "$EXPIRED_BOX/reboot.log" "reboot-called"
assert_not_exists "Expired REBOOT confirmation clears pending state" "$EXPIRED_BOX/reboot_pending"

RESTART_UPDATES='{"ok":true,"result":[{"update_id":1,"message":{"message_id":70,"chat":{"id":"123"},"text":"RESTART"}}]}'
RESTART_BOX=$(run_bot_scenario "$RESTART_UPDATES" restart)
assert_contains "RESTART sends service restart acknowledgement" "$RESTART_BOX/send.log" "Restarting Gatekeeper services"
assert_contains "RESTART calls gatekeeper_init restart" "$RESTART_BOX/service.log" "gatekeeper_init restart"
assert_contains "RESTART calls trigger listener restart" "$RESTART_BOX/service.log" "gatekeeper_trigger_listener restart"
assert_contains "RESTART calls tg_gatekeeper restart" "$RESTART_BOX/service.log" "tg_gatekeeper restart"
assert_not_contains "RESTART does not call router reboot" "$RESTART_BOX/reboot.log" "reboot-called"

rm -rf "$PROMPT_BOX" "$CONFIRM_BOX" "$EXPIRED_BOX" "$RESTART_BOX"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
