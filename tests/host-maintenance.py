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

    def test_prerelease(self):
        for record in [{'tag_name': 'v1.2.3', 'prerelease': True}, {'tag_name': 'experimental-v1.2.3'}, {'tag_name': 'v1.2.3-rc.1'}, {'tag_name': 'v1.2.3', 'draft': True}]:
            with self.assertRaises(ValueError):
                stable.stable(record)
        self.assertEqual(stable.stable({'tag_name': 'v1.2.3'}), '1.2.3')

    def test_wrong_plan_instance(self):
        with self.assertRaises(host.Error):
            host.read_plan('other-0123456789ab', 'selected')

    def test_backend_uses_protected_cluster_credentials(self):
        backend = SimpleNamespace(K=['kubectl', '--kubeconfig', '/operator/config'],
                                  V=['velero', '--kubeconfig', '/operator/config'])
        profile = {'recovery_backend': '/protected/backend.py', 'kubeconfig': '/protected/config'}
        with patch.object(host, 'module', return_value=backend), patch.object(host, 'trusted', side_effect=Path):
            selected = host.recovery_backend(profile)
            self.assertEqual(selected.K[-1], '/protected/config')
            self.assertEqual(selected.V[-1], '/protected/config')
            selected.K = ['kubectl']
            with self.assertRaises(host.Error):
                host.recovery_backend(profile)

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
