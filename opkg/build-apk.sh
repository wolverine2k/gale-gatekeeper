#!/bin/sh
set -eu
umask 022
export APK_CONFIG=/dev/null

fail() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
usage() { printf '%s\n' 'Usage: sh opkg/build-apk.sh --sdk PATH --output DIR --version VERSION --release RELEASE --signing-key PATH [--jobs N]'; }
sdk= output= version= release= signing_key= jobs=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sdk|--output|--version|--release|--signing-key|--jobs)
            [ "$#" -ge 2 ] || fail 'Missing option value'
            case "$1" in
                --sdk) sdk=$2 ;; --output) output=$2 ;; --version) version=$2 ;;
                --release) release=$2 ;; --signing-key) signing_key=$2 ;; --jobs) jobs=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail 'Unknown option' ;;
    esac
done
[ -n "$sdk" ] && [ -n "$output" ] && [ -n "$version" ] && [ -n "$release" ] && [ -n "$signing_key" ] || { usage >&2; fail 'All required options must be provided'; }
case "$version" in [0-9]*) ;; *) fail 'Version must start with a digit' ;; esac
case "$version" in *[!0-9A-Za-z._]*) fail 'Invalid version' ;; esac
case "$release" in ''|0*|*[!0-9]*) fail 'Release must be a positive integer' ;; esac
case "$jobs" in ''|0*|*[!0-9]*) fail 'Jobs must be a positive integer' ;; esac
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
[ -d "$sdk" ] || fail 'SDK directory does not exist'
sdk=$(CDPATH= cd -- "$sdk" && pwd -P)
for path in "$sdk" "$repo" "$output"; do
    case "$path" in *[!A-Za-z0-9_./+-]*) fail 'Build paths must not contain whitespace or shell metacharacters' ;; esac
done
[ -f "$sdk/include/version.mk" ] && grep -Eq 'VERSION_NUMBER.*25\.12\.0' "$sdk/include/version.mk" || fail 'The official OpenWrt 25.12.0 SDK is required'
[ -f "$sdk/include/package-pack.mk" ] && [ -f "$sdk/rules.mk" ] || fail 'Invalid SDK layout'
apk=$sdk/staging_dir/host/bin/apk
[ -x "$apk" ] || fail 'SDK host apk is missing'
"$apk" version --check "$version-r$release" >/dev/null 2>&1 || fail 'Version is not valid in native APK format'
[ -f "$signing_key" ] && [ ! -L "$signing_key" ] && [ -r "$signing_key" ] || fail 'Signing key must be a readable local private-key file'
signing_key=$(CDPATH= cd -- "$(dirname -- "$signing_key")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "$signing_key")")
openssl pkey -in "$signing_key" -passin pass: -check -noout >/dev/null 2>&1 || fail 'Signing key must be an unencrypted valid private key'
[ ! -e "$output" ] || [ -d "$output" ] || fail 'Output must be a directory'
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd -P)
case "$signing_key" in "$output"/*) fail 'Private key must not be inside the output directory' ;; esac
[ -z "$(ls -A "$output")" ] || fail 'Output directory must be empty'
package=$sdk/package/gatekeeper
[ ! -e "$package" ] || fail 'SDK package/gatekeeper already exists; use a clean SDK package directory'
work=$(mktemp -d)
if ! mkdir "$package"; then
    rm -rf "$work"
    fail 'Unable to reserve SDK package/gatekeeper directory'
fi
cleanup() { rm -rf "$work" "$package"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir "$package/src"
cp "$repo/opkg/Makefile" "$package/Makefile"
for source in \
    gatekeeper.sh tg_bot.sh gatekeeper_trigger.sh dnsmasq_trigger.sh gatekeeper_sync.sh \
    gatekeeper.nft gatekeeper_init tg_gatekeeper gatekeeper_trigger_listener \
    opkg/etc/config/gatekeeper opkg/usr/lib/gatekeeper/restore_helpers.sh \
    opkg/luci/usr/libexec/rpcd/gatekeeper \
    opkg/luci/usr/share/luci/menu.d/luci-app-gatekeeper.json \
    opkg/luci/usr/share/rpcd/acl.d/luci-app-gatekeeper.json \
    opkg/luci/htdocs/luci-static/resources/view/gatekeeper/overview.js \
    opkg/luci/htdocs/luci-static/resources/view/gatekeeper/devices.js \
    opkg/luci/htdocs/luci-static/resources/view/gatekeeper/blacklist.js \
    opkg/luci/htdocs/luci-static/resources/view/gatekeeper/schedules.js \
    opkg/luci/htdocs/luci-static/resources/view/gatekeeper/backup_restore.js \
    opkg/luci/htdocs/luci-static/resources/view/gatekeeper/settings.js; do
    [ -f "$repo/$source" ] && [ ! -L "$repo/$source" ] || fail "Missing or symlinked package source: $source"
    mkdir -p "$package/src/$(dirname -- "$source")"
    cp "$repo/$source" "$package/src/$source"
done
mkdir -p "$work/feed" "$work/keys"
openssl pkey -in "$signing_key" -passin pass: -pubout -out "$work/keys/feed-public.pem" 2>/dev/null || fail 'Unable to derive public feed key'
ln -s "$signing_key" "$work/signing-key"
GATEKEEPER_APK=$apk GATEKEEPER_SIGNING_KEY=$work/signing-key
export GATEKEEPER_APK GATEKEEPER_SIGNING_KEY
unset PKG_VERSION PKG_RELEASE
make -C "$sdk" defconfig CONFIG_USE_APK=y CONFIG_SIGNED_PACKAGES=y \
    BUILD_KEY_APK_SEC="$work/signing-key" BUILD_KEY_APK_PUB="$work/keys/feed-public.pem"
make -C "$sdk" package/gatekeeper/clean CONFIG_USE_APK=y CONFIG_SIGNED_PACKAGES=y \
    BUILD_KEY_APK_SEC="$work/signing-key" BUILD_KEY_APK_PUB="$work/keys/feed-public.pem" \
    GATEKEEPER_VERSION="$version" GATEKEEPER_RELEASE="$release" GATEKEEPER_SOURCE_DIR="$package/src"
make -C "$sdk" -j"$jobs" package/gatekeeper/compile \
    CONFIG_USE_APK=y CONFIG_SIGNED_PACKAGES=y CONFIG_PACKAGE_gatekeeper=m CONFIG_PACKAGE_luci-app-gatekeeper=m \
    GATEKEEPER_VERSION="$version" GATEKEEPER_RELEASE="$release" GATEKEEPER_SOURCE_DIR="$package/src" \
    BUILD_KEY_APK_SEC="$work/signing-key" BUILD_KEY_APK_PUB="$work/keys/feed-public.pem" \
    FAKEROOT="$sdk/staging_dir/host/bin/fakeroot sh $repo/opkg/apk-sign.sh" V=s
for name in gatekeeper luci-app-gatekeeper; do
    filename=$name-$version-r$release.apk
    find "$sdk/bin" -type f -name "$filename" > "$work/matches"
    [ "$(wc -l < "$work/matches" | tr -d ' ')" = 1 ] || fail "Expected exactly one SDK package: $filename"
    IFS= read -r artifact < "$work/matches"
    filename=openwrt-25.12-$filename
    cp "$artifact" "$work/feed/$filename"
    "$apk" verify --keys-dir "$work/keys" "$work/feed/$filename"
done
(cd "$work/feed" && "$apk" mkndx --keys-dir "$work/keys" --sign-key "$signing_key" --pkgname-spec 'openwrt-25.12-${name}-${version}.apk' --output packages.adb ./*.apk)
"$apk" verify --keys-dir "$work/keys" "$work/feed/packages.adb"
: > "$work/feed/packages.tsv"
for name in gatekeeper luci-app-gatekeeper; do
    filename=openwrt-25.12-$name-$version-r$release.apk
    hash=$(sha256sum "$work/feed/$filename" | cut -d ' ' -f 1)
    printf 'apk\t%s\t%s-r%s\tnoarch\t%s\t%s\n' "$name" "$version" "$release" "$filename" "$hash" >> "$work/feed/packages.tsv"
done
cp "$work/keys/feed-public.pem" "$work/feed/"
(cd "$work/feed" && sha256sum ./*.apk packages.adb feed-public.pem packages.tsv | sed 's|  \./|  |' > SHA256SUMS)
cp "$work/feed/"*.apk "$work/feed/packages.adb" "$work/feed/feed-public.pem" "$work/feed/packages.tsv" "$work/feed/SHA256SUMS" "$output/"
printf '%s\n' 'Built signed APK feed with public trust key feed-public.pem'
