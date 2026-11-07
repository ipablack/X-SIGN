"""Read-only verification using a dummy local URL; never uploads IPA or certificate data."""
import json,urllib.request,urllib.parse,plistlib,secrets,time,sys
ROOT='https://x-sign.web.app'
class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None
client=urllib.request.build_opener(NoRedirects)
def read(request,limit=32768):
    with client.open(request,timeout=20) as response:
        data=response.read(limit+1)
        if len(data)>limit or response.status!=200:raise RuntimeError('Invalid service response')
        return data
def verify():
    status=json.loads(read(ROOT+'/native/status'))
    assert status=={'service':'xsign-native-ota','version':1,'ready':True}
    payload='https://localhost.backloop.dev:52345/ota/'+secrets.token_hex(32)+'/payload.ipa'
    descriptor={'payloadURL':payload,'bundleIdentifier':'com.ipablack.verification','bundleVersion':'1.0',
                'title':'XSign Verification','expiresAt':int(time.time())+600}
    reply=json.loads(read(urllib.request.Request(ROOT+'/native/prepare',data=json.dumps(descriptor).encode(),
        headers={'Content-Type':'application/json'},method='POST')))
    url=urllib.parse.urlsplit(reply['manifestURL'])
    assert url.scheme=='https' and url.netloc=='x-sign.web.app' and url.path=='/native/manifest.plist'
    record=plistlib.loads(read(reply['manifestURL']))
    assert record['items'][0]['assets']==[{'kind':'software-package','url':payload}]
    metadata=record['items'][0]['metadata']
    assert metadata['bundle-identifier']==descriptor['bundleIdentifier']
    assert metadata['bundle-version']==descriptor['bundleVersion']
    assert metadata['title']==descriptor['title']
    print('PASS: x-sign.web.app serves the correct private manifest protocol. No IPA or signing credential was uploaded.')

if __name__=='__main__':
    try:verify()
    except Exception:
        sys.exit('XSign domain is not ready: deploy DomainBackend to the EXISTING x-sign.web.app Firebase website, then run this workflow again. No IPA or signing credential was sent.')
