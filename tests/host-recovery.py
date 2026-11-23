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

    def test_progress_uses_flat_argv_and_only_public_fields(self):
        (self.root / 'replicas.json').write_text(json.dumps({'namespace': 'fixture',
            'backup': 'known-backup', 'private': 'must-not-appear'}))
        def run(args):
            self.assertTrue(all(isinstance(x, str) for x in args))
            if 'podvolumebackups.velero.io' in args:
                return json.dumps({'items': [{'metadata': {'labels': {'velero.io/backup-name': 'known-backup'}},
                    'spec': {'volume': 'home'}, 'status': {'phase': 'InProgress',
                    'progress': {'bytesDone': 10, 'totalBytes': 100}}}]})
            return json.dumps({'metadata': {'annotations': {}}, 'status': {'phase': 'InProgress'}})
        with patch.object(h, 'trusted', side_effect=Path), patch.object(h, 'run', side_effect=run):
            data = h.operation_progress({'namespace': 'fixture', 'kubeconfig': '/example/config',
                                        'velero': {'namespace': 'velero'}}, self.root)
        self.assertEqual(data[0]['stage'], 'InProgress')
        self.assertNotIn('must-not-appear', json.dumps(data))

    def test_restore_pin_reconciliation_uses_real_kube_argument_contract(self):
        profile, folder, plan = self.pin_fixture()
        profile.update(namespace='fixture', kubeconfig='/example/config')
        plan.update(operation='restore', target_backup='known-backup', instance='checkout-fixture',
                    phase='prepared; no workloads changed')
        audit = self.root / 'CHANGES.md'; audit.write_text('')
        backend = SimpleNamespace(ROOT=self.root, restore=lambda *a: {'namespace_uid': 'new'})
        restored_image = 'example/image:v1.0.0@sha256:' + 'a' * 64
        def run(args):
            self.assertTrue(all(isinstance(x, str) for x in args))
            if 'namespace' in args:
                return json.dumps({'metadata': {'uid': 'new'}})
            return json.dumps({'items': [{'metadata': {'name': 'hermes-agent'}, 'spec': {'template':
                {'spec': {'containers': [{'image': restored_image}]}}}}]})
        with patch.object(h, 'recovery_backend', return_value=backend), \
             patch.object(h, 'trusted', side_effect=lambda p: audit if str(p) == '/CHANGES.md' else Path(p)), \
             patch.object(h, 'recovery_guard'), patch.object(h, 'run', side_effect=run), \
             patch.object(h, 'publish_image_pins') as publish:
            h.recovery_worker(profile, folder, plan)
            self.assertEqual(publish.call_args.args[2]['images']['HERMES_AGENT_IMAGE'], restored_image)
            restored_image = 'example/image:v1.2.2'
            publish.reset_mock()
            h.recovery_worker(profile, folder, plan)
            self.assertEqual(publish.call_args.args[2]['images']['HERMES_AGENT_IMAGE'],
                             h.envfile(profile['env_file'])['HERMES_AGENT_IMAGE'])
            restored_image = 'example/image:v0.0.9'
            publish.reset_mock()
            with self.assertRaisesRegex(h.Error, 'matching reviewed pins'):
                h.recovery_worker(profile, folder, plan)
            publish.assert_not_called()
        self.assertTrue(plan['phase'].startswith('restore-complete'))

    def exercise_real_recovery_contract(self, fail_helper=False):
        # Reuse only the native-CLI fixture: coordinator, guard, snapshot, backup,
        # restore, seals, coverage and image reconciliation run their real code.
        spec = importlib.util.spec_from_file_location('backend_fixture', ROOT / 'tests/velero-recovery.py')
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        backend = fixture.Fake()
        backend.ROOT = self.root
        name, _ = backend.backup(backend.binding['namespace'], self.root / 'known-good')
        backend.make_unhealthy()
        backend.fail_remove = fail_helper
        backend.actions.clear()
        profile, _, _ = self.pin_fixture()
        profile.update(backend.binding, source=str(ROOT), source_revision='reviewed')
        audit = self.root / 'CHANGES.md'; audit.write_text('')
        def run(args):
            if args[0] == 'systemd-run':
                return ''
            self.assertEqual(args[0], 'kubectl')
            i = args.index('get')
            kind = args[i + 1]
            name = args[i + 2] if args[i + 2] != '-o' else None
            ns = args[args.index('-n') + 1] if '-n' in args else None
            return json.dumps(backend._get(kind, name, ns))
        with patch.object(h, 'recovery_backend', return_value=backend), \
             patch.object(h, 'profile', return_value=profile), \
             patch.object(h, 'trusted', side_effect=lambda p: audit if str(p) == '/CHANGES.md' else Path(p)), \
             patch.object(h, 'tree_hash', return_value={}), \
             patch.object(h, 'STATE', self.root / 'state'), \
             patch.object(h.os, 'statvfs', return_value=SimpleNamespace(f_bavail=50, f_blocks=100)), \
             patch.object(h, 'run', side_effect=run), patch.object(h, 'output'):
            h.launch_recovery(profile, 'checkout-fixture', 'restore', name)
            folder = next((self.root / 'state').iterdir())
            plan = json.loads((folder / 'plan.json').read_text())
            if fail_helper:
                with self.assertRaises(fixture.r.RecoveryError):
                    h.recovery_worker(profile, folder, plan)
                self.assertFalse(backend.deleted)
                self.assertTrue((folder / 'failure.json').exists())
                self.assertEqual([d['spec']['replicas'] for d in backend.deps], [0, 0])
            else:
                h.recovery_worker(profile, folder, plan)
                result = json.loads((folder / 'restore-result.json').read_text())
                self.assertEqual(result['stage'], 'completed')
                self.assertEqual(h.envfile(profile['config_path'])['HERMES_AGENT_IMAGE'],
                                 'example/image:v1.0.0@sha256:' + 'a' * 64)
                self.assertTrue(plan['phase'].startswith('restore-complete'))
                with self.assertRaises(fixture.r.RecoveryError):
                    backend.eligible(result['safetyBackup'], profile['namespace'])
            self.assertTrue((folder / 'diagnostics/handoff.json').exists())
            self.assertFalse((folder / 'safety/resume.json').exists())

    def test_real_coordinator_backend_unhealthy_restore_contract(self):
        self.exercise_real_recovery_contract()

    def test_real_coordinator_backend_unsafe_helper_blocks_deletion(self):
        self.exercise_real_recovery_contract(fail_helper=True)

    def pin_fixture(self):
        images = {key: 'example/image:v1.2.3@sha256:' + 'a' * 64 for key in
                  ['HERMES_AGENT_IMAGE', 'HERMES_WEBUI_IMAGE', 'HERMES_BROWSER_IMAGE']}
        data = '# keep comment\nHERMES_NAMESPACE=fixture\nOTHER_VALUE=keep\n' + ''.join(k + '=docker.io/example/image:v1.2.2@sha256:' + 'b' * 64 + '\n' for k in images)
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
