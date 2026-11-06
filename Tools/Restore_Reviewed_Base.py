"""Prepare missing XSign base files from a pinned public commit, without writing the app repo."""
from pathlib import Path, PurePosixPath
import os
import subprocess
import tarfile
import tempfile

XSIGN_BASE_COMMIT = '84bb3b8f22ac07b963a5a4ef8ad38f3e44bb8ca8'
XSIGN_BASE_REPOSITORY = 'https://github.com/ipablack/X-SIGN.git'
XSIGN_BASE_MARKERS = ('Feather/FeatherApp.swift', 'Feather.xcodeproj/project.pbxproj',
                      'Feather.xcworkspace/contents.xcworkspacedata', 'NimbleKit/Package.swift')


def prepare_reviewed_base(root):
    if all((root / name).is_file() for name in XSIGN_BASE_MARKERS):
        return {}
    if os.environ.get('GITHUB_REPOSITORY', '').lower() == 'ipablack/repo':
        raise SystemExit('Run the application workflow in X-SIGN, not in the catalogue repository; no files were changed.')
    temporary = Path(os.environ['RUNNER_TEMP'])
    with tempfile.TemporaryDirectory(prefix='xsign-base-', dir=temporary) as folder:
        folder = Path(folder)
        cache = os.environ.get('XSIGN_BASE_CACHE')
        repository = Path(cache) if cache else folder / 'public.git'
        if not cache:
            subprocess.run(['git', 'init', '--bare', '-q', str(repository)], check=True)
            subprocess.run(['git', '-C', str(repository), 'fetch', '--quiet', '--depth', '1',
                            XSIGN_BASE_REPOSITORY, XSIGN_BASE_COMMIT], check=True)
        actual = subprocess.check_output(['git', '-C', str(repository), 'rev-parse',
                                          XSIGN_BASE_COMMIT + '^{commit}'], text=True).strip()
        if actual != XSIGN_BASE_COMMIT:
            raise SystemExit('The recovery commit does not match the reviewed source.')
        archive = folder / 'reviewed.tar'
        with archive.open('wb') as output:
            subprocess.run(['git', '-C', str(repository), 'archive', '--format=tar', XSIGN_BASE_COMMIT],
                           stdout=output, check=True)
        result, size = {}, 0
        with tarfile.open(archive) as source:
            for item in source:
                if item.isdir():
                    continue
                rel = PurePosixPath(item.name)
                if rel.is_absolute() or '..' in rel.parts or not rel.parts or rel.parts[0] == '.git' or not item.isfile():
                    raise SystemExit('An unsafe entry blocked source recovery.')
                # Keep the current workflow; old automatic patchers must not be restored.
                if rel.parts[:2] == ('.github', 'workflows'):
                    continue
                size += item.size
                if item.size < 0 or size > 134_217_728:
                    raise SystemExit('The recovery archive exceeds its reviewed size limit.')
                stream = source.extractfile(item)
                if stream is None:
                    raise SystemExit('A reviewed source file could not be read.')
                data = stream.read(item.size + 1)
                if len(data) != item.size:
                    raise SystemExit('An incomplete archive blocked source recovery.')
                result[str(rel)] = (data, item.mode & 0o777)
        if not all(name in result for name in XSIGN_BASE_MARKERS):
            raise SystemExit('The pinned archive does not contain the complete application base.')
        return result
