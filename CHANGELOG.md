# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **BusyBox `tr` POSIX-character-class incompatibility** - Older BusyBox `tr` does not interpret `[:upper:]` / `[:lower:]` as POSIX character classes; it treats them as literal characters. Surfaced as `SCHEDADD … LivingRoomTV` being rejected with "Invalid name" because the input was never lowercased. Replaced all 21 occurrences in `tg_bot.sh` and `gatekeeper.sh` with the `tr 'A-Z' 'a-z'` ASCII-range form per the CLAUDE.md convention.
- **SCHEDADD invalid-name error is now actionable** - Names with hyphens like `living-room-tv` previously hit a generic regex error with no clue why (UCI section names disallow hyphens). The error now detects the hyphen case specifically and suggests the underscore alternative (`living_room_tv`) so the user can copy-paste a working command.
- **REVOKE/DREVOKE not appearing in logread** - Added `logger -t tg_bot` calls to REVOKE and DREVOKE so they appear in `logread -f | grep tg_bot` alongside other bot operations
- **BLADD allows duplicate MACs** - BLADD now checks if MAC already exists in `blacklist_macs` before adding to UCI and nftables; responds with an info message if already present

### Changed
- **`gatekeeper.sh` validation order** - Added new step 3.6 between blacklist mode (3.5) and notification (4): if the MAC has an active schedule, auto-approve until window end and optionally notify (controlled by `gatekeeper.main.schedule_notify`). New ordering: static lease → `denied_macs` → `approved_macs` → disabled-flag → blacklist mode → **active schedule** → notification.
- **Telegram Bot HELP** - New `📅 Schedules` subsection listing all SCHED commands; `BACKUP` and `RESTORE` added under Maintenance; STATUS now tags schedule-driven approvals with `⏰ <schedule-name>`.
- **`/etc/config/gatekeeper` schema** - New `option schedule_notify` in `main` (default `0`). New `config schedule '<name>'` section type with `mac` / `days` / `start` / `stop` / `label` / `enabled` options.
- **Blacklist command names** - Renamed `BL_ON`/`BL_OFF`/`BL_STATUS`/`BL_ADD`/`BL_REMOVE`/`BL_CLEAR` to `BLON`/`BLOFF`/`BLSTATUS`/`BLADD`/`BLREMOVE`/`BLCLEAR` (shorter, no underscore); `BLACKLIST_` prefix aliases still work

### Documentation
- New design specs in `docs/superpowers/specs/`: `2026-04-28-scheduled-approval-design.md`, `2026-04-28-config-backup-design.md`, `2026-04-28-config-restore-design.md`.
- New implementation plans in `docs/superpowers/plans/`: matching files for each of the three features.
- `CLAUDE.md` updated with: new state-files rows (`/tmp/sched_active`, `/tmp/sched_lock`), validation-order step 6 (active-schedule), and three new command subsections (Schedules, Backup, Restore).
- `README.md` and `QUICK_REFERENCE.md` updated with all new commands.
- Fixed README and QUICK_REFERENCE: removed non-existent `bypass_switch` nftables set; corrected emergency disable/enable commands to use `DISABLE`/`ENABLE` bot commands or `nft flush chain` / `fw4 reload`

### Added
- **Scheduled Auto-Approval** - Major new feature for time-window-based MAC auto-approval
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

- **Dev-only test harness** - Pure-shell unit tests for portable helper logic
  - `tests/test_schedule_helpers.sh` (28 assertions) covers `expand_days`, `hm_to_min`, `window_active_now` (same-day, cross-midnight, comma-list days, single-anchored-day cross-midnight)
  - `tests/test_backup_helpers.sh` (5 assertions) covers the awk host-extractor and the sed secret-stripper
  - `tests/test_restore_helpers.sh` (9 assertions) covers the awk parser and the `is_valid_backup` predicate
  - All run on macOS / Linux dev machines without a router or Telegram bot (note: schedule + restore tests need GNU `date` via `brew install coreutils` on macOS)

- **Blacklist Mode** - Major new feature that inverts approval logic
  - Only blacklisted MACs require approval, others are auto-approved for 24 hours
  - Persistent configuration via UCI (survives reboots)
  - New `blacklist_macs` nftables set for efficient filtering
  - Auto-approval messages include MAC, IP, and hostname information

- **New Telegram Bot Commands**
  - `BLON` / `BLACKLIST_ON` - Enable blacklist mode
  - `BLOFF` / `BLACKLIST_OFF` - Disable blacklist mode
  - `BLSTATUS` / `BLACKLIST_STATUS` - Show blacklist status and list MACs
  - `BLADD [MAC]` / `BLACKLIST_ADD [MAC]` - Add MAC to blacklist
  - `BLREMOVE [MAC]` / `BLACKLIST_REMOVE [MAC]` - Remove MAC from blacklist
  - `BLCLEAR` / `BLACKLIST_CLEAR` - Clear all blacklist entries

- **Automated Deployment**
  - New `deploy.sh` script for automated deployment via SCP
  - Support for dry-run, config-only, scripts-only, and no-config deployment modes
  - `--no-config` flag deploys all files while preserving existing router configuration
  - Automatic permission setting and service restart
  - Built-in connectivity testing and verification
  - Color-coded output for better visibility

- **Enhanced Documentation**
  - Comprehensive `README.md` with quick start guide
  - New `DEPLOY.md` with detailed deployment instructions
  - Updated `CLAUDE.md` with blacklist mode documentation
  - Example configuration file (`.deploy.conf.example`)

- **Improved Synchronization**
  - `gatekeeper_sync.sh` now supports both static and blacklist MAC sync
  - `gatekeeper_init` syncs both static and blacklist MACs on boot
  - Parameter support for selective sync (`static`, `blacklist`, or `all`)

### Changed
- **Firewall Architecture**
  - Updated from 4 to 5 nftables sets (added `blacklist_macs`)
  - Updated firewall documentation and comments

- **UCI Configuration**
  - Added `blacklist_mode` option to `gatekeeper.main`
  - Added `blacklist` section for MAC address list
  - Updated default config template

- **Telegram Menu**
  - Removed "Log" and "Clear" buttons from keyboard menu
  - Cleaner 2-row layout: Status/DStatus/Help and Sync/Enable/Disable
  - Commands still accessible via text input

- **Help Command**
  - Updated to include new blacklist mode commands
  - Better organized into sections (Device Management, Blacklist Mode, System Control)

### Fixed
- No bug fixes in this release (feature addition)

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
- nftables integration with 4 sets
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
