"""Select an installed stable Xcode 26 toolchain instead of the image's default 16.4."""
from pathlib import Path
import os
import plistlib
import re
import subprocess


def stable_version(value):
    if not isinstance(value, str) or not re.fullmatch(r'26(?:\.[0-9]+){0,2}', value):
        return None
    return tuple(int(part) for part in value.split('.'))


def candidates(applications):
    found = {}
    for app in Path(applications).glob('Xcode*.app'):
        if re.search(r'beta|preview|release.?candidate|(?:^|[_ -])rc(?:[_ .-]|$)', app.name, re.I):
            continue
        try:
            resolved = app.resolve(strict=True)
            info = plistlib.loads((resolved / 'Contents/Info.plist').read_bytes())
            version = stable_version(info.get('CFBundleShortVersionString'))
            developer = resolved / 'Contents/Developer'
            if version and (developer / 'usr/bin/xcodebuild').is_file():
                found[developer] = version
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
    return sorted(found, key=lambda path: found[path], reverse=True)


def select_xcode(applications=Path('/Applications')):
    for developer in candidates(applications):
        env = dict(os.environ, DEVELOPER_DIR=str(developer))
        try:
            version = subprocess.check_output(
                ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], env=env,
                text=True, timeout=30, stderr=subprocess.STDOUT
            ).strip()
            if stable_version(version) is None:
                continue
            details = subprocess.check_output(
                ['xcodebuild', '-version'], env=env, text=True, timeout=30,
                stderr=subprocess.STDOUT
            ).strip()
        except (OSError, subprocess.SubprocessError):
            continue
        if not re.search(r'^Xcode 26(?:\.|$)', details, re.M):
            continue
        return developer, version, details
    raise SystemExit(
        'No usable stable Xcode 26 with an iOS 26 SDK is installed. '
        'Select the other supported Intel runner; Xcode 16.4 cannot compile the guarded iOS 26 UI.'
    )


def main():
    developer, sdk, details = select_xcode()
    if any(character in str(developer) for character in '\r\n'):
        raise SystemExit('Invalid developer directory')
    env_path = os.environ.get('GITHUB_ENV')
    if not env_path:
        raise SystemExit('GITHUB_ENV is required to persist the toolchain for later steps')
    with Path(env_path).open('a') as output:
        output.write(f'DEVELOPER_DIR={developer}\n')
    print(details)
    print(f'iPhoneOS SDK: {sdk}; deployment target remains iOS 15.0')
    print(f'DEVELOPER_DIR={developer}')


if __name__ == '__main__':
    main()
