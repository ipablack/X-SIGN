"""Stage the pinned IDevice archive before Xcode resolves binary packages."""
from pathlib import Path
import hashlib
import re
import subprocess
import tempfile
import time


PACKAGE = Path(__file__).resolve().parents[1] / 'IDeviceKitten'
ASSETS_API = 'https://api.github.com/repos/jkcoxson/idevice/releases/assets'


def read_pin(package):
    manifest = (package / 'Package.swift').read_text(encoding='utf-8')
    asset = re.search(r'^let ideviceAssetID = ([1-9][0-9]*)$', manifest, re.M)
    url = re.search(
        r'^let ideviceURL = "(https://github\.com/jkcoxson/idevice/releases/download/[^"/]+/IDevice\.xcframework\.zip)"$',
        manifest, re.M
    )
    checksum = re.search(r'^let ideviceChecksum = "([a-f0-9]{64})"$', manifest, re.M)
    if not (asset and url and checksum):
        raise SystemExit('error: IDevice pin is missing or invalid in IDeviceKitten/Package.swift.')
    return asset[1], url[1], checksum[1]


def sha256(path):
    checksum = hashlib.sha256()
    with path.open('rb') as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def download(url, destination):
    # A fresh request avoids reusing an expired, cached release redirect.
    subprocess.run([
        'curl', '--fail', '--silent', '--show-error', '--location',
        '--proto', '=https', '--proto-redir', '=https',
        '--connect-timeout', '15', '--max-time', '240', '--max-filesize', '314572800',
        '--header', 'Accept: application/octet-stream', '--user-agent', 'XSign-build',
        '--output', str(destination), f'{url}?xsign={time.time_ns()}',
    ], check=True)


def prepare(package=PACKAGE):
    asset_id, release_url, checksum = read_pin(package)
    destination = package / 'deps' / asset_id / 'IDevice.xcframework.zip'
    if destination.is_file() and sha256(destination) == checksum:
        print('Reusing verified IDevice archive.')
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    asset_url = f'{ASSETS_API}/{asset_id}'
    sources = [
        ('GitHub Releases asset API', asset_url),
        ('GitHub release download', release_url),
        ('GitHub Releases asset API retry', asset_url),
    ]
    with tempfile.TemporaryDirectory(prefix='.download-', dir=destination.parent) as directory:
        candidate = Path(directory) / 'IDevice.xcframework.zip'
        for label, url in sources:
            print(f'Fetching pinned IDevice archive from {label}.', flush=True)
            try:
                download(url, candidate)
            except subprocess.CalledProcessError as error:
                print(f'{label} download failed (curl {error.returncode}).', flush=True)
            else:
                if sha256(candidate) == checksum:
                    candidate.replace(destination)
                    print('Verified and staged IDevice archive.')
                    return
                print(f'{label} returned data with the wrong SHA-256.', flush=True)
            candidate.unlink(missing_ok=True)
    raise SystemExit('error: Could not download and verify the pinned IDevice archive from GitHub.')


if __name__ == '__main__':
    prepare()
