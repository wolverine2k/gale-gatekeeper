# Tests

Dev-only POSIX-shell unit tests for the helpers used by `tg_bot.sh` and
`gatekeeper.sh`. Run on a dev machine; not deployed to the router.

Run from the repository root. Run the BusyBox-compat suite on every change:

```sh
sh tests/test_busybox_compat.sh        # static-analysis: catches GNU-only date/bashisms
sh tests/test_schedule_helpers.sh      # window_active_now / expand_days unit tests
sh tests/test_backup_helpers.sh
sh tests/test_restore_helpers.sh
sh tests/test_rpcd_helpers.sh
sh tests/test_rpcd_methods.sh
```

**macOS prerequisite:** the helpers call `date -d "YYYY-MM-DD HH:MM:SS"`,
which BSD `date` (default on macOS) does not accept — it has no `-d` flag
at all and uses `-j -f` instead. Install GNU coreutils once with `brew
install coreutils`, then run the suite with `gdate` shadowing `date`:

```sh
PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH" sh tests/test_schedule_helpers.sh
```

(Adjust the prefix to `/usr/local/...` on Intel Homebrew.)

**Why not `date -d "today HH:MM"`?** That GNU-only spelling is silently
rejected by BusyBox `date` on the OpenWrt router (BusyBox accepts only
`hh:mm[:ss]`, `YYYY-MM-DD hh:mm[:ss]`, the dotted compact form, or
`@epoch` — see CLAUDE.md "Shell Compatibility Note"). When BusyBox
rejects the input it prints `date: invalid date '...'` to stderr and
writes nothing to stdout, so `$(date -d "today $stop" +%s)` returns an
empty string with no signal to the caller. That bug shipped briefly and
silently killed every scheduled auto-approve. The static-analysis test
(`tests/test_busybox_compat.sh`) blocks the regression at dev time —
run it before every commit that touches a router-side script.

These tests cover the **pure-logic** helpers (`expand_days`,
`window_active_now`). Integration with `nft` / `uci` / Telegram is verified
manually on the router per the spec's testing plan
(see `docs/superpowers/specs/2026-04-28-scheduled-approval-design.md` §9).

The helper bodies in this file must be kept in sync with the copies inlined
into `tg_bot.sh` and `gatekeeper.sh` — there are three copies on purpose; the
spec accepts duplication to avoid adding a new runtime file.
