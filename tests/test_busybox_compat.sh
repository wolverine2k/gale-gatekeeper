#!/bin/sh
# Static-analysis test: catches BusyBox-incompatible patterns in scripts that
# run on the OpenWrt router. The router ships BusyBox ash + BusyBox `date`,
# both of which silently reject many GNU/coreutils features. When a GNU-only
# call ends up inside `$(...)`, the caller gets an empty string with no exit-
# code signal — which is how the schedule auto-approve bug shipped silently.
#
# Run from the repository root:
#   sh tests/test_busybox_compat.sh
#
# To add a new check: define a `check_*` function below following the pattern.

set -u

# Files to scan can be overridden by the test harness — empty default means
# "use ROUTER_SCRIPTS". The regression self-test at the bottom uses this.
TARGETS_OVERRIDE="${TARGETS_OVERRIDE:-}"

# Files that run on the router and MUST be BusyBox-safe. Add new ones here
# whenever a runtime script joins the project. `deploy.sh` is intentionally
# excluded — it runs on the dev machine with `#!/bin/bash`.
ROUTER_SCRIPTS="
gatekeeper.sh
tg_bot.sh
gatekeeper_trigger.sh
dnsmasq_trigger.sh
gatekeeper_sync.sh
gatekeeper.nft
gatekeeper_init
tg_gatekeeper
gatekeeper_trigger_listener
opkg/usr/lib/gatekeeper/restore_helpers.sh
opkg/luci/usr/libexec/rpcd/gatekeeper
"

FAIL_COUNT=0

# scan_pattern <id> <egrep_pattern> <why>
#   For each target, print "FAIL" rows for every match outside a comment.
#   Increments FAIL_COUNT in the parent shell — uses a temp file because
#   while-read pipelines run in a subshell on BusyBox ash and lose state.
scan_pattern() {
    id="$1" pat="$2" why="$3"
    targets="${TARGETS_OVERRIDE:-$ROUTER_SCRIPTS}"
    for path in $targets; do
        [ -f "$path" ] || continue
        # `grep -nE` returns "<line>:<content>". Comment-only lines are
        # filtered out below so a doc-comment about a forbidden pattern
        # doesn't itself fail the test.
        grep -nE "$pat" "$path" 2>/dev/null | while IFS=: read -r lineno content; do
            stripped=$(printf '%s' "$content" | sed 's/^[[:space:]]*//')
            case "$stripped" in
                '#'*) continue ;;
            esac
            printf 'FAIL [%s] %s:%s\n  match: %s\n  why:   %s\n\n' \
                "$id" "$path" "$lineno" "$stripped" "$why"
        done
    done
}

# ---- Individual checks ---------------------------------------------------
# Each check is a function so its egrep pattern can use `|` freely.

check_gnu_date_relative() {
    # GNU `date -d "today 23:59"` style is silently rejected by BusyBox.
    # BusyBox accepts only: hh:mm[:ss], YYYY-MM-DD hh:mm[:ss],
    # [[YY]YY]MMDDhhmm[.ss], or @epoch.
    scan_pattern "GNU_DATE_RELATIVE" \
        'date[[:space:]]+-d[[:space:]]+"(today|tomorrow|yesterday|next[[:space:]]|last[[:space:]]|[0-9]+[[:space:]]+(day|days|hour|hours|minute|minutes|week|weeks|month|months|year|years)[[:space:]]+ago)' \
        'GNU-only `date -d "today/tomorrow/...HH:MM"` — BusyBox `date -d` accepts only hh:mm, YYYY-MM-DD hh:mm:ss, [[YY]YY]MMDDhhmm[.ss], or @epoch. Use date -d "$(date +%Y-%m-%d) HH:MM:00" +%s instead.'
}

check_bash_double_bracket() {
    scan_pattern "BASH_DOUBLE_BRACKET" \
        '\[\[[[:space:]]' \
        'bashism `[[ ... ]]` — BusyBox ash supports only POSIX `[ ... ]`.'
}

check_bash_lowercase_param() {
    scan_pattern "BASH_LOWERCASE_PARAM" \
        '\$\{[A-Za-z_][A-Za-z_0-9]*,,\}' \
        'bashism `${var,,}` — BusyBox ash has no case-conversion expansion. Use `tr A-Z a-z`.'
}

check_bash_uppercase_param() {
    scan_pattern "BASH_UPPERCASE_PARAM" \
        '\$\{[A-Za-z_][A-Za-z_0-9]*\^\^\}' \
        'bashism `${var^^}` — BusyBox ash has no case-conversion expansion. Use `tr a-z A-Z`.'
}

check_bash_process_subst() {
    # `<(...)` and `>(...)`. We anchor on the parenthesis so plain `<file`
    # redirection isn't matched.
    scan_pattern "BASH_PROCESS_SUBST" \
        '[<>]\(' \
        'process substitution `<(...)` / `>(...)` — bash-only, BusyBox ash does not parse it.'
}

check_bash_function_kw() {
    scan_pattern "BASH_FUNCTION_KW" \
        '^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z_0-9]*' \
        '`function name() { ... }` keyword — POSIX requires plain `name() { ... }`.'
}

check_bash_arrays() {
    scan_pattern "BASH_ARRAYS" \
        '\$\{[A-Za-z_][A-Za-z_0-9]*\[(@|\*|[0-9]+)\]\}' \
        'bash arrays `${arr[@]}` — BusyBox ash has no arrays.'
}

check_grep_pcre() {
    scan_pattern "GREP_PCRE" \
        'grep[[:space:]]+(-[a-zA-Z]*)?P([[:space:]]|$)' \
        '`grep -P` (PCRE) — BusyBox grep is built without PCRE in OpenWrt by default. Use `grep -E`.'
}

check_bash_shebang() {
    # Router scripts must NOT start with #!/bin/bash. `deploy.sh` is the only
    # bash-allowed file and is excluded from ROUTER_SCRIPTS.
    targets="${TARGETS_OVERRIDE:-$ROUTER_SCRIPTS}"
    for path in $targets; do
        [ -f "$path" ] || continue
        first=$(head -1 "$path" 2>/dev/null)
        case "$first" in
            '#!/bin/bash'*|'#!/usr/bin/env bash'*)
                printf 'FAIL [BASH_SHEBANG] %s:1\n  match: %s\n  why:   %s\n\n' \
                    "$path" "$first" \
                    "router-side script must use #!/bin/sh, not bash"
                ;;
        esac
    done
}

# ---- Run all checks, count fails -----------------------------------------

OUT=$(
    check_gnu_date_relative
    check_bash_double_bracket
    check_bash_lowercase_param
    check_bash_uppercase_param
    check_bash_process_subst
    check_bash_function_kw
    check_bash_arrays
    check_grep_pcre
    check_bash_shebang
)

if [ -n "$OUT" ]; then
    printf '%s\n' "$OUT"
    FAIL_COUNT=$(printf '%s\n' "$OUT" | grep -c '^FAIL ')
fi

# Sanity: confirm at least one target script was actually scanned. If the
# ROUTER_SCRIPTS list rots (file renamed, never updated), every check would
# silently pass — exactly the failure mode this suite is meant to prevent.
SCANNED=0
targets="${TARGETS_OVERRIDE:-$ROUTER_SCRIPTS}"
for path in $targets; do
    [ -f "$path" ] && SCANNED=$((SCANNED + 1))
done
echo "scanned $SCANNED file(s)"

if [ "$SCANNED" = "0" ]; then
    echo "FAIL: no target files found — ROUTER_SCRIPTS may be stale"
    exit 1
fi

if [ "$FAIL_COUNT" = "0" ]; then
    echo "PASS: no BusyBox-incompatible patterns found"
    exit 0
else
    echo "FAIL: $FAIL_COUNT BusyBox-incompatible match(es) above"
    echo "Fix each match. If a match is a genuine false positive, narrow the"
    echo "regex in the matching check_* function in this file."
    exit 1
fi
