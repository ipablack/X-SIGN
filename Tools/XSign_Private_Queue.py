"""Process an opaque request on a public runner using only private GitHub storage."""
import base64
from contextlib import redirect_stdout, redirect_stderr
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

import XSign_Release as release
from Delivery import ipa_publisher as publisher


class QueueConfigurationError(ValueError):
    """A fixed operator-facing message that can be shown in public CI logs."""


def read_file(path, commit, limit):
    entry = publisher.api('contents/' + publisher.encode_path(path) + '?ref=' + commit, optional=True)
    if entry is None:
        raise QueueConfigurationError('A queued request file is missing. Submit the IPA again from Studio.')
    size = entry.get('size')
    sha = entry.get('sha', '')
    if entry.get('type') != 'file' or type(size) is not int or not 0 < size <= limit or not re.fullmatch(r'[a-f0-9]{40}', sha):
        raise ValueError('Invalid private queue file')
    blob = entry if entry.get('encoding') == 'base64' and entry.get('content') else publisher.api('git/blobs/' + sha)
    data = base64.b64decode(''.join(blob['content'].split()), validate=True)
    if len(data) != size or hashlib.sha1(b'blob ' + str(size).encode() + b'\0' + data).hexdigest() != sha:
        raise ValueError('Private queue file changed')
    return data, sha


def write_result(result_path, output, cleanup):
    # Update only against the current head. Successful reruns are idempotent.
    for attempt in range(3):
        head = publisher.api('git/ref/heads/main')['object']['sha']
        if publisher.content(result_path, head):
            return
        tree = publisher.api('git/commits/' + head)['tree']['sha']
        entries = [{'path': result_path, 'mode': '100644', 'type': 'blob', 'content': json.dumps(output, ensure_ascii=False)}]
        current = {path: publisher.api('contents/' + publisher.encode_path(path) + '?ref=' + head, optional=True)
                   for path in cleanup}
        if all(current[path] and current[path].get('sha') == digest for path, digest in cleanup.items()):
            entries += [{'path': path, 'mode': '100644', 'type': 'blob', 'sha': None} for path in cleanup]
        tree = publisher.api('git/trees', 'POST', {'base_tree': tree, 'tree': entries})
        commit = publisher.api('git/commits', 'POST', {'message': 'Save XSign processing result', 'tree': tree['sha'], 'parents': [head]})
        try:
            publisher.api('git/refs/heads/main', 'PATCH', {'sha': commit['sha'], 'force': False})
            return
        except RuntimeError as error:
            if not getattr(error, 'conflict', False) or attempt == 2:
                raise


def process():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_bytes())
    payload = event.get('client_payload')
    action = event.get('action')
    if event.get('repository', {}).get('private') is not False:
        raise QueueConfigurationError('Run IPA inspection in the public extraction repository.')
    if action not in ('xsign-inspect-ipa', 'xsign-publish-ipa') or not isinstance(payload, dict) or set(payload) != {'request_id'}:
        raise QueueConfigurationError('The dispatch must contain only a queued request ID. For a public Release link, use the Studio public inspection workflow.')
    request = payload['request_id']
    if not release.valid_request_id(request):
        raise QueueConfigurationError('Studio supplied an invalid queue request ID.')
    target = os.environ.get('XSIGN_CATALOG_REPOSITORY', '')
    token = os.environ.get('XSIGN_IPA_STORAGE_TOKEN', '')
    if not re.fullmatch(r'[A-Za-z0-9-]+/[A-Za-z0-9_.-]+', target) or not token:
        raise QueueConfigurationError('Set XSIGN_IPA_STORAGE_REPOSITORY and XSIGN_IPA_STORAGE_TOKEN for private queue jobs, or inspect a public Release link from Studio.')
    publisher.REPO = target
    publisher.BRANCH = 'main'
    os.environ['GH_TOKEN'] = token
    try:
        repository = publisher.api('')
    except RuntimeError:
        raise QueueConfigurationError('The runner could not read the configured storage repository. Check its name and token permissions.') from None
    if repository.get('private') is not True or repository.get('full_name', '').lower() != target.lower():
        raise QueueConfigurationError('The configured private queue requires a private storage repository. Use the public inspection workflow for public assets.')
    head = publisher.api('git/ref/heads/main')['object']['sha']
    request_path = '.xsign-queue/requests/' + request + '.json'
    result_path = '.xsign-queue/results/' + request + '.json'
    if publisher.content(result_path, head):
        return
    data, sha = read_file(request_path, head, 100_000)
    queued = json.loads(data)
    kind = 'inspect' if action == 'xsign-inspect-ipa' else 'publish'
    if queued.get('kind') != kind:
        raise QueueConfigurationError('The queued operation does not match the requested workflow.')
    cleanup = {request_path: sha}
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        ipa = folder / 'app.ipa'
        url = queued.get('ipa_url')
        if url is not None:
            url = release.checked_url(url, 'IPA')
            parts = release.private_release_parts(url, target)
            if not parts:
                raise QueueConfigurationError('The private queue accepts Release assets from its configured storage repository. Inspect public Release links from Studio.')
            release.download_private_release(parts, target, token, ipa)
        elif kind == 'publish':
            path = '.xsign-queue/requests/' + request + '.ipa'
            package, digest = read_file(path, head, 25 * 1024 * 1024)
            cleanup[path] = digest
            ipa.write_bytes(package)
        else:
            raise ValueError('Inspection requires a private Release asset')
        if kind == 'inspect':
            result = release.inspect_ipa(ipa)
            result['requestDigest'] = hashlib.sha256(url.encode()).hexdigest()
        else:
            metadata = publisher.clean_metadata(queued.get('metadata', {}))
            # Generated icons stay private as part of the Release.
            metadata['icon'] = ''
            info = publisher.inspect_ipa(ipa, metadata, folder)
            catalogue = publisher.snapshot()['data']
            publisher.choose_category(catalogue, metadata)
            existing = publisher.match_app(catalogue['apps'], info, metadata)
            duplicate = publisher.duplicate(existing, info, metadata)
            job = {'ipa': ipa, 'folder': folder, 'info': info, 'metadata': metadata, 'cleanup': {},
                   'base': existing, 'duplicate': duplicate, 'release_commit': head}
            if not duplicate:
                publisher.publish_release(job, repository)
            publisher.commit_catalogue([job])
            result = {'sha256': info['sha256'], 'published': True}
    write_result(result_path, {'requestID': request, **result}, cleanup)


if __name__ == '__main__':
    try:
        with open(os.devnull, "w") as sink, redirect_stdout(sink), redirect_stderr(sink):
            process()
    except QueueConfigurationError as error:
        print('::error::' + str(error))
        raise SystemExit(1) from None
    except Exception:
        print('::error::Could not process the private queue. Check queue contents, repository access and the Release asset.')
        # Neither repository paths, metadata, nor provider errors belong in public logs.
        raise SystemExit(1) from None
