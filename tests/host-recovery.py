#!/usr/bin/env python3
"""Coordinator unit tests; subprocesses and cluster state are explicitly mocked."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_recovery_tests', ROOT / 'scripts/host_maintenance.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


class Coordinator(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def test_restore_acknowledgment_precedes_host_access(self):
        with patch.object(h, 'profile') as profile:
            with self.assertRaises(SystemExit) as error:
                h.main(['--checkout', str(self.root), 'restore', 'known-backup'])
            self.assertEqual(error.exception.code, 2)
            profile.assert_not_called()

    def test_shared_lock_prevents_provision_replacement(self):
        (self.root / 'provision.lock').write_text('')
        with patch.object(h, 'CONFIG', self.root), patch.object(h, 'trusted', side_effect=Path):
            with h.shared_provision_lock():
                with (self.root / 'provision.lock').open('rb') as stream:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_readonly_lock_does_not_bootstrap_host_state(self):
        with patch.object(h, 'CONFIG', self.root), patch.object(h, 'trusted', side_effect=Path):
            with self.assertRaises(FileNotFoundError):
                with h.shared_provision_lock():
                    pass
        self.assertEqual(list(self.root.iterdir()), [])

    def test_backup_launch_is_supervised_and_bound(self):
        config = self.root / 'hermes.env'; config.write_text('HERMES_NAMESPACE=fixture\n')
        profile = dict(namespace='fixture', checkout=str(self.root), config_path=str(config),
                       source=str(ROOT), source_revision='reviewed')
        backend = SimpleNamespace(preflight=lambda ns: None)
        with patch.object(h, 'recovery_backend', return_value=backend), \
             patch.object(h, 'STATE', self.root / 'state'), \
             patch.object(h, 'snapshot', return_value={'namespace': 'bound'}), \
             patch.object(h, 'tree_hash', return_value={}), \
             patch.object(h.os, 'statvfs', return_value=SimpleNamespace(f_bavail=50, f_blocks=100)), \
             patch.object(h, 'run') as run, patch.object(h, 'output'):
            h.launch_recovery(profile, 'checkout-fixture', 'backup')
        args = run.call_args.args[0]
        self.assertEqual(args[0], 'systemd-run')
        self.assertIn('--worker', args)
        self.assertEqual(args[args.index('--checkout') + 1], str(self.root))
        plan = json.loads(next((self.root / 'state').glob('*/plan.json')).read_text())
        self.assertEqual(plan['operation'], 'backup')
        self.assertEqual(plan['phase'], 'prepared; no workloads changed')
        self.assertIsNone(plan['backup'])

    def test_backend_preflight_blocks_planning_before_artifacts(self):
        def refuse(ns):
            raise RuntimeError('synthetic unavailable backup prerequisite')
        with patch.object(h, 'recovery_backend', return_value=SimpleNamespace(preflight=refuse)), \
             patch.object(h, 'snapshot') as snapshot, patch.object(h, 'STATE', self.root / 'state'):
            with self.assertRaises(RuntimeError):
                h.prepare({'namespace': 'fixture'}, 'checkout-fixture', True)
            snapshot.assert_not_called()
            self.assertFalse((self.root / 'state').exists())

    def pin_fixture(self):
        images = {key: 'example/image:v1.2.3@sha256:' + 'a' * 64 for key in
                  ['HERMES_AGENT_IMAGE', 'HERMES_WEBUI_IMAGE', 'HERMES_BROWSER_IMAGE']}
        data = '# keep comment\nHERMES_NAMESPACE=fixture\nOTHER_VALUE=keep\n' + ''.join(k + '=example/image:v1.2.2\n' for k in images)
        source, protected = self.root / 'hermes.env', self.root / 'protected.env'
        source.write_text(data); protected.write_text(data)
        folder = self.root / 'operation'; folder.mkdir(mode=0o700)
        return dict(config_path=str(source), env_file=str(protected)), folder, dict(
            images=images, config_sha256=hashlib.sha256(data.encode()).hexdigest())

    def test_verified_rollout_pins_are_persisted_without_internal_mode(self):
        profile, folder, plan = self.pin_fixture()
        with patch.object(h, 'trusted', side_effect=Path):
            h.publish_image_pins(profile, folder, plan)
        source = Path(profile['config_path']); protected = Path(profile['env_file'])
        self.assertEqual(source.read_bytes(), protected.read_bytes())
        self.assertTrue(source.read_text().startswith('# keep comment\n'))
        self.assertEqual(h.envfile(source)['OTHER_VALUE'], 'keep')
        self.assertNotIn('HERMES_MAINTENANCE_UPGRADE', h.envfile(source))
        self.assertEqual(source.stat().st_mode & 0o777, 0o600)
        self.assertTrue((folder / 'source-config-before.env').exists())
        for key, value in plan['images'].items():
            self.assertEqual(h.envfile(source)[key], value)

    def test_concurrent_config_edit_does_not_get_overwritten(self):
        profile, folder, plan = self.pin_fixture()
        source = Path(profile['config_path'])
        source.write_text(source.read_text() + '# operator concurrent edit\n')
        edited = source.read_bytes()
        with patch.object(h, 'trusted', side_effect=Path):
            with self.assertRaisesRegex(h.Error, 'source configuration changed'):
                h.publish_image_pins(profile, folder, plan)
        self.assertEqual(source.read_bytes(), edited)
        self.assertEqual(list(folder.iterdir()), [])

    def test_atomic_configuration_rejects_symlink(self):
        target = self.root / 'actual'; target.write_bytes(b'keep')
        link = self.root / 'link'; link.symlink_to(target)
        with self.assertRaises(h.Error):
            h.replace_configuration(link, b'replace', hashlib.sha256(b'keep').hexdigest())
        self.assertEqual(target.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main(verbosity=2)
