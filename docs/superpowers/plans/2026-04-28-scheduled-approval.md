# Scheduled Auto-Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-MAC time-window auto-approval to Gatekeeper. A user can register one or more schedules per MAC; during an active window the MAC is silently auto-approved, bypassing the Telegram approval prompt. Stop times revoke the temporary approval.

**Architecture:** State-driven convergence. UCI is the source of truth for schedule definitions. A new `scheduler_tick()` runs on every iteration of `tg_bot.sh`'s main polling loop (~30 s tick rate), reconciling `approved_macs` toward desired state. `gatekeeper.sh` gains a reactive step 3.6 that catches mid-window DHCP events. No new daemons, no new dependencies. Per-window helper logic is duplicated between `tg_bot.sh` and `gatekeeper.sh` (~30 LOC) — accepted trade-off to preserve the project's "no new runtime files" constraint.

**Tech Stack:** POSIX `/bin/sh` (BusyBox ash), nftables (`nft`), OpenWrt UCI (`uci`), `curl`, `jq`. Dev-only test harness uses bash/sh on macOS or Linux.

**Spec reference:** `docs/superpowers/specs/2026-04-28-scheduled-approval-design.md`

**Compatibility constraints:**
- All router code must run under BusyBox `ash`. No `[[ ]]`, `${var,,}`, arrays, `function` keyword, process substitution, or other bashisms.
- HH:MM string comparison must be done as integer minutes, not lexicographic — BusyBox `[ ]` does not support `<` / `>` for strings.
- Numbers with leading zeros (e.g. `"08"`, `"09"`) must be handled to avoid octal-arithmetic errors. Use `awk -F: '{print $1*60+$2}'` for HH:MM → minute conversion.

---

### Task 1: Add UCI schema documentation to the config template

Document the new `schedule` section type and the `schedule_notify` flag in the UCI config template so installs of the package include the schema documentation. No runtime code yet.

**Files:**
- Modify: `opkg/etc/config/gatekeeper`

- [ ] **Step 1: Add `schedule_notify` option doc to the `main` section**

In `opkg/etc/config/gatekeeper`, inside `config gatekeeper 'main'`, add this option after the existing `option disabled '0'` block:

```
	# Schedule notify (optional, default: 0)
	# Controls the optional info message sent when a scheduled auto-approval
	# fires during a DHCP event for the configured MAC.
	# 0 = silent, 1 = post info message to chat
	# Toggle via Telegram: SCHEDNOTIFY ON / OFF / STATUS
	option schedule_notify '0'
```

- [ ] **Step 2: Add documentation block for the `schedule` section type**

Append the following to the end of `opkg/etc/config/gatekeeper`:

```
# Scheduled auto-approval entries
#
# Each `config schedule '<name>'` section defines one auto-approval window
# for one MAC. Multiple sections per MAC are allowed (e.g. weekday vs.
# weekend windows). Manage schedules via the Telegram bot:
#
#   SCHEDADD  aa:bb:cc:dd:ee:ff weekdays 16:00-20:00 kids_eve
#   SCHEDLIST
#   SCHEDREMOVE kids_eve
#   SCHEDOFF kids_eve   /  SCHEDON kids_eve
#
# Section name validation: ^[a-z0-9_]{1,32}$
# `days`  : daily | weekdays | weekends | comma-separated subset of
#           mon,tue,wed,thu,fri,sat,sun
# `start` / `stop` : HH:MM 24h, router local timezone.
#                    If stop <= start the window crosses midnight, anchored
#                    to the start day.
# `enabled` : 1 (default) active, 0 paused via SCHEDOFF.
#
# Example (commented out):
# config schedule 'sched_kids_eve'
#	option mac     'aa:bb:cc:dd:ee:ff'
#	option days    'weekdays'
#	option start   '16:00'
#	option stop    '20:00'
#	option label   'Kids tablet evening'
#	option enabled '1'
```

- [ ] **Step 3: Verify file still parses as a UCI config**

Run on a deploy target *or* a dev machine with `uci` installed:

```bash
uci -c $(pwd)/opkg/etc/config show gatekeeper
```

Expected: lists `gatekeeper.main`, `gatekeeper.blacklist` sections; new options/comments do not produce parse errors. (If you don't have `uci` locally, defer this verification to Task 15's on-router smoke test.)

- [ ] **Step 4: Commit**

```bash
git add opkg/etc/config/gatekeeper
git commit -m "Document schedule section type and schedule_notify flag in UCI config"
```

---

### Task 2: Set up test harness and implement `expand_days` helper

Create the dev-only test directory and write the day-token expansion helper with full unit tests. This helper is later inlined verbatim into both `tg_bot.sh` and `gatekeeper.sh`; the test file ensures both copies have the same correct logic.

**Files:**
- Create: `tests/test_schedule_helpers.sh`
- Create: `tests/README.md`

- [ ] **Step 1: Write the test file with `expand_days` definition and assertions**

Create `tests/test_schedule_helpers.sh`:

```sh
#!/bin/sh
# Dev-only unit tests for schedule helper functions.
# These functions are duplicated verbatim into tg_bot.sh and gatekeeper.sh.
# When you change one, change all three. Run from repo root:
#   sh tests/test_schedule_helpers.sh

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
```

- [ ] **Step 2: Add a brief tests README**

Create `tests/README.md`:

```markdown
# Tests

Dev-only POSIX-shell unit tests for the helpers used by `tg_bot.sh` and
`gatekeeper.sh`. Run on a dev machine; not deployed to the router.

```sh
sh tests/test_schedule_helpers.sh
```

These tests cover the **pure-logic** helpers (`expand_days`,
`window_active_now`). Integration with `nft` / `uci` / Telegram is verified
manually on the router per the spec's testing plan
(see `docs/superpowers/specs/2026-04-28-scheduled-approval-design.md` §9).

The helper bodies in this file must be kept in sync with the copies inlined
into `tg_bot.sh` and `gatekeeper.sh` — there are three copies on purpose; the
spec accepts duplication to avoid adding a new runtime file.
```

- [ ] **Step 3: Run the test and confirm all pass**

```bash
sh tests/test_schedule_helpers.sh
```

Expected output (final line):
```
PASS=6 FAIL=0
```

Exit code 0.

- [ ] **Step 4: Commit**

```bash
git add tests/test_schedule_helpers.sh tests/README.md
git commit -m "Add dev test harness and expand_days helper for schedule day tokens"
```

---

### Task 3: Add `window_active_now` predicate with cross-midnight support

The core scheduling predicate. Given a schedule's `days`/`start`/`stop` and the current `today_dow`/`now_hm`, returns the window-end epoch on stdout if the schedule is active, or empty if not. Same-day and cross-midnight cases.

**Files:**
- Modify: `tests/test_schedule_helpers.sh`

- [ ] **Step 1: Add `window_active_now` after `expand_days` in the test file**

In `tests/test_schedule_helpers.sh`, after the `expand_days` block (just before the final `echo "PASS=..."`), insert:

```sh
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
        date -d "today $stop" +%s
    else
        # Cross-midnight: today $start -> tomorrow $stop
        # Cross-midnight: today $start -> tomorrow $stop
        # Derive yesterday from today_dow (no system clock dependency)
        yesterday_dow=$(echo "$today_dow" | awk '
            BEGIN { split("sun mon tue wed thu fri sat", d) }
            { for (i=1;i<=7;i++) if (d[i]==$1) { print d[(i+5)%7+1]; exit } }
        ')
        if echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" \
           && [ "$now_m" -ge "$start_m" ]; then
            date -d "tomorrow $stop" +%s
        elif echo "$expanded" | tr ' ' '\n' | grep -qx "$yesterday_dow" \
             && [ "$now_m" -lt "$stop_m" ]; then
            date -d "today $stop" +%s
        fi
    fi
}

# Helper: turn an end-epoch (or empty) into ACTIVE / inactive for asserts.
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
```

- [ ] **Step 2: Run the test and verify all pass**

```bash
sh tests/test_schedule_helpers.sh
```

Expected last line: `PASS=28 FAIL=0` (6 from Task 2 + 4 hm_to_min + 18 window_active_now/is_active = 28). Exit code 0.

If `date -d "yesterday"` fails on macOS (BSD `date`), substitute `gdate` from `coreutils`: `brew install coreutils`, then `alias date=gdate` in the shell or run via `PATH=/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH sh tests/test_schedule_helpers.sh`. BusyBox `date -d` on the router supports the GNU syntax used here.

- [ ] **Step 3: Commit**

```bash
git add tests/test_schedule_helpers.sh
git commit -m "Add window_active_now predicate with same-day and cross-midnight tests"
```

---

### Task 4: Add `scheduler_tick` to `tg_bot.sh` and wire it into the main loop

Inline the helpers (`expand_days`, `hm_to_min`, `window_active_now`) into `tg_bot.sh`, add the `scheduler_tick` function that converges `approved_macs` toward desired state, and call it once per main-loop iteration before processing Telegram updates.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Add helpers and `scheduler_tick` after `parse_remaining_secs`**

Locate the existing `parse_remaining_secs` function in `tg_bot.sh` (around line 146). Immediately after its closing `}`, insert:

```sh
# Schedule helpers — kept identical to copies in gatekeeper.sh and the
# unit-test file tests/test_schedule_helpers.sh. When you change one,
# change all three.
expand_days() {
    case "$1" in
        daily)    echo "mon tue wed thu fri sat sun" ;;
        weekdays) echo "mon tue wed thu fri" ;;
        weekends) echo "sat sun" ;;
        *)        echo "$1" | tr ',' ' ' ;;
    esac
}

hm_to_min() {
    echo "$1" | awk -F: '{print $1 * 60 + $2}'
}

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
        date -d "today $stop" +%s
    else
        # Cross-midnight: today $start -> tomorrow $stop
        # Derive yesterday from today_dow (no system clock dependency)
        yesterday_dow=$(echo "$today_dow" | awk '
            BEGIN { split("sun mon tue wed thu fri sat", d) }
            { for (i=1;i<=7;i++) if (d[i]==$1) { print d[(i+5)%7+1]; exit } }
        ')
        if echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" \
           && [ "$now_m" -ge "$start_m" ]; then
            date -d "tomorrow $stop" +%s
        elif echo "$expanded" | tr ' ' '\n' | grep -qx "$yesterday_dow" \
             && [ "$now_m" -lt "$stop_m" ]; then
            date -d "today $stop" +%s
        fi
    fi
}

# scheduler_tick — converge approved_macs toward the union of currently-active
# schedules. Called once per main-loop iteration. Idempotent and crash-safe:
# missed ticks are recovered by the next one.
SCHED_ACTIVE_FILE="/tmp/sched_active"
SCHED_LOCK_FILE="/tmp/sched_lock"

scheduler_tick() {
    # Function-local variables — stop pollution of the surrounding loop scope
    # (BusyBox ash supports `local`; helpers below stay sans-`local` because
    # they're always invoked via $(...) and run in their own subshell).
    local NOW_EPOCH DOW HM sec enabled mac days start stop
    local end_epoch remaining old_macs new_macs locked

    # Skip while gatekeeper is in emergency-disabled state.
    [ "$(uci -q get gatekeeper.main.disabled)" = "1" ] && return 0

    # Skip until NTP has set a sane date (first ~60 s after boot).
    [ "$(date +%Y)" -ge 2024 ] || return 0

    # Single-flight: skip if another tick is already running.
    locked=0
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$SCHED_LOCK_FILE"
        flock -n 9 || return 0
        locked=1
    fi

    NOW_EPOCH=$(date +%s)
    DOW=$(date +%a | tr '[:upper:]' '[:lower:]')
    HM=$(date +%H:%M)

    : > "${SCHED_ACTIVE_FILE}.tmp"

    # Iterate UCI schedule sections.
    for sec in $(uci show gatekeeper 2>/dev/null \
                 | sed -n 's/^gatekeeper\.\([^.=]*\)=schedule$/\1/p'); do
        enabled=$(uci -q get "gatekeeper.${sec}.enabled" || echo 1)
        [ "$enabled" = "1" ] || continue

        mac=$(uci -q get "gatekeeper.${sec}.mac" | tr '[:upper:]' '[:lower:]')
        days=$(uci -q get "gatekeeper.${sec}.days")
        start=$(uci -q get "gatekeeper.${sec}.start")
        stop=$(uci -q get "gatekeeper.${sec}.stop")

        [ -n "$mac" ] && [ -n "$days" ] && [ -n "$start" ] && [ -n "$stop" ] || continue

        end_epoch=$(window_active_now "$days" "$start" "$stop" "$DOW" "$HM")
        [ -n "$end_epoch" ] || continue

        # 4b: denied_macs wins.
        if nft list set inet fw4 denied_macs 2>/dev/null | grep -qi "$mac"; then
            continue
        fi

        remaining=$(( end_epoch - NOW_EPOCH ))
        [ "$remaining" -ge 60 ] || continue

        # Idempotent push (delete-then-add is required to update timeout).
        nft "delete element inet fw4 approved_macs { $mac }" 2>/dev/null
        nft "add element inet fw4 approved_macs { $mac timeout ${remaining}s }" 2>/dev/null

        echo "$sec $mac $end_epoch" >> "${SCHED_ACTIVE_FILE}.tmp"
    done

    # Window-end pop: any MAC active last tick but not now -> remove.
    if [ -f "$SCHED_ACTIVE_FILE" ]; then
        old_macs=$(awk '{print $2}' "$SCHED_ACTIVE_FILE" | sort -u)
        new_macs=$(awk '{print $2}' "${SCHED_ACTIVE_FILE}.tmp" | sort -u)
        for mac in $old_macs; do
            if ! echo "$new_macs" | grep -qx "$mac"; then
                nft "delete element inet fw4 approved_macs { $mac }" 2>/dev/null
                echo "$(date '+%Y-%m-%dT%H:%M:%S') $mac - - schedule-window-ended" >> "$LOG_FILE"
            fi
        done
    fi

    mv "${SCHED_ACTIVE_FILE}.tmp" "$SCHED_ACTIVE_FILE"

    # Release the lock fd so it isn't inherited by every child the main loop
    # spawns afterwards (curl, jq, nft, awk, etc.). Re-opened on the next tick.
    [ "$locked" = "1" ] && exec 9<&-
}
```

- [ ] **Step 2: Call `scheduler_tick` once per main-loop iteration**

In `tg_bot.sh`, find the main loop (`while true; do` near line 160). Inside that loop, after the log-rotation block (around line 183, just before `echo "$RESPONSE" | jq -c '.result[]' ...`), insert:

```sh
    # Reconcile schedule-driven approvals before processing Telegram updates.
    # Tick is cheap (~tens of ms) and idempotent.
    scheduler_tick
```

- [ ] **Step 3: Run a syntax check on the modified file**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0. If you get a syntax error, re-check the inserted blocks.

- [ ] **Step 4: Smoke-test by sourcing the helper functions interactively**

On a Linux machine (or macOS with `coreutils`):

```bash
sh -c '
. ./tg_bot.sh 2>/dev/null || true   # will fail to start the bot loop, that is OK
type expand_days >/dev/null
type window_active_now >/dev/null
type scheduler_tick >/dev/null
echo OK
' 2>/dev/null | tail -1
```

(This will print syntax errors if any are present; the function-existence checks are loose since sourcing the full file invokes the main `while true` loop. A cleaner verification is the on-router smoke test in Task 15.)

- [ ] **Step 5: Commit**

```bash
git add tg_bot.sh
git commit -m "Add scheduler_tick reconciliation loop and schedule helpers to tg_bot.sh"
```

---

### Task 5: Implement `SCHEDADD` Telegram command

The most complex command. Validates MAC, days, window, and name; warns on static-lease MACs; persists to UCI; triggers an immediate tick.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Add the SCHEDADD handler**

Locate the existing `BLCLEAR` handler in `tg_bot.sh` (the last handler in the chain, around line 808). Just before its closing `fi` for the outer command-dispatch chain (the final `fi` on the line right after the BLCLEAR block, currently at line 820), insert a new `elif` block:

```sh
        # === SCHEDADD COMMAND ===
        # Add a scheduled auto-approval window.
        # Usage: SCHEDADD <mac> <days> <start>-<stop> [name]
        elif [ "$CMD" = "SCHEDADD" ]; then
            SCHED_MAC=$(echo "$TEXT" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
            SCHED_DAYS=$(echo "$TEXT" | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
            SCHED_WIN=$(echo "$TEXT" | awk '{print $4}')
            SCHED_NAME=$(echo "$TEXT" | awk '{print $5}' | tr '[:upper:]' '[:lower:]')

            # Validate MAC
            if ! echo "$SCHED_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                MSG="❌ Invalid MAC. Usage: SCHEDADD <mac> <days> <start>-<stop> [name]"
            # Validate days
            elif ! { [ "$SCHED_DAYS" = "daily" ] || [ "$SCHED_DAYS" = "weekdays" ] || [ "$SCHED_DAYS" = "weekends" ] \
                   || echo "$SCHED_DAYS" | grep -qE '^(mon|tue|wed|thu|fri|sat|sun)(,(mon|tue|wed|thu|fri|sat|sun))*$'; }; then
                MSG="❌ Invalid days. Use: daily | weekdays | weekends | mon,tue,wed,thu,fri,sat,sun"
            # Validate window
            elif ! echo "$SCHED_WIN" | grep -qE '^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]-(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$'; then
                MSG="❌ Invalid window. Use: HH:MM-HH:MM (24h, e.g. 16:00-20:00)"
            else
                SCHED_START=${SCHED_WIN%-*}
                SCHED_STOP=${SCHED_WIN#*-}
                if [ "$SCHED_START" = "$SCHED_STOP" ]; then
                    MSG="❌ start and stop must differ"
                else
                    # Resolve name (auto-generate or validate)
                    if [ -z "$SCHED_NAME" ]; then
                        SUFFIX=$(echo "$SCHED_MAC" | tr -d ':' | cut -c7-12)
                        n=1
                        while uci -q get "gatekeeper.sched_${SUFFIX}_${n}" >/dev/null 2>&1; do
                            n=$((n+1))
                        done
                        SCHED_NAME="sched_${SUFFIX}_${n}"
                        NAME_VALID=1
                    elif ! echo "$SCHED_NAME" | grep -qE '^[a-z0-9_]{1,32}$'; then
                        MSG="❌ Invalid name. Use 1-32 chars of [a-z0-9_]"
                        NAME_VALID=0
                    elif uci -q get "gatekeeper.${SCHED_NAME}" >/dev/null 2>&1; then
                        MSG="❌ Schedule '${SCHED_NAME}' already exists. Use SCHEDREMOVE first."
                        NAME_VALID=0
                    else
                        NAME_VALID=1
                    fi

                    if [ "$NAME_VALID" = "1" ]; then
                        # Static-lease check (warn-but-allow per decision 4d)
                        STATIC_LEASES=$(uci show dhcp 2>/dev/null | grep "\.mac=" | awk -F"='" '{print $2}' | tr -d "'" | tr '[:upper:]' '[:lower:]')
                        WARN=""
                        for sm in $STATIC_LEASES; do
                            if [ "$sm" = "$SCHED_MAC" ]; then
                                WARN="⚠️ MAC has a static DHCP lease; this schedule will have no effect until the static lease is removed.\n\n"
                                break
                            fi
                        done

                        # Persist
                        uci set "gatekeeper.${SCHED_NAME}=schedule"
                        uci set "gatekeeper.${SCHED_NAME}.mac=${SCHED_MAC}"
                        uci set "gatekeeper.${SCHED_NAME}.days=${SCHED_DAYS}"
                        uci set "gatekeeper.${SCHED_NAME}.start=${SCHED_START}"
                        uci set "gatekeeper.${SCHED_NAME}.stop=${SCHED_STOP}"
                        uci set "gatekeeper.${SCHED_NAME}.enabled=1"
                        if uci commit gatekeeper; then
                            scheduler_tick
                            MSG="${WARN}✅ Schedule *${SCHED_NAME}* added: \`${SCHED_MAC}\` ${SCHED_DAYS} ${SCHED_START}–${SCHED_STOP}"
                            echo "$(date '+%Y-%m-%dT%H:%M:%S') ${SCHED_MAC} - - sched-added-${SCHED_NAME}" >> "$LOG_FILE"
                            logger -t tg_bot "Schedule added: ${SCHED_NAME} (${SCHED_MAC} ${SCHED_DAYS} ${SCHED_START}-${SCHED_STOP})"
                        else
                            uci revert gatekeeper 2>/dev/null
                            MSG="❌ Failed to save schedule (UCI commit error)"
                        fi
                    fi
                fi
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Manual on-device test plan (deferred to Task 15)**

Add this case to your mental list for Task 15's smoke test:

```
Send to bot: SCHEDADD aa:bb:cc:dd:ee:ff weekdays 16:00-20:00 kids_eve
Expected reply: ✅ Schedule *kids_eve* added: aa:bb:cc:dd:ee:ff weekdays 16:00–20:00
Then: uci show gatekeeper.kids_eve   -> shows mac/days/start/stop/enabled
```

- [ ] **Step 4: Commit**

```bash
git add tg_bot.sh
git commit -m "Add SCHEDADD command to register an auto-approval schedule"
```

---

### Task 6: Implement `SCHEDREMOVE` Telegram command

Removes a schedule by stable name. If the schedule was currently active, immediately removes the MAC from `approved_macs` (don't wait for the next tick).

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Add the SCHEDREMOVE handler**

In `tg_bot.sh`, immediately after the SCHEDADD `elif` block from Task 5, insert:

```sh
        # === SCHEDREMOVE COMMAND ===
        # Delete a schedule by name.
        # Usage: SCHEDREMOVE <name>
        elif [ "$CMD" = "SCHEDREMOVE" ] && [ -n "$ARG" ]; then
            SCHED_NAME=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')
            SECTION_TYPE=$(uci -q get "gatekeeper.${SCHED_NAME}")
            if [ "$SECTION_TYPE" != "schedule" ]; then
                MSG="❌ No schedule named '${SCHED_NAME}'"
            else
                SCHED_MAC=$(uci -q get "gatekeeper.${SCHED_NAME}.mac")
                # If this schedule was the only thing keeping the MAC in
                # approved_macs, drop it now so the user sees instant effect.
                if [ -n "$SCHED_MAC" ] && [ -f "$SCHED_ACTIVE_FILE" ] \
                   && grep -q "^${SCHED_NAME} " "$SCHED_ACTIVE_FILE"; then
                    nft "delete element inet fw4 approved_macs { $SCHED_MAC }" 2>/dev/null
                fi
                uci delete "gatekeeper.${SCHED_NAME}" 2>/dev/null
                if uci commit gatekeeper; then
                    scheduler_tick
                    MSG="🗑️ Schedule *${SCHED_NAME}* removed."
                    echo "$(date '+%Y-%m-%dT%H:%M:%S') ${SCHED_MAC:--} - - sched-removed-${SCHED_NAME}" >> "$LOG_FILE"
                    logger -t tg_bot "Schedule removed: ${SCHED_NAME}"
                else
                    uci revert gatekeeper 2>/dev/null
                    MSG="❌ Failed to remove schedule (UCI commit error)"
                fi
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tg_bot.sh
git commit -m "Add SCHEDREMOVE command to delete a schedule by name"
```

---

### Task 7: Implement `SCHEDLIST` Telegram command

Lists all schedules, optionally filtered by MAC. Marks currently-active rows with `⏰ active (until HH:MM)` based on `/tmp/sched_active`.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Add the SCHEDLIST handler**

In `tg_bot.sh`, immediately after the SCHEDREMOVE block, insert:

```sh
        # === SCHEDLIST COMMAND ===
        # List all schedules; optional MAC filter.
        # Usage: SCHEDLIST           - all schedules
        #        SCHEDLIST <mac>     - only schedules for that MAC
        elif [ "$CMD" = "SCHEDLIST" ]; then
            FILTER_MAC=""
            if [ -n "$ARG" ]; then
                FILTER_MAC=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')
                if ! echo "$FILTER_MAC" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
                    MSG="❌ Invalid MAC filter. Use: SCHEDLIST [aa:bb:cc:dd:ee:ff]"
                    curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                         -H "Content-Type: application/json" \
                         -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                    continue
                fi
            fi

            MSG="📅 *Schedules"
            [ -n "$FILTER_MAC" ] && MSG="${MSG} for ${FILTER_MAC}"
            MSG="${MSG}:*\n"

            count=0
            for sec in $(uci show gatekeeper 2>/dev/null \
                         | sed -n 's/^gatekeeper\.\([^.=]*\)=schedule$/\1/p'); do
                mac=$(uci -q get "gatekeeper.${sec}.mac" | tr '[:upper:]' '[:lower:]')
                [ -n "$FILTER_MAC" ] && [ "$mac" != "$FILTER_MAC" ] && continue

                days=$(uci -q get "gatekeeper.${sec}.days")
                start=$(uci -q get "gatekeeper.${sec}.start")
                stop=$(uci -q get "gatekeeper.${sec}.stop")
                label=$(uci -q get "gatekeeper.${sec}.label")
                enabled=$(uci -q get "gatekeeper.${sec}.enabled" || echo 1)

                count=$((count+1))

                STATE=""
                if [ "$enabled" != "1" ]; then
                    STATE=" *(paused)*"
                elif [ -f "$SCHED_ACTIVE_FILE" ] && grep -q "^${sec} " "$SCHED_ACTIVE_FILE"; then
                    end_epoch=$(grep "^${sec} " "$SCHED_ACTIVE_FILE" | awk '{print $3}')
                    end_str=$(date -d "@${end_epoch}" '+%H:%M' 2>/dev/null)
                    STATE=" ⏰ *active (until ${end_str})*"
                fi

                MSG="${MSG}\n*${sec}*${STATE}\n   └ \`${mac}\` ${days} ${start}–${stop}"
                [ -n "$label" ] && MSG="${MSG}\n   _${label}_"
            done

            if [ "$count" = "0" ]; then
                MSG="${MSG}\n_No schedules._"
            else
                MSG="${MSG}\n\n💡 SCHEDREMOVE <name> | SCHEDOFF <name> | SCHEDON <name>"
            fi

            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tg_bot.sh
git commit -m "Add SCHEDLIST command with optional MAC filter and active-window tag"
```

---

### Task 8: Implement `SCHEDSHOW` Telegram command

Single-record detail view.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Add the SCHEDSHOW handler**

In `tg_bot.sh`, immediately after the SCHEDLIST block, insert:

```sh
        # === SCHEDSHOW COMMAND ===
        # Show full details of one schedule.
        # Usage: SCHEDSHOW <name>
        elif [ "$CMD" = "SCHEDSHOW" ] && [ -n "$ARG" ]; then
            SCHED_NAME=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')
            SECTION_TYPE=$(uci -q get "gatekeeper.${SCHED_NAME}")
            if [ "$SECTION_TYPE" != "schedule" ]; then
                MSG="❌ No schedule named '${SCHED_NAME}'"
            else
                mac=$(uci -q get "gatekeeper.${SCHED_NAME}.mac")
                days=$(uci -q get "gatekeeper.${SCHED_NAME}.days")
                start=$(uci -q get "gatekeeper.${SCHED_NAME}.start")
                stop=$(uci -q get "gatekeeper.${SCHED_NAME}.stop")
                label=$(uci -q get "gatekeeper.${SCHED_NAME}.label")
                enabled=$(uci -q get "gatekeeper.${SCHED_NAME}.enabled" || echo 1)

                STATE="paused"
                if [ "$enabled" = "1" ]; then
                    STATE="enabled"
                    if [ -f "$SCHED_ACTIVE_FILE" ] && grep -q "^${SCHED_NAME} " "$SCHED_ACTIVE_FILE"; then
                        end_epoch=$(grep "^${SCHED_NAME} " "$SCHED_ACTIVE_FILE" | awk '{print $3}')
                        end_str=$(date -d "@${end_epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null)
                        STATE="enabled, ⏰ active until ${end_str}"
                    fi
                fi

                MSG="📅 *Schedule:* ${SCHED_NAME}\n"
                MSG="${MSG}🔹 *MAC:* \`${mac}\`\n"
                MSG="${MSG}🔹 *Days:* ${days}\n"
                MSG="${MSG}🔹 *Window:* ${start}–${stop}\n"
                MSG="${MSG}🔹 *State:* ${STATE}\n"
                [ -n "$label" ] && MSG="${MSG}🔹 *Label:* ${label}\n"
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tg_bot.sh
git commit -m "Add SCHEDSHOW command for single-schedule detail view"
```

---

### Task 9: Implement `SCHEDOFF` and `SCHEDON` Telegram commands

Toggle a schedule's `enabled` flag without removing it. Trigger an immediate `scheduler_tick` so the change is visible right away.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Add the SCHEDOFF and SCHEDON handlers**

In `tg_bot.sh`, immediately after the SCHEDSHOW block, insert:

```sh
        # === SCHEDOFF / SCHEDON COMMANDS ===
        # Toggle a schedule's enabled flag. SCHEDOFF pauses (window pops on next tick);
        # SCHEDON resumes (window pushes on next tick if currently in time-range).
        elif { [ "$CMD" = "SCHEDOFF" ] || [ "$CMD" = "SCHEDON" ]; } && [ -n "$ARG" ]; then
            SCHED_NAME=$(echo "$ARG" | tr '[:upper:]' '[:lower:]')
            SECTION_TYPE=$(uci -q get "gatekeeper.${SCHED_NAME}")
            if [ "$SECTION_TYPE" != "schedule" ]; then
                MSG="❌ No schedule named '${SCHED_NAME}'"
            else
                if [ "$CMD" = "SCHEDOFF" ]; then
                    uci set "gatekeeper.${SCHED_NAME}.enabled=0"
                    NEW_STATE="paused"
                    EMOJI="⏸️"
                else
                    uci set "gatekeeper.${SCHED_NAME}.enabled=1"
                    NEW_STATE="enabled"
                    EMOJI="▶️"
                fi
                if uci commit gatekeeper; then
                    scheduler_tick
                    MSG="${EMOJI} Schedule *${SCHED_NAME}* ${NEW_STATE}."
                    echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - sched-${NEW_STATE}-${SCHED_NAME}" >> "$LOG_FILE"
                else
                    uci revert gatekeeper 2>/dev/null
                    MSG="❌ Failed to toggle schedule (UCI commit error)"
                fi
            fi
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tg_bot.sh
git commit -m "Add SCHEDOFF and SCHEDON commands to pause/resume schedules"
```

---

### Task 10: Implement `SCHEDNOTIFY` Telegram command

Toggle the `gatekeeper.main.schedule_notify` flag (default `0`, silent). When `1`, `gatekeeper.sh` step 3.6 will post an info message on schedule auto-approval. The flag itself is read in Task 13.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Add the SCHEDNOTIFY handler**

In `tg_bot.sh`, immediately after the SCHEDOFF/SCHEDON block, insert:

```sh
        # === SCHEDNOTIFY COMMAND ===
        # Toggle the optional info-message on schedule auto-approve.
        # Usage: SCHEDNOTIFY ON | OFF | STATUS
        elif [ "$CMD" = "SCHEDNOTIFY" ] && [ -n "$ARG" ]; then
            SUB=$(echo "$ARG" | tr '[:lower:]' '[:upper:]')
            case "$SUB" in
                ON)
                    uci set gatekeeper.main.schedule_notify=1
                    if uci commit gatekeeper; then
                        MSG="🔔 Schedule notifications: *ENABLED*"
                    else
                        uci revert gatekeeper 2>/dev/null
                        MSG="❌ Failed to update setting (UCI commit error)"
                    fi
                    ;;
                OFF)
                    uci set gatekeeper.main.schedule_notify=0
                    if uci commit gatekeeper; then
                        MSG="🔕 Schedule notifications: *DISABLED*"
                    else
                        uci revert gatekeeper 2>/dev/null
                        MSG="❌ Failed to update setting (UCI commit error)"
                    fi
                    ;;
                STATUS)
                    SN=$(uci -q get gatekeeper.main.schedule_notify || echo 0)
                    if [ "$SN" = "1" ]; then
                        MSG="🔔 Schedule notifications: *ENABLED*"
                    else
                        MSG="🔕 Schedule notifications: *DISABLED*"
                    fi
                    ;;
                *)
                    MSG="❌ Usage: SCHEDNOTIFY ON | OFF | STATUS"
                    ;;
            esac
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tg_bot.sh
git commit -m "Add SCHEDNOTIFY ON/OFF/STATUS to toggle schedule auto-approve info messages"
```

---

### Task 11: Tag schedule-driven entries in `STATUS` output

Locate the existing `STATUS` command handler and append a `⏰ Scheduled (<name>)` marker to entries whose MAC appears in `/tmp/sched_active`.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Modify the STATUS handler's per-entry rendering**

In `tg_bot.sh`, find the STATUS handler's per-guest formatting block (currently around lines 355–360):

```sh
                    # Format guest entry: ID. Hostname, MAC address, remaining time, and absolute expiry
                    if [ -n "$EXPIRY_STR" ]; then
                        MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME}, expires ${EXPIRY_STR})\n"
                    else
                        MSG="${MSG}${count}. *${H_NAME}*\n   └ \`${M_ADDR}\` (${M_TIME})\n"
                    fi
```

Replace it with:

```sh
                    # Tag entries that came from a scheduled push so the user can tell
                    # the difference between manual approvals and schedule-driven ones.
                    SCHED_TAG=""
                    if [ -f "$SCHED_ACTIVE_FILE" ]; then
                        SN=$(grep -i " ${M_ADDR} " "$SCHED_ACTIVE_FILE" | head -n 1 | awk '{print $1}')
                        [ -n "$SN" ] && SCHED_TAG=" ⏰ _${SN}_"
                    fi

                    # Format guest entry: ID. Hostname, MAC address, remaining time,
                    # absolute expiry, and (optional) schedule tag.
                    if [ -n "$EXPIRY_STR" ]; then
                        MSG="${MSG}${count}. *${H_NAME}*${SCHED_TAG}\n   └ \`${M_ADDR}\` (${M_TIME}, expires ${EXPIRY_STR})\n"
                    else
                        MSG="${MSG}${count}. *${H_NAME}*${SCHED_TAG}\n   └ \`${M_ADDR}\` (${M_TIME})\n"
                    fi
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tg_bot.sh
git commit -m "Tag schedule-driven entries in STATUS with the schedule name"
```

---

### Task 12: Update the `HELP` command

Add a new `📅 Schedules` section to the existing HELP message.

**Files:**
- Modify: `tg_bot.sh`

- [ ] **Step 1: Insert schedule help block before the `Maintenance` section**

In the HELP handler in `tg_bot.sh` (around lines 270–293), find the line that starts the Maintenance subsection:

```sh
            MSG="${MSG}*Maintenance:*\n"
```

Immediately *before* that line, insert:

```sh
            MSG="${MSG}*Schedules:*\n"
            MSG="${MSG}\`SCHEDADD <mac> <days> <start>-<stop> [name]\` - Add auto-approve window\n"
            MSG="${MSG}\`SCHEDLIST [mac]\` - List schedules (filter by MAC optional)\n"
            MSG="${MSG}\`SCHEDSHOW <name>\` - Show schedule details\n"
            MSG="${MSG}\`SCHEDREMOVE <name>\` - Delete a schedule\n"
            MSG="${MSG}\`SCHEDOFF <name>\` / \`SCHEDON <name>\` - Pause/resume\n"
            MSG="${MSG}\`SCHEDNOTIFY ON|OFF|STATUS\` - Toggle schedule notifications\n"
            MSG="${MSG}_Days:_ daily | weekdays | weekends | mon,tue,...\n"
            MSG="${MSG}_Times:_ HH:MM (24h, local TZ). Stop ≤ start = crosses midnight.\n\n"
```

- [ ] **Step 2: Run a syntax check**

```bash
sh -n tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tg_bot.sh
git commit -m "Add Schedules section to HELP command"
```

---

### Task 13: Add reactive auto-approve gate to `gatekeeper.sh` (step 3.6)

Inline the helper functions into `gatekeeper.sh` (duplicates of `tg_bot.sh` per the spec) and add a new step between blacklist mode (3.5) and notification (4) that auto-approves a MAC if it matches an active schedule.

**Files:**
- Modify: `gatekeeper.sh`

- [ ] **Step 1: Add helpers near the top of `gatekeeper.sh`**

In `gatekeeper.sh`, after the `LOG_FILE="/tmp/gatekeeper.log"` line (around line 88) but **before** the early-disabled exit (line 103), insert:

```sh
# Schedule helpers — kept identical to copies in tg_bot.sh and the
# unit-test file tests/test_schedule_helpers.sh. When you change one,
# change all three.
expand_days() {
    case "$1" in
        daily)    echo "mon tue wed thu fri sat sun" ;;
        weekdays) echo "mon tue wed thu fri" ;;
        weekends) echo "sat sun" ;;
        *)        echo "$1" | tr ',' ' ' ;;
    esac
}

hm_to_min() {
    echo "$1" | awk -F: '{print $1 * 60 + $2}'
}

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
        date -d "today $stop" +%s
    else
        # Cross-midnight: today $start -> tomorrow $stop
        # Derive yesterday from today_dow (no system clock dependency)
        yesterday_dow=$(echo "$today_dow" | awk '
            BEGIN { split("sun mon tue wed thu fri sat", d) }
            { for (i=1;i<=7;i++) if (d[i]==$1) { print d[(i+5)%7+1]; exit } }
        ')
        if echo "$expanded" | tr ' ' '\n' | grep -qx "$today_dow" \
           && [ "$now_m" -ge "$start_m" ]; then
            date -d "tomorrow $stop" +%s
        elif echo "$expanded" | tr ' ' '\n' | grep -qx "$yesterday_dow" \
             && [ "$now_m" -lt "$stop_m" ]; then
            date -d "today $stop" +%s
        fi
    fi
}

# Returns the *latest* end-epoch across all enabled schedules whose mac equals
# $1 and whose window is active right now. Empty stdout = no active schedule.
check_active_schedule_for_mac() {
    target_mac=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    [ -n "$target_mac" ] || return 0
    [ "$(date +%Y)" -ge 2024 ] || return 0   # NTP guard

    today_dow=$(date +%a | tr '[:upper:]' '[:lower:]')
    now_hm=$(date +%H:%M)
    best_end=""

    for sec in $(uci show gatekeeper 2>/dev/null \
                 | sed -n 's/^gatekeeper\.\([^.=]*\)=schedule$/\1/p'); do
        enabled=$(uci -q get "gatekeeper.${sec}.enabled" || echo 1)
        [ "$enabled" = "1" ] || continue

        mac=$(uci -q get "gatekeeper.${sec}.mac" | tr '[:upper:]' '[:lower:]')
        [ "$mac" = "$target_mac" ] || continue

        days=$(uci -q get "gatekeeper.${sec}.days")
        start=$(uci -q get "gatekeeper.${sec}.start")
        stop=$(uci -q get "gatekeeper.${sec}.stop")
        [ -n "$days" ] && [ -n "$start" ] && [ -n "$stop" ] || continue

        end_epoch=$(window_active_now "$days" "$start" "$stop" "$today_dow" "$now_hm")
        [ -n "$end_epoch" ] || continue

        if [ -z "$best_end" ] || [ "$end_epoch" -gt "$best_end" ]; then
            best_end=$end_epoch
        fi
    done
    [ -n "$best_end" ] && echo "$best_end"
}
```

- [ ] **Step 2: Insert step 3.6 between blacklist mode and notification**

In `gatekeeper.sh`, find the end of the blacklist-mode block (currently around line 180, the comment that reads `# MAC is in blacklist - fall through to normal approval request below`) and the start of step 4 (`# Step 4: For non-static devices with 'add' action, send notification`).

Between them, insert:

```sh
# Step 3.6: Active schedule auto-approve (hybrid catch for mid-window DHCP).
# A scheduled MAC connecting inside its window is silently auto-approved
# until the window's end. Decisions:
#   - Static lease (step 1) wins over schedules.
#   - denied_macs (step 2) wins over schedules.
#   - Schedule wins over the blacklist gate.
if [ "$is_static" -eq 0 ] && [ "$ACTION" = "add" ]; then
    SCHED_END=$(check_active_schedule_for_mac "$MAC")
    if [ -n "$SCHED_END" ]; then
        NOW_TS=$(date +%s)
        REMAINING=$(( SCHED_END - NOW_TS ))
        if [ "$REMAINING" -ge 60 ]; then
            nft "delete element inet fw4 approved_macs { $MAC }" 2>/dev/null
            nft "add element inet fw4 approved_macs { $MAC timeout ${REMAINING}s }" 2>/dev/null
            logger -t gatekeeper "Auto-approved (schedule): $MAC ($HOSTNAME) - $IP, ${REMAINING}s"
            echo "$(date '+%Y-%m-%dT%H:%M:%S') $MAC $IP ${HOSTNAME:--} schedule-approved-${REMAINING}s" >> "$LOG_FILE"

            SN=$(uci -q get gatekeeper.main.schedule_notify || echo 0)
            if [ "$SN" = "1" ]; then
                EXPIRY_STR=$(date -d "@${SCHED_END}" '+%Y-%m-%d %H:%M' 2>/dev/null)
                MESSAGE="✅ *Scheduled Auto-Approve*%0A%0A"
                MESSAGE="${MESSAGE}🔹 *Device:* ${HOSTNAME:-Unknown}%0A"
                MESSAGE="${MESSAGE}🔹 *MAC:* ${MAC}%0A"
                MESSAGE="${MESSAGE}🔹 *IP:* ${IP}%0A"
                MESSAGE="${MESSAGE}🔹 *Until:* ${EXPIRY_STR}"
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
                    -d "chat_id=${CHAT_ID}" \
                    -d "text=${MESSAGE}" \
                    -d "parse_mode=Markdown" > /dev/null
            fi
            exit 0
        fi
    fi
fi
```

- [ ] **Step 3: Run a syntax check**

```bash
sh -n gatekeeper.sh
```

Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add gatekeeper.sh
git commit -m "Add reactive schedule auto-approve gate (step 3.6) to gatekeeper.sh"
```

---

### Task 14: Update repository documentation

Add the new commands and state files to the user-facing docs and to `CLAUDE.md`.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `QUICK_REFERENCE.md`

- [ ] **Step 1: Update `CLAUDE.md` State Files table**

In `CLAUDE.md`, find the "State Files (`/tmp` — non-persistent)" table. Add two rows after the existing rows (after `/tmp/gatekeeper_timer_<MAC-no-colons>`):

```markdown
| `/tmp/sched_active` | Schedule reconciliation snapshot (one line per active schedule: `name mac end-epoch`); rebuilt by `scheduler_tick` and read by `STATUS` for the ⏰ tag |
| `/tmp/sched_lock` | flock guard preventing overlapping `scheduler_tick` invocations |
```

- [ ] **Step 2: Update `CLAUDE.md` validation order**

In `CLAUDE.md`, find the `gatekeeper.sh validation order` numbered list. Insert a new bullet between the blacklist-mode bullet (currently #5) and the "Otherwise → Send approval request" bullet (currently #6):

```markdown
6. Active schedule for MAC? → Auto-approve until window end, optionally notify (controlled by `gatekeeper.main.schedule_notify`)
```

Then renumber the original bullet 6 to bullet 7.

- [ ] **Step 3: Add Schedule commands section to `CLAUDE.md` "Telegram Bot Commands"**

In `CLAUDE.md`, find the `## Telegram Bot Commands` section. After the `**System:**` block, insert:

```markdown
**Schedules (auto-approve windows):**
- `SCHEDADD <mac> <days> <start>-<stop> [name]` — Register an auto-approval window. `name` auto-generated if omitted (`sched_<last3octets>_<n>`). `days` = `daily` | `weekdays` | `weekends` | comma-separated `mon,tue,...,sun`. Times in `HH:MM` 24h, router local TZ. `stop ≤ start` = crosses midnight, anchored to the start day.
- `SCHEDLIST [mac]` — List all schedules; optional MAC filter. Active schedules tagged `⏰ active (until HH:MM)`.
- `SCHEDSHOW <name>` — Single-schedule detail view.
- `SCHEDREMOVE <name>` — Delete a schedule. If currently active, MAC is removed from `approved_macs` immediately.
- `SCHEDOFF <name>` / `SCHEDON <name>` — Pause/resume a schedule without deleting it.
- `SCHEDNOTIFY ON|OFF|STATUS` — Toggle the optional info message on schedule auto-approve (default OFF).

Schedule definitions live in UCI (`/etc/config/gatekeeper`) as `config schedule '<name>'` sections; they survive reboots. The `scheduler_tick()` function in `tg_bot.sh` reconciles `approved_macs` once per polling-loop iteration. `gatekeeper.sh` step 3.6 reactively auto-approves mid-window DHCP events. A manual `REVOKE` during an active window adds the MAC to `denied_macs` for 30 min; the scheduler skips re-push while the deny entry exists, so REVOKE remains effective for at least 30 minutes during a window.
```

- [ ] **Step 4: Update `README.md`**

In `README.md`, locate the bot command listing (search for `STATUS` to find it). Add a new subsection following the same style as the existing blacklist-mode listing. Use the same content as in CLAUDE.md Step 3.

If `README.md` doesn't have a structured command listing, add a "Schedules" subsection in the most relevant existing area (typically a "Features" or "Commands" section — match the file's existing voice and depth).

- [ ] **Step 5: Update `QUICK_REFERENCE.md`**

In `QUICK_REFERENCE.md`, add concise one-line entries for each new command in the existing "command" / cheat-sheet format. Example block to add:

```
SCHEDADD <mac> <days> <start>-<stop> [name]   Add scheduled auto-approve
SCHEDLIST [mac]                                List schedules
SCHEDSHOW <name>                               Show schedule detail
SCHEDREMOVE <name>                             Delete schedule
SCHEDOFF <name> / SCHEDON <name>               Pause/resume schedule
SCHEDNOTIFY ON|OFF|STATUS                      Toggle schedule notifications
```

(Match the existing layout of `QUICK_REFERENCE.md` — single-column table, two-column table, or plain prose.)

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md README.md QUICK_REFERENCE.md
git commit -m "Document scheduled auto-approval commands and state files"
```

---

### Task 15: On-router smoke test (manual verification)

Deploy to the router and walk through the scenarios from the spec's testing plan (§9). This is the final verification gate.

**Files:**
- None (test only)

- [ ] **Step 1: Run pure-shell unit tests on dev machine first**

```bash
sh tests/test_schedule_helpers.sh
```

Expected last line: `PASS=28 FAIL=0`. Exit code 0. Fix any failures before deploying.

- [ ] **Step 2: Deploy to router**

```bash
./deploy.sh 192.168.1.1 --no-config
```

(Use `--no-config` to preserve any existing UCI customizations on the router.) Watch for SCP errors. Confirm services restart cleanly.

- [ ] **Step 3: Tail the log in another terminal**

```bash
ssh root@192.168.1.1 'logread -f | grep -E "gatekeeper|tg_bot"'
```

Leave this running for the rest of the test sequence.

- [ ] **Step 4: Sanity check — HELP and SCHEDLIST**

Send to the bot via Telegram:
```
HELP
```
Expected: HELP message includes the new `📅 Schedules` block with all six commands.

```
SCHEDLIST
```
Expected: `📅 Schedules:` header followed by `_No schedules._` (assuming a clean install).

- [ ] **Step 5: Validation errors**

Each of these should return a specific `❌` reply with no UCI write:
```
SCHEDADD                              # missing args
SCHEDADD bad-mac weekdays 16:00-20:00 # invalid MAC
SCHEDADD aa:bb:cc:dd:ee:ff funday 16:00-20:00     # invalid days
SCHEDADD aa:bb:cc:dd:ee:ff weekdays 25:00-30:00   # invalid times
SCHEDADD aa:bb:cc:dd:ee:ff weekdays 16:00-16:00   # start == stop
SCHEDADD aa:bb:cc:dd:ee:ff weekdays 16:00-20:00 BAD-Name   # invalid name
```

Confirm `uci show gatekeeper | grep '=schedule'` shows nothing was created.

- [ ] **Step 6: Time-bracketed window test (push + pop)**

Choose a MAC NOT currently on your network. Compute `start = now+1m`, `stop = now+3m`. Send:
```
SCHEDADD aa:bb:cc:dd:ee:ff daily HH:MM-HH:MM smoke
```

(Replace HH:MM with the computed times.)

Watch:
```
ssh root@192.168.1.1 'while true; do nft list set inet fw4 approved_macs | grep -i aa:bb:cc:dd:ee:ff; sleep 5; done'
```

Expected: empty output for ~1 min, then the MAC appears with a timeout decreasing toward 0, then disappears around `start+2m`. Log line `schedule-window-ended` written.

Cleanup:
```
SCHEDREMOVE smoke
```

- [ ] **Step 7: Cross-midnight (sanity check)**

```
SCHEDADD aa:bb:cc:dd:ee:ff daily 23:58-00:02 xnight
```

Run `nft list set inet fw4 approved_macs` at 23:59, 00:01, 00:03 (or fake the schedule with whatever bracket lines up with your test window). Confirm the MAC is present at 23:59 and 00:01 and absent at 00:03.

Cleanup:
```
SCHEDREMOVE xnight
```

- [ ] **Step 8: Reactive (hybrid) catch**

Set up a schedule for a MAC of a real device on your network with a window covering "now":
```
SCHEDADD <real-mac> daily HH:MM-HH:MM hybrid_test
```

Then on the router:
```
ssh root@192.168.1.1 'nft flush set inet fw4 approved_macs'
```

Trigger a fake DHCP event for that MAC:
```
ssh root@192.168.1.1 '/usr/bin/dnsmasq_trigger.sh add <real-mac> 192.168.1.99 testhost add'
```

Expected: log shows `schedule-approved-<N>s`; `nft list set inet fw4 approved_macs` shows the MAC immediately. Confirms step 3.6 fires.

Cleanup:
```
SCHEDREMOVE hybrid_test
```

- [ ] **Step 9: `fw4 reload` self-heal**

With an active schedule:
```
ssh root@192.168.1.1 'fw4 reload'
```

Wait ≤ 60s. Expected: `nft list set inet fw4 approved_macs` shows the scheduled MAC again (re-pushed by next `scheduler_tick`).

- [ ] **Step 10: REVOKE precedence**

With a window active for `<mac>`:
- `STATUS` to find the device's session ID.
- `REVOKE <id>`.

Expected:
- MAC moves from `approved_macs` to `denied_macs` (30m).
- For at least 30 minutes, `scheduler_tick` does NOT re-push (verify by inspecting `approved_macs` over a 5-min window).

After 30 min, `denied_macs` entry expires; next tick re-pushes if the window is still active.

- [ ] **Step 11: DISABLE / ENABLE behavior**

```
DISABLE
```
Expected: `gatekeeper_forward` chain flushed; scheduler_tick is a no-op (verify by waiting 60s and confirming no change to nftables sets).

```
ENABLE
```
Expected: chain restored; within 30s, any active schedule windows are re-pushed.

- [ ] **Step 12: SCHEDOFF / SCHEDON immediate effect**

With an active scheduled MAC:
```
SCHEDOFF <name>
```
Expected within 30s: MAC removed from `approved_macs`.

```
SCHEDON <name>
```
Expected within 30s: MAC re-added.

- [ ] **Step 13: Multi-schedule overlap**

Create two overlapping schedules for the same MAC:
```
SCHEDADD aa:bb:cc:dd:ee:ff daily 10:00-12:00 morn
SCHEDADD aa:bb:cc:dd:ee:ff daily 11:00-14:00 noon
```

At 11:30, the MAC's `approved_macs` timeout should match the *latest* end (14:00). Check: `nft list set inet fw4 approved_macs | grep aa:bb:cc:dd:ee:ff`.

Cleanup:
```
SCHEDREMOVE morn
SCHEDREMOVE noon
```

- [ ] **Step 14: Static-lease warning path**

Pick a MAC that IS in your UCI static DHCP leases:
```
SCHEDADD <static-mac> weekdays 16:00-20:00 static_test
```

Expected: reply prefixed with `⚠️ MAC has a static DHCP lease...` warning, but the schedule IS created (verify with `SCHEDLIST`).

Cleanup:
```
SCHEDREMOVE static_test
```

- [ ] **Step 15: Persistence across reboot**

With at least one schedule defined:
```
ssh root@192.168.1.1 reboot
```

After router comes back up:
```
SCHEDLIST
```
Expected: schedule is still present and (if its window is currently active) tagged `⏰ active`. Confirms UCI persistence works.

- [ ] **Step 16: If anything fails**

If any of steps 4–15 fail, do **NOT** mark the implementation complete. Open a fresh debugging session per the project's debugging conventions, fix the underlying issue, redeploy with `./deploy.sh`, and re-run the failed step. Reuse the in-loop log tail from Step 3 for live diagnosis.

Once all steps pass:

```bash
git tag -a v1.x.0-scheduled-approval -m "Scheduled auto-approval feature"
```

(Replace `1.x.0` with the appropriate next version number per the project's tagging convention.)

---

## Self-Review

**Spec coverage:** Each spec section maps to a task —
- §3 Decisions: encoded in tasks 4–13 (precedence, validation, helpers).
- §4.1 file-by-file inventory: tasks 1, 4–13, 14.
- §4.2 UCI schema: task 1.
- §4.3 ephemeral state: tasks 4 (sched_active write), 7 (sched_active read), 11 (sched_active in STATUS).
- §5 scheduler tick: task 4.
- §6 reactive integration: task 13.
- §7 commands: tasks 5–10, 12.
- §8 edge cases: handled in tasks 4 (NTP guard, flock, denied-wins, idempotent), 5 (validation), 13 (NTP guard, soft fail), 15 (manual verification).
- §9 testing: tasks 2–3 (unit), 15 (manual on-router).

No gaps identified.

**Type/name consistency check:**
- `SCHED_ACTIVE_FILE` and `SCHED_LOCK_FILE` declared in task 4, used by tasks 6 (SCHEDREMOVE), 7 (SCHEDLIST), 8 (SCHEDSHOW), 11 (STATUS tag). Consistent.
- Function names (`expand_days`, `hm_to_min`, `window_active_now`, `scheduler_tick`, `check_active_schedule_for_mac`) used uniformly across tasks 4 and 13.
- UCI option names (`mac`, `days`, `start`, `stop`, `enabled`, `label`, `schedule_notify`) consistent with task 1's schema.

**Placeholder scan:** No "TBD" / "TODO" / "fill in" markers. Every code step has complete code. Every test step shows the expected output.
