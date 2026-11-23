#!/usr/bin/env python3
"""Opt-in real-cluster bootstrap preservation test using only synthetic data.

Run seed with the baseline installer, overlay the candidate code, then run verify.
This exercises install.sh, not a complete Velero-backed host upgrade transaction.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
NS = 'hermes-test-bootstrap-retention'
STATE = ROOT / 'current_config/bootstrap-regression'
ENV = STATE / 'hermes.env'


def kube(*args):
    r = subprocess.run(['kubectl', *args], capture_output=True, text=True, timeout=180)
    if r.returncode:
        raise RuntimeError('kubectl failed; private diagnostics required')
    return r.stdout


def snapshot():
    secret = json.loads(kube('-n', NS, 'get', 'secret', 'hermes-bootstrap-archive', '-o', 'json'))
    # Only a synthetic fixture's opaque digest/identity is retained, never its payload.
    metadata = secret['metadata']
    pvcs = json.loads(kube('-n', NS, 'get', 'pvc', '-o', 'json'))['items']
    deployments = json.loads(kube('-n', NS, 'get', 'deployment', '-o', 'json'))['items']
    return dict(secret_uid=metadata['uid'], resource_version=metadata['resourceVersion'],
                archive_digest=hashlib.sha256(json.dumps(secret['data'], sort_keys=True).encode()).hexdigest(),
                pvc_uids={p['metadata']['name']: p['metadata']['uid'] for p in pvcs},
                ready=all(d['status'].get('availableReplicas') == 1 for d in deployments),
                deployment_count=len(deployments))


def install(label):
    env = dict(os.environ, ENV_FILE=str(ENV), HERMES_RENDER_DIR=str(STATE / 'rendered'))
    with (STATE / (label + '.log')).open('w') as log:
        result = subprocess.run([str(ROOT / 'install.sh')], cwd=ROOT, env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    if result.returncode:
        raise RuntimeError(label + ' installer failed; inspect protected fixture log')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('phase', choices=['seed', 'verify'])
    p.add_argument('--allow-disposable-cluster', action='store_true', required=True)
    args = p.parse_args()
    os.umask(0o077)
    if args.phase == 'seed':
        assert not kube('get', 'namespace', NS, '--ignore-not-found', '-o', 'name').strip()
        STATE.mkdir(parents=True, mode=0o700)
        bootstrap = STATE / 'bootstrap'
        (bootstrap / 'memories').mkdir(parents=True)
        (bootstrap / 'memories/bootstrap-fixture.txt').write_text('original bootstrap marker\n')
        values = dict(HERMES_NAMESPACE=NS, HERMES_AUTH_MODE='local-password',
                      HERMES_BOOTSTRAP_PROFILE='', HERMES_BOOTSTRAP_DIR=str(bootstrap),
                      HERMES_BOOTSTRAP_MODE='missing', HERMES_ADDON_REQUIREMENTS='',
                      HERMES_ANSIBLE_SETUP='true', HERMES_SSH_SETUP='true',
                      HERMES_ISOLATED_TEST='false', WEBUI_HOST='webui.example.com',
                      DASHBOARD_HOST='dashboard.example.com',
                      HERMES_AGENT_IMAGE='nousresearch/hermes-agent:v0.23.1',
                      HERMES_WEBUI_IMAGE='ghcr.io/nesquena/hermes-webui:0.52.678',
                      HERMES_BROWSER_IMAGE='ghcr.io/browserless/chromium:v2.63.1',
                      HERMES_HOME_STORAGE_SIZE='5Gi', HERMES_WORKSPACE_STORAGE_SIZE='5Gi',
                      STORAGE_CLASS_NAME='local-path', HERMES_ADDON_PYTHON_VERSION='3.13')
        ENV.write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in values.items()))
        install('baseline')
        before = snapshot()
        assert before['ready'] and before['deployment_count'] == 4
        kube('-n', NS, 'exec', 'deployment/hermes-agent', '--', 'sh', '-c',
             'printf "operator-owned marker\\n" > /opt/data/memories/bootstrap-fixture.txt')
        (STATE / 'before.json').write_text(json.dumps(before, indent=2) + '\n')
        print('PASS baseline full stack with retained bootstrap Secret and Ansible enabled', flush=True)
    else:
        before = json.loads((STATE / 'before.json').read_text())
        values = dict(shlex.split(line)[0].split('=', 1) for line in ENV.read_text().splitlines())
        values.update(HERMES_BOOTSTRAP_MODE='disabled', HERMES_MAINTENANCE_UPGRADE='true')
        ENV.write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in values.items()))
        for label in ['candidate', 'candidate-rerun']:
            install(label)
            after = snapshot()
            assert after == before, 'Secret identity/data, PVC identity or readiness drift'
            marker = kube('-n', NS, 'exec', 'deployment/hermes-agent', '--',
                          'cat', '/opt/data/memories/bootstrap-fixture.txt')
            assert marker == 'operator-owned marker\n', 'Bootstrap was replayed'
            assert not (STATE / 'rendered/bootstrap.tar.gz').exists()
            print('PASS ' + label + ': four Ready deployments; Secret UID/resourceVersion/data and PVCs preserved; no archive replay', flush=True)
        (STATE / 'result.json').write_text(json.dumps(dict(passed=True, checks=after), indent=2) + '\n')


if __name__ == '__main__':
    main()
