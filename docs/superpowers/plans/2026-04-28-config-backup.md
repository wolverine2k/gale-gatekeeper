# Configuration Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Telegram `BACKUP` (and `BACKUP NOSECRETS`) command that produces a plain-text UCI snapshot of `/etc/config/gatekeeper` plus the static DHCP host entries from `/etc/config/dhcp`, uploads it via Telegram's `sendDocument`, and deletes the temp file.

**Architecture:** One new `elif` handler in `tg_bot.sh`, no new daemons, no new runtime files. Read-only: reads two UCI configs, writes a temp file in `/tmp`, uploads via curl multipart, deletes the file. Pure-logic helpers (host extractor + secret stripper) get dev-only unit tests in `tests/`.

**Tech Stack:** POSIX `/bin/sh` (BusyBox ash), `uci`, `awk`, `sed -E`, `curl -F`, `jq`.

**Spec reference:** `docs/superpowers/specs/2026-04-28-config-backup-design.md`

**Compatibility constraints:**
- All router code must run under BusyBox `ash`. No bashisms.
- `awk` script must work with BusyBox awk (POSIX features only — field comparison, `print`, BEGIN, no `gensub`/`patsplit`).
- `sed -E` is fine on BusyBox sed (extended regex supported).
- `curl -F` (multipart) is supported by the curl shipped with OpenWrt.

---

### Task 1: Unit tests for the backup pure-text helpers

Create a dev-only POSIX-shell test harness for the two pure-text transforms used by the backup feature: the `awk` extractor that pulls `config host` blocks out of `/etc/config/dhcp`, and the `sed -E` substitution that blanks `token` / `chat_id` values. Tests run on macOS or Linux dev machines without a router.

**Files:**
- Create: `tests/test_backup_helpers.sh`

- [ ] **Step 1: Write the test file**

Create `tests/test_backup_helpers.sh`:

```sh
#!/bin/sh
# Dev-only unit tests for backup pure-text transforms.
# These transforms are inlined verbatim into the BACKUP handler in tg_bot.sh.
# When you change one, change both. Run from repo root:
#   sh tests/test_backup_helpers.sh

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

# --- Test 1: config host extractor ---------------------------------------
# The awk script in tg_bot.sh extracts only `config host` blocks from a
# /etc/config/dhcp-style input.

extract_hosts() {
    awk '/^config[[:space:]]/ { in_host = ($2 == "host") } in_host { print }'
}

DHCP_FIXTURE='config dnsmasq
	option domainneeded '\''1'\''
	option boguspriv '\''1'\''

config dhcp '\''lan'\''
	option interface '\''lan'\''

config host '\''kids'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option ip '\''192.168.1.50'\''
	option name '\''kids-tablet'\''

config host
	option mac '\''11:22:33:44:55:66'\''
	option ip '\''192.168.1.51'\''

config odhcpd '\''odhcpd'\''
	option maindhcp '\''0'\'''

EXPECTED_HOSTS='config host '\''kids'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option ip '\''192.168.1.50'\''
	option name '\''kids-tablet'\''

config host
	option mac '\''11:22:33:44:55:66'\''
	option ip '\''192.168.1.51'\'''

GOT=$(printf '%s\n' "$DHCP_FIXTURE" | extract_hosts)
assert_eq "extract_hosts: skips dnsmasq+dhcp+odhcpd, keeps both host blocks" \
    "$GOT" "$EXPECTED_HOSTS"

# Empty input -> empty output.
GOT=$(printf '' | extract_hosts)
assert_eq "extract_hosts: empty input" "$GOT" ""

# Input with no host blocks -> empty output.
NO_HOSTS='config dnsmasq
	option boguspriv '\''1'\''

config dhcp '\''lan'\''
	option interface '\''lan'\'''
GOT=$(printf '%s\n' "$NO_HOSTS" | extract_hosts)
assert_eq "extract_hosts: input with no host blocks" "$GOT" ""

# --- Test 2: secret stripper ---------------------------------------------
# The sed -E script in tg_bot.sh blanks the value of `option token` and
# `option chat_id` while leaving everything else untouched.

strip_secrets() {
    sed -E "s/^([[:space:]]*option (token|chat_id) ).*/\1''/"
}

GK_FIXTURE='package gatekeeper

config gatekeeper '\''main'\''
	option token '\''secret123:abcdef'\''
	option chat_id '\''987654321'\''
	option blacklist_mode '\''0'\''
	option disabled '\''0'\''

config schedule '\''sched_kids_eve'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option enabled '\''1'\'''

EXPECTED_STRIPPED='package gatekeeper

config gatekeeper '\''main'\''
	option token '\'\''
	option chat_id '\'\''
	option blacklist_mode '\''0'\''
	option disabled '\''0'\''

config schedule '\''sched_kids_eve'\''
	option mac '\''aa:bb:cc:dd:ee:ff'\''
	option enabled '\''1'\'''

GOT=$(printf '%s\n' "$GK_FIXTURE" | strip_secrets)
assert_eq "strip_secrets: blanks token+chat_id, preserves others" \
    "$GOT" "$EXPECTED_STRIPPED"

# A line whose option name *contains* token/chat_id but isn't exactly
# "token" / "chat_id" must NOT be matched (e.g., "stoken_alt").
NEAR_FIXTURE='	option stoken_alt '\''nope'\''
	option chat_id_alt '\''also_nope'\''
	option token '\''real'\'''
EXPECTED_NEAR='	option stoken_alt '\''nope'\''
	option chat_id_alt '\''also_nope'\''
	option token '\'\'''
GOT=$(printf '%s\n' "$NEAR_FIXTURE" | strip_secrets)
assert_eq "strip_secrets: only matches exact token/chat_id keys" \
    "$GOT" "$EXPECTED_NEAR"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the test**

```bash
sh /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_backup_helpers.sh
```

Expected output (final line): `PASS=5 FAIL=0`. Exit code 0.

If a test fails, the harness prints the actual vs. expected output between markers — fix the helper inline and re-run.

- [ ] **Step 3: Set executable bit and verify**

```bash
chmod +x /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_backup_helpers.sh
ls -la /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_backup_helpers.sh
```

Expected: `-rwxr-xr-x` (or similar with the `x` bit set).

- [ ] **Step 4: Commit**

```bash
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper add tests/test_backup_helpers.sh
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper commit -m "Add unit tests for backup host-extractor and secret-stripper"
```

---

### Task 2: BACKUP command handler in `tg_bot.sh` + HELP update

Add the `BACKUP` (and `BACKUP NOSECRETS`) handler at the end of the `tg_bot.sh` dispatch chain, plus add a one-liner to the existing `HELP` message under the Maintenance subsection. These two changes ship together so that introducing a new command doesn't leave HELP stale.

**Files:**
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/tg_bot.sh`

- [ ] **Step 1: Add the BACKUP handler at the end of the dispatch chain**

In `tg_bot.sh`, locate the last `elif` of the message-processing dispatch chain inside the `while read -r row` loop. Currently the last handler is `SCHEDNOTIFY` (added by the scheduled-approval feature; it ends with the standard `curl … sendMessage …` line followed by an empty line, then the chain-closing `fi`).

Just **after** the SCHEDNOTIFY handler's closing `curl … sendMessage …` line, and **before** the chain-closing `fi`, insert this new `elif` block:

```sh
        # === BACKUP COMMAND ===
        # Generate a UCI-text backup of gatekeeper config + static DHCP hosts,
        # send it to Telegram as a document, delete the temp file.
        # Usage: BACKUP            - include token/chat_id
        #        BACKUP NOSECRETS  - blank out token/chat_id
        elif [ "$CMD" = "BACKUP" ]; then
            INCLUDE_SECRETS=1
            if [ -n "$ARG" ]; then
                if [ "$(echo "$ARG" | tr 'a-z' 'A-Z')" = "NOSECRETS" ]; then
                    INCLUDE_SECRETS=0
                else
                    MSG="❌ Usage: BACKUP [NOSECRETS]"
                    curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                         -H "Content-Type: application/json" \
                         -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                    continue
                fi
            fi

            BK_HOST=$(uci -q get system.@system[0].hostname \
                      || cat /proc/sys/kernel/hostname 2>/dev/null \
                      || echo openwrt)
            STAMP=$(date +%Y%m%d-%H%M)
            BACKUP_FILE="/tmp/gatekeeper-backup-${BK_HOST}-${STAMP}-$$.txt"
            if [ "$INCLUDE_SECRETS" = "1" ]; then
                SECRETS_LABEL="yes"
            else
                SECRETS_LABEL="no"
            fi

            # Build the file
            {
                echo "# Gatekeeper backup"
                echo "# Generated:        $(date -Iseconds 2>/dev/null || date)"
                echo "# Hostname:         $BK_HOST"
                echo "# Schema:           v1"
                echo "# Includes secrets: $SECRETS_LABEL"
                echo "# Source files:"
                echo "#   /etc/config/gatekeeper"
                echo "#   /etc/config/dhcp (host entries only)"
                echo ""
                echo "# === /etc/config/gatekeeper ==="
                if [ "$INCLUDE_SECRETS" = "1" ]; then
                    uci export gatekeeper
                else
                    uci export gatekeeper \
                        | sed -E "s/^([[:space:]]*option (token|chat_id) ).*/\1''/"
                fi
                echo ""
                echo "# === /etc/config/dhcp (host entries only) ==="
                awk '/^config[[:space:]]/ { in_host = ($2 == "host") } in_host { print }' \
                    /etc/config/dhcp 2>/dev/null
            } > "$BACKUP_FILE"

            # Multipart upload via sendDocument
            CAPTION="Gatekeeper backup from ${BK_HOST} (secrets: ${SECRETS_LABEL})"
            UPLOAD_RESP=$(curl -s --connect-timeout 10 --max-time 60 \
                -F "chat_id=$CHAT_ID" \
                -F "document=@${BACKUP_FILE}" \
                -F "caption=${CAPTION}" \
                "https://api.telegram.org/bot$TOKEN/sendDocument")

            if echo "$UPLOAD_RESP" | jq -e '.ok' >/dev/null 2>&1; then
                logger -t tg_bot "Backup sent: ${BACKUP_FILE} (secrets=${SECRETS_LABEL})"
                echo "$(date '+%Y-%m-%dT%H:%M:%S') - - - backup-sent-${SECRETS_LABEL}" >> "$LOG_FILE"
            else
                MSG="❌ Backup upload failed. Check logs."
                curl -s $CURL_OPTS -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
                     -H "Content-Type: application/json" \
                     -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                logger -t tg_bot "Backup upload failed: $UPLOAD_RESP"
            fi

            rm -f "$BACKUP_FILE"
```

Indentation: `elif` at 8 spaces, body at 12 spaces (matches every other handler in the file).

- [ ] **Step 2: Add a HELP line under the Maintenance subsection**

In `tg_bot.sh`, locate the HELP handler (`elif [ "$CMD" = "HELP" ]`). Inside the message-building block, find the existing Maintenance subsection (the line `MSG="${MSG}*Maintenance:*\n"` and the lines under it). Just **after** the existing line:

```sh
            MSG="${MSG}\`CLEAR\` - Clear logs and name cache\n"
```

Insert one new line:

```sh
            MSG="${MSG}\`BACKUP [NOSECRETS]\` - Send config backup as a Telegram file\n"
```

(The exact preceding-line text may vary slightly depending on the order of Maintenance entries in the current file; insert the new line such that BACKUP appears alongside the other Maintenance commands and before any `\n` separator that ends the subsection.)

- [ ] **Step 3: Run a syntax check**

```bash
sh -n /Users/nmehta/Documents/code/github/gale-gatekeeper/tg_bot.sh
```

Expected: no output, exit code 0. If you see a syntax error, re-check the inserted blocks for unbalanced quotes, braces, or here-doc issues.

- [ ] **Step 4: Verify the helper transforms still pass against the new file**

The unit test file is independent of `tg_bot.sh` (it inlines its own copies for test isolation), so this is a sanity check rather than a sync check:

```bash
sh /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_backup_helpers.sh
```

Expected: `PASS=5 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper add tg_bot.sh
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper commit -m "Add BACKUP command and HELP entry for Telegram config backup"
```

---

### Task 3: Repository documentation updates

Document the new command in the project-level docs.

**Files:**
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/CLAUDE.md`
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/README.md`
- Modify: `/Users/nmehta/Documents/code/github/gale-gatekeeper/QUICK_REFERENCE.md`

- [ ] **Step 1: Update `CLAUDE.md` Telegram Bot Commands section**

In `CLAUDE.md`, locate the `## Telegram Bot Commands` section. Inside the **System:** block (the one that lists ENABLE/DISABLE/SYNC/etc.), append:

```markdown
- `BACKUP` / `BACKUP NOSECRETS` — Send a plain-text UCI snapshot of `/etc/config/gatekeeper` plus the static DHCP host entries from `/etc/config/dhcp` to the configured chat as a Telegram document. `NOSECRETS` blanks the bot token and chat id before upload (default includes them). The temp file in `/tmp` is deleted after upload regardless of success or failure.
```

- [ ] **Step 2: Update `README.md`**

Read `README.md`. Find the bot-commands area (look for the same `Schedules` table you added in the scheduled-approval feature; backup belongs alongside the System / Maintenance commands). Add a row matching the existing two-column `| Command | Description |` table style:

```markdown
| `BACKUP` / `BACKUP NOSECRETS` | Send a config backup file (UCI text) to the chat. `NOSECRETS` blanks token/chat_id |
```

If `README.md` doesn't have a System or Maintenance command table, add the row to the most relevant existing table; match the file's voice and style.

- [ ] **Step 3: Update `QUICK_REFERENCE.md`**

In the Most Used Telegram Commands table (or whatever the file's main command-cheat-sheet is called), append:

```markdown
| `BACKUP [NOSECRETS]` | Send config backup as Telegram file |
```

Match the existing column order/style.

- [ ] **Step 4: Commit**

```bash
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper add CLAUDE.md README.md QUICK_REFERENCE.md
git -C /Users/nmehta/Documents/code/github/gale-gatekeeper commit -m "Document BACKUP command in CLAUDE.md, README, and QUICK_REFERENCE"
```

---

### Task 4: On-router smoke test (manual verification)

Deploy to the router and walk through the spec's testing scenarios (§8). This is the final verification gate.

**Files:**
- None (test only)

- [ ] **Step 1: Run pure-shell unit tests on dev machine first**

```bash
sh /Users/nmehta/Documents/code/github/gale-gatekeeper/tests/test_backup_helpers.sh
```

Expected: `PASS=5 FAIL=0`. Exit 0. Fix any failure before deploying.

- [ ] **Step 2: Deploy to the router**

```bash
./deploy.sh 192.168.1.1 --no-config
```

(Use `--no-config` to preserve any existing UCI customizations.) Watch for SCP errors. Confirm services restart cleanly.

- [ ] **Step 3: Tail the log in another terminal**

```bash
ssh root@192.168.1.1 'logread -f | grep -E "gatekeeper|tg_bot"'
```

Leave running for the rest of the test sequence.

- [ ] **Step 4: Sanity check — HELP**

Send to the bot via Telegram:
```
HELP
```

Expected: HELP message includes `BACKUP [NOSECRETS]` line under the Maintenance subsection.

- [ ] **Step 5: Default backup (with secrets)**

Send:
```
BACKUP
```

Expected within ~5 seconds:
- A document arrives in the chat with caption `Gatekeeper backup from <hostname> (secrets: yes)`.
- Filename matches `gatekeeper-backup-<hostname>-YYYYMMDD-HHMM-<pid>.txt`.

Open the file and verify:
- Header shows `Includes secrets: yes`.
- `# === /etc/config/gatekeeper ===` section contains `option token 'XXXX:YYYY'` (real token), `option chat_id '<chatid>'` (real id), plus `blacklist_mode`, `disabled`, `schedule_notify`, the blacklist section, and any active schedule sections.
- `# === /etc/config/dhcp (host entries only) ===` section contains your real `config host` blocks (and only those — no `config dnsmasq`, `config dhcp`, etc.).

- [ ] **Step 6: NOSECRETS variant**

Send:
```
BACKUP NOSECRETS
```

Expected:
- Document caption `Gatekeeper backup from <hostname> (secrets: no)`.
- Header shows `Includes secrets: no`.
- File lines show `option token ''` and `option chat_id ''` (empty quoted values).
- Everything else (blacklist_mode, schedules, host entries) identical to the previous backup.

Also try lowercase / mixed-case spelling:
```
BACKUP nosecrets
BACKUP NoSecrets
```

Both should produce the secrets-stripped variant.

- [ ] **Step 7: Bad arg rejection**

Send:
```
BACKUP foo
```

Expected: `❌ Usage: BACKUP [NOSECRETS]` reply. No file generated; no temp file in `/tmp`.

Verify:
```bash
ssh root@192.168.1.1 'ls /tmp/gatekeeper-backup-*.txt 2>/dev/null | wc -l'
```

Expected output: `0`.

- [ ] **Step 8: Cleanup verification (success path)**

Send `BACKUP` again. Once the file arrives in Telegram, immediately:

```bash
ssh root@192.168.1.1 'ls /tmp/gatekeeper-backup-*.txt 2>/dev/null | wc -l'
```

Expected output: `0` (file deleted after upload).

- [ ] **Step 9: Cleanup verification (failure path)**

Temporarily disconnect the router's WAN (or block port 443 to api.telegram.org) so the upload will fail. Send `BACKUP`. Expected:
- Telegram receives `❌ Backup upload failed. Check logs.` (after WAN comes back, since the bot needs the API to send the error reply).
- After the error reply, verify:

```bash
ssh root@192.168.1.1 'ls /tmp/gatekeeper-backup-*.txt 2>/dev/null | wc -l'
```

Expected output: `0` (temp file removed even on failure).

Restore the WAN.

- [ ] **Step 10: Concurrent backups**

Send 5 `BACKUP` commands as fast as you can type. Expected: 5 distinct documents arrive in the chat, with timestamps within the same minute but different PIDs in the filename, and `/tmp` clean afterwards.

```bash
ssh root@192.168.1.1 'ls /tmp/gatekeeper-backup-*.txt 2>/dev/null | wc -l'
```

Expected output: `0`.

- [ ] **Step 11: If anything fails**

Do **NOT** mark the implementation complete. Open a fresh debugging session per the project's debugging conventions, fix the underlying issue, redeploy with `./deploy.sh`, and re-run the failing step. Use the in-loop log tail from Step 3 for live diagnosis.

Once all steps pass, the feature is ready to be tagged or merged.

---

## Self-Review

**1. Spec coverage:**
- §1 Summary, §2 Goals/Non-Goals: encoded throughout the plan; non-goals (restore, scheduled backups, encryption, tar.gz/JSON) explicitly excluded.
- §3 Decisions: all decisions enforced (Q1 backup-only — no RESTORE handler; Q2a host entries only — awk filter on `$2 == "host"`; Q2b secrets included by default — `INCLUDE_SECRETS=1`; Q3 plain-text format — file body composition in Task 2; Q4a manual only — single Telegram command; Q4b delete after upload — `rm -f` at end of handler regardless of upload result; Impl inline — only `tg_bot.sh` modified).
- §4 Architecture & Data Model: file-by-file changes match Task 2 + Task 3.
- §5 File format: header + section markers + uci export + awk extraction + sed strip — all in Task 2 Step 1.
- §6 Command handler: matches Task 2 Step 1 verbatim.
- §7 Edge cases: covered by error handling in Task 2 (jq -e, rm -f, awk 2>/dev/null, sed -E, NOSECRETS case-insensitive parse, PID suffix).
- §8 Testing: pure-text unit tests in Task 1; on-router manual tests in Task 4.
- §9 Out-of-scope: explicitly excluded from all tasks.

No spec gaps identified.

**2. Placeholder scan:** No "TBD" / "TODO" / "implement later" / "fill in" tokens. All code blocks contain complete, runnable code.

**3. Type / name consistency:**
- `INCLUDE_SECRETS`, `BK_HOST`, `STAMP`, `BACKUP_FILE`, `SECRETS_LABEL`, `CAPTION`, `UPLOAD_RESP` are introduced in Task 2 and not referenced in any later task.
- Test helper names (`extract_hosts`, `strip_secrets`, `assert_eq`) live entirely inside `tests/test_backup_helpers.sh`.
- Filename format `gatekeeper-backup-<hostname>-YYYYMMDD-HHMM-<pid>.txt` is consistent across spec, plan, code blocks, and Task 4 verification commands.
