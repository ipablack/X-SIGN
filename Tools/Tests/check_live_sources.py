"""Regressions for live source conversion, incremental updates and atomic publishing."""
from datetime import datetime,timedelta,timezone
from pathlib import Path
from unittest.mock import patch
import importlib.util,json,tempfile,sys

path=Path(__file__).resolve().parents[1]/'Sync_Live_Sources.py'
spec=importlib.util.spec_from_file_location('live_sources',path)
live=importlib.util.module_from_spec(spec);spec.loader.exec_module(live)
NOW=datetime(2026,10,31,tzinfo=timezone.utc)


def post(i,version='2.0',day='2026-10-30',link=None):
    return {'id':i,'title':{'rendered':'Fixture &amp; App '+str(i)},'modified_gmt':day+'T12:00:00',
            'downloads':[{'download_url':link or 'https://example.org/'+str(i)+'.ipa','download_version':version,'download_size':'12.5 MB'}],
            'app_details':{'name':'Fixture '+str(i),'package':'123456','bundle':''},
            'yoast_head_json':{'description':'Updated description','og_image':[{'url':'https://example.org/icon.png'}]}}


def main():
    assert live.public_url('https://example.org/a.ipa?token=') is None
    assert live.public_url('https://user:password@example.org/a.ipa') is None
    assert live.public_url('https://example.org/a.ipa?X-Amz-Signature=secret') is None
    assert live.public_url('https://example.org/a.ipa?download=1')
    root={'apps':[
        {'name':'Public','bundleIdentifier':'org.fixture.app','version':'2.0','downloadURL':'https://example.org/new.ipa'},
        {'name':'Public','bundleIdentifier':'org.fixture.app','version':'2.0','downloadURL':'https://example.org/new.ipa'},
        {'name':'Older Public','bundleIdentifier':'org.fixture.old','version':'9.0','downloadURL':'https://example.org/new.ipa?token=SECRET',
         'localizedDescription':'test https://example.org/service?token=SECRET',
         'versions':[{'version':'1.0','downloadURL':'https://example.org/old.ipa','size':5}]},
        {'name':'Private','version':'1.0','downloadURL':'https://example.org/private.ipa?token='}],
        'categories':[{'value':'games','label':'Games'}], 'gameCategories':[{'value':'games','label':'Games'}]}
    source=live.normalize_soon(root,NOW)
    assert len(source['apps'])==2 and len({a['catalogID'] for a in source['apps']})==2
    assert source['apps'][1]['version']=='1.0' and source['apps'][1]['downloadURL']=='https://example.org/old.ipa'
    assert source['categories']==[{'id':'games','name':'Games','isGame':True}]
    assert 'SECRET' not in json.dumps(source)
    assert live.post_app(post(1))['size']==13_107_200
    assert 'bundleIdentifier' not in live.post_app(post(1)), 'A numeric App Store ID became a fake bundle'
    proper=post(1);proper['app_details']['bundle']='org.fixture.real'
    assert live.post_app(proper)['bundleIdentifier']=='org.fixture.real'
    assert live.post_app(post(2,link='https://example.org/not-an-ipa.html')) is None

    pages={1:([post(1)],2),2:([post(2)],2)}
    full=live.normalize_ipaomtk(None,NOW,lambda page:pages[page])
    assert {a['catalogID'] for a in full['apps']}=={'ipaomtk.post.1','ipaomtk.post.2'}
    # An edit updates its stable row; an old page ends the incremental scan, keeping older apps.
    recent=post(1,'3.0',day='2026-10-31')
    later=NOW+timedelta(hours=1)
    pages={1:([recent,post(3,'1.0',day='2026-10-31'),post(4,day='2026-10-28')],2)}
    requested=[]
    def loader(page): requested.append(page);return pages[page]
    incremental=live.normalize_ipaomtk(full,later,loader)
    assert requested==[1] and len(incremental['apps'])==4
    assert next(a for a in incremental['apps'] if a['catalogID']=='ipaomtk.post.1')['version']=='3.0'
    # Weekly full reconciliation removes entries deleted upstream.
    reconciled=live.normalize_ipaomtk(incremental,NOW+timedelta(days=8),lambda page:([post(3)],1))
    assert [a['catalogID'] for a in reconciled['apps']]==['ipaomtk.post.3']
    # One failing provider cannot overwrite the last good file or block the other feed.
    with tempfile.TemporaryDirectory() as folder:
        folder=Path(folder);live.write(folder/'ipaomtk.json',full);before=(folder/'ipaomtk.json').read_bytes()
        with patch.object(sys,'argv',['sync','--output',str(folder)]),patch.object(live,'fetch',return_value=(root,{})),patch.object(live,'normalize_ipaomtk',side_effect=RuntimeError('provider failed')):
            live.main()
        assert (folder/'ipaomtk.json').read_bytes()==before
        assert json.loads((folder/'status.json').read_bytes())['sources']['ipaomtk']['state']=='cached'
        assert (folder/'ipasoon.json').is_file()
    print('PASS: live feeds preserve version/URL pairs, remove private links, update stable rows, stop incremental scans, reconcile deletions and retain a failed provider independently')


if __name__=='__main__': main()
