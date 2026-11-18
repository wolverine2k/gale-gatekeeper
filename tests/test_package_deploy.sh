#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/packages" "$TMP/feed" "$TMP/control" "$TMP/data" "$TMP/router/etc/apk/keys" "$TMP/router/etc/config" "$TMP/router/tmp"
export TEST_LOG="$TMP/log" TEST_RELEASE=23.05.5 TEST_MANAGER=opkg TEST_ROUTER_ROOT="$TMP/router" TEST_FEED="$TMP/feed" TEST_STATE="$TMP/state"
export REAL_JQ=$(command -v jq)
export APK_CONFIG=/unsafe/allow-untrusted.conf
cat > "$TMP/bin/ssh" <<'STUB'
#!/bin/bash
set -eu
script=$(cat)
printf '%s\n%s\n' "$*" "$script" >> "$TEST_LOG"
case "$script" in
    *GK_DISCOVER*) printf '%s\n%s\n%s\n' "$TEST_RELEASE" "$TEST_MANAGER" "${TEST_DISTRO:-OpenWrt}" ;;
    *GK_PREFLIGHT*|*GK_APK_VERIFY*|*GK_INSTALL*)
        [ "${TEST_PREFLIGHT_FAIL:-0}" = 0 ] || exit 1
        command=${!#}
        command=${command//\/tmp\/gatekeeper-deploy-/$TEST_ROUTER_ROOT\/tmp\/gatekeeper-deploy-}
        printf '%s\n' "$script" | sed "s|/etc/|$TEST_ROUTER_ROOT/etc/|g;s|/usr/|$TEST_ROUTER_ROOT/usr/|g;s|/www/|$TEST_ROUTER_ROOT/www/|g;s|/tmp/gatekeeper-verify|$TEST_ROUTER_ROOT/tmp/gatekeeper-verify|g" | eval "$command"
        ;;
    '') [ "${!#}" = "echo 'Connection OK'" ] || exit 97 ;;
    *) exit 97 ;;
esac
STUB
cat > "$TMP/bin/scp" <<'STUB'
#!/bin/bash
set -eu
printf 'SCP %s\n' "$*" >> "$TEST_LOG"
while [ "$#" -gt 2 ]; do shift; done
destination="$TEST_ROUTER_ROOT${2#*:}"
cp "$1" "$destination"
[ "${TEST_REMOTE_TAMPER:-0}" = 0 ] || printf x >> "$destination"
STUB
cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
set -eu
printf 'CURL %s\n' "$*" >> "$TEST_LOG"
[ "$1" = --disable ] || exit 1
while [ "$#" -gt 0 ]; do
    case "$1" in --output) output=$2; shift 2 ;; *) url=$1; shift ;; esac
done
case "$url" in https://feed.example/releases/packages.adb|https://feed.example/releases/*.apk) cp "$TEST_FEED/${url##*/}" "$output" ;; *) exit 1 ;; esac
STUB
cat > "$TMP/bin/opkg" <<'STUB'
#!/bin/bash
set -eu
printf 'OPKG %s\n' "$*" >> "$TEST_LOG"
case "$1" in
    print-architecture) printf 'arch all 1\n' ;;
    files) [ "${TEST_OWNER:-unmanaged}" = managed ] || exit 1; printf '%s/etc/config/gatekeeper\n' "$TEST_ROUTER_ROOT" ;;
    status)
        case "$2" in
            gatekeeper|luci-app-gatekeeper)
                value=${TEST_RUNTIME:-}; [ "$2" = gatekeeper ] || value=${TEST_LUCI:-}
                [ ! -f "$TEST_STATE.$2" ] || value=$(cat "$TEST_STATE.$2")
                ;;
            *) [ "${TEST_DEPENDENCIES:-present}" = present ] || exit 1; value=1.0 ;;
        esac
        [ -n "$value" ] || exit 0
        printf 'Package: %s\nStatus: install ok installed\nVersion: %s\n' "$2" "$value"
        ;;
    compare-versions) [ "${TEST_DOWNGRADE:-0}" = 0 ] ;;
    --noaction) [ "${TEST_DEPENDENCIES:-present}" = present ] ;;
    install)
        if [ "${TEST_NOOP:-0}" = 0 ]; then
            for file in "$@"; do file=${file#./}; file=${file#openwrt-??.??-}; case "$file" in gatekeeper_*) printf '1.2.3-1' > "$TEST_STATE.gatekeeper" ;; luci-app-gatekeeper_*) printf '1.2.3-1' > "$TEST_STATE.luci-app-gatekeeper" ;; esac; done
        fi
        ;;
    *) exit 1 ;;
esac
STUB
cat > "$TMP/bin/apk" <<'STUB'
#!/bin/bash
set -eu
[ "${APK_CONFIG:-}" = /dev/null ] || { printf 'Unsafe APK_CONFIG\n' >&2; exit 1; }
printf 'APK_CONFIG=%s APK %s\n' "$APK_CONFIG" "$*" >> "$TEST_LOG"
case "$1" in
    --print-arch) printf 'x86_64\n'; exit 0 ;;
    query)
        name=${!#}; value=${TEST_RUNTIME:-}; [ "$name" = gatekeeper ] || value=${TEST_LUCI:-}
        [ ! -f "$TEST_STATE.$name" ] || value=$(cat "$TEST_STATE.$name")
        if [ -z "$value" ]; then printf '[]\n'; else "$REAL_JQ" -n --arg n "$name" --arg v "$value" '[{name:$n,version:$v}]'; fi
        exit 0 ;;
    info)
        [ "${TEST_OWNER:-unmanaged}" != unmanaged ] || exit 1
        owner=gatekeeper; [ "${TEST_OWNER:-}" != prefix ] || owner=gatekeeper-custom
        printf '%s is owned by %s-%s\n' "$3" "$owner" "${TEST_RUNTIME:-1.2.2-r1}"
        exit 0 ;;
    version)
        if [ -n "${TEST_NATIVE_APK:-}" ]; then exec "$TEST_NATIVE_APK" "$@"; fi
        if [ "${TEST_DOWNGRADE:-0}" = 1 ]; then printf '>\n'; elif [ "$3" = "$4" ]; then printf '=\n'; else printf '<\n'; fi
        exit 0 ;;
esac
kind=; keys=; repo=; output=; simulate=0; files=()
original=("$@")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keys-dir) keys=$2; shift 2 ;;
        --repository) repo=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --repositories-file|--format|--pkgname-spec) shift 2 ;;
        verify|adbdump|fetch|add) kind=$1; shift ;;
        --simulate) simulate=1; shift ;;
        --*) shift ;;
        *) files+=("$1"); shift ;;
    esac
done
if [ -n "${TEST_NATIVE_APK:-}" ]; then
    case "$kind" in
        verify|adbdump) exec "$TEST_NATIVE_APK" "${original[@]}" ;;
        fetch) exec "$TEST_NATIVE_APK" --root "$TEST_NATIVE_ROOT" "${original[@]}" ;;
    esac
fi
case "$kind" in
    verify) for file in "${files[@]}"; do "$REAL_JQ" -e '.signer == "good"' "$file" >/dev/null; done ;;
    adbdump) cat "${files[0]}" ;;
    fetch)
        for name in gatekeeper luci-app-gatekeeper; do
            file="$name-1.2.3-r1.apk"
            source_file=$("$REAL_JQ" -r --arg n "$name" '.packages[]|select(.name==$n)|.filename' "$repo")
            expected=$("$REAL_JQ" -r --arg n "$name" '.packages[]|select(.name==$n)|.hashes' "$repo")
            actual=$(shasum -a 256 "${repo%/*}/$source_file" | awk '{print $1}')
            [ "$actual" = "$expected" ] || exit 1
            cp "${repo%/*}/$source_file" "$output/$file"
        done ;;
    add)
        [ "${TEST_DEPENDENCIES:-present}" = present ] || exit 1
        if [ "$simulate" = 1 ] && [ -n "${TEST_NATIVE_APK:-}" ]; then
            exec "$TEST_NATIVE_APK" --root "$TEST_NATIVE_ROOT" --keys-dir "$TEST_ROUTER_ROOT/etc/apk/keys" "${original[@]}"
        fi
        if [ "$simulate" = 0 ] && [ "${TEST_NOOP:-0}" = 0 ]; then
            for file in "${files[@]}"; do
                case "${file##*/}" in gatekeeper-*) printf '1.2.3-r1' > "$TEST_STATE.gatekeeper" ;; luci-app-gatekeeper-*) printf '1.2.3-r1' > "$TEST_STATE.luci-app-gatekeeper" ;; esac
            done
        fi ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/ssh" "$TMP/bin/scp" "$TMP/bin/curl" "$TMP/bin/apk" "$TMP/bin/opkg"
export PATH="$TMP/bin:$PATH"
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
make_pair() {
    : > "$TMP/packages/packages.tsv"; : > "$TMP/packages/SHA256SUMS"
    for name in gatekeeper luci-app-gatekeeper; do
        printf 'Package: %s\nVersion: %s\nArchitecture: all\nDepends: libc\n' "$name" "${TEST_METADATA_VERSION:-1.2.3-1}" > "$TMP/control/control"
        printf '/etc/config/gatekeeper\n' > "$TMP/control/conffiles"
        tar -czf "$TMP/control.tar.gz" -C "$TMP/control" ./control ./conffiles
        tar -czf "$TMP/data.tar.gz" -C "$TMP/data" .
        printf '2.0\n' > "$TMP/debian-binary"
        file="${FIXTURE_PREFIX:-}${name}_1.2.3-1_all.ipk"
        tar -czf "$TMP/packages/$file" -C "$TMP" ./debian-binary ./control.tar.gz ./data.tar.gz
        hash=$(sha "$TMP/packages/$file")
        printf 'opkg\t%s\t1.2.3-1\tall\t%s\t%s\n' "$name" "$file" "$hash" >> "$TMP/packages/packages.tsv"
        printf '%s  %s\n' "$hash" "$file" >> "$TMP/packages/SHA256SUMS"
    done
}
if [ -n "${TEST_NATIVE_APK:-}" ]; then
    mkdir -p "$TMP/native/keys" "$TMP/native/root"
    export TEST_NATIVE_ROOT="$TMP/native/root"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/native/good.key" 2>/dev/null
    openssl pkey -in "$TMP/native/good.key" -pubout -out "$TMP/native/keys/good.pem" 2>/dev/null
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/native/wrong.key" 2>/dev/null
    openssl pkey -in "$TMP/native/wrong.key" -pubout -out "$TMP/native/keys/wrong.pem" 2>/dev/null
    APK_CONFIG=/dev/null "$TEST_NATIVE_APK" --root "$TEST_NATIVE_ROOT" --initdb --no-network add >/dev/null
fi
make_apks() {
    rm -f "$TMP/packages/"*.apk "$TMP/feed/"*.apk
    : > "$TMP/packages/packages.tsv"; : > "$TMP/packages/SHA256SUMS"
    for name in gatekeeper luci-app-gatekeeper; do
        file="${FIXTURE_PREFIX:-}$name-1.2.3-r1.apk"
        if [ -n "${TEST_NATIVE_APK:-}" ]; then
            key=good; [ "${FIXTURE_SIGNER:-good}" = good ] || key=wrong
            APK_CONFIG=/dev/null "$TEST_NATIVE_APK" mkpkg --compression none -I "name:$name" -I "version:${FIXTURE_VERSION:-1.2.3-r1}" -I arch:noarch -I "description:${FIXTURE_BUILD:-one}" --sign-key "$TMP/native/$key.key" -o "$TMP/packages/$file"
        else
            "$REAL_JQ" -n --arg n "$name" --arg v "${FIXTURE_VERSION:-1.2.3-r1}" --arg b "${FIXTURE_BUILD:-one}" --arg s "${FIXTURE_SIGNER:-good}" '{info:{name:$n,version:$v,arch:"noarch"},build:$b,signer:$s}' > "$TMP/packages/$file"
        fi
        hash=$(sha "$TMP/packages/$file")
        printf 'apk\t%s\t1.2.3-r1\tnoarch\t%s\t%s\n' "$name" "$file" "$hash" >> "$TMP/packages/packages.tsv"
        printf '%s  %s\n' "$hash" "$file" >> "$TMP/packages/SHA256SUMS"
    done
    if [ -n "${TEST_NATIVE_APK:-}" ]; then
        APK_CONFIG=/dev/null "$TEST_NATIVE_APK" mkndx --keys-dir "$TMP/native/keys" --sign-key "$TMP/native/good.key" --pkgname-spec "${FIXTURE_PREFIX:-}"'${name}-${version}.apk' --output "$TMP/packages/packages.adb" "$TMP/packages/"*.apk >/dev/null
        cp "$TMP/native/keys/good.pem" "$TMP/packages/feed-public.pem"
    else
        runtime="${FIXTURE_PREFIX:-}gatekeeper-1.2.3-r1.apk"
        companion="${FIXTURE_PREFIX:-}luci-app-gatekeeper-1.2.3-r1.apk"
        "$REAL_JQ" -n --arg f1 "$runtime" --arg f2 "$companion" --arg h1 "$(sha "$TMP/packages/$runtime")" --arg h2 "$(sha "$TMP/packages/$companion")" --arg v "${FIXTURE_VERSION:-1.2.3-r1}" --argjson s1 "$(wc -c < "$TMP/packages/$runtime")" --argjson s2 "$(wc -c < "$TMP/packages/$companion")" '{signer:"good",packages:[{name:"gatekeeper",version:$v,arch:"noarch",filename:$f1,hashes:$h1,"file-size":$s1},{name:"luci-app-gatekeeper",version:$v,arch:"noarch",filename:$f2,hashes:$h2,"file-size":$s2}]}' > "$TMP/packages/packages.adb"
        printf 'public-key-fixture\n' > "$TMP/packages/feed-public.pem"
    fi
    printf '%s  packages.adb\n' "$(sha "$TMP/packages/packages.adb")" >> "$TMP/packages/SHA256SUMS"
    cp "$TMP/packages/"*.apk "$TMP/packages/packages.adb" "$TMP/feed/"
}
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }
fail() { cat "$TMP/output" >&2; printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run() { : > "$TEST_LOG"; rm -f "$TEST_STATE.gatekeeper" "$TEST_STATE.luci-app-gatekeeper"; bash "$ROOT/deploy.sh" router.local --packages "$TMP/packages" "$@" > "$TMP/output" 2>&1; }
reject() { if run "$@"; then fail "unexpected acceptance: $*"; fi; }
clean_stage() { [ -z "$(ls -A "$TEST_ROUTER_ROOT/tmp")" ] || fail 'verification stage leaked'; }
make_pair
run --dry-run --luci || fail 'package dispatch dry run'
! grep -Eq 'SCP|GK_INSTALL' "$TEST_LOG" || fail 'IPK dry run wrote router'
ok 'dispatch and read-only IPK dry run with legacy basenames'
for base in 23.05 24.10; do
    FIXTURE_PREFIX="openwrt-$base-" make_pair
    TEST_RELEASE="$base.5" run --luci || fail "prefixed OpenWrt $base IPK install"
    clean_stage
    other=23.05; [ "$base" != 23.05 ] || other=24.10
    TEST_RELEASE="$other.5" reject --dry-run
    ! grep -q GK_PREFLIGHT "$TEST_LOG" || fail 'cross-base IPK reached preflight'
done
FIXTURE_PREFIX=openwrt-25.12- make_pair; reject --dry-run
FIXTURE_PREFIX=openwrt-99.99- make_pair; reject --dry-run
FIXTURE_PREFIX=renamed- make_pair; reject --dry-run
make_pair
ok 'base-prefixed 23.05 and 24.10 IPKs install; cross-base and unknown prefixes refused'
for flag in --ask-password --no-config --no-restart --restart-only --scripts-only --config-only --luci-only; do reject "$flag"; [ ! -s "$TEST_LOG" ] || fail 'legacy conflict reached SSH'; done
(cd "$ROOT" && bash ./deploy.sh router.local --dry-run) > "$TMP/output" 2>&1 || fail 'raw dry run regressed'
ok 'legacy flags rejected and raw deployment preserved'
for release in 22.03.7 SNAPSHOT 26.01.0; do TEST_RELEASE=$release reject --dry-run; done
TEST_DISTRO=OtherOS reject --dry-run
TEST_MANAGER=ambiguous reject --dry-run
reject --package-manager apk --dry-run
ok 'release, distro and native manager qualification'
printf x >> "$TMP/packages/gatekeeper_1.2.3-1_all.ipk"; reject --dry-run
TEST_METADATA_VERSION=1.2.4-1 make_pair; reject --dry-run
make_pair
sed 's/luci-app-gatekeeper\t1.2.3-1/luci-app-gatekeeper\t1.2.4-1/' "$TMP/packages/packages.tsv" > "$TMP/changed"; mv "$TMP/changed" "$TMP/packages/packages.tsv"; reject --dry-run
make_pair
ok 'local hashes, metadata and exact pair validation'
TEST_DOWNGRADE=1 TEST_RUNTIME=9.0-1 reject --dry-run
TEST_LUCI=1.2.2-1 reject --dry-run
TEST_NOOP=1 TEST_RUNTIME=1.2.2-1 reject --luci
TEST_LUCI=1.2.3-1 run || fail 'same-release installed IPK companion rejected'
ok 'IPK downgrade, companion mismatch and postinstall no-op rejection'
TEST_REMOTE_TAMPER=1 reject --luci
! grep -q 'OPKG install' "$TEST_LOG" || fail 'remote tampering reached install'
run --luci || fail 'IPK install'
clean_stage
ok 'remote IPK hashes and final installed versions'
if bash "$ROOT/opkg/deploy-package.sh" 'router;touch /tmp/injected' --packages "$TMP/packages" --dry-run > "$TMP/output" 2>&1; then fail 'host injection'; fi
reject --dry-run --feed-url 'https://feed.invalid/;id'
ok 'injection rejected'
export TEST_RELEASE=25.12.0 TEST_MANAGER=apk
make_apks
reject --dry-run
reject --dry-run --feed-url https://feed.example/releases
cp "$TMP/packages/feed-public.pem" "$TEST_ROUTER_ROOT/etc/apk/keys/project.pem"
run --dry-run --luci --feed-url https://feed.example/releases/ || fail 'signed feed dry run'
grep -q 'CURL .*https://feed.example/releases/packages.adb' "$TEST_LOG" || fail 'index URL is not flat .adb'
grep -q 'temporary verification files cleaned' "$TMP/output" || fail 'dry run semantics misleading'
clean_stage
ok 'legacy signed APK/index verification uses flat feed and cleans temporary dry-run files'
FIXTURE_PREFIX=openwrt-25.12- make_apks
run --dry-run --luci --feed-url https://feed.example/releases || fail 'base-prefixed signed APK dry run'
grep -q 'CURL .*https://feed.example/releases/openwrt-25.12-gatekeeper-1.2.3-r1.apk' "$TEST_LOG" || fail 'prefixed APK URL not verified'
run --luci --feed-url https://feed.example/releases || fail 'base-prefixed signed APK install'
clean_stage
cp "$TMP/packages/packages.adb" "$TMP/old-prefixed.adb"
FIXTURE_PREFIX=openwrt-25.12- FIXTURE_BUILD=two make_apks
cp "$TMP/old-prefixed.adb" "$TMP/packages/packages.adb"
cp "$TMP/old-prefixed.adb" "$TMP/feed/packages.adb"
awk '$2 != "packages.adb"' "$TMP/packages/SHA256SUMS" > "$TMP/sums"
printf '%s  packages.adb\n' "$(sha "$TMP/old-prefixed.adb")" >> "$TMP/sums"; mv "$TMP/sums" "$TMP/packages/SHA256SUMS"
reject --dry-run --feed-url https://feed.example/releases
grep -q 'APK .* fetch' "$TEST_LOG" || fail 'prefixed index-to-APK binding was not exercised'
for prefix in openwrt-23.05- openwrt-24.10- openwrt-99.99- renamed-; do
    FIXTURE_PREFIX=$prefix make_apks
    reject --dry-run --feed-url https://feed.example/releases
    ! grep -q GK_PREFLIGHT "$TEST_LOG" || fail 'wrong-base APK reached preflight'
done
make_apks
ok 'base-prefixed 25.12 signed APK install and index binding; wrong and unknown prefixes refused'
TEST_DOWNGRADE=1 TEST_RUNTIME=9.0-r1 reject --dry-run --feed-url https://feed.example/releases
TEST_LUCI=1.2.2-r1 reject --dry-run --feed-url https://feed.example/releases
TEST_NOOP=1 TEST_RUNTIME=1.2.2-r1 reject --luci --feed-url https://feed.example/releases
TEST_LUCI=1.2.3-r1 run --feed-url https://feed.example/releases || fail 'same-release installed APK companion rejected'
ok 'APK downgrade, companion mismatch and postinstall no-op rejection'
FIXTURE_VERSION=1.2.4-r1 make_apks
reject --dry-run --feed-url https://feed.example/releases
make_apks
cp "$TMP/feed/packages.adb" "$TMP/old.adb"
FIXTURE_BUILD=two make_apks
cp "$TMP/old.adb" "$TMP/feed/packages.adb"
reject --dry-run --feed-url https://feed.example/releases
cp "$TMP/old.adb" "$TMP/packages/packages.adb"
awk '$2 != "packages.adb"' "$TMP/packages/SHA256SUMS" > "$TMP/sums"
printf '%s  packages.adb\n' "$(sha "$TMP/old.adb")" >> "$TMP/sums"; mv "$TMP/sums" "$TMP/packages/SHA256SUMS"
reject --dry-run --feed-url https://feed.example/releases
grep -q 'APK .* fetch' "$TEST_LOG" || fail 'index-to-APK checksum binding was not exercised'
if [ -n "${TEST_NATIVE_APK:-}" ]; then cp "$TMP/native/keys/wrong.pem" "$TEST_ROUTER_ROOT/etc/apk/keys/other-trusted.pem"; fi
FIXTURE_SIGNER=wrong make_apks
reject --dry-run --feed-url https://feed.example/releases
make_apks
if [ -n "${TEST_NATIVE_APK:-}" ]; then
    APK_CONFIG=/dev/null "$TEST_NATIVE_APK" mkndx --keys-dir "$TMP/native/keys" --sign-key "$TMP/native/wrong.key" --output "$TMP/packages/packages.adb" "$TMP/packages/"*.apk >/dev/null
else
    "$REAL_JQ" '.signer="wrong"' "$TMP/packages/packages.adb" > "$TMP/changed"; mv "$TMP/changed" "$TMP/packages/packages.adb"
fi
awk '$2 != "packages.adb"' "$TMP/packages/SHA256SUMS" > "$TMP/sums"
printf '%s  packages.adb\n' "$(sha "$TMP/packages/packages.adb")" >> "$TMP/sums"; mv "$TMP/sums" "$TMP/packages/SHA256SUMS"
cp "$TMP/packages/packages.adb" "$TMP/feed/packages.adb"
reject --dry-run --feed-url https://feed.example/releases
make_apks
ok 'self-consistent bad metadata, same-version rebuilt bytes/index and wrong APK/index publisher rejected'
TEST_DEPENDENCIES=missing reject --dry-run --feed-url https://feed.example/releases
printf 'secret-token-do-not-display\n' > "$TEST_ROUTER_ROOT/etc/config/gatekeeper"
reject --dry-run --feed-url https://feed.example/releases
TEST_OWNER=prefix TEST_RUNTIME=1.2.2-r1 reject --dry-run --feed-url https://feed.example/releases
TEST_OWNER=managed TEST_RUNTIME=1.2.2-r1 run --dry-run --feed-url https://feed.example/releases || fail 'exact APK owner rejected'
[ "$(cat "$TEST_ROUTER_ROOT/etc/config/gatekeeper")" = secret-token-do-not-display ] || fail 'credentials changed'
! grep -q secret-token "$TMP/output" || fail 'credentials printed'
TEST_OWNER=managed TEST_RUNTIME=1.2.2-r1 run --luci --feed-url https://feed.example/releases || fail 'verified local APK install'
! grep -Eq 'force-maintainer|uci |fw4 |/etc/init.d/.*restart|--allow-untrusted|APK_CONFIG=/unsafe' "$TEST_LOG" || fail 'unsafe trust/config/service operation'
clean_stage
ok 'exact ownership, installed prerequisites, safe APK_CONFIG and native configuration handling'
printf '%s package deploy tests passed (native APK: %s)\n' "$pass" "${TEST_NATIVE_APK:-mock}"
