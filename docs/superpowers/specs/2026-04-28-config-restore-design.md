# Configuration Restore — Design Spec

**Date:** 2026-04-28
**Author:** Naresh Mehta
**Status:** Approved (pending implementation plan)

## 1. Summary

Add a Telegram `RESTORE` command that complements the existing `BACKUP`
feature. The user replies `RESTORE` to a previously-uploaded backup file
in the chat; the bot downloads the file, validates it, computes a merge
plan against the current UCI state, and replies with a preview. Within
10 minutes, the user replies `YES` to the preview message and the bot
applies the plan inside a single UCI transaction with revert-on-failure.

**Restore is additive only.** Entries already present in current UCI are
skipped. Nothing is deleted. Only blacklist MACs and schedule sections
that are missing from the current config get added; non-secret main
options (`blacklist_mode`, `disabled`, `schedule_notify`) get updated to
their backup values; `token` and `chat_id` are never touched.

## 2. Goals & Non-Goals

### Goals
- Telegram-driven recovery from a backup file produced by `BACKUP`.
- Two-step UX: explicit preview, explicit `YES` confirmation, 10-minute
  expiry window.
- Additive merge semantics — never delete current state, never rewrite
  user-edited entries that already exist.
- Always preserve `token` and `chat_id` (no Telegram-lockout risk).
- Atomic apply: either every queued change lands together (single
  `uci commit`) or none of them do (`uci revert` on any failure).
- Post-apply hooks: `scheduler_tick` for newly-restored schedules,
  `blacklist_macs` nftables re-sync from new UCI state.
- Read-only validation gate: invalid file → no UCI changes attempted.
- No new runtime files. No new daemons. No new dependencies (`curl`/`jq`
  are already in use).

### Non-Goals (deferred / YAGNI)
- **DHCP host restore.** Separate spec/plan cycle. The dhcp section in
  the backup file is read for validation only (presence of the section
  marker) but not applied.
- **Subtractive merge** (revert-to-backup, rebuild-from-backup). If the
  current config has a blacklist MAC the backup is missing, that MAC
  stays. Restore is additive only.
- **Auto-merging existing schedules' internals.** A schedule whose name
  already exists in current UCI is skipped wholesale. To refresh
  internals: `SCHEDREMOVE <name>` first.
- **Single-step apply (`RESTORE FORCE`).** Always preview-then-confirm.
- **Cross-router conflict detection** (e.g., restoring a backup whose
  MACs reference a different network).
- **Encrypted backups.**
- **Schedule sweeper / cron-based pending-state cleanup.** Single-slot
  pending state in `/tmp` is sufficient; next RESTORE overwrites,
  reboot clears.

## 3. Decisions Made

| ID | Decision |
|----|----------|
| **Q1** | Scope = `/etc/config/gatekeeper` only. The dhcp section in the backup is checked for presence (validation) but its host entries are not applied. |
| **Q2a** | Trigger = reply to a backup file message in the chat with text `RESTORE`. |
| **Q2b** | Two-step flow: preview generated on `RESTORE`; apply runs only when user replies `YES` to the preview message within 10 minutes. |
| **Q3a** | Main options: `blacklist_mode`, `disabled`, `schedule_notify` get updated from backup if values differ. `token` and `chat_id` are NEVER overwritten. Empty values (NOSECRETS-stripped) are skipped. |
| **Q3b** | Blacklist MACs: add missing MACs only (case-insensitive dedup by MAC value). Nothing is removed from the current list. |
| **Q3c** | Schedule sections: add missing schedules only (keyed by stable UCI section name). If a section by that name already exists, the entire incoming section is skipped — no field-level merge. |
| **Q4a** | Validation gate runs before any UCI write. Five checks: header line, schema version, both section markers, `package gatekeeper` presence, file size < 1 MB. Any failure → specific error reply, no mutations. |
| **Q4b** | Two-phase apply: (1) parse + plan (no UCI writes), (2) apply + commit. Any individual `uci` operation failure or commit failure → `uci revert gatekeeper`, error reply, abort. |
| **Q4c** | Post-apply hooks (only on commit success): `scheduler_tick` and `blacklist_macs` nftables re-sync. |
| **Q4d** | Two replies: preview (after RESTORE) showing diff with friendly hostname resolution; apply summary (after YES) listing what landed. Preview window 10 min, enforced by YES handler reading the timestamp from `/tmp/restore_pending`. |
| **Impl** | Inline in `tg_bot.sh` as two new `elif` handlers (RESTORE, YES). No new runtime files. |

## 4. Architecture & Data Model

### 4.1 File-by-file change inventory

| File | Change |
|------|--------|
| `tg_bot.sh` | Two new `elif` handlers (RESTORE, YES) at the end of the dispatch chain; one new line in HELP under Maintenance. New jq extraction for `reply_to_message.document.*` and `reply_to_message.message_id`. |
| `tests/test_restore_helpers.sh` *(new)* | Pure-shell unit tests for the parser awk and the header-validation predicate. |
| `CLAUDE.md`, `README.md`, `QUICK_REFERENCE.md` | One-line entries each. |
| Other runtime files | **No changes.** |

### 4.2 Telegram API additions

Two new endpoints, both already supported by the curl already on the
router:

- `GET /bot<TOKEN>/getFile?file_id=<id>` → returns `{ result: { file_path: "documents/file_NNN.txt" } }`.
- `GET https://api.telegram.org/file/bot<TOKEN>/<file_path>` → the
  document bytes. **Note the different host path: `api.telegram.org/file/bot…`,
  not `/bot…`** — Telegram's file CDN is hosted on the same domain but
  under `/file/`.

### 4.3 Ephemeral `/tmp` state

| File | Purpose |
|------|---------|
| `/tmp/restore_file.txt` | The downloaded backup file from Telegram. |
| `/tmp/restore_plan.sh` | Generated apply plan — one `uci …` command per line. Re-read by the YES handler. |
| `/tmp/restore_pending` | Single line: `<preview-msg-id> <epoch>`. The pending state. Latest RESTORE overwrites. |

All three are removed on apply success, on apply failure, and on
expiry. Reboot also clears them. No persistent state lives outside the
applied UCI changes themselves.

### 4.4 No new persistent files

The feature does not add any file under `/etc/`, `/usr/`, or any other
persistent location.

## 5. Parser & Merge Engine

### 5.1 Parser — awk emits a flat record stream

A single awk script reads the backup file and produces tab-separated
records, one per UCI option/list, plus a `section` marker each time a
new `config` block starts. The parser scopes to the
`/etc/config/gatekeeper` portion of the backup (between the section
markers).

```awk
BEGIN { in_section = 0; cur_type = ""; cur_name = "" }

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
    print "section\t" cur_type "\t" cur_name
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
    print kind "\t" cur_type "\t" cur_name "\t" key "\t" val
}
```

Output records (excerpt for a typical backup):

```
section	gatekeeper	main
option	gatekeeper	main	token	8373…
option	gatekeeper	main	chat_id	1393…
option	gatekeeper	main	blacklist_mode	1
section	blacklist	blacklist
list	blacklist	blacklist	mac	a8:23:fe:52:0d:b8
…
section	schedule	livingroomtv
option	schedule	livingroomtv	mac	b0:6b:11:19:5d:06
option	schedule	livingroomtv	days	daily
…
```

Values that contain spaces (e.g., `option label 'Kids tablet evening'`)
are captured first-quote-to-last-quote and reproduced intact.

### 5.2 Merge engine — shell consumes records, emits plan + preview

A shell loop reads each tab-separated record. State variables track
the current section (`section_type`, `section_name`, `skip_section`).

- **`section gatekeeper main`** → set state. No skip.
- **`section blacklist blacklist`** → set state. No skip. Cache the
  current blacklist MACs once: `uci show gatekeeper.blacklist | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | tr 'A-Z' 'a-z'`.
- **`section schedule <name>`** → set state. Look up
  `uci -q get gatekeeper.<name>`; if it returns `schedule`, set
  `skip_section=1`. All subsequent records for this section are
  skipped (per Q3c).
- **`option gatekeeper main <key> <val>`:**
  - Skip if `key` ∈ {`token`, `chat_id`} (Q3a).
  - Skip if `val` is empty (NOSECRETS).
  - Read `current=$(uci -q get gatekeeper.main.<key>)`.
  - If `current == val`: skip (no-op).
  - Else: append `uci set gatekeeper.main.<key>='<val>'` to the plan
    file; append `main option <key>: <current> → <val>` to the preview.
- **`list blacklist blacklist mac <mac>`:**
  - Lowercase `<mac>`.
  - If in cache: append to preview's "already present" list.
  - Else: append `uci add_list gatekeeper.blacklist.mac='<mac>'` to the
    plan; append to preview's "additions" list with hostname resolution.
- **`option schedule <name> <key> <val>`** (when `skip_section=0`):
  - First record for this `<name>`: append
    `uci set gatekeeper.<name>=schedule` to the plan; start a new
    preview "Schedule additions" entry.
  - Always: append `uci set gatekeeper.<name>.<key>='<val>'`.

### 5.3 Plan file format

`/tmp/restore_plan.sh` is a sequence of `uci …` commands, one per line,
optionally with `#`-prefixed comment lines. Example:

```sh
# Restore plan generated at 2026-04-28T18:00:11
uci set gatekeeper.main.blacklist_mode='1'
uci add_list gatekeeper.blacklist.mac='aa:f9:6c:74:55:11'
uci add_list gatekeeper.blacklist.mac='ee:5c:3f:27:10:7e'
uci set gatekeeper.livingroomtv=schedule
uci set gatekeeper.livingroomtv.mac='b0:6b:11:19:5d:06'
uci set gatekeeper.livingroomtv.days='daily'
uci set gatekeeper.livingroomtv.start='17:00'
uci set gatekeeper.livingroomtv.stop='23:59'
uci set gatekeeper.livingroomtv.enabled='1'
```

The YES handler executes this file line-by-line: skip blank/comment
lines, run each command via `eval`, check `$?`. On any non-zero exit,
abort and revert.

UCI option values are quoted with single quotes. UCI's own value grammar
forbids embedded single quotes in option values, so this is safe; the
backup format inherits that constraint from `uci export`.

### 5.4 Hostname resolution helper

A shell function `mac_hostname <mac>` mirrors the existing STATUS
chain in `tg_bot.sh`:

1. `/tmp/mac_names` — name cache populated when devices are approved.
2. `/tmp/dhcp.leases` — current dnsmasq active leases.
3. UCI `dhcp.<sec>.name` — static-lease hostname.
4. Empty (no fallback string in restore previews; we omit the
   parenthetical if the name is unknown).

Used to render previews like:

```
• b0:6b:11:19:5d:06 (Living Room TV)
```

versus, for a MAC with no resolved name:

```
• 96:ab:d8:c4:39:23
```

## 6. Telegram Flow & State

### 6.1 Update extraction

Three new fields are extracted from each `$row` JSON via `jq`,
alongside the existing `TEXT`, `U_ID`, `CMD`, `ARG`:

```sh
REPLY_DOC_ID=$(echo "$row" | jq -r '.message.reply_to_message.document.file_id // empty')
REPLY_DOC_NAME=$(echo "$row" | jq -r '.message.reply_to_message.document.file_name // empty')
REPLY_DOC_SIZE=$(echo "$row" | jq -r '.message.reply_to_message.document.file_size // 0')
REPLY_TO_MSGID=$(echo "$row" | jq -r '.message.reply_to_message.message_id // empty')
```

### 6.2 RESTORE handler

Triggered when `CMD = "RESTORE"`. Steps:

1. **Reply gate.** If `REPLY_DOC_ID` is empty: reply `❌ RESTORE must be sent as a reply to a backup file message.` Abort.
2. **Size gate.** If `REPLY_DOC_SIZE > 1048576` (1 MB): reply `❌ File too large (max 1 MB).` Abort.
3. **getFile API call.** Parse the response with `jq -r '.result.file_path // empty'`. If empty: reply `❌ Couldn't fetch file from Telegram.` Abort.
4. **Download** to `/tmp/restore_file.txt` via `curl -o`.
5. **Validation gate.** Run the five checks. On failure: reply with the specific reason, `rm -f /tmp/restore_file.txt`, abort.
6. **Parse + diff.** Run the awk parser on the file; pipe records through the merge engine; produce `/tmp/restore_plan.sh` and a preview string in the `MSG` variable.
7. **No-op short-circuit.** If `/tmp/restore_plan.sh` is empty (after stripping comments/blanks): reply `🔄 Restore preview — nothing to do. All entries from this backup are already present.`, `rm -f /tmp/restore_*`, abort.
8. **Send preview** via `sendMessage` with `parse_mode=Markdown`. Capture the response's `result.message_id` into `PREVIEW_MSGID`.
9. **Persist pending state** to `/tmp/restore_pending`: `echo "$PREVIEW_MSGID $(date +%s)" > /tmp/restore_pending`.
10. **Log.** `logger -t tg_bot "Restore preview sent: msg_id=$PREVIEW_MSGID file=$REPLY_DOC_NAME"`.

The downloaded file and plan stay in `/tmp` until either YES is processed or a fresh RESTORE overwrites them.

### 6.3 YES handler

Triggered when `CMD = "YES"`. Strict gating prevents accidental triggers:

1. **Reply context required.** If `REPLY_TO_MSGID` is empty: silently ignore.
2. **Pending state required.** If `/tmp/restore_pending` doesn't exist: silently ignore.
3. **Match the message id.** Read the file's first field; if it doesn't equal `REPLY_TO_MSGID`: silently ignore (user is replying YES to some unrelated message — not our preview).
4. **Expiry check.** Read the second field (epoch). If `now - epoch > 600`: reply `⌛ Pending restore expired (>10 min). Reply RESTORE to a backup file again.`, `rm -f /tmp/restore_*`, abort.
5. **Plan exists.** If `/tmp/restore_plan.sh` is missing: reply `❌ Plan file missing — restart restore by replying RESTORE to a backup file.`, `rm -f /tmp/restore_pending`, abort.
6. **Two-phase apply.**
   ```sh
   FAILED_LINE=""
   while IFS= read -r line; do
       case "$line" in
           ''|\#*) continue ;;
       esac
       if ! eval "$line"; then
           FAILED_LINE="$line"
           break
       fi
   done < /tmp/restore_plan.sh

   if [ -n "$FAILED_LINE" ]; then
       uci revert gatekeeper 2>/dev/null
       reply "❌ Restore failed at: \`$FAILED_LINE\`"
       rm -f /tmp/restore_*
       continue
   fi

   if ! uci commit gatekeeper; then
       uci revert gatekeeper 2>/dev/null
       reply "❌ Restore commit failed (UCI error)"
       rm -f /tmp/restore_*
       continue
   fi
   ```
7. **Post-apply hooks.**
   - Re-sync `blacklist_macs` nftables set: `nft flush set inet fw4 blacklist_macs 2>/dev/null`, then iterate UCI blacklist and re-add (same code path as `BLON` and `ENABLE`).
   - Call `scheduler_tick` to push any newly-restored active schedules.
8. **Summary reply.** `✅ Restore complete: <N> change(s) applied.` plus a brief breakdown matching the preview structure.
9. **Cleanup.** `rm -f /tmp/restore_file.txt /tmp/restore_plan.sh /tmp/restore_pending`.
10. **Log.** `logger -t tg_bot "Restore applied: <N> changes"`; line in `$LOG_FILE`.

### 6.4 Pending-state semantics

- **Single-slot.** Only one pending restore at a time. Second RESTORE overwrites file/plan/pending. Earlier preview becomes orphan-but-harmless (its YES will fail the message-id match in step 3).
- **No active expiry sweeper.** The 10-minute window is enforced in the YES handler. No cron/timer needed.
- **Cleared on apply (success or failure).** Both paths `rm -f /tmp/restore_*`.
- **Audit trail via `logger`.** Lifecycle is visible in `logread`.

## 7. Edge Cases & Error Handling

| Case | Handling |
|------|----------|
| File too large (`> 1 MB`) | Rejected before download via `document.file_size`. |
| getFile API failure / network error | `jq` returns empty file_path → `❌ Couldn't fetch file from Telegram.` |
| Download truncated / `/tmp` full | Validation gate catches missing markers; `❌ Backup file invalid (failed validation).` |
| Header missing / wrong schema | Specific reject: `❌ Not a Gatekeeper backup file (missing header)` / `❌ Unsupported schema version` / `❌ Backup is incomplete (missing section markers)`. |
| Backup is NOSECRETS | Empty values for token/chat_id are skipped by the merge engine's "skip if val empty" rule. Combined with Q3a, identical outcome regardless of which side blanked them. |
| MACs in different case | Merge lowercases both sides before comparing; no false-positive duplicates. |
| Backup from a different router | Hostname is metadata only; restore still applies. Matches the recovery scenario. |
| RESTORE not a reply | Reply gate rejects with explicit message. |
| RESTORE replying to a non-document | `reply_to_message.document.file_id` is empty → same reject. |
| Two RESTOREs in quick succession | Second overwrites pending state; first preview's YES fails the msg-id match and is silently ignored. |
| YES outside the 10-min window | Expiry message; cleanup. |
| YES with no pending state | Silently ignored. |
| YES replying to an unrelated message | Silently ignored (msg-id mismatch). |
| `uci set` line fails mid-apply | Revert + reply with the offending line. |
| `uci commit` fails | Revert + generic commit error reply. |
| Plan references a brand-new schedule name | `uci set gatekeeper.<name>=schedule` creates the section idempotently. |
| `gatekeeper.main.disabled=1` during restore | Restore is a UCI mutation only; no firewall side-effects beyond the post-apply nftables re-sync. The user can restore while in emergency-disabled state. |
| Restore adds a schedule overlapping an existing one | Already handled by `scheduler_tick` (max-end-epoch). Not a conflict. |
| `fw4 reload` between phase 1 and phase 2 | UCI commit is independent of nftables. Post-apply hook re-syncs `blacklist_macs`; if the next reload runs after, `gatekeeper.nft` already reads UCI for blacklist_macs. Self-heals. |
| User restores while a scheduled window is active | `approved_macs` is independent of UCI. After commit, `scheduler_tick` runs idempotently — it re-pushes if needed, no-ops otherwise. |

### Error-handling principles

- **Validation precedes mutation.** Every reject path leaves UCI untouched.
- **Cleanup is unconditional.** Both success and failure paths in the YES handler `rm -f /tmp/restore_*`. No stale state survives.
- **Errors are specific.** Every failure reply names the actual problem.
- **No `set -e`.** Each command's exit code is explicitly checked. Matches existing `tg_bot.sh` style.

## 8. Testing Plan

### Pure-text unit tests (dev-only)

A new file `tests/test_restore_helpers.sh` covers:

1. **Parser** — feed a fixture matching the format of the BACKUP output; assert the awk emits the exact expected tab-separated record stream.
2. **Section/value parsing edge cases** — fixture with `option label 'Kids tablet evening'` (value with spaces); assert the captured value is `Kids tablet evening`.
3. **Header-validation predicate** — small shell function `is_valid_backup` that takes a path and returns 0/1; tests cover happy path, missing header, wrong schema, missing markers.

Tests run on macOS / Linux dev machines; no router or Telegram bot needed.

### On-router manual checks

1. Send the existing shared backup as a reply with `RESTORE`. Verify preview matches expectation (no-op for current state, since all entries are already present).
2. Manually `BLREMOVE` one MAC, then `RESTORE` + `YES`. Verify the MAC is restored (`BLSTATUS`).
3. Manually `SCHEDREMOVE livingroomtv`, then `RESTORE` + `YES`. Verify the schedule reappears (`SCHEDLIST`).
4. Manually `BLOFF`, then `RESTORE` + `YES`. Verify `BLSTATUS` shows blacklist_mode is back to 1.
5. Reply `RESTORE` to a non-document message. Verify rejection.
6. Reply `RESTORE` to a non-backup file (e.g., a screenshot). Verify validation rejection.
7. Send `RESTORE` (preview produced), wait 11 minutes, then `YES`. Verify expiry message and `/tmp` clean.
8. Send two `RESTORE`s in quick succession; reply `YES` to the first preview. Verify silent ignore (msg-id mismatch).
9. Restore with NOSECRETS backup. Verify `token` and `chat_id` are not changed.
10. Verify `/tmp/restore_*` is empty after every successful and every failed run.

## 9. Out-of-Scope (recorded for future work)

- **DHCP host restore** — own spec/plan cycle.
- **Subtractive merge** (revert-to-backup) — different feature with replace semantics.
- **Auto-merging existing schedules' internals** — current behavior is whole-section skip.
- **`RESTORE FORCE` / dry-run modes** — preview-then-confirm is the only path.
- **Cross-router conflict detection.**
- **Encrypted backups.**
- **Web UI / LuCI app.**
