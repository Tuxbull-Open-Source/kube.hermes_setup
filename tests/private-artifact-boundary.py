#!/usr/bin/env python3
"""Guard private runtime artifacts without creating or reading any private files.

Uses check-ignore --no-index so accidental tracked private files cannot hide a
missing ignore rule. A separate tracked-tree check detects already-added leaks.
Public example templates must remain both trackable and present in Git.
"""
from pathlib import Path, PurePosixPath
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = (
    'hermes.env', 'current_config/hermes.env', 'current_config/artifacts/hermes.yaml',
    'configuration_answers', '.rendered/hermes.yaml', '.rendered/bootstrap.tar.gz',
    '.maintenance-state/plan.json', '.maintenance-state/recovery/metadata.json',
    'cluster.kubeconfig', 'kubeconfig', 'kubeconfig.yaml', 'kubeconfigs/cluster.yaml',
    '.kube/config', 'auth.json', 'runtime/auth.json', 'runtime/state.db',
    'runtime/sessions.sqlite', 'runtime/sessions.sqlite3', 'runtime/state.db-wal',
    'logs/upgrade.log', 'upgrade.log', 'plans/plan.json', '.hermes/plans/upgrade.md',
    'backups/manifest.json', 'backup-manifests/backup.yaml', 'backup.tar.gz',
)
PUBLIC = ('examples/hermes.env.example', 'manifests/hermes.yaml.tpl',
          'examples/bootstrap-profiles/personal-assistant/requirements.txt',
          'examples/bootstrap-profiles/personal-assistant/memories/MEMORY.md')


def git(*args, input=None):
    result = subprocess.run(['git', '--no-replace-objects', '-C', str(ROOT), *args],
                            input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in (0, 1):
        raise RuntimeError('Git boundary inspection failed')
    return result


def ignored(paths):
    result = git('check-ignore', '--no-index', '-z', '--stdin',
                 input=b'\0'.join(p.encode() for p in paths) + b'\0')
    return {p.decode() for p in result.stdout.split(b'\0') if p}


def private_name(name):
    path = PurePosixPath(name)
    parts = path.parts
    directories = {'current_config', '.rendered', '.maintenance-state', 'kubeconfigs',
                   '.kube', 'backups', 'backup-manifests', 'logs', 'plans'}
    basename = path.name
    return (bool(set(parts[:-1]) & directories) or
            parts[0] in ('bootstrap', 'configuration_answers') or
            basename in ('auth.json', 'hermes.env', 'kubeconfig') or
            basename.startswith('kubeconfig.') or
            basename.endswith(('.env', '.key', '.token', '.secret', '.kubeconfig', '.log',
                               '.db', '.sqlite', '.sqlite3', '.db-wal', '.db-shm',
                               '.sqlite-wal', '.sqlite-shm', '.sqlite3-wal', '.sqlite3-shm',
                               '.tgz', '.tar.gz', '.age')))


class ArtifactBoundary(unittest.TestCase):
    def test_private_paths_are_ignored(self):
        missing = sorted(set(PRIVATE) - ignored(PRIVATE))
        self.assertEqual(missing, [], 'Private artifact paths not ignored: ' + ', '.join(missing))

    def test_public_sanitized_templates_remain_trackable(self):
        self.assertEqual(ignored(PUBLIC), set(), 'Public templates must not be ignored')
        tracked = {x.decode() for x in git('ls-files', '-z').stdout.split(b'\0') if x}
        self.assertTrue(set(PUBLIC) <= tracked, 'Public sanitized examples must stay versioned')

    def test_tracked_tree_excludes_private_artifacts(self):
        tracked = [x.decode() for x in git('ls-files', '-z').stdout.split(b'\0') if x]
        forbidden = sorted(p for p in tracked if private_name(p))
        self.assertEqual(forbidden, [], 'Tracked private artifact paths: ' + ', '.join(forbidden))


if __name__ == '__main__':
    unittest.main(verbosity=2)
