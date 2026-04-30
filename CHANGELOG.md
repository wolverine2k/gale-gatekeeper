# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Scheduled auto-approve silently no-op'd on the router**. `window_active_now` (in `gatekeeper.sh`, `tg_bot.sh`, and the test helper) called `date -d "today $stop" +%s` / `date -d "tomorrow $stop" +%s` — GNU coreutils relative-date syntax that BusyBox `date` does NOT support. BusyBox printed `date: invalid date 'today 23:59'` to stderr and wrote nothing to stdout, so `check_active_schedule_for_mac` saw an empty `end_epoch`, skipped every schedule, and `gatekeeper.sh` step 3.6 fell through to the regular notification path. Effect: every scheduled MAC sent a Telegram approval request inside its window instead of being silently auto-approved. `scheduler_tick` in `tg_bot.sh` was equally broken, so `/tmp/sched_active` stayed empty and SCHEDLIST never showed the `⏰ active` tag. Fix: switched to `date -d "$(date +%Y-%m-%d) HH:MM:00" +%s` (the `YYYY-MM-DD hh:mm:ss` form is in BusyBox's documented `-d` grammar AND is GNU-compatible). Cross-midnight branch now uses `today_stop_epoch + 86400` instead of `date -d "tomorrow $stop"`. All 28 schedule-helper unit tests still pass. Both `gatekeeper.sh` and `tg_bot.sh` must be redeployed for the fix to take effect.

### Added
- **`tests/test_busybox_compat.sh`** - Static-analysis test that scans every router-side script for known BusyBox-incompatible patterns (GNU `date -d "today/tomorrow/..."`, `[[ ]]`, `${var,,}` / `${var^^}`, process substitution `<(...)`, `function` keyword, bash arrays, `grep -P`, and the `#!/bin/bash` shebang). Run before every commit that touches a router-side script. Each match cites the file, line, exact content, and a one-line "why" explaining the BusyBox limitation. Catches the exact class of regression that shipped the broken `date -d "today $stop"` call — would have failed CI/local before merge.

### Added
- **LuCI Web UI (`luci-app-gatekeeper`)** - Major new feature. Browser-based admin interface as a sibling ipk to the runtime package. Independent of the Telegram bot — installs alongside, reads/writes the same UCI + nftables state, and works with the bot running, stopped, or never installed at all.
  - Six pages under `Services → Gatekeeper`: Overview, Devices, Blacklist, Schedules, Backup / Restore, Settings.
  - **Overview**: status cards (bot daemon / firewall / NTP clock / mode flags), 5 count cards (active/denied/static/blacklist/schedules), live tail of `/tmp/gatekeeper.log`, optional auto-refresh every 5 s.
  - **Devices**: separate tables for active (approved_macs), denied (denied_macs), and static (static_macs). Per-row Approve / Deny / +30m / +1h / +4h / Revoke buttons. ⏰ tag indicates schedule-driven approvals; hostname column resolves via the same chain the STATUS bot command uses.
  - **Blacklist**: large slide-toggle for `blacklist_mode`, MAC list editor with online indicator (matched against `/tmp/dhcp.leases`), bulk Clear All.
  - **Schedules**: table + modal CRUD with day-preset selector (Daily / Weekdays / Weekends / Custom), browser-native time pickers, hyphen-to-underscore name correction hints (UCI section names disallow hyphens), pause/resume toggle. Active windows show end-time inline.
  - **Backup / Restore**: browser-native download (with secrets / NO secrets) and drag-and-drop file upload. Two-step preview-then-apply restore flow showing the same merge plan the Telegram RESTORE flow produces — additive merge, never overwrites token/chat_id, atomic apply with `uci revert` on any failure.
  - **Settings**: form for token (masked + show toggle), chat_id, blacklist_mode, schedule_notify, disabled flag. "Test bot connection" button calls Telegram `getMe` and reports username/first-name. Sync MAC sets and Clear logs maintenance buttons.
  - Backend is a single rpcd exec plugin at `/usr/libexec/rpcd/gatekeeper` exposing 31 ubus methods (POSIX `/bin/sh`, BusyBox-compatible). Frontend is 6 ES module `view/<page>.js` files in the modern client-side LuCI pattern.
  - Auth is the router's existing admin password (LuCI's standard ACL); no separate credential store.
  - GitHub Actions workflow (`.github/workflows/makefile.yml`) extended to build the LuCI ipk in the same job as the runtime package. Both `.ipk` files are uploaded as workflow artifacts on every push and PR, and attached to the GitHub Release on every `v*` tag push.

- **Shared `restore_helpers.sh` library** (`/usr/lib/gatekeeper/restore_helpers.sh`) - Refactor that pulls `mac_hostname`, `is_valid_backup`, `restore_parse_to_records`, `restore_build_plan`, and the `RESTORE_*` state-file constants out of `tg_bot.sh` (~250 lines) into a shared sourceable library. Both `tg_bot.sh` and the new LuCI rpcd backend source it — single source of truth for the restore parser/merge engine. The schedule-helper trio remains intentionally three-copy-duplicated per its existing contract.

- **`deploy.sh --luci` / `--luci-only` flags** - New optional flags that deploy the LuCI app files (rpcd backend, ACL, menu manifest, all six frontend views) and restart `rpcd` so it discovers the new plugin. `--luci` is additive (runtime + LuCI in one shot); `--luci-only` skips the runtime files entirely for fast iteration on LuCI-only changes. Documented in `README.md`, `CLAUDE.md`, and `DEPLOY.md`.

- **`deploy.sh --ask-password` flag** - For routers without SSH key auth, prompts once at the start for the root password and reuses it for every `ssh`/`scp` call in the run, eliminating the per-call password prompts. Routes ssh/scp through `sshpass -e`, holding the password in the `SSHPASS` env var only — it never appears in argv (`ps`/shell history stay clean). Requires `sshpass` (`brew install hudochenkov/sshpass/sshpass` on macOS, `apt-get install sshpass` on Debian/Ubuntu). Combines with any other flag (e.g. `--luci-only --ask-password`). For unattended use, SSH keys (`ssh-copy-id`) remain preferred.

- **Scheduled Auto-Approval** - Major feature for time-window-based MAC auto-approval
  - Define recurring time windows per MAC (e.g., kid's tablet weekdays 16:00-20:00)
  - Multiple schedules per MAC supported (e.g., separate weekday and weekend windows)
  - Day-of-week selection: `daily`, `weekdays`, `weekends`, or comma-separated `mon,tue,wed,thu,fri,sat,sun`
  - Cross-midnight windows (e.g., `22:00-06:00`)
  - Hybrid behavior: `scheduler_tick` proactively pushes/pops `approved_macs` at window boundaries (one tick per `tg_bot.sh` polling iteration); `gatekeeper.sh` step 3.6 reactively catches mid-window DHCP events
  - Self-healing across `fw4 reload` events; idempotent reconciliation
  - Stable UCI section names; persists across reboots
  - Manual `REVOKE` during a window adds the MAC to `denied_macs` for 30 min and the scheduler skips re-push for that period
  - Optional `schedule_notify` flag: when set, the bot sends a "✅ Scheduled Auto-Approve" info message on each schedule-triggered approval
  - New Telegram commands: `SCHEDADD`, `SCHEDLIST`, `SCHEDSHOW`, `SCHEDREMOVE`, `SCHEDOFF`/`SCHEDON`, `SCHEDNOTIFY`
  - New UCI section type `config schedule '<name>'` and new `option schedule_notify` in `main`
  - New ephemeral state: `/tmp/sched_active`, `/tmp/sched_lock`

- **Configuration Backup** - Telegram-driven config snapshot
  - New `BACKUP` command produces a plain-text UCI dump and uploads it as a Telegram document via `sendDocument`
  - Includes `/etc/config/gatekeeper` (main, blacklist, schedules) plus the static DHCP host entries from `/etc/config/dhcp`
  - `BACKUP NOSECRETS` variant blanks `token` and `chat_id` before upload for files you might share more broadly
  - Filename: `gatekeeper-backup-<hostname>-<YYYYMMDD-HHMM>-<pid>.txt` (PID suffix prevents concurrent-backup collisions)
  - Temp file deleted from `/tmp` immediately after upload regardless of success or failure (Telegram chat history is the archive)

- **Configuration Restore** - Telegram-driven additive merge from a backup file
  - Reply `RESTORE` to a backup file in the chat; bot validates, computes a merge plan, replies with a preview
  - Reply `YES` to the preview message within 10 minutes to apply the plan in a single UCI transaction
  - Additive merge semantics: skip duplicate blacklist MACs (case-insensitive by value); skip existing schedule sections (by name); restore non-secret main options if values differ; never touch `token` or `chat_id`
  - Two-phase apply with `uci revert` on any failure
  - Post-apply hooks: `scheduler_tick` for newly-restored active schedules; `blacklist_macs` nftables re-sync from new UCI state
  - 5-check validation gate (header, schema v1, both section markers, package line, file size cap) before any UCI mutation
  - Friendly preview rendering uses the same hostname-resolution chain as `STATUS` to show device names alongside MACs
  - All `/tmp/restore_*` state cleaned up on success, failure, expiry, or supersession by another RESTORE

- **Blacklist Mode** - Inverts approval logic so only blacklisted MACs require approval, others are auto-approved for 24 hours
  - Persistent configuration via UCI (survives reboots)
  - New `blacklist_macs` nftables set for efficient filtering
  - Auto-approval messages include MAC, IP, and hostname information
  - New Telegram commands: `BLON`/`BLOFF`/`BLSTATUS`/`BLADD [MAC]`/`BLREMOVE [MAC]`/`BLCLEAR` (plus `BLACKLIST_*` prefix aliases)

- **Dev-only test harness** - Pure-shell unit tests for portable helper logic
  - `tests/test_schedule_helpers.sh` (28 assertions) covers `expand_days`, `hm_to_min`, `window_active_now` (same-day, cross-midnight, comma-list days, single-anchored-day cross-midnight); auto-detects `gdate` (GNU coreutils) on macOS, falls back to `date` on Linux
  - `tests/test_backup_helpers.sh` (5 assertions) covers the awk host-extractor and the sed secret-stripper
  - `tests/test_restore_helpers.sh` (9 assertions) covers the awk parser and the `is_valid_backup` predicate
  - All run on macOS / Linux dev machines without a router or Telegram bot

- **Automated deployment (`deploy.sh`)** - SCP-based deploy script for development iteration
  - Supports `--dry-run`, `--no-restart`, `--restart-only`, `--config-only`, `--scripts-only`, `--no-config` modes
  - Automatic permission-setting and service restart
  - Built-in connectivity testing and verification
  - Flag-conflict detection rejects nonsensical combinations (e.g. `--config-only --luci-only`)
  - Color-coded output

- **Improved synchronization (`gatekeeper_sync.sh`)** - Manual sync utility supports both static and blacklist MACs
  - `gatekeeper_init` syncs both at boot
  - Parameter support for selective sync (`static`, `blacklist`, or `all`)
  - Bot's `SYNC` command and LuCI's "Sync MAC sets" button both call `gatekeeper_sync.sh all` for unified scope

### Fixed
- **BusyBox `tr` POSIX-character-class incompatibility** - Older BusyBox `tr` does not interpret `[:upper:]` / `[:lower:]` as POSIX character classes; it treats them as literal characters. Surfaced as `SCHEDADD … LivingRoomTV` being rejected with "Invalid name" because the input was never lowercased. Replaced all 21 occurrences in `tg_bot.sh` and `gatekeeper.sh` with the `tr 'A-Z' 'a-z'` ASCII-range form per the CLAUDE.md convention.
- **SCHEDADD invalid-name error is now actionable** - Names with hyphens like `living-room-tv` previously hit a generic regex error with no clue why (UCI section names disallow hyphens). The error now detects the hyphen case specifically and suggests the underscore alternative (`living_room_tv`) so the user can copy-paste a working command.
- **REVOKE/DREVOKE not appearing in logread** - Added `logger -t tg_bot` calls to REVOKE and DREVOKE so they appear in `logread -f | grep tg_bot` alongside other bot operations
- **BLADD allows duplicate MACs** - BLADD now checks if MAC already exists in `blacklist_macs` before adding to UCI and nftables; responds with an info message if already present
- **`deploy.sh` skipped `restore_helpers.sh`** - The shared library at `/usr/lib/gatekeeper/restore_helpers.sh` is sourced by `tg_bot.sh` at startup; without it the bot crashed before the polling loop even began. `deploy.sh` now creates `/usr/lib/gatekeeper/` and copies the file as part of the standard runtime deploy. Manual deployment instructions in `DEPLOY.md` updated similarly.
- **Bot `SYNC` scope mismatch with LuCI** - Bot `SYNC` only re-synced `static_macs`, while LuCI's "Sync MAC sets" button re-syncs both `static_macs` and `blacklist_macs` via `gatekeeper_sync.sh all`. The bot now calls the same helper script (with a fallback to inline static-only sync if the script is missing). Both surfaces produce identical results and the same Telegram report (`🔄 Synced N static and M blacklist MACs.`). HELP text and header comment updated.
- **nftables timeout-update no-ops in 5 places** - `nft add element ... timeout 30m` silently no-ops if the MAC is already in the target set; the existing element keeps its old timeout. Added `nft delete element ...` immediately before each `add` in: bot inline approve callback (`tg_bot.sh:357`), bot REVOKE handler (`tg_bot.sh:735`), bot DREVOKE handler (`tg_bot.sh:664`), rpcd `revoke` method, rpcd `denied_revoke_approve` method. The CLAUDE.md "Critical Implementation Details" section already documented the rule; this propagates the fix to every callsite that violated it.
- **LuCI ipk had no version floor on runtime gatekeeper** - `Depends: luci-base, gatekeeper, rpcd` would happily install with an older runtime that lacks `restore_helpers.sh`, breaking the rpcd backend at every call. Now pinned to `gatekeeper (>= ${PKG_VERSION}-${PKG_RELEASE})`; opkg refuses the install unless the runtime is at least the same version as the LuCI ipk being shipped.
- **LuCI ipk lacked `postinst`** - After `opkg install luci-app-gatekeeper_*.ipk`, `rpcd` didn't auto-discover the new `/usr/libexec/rpcd/gatekeeper` plugin until manual `/etc/init.d/rpcd restart`. Added a `postinst` that runs the restart, with `IPKG_INSTROOT` guard so chroot/image-build installs are unaffected.
- **Method count claims** - All five doc references claimed `~28 methods`; the rpcd plugin actually exposes 31 (verified by `gatekeeper list | jq 'length'`). Removed the dead `sched_show` method (declared, ACL'd, never called by frontend; redundant with `sched_list` filtered by name) from the plugin, ACL, and CLAUDE.md "Status reads" list. Updated all five method-count references.
- **Menu path "Network → Services → Gatekeeper" was wrong** - The LuCI menu JSON registers under `admin/services/gatekeeper`, which renders as a top-level **`Services → Gatekeeper`** in standard OpenWrt LuCI. All five docs (`README.md`, `CHANGELOG.md`, `CLAUDE.md`, `DEPLOY.md`, `QUICK_REFERENCE.md`) updated.
- **CHANGELOG nftables-set-count typo** - The blacklist-mode entry said "Updated from 4 to 5 nftables sets"; the actual transition was 3 → 4 (the initial v1.0.0 release had 3 sets — `static_macs`, `approved_macs`, `denied_macs` — and `blacklist_macs` was added later). v1.0.0 entry also corrected from "4 sets" to "3 sets".
- **`LOG` command comment said "10 entries"** - Code uses `tail -n 20`. Comments in `tg_bot.sh` (header docstring + handler comment) corrected to match.
- **Dead `countsRow` code in `overview.js`** - A duplicate count-card row variable was constructed but never appended to the DOM; the actual rendered counts row uses ID-based DOM updates from the polling loop. Removed.
- **Schedules page delay note referenced internal script name** - The user-facing note on the Schedules page mentioned `tg_bot.sh` and `scheduler_tick`, which is meaningless to a LuCI admin who never opened the bot's source. Reworded to "schedule changes can take up to 30 seconds to take effect".

### Changed
- **`gatekeeper.sh` validation order** - Added new step 3.6 between blacklist mode (3.5) and notification (4): if the MAC has an active schedule, auto-approve until window end and optionally notify (controlled by `gatekeeper.main.schedule_notify`). New ordering: static lease → `denied_macs` → `approved_macs` → disabled-flag → blacklist mode → **active schedule** → notification.
- **Telegram Bot HELP** - New `📅 Schedules` subsection listing all SCHED commands; `BACKUP` and `RESTORE` added under Maintenance; STATUS now tags schedule-driven approvals with `⏰ <schedule-name>`.
- **`/etc/config/gatekeeper` schema** - New `option schedule_notify` in `main` (default `0`). New `config schedule '<name>'` section type with `mac` / `days` / `start` / `stop` / `label` / `enabled` options.
- **Blacklist command names** - Renamed `BL_ON`/`BL_OFF`/`BL_STATUS`/`BL_ADD`/`BL_REMOVE`/`BL_CLEAR` to `BLON`/`BLOFF`/`BLSTATUS`/`BLADD`/`BLREMOVE`/`BLCLEAR` (shorter, no underscore); `BLACKLIST_` prefix aliases still work
- **Firewall architecture** - Updated from 3 to 4 nftables sets (added `blacklist_macs`); firewall comments and documentation updated
- **UCI configuration** - Added `blacklist_mode` option to `gatekeeper.main` and a `blacklist` section type for the MAC list; default config template updated
- **Telegram menu layout** - Removed "Log" and "Clear" buttons from the keyboard menu; cleaner 2-row layout (Status/DStatus/Help and Sync/Enable/Disable). Commands still accessible via text input.
- **Help command** - Reorganized into sections (Device Management, Blacklist Mode, Schedules, Maintenance, System Control); includes all new commands

### Documentation
- New design specs in `docs/superpowers/specs/`: `2026-04-28-scheduled-approval-design.md`, `2026-04-28-config-backup-design.md`, `2026-04-28-config-restore-design.md`.
- New implementation plans in `docs/superpowers/plans/`: matching files for each of the three features.
- `CLAUDE.md` updated with: new state-files rows (`/tmp/sched_active`, `/tmp/sched_lock`), validation-order step 6 (active-schedule), and three new command subsections (Schedules, Backup, Restore).
- `README.md` and `QUICK_REFERENCE.md` updated with all new commands.
- Fixed README and QUICK_REFERENCE: removed non-existent `bypass_switch` nftables set; corrected emergency disable/enable commands to use `DISABLE`/`ENABLE` bot commands or `nft flush chain` / `fw4 reload`

## [1.0.0] - 2026-01-XX

### Added
- Initial release
- Telegram-based network access control
- Interactive approve/deny buttons
- Static DHCP lease detection
- Timeout-based access control
- Auto-deny timer (5 minutes)
- Rate limiting (60 seconds)
- Emergency bypass switch
- Device management commands (STATUS, EXTEND, REVOKE)
- Denied device tracking (DSTATUS, DEXTEND, DREVOKE)
- Activity logging
- Custom hostname caching
- IPv6 filtering
- nftables integration with 3 sets (`static_macs`, `approved_macs`, `denied_macs`)
- procd service management
- UCI configuration

---

## Version History

### Blacklist Mode Features (Current)
- Inverted approval logic for trusted networks
- Persistent blacklist configuration
- 24-hour auto-approval timeout
- Informational messages for auto-approved devices
- Full Telegram command integration

### Core Features (v1.0.0)
- Basic approval/deny workflow
- Static lease bypass
- 30-minute temporary access
- Rate limiting and auto-deny
- Emergency bypass switch
- Device management via Telegram
