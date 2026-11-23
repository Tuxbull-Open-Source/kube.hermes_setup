#!/usr/bin/env python3
"""Mocked unit/sequence tests only: no CLI invocation or live cluster access."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('recovery', Path(__file__).resolve().parents[1] / 'scripts/velero_recovery.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
BINDING = {'checkout': '/example/checkout', 'namespace': 'example-app', 'namespace_uid': 'ns-original', 'cluster_uid': 'cluster-original',
           'pvc_uids': {'hermes-home': 'home-original', 'hermes-workspace': 'workspace-original'},
           'kubeconfig': '/protected/kubeconfig', 'velero': {'storage_location': 'primary'}}
PROBES = 'a' * 64 + '  /data/home/sample\n600:10000:10000\n' + 'b' * 64 + '  /data/workspace/sample\n644:10000:10000\n'


def obj(name, uid=None, spec=None, status=None):
    return {'metadata': {'name': name, 'uid': uid or name + '-uid'}, 'spec': spec or {}, 'status': status or {}}


class Fake(r.RecoveryBackend):
    """In-memory Kubernetes/Velero fixture; command effects are explicitly mocked."""
    def __init__(self):
        super().__init__(BINDING)
        self.nsuid = BINDING['namespace_uid']
        self.pvcuids = dict(BINDING['pvc_uids'])
        self.deps = [obj('agent', spec={'replicas': 2}), obj('browser', spec={'replicas': 0})]
        self.pods, self.backups, self.restores, self.records = [], {}, {}, {}
        self.actions, self.objects = [], []
        self.fail_backup = self.fail_resume = self.fail_remove = self.bad_hash = False
        self.deleted = False

    def _get(self, kind, name=None, ns=None):
        if name is None:
            return {'items': self._items(kind, ns)}
        if kind == 'namespace':
            return obj(name, 'cluster-original' if name == 'kube-system' else self.nsuid)
        if kind == 'backupstoragelocations.velero.io':
            return obj(name, status={'phase': 'Available'})
        if kind == 'daemonset':
            return obj(name, status={'numberReady': 1, 'desiredNumberScheduled': 1})
        if kind == 'storageclass':
            return {'provisioner': 'example.com/dynamic'}
        if kind == 'persistentvolume':
            claim = name.removeprefix('pv-')
            return obj(name, spec={'claimRef': {'uid': self.pvcuids[claim], 'namespace': self.binding['namespace']}})
        if kind == 'deployment':
            if name == 'velero' and ns == self.velero_namespace:
                return obj(name, spec={'template': {'spec': {'containers': [
                    {'name': 'velero', 'image': 'velero/velero:v1.18.4'}]}}})
            return copy.deepcopy(next(d for d in self.deps if d['metadata']['name'] == name))
        if kind == 'pod':
            return copy.deepcopy(next(p for p in self.pods if p['metadata']['name'] == name))
        if kind == 'backups.velero.io':
            return copy.deepcopy(self.backups[name])
        if kind == 'restores.velero.io':
            return copy.deepcopy(self.restores[name])
        raise AssertionError(('unexpected get', kind))

    def _items(self, kind, ns=None):
        if kind in ('persistentvolumeclaims', 'pvc'):
            return [obj(n, u, {'storageClassName': 'dynamic', 'volumeName': ('new-' if self.deleted else '') + 'pv-' + n},
                        {'phase': 'Bound'}) for n, u in self.pvcuids.items()]
        if kind == 'deployments':
            return copy.deepcopy(self.deps)
        if kind == 'pods':
            return copy.deepcopy(self.pods)
        if kind == 'namespaces':
            return [] if self.nsuid is None else [obj(self.binding['namespace'], self.nsuid)]
        if kind == 'backups.velero.io':
            return list(self.backups.values())
        if kind == 'restores.velero.io':
            return list(self.restores.values())
        if kind in ('podvolumebackups.velero.io', 'podvolumerestores.velero.io'):
            return [p for (k, _), records in self.records.items() if k == kind for p in records]
        return []

    def _run(self, argv, data=None, timeout=90):
        if 'api-resources' in argv:
            return 'namespaces\npersistentvolumes\ncustomresourcedefinitions.apiextensions.k8s.io\n'
        self.actions.append(list(argv))
        if 'scale' in argv:
            name = next(a.split('/', 1)[1] for a in argv if a.startswith('deployment/'))
            replicas = int(next(a.split('=')[1] for a in argv if a.startswith('--replicas=')))
            if self.fail_resume and replicas:
                raise r.RecoveryError('mock resume failure')
            next(d for d in self.deps if d['metadata']['name'] == name)['spec']['replicas'] = replicas
        if 'exec' in argv:
            return PROBES.replace('a', 'c') if self.bad_hash and self.deleted else PROBES
        if 'delete' in argv and 'pod' in argv:
            if self.fail_remove:
                raise r.RecoveryError('mock helper failure')
            self.pods = []
        if 'delete' in argv and 'namespace' in argv:
            self.nsuid, self.pods, self.deleted = None, [], True
        if 'annotate' in argv:
            name = argv[argv.index('backups.velero.io') + 1]
            self.backups[name]['metadata']['annotations'][r.SEAL] = 'true'
        return ''

    def _archive_scope(self, name, meta, folder):
        self.actions.append(('archive-scope', name))

    def _create(self, value):
        self.objects.append(copy.deepcopy(value))
        kind, name = value['kind'], value['metadata']['name']
        if kind == 'Pod':
            value = copy.deepcopy(value)
            value['metadata']['uid'] = 'helper-uid'
            value['status'] = {'phase': 'Running'}
            self.pods = [value]
        if kind == 'Backup':
            if self.fail_backup:
                raise r.RecoveryError('mock backup failure')
            value = copy.deepcopy(value)
            value['status'] = {'phase': 'Completed', 'expiration': '2099-01-01T00:00:00Z'}
            self.backups[name] = value
            m = json.loads(value['metadata']['annotations'][r.KEY])
            self._records(name, m)
        if kind == 'Restore':
            self.nsuid = 'ns-restored'
            self.pvcuids = {n: u + '-new' for n, u in self.pvcuids.items()}
            for d in self.deps:
                d['metadata']['uid'] += '-new'
            m = json.loads(self.backups[value['spec']['backupName']]['metadata']['annotations'][r.KEY])
            helper = self._helper(m)
            helper['metadata']['uid'] = 'helper-restored'
            helper['status'] = {'phase': 'Running'}
            self.pods = [helper]
            self.restores[name] = dict(value, status={'phase': 'Completed'})
            self._records(name, dict(m, helperUID='helper-restored'), True)

    def _records(self, name, m, restore=False):
        records = []
        for volume in sorted(r.VOLUMES):
            p = obj('record-' + volume, spec={'volume': volume, 'pod': {'name': m['helper'], 'namespace': m['namespace'],
                        'uid': m['helperUID']}, 'uploaderType': 'kopia', 'backupStorageLocation': self.location},
                    status={'phase': 'Completed', 'snapshotID': 'snapshot-' + volume})
            p['metadata']['labels'] = {('velero.io/restore-name' if restore else 'velero.io/backup-name'): name,
                                        'velero.io/pvc-uid': m['pvcs']['hermes-' + volume]}
            p['metadata']['annotations'] = {'velero.io/pvc-name': 'hermes-' + volume}
            records.append(p)
        self.records[('podvolumerestores.velero.io' if restore else 'podvolumebackups.velero.io', name)] = records


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.b = Fake()
        self.ns = BINDING['namespace']

    def backup(self):
        return self.b.backup(self.ns, self.folder / 'backup')

    def test_restore_point_survives_verified_identity_reenrollment(self):
        name, original = self.backup()
        result = self.b.restore(name, self.ns, self.folder / 'restore')
        self.b.binding.update(namespace_uid=result['namespace_uid'], pvc_uids=result['pvc_uids'])
        self.assertEqual(self.b.eligible(name, self.ns)['pvcs'], original['pvcs'])
        foreign = r.RecoveryBackend({**self.b.binding, 'checkout': '/example/unrelated-checkout'})
        with patch.object(foreign, '_get', side_effect=self.b._get), patch.object(foreign, '_items', side_effect=self.b._items):
            with self.assertRaisesRegex(r.RecoveryError, 'Backup identity'):
                foreign.eligible(name, self.ns)

    def test_unsupported_velero_blocks_before_mutation(self):
        original = self.b._get
        def get(kind, name=None, ns=None):
            if kind == 'deployment' and name == 'velero':
                return obj(name, spec={'template': {'spec': {'containers': [
                    {'name': 'velero', 'image': 'velero/velero:v1.17.0'}]}}})
            return original(kind, name, ns)
        with patch.object(self.b, '_get', side_effect=get):
            with self.assertRaisesRegex(r.RecoveryError, '1.18'):
                self.b.preflight(self.ns)
        self.assertFalse(self.b.actions)

    def test_external_replica_change_not_overwritten(self):
        meta = self.b.preflight(self.ns)
        self.b.deps[0]['spec']['replicas'] = 3
        with self.assertRaises(r.RecoveryError):
            self.b._scale(meta, True)
        self.assertEqual(self.b.deps[0]['spec']['replicas'], 3)

    def test_probe_shell_supports_arbitrary_names_and_empty_workspace(self):
        volumes = self.folder / 'volumes'
        for name in ('home', 'workspace'):
            (volumes / name).mkdir(parents=True)
        (volumes / 'home/.env').write_text('synthetic-private-content')
        private = volumes / 'workspace/personal\nname.txt'
        private.write_text('synthetic-workspace-content')
        def shell(argv, *args, **kwargs):
            script = argv[-1].replace('/data/', str(volumes) + '/')
            done = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            return done.stdout.replace(str(volumes) + '/', '/data/')
        with patch.object(self.b, '_run', side_effect=shell):
            text = self.b._probes({'namespace': self.ns, 'helper': 'helper'})
            self.assertNotIn('private-content', text)
            self.assertNotIn('personal', text)
            private.unlink()
            empty = self.b._probes({'namespace': self.ns, 'helper': 'helper'})
            self.assertIn('/data/workspace/no-files', empty)

    def test_archive_rejects_foreign_scope_and_missing_namespace(self):
        import io
        import tarfile
        meta = self.b.preflight(self.ns)
        folder = self.folder / 'archive'; folder.mkdir()
        for case in ('good', 'missing', 'foreign', 'cluster'):
            records = []
            if case != 'missing':
                records.append(('resources/namespaces/cluster/' + self.ns + '.json',
                    {'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': self.ns, 'uid': meta['namespaceUID']}}))
            if case == 'foreign':
                records.append(('resources/secrets/namespaces/other/example.json',
                    {'kind': 'Secret', 'metadata': {'name': 'example', 'namespace': 'other'}}))
            if case == 'cluster':
                records.append(('resources/clusterroles.rbac.authorization.k8s.io/cluster/example.json',
                    {'kind': 'ClusterRole', 'metadata': {'name': 'example', 'namespace': self.ns}}))
            with tarfile.open(folder / 'velero-metadata.tar.gz', 'w:gz') as archive:
                for name, obj in records:
                    data = json.dumps(obj).encode(); info = tarfile.TarInfo(name); info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
            with patch.object(self.b, '_run', return_value=''), self.subTest(case=case):
                if case == 'good':
                    r.RecoveryBackend._archive_scope(self.b, 'backup', meta, folder)
                else:
                    with self.assertRaises(r.RecoveryError):
                        r.RecoveryBackend._archive_scope(self.b, 'backup', meta, folder)

    def test_explicit_cli_binding(self):
        for cmd in (self.b.K, self.b.V):
            self.assertEqual(cmd.count('--kubeconfig'), 1)
            self.assertEqual(cmd[cmd.index('--kubeconfig') + 1], BINDING['kubeconfig'])
        self.assertEqual(self.b.ttl, '720h')
        self.assertEqual(self.b.ROOT, Path('/srv/backup/hermes-maintenance/recovery'))

    def test_namespace_selector_rejected(self):
        with self.assertRaises(r.RecoveryError):
            self.b.preflight('another-app')
        self.assertFalse(self.b.actions)

    def test_identity_drift_blocks_mutation(self):
        for field in ('nsuid', 'pvcuids'):
            with self.subTest(field=field):
                self.b = Fake()
                setattr(self.b, field, 'wrong' if field == 'nsuid' else {})
                with self.assertRaises(r.RecoveryError):
                    self.backup()
                self.assertFalse(self.b.actions)

    def test_preflight_is_read_only(self):
        m = self.b.preflight(self.ns)
        self.assertEqual(m['replicas'], {'agent': 2, 'browser': 0})
        self.assertFalse(self.b.actions)
        self.assertFalse(self.b.objects)

    def test_backup_sealed_after_cleanup_and_resume(self):
        name, meta = self.backup()
        self.assertEqual(self.b.eligible(name, self.ns), meta)
        self.assertFalse(self.b.pods)
        self.assertEqual(self.b.deps[0]['spec']['replicas'], 2)
        seal_index = next(i for i, a in enumerate(self.b.actions) if 'annotate' in a)
        cleanup_index = next(i for i, a in enumerate(self.b.actions) if 'delete' in a)
        rollout_index = next(i for i, a in enumerate(self.b.actions) if 'rollout' in a)
        self.assertLess(cleanup_index, rollout_index)
        self.assertLess(rollout_index, seal_index)
        self.assertEqual((self.folder / 'backup' / 'replicas.json').stat().st_mode & 0o777, 0o600)

    def test_backup_failure_restores_exact_replicas(self):
        self.b.fail_backup = True
        with self.assertRaises(r.RecoveryError):
            self.backup()
        self.assertEqual([d['spec']['replicas'] for d in self.b.deps], [2, 0])
        self.assertFalse(self.b.pods)
        self.assertFalse(any('annotate' in a for a in self.b.actions))

    def test_failed_resume_preserves_metadata_and_never_seals(self):
        self.b.fail_resume = True
        with self.assertRaises(r.RecoveryError):
            self.backup()
        state = json.loads((self.folder / 'backup' / 'resume.json').read_text())
        self.assertTrue(state['manualRecoveryRequired'])
        self.assertFalse(any('annotate' in a for a in self.b.actions))

    def test_helper_cleanup_failure_keeps_writers_stopped(self):
        self.b.fail_remove = True
        with self.assertRaises(r.RecoveryError):
            self.backup()
        self.assertEqual(self.b.deps[0]['spec']['replicas'], 0)
        self.assertFalse(any('annotate' in a for a in self.b.actions))

    def test_volume_identity_and_count_fail_closed(self):
        name, m = self.backup()
        key = ('podvolumebackups.velero.io', name)
        original = copy.deepcopy(self.b.records[key])
        for change in ('duplicate', 'wrong-uid', 'restic', 'failed'):
            with self.subTest(change=change):
                records = copy.deepcopy(original)
                if change == 'duplicate': records.append(copy.deepcopy(records[0]))
                if change == 'wrong-uid': records[0]['spec']['pod']['uid'] = 'wrong'
                if change == 'restic': records[0]['spec']['uploaderType'] = 'restic'
                if change == 'failed': records[0]['status']['phase'] = 'Failed'
                self.b.records[key] = records
                with self.assertRaises(r.RecoveryError): self.b.eligible(name, self.ns)

    def test_unsealed_expired_wrong_scope_rejected(self):
        name, _ = self.backup()
        original = copy.deepcopy(self.b.backups[name])
        for mode in ('unsealed', 'expired', 'scope', 'warnings'):
            b = copy.deepcopy(original)
            if mode == 'unsealed': b['metadata']['annotations'].pop(r.SEAL)
            if mode == 'expired': b['status']['expiration'] = '2000-01-01T00:00:00Z'
            if mode == 'scope': b['spec']['includedNamespaces'] = ['*']
            if mode == 'warnings': b['status']['warnings'] = 1
            self.b.backups[name] = b
            with self.subTest(mode=mode), self.assertRaises(r.RecoveryError): self.b.eligible(name, self.ns)

    def test_native_csi_default_exclusions_are_narrowly_allowed(self):
        name, _ = self.backup()
        spec = self.b.backups[name]['spec']
        spec['excludedClusterScopedResources'].append('volumesnapshotcontents.snapshot.storage.k8s.io')
        spec['excludedNamespaceScopedResources'].append('volumesnapshots.snapshot.storage.k8s.io')
        self.b.eligible(name, self.ns)
        spec['excludedNamespaceScopedResources'].append('secrets')
        with self.assertRaises(r.RecoveryError):
            self.b.eligible(name, self.ns)

    def test_restore_warning_results_not_endpoint_log_chatter(self):
        meta = self.b.preflight(self.ns)
        self.b.restores['restore'] = obj('restore', status={'phase': 'Completed', 'warnings': 3})
        lines = ['level=warning msg="stat /resources/persistentvolumes/cluster/' + p +
                 '.json: no such file or directory" logSource="pkg/controller/restore_controller.go:616"'
                 for p in meta['sourcePVs'].values()]
        lines.append('level=warning msg="kube-root-ca.crt already exists; in-cluster version is different" logSource="pkg/controller/restore_controller.go:620"')
        lines.append('level=warning msg="No annotations found, using restore spec setting: false" logSource="pkg/restore/restore.go:2630"')
        with patch.object(self.b, '_run', return_value='\n'.join(lines)):
            self.b._velero_wait('restores', 'restore', meta)
        lines[-1] = 'level=warning msg="unexpected warning" logSource="pkg/controller/restore_controller.go:620"'
        with patch.object(self.b, '_run', return_value='\n'.join(lines)):
            with self.assertRaises(r.RecoveryError):
                self.b._velero_wait('restores', 'restore', meta)

    def test_safe_listing_does_not_export_metadata(self):
        self.backup()
        result = self.b.list_backups(self.ns)
        self.assertTrue(result[0]['eligible'])
        self.assertNotIn('probes', json.dumps(result))
        self.assertNotIn('namespaceUID', json.dumps(result))

    def test_restore_full_mocked_sequence_new_identities(self):
        name, _ = self.backup()
        result = self.b.restore(name, self.ns, self.folder / 'restore')
        self.assertEqual(result['namespace_uid'], 'ns-restored')
        self.assertTrue(result['reenrollmentRequired'])
        self.assertEqual([d['spec']['replicas'] for d in self.b.deps], [2, 0])
        self.assertFalse(self.b.pods)
        self.assertEqual(len(self.b.backups), 2)
        restore = next(o for o in self.b.objects if o['kind'] == 'Restore')
        self.assertTrue(restore['spec']['includeClusterResources'])
        self.assertNotIn('persistentvolumes', restore['spec']['excludedResources'])
        self.assertNotIn('persistentvolumeclaims', restore['spec']['excludedResources'])
        self.assertEqual(self.b.backups[name]['spec']['includedClusterScopedResources'], ['namespaces'])
        self.assertEqual(set(self.b.backups[name]['spec']['excludedClusterScopedResources']),
                         {'persistentvolumes', 'customresourcedefinitions.apiextensions.k8s.io'})
        modifier = next(o for o in self.b.objects if o['kind'] == 'ConfigMap')
        rules = json.loads(modifier['data']['rules.yaml'])['resourceModifierRules']
        self.assertIsNone(json.loads(rules[0]['mergePatches'][0]['patchData'])['spec']['volumeName'])
        with self.assertRaises(r.RecoveryError): self.b.preflight(self.ns)

    def test_hash_mismatch_never_resumes_restored_workloads(self):
        name, _ = self.backup()
        self.b.bad_hash = True
        with self.assertRaises(r.RecoveryError): self.b.restore(name, self.ns, self.folder / 'restore')
        self.assertEqual([d['spec']['replicas'] for d in self.b.deps], [0, 0])
        self.assertTrue((self.folder / 'restore' / 'restore-failure.json').exists())

    def test_safety_backup_failure_prevents_namespace_deletion(self):
        name, _ = self.backup()
        self.b.fail_backup = True
        with self.assertRaises(r.RecoveryError): self.b.restore(name, self.ns, self.folder / 'restore')
        self.assertFalse(self.b.deleted)

    def test_subprocess_failures_do_not_leak_output(self):
        b = r.RecoveryBackend(BINDING)
        for failure in (subprocess.CompletedProcess([], 1, 'SECRET stdout', 'SECRET stderr'),
                        subprocess.TimeoutExpired('SECRET command', 1, output='SECRET stdout')):
            kwargs = {'side_effect': failure} if isinstance(failure, Exception) else {'return_value': failure}
            with patch.object(r.subprocess, 'run', **kwargs), self.assertRaises(r.RecoveryError) as caught:
                b._run(b.K)
            self.assertNotIn('SECRET', str(caught.exception))

    def test_active_velero_blocks_backup(self):
        self.b.backups['external'] = obj('external', status={'phase': 'InProgress'})
        with self.assertRaises(r.RecoveryError): self.backup()
        self.assertFalse(self.b.actions)

    def test_cluster_identity_blocks_mutation(self):
        original = self.b._get
        def get(kind, name=None, ns=None):
            if kind == 'namespace' and name == 'kube-system': return obj(name, 'wrong-cluster')
            return original(kind, name, ns)
        with patch.object(self.b, '_get', side_effect=get), self.assertRaises(r.RecoveryError): self.backup()
        self.assertFalse(self.b.actions)

    def test_storage_and_node_agent_fail_closed(self):
        original = self.b._get
        for target in ('backupstoragelocations.velero.io', 'daemonset'):
            def get(kind, name=None, ns=None):
                if kind == target: return obj(name, status={})
                return original(kind, name, ns)
            with self.subTest(target=target), patch.object(self.b, '_get', side_effect=get), self.assertRaises(r.RecoveryError):
                self.backup()
        self.assertFalse(self.b.actions)

    def test_unsupported_controllers_block_before_scale(self):
        original = self.b._items
        for target in ('statefulsets', 'daemonsets', 'cronjobs', 'horizontalpodautoscalers', 'replicationcontrollers'):
            def items(kind, ns=None):
                return [obj('unsupported')] if kind == target else original(kind, ns)
            with self.subTest(target=target), patch.object(self.b, '_items', side_effect=items), self.assertRaises(r.RecoveryError):
                self.backup()
        self.assertFalse(self.b.actions)

    def test_unmanaged_pod_blocks_before_scale(self):
        self.b.pods = [obj('writer', status={'phase': 'Running'})]
        with self.assertRaises(r.RecoveryError): self.backup()
        self.assertFalse(self.b.actions)

    def test_restore_volume_uid_mismatch_blocks_resume(self):
        name, _ = self.backup()
        original = self.b._records
        def records(name, m, restore=False):
            original(name, m, restore)
            if restore:
                self.b.records[('podvolumerestores.velero.io', name)][0]['spec']['pod']['uid'] = 'wrong-helper'
        with patch.object(self.b, '_records', side_effect=records), self.assertRaises(r.RecoveryError):
            self.b.restore(name, self.ns, self.folder / 'restore')
        self.assertEqual([d['spec']['replicas'] for d in self.b.deps], [0, 0])

    def test_helper_read_only_and_no_application_image_dependency(self):
        h = self.b._helper(self.b.preflight(self.ns))
        self.assertFalse(h['spec']['automountServiceAccountToken'])
        self.assertTrue(all(v['readOnly'] for v in h['spec']['containers'][0]['volumeMounts']))
        self.assertEqual(h['spec']['containers'][0]['securityContext']['capabilities']['add'], ['DAC_OVERRIDE'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
