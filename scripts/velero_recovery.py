#!/usr/bin/env python3
"""Bound-instance cold Velero/Kopia recovery, using only stdlib and native CLIs.

The host coordinator MUST hold ROOT/operation.lock throughout each operation,
provide a protected binding/artifact directory and supervise this process outside
application Pods. restore() is destructive; the caller must require explicit
--accept-data-loss. No automatic reenrollment, retry or application acceptance.
Other administrators/GitOps must not mutate the namespace during the window.
Velero 1.18 resource modifiers and Kopia FSB are required; qualify live before use.
"""
import copy
import datetime as dt
import hashlib
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import time
import uuid

ROOT = Path('/srv/backup/hermes-maintenance/recovery')
KEY = 'recovery.hermes.io/metadata'
SEAL = 'recovery.hermes.io/sealed'
PVC_NAMES = {'hermes-home', 'hermes-workspace'}
VOLUMES = {'home', 'workspace'}
TERMINAL = {'Completed', 'Failed', 'PartiallyFailed', 'FailedValidation', 'Canceled'}
EXCLUDED = ['persistentvolumes', 'jobs.batch', 'cronjobs.batch', 'replicasets.apps',
            'events', 'events.events.k8s.io']


class RecoveryError(RuntimeError):
    """Public-safe failure; captured command output is never interpolated."""
    public_safe = True


def require(ok, message):
    if not ok:
        raise RecoveryError(message)


def now():
    return dt.datetime.now(dt.timezone.utc)


def valid_name(value):
    return isinstance(value, str) and re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,251}[a-z0-9]|[a-z0-9]', value)


def save(path, value):
    """Create private artifacts atomically; never follow a destination symlink."""
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not path.parent.is_symlink() and not (path.parent.stat().st_mode & 0o077),
            'Operation directory must be private')
    temp = path.with_name('.' + path.name + '-' + uuid.uuid4().hex)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


class RecoveryBackend:
    ROOT = ROOT

    def __init__(self, binding):
        self.binding = copy.deepcopy(binding)
        b = self.binding
        require(isinstance(b.get('checkout'), str) and Path(b['checkout']).is_absolute(),
                'A canonical enrolled checkout is required')
        self.instance = 'checkout-' + hashlib.sha256(b['checkout'].encode()).hexdigest()[:24]
        require(valid_name(b.get('namespace')), 'Invalid bound namespace')
        require(b['namespace'] not in {'default', 'kube-system', 'kube-public', 'kube-node-lease'},
                'System namespace is forbidden')
        require(all(isinstance(b.get(k), str) and b[k] for k in
                    ('kubeconfig', 'namespace_uid', 'cluster_uid')), 'Incomplete identity binding')
        require(Path(b['kubeconfig']).is_absolute(), 'Kubeconfig must be absolute')
        require(set(b.get('pvc_uids', {})) == PVC_NAMES and
                all(isinstance(v, str) and v for v in b['pvc_uids'].values()), 'Invalid PVC binding')
        v = b.get('velero', {})
        self.velero_namespace = v.get('namespace', 'velero')
        self.location = v.get('storage_location')
        require(valid_name(self.velero_namespace) and valid_name(self.location), 'Invalid Velero binding')
        require(self.velero_namespace != b['namespace'], 'Velero must be outside the managed namespace')
        self.ttl = v.get('ttl', '720h')
        require(isinstance(self.ttl, str) and re.fullmatch(r'[1-9][0-9]*h(?:0m0s)?', self.ttl), 'Invalid backup TTL')
        self.image = v.get('helper_image', 'docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec')
        require(isinstance(self.image, str) and bool(self.image) and not any(c.isspace() for c in self.image),
                'Invalid helper image')
        self.K = ['kubectl', '--kubeconfig', b['kubeconfig'], '--request-timeout=45s']
        self.V = ['velero', '--kubeconfig', b['kubeconfig'], '--namespace', self.velero_namespace]

    def _run(self, argv, data=None, timeout=90):
        try:
            result = subprocess.run(argv, input=json.dumps(data) if data is not None else None,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout, env={'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                                                          'HOME': '/root', 'LANG': 'C.UTF-8'})
        except (OSError, subprocess.SubprocessError):
            raise RecoveryError('Recovery command could not complete; inspect private diagnostics') from None
        if result.returncode != 0:
            error = RecoveryError('Recovery command failed; inspect protected operation diagnostics when available')
            error.private_command_failure = {'argv': argv, 'returncode': result.returncode,
                                             'stdout': result.stdout, 'stderr': result.stderr}
            raise error
        return result.stdout

    def _get(self, kind, name=None, ns=None):
        try:
            return json.loads(self._run(self.K + (['-n', ns] if ns else []) +
                                        ['get', kind] + ([name] if name else []) + ['-o', 'json']))
        except (ValueError, TypeError):
            raise RecoveryError('Invalid Kubernetes response') from None

    def _items(self, kind, ns=None):
        return self._get(kind, ns=ns).get('items', [])

    def _create(self, obj):
        self._run(self.K + ['create', '-f', '-'], obj)

    def _scope(self, ns):
        require(ns == self.binding['namespace'], 'Namespace differs from protected binding')

    def _identity(self, ns):
        self._scope(ns)
        b = self.binding
        require(self._get('namespace', 'kube-system')['metadata']['uid'] == b['cluster_uid'],
                'Cluster identity mismatch')
        require(self._get('namespace', ns)['metadata']['uid'] == b['namespace_uid'],
                'Namespace identity mismatch; explicit reenrollment required')
        pvcs = self._items('persistentvolumeclaims', ns)
        require({p['metadata']['name']: p['metadata']['uid'] for p in pvcs} == b['pvc_uids'],
                'PVC identity mismatch; explicit reenrollment required')
        require(all(p.get('status', {}).get('phase') == 'Bound' for p in pvcs), 'Unbound PVC')
        return pvcs

    @staticmethod
    def _namespace_contract(obj):
        meta = obj.get('metadata', {})
        selected = {field: {k: v for k, v in meta.get(field, {}).items() if not k.startswith('velero.io/')}
                    for field in ('labels', 'annotations')}
        return hashlib.sha256(json.dumps(selected, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

    def _archive_scope(self, name, meta, folder):
        """Inspect native Velero metadata privately before allowing cluster-scoped restore."""
        path = Path(folder) / 'velero-metadata.tar.gz'
        self._run(self.V + ['backup', 'download', name, '--output', str(path)])
        require(path.is_file() and not path.is_symlink(), 'Metadata download unavailable')
        path.chmod(0o600)
        found = False
        with tarfile.open(path, 'r:gz') as archive:
            members = archive.getmembers()
            require(len(members) <= 100000 and sum(m.size for m in members) <= 128 * 1024 * 1024,
                    'Metadata archive exceeds review bounds')
            for member in members:
                require(member.isdir() or member.isfile(), 'Metadata archive contains non-regular entries')
                if not member.isfile() or not member.name.startswith('resources/'):
                    continue
                obj = json.load(archive.extractfile(member))
                identity = obj.get('metadata', {})
                if '/cluster/' in member.name:
                    require(obj.get('kind') == 'Namespace' and member.name.split('/')[1] == 'namespaces',
                            'Unexpected cluster-scoped archive item')
                if obj.get('kind') == 'Namespace' and obj.get('apiVersion') == 'v1':
                    require(identity.get('name') == meta['namespace'] and
                            identity.get('uid') == meta['namespaceUID'] and
                            self._namespace_contract(obj) == meta['namespaceMetadataHash'],
                            'Archived namespace metadata differs from the cold snapshot')
                    found = True
                else:
                    require(identity.get('namespace') == meta['namespace'],
                            'Backup contains foreign or unexpected cluster-scoped resources')
        require(found, 'Backup does not preserve the original Namespace metadata')

    def _active(self):
        return any(x.get('status', {}).get('phase', 'New') not in TERMINAL
                   for kind in ('backups', 'restores', 'podvolumebackups', 'podvolumerestores',
                                'datauploads', 'datadownloads')
                   for x in self._items(kind + '.velero.io', self.velero_namespace))

    def preflight(self, ns):
        """Read-only identity, storage, controller and operation gates."""
        pvcs = self._identity(ns)
        server = self._get('deployment', 'velero', self.velero_namespace)
        containers = server.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])
        image = next((c.get('image', '') for c in containers if c.get('name') == 'velero'), '')
        version = re.search(r':v?1\.(\d+)\.(\d+)(?:@sha256:[0-9a-f]{64})?$', image)
        require(version is not None and int(version.group(1)) >= 18,
                'A version-pinned stable Velero 1.18+ server is required for merge-patch restore modifiers')
        require(not self._active(), 'Another Velero operation is active')
        bsl = self._get('backupstoragelocations.velero.io', self.location, self.velero_namespace)
        require(bsl.get('status', {}).get('phase') == 'Available' and
                bsl.get('spec', {}).get('accessMode', 'ReadWrite') == 'ReadWrite', 'Backup storage unavailable or read-only')
        ds = self._get('daemonset', 'node-agent', self.velero_namespace).get('status', {})
        require(ds.get('numberReady', 0) == ds.get('desiredNumberScheduled', -1) > 0 and
                not ds.get('numberUnavailable', 0), 'Velero node-agent unavailable')
        for kind in ('statefulsets', 'daemonsets', 'cronjobs', 'horizontalpodautoscalers', 'replicationcontrollers'):
            require(not self._items(kind, ns), 'Unsupported workload controller')
        require(not any(x.get('status', {}).get('active', 0) for x in self._items('jobs', ns)), 'Active job present')
        deployments = self._items('deployments', ns)
        require(bool(deployments) and all(not d['metadata'].get('ownerReferences') for d in deployments),
                'Missing or externally controlled deployments')
        require(all(type(d['spec'].get('replicas', 1)) is int and 0 <= d['spec'].get('replicas', 1) <= 100
                    for d in deployments), 'Unsupported replica count')
        owners = {d['metadata']['uid'] for d in deployments}
        rss = self._items('replicasets', ns)
        require(all(any(r.get('uid') in owners and r.get('controller') for r in x['metadata'].get('ownerReferences', []))
                    for x in rss), 'Unmanaged ReplicaSet present')
        rsuids = {x['metadata']['uid'] for x in rss}
        require(all(p.get('status', {}).get('phase') in ('Succeeded', 'Failed') or
                    any(r.get('uid') in rsuids and r.get('controller') for r in p['metadata'].get('ownerReferences', []))
                    for p in self._items('pods', ns)), 'Unmanaged active Pod present')
        source_pvs = {}
        for pvc in pvcs:
            spec = pvc['spec']
            require(spec.get('volumeMode', 'Filesystem') == 'Filesystem' and not spec.get('selector') and
                    spec.get('storageClassName') and not spec.get('dataSource') and not spec.get('dataSourceRef'),
                    'PVC is not a supported dynamic filesystem claim')
            sc = self._get('storageclass', spec['storageClassName'])
            require(sc.get('provisioner') not in (None, '', 'kubernetes.io/no-provisioner'), 'Dynamic provisioner required')
            pv = self._get('persistentvolume', spec['volumeName'])
            ref = pv.get('spec', {}).get('claimRef', {})
            require(ref.get('uid') == pvc['metadata']['uid'] and ref.get('namespace') == ns,
                    'Source PV claim identity mismatch')
            source_pvs[pvc['metadata']['name']] = spec['volumeName']
        cluster_excluded = sorted(set(self._run(self.K + ['api-resources', '--namespaced=false', '--verbs=list', '-o', 'name']).split()) - {'namespaces'})
        require({'persistentvolumes', 'customresourcedefinitions.apiextensions.k8s.io'} <= set(cluster_excluded),
                'Complete cluster resource discovery required')
        return {'version': 2, 'excludedClusterResources': cluster_excluded, 'instance': self.instance, 'namespace': ns, 'namespaceUID': self.binding['namespace_uid'],
                'clusterUID': self.binding['cluster_uid'], 'pvcs': dict(self.binding['pvc_uids']),
                'namespaceMetadataHash': self._namespace_contract(self._get('namespace', ns)),
                'sourcePVs': source_pvs,
                'replicas': {d['metadata']['name']: d['spec'].get('replicas', 1) for d in deployments},
                'deploymentUIDs': {d['metadata']['name']: d['metadata']['uid'] for d in deployments},
                'helper': 'hermes-recovery-' + uuid.uuid4().hex[:16]}

    def _wait(self, predicate, seconds=600):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            time.sleep(3)
        raise RecoveryError('Recovery timed out; inspect operation before retrying')

    def _scale(self, meta, zero):
        ns = meta['namespace']
        require(self._get('namespace', 'kube-system')['metadata']['uid'] == meta['clusterUID'] and
                self._get('namespace', ns)['metadata']['uid'] == meta['namespaceUID'], 'Identity changed before scaling')
        require({p['metadata']['name']: p['metadata']['uid'] for p in self._items('pvc', ns)} == meta['pvcs'],
                'PVC identity changed before scaling')
        failed = False
        for name, replicas in meta['replicas'].items():
            try:
                d = self._get('deployment', name, ns)
                require(d['metadata']['uid'] == meta['deploymentUIDs'][name], 'Deployment identity changed')
                current = d['spec'].get('replicas', 1)
                require(current == replicas if zero else current in (0, replicas),
                        'Replica intent changed externally; refusing to overwrite it')
                self._run(self.K + ['-n', ns, 'scale', 'deployment/' + name,
                                   '--current-replicas=' + str(d['spec'].get('replicas', 1)),
                                   '--replicas=' + str(0 if zero else replicas)])
            except RecoveryError:
                failed = True
        require(not failed, 'Replica restoration/scaling incomplete; inspect replicas.json')

    def _resume(self, meta):
        self._scale(meta, False)
        for name, replicas in meta['replicas'].items():
            if replicas:
                self._run(self.K + ['-n', meta['namespace'], 'rollout', 'status', 'deployment/' + name,
                                   '--timeout=300s'], timeout=330)
        require({d['metadata']['name']: d['spec'].get('replicas', 1)
                 for d in self._items('deployments', meta['namespace'])} == meta['replicas'], 'Replica map drifted')

    def _quiet(self, ns, helper=None):
        return all(p['metadata']['name'] == helper or p.get('status', {}).get('phase') in ('Succeeded', 'Failed')
                   for p in self._items('pods', ns))

    def _helper(self, meta):
        return {'apiVersion': 'v1', 'kind': 'Pod',
                'metadata': {'name': meta['helper'], 'namespace': meta['namespace'],
                             'annotations': {'backup.velero.io/backup-volumes': 'home,workspace'}},
                'spec': {'restartPolicy': 'Never', 'automountServiceAccountToken': False,
                         'terminationGracePeriodSeconds': 1, 'securityContext': {'runAsUser': 0},
                         'containers': [{'name': 'hold', 'image': self.image, 'command': ['sleep', '2147483647'],
                                         'securityContext': {'allowPrivilegeEscalation': False,
                                                             'capabilities': {'drop': ['ALL'], 'add': ['DAC_OVERRIDE']}},
                                         'resources': {'requests': {'cpu': '10m', 'memory': '16Mi'}, 'limits': {'memory': '64Mi'}},
                                         'volumeMounts': [{'name': v, 'mountPath': '/data/' + v, 'readOnly': True}
                                                          for v in sorted(VOLUMES)]}],
                         'volumes': [{'name': v, 'persistentVolumeClaim': {'claimName': 'hermes-' + v}}
                                     for v in sorted(VOLUMES)]}}

    def _remove_helper(self, meta):
        ns = meta['namespace']
        require(self._get('namespace', ns)['metadata']['uid'] == meta['namespaceUID'], 'Namespace changed before helper cleanup')
        present = [p for p in self._items('pods', ns) if p['metadata']['name'] == meta['helper']]
        if present and meta.get('helperUID'):
            require(present[0]['metadata']['uid'] == meta['helperUID'], 'Helper identity changed; refusing cleanup')
        self._run(self.K + ['-n', ns, 'delete', 'pod', meta['helper'], '--ignore-not-found=true',
                           '--wait=true', '--timeout=180s'], timeout=210)
        require(not any(p['metadata']['name'] == meta['helper'] for p in self._items('pods', ns)),
                'Helper remains; writers must not resume')

    def _probes(self, meta):
        # Deterministic samples; never emit plaintext content or private filenames.
        script = r'''set -eu
set -o pipefail
emit_sample() {
  p="$1"
  sum=$(sha256sum < "$p")
  printf '%s  /data/%s/sample\n' "${sum%% *}" "$d"
  stat -c '%a:%u:%g' "$p"
}
for d in home workspace; do
  found=0
  for f in config.yaml .env AGENTS.md marker; do
    p="/data/$d/$f"
    if [ -f "$p" ] && [ ! -L "$p" ]; then emit_sample "$p"; found=1; break; fi
  done
  if [ "$found" = 0 ]; then
    find "/data/$d" -xdev -path "/data/$d/.velero" -prune -o -type f -print0 |
      LC_ALL=C sort -z | (
        IFS= read -r -d '' p || p=''
        if [ -n "$p" ]; then
          emit_sample "$p"
        else
          sum=$(sha256sum < /dev/null)
          printf '%s  /data/%s/no-files\n' "${sum%% *}" "$d"
          stat -c '%a:%u:%g' "/data/$d"
        fi
        cat > /dev/null
      )
  fi
done'''
        text = self._run(self.K + ['-n', meta['namespace'], 'exec', meta['helper'], '-c', 'hold', '--', 'sh', '-c', script])
        lines = text.splitlines()
        require(len(lines) == 4 and all(re.fullmatch(r'[0-9a-f]{64}  /data/(home|workspace)/(sample|no-files)', lines[i])
                                          for i in (0, 2)) and
                all(re.fullmatch(r'[0-7]+:[0-9]+:[0-9]+', lines[i]) for i in (1, 3)), 'Sample probe unavailable')
        return text

    def _coverage(self, name, meta, restore=False):
        resource = 'podvolumerestores' if restore else 'podvolumebackups'
        label = 'velero.io/restore-name' if restore else 'velero.io/backup-name'
        records = [p for p in self._items(resource + '.velero.io', self.velero_namespace)
                   if p['metadata'].get('labels', {}).get(label) == name]
        require(len(records) == 2 and {p['spec']['volume'] for p in records} == VOLUMES,
                'Expected exactly two helper volume records')
        for p in records:
            spec, status = p['spec'], p.get('status', {})
            pod = spec.get('pod', {})
            require(status.get('phase') == 'Completed' and pod.get('name') == meta['helper'] and
                    pod.get('namespace') == meta['namespace'] and pod.get('uid') == meta['helperUID'],
                    'Volume record helper identity/completion mismatch')
            if not restore:
                require(spec.get('uploaderType') == 'kopia' and status.get('snapshotID') and
                        spec.get('backupStorageLocation') == self.location and
                        p['metadata'].get('annotations', {}).get('velero.io/pvc-name') == 'hermes-' + spec['volume'] and
                        p['metadata'].get('labels', {}).get('velero.io/pvc-uid') == meta['pvcs']['hermes-' + spec['volume']],
                        'Kopia snapshot/PVC identity mismatch')
        return records

    def _velero_wait(self, kind, name, meta=None):
        def poll():
            if kind == 'backups' and meta is not None:
                self._identity(meta['namespace'])
                require(self._quiet(meta['namespace'], meta['helper']) and
                        all(d['spec'].get('replicas', 1) == 0 for d in self._items('deployments', meta['namespace'])),
                        'Writer appeared during cold backup')
            obj = self._get(kind + '.velero.io', name, self.velero_namespace)
            return obj if obj.get('status', {}).get('phase') in TERMINAL else None
        obj = self._wait(poll, 14400)
        s = obj['status']
        require(s.get('phase') == 'Completed' and not s.get('errors'), 'Velero operation did not complete cleanly')
        if s.get('warnings'):
            require(kind == 'restores' and meta is not None, 'Unclassified Velero warnings')
            logs = self._run(self.V + ['restore', 'logs', name], timeout=120)
            warnings = [line for line in logs.splitlines() if 'level=warning' in line]
            expected = ['/resources/persistentvolumes/cluster/' + pv + '.json: no such file or directory'
                        for pv in meta['sourcePVs'].values()]
            # Never allow arbitrary warning counts/content. Root CA regeneration is benign.
            require(bool(warnings) and all(any(token in line for token in expected) or
                    ('kube-root-ca.crt' in line and 'already exists' in line and 'in-cluster version is different' in line)
                    for line in warnings) and s['warnings'] in (2, 3) and
                    all(any(token in line for line in warnings) for token in expected), 'Unclassified restore warnings')
        return obj

    def backup(self, ns, folder):
        folder = Path(folder)
        meta = self.preflight(ns)
        name = 'hermes-cold-' + uuid.uuid4().hex
        meta['backup'] = name
        save(folder / 'replicas.json', meta)
        failed = False
        try:
            self._identity(ns)
            self._scale(meta, True)
            self._wait(lambda: self._quiet(ns))
            self._identity(ns)
            self._create(self._helper(meta))
            self._run(self.K + ['-n', ns, 'wait', 'pod/' + meta['helper'], '--for=condition=Ready', '--timeout=180s'], timeout=210)
            meta['helperUID'] = self._get('pod', meta['helper'], ns)['metadata']['uid']
            meta['probes'] = self._probes(meta)
            require(self._quiet(ns, meta['helper']), 'Writers restarted during quiescence')
            require(all(d['spec'].get('replicas', 1) == 0 for d in self._items('deployments', ns)), 'Deployment restarted')
            save(folder / 'replicas.json', meta)
            self._create({'apiVersion': 'velero.io/v1', 'kind': 'Backup',
                          'metadata': {'name': name, 'namespace': self.velero_namespace,
                                       'annotations': {KEY: json.dumps(meta, separators=(',', ':'))}},
                          'spec': {'includedNamespaces': [ns],
                                   'includedClusterScopedResources': ['namespaces'],
                                   'excludedClusterScopedResources': meta['excludedClusterResources'],
                                   'includedNamespaceScopedResources': ['*'],
                                   'excludedNamespaceScopedResources': [x for x in EXCLUDED if x != 'persistentvolumes'],
                                   'snapshotVolumes': False,
                                   'defaultVolumesToFsBackup': False, 'storageLocation': self.location, 'ttl': self.ttl}})
            save(folder / 'backup.json', self._velero_wait('backups', name, meta))
            save(folder / 'pvb.json', self._coverage(name, meta))
            self._archive_scope(name, meta, folder)
            require(self._quiet(ns, meta['helper']) and self._probes(meta) == meta['probes'],
                    'Cold data changed during backup')
        except BaseException:
            failed = True
            raise
        finally:
            # Cleanup and resume are independent attempts, but do not start writers
            # if helper absence cannot be proven. Never seal failed cleanup/resume.
            try:
                self._remove_helper(meta)
                self._resume(meta)
                save(folder / 'resume.json', {'resumed': True, 'backupFailed': failed})
            except BaseException:
                save(folder / 'resume.json', {'resumed': False, 'manualRecoveryRequired': True,
                                            'replicas': meta['replicas'], 'backup': name})
                raise RecoveryError('Backup cleanup/resume failed; preserve replicas.json for manual recovery') from None
        self._run(self.K + ['-n', self.velero_namespace, 'annotate', 'backups.velero.io', name, SEAL + '=true'])
        self.eligible(name, ns)  # Read back exact seal and immutable coverage before success.
        return name, meta

    def eligible(self, name, ns):
        self._scope(ns)
        require(valid_name(name), 'Invalid backup name')
        try:
            b = self._get('backups.velero.io', name, self.velero_namespace)
            annotations = b['metadata'].get('annotations', {})
            m = json.loads(annotations.get(KEY, '{}'))
            require(annotations.get(SEAL) == 'true', 'Backup has no successful-resume seal')
            require(m.get('version') == 2 and m.get('instance') == self.instance and m.get('namespace') == ns and
                    m.get('clusterUID') == self.binding['cluster_uid'] and
                    bool(m.get('namespaceUID')) and set(m.get('pvcs', {})) == PVC_NAMES and
                    all(isinstance(v, str) and v for v in m['pvcs'].values()) and m.get('backup') == name,
                    'Backup identity differs from enrollment')
            sp, s = b['spec'], b.get('status', {})
            require(sp.get('includedNamespaces') == [ns] and not sp.get('excludedNamespaces') and
                    sp.get('includeClusterResources') is None and not sp.get('includedResources') and
                    not sp.get('excludedResources') and not sp.get('labelSelector') and not sp.get('orLabelSelectors') and
                    sp.get('includedClusterScopedResources') == ['namespaces'] and
                    set(m.get('excludedClusterResources', [])) <= set(sp.get('excludedClusterScopedResources', [])) <=
                    set(m.get('excludedClusterResources', [])) | {'volumesnapshotcontents.snapshot.storage.k8s.io'} and
                    'namespaces' not in m.get('excludedClusterResources', []) and
                    {'persistentvolumes', 'customresourcedefinitions.apiextensions.k8s.io'} <= set(m.get('excludedClusterResources', [])) and
                    sp.get('includedNamespaceScopedResources') == ['*'] and
                    sp.get('defaultVolumesToFsBackup') is False and sp.get('snapshotVolumes') is False and
                    sp.get('storageLocation') == self.location and
                    set(EXCLUDED) - {'persistentvolumes'} <= set(sp.get('excludedNamespaceScopedResources', [])) <=
                    (set(EXCLUDED) - {'persistentvolumes'}) | {'volumesnapshots.snapshot.storage.k8s.io'},
                    'Backup scope differs from cold contract')
            require(s.get('phase') == 'Completed' and not s.get('errors') and not s.get('warnings') and
                    dt.datetime.fromisoformat(s['expiration'].replace('Z', '+00:00')) > now(), 'Backup incomplete or expired')
            require(valid_name(m.get('helper')) and m.get('helperUID') and isinstance(m.get('probes'), str) and m['probes'] and
                    set(m.get('sourcePVs', {})) == PVC_NAMES and m.get('replicas') and
                    set(m.get('deploymentUIDs', {})) == set(m['replicas']) and
                    all(valid_name(k) and type(v) is int and 0 <= v <= 100 for k, v in m['replicas'].items()),
                    'Invalid recovery metadata')
            self._coverage(name, m)
            return m
        except (ValueError, TypeError, KeyError):
            raise RecoveryError('Malformed backup metadata') from None

    def list_backups(self, ns):
        self._identity(ns)
        result = []
        volumes = self._items('podvolumebackups.velero.io', self.velero_namespace)
        for b in self._items('backups.velero.io', self.velero_namespace):
            sp = b.get('spec', {})
            if any(fnmatch.fnmatchcase(ns, pattern) for pattern in sp.get('excludedNamespaces', [])) or not any(
                    fnmatch.fnmatchcase(ns, pattern) for pattern in (sp.get('includedNamespaces') or ['*'])):
                continue
            name = b['metadata']['name']
            try:
                self.eligible(name, ns)
                eligible = True
            except RecoveryError:
                eligible = False
            s = b.get('status', {})
            completed = sum(1 for p in volumes if
                            p['metadata'].get('labels', {}).get('velero.io/backup-name') == name and
                            p.get('spec', {}).get('pod', {}).get('namespace') == ns and
                            p.get('status', {}).get('phase') == 'Completed')
            result.append({'name': name, 'phase': s.get('phase'), 'expires': s.get('expiration'),
                           'namespaceSelected': True, 'completedFilesystemVolumes': completed,
                           'eligible': eligible, 'restoreTestEvidence': 'not recorded by listing',
                           'warnings': s.get('warnings', 0), 'errors': s.get('errors', 0)})
        return sorted(result, key=lambda b: b['name'])

    def diagnostics(self, ns, folder):
        self._scope(ns)
        folder = Path(folder)
        pods = self._items('pods', ns)
        save(folder / 'handoff.json', {'pods': [{'name': p['metadata']['name'], 'phase': p.get('status', {}).get('phase')}
                                               for p in pods]})
        save(folder / 'events.json', self._items('events', ns)[-200:])
        logs = []
        for p in pods:
            for c in p['spec'].get('containers', []) + p['spec'].get('initContainers', []):
                for previous in (False, True):
                    try:
                        text = self._run(self.K + ['-n', ns, 'logs', p['metadata']['name'], '-c', c['name'],
                                                  '--tail=100', '--limit-bytes=32768'] + (['--previous'] if previous else []))
                        logs.append({'pod': p['metadata']['name'], 'container': c['name'], 'previous': previous, 'log': text})
                    except RecoveryError:
                        pass
        save(folder / 'logs.json', logs)

    def _modifier(self, name, ns):
        patch = {'spec': {'volumeName': None}, 'metadata': {'annotations': {
            'pv.kubernetes.io/bind-completed': None, 'pv.kubernetes.io/bound-by-controller': None,
            'volume.kubernetes.io/selected-node': None}}}
        rules = {'version': 'v1', 'resourceModifierRules': [
            {'conditions': {'groupResource': 'persistentvolumeclaims', 'namespaces': [ns]},
             'mergePatches': [{'patchData': json.dumps(patch)}]},
            {'conditions': {'groupResource': 'deployments.apps', 'namespaces': [ns]},
             'mergePatches': [{'patchData': json.dumps({'spec': {'replicas': 0}})}]}]}
        self._create({'apiVersion': 'v1', 'kind': 'ConfigMap',
                      'metadata': {'name': name, 'namespace': self.velero_namespace},
                      'data': {'rules.yaml': json.dumps(rules)}})

    def restore(self, name, ns, folder):
        """Exact-name destructive replacement; explicit consent belongs to caller.

        Failure after deletion deliberately leaves restored writers at zero. The
        safety backup and private stage records survive; never automatically retry.
        """
        folder = Path(folder)
        meta = self.eligible(name, ns)
        self.preflight(ns)
        self.diagnostics(ns, folder / 'diagnostics')
        self._archive_scope(name, meta, folder)
        safety, _ = self.backup(ns, folder / 'safety')
        self.eligible(safety, ns)
        self.eligible(name, ns)  # May have expired during the safety backup.
        self.preflight(ns)
        rname = 'hermes-restore-' + uuid.uuid4().hex
        state = {'backup': name, 'safetyBackup': safety, 'restore': rname,
                 'stage': 'prepared', 'reenrollmentRequired': True}
        save(folder / 'restore-state.json', state)
        self._modifier(rname, ns)
        try:
            # Stop writers again after the safety backup resumed them.
            current = self.preflight(ns)
            save(folder / 'pre-delete-replicas.json', current)
            self._scale(current, True)
            self._wait(lambda: self._quiet(ns))
            self._identity(ns)
            require(not self._active(), 'Conflicting Velero operation')
            state['stage'] = 'deleting-namespace'
            save(folder / 'restore-state.json', state)
            self._run(self.K + ['delete', 'namespace', ns, '--wait=true', '--timeout=600s'], timeout=630)
            require(not any(x['metadata']['name'] == ns for x in self._items('namespaces')), 'Namespace deletion incomplete')
            state['stage'] = 'restoring-stopped-resources'
            save(folder / 'restore-state.json', state)
            self._create({'apiVersion': 'velero.io/v1', 'kind': 'Restore',
                          'metadata': {'name': rname, 'namespace': self.velero_namespace},
                          'spec': {'backupName': name, 'includedNamespaces': [ns], 'includeClusterResources': True,
                                   # PV manifests were excluded from the BACKUP. Do not
                                   # exclude the PV type here: Velero gates FSB/PVR creation
                                   # on both PV and PVC types being allowed during restore.
                                   'excludedResources': [x for x in EXCLUDED if x != 'persistentvolumes'],
                                   'restorePVs': True, 'existingResourcePolicy': 'none',
                                   'resourceModifier': {'apiGroup': '', 'kind': 'configmap', 'name': rname}}})
            save(folder / 'restore.json', self._velero_wait('restores', rname, meta))
            restored = copy.deepcopy(meta)
            restored['namespaceUID'] = self._get('namespace', ns)['metadata']['uid']
            require(self._namespace_contract(self._get('namespace', ns)) == meta['namespaceMetadataHash'],
                    'Restored Namespace labels or annotations differ')
            require(restored['namespaceUID'] != meta['namespaceUID'], 'Namespace was not replaced')
            pvcs = self._items('pvc', ns)
            restored['pvcs'] = {p['metadata']['name']: p['metadata']['uid'] for p in pvcs}
            require(set(restored['pvcs']) == PVC_NAMES and all(p.get('status', {}).get('phase') == 'Bound' and
                    p['metadata']['uid'] != meta['pvcs'][p['metadata']['name']] and
                    p['spec'].get('volumeName') not in meta['sourcePVs'].values() for p in pvcs), 'Restored PVC identities/binding invalid')
            restored['helperUID'] = self._get('pod', meta['helper'], ns)['metadata']['uid']
            save(folder / 'pvr.json', self._coverage(rname, restored, restore=True))
            self._run(self.K + ['-n', ns, 'wait', 'pod/' + meta['helper'], '--for=condition=Ready', '--timeout=300s'], timeout=330)
            deployments = self._items('deployments', ns)
            require({d['metadata']['name'] for d in deployments} == set(meta['replicas']) and
                    all(d['spec'].get('replicas', 1) == 0 for d in deployments) and self._quiet(ns, meta['helper']),
                    'Restored workload set is not quiescent')
            restored['deploymentUIDs'] = {d['metadata']['name']: d['metadata']['uid'] for d in deployments}
            require(self._probes(restored) == meta['probes'], 'Restored sample hashes/ownership differ; writers remain stopped')
            self._remove_helper(restored)
            save(folder / 'restored-replicas.json', restored)
            state['stage'] = 'resuming-restored-workloads'
            save(folder / 'restore-state.json', state)
            self._resume(restored)
            self._run(self.K + ['-n', self.velero_namespace, 'delete', 'configmap', rname, '--ignore-not-found=true'])
            require(not any(c['metadata']['name'] == rname for c in self._items('configmaps', self.velero_namespace)),
                    'Restore modifier cleanup incomplete')
            result = dict(state, stage='completed', namespace=ns, namespace_uid=restored['namespaceUID'],
                          cluster_uid=restored['clusterUID'], pvc_uids=restored['pvcs'],
                          applicationAcceptanceRequired=True, sampleHashes='matched')
            save(folder / 'restore-state.json', result)
            return result
        except BaseException:
            save(folder / 'restore-failure.json', dict(state, manualRecoveryRequired=True))
            raise RecoveryError('Restore failed; inspect private state and safety backup; do not retry automatically') from None
