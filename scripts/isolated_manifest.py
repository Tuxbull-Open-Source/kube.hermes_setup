#!/usr/bin/env python3
"""Restrict an explicitly isolated rehearsal manifest, never production."""
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


if __name__ == '__main__':
    path = Path(sys.argv[1])
    path.write_text(yaml.safe_dump_all(restrict(yaml.safe_load_all(path.read_text()), os.environ['HERMES_NAMESPACE'])))
