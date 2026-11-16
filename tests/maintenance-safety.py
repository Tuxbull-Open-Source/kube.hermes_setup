#!/usr/bin/env python3
"""P2 regressions: ordered execution/security and read-only isolation preflight."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
NS = 'hermes-test-safety'


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


host = load('host_maintenance')
isolated = load('isolated_manifest')


class ExecutionContract(unittest.TestCase):
    def setUp(self):
        self.doc = {'kind': 'Deployment', 'metadata': {'name': 'app'}, 'spec': {'template': {'spec': {
            'containers': [{'name': 'app', 'image': 'old'}],
            'initContainers': [{'name': 'init', 'image': 'old'}]}}}}
        self.before = {'deployments': [copy.deepcopy(self.doc)], 'pvcs': []}

    def check(self):
        host.protected_contract(self.before, [self.doc], NS)

    def test_image_only_and_api_defaults(self):
        for field in ['containers', 'initContainers']:
            target = self.doc['spec']['template']['spec'][field][0]
            target.update(image='new', command=[], args=[], securityContext={})
            source = self.before['deployments'][0]['spec']['template']['spec'][field][0]
            source.update(imagePullPolicy='IfNotPresent', terminationMessagePath='/dev/termination-log',
                          terminationMessagePolicy='File')
        self.check()

    def test_order_and_empty_semantics(self):
        for field in ['containers', 'initContainers']:
            for key in ['command', 'args']:
                with self.subTest(field=field, key=key):
                    self.setUp()
                    target = self.doc['spec']['template']['spec'][field][0]
                    source = self.before['deployments'][0]['spec']['template']['spec'][field][0]
                    source[key] = ['first', 'second']
                    target[key] = ['first', 'second']
                    self.check()
                    for changed in [['second', 'first'], [], [''], ['first', 'second', '--arbitrary']]:
                        target[key] = changed
                        with self.assertRaisesRegex(host.Error, 'command/args'):
                            self.check()
                    source.pop(key)
                    target[key] = ['']  # Empty string argument is NOT an empty argument list.
                    with self.assertRaises(host.Error):
                        self.check()


SECURITY = {'privileged': True, 'runAsUser': 0, 'runAsGroup': 0,
            'capabilities': {'add': ['SYS_ADMIN']}, 'seccompProfile': {'type': 'Unconfined'},
            'allowPrivilegeEscalation': True, 'readOnlyRootFilesystem': False,
            'runAsNonRoot': False, 'procMount': 'Unmasked', 'seLinuxOptions': {'type': 'other'}}


def security_test(field, key, value):
    def test(self):
        target = self.doc['spec']['template']['spec'][field][0]
        source = self.before['deployments'][0]['spec']['template']['spec'][field][0]
        target['securityContext'] = {key: value}
        with self.assertRaisesRegex(host.Error, 'securityContext'):
            self.check()
        source['securityContext'] = copy.deepcopy(target['securityContext'])
        self.check()
        target['securityContext'] = {}
        with self.assertRaises(host.Error):
            self.check()
    return test


for field in ['containers', 'initContainers']:
    for key, value in SECURITY.items():
        setattr(ExecutionContract, 'test_' + field + '_' + key, security_test(field, key, value))


class Isolation(unittest.TestCase):
    def setUp(self):
        self.docs = [{'kind': 'NetworkPolicy', 'metadata': {'name': 'render-derived-vendor'}}]
        self.responses = [dict(kind='Namespace', metadata=dict(name=NS)), {'items': []},
                          {'items': []}, {'groups': []}]

    def run_guard(self, responses=None):
        with patch.object(isolated, 'kubectl', side_effect=responses or self.responses) as kube:
            isolated.preflight(self.docs, NS)
            self.assertTrue(all(call.args[0] == 'get' for call in kube.call_args_list))
            return kube.call_count

    def test_clean_no_crds(self):
        self.assertEqual(self.run_guard(), 4)

    def test_absent_namespace(self):
        self.assertEqual(self.run_guard([None]), 1)

    def test_independent_policy_preserved_not_certified(self):
        policy = {'metadata': {'name': 'operator-deny', 'uid': 'original'},
                  'spec': {'podSelector': {}, 'policyTypes': ['Ingress', 'Egress']}}
        self.responses[2]['items'] = [policy]
        original = copy.deepcopy(policy)
        self.run_guard()
        self.assertEqual(policy, original)

    def test_ingress_rejected_any_name(self):
        self.responses[1]['items'] = [{'metadata': {'name': 'not-vendor'}}]
        with self.assertRaisesRegex(ValueError, 'Ingress'):
            self.run_guard()

    def test_vendor_policy_rejected_even_default_deny(self):
        self.responses[2]['items'] = [dict(metadata=dict(name='render-derived-vendor'), spec={})]
        with self.assertRaisesRegex(ValueError, 'NetworkPolicy'):
            self.run_guard()

    def test_namespace_guard_before_reads(self):
        with patch.object(isolated, 'kubectl') as kube:
            for ns, docs in [('production', []), (NS, [dict(kind='Ingress', metadata=dict(namespace='other'))])]:
                with self.assertRaises(ValueError):
                    isolated.preflight(docs, ns)
            kube.assert_not_called()

    def test_optional_resources_and_routes(self):
        for group in ['traefik.io', 'traefik.containo.us']:
            for name in ['middlewares', 'ingressroutes', 'ingressroutetcps', 'ingressrouteudps']:
                with self.subTest(group=group, name=name):
                    responses = self.responses[:3] + [dict(groups=[dict(name=group, preferredVersion=dict(groupVersion=group+'/v1alpha1'))]),
                        dict(resources=[dict(name=name, namespaced=True)]), {'items': []}]
                    self.run_guard(responses)
                    responses[-1] = {'items': [{'metadata': {'name': 'exposure'}}]}
                    with self.assertRaisesRegex(ValueError, 'Traefik'):
                        self.run_guard(responses)

    def test_optional_group_without_exposure_resource(self):
        self.run_guard(self.responses[:3] + [dict(groups=[dict(name='traefik.io', preferredVersion=dict(groupVersion='traefik.io/v1alpha1'))]), dict(resources=[])])

    def test_malformed_responses_fail_closed(self):
        for index in range(4):
            for bad in [{}, [], {'items': None}, {'items': [{}]}, {'kind': 'Status'}]:
                with self.subTest(index=index, bad=bad):
                    responses = copy.deepcopy(self.responses)
                    responses[index] = bad
                    with self.assertRaises((ValueError, AttributeError, TypeError)):
                        self.run_guard(responses)

    def test_all_request_errors_fail_closed(self):
        for index in range(4):
            for error in [subprocess.CalledProcessError(1, 'kubectl', stderr='Forbidden'),
                          subprocess.CalledProcessError(1, 'kubectl', stderr='NotFound'),
                          subprocess.TimeoutExpired('kubectl', 45)]:
                responses = copy.deepcopy(self.responses)
                responses[index] = error
                with self.assertRaises(type(error)):
                    self.run_guard(responses)

    def test_optional_api_errors_and_malformed_discovery(self):
        prefix = self.responses[:3] + [dict(groups=[dict(name='traefik.io', preferredVersion=dict(groupVersion='traefik.io/v1alpha1'))])]
        resource = dict(resources=[dict(name='middlewares', namespaced=True)])
        for bad in [{}, {'resources': None}, {'resources': [{}]}, {'resources': [{'name': None}]},
                    {'resources': [{'name': 'middlewares', 'namespaced': False}]}]:
            with self.assertRaises((ValueError, KeyError)):
                self.run_guard(prefix + [bad])
        for error in [subprocess.CalledProcessError(1, 'kubectl', stderr='Forbidden'),
                      subprocess.CalledProcessError(1, 'kubectl', stderr='NotFound'),
                      subprocess.TimeoutExpired('kubectl', 45)]:
            for responses in [prefix + [error], prefix + [resource, error]]:
                with self.assertRaises(type(error)):
                    self.run_guard(responses)

    def test_kubectl_boundary(self):
        for stdout in ['null', '[]', '', 'not-json']:
            with patch.object(isolated.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=stdout)):
                with self.assertRaises(ValueError):
                    isolated.kubectl('get', '--raw', '/apis')
        with patch.object(isolated.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='')) as run:
            self.assertIsNone(isolated.kubectl('get', 'namespace', NS, '--ignore-not-found=true', '-o', 'json'))
            self.assertTrue(run.call_args.kwargs['check'])
            self.assertEqual(run.call_args.kwargs['timeout'], 45)

    def test_installer_real_render_precedes_all_mutations(self):
        # Execute actual main/preflight/render/filter with only unrelated setup and
        # mutation boundaries stubbed. A real executable kubectl mock records reads.
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            kube = directory / 'kubectl'
            kube.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as f: f.write(' '.join(sys.argv[1:])+'\\n')
a=sys.argv[1:]
if 'namespace' in a: result={'kind':'Namespace','metadata':{'name':os.environ['HERMES_NAMESPACE']}}
elif a[-1].endswith('/ingresses'): result={'items':[{'metadata':{'name':'existing'}}]} if os.environ['CONFLICT']=='Ingress' else {'items':[]}
elif a[-1].endswith('/networkpolicies'): result={'items':[{'metadata':{'name':'hermes-browser-restrict'}}]} if os.environ['CONFLICT']=='NetworkPolicy' else {'items':[]}
elif a[-1]=='/apis': result={'groups':[{'name':'traefik.io','preferredVersion':{'groupVersion':'traefik.io/v1alpha1'}}]}
elif a[-1]=='/apis/traefik.io/v1alpha1': result={'resources':[{'name':'middlewares','namespaced':True}]}
elif a[-1].endswith('/middlewares'): result={'items':[{'metadata':{'name':'existing'}}]} if os.environ['CONFLICT']=='Middleware' else {'items':[]}
else: sys.exit(88)
print(json.dumps(result))
''')
            kube.chmod(0o700)
            shell = '''set -euo pipefail
set -a
source examples/hermes.env.example
set +a
source ./install.sh
export HERMES_NAMESPACE=hermes-test-safety HERMES_ISOLATED_TEST=true
export HERMES_BOOTSTRAP_MODE=disabled HERMES_ADDON_REQUIREMENTS=
export DASHBOARD_HOST=dashboard.example.com WEBUI_HOST=webui.example.com
load_env() { :; }
remove_local_credential_captures() { :; }
resolve_runtime_credentials() { :; }
validate() { :; }
create_bootstrap_archive() { :; }
create_namespace_and_secrets() { echo MUTATION >> "$CALLS"; }
resolve_api_key_revision() { export API_SERVER_KEY_REVISION=fixture; }
apply_and_wait() { echo APPLY >> "$CALLS"; }
print_summary() { :; }
main
'''
            for conflict in ['Ingress', 'NetworkPolicy', 'Middleware', 'clean']:
                calls = directory / ('calls-' + conflict)
                env = dict(os.environ, PATH=str(directory)+':'+os.environ['PATH'], CALLS=str(calls),
                           CONFLICT=conflict, HERMES_INSTALL_LIB_ONLY='true', HERMES_RENDER_DIR=str(directory/'render'))
                result = subprocess.run(['bash', '-c', shell], cwd=ROOT, env=env, capture_output=True, text=True)
                recorded = calls.read_text()
                if conflict == 'clean':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('MUTATION\n', recorded)
                    self.assertIn('APPLY\n', recorded)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('MUTATION', recorded)
                    self.assertNotIn('APPLY', recorded)
                self.assertTrue(all(' get ' in ' '+line or line in ['MUTATION', 'APPLY'] for line in recorded.splitlines()))


if __name__ == '__main__':
    unittest.main()
