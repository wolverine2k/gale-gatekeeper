# Configuration Backup — Design Spec

**Date:** 2026-04-28
**Author:** Naresh Mehta
**Status:** Approved (pending implementation plan)

## 1. Summary

Add a `BACKUP` Telegram command that produces a plain-text snapshot of the
Gatekeeper configuration plus the static DHCP host entries, and uploads the
file to the configured chat via Telegram's `sendDocument` API. The temporary
file is deleted immediately after upload; Telegram chat history is the
archive.

A `BACKUP NOSECRETS` variant blanks out the bot token and chat id before
upload for cases where the file may be shared more broadly.

## 2. Goals & Non-Goals

### Goals
- Single Telegram command produces a complete, restore-grade backup.
- Backup includes:
  - Full `/etc/config/gatekeeper` (main, blacklist, all schedule sections).
  - `config host` entries from `/etc/config/dhcp` (static DHCP leases only,
    not the surrounding dnsmasq settings).
- Optional secret-stripping (`BACKUP NOSECRETS`) for sharing the file with
  anyone who isn't already trusted with the bot itself.
- Plain-text UCI format — human-readable, diffable, restorable via
  `uci import` or hand editing.
- Read-only operation — never writes UCI, nftables, or firewall.
- No new runtime files. No new daemons. No new dependencies.

### Non-Goals (deferred / YAGNI)
- **Restore** (`RESTORE` command) — separate spec/plan cycle. Restore has
  significantly more failure modes (lockout via wrong token, atomicity
  across multiple UCI configs, validation, rollback) and warrants its own
  design.
- **Scheduled backups** (cron, on-change) — manual is sufficient for a
  single-operator bot.
- **Persistent backup history on the router** — Telegram chat history is
  the archive; `/tmp` is the right scratch area.
- **Encryption / passphrase** — bot's CHAT_ID restriction is the trust
  boundary; secrets already flow over the same channel.
- **`.tar.gz` archive format / JSON** — plain text is simpler, more
  inspectable, and round-trips through `uci import`.
- **Backing up `gatekeeper.nft`, init scripts, or any package-shipped
  files** — those are re-installable from the package; user config is the
  only thing worth backing up.

## 3. Decisions Made

| ID | Decision |
|----|----------|
| **Q1** | v1 = backup only. Restore is a future spec. |
| **Q2a** | The dhcp portion of the backup is **just the `config host` blocks**, not the entire `/etc/config/dhcp`. |
| **Q2b** | `BACKUP` includes secrets (`token`, `chat_id`) by default. `BACKUP NOSECRETS` blanks them. |
| **Q3** | File format = plain-text UCI dump with header + section markers. Single file. |
| **Q4a** | Manual trigger only via the `BACKUP` Telegram command. No cron, no on-change. |
| **Q4b** | The temp file is deleted from `/tmp` immediately after upload (success or failure). |
| **Impl** | Inline in `tg_bot.sh` as a new `elif` handler. No new runtime files. |

## 4. Architecture & Data Model

### 4.1 File-by-file change inventory

| File | Change |
|------|--------|
| `tg_bot.sh` | One new `elif [ "$CMD" = "BACKUP" ]` handler at the end of the dispatch chain. One new line in the HELP message (under the existing **Maintenance** subsection). |
| `tests/test_schedule_helpers.sh` *or* `tests/test_backup_helpers.sh` | Two new pure-text unit tests (host extraction + secret stripping). |
| `CLAUDE.md` | Add `BACKUP` to the Maintenance command list. |
| `README.md`, `QUICK_REFERENCE.md` | One-line entries. |
| `gatekeeper.sh`, `gatekeeper.nft`, `opkg/etc/config/gatekeeper`, init scripts | **No changes.** The feature is read-only and lives entirely in the bot. |

### 4.2 No new state or persistent files

The temp file `/tmp/gatekeeper-backup-<hostname>-<YYYYMMDD-HHMM>-<pid>.txt`
exists for the duration of one backup operation. It is removed in both the
success and failure paths.

### 4.3 Telegram API endpoint

`https://api.telegram.org/bot<TOKEN>/sendDocument` with multipart-form
arguments:
- `chat_id=<CHAT_ID>`
- `document=@<temp-file-path>`
- `caption="Gatekeeper backup from <hostname> (secrets: yes|no)"`

The 50 MB Telegram-document limit is far above any realistic backup size
(< 10 KB even for heavy usage).

## 5. Backup File Format

### 5.1 Filename

`gatekeeper-backup-<hostname>-<YYYYMMDD-HHMM>-<pid>.txt`

`<hostname>` is from `uci -q get system.@system[0].hostname`, falling back
to `/proc/sys/kernel/hostname`, then `openwrt`. Timestamp is router local
time. PID is `$$` (the bot's process id) — appended to disambiguate
concurrent backups within the same minute.

### 5.2 Body structure

```
# Gatekeeper backup
# Generated:        2026-04-28T14:32:11+02:00
# Hostname:         openwrt
# Schema:           v1
# Includes secrets: yes
# Source files:
#   /etc/config/gatekeeper
#   /etc/config/dhcp (host entries only)

# === /etc/config/gatekeeper ===
package gatekeeper

config gatekeeper 'main'
    option token 'XXXXX:YYYYYYYYYY'
    option chat_id '123456789'
    option blacklist_mode '0'
    option disabled '0'
    option schedule_notify '0'

config blacklist 'blacklist'
    list mac 'aa:bb:cc:dd:ee:ff'

config schedule 'sched_kids_eve'
    option mac 'aa:bb:cc:dd:ee:ff'
    option days 'weekdays'
    option start '16:00'
    option stop '20:00'
    option enabled '1'

# === /etc/config/dhcp (host entries only) ===
config host
    option mac 'aa:bb:cc:dd:ee:ff'
    option ip '192.168.1.50'
    option name 'kids-tablet'

config host
    option mac '11:22:33:44:55:66'
    option ip '192.168.1.51'
    option name 'work-laptop'
```

### 5.3 Gatekeeper section sourcing

`uci export gatekeeper` emits the canonical UCI text format covering all
sections under the `gatekeeper` package: `main`, `blacklist`, and any
`schedule '<name>'` sections.

### 5.4 DHCP host extraction

A `config host` block in `/etc/config/dhcp` starts with a line `config
host` (optionally followed by `'<name>'`) and continues until the next
`config <something>` line or end-of-file. Extracted via:

```sh
awk '/^config[[:space:]]/ { in_host = ($2 == "host") } in_host { print }' \
    /etc/config/dhcp
```

`in_host` defaults to 0, so anything before the first `config host` is
skipped. Blank lines between consecutive host blocks are preserved.

### 5.5 Secret-stripping (NOSECRETS)

When the user runs `BACKUP NOSECRETS`, the gatekeeper-section dump is
piped through:

```sh
sed -E "s/^([[:space:]]*option (token|chat_id) ).*/\1''/"
```

Both keys remain in the file with empty quoted values, so a future
restore knows the keys exist and can prompt for values. The header line
flips from `Includes secrets: yes` → `no`.

## 6. Command Handler

### 6.1 Argument parsing

- `BACKUP` (no arg) → secrets included.
- `BACKUP NOSECRETS` (case-insensitive) → secrets stripped.
- `BACKUP <anything-else>` → reject with `❌ Usage: BACKUP [NOSECRETS]`.

### 6.2 Handler shape (illustrative)

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
                    curl -s $CURL_OPTS -X POST \
                        "https://api.telegram.org/bot$TOKEN/sendMessage" \
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
            SECRETS_LABEL=$([ "$INCLUDE_SECRETS" = "1" ] && echo yes || echo no)

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
                curl -s $CURL_OPTS -X POST \
                    "https://api.telegram.org/bot$TOKEN/sendMessage" \
                    -H "Content-Type: application/json" \
                    -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$MSG\",\"parse_mode\":\"Markdown\"}"
                logger -t tg_bot "Backup upload failed: $UPLOAD_RESP"
            fi

            rm -f "$BACKUP_FILE"
```

### 6.3 No additional success message

`sendDocument` causes the file to appear directly in the chat with the
caption — no separate "✅ Backup sent" sendMessage is needed (matches the
spec's stylistic preference: don't double-notify when Telegram already
shows the user the action).

### 6.4 HELP update

Insert one line in the existing **Maintenance** subsection of the HELP
message:

```
`BACKUP [NOSECRETS]` - Send config backup as a Telegram file
```

## 7. Edge Cases & Error Handling

| Case | Handling |
|------|----------|
| `/etc/config/dhcp` missing or unreadable | `awk … 2>/dev/null` swallows the error; the dhcp section header still prints with no body. |
| Zero `config host` entries | dhcp section header still printed, body empty. Backup remains valid. |
| `/tmp` full / write fails | Truncated `BACKUP_FILE`; `curl` still attempts upload; `jq -e '.ok'` catches API rejection; reply with `❌ Backup upload failed`; `rm -f` removes the partial file. |
| Concurrent `BACKUP` commands within the same minute | PID suffix in filename (`-$$`) gives each invocation a unique path. |
| Telegram API failure / rate limit / network glitch | `jq -e '.ok'` returns false → `❌ Backup upload failed` reply. Local file removed. User retries. |
| `sendDocument` 50 MB limit | Backup is < 10 KB. Not a real risk. |
| Token / chat_id missing in UCI | The bot doesn't run at all in this state; `BACKUP` is unreachable. |
| BusyBox vs GNU `awk` / `sed` | Used POSIX features only (`awk` field comparison, `sed -E`); BusyBox supports both. |
| `BACKUP` with malformed argument | Reject with usage error; no file created. |
| User SSH-modifies UCI between the gatekeeper-read and dhcp-read | Non-atomic across the two configs. Window is microseconds; documented as known. |
| Hostname has unusual characters | `uci` returns OpenWrt-valid hostname (`[a-zA-Z0-9-]+`); safe in filename. |

### Error-handling principles

- **Fail loud, fail clean:** failed upload → user-visible `❌` reply,
  local file deleted regardless. Never leave a stale backup in `/tmp`.
- **Read-only operation:** backup never modifies UCI, nftables, or
  firewall state. A bug in this command cannot break the gatekeeper.
- **No `set -e`:** matches existing `tg_bot.sh` style. Each external
  command's exit code is either explicitly checked (`jq -e`) or
  deliberately ignored (`2>/dev/null`).

## 8. Testing Plan

### Pure-text unit tests (dev-only)

Add two cases to `tests/test_schedule_helpers.sh` (or a new
`tests/test_backup_helpers.sh`):

1. **`config host` extractor** — fixture with mixed `config dhcp lan`,
   `config host 'foo'`, `config dnsmasq`, anonymous `config host`. Assert
   output contains exactly the host blocks and nothing else.
2. **Secret stripping** — fixture with `option token 'abc123'` and
   `option chat_id '999'` plus surrounding text. Assert sed transform
   leaves both as `option token ''` / `option chat_id ''` while
   preserving everything else.

These run on macOS/Linux dev machines without a router or Telegram bot.

### On-router manual checks

1. Send `BACKUP` from Telegram. Confirm a document arrives with caption
   `Gatekeeper backup from <hostname> (secrets: yes)`.
2. Open the file. Verify both sections present, secrets visible, schedule
   + blacklist + host blocks intact.
3. Send `BACKUP NOSECRETS`. Confirm caption shows `secrets: no` and the
   file's `option token ''` / `option chat_id ''` lines are blank.
4. Send `BACKUP foo`. Confirm `❌ Usage: BACKUP [NOSECRETS]` reply.
5. After each backup, verify `/tmp` has no
   `gatekeeper-backup-*.txt` files (`ls /tmp/gatekeeper-backup-*` fails).
6. Disconnect WAN briefly, run `BACKUP`. Confirm `❌ Backup upload failed`
   reply and `/tmp` is clean.
7. Send 5 `BACKUP` commands in rapid succession. Confirm Telegram receives
   5 distinct files (validates the PID-suffixed filename mitigation).

## 9. Out-of-Scope (recorded for future work)

- **Restore** — separate spec & plan cycle. Sketch: `RESTORE` is triggered
  by replying to a backup file or sending it directly to the bot. Needs a
  validation pass, dry-run mode, atomic multi-config write,
  rollback-on-failure, and explicit confirmation before clobbering the
  current config (because a wrong token would lock the user out).
- **Scheduled / on-change auto-backup** — possibly via the existing
  scheduler infrastructure once the use case is clearer.
- **Encryption / passphrase** — out-of-band hardening.
- **`.tar.gz` archive / JSON output** — only worth revisiting if backups
  ever grow large enough that compression matters, or if a tooling
  pipeline needs a structured format.
- **Backing up `/etc/gatekeeper/gatekeeper.nft`, init scripts, or other
  package files** — those are recovered by reinstalling the `.ipk`.
