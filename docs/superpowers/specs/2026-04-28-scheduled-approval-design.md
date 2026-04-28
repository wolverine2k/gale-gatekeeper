# Scheduled Auto-Approval — Design Spec

**Date:** 2026-04-28
**Author:** Naresh Mehta
**Status:** Approved (pending implementation plan)

## 1. Summary

Add a feature that lets the user define recurring time windows during which a
specific MAC is automatically allowed onto the network without requiring a
Telegram approval prompt. Each MAC can have multiple schedules, each schedule
covers any subset of weekdays, and start/stop times are independent per
schedule. Schedules persist across reboots in UCI.

The canonical use case is "kid's tablet allowed weekdays 16:00–20:00, weekends
09:00–21:00" — two schedules on the same MAC.

## 2. Goals & Non-Goals

### Goals
- Per-MAC, time-of-day-bounded automatic approval, persisted in UCI.
- Multiple independent schedules per MAC.
- Day selection via natural keywords (`daily`, `weekdays`, `weekends`,
  comma-separated three-letter abbreviations).
- Cross-midnight windows (e.g., `22:00-06:00`).
- Hybrid behavior: proactive push at window start, reactive catch on
  mid-window DHCP events.
- Stable, user-controllable schedule identifiers for `SCHEDREMOVE`/`SCHEDOFF`.

### Non-Goals (deferred)
- Calendar date bounds (`valid_from` / `valid_until`).
- One-shot, single-occurrence schedules.
- Per-schedule timezone overrides.
- Schedule-conflict warnings at create time.
- Scheduler-driven push notifications beyond the existing optional info
  message (see §6 — `schedule_notify` flag).

## 3. Decisions Made

The following decisions were settled before writing this spec. They are listed
here so future readers don't have to re-derive them.

| ID | Decision |
|----|----------|
| **C** | Behavior is **hybrid**: a scheduler tick proactively pushes the MAC into `approved_macs` at window start; `gatekeeper.sh` also reactively pushes if a DHCP event for the MAC arrives mid-window. |
| **A** | At window stop, the MAC is simply removed from `approved_macs`. No automatic add to `denied_macs`. Reconnect attempts go through the normal approval flow. |
| **3a** | Time format: `HH:MM` 24-hour, in the router's local timezone (`system.system.timezone`). |
| **3b** | Cross-midnight windows are allowed: when `stop <= start`, the window crosses midnight, anchored to the start day. |
| **3c** | Day tokens: `daily` / `weekdays` / `weekends` / comma-separated `mon,tue,wed,thu,fri,sat,sun`. Different times per day are expressed as separate schedules. |
| **4a** | When `gatekeeper.main.disabled=1`, the scheduler is a no-op. After ENABLE, the next tick re-pushes any active windows. |
| **4b** | A MAC currently in `denied_macs` is **not** pushed by the scheduler. Denials are time-bounded (30 min); the schedule resumes naturally on the first tick after the deny entry expires. |
| **4c** | Blacklist mode is irrelevant once a schedule is active — the MAC is in `approved_macs` and the blacklist gate doesn't run. |
| **4d** | `SCHEDADD` on a MAC that has a static DHCP lease succeeds with a warning ("⚠️ MAC has a static lease; this schedule will have no effect"). |
| **4e** | `STATUS` tags scheduled-driven `approved_macs` entries with a "⏰ Scheduled" indicator. |
| **5a** | Schedules are addressed by stable user-supplied UCI section names (auto-generated if omitted). |
| **5b** | An optional human-readable label is stored per schedule for display only. |
| **5c** | No date bounds; schedules persist until explicitly removed. |
| **Impl** | Implementation: in-loop `scheduler_tick()` inside `tg_bot.sh`'s main polling loop. No new daemon, no cron dependency. |
| **CLI** | Command structure: MAC-first `SCHEDADD`, name-based `SCHEDREMOVE` / `SCHEDSHOW` / `SCHEDOFF` / `SCHEDON`, plus `SCHEDLIST` (optionally filtered by MAC) and a `SCHEDNOTIFY` toggle. |

## 4. Architecture & Data Model

### 4.1 File-by-file change inventory

| File | Change |
|------|--------|
| `tg_bot.sh` | Six new command handlers + helpers; one new `scheduler_tick()` function called once per polling-loop iteration; STATUS rendering tweak for the "⏰ Scheduled" tag. |
| `gatekeeper.sh` | One new step (3.6) between blacklist mode and notification: "active schedule for this MAC?" → push to `approved_macs` and exit silently. |
| `opkg/etc/config/gatekeeper` | Documentation comment block for the new `schedule` section type and the optional `schedule_notify` flag. |
| `gatekeeper.nft` | **No changes.** It already operates on `approved_macs`. |
| `gatekeeper_init` | **No changes.** UCI is read on demand by `tg_bot.sh`. |
| `gatekeeper_sync.sh` | **No changes.** |
| `CLAUDE.md` | Add `/tmp/sched_active` row to State Files table; brief mention of step 3.6 in `gatekeeper.sh` validation order; new section listing schedule commands. |
| `README.md` / `QUICK_REFERENCE.md` | Document new commands. |

No new files in the runtime path. No new dependencies. No new procd lifecycle.

### 4.2 UCI schema additions

Added to `/etc/config/gatekeeper`:

```
config schedule 'sched_kids_eve'
    option mac     'aa:bb:cc:dd:ee:ff'
    option days    'weekdays'              # daily|weekdays|weekends|mon,tue,...
    option start   '16:00'                  # HH:MM, router local TZ
    option stop    '20:00'                  # HH:MM; if stop<=start, crosses midnight
    option label   'Kids tablet evening'    # optional, display-only
    option enabled '1'                      # 1 active, 0 paused (SCHEDOFF)
```

Plus a new option in the existing `main` section:

```
option schedule_notify '0'  # 0 = silent, 1 = post info message on schedule auto-approve
```

UCI section names match `^[a-z0-9_]{1,32}$`. Auto-generated names take the form
`sched_<last3octets-no-colons>_<n>` where `n` is the smallest positive integer
producing a unique section name.

### 4.3 Ephemeral state in `/tmp`

| File | Purpose |
|------|---------|
| `/tmp/sched_active` | Lines: `<sched-name> <mac> <window-end-epoch>`. Rebuilt each tick. Used by STATUS to render the "⏰ Scheduled" tag and by the tick to detect window-end transitions. |
| `/tmp/sched_lock` | flock(1) guard to prevent overlapping ticks (rare but cheap insurance). |

Both files are non-persistent. Recovery on reboot relies on the next tick
recomputing desired state from UCI.

## 5. Scheduler Tick Algorithm

A new `scheduler_tick()` function lives in `tg_bot.sh`. It is invoked once per
main-loop iteration, just before Telegram update processing, so a long
`getUpdates` poll does not delay scheduling work.

### 5.1 Skip conditions (early exit)

1. `gatekeeper.main.disabled=1` → return.
2. `date +%Y < 2024` → return (NTP not yet synced; avoids bogus pushes during
   first ~60s after boot).
3. flock contention → return.

### 5.2 Per-tick logic

```
NOW_EPOCH = date +%s
DOW       = date +%a (lowercased)
HM        = date +%H:%M

new_active = empty file

for each UCI section of type 'schedule':
    enabled = uci -q get gatekeeper.<sec>.enabled || "1"   # default-on if option missing
    skip if enabled != "1"
    end_epoch = window_active_now(days, start, stop, DOW, HM, NOW_EPOCH)
    skip if end_epoch is empty
    skip if MAC currently in denied_macs        # decision 4b
    remaining = end_epoch - NOW_EPOCH
    skip if remaining < 60                      # avoid 0-second timeouts

    nft delete element approved_macs { mac }    # idempotent
    nft add element approved_macs { mac timeout <remaining>s }

    record (sched-name, mac, end_epoch) into new_active

# Window-end detection: anything that was active last tick but isn't now
for mac in (old_active.macs - new_active.macs):
    nft delete element approved_macs { mac }    # decision A: just remove
    log "schedule-window-ended"

mv new_active /tmp/sched_active
```

### 5.3 Day-set expansion

`expand_days(token)` is the helper that turns the user-facing day token into a
space-separated list of three-letter abbreviations:

- `daily` → `mon tue wed thu fri sat sun`
- `weekdays` → `mon tue wed thu fri`
- `weekends` → `sat sun`
- comma-separated subset (e.g. `mon,wed,fri`) → space-separated equivalent.

Day matching against `date +%a` is always lowercase.

### 5.4 `window_active_now` predicate

Same-day case (`start < stop`):
- Today's lowercase `%a` must be in the expanded day set.
- Current `HH:MM` must satisfy `start <= now < stop`.
- `end_epoch = date -d "today $stop" +%s`.

Cross-midnight case (`stop <= start`):
- If today's `%a` is in the day set AND `now >= start`:
  active until tomorrow at `stop`.
- Else if yesterday's `%a` is in the day set AND `now < stop`:
  active until today at `stop`.
- Else: not active.

The "anchor day" for cross-midnight windows is the *start* day — a `mon
22:00-06:00` schedule activates Monday at 22:00 and ends Tuesday at 06:00.

### 5.5 Properties

- **Idempotent:** Each tick recomputes desired state from scratch. A missed
  tick is recovered by the next one. There is no event log to replay.
- **Self-healing on `fw4 reload`:** When a reload wipes `approved_macs`, the
  next tick re-pushes any active windows within ≤30s.
- **REVOKE-aware:** A manual `REVOKE` adds the MAC to `denied_macs` for 30
  minutes; the tick's denied-wins rule skips re-push. The schedule resumes
  automatically after the deny entry expires.

## 6. Reactive Integration in `gatekeeper.sh`

The proactive tick has up to a 30-second gap between window start and the next
iteration. A device joining the network mid-window (router reboot, device
wake-up) needs to be auto-approved on the spot. This is the reactive half of
the hybrid behavior.

### 6.1 New step 3.6 (between blacklist mode and notification)

```
if is_static = 0 AND ACTION = "add":
    end_epoch = check_active_schedule_for_mac(MAC)
    if end_epoch is not empty:
        remaining = end_epoch - now
        if remaining >= 60:
            nft delete element approved_macs { MAC }
            nft add element approved_macs { MAC timeout <remaining>s }
            log "schedule-approved-<remaining>s"
            if uci gatekeeper.main.schedule_notify = 1:
                send Telegram info message "✅ Scheduled Auto-Approve … until <expiry>"
            exit 0
```

`check_active_schedule_for_mac` is a thin wrapper around `window_active_now`:
iterates schedules whose `mac` matches the input **and whose `enabled` option
is `1` (default if missing)**, returns the **maximum** `end_epoch` across all
active matches (so overlapping schedules grant the longest possible session),
or empty.

### 6.2 Final precedence order in `gatekeeper.sh`

| Step | Check | Result |
|------|-------|--------|
| 0 | `gatekeeper.main.disabled=1` | Exit immediately |
| 1 | MAC in static DHCP leases | `is_static=1`, no notification |
| 2 | MAC in `denied_macs` | Silent exit |
| 3 | MAC in `approved_macs` | Silent exit |
| 3.5 | Blacklist mode ON, MAC not in blacklist | Auto-approve 24h, info message |
| **3.6** | **Active schedule for MAC** | **Auto-approve until window end, optional info message** |
| 4 | Otherwise | Notification with Approve/Deny buttons + 5-min auto-deny timer |

Step 1 wins over step 3.6 (decision 4d). Step 2 wins over step 3.6
(decision 4b). Step 3.5 and 3.6 are mutually safe — if both would apply, the
schedule's `approved_macs` push short-circuits subsequent gates.

## 7. Telegram Command Interface

### 7.1 Commands

| Command | Description |
|---------|-------------|
| `SCHEDADD <mac> <days> <start>-<stop> [name]` | Create a schedule. Name auto-generated if omitted. |
| `SCHEDREMOVE <name>` | Delete a schedule. If currently active, removes from `approved_macs` immediately. |
| `SCHEDLIST [mac]` | List all schedules, or filter by MAC. Active schedules tagged `⏰ active (until HH:MM)`. |
| `SCHEDSHOW <name>` | Show a single schedule's full details. |
| `SCHEDOFF <name>` | Pause a schedule (sets `enabled=0`). Removes from `approved_macs` if active. |
| `SCHEDON <name>` | Resume a paused schedule. |
| `SCHEDNOTIFY ON\|OFF\|STATUS` | Toggle the `schedule_notify` flag (default OFF). |

### 7.2 SCHEDADD validation

1. **MAC** matches `^([0-9a-f]{2}:){5}[0-9a-f]{2}$` (lowercased before storage).
2. **Days** is `daily` / `weekdays` / `weekends` / comma-separated subset of
   `mon,tue,wed,thu,fri,sat,sun`.
3. **Window** matches `^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]-(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$`. Reject
   `start == stop`. Inverted = crosses midnight (allowed).
4. **Name**, if supplied, is normalized to lowercase first, then must match `^[a-z0-9_]{1,32}$` and not already exist as a UCI section under `gatekeeper.`.
5. **Static-lease check** (decision 4d): if the MAC is in any UCI
   `dhcp.@host[*].mac`, prepend warning to the success reply but still create.
6. Persist the schedule. The UCI write **must explicitly include**
   `option enabled '1'` so the schedule is active immediately. Other options
   set: `mac`, `days`, `start`, `stop`, and `label` (only if supplied). After
   `uci commit gatekeeper`, call `scheduler_tick` inline so the window
   activates without waiting up to 30s.

### 7.3 Example interactions

```
> SCHEDADD aa:bb:cc:dd:ee:ff weekdays 16:00-20:00 kids_eve
✅ Schedule *kids_eve* added: aa:bb:cc:dd:ee:ff weekdays 16:00–20:00

> SCHEDADD aa:bb:cc:dd:ee:ff weekends 09:00-21:00
✅ Schedule *sched_ddeeff_1* added: aa:bb:cc:dd:ee:ff weekends 09:00–21:00

> SCHEDLIST
📅 Schedules

1. *kids_eve* ⏰ active (until 20:00)
   └ aa:bb:cc:dd:ee:ff weekdays 16:00–20:00
2. *sched_ddeeff_1*
   └ aa:bb:cc:dd:ee:ff weekends 09:00–21:00

💡 SCHEDREMOVE <name> | SCHEDOFF <name> | SCHEDON <name>
```

### 7.4 HELP additions

A new subsection appended to the existing `HELP` text:

```
📅 Schedules:
SCHEDADD <mac> <days> <start>-<stop> [name] - Add auto-approve schedule
SCHEDLIST [mac]    - List schedules (optionally filter by MAC)
SCHEDSHOW <name>   - Show schedule details
SCHEDREMOVE <name> - Delete a schedule
SCHEDOFF <name> / SCHEDON <name> - Pause/resume a schedule
SCHEDNOTIFY ON|OFF|STATUS - Toggle schedule auto-approve notifications

Days: daily | weekdays | weekends | mon,tue,wed,thu,fri,sat,sun
Times: HH:MM (24h, router local time). Stop < start = crosses midnight.
```

## 8. Edge Cases & Error Handling

| Case | Handling |
|------|----------|
| NTP not yet synced at boot | Tick exits early when `date +%Y < 2024`. Same guard in `gatekeeper.sh` step 3.6. |
| `fw4 reload` wipes `approved_macs` | Idempotent tick re-pushes within ≤30s. |
| Manual `REVOKE` during active window | Adds to `denied_macs` (30m); tick's denied-wins rule skips re-push. Schedule resumes after deny expires. Documented as intended. |
| `SCHEDREMOVE` while window active | Explicitly removes from `approved_macs`; tick's pop-loop is a backup. |
| Two schedules overlap on same MAC | `check_active_schedule_for_mac` returns `max(end_epoch)`. Tick yields longest timeout. |
| Cross-midnight at month/year boundary | `date -d "tomorrow $stop"` handles correctly across boundaries. |
| DST transitions | Affected window stretched/squeezed by one hour. Documented as a known limitation. |
| Concurrent ticks | `flock /tmp/sched_lock`; second invocation returns. |
| UCI commit failure | Reply `❌ Failed to save schedule (UCI commit error)`; no `scheduler_tick` called. |
| `tg_bot.sh` long-poll wedged | Tick paused up to ~60s (curl `--max-time`); resumes after. Acceptable for HH:MM resolution. |
| `SCHEDADD` with duplicate name | Reject: `❌ Schedule '<name>' already exists. Use SCHEDREMOVE first.` |
| `SCHEDADD` with malformed days/window/MAC | Reject with specific error message; no partial state written. |
| MAC matches both blacklist and a schedule | Schedule wins; once in `approved_macs`, blacklist gate doesn't apply. |
| Iteration error in step 3.6 | Soft-fail to step 4 (notification). Degraded path is the original behavior. |

### Error-handling principles

- Validation precedes persistence. Every malformed input is rejected with a
  specific `❌ <reason>` before any UCI or nftables write.
- All `nft add element` calls are paired with a preceding `nft delete element
  ... 2>/dev/null` to make retries safe (existing pattern in the codebase).
- All UCI reads use `uci -q` to swallow missing-key noise.
- A failed UCI commit replies with a clear error and leaves prior state intact.

## 9. Testing Plan

The codebase has no automated test harness; testing is manual on the deploy
target. The deploy script (`./deploy.sh`) plus `logread -f | grep -E
"gatekeeper|tg_bot"` is the workflow.

1. **Direct script invocation:** Run `gatekeeper.sh add <mac> <ip> <host>`
   with a UCI schedule pre-populated. Confirm step 3.6 fires.
2. **Time-bracketed window:** Set `start=now+1min stop=now+3min`; observe
   push at `+1min`, pop at `+3min` via `nft list set inet fw4 approved_macs`.
3. **Cross-midnight:** `start=23:58 stop=00:02 daily`; observe at 23:59,
   00:01, 00:03.
4. **Reactive (hybrid):** With a window active, `nft flush set inet fw4
   approved_macs`, then trigger a fake DHCP event for the scheduled MAC; verify
   step 3.6 re-pushes.
5. **`fw4 reload` self-heal:** Active window, `fw4 reload`, wait 30s, verify
   `approved_macs` repopulated.
6. **REVOKE precedence:** Trigger window, `REVOKE`, confirm `denied_macs`
   suppresses re-push for 30m.
7. **DISABLE/ENABLE:** Tick is no-op while disabled; ENABLE catches up within
   30s.
8. **SCHEDOFF/SCHEDON:** Confirm immediate pop on SCHEDOFF, push on SCHEDON.
9. **Multi-schedule overlap:** Two overlapping schedules on the same MAC;
   verify the `approved_macs` timeout matches the latest end.
10. **Static-lease warning path:** `SCHEDADD` on a static-lease MAC emits the
    warning and still creates the schedule.

## 10. Out-of-Scope (recorded for future work)

- Calendar date bounds (`valid_from` / `valid_until`).
- One-shot, single-occurrence schedules.
- Per-schedule timezone overrides.
- Schedule-conflict warnings at create time.
- Push notifications on every schedule activation.
- A web UI / LuCI app for schedule management.
