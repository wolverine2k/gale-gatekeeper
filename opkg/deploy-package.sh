#!/bin/bash
set -euo pipefail
export LC_ALL=C
fail() { printf 'Package deployment refused: %s\n' "$*" >&2; exit 1; }
usage() { printf '%s\n' 'Usage: bash opkg/deploy-package.sh ROUTER --packages DIR [--luci] [--dry-run] [--package-manager auto|opkg|apk] [--feed-url HTTPS_URL]'; }
[ "$#" -gt 0 ] || { usage; exit 1; }
router=$1
shift
[[ "$router" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail 'Use a hostname or IPv4 address without SSH options or shell characters.'
packages= manager=auto feed= luci=0 dry=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --packages|--package-manager|--feed-url)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "Missing value for $1"
            case "$1" in
                --packages) [ -z "$packages" ] || fail 'Duplicate --packages'; packages=$2 ;;
                --package-manager) manager=$2 ;;
                --feed-url) feed=$2 ;;
            esac
            shift 2 ;;
        --luci) luci=1; shift ;;
        --dry-run) dry=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --ask-password) fail '--ask-password is unsupported in package mode; configure SSH keys or an SSH agent first.' ;;
        *) fail "Unsupported package-mode option: $1 (legacy deployment flags cannot be combined with --packages)" ;;
    esac
done
case "$manager" in auto|opkg|apk) ;; *) fail 'Invalid package manager' ;; esac
[ -n "$packages" ] && [ -d "$packages" ] || fail '--packages must name an artifact directory'
packages=$(cd "$packages" && pwd)
if [ -n "$feed" ]; then
    [[ "$feed" =~ ^https://[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?(/[a-zA-Z0-9._~/-]*)?$ ]] || fail 'Feed URL must be HTTPS without credentials, query parameters or shell characters'
fi
hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
remote() {
    local command='sh -s --' arg
    for arg in "$@"; do
        [[ "$arg" != *"'"* ]] || fail 'Unsafe remote argument'
        command="$command '$arg'"
    done
    ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$router" "$command"
}
discover() {
remote <<'REMOTE'
set -eu
: GK_DISCOVER
[ -r /etc/openwrt_release ] || exit 1
awk -F "'" '/^DISTRIB_RELEASE=/{print $2}' /etc/openwrt_release
opkg_ok=0
apk_ok=0
if command -v opkg >/dev/null 2>&1 && opkg --version >/dev/null 2>&1 && { [ -f /usr/lib/opkg/status ] || [ -f /var/lib/opkg/status ]; }; then opkg_ok=1; fi
if command -v apk >/dev/null 2>&1 && APK_CONFIG=/dev/null apk --version >/dev/null 2>&1 && [ -f /lib/apk/db/installed ]; then apk_ok=1; fi
case "$opkg_ok:$apk_ok" in
    1:0) printf 'opkg\n' ;;
    0:1) printf 'apk\n' ;;
    *) printf 'ambiguous\n' ;;
esac
awk -F "'" '/^DISTRIB_ID=/{print $2}' /etc/openwrt_release
REMOTE
}
discovery=$(discover) || fail 'Could not identify router release and native package database'
release=$(printf '%s\n' "$discovery" | sed -n '1p')
actual=$(printf '%s\n' "$discovery" | sed -n '2p')
[ "$(printf '%s\n' "$discovery" | wc -l | tr -d ' ')" = 3 ] || fail 'Unexpected discovery output'
[ "$(printf '%s\n' "$discovery" | sed -n '3p')" = OpenWrt ] || fail 'DISTRIB_ID must be OpenWrt; release-file claims are not hardware attestation'
case "$release" in
    23.05.[0-9]*|24.10.[0-9]*) expected=opkg ;;
    25.12.[0-9]*) expected=apk ;;
    *) fail "Unqualified OpenWrt release: $release (SNAPSHOT and 22.03 are unsupported)" ;;
esac
[[ "$release" =~ ^(23\.05|24\.10|25\.12)\.[0-9]+$ ]] || fail 'Only qualified stable OpenWrt releases are supported'
[ "$actual" = "$expected" ] || fail 'Native executables/database are ambiguous or incompatible with release'
[ "$manager" = auto ] || [ "$manager" = "$expected" ] || fail 'Explicit manager cannot override release package format'
manager=$expected
base=${release%.*}
[ -r "$packages/packages.tsv" ] && [ -r "$packages/SHA256SUMS" ] || fail 'Missing packages.tsv or SHA256SUMS'
names=() versions=() arches=() files=() hashes=()
while IFS=$'\t' read -r family name version arch file hash extra || [ -n "${family:-}" ]; do
    [ -n "$family" ] && [ -z "${extra:-}" ] || fail 'Invalid manifest row'
    case "$family" in opkg|apk) ;; *) fail 'Unknown manifest package family' ;; esac
    [[ "$name" =~ ^(gatekeeper|luci-app-gatekeeper)$ ]] || fail 'Unexpected package name'
    [[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_~-]*$ ]] || fail 'Unsafe package version'
    [[ "$arch" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || fail 'Unsafe architecture'
    [[ "$file" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*\.(ipk|apk)$ ]] || fail 'Unsafe package basename'
    [[ "$hash" =~ ^[a-f0-9]{64}$ ]] || fail 'Invalid SHA256'
    [ "$family" = "$manager" ] || continue
    case "$family" in
        opkg) legacy="${name}_${version}_${arch}.ipk" ;;
        apk) legacy="$name-$version.apk" ;;
    esac
    [ "$file" = "$legacy" ] || [ "$file" = "openwrt-$base-$legacy" ] || fail "Package basename does not match OpenWrt $base and manifest metadata: $file"
    for old in "${names[@]+${names[@]}}"; do [ "$old" != "$name" ] || fail 'Duplicate manifest package'; done
    [ -f "$packages/$file" ] && [ ! -L "$packages/$file" ] || fail "Missing regular artifact: $file"
    [ "$(hash_file "$packages/$file")" = "$hash" ] || fail "Artifact hash mismatch: $file"
    [ "$(awk -v h="$hash" -v f="$file" '$0 == h "  " f {n++} END {print n+0}' "$packages/SHA256SUMS")" = 1 ] || fail "SHA256SUMS mismatch: $file"
    names+=("$name"); versions+=("$version"); arches+=("$arch"); files+=("$file"); hashes+=("$hash")
done < "$packages/packages.tsv"
[ "${#names[@]}" = 2 ] || fail 'Manifest must contain a runtime and LuCI pair for the selected package manager'
[ "${versions[0]}" = "${versions[1]}" ] || fail 'Runtime and LuCI versions must match exactly'
version=${versions[0]}
dependencies=()
selected=()
for i in 0 1; do
    if [ "$manager" = opkg ]; then
        control=$(tar -xzOf "$packages/${files[$i]}" ./control.tar.gz | tar -xzOf - ./control) || fail 'Cannot read IPK control metadata'
        for field in Package Version Architecture; do
            case "$field" in Package) value=${names[$i]} ;; Version) value=${versions[$i]} ;; Architecture) value=${arches[$i]} ;; esac
            [ "$(printf '%s\n' "$control" | awk -F ': ' -v k="$field" '$1 == k {print $2}')" = "$value" ] || fail "IPK $field metadata mismatch"
        done
        if [ "${names[$i]}" = gatekeeper ]; then
            conffiles=$(tar -xzOf "$packages/${files[$i]}" ./control.tar.gz | tar -xzOf - ./conffiles) || fail 'Missing native conffiles metadata'
            printf '%s\n' "$conffiles" | grep -qx '/etc/config/gatekeeper' || fail 'Runtime package must preserve /etc/config/gatekeeper as a native conffile'
        fi
    fi
    if [ "${names[$i]}" = gatekeeper ] || [ "$luci" = 1 ]; then
        selected+=("$i")
        if [ "$manager" = opkg ]; then
            deps=$(printf '%s\n' "$control" | sed -n 's/^Depends: //p')
            while IFS= read -r dep; do
                dep=$(printf '%s' "$dep" | sed 's/^ *//;s/ *$//')
                [ -n "$dep" ] || continue
                if [[ "$dep" =~ ^([a-zA-Z0-9][a-zA-Z0-9+._-]*)([[:space:]]+\((\>=|\<=|=|\>|\<)[[:space:]]+([a-zA-Z0-9][a-zA-Z0-9.+_~-]*)\))?$ ]]; then
                    dep_name=${BASH_REMATCH[1]}; dep_op=${BASH_REMATCH[3]:-=}; dep_version=${BASH_REMATCH[4]:-}
                else fail "Unsupported dependency expression: $dep"; fi
                if [ "$dep_name" = gatekeeper ]; then
                    [ "$dep_version" = "$version" ] && { [ "$dep_op" = '>=' ] || [ "$dep_op" = = ]; } || fail 'LuCI runtime dependency does not match release'
                    continue
                fi
                dependencies+=("$dep_name:$dep_op:$dep_version")
            done < <(printf '%s\n' "$deps" | tr ',' '\n')
        fi
    fi
done
fingerprint= indexhash=
if [ "$manager" = apk ]; then
    [ -n "$feed" ] || fail 'APK requires --feed-url for a signed HTTPS feed; configure the feed signing key on the router manually first'
    [ -f "$packages/feed-public.pem" ] && [ ! -L "$packages/feed-public.pem" ] || fail 'Missing feed-public.pem (expected pretrusted feed public key)'
    fingerprint=$(hash_file "$packages/feed-public.pem")
    [ -f "$packages/packages.adb" ] && [ ! -L "$packages/packages.adb" ] || fail 'Missing signed packages.adb'
    indexhash=$(hash_file "$packages/packages.adb")
    [ "$(awk -v h="$indexhash" '$0 == h "  packages.adb" {n++} END {print n+0}' "$packages/SHA256SUMS")" = 1 ] || fail 'Signed index SHA256SUMS mismatch'
    feed=${feed%/}
fi
preflight() {
remote "$manager" "$luci" "$feed" "$fingerprint" "$version" "${arches[0]}" "${arches[1]}" "${dependencies[@]+${dependencies[@]}}" <<'REMOTE'
set -eu
: GK_PREFLIGHT
manager=$1; luci=$2; feed=$3; fingerprint=$4; version=$5; arch1=$6; arch2=$7
shift 7
command -v sha256sum >/dev/null 2>&1 || exit 1
if [ "$manager" = opkg ]; then
    for arch in "$arch1" "$arch2"; do
        opkg print-architecture | awk -v a="$arch" '$1 == "arch" && $2 == a {found=1} END {exit !found}' || exit 1
    done
else
    command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || exit 1
    native=$(APK_CONFIG=/dev/null apk --print-arch)
    for arch in "$arch1" "$arch2"; do [ "$arch" = noarch ] || [ "$arch" = "$native" ] || exit 1; done
    trusted=0
    for key in /etc/apk/keys/*; do
        [ -f "$key" ] || continue
        sum=$(sha256sum "$key"); sum=${sum%% *}
        [ "$sum" != "$fingerprint" ] || trusted=1
    done
    [ "$trusted" = 1 ] || { printf 'Expected feed key is not pretrusted; configure trust manually.\n' >&2; exit 1; }
fi
installed_version() {
    if [ "$manager" = opkg ]; then
        status=$(opkg status "$1") || return 1
        if printf '%s\n' "$status" | grep -q '^Status: .* installed$'; then
            printf '%s\n' "$status" | awk -F ': ' '$1 == "Version" {print $2}'
        fi
    else
        APK_CONFIG=/dev/null apk query --from installed --format json --fields name,version "$1" | jq -er --arg n "$1" 'map(select(.name == $n)) | if length == 0 then "" elif length == 1 then .[0].version else error("ambiguous installed version") end'
    fi
}
runtime_installed=$(installed_version gatekeeper)
luci_installed=$(installed_version luci-app-gatekeeper)
for installed in "$runtime_installed" "$luci_installed"; do
    [ -n "$installed" ] || continue
    if [ "$manager" = opkg ]; then
        opkg compare-versions "$installed" '<=' "$version" || { printf 'Downgrade refused\n' >&2; exit 1; }
    else
        comparison=$(APK_CONFIG=/dev/null apk version --test "$installed" "$version")
        [ "$comparison" = '<' ] || [ "$comparison" = = ] || { printf 'Downgrade refused\n' >&2; exit 1; }
    fi
done
[ "$luci" = 1 ] || [ -z "$luci_installed" ] || [ "$luci_installed" = "$version" ] || { printf 'Runtime-only update would leave a mismatched installed LuCI companion\n' >&2; exit 1; }
check_owner() {
    owner=$1; path=$2
    [ -e "$path" ] || [ -L "$path" ] || return 0
    if [ "$manager" = opkg ]; then
        opkg files "$owner" | grep -Fx "$path" >/dev/null || { printf 'Unmanaged/conflicting file: %s\n' "$path" >&2; exit 1; }
    else
        case "$owner" in gatekeeper) owner_version=$runtime_installed ;; luci-app-gatekeeper) owner_version=$luci_installed ;; *) exit 1 ;; esac
        [ -n "$owner_version" ] || exit 1
        result=$(APK_CONFIG=/dev/null apk info --who-owns "$path") || exit 1
        [ "$result" = "$path is owned by $owner-$owner_version" ] || { printf 'Unmanaged/conflicting file: %s\n' "$path" >&2; exit 1; }
    fi
}
for path in /etc/config/gatekeeper /usr/bin/gatekeeper.sh /usr/bin/tg_bot.sh /usr/bin/gatekeeper_trigger.sh /usr/bin/dnsmasq_trigger.sh /usr/bin/gatekeeper_sync.sh /usr/lib/gatekeeper/restore_helpers.sh /etc/gatekeeper/gatekeeper.nft /etc/init.d/gatekeeper_init /etc/init.d/tg_gatekeeper /etc/init.d/gatekeeper_trigger_listener; do check_owner gatekeeper "$path"; done
if [ "$luci" = 1 ]; then
    for path in /usr/libexec/rpcd/gatekeeper /usr/share/luci/menu.d/luci-app-gatekeeper.json /usr/share/rpcd/acl.d/luci-app-gatekeeper.json /www/luci-static/resources/view/gatekeeper/*.js; do check_owner luci-app-gatekeeper "$path"; done
fi
if [ "$manager" = opkg ]; then
    for dep in "$@"; do
        name=${dep%%:*}; rest=${dep#*:}; op=${rest%%:*}; needed=${rest#*:}
        status=$(opkg status "$name")
        printf '%s\n' "$status" | grep -q '^Status: .* installed$' || { printf 'Missing prerequisite: %s\n' "$name" >&2; exit 1; }
        if [ -n "$needed" ]; then
            installed=$(printf '%s\n' "$status" | sed -n 's/^Version: //p')
            opkg compare-versions "$installed" "$op" "$needed" || exit 1
        fi
    done
fi
printf 'runtime:%s\nluci:%s\n' "$runtime_installed" "$luci_installed"
REMOTE
}
installed_versions=$(preflight) || fail 'Read-only ownership, version, trust, architecture or dependency preflight failed; migrate unmanaged files explicitly and configure feed trust/dependencies manually'
[ "$(printf '%s\n' "$installed_versions" | wc -l | tr -d ' ')" = 2 ] || fail 'Unexpected installed-version query output'
companion_before=$(printf '%s\n' "$installed_versions" | sed -n 's/^luci://p')
verify_luci=$luci
[ -z "$companion_before" ] || verify_luci=1
printf 'Qualified OpenWrt %s / %s; verifying release %s. Release-file claims are not hardware attestation.\n' "$release" "$manager" "$version"
printf 'Firewall include registration and dnsmasq integration remain manual; no activation, UCI changes, or explicit service restarts are performed. Native package hooks may restart rpcd.\n'
if [ "$manager" = apk ]; then
    apk_args=("$feed" "$version" "$luci" "$dry" "$fingerprint" "$indexhash" "$verify_luci")
    for i in 0 1; do apk_args+=("${names[$i]}" "${arches[$i]}" "${files[$i]}" "${hashes[$i]}"); done
    remote "${apk_args[@]}" <<'REMOTE' || fail 'Signed feed verification, installed prerequisites, installation or final version validation failed'
set -eu
: GK_APK_VERIFY
export APK_CONFIG=/dev/null
feed=$1; version=$2; luci=$3; dry=$4; fingerprint=$5; indexhash=$6; verify_luci=$7
shift 7
umask 077
stage=$(mktemp -d /tmp/gatekeeper-verify.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$stage/keys" "$stage/bound"
trusted=0
for key in /etc/apk/keys/*; do
    [ -f "$key" ] || continue
    sum=$(sha256sum "$key"); sum=${sum%% *}
    if [ "$sum" = "$fingerprint" ]; then cp "$key" "$stage/keys/publisher.pem"; trusted=1; break; fi
done
[ "$trusted" = 1 ] || exit 1
fetch_https() {
    curl --disable --fail --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 180 --output "$2" "$1"
}
check_hash() {
    actual=$(sha256sum "$1"); actual=${actual%% *}
    [ "$actual" = "$2" ] || { printf 'Feed SHA256 mismatch: %s\n' "${1##*/}" >&2; exit 1; }
}
check_hash "$stage/keys/publisher.pem" "$fingerprint"
fetch_https "$feed/packages.adb" "$stage/packages.adb"
check_hash "$stage/packages.adb" "$indexhash"
apk verify --keys-dir "$stage/keys" "$stage/packages.adb"
apk adbdump --keys-dir "$stage/keys" --format json "$stage/packages.adb" > "$stage/index.json"
jq -e '.packages | type == "array" and length == 2' "$stage/index.json" >/dev/null
install_files=
while [ "$#" -gt 0 ]; do
    name=$1; arch=$2; file=$3; expected=$4; shift 4
    fetch_https "$feed/$file" "$stage/$file"
    check_hash "$stage/$file" "$expected"
    apk verify --keys-dir "$stage/keys" "$stage/$file"
    apk adbdump --keys-dir "$stage/keys" --format json "$stage/$file" > "$stage/$file.json"
    jq -e --arg n "$name" --arg v "$version" --arg a "$arch" '.info | .name == $n and .version == $v and .arch == $a' "$stage/$file.json" >/dev/null
    size=$(wc -c < "$stage/$file" | tr -d ' ')
    jq -e --arg n "$name" --arg v "$version" --arg a "$arch" --argjson s "$size" '[.packages[] | select(.name == $n)] | length == 1 and (.[0] | .version == $v and .arch == $a and .["file-size"] == $s and (.hashes | type == "string" and length > 0))' "$stage/index.json" >/dev/null
    bound_file="$name-$version.apk"
    if [ "$name" = gatekeeper ] || [ "$luci" = 1 ]; then install_files="$install_files $stage/bound/$bound_file"; fi
    printf '%s  %s\n' "$expected" "$bound_file" >> "$stage/expected.sha256"
done
apk --keys-dir "$stage/keys" --no-network --no-cache --repositories-file /dev/null --repository "$stage/packages.adb" fetch --pkgname-spec '${name}-${version}.apk' --output "$stage/bound" gatekeeper luci-app-gatekeeper
(cd "$stage/bound" && sha256sum -c "$stage/expected.sha256")
apk --no-logfile --no-network --no-cache --repositories-file /dev/null add --simulate $install_files >/dev/null
if [ "$dry" = 0 ]; then
    apk --no-network --no-cache --repositories-file /dev/null add $install_files
    for name in gatekeeper luci-app-gatekeeper; do
        if [ "$name" = luci-app-gatekeeper ] && [ "$verify_luci" = 0 ]; then
            apk query --from installed --format json --fields name,version "$name" | jq -e --arg n "$name" 'map(select(.name == $n)) | length == 0' >/dev/null
        else
            apk query --from installed --format json --fields name,version "$name" | jq -e --arg n "$name" --arg v "$version" 'map(select(.name == $n)) | length == 1 and .[0].version == $v' >/dev/null
        fi
    done
fi
REMOTE
else
    if [ "$dry" = 1 ]; then
        printf 'Dry run: read-only IPK preflight; no installation or persistent changes.\n'
        exit 0
    fi
    stage="/tmp/gatekeeper-deploy-$$-$RANDOM-$RANDOM"
    cleanup() {
        remote "$stage" <<'REMOTE' >/dev/null 2>&1 || true
set -eu
: GK_INSTALL
rm -rf "$1"
REMOTE
    }
    remote "$stage" <<'REMOTE'
set -eu
: GK_INSTALL
umask 077
mkdir "$1"
REMOTE
    trap cleanup EXIT
    install_args=("$stage" "$version" "$verify_luci")
    for i in "${selected[@]}"; do
        scp -O -o BatchMode=yes -o ConnectTimeout=15 "$packages/${files[$i]}" "root@$router:$stage/${files[$i]}"
        install_args+=("${files[$i]}" "${hashes[$i]}")
    done
    remote "${install_args[@]}" <<'REMOTE'
set -eu
: GK_INSTALL
stage=$1; version=$2; luci=$3
shift 3
cd "$stage"
files=
while [ "$#" -gt 0 ]; do
    file=$1; expected=$2; shift 2
    actual=$(sha256sum "$file"); actual=${actual%% *}
    [ "$actual" = "$expected" ] || { printf 'Remote SHA256 mismatch\n' >&2; exit 1; }
    files="$files ./$file"
done
opkg --noaction install $files >/dev/null
opkg install $files
for name in gatekeeper luci-app-gatekeeper; do
    status=$(opkg status "$name")
    if [ "$name" = luci-app-gatekeeper ] && [ "$luci" = 0 ]; then
        if printf '%s\n' "$status" | grep -q '^Status: .* installed$'; then exit 1; fi
    else
        printf '%s\n' "$status" | grep -q '^Status: .* installed$' || exit 1
        [ "$(printf '%s\n' "$status" | sed -n 's/^Version: //p')" = "$version" ] || { printf 'Installed version verification failed\n' >&2; exit 1; }
    fi
done
REMOTE
fi
if [ "$dry" = 1 ]; then
    printf 'Dry run: signed feed and package verification complete; temporary verification files cleaned; no installation or persistent config, trust, repository, or service changes.\n'
else
    printf 'Package installation and final versions verified; native configuration preservation applies. Complete manual setup before enabling Gatekeeper services.\n'
fi
