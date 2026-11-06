"""X-SIGN IPA metadata/release publisher. Standard library only; never runs IPA code."""
import base64, copy, hashlib, html, ipaddress, json, os, plistlib, re, socket, struct
import subprocess, sys, urllib.parse, urllib.request, zipfile, zlib
from pathlib import Path

MAX_IPA = 1800 * 1024 * 1024
MAX_ICON = 5 * 1024 * 1024
REPO = os.environ.get('GITHUB_REPOSITORY', '')
BRANCH = os.environ.get('TARGET_BRANCH', 'main')
WORK = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'xsign-ipa-publisher'


def gh(*args, data=None):
    result = subprocess.run(['gh', *args], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    if result.returncode:
        error = RuntimeError('GitHub request failed: ' + result.stderr.strip()[-1500:])
        error.conflict = bool(re.search(r'HTTP (409|422)', result.stderr))
        raise error
    return result.stdout


def api(path, method='GET', payload=None, optional=False):
    args = ['api', '--method', method, '-H', 'Accept: application/vnd.github+json',
            '-H', 'X-GitHub-Api-Version: 2022-11-28', 'repos/' + REPO + ('/' + path if path else '')]
    if payload is not None:
        args += ['--input', '-']
    try:
        value = gh(*args, data=json.dumps(payload) if payload is not None else None)
        return json.loads(value) if value.strip() else None
    except RuntimeError as error:
        if optional and 'HTTP 404' in str(error):
            return None
        raise


def public_https(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError('Download URL must be HTTPS without embedded credentials.')
    if parsed.port not in (None, 443):
        raise ValueError('Only the standard HTTPS port is supported.')
    addresses = socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(row[4][0]).is_global for row in addresses):
        raise ValueError('Local and private network download addresses are not supported.')
    return url


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return super().redirect_request(request, fp, code, msg, headers, public_https(newurl))


def download(url, target, maximum):
    opener = urllib.request.build_opener(HTTPSRedirect())
    request = urllib.request.Request(public_https(url), headers={'User-Agent': 'X-SIGN-IPA-Publisher/1.0'})
    size = 0
    # This request deliberately has no GitHub authorization header.
    with opener.open(request, timeout=90) as response, target.open('wb') as output:
        length = response.headers.get('Content-Length')
        if length and int(length) > maximum:
            raise ValueError('Download exceeds the allowed size.')
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > maximum:
                raise ValueError('Download exceeds the allowed size.')
            output.write(chunk)
    if not size:
        raise ValueError('Downloaded file is empty.')


def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)


def web_png(data):
    """Restore common iOS CgBI RGBA icons to ordinary, browser-readable PNG."""
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Not PNG.')
    offset, records = 8, []
    while offset + 12 <= len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        if size > MAX_ICON or offset + size + 12 > len(data):
            raise ValueError('Invalid PNG chunk.')
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + size]
        if zlib.crc32(kind + payload) & 0xffffffff != struct.unpack('>I', data[offset + 8 + size:offset + 12 + size])[0]:
            raise ValueError('Invalid PNG checksum.')
        records.append((kind, payload)); offset += size + 12
        if kind == b'IEND':
            break
    header = next((p for k, p in records if k == b'IHDR'), None)
    if header is None or len(header) != 13 or not any(k == b'IEND' for k, _ in records):
        raise ValueError('PNG is incomplete.')
    width, height, depth, mode, comp, filtering, interlace = struct.unpack('>IIBBBBB', header)
    if not 0 < width <= 4096 or not 0 < height <= 4096:
        raise ValueError('Icon dimensions exceed the supported limit.')
    if not any(k == b'CgBI' for k, _ in records):
        return data, width * height
    if (depth, mode, comp, filtering, interlace) != (8, 6, 0, 0, 0):
        raise ValueError('This optimized iOS icon needs a manual PNG/JPEG/WebP icon.')
    stride, expected = width * 4, (width * 4 + 1) * height
    decoder = zlib.decompressobj(-15)
    raw = decoder.decompress(b''.join(p for k, p in records if k == b'IDAT'), expected + 1)
    if len(raw) != expected or not decoder.eof or decoder.unconsumed_tail:
        raise ValueError('Invalid optimized PNG image data.')
    previous = bytearray(stride); restored = bytearray()
    for y in range(height):
        start = y * (stride + 1); mode = raw[start]; row = bytearray(raw[start + 1:start + 1 + stride])
        if mode not in range(5):
            raise ValueError('Unsupported PNG filter.')
        for x in range(stride):
            a = row[x - 4] if x >= 4 else 0; b = previous[x]; c = previous[x - 4] if x >= 4 else 0
            if mode == 1: predictor = a
            elif mode == 2: predictor = b
            elif mode == 3: predictor = (a + b) // 2
            elif mode == 4:
                p = a + b - c; distances = [abs(p - a), abs(p - b), abs(p - c)]
                predictor = [a, b, c][distances.index(min(distances))]
            else: predictor = 0
            row[x] = (row[x] + predictor) & 255
        previous = row[:]; restored.append(0)
        for x in range(0, stride, 4):
            blue, green, red, alpha = row[x:x + 4]
            rgba = [min(255, (v * 255 + alpha // 2) // alpha) if alpha else 0 for v in [red, green, blue]]
            restored.extend([*rgba, alpha])
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(restored)) + chunk(b'IEND', b''), width * height


def read_member(archive, name, limit):
    if archive.getinfo(name).file_size > limit:
        raise ValueError('Archive metadata or icon is too large.')
    with archive.open(name) as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Archive member exceeds its limit.')
    return data


def inspect_ipa(path, metadata, output):
    if not 0 < path.stat().st_size <= MAX_IPA:
        raise ValueError('IPA must be nonempty and below 1800 MiB.')
    with path.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) > 100000:
            raise ValueError('IPA contains too many entries.')
        main = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        if len(main) != 1:
            raise ValueError('IPA needs exactly one main Payload/*.app/Info.plist.')
        info = plistlib.loads(read_member(archive, main[0], 2 * 1024 * 1024))
        if not isinstance(info, dict):
            raise ValueError('Info.plist is not a dictionary.')
        bundle = str(info.get('CFBundleIdentifier', '')).strip()
        if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
            raise ValueError('IPA has no valid, real Bundle ID.')
        version = str(info.get('CFBundleShortVersionString') or info.get('CFBundleVersion') or '').strip()
        if not version:
            raise ValueError('IPA has no version/build number.')
        root = main[0][:-len('Info.plist')]
        declared = list(info.get('CFBundleIconFiles') or [])
        if isinstance(info.get('CFBundleIconFile'), str): declared.append(info['CFBundleIconFile'])
        for key in ['CFBundleIcons', 'CFBundleIcons~ipad']:
            primary = (info.get(key) or {}).get('CFBundlePrimaryIcon') or {}
            declared.extend(primary.get('CFBundleIconFiles') or [])
            if primary.get('CFBundleIconName'): declared.append(primary['CFBundleIconName'])
        declared = {Path(str(n)).stem.lower() for n in declared}
        best_icon = None
        for name in names:
            relative = name.removeprefix(root)
            if not name.startswith(root) or '/' in relative or not relative.lower().endswith('.png'):
                continue
            stem = Path(relative).stem.lower()
            if not (any(stem.startswith(d) for d in declared) or stem.startswith(('appicon', 'icon'))):
                continue
            try:
                image, area = web_png(read_member(archive, name, MAX_ICON))
                if best_icon is None or area > best_icon[0]: best_icon = (area, name, image)
            except (ValueError, RuntimeError, zlib.error):
                continue
        icon = None; icon_source = ''
        if metadata.get('icon'):
            manual = output / 'manual-icon'; download(metadata['icon'], manual, MAX_ICON)
            data = manual.read_bytes()
            if data.startswith(b'\x89PNG'):
                data, _ = web_png(data); ext = 'png'
            elif data.startswith(b'\xff\xd8\xff'): ext = 'jpg'
            elif data.startswith(b'RIFF') and data[8:12] == b'WEBP': ext = 'webp'
            else: raise ValueError('Manual icon must be PNG, JPEG, or WebP.')
            icon = output / ('icon.' + ext); icon.write_bytes(data); icon_source = 'manual'
        elif best_icon:
            _, icon_source, data = best_icon
            icon = output / 'icon.png'; icon.write_bytes(data)
        if icon is None:
            raise ValueError('No usable declared PNG icon was found. Assets.car alone is not decoded; provide a manual icon URL.')
        original = str(info.get('CFBundleDisplayName') or info.get('CFBundleName') or bundle)
        return {'name': metadata.get('name') or original, 'originalName': original, 'bundleIdentifier': bundle,
                'version': version, 'buildVersion': str(info.get('CFBundleVersion') or ''),
                'minOSVersion': str(info.get('MinimumOSVersion') or ''), 'size': path.stat().st_size,
                'sha256': digest, 'iconFile': icon.name, 'iconSource': icon_source,
                'iconSha256': hashlib.sha256(icon.read_bytes()).hexdigest()}


def encode_path(path):
    return '/'.join(urllib.parse.quote(p, safe='') for p in path.split('/'))


def content(path, ref):
    file = api('contents/' + encode_path(path) + '?ref=' + urllib.parse.quote(ref, safe=''), optional=True)
    if not file: return None
    if file.get('type') != 'file': raise ValueError(path + ' is not a file.')
    if file.get('size', 0) > 15 * 1024 * 1024: raise ValueError('Catalogue file exceeds 15 MiB.')
    blob = file if file.get('encoding') == 'base64' and isinstance(file.get('content'), str) else api('git/blobs/' + file['sha'])
    return {'sha': file['sha'], 'data': base64.b64decode(blob['content'])}


def snapshot():
    head = api('git/ref/heads/' + encode_path(BRANCH))['object']['sha']
    tree = api('git/commits/' + head)['tree']['sha']
    file = content('repo.json', head)
    data = json.loads(file['data'].decode('utf-8-sig')) if file else {'name': 'IPA BLACK', 'identifier': 'xsign.core.owned', 'apps': [], 'categories': [], 'news': []}
    if not isinstance(data, dict) or not isinstance(data.get('apps'), list): raise ValueError('repo.json must contain an apps list.')
    return {'head': head, 'tree': tree, 'data': data}


def match_app(apps, info, metadata):
    matches = [app for app in apps if app.get('bundleIdentifier') == info['bundleIdentifier']]
    if len(matches) > 1:
        exact = [app for app in matches if app.get('name') == (metadata.get('name') or info['name'])]
        if len(exact) != 1: raise ValueError('Several catalogue variants share this Bundle ID; supply the exact custom name to select one.')
        return exact[0]
    return matches[0] if matches else None


def duplicate(existing, info, metadata):
    if not existing or existing.get('sha256') != info['sha256']: return False
    if existing.get('version') != info['version'] or existing.get('buildVersion', '') != info['buildVersion']: return False
    if any(metadata.get(key) and metadata[key] != existing.get(field) for key, field in [('name','name'),('desc','localizedDescription'),('category','category')]): return False
    if metadata.get('icon') and existing.get('iconSha256') != info['iconSha256']: return False
    if 'skip_appstore' in metadata and metadata['skip_appstore'] != existing.get('skipAppStoreLookup', False): return False
    return True


def update_app(apps, item):
    info, metadata, original = item['info'], item['metadata'], item['base']
    existing = match_app(apps, info, metadata)
    if original is None and existing is not None:
        raise ValueError('An app with this Bundle ID appeared during processing. Sync and retry instead of creating a duplicate.')
    if original is not None and existing is None: raise ValueError('The app was removed during processing. Catalogue was not overwritten.')
    current = copy.deepcopy(existing or {})
    name = metadata.get('name') or current.get('name') or info['name']
    patch = {'name': name, 'bundleIdentifier': info['bundleIdentifier'], 'version': info['version'],
             'buildVersion': info['buildVersion'], 'size': info['size'], 'sha256': info['sha256'],
             'iconSha256': info['iconSha256'], 'iconURL': info['iconURL'], 'downloadURL': info['downloadURL'],
             'versionDate': info['date'], 'releaseURL': info['releaseURL']}
    if metadata.get('desc'): patch['localizedDescription'] = metadata['desc']
    if 'down' in current: patch['down'] = info['downloadURL']
    if metadata.get('desc') and 'versionDescription' in current: patch['versionDescription'] = metadata['desc']
    if metadata.get('category'):
        patch['category'] = metadata['category']
    if 'skip_appstore' in metadata: patch['skipAppStoreLookup'] = metadata['skip_appstore']
    for key, value in patch.items():
        if original is not None and existing.get(key) != original.get(key) and value != existing.get(key):
            raise ValueError('Concurrent catalogue edit conflicts with field: ' + key)
        current[key] = value
    current.setdefault('catalogID', 'xsign.releases.' + info['bundleIdentifier'])
    current.setdefault('developerName', 'IPA BLACK')
    versions = current.get('versions') or []
    if not isinstance(versions, list) or any(not isinstance(v, dict) for v in versions): raise ValueError('Existing versions are malformed.')
    old_version = next((v for v in versions if v.get('version') == info['version']), {})
    latest = {**old_version, 'version': info['version'], 'date': info['date'], 'downloadURL': info['downloadURL'],
              'size': info['size'], 'sha256': info['sha256'], 'buildVersion': info['buildVersion'],
              'localizedDescription': metadata.get('desc') or current.get('localizedDescription') or ''}
    if info.get('minOSVersion'): latest['minOSVersion'] = info['minOSVersion']
    if original is not None:
        previous = next((v for v in (original.get('versions') or []) if v.get('version') == info['version']), {})
        for key, value in latest.items():
            if old_version.get(key) != previous.get(key) and value != old_version.get(key):
                raise ValueError('Concurrent version edit conflicts with field: ' + key)
    if existing and existing.get('downloadURL') and existing.get('downloadURL') != info['downloadURL']:
        history = current.setdefault('releaseHistory', [])
        if not isinstance(history, list): raise ValueError('Existing releaseHistory is malformed.')
        record = {k: existing[k] for k in ['version','buildVersion','downloadURL','iconURL','sha256','releaseURL','versionDate','size'] if k in existing}
        if not any(isinstance(row, dict) and row.get('downloadURL') == record['downloadURL'] for row in history): history.insert(0, record)
        if not versions and existing.get('version') != info['version'] and existing.get('version'):
            versions.append({'version': existing['version'], 'downloadURL': existing['downloadURL'], 'date': existing.get('versionDate', info['date']), 'size': existing.get('size', 0)})
    current['versions'] = [latest] + [v for v in versions if v.get('version') != info['version']]
    if existing: apps[apps.index(existing)] = current
    else: apps.insert(0, current)


def clean_metadata(raw):
    if not isinstance(raw, dict): raise ValueError('Upload metadata must be a JSON object.')
    out = {}
    for key, limit in [('name',300),('desc',20000),('icon',4000),('category',100)]:
        value = raw.get(key, '')
        if not isinstance(value, str) or len(value) > limit: raise ValueError('Invalid metadata field: ' + key)
        out[key] = value.strip()
    value = raw.get('skip_appstore', True)
    if isinstance(value, str) and value.lower() in ['true','false']: value = value.lower() == 'true'
    if not isinstance(value, bool): raise ValueError('skip_appstore must be a boolean.')
    out['skip_appstore'] = value
    return out


def prepare_jobs(inputs):
    jobs = []; trigger = os.environ['GITHUB_EVENT_NAME']
    if trigger == 'workflow_dispatch' and inputs.get('ipa_url', '').strip():
        folder = WORK / 'url'; folder.mkdir(parents=True, exist_ok=True)
        ipa = folder / 'app.ipa'; download(inputs['ipa_url'].strip(), ipa, MAX_IPA)
        metadata = clean_metadata({key: inputs.get(value, '') for key,value in [('name','custom_name'),('desc','custom_desc'),('icon','custom_icon'),('category','category_id')]} | {'skip_appstore': inputs.get('skip_appstore', True)})
        jobs.append({'ipa': ipa, 'metadata': metadata, 'folder': folder, 'cleanup': {}})
    else:
        files = sorted(Path('uploads').glob('*.ipa'))
        if not files: raise ValueError('No IPA queued: provide ipa_url or commit uploads/*.ipa plus its JSON metadata.')
        if len(files) > 10: raise ValueError('At most 10 queued IPA files are processed per run.')
        for index, path in enumerate(files):
            if path.is_symlink() or path.resolve().parent != (Path.cwd() / 'uploads').resolve(): raise ValueError('Unsafe upload path.')
            sidecar = path.with_suffix('.json')
            meta_path = sidecar if sidecar.exists() else Path('uploads/meta.json')
            if meta_path.is_symlink(): raise ValueError('Metadata symlinks are not supported.')
            if meta_path.exists() and meta_path.stat().st_size > 100000: raise ValueError('Upload metadata is too large.')
            metadata = clean_metadata(json.loads(meta_path.read_text()) if meta_path.exists() else {})
            folder = WORK / ('file-' + str(index)); folder.mkdir(parents=True, exist_ok=True)
            cleanup = {}
            for file in [path] + ([meta_path] if meta_path.exists() else []):
                blob = hashlib.sha1(b'blob ' + str(file.stat().st_size).encode() + b'\0')
                with file.open('rb') as stream:
                    while block := stream.read(1024 * 1024): blob.update(block)
                cleanup[file.as_posix()] = blob.hexdigest()
            jobs.append({'ipa': path, 'metadata': metadata, 'folder': folder, 'cleanup': cleanup})
    for job in jobs:
        job['info'] = inspect_ipa(job['ipa'], job['metadata'], job['folder'])
    return jobs


def publish_release(job, repository):
    from datetime import datetime, timezone
    info = job['info']; info['date'] = datetime.now(timezone.utc).date().isoformat()
    slug = re.sub(r'[^a-zA-Z0-9.-]+', '-', info['bundleIdentifier'])[:90]
    tag = 'ipa-' + slug + '-' + info['sha256'][:12] + '-' + os.environ['GITHUB_RUN_ID'] + '-' + os.environ.get('GITHUB_RUN_ATTEMPT','1')
    # Include the batch index in case two variants contain identical IPA bytes.
    tag += '-' + job['folder'].name
    prefix = 'https://github.com/' + REPO + '/releases/download/' + tag + '/'
    info.update(downloadURL=prefix+'app.ipa', iconURL=prefix+info['iconFile'],
                releaseURL='https://github.com/'+REPO+'/releases/tag/'+tag, repository=REPO,
                releaseVisibility='private' if repository.get('private') else 'public')
    info_file = job['folder'] / 'info.json'; info_file.write_text(json.dumps(info,ensure_ascii=False,indent=2)+'\n')
    notes = job['folder'] / 'notes.md'
    notes.write_text('## IPA BLACK\n\n' + '\n'.join('- **'+key+'**: '+html.escape(str(info[key])).replace('\n',' ') for key in ['name','bundleIdentifier','version','buildVersion','minOSVersion','size','sha256']) + '\n')
    release = api('releases', 'POST', {'tag_name':tag, 'target_commitish':os.environ['GITHUB_SHA'],
                  'name':info['name'][:140]+' · '+info['version'][:40], 'body':notes.read_text(), 'draft':True,
                  'make_latest':'false'})
    release_id = str(release['id'])
    # Give the IPA a stable asset name without loading the entire file into memory.
    local = job['folder'] / 'app.ipa'
    if local.resolve() != job['ipa'].resolve() and not (local.exists() and local.samefile(job['ipa'])):
        if local.exists(): local.unlink()
        try: os.link(job['ipa'], local)
        except OSError:
            import shutil; shutil.copyfile(job['ipa'], local)
    gh('release','upload',tag,str(local),str(job['folder']/info['iconFile']),str(info_file),'--repo',REPO)
    # The by-tag REST endpoint only guarantees published releases; use the draft ID.
    release = api('releases/' + release_id)
    assets = {asset['name']:asset for asset in release.get('assets',[])}
    for path in [local,job['folder']/info['iconFile'],info_file]:
        asset=assets.get(path.name)
        if not asset or asset.get('state')!='uploaded' or asset.get('size')!=path.stat().st_size or asset.get('browser_download_url')!=prefix+path.name:
            raise ValueError('Release asset verification failed; release remains draft.')
    api('releases/' + release_id, 'PATCH', {'draft':False, 'make_latest':'false'})


def commit_catalogue(jobs):
    for attempt in range(3):
        remote = snapshot(); data = remote['data']
        for job in jobs:
            if job.get('duplicate'):
                if not duplicate(match_app(data['apps'], job['info'], job['metadata']), job['info'], job['metadata']):
                    raise ValueError('The previously published app changed or was removed. Queue was retained; sync and retry.')
                continue
            if job['metadata'].get('category') and not any(c.get('id')==job['metadata']['category'] for c in data.get('categories',[])):
                raise ValueError('Selected category no longer exists in repo.json.')
            update_app(data['apps'], job)
        changed = any(not j.get('duplicate') for j in jobs)
        entries = []
        if changed:
            revision = data.get('repo_revision_id',0)
            if not isinstance(revision,int) or isinstance(revision,bool) or revision < 0: raise ValueError('Invalid repo_revision_id.')
            data['repo_revision_id'] = revision + 1
            projection = {k:data[k] for k in ['name','identifier','subtitle','description','iconURL','tintColor','repo_revision_id','xsign_config','categories'] if k in data}
            for path,value in [('repo.json',data),('xsign-config.json',projection)]:
                entries.append({'path':path,'mode':'100644','type':'blob','content':json.dumps(value,ensure_ascii=False,indent=2)+'\n'})
        cleanup_cache, delete_paths, retain_paths = {}, set(), set()
        for job in jobs:
            unchanged = True
            for path, expected in job['cleanup'].items():
                if path not in cleanup_cache:
                    cleanup_cache[path] = api('contents/' + encode_path(path) + '?ref=' + urllib.parse.quote(remote['head'], safe=''), optional=True)
                current = cleanup_cache[path]
                if not current or current.get('sha') != expected: unchanged = False
            # Keep an IPA together with its metadata if either changed after queuing.
            if unchanged: delete_paths.update(job['cleanup'])
            else:
                retain_paths.update(job['cleanup'])
                print('::warning::Queued IPA or metadata changed during processing; this upload pair was retained.')
        delete_paths.difference_update(retain_paths)
        for path in sorted(delete_paths):
            entries.append({'path':path,'mode':'100644','type':'blob','sha':None})
        if not entries: return data
        tree = api('git/trees','POST',{'base_tree':remote['tree'],'tree':entries})
        commit = api('git/commits','POST',{'message':'Publish IPA BLACK catalogue updates [skip ci]','tree':tree['sha'],'parents':[remote['head']]})
        try:
            api('git/refs/heads/'+encode_path(BRANCH),'PATCH',{'sha':commit['sha'],'force':False})
            return data
        except RuntimeError as error:
            if not getattr(error,'conflict',False) or attempt==2: raise
    raise RuntimeError('Concurrent catalogue updates prevented publication.')


def main():
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', REPO): raise ValueError('Invalid GitHub repository.')
    if os.environ.get('GITHUB_REF_TYPE')!='branch': raise ValueError('Run the publisher on a branch, not a tag.')
    WORK.mkdir(parents=True,exist_ok=True)
    inputs=json.loads(os.environ.get('INPUTS_JSON') or '{}')
    repository=api('')
    if repository.get('private'):
        print('::warning::Releases are private. Their download URLs require GitHub authentication and are not public source links.')
    jobs=prepare_jobs(inputs); initial=snapshot()['data']
    seen=set()
    for job in jobs:
        if job['info']['bundleIdentifier'] in seen: raise ValueError('Queue one IPA per Bundle ID in each batch.')
        seen.add(job['info']['bundleIdentifier'])
        if job['metadata'].get('category') and not any(c.get('id')==job['metadata']['category'] for c in initial.get('categories',[])): raise ValueError('Selected category does not exist in repo.json.')
        existing=match_app(initial['apps'],job['info'],job['metadata']);job['base']=copy.deepcopy(existing)
        job['duplicate']=duplicate(existing,job['info'],job['metadata'])
    for job in jobs:
        if not job['duplicate']: publish_release(job,repository)
    commit_catalogue(jobs)
    summary=['## IPA BLACK — IPA processing','', '| App | Bundle ID | Version | Result |','|---|---|---|---|']
    for job in jobs:
        info=job['info'];name=html.escape(info['name']).replace('|','&#124;').replace('\n',' ')
        result='Already published: identical file and metadata' if job['duplicate'] else '[Release]('+info['releaseURL']+')'
        summary.append('| '+name+' | `'+info['bundleIdentifier']+'` | '+html.escape(info['version']).replace('|','&#124;')+' | '+result+' |')
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as output:
        output.write('\n'.join(summary)+'\n')
    print('IPA extraction, Releases and catalogue processing completed.')


if __name__=='__main__':
    try: main()
    except Exception as error:
        print('::error::'+str(error).replace('\n',' ')[:2000]);sys.exit(1)
