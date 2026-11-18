#!/bin/sh

set -u

PASS=0
FAIL=0
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/gatekeeper-ipk-test.XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' 0
trap 'exit 1' HUP INT TERM
TMPDIR="$SANDBOX/tmp"
GITHUB_WORKSPACE="$SANDBOX/workspace"
PKG_VERSION=${PKG_VERSION:-1.0}
PKG_RELEASE=${PKG_RELEASE:-1}
case "$PKG_VERSION-$PKG_RELEASE" in
    *[!A-Za-z0-9.+~-]*|'') printf '%s\n' 'FAIL invalid package version/release'; exit 1 ;;
esac
BASES=${OPENWRT_BASE:-'23.05 24.10'}
export TMPDIR GITHUB_WORKSPACE PKG_VERSION PKG_RELEASE
mkdir -p "$TMPDIR" "$GITHUB_WORKSPACE" || exit 1
for SOURCE in gatekeeper.sh tg_bot.sh gatekeeper_trigger.sh dnsmasq_trigger.sh \
    gatekeeper_sync.sh gatekeeper.nft gatekeeper_init tg_gatekeeper \
    gatekeeper_trigger_listener opkg; do
    ln -s "$REPO/$SOURCE" "$GITHUB_WORKSPACE/$SOURCE" || exit 1
done

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n----- got -----\n%s\n----- want -----\n%s\n' "$1" "$2" "$3"
        return 1
    fi
}

assert() {
    CHECK_LABEL=$1
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n' "$CHECK_LABEL"
        return 1
    fi
}

extract_build() {
    awk -v step="    - name: $1" '
        /^    - / {
            if (active) exit
            selected = ($0 == step)
        }
        selected && /^      run: \|$/ { active = 1; found = 1; next }
        active {
            if ($0 == "") { print; next }
            if (substr($0, 1, 8) != "        ") exit
            print substr($0, 9)
            lines++
        }
        END { if (!found || !lines) exit 1 }
    ' "$REPO/.github/workflows/makefile.yml" > "$2"
}

field() {
    awk -v key="$2" 'index($0, key ": ") == 1 { print substr($0, length(key) + 3) }' "$1"
}

root_owned() {
    LC_ALL=C tar --numeric-owner -tvzf "$1" > "$SANDBOX/ownership.list" || return 1
    awk 'NF < 2 || $2 != "0/0" { bad = 1 } END { exit (bad || NR == 0) }' "$SANDBOX/ownership.list"
}

valid_control() {
    awk '
        /^[A-Za-z0-9][A-Za-z0-9-]*: / {
            description = ($0 ~ /^Description: [^[:space:]]/)
            if (description) summaries++
            next
        }
        /^ / { if (!description) bad = 1; else continuations++; next }
        { bad = 1 }
        END { exit (bad || summaries != 1 || continuations == 0) }
    ' "$1"
}

check_package() {
    PACKAGE=$1
    IPK="$GITHUB_WORKSPACE/$2"
    UNPACK="$SANDBOX/$OPENWRT_BASE/$PACKAGE"
    assert "$PACKAGE artifact exists" test -s "$IPK" || return
    MAGIC=$(od -An -N2 -tu1 "$IPK" | awk '{$1=$1; print}')
    assert_eq "$PACKAGE outer gzip magic" "$MAGIC" '31 139'
    assert "$PACKAGE outer gzip integrity" gzip -t "$IPK" || return
    assert "$PACKAGE outer numeric ownership 0/0" root_owned "$IPK"
    MEMBERS=$(tar -tzf "$IPK")
    assert_eq "$PACKAGE exact outer members and OpenWrt order" "$MEMBERS" './debian-binary
./data.tar.gz
./control.tar.gz' || return
    mkdir -p "$UNPACK/control" "$UNPACK/data" || exit 1
    assert "$PACKAGE outer archive extraction" tar -xzf "$IPK" -C "$UNPACK" || return
    assert_eq "$PACKAGE debian-binary bytes" \
        "$(od -An -tu1 "$UNPACK/debian-binary" | awk '{$1=$1; print}')" '50 46 48 10'
    for ARCHIVE in control data; do
        assert "$PACKAGE $ARCHIVE gzip integrity" gzip -t "$UNPACK/$ARCHIVE.tar.gz" || return
        assert "$PACKAGE $ARCHIVE numeric ownership 0/0" root_owned "$UNPACK/$ARCHIVE.tar.gz"
        assert "$PACKAGE $ARCHIVE extraction" tar -xzf "$UNPACK/$ARCHIVE.tar.gz" -C "$UNPACK/$ARCHIVE" || return
    done
    CONTROL="$UNPACK/control/control"
    assert "$PACKAGE control exists" test -s "$CONTROL" || return
    assert "$PACKAGE control fields and description continuations" valid_control "$CONTROL"
    assert_eq "$PACKAGE Package field" "$(field "$CONTROL" Package)" "$PACKAGE"
    assert_eq "$PACKAGE Version field" "$(field "$CONTROL" Version)" "$PKG_VERSION-$PKG_RELEASE"
    assert_eq "$PACKAGE Architecture field" "$(field "$CONTROL" Architecture)" all
    if [ "$PACKAGE" = gatekeeper ]; then
        assert_eq "$PACKAGE Depends field" "$(field "$CONTROL" Depends)" 'jq, curl, coreutils, coreutils-timeout'
        assert "$PACKAGE conffiles exists" test -f "$UNPACK/control/conffiles"
        assert_eq "$PACKAGE preserved configuration" "$(cat "$UNPACK/control/conffiles")" '/etc/config/gatekeeper'
        for PAYLOAD in usr/bin/gatekeeper.sh usr/bin/tg_bot.sh usr/bin/gatekeeper_trigger.sh \
            usr/bin/dnsmasq_trigger.sh usr/bin/gatekeeper_sync.sh \
            etc/init.d/gatekeeper_init etc/init.d/tg_gatekeeper \
            etc/init.d/gatekeeper_trigger_listener etc/gatekeeper/gatekeeper.nft; do
            assert "$PACKAGE executable $PAYLOAD" test -x "$UNPACK/data/$PAYLOAD"
            assert "$PACKAGE nonempty $PAYLOAD" test -s "$UNPACK/data/$PAYLOAD"
            assert "$PACKAGE source bytes $PAYLOAD" cmp -s "$REPO/${PAYLOAD##*/}" "$UNPACK/data/$PAYLOAD"
        done
        for PAYLOAD in usr/lib/gatekeeper/restore_helpers.sh etc/config/gatekeeper; do
            assert "$PACKAGE payload $PAYLOAD" test -s "$UNPACK/data/$PAYLOAD"
            assert "$PACKAGE source bytes $PAYLOAD" cmp -s "$REPO/opkg/$PAYLOAD" "$UNPACK/data/$PAYLOAD"
        done
        assert_eq "$PACKAGE credential configuration mode" "$(tar -tvzf "$UNPACK/data.tar.gz" ./etc/config/gatekeeper | awk '{print $1}')" '-rw-------'
        assert "$PACKAGE firewall include shell syntax" sh -n "$UNPACK/data/etc/gatekeeper/gatekeeper.nft"
    else
        assert_eq "$PACKAGE Depends field" "$(field "$CONTROL" Depends)" "luci-base, gatekeeper (>= $PKG_VERSION-$PKG_RELEASE), rpcd"
        assert "$PACKAGE executable rpcd backend" test -x "$UNPACK/data/usr/libexec/rpcd/gatekeeper"
        for PAYLOAD in usr/libexec/rpcd/gatekeeper \
            usr/share/luci/menu.d/luci-app-gatekeeper.json \
            usr/share/rpcd/acl.d/luci-app-gatekeeper.json; do
            assert "$PACKAGE payload $PAYLOAD" test -s "$UNPACK/data/$PAYLOAD"
            assert "$PACKAGE source bytes $PAYLOAD" cmp -s "$REPO/opkg/luci/$PAYLOAD" "$UNPACK/data/$PAYLOAD"
        done
        for VIEW in overview devices blacklist schedules backup_restore settings; do
            VIEW_PATH="luci-static/resources/view/gatekeeper/$VIEW.js"
            assert "$PACKAGE view $VIEW" test -s "$UNPACK/data/www/$VIEW_PATH"
            assert "$PACKAGE view source bytes $VIEW" cmp -s "$REPO/opkg/luci/htdocs/$VIEW_PATH" "$UNPACK/data/www/$VIEW_PATH"
        done
        set -- "$UNPACK"/data/www/luci-static/resources/view/gatekeeper/*.js
        assert_eq "$PACKAGE exactly six views" "$#" 6
        assert "$PACKAGE executable postinst" test -x "$UNPACK/control/postinst"
        assert "$PACKAGE postinst shell syntax" sh -n "$UNPACK/control/postinst"
        if assert_eq "$PACKAGE postinst shebang and offline guard" "$(cat "$UNPACK/control/postinst")" '#!/bin/sh
[ -n "$IPKG_INSTROOT" ] || /etc/init.d/rpcd restart
exit 0'; then
            assert "$PACKAGE offline postinst execution" env IPKG_INSTROOT="$UNPACK/data" "$UNPACK/control/postinst"
        fi
    fi
}

for OPENWRT_BASE in $BASES; do
case "$OPENWRT_BASE" in 23.05|24.10) ;; *) printf 'FAIL unsupported IPK base: %s\n' "$OPENWRT_BASE"; exit 1 ;; esac
IPK_NAME="openwrt-${OPENWRT_BASE}-gatekeeper_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"
LUCI_IPK_NAME="openwrt-${OPENWRT_BASE}-luci-app-gatekeeper_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"
export OPENWRT_BASE IPK_NAME LUCI_IPK_NAME
VERSION_BUILD="$SANDBOX/set-version-$OPENWRT_BASE.sh"
VERSION_ENV="$SANDBOX/version-$OPENWRT_BASE.env"
if assert "$OPENWRT_BASE version block extraction" extract_build 'Set package version' "$VERSION_BUILD"; then
    assert "$OPENWRT_BASE version block execution" env GITHUB_REF="refs/tags/v$PKG_VERSION" GITHUB_REF_NAME="v$PKG_VERSION" GITHUB_ENV="$VERSION_ENV" bash "$VERSION_BUILD"
    assert_eq "$OPENWRT_BASE runtime filename prefix" "$(sed -n 's/^IPK_NAME=//p' "$VERSION_ENV")" "$IPK_NAME"
    assert_eq "$OPENWRT_BASE LuCI filename prefix" "$(sed -n 's/^LUCI_IPK_NAME=//p' "$VERSION_ENV")" "$LUCI_IPK_NAME"
fi
for NAME in gatekeeper luci-app-gatekeeper; do
    BUILD="$SANDBOX/build-$OPENWRT_BASE-$NAME.sh"
    if assert "$NAME workflow build block extraction" extract_build "Build $NAME .ipk package" "$BUILD"; then
        if (CDPATH= cd -- "$GITHUB_WORKSPACE" && sh "$BUILD") > "$SANDBOX/build-$NAME.log" 2>&1; then
            PASS=$((PASS + 1))
            case "$NAME" in
                gatekeeper) check_package "$NAME" "$IPK_NAME" ;;
                luci-app-gatekeeper) check_package "$NAME" "$LUCI_IPK_NAME" ;;
            esac
        else
            FAIL=$((FAIL + 1))
            printf 'FAIL %s workflow build\n' "$NAME"
            cat "$SANDBOX/build-$NAME.log"
        fi
    fi
done
MANIFEST_BUILD="$SANDBOX/manifest-$OPENWRT_BASE.sh"
if assert "$OPENWRT_BASE manifest block extraction" extract_build 'Write IPK manifest and checksums' "$MANIFEST_BUILD"; then
    assert "$OPENWRT_BASE manifest block execution" sh -c 'cd "$GITHUB_WORKSPACE" && sh "$1"' sh "$MANIFEST_BUILD"
    assert "$OPENWRT_BASE artifact checksums" sh -c 'cd "$GITHUB_WORKSPACE" && sha256sum -c SHA256SUMS'
    assert_eq "$OPENWRT_BASE manifest pair count" "$(wc -l < "$GITHUB_WORKSPACE/packages.tsv" | tr -d ' ')" 2
    for NAME in gatekeeper luci-app-gatekeeper; do
        FILE="openwrt-${OPENWRT_BASE}-${NAME}_${PKG_VERSION}-${PKG_RELEASE}_all.ipk"
        HASH=$(sha256sum "$GITHUB_WORKSPACE/$FILE" | cut -d ' ' -f 1)
        EXPECTED=$(printf 'opkg\t%s\t%s-%s\tall\t%s\t%s' "$NAME" "$PKG_VERSION" "$PKG_RELEASE" "$FILE" "$HASH")
        assert "$OPENWRT_BASE manifest $NAME basename and metadata" grep -Fx "$EXPECTED" "$GITHUB_WORKSPACE/packages.tsv"
    done
fi
done
OPENWRT_BASE=23.05
export OPENWRT_BASE

CHECKER="$SANDBOX/opkg-checker.sh"
extract_checker() {
    awk -v quote="'" '
        $0 == "          \"$IMAGE\" /bin/sh -ec " quote { active = 1; next }
        active && $0 == "          " quote " sh \"$IPK_NAME\" \"$LUCI_IPK_NAME\"" { closed = 1; exit }
        active {
            line = substr($0, 13)
            if (line == "mkdir -p /var/lock") {
                line = "mkdir -p \"$TMPDIR/opkg-lock\""
                rewritten++
            }
            print line
            lines++
        }
        END { if (!closed || !lines || rewritten != 1) exit 1 }
    ' "$REPO/.github/workflows/makefile.yml" > "$CHECKER"
}

if assert 'workflow opkg checker extraction and safe lock initialization' extract_checker; then
    mkdir -p "$SANDBOX/fixture-bin" || exit 1
    cat > "$SANDBOX/fixture-bin/opkg" <<'OPKG'
#!/bin/sh
case "$*" in
    --version) printf '%s\n' 'opkg test double' ;;
    '--noaction install /packages/openwrt-23.05-gatekeeper_1.0-1_all.ipk')
        printf '%s\n' "$OPKG_OUTPUT"
        exit "$OPKG_STATUS" ;;
    *) exit 99 ;;
esac
OPKG
    chmod 755 "$SANDBOX/fixture-bin/opkg" || exit 1
    DEPENDENCIES="Unknown package 'gatekeeper'.
Collected errors:
 * pkg_hash_check_unresolved: cannot find dependency jq for gatekeeper
 * pkg_hash_fetch_best_installation_candidate: Packages for gatekeeper found, but incompatible with the architectures configured
 * opkg_install_cmd: Cannot install package gatekeeper."
    for SCENARIO in success dependencies malformed mixed; do
        STATUS=1
        EXPECTED=rejected
        case "$SCENARIO" in
            success) STATUS=0; OUTPUT='Installing gatekeeper (1.0-1) to root...'; EXPECTED=accepted ;;
            dependencies) OUTPUT=$DEPENDENCIES; EXPECTED=accepted ;;
            malformed) OUTPUT='Collected errors:
 * pkg_init_from_file: Malformed package file /packages/openwrt-23.05-gatekeeper_1.0-1_all.ipk.' ;;
            mixed) OUTPUT="$DEPENDENCIES
 * opkg_download: Failed to download unrelated resource." ;;
        esac
        if env PATH="$SANDBOX/fixture-bin:$PATH" OPKG_OUTPUT="$OUTPUT" OPKG_STATUS="$STATUS" \
            sh -e "$CHECKER" openwrt-23.05-gatekeeper_1.0-1_all.ipk > "$SANDBOX/checker-$SCENARIO.log" 2>&1; then
            RESULT=accepted
        else
            RESULT=rejected
        fi
        assert_eq "workflow opkg checker $SCENARIO policy" "$RESULT" "$EXPECTED" \
            || cat "$SANDBOX/checker-$SCENARIO.log"
    done
fi

printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
