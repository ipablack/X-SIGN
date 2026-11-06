"""Set up the publisher, Studio and native configuration in the separate source repo.

All files are committed atomically. Existing apps, managed-source deletions and
unknown catalogue fields survive. --preview performs GET requests only.
"""
from pathlib import Path
from urllib.parse import quote
import argparse
import base64
import copy
import hashlib
import json
import os
import re
from Disable_Legacy_Workflows import github_api, GitHubAPIError


def merge_missing(defaults, current):
    if isinstance(defaults, dict) and isinstance(current, dict):
        result = copy.deepcopy(current)
        for key, value in defaults.items():
            result[key] = merge_missing(value, current[key]) if key in current else copy.deepcopy(value)
        return result
    return copy.deepcopy(current)


def normalize_catalogue(current, defaults, priority):
    if not isinstance(current, dict) or not isinstance(current.get('apps'), list):
        raise ValueError('The existing repo.json needs a valid apps array; it was not overwritten.')
    result = merge_missing(defaults, current)
    config = result.get('xsign_config')
    if not isinstance(config, dict) or not isinstance(config.get('dashboard'), dict):
        raise ValueError('Invalid xsign_config/dashboard; it was not overwritten.')
    dashboard = config['dashboard']
    if dashboard.get('schema_version') != 2 or not isinstance(dashboard.get('sources'), list):
        raise ValueError('Review the unsupported dashboard schema before initializing the source repo.')
    aliases = {
        'https://github.com/ipablack/repo/raw/refs/heads/main/repo.json': priority[0],
        'https://github.com/ipablack/repo/blob/main/repo.json': priority[0],
        'https://raw.githubusercontent.com/ipablack/repo/refs/heads/main/repo.json': priority[0]}
    sources = dashboard['sources']
    if len(sources) > 50:
        raise ValueError('The dashboard supports at most 50 managed sources.')
    for item in sources:
        if not isinstance(item, dict) or not all(isinstance(item.get(k), str) and item[k] for k in ['id', 'name', 'url']):
            raise ValueError('Review a malformed managed source before publishing.')
    sources.sort(key=lambda item: priority.index(aliases.get(item['url'], item['url']))
                 if aliases.get(item['url'], item['url']) in priority else 2)
    # A real [] stays []; the compatibility projection cannot resurrect defaults.
    config['app_control']['core_sources'] = [
        {key: source[key] for key in ['name', 'id', 'url']}
        for source in sources if source.get('enabled') is not False]
    locks = config['security_locks']
    locks['lock_bundle_rename'] = not locks['allow_app_metadata_editing']
    if result['apps'] != current['apps']:
        raise ValueError('Catalogue initialization cannot modify or remove existing apps.')
    revision = current.get('repo_revision_id', 0)
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
        raise ValueError('Invalid repo_revision_id.')
    result['repo_revision_id'] = revision
    if result != current:
        result['repo_revision_id'] = revision + 1
    return result


def encode(data):
    return (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode()


def bootstrap(root, token, preview=False, call=github_api):
    contract = json.loads((root / 'Tools/Integration/contract.json').read_text())
    repository = contract['publish_repository']
    branch = contract['publish_branch']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid source repository.')
    if not token and not preview:
        raise ValueError('XSIGN_CONTROL_TOKEN is required to write to the separate source repository.')

    def api(endpoint, method='GET', payload=None):
        return call(repository, token, endpoint, method, payload)

    metadata = api('')
    if metadata.get('default_branch') != branch:
        raise ValueError('The source default branch must match the reviewed branch: ' + branch)
    head = api('git/ref/heads/' + quote(branch, safe=''))['object']['sha']
    tree = api('git/commits/' + head)['tree']['sha']

    def read_file(path):
        try:
            value = api('contents/' + quote(path, safe='/') + '?ref=' + quote(head, safe=''))
        except GitHubAPIError as error:
            if error.status == 404:
                return None
            raise
        if value.get('type') != 'file' or value.get('size', 0) > 15 * 1024 * 1024:
            raise ValueError('Invalid or oversized source file: ' + path)
        if value.get('encoding') != 'base64':
            sha = value.get('sha', '')
            if not re.fullmatch(r'[a-f0-9]{40,64}', sha):
                raise ValueError('Invalid source blob.')
            value = api('git/blobs/' + sha)
        if value.get('encoding') != 'base64' or not isinstance(value.get('content'), str):
            raise ValueError('The source file could not be read: ' + path)
        data = base64.b64decode(''.join(value['content'].split()), validate=True)
        if len(data) > 15 * 1024 * 1024:
            raise ValueError('Source file exceeds 15 MiB: ' + path)
        return data

    old = read_file(contract['catalogue_path'])
    defaults = json.loads((root / 'Tools/Delivery/repo.example.json').read_text())
    current = json.loads(old.decode('utf-8-sig')) if old is not None else {'apps': []}
    catalogue = normalize_catalogue(current, defaults, contract['source_priority'])
    projection = {key: catalogue[key] for key in ['name', 'identifier', 'subtitle', 'description', 'iconURL',
        'tintColor', 'repo_revision_id', 'xsign_config', 'categories'] if key in catalogue}
    targets = {
        contract['catalogue_path']: encode(catalogue),
        contract['projection_path']: encode(projection),
        '.github/workflows/ipa_manager.yml': (root / 'Tools/Delivery/ipa_manager.yml').read_bytes(),
        'studio.html': (root / 'Tools/XSign_Studio.html').read_bytes()}
    known = json.loads((root / 'Tools/Delivery/source-asset-hashes.json').read_text())
    changes = []
    for path, content in targets.items():
        existing = old if path == contract['catalogue_path'] else read_file(path)
        if existing == content:
            continue
        if path in known and existing is not None and hashlib.sha256(existing).hexdigest() not in known[path]:
            raise ValueError('A customized source asset needs review before replacement: ' + path)
        changes.append({'path': path, 'mode': '100644', 'type': 'blob', 'content': content.decode()})
    result = {'status': 'preview' if preview else 'unchanged', 'repository': repository, 'branch': branch,
        'preserved_apps': len(current['apps']), 'revision': catalogue['repo_revision_id'],
        'files': [item['path'] for item in changes]}
    if changes and not preview:
        updated_tree = api('git/trees', 'POST', {'base_tree': tree, 'tree': changes})
        commit = api('git/commits', 'POST', {'message': 'Initialize unified XSign Studio, sources and IPA publisher [skip ci]',
            'tree': updated_tree['sha'], 'parents': [head]})
        api('git/refs/heads/' + quote(branch, safe=''), 'PATCH', {'sha': commit['sha'], 'force': False})
        result.update(status='saved', commit=commit['sha'])
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview', action='store_true')
    args = parser.parse_args()
    try:
        result = bootstrap(Path(__file__).resolve().parents[1], os.environ.get('XSIGN_CONTROL_TOKEN', ''), preview=args.preview)
        print(json.dumps(result, ensure_ascii=False))
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with Path(summary).open('a') as output:
                output.write('## Source setup: ' + result['status'] + '\n\nRepository: `' + result['repository']
                    + '`. Existing apps preserved: ' + str(result['preserved_apps']) + '.\n\n'
                    + 'Studio HTML is saved as `studio.html`; publishing the existing website remains a separate hosting action.\n')
    except Exception as error:
        raise SystemExit('::error::' + str(error).replace('\n', ' ')[:700])
