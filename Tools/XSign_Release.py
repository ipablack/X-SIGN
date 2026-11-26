"""Validate Studio's release settings and inspect the exact bytes of an XSign IPA."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
from pathlib import Path
from urllib.parse import quote, urlsplit, unquote
import zipfile

from Delivery.ipa_publisher import MAX_IPA, download, read_member


DEFAULT_NAME = 'Xsign'
DEFAULT_BUNDLE = 'Xsign'
LEGACY_BUNDLE = 'com.ipablack.xsign'
DEFAULT_VERSION = '1.0'
STUDIO_BUILD_SCHEMA = 1
STUDIO_BUILD_FILE = Path('xsign-build.json')
MAX_STUDIO_FILE = 16 * 1024
ICON = Path('Feather/Resources/Assets.xcassets/AppIcon.appiconset/xsign.png')
ICON_COMPOSER = Path('Feather/Resources/AppIcon.icon')
MAX_SOURCE_ICON = 8 * 1024 * 1024
MACHO_HEADERS = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                 b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def checked_url(value, label):
    if not isinstance(value, str) or len(value) > 2048 or re.search(r'[\s\\\x00-\x1f\x7f]', value) or '#' in value:
        raise ValueError(f'{label} needs a direct HTTPS URL without spaces or a fragment.')
    url = urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username is not None or url.password is not None or url.port not in (None, 443):
        raise ValueError(f'{label} needs a public HTTPS URL without credentials.')
    return value


def version(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9]{1,9}(?:\.[0-9]{1,9}){0,2}', value)


def read_settings(raw, run_number):
    if not isinstance(raw, dict) or set(raw) - {'appName', 'bundleIdentifier', 'version', 'buildVersion', 'iconURL', 'manifestURL', 'catalogOrigin', 'delivery'}:
        raise ValueError('Invalid Studio settings. Load the current Studio and send a new build.')
    if not all(isinstance(value, str) for value in raw.values()):
        raise ValueError('Studio build settings must be strings.')
    delivery = raw.get('delivery', 'private')
    if delivery not in ('private', 'release', 'everyone'):
        raise ValueError('Select private, release or everyone in the Studio build request.')
    settings = {
        'appName': raw.get('appName', DEFAULT_NAME), 'bundleIdentifier': raw.get('bundleIdentifier', DEFAULT_BUNDLE),
        'version': raw.get('version', DEFAULT_VERSION), 'buildVersion': raw.get('buildVersion', str(run_number)),
        'iconURL': raw.get('iconURL', ''), 'manifestURL': raw.get('manifestURL', ''),
        'delivery': delivery,
    }
    name = settings['appName']
    bundle = settings['bundleIdentifier']
    build = settings['buildVersion']
    if not name or name != name.strip() or len(name) > 64 or re.search(r'[\x00-\x1f\x7f$]', name):
        raise ValueError('App name needs 1–64 printable characters, without a dollar sign.')
    if len(bundle) > 155 or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*', bundle):
        raise ValueError('Bundle ID needs letters, digits, hyphens and optional dots, such as Xsign.')
    if not version(settings['version']):
        raise ValueError('App version needs up to three numeric components, such as 1.0.')
    if not version(build) or not any(int(part) for part in build.split('.')):
        raise ValueError('Build needs a positive number such as 14 or 14.1.')
    for key, label in [('iconURL', 'App icon'), ('manifestURL', 'Signed manifest')]:
        if settings[key]:
            checked_url(settings[key], label)
    settings['releaseOrigin'] = hashlib.sha256(settings['manifestURL'].encode()).hexdigest() if settings['manifestURL'] else ''
    return settings


def read_studio_settings(path, run_number):
    if path.is_symlink():
        raise ValueError(f'Expected a regular Studio file at {path.name}.')
    try:
        with path.open('rb') as source:
            data = source.read(MAX_STUDIO_FILE + 1)
    except FileNotFoundError:
        print('No saved Studio settings. Using the default Xsign identity and this run number.')
        return read_settings({}, run_number)
    if len(data) > MAX_STUDIO_FILE:
        raise ValueError(f'{path.name} exceeds the limit for Studio requests.')
    try:
        value = json.loads(data.decode('utf-8-sig'))
    except (ValueError, UnicodeError):
        raise ValueError(f'{path.name} is not valid UTF-8 JSON. Save the settings again in Studio.') from None
    if not isinstance(value, dict) or type(value.get('schema_version')) is not int or value['schema_version'] != STUDIO_BUILD_SCHEMA:
        raise ValueError(f'{path.name} uses an unsupported Studio settings format.')
    if set(value) != {'schema_version', 'request_id', 'settings'} or not valid_request_id(value['request_id']):
        raise ValueError('Invalid build request in xsign-build.json. Save the settings again in Studio.')
    settings = value['settings']
    if not isinstance(settings, dict) or not {'appName', 'bundleIdentifier', 'version'} <= settings.keys():
        raise ValueError('Saved Studio settings need an app name, Bundle ID and version.')
    return {**read_settings(settings, run_number), 'requestID': value['request_id']}


def valid_request_id(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{32}', value) is not None


def read_inspection_event(event_path):
    event = json.loads(event_path.read_text())
    payload = event.get('client_payload', {})
    if not isinstance(payload, dict) or set(payload) != {'request_id', 'ipa_url'} or not valid_request_id(payload['request_id']):
        raise ValueError('Invalid inspection request. Send a direct IPA link from X-SIGN STUDIO.')
    return payload['request_id'], checked_url(payload['ipa_url'], 'IPA')


def private_release_parts(url, repository):
    parsed = urlsplit(url)
    parts = [unquote(part) for part in parsed.path.split('/')[1:]]
    if (parsed.hostname != 'github.com' or parsed.query or parsed.fragment or len(parts) != 6 or
            '/'.join(parts[:2]).lower() != repository.lower() or parts[2:4] != ['releases', 'download'] or
            not re.fullmatch(r'[A-Za-z0-9._-]+', parts[4]) or
            not re.fullmatch(r'[A-Za-z0-9._-]+\.ipa', parts[5], flags=re.I)):
        return None
    return parts[4], parts[5]


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def download_private_release(parts, repository, token, target):
    if not re.fullmatch(r'[A-Za-z0-9-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Set XSIGN_CATALOG_REPOSITORY to owner/repo for private releases.')
    api = 'https://api.github.com/repos/' + repository
    headers = {'Authorization': 'Bearer ' + token, 'User-Agent': 'Xsign-Release-Check',
               'Accept': 'application/vnd.github+json'}
    direct = build_opener(NoRedirect())
    tag, filename = parts
    with direct.open(Request(api, headers=headers), timeout=30) as storage:
        if json.load(storage).get('private') is not True:
            raise ValueError('Protected releases must be hosted in a private repository.')
    with direct.open(Request(api + '/releases/tags/' + quote(tag, safe=''), headers=headers), timeout=30) as release:
        record = json.load(release)
    asset = next((item for item in record.get('assets', []) if item.get('name') == filename and item.get('state') == 'uploaded'), None)
    if (record.get('draft') is not False or not asset or type(asset.get('id')) is not int or asset['id'] <= 0 or
            type(asset.get('size')) is not int):
        raise ValueError('The private release asset is unavailable or remains a draft.')
    size = asset['size']
    if not 0 < size <= MAX_IPA:
        raise ValueError('The private IPA asset is outside the allowed size.')
    endpoint = api + '/releases/assets/' + str(asset['id'])
    try:
        response = direct.open(Request(endpoint, headers={**headers, 'Accept': 'application/octet-stream'}), timeout=90)
    except HTTPError as error:
        if error.code != 302:
            raise
        location = urlsplit(error.headers.get('Location', ''))
        error.close()
        if location.scheme != 'https' or location.netloc != 'release-assets.githubusercontent.com' or location.fragment:
            raise ValueError('GitHub returned an unexpected asset location.')
        response = direct.open(Request(location.geturl()), timeout=90)
    with response, target.open('wb') as output:
        remaining = size
        while block := response.read(min(remaining + 1, 1024 * 1024)):
            remaining -= len(block)
            if remaining < 0:
                raise ValueError('The private IPA exceeds its declared size.')
            output.write(block)
        if remaining != 0:
            raise ValueError('The private IPA is incomplete.')
    with target.open('rb') as stream:
        sha256 = hashlib.file_digest(stream, 'sha256').hexdigest()
    if asset.get('digest') != 'sha256:' + sha256:
        raise ValueError('GitHub’s private release asset digest does not match the downloaded IPA.')


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def finalize_info(path, settings):
    """Apply Studio presentation fields after Xcode generates plist defaults, before signing."""
    with path.open('rb') as source:
        info = plistlib.load(source)
    for key, field in [('CFBundleIdentifier', 'bundleIdentifier'),
                       ('CFBundleShortVersionString', 'version'), ('CFBundleVersion', 'buildVersion')]:
        if info.get(key) != settings[field]:
            raise ValueError(f'Xcode produced an unexpected {key}. Check the Studio build settings.')
    for key in ('CFBundleName', 'CFBundleDisplayName'):
        info[key] = settings['appName']
    info['XSignStudioBuildRequest'] = settings.get('requestID', '')
    info['XSignReleaseOrigin'] = settings.get('releaseOrigin', '')
    info['XSignStudioRelease'] = True
    # The native XSign splash begins after the system launches this empty storyboard substitute.
    info['UILaunchScreen'] = {}
    info.pop('UILaunchStoryboardName', None)
    info.pop('UILaunchStoryboards', None)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.xsign-plist-', delete=False) as target:
        replacement = Path(target.name)
        try:
            plistlib.dump(info, target, fmt=plistlib.FMT_BINARY)
            target.close()
            replacement.chmod(0o644)
            replacement.replace(path)
        finally:
            replacement.unlink(missing_ok=True)


def inspect_ipa(path, require_xsign=False):
    if not 0 < path.stat().st_size <= MAX_IPA:
        raise ValueError('The IPA is empty or exceeds 1800 MiB.')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        infos = [name for name in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
        if len(infos) != 1 or len(names) != len(set(names)) or len(names) > 100_000:
            raise ValueError('An IPA must contain one app Info.plist and unique entries.')
        info = plistlib.loads(read_member(archive, infos[0], 2 * 1024 * 1024))
        if not isinstance(info, dict):
            raise ValueError('The app Info.plist must be a dictionary.')
        app = infos[0].removesuffix('Info.plist')
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or not executable or '/' in executable or '\\' in executable:
            raise ValueError('The IPA has no valid app executable name.')
        binary = archive.getinfo(app + executable)
        with archive.open(binary) as stream:
            if stream.read(4) not in MACHO_HEADERS:
                raise ValueError('The IPA executable is not a 64-bit Mach-O binary.')
        if binary.file_size < 4096:
            raise ValueError('The IPA executable is incomplete.')
        name = info.get('CFBundleDisplayName') or info.get('CFBundleName')
        release = read_settings({'appName': name, 'bundleIdentifier': info.get('CFBundleIdentifier'),
                                 'version': info.get('CFBundleShortVersionString'), 'buildVersion': info.get('CFBundleVersion')}, 1)
        marker = info.get('XSignStudioRelease') is True or 'XSignReleaseOrigin' in info or (
            release['bundleIdentifier'].lower() == LEGACY_BUNDLE and
            any('xsign' in item.get('CFBundleURLSchemes', []) for item in info.get('CFBundleURLTypes', []) if isinstance(item, dict)))
        if require_xsign:
            if info.get('UIFileSharingEnabled') is True or any(n.lower().endswith(('.p12', '.ipa')) for n in names):
                raise ValueError('Unexpected file sharing or private archive in the built IPA.')
            if info.get('XSignStudioRelease') is not True or app + 'XSignInstall.html' in names:
                raise ValueError('The built IPA has unexpected update metadata or an obsolete installation resource.')
            if info.get('CFBundleName') != name:
                raise ValueError('The bundle name and app display name do not match the build settings.')
            minimum = info.get('MinimumOSVersion')
            if not version(minimum) or tuple(int(x) for x in (minimum.split('.') + ['0', '0'])[:3]) > (15, 0, 0):
                raise ValueError('The IPA no longer supports iOS 15.')
            primary = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
            if not (primary.get('CFBundleIconName') == 'AppIcon' or primary.get('CFBundleIconFiles')):
                raise ValueError('The built IPA has no primary icon.')
            if archive.testzip() is not None:
                raise ValueError('The built IPA failed its ZIP integrity check.')
            check_bundle_privacy(archive)
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {**{key: release[key] for key in ('appName', 'bundleIdentifier', 'version', 'buildVersion')},
            'sha256': digest, 'size': path.stat().st_size, 'isXSign': marker,
            'releaseOrigin': info.get('XSignReleaseOrigin') or '', 'buildRequestID': info.get('XSignStudioBuildRequest') or ''}


URL_TEXT = re.compile(rb'https?://[^\x00-\x20\x7f"<>\\]+', re.I)
UTF16_CODE_UNITS = (re.compile(rb'(?:[\x20-\x7e]\x00){10,}'), re.compile(rb'(?:\x00[\x20-\x7e]){10,}'))
GITHUB_CREDENTIAL = re.compile(rb'(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{82})(?![A-Za-z0-9_])')
PRIVATE_KEY = re.compile(rb'-----BEGIN (?:ENCRYPTED |RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----[ \r\n]+[A-Za-z0-9+/]{40}')
SOURCE_HOSTS = {
    'appiraq.com', 'vip.appiraq.com', 'supapi.trystore.net',
    'repo.ucerts.io', 'repository.apptesters.org', 'appstore.nabzclan.vip', 'file.ipaomtk.com',
}
PRIVATE_FILENAMES = {'xsignsoonlaunchpreview.json', 'xsigncatalogreference.json', 'repo.json', 'xsign-config.json', 'ipasoon.json'}
NO_SIGNING_FILES = {'.p12', '.pfx', '.mobileprovision', '.pem', '.key', '.entitlements', '.ipa', '.tipa'}


def check_bundle_privacy(archive):
    for member in archive.infolist():
        name = Path(member.filename)
        if member.is_dir():
            continue
        if name.name.lower() in PRIVATE_FILENAMES or name.suffix.lower() in NO_SIGNING_FILES or '.dsym' in member.filename.lower():
            raise ValueError(f'Release privacy check rejected bundled catalogue or signing data: {name.name}.')
        with archive.open(member) as stream:
            remainder = b''
            while block := stream.read(1024 * 1024):
                sample = remainder + block
                samples = [sample]
                for pattern in UTF16_CODE_UNITS:
                    samples.extend(run.group().replace(b'\0', b'') for run in pattern.finditer(sample))
                for decoded in samples:
                    if GITHUB_CREDENTIAL.search(decoded) or PRIVATE_KEY.search(decoded):
                        raise ValueError(f'Release privacy check found an embedded credential in {name.name}.')
                    for match in URL_TEXT.finditer(decoded.replace(b'\\/', b'/')):
                        value = match.group()[:4096].decode('ascii', errors='ignore')
                        try:
                            url = urlsplit(value)
                            host = url.hostname or ''
                        except ValueError:
                            continue
                        if url.username and url.password is not None:
                            raise ValueError(f'Release privacy check found an embedded credential in {name.name}.')
                        path = unquote(url.path)
                        if (host in SOURCE_HOSTS or any(host.endswith('.' + tail) for tail in ('appiraq.com', 'ipaomtk.com')) or
                                re.search(r'\.(?:ipa|tipa)(?:$|[^A-Za-z0-9_])', path, re.I) or
                                re.search(r'/(?:repo|xsign-config|ipasoon)\.json(?:$|[^A-Za-z0-9_])', path, re.I)):
                            raise ValueError(f'Release privacy check found an embedded source or IPA URL in {name.name}.')
                remainder = sample[-8192:]


def prepare_icon(settings, destination):
    url = settings['iconURL']
    if not url:
        return
    from PIL import Image, UnidentifiedImageError

    with tempfile.TemporaryDirectory() as directory:
        incoming = Path(directory) / 'input.png'
        download(url, incoming, MAX_SOURCE_ICON)
        try:
            with Image.open(incoming, formats=('PNG',)) as image:
                if getattr(image, 'n_frames', 1) != 1 or not 64 <= image.width == image.height <= 4096:
                    raise ValueError('Use a still square PNG between 64×64 and 4096×4096 for the app icon.')
                rgba = image.convert('RGBA').resize((1024, 1024), Image.Resampling.LANCZOS)
                background = Image.new('RGBA', rgba.size, (0, 0, 0, 255))
                normalized = Image.alpha_composite(background, rgba).convert('RGB')
        except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as error:
            raise ValueError('The icon URL must download a readable square PNG image.') from error
        normalized.save(destination, format='PNG', optimize=True)
    settings['iconSHA256'] = hashlib.sha256(destination.read_bytes()).hexdigest()


@contextmanager
def build_icon(data, work, icon=ICON, composer=ICON_COMPOSER):
    original = icon.read_bytes() if data is not None else None
    with tempfile.TemporaryDirectory(dir=work) as directory:
        backup = Path(directory) / 'AppIcon.icon'
        try:
            if data is not None:
                icon.write_bytes(data)
            # Xcode 26 gives an Icon Composer file precedence over the PNG catalog.
            if composer.is_dir():
                shutil.move(composer, backup)
            yield
        finally:
            if original is not None:
                icon.write_bytes(original)
            if backup.exists():
                shutil.move(backup, composer)


def build_ipa(settings, package, work):
    env = dict(os.environ, XSIGN_APP_NAME=settings['appName'], XSIGN_BUNDLE_ID=settings['bundleIdentifier'],
               XSIGN_APP_VERSION=settings['version'], XSIGN_BUILD_NUMBER=settings['buildVersion'],
               XSIGN_RELEASE_ORIGIN=settings['releaseOrigin'], XSIGN_STUDIO_BUILD_REQUEST=settings.get('requestID', ''),
               XSIGN_RESULT_BUNDLE=str(work / 'xsign-build.xcresult'))
    icon = None
    if settings['iconURL']:
        icon_path = work / 'xsign-build-icon.png'
        if not icon_path.is_file() or not 0 < icon_path.stat().st_size <= MAX_SOURCE_ICON:
            raise ValueError('The prepared icon is missing or too large. Re-run the Studio preflight.')
        icon = icon_path.read_bytes()
        if hashlib.sha256(icon).hexdigest() != settings.get('iconSHA256'):
            raise ValueError('The prepared icon does not match this Studio build request.')
    package.unlink(missing_ok=True)
    with build_icon(icon, work):
        subprocess.run(['make'], env=env, check=True)
    print('Verifying the packaged IPA identity, icon and bundled resources.', flush=True)
    info = inspect_ipa(package, require_xsign=True)
    with zipfile.ZipFile(package) as archive:
        templates = [name for name in archive.namelist() if
                     re.fullmatch(r'Payload/[^/]+\.app/XSignUpdateScreen\.html', name)]
        expected = Path('Feather/Resources/XSignUpdateScreen.html').read_bytes()
        if len(templates) != 1 or archive.read(templates[0]) != expected:
            raise ValueError('The verified IPA is missing the Studio installation template.')
    for key in ('appName', 'bundleIdentifier', 'version', 'buildVersion', 'releaseOrigin'):
        if info[key] != settings[key]:
            raise ValueError(f'Built IPA {key} does not match the Studio build request.')
    if info['buildRequestID'] != settings.get('requestID', ''):
        raise ValueError('Built IPA does not carry this Studio request ID.')
    return info


def report_failure(work, summary):
    diagnostics = []
    fallback = []
    for log in sorted(work.glob('xsign-local-*.log')):
        with log.open(errors='replace') as lines:
            for entry in lines:
                line = entry.strip()
                if not re.search(r'(^|:\s*)error:|Precondition failed|Fatal error:|XSign release error:|No usable stable Xcode|\*\* BUILD FAILED \*\*', line, re.I):
                    continue
                line = re.sub(r'^.*?/work/[^/]+/[^/]+/', '', line)[:750]
                wrapper = line == '** BUILD FAILED **' or "Command '['make']'" in line
                target = fallback if wrapper else diagnostics
                if line not in target and len(target) < 15:
                    target.append(line)
        if len(diagnostics) >= 15:
            break
    with summary.open('a') as output:
        output.write('## XSign build or verification failed\n\n')
        for item in diagnostics or fallback:
            output.write('    ' + item + '\n')
        output.write('\nOpen the failing step or download its logs artifact for the full diagnostics and any Xcode result bundle.\n')
    first = (diagnostics or fallback)[:5]
    for index, item in enumerate(first):
        title = 'XSign build cause' if index == 0 else 'XSign build'
        print(f'::error title={title}::' + item.replace('%', '%25'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    validate = commands.add_parser('validate')
    validate.add_argument('output', type=Path)
    validate.add_argument('--studio-file', type=Path, default=STUDIO_BUILD_FILE)
    build = commands.add_parser('build')
    build.add_argument('settings', type=Path)
    finalize = commands.add_parser('finalize-info')
    finalize.add_argument('info', type=Path)
    commands.add_parser('report-failure')
    inspection = commands.add_parser('inspect')
    inspection.add_argument('output', type=Path)
    inspection.add_argument('--event-file', type=Path)
    args = parser.parse_args()
    if args.command == 'validate':
        settings = read_studio_settings(args.studio_file, os.environ.get('GITHUB_RUN_NUMBER', '1'))
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            everyone = settings['delivery'] == 'everyone' and os.environ.get('GITHUB_EVENT_NAME') == 'push'
            public_release = settings['delivery'] == 'release' or everyone
            owner_draft = not public_release and os.environ.get('XSIGN_BUILD_REPO_PRIVATE') != 'true'
            if everyone and os.environ.get('XSIGN_RELEASE_PUBLISH_READY') != 'true':
                raise ValueError('Set XSIGN_RELEASE_PUBLISH_TOKEN before building for all users.')
            with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
                output.write(f'publish={str(everyone).lower()}\nowner_draft={str(owner_draft).lower()}\npublic_release={str(public_release).lower()}\n')
        prepare_icon(settings, args.output.with_name('xsign-build-icon.png'))
        write_json(args.output, settings)
        print(f"Validated Studio build {settings['version']} ({settings['buildVersion']}) for {settings['bundleIdentifier']}.")
    elif args.command == 'report-failure':
        report_failure(Path(os.environ['RUNNER_TEMP']), Path(os.environ['GITHUB_STEP_SUMMARY']))
    elif args.command == 'finalize-info':
        keys = {'appName': 'XSIGN_APP_NAME', 'bundleIdentifier': 'XSIGN_BUNDLE_ID',
                'version': 'XSIGN_APP_VERSION', 'buildVersion': 'XSIGN_BUILD_NUMBER'}
        settings = read_settings({key: os.environ[value] for key, value in keys.items()}, '1')
        settings.update(requestID=os.environ['XSIGN_STUDIO_BUILD_REQUEST'],
                        releaseOrigin=os.environ['XSIGN_RELEASE_ORIGIN'])
        finalize_info(args.info, settings)
        print(f"Packaged app name: {settings['appName']}")
    elif args.command == 'build':
        settings = json.loads(args.settings.read_text())
        package = Path('packages/X-SIGN.ipa')
        work = Path(os.environ['RUNNER_TEMP'])
        print(f"Building {settings['bundleIdentifier']} {settings['version']} ({settings['buildVersion']}).", flush=True)
        info = build_ipa(settings, package, work)
        write_json(package.with_name('info.json'), info)
        details = '\n'.join([
            f"App: {info['appName']}", f"Bundle ID: {info['bundleIdentifier']}", f"Version: {info['version']}",
            f"Build: {info['buildVersion']}", f"IPA SHA-256: {info['sha256']}",
            f"Studio request: {info['buildRequestID'] or 'default build'}",
            f"Custom icon SHA-256: {settings.get('iconSHA256', 'default icon')}",
            f"Checkout: {os.environ['GITHUB_SHA']}",
            f"Original interface: {os.environ['XSIGN_ORIGINAL_UI']}",
            f"Workflow run: {os.environ['GITHUB_RUN_NUMBER']} (attempt {os.environ['GITHUB_RUN_ATTEMPT']})",
            'Xcode and the IPA archive passed verification. Physical installation requires a compatible iOS signature.',
        ]) + '\n'
        package.with_name('BUILD_MODE.txt').write_text(details)
        print(details)
    else:
        request_id, url = read_inspection_event(args.event_file or Path(os.environ['GITHUB_EVENT_PATH']))
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / 'candidate.ipa'
            repository = os.environ.get('XSIGN_CATALOG_REPOSITORY', '') or 'ipablack/repo'
            token = os.environ.get('XSIGN_CATALOG_GITHUB_TOKEN', '')
            parts = private_release_parts(url, repository)
            if parts and token:
                try:
                    download_private_release(parts, repository, token, package)
                except HTTPError as error:
                    error.close()
                    raise ValueError(f'Private GitHub Release returned HTTP {error.code}. Check the Releases asset, repository secret, and its Contents: read access.') from None
            else:
                download(url, package, MAX_IPA)
            info = inspect_ipa(package)
        write_json(args.output, {**info, 'requestID': request_id, 'requestDigest': hashlib.sha256(url.encode()).hexdigest()})
        print(f"Inspected {info['bundleIdentifier']} {info['version']} ({info['buildVersion']}).")


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        # Network exceptions can contain the input URL. Keep the log free of signed query strings.
        message = str(error) if isinstance(error, (ValueError, subprocess.CalledProcessError)) else type(error).__name__
        if isinstance(error, HTTPError):
            message = f'The download returned HTTP {error.code}. Use a direct HTTPS link accessible to the runner.'
        elif isinstance(error, (URLError, socket.gaierror)):
            message = 'The runner could not reach the download URL.'
        sys.exit('XSign release error: ' + message.replace('\n', ' ')[:500])
