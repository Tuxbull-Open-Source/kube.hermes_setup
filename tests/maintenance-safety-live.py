#!/usr/bin/env python3
"""Opt-in real API regression, disposable namespace only; no PVCs or real data.
Usage: python3 tests/maintenance-safety-live.py UNFILTERED_MANIFEST CACHED_IMAGE
Set HERMES_NAMESPACE to a new hermes-test-* namespace; requires kubectl/PyYAML.
Creates and deletes only that namespace. Does not qualify a full Hermes upgrade.
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


isolated = load('isolated_manifest')
host = load('host_maintenance')


def k(*args, obj=None):
    result = subprocess.run(['kubectl', '--request-timeout=30s', *args],
                            input=json.dumps(obj) if obj else None, text=True,
                            capture_output=True, check=True, timeout=180)
    return json.loads(result.stdout) if result.stdout.strip() else None


def main():
    namespace = os.environ['HERMES_NAMESPACE']
    docs = [x for x in yaml.safe_load_all(Path(sys.argv[1]).read_text()) if x]
    image = sys.argv[2]
    isolated.restrict(copy.deepcopy(docs), namespace)
    assert k('get', 'namespace', namespace, '--ignore-not-found=true', '-o', 'json') is None, 'Refuse reused namespace'
    isolated.preflight(docs, namespace)
    print('PASS absent namespace')
    k('create', 'namespace', namespace, '-o', 'json')
    try:
        policy = dict(apiVersion='networking.k8s.io/v1', kind='NetworkPolicy', metadata=dict(name='operator-deny', namespace=namespace),
                      spec=dict(podSelector={}, policyTypes=['Ingress', 'Egress']))
        original = k('apply', '-f', '-', '-o', 'json', obj=policy)
        isolated.preflight(docs, namespace)
        vendor = next(d['metadata']['name'] for d in docs if d['kind'] == 'NetworkPolicy')
        fixtures = [dict(apiVersion='networking.k8s.io/v1', kind='Ingress', metadata=dict(name='old-route', namespace=namespace),
                         spec=dict(ingressClassName='fixture-no-controller', defaultBackend=dict(service=dict(name='absent', port=dict(number=80))))),
                    dict(policy, metadata=dict(name=vendor, namespace=namespace))]
        groups = k('get', '--raw', '/apis')['groups']
        for group in groups:
            if group['name'] in ['traefik.io', 'traefik.containo.us']:
                version = group['preferredVersion']['groupVersion']
                resources = k('get', '--raw', '/apis/' + version)['resources']
                if any(r['name'] == 'middlewares' for r in resources):
                    fixtures.append(dict(apiVersion=version, kind='Middleware', metadata=dict(name='old-middleware', namespace=namespace),
                                         spec=dict(headers=dict(customRequestHeaders={'X-Fixture': 'test'}))))
        for fixture in fixtures:
            before = k('apply', '-f', '-', '-o', 'json', obj=fixture)
            try:
                isolated.preflight(docs, namespace)
                raise AssertionError('Preflight accepted ' + fixture['kind'])
            except ValueError:
                pass
            resource = fixture['kind'].lower()
            if fixture['kind'] == 'Middleware':
                resource += '.' + fixture['apiVersion'].split('/')[0]
            after = k('-n', namespace, 'get', resource, fixture['metadata']['name'], '-o', 'json')
            assert (before['metadata']['uid'], before['metadata']['resourceVersion'], before['spec']) == (after['metadata']['uid'], after['metadata']['resourceVersion'], after['spec'])
            assert not k('-n', namespace, 'get', 'deployments,secrets,jobs,pvc', '-o', 'json')['items']
            print('PASS refused unchanged ' + fixture['kind'])
            subprocess.run(['kubectl', '-n', namespace, 'delete', resource, fixture['metadata']['name'], '--wait=true'], check=True, timeout=60)
            assert k('-n', namespace, 'get', resource, fixture['metadata']['name'], '--ignore-not-found=true', '-o', 'json') is None
        isolated.preflight(docs, namespace)
        security = dict(runAsUser=10000, runAsGroup=10000, allowPrivilegeEscalation=False,
                        readOnlyRootFilesystem=True, capabilities=dict(drop=['ALL']), seccompProfile=dict(type='RuntimeDefault'))
        container = dict(name='app', image=image, command=['/bin/sh', '-c'], args=['sleep 300'], securityContext=security)
        deployment = dict(apiVersion='apps/v1', kind='Deployment', metadata=dict(name='fixture', namespace=namespace),
                          spec=dict(replicas=1, selector=dict(matchLabels=dict(app='fixture')), template=dict(metadata=dict(labels=dict(app='fixture')),
                          spec=dict(securityContext={}, containers=[container], initContainers=[dict(container, name='init', args=['true'])]))))
        filtered = isolated.restrict([copy.deepcopy(deployment)], namespace)
        k('apply', '-f', '-', '-o', 'json', obj=filtered[0])
        subprocess.run(['kubectl', '-n', namespace, 'rollout', 'status', 'deployment/fixture', '--timeout=120s'], check=True, timeout=150)
        live = k('-n', namespace, 'get', 'deployment', 'fixture', '-o', 'json')
        before = dict(deployments=[live], pvcs=[])
        host.protected_contract(before, [deployment], namespace)
        for field in ['containers', 'initContainers']:
            target = copy.deepcopy(deployment)
            target['spec']['template']['spec'][field][0]['image'] = 'example.com/image:new'
            host.protected_contract(before, [target], namespace)
            for key, value in [('command', ['false']), ('args', ['false']), ('securityContext', {'privileged': True})]:
                target = copy.deepcopy(deployment)
                target['spec']['template']['spec'][field][0][key] = value
                try:
                    host.protected_contract(before, [target], namespace)
                    raise AssertionError('Accepted changed ' + field + '/' + key)
                except host.Error:
                    pass
        after = k('-n', namespace, 'get', 'networkpolicy', 'operator-deny', '-o', 'json')
        assert (original['metadata']['uid'], original['spec']) == (after['metadata']['uid'], after['spec'])
        print('PASS clean filtered Deployment Ready, real API defaults, image-only positive, six execution/security negatives; operator policy UID/spec unchanged')
    finally:
        subprocess.run(['kubectl', 'delete', 'namespace', namespace, '--wait=true', '--timeout=120s'], check=True, timeout=150)
        assert k('get', 'namespace', namespace, '--ignore-not-found=true', '-o', 'json') is None
        print('PASS cleanup namespace; no PVCs or host data created')


if __name__ == '__main__':
    main()
