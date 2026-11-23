#!/usr/bin/env python3
"""Restrict an explicitly isolated rehearsal manifest, never production."""
import copy
import json
import subprocess
import os
from pathlib import Path
import re
import sys
import yaml


def restrict(documents, namespace):
    if not re.fullmatch(r'hermes-test-[a-z0-9-]+|wow-velero-test-[a-z0-9-]+', namespace):
        raise ValueError('Isolated mode requires a dedicated test namespace')
    result = []
    for doc in documents:
        if not doc:
            continue
        if doc.get('metadata', {}).get('namespace', namespace) != namespace:
            raise ValueError('Cross-namespace rehearsal manifest')
        if doc['kind'] in ['Ingress', 'Middleware', 'NetworkPolicy']:
            continue
        if doc['kind'] == 'Deployment' and doc['metadata']['name'] == 'hermes-webui':
            doc['spec']['template']['spec']['containers'][0]['env'].append({'name': 'UV_OFFLINE', 'value': 'true'})
        result.append(doc)
    return result


def kubectl(*args):
    # Never interpret a failed request (Forbidden, timeout, etc.) as absence.
    result = subprocess.run(['kubectl', '--request-timeout=30s', *args],
                            check=True, capture_output=True, text=True, timeout=45)
    if not result.stdout.strip():
        if '--ignore-not-found=true' in args:
            return None
        raise ValueError('Empty Kubernetes response')
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError('Malformed Kubernetes response')
    return value


def items(value):
    if not isinstance(value, dict) or not isinstance(value.get('items'), list):
        raise ValueError('Malformed isolation resource list')
    for item in value['items']:
        if not isinstance(item, dict) or not isinstance(item.get('metadata', {}).get('name'), str):
            raise ValueError('Malformed isolation resource')
    return value['items']


def preflight(documents, namespace):
    """Read-only managed-exposure guard, not proof of network isolation."""
    restrict(copy.deepcopy(documents), namespace)  # Validate before API reads; keep input unfiltered.
    current = kubectl('get', 'namespace', namespace, '--ignore-not-found=true', '-o', 'json')
    if current is None:  # Only successful --ignore-not-found may establish absence.
        return
    if current.get('kind') != 'Namespace' or current.get('metadata', {}).get('name') != namespace:
        raise ValueError('Unexpected namespace response')
    vendor = {d['metadata']['name'] for d in documents if d and d['kind'] == 'NetworkPolicy'}
    base = '/apis/networking.k8s.io/v1/namespaces/' + namespace
    if items(kubectl('get', '--raw', base + '/ingresses')):
        raise ValueError('Existing Ingress conflicts with isolated mode; remove separately after review')
    policies = items(kubectl('get', '--raw', base + '/networkpolicies'))
    if vendor & {p['metadata']['name'] for p in policies}:
        raise ValueError('Existing vendor NetworkPolicy conflicts with isolated mode; remove separately after review')
    # Discover optional Traefik APIs rather than swallowing all NotFound/errors.
    # A missing group/resource is safe; a failed discovery/list is never safe.
    discovery = kubectl('get', '--raw', '/apis')
    if not isinstance(discovery, dict) or not isinstance(discovery.get('groups'), list):
        raise ValueError('Malformed API discovery')
    for group in discovery['groups']:
        if not isinstance(group.get('name'), str):
            raise ValueError('Malformed API group')
        if group['name'] not in ['traefik.io', 'traefik.containo.us']:
            continue
        version = group['preferredVersion']['groupVersion']
        if not isinstance(version, str) or not re.fullmatch(re.escape(group['name']) + r'/v[0-9]+(?:alpha[0-9]+|beta[0-9]+)?', version):
            raise ValueError('Malformed API version')
        api = kubectl('get', '--raw', '/apis/' + version)
        if not isinstance(api, dict) or not isinstance(api.get('resources'), list):
            raise ValueError('Malformed API resources')
        for resource in api['resources']:
            name = resource['name']
            if not isinstance(name, str):
                raise ValueError('Malformed API resource name')
            if name not in ['middlewares', 'ingressroutes', 'ingressroutetcps', 'ingressrouteudps']:
                continue
            if resource.get('namespaced') is not True:
                raise ValueError('Unexpected exposure resource scope')
            if items(kubectl('get', '--raw', '/apis/' + version + '/namespaces/' + namespace + '/' + name)):
                raise ValueError('Existing Traefik exposure conflicts with isolated mode; remove separately after review')


if __name__ == '__main__':
    path = Path(sys.argv[1])
    documents = list(yaml.safe_load_all(path.read_text()))
    namespace = os.environ['HERMES_NAMESPACE']
    if len(sys.argv) > 2 and sys.argv[2] == 'preflight':
        preflight(documents, namespace)
    path.write_text(yaml.safe_dump_all(restrict(documents, namespace)))
