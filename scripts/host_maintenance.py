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
sys.dont_write_bytecode = True  # Immutable reviewed snapshots must never gain cache files.
import contextlib
import stat as filemode
import uuid
import yaml

SELF = '/usr/local/libexec/hermes-maintenance.py'
CONFIG = Path('/etc/hermes-maintenance')
STATE = Path('/srv/backup/hermes-maintenance')
SAFE_ENV = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root', 'LANG': 'C.UTF-8', 'PYTHONDONTWRITEBYTECODE': '1'}


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


def record_failure(folder, exc):
    save(folder / 'failure.json', {'type': type(exc).__name__, 'message': str(exc),
         'public_safe': isinstance(exc, Error) or getattr(exc, 'public_safe', False) is True})
    private = getattr(exc, 'private_command_failure', None)
    if private is None:
        private = getattr(exc.__context__, 'private_command_failure', None)
    if private is not None:
        save(folder / 'command-failure.json', private)


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
    require(p.get('binding_version') == 2 and 'recovery_backend' not in p,
            'Legacy external recovery binding; re-enroll this checkout with repository-owned recovery')
    for key in ['source', 'env_file', 'kubeconfig']:
        trusted(p[key])
    trusted(Path(p['source']) / 'scripts/velero_recovery.py')
    require(hashlib.sha256(trusted(SELF).read_bytes()).digest() ==
            hashlib.sha256(trusted(Path(p['source']) / 'scripts/host_maintenance.py').read_bytes()).digest(),
            'Installed helper differs from enrolled source; re-enroll this checkout')
    velero = p.get('velero', {})
    require(isinstance(velero, dict) and bool(velero.get('storage_location')),
            'Explicit Velero storage location required; re-enroll this checkout')
    require(velero == {
        'namespace': values.get('HERMES_VELERO_NAMESPACE', 'velero'),
        'storage_location': values.get('HERMES_VELERO_STORAGE_LOCATION', ''),
        'ttl': values.get('HERMES_VELERO_BACKUP_TTL', '720h'),
    }, 'Velero configuration differs from protected binding; re-enroll this checkout')
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
    # Validate the repository recovery contract BEFORE producing an executable plan.
    # A healthy workload alone does not establish that its backup scope is supported.
    recovery_backend(p).preflight(p['namespace'])
    before = snapshot(p)
    secret_names = before['secrets'][p['namespace']]
    required = {'hermes-api-server', 'hermes-browser-token', 'hermes-browser-cdp'}
    if envfile(p['env_file'])['HERMES_AUTH_MODE'] == 'local-password':
        required.add('hermes-dashboard-auth')
    require(required <= secret_names.keys(), 'Missing existing credentials; upgrade must not generate keys')
    # Retained archives are covered by the same drift/preservation contract as
    # other Secrets; the sealed installer mode below must never replay them.
    STATE.mkdir(mode=0o700, exist_ok=True)
    folder = STATE / (name + '-' + uuid.uuid4().hex[:12])
    folder.mkdir(mode=0o700)
    values = envfile(p['env_file'])
    require(values.get('HERMES_BOOTSTRAP_MODE') == 'disabled', 'Upgrade requires explicit disabled bootstrap; manage profile changes separately')
    require(not values.get('HERMES_ADDON_REQUIREMENTS'), 'Upgrade must not replace addon packages')
    values['HERMES_MAINTENANCE_UPGRADE'] = 'true'
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
            'bootstrap_archive': 'retained without replay' if 'hermes-bootstrap-archive' in secret_names else 'absent; not created',
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
    """Only the enrolled repository snapshot may supply privileged recovery code."""
    require('recovery_backend' not in p, 'External recovery modules are not supported; re-enroll')
    path = trusted(Path(p['source']) / 'scripts/velero_recovery.py')
    backend = module(path, 'repository_velero_recovery').RecoveryBackend(p)
    for name in ['K', 'V']:
        argv = list(getattr(backend, name, []))
        require(argv.count('--kubeconfig') == 1, 'Recovery client requires one protected kubeconfig')
        index = argv.index('--kubeconfig') + 1
        require(index < len(argv) and argv[index] == str(trusted(p['kubeconfig'])),
                'Recovery client cluster identity does not match the enrolled checkout')
    return backend


def replace_configuration(path, data, expected_digest):
    """Atomically update data, never execute it or follow its final path symlink."""
    path = Path(path)
    require(path.resolve() == path and not path.is_symlink(), 'Configuration path changed')
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temp = '.maintenance-' + uuid.uuid4().hex
    try:
        require(os.readlink('/proc/self/fd/' + str(fd)) == str(path.parent), 'Configuration parent changed')
        source_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(source_fd, 'rb') as source:
            stat = os.fstat(source.fileno())
            require(filemode.S_ISREG(stat.st_mode), 'Configuration must remain a regular file')
            require(hashlib.sha256(source.read()).hexdigest() == expected_digest,
                    'Configuration changed while operation ran; reconcile without replaying the upgrade')
        out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(out, 'wb') as target:
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
            os.fchown(target.fileno(), stat.st_uid, stat.st_gid)
        current = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
        require((current.st_ino, current.st_mtime_ns, current.st_size) ==
                (stat.st_ino, stat.st_mtime_ns, stat.st_size), 'Configuration changed during pin publication')
        os.replace(temp, path.name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        try:
            os.unlink(temp, dir_fd=fd)
        except FileNotFoundError:
            pass
        os.close(fd)


def publish_image_pins(p, folder, plan):
    """Keep next week's configured plan consistent with this successful rollout."""
    images = plan['images']
    require(set(images) == {'HERMES_AGENT_IMAGE', 'HERMES_WEBUI_IMAGE', 'HERMES_BROWSER_IMAGE'},
            'Unexpected image pin update scope')
    source = Path(p['config_path'])
    protected = trusted(p['env_file'])
    original, protected_original = source.read_bytes(), protected.read_bytes()
    require(hashlib.sha256(original).hexdigest() == plan['config_sha256'] and
            envfile(source) == envfile(protected),
            'Runtime updated but source configuration changed; reconcile pins without rerunning')
    # Retain exact original data privately for operator recovery, outside the checkout.
    for name, data in [('source-config-before.env', original), ('protected-config-before.env', protected_original)]:
        path = folder / name
        with path.open('xb') as stream:
            stream.write(data)
        path.chmod(0o600)
    rows = []
    seen = set()
    for line in original.decode().splitlines():
        fields = shlex.split(line, comments=True)
        key = fields[0].split('=', 1)[0] if fields else None
        if key in images:
            rows.append(key + '=' + shlex.quote(images[key])); seen.add(key)
        else:
            rows.append(line)
    require(seen == set(images), 'Source configuration is missing explicit image pins')
    updated = ('\n'.join(rows) + '\n').encode()
    replace_configuration(source, updated, plan['config_sha256'])
    replace_configuration(protected, updated, hashlib.sha256(protected_original).hexdigest())
    require(source.read_bytes() == protected.read_bytes() == updated, 'Image pin publication incomplete')
    save(folder / 'published-pins.json', {'images': images, 'configuration_updated': True})


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
            plan['phase'] = 'rollout-complete; publishing exact image pins'
            save(folder / 'plan.json', plan)
            publish_image_pins(p, folder, plan)
            plan['phase'] = 'rollout-complete; application acceptance required'
            save(folder / 'plan.json', plan)
        except Exception as exc:
            plan['phase'] = ('rollout-complete; post-upgrade validation failed; inspect before retry' if plan['phase'].startswith('rollout-complete') else 'failed; inspect logs and recovery metadata before retry')
            save(folder / 'plan.json', plan)
            record_failure(folder, exc)
            try:
                backend.diagnostics(p['namespace'], folder)
            except Exception:
                pass  # Preserve the original failed gate even if diagnostics fail.
            raise


def recovery_guard(p, plan):
    require(profile(p['checkout']) == p and p == plan['profile'],
            'Recovery binding/configuration changed; prepare a new operation')
    require(hashlib.sha256(Path(p['config_path']).read_bytes()).hexdigest() == plan['config_sha256'],
            'Recovery source configuration changed')
    require(tree_hash(p['source']) == plan['source_hashes'], 'Reviewed recovery source changed')
    current = snapshot(p)
    before = plan['before']
    for field in ['namespace', 'secrets']:
        require(current[field] == before[field], 'Recovery live identity or credentials drifted')
    for field in ['pvcs', 'deployments']:
        def identities(state):
            return {x['metadata']['name']: (x['metadata']['uid'], x['spec']) for x in state[field]}
        require(identities(current) == identities(before), 'Recovery live resource contract drifted')


def require_worker_unit(unit):
    require(any(x.split(':', 2)[-1] == '/system.slice/' + unit + '.service'
                for x in Path('/proc/self/cgroup').read_text().splitlines()),
            'Worker requires its independent systemd service')


def launch_recovery(p, instance, operation, backup_name=None):
    backend = recovery_backend(p)
    backend.preflight(p['namespace'])
    if operation == 'restore':
        require(bool(re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}', backup_name or '')),
                'An exact valid backup name is required')
        backend.eligible(backup_name, p['namespace'])
    for path in ['/', '/srv/backup']:
        fs = os.statvfs(path)
        require(fs.f_bavail / fs.f_blocks > .10, 'Host free space below ten percent')
    STATE.mkdir(mode=0o700, exist_ok=True)
    folder = STATE / (instance + '-' + uuid.uuid4().hex[:12])
    folder.mkdir(mode=0o700)
    plan = {'instance': instance, 'namespace': p['namespace'], 'profile': p,
            'operation': operation, 'target_backup': backup_name, 'backup': None,
            'before': snapshot(p), 'source_revision': p['source_revision'],
            'source_hashes': tree_hash(p['source']),
            'config_sha256': hashlib.sha256(Path(p['config_path']).read_bytes()).hexdigest(),
            'phase': 'prepared; no workloads changed'}
    save(folder / 'plan.json', plan)
    unit = 'hermes-maintenance-' + folder.name
    args = ['systemd-run', '--unit=' + unit, '--property=Type=exec',
            '--property=UMask=0077', '--property=StandardOutput=null',
            '--property=StandardError=null', SELF, '--checkout', p['checkout'],
            '--worker', '--job', folder.name, operation]
    if operation == 'restore':
        args += [backup_name, '--accept-data-loss']
    run(args)
    output({'state': 'started, not completed', 'operation': folder.name,
            'namespace': p['namespace'], 'unit': unit + '.service',
            'next': 'maintenance.sh logs ' + folder.name})


def recovery_worker(p, folder, plan):
    backend = recovery_backend(p)
    with open(trusted(backend.ROOT) / 'operation.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            recovery_guard(p, plan)
            operation = plan['operation']
            require(operation in ['backup', 'restore'], 'Invalid recovery operation')
            with open(trusted('/CHANGES.md'), 'a') as audit:
                audit.write(dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d;%H%M%S;') +
                            'HERMES_MAINTENANCE;' + operation + ';see phase log;START;' + str(folder) + '\n')
            plan['phase'] = 'cold-backup' if operation == 'backup' else 'safety-backup-and-restore'
            save(folder / 'plan.json', plan)
            if operation == 'backup':
                name, metadata = backend.backup(p['namespace'], folder)
                backend.eligible(name, p['namespace'])
                plan['backup'] = name
                save(folder / 'backup-metadata.json', metadata)
                plan['phase'] = 'backup-complete; original replicas resumed'
            else:
                result = backend.restore(plan['target_backup'], p['namespace'], folder)
                save(folder / 'restore-result.json', result)
                require(kube(p, 'get', 'namespace', p['namespace'])['metadata']['uid'] == result['namespace_uid'],
                        'Restored namespace identity changed before configuration reconciliation')
                image_keys = {'hermes-agent': 'HERMES_AGENT_IMAGE', 'hermes-webui': 'HERMES_WEBUI_IMAGE',
                              'hermes-browser': 'HERMES_BROWSER_IMAGE'}
                configured = envfile(p['env_file'])
                restored_pins = {key: configured[key] for key in image_keys.values()}
                for deployment in kube(p, '-n', p['namespace'], 'get', 'deployments')['items']:
                    key = image_keys.get(deployment['metadata']['name'])
                    if key:
                        restored_pins[key] = deployment['spec']['template']['spec']['containers'][0]['image']
                plan['phase'] = 'restore-complete; reconciling restored image pins'
                save(folder / 'plan.json', plan)
                publish_image_pins(p, folder, {**plan, 'images': restored_pins})
                plan['backup'] = plan['target_backup']
                plan['phase'] = 'restore-complete; application acceptance and identity re-enrollment required'
            save(folder / 'plan.json', plan)
        except Exception as exc:
            plan['phase'] = ('restore-complete; configuration reconciliation failed; inspect before retry' if plan['phase'].startswith('restore-complete') else 'failed; inspect recovery metadata before retry')
            save(folder / 'plan.json', plan)
            record_failure(folder, exc)
            try:
                backend.diagnostics(p['namespace'], folder)
            except Exception:
                pass
            raise


@contextlib.contextmanager
def shared_provision_lock():
    """Never create host state during status/list/help; enrollment creates this lock."""
    path = trusted(CONFIG / 'provision.lock')
    with path.open('rb') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Error('Host enrollment is running; retry after it completes') from None
        yield


def main(argv=None):
    parser = argparse.ArgumentParser(description='Independent host maintenance. Read-only cluster: status, plan/render. Upgrade causes downtime and a cold Velero backup, then runs the reviewed installer. Existing sudo rights required. No automatic rollback. Exit 0 success, 1 failed gate, 2 usage. Logs/configuration remain root-only.')
    parser.add_argument('--checkout', required=True, help=argparse.SUPPRESS)
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--job', help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('status', help='Read-only resource status; not an application probe')
    sub.add_parser('list-backups', help='Read-only Velero selection, coverage and eligibility for this checkout')
    sub.add_parser('backup', help='Launch cold Velero backup with downtime; original replicas resume afterward')
    restore = sub.add_parser('restore', help='Safety backup then replace this instance with an exact recovery point; loses subsequent writes')
    restore.add_argument('backup')
    restore.add_argument('--accept-data-loss', action='store_true', required=True,
                         help='Acknowledge replacement and loss of writes after the selected backup')
    for name in ['plan', 'render']:
        q = sub.add_parser(name, help='Render configured checkout to protected host files; no cluster writes')
        q.add_argument('--latest-stable', action='store_true', help='Resolve stable publisher releases and registry digests now; never float at execution')
    for name in ['upgrade', 'logs']:
        q = sub.add_parser(name, help='Launch prepared plan with downtime' if name == 'upgrade' else 'Read concise durable plan state and log locations')
        q.add_argument('plan')
    a = parser.parse_args(argv)
    require(os.geteuid() == 0, 'Use maintenance.sh through the installed sudo helper')
    os.umask(0o077)
    with shared_provision_lock():
        return dispatch(a)


def operation_progress(p, folder):
    """Allowlisted native progress; never emit embedded recovery/config data."""
    result = []
    namespace = p['velero']['namespace']
    for relative in ['replicas.json', 'safety/replicas.json']:
        path = folder / relative
        if not path.exists():
            continue
        meta = json.loads(trusted(path).read_text())
        require(meta.get('namespace') == p['namespace'], 'Recovery progress scope differs')
        name = meta.get('backup')
        if not isinstance(name, str) or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}', name):
            continue
        item = {'name': name, 'stage': 'not yet available', 'volumes': []}
        try:
            backup = kube(p, '-n', namespace, 'get', 'backup.velero.io', name)
            item['stage'] = backup.get('status', {}).get('phase', 'New')
            item['sealed'] = backup['metadata'].get('annotations', {}).get('recovery.hermes.io/sealed') == 'true'
            volumes = kube(p, '-n', namespace, 'get', 'podvolumebackups.velero.io')['items']
            item['volumes'] = [{'volume': v['spec']['volume'], 'phase': v.get('status', {}).get('phase'),
                                'progress': {k: v.get('status', {}).get('progress', {}).get(k)
                                             for k in ['bytesDone', 'totalBytes']}}
                               for v in volumes if v['metadata'].get('labels', {}).get('velero.io/backup-name') == name]
        except Error:
            pass
        result.append(item)
    path = folder / 'restore-state.json'
    if path.exists():
        state = json.loads(trusted(path).read_text())
        result.append({k: state.get(k) for k in ['restore', 'stage', 'backup', 'safetyBackup']})
    return result


def dispatch(a):
    p = profile(a.checkout)
    name = binding_id(a.checkout)
    if a.command in ['backup', 'restore']:
        if a.worker:
            require(bool(a.job), 'Recovery worker requires a sealed operation')
            folder, plan = read_plan(a.job, name)
            require(plan.get('operation') == a.command, 'Recovery operation type mismatch')
            require(plan['phase'] == 'prepared; no workloads changed', 'Operation already launched; inspect logs, never replay')
            if a.command == 'restore':
                require(plan.get('target_backup') == a.backup, 'Recovery point differs from sealed operation')
            require_worker_unit('hermes-maintenance-' + folder.name)
            try:
                recovery_worker(p, folder, plan)
            except Exception as exc:
                plan['phase'] = ('restore-complete; configuration reconciliation failed; inspect before retry' if plan['phase'].startswith('restore-complete') else 'failed; inspect recovery metadata before retry')
                save(folder / 'plan.json', plan)
                record_failure(folder, exc)
                raise
        else:
            require(a.job is None, 'Operation IDs are internal; use logs to inspect a previous run')
            launch_recovery(p, name, a.command, getattr(a, 'backup', None))
        return 0
    require(a.job is None, 'Operation ID is not valid for this command')
    if a.command == 'list-backups':
        output({'instance': name, 'namespace': p['namespace'],
                'backups': recovery_backend(p).list_backups(p['namespace'])})
        return 0
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
        summary = {k: plan[k] for k in ['instance', 'namespace', 'phase', 'backup']}
        summary.update(protected_logs=str(folder), unit='hermes-maintenance-' + folder.name + '.service',
                       recovery_progress=operation_progress(p, folder))
        if (folder / 'failure.json').exists():
            failure = json.loads(trusted(folder / 'failure.json').read_text())
            summary['failure'] = failure['message'] if failure.get('public_safe') is True else \
                'Details are protected; inspect the recorded failure before retrying'
        output(summary)
        return 0
    require(plan['phase'] == 'prepared; no workloads changed', 'Plan already launched; inspect logs, never replay')
    unit = 'hermes-maintenance-' + folder.name
    if a.worker:
        require(any(x.split(':', 2)[-1] == '/system.slice/' + unit + '.service' for x in Path('/proc/self/cgroup').read_text().splitlines()), 'Worker requires its independent systemd service')
        try:
            worker(p, folder, plan)
        except Exception as exc:
            plan['phase'] = ('rollout-complete; post-upgrade validation failed; inspect before retry' if plan['phase'].startswith('rollout-complete') else 'failed; inspect logs and recovery metadata before retry')
            save(folder / 'plan.json', plan)
            record_failure(folder, exc)
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
        print('ERROR: ' + (str(exc) if isinstance(exc, Error) or getattr(exc, 'public_safe', False) is True else type(exc).__name__ + '; inspect protected logs'), file=sys.stderr)
        sys.exit(1)
