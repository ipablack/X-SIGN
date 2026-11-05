"""Publish IPA BLACK live catalogs from public provider endpoints, without credentials.

Soon's public endpoint is also consumed directly by XSign. The saved copy is useful
for other source clients. IPAOMTK's WordPress response needs conversion to a catalog.
Never substitutes a bundled snapshot for a successful live fetch.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import argparse, hashlib, html, json, re, sys, time

SOON = 'https://appiraq.com/source.php?action=getAll'
IPAOMTK = 'https://ipaomtk.com/wp-json/wp/v2/posts'
BASE = 'https://raw.githubusercontent.com/ipa-black/X-SIGN/main/public/sources/'
LIMIT = 33_554_432
PRIVATE_KEYS = {'token','key','api_key','apikey','access_token','authorization','signature','policy','key-pair-id'}


def public_url(value):
    from urllib.parse import parse_qsl
    if not isinstance(value, str): return None
    try:
        value = html.unescape(value.strip())
        p = urlsplit(value)
        if p.scheme not in ('http','https') or not p.hostname or p.username or p.password: return None
        if any(ord(c) < 33 for c in value): return None
        if any(k.lower() in PRIVATE_KEYS or k.lower().startswith(('x-amz-','x-goog-')) for k,v in parse_qsl(p.query,keep_blank_values=True)): return None
        return value
    except ValueError: return None


def text(value, maximum=500):
    value=html.unescape(re.sub('<[^>]*>', ' ', value if isinstance(value,str) else '')).strip()
    value=re.sub(r'https?://[^\s<>"\']+',lambda m:m[0] if public_url(m[0]) else '[private link omitted]',value)
    return value[:maximum]


def fetch(url):
    for attempt in range(3):
        try:
            request = Request(url, headers={'Accept':'application/json','User-Agent':'IPA-BLACK-LiveCatalog/1.0'})
            with urlopen(request, timeout=40) as response:
                raw = response.read(LIMIT+1)
                if not raw or len(raw)>LIMIT: raise ValueError('Empty or oversized provider response')
                return json.loads(raw), dict(response.headers)
        except Exception:
            if attempt == 2: raise
            time.sleep(attempt+1)


def catalog(identifier, apps, provider, now):
    result = {'name':'IPA BLACK','identifier':'com.ipablack.live.'+identifier,
              'iconURL':'https://github.com/ipa-black.png','apps':apps,'news':[],
              'sourceURL':BASE+identifier+'.json',
              'xsign_live':{'provider':provider,'updated_at':now.isoformat(),'format':1}}
    return result


def size_bytes(value):
    if isinstance(value,int) and not isinstance(value,bool) and value>=0: return value
    if not isinstance(value,str): return None
    match = re.fullmatch(r'\s*(\d+(?:\.\d+)?)\s*(B|KB|MB|GB)?\s*',value,re.I)
    return int(float(match[1])*1024**{'B':0,'KB':1,'MB':2,'GB':3}[(match[2] or 'B').upper()]) if match else None


def normalize_soon(data, now):
    if not isinstance(data,dict) or not isinstance(data.get('apps'),list) or not data['apps']:
        raise ValueError('Soon returned no valid apps list')
    apps=[]; seen=set()
    for source in data['apps']:
        if not isinstance(source,dict): continue
        app=dict(source)
        builds=[]
        for version in source.get('versions') or []:
            if not isinstance(version,dict): continue
            link=public_url(version.get('downloadURL'))
            if link and text(version.get('version')):
                build={k:version[k] for k in ['version','date','size','localizedDescription'] if k in version}
                if 'localizedDescription' in build: build['localizedDescription']=text(build['localizedDescription'])
                build['downloadURL']=link;builds.append(build)
        link=public_url(source.get('downloadURL'))
        if link and text(source.get('version')):
            current={k:source[k] for k in ['version','size'] if k in source};current['downloadURL']=link
        elif builds: current=builds[0]
        else: continue
        key=(text(source.get('bundleIdentifier')),text(source.get('name')))
        if key in seen: continue
        seen.add(key)
        # Explicit allowlist prevents arbitrary access tokens or vendor service fields leaking to main.
        app={k:text(source[k]) for k in ['name','bundleIdentifier','developerName','subtitle','category','localizedDescription'] if k in source}
        app.update({k:current[k] for k in ['version','downloadURL','size'] if k in current})
        app['catalogID']='soon:'+hashlib.sha256(json.dumps(key,ensure_ascii=False).encode()).hexdigest()[:24]
        app['skipAppStoreLookup']=True
        for k in ['iconURL']:
            if public_url(source.get(k)): app[k]=public_url(source[k])
        app['screenshots']=[u for u in (public_url(v) for v in source.get('screenshots',[]) if isinstance(v,str)) if u][:3]
        if builds: app['versions']=[current]+[v for v in builds if (v['version'],v['downloadURL'])!=(current['version'],current['downloadURL'])]
        apps.append(app)
    if not apps: raise ValueError('Soon has no public download entries; keeping the last valid catalog')
    result=catalog('ipasoon',apps,SOON,now)
    categories={}
    for key in ['categories','gameCategories']:
        for row in data.get(key) or []:
            if not isinstance(row,dict): continue
            i=text(row.get('id') or row.get('value'));name=text(row.get('name') or row.get('label'))
            if i and name:
                prior=categories.get(i,{})
                categories[i]={'id':i,'name':name,'isGame':key=='gameCategories' or row.get('isGame') is True or prior.get('isGame') is True}
    result['categories']=list(categories.values())
    return result


def post_app(post):
    if not isinstance(post,dict) or not isinstance(post.get('id'),int): return None
    detail=post.get('app_details') or {};yoast=post.get('yoast_head_json') or {}
    name=text(detail.get('name') or (post.get('title') or {}).get('rendered'),160)
    builds=[]
    for item in post.get('downloads') or []:
        if not isinstance(item,dict): continue
        link=public_url(item.get('download_url'));version=text(item.get('download_version') or detail.get('version'),80)
        if not link or not version or not urlsplit(link).path.lower().endswith(('.ipa','.zip','.tipa')): continue
        build={'version':version,'downloadURL':link,'date':post.get('modified_gmt') or post.get('date_gmt') or post.get('date') or '2000-01-01'}
        size=size_bytes(item.get('download_size') or detail.get('size'))
        if size is not None: build['size']=size
        if text(item.get('download_mod_info')): build['localizedDescription']=text(item['download_mod_info'])
        builds.append(build)
    if not name or not builds: return None
    app={'name':name,'catalogID':'ipaomtk.post.'+str(post['id']),'skipAppStoreLookup':True,
         'developerName':text(detail.get('publisher'),160) or 'Unknown',
         'version':builds[0]['version'],'downloadURL':builds[0]['downloadURL'],'versions':builds,
         'localizedDescription':text(yoast.get('description') or (post.get('app_mod') or {}).get('information'))}
    bundle=text(detail.get('bundle'),200)
    # Apple numeric product IDs and invented bundle IDs must not masquerade as actual Info.plist values.
    if re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',bundle): app['bundleIdentifier']=bundle
    if 'size' in builds[0]: app['size']=builds[0]['size']
    images=yoast.get('og_image') or []
    icon=next((public_url(i.get('url')) for i in images if isinstance(i,dict) and public_url(i.get('url'))),None)
    if icon: app['iconURL']=icon
    return app


def wp_page(page):
    fields='id,slug,title,date,date_gmt,modified_gmt,downloads,app_mod,app_details,yoast_head_json'
    query=urlencode({'per_page':100,'page':page,'orderby':'modified','order':'desc','_fields':fields})
    rows,headers=fetch(IPAOMTK+'?'+query)
    if not isinstance(rows,list): raise ValueError('IPAOMTK returned a non-list response')
    total=int(next((v for k,v in headers.items() if k.lower()=='x-wp-totalpages'),'0'))
    if not 1<=total<=500: raise ValueError('IPAOMTK pagination is missing or exceeds the safety limit')
    return rows,total


def normalize_ipaomtk(previous, now, page_loader=wp_page):
    old_meta=(previous or {}).get('xsign_live') or {}
    try: last_full=datetime.fromisoformat(old_meta.get('full_sync_at',''))
    except (ValueError,TypeError): last_full=datetime.min.replace(tzinfo=timezone.utc)
    full=not previous or now-last_full>=timedelta(days=7)
    try: cutoff=datetime.fromisoformat(old_meta.get('updated_at',''))-timedelta(days=1)
    except (ValueError,TypeError): full=True;cutoff=datetime.min.replace(tzinfo=timezone.utc)
    apps={} if full else {a['catalogID']:a for a in previous.get('apps',[]) if a.get('catalogID')}
    def consume(rows):
        old=False
        for row in rows:
            try: modified=datetime.fromisoformat(row.get('modified_gmt','').replace('Z','+00:00')).replace(tzinfo=timezone.utc)
            except (ValueError,TypeError): modified=now
            if modified<cutoff: old=True
            identity='ipaomtk.post.'+str(row.get('id'))
            app=post_app(row)
            if app: apps[identity]=app
            else: apps.pop(identity,None)
        return old
    first,total=page_loader(1);stop=consume(first)
    if full:
        # Decode each page in a worker and discard its large provider metadata immediately.
        with ThreadPoolExecutor(max_workers=3) as pool:
            for start in range(2,total+1,3):
                for rows,_ in pool.map(page_loader,range(start,min(start+3,total+1))): consume(rows)
    elif not stop:
        for page in range(2,total+1):
            rows,_=page_loader(page)
            if consume(rows): break
    if not apps: raise ValueError('IPAOMTK returned no downloadable apps')
    result=catalog('ipaomtk',sorted(apps.values(),key=lambda a:(a['versions'][0]['date'],a['catalogID']),reverse=True),IPAOMTK,now)
    result['xsign_live']['full_sync_at']=(now if full else last_full).isoformat()
    result['xsign_live']['published_posts_pages']=total
    return result


def write(path, value):
    raw=(json.dumps(value,ensure_ascii=False,separators=(',',':'))+'\n').encode()
    if len(raw)>LIMIT: raise ValueError('Catalog is larger than the native transport limit')
    path.parent.mkdir(parents=True,exist_ok=True)
    temp=path.with_suffix('.tmp');temp.write_bytes(raw);temp.replace(path)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',default='public/sources');args=parser.parse_args()
    folder=Path(args.output);now=datetime.now(timezone.utc);status={};success=False
    for name,operation in [('ipasoon',lambda prior:normalize_soon(fetch(SOON)[0],now)),('ipaomtk',lambda prior:normalize_ipaomtk(prior,now))]:
        path=folder/(name+'.json')
        try: previous=json.loads(path.read_bytes()) if path.exists() else None
        except (ValueError,OSError): previous=None
        try:
            result=operation(previous);write(path,result);success=True
            status[name]={'state':'fresh','apps':len(result['apps']),'url':BASE+name+'.json'}
        except Exception as error:
            message=re.sub(r'https?://\S+','<provider URL>',str(error))[:180]
            status[name]={'state':'cached' if previous else 'unavailable','error':message}
            print(name+': '+status[name]['state']+'; '+message,file=sys.stderr)
    write(folder/'status.json',{'checked_at':now.isoformat(),'sources':status})
    print(json.dumps(status,ensure_ascii=False))
    if not success and not any((folder/(name+'.json')).exists() for name in status): raise SystemExit(1)


if __name__=='__main__': main()
