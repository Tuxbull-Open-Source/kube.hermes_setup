#!/usr/bin/python3 -I
"""Host-owned upgrade coordinator; installer and recovery backend retain ownership.

Provision a reviewed root-owned source snapshot and /etc/hermes-maintenance/*.json.
Never install a symlink to an operator's checkout. No unattended checkout execution.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import uuid
import yaml

SELF = '/usr/local/libexec/hermes-maintenance.py'
CONFIG = Path('/etc/hermes-maintenance')
STATE = Path('/srv/backup/hermes-maintenance')
SAFE_ENV = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LANG': 'C.UTF-8'}


class Error(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Error(message)


def trusted(path):
    path = Path(path)
    require(path.is_absolute(), 'Privileged paths must be absolute')
    for part in [path, *path.parents]:
        st = part.lstat()
        require(not part.is_symlink() and st.st_uid == 0 and not st.st_mode & 0o022,
                'Untrusted privileged path: ' + str(part))
    return path


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, trusted(path))
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


def run(args, env=None, timeout=90):
    p = subprocess.run(args, env={**SAFE_ENV, **(env or {})}, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    # Raw installer errors may contain private configuration; never echo them.
    require(p.returncode == 0, 'Command failed: ' + Path(args[0]).name)
    return p.stdout


def save(path, obj):
    path = Path(path)
    tmp = path.with_suffix('.new')
    with open(tmp, 'w') as stream:
        os.chmod(tmp, 0o600)
        json.dump(obj, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    tmp.replace(path)


def output(obj):
    print(yaml.safe_dump(obj, sort_keys=False), end='')


def envfile(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        fields = shlex.split(line, comments=True)
        if not fields:
            continue
        require(len(fields) == 1 and '=' in fields[0], 'Invalid environment assignment')
        key, value = fields[0].split('=', 1)
        require(re.fullmatch('[A-Z][A-Z0-9_]*', key), 'Invalid environment key')
        require(key not in result, 'Duplicate environment key')
        result[key] = value
    return result


def write_env(path, values):
    path.write_text(''.join(key + '=' + shlex.quote(value) + '\n' for key, value in sorted(values.items())))
    path.chmod(0o600)


def tree_hash(root):
    result = {}
    for path in sorted(Path(root).rglob('*')):
        trusted(path)
        if path.is_file():
            result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def source_config(checkout):
    """Read data only: never execute the operator-writable environment file."""
    checkout = Path(checkout)
    require(checkout.is_absolute() and checkout.resolve() == checkout, 'Canonical checkout path required')
    candidates = [checkout / 'hermes.env', checkout / 'current_config/hermes.env']
    present = [path for path in candidates if path.is_file()]
    require(len(present) == 1, 'Require exactly one checkout hermes.env (root or current_config); missing or ambiguous configuration')
    path = present[0]
    require(not path.is_symlink() and path.resolve().is_relative_to(checkout), 'Configuration must belong to this checkout')
    values = envfile(path)
    require(bool(re.fullmatch('[a-z0-9][a-z0-9-]{0,62}', values.get('HERMES_NAMESPACE', ''))), 'Explicit configured namespace required; no default or discovery')
    require(values.get('HERMES_AUTH_MODE') in ['local-password', 'external-oidc'], 'Explicit configured auth mode required')
    return path, values


def binding_id(checkout):
    return 'checkout-' + hashlib.sha256(str(checkout).encode()).hexdigest()[:24]


def profile(checkout):
    path, values = source_config(checkout)
    p = json.loads(trusted(CONFIG / (binding_id(checkout) + '.json')).read_text())
    require(p['checkout'] == str(checkout) and p['config_path'] == str(path), 'Protected binding belongs to another checkout/configuration')
    for key in ['source', 'env_file', 'recovery_backend', 'kubeconfig']:
        trusted(p[key])
    require(values.get('HERMES_NAMESPACE') == p['namespace'], 'Configured namespace differs from protected target; correct source configuration, never discover another namespace')
    require(values == envfile(p['env_file']), 'Checkout configuration differs from reviewed protected snapshot; reconcile and review before maintenance')
    return p


def kube(p, *args):
    return json.loads(run(['kubectl', '--kubeconfig', p['kubeconfig'], '--request-timeout=45s', *args, '-o', 'json']))


def snapshot(p):
    ns = p['namespace']
    cluster_uid = kube(p, 'get', 'namespace', 'kube-system')['metadata']['uid']
    require(cluster_uid == p['cluster_uid'], 'Cluster identity mismatch')
    namespace = kube(p, 'get', 'namespace', ns)['metadata']['uid']
    pvcs = kube(p, '-n', ns, 'get', 'pvc')['items']
    require(namespace == p['namespace_uid'], 'Namespace UID differs from configured checkout')
    require({x['metadata']['name']: x['metadata']['uid'] for x in pvcs} == p['pvc_uids'], 'PVC identity mismatch')
    require(all(x.get('status', {}).get('phase') == 'Bound' for x in pvcs), 'Unbound PVC')
    secrets = {}
    for scope in [ns, *p.get('protected_namespaces', [])]:
        secrets[scope] = {x['metadata']['name']: x.get('data', {}) for x in kube(p, '-n', scope, 'get', 'secrets')['items']}
    return {'namespace': namespace, 'pvcs': pvcs, 'secrets': secrets,
            'deployments': kube(p, '-n', ns, 'get', 'deployments')['items']}


def protected_contract(before, docs, namespace):
    """Compare safety-critical fields without conflating API defaults with drift."""
    live = {x['metadata']['name']: x for x in before['deployments']}
    rendered = {x['metadata']['name']: x for x in docs if x['kind'] == 'Deployment'}
    require(set(live) == set(rendered), 'Deployment set changed')
    for doc in docs:
        require(doc.get('metadata', {}).get('namespace', namespace) == namespace, 'Cross-namespace manifest')
    for name, doc in rendered.items():
        a, b = live[name]['spec']['template']['spec'], doc['spec']['template']['spec']
        require(a.get('securityContext') == b.get('securityContext'), 'Runtime UID/GID/securityContext drift')
        for field in ['containers', 'initContainers']:
            ac = {x['name']: x for x in a.get(field, [])}
            bc = {x['name']: x for x in b.get(field, [])}
            require(set(ac) == set(bc), 'Container layout changed; qualify installer separately')
            for container, target in bc.items():
                source = ac[container]
                # Empty command/args use image defaults; nonempty lists are ordered.
                for key in ['command', 'args']:
                    require((source.get(key) or []) == (target.get(key) or []), 'Container command/args changed')
                # Empty securityContext has no settings. Do not drop any security fields:
                # admission-injected settings must also be explicitly preserved.
                require((source.get('securityContext') or {}) == (target.get('securityContext') or {}), 'Container securityContext changed')
                require(source.get('resources', {}) == target.get('resources', {}), 'Protected resource settings changed')
                def env(c):
                    # Kubernetes may omit explicit value:""; both mean empty.
                    return {v['name']: v.get('valueFrom', v.get('value', '')) for v in c.get('env', [])}
                require(env(source) == env(target), 'Authentication/runtime environment changed')
                require(source.get('volumeMounts', []) == target.get('volumeMounts', []), 'Volume mount contract changed')
        def claims(spec):
            return {x['name']: x['persistentVolumeClaim'] for x in spec.get('volumes', []) if 'persistentVolumeClaim' in x}
        require(claims(a) == claims(b), 'Persistent volume mapping changed')
    claims = {x['metadata']['name']: x['spec'] for x in before['pvcs']}
    for doc in docs:
        if doc['kind'] == 'PersistentVolumeClaim':
            target, previous = doc['spec'], claims[doc['metadata']['name']]
            for field in ['accessModes', 'storageClassName', 'resources']:
                require(target.get(field) == previous.get(field), 'PVC contract changed (including resize/shrink)')


def render(p, folder, values):
    write_env(folder / 'candidate.env', values)
    shell = 'source ./install.sh; load_env; prepare_paths; prepare_defaults; resolve_runtime_credentials; validate; create_bootstrap_archive; preflight_manifest'
    env = {'ENV_FILE': str(folder / 'candidate.env'), 'HERMES_RENDER_DIR': str(folder / 'rendered'),
           'KUBECONFIG': p['kubeconfig'], 'HERMES_INSTALL_LIB_ONLY': 'true'}
    with open(folder / 'render.log', 'w') as log:
        r = subprocess.run(['bash', '-euo', 'pipefail', '-c', shell], cwd=p['source'], env={**SAFE_ENV, **env}, stdout=log, stderr=log, timeout=180)
    require(r.returncode == 0, 'Render failed; inspect protected render.log')
    docs = list(yaml.safe_load_all((folder / 'rendered/hermes.yaml').read_text()))
    return [x for x in docs if x]


def prepare(p, name, latest):
    before = snapshot(p)
    secret_names = before['secrets'][p['namespace']]
    required = {'hermes-api-server', 'hermes-browser-token', 'hermes-browser-cdp'}
    if envfile(p['env_file'])['HERMES_AUTH_MODE'] == 'local-password':
        required.add('hermes-dashboard-auth')
    require(required <= secret_names.keys(), 'Missing existing credentials; upgrade must not generate keys')
    require('hermes-bootstrap-archive' not in secret_names, 'Retained bootstrap Secret requires separate preservation review')
    STATE.mkdir(mode=0o700, exist_ok=True)
    folder = STATE / (name + '-' + uuid.uuid4().hex[:12])
    folder.mkdir(mode=0o700)
    values = envfile(p['env_file'])
    require(values.get('HERMES_BOOTSTRAP_MODE') == 'disabled', 'Upgrade requires explicit disabled bootstrap; manage profile changes separately')
    require(not values.get('HERMES_ADDON_REQUIREMENTS'), 'Upgrade must not replace addon packages')
    resolver = module(Path(p['source']) / 'scripts/stable_images.py', 'stable_images')
    targets = resolver.resolve() if latest else resolver.verify_selected(values)
    # Reuse credentials only. Never let an upgrade become a rotation.
    for key in ['API_SERVER_KEY', 'BROWSER_TOKEN', 'DASHBOARD_AUTH_PASSWORD', 'DASHBOARD_AUTH_USER']:
        values[key] = ''
    values.pop('HERMES_RENDER_DIR', None)
    for key, target in targets.items():
        values[key] = target['image']
    for key in ['HERMES_AGENT_IMAGE', 'HERMES_WEBUI_IMAGE', 'HERMES_BROWSER_IMAGE']:
        require(bool(re.fullmatch(r'.+:[^/@]+@sha256:[a-f0-9]{64}', values.get(key, ''))), 'All selected images require immutable digest pins')
    docs = render(p, folder, values)
    protected_contract(before, docs, p['namespace'])
    manifest = folder / 'rendered/hermes.yaml'
    plan = {'instance': name, 'namespace': p['namespace'], 'source_revision': p['source_revision'],
            'profile': p, 'before': before, 'source_hashes': tree_hash(p['source']),
            'config_sha256': hashlib.sha256(Path(p['config_path']).read_bytes()).hexdigest(),
            'env_sha256': hashlib.sha256((folder / 'candidate.env').read_bytes()).hexdigest(),
            'manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(), 'publisher_releases': targets,
            'images': {k: v for k, v in values.items() if k.endswith('_IMAGE')},
            'phase': 'prepared; no workloads changed', 'backup': None}
    save(folder / 'plan.json', plan)
    output({'plan': folder.name, 'namespace': p['namespace'], 'phase': plan['phase'], 'images': plan['images'],
            'source_revision': p['source_revision'], 'log': str(folder / 'render.log'),
            'qualification': 'Review release compatibility and targeted acceptance before upgrade; no automatic full PVC clone.'})


def read_plan(name, instance):
    require(bool(re.fullmatch(re.escape(instance) + '-[a-f0-9]{12}', name)), 'Wrong instance or invalid plan ID')
    folder = trusted(STATE / name)
    return folder, json.loads(trusted(folder / 'plan.json').read_text())


def guard(p, folder, plan):
    require(profile(p['checkout']) == p, 'Source configuration changed; prepare again')
    require(p == plan['profile'], 'Protected binding changed; prepare again')
    require(hashlib.sha256(Path(p['config_path']).read_bytes()).hexdigest() == plan['config_sha256'], 'Source configuration changed after plan')
    require(tree_hash(p['source']) == plan['source_hashes'], 'Reviewed source changed')
    require(hashlib.sha256((folder / 'candidate.env').read_bytes()).hexdigest() == plan['env_sha256'], 'Candidate changed')
    require(hashlib.sha256((folder / 'rendered/hermes.yaml').read_bytes()).hexdigest() == plan['manifest_sha256'], 'Manifest changed')
    def contract(state):
        return {'namespace': state['namespace'], 'secrets': state['secrets'],
                'pvcs': {x['metadata']['name']: (x['metadata']['uid'], x['spec']) for x in state['pvcs']},
                'deployments': {x['metadata']['name']: (x['metadata']['uid'], x['spec']) for x in state['deployments']}}
    require(contract(snapshot(p)) == contract(plan['before']), 'Live state drifted; prepare again')


def recovery_backend(p):
    backend = module(p['recovery_backend'], 'recovery')
    # Backend commands must use the same protected cluster credential snapshot.
    # Do not inherit a kubeconfig beneath an operator-writable directory.
    for name in ['K', 'V']:
        argv = list(getattr(backend, name, []))
        require(argv.count('--kubeconfig') == 1, 'Recovery backend needs an explicit kubeconfig client contract')
        index = argv.index('--kubeconfig') + 1
        require(index < len(argv), 'Malformed recovery backend kubeconfig argument')
        argv[index] = str(trusted(p['kubeconfig']))
        setattr(backend, name, argv)
    return backend


def worker(p, folder, plan):
    backend = recovery_backend(p)
    # Use the SAME lock as operator backup/restore, not a second unrelated lock.
    with open(trusted(backend.ROOT) / 'operation.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            guard(p, folder, plan)
            with open(trusted('/CHANGES.md'), 'a') as audit:
                audit.write(dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d;%H%M%S;') + 'HERMES_MAINTENANCE;upgrade ' + plan['instance'] + ';see phase log;START;' + str(folder) + '\n')
            plan['phase'] = 'cold-backup'; save(folder / 'plan.json', plan)
            backup, metadata = backend.backup(p['namespace'], folder)
            backend.eligible(backup, p['namespace'])
            plan['backup'] = backup
            save(folder / 'backup-metadata.json', metadata)
            plan['phase'] = 'installing'; save(folder / 'plan.json', plan)
            env = {'ENV_FILE': str(folder / 'candidate.env'), 'HERMES_RENDER_DIR': str(folder / 'rendered'), 'KUBECONFIG': p['kubeconfig']}
            with open(folder / 'upgrade.log', 'w') as log:
                result = subprocess.run(['bash', './install.sh'], cwd=p['source'], env={**SAFE_ENV, **env}, stdout=log, stderr=log, timeout=3600)
            require(result.returncode == 0, 'Installer failed; inspect upgrade.log, do not replay blindly')
            after = snapshot(p)
            require(after['secrets'] == plan['before']['secrets'], 'Secret preservation check failed')
            docs = [x for x in yaml.safe_load_all((folder / 'rendered/hermes.yaml').read_text()) if x]
            protected_contract(after, docs, p['namespace'])
            for doc in docs:
                if doc['kind'] == 'Deployment':
                    actual = next(x for x in after['deployments'] if x['metadata']['name'] == doc['metadata']['name'])
                    require([x['image'] for x in actual['spec']['template']['spec']['containers']] == [x['image'] for x in doc['spec']['template']['spec']['containers']], 'Image verification failed')
            plan['phase'] = 'rollout-complete; application acceptance required'
            save(folder / 'plan.json', plan)
        except Exception as exc:
            plan['phase'] = 'failed; inspect logs and recovery metadata before retry'
            save(folder / 'plan.json', plan)
            save(folder / 'failure.json', {'type': type(exc).__name__, 'message': str(exc)})
            try:
                backend.diagnostics(p['namespace'], folder)
            except Exception:
                pass  # Preserve the original failed gate even if diagnostics fail.
            raise


def main(argv=None):
    parser = argparse.ArgumentParser(description='Independent host maintenance. Read-only cluster: status, plan/render. Upgrade causes downtime and a cold Velero backup, then runs the reviewed installer. Existing sudo rights required. No automatic rollback. Exit 0 success, 1 failed gate, 2 usage. Logs/configuration remain root-only.')
    parser.add_argument('--checkout', required=True, help=argparse.SUPPRESS)
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('status', help='Read-only resource status; not an application probe')
    for name in ['plan', 'render']:
        q = sub.add_parser(name, help='Render configured checkout to protected host files; no cluster writes')
        q.add_argument('--latest-stable', action='store_true', help='Resolve stable publisher releases and registry digests now; never float at execution')
    for name in ['upgrade', 'logs']:
        q = sub.add_parser(name, help='Launch prepared plan with downtime' if name == 'upgrade' else 'Read concise durable plan state and log locations')
        q.add_argument('plan')
    a = parser.parse_args(argv)
    require(os.geteuid() == 0, 'Use maintenance.sh through the installed sudo helper')
    os.umask(0o077)
    p = profile(a.checkout)
    name = binding_id(a.checkout)
    if a.command == 'status':
        state = snapshot(p)
        deployments = [{'name': x['metadata']['name'], 'desired': x['spec'].get('replicas', 1), 'available': x.get('status', {}).get('availableReplicas', 0)} for x in state['deployments']]
        healthy = bool(deployments) and all(x['desired'] > 0 and x['available'] == x['desired'] for x in deployments)
        output({'instance': name, 'namespace': p['namespace'], 'deployments': deployments, 'resource_health': healthy, 'application_probe': 'not performed', 'source_revision': p['source_revision']})
        return 0 if healthy else 1
    if a.command in ['plan', 'render']:
        prepare(p, name, a.latest_stable); return 0
    folder, plan = read_plan(a.plan, name)
    if a.command == 'logs':
        output({k: plan[k] for k in ['instance', 'namespace', 'phase', 'backup']})
        output({'protected_logs': str(folder), 'unit': 'hermes-maintenance-' + folder.name + '.service'}); return 0
    require(plan['phase'] == 'prepared; no workloads changed', 'Plan already launched; inspect logs, never replay')
    unit = 'hermes-maintenance-' + folder.name
    if a.worker:
        require(any(x.split(':', 2)[-1] == '/system.slice/' + unit + '.service' for x in Path('/proc/self/cgroup').read_text().splitlines()), 'Worker requires its independent systemd service')
        try:
            worker(p, folder, plan)
        except Exception as exc:
            plan['phase'] = 'failed; inspect logs and recovery metadata before retry'
            save(folder / 'plan.json', plan)
            save(folder / 'failure.json', {'type': type(exc).__name__, 'message': str(exc)})
            raise
        return 0
    guard(p, folder, plan)
    for root in ['/', '/srv/backup']:
        fs = os.statvfs(root)
        require(fs.f_bavail / fs.f_blocks > .10, 'Host free space below ten percent')
    run(['systemd-run', '--unit=' + unit, '--property=Type=exec', '--property=UMask=0077', '--property=StandardOutput=null', '--property=StandardError=null', SELF, '--checkout', a.checkout, '--worker', 'upgrade', a.plan])
    output({'state': 'started, not completed', 'unit': unit + '.service', 'next': 'maintenance.sh logs ' + a.plan})
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        # Do not echo arbitrary exception payloads (may contain secrets).
        print('ERROR: ' + (str(exc) if isinstance(exc, Error) else type(exc).__name__ + '; inspect protected logs'), file=sys.stderr)
        sys.exit(1)
