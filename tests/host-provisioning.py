#!/usr/bin/env python3
"""Local tests only: no sudo, root installation, credentials or live cluster."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('provision_host', ROOT / 'scripts/provision_host.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
COMMIT = 'a' * 40


def env_values():
    values = {'HERMES_NAMESPACE': 'assistant', 'HERMES_AUTH_MODE': 'local-password',
              'HERMES_BOOTSTRAP_MODE': 'disabled', 'HERMES_ADDON_REQUIREMENTS': '',
              'HERMES_VELERO_STORAGE_LOCATION': 'default'}
    for key in ('HERMES_AGENT_IMAGE', 'HERMES_WEBUI_IMAGE', 'HERMES_BROWSER_IMAGE'):
        values[key] = 'registry.example.com/image:1.2.3@sha256:' + 'b' * 64
    return values


def env_bytes(values=None):
    return ''.join(k + '=' + v + '\n' for k, v in (values or env_values()).items()).encode()


def archive(extra=None, commit=COMMIT):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.PAX_FORMAT,
                      pax_headers={'comment': commit}) as tar:
        for name in p.REQUIRED:
            member = tarfile.TarInfo(name)
            data = b'# synthetic test fixture only\n'
            member.size = len(data)
            member.mode = 0o755
            tar.addfile(member, io.BytesIO(data))
        if extra:
            tar.addfile(extra, io.BytesIO(b'x' * extra.size))
    return stream.getvalue()


class PureTests(unittest.TestCase):
    def test_revision_rejects_unpinned_or_injected(self):
        for value in ('main', 'a' * 39, 'A' * 40, '--help', '../' + COMMIT):
            with self.subTest(value=value), self.assertRaises(p.Error):
                p.revision(value)
        self.assertEqual(p.revision(COMMIT), COMMIT)

    def test_config_data_is_never_executed(self):
        self.assertEqual(p.parse_env(b'VALUE="$(touch /not-executed)"\n')['VALUE'], '$(touch /not-executed)')
        for text in (b'KEY=x\nKEY=y', b'KEY=x command', b'export KEY=x', b'bad=x'):
            with self.assertRaises(p.Error):
                p.parse_env(text)

    def test_settings_contract(self):
        self.assertEqual(p.settings(env_values()), {'namespace': 'velero', 'storage_location': 'default', 'ttl': '720h'})
        for key, value in [('HERMES_NAMESPACE', ''), ('HERMES_NAMESPACE', 'bad-'),
                           ('HERMES_AUTH_MODE', ''), ('HERMES_BOOTSTRAP_MODE', 'missing'),
                           ('HERMES_ADDON_REQUIREMENTS', 'requirements.txt'),
                           ('HERMES_AGENT_IMAGE', 'image:latest'),
                           ('HERMES_VELERO_NAMESPACE', 'bad/namespace'),
                           ('HERMES_VELERO_STORAGE_LOCATION', ''),
                           ('HERMES_VELERO_BACKUP_TTL', '0h')]:
            values = env_values(); values[key] = value
            with self.subTest(key=key), self.assertRaises(p.Error):
                p.settings(values)
        values = env_values(); values['HERMES_VELERO_BACKUP_TTL'] = '24h'
        self.assertEqual(p.settings(values)['ttl'], '24h')
        values['HERMES_VELERO_NAMESPACE'] = 'backup-system'
        self.assertEqual(p.settings(values)['namespace'], 'backup-system')
        values['HERMES_VELERO_NAMESPACE'] = values['HERMES_NAMESPACE']
        with self.assertRaises(p.Error):
            p.settings(values)

    def test_archive_good_and_commit_mismatch(self):
        self.assertEqual(set(p.archive_files(archive(), COMMIT)), set(p.REQUIRED))
        with self.assertRaises(p.Error):
            p.archive_files(archive(commit='b' * 40), COMMIT)

    def test_archive_rejects_traversal_links_devices_duplicates(self):
        for name, kind in [('../escape', tarfile.REGTYPE), ('/escape', tarfile.REGTYPE),
                           ('a/./b', tarfile.REGTYPE), ('a//b', tarfile.REGTYPE),
                           ('link', tarfile.SYMTYPE), ('link', tarfile.LNKTYPE),
                           ('device', tarfile.CHRTYPE), ('fifo', tarfile.FIFOTYPE),
                           (p.REQUIRED[0], tarfile.REGTYPE),
                           (p.RECEIPT, tarfile.REGTYPE), ('scripts', tarfile.REGTYPE)]:
            member = tarfile.TarInfo(name); member.type = kind
            member.linkname = '/etc/passwd'
            with self.subTest(name=name, kind=kind), self.assertRaises(p.Error):
                p.archive_files(archive(member), COMMIT)

    def test_reserve_accounts_for_planned_writes(self):
        fs = type('FS', (), {'f_blocks': 1000, 'f_bavail': 110, 'f_frsize': 1})()
        with patch.object(p.os, 'statvfs', return_value=fs):
            p.reserve('/', 10)
            with self.assertRaises(p.Error):
                p.reserve('/', 11)

    def test_trusted_rejects_owner_mode_and_symlink(self):
        for uid, mode in [(1, stat.S_IFREG | 0o600), (0, stat.S_IFREG | 0o622),
                          (0, stat.S_IFLNK | 0o777)]:
            value = type('Stat', (), {'st_uid': uid, 'st_mode': mode})()
            with patch.object(Path, 'lstat', return_value=value), self.assertRaises(p.Error):
                p.trusted('/protected/file', regular=True)

    def test_active_workers_fail_closed(self):
        with patch.object(p, 'run', return_value='hermes-maintenance-test.service loaded active running'):
            with self.assertRaises(p.Error):
                p.no_workers()

    def test_help_no_privileged_calls(self):
        result = subprocess.run(['bash', str(ROOT / 'provision-host.sh'), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('administrator', result.stdout)
        result = subprocess.run(['python3', str(ROOT / 'scripts/provision_host.py'), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--stage-archive', result.stdout)


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='host-provisioning-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        for constant, relative in [('SOURCES', 'sources'), ('CONFIG', 'config'),
                                   ('STATE', 'backup'), ('RECOVERY', 'backup/recovery'),
                                   ('PROVISION', 'libexec/hermes-provision-host.py'),
                                   ('HELPER', 'libexec/hermes-maintenance-v2.py'), ('AUDIT', 'CHANGES.md')]:
            obj = patch.object(p, constant, self.root / relative); obj.start(); self.addCleanup(obj.stop)
        # Privilege boundary mocked to this test-owned fixture. Never install to
        # actual privileged paths, even when a test runner happens to be root.
        def fixture_trusted(path, regular=False):
            path = Path(path)
            self.assertTrue(path.is_relative_to(self.root), 'attempt to access outside fixture')
            for item in [path, *path.relative_to(self.root).parents]:
                if not item.is_absolute():
                    continue
                st = item.lstat()
                p.require(not stat.S_ISLNK(st.st_mode) and not st.st_mode & 0o022, 'Untrusted fixture path')
            if regular:
                p.require(path.is_file(), 'Expected regular fixture file')
            return path
        obj = patch.object(p, 'trusted', side_effect=fixture_trusted); obj.start(); self.addCleanup(obj.stop)
        obj = patch.object(p, 'reserve'); obj.start(); self.addCleanup(obj.stop)
        self.runner = patch.object(p, 'run', return_value=''); self.run_mock = self.runner.start(); self.addCleanup(self.runner.stop)
        self.checkout = self.root / 'checkout'; self.checkout.mkdir()
        self.env = self.checkout / 'hermes.env'; self.env.write_bytes(env_bytes())
        self.credential = self.root / 'cluster.kubeconfig'
        # A credential placeholder, not real kubeconfig contents.
        self.credential.touch(mode=0o600)

    def stage(self):
        data = archive()
        path = self.root / 'source.tar'; path.write_bytes(data); path.chmod(0o600)
        return p.stage(path, hashlib.sha256(data).hexdigest(), COMMIT)

    def inventory(self, credential, *args):
        self.assertEqual(credential, self.credential)
        self.assertIn('get', args)
        if args == ('get', 'namespace', 'kube-system'):
            return {'metadata': {'uid': 'cluster-uid'}}
        if args == ('get', 'namespace', 'assistant'):
            return {'metadata': {'uid': 'namespace-uid'}}
        self.assertEqual(args, ('-n', 'assistant', 'get', 'pvc'))
        return {'items': [{'metadata': {'name': n, 'uid': n + '-uid'}, 'status': {'phase': 'Bound'}}
                          for n in ('hermes-home', 'hermes-workspace')]}

    def test_stage_is_immutable_and_detects_content_drift(self):
        source = self.stage()
        self.assertEqual(p.reviewed_source(COMMIT), source)
        self.assertEqual(self.stage(), source)
        (source / 'scripts/stable_images.py').write_text('# changed')
        with self.assertRaises(p.Error):
            p.reviewed_source(COMMIT)

    def test_stage_digest_mismatch(self):
        path = self.root / 'source.tar'; path.write_bytes(archive())
        with self.assertRaises(p.Error):
            p.stage(path, '0' * 64, COMMIT)
        self.assertFalse(p.SOURCES.exists())

    def test_config_unique_and_symlink_rejection(self):
        self.assertEqual(p.source_config(self.checkout)[0], self.env)
        wizard = self.checkout / 'current_config'; wizard.mkdir()
        other = wizard / 'hermes.env'; other.write_bytes(env_bytes())
        with self.assertRaises(p.Error):
            p.source_config(self.checkout)
        self.env.unlink()
        self.assertEqual(p.source_config(self.checkout)[0], other)
        other.unlink(); other.symlink_to(self.credential)
        with self.assertRaises(p.Error):
            p.source_config(self.checkout)
        other.unlink()
        with self.assertRaises(p.Error):
            p.source_config(self.checkout)

    def test_enroll_backup_preservation_and_binding_v2(self):
        self.stage()
        unrelated = p.CONFIG / 'unrelated-legacy.json'; unrelated.write_text('{"legacy":true}')
        p.HELPER.parent.mkdir(); p.HELPER.write_bytes(b'old helper')
        legacy = p.HELPER.with_name('hermes-maintenance.py')
        legacy.write_bytes(b'legacy controller must remain unchanged')
        legacy.chmod(0o755)
        legacy_stat = legacy.stat()
        with patch.object(p, 'kube', side_effect=self.inventory):
            name = p.enroll(self.checkout, COMMIT, str(self.credential))
            binding = json.loads((p.CONFIG / (name + '.json')).read_text())
            self.assertEqual(binding['binding_version'], 2)
            self.assertNotIn('recovery_backend', binding)
            self.assertEqual(binding['velero'], {'namespace': 'velero', 'storage_location': 'default', 'ttl': '720h'})
            self.assertEqual(binding['pvc_uids']['hermes-home'], 'hermes-home-uid')
            self.assertEqual((p.CONFIG / (name + '.env')).read_bytes(), self.env.read_bytes())
            p.enroll(self.checkout, COMMIT, str(self.credential))
        backups = list(p.STATE.glob('enrollment-*'))
        self.assertEqual(len(backups), 1)  # Identical reenrollment is a no-change pass.
        self.assertTrue(any((x / '0-hermes-maintenance-v2.py').read_bytes() == b'old helper' for x in backups))
        self.assertEqual(unrelated.read_text(), '{"legacy":true}')
        self.assertEqual(legacy.read_bytes(), b'legacy controller must remain unchanged')
        self.assertEqual((legacy.stat().st_ino, legacy.stat().st_mtime_ns, legacy.stat().st_mode),
                         (legacy_stat.st_ino, legacy_stat.st_mtime_ns, legacy_stat.st_mode))
        self.assertEqual(stat.S_IMODE(p.RECOVERY.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((p.CONFIG / (name + '.env')).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(p.HELPER.stat().st_mode), 0o755)
        self.assertIn('enrollment-complete', p.AUDIT.read_text())

    def test_kubeconfig_not_read_or_copied(self):
        self.stage()
        original = Path.read_bytes
        def guarded_read(path):
            self.assertNotEqual(path, self.credential, 'credential content was read')
            return original(path)
        with patch.object(p, 'kube', side_effect=self.inventory), patch.object(Path, 'read_bytes', guarded_read):
            p.enroll(self.checkout, COMMIT, str(self.credential))
        self.assertFalse(any(x.name == self.credential.name for x in p.STATE.rglob('*')))

    def test_kubeconfig_conflict_rejected_before_queries(self):
        self.stage()
        values = env_values(); values['KUBECONFIG'] = str(self.credential)
        self.env.write_bytes(env_bytes(values))
        with patch.object(p, 'kube') as kube, self.assertRaises(p.Error):
            p.make_binding(self.checkout, COMMIT, '/different/location')
        kube.assert_not_called()

    def test_missing_explicit_storage_rejected_before_queries(self):
        self.stage()
        values = env_values(); del values['HERMES_VELERO_STORAGE_LOCATION']
        self.env.write_bytes(env_bytes(values))
        with patch.object(p, 'kube') as kube, self.assertRaises(p.Error):
            p.make_binding(self.checkout, COMMIT, str(self.credential))
        kube.assert_not_called()

    def test_active_maintenance_preserves_helper(self):
        self.stage()
        p.HELPER.parent.mkdir(); p.HELPER.write_bytes(b'old helper')
        self.run_mock.return_value = 'hermes-maintenance-active.service loaded active running'
        with patch.object(p, 'kube', side_effect=self.inventory), self.assertRaises(p.Error):
            p.enroll(self.checkout, COMMIT, str(self.credential))
        self.assertEqual(p.HELPER.read_bytes(), b'old helper')
        self.assertEqual(list(p.STATE.glob('enrollment-*')), [])

    def test_operation_lock_excludes_enrollment(self):
        self.stage()
        with (p.RECOVERY / 'operation.lock').open('r+') as lock:
            p.fcntl.flock(lock, p.fcntl.LOCK_EX | p.fcntl.LOCK_NB)
            with patch.object(p, 'kube', side_effect=self.inventory), self.assertRaises(p.Error):
                p.enroll(self.checkout, COMMIT, str(self.credential))
        self.assertFalse(p.HELPER.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
