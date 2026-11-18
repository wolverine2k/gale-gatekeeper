#!/bin/sh
set -eu
export APK_CONFIG=/dev/null

fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
[ -n "${OPENWRT_SDK:-}" ] || fail 'Set OPENWRT_SDK to the official OpenWrt 25.12.0 SDK directory'
sdk=$(CDPATH= cd -- "$OPENWRT_SDK" && pwd -P)
apk=$sdk/staging_dir/host/bin/apk
[ -x "$apk" ] || fail 'SDK host apk is missing'
[ "$#" -le 1 ] || fail 'Usage: OPENWRT_SDK=PATH sh tests/test_apk_packages.sh [FEED_DIR]'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$work/keys" "$work/empty-keys" "$work/wrong-keys"
if [ "$#" -eq 1 ]; then
    feed=$(CDPATH= cd -- "$1" && pwd -P)
else
    for keyfile in private-key.pem public-key.pem; do
        [ -e "$sdk/$keyfile" ] || printf '%s\n' "$keyfile" >> "$work/absent-sdk-keys"
    done
    (umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/fixture.key" 2>/dev/null)
    sh "$repo/opkg/build-apk.sh" --sdk "$sdk" --output "$work/feed" \
        --version "${PKG_VERSION:-1.0.0}" --release "${PKG_RELEASE:-1}" --signing-key "$work/fixture.key" --jobs "${JOBS:-2}"
    feed=$work/feed
    if [ -f "$work/absent-sdk-keys" ]; then
        while IFS= read -r keyfile; do
            [ ! -e "$sdk/$keyfile" ] || fail 'Build unexpectedly generated an SDK signing key'
        done < "$work/absent-sdk-keys"
    fi
fi
[ -f "$feed/feed-public.pem" ] && [ ! -L "$feed/feed-public.pem" ] || fail 'Missing public feed key'
openssl pkey -pubin -in "$feed/feed-public.pem" -noout >/dev/null 2>&1 || fail 'Feed key is not a public key'
if grep -q 'PRIVATE KEY' "$feed/feed-public.pem"; then fail 'Private key published'; fi
cp "$feed/feed-public.pem" "$work/keys/"
(umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/wrong.key" 2>/dev/null)
openssl pkey -in "$work/wrong.key" -pubout -out "$work/wrong-keys/wrong.pem" 2>/dev/null
count=0
for artifact in "$feed"/*; do
    [ -f "$artifact" ] && [ ! -L "$artifact" ] || fail 'Unexpected non-file feed artifact'
    case "$(basename -- "$artifact")" in
        feed-public.pem|packages.tsv|SHA256SUMS) continue ;;
        packages.adb|openwrt-25.12-gatekeeper-*.apk|openwrt-25.12-luci-app-gatekeeper-*.apk) ;;
        *) fail 'Unexpected feed artifact' ;;
    esac
    count=$((count + 1))
    "$apk" verify --keys-dir "$work/keys" "$artifact"
    if "$apk" verify --keys-dir "$work/empty-keys" "$artifact" >"$work/rejected.log" 2>&1; then fail 'Untrusted artifact accepted'; fi
    grep -Eiq 'signature|untrusted' "$work/rejected.log" || fail 'Missing-key rejection was not a signature failure'
    if "$apk" verify --keys-dir "$work/wrong-keys" "$artifact" >"$work/rejected.log" 2>&1; then fail 'Wrong-key artifact accepted'; fi
    grep -Eiq 'signature|untrusted' "$work/rejected.log" || fail 'Wrong-key rejection was not a signature failure'
    "$apk" adbdump --keys-dir "$work/keys" --format json "$artifact" > "$work/$(basename -- "$artifact").json"
    python3 - "$artifact" "$work/tampered" <<'PY'
import pathlib, sys
p = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
assert len(p) > 32
p[len(p) // 2] ^= 1
pathlib.Path(sys.argv[2]).write_bytes(p)
PY
    if "$apk" verify --keys-dir "$work/keys" "$work/tampered" >"$work/rejected.log" 2>&1; then fail 'Tampered artifact accepted'; fi
done
[ "$count" -eq 3 ] || fail 'Expected two APKs and one signed packages.adb index'
for name in gatekeeper luci-app-gatekeeper; do
    set -- "$feed/openwrt-25.12-$name-"*.apk
    [ "$#" -eq 1 ] && [ -f "$1" ] || fail "Expected exactly one $name APK"
    mkdir -p "$work/$name"
    "$apk" extract --keys-dir "$work/keys" --no-chown --destination "$work/$name" "$1"
done
python3 - "$repo" "$work" "$feed" "$apk" <<'PY'
import functools, hashlib, http.server, json, os, pathlib, re, shutil, stat, subprocess, sys, threading
repo, work, feed, apk = map(pathlib.Path, sys.argv[1:])
def objects(value):
    if isinstance(value, dict):
        yield value
        for v in value.values():
            yield from objects(v)
    elif isinstance(value, list):
        for v in value:
            yield from objects(v)
def load(name):
    return json.loads((work / name).read_text())
metadata = {}
versions = set()
for name in ('gatekeeper', 'luci-app-gatekeeper'):
    artifacts = list(feed.glob('openwrt-25.12-' + name + '-*.apk'))
    assert len(artifacts) == 1, artifacts
    doc = load(artifacts[0].name + '.json')
    info, = [x for x in objects(doc) if x.get('name') == name and 'arch' in x]
    assert info['arch'] == 'noarch', info
    version = info['version']
    assert re.fullmatch(r'[0-9][A-Za-z0-9._]*-r[1-9][0-9]*', version), info
    assert artifacts[0].name == f'openwrt-25.12-{name}-{version}.apk'
    versions.add(version)
    metadata[name] = (doc, info)
assert len(versions) == 1, versions
version, = versions
assert {p.name for p in feed.iterdir()} == {'feed-public.pem', 'packages.adb', 'packages.tsv', 'SHA256SUMS',
    f'openwrt-25.12-gatekeeper-{version}.apk', f'openwrt-25.12-luci-app-gatekeeper-{version}.apk'}, 'Unexpected feed contents'
checksums = {}
for line in (feed / 'SHA256SUMS').read_text().splitlines():
    checksum, filename = line.split('  ', 1)
    assert filename not in checksums and re.fullmatch(r'[a-f0-9]{64}', checksum), line
    assert filename in {p.name for p in feed.iterdir()} - {'SHA256SUMS'}, filename
    assert hashlib.sha256((feed / filename).read_bytes()).hexdigest() == checksum, filename
    checksums[filename] = checksum
assert set(checksums) == {p.name for p in feed.iterdir()} - {'SHA256SUMS'}
rows = [line.split('\t') for line in (feed / 'packages.tsv').read_text().splitlines()]
assert len(rows) == 2
assert {tuple(row) for row in rows} == {
    ('apk', name, version, 'noarch', f'openwrt-25.12-{name}-{version}.apk', checksums[f'openwrt-25.12-{name}-{version}.apk'])
    for name in ('gatekeeper', 'luci-app-gatekeeper')
}
expected_version = os.environ.get('PKG_VERSION')
expected_release = os.environ.get('PKG_RELEASE')
if expected_version and expected_release:
    assert version == f'{expected_version}-r{expected_release}', version
for name, expected in [('gatekeeper', {'jq', 'curl', 'coreutils', 'coreutils-timeout'}),
                       ('luci-app-gatekeeper', {'luci-base', 'rpcd', f'gatekeeper>={version}'})]:
    deps = metadata[name][1]['depends']
    assert isinstance(deps, list), deps
    assert expected <= set(deps), deps
    assert not any('(' in x or ')' in x for x in deps), deps
index = load('packages.adb.json')
assert any(x.get('pkgname-spec') == 'openwrt-25.12-${name}-${version}.apk' for x in objects(index)), index
indexed = [x for x in objects(index) if x.get('name') in metadata and 'arch' in x]
assert len(indexed) == 2, indexed
assert {x['name'] for x in indexed} == set(metadata)
for info in indexed:
    assert info['version'] == version and info['arch'] == 'noarch', info
requests = []
class FeedHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        super().do_GET()
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(FeedHandler, directory=str(feed)))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
fetch_root = work / 'fetch-root'
fetch_output = work / 'fetched'
fetch_root.mkdir()
fetch_output.mkdir()
try:
    subprocess.run([str(apk), '--cache=no', '--root', str(fetch_root), '--keys-dir', str(work / 'keys'),
                    '--repositories-file', '/dev/null', '--repository',
                    f'http://127.0.0.1:{server.server_port}/packages.adb',
                    'fetch', '--output', str(fetch_output), 'gatekeeper', 'luci-app-gatekeeper'], check=True)
finally:
    server.shutdown()
    server.server_close()
    thread.join()
assert '/packages.adb' in requests, requests
assert {p.name for p in fetch_output.iterdir()} == {f'{name}-{version}.apk' for name in metadata}
for name in metadata:
    filename = f'openwrt-25.12-{name}-{version}.apk'
    assert '/' + filename in requests, requests
    assert (fetch_output / f'{name}-{version}.apk').read_bytes() == (feed / filename).read_bytes(), name
print('PASS: native APK fetch resolves signed index to prefixed HTTP package URLs')
runtime = {f'usr/bin/{n}': n for n in ['gatekeeper.sh', 'tg_bot.sh', 'gatekeeper_trigger.sh', 'dnsmasq_trigger.sh', 'gatekeeper_sync.sh']}
runtime.update({f'etc/init.d/{n}': n for n in ['gatekeeper_init', 'tg_gatekeeper', 'gatekeeper_trigger_listener']})
runtime.update({'etc/gatekeeper/gatekeeper.nft': 'gatekeeper.nft',
                'etc/config/gatekeeper': 'opkg/etc/config/gatekeeper',
                'usr/lib/gatekeeper/restore_helpers.sh': 'opkg/usr/lib/gatekeeper/restore_helpers.sh'})
luci = {'usr/libexec/rpcd/gatekeeper': 'opkg/luci/usr/libexec/rpcd/gatekeeper',
        'usr/share/luci/menu.d/luci-app-gatekeeper.json': 'opkg/luci/usr/share/luci/menu.d/luci-app-gatekeeper.json',
        'usr/share/rpcd/acl.d/luci-app-gatekeeper.json': 'opkg/luci/usr/share/rpcd/acl.d/luci-app-gatekeeper.json'}
for view in ['overview', 'devices', 'blacklist', 'schedules', 'backup_restore', 'settings']:
    luci[f'www/luci-static/resources/view/gatekeeper/{view}.js'] = f'opkg/luci/htdocs/luci-static/resources/view/gatekeeper/{view}.js'
for name, mapping in [('gatekeeper', runtime), ('luci-app-gatekeeper', luci)]:
    root = work / name
    generated = {f'lib/apk/packages/{name}.list'}
    if name == 'gatekeeper':
        generated |= {f'lib/apk/packages/{name}.conffiles', f'lib/apk/packages/{name}.conffiles_static'}
    actual = {str(p.relative_to(root)) for p in root.rglob('*') if not p.is_dir()}
    assert actual == set(mapping) | generated, (name, actual ^ (set(mapping) | generated))
    for target, source in mapping.items():
        p = root / target
        assert not p.is_symlink(), target
        assert p.read_bytes() == (repo / source).read_bytes(), target
        executable = target.startswith(('usr/bin/', 'etc/init.d/', 'etc/gatekeeper/', 'usr/libexec/'))
        assert stat.S_IMODE(p.stat().st_mode) == (0o600 if target == 'etc/config/gatekeeper' else 0o755 if executable else 0o644), target
    doc = metadata[name][0]
    file_objects = [x for x in objects(doc) if 'acl' in x]
    assert file_objects, 'Missing native APK file ownership metadata'
    for obj in file_objects:
        acl = obj['acl']
        assert acl.get('user') in ('root', '0') and acl.get('group') in ('root', '0'), acl
root = work / 'gatekeeper'
assert (root / 'lib/apk/packages/gatekeeper.conffiles').read_text().splitlines() == ['/etc/config/gatekeeper']
csum = hashlib.sha256((repo / 'opkg/etc/config/gatekeeper').read_bytes()).hexdigest()
assert (root / 'lib/apk/packages/gatekeeper.conffiles_static').read_text().split() == ['/etc/config/gatekeeper', csum]
for name in ('gatekeeper', 'luci-app-gatekeeper'):
    scripts, = [x for x in objects(metadata[name][0]) if 'post-install' in x]
    for phase in ('post-install', 'post-upgrade'):
        script = scripts[phase]
        assert 'IPKG_NO_SCRIPT' in script and 'IPKG_INSTROOT' in script, script
        if name == 'luci-app-gatekeeper':
            assert '[ -n "$IPKG_INSTROOT" ] || /etc/init.d/rpcd restart' in script, script
        path = work / f'{name}-{phase}'
        path.write_text(script)
        subprocess.run(['sh', '-n', str(path)], check=True)
        offline = work / 'offline-root'
        shutil.rmtree(offline, ignore_errors=True)
        env = dict(os.environ, IPKG_INSTROOT=str(offline))
        env.pop('IPKG_NO_SCRIPT', None)
        subprocess.run(['sh', str(path)], env=env, check=True)
        fixture = offline / 'lib'
        fixture.mkdir(parents=True)
        (fixture / 'functions.sh').write_text('exit 91\n')
        subprocess.run(['sh', str(path)], env=dict(env, IPKG_NO_SCRIPT='1'), check=True)
        (fixture / 'functions.sh').write_text('add_group_and_user() { :; }\ndefault_postinst() { :; }\n')
        subprocess.run(['sh', str(path)], env=env, check=True)
print('PASS: native APK signatures, index, metadata, payloads, permissions, conffiles and offline lifecycle')
PY
printf '%s\n' 'PASS: missing/wrong public keys and tampered artifacts rejected'
