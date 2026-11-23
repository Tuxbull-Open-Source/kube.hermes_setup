#!/usr/bin/env python3
"""Retained-bootstrap regressions; fake cluster tests are not live acceptance."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('host_bootstrap', ROOT / 'scripts/host_maintenance.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class BootstrapMaintenance(unittest.TestCase):
    def test_prepare_retains_archive_and_seals_no_replay_mode(self):
        for retained in (False, True):
            for ansible in ('false', 'true'):
                with self.subTest(retained=retained, ansible=ansible), tempfile.TemporaryDirectory() as temp:
                    directory = Path(temp)
                    env = directory / 'source.env'
                    env.write_text('HERMES_AUTH_MODE=external-oidc\nHERMES_BOOTSTRAP_MODE=disabled\n'
                                   'HERMES_ADDON_REQUIREMENTS=\nHERMES_ANSIBLE_SETUP=' + ansible + '\n')
                    secrets = {key: {'key': 'synthetic-private-value'} for key in
                               ['hermes-api-server', 'hermes-browser-token', 'hermes-browser-cdp']}
                    if retained:
                        secrets['hermes-bootstrap-archive'] = {'bootstrap.tar.gz': 'opaque-synthetic-archive'}
                    before = dict(namespace='uid', deployments=[], pvcs=[], secrets={'fixture': secrets})
                    original = copy.deepcopy(before)
                    profile = dict(namespace='fixture', env_file=str(env), config_path=str(env),
                                   source=str(ROOT), source_revision='reviewed')
                    images = {key: {'image': 'example/image:v1.2.3@sha256:' + 'a' * 64}
                              for key in ['HERMES_AGENT_IMAGE', 'HERMES_WEBUI_IMAGE', 'HERMES_BROWSER_IMAGE']}
                    def render(p, folder, values):
                        self.assertEqual(values['HERMES_MAINTENANCE_UPGRADE'], 'true')
                        self.assertEqual(values['HERMES_ANSIBLE_SETUP'], ansible)
                        host.write_env(folder / 'candidate.env', values)
                        (folder / 'rendered').mkdir()
                        (folder / 'rendered/hermes.yaml').write_text('')
                        return []
                    with patch.object(host, 'recovery_backend', return_value=SimpleNamespace(preflight=lambda ns: None)), \
                         patch.object(host, 'snapshot', return_value=before), \
                         patch.object(host, 'STATE', directory / 'state'), \
                         patch.object(host, 'module', return_value=SimpleNamespace(resolve=lambda: images)), \
                         patch.object(host, 'render', side_effect=render), \
                         patch.object(host, 'tree_hash', return_value={}), \
                         patch.object(host, 'output') as output:
                        host.prepare(profile, 'checkout-fixture', True)
                    self.assertEqual(before, original)
                    self.assertNotIn('opaque-synthetic-archive', str(output.call_args))
                    plan = json.loads(next((directory / 'state').glob('*/plan.json')).read_text())
                    self.assertEqual(plan['before']['secrets'], original['secrets'])

    def shell(self, body, **settings):
        env = dict({k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in os.environ}, HERMES_INSTALL_LIB_ONLY='true', ENV_FILE='/dev/null',
                   HERMES_BOOTSTRAP_PROFILE='universal-system-administrator',
                   HERMES_BOOTSTRAP_MODE='disabled', HERMES_ADDON_REQUIREMENTS='',
                   HERMES_MAINTENANCE_UPGRADE='true', HERMES_ANSIBLE_SETUP='true',
                   HERMES_DASHBOARD_ENABLED='false', HERMES_WEBUI_ENABLED='false',
                   WEBUI_HOST='webui.example.com', DASHBOARD_HOST='dashboard.example.com',
                   HERMES_OIDC_ISSUER='https://sso.example.com',
                   HERMES_AUTH_MODE='external-oidc', **settings)
        return subprocess.run(['bash', '-euo', 'pipefail', '-c',
                               'source ./install.sh; prepare_defaults; ' + body],
                              cwd=ROOT, env=env, capture_output=True, text=True)

    def test_no_archive_generation_even_with_ansible(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.shell('prepare_paths; mkdir -p "$RENDER_DIR"; '
                                'printf stale > "$BOOTSTRAP_ARCHIVE"; create_bootstrap_archive; '
                                'test ! -f "$BOOTSTRAP_ARCHIVE"; '
                                'test ! -d "$BOOTSTRAP_STAGE"; test "$HERMES_ANSIBLE_SETUP" = true',
                                HERMES_RENDER_DIR=temp)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_bootstrap_secret_mutations(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.shell('''prepare_paths
mkdir -p "$RENDER_DIR"
kubectl() { printf '%s\\n' "$*" >> "$CALLS"; if [[ "$1" == apply ]]; then cat >/dev/null; else printf '{}\\n'; fi; }
export API_SERVER_KEY=synthetic-internal-key BROWSER_TOKEN=synthetic-browser-token BROWSER_CDP_URL=ws://browser:3000/chromium
create_bootstrap_archive
create_namespace_and_secrets
''', HERMES_RENDER_DIR=temp, CALLS=str(Path(temp) / 'calls'))
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (Path(temp) / 'calls').read_text()
            self.assertNotIn('hermes-bootstrap-archive', calls)
            self.assertIn('hermes-api-server', calls)

    def test_stale_archive_rejected_before_any_cluster_write(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.shell('''prepare_paths
mkdir -p "$RENDER_DIR"
printf stale > "$BOOTSTRAP_ARCHIVE"
kubectl() { printf mutation >> "$CALLS"; }
create_namespace_and_secrets
''', HERMES_RENDER_DIR=temp, CALLS=str(Path(temp) / 'calls'))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unexpected bootstrap archive', result.stderr)
            self.assertFalse((Path(temp) / 'calls').exists())

    def test_retained_archive_drift_still_blocks_execution(self):
        import hashlib
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            config = folder / 'config.env'
            config.write_text('fixture')
            (folder / 'candidate.env').write_text('candidate')
            (folder / 'rendered').mkdir()
            manifest = folder / 'rendered/hermes.yaml'
            manifest.write_text('manifest')
            profile = dict(checkout=str(folder), config_path=str(config), source=str(ROOT))
            before = dict(namespace='fixture', pvcs=[], deployments=[],
                          secrets={'fixture': {'hermes-bootstrap-archive': {'bootstrap.tar.gz': 'original'}}})
            plan = dict(profile=profile, before=before, source_hashes={},
                        config_sha256=hashlib.sha256(config.read_bytes()).hexdigest(),
                        env_sha256=hashlib.sha256((folder / 'candidate.env').read_bytes()).hexdigest(),
                        manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest())
            for changed in ({}, {'hermes-bootstrap-archive': {'bootstrap.tar.gz': 'changed'}}):
                after = copy.deepcopy(before)
                after['secrets']['fixture'] = changed
                with patch.object(host, 'profile', return_value=profile), \
                     patch.object(host, 'tree_hash', return_value={}), \
                     patch.object(host, 'snapshot', return_value=after):
                    with self.assertRaisesRegex(host.Error, 'Live state drifted'):
                        host.guard(profile, folder, plan)

    def test_init_script_skips_retained_archive(self):
        template = (ROOT / 'manifests/hermes.yaml.tpl').read_text()
        self.assertIn('if [ "${HERMES_MAINTENANCE_UPGRADE}" != "true" ] && [ -f /bootstrap/bootstrap.tar.gz ]; then', template)

    def test_rejects_bootstrap_or_addon_reconfiguration(self):
        for key, value in [('HERMES_BOOTSTRAP_MODE', 'missing'),
                           ('HERMES_ADDON_REQUIREMENTS', '/unreviewed/requirements.txt'),
                           ('HERMES_MAINTENANCE_UPGRADE', 'invalid')]:
            with self.subTest(key=key):
                # Override defaults without duplicate kwargs.
                env = dict(os.environ, HERMES_INSTALL_LIB_ONLY='true',
                           HERMES_BOOTSTRAP_PROFILE='', HERMES_BOOTSTRAP_MODE='disabled',
                           HERMES_ADDON_REQUIREMENTS='', HERMES_MAINTENANCE_UPGRADE='true')
                env[key] = value
                result = subprocess.run(['bash', '-c', 'source ./install.sh; prepare_defaults'],
                                        cwd=ROOT, env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
