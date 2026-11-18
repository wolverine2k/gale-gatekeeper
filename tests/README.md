# Tests

Dev-only shell and Python tests for runtime helpers, packaging, artifact
validation, and deployment. Run on a development or CI host; not deployed to the router.

Run from the repository root. Run the BusyBox-compat suite on every change:

```sh
sh tests/test_busybox_compat.sh        # static-analysis: catches GNU-only date/bashisms
sh tests/test_schedule_helpers.sh      # window_active_now / expand_days unit tests
sh tests/test_backup_helpers.sh
sh tests/test_restore_helpers.sh
sh tests/test_reboot_command.sh       # Telegram REBOOT/RESTART system commands
sh tests/test_rpcd_helpers.sh
sh tests/test_rpcd_methods.sh
sh tests/test_randomized_mac.sh      # is_randomized_mac (anti-randomization heuristic)
sh tests/test_maclookup.sh            # lookup_mac_vendor (OUI vendor enrichment, stubbed curl)
sh tests/test_ipk_packages.sh
bash tests/test_package_deploy.sh
python3 -B tests/test_validate_ipks.py
```

Native APK tests additionally require the checksum-verified OpenWrt 25.12.0 Linux
SDK, OpenSSL, and Python 3:

```sh
OPENWRT_SDK=/path/to/sdk sh tests/test_apk_packages.sh
```

The APK suite verifies `openwrt-25.12-` package basenames and the signed index's
`pkgname-spec`, including an actual native APK fetch from an isolated localhost
HTTP server and byte-for-byte checks of the prefixed downloads.

The APK suite uses ephemeral test signing keys. Never enroll those keys on a
production router. Use the optional feed-directory argument to validate an
existing built feed instead of rebuilding it. Package-deployment tests use
isolated SSH/package-manager fixtures; they do not contact a router or establish
runtime compatibility. The optional `TEST_NATIVE_APK` variant exercises real
APK signature, index, fetch, and solver operations; its isolated database fixture
requires a disposable Linux root test environment (as used by CI).

```sh
OPENWRT_SDK=/path/to/sdk sh tests/test_apk_upgrade.sh
```

The upgrade suite requires Docker on the same Linux host as the SDK and network
access to official OpenWrt feeds. It builds two signed versions, verifies a pinned
25.12.0 rootfs checksum, performs real native dependency resolution/installation
and upgrade in a disposable container, and checks modified-config preservation.
`IPKG_NO_SCRIPT=1` keeps live service hooks disabled in this unbooted fixture;
the separate offline lifecycle tests exercise hook guards. This is not a booted
router/procd/firewall test.

The IPK package suite executes the actual version, build, and manifest blocks from
`.github/workflows/makefile.yml` in a temporary workspace for both 23.05 and 24.10.
Set `OPENWRT_BASE=23.05` or `24.10` to select just one matrix case. It verifies the
`openwrt-<base>-` filename prefixes without changing internal package identities. It checks both packages' gzip/tar containers, control
metadata, root ownership, payload contents, executable modes, and the offline
postinst guard. It requires Bash, GNU tar, and GNU coreutils (the CI runner
provides them). On macOS, prepend the Homebrew `gnu-tar` and `coreutils`
`libexec/gnubin` directories to PATH.
`validate_ipks.py` validates an existing generated or downloaded pair without
rebuilding it. Supply a directory containing exactly that series' two IPKs,
`packages.tsv`, and `SHA256SUMS` (other non-IPK checkout files are allowed):

```sh
python3 tests/validate_ipks.py "$ARTIFACT_DIR" 23.05 2.0.0 --release 1
```

Use `24.10` for that series. On macOS and Linux, Python 3 and its standard library are sufficient;
GNU tar and the OpenWrt SDK are not required for this artifact-only check. Source
comparison defaults to the validator's repository, independent of the working
directory; `--source-root /path/to/matching/checkout` selects another source tree.
Validation errors fail the command and GitHub job, including under Python's
optimization mode. Unit tests cover corrupt/malformed containers, metadata,
checksums, unsafe entries, ownership/permissions, and payload mismatches.

Both IPK matrix jobs run the artifact-only validator after writing manifests and
before upload. The 25.12 job separately validates the actual generated APK feed
with its native SDK tools before upload; this IPK validator does not parse APKs.
The workflow also checks the exact release artifacts with OpenWrt 23.05.5 and
24.10.0 `opkg --noaction install` in checksum-pinned, network-isolated root filesystems. That
check allows expected missing-dependency errors after successful metadata parsing;
it does not claim to validate a complete router installation or runtime behavior.

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
