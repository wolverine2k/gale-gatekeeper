# Repository Guidelines

## Project Structure & Module Organization

Gatekeeper is an OpenWrt network access controller with Telegram and optional LuCI interfaces. Root scripts are the runtime and deployment entry points: `gatekeeper.sh`, `tg_bot.sh`, `dnsmasq_trigger.sh`, `gatekeeper_trigger.sh`, `gatekeeper_sync.sh`, `deploy.sh`, and init scripts such as `tg_gatekeeper`. Package assets live under `opkg/`: UCI config in `opkg/etc/config/`, shared shell helpers in `opkg/usr/lib/gatekeeper/`, and LuCI files in `opkg/luci/`. Tests are dev-only shell scripts in `tests/`. User-facing docs are in `README.md`, `DEPLOY.md`, `QUICK_REFERENCE.md`, and `CHANGELOG.md`; images are in `assets/`.

## Build, Test, and Development Commands

- `sh tests/test_busybox_compat.sh`: scans router-side scripts for BusyBox-incompatible shell patterns.
- `sh tests/test_schedule_helpers.sh`: tests schedule day and time-window helpers.
- `sh tests/test_backup_helpers.sh && sh tests/test_restore_helpers.sh`: verifies backup and restore parsing helpers.
- `sh tests/test_rpcd_helpers.sh && sh tests/test_rpcd_methods.sh`: checks LuCI rpcd backend helper behavior and method dispatch.
- `./deploy.sh 192.168.1.1 --dry-run`: previews router deployment.
- `./deploy.sh 192.168.1.1 --luci-only`: deploys only LuCI files for UI/backend iteration.

On macOS, install GNU coreutils and run date-sensitive tests with `PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"`.

## Coding Style & Naming Conventions

Router-side scripts must stay POSIX `/bin/sh` compatible for BusyBox ash. Avoid `[[ ]]`, bash arrays, process substitution, `${var,,}`, `${var^^}`, `function name`, `grep -P`, and GNU relative `date -d` strings. `deploy.sh` is the deliberate Bash exception. Keep LuCI view files named after pages, for example `overview.js` and `backup_restore.js`, and keep UCI/rpcd JSON names aligned with `luci-app-gatekeeper`.

## Testing Guidelines

Run `tests/test_busybox_compat.sh` before every change touching router-side scripts. When changing schedule helpers, update the copies in `tg_bot.sh`, `gatekeeper.sh`, and `tests/test_schedule_helpers.sh`. When changing `restore_helpers.sh`, update the inlined restore test copy. Integration with `uci`, `nft`, Telegram, and LuCI should be verified manually on an OpenWrt router.

## Commit & Pull Request Guidelines

Recent history uses concise, imperative summaries such as `Fix scheduled auto-approve broken by GNU-only date syntax on BusyBox`. Keep subjects specific and behavior-focused. For commits made by agents in this workspace, use Lore trailers when useful: `Constraint:`, `Rejected:`, `Confidence:`, `Scope-risk:`, `Tested:`, and `Not-tested:`.

Pull requests should describe user-visible behavior, list tests run, call out router/manual verification, and include screenshots for LuCI UI changes.

## Security & Configuration Tips

Do not commit Telegram tokens, chat IDs, router passwords, generated backups, or local `.deploy.conf` files. Preserve `/etc/config/gatekeeper` on upgrades unless the change explicitly migrates configuration.
