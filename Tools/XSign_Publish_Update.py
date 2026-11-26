"""Publish a verified Studio build, then commit its update policy in one Git operation."""
import json
import os
from pathlib import Path
import re

from Delivery import ipa_publisher as github
from XSign_Release import inspect_ipa


TARGET = 'ipablack/repo'
LEGACY = 'com.ipablack.xsign'
PRIMARY = 'xsign'
CONFIG_LIMIT = 524288
PROJECTION = ('name', 'identifier', 'subtitle', 'description', 'iconURL', 'tintColor',
              'repo_revision_id', 'xsign_config', 'categories')


def version_key(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,9}(?:\.[0-9]{1,9}){0,3}', value):
        raise ValueError('Expected a numeric version and build number.')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (4 - len(parts))


def update_policy(data, info, url):
    config = data.get('xsign_config', {})
    dashboard = config.get('dashboard', {})
    if dashboard.get('schema_version') != 2:
        raise ValueError('Publish the current Studio settings to ipablack/repo before enabling automatic updates.')
    records = dashboard.setdefault('bundle_updates', {})
    generic = dashboard.get('update', {})
    alias = dashboard.get('compatibility_update_bundle')
    bundle = info['bundleIdentifier'].lower()
    current = records.get(bundle, generic if bundle == (alias or LEGACY) else {})
    same_asset = current.get('sha256') == info['sha256']
    if same_asset and current.get('enabled') is True and current.get('required') is True and current.get('ipa_url'):
        return False
    if current.get('latest_version') and not same_asset:
        candidate = version_key(info['version']), version_key(info['buildVersion'])
        previous = version_key(current['latest_version']), version_key(current.get('build_version') or '0')
        if candidate <= previous:
            raise ValueError('The published policy already has this version/build or a newer one. Increase the build number.')
    update = {**current, 'enabled': True, 'required': True, 'required_policy': 'minimum',
              'bundle_identifier': bundle, 'app_name': info['appName'],
              'latest_version': info['version'], 'build_version': info['buildVersion'],
              'sha256': info['sha256'], 'ipa_url': url, 'manifest_url': '',
              'build_request_id': info['buildRequestID'], 'html': current.get('html', '')}
    records[bundle] = update
    if bundle == PRIMARY:
        if alias != PRIMARY:
            records.setdefault(LEGACY, generic)
        dashboard.update(update=update, compatibility_update_bundle=PRIMARY)
    elif bundle == LEGACY:
        if not alias or alias == LEGACY:
            dashboard['update'] = update
        config.setdefault('force_update', {}).update(enabled=True, min_version=info['version'],
                                                     min_build_version=info['buildVersion'], update_url=url)
    revision = data.get('repo_revision_id', 0)
    if type(revision) is not int or revision < 0:
        raise ValueError('Invalid catalogue revision.')
    data['repo_revision_id'] = revision + 1
    return True


def publish_policy(info, url):
    for attempt in range(3):
        remote = github.snapshot()
        data = remote['data']
        if not update_policy(data, info, url):
            return
        projected = {key: data[key] for key in PROJECTION if key in data}
        projection = json.dumps(projected, ensure_ascii=False, indent=2) + '\n'
        if len(projection.encode()) > CONFIG_LIMIT:
            raise ValueError('Studio configuration exceeds 512 KiB.')
        entries = [{'path': path, 'mode': '100644', 'type': 'blob', 'content': contents}
                   for path, contents in [('repo.json', json.dumps(data, ensure_ascii=False, indent=2) + '\n'),
                                          ('xsign-config.json', projection)]]
        tree = github.api('git/trees', 'POST', {'base_tree': remote['tree'], 'tree': entries})
        commit = github.api('git/commits', 'POST', {'tree': tree['sha'], 'parents': [remote['head']],
                                                   'message': 'Publish mandatory XSign update [skip ci]'})
        try:
            github.api('git/refs/heads/main', 'PATCH', {'sha': commit['sha'], 'force': False})
            return
        except RuntimeError as error:
            if not getattr(error, 'conflict', False) or attempt == 2:
                raise


def publish_asset(path, info):
    tag = 'xsign-update-' + info['sha256']
    release = github.find_release(tag)
    if release is None:
        release = github.api('releases', 'POST', {'tag_name': tag, 'target_commitish': 'main', 'draft': True,
                                                   'name': f"XSign {info['version']} ({info['buildVersion']})",
                                                   'make_latest': 'false'})
    release_id = str(release['id'])
    asset = next((entry for entry in release['assets'] if entry['name'] == path.name), None)
    if asset is None:
        if not release['draft']:
            raise ValueError('This published release is missing its verified asset.')
        asset = github.upload_asset(TARGET, release_id, path)
    github.verify_asset(asset, path.name, info['size'], info['sha256'])
    if release['draft']:
        github.api('releases/' + release_id, 'PATCH', {'draft': False, 'make_latest': 'false'})
    return github.final_release_assets(release_id, tag, TARGET, {path.name: asset})[path.name]


def main():
    if not os.environ.get('GH_TOKEN'):
        raise ValueError('Set XSIGN_RELEASE_PUBLISH_TOKEN in Actions to publish automatic updates.')
    github.REPO, github.BRANCH = TARGET, 'main'
    path = Path('packages/X-SIGN.ipa')
    info = inspect_ipa(path, require_xsign=True)
    settings = json.loads((Path(os.environ['RUNNER_TEMP']) / 'xsign-build-settings.json').read_text())
    if settings.get('delivery') != 'everyone':
        raise ValueError('The Studio build request did not authorize public distribution.')
    if not info['buildRequestID'] or info['buildRequestID'] != settings.get('requestID'):
        raise ValueError('The IPA does not match the Studio build request.')
    if github.api('').get('private') is not False:
        raise ValueError('The app reads ipablack/repo directly. Publish to the configured public catalogue.')
    data = github.snapshot()['data']
    if not update_policy(data, info, ''):
        print('This IPA already matches the published update policy.')
        return
    publish_policy(info, publish_asset(path, info))
    print('Published the verified IPA and enabled the mandatory update.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        raise SystemExit('XSign update publication failed: ' + str(error)) from None
