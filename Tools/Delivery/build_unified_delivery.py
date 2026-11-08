"""Build the reviewed one-file updater and the complete, unified source export.

Run from any directory: python3 Tools/Delivery/build_unified_delivery.py --output DIR
Requires PyYAML in the packaging environment; the resulting workflow is self-contained.
"""
from pathlib import Path, PurePosixPath
import argparse
import base64
import hashlib
import json
import lzma
import subprocess
import stat
import textwrap
import zipfile
import yaml

ROOT = Path(__file__).resolve().parents[2]
ALLOWED = {'Feather', 'Feather.xcconfig', 'Feather.xcodeproj', 'Feather.xcworkspace', 'NimbleKit',
           'AltSourceKit', 'IDeviceKitten', 'Zsign', 'Tools', 'DomainBackend', 'Makefile', 'public', '.gitignore', 'firebase.json'}


def digest(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


def build(output):
    output.mkdir(parents=True, exist_ok=True)
    before = json.loads((ROOT / 'Tools/Delivery/reviewed-before-hashes.json').read_text())
    rows = []
    for name, known in sorted(before.items()):
        rel = PurePosixPath(name)
        if rel.is_absolute() or '..' in rel.parts or rel.parts[0] not in ALLOWED or str(rel) != name:
            raise ValueError('Unapproved payload path: ' + name)
        file = ROOT / name
        if any(p.is_symlink() for p in [file, *file.parents]):
            raise ValueError('Symlink blocks payload: ' + name)
        data = file.read_bytes() if file.is_file() else None
        binary = data is not None and file.suffix.lower() == '.png'
        row = {'path': name, 'before': known, 'after': digest(data),
               'text': base64.b64encode(data).decode('ascii') if binary else data.decode('utf-8') if data is not None else None}
        if binary:
            row['encoding'] = 'base64'
        rows.append(row)
    raw = json.dumps(rows, ensure_ascii=False, separators=(',', ':')).encode()
    # Base85 keeps the self-contained workflow inside the file-size budget.
    encoded = base64.b85encode(lzma.compress(raw, preset=6)).decode('ascii')
    installer = (ROOT / 'Tools/Restore_Reviewed_Base.py').read_text() + '\n' + '''from pathlib import Path,PurePosixPath
import base64,hashlib,json,os,subprocess,lzma
raw=lzma.decompress(base64.b85decode("""PAYLOAD"""),memlimit=67108864)
if hashlib.sha256(raw).hexdigest()!='DIGEST':raise SystemExit('Payload integrity failure')
rows=json.loads(raw);root=Path.cwd().resolve();ready=[];seen=set()
baseline=prepare_reviewed_base(root);restored=[];row_paths={r['path'] for r in rows}
for name,(data,mode) in baseline.items():
 target=root/name
 if any(p.is_symlink() for p in [target,*target.parents]):raise SystemExit('Symlink blocks recovery: '+name)
 if target.exists() and not target.is_file():raise SystemExit('Invalid recovery target: '+name)
 if name not in row_paths and not target.exists():restored.append((target,data,mode))
for row in rows:
 name=row['path'];rel=PurePosixPath(name)
 if name in seen or rel.is_absolute() or '..' in rel.parts or not rel.parts or str(rel)!=name or rel.parts[0] not in ALLOWED:
  raise SystemExit('Invalid update path')
 seen.add(name);target=root/name
 if any(p.is_symlink() for p in [target,*target.parents]):raise SystemExit('Symlink blocks update: '+name)
 if target.exists() and not target.is_file():raise SystemExit('Invalid target: '+name)
 encoding=row.get('encoding','utf-8')
 if encoding not in ['utf-8','base64']:raise SystemExit('Invalid payload encoding')
 data=(base64.b64decode(row['text'],validate=True) if encoding=='base64' else row['text'].encode()) if row['text'] is not None else None
 if (hashlib.sha256(data).hexdigest() if data is not None else None)!=row['after']:raise SystemExit('Invalid target digest')
 old=target.read_bytes() if target.exists() else baseline.get(name,(None,0))[0]
 current=hashlib.sha256(old).hexdigest() if old is not None else None
 if current==row['after']:continue
 if current not in row['before']:raise SystemExit('Existing source differs; no files were changed: '+name)
 ready.append((target,data))
for target,data,mode in restored:
 target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);target.chmod(mode)
for target,data in ready:
 if data is None:
  if target.exists():target.unlink()
 else:target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
stage=[r['path'] for r in rows if (root/r['path']).exists() or subprocess.run(['git','ls-files','--error-unmatch','--',r['path']],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0]
stage+= [str(target.relative_to(root)) for target,_,_ in restored]
(Path(os.environ['RUNNER_TEMP'])/'xsign-secure-local-signing-paths.nul').write_bytes(b''.join(n.encode()+b'\\0' for n in stage))
print('Applied',len(ready),'reviewed source updates and restored',len(restored),'missing base files. No workflow file, website deployment or credential was overwritten.')
'''.replace('DIGEST', digest(raw)).replace('ALLOWED', repr(sorted(ALLOWED)))
    source = installer.replace('PAYLOAD', encoded)
    (output / 'apply-reviewed-update.py').write_text(source)
    (output / 'reviewed-update.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
    workflow = json.loads((ROOT / 'Tools/Delivery/workflow.template.json').read_text())
    step = workflow['jobs']['preflight']['steps'][1]
    # GitHub evaluates expression openers even inside quoted env values.
    # A period is outside the Base85 alphabet and can safely stand in for '$'.
    chunks = textwrap.wrap(encoded.replace('$', '.'), 8192)
    step['env'] = {f'XSIGN_PAYLOAD_{i:03d}': chunk for i, chunk in enumerate(chunks)}
    step['run'] = ("python3 - <<'XSIGN_REVIEWED_UPDATE'\nimport os\nfrom pathlib import Path\n"
        + "encoded=''.join(os.environ['XSIGN_PAYLOAD_%03d'%i] for i in range(" + str(len(chunks)) + ")).replace('.', '$')\n"
        + 'installer_source=' + repr(installer) + "\ninstaller_source=installer_source.replace('PAYLOAD',encoded)\n"
        + "(Path(os.environ['RUNNER_TEMP'])/'apply-reviewed-update.py').write_text(installer_source)\n"
        + "exec(compile(installer_source,'reviewed-update','exec'))\nXSIGN_REVIEWED_UPDATE\n")

    class Dumper(yaml.SafeDumper):
        pass
    Dumper.add_representer(str, lambda d, s: d.represent_scalar('tag:yaml.org,2002:str', s, style='|' if '\n' in s else None))
    Dumper.ignore_aliases = lambda *args: True
    yml = output / 'XSign_Full_Link.yml'
    yml.write_text('# Canonical application workflow: .github/workflows/XSign_Full_Link.yml\n'
        '# XSign 1.0: native app, Studio, sources and publisher share one reviewed payload.\n'
        + yaml.dump(workflow, Dumper=Dumper, sort_keys=False, allow_unicode=True, width=120))
    assert yml.stat().st_size < 500_000, 'GitHub workflow file exceeds delivery limit'
    for job in workflow['jobs'].values():
        for entry in job['steps']:
            if 'run' in entry:
                assert len(entry['run']) <= 21_000, 'GitHub run step exceeds its size limit'
                subprocess.run(['bash', '-n'], input=entry['run'], text=True, check=True)
    guide = ROOT / 'Tools/Delivery/XSign_Unified_Guide_AR.md'
    (output / 'XSign_Control_Panel_Guide_AR.md').write_bytes(guide.read_bytes())
    tracked = set(json.loads((ROOT / 'Tools/Delivery/full-source-paths.json').read_text()))
    application = sorted(tracked | set(before))
    archive_path = output / 'XSign_Full_Link.zip'
    manifest = []
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, 9) as archive:
        def put(path, data, mode=0o644):
            assert path not in {r['path'] for r in manifest}, path
            info = zipfile.ZipInfo(path)
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
            manifest.append({'path': path, 'size': len(data), 'sha256': digest(data)})
        put(yml.name, yml.read_bytes())
        put('README_AR.md', guide.read_bytes())
        put('apply-reviewed-update.py', source.encode())
        hashes = [{k: v for k, v in row.items() if k != 'text'} for row in rows]
        put('reviewed-file-hashes.json', json.dumps(hashes, indent=2).encode())
        for name in application:
            if not name:
                continue
            file = ROOT / name
            if not file.is_file():
                continue
            if file.is_symlink() or any(p.is_symlink() for p in file.parents):
                raise ValueError('Symlink blocks source export: ' + name)
            if name.lower().endswith(('.p12', '.pfx', '.mobileprovision')):
                raise ValueError('Signing material must not be exported: ' + name)
            if name.startswith('.github/workflows/'):
                if name != '.github/workflows/XSign_Full_Link.yml':
                    put('Legacy_Reference/' + PurePosixPath(name).name + '.disabled', file.read_bytes(), file.stat().st_mode & 0o777)
                continue
            put('APPLICATION/' + name, file.read_bytes(), file.stat().st_mode & 0o777)
        put('APPLICATION/.github/workflows/XSign_Full_Link.yml', yml.read_bytes())
        put('CONTROL_PANEL/index.html', (ROOT / 'Tools/XSign_Studio.html').read_bytes())
        studio = ROOT / 'Tools/StudioSource'
        for file in sorted(studio.rglob('*')):
            if file.is_file() and not {'node_modules', 'dist', '__pycache__'}.intersection(file.relative_to(studio).parts):
                put('CONTROL_PANEL/StudioSource/' + file.relative_to(studio).as_posix(), file.read_bytes())
        put('SOURCE_REPOSITORY/.github/workflows/ipa_manager.yml', (ROOT / 'Tools/Delivery/ipa_manager.yml').read_bytes())
        put('SOURCE_REPOSITORY/repo.example.json', (ROOT / 'Tools/Delivery/repo.example.json').read_bytes())
        put('PROJECT_CONTRACT.json', (ROOT / 'Tools/Integration/contract.json').read_bytes())
        archive.writestr('PACKAGE_MANIFEST.json', json.dumps(manifest, ensure_ascii=False, indent=2))
    print(json.dumps({'reviewed_paths': len(rows), 'source_files': len(manifest),
        'workflow_bytes': yml.stat().st_size, 'zip_bytes': archive_path.stat().st_size,
        'payload_sha256': digest(raw)}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'packages/unified')
    build(parser.parse_args().output.resolve())
