import copy
import gzip
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import validate_ipks as validator


def entry(name, content=b'', mode=0o644, kind=tarfile.REGTYPE):
    info = tarfile.TarInfo(name)
    info.mode = mode
    info.type = kind
    info.size = len(content)
    return info, content


def pack(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:', format=tarfile.GNU_FORMAT) as archive:
        for info, content in entries:
            info = copy.copy(info)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    return gzip.compress(stream.getvalue(), mtime=0)


def unpack(blob):
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as archive:
        return [(info, b'' if info.isdir() else archive.extractfile(info).read()) for info in archive]


def replace_content(entries, name, content):
    index = next(i for i, (info, _) in enumerate(entries) if info.name == name)
    entries[index] = entries[index][0], content


def header_field(raw, start, content):
    raw = bytearray(raw)
    raw[start:start + len(content)] = content
    raw[148:156] = b'        '
    raw[148:156] = f'{sum(raw[:512]):06o}\0 '.encode()
    return bytes(raw)


class ValidatePackagesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.folder = self.root / 'packages'
        self.folder.mkdir()
        self.build()

    def build(self, base='23.05', version='2.0.0', release='1'):
        for path in self.folder.iterdir():
            path.unlink()
        self.base, self.version, self.release = base, version, release
        full_version = f'{version}-{release}'
        self.names = {}
        for package in validator.PACKAGES:
            self.names[package] = f'openwrt-{base}-{package}_{full_version}_all.ipk'
            mapping = validator.inventory(package)
            payload = [entry(name or '.', mode=0o755, kind=tarfile.DIRTYPE)
                       for name in sorted(validator.directories(mapping))]
            for destination, (source, mode) in mapping.items():
                path = self.source / source
                path.parent.mkdir(parents=True, exist_ok=True)
                content = f'fixture source: {source}\n'.encode()
                path.write_bytes(content)
                payload.append(entry(destination, content, mode))
            runtime = package == 'gatekeeper'
            dependencies = 'jq, curl, coreutils, coreutils-timeout' if runtime else f'luci-base, gatekeeper (>= {full_version}), rpcd'
            description = 'Telegram-based Network Access Control for OpenWrt' if runtime else 'LuCI web interface for Gatekeeper'
            control = (f'Package: {package}\nVersion: {full_version}\nDepends: {dependencies}\n'
                       f'Section: {"net" if runtime else "luci"}\nArchitecture: all\nInstalled-Size: 1\n'
                       f'Maintainer: Naresh Mehta <naresh@naresh.se>\nDescription: {description}\n More detail.\n').encode()
            controls = [entry('.', mode=0o755, kind=tarfile.DIRTYPE), entry('control', control)]
            controls.append(entry('conffiles', b'/etc/config/gatekeeper\n') if runtime else
                            entry('postinst', validator.POSTINST, 0o755))
            blob = pack([entry('debian-binary', b'2.0\n'), entry('data.tar.gz', pack(payload)),
                         entry('control.tar.gz', pack(controls))])
            (self.folder / self.names[package]).write_bytes(blob)
        self.refresh()

    def refresh(self):
        sums, rows = [], []
        for package, name in self.names.items():
            digest = hashlib.sha256((self.folder / name).read_bytes()).hexdigest()
            sums.append(f'{digest}  {name}\n')
            rows.append(f'opkg\t{package}\t{self.version}-{self.release}\tall\t{name}\t{digest}\n')
        (self.folder / 'SHA256SUMS').write_text(''.join(sums))
        (self.folder / 'packages.tsv').write_text(''.join(rows))

    def validate(self):
        return validator.validate_packages(self.folder, self.base, self.version, self.release, self.source)

    def mutate(self, callback, layer='data.tar.gz', package='gatekeeper'):
        path = self.folder / self.names[package]
        outer = unpack(path.read_bytes())
        if layer is None:
            callback(outer)
        else:
            content = next(content for info, content in outer if info.name == layer)
            inner = unpack(content)
            callback(inner)
            replace_content(outer, layer, pack(inner))
        path.write_bytes(pack(outer))
        self.refresh()

    def mutate_raw(self, callback, layer='data.tar.gz'):
        def change(outer):
            if layer is None:
                return
            blob = next(content for info, content in outer if info.name == layer)
            replace_content(outer, layer, gzip.compress(callback(gzip.decompress(blob)), mtime=0))
        if layer is None:
            path = self.folder / self.names['gatekeeper']
            path.write_bytes(gzip.compress(callback(gzip.decompress(path.read_bytes())), mtime=0))
            self.refresh()
        else:
            self.mutate(change, layer=None)

    def test_valid_both_bases(self):
        for base in ('23.05', '24.10'):
            with self.subTest(base=base):
                self.build(base)
                (self.folder / 'repository-file.txt').write_text('allowed')
                self.assertEqual(set(self.validate()), set(self.names.values()))

    def test_nondefault_version_and_release(self):
        self.build('24.10', '3.4.5-rc2', '7')
        self.validate()

    def test_missing_and_extra_ipks(self):
        for extra in (False, True):
            with self.subTest(extra=extra):
                self.build()
                if extra:
                    (self.folder / 'other.ipk').write_bytes(b'')
                else:
                    (self.folder / self.names['gatekeeper']).unlink()
                with self.assertRaisesRegex(validator.ValidationError, 'IPK inventory'):
                    self.validate()

    def test_checksum_tamper(self):
        with (self.folder / self.names['gatekeeper']).open('ab') as stream:
            stream.write(b'tamper')
        with self.assertRaisesRegex(validator.ValidationError, 'checksum mismatch'):
            self.validate()

    def test_checksum_entries(self):
        path = self.folder / 'SHA256SUMS'
        original = path.read_text()
        lines = original.splitlines(keepends=True)
        cases = (lines[0] * 2, lines[0], original.replace('  openwrt-', '  ../openwrt-', 1),
                 original.replace('  openwrt-', '  /openwrt-', 1), 'z' + original[1:],
                 original.replace(self.names['gatekeeper'], 'unknown.ipk'))
        for content in cases:
            with self.subTest(content=content[:80]):
                path.write_text(content)
                with self.assertRaisesRegex(validator.ValidationError, 'SHA256SUMS'):
                    self.validate()

    def test_manifest_rows(self):
        path = self.folder / 'packages.tsv'
        original = path.read_text()
        lines = original.splitlines(keepends=True)
        cases = (lines[0] * 2, lines[0], original + lines[0], original.replace('opkg\t', 'apk\t', 1),
                 original.replace('\tgatekeeper\t', '\tunknown\t', 1),
                 original.replace('\t2.0.0-1\t', '\t9.0-1\t', 1),
                 original.replace('openwrt-23.05-', 'openwrt-24.10-', 1),
                 original.replace('\tall\t', '\tarm\t', 1),
                 original.replace(self.names['gatekeeper'], '../outside.ipk'),
                 original.replace('opkg\t', 'opkg\textra\t', 1))
        for content in cases:
            with self.subTest(content=content[:100]):
                path.write_text(content)
                with self.assertRaisesRegex(validator.ValidationError, 'packages.tsv'):
                    self.validate()

    def test_manifest_hash_mismatch(self):
        path = self.folder / 'packages.tsv'
        rows = path.read_text().splitlines()
        row = rows[0].split('\t')
        row[-1] = '0' * 64
        path.write_text('\t'.join(row) + '\n' + rows[1] + '\n')
        with self.assertRaisesRegex(validator.ValidationError, 'checksum mismatch'):
            self.validate()

    def test_invalid_arguments(self):
        for base, version, release in (('25.12', '2', '1'), ('23.05', '../escape', '1'),
                                       ('23.05', '2', '0'), ('23.05', '2', '-1'),
                                       ('23.05', '2', '1.5'), ('23.05', '2', '01')):
            with self.subTest(base=base, version=version, release=release):
                with self.assertRaises(validator.ValidationError):
                    validator.validate_packages(self.folder, base, version, release, self.source)

    def test_nonregular_and_symlink_inputs(self):
        for name in ('SHA256SUMS', 'packages.tsv', self.names['gatekeeper']):
            for kind in ('symlink', 'directory'):
                with self.subTest(name=name, kind=kind):
                    self.build()
                    path = self.folder / name
                    content = path.read_bytes()
                    path.unlink()
                    if kind == 'symlink':
                        target = self.root / 'target'
                        target.write_bytes(content)
                        path.symlink_to(target)
                    else:
                        path.mkdir()
                    with self.assertRaisesRegex(validator.ValidationError, 'regular file|symlink'):
                        self.validate()
                    if path.is_dir() and not path.is_symlink():
                        path.rmdir()
                    else:
                        path.unlink()

    def test_ar_container(self):
        (self.folder / self.names['gatekeeper']).write_bytes(b'!<arch>\n')
        self.refresh()
        with self.assertRaisesRegex(validator.ValidationError, 'not gzip'):
            self.validate()

    def test_gzip_truncated_and_bad_crc(self):
        for layer in (None, 'data.tar.gz', 'control.tar.gz'):
            for corruption in ('truncate', 'crc'):
                with self.subTest(layer=layer, corruption=corruption):
                    self.build()
                    def corrupt(blob):
                        return blob[:-5] if corruption == 'truncate' else blob[:-8] + bytes(8)
                    if layer is None:
                        path = self.folder / self.names['gatekeeper']
                        path.write_bytes(corrupt(path.read_bytes()))
                        self.refresh()
                    else:
                        self.mutate(lambda entries: replace_content(entries, layer, corrupt(
                            next(data for info, data in entries if info.name == layer))), layer=None)
                    with self.assertRaisesRegex(validator.ValidationError, 'invalid gzip'):
                        self.validate()

    def test_bad_marker(self):
        self.mutate(lambda entries: replace_content(entries, 'debian-binary', b'2.0'), layer=None)
        with self.assertRaisesRegex(validator.ValidationError, 'marker'):
            self.validate()

    def test_wrong_nesting(self):
        self.mutate(lambda entries: replace_content(entries, 'data.tar.gz', b'not gzip'), layer=None)
        with self.assertRaisesRegex(validator.ValidationError, 'not gzip'):
            self.validate()

    def test_outer_order_and_inventory(self):
        for change in (lambda entries: entries.reverse(), lambda entries: entries.append(entry('extra'))):
            self.build()
            self.mutate(change, layer=None)
            with self.assertRaisesRegex(validator.ValidationError, 'outer member'):
                self.validate()

    def test_ownership_all_layers(self):
        for layer in (None, 'data.tar.gz', 'control.tar.gz'):
            for attribute, value in (('uid', 1), ('gid', 1), ('uname', 'root'), ('gname', 'root')):
                with self.subTest(layer=layer, attribute=attribute):
                    self.build()
                    self.mutate(lambda entries: setattr(entries[0][0], attribute, value), layer)
                    with self.assertRaisesRegex(validator.ValidationError, 'ownership'):
                        self.validate()

    def test_modes_all_layers(self):
        for layer, name in ((None, 'debian-binary'), ('control.tar.gz', 'control'),
                            ('control.tar.gz', 'conffiles'), ('data.tar.gz', '.'),
                            ('data.tar.gz', 'usr/bin/gatekeeper.sh'), ('data.tar.gz', 'usr/lib/gatekeeper/restore_helpers.sh')):
            with self.subTest(layer=layer, name=name):
                self.build()
                self.mutate(lambda entries: setattr(next(info for info, _ in entries if info.name == name), 'mode', 0o777), layer)
                with self.assertRaisesRegex(validator.ValidationError, 'mode'):
                    self.validate()

    def test_config_privacy(self):
        self.mutate(lambda entries: setattr(next(info for info, _ in entries if info.name == 'etc/config/gatekeeper'), 'mode', 0o644))
        with self.assertRaisesRegex(validator.ValidationError, 'mode/type.*etc/config/gatekeeper'):
            self.validate()

    def test_postinst_guard_and_mode(self):
        for mode in (False, True):
            with self.subTest(mode=mode):
                self.build()
                if mode:
                    change = lambda entries: setattr(next(info for info, _ in entries if info.name == 'postinst'), 'mode', 0o644)
                else:
                    change = lambda entries: replace_content(entries, 'postinst', b'#!/bin/sh\n/etc/init.d/rpcd restart\n')
                self.mutate(change, 'control.tar.gz', 'luci-app-gatekeeper')
                with self.assertRaisesRegex(validator.ValidationError, 'postinst'):
                    self.validate()

    def test_conffiles_bytes(self):
        self.mutate(lambda entries: replace_content(entries, 'conffiles', b'/etc/config/other\n'), 'control.tar.gz')
        with self.assertRaisesRegex(validator.ValidationError, 'conffiles'):
            self.validate()

    def test_control_metadata_and_continuations(self):
        replacements = ((b'Package: gatekeeper', b'Package: other'), (b'Version: 2.0.0-1', b'Version: 2.0.0-2'),
                        (b'Architecture: all', b'Architecture: arm'), (b'Section: net', b'Section: other'),
                        (b'coreutils-timeout', b'unknown'), (b'Maintainer: Naresh', b'Maintainer: Other'),
                        (b'Description: Telegram', b'Description: Other'), (b'Installed-Size: 1', b'Installed-Size: 0'),
                        (b'Installed-Size: 1', b'Installed-Size: -1'), (b'Installed-Size: 1', b'Installed-Size: NaN'),
                        (b'Package: gatekeeper\n', b'Package: gatekeeper\nPackage: gatekeeper\n'),
                        (b'Version: 2.0.0-1\n', b'Version: 2.0.0-1\n invalid continuation\n'),
                        (b' More detail.', b'\t'), (b'Package: gatekeeper', b'Package gatekeeper'))
        for old, new in replacements:
            with self.subTest(replacement=new):
                self.build()
                def change(entries):
                    content = next(data for info, data in entries if info.name == 'control')
                    replace_content(entries, 'control', content.replace(old, new))
                self.mutate(change, 'control.tar.gz')
                with self.assertRaisesRegex(validator.ValidationError, 'control:'):
                    self.validate()

    def test_extra_control_file(self):
        self.mutate(lambda entries: entries.append(entry('preinst', b'bad')), 'control.tar.gz')
        with self.assertRaisesRegex(validator.ValidationError, 'inventory'):
            self.validate()

    def test_altered_source_payload(self):
        self.mutate(lambda entries: replace_content(entries, 'usr/bin/gatekeeper.sh', b'changed'))
        with self.assertRaisesRegex(validator.ValidationError, 'source bytes differ'):
            self.validate()

    def test_extra_missing_payload_files_and_directories(self):
        changes = (lambda entries: entries.append(entry('unexpected')), lambda entries: entries.pop(),
                   lambda entries: entries.append(entry('extra-dir', mode=0o755, kind=tarfile.DIRTYPE)),
                   lambda entries: entries.pop(0))
        for change in changes:
            self.build()
            self.mutate(change)
            with self.assertRaisesRegex(validator.ValidationError, 'inventory'):
                self.validate()

    def test_symlink_source_and_source_parent(self):
        for relative in ('gatekeeper.sh', 'opkg/usr/lib/gatekeeper'):
            with self.subTest(source=relative):
                path = self.source / relative
                target = self.root / ('target-' + path.name)
                path.rename(target)
                path.symlink_to(target, target_is_directory=target.is_dir())
                with self.assertRaisesRegex(validator.ValidationError, 'symlink source'):
                    self.validate()
                path.unlink()
                target.rename(path)

    def test_links_devices_and_pax_hidden_records(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE,
                     tarfile.FIFOTYPE, tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME,
                     tarfile.GNUTYPE_LONGLINK, tarfile.GNUTYPE_SPARSE):
            with self.subTest(kind=kind):
                self.build()
                self.mutate_raw(lambda raw: header_field(raw, 156, kind))
                with self.assertRaisesRegex(validator.ValidationError, 'unsupported tar record'):
                    self.validate()

    def test_duplicate_paths_including_directories(self):
        for index in (0, -1):
            self.build()
            self.mutate(lambda entries: entries.append(copy.deepcopy(entries[index])))
            with self.assertRaisesRegex(validator.ValidationError, 'duplicate tar path'):
                self.validate()

    def test_unsafe_tar_paths(self):
        for name in ('../escape', '/absolute', './foo/../escape', 'a//b', 'a/./b', 'a\\b'):
            with self.subTest(name=name):
                self.build()
                self.mutate(lambda entries: entries.append(entry(name)))
                with self.assertRaisesRegex(validator.ValidationError, 'unsafe tar path'):
                    self.validate()

    def test_absolute_and_repeated_slash_directory_paths(self):
        for name in (b'/\0', b'foo//\0', b'\0'):
            with self.subTest(name=name):
                self.build()
                self.mutate_raw(lambda raw: header_field(raw, 0, name))
                with self.assertRaisesRegex(validator.ValidationError, 'unsafe tar path'):
                    self.validate()

    def test_base256_numeric_fields(self):
        for offset in (100, 108, 116, 124, 136):
            with self.subTest(offset=offset):
                self.build()
                self.mutate_raw(lambda raw: header_field(raw, offset, b'\x80'))
                with self.assertRaisesRegex(validator.ValidationError, 'base-256'):
                    self.validate()

    def test_invalid_tar_headers(self):
        for change, message in ((lambda raw: header_field(raw, 100, b'9999999\0'), 'octal'),
                                (lambda raw: header_field(raw, 257, b'invalid!'), 'magic'),
                                (lambda raw: b'x' + raw[1:], 'header')):
            self.build()
            self.mutate_raw(change)
            with self.assertRaisesRegex(validator.ValidationError, message):
                self.validate()

    def test_truncated_tar_and_missing_end_markers(self):
        cases = ((lambda raw: raw[:-1], 'truncated tar block'),
                 (lambda raw: raw[:512], 'missing tar end marker'),
                 (lambda raw: raw[:512] + bytes(512), 'second tar end marker'),
                 (lambda raw: header_field(raw[:512], 124, b'00000077777\0'), 'directory has data'))
        for change, message in cases:
            with self.subTest(message=message):
                self.build()
                self.mutate_raw(change)
                with self.assertRaisesRegex(validator.ValidationError, message):
                    self.validate()

    def test_truncated_tar_member(self):
        self.mutate_raw(lambda raw: header_field(raw[:512], 124, b'00000077777\0'), layer=None)
        with self.assertRaisesRegex(validator.ValidationError, 'truncated tar member'):
            self.validate()

    def test_tar_trailing_data(self):
        self.mutate_raw(lambda raw: raw + b'x' + bytes(511))
        with self.assertRaisesRegex(validator.ValidationError, 'trailing data'):
            self.validate()

    def test_nonzero_tar_padding(self):
        self.mutate_raw(lambda raw: raw[:516] + b'x' + raw[517:], layer=None)
        with self.assertRaisesRegex(validator.ValidationError, 'padding'):
            self.validate()

    def test_size_limits(self):
        for constant, limit, message in (('MAX_COMPRESSED', 10, 'size limit'),
                                         ('MAX_UNCOMPRESSED', 512, 'uncompressed size limit'),
                                         ('MAX_MEMBERS', 1, 'member count limit'),
                                         ('MAX_MANIFEST', 10, 'size limit')):
            with self.subTest(constant=constant), patch.object(validator, constant, limit):
                with self.assertRaisesRegex(validator.ValidationError, message):
                    self.validate()

    def test_gzip_bomb_bounded(self):
        with patch.object(validator, 'MAX_UNCOMPRESSED', 1024):
            with self.assertRaisesRegex(validator.ValidationError, 'uncompressed size limit'):
                validator.archive(gzip.compress(bytes(1024 * 1024)), 'bomb fixture')

    def test_cli_different_cwd_and_optimized_rejection(self):
        script = Path(validator.__file__).resolve()
        arguments = [str(script), str(self.folder), self.base, self.version, '--source-root', str(self.source)]
        valid = subprocess.run([sys.executable, *arguments], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(valid.stdout.count('PASS:'), 2)
        self.mutate(lambda entries: replace_content(entries, 'debian-binary', b'bad'), layer=None)
        invalid = subprocess.run([sys.executable, '-O', *arguments], cwd=self.root, capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn('FAIL:', invalid.stderr)
        self.assertIn('marker', invalid.stderr)
        self.assertNotIn('Traceback', invalid.stderr)
        self.assertNotIn('PASS:', invalid.stdout)

    def test_cli_default_source_root_from_different_cwd(self):
        repository = Path(validator.__file__).resolve().parents[1]
        for package in validator.PACKAGES:
            mapping = validator.inventory(package)
            def change(entries):
                for destination, (source, _) in mapping.items():
                    replace_content(entries, destination, (repository / source).read_bytes())
            self.mutate(change, package=package)
        arguments = [sys.executable, str(Path(validator.__file__).resolve()), str(self.folder), self.base, self.version]
        result = subprocess.run(arguments, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('PASS:'), 2)
        self.assertEqual(len(validator.validate_packages(self.folder, self.base, self.version)), 2)

    def test_gnu_hidden_header_extensions(self):
        for offset in (345, 357, 369, 482):
            with self.subTest(offset=offset):
                self.build()
                self.mutate_raw(lambda raw: header_field(raw, offset, b'1'))
                with self.assertRaisesRegex(validator.ValidationError, 'unsupported GNU header extension'):
                    self.validate()

    def test_manifest_missing_and_invalid_utf8(self):
        for name in ('SHA256SUMS', 'packages.tsv'):
            for missing in (True, False):
                with self.subTest(name=name, missing=missing):
                    self.build()
                    path = self.folder / name
                    if missing:
                        path.unlink()
                    else:
                        path.write_bytes(b'\xff')
                    with self.assertRaisesRegex(validator.ValidationError, 'cannot read regular file|invalid UTF-8'):
                        self.validate()

    def test_cli_release_and_invalid_arguments(self):
        self.build('24.10', '4.5.6', '9')
        arguments = [sys.executable, str(Path(validator.__file__).resolve()), str(self.folder), self.base,
                     self.version, '--release', '9', '--source-root', str(self.source)]
        result = subprocess.run(arguments, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for index, value in ((3, '25.12'), (6, '0')):
            invalid_args = arguments.copy()
            invalid_args[index] = value
            result = subprocess.run(invalid_args, cwd=self.root, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(result.stderr)


if __name__ == '__main__':
    unittest.main()
