#!/bin/sh
set -eu

[ -n "${OPENWRT_SDK:-}" ] || { printf '%s\n' 'Set OPENWRT_SDK to the official OpenWrt 25.12.0 Linux SDK' >&2; exit 1; }
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d)
image=
cleanup() {
    [ -z "$image" ] || docker image rm "$image" >/dev/null 2>&1 || :
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/feeds"
(umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$work/test-key.pem")
for version in 1.2.3 1.2.4; do
    sh "$repo/opkg/build-apk.sh" --sdk "$OPENWRT_SDK" --output "$work/feeds/$version" \
        --version "$version" --release 1 --signing-key "$work/test-key.pem"
done
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-25.12.0-x86-64-rootfs.tar.gz \
    --output "$work/rootfs.tar.gz"
printf '%s  %s\n' 11c2f26b9d48c02cbdb3b63d499e1f6413ed62bcdbbea78937b12279b95acb1e "$work/rootfs.tar.gz" | sha256sum -c -
image=$(docker import --platform linux/amd64 "$work/rootfs.tar.gz")
docker run --rm --mount "type=bind,src=$work/feeds,dst=/feeds,readonly" "$image" /bin/sh -ec '
    cp /feeds/1.2.3/feed-public.pem /etc/apk/keys/gatekeeper-integration.pem
    export APK_CONFIG=/dev/null IPKG_NO_SCRIPT=1
    for version in 1.2.3 1.2.4; do
        apk verify --keys-dir /etc/apk/keys "/feeds/$version/packages.adb" /feeds/"$version"/*.apk
    done
    apk update
    apk --preserve-env --repository /feeds/1.2.3/packages.adb add /feeds/1.2.3/openwrt-25.12-gatekeeper-1.2.3-r1.apk /feeds/1.2.3/openwrt-25.12-luci-app-gatekeeper-1.2.3-r1.apk
    apk query --from installed --format json --fields name,version gatekeeper luci-app-gatekeeper | jq -e '\''length == 2 and all(.version == "1.2.3-r1")'\''
    printf "\noption integration_preserve native-upgrade\n" >> /etc/config/gatekeeper
    before=$(sha256sum /etc/config/gatekeeper)
    apk --preserve-env --repository /feeds/1.2.4/packages.adb add /feeds/1.2.4/openwrt-25.12-gatekeeper-1.2.4-r1.apk /feeds/1.2.4/openwrt-25.12-luci-app-gatekeeper-1.2.4-r1.apk
    after=$(sha256sum /etc/config/gatekeeper)
    [ "$before" = "$after" ]
    apk query --from installed --format json --fields name,version gatekeeper luci-app-gatekeeper | jq -e '\''length == 2 and all(.version == "1.2.4-r1")'\''
    test -x /usr/bin/gatekeeper.sh
    test -x /usr/libexec/rpcd/gatekeeper
    test -x /etc/gatekeeper/gatekeeper.nft
    printf "%s\n" "PASS: native OpenWrt 25.12 install, dependency resolution, queries and modified-config upgrade preservation"
'
