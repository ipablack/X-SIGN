from pathlib import Path
import importlib.util, json, tempfile, zipfile

module_path=Path(__file__).resolve().parents[1]/'Extract_IPASoon_Sources.py'
spec=importlib.util.spec_from_file_location('extract_feeds',module_path)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

def main():
    rows=[
        {'name':'Fixture Standard','bundleIdentifier':'org.fixture.app','version':'2.0','downloadURL':'https://example.org/app.ipa','localizedDescription':'reference https://private.example/app?token=PRIVATE'},
        {'name':'Fixture Standard','bundleIdentifier':'org.fixture.app','version':'2.0','downloadURL':'https://example.org/app.ipa'},
        {'name':'Fixture Plus','bundleIdentifier':'org.fixture.app','version':'3.0','downloadURL':'https://private.example/app?token=PRIVATE','versions':[{'version':'1.0','downloadURL':'https://example.org/old.ipa','date':'2026-01-01 10:20:30','size':8}]},
        {'name':'Private','bundleIdentifier':'org.fixture.private','downloadURL':'https://private.example/app?TOKEN='},
        {'name':'No URL','bundleIdentifier':'org.fixture.missing'},
    ]
    data={'name':'Fixture','apps':rows,'categories':[{'value':'games','label':'Games'}],'gameCategories':[{'value':'games','label':'Games'}]}
    with tempfile.TemporaryDirectory() as folder:
        folder=Path(folder);ipa=folder/'fixture.ipa'
        with zipfile.ZipFile(ipa,'w') as archive:
            for feed in module.FEEDS: archive.writestr('Payload/Fixture.app/'+feed,json.dumps(data))
        results=module.extract(ipa,folder/'feeds')
        assert len(results)==3
        for result in results:
            source=json.loads((folder/'feeds'/result['file']).read_text())
            assert len(source['apps'])==2
            assert len({row['catalogID'] for row in source['apps']})==2
            assert source['apps'][1]['version']=='1.0' and source['apps'][1]['downloadURL']=='https://example.org/old.ipa'
            assert source['categories']==[{'id':'games','name':'Games','isGame':True}]
            assert 'PRIVATE' not in json.dumps(source)
            assert source['xsign_snapshot']['automatic_upstream_refresh'] is False
    for value in ['https://user:password@example.org/a.ipa','file:///tmp/a.ipa','https://private.example/a?X-Amz-Signature=secret','https://private.example/a?token=']:
        assert module.public_url(value) is None
    print('PASS: actual IPA feed extraction retains mod variants, deduplicates rows, keeps version/URL pairs coherent and excludes credentials including empty-token links')

if __name__=='__main__': main()
