"""Build a credential-free AltStore snapshot from the supplied IPA's bundled JSON.
No application binaries are executed or redistributed by this script.
"""
import hashlib
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit, parse_qs
import zipfile

FEEDS = ('han.json', 'ipaomtk.json', 'soon.json')

def http(value):
    if not isinstance(value, str): return None
    parsed = urlsplit(value.strip())
    if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password: return None
    if any(k.lower() in {'token', 'key', 'api_key', 'apikey', 'authorization', 'signature', 'sig'} for k in parse_qs(parsed.query)):
        return None
    return value.strip()

def normalize(ipa):
    rows = {}
    counts = {}
    excluded = set()
    with zipfile.ZipFile(ipa) as archive:
        for feed in FEEDS:
            paths = [p for p in archive.namelist() if p.startswith('Payload/') and p.count('/') == 2 and p.endswith('/' + feed)]
            if len(paths) != 1: raise ValueError('Missing or ambiguous catalog: ' + feed)
            info = archive.getinfo(paths[0])
            if info.file_size > 8_388_608: raise ValueError('Catalog too large: ' + feed)
            root = json.loads(archive.read(info))
            apps = root['apps']
            counts[feed] = len(apps)
            for app in apps:
                bundle = app.get('bundleIdentifier', '').strip()
                name = app.get('name', '').strip()
                versions = [v for v in app.get('versions', []) if isinstance(v, dict)]
                version = next((v for v in versions if http(v.get('downloadURL'))), {})
                url = http(app.get('downloadURL')) or http(version.get('downloadURL'))
                if not name or not bundle: raise ValueError('Incomplete app in ' + feed)
                key = bundle.lower() + '\x1f' + name.lower()
                if not url:
                    excluded.add(key)
                    continue
                if key in rows: continue
                item = {'catalogID': 'ref_' + hashlib.sha256(key.encode()).hexdigest()[:24],
                        'name': name, 'bundleIdentifier': bundle,
                        'version': str(app.get('version') or version.get('version') or '1.0'),
                        'downloadURL': url, 'skipAppStoreLookup': True}
                for field in ['developerName', 'subtitle', 'localizedDescription', 'versionDescription', 'category']:
                    if isinstance(app.get(field), str):
                        limit = 600 if field in ('localizedDescription', 'versionDescription') else 180
                        item[field] = app[field][:limit]
                size = app.get('size', version.get('size'))
                try: size = int(size)
                except (TypeError, ValueError): size = None
                if size is not None and size >= 0: item['size'] = size
                icon = http(app.get('iconURL'))
                if icon: item['iconURL'] = icon
                screenshots = app.get('screenshotURLs', app.get('screenshots', []))
                if isinstance(screenshots, dict): screenshots = screenshots.get('iphone', [])
                if isinstance(screenshots, list): item['screenshotURLs'] = [u for u in screenshots if http(u)][:3]
                rows[key] = item
    return {'name': 'IPA BLACK', 'identifier': 'xsign.core.reference',
            'subtitle': 'تطبيقات إضافية من الملف المرفوع', 'tintColor': '#005BBB',
            'apps': list(rows.values()),
            'xsign_snapshot': {'input_sha256': hashlib.sha256(Path(ipa).read_bytes()).hexdigest(),
                               'bundled_catalogs': counts, 'unique_rows': len(rows),
                               'excluded_protected_or_missing_downloads': len(excluded - rows.keys()),
                               'description_character_limit': 600, 'screenshot_limit': 3,
                               'automatic_upstream_refresh': False}}

if __name__ == '__main__':
    result = normalize(sys.argv[1])
    target = Path(sys.argv[2]); target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
    print('Reference snapshot:', result['xsign_snapshot']['bundled_catalogs'], 'unique rows:', len(result['apps']))
