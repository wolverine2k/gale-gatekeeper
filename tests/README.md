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
