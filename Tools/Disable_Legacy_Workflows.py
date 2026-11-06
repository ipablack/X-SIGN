"""Disable reviewed, superseded workflows in this repository; never delete them."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import re
import urllib.error
import urllib.request


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHubAPIError(RuntimeError):
    def __init__(self, status):
        self.status = status
        super().__init__('GitHub HTTP ' + str(status))


def github_api(repository, token, endpoint, method='GET', payload=None):
    headers = {'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
               'User-Agent': 'XSign-Unified/1.0', 'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(
        'https://api.github.com/repos/' + repository + ('/' + endpoint if endpoint else ''),
        data=json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None,
        method=method, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirects).open(request, timeout=30) as response:
            data = response.read(25_165_825)
            if len(data) > 25_165_824:
                raise RuntimeError('GitHub workflow response exceeded the limit.')
            return json.loads(data) if data else None
    except urllib.error.HTTPError as error:
        raise GitHubAPIError(error.code) from None
    except urllib.error.URLError:
        raise RuntimeError('Cannot reach GitHub.') from None


def consolidate(root, repository, token, branch, call=github_api, expected_head=None):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository.')
    metadata = call(repository, token, '')
    if branch != metadata.get('default_branch'):
        print('Branch check: legacy workflow states are changed only on the default branch.')
        return []
    if expected_head:
        from urllib.parse import quote
        current = call(repository, token, 'git/ref/heads/' + quote(branch, safe=''))['object']['sha']
        if current != expected_head:
            raise RuntimeError('The default branch changed; run the unified workflow again from the latest commit.')
    approved = json.loads((root / 'Tools/Delivery/legacy-workflows.json').read_text())
    workflows = []
    for page in range(1, 11):
        batch = call(repository, token, 'actions/workflows?per_page=100&page=' + str(page))['workflows']
        workflows.extend(batch)
        if len(batch) < 100:
            break
    else:
        raise RuntimeError('Workflow inventory exceeded the review limit.')
    plan = []
    for workflow in workflows:
        path = workflow.get('path')
        if path not in approved or workflow.get('state') != 'active':
            continue
        rel = PurePosixPath(path)
        if rel.is_absolute() or '..' in rel.parts or len(rel.parts) != 3 or rel.parts[:2] != ('.github', 'workflows'):
            raise ValueError('Invalid reviewed workflow path.')
        file = root / path
        if file.is_symlink() or not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() not in approved[path]:
            raise RuntimeError('Review the changed legacy workflow before disabling it: ' + path)
        identifier = str(workflow['id'])
        if not identifier.isdecimal():
            raise ValueError('Invalid GitHub workflow identifier.')
        plan.append((path, identifier))
    # Validate the entire plan before the first mutation. Custom workflows stay active.
    for path, identifier in plan:
        call(repository, token, 'actions/workflows/' + identifier + '/disable', 'PUT')
        print('Disabled superseded workflow:', path)
    print('Unified workflow retained. Existing runs are not cancelled; workflow files were not deleted.')
    return [path for path, _ in plan]


if __name__ == '__main__':
    try:
        token = os.environ.get('GH_TOKEN', '')
        if not token:
            raise RuntimeError('The workflow token is missing.')
        consolidate(Path.cwd(), os.environ['GITHUB_REPOSITORY'], token, os.environ['GITHUB_REF_NAME'], expected_head=os.environ['GITHUB_SHA'])
    except Exception as error:
        raise SystemExit('::error::' + str(error).replace('\n', ' ')[:500])
