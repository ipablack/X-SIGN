"""Extract public-link AltStore feeds from the user-supplied IPA, without executing it."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit
import zipfile

FEEDS = ('soon.json', 'ipaomtk.json', 'han.json')
PRIVATE_KEYS = {'token', 'key', 'api_key', 'apikey', 'authorization', 'signature', 'sig', 'access_token', 'password',
                'policy', 'key-pair-id', 'x-amz-signature', 'x-amz-credential', 'x-amz-security-token'}

def clean_text(value, limit):
    return re.sub(r'https?://[^\s<>"\']+', lambda match: match[0] if public_url(match[0]) else '[رابط يتطلب صلاحية]', value)[:limit]

def public_url(value):
    if not isinstance(value, str): return None
    value = value.strip()
    try:
        parsed = urlsplit(value)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password: return None
        if any(key.lower() in PRIVATE_KEYS for key, _ in parse_qsl(parsed.query, keep_blank_values=True)): return None
    except ValueError: return None
    return value

def integer(value):
    try: return max(0, int(value))
    except (TypeError, ValueError, OverflowError): return 0

def extract_feed(root, feed, input_hash):
    rows = {}; omitted = set(); missing = 0
    for app in root.get('apps', []):
        if not isinstance(app, dict): missing += 1; continue
        name = str(app.get('name') or '').strip(); bundle = str(app.get('bundleIdentifier') or '').strip()
        key = bundle.lower() + '\x1f' + name.lower()
        if not name or not bundle: missing += 1; continue
        versions = []
        for raw in app.get('versions', []):
            if not isinstance(raw, dict): continue
            url = public_url(raw.get('downloadURL'))
            if not url: continue
            item = {'version':str(raw.get('version') or '1.0'), 'downloadURL':url, 'size':integer(raw.get('size'))}
            if isinstance(raw.get('date'),str): item['date'] = raw['date'][:10]
            if isinstance(raw.get('localizedDescription'),str): item['localizedDescription'] = clean_text(raw['localizedDescription'],1200)
            versions.append(item)
        direct = public_url(app.get('downloadURL'))
        if direct:
            selected = {'version':str(app.get('version') or '1.0'), 'downloadURL':direct, 'size':integer(app.get('size'))}
            if isinstance(app.get('versionDate'),str): selected['date'] = app['versionDate'][:10]
            if not any(v['downloadURL']==direct and v['version']==selected['version'] for v in versions): versions.insert(0,selected)
        elif versions: selected = versions[0]
        else: omitted.add(key); continue
        if key in rows: continue
        item = {'catalogID':'soon_'+hashlib.sha256(key.encode()).hexdigest()[:24], 'name':name, 'bundleIdentifier':bundle,
                'version':selected['version'], 'downloadURL':selected['downloadURL'], 'size':selected['size'],
                'versions':versions, 'skipAppStoreLookup':True}
        if selected.get('date'): item['versionDate'] = selected['date']
        for field in ('developerName','subtitle','localizedDescription','versionDescription','category'):
            if isinstance(app.get(field),str): item[field] = clean_text(app[field],1200 if 'Description' in field else 200)
        # If the newest URL is protected, the version and URL both come from the same available version.
        if not direct and selected.get('localizedDescription'): item['versionDescription'] = selected['localizedDescription']
        for field in ('iconURL','headerURL','bannerURL'):
            url = public_url(app.get(field))
            if url: item[field] = url
        screenshots = app.get('screenshotURLs',[])
        if isinstance(screenshots,dict): screenshots = screenshots.get('iphone',[])
        if isinstance(screenshots,list): item['screenshotURLs'] = [url for value in screenshots if (url:=public_url(value))][:6]
        rows[key] = item
    categories = {}
    for list_name, is_game in [('categories',False),('gameCategories',True)]:
        for raw in root.get(list_name,[]):
            if not isinstance(raw,dict): continue
            identifier = str(raw.get('id') or raw.get('value') or '').strip()
            if identifier: categories[identifier] = {'id':identifier,'name':str(raw.get('name') or raw.get('label') or identifier),'isGame':is_game}
    label = Path(feed).stem
    result = {'name':'IPA BLACK','identifier':'com.ipablack.snapshot.'+label,
              'subtitle':{'soon':'كتالوج IPA Soon من الملف المرفوع','ipaomtk':'كتالوج IPAOMTK من الملف المرفوع','han':'كتالوج Han من الملف المرفوع'}[label],
              'tintColor':'#005BBB','categories':list(categories.values()),'news':[],'apps':list(rows.values()),
              'xsign_snapshot':{'input_sha256':input_hash,'bundled_file':feed,'input_rows':len(root.get('apps',[])),
                  'included_rows':len(rows),'excluded_protected_or_missing':len(omitted-rows.keys())+missing,
                  'automatic_upstream_refresh':False,'original_source_name':root.get('name')}}
    return result

def extract(ipa, output):
    input_hash = hashlib.sha256(ipa.read_bytes()).hexdigest()
    output.mkdir(parents=True,exist_ok=True)
    results = []
    with zipfile.ZipFile(ipa) as archive:
        for feed in FEEDS:
            matches = [name for name in archive.namelist() if name.startswith('Payload/') and name.count('/')==2 and name.endswith('/'+feed)]
            if len(matches)!=1: raise ValueError('Missing or ambiguous feed: '+feed)
            info = archive.getinfo(matches[0])
            if info.file_size>16_777_216: raise ValueError('Unexpected feed size')
            data = extract_feed(json.loads(archive.read(info)),feed,input_hash)
            filename = 'IPA_BLACK_'+{'soon':'IPASoon','ipaomtk':'IPAOMTK','han':'Han'}[Path(feed).stem]+'_Source.json'
            (output/filename).write_text(json.dumps(data,ensure_ascii=False,separators=(',',':'))+'\n')
            results.append({'file':filename,**data['xsign_snapshot']})
    (output/'extraction_summary.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
    return results

if __name__=='__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa',type=Path); parser.add_argument('output_directory',type=Path)
    args = parser.parse_args()
    for result in extract(args.ipa,args.output_directory): print(result['file'],result['included_rows'],'apps')
