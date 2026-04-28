# Configuration Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Telegram `RESTORE` (and `YES` confirmation) command pair that consumes a backup file produced by `BACKUP`, computes an additive merge plan against current UCI, and applies it inside a single `uci commit` transaction with revert-on-failure. v1 covers `/etc/config/gatekeeper` only — main options (except `token`/`chat_id`), blacklist MACs, schedule sections.

**Architecture:** Two new `elif` handlers in `tg_bot.sh`. RESTORE downloads the file via Telegram `getFile`, validates it, parses + diffs against current UCI, builds an apply-plan file in `/tmp`, sends a preview reply, and stores pending state. YES (within 10 minutes, replying to the preview message) executes the plan line-by-line with revert-on-any-failure, then runs post-apply hooks (`scheduler_tick` + `blacklist_macs` nft re-sync). No new daemons, no new runtime files. Pure-text helpers (parser awk, `is_valid_backup`) get dev-only unit tests.

**Tech Stack:** POSIX `/bin/sh` (BusyBox ash), `awk`, `sed`, `grep`, `uci`, `nft`, `curl`, `jq`.

**Spec reference:** `docs/superpowers/specs/2026-04-28-config-restore-design.md`

**Compatibility constraints:**
- All router code must run under BusyBox `ash`. No bashisms.
- `tr 'A-Z' 'a-z'` (ASCII range form), NOT `tr '[:upper:]' '[:lower:]'` — older BusyBox `tr` doesn't interpret POSIX character classes.
- `awk` script must work with BusyBox awk (POSIX features only — field comparison, `print`, `index`, `substr`, `gsub`, `length`, `BEGIN`).
- `sed -E` is fine on BusyBox sed.

---

### Task 1: Unit tests for the restore pure-text helpers

Create a dev-only POSIX-shell test harness for the two pure-text transforms used by the restore feature: the awk parser that turns the backup-file body into tab-separated records, and the `is_valid_backup` predicate that gates restore on file structure. Tests run on macOS or Linux dev machines without a router.

**Files:**
- Create: `tests/test_restore_helpers.sh`

- [ ] **Step 1: Write the test file**

Create `tests/test_restore_helpers.sh` with the following exact content:

```sh
#!/bin/sh
# Dev-only unit tests for restore pure-text transforms.
# Parser awk and is_valid_backup are inlined verbatim into tg_bot.sh.
# When you change one, change both. Run from repo root:
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
                gsub(/^['\''"]/, "", n); gsub(/['\''"]$/, "", n)
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
```

- [ ] **Step 2: Run the test**

```bash
sh /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_restore_helpers.sh
```

Expected output (final line): `PASS=9 FAIL=0`. Exit code 0.

If a test fails, the harness prints `got` vs `want` between `-----` markers. Fix the helper inline. Do NOT modify the parser body once it matches the spec — those bytes will be inlined verbatim into `tg_bot.sh` in Task 2.

- [ ] **Step 3: Set executable bit**

```bash
chmod +x /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_restore_helpers.sh
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper add tests/test_restore_helpers.sh
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper commit -m "Add unit tests for restore parser and is_valid_backup predicate"
```

---

### Task 2: RESTORE + YES handlers, helpers, jq extraction, HELP entry

This is the substantive task. Adds four helper functions, four new jq extraction lines, two new `elif` handlers (RESTORE and YES), and one new HELP line. All in `tg_bot.sh`. Single commit.

**Files:**
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/tg_bot.sh`

- [ ] **Step 1: Add helper functions near `parse_remaining_secs`**

Locate the existing `parse_remaining_secs` function in `tg_bot.sh`. Just **after** its closing `}` (and before the schedule helpers `expand_days` etc.), insert the following block:

```sh
# mac_hostname <mac> — emit best-known device name for a MAC, or empty.
# Mirrors STATUS handler's resolution chain. Used by RESTORE preview.
mac_hostname() {
    m=$(echo "$1" | tr 'A-Z' 'a-z')
    [ -z "$m" ] && return
    h=$(grep -i "$m" "$NAME_MAP" 2>/dev/null | tail -n 1 | cut -d'=' -f2)
    [ -z "$h" ] && h=$(grep -i "$m" /tmp/dhcp.leases 2>/dev/null | awk '{print $4}')
    if [ -z "$h" ] || [ "$h" = "*" ]; then
        h=$(uci show dhcp 2>/dev/null | grep -i "$m" | cut -d. -f2 \
            | xargs -I {} uci -q get dhcp.{}.name 2>/dev/null | head -n 1)
    fi
    [ "$h" = "*" ] && h=""
    echo "$h"
}

# is_valid_backup <path> — returns 0 if path is a Gatekeeper v1 backup,
# 1 otherwise. Five-check validation gate.
is_valid_backup() {
    p="$1"
    [ -f "$p" ] || return 1
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

# restore_parse_to_records <input> <output-tsv>
# Awk parser → tab-separated records:
#   section <type> <name>
#   option <type> <name> <key> <value>
#   list <type> <name> <key> <value>
restore_parse_to_records() {
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
                gsub(/^['\''"]/, "", n); gsub(/['\''"]$/, "", n)
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
    ' "$1" > "$2"
}

# restore_build_plan <records-tsv> <plan-out> <preview-out>
# Reads records, computes the additive merge against current UCI, writes
# the plan file (one uci command per line) and preview text. Returns 0
# if the plan has at least one mutation, 1 if everything is a no-op.
restore_build_plan() {
    records="$1"
    plan="$2"
    preview="$3"

    {
        echo "# Restore plan generated at $(date -Iseconds 2>/dev/null || date)"
    } > "$plan"
    : > "$preview"

    current_bl=$(uci show gatekeeper.blacklist 2>/dev/null \
        | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" \
        | tr 'A-Z' 'a-z' | sort -u)

    sec_type=""
    sec_name=""
    sec_skip=0
    schedule_started=0
    pending_sched_name=""
    pending_sched_mac=""
    pending_sched_days=""
    pending_sched_start=""
    pending_sched_stop=""

    pv_main=""
    pv_bl_added=""
    pv_bl_present=""
    pv_sched_added=""
    pv_sched_present=""

    plan_count=0
    main_count=0
    bl_added_count=0
    bl_present_count=0
    sched_added_count=0
    sched_present_count=0

    flush_pending_schedule() {
        if [ -n "$pending_sched_name" ]; then
            line="\n• \`${pending_sched_name}\` → \`${pending_sched_mac}\`"
            host=$(mac_hostname "$pending_sched_mac")
            [ -n "$host" ] && line="${line} (${host})"
            line="${line}\n  ${pending_sched_days} ${pending_sched_start}–${pending_sched_stop}"
            pv_sched_added="${pv_sched_added}${line}"
            sched_added_count=$((sched_added_count+1))
        fi
        pending_sched_name=""
        pending_sched_mac=""
        pending_sched_days=""
        pending_sched_start=""
        pending_sched_stop=""
    }

    TAB=$(printf '\t')
    while IFS="$TAB" read -r kind type name key val; do
        if [ "$kind" = "section" ]; then
            flush_pending_schedule
            sec_type="$type"
            sec_name="$name"
            sec_skip=0
            schedule_started=0
            if [ "$type" = "schedule" ]; then
                existing=$(uci -q get "gatekeeper.${name}")
                if [ "$existing" = "schedule" ]; then
                    sec_skip=1
                    pv_sched_present="${pv_sched_present}\n• \`${name}\`"
                    sched_present_count=$((sched_present_count+1))
                fi
            fi
            continue
        fi

        [ "$sec_skip" = "1" ] && continue

        case "$sec_type" in
            gatekeeper)
                if [ "$kind" = "option" ]; then
                    case "$key" in
                        token|chat_id) continue ;;
                    esac
                    [ -z "$val" ] && continue
                    cur=$(uci -q get "gatekeeper.main.${key}")
                    if [ "$cur" != "$val" ]; then
                        echo "uci set gatekeeper.main.${key}='${val}'" >> "$plan"
                        plan_count=$((plan_count+1))
                        main_count=$((main_count+1))
                        pv_main="${pv_main}\n• ${key}: \`${cur}\` → \`${val}\`"
                    fi
                fi
                ;;
            blacklist)
                if [ "$kind" = "list" ] && [ "$key" = "mac" ]; then
                    mac_lc=$(echo "$val" | tr 'A-Z' 'a-z')
                    if echo "$current_bl" | grep -qx "$mac_lc"; then
                        pv_bl_present="${pv_bl_present}\n• ${mac_lc}"
                        bl_present_count=$((bl_present_count+1))
                    else
                        echo "uci add_list gatekeeper.blacklist.mac='${mac_lc}'" >> "$plan"
                        plan_count=$((plan_count+1))
                        bl_added_count=$((bl_added_count+1))
                        host=$(mac_hostname "$mac_lc")
                        if [ -n "$host" ]; then
                            pv_bl_added="${pv_bl_added}\n• ${mac_lc} (${host})"
                        else
                            pv_bl_added="${pv_bl_added}\n• ${mac_lc}"
                        fi
                    fi
                fi
                ;;
            schedule)
                if [ "$schedule_started" = "0" ]; then
                    echo "uci set gatekeeper.${sec_name}=schedule" >> "$plan"
                    plan_count=$((plan_count+1))
                    schedule_started=1
                    pending_sched_name="$sec_name"
                fi
                if [ "$kind" = "option" ]; then
                    echo "uci set gatekeeper.${sec_name}.${key}='${val}'" >> "$plan"
                    plan_count=$((plan_count+1))
                    case "$key" in
                        mac)   pending_sched_mac="$val" ;;
                        days)  pending_sched_days="$val" ;;
                        start) pending_sched_start="$val" ;;
                        stop)  pending_sched_stop="$val" ;;
                    esac
                fi
                ;;
        esac
    done < "$records"

    flush_pending_schedule

    {
        if [ "$main_count" -gt 0 ]; then
            printf '*Main options:*%b\n_(token / chat_id never touched.)_\n\n' "$pv_main"
        fi
        if [ "$bl_added_count" -gt 0 ]; then
            printf '*Blacklist additions* (%d new):%b\n\n' "$bl_added_count" "$pv_bl_added"
        fi
        if [ "$bl_present_count" -gt 0 ]; then
            printf '*Blacklist already present* (%d):%b\n\n' "$bl_present_count" "$pv_bl_present"
        fi
        if [ "$sched_added_count" -gt 0 ]; then
            printf '*Schedule additions* (%d new):%b\n\n' "$sched_added_count" "$pv_sched_added"
        fi
        if [ "$sched_present_count" -gt 0 ]; then
            printf '*Schedule already present* (%d):%b\n\n' "$sched_present_count" "$pv_sched_present"
        fi
    } > "$preview"

    [ "$plan_count" -gt 0 ]
}

# State files for the two-step restore flow
RESTORE_FILE="/tmp/restore_file.txt"
RESTORE_PLAN="/tmp/restore_plan.sh"
RESTORE_RECORDS="/tmp/restore_records.tsv"
RESTORE_PREVIEW="/tmp/restore_preview.txt"
RESTORE_PENDING="/tmp/restore_pending"
```

- [ ] **Step 2: Add reply-message jq extractions in the per-message block**

Find the existing per-message extraction block in `tg_bot.sh` (look for `CMD=$(echo "$TEXT" | awk '{print toupper($1)}')` and the surrounding `ARG=...`, `ARG2=...` lines). Just **after** those lines, insert four new extractions:

```sh
        # Reply-context fields used by RESTORE / YES handlers.
        REPLY_DOC_ID=$(echo "$row" | jq -r '.message.reply_to_message.document.file_id // empty')
        REPLY_DOC_NAME=$(echo "$row" | jq -r '.message.reply_to_message.document.file_name // empty')
        REPLY_DOC_SIZE=$(echo "$row" | jq -r '.message.reply_to_message.document.file_size // 0')
        REPLY_TO_MSGID=$(echo "$row" | jq -r '.message.reply_to_message.message_id // empty')
```

Indentation: 8 spaces (matches the surrounding `CMD=…` lines).

- [ ] **Step 3: Add the RESTORE handler at the end of the dispatch chain**

Locate the LAST `elif` of the message-processing dispatch chain in the `while read -r row` loop. After the BACKUP feature, the last handler is now the BACKUP `elif`. Just **after** the BACKUP handler's closing `curl … sendMessage`/`rm -f` block, and **before** the chain-closing `fi`, insert the RESTORE handler:

```sh
        # === RESTORE COMMAND ===
        # Begin a restore from a backup file. Must be sent as a reply to the
        # backup file message in the chat. Produces a preview; user confirms
        # by replying YES to the preview within 10 minutes.
        elif [ "$CMD" = "RESTORE" ]; then
            if [ -z "$REPLY_DOC_ID" ]; then
                MSG="❌ RESTORE must be sent as a reply to a backup file message."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                continue
            fi

            if [ "$REPLY_DOC_SIZE" -gt 1048576 ] 2>/dev/null; then
                MSG="❌ File too large (max 1 MB)."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                continue
            fi

            # Fetch file_path via getFile.
            GF_RESP=$(curl -s --connect-timeout 10 --max-time 30 \
                "https://api.telegram.org/bot$TOKEN/getFile?file_id=$REPLY_DOC_ID")
            FILE_PATH=$(echo "$GF_RESP" | jq -r '.result.file_path // empty')
            if [ -z "$FILE_PATH" ]; then
                MSG="❌ Couldn't fetch file from Telegram."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                logger -t tg_bot "Restore getFile failed: $GF_RESP"
                continue
            fi

            # Download to /tmp.
            rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"
            curl -s --connect-timeout 10 --max-time 30 \
                -o "$RESTORE_FILE" \
                "https://api.telegram.org/file/bot$TOKEN/$FILE_PATH"

            # Validate.
            if ! is_valid_backup "$RESTORE_FILE"; then
                MSG="❌ Backup file invalid (failed validation gate)."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE"
                continue
            fi

            # Parse + diff. restore_build_plan returns 0 if there's at least
            # one mutation, 1 if everything is already present.
            restore_parse_to_records "$RESTORE_FILE" "$RESTORE_RECORDS"
            if ! restore_build_plan "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"; then
                MSG="🔄 Restore preview — nothing to do.\nAll entries from this backup are already present."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"
                continue
            fi

            # Send preview, capture the new message_id, persist pending state.
            PREVIEW_BODY=$(printf '🔄 Restore preview from \`%s\`\n\n' "${REPLY_DOC_NAME:-unknown}")
            PREVIEW_BODY="${PREVIEW_BODY}$(cat "$RESTORE_PREVIEW")"
            PREVIEW_BODY="${PREVIEW_BODY}\nReply YES (within 10 minutes) to apply."
            PREVIEW_PAYLOAD=$(jq -n --arg c "$CHAT_ID" --arg t "$PREVIEW_BODY" \
                '{chat_id: $c, text: $t, parse_mode: "Markdown"}')
            PREVIEW_RESP=$(curl -s $CURL_OPTS -X POST \
                "https://api.telegram.org/bot$TOKEN/sendMessage" \
                -H "Content-Type: application/json" -d "$PREVIEW_PAYLOAD")
            PREVIEW_MSGID=$(echo "$PREVIEW_RESP" | jq -r '.result.message_id // empty')
            if [ -z "$PREVIEW_MSGID" ]; then
                logger -t tg_bot "Restore preview send failed: $PREVIEW_RESP"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW"
                continue
            fi

            echo "$PREVIEW_MSGID $(date +%s)" > "$RESTORE_PENDING"
            logger -t tg_bot "Restore preview sent: msg_id=$PREVIEW_MSGID file=$REPLY_DOC_NAME"
```

Indentation: `elif` at 8 spaces, body at 12 spaces. Match the BACKUP handler immediately above.

Note the use of `jq -n --arg ...` to build the preview JSON payload — this is more robust than shell-string interpolation when the preview contains backticks, asterisks, and other markdown characters that could break a hand-built JSON literal.

- [ ] **Step 4: Add the YES handler immediately after RESTORE**

Just after the RESTORE handler's last `logger -t tg_bot ...` line, before the chain-closing `fi`, insert:

```sh
        # === YES COMMAND ===
        # Confirm a pending restore. Must be sent as a reply to the preview
        # message and within 10 minutes.
        elif [ "$CMD" = "YES" ]; then
            # Strict gating: silently ignore unless this YES matches the pending preview.
            [ -z "$REPLY_TO_MSGID" ] && continue
            [ -f "$RESTORE_PENDING" ] || continue
            STORED_MSGID=$(awk '{print $1}' "$RESTORE_PENDING")
            STORED_EPOCH=$(awk '{print $2}' "$RESTORE_PENDING")
            [ "$REPLY_TO_MSGID" = "$STORED_MSGID" ] || continue

            NOW_EPOCH=$(date +%s)
            if [ $((NOW_EPOCH - STORED_EPOCH)) -gt 600 ]; then
                MSG="⌛ Pending restore expired (>10 min). Reply RESTORE to a backup file again."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
                continue
            fi

            if [ ! -s "$RESTORE_PLAN" ]; then
                MSG="❌ Plan file missing — restart restore by replying RESTORE to a backup file."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_PENDING"
                continue
            fi

            # Two-phase apply.
            FAILED_LINE=""
            while IFS= read -r line; do
                case "$line" in
                    ''|\#*) continue ;;
                esac
                if ! eval "$line"; then
                    FAILED_LINE="$line"
                    break
                fi
            done < "$RESTORE_PLAN"

            if [ -n "$FAILED_LINE" ]; then
                uci revert gatekeeper 2>/dev/null
                MSG="❌ Restore failed at: \`${FAILED_LINE}\`"
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
                continue
            fi

            if ! uci commit gatekeeper; then
                uci revert gatekeeper 2>/dev/null
                MSG="❌ Restore commit failed (UCI error)."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
                continue
            fi

            # Post-apply hooks.
            # Re-sync blacklist_macs nftables set from new UCI state.
            nft flush set inet fw4 blacklist_macs 2>/dev/null
            BLACKLIST_MACS=$(uci show gatekeeper.blacklist 2>/dev/null \
                | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}")
            for mac in $BLACKLIST_MACS; do
                [ -z "$mac" ] && continue
                nft "add element inet fw4 blacklist_macs { $mac }" 2>/dev/null
            done
            # Push any newly-restored active schedules.
            scheduler_tick

            # Compose summary from the plan file.
            N_MAIN=$(grep -c '^uci set gatekeeper\.main\.' "$RESTORE_PLAN")
            N_BL=$(grep -c '^uci add_list gatekeeper\.blacklist\.mac=' "$RESTORE_PLAN")
            N_SCHED=$(grep -cE '^uci set gatekeeper\.[^.]+=schedule$' "$RESTORE_PLAN")
            N_TOTAL=$((N_MAIN + N_BL + N_SCHED))

            MSG="✅ Restore complete: ${N_TOTAL} change(s) applied.\n"
            [ "$N_MAIN"  -gt 0 ] && MSG="${MSG}• ${N_MAIN} main option(s) updated\n"
            [ "$N_BL"    -gt 0 ] && MSG="${MSG}• ${N_BL} blacklist MAC(s) added\n"
            [ "$N_SCHED" -gt 0 ] && MSG="${MSG}• ${N_SCHED} schedule(s) added\n"
            curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                 -H "Content-Type: application/json" \
                 -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"

            echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - restore-applied-${N_TOTAL}" >> "$LOG_FILE"
            logger -t tg_bot "Restore applied: $N_TOTAL changes (main=$N_MAIN bl=$N_BL sched=$N_SCHED)"

            rm -f "$RESTORE_FILE" "$RESTORE_RECORDS" "$RESTORE_PLAN" "$RESTORE_PREVIEW" "$RESTORE_PENDING"
```

- [ ] **Step 5: Add the HELP entry**

In `tg_bot.sh`, locate the HELP handler. Find the existing Maintenance subsection lines (after `*Maintenance:*\n`). Just **after** the line containing `\`BACKUP [NOSECRETS]\``, and **before** any subsequent line, insert:

```sh
            MSG="${MSG}\`RESTORE\` (reply to a backup file) - Restore config from a backup; \`YES\` to confirm\n"
```

- [ ] **Step 6: Run a syntax check**

```bash
sh -n /Users/nmehta/Documents/code/github/gale-gatekeeper/tg_bot.sh
```

Expected: no output, exit code 0.

- [ ] **Step 7: Re-run the unit tests (sanity)**

```bash
sh /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_restore_helpers.sh
```

Expected: `PASS=9 FAIL=0`. (Independent of `tg_bot.sh`; this is a sanity check.)

- [ ] **Step 8: Commit**

```bash
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper add tg_bot.sh
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper commit -m "Add RESTORE/YES handlers and HELP entry for config restore"
```

---

### Task 3: Repository documentation updates

Document the new commands in the project-level docs.

**Files:**
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/CLAUDE.md`
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/README.md`
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/QUICK_REFERENCE.md`

- [ ] **Step 1: Update `CLAUDE.md`**

Locate the `## Telegram Bot Commands` section. Inside the **System:** subsection, immediately after the `BACKUP` bullet (added by the previous backup feature), append:

```markdown
- `RESTORE` (as a reply to a backup file message) — Begin restoring config from a backup. The bot validates the file, computes an additive merge plan against current UCI (skip duplicates by MAC for blacklist, by section name for schedules; never touch `token`/`chat_id`), and replies with a preview. Reply `YES` to the preview within 10 minutes to apply. Restore is read-only against UCI until you confirm; failures during apply roll back via `uci revert`.
```

- [ ] **Step 2: Update `README.md`**

Read `README.md`. Find the System Control / Maintenance command table where the BACKUP row lives. Add a row matching the existing two-column `| Command | Description |` style:

```markdown
| `RESTORE` (reply to backup file) / `YES` | Restore config from a backup file (additive merge; reply YES within 10 min to confirm) |
```

- [ ] **Step 3: Update `QUICK_REFERENCE.md`**

Add concise entries to the cheat-sheet table:

```markdown
| `RESTORE` (reply to file) | Begin restore from backup file |
| `YES` (reply to preview) | Confirm pending restore |
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper add CLAUDE.md README.md QUICK_REFERENCE.md
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper commit -m "Document RESTORE/YES commands in CLAUDE.md, README, and QUICK_REFERENCE"
```

---

### Task 4: On-router smoke test (manual verification)

Deploy to the router and walk through the spec's testing scenarios (§8). This is the final verification gate.

**Files:**
- None (test only)

- [ ] **Step 1: Run pure-shell unit tests on dev machine first**

```bash
sh /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_restore_helpers.sh
```

Expected: `PASS=9 FAIL=0`. Exit 0.

- [ ] **Step 2: Deploy to the router**

```bash
./deploy.sh 192.168.1.1 --no-config
```

Watch for SCP errors. Confirm services restart cleanly.

- [ ] **Step 3: Tail the log in another terminal**

```bash
ssh root@192.168.1.1 'logread -f | grep -E "gatekeeper|tg_bot"'
```

- [ ] **Step 4: Sanity — HELP includes RESTORE**

Send `HELP`. Verify the Maintenance subsection lists `RESTORE` (and `BACKUP`).

- [ ] **Step 5: No-op restore (current state already matches a fresh BACKUP)**

Send `BACKUP` to produce a current snapshot. Reply `RESTORE` to that file. Expected reply: `🔄 Restore preview — nothing to do. All entries from this backup are already present.` Verify `/tmp` is clean:

```bash
ssh root@192.168.1.1 'ls /tmp/restore_* 2>/dev/null | wc -l'
```

Expected: `0`.

- [ ] **Step 6: Add-back a missing blacklist MAC**

`BLREMOVE` one of the MACs from the most recent backup. Reply `RESTORE` to that backup file. Verify the preview shows that MAC under "Blacklist additions". Reply `YES` (replying to the preview message). Verify `BLSTATUS` shows the MAC restored. Verify `/tmp/restore_*` are deleted.

- [ ] **Step 7: Add-back a missing schedule**

`SCHEDREMOVE livingroomtv` (or whichever schedule is in your most recent backup). Reply `RESTORE` to that file. Verify the preview shows the schedule under "Schedule additions". Reply `YES`. Verify `SCHEDLIST` shows the schedule restored.

- [ ] **Step 8: Update a main option**

Send `BLOFF` (turning off blacklist mode). Reply `RESTORE` to the backup (which has `blacklist_mode='1'`). Verify the preview shows `blacklist_mode: '0' → '1'` under "Main options". Reply `YES`. Verify `BLSTATUS` shows blacklist mode is back ON.

- [ ] **Step 9: NOSECRETS backup**

Send `BACKUP NOSECRETS`. Reply `RESTORE` to the resulting file. Verify the preview does NOT include any change to `token` or `chat_id` (they're blank in the file, so the merge engine skips them). After `YES`, verify `uci -q get gatekeeper.main.token` is unchanged.

- [ ] **Step 10: Reject — RESTORE not as a reply**

Send `RESTORE` (as a plain message, not a reply). Expected: `❌ RESTORE must be sent as a reply to a backup file message.`

- [ ] **Step 11: Reject — RESTORE replying to a non-backup file**

Upload a screenshot or any non-backup file to the chat. Reply `RESTORE` to it. Expected: `❌ Backup file invalid (failed validation gate).` Verify `/tmp/restore_*` are absent afterward.

- [ ] **Step 12: Expiry**

Send `RESTORE` to a backup file (which produces a preview). Wait **11 minutes**. Reply `YES` to the preview. Expected: `⌛ Pending restore expired (>10 min). Reply RESTORE to a backup file again.` `/tmp/restore_*` should be gone.

- [ ] **Step 13: Concurrent restores — last-one-wins**

Send `RESTORE` to backup file A. While the preview is pending, send `RESTORE` to a different backup file B. Reply `YES` to the FIRST preview (file A's). Expected: silently ignored — the YES handler's message-id check fails because pending state now references file B's preview message.

- [ ] **Step 14: Concurrent / spam YES**

Send a casual `YES` (not as a reply) in the chat. Expected: bot ignores silently.

Send `YES` as a reply to some unrelated message in the chat. Expected: bot ignores silently.

- [ ] **Step 15: Cleanup verification (success path)**

After every successful restore in the previous steps, verify:

```bash
ssh root@192.168.1.1 'ls /tmp/restore_* 2>/dev/null | wc -l'
```

Expected: `0`.

- [ ] **Step 16: Cleanup verification (failure path)**

Manually corrupt the plan file mid-process (advanced; only if you want to exercise the failure path):

```bash
ssh root@192.168.1.1 'echo "uci nonsense" >> /tmp/restore_plan.sh'
```

Then send `YES` (replying to the preview). Expected: `❌ Restore failed at: \`uci nonsense\`` reply, `/tmp/restore_*` gone, no UCI commit happened (verify via `uci show gatekeeper`).

- [ ] **Step 17: If anything fails**

Do **NOT** mark the implementation complete. Open a fresh debugging session, fix the underlying issue, redeploy with `./deploy.sh`, re-run the failing step. Use the in-loop log tail from Step 3 for live diagnosis.

Once all steps pass, the feature is ready to be tagged or merged.

---

## Self-Review

**1. Spec coverage:**
- §1 Summary: `RESTORE` + `YES` two-step flow with preview + 10-min expiry — encoded throughout Tasks 1–2.
- §2 Goals/Non-Goals: gatekeeper-only scope (Task 2 step 1 awk skips dhcp), additive merge (Task 2 step 1 merge engine), token/chat_id never touched (Task 2 step 1 case branch), atomic apply with revert (Task 2 step 4), post-apply hooks (Task 2 step 4), no new runtime files. All present.
- §3 Decisions: all enforced (see Task 2 step 1 helper bodies and step 3/4 handlers).
- §4 Architecture: file inventory matches Tasks 2 + 3.
- §5 Parser & merge engine: full code in Task 2 step 1.
- §6 Telegram flow & state: full code in Task 2 steps 3–4.
- §7 Edge cases: handled in Task 2's RESTORE/YES flows; covered manually in Task 4.
- §8 Testing: pure-text unit tests in Task 1; on-router smoke in Task 4.
- §9 Out-of-scope: explicitly excluded from all tasks.

No spec gaps identified.

**2. Placeholder scan:** No "TBD" / "TODO" / "implement later" / "fill in" tokens. Every code step has complete, runnable code.

**3. Type / name consistency:**
- `RESTORE_FILE`, `RESTORE_PLAN`, `RESTORE_RECORDS`, `RESTORE_PREVIEW`, `RESTORE_PENDING` — defined in Task 2 step 1, used consistently in Task 2 steps 3–4.
- `REPLY_DOC_ID`, `REPLY_DOC_NAME`, `REPLY_DOC_SIZE`, `REPLY_TO_MSGID` — extracted in Task 2 step 2, used in Task 2 steps 3–4.
- Helper function names (`mac_hostname`, `is_valid_backup`, `restore_parse_to_records`, `restore_build_plan`) consistent across steps.
- `flush_pending_schedule` is an inner function defined inside `restore_build_plan` and used only there. POSIX shells allow this and the inner function correctly accesses the outer's variables.
- The plan-file format (`uci set gatekeeper.…`, `uci add_list gatekeeper.blacklist.mac=…`, `uci set gatekeeper.<name>=schedule`) is consistent across the merge engine (Task 2 step 1) and the summary-counting in YES (Task 2 step 4).
