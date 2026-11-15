#!/usr/bin/env python3
"""Resolve publisher stable releases to verified registry manifest digests."""
import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request

COMPONENTS = {
    'HERMES_AGENT_IMAGE': ('NousResearch/hermes-agent', 'docker.io/nousresearch/hermes-agent', 'v'),
    'HERMES_WEBUI_IMAGE': ('nesquena/hermes-webui', 'ghcr.io/nesquena/hermes-webui', ''),
    'HERMES_BROWSER_IMAGE': ('browserless/browserless', 'ghcr.io/browserless/chromium', 'v'),
}


def fetch(url, headers=None):
    request = urllib.request.Request(url, headers={'User-Agent': 'kube-hermes-maintenance', **(headers or {})})
    with urllib.request.urlopen(request, timeout=45) as response:
        return response.read(), response.headers


def stable(release):
    if release.get('draft') or release.get('prerelease') or not re.fullmatch(r'v?\d+\.\d+\.\d+', release.get('tag_name', '')):
        raise ValueError('Publisher release is not a stable semantic version')
    return release['tag_name'].lstrip('v')


def digest(image):
    registry, name = image.split('/', 1)
    name, tag = name.rsplit(':', 1)
    host = 'registry-1.docker.io' if registry == 'docker.io' else registry
    url = f'https://{host}/v2/{name}/manifests/{tag}'
    headers = {'Accept': ', '.join(['application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json', 'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'])}
    try:
        body, response = fetch(url, headers)
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
        challenge = dict(re.findall(r'(\w+)="([^"]+)"', error.headers.get('WWW-Authenticate', '')))
        realm = challenge.pop('realm')
        if urllib.parse.urlparse(realm).scheme != 'https':
            raise ValueError('Insecure registry authentication endpoint')
        token = json.loads(fetch(realm + '?' + urllib.parse.urlencode(challenge))[0])
        headers['Authorization'] = 'Bearer ' + (token.get('token') or token['access_token'])
        body, response = fetch(url, headers)
    calculated = 'sha256:' + hashlib.sha256(body).hexdigest()
    if response.get('Docker-Content-Digest') != calculated:
        raise ValueError('Registry manifest digest mismatch')
    manifest = json.loads(body)
    if manifest.get('schemaVersion') != 2:
        raise ValueError('Unsupported registry manifest')
    return image + '@' + calculated


def verify_selected(values):
    records = {}
    for key, (repo, image, prefix) in COMPONENTS.items():
        selected = values.get(key, '')
        match = re.fullmatch(re.escape(image) + r':(v?\d+\.\d+\.\d+)@sha256:[a-f0-9]{64}', selected)
        if not match:
            raise ValueError('Selected image is not a pinned stable publisher image')
        tag = 'v' + match[1].lstrip('v')
        release = json.loads(fetch(f'https://api.github.com/repos/{repo}/releases/tags/{tag}')[0])
        stable(release)
        if digest(selected.split('@')[0]) != selected:
            raise ValueError('Selected digest differs from publisher registry tag')
        records[key] = {'image': selected, 'release': release['html_url'], 'tag': tag, 'prerelease': False}
    return records


def resolve():
    result = {}
    for key, (repo, image, prefix) in COMPONENTS.items():
        url = f'https://api.github.com/repos/{repo}/releases/latest'
        release = json.loads(fetch(url)[0])
        version = stable(release)
        result[key] = {'image': digest(f'{image}:{prefix}{version}'), 'release': release['html_url'], 'tag': release['tag_name'], 'prerelease': False}
    return result


if __name__ == '__main__':
    print(json.dumps(resolve(), indent=2))
