#!/usr/bin/env python3
"""Fast maintenance contract/negative tests; not deployment acceptance."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


host = load('host_maintenance')
stable = load('stable_images')
isolated = load('isolated_manifest')


class Contract(unittest.TestCase):
    def test_alias(self):
        a = subprocess.run([str(ROOT / 'maintenance.sh'), '--help'], capture_output=True)
        b = subprocess.run([str(ROOT / 'maintain.sh'), '--help'], capture_output=True)
        self.assertEqual(a.returncode, 0)
        self.assertEqual(a.stdout, b.stdout)

    def test_upgrade_never_restarts_by_default(self):
        p = subprocess.run([str(ROOT / 'maintenance.sh'), 'upgrade'], capture_output=True)
        self.assertEqual(p.returncode, 2)
        self.assertIn(b'No rollout', p.stderr)

    def test_checkout_configuration_contract(self):
        import tempfile
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / 'hermes.env'
            text = 'HERMES_NAMESPACE=fixture\nHERMES_AUTH_MODE=external-oidc\nHERMES_VELERO_STORAGE_LOCATION=fixture-store\n'
            source.write_text(text)
            protected = root / 'protected.env'
            protected.write_text(text)
            binding = dict(checkout=str(root), config_path=str(source), namespace='fixture',
                           source=str(root), env_file=str(protected), kubeconfig='/config',
                           binding_version=2, velero={'namespace': 'velero', 'storage_location': 'fixture-store', 'ttl': '720h'})
            config = root / (host.binding_id(root) + '.json')
            config.write_text(json.dumps(binding))
            (root / 'scripts').mkdir()
            helper = root / 'scripts/host_maintenance.py'
            helper.write_text('fixture helper')
            with patch.object(host, 'CONFIG', root), patch.object(host, 'SELF', str(helper)), \
                 patch.object(host, 'trusted', side_effect=Path):
                self.assertEqual(host.profile(str(root)), binding)
                # A protected mapping cannot route this checkout to another namespace.
                binding['namespace'] = 'other'
                config.write_text(json.dumps(binding))
                with self.assertRaisesRegex(host.Error, 'Configured namespace differs'):
                    host.profile(str(root))
                binding['namespace'] = 'fixture'
                config.write_text(json.dumps(binding))
                # Changes after planning fail before any cluster interaction.
                source.write_text(text + 'HERMES_WEBUI_ENABLED=false\n')
                with self.assertRaisesRegex(host.Error, 'differs from reviewed'):
                    host.guard(binding, root, {})
                source.write_text(text)
                import hashlib
                plan = {'profile': binding, 'config_sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
                source.write_text(text + '# changed after planning\n')
                with self.assertRaisesRegex(host.Error, 'changed after plan'):
                    host.guard(binding, root, plan)
                source.write_text(text)
                (root / 'current_config').mkdir()
                (root / 'current_config/hermes.env').write_text(text)
                with self.assertRaisesRegex(host.Error, 'ambiguous'):
                    host.profile(str(root))
                source.unlink()
                (root / 'current_config/hermes.env').write_text('HERMES_AUTH_MODE=external-oidc\n')
                with self.assertRaisesRegex(host.Error, 'Explicit configured namespace'):
                    host.source_config(str(root))

    def test_wrong_namespace_uid(self):
        with patch.object(host, 'kube', side_effect=[{'metadata': {'uid': 'cluster'}}, {'metadata': {'uid': 'wrong'}}, {'items': []}]):
            with self.assertRaisesRegex(host.Error, 'Namespace UID'):
                host.snapshot({'namespace': 'fixture', 'namespace_uid': 'expected', 'cluster_uid': 'cluster'})

    def test_removed_selector(self):
        result = subprocess.run([str(ROOT / 'maintenance.sh'), '--instance', 'other', 'status'], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'not supported', result.stderr)

    def test_prerelease(self):
        for record in [{'tag_name': 'v1.2.3', 'prerelease': True}, {'tag_name': 'experimental-v1.2.3'}, {'tag_name': 'v1.2.3-rc.1'}, {'tag_name': 'v1.2.3', 'draft': True}]:
            with self.assertRaises(ValueError):
                stable.stable(record)
        self.assertEqual(stable.stable({'tag_name': 'v1.2.3'}), '1.2.3')

    def test_wrong_plan_instance(self):
        with self.assertRaises(host.Error):
            host.read_plan('other-0123456789ab', 'selected')

    def test_backend_uses_protected_cluster_credentials(self):
        backend = SimpleNamespace(K=['kubectl', '--kubeconfig', '/protected/config'],
                                  V=['velero', '--kubeconfig', '/protected/config'])
        profile = {'source': '/protected/source', 'kubeconfig': '/protected/config'}
        factory = SimpleNamespace(RecoveryBackend=lambda binding: backend)
        with patch.object(host, 'module', return_value=factory) as loader, patch.object(host, 'trusted', side_effect=Path):
            selected = host.recovery_backend(profile)
            self.assertEqual(selected.K[-1], '/protected/config')
            self.assertEqual(selected.V[-1], '/protected/config')
            self.assertEqual(loader.call_args.args[0], Path('/protected/source/scripts/velero_recovery.py'))
            selected.K = ['kubectl']
            with self.assertRaises(host.Error):
                host.recovery_backend(profile)
            with self.assertRaisesRegex(host.Error, 'External recovery'):
                host.recovery_backend({**profile, 'recovery_backend': '/external.py'})

    def test_namespace_guard(self):
        with self.assertRaises(ValueError):
            isolated.restrict([], 'production')
        with self.assertRaises(ValueError):
            isolated.restrict([{'kind': 'Deployment', 'metadata': {'namespace': 'production'}}], 'hermes-test-fixture')

    def test_no_exposure(self):
        self.assertEqual(isolated.restrict([{'kind': kind} for kind in ['Ingress', 'Middleware', 'NetworkPolicy']], 'hermes-test-fixture'), [])

    def test_pvc_shrink(self):
        before = {'deployments': [], 'pvcs': [{'metadata': {'name': 'hermes-home'}, 'spec': {'resources': {'requests': {'storage': '20Gi'}}}}]}
        doc = {'kind': 'PersistentVolumeClaim', 'metadata': {'name': 'hermes-home'}, 'spec': {'resources': {'requests': {'storage': '20Gi'}}}}
        host.protected_contract(before, [doc], 'test')
        doc['spec']['resources']['requests']['storage'] = '10Gi'
        with self.assertRaises(host.Error):
            host.protected_contract(before, [doc], 'test')

    def test_protected_resources(self):
        spec = {'securityContext': {'fsGroup': 10000}, 'containers': [{'name': 'app', 'resources': {'limits': {'memory': '1Gi'}}}]}
        doc = {'kind': 'Deployment', 'metadata': {'name': 'app'}, 'spec': {'template': {'spec': spec}}}
        before = {'deployments': [copy.deepcopy(doc)], 'pvcs': []}
        host.protected_contract(before, [doc], 'test')
        spec['containers'][0]['resources']['limits']['memory'] = '2Gi'
        with self.assertRaises(host.Error):
            host.protected_contract(before, [doc], 'test')


if __name__ == '__main__':
    unittest.main()
