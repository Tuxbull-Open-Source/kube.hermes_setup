#!/usr/bin/python3 -I
"""Reviewed host enrollment. No operator-writable code is executed as root.

Bootstrap is deliberately administrator-reviewed, not sudo of this checkout:
1. As the operator, inspect a clean checkout and export the full reviewed commit:
   git --no-replace-objects archive --format=tar --output=source.tar COMMIT
2. An administrator copies source.tar into a root-only staging directory, verifies
   its provenance/commit and reviews its contents independently. Review THIS module
   separately, install it as a regular root-owned 0755 file at
   /usr/local/libexec/hermes-provision-host.py (all parents protected). Before
   replacement, archive the old helper under /srv/backup and audit /CHANGES.md.
   Never sudo python from the checkout or trust an operator-supplied digest alone.
3. From that protected staging directory, the administrator invokes the installed
   helper with --stage-archive PATH --archive-sha256 REVIEWED_SHA256 --revision
   COMMIT. The digest is an administrator attestation, not a signature. Archive
   extraction rejects links, special files, duplicate names and unsafe paths.
4. The operator runs ./provision-host.sh --revision COMMIT [--kubeconfig PATH].
   Thereafter use ./maintenance.sh. No sudoers changes are made.

The initial manual trust decision cannot securely be automated using code from an
operator-writable checkout. Staging and enrollment are separate supported steps.
The root helper never invokes Git in an operator-controlled repository.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import uuid

PROVISION = Path('/usr/local/libexec/hermes-provision-host.py')
HELPER = Path('/usr/local/libexec/hermes-maintenance-v2.py')
SOURCES = Path('/usr/local/lib/hermes-maintenance')
CONFIG = Path('/etc/hermes-maintenance')
STATE = Path('/srv/backup/hermes-maintenance')
RECOVERY = STATE / 'recovery'
AUDIT = Path('/CHANGES.md')
SAFE_ENV = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'HOME': '/root', 'LANG': 'C.UTF-8'}
REQUIRED = ('scripts/provision_host.py', 'scripts/host_maintenance.py',
            'scripts/velero_recovery.py', 'scripts/stable_images.py', 'install.sh')
RECEIPT = '.source-review.json'
MAX_ARCHIVE = 128 * 1024 * 1024


class Error(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Error(message)


def revision(value):
    require(bool(re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', value)),
            'Use a full lowercase commit ID, not a branch or tag')
    return value


def trusted(path, regular=False):
    path = Path(path)
    require(path.is_absolute(), 'Protected path must be absolute')
    for item in [path, *path.parents]:
        mode = item.lstat()
        require(not stat.S_ISLNK(mode.st_mode) and mode.st_uid == 0 and
                not mode.st_mode & 0o022, 'Protected path has unsafe ownership or permissions')
        require(item == path or stat.S_ISDIR(mode.st_mode), 'Invalid protected parent')
    if regular:
        require(stat.S_ISREG(path.lstat().st_mode), 'Expected a protected regular file')
    return path


def protected_dir(path):
    path = Path(path)
    if not path.exists():
        if not path.parent.exists():
            protected_dir(path.parent)
        trusted(path.parent)
        path.mkdir(mode=0o700)
    trusted(path)
    require(path.is_dir(), 'Expected protected directory')
    return path


def run(argv):
    result = subprocess.run(argv, env=SAFE_ENV, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, timeout=90)
    require(result.returncode == 0, 'Host command failed; no raw output disclosed')
    return result.stdout


def reserve(path, needed=0):
    while not Path(path).exists():
        path = Path(path).parent
    fs = os.statvfs(path)
    require(fs.f_blocks > 0 and fs.f_bavail * fs.f_frsize - needed >=
            fs.f_blocks * fs.f_frsize / 10, 'Insufficient disk reserve (require at least ten percent after writes)')


def atomic(path, data, mode=0o600):
    path = Path(path)
    trusted(path.parent)
    if path.exists() or path.is_symlink():
        trusted(path, regular=True)
    fd, name = tempfile.mkstemp(prefix='.provision-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def audit(event, commit, binding=None):
    if AUDIT.exists() or AUDIT.is_symlink():
        trusted(AUDIT, regular=True)
    else:
        trusted(AUDIT.parent)
    # Do not include configuration, credential locations or arbitrary strings.
    fd = os.open(AUDIT, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a', encoding='utf-8') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d;%H%M%S;') +
                     'HERMES_MAINTENANCE;host provisioning;00:00;none;' + event +
                     ' revision=' + revision(commit) +
                     (' binding=' + binding if binding else '') + '\n')
        stream.flush()
        os.fsync(stream.fileno())


def no_workers():
    units = run(['systemctl', 'list-units', '--all', '--no-legend', '--plain',
                 '--state=active,activating,deactivating,reloading', 'hermes-maintenance-*.service'])
    require(not units.strip(), 'Maintenance is running; stop enrollment and wait for completion')


@contextlib.contextmanager
def exclusive():
    protected_dir(CONFIG)
    # Maintenance launch/worker must share this lock (shared mode). The recovery
    # operation lock additionally excludes a running backup/restore transaction.
    paths = [CONFIG / 'provision.lock', RECOVERY / 'operation.lock']
    handles = []
    try:
        protected_dir(RECOVERY)
        require(stat.S_IMODE(RECOVERY.stat().st_mode) == 0o700,
                'Recovery directory must have mode 0700')
        for path in paths:
            if path.exists() or path.is_symlink():
                trusted(path, regular=True)
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            handles.append(fd)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Error('Maintenance or recovery is running; no replacement allowed') from None
        no_workers()
        yield
    finally:
        for fd in reversed(handles):
            os.close(fd)


def archive_files(data, commit):
    require(len(data) <= MAX_ARCHIVE, 'Source archive is too large')
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        require(archive.pax_headers.get('comment') == commit,
                'Archive must be git archive of the exact reviewed commit')
        seen = set()
        total = 0
        for member in archive:
            name = member.name.rstrip('/') if member.isdir() else member.name
            parts = PurePosixPath(name).parts
            require(name and not name.startswith('/') and '\\' not in name and
                    all(x not in ('', '.', '..') for x in name.split('/')) and
                    parts[0] != '.git' and name != RECEIPT,
                    'Unsafe archive pathname')
            require(name not in seen, 'Duplicate archive pathname')
            seen.add(name)
            require(member.isdir() or member.isreg(), 'Archive links and special files are forbidden')
            require(not member.mode & 0o7000, 'Archive special permission bits are forbidden')
            if member.isreg():
                total += member.size
                require(total <= MAX_ARCHIVE, 'Expanded source archive is too large')
                result[name] = (archive.extractfile(member).read(),
                                0o755 if member.mode & 0o111 else 0o644)
    require(all(name in result for name in REQUIRED), 'Reviewed archive lacks repository maintenance modules')
    for name in result:
        require(not any(str(parent) in result for parent in PurePosixPath(name).parents),
                'Archive file/directory collision')
    return result


def stage(archive, digest, commit):
    revision(commit)
    require(bool(re.fullmatch('[0-9a-f]{64}', digest)), 'Explicit administrator-reviewed archive SHA256 required')
    data = trusted(archive, regular=True).read_bytes()
    require(hashlib.sha256(data).hexdigest() == digest, 'Reviewed archive digest mismatch')
    files = archive_files(data, commit)
    reserve(SOURCES, sum(len(x[0]) for x in files.values()) + 1024 * 1024)
    for path in (STATE, CONFIG, AUDIT.parent):
        reserve(path, 1024 * 1024)
    protected_dir(SOURCES)
    with exclusive():
        target = SOURCES / commit
        if target.exists() or target.is_symlink():
            reviewed_source(commit)
            receipt = json.loads(trusted(target / RECEIPT, regular=True).read_text())
            require(receipt.get('archive_sha256') == digest, 'Existing snapshot belongs to a different archive attestation')
            return target
        audit('source-stage-start', commit)
        folder = Path(tempfile.mkdtemp(prefix='.staging-', dir=SOURCES))
        try:
            hashes = {}
            for name, (content, mode) in files.items():
                dest = folder / name
                dest.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                atomic(dest, content, mode)
                hashes[name] = hashlib.sha256(content).hexdigest()
            atomic(folder / RECEIPT, json.dumps({'revision': commit, 'archive_sha256': digest,
                                               'files': hashes}, sort_keys=True).encode())
            folder.rename(target)
        finally:
            if folder.exists():
                shutil.rmtree(folder)
        audit('source-stage-complete', commit)
    return target


def reviewed_source(commit):
    source = trusted(SOURCES / revision(commit))
    receipt = json.loads(trusted(source / RECEIPT, regular=True).read_text())
    require(receipt['revision'] == commit, 'Source review revision mismatch')
    actual = {}
    for path in source.rglob('*'):
        trusted(path)
        require(path.is_dir() or stat.S_ISREG(path.stat().st_mode), 'Unsupported source file')
        if path.is_file() and path != source / RECEIPT:
            actual[str(path.relative_to(source))] = hashlib.sha256(path.read_bytes()).hexdigest()
    require(actual == receipt['files'] and all(x in actual for x in REQUIRED),
            'Reviewed immutable source content changed')
    return source


def parse_env(data):
    values = {}
    for line in data.decode('utf-8').splitlines():
        fields = shlex.split(line, comments=True)
        if not fields:
            continue
        require(len(fields) == 1 and '=' in fields[0], 'Invalid configuration assignment')
        key, value = fields[0].split('=', 1)
        require(bool(re.fullmatch('[A-Z][A-Z0-9_]*', key)) and key not in values,
                'Invalid or duplicate configuration key')
        values[key] = value
    return values


def source_config(checkout):
    checkout = Path(checkout)
    require(checkout.is_absolute() and checkout.resolve() == checkout and checkout.is_dir(),
            'Canonical checkout directory required')
    candidates = [checkout / 'hermes.env', checkout / 'current_config/hermes.env']
    present = [p for p in candidates if p.exists() or p.is_symlink()]
    require(len(present) == 1, 'Require exactly one hermes.env: checkout root or current_config')
    path = present[0]
    require(path.resolve() == path and path.is_file(), 'Configuration symlinks are forbidden')
    # O_NOFOLLOW excludes a last-component swap. This is data, never sourced code.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'Configuration must be regular')
        data = stream.read(1024 * 1024 + 1)
    require(len(data) <= 1024 * 1024, 'Configuration is too large')
    return path, data, parse_env(data)


def settings(values):
    require(bool(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', values.get('HERMES_NAMESPACE', ''))),
            'Explicit configured namespace required')
    require(values.get('HERMES_AUTH_MODE') in ('local-password', 'external-oidc'), 'Explicit configured auth mode required')
    require(values.get('HERMES_BOOTSTRAP_MODE') == 'disabled', 'Maintenance requires explicitly disabled bootstrap')
    require(not values.get('HERMES_ADDON_REQUIREMENTS'), 'Maintenance requires empty addon requirements')
    for key in ('HERMES_AGENT_IMAGE', 'HERMES_WEBUI_IMAGE', 'HERMES_BROWSER_IMAGE'):
        require(bool(re.fullmatch(r'[^\s@]+:v?\d+\.\d+\.\d+@sha256:[a-f0-9]{64}', values.get(key, ''))),
                'All three images require exact semantic version tags and SHA256 digests')
    velero_namespace = values.get('HERMES_VELERO_NAMESPACE', 'velero')
    require(bool(re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', velero_namespace)) and
            velero_namespace != values['HERMES_NAMESPACE'], 'Valid separate Velero namespace required')
    storage = values.get('HERMES_VELERO_STORAGE_LOCATION', '')
    require(bool(re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?', storage)),
            'Explicit HERMES_VELERO_STORAGE_LOCATION required')
    ttl = values.get('HERMES_VELERO_BACKUP_TTL', '720h')
    require(bool(re.fullmatch(r'[1-9][0-9]*h', ttl)), 'Velero TTL must be positive whole hours')
    return {'namespace': velero_namespace, 'storage_location': storage, 'ttl': ttl}


def kube(kubeconfig, *args):
    return json.loads(run(['kubectl', '--kubeconfig', str(kubeconfig), '--request-timeout=45s', *args, '-o', 'json']))


def make_binding(checkout, commit, kubeconfig=None):
    source = reviewed_source(commit)
    config_path, data, values = source_config(checkout)
    velero = settings(values)
    configured = values.get('KUBECONFIG')
    require(not (configured and kubeconfig and configured != kubeconfig),
            'Kubeconfig argument conflicts with authoritative configuration')
    credential = configured or kubeconfig
    require(bool(credential), 'Set KUBECONFIG in the authoritative config or supply its protected location')
    # Do not open, print, hash, copy or parse kubeconfig contents.
    credential = trusted(credential, regular=True)
    namespace = values['HERMES_NAMESPACE']
    cluster_uid = kube(credential, 'get', 'namespace', 'kube-system')['metadata']['uid']
    namespace_uid = kube(credential, 'get', 'namespace', namespace)['metadata']['uid']
    pvcs = kube(credential, '-n', namespace, 'get', 'pvc')['items']
    require({x['metadata']['name'] for x in pvcs} == {'hermes-home', 'hermes-workspace'},
            'Expected exactly the Hermes home and workspace PVCs')
    require(all(x.get('status', {}).get('phase') == 'Bound' for x in pvcs), 'Both PVCs must be Bound')
    require(cluster_uid and namespace_uid and all(x['metadata'].get('uid') for x in pvcs), 'Missing cluster identity')
    name = 'checkout-' + hashlib.sha256(str(checkout).encode()).hexdigest()[:24]
    binding = {'binding_version': 2, 'checkout': str(checkout), 'config_path': str(config_path),
               'namespace': namespace, 'cluster_uid': cluster_uid, 'namespace_uid': namespace_uid,
               'pvc_uids': {x['metadata']['name']: x['metadata']['uid'] for x in pvcs},
               'source': str(source), 'source_revision': commit,
               'env_file': str(CONFIG / (name + '.env')), 'kubeconfig': str(credential),
               'protected_namespaces': [], 'velero': velero}
    return name, binding, data


def enroll(checkout, commit, kubeconfig=None):
    name, binding, data = make_binding(checkout, commit, kubeconfig)
    helper_data = trusted(Path(binding['source']) / 'scripts/host_maintenance.py', regular=True).read_bytes()
    provision_data = trusted(Path(binding['source']) / 'scripts/provision_host.py', regular=True).read_bytes()
    targets = [HELPER, CONFIG / (name + '.json'), CONFIG / (name + '.env'), PROVISION]
    needed = len(helper_data) + len(provision_data) + len(data) + 1024 * 1024
    for path in targets:
        if path.exists() or path.is_symlink():
            needed += trusted(path, regular=True).stat().st_size
    for path in (STATE, CONFIG, HELPER.parent, AUDIT.parent):
        reserve(path, needed)
    protected_dir(HELPER.parent)
    with exclusive():
        # Re-read source data before installing; configuration drift invalidates enrollment.
        require(source_config(checkout)[1] == data, 'Configuration changed during enrollment')
        previous = CONFIG / (name + '.json')
        if previous.exists():
            old = json.loads(trusted(previous, regular=True).read_text())
            require(old.get('checkout') == binding['checkout'] and
                    old.get('namespace') == binding['namespace'] and
                    old.get('cluster_uid') == binding['cluster_uid'],
                    'Existing checkout cannot be silently retargeted to another namespace or cluster')
            binding['protected_namespaces'] = old.get('protected_namespaces', [])
            expected = [(HELPER, helper_data, 0o755), (PROVISION, provision_data, 0o755),
                        (CONFIG / (name + '.env'), data, 0o600)]
            if old == binding and stat.S_IMODE(previous.stat().st_mode) == 0o600 and all(
                    path.exists() and trusted(path, regular=True).read_bytes() == content and
                    stat.S_IMODE(path.stat().st_mode) == mode for path, content, mode in expected):
                return name
        backup = STATE / ('enrollment-' + uuid.uuid4().hex)
        backup.mkdir(mode=0o700)
        for i, path in enumerate(targets):
            if path.exists():
                atomic(backup / (str(i) + '-' + path.name), trusted(path, regular=True).read_bytes())
        atomic(backup / 'scope.json', json.dumps({'targets': [str(p) for p in targets],
                                               'revision': commit}).encode())
        audit('enrollment-start', commit, name)
        # Binding is the final commit point. Failed partial writes retain backups
        # and fail closed through helper/env/version checks; no automatic rollback.
        atomic(HELPER, helper_data, 0o755)
        atomic(PROVISION, provision_data, 0o755)
        atomic(CONFIG / (name + '.env'), data)
        atomic(CONFIG / (name + '.json'), json.dumps(binding, indent=2).encode())
        require(json.loads((CONFIG / (name + '.json')).read_text()) == binding and
                (CONFIG / (name + '.env')).read_bytes() == data and HELPER.read_bytes() == helper_data and
                PROVISION.read_bytes() == provision_data,
                'Installed enrollment verification failed')
        audit('enrollment-complete', commit, name)
    return name


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--checkout')
    parser.add_argument('--kubeconfig', help='Existing protected credential LOCATION only; never copied')
    parser.add_argument('--stage-archive', help='Administrator only: reviewed archive in protected staging')
    parser.add_argument('--archive-sha256', help='Independent administrator review attestation')
    args = parser.parse_args(argv)
    revision(args.revision)
    require(os.geteuid() == 0, 'Use the nonroot provision-host.sh launcher')
    trusted(Path(__file__), regular=True)
    os.umask(0o077)
    if args.stage_archive:
        require(not args.checkout and not args.kubeconfig and args.archive_sha256,
                'Archive staging cannot be combined with enrollment')
        stage(args.stage_archive, args.archive_sha256, args.revision)
        print('Reviewed source snapshot staged. No application resources changed.')
    else:
        require(args.checkout and not args.archive_sha256, 'Enrollment requires --checkout')
        name = enroll(args.checkout, args.revision, args.kubeconfig)
        print('Enrolled ' + name + '. No application resources changed. Use ./maintenance.sh.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print('ERROR: ' + (str(exc) if isinstance(exc, Error) else
                          type(exc).__name__ + '; enrollment failed (details suppressed)'), file=sys.stderr)
        sys.exit(1)
