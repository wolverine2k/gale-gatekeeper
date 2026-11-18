import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tarfile
import zlib


MAX_COMPRESSED = 16 * 1024 * 1024
MAX_UNCOMPRESSED = 64 * 1024 * 1024
MAX_MEMBERS = 4096
MAX_MANIFEST = 64 * 1024
PACKAGES = ('gatekeeper', 'luci-app-gatekeeper')
POSTINST = b'#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || /etc/init.d/rpcd restart\nexit 0\n'


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def read_regular(path, limit):
    try:
        require(stat.S_ISREG(path.lstat().st_mode), f'{path}: not a regular file or symlink input')
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'rb') as handle:
            info = os.fstat(handle.fileno())
            require(stat.S_ISREG(info.st_mode), f'{path}: not a regular file')
            require(info.st_size <= limit, f'{path}: size limit exceeded')
            content = handle.read(limit + 1)
    except OSError as exc:
        raise ValidationError(f'{path}: cannot read regular file: {exc}') from exc
    require(len(content) <= limit, f'{path}: size limit exceeded')
    return content


def manifest_lines(path):
    try:
        return read_regular(path, MAX_MANIFEST).decode('utf-8').splitlines()
    except UnicodeError as exc:
        raise ValidationError(f'{path}: invalid UTF-8') from exc


def inventory(package):
    if package == 'gatekeeper':
        mapping = {f'usr/bin/{name}': (name, 0o755) for name in (
            'gatekeeper.sh', 'tg_bot.sh', 'gatekeeper_trigger.sh',
            'dnsmasq_trigger.sh', 'gatekeeper_sync.sh')}
        mapping.update({f'etc/init.d/{name}': (name, 0o755) for name in (
            'gatekeeper_init', 'tg_gatekeeper', 'gatekeeper_trigger_listener')})
        mapping.update({
            'etc/gatekeeper/gatekeeper.nft': ('gatekeeper.nft', 0o755),
            'etc/config/gatekeeper': ('opkg/etc/config/gatekeeper', 0o600),
            'usr/lib/gatekeeper/restore_helpers.sh': ('opkg/usr/lib/gatekeeper/restore_helpers.sh', 0o644),
        })
    else:
        mapping = {name: (f'opkg/luci/{name}', mode) for name, mode in (
            ('usr/libexec/rpcd/gatekeeper', 0o755),
            ('usr/share/luci/menu.d/luci-app-gatekeeper.json', 0o644),
            ('usr/share/rpcd/acl.d/luci-app-gatekeeper.json', 0o644))}
        mapping.update({f'www/luci-static/resources/view/gatekeeper/{view}.js': (
            f'opkg/luci/htdocs/luci-static/resources/view/gatekeeper/{view}.js', 0o644)
            for view in ('overview', 'devices', 'blacklist', 'schedules', 'backup_restore', 'settings')})
    return mapping


def directories(mapping):
    return {''} | {str(parent) for name in mapping for parent in PurePosixPath(name).parents if str(parent) != '.'}


def archive(blob, label):
    require(len(blob) <= MAX_COMPRESSED, f'{label}: compressed size limit exceeded')
    require(blob.startswith(b'\x1f\x8b'), f'{label}: not gzip')
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(blob)) as stream:
            raw = stream.read(MAX_UNCOMPRESSED + 1)
    except (OSError, EOFError, zlib.error) as exc:
        raise ValidationError(f'{label}: invalid gzip: {exc}') from exc
    require(len(raw) <= MAX_UNCOMPRESSED, f'{label}: uncompressed size limit exceeded')
    require(len(raw) % 512 == 0, f'{label}: truncated tar block')
    entries = {}
    offset = 0
    while offset + 512 <= len(raw):
        header = raw[offset:offset + 512]
        if header == bytes(512):
            require(len(raw) - offset >= 1024, f'{label}: missing second tar end marker')
            require(not any(raw[offset:]), f'{label}: trailing data after tar end marker')
            return entries
        require(len(entries) < MAX_MEMBERS, f'{label}: member count limit exceeded')
        require(header[156:157] in (b'0', b'\0', b'5'), f'{label}: unsupported tar record')
        for start, end in ((100, 108), (108, 116), (116, 124), (124, 136), (136, 148), (148, 156), (329, 337), (337, 345)):
            field = header[start:end]
            require(not field[0] & 128, f'{label}: base-256 numeric field')
            require(re.fullmatch(rb'[0-7]*', field.strip(b'\0 ')) is not None, f'{label}: invalid octal header field')
        require(header[257:265] in (b'ustar\x0000', b'ustar  \x00'), f'{label}: invalid tar header magic')
        if header[257:265] == b'ustar  \x00':
            require(not any(header[345:]), f'{label}: unsupported GNU header extension')
        else:
            require(not any(header[500:]), f'{label}: invalid tar header padding')
        try:
            member = tarfile.TarInfo.frombuf(header, 'utf-8', 'strict')
        except (tarfile.HeaderError, UnicodeError, ValueError) as exc:
            raise ValidationError(f'{label}: invalid tar header: {exc}') from exc
        raw_name = header[:100].split(b'\0', 1)[0]
        require(raw_name and not raw_name.startswith(b'/') and b'//' not in raw_name,
                f'{label}: unsafe tar path {raw_name!r}')
        name = '' if member.name == '.' and member.isdir() else member.name
        if name.startswith('./'):
            name = name[2:]
        if member.isdir():
            name = name.rstrip('/')
        require(name == '' and member.isdir() or bool(name) and not name.startswith('/') and
                all(part not in ('', '.', '..') for part in name.split('/')) and '\\' not in name,
                f'{label}: unsafe tar path {member.name!r}')
        require(name not in entries, f'{label}: duplicate tar path {name!r}')
        require(member.uid == member.gid == 0 and member.uname == member.gname == '',
                f'{label}: nonnumeric root ownership for {name!r}')
        require(not member.linkname, f'{label}: unexpected link target')
        require(not member.isdir() or member.size == 0, f'{label}: directory has data')
        end = offset + 512 + member.size
        padded_end = offset + 512 + ((member.size + 511) // 512) * 512
        require(padded_end <= len(raw), f'{label}: truncated tar member {name!r}')
        require(not any(raw[end:padded_end]), f'{label}: nonzero tar member padding')
        entries[name] = (member.mode, None if member.isdir() else raw[offset + 512:end])
        offset = padded_end
    raise ValidationError(f'{label}: missing tar end marker')


def check_inventory(entries, files, dirs, label):
    expected = set(files) | dirs
    missing, extra = sorted(expected - set(entries)), sorted(set(entries) - expected)
    require(not missing and not extra,
            f'{label}: unexpected file/directory inventory (missing={missing[:5]!r}, extra={extra[:5]!r})')
    for name in dirs:
        require(entries[name] == (0o755, None), f'{label}: directory mode/type {name!r}')
    for name, mode in files.items():
        require(entries[name][0] == mode and entries[name][1] is not None,
                f'{label}: file mode/type {name!r}')


def metadata(content, package, version):
    fields = {}
    last = None
    try:
        lines = content.decode('utf-8').splitlines()
    except UnicodeError as exc:
        raise ValidationError('control: invalid UTF-8') from exc
    for line in lines:
        if line.startswith((' ', '\t')):
            require(last == 'Description' and bool(line.strip()), 'control: invalid continuation')
            continue
        key, sep, value = line.partition(': ')
        require(sep and re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*', key) and key not in fields and value.strip(),
                f'control: invalid/duplicate field {line!r}')
        fields[key] = value
        last = key
    expected = {
        'Package': package, 'Version': version, 'Architecture': 'all',
        'Maintainer': 'Naresh Mehta <naresh@naresh.se>',
        'Section': 'net' if package == 'gatekeeper' else 'luci',
        'Depends': 'jq, curl, coreutils, coreutils-timeout' if package == 'gatekeeper' else f'luci-base, gatekeeper (>= {version}), rpcd',
        'Description': 'Telegram-based Network Access Control for OpenWrt' if package == 'gatekeeper' else 'LuCI web interface for Gatekeeper',
    }
    require(set(fields) == set(expected) | {'Installed-Size'}, 'control: unexpected field inventory')
    for key, value in expected.items():
        require(fields[key] == value, f'{package} control: wrong {key}')
    require(re.fullmatch(r'[1-9][0-9]*', fields['Installed-Size']) is not None, 'control: invalid Installed-Size')


def validate_packages(folder, base, version, release='1', source_root=None):
    require(base in ('23.05', '24.10'), 'unsupported OpenWrt base')
    require(isinstance(version, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+~_-]*', version) is not None,
            'invalid package version')
    require(isinstance(release, str) and re.fullmatch(r'[1-9][0-9]*', release) is not None,
            'release must be a positive integer')
    folder = Path(folder)
    source_root = Path(source_root) if source_root is not None else Path(__file__).resolve().parents[1]
    full_version = f'{version}-{release}'
    names = {package: f'openwrt-{base}-{package}_{full_version}_all.ipk' for package in PACKAGES}
    require({path.name for path in folder.glob('*.ipk')} == set(names.values()), 'unexpected IPK inventory (missing or extra package)')
    sums = {}
    for line in manifest_lines(folder / 'SHA256SUMS'):
        match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
        require(match is not None, 'SHA256SUMS: invalid hash or unsafe filename')
        digest, name = match.groups()
        require(name in names.values() and name not in sums, 'SHA256SUMS: unexpected/duplicate filename')
        sums[name] = digest
    require(set(sums) == set(names.values()), 'SHA256SUMS: expected exactly two entries')
    rows = manifest_lines(folder / 'packages.tsv')
    require(len(rows) == 2, 'packages.tsv: expected exactly two rows')
    seen = set()
    for line in rows:
        row = line.split('\t')
        require(len(row) == 6, 'packages.tsv: expected six columns')
        family, package, package_version, arch, filename, digest = row
        require(package in names and package not in seen, 'packages.tsv: unknown/duplicate package')
        require((family, package_version, arch, filename) == ('opkg', full_version, 'all', names[package]),
                'packages.tsv: wrong family/version/architecture/filename')
        require(digest == sums[filename], 'packages.tsv: checksum mismatch')
        seen.add(package)
    for package, filename in names.items():
        blob = read_regular(folder / filename, MAX_COMPRESSED)
        require(hashlib.sha256(blob).hexdigest() == sums[filename], f'{filename}: checksum mismatch')
        outer = archive(blob, filename)
        require(list(outer) == ['debian-binary', 'data.tar.gz', 'control.tar.gz'], f'{filename}: wrong outer member order/inventory')
        require(all(mode == 0o644 and content is not None for mode, content in outer.values()), f'{filename}: outer mode/type')
        require(outer['debian-binary'][1] == b'2.0\n', f'{filename}: invalid debian-binary marker')
        control = archive(outer['control.tar.gz'][1], f'{filename}: control')
        auxiliary = 'conffiles' if package == 'gatekeeper' else 'postinst'
        check_inventory(control, {'control': 0o644, auxiliary: 0o644 if package == 'gatekeeper' else 0o755}, {''}, 'control')
        metadata(control['control'][1], package, full_version)
        require(control[auxiliary][1] == (b'/etc/config/gatekeeper\n' if package == 'gatekeeper' else POSTINST),
                f'control: invalid {auxiliary} bytes')
        data = archive(outer['data.tar.gz'][1], f'{filename}: data')
        mapping = inventory(package)
        check_inventory(data, {name: mode for name, (_, mode) in mapping.items()}, directories(mapping), 'payload')
        for name, (source, _) in mapping.items():
            path = source_root / source
            require(not any((source_root / parent).is_symlink() for parent in (PurePosixPath(source), *PurePosixPath(source).parents)),
                    f'{path}: symlink source')
            require(data[name][1] == read_regular(path, MAX_UNCOMPRESSED), f'payload: source bytes differ for {name}')
    return tuple(names.values())


def main():
    parser = argparse.ArgumentParser(description='Validate the complete generated OpenWrt IPK package pair.')
    parser.add_argument('package_dir', type=Path)
    parser.add_argument('openwrt_base', choices=('23.05', '24.10'))
    parser.add_argument('version')
    parser.add_argument('--release', default='1')
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        names = validate_packages(args.package_dir, args.openwrt_base, args.version, args.release, args.source_root)
    except (ValidationError, OSError, UnicodeError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        return 1
    for name in names:
        print(f'PASS: {name}: checksums, archives, metadata, ownership, modes and source payloads')
    return 0


if __name__ == '__main__':
    sys.exit(main())
