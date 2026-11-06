"""Read-only diagnostic for Feather's public manifest protocol; never sends signing material."""
import json,plistlib,secrets,urllib.parse,urllib.request,urllib.error
ORIGIN='https://api.palera.in'
class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None

def verify():
    payload='http://127.0.0.1:52345/ota/'+secrets.token_hex(32)+'/payload.ipa'
    params={'bundleid':'com.xsign.verification','name':'XSign','version':'2','fetchurl':payload}
    url=ORIGIN+'/genPlist?'+urllib.parse.urlencode(params,quote_via=urllib.parse.quote)
    client=urllib.request.build_opener(NoRedirects)
    request=urllib.request.Request(url,headers={'User-Agent':'XSign/1.0','Accept':'application/xml, application/octet-stream'})
    with client.open(request,timeout=20) as response:
        data=response.read(32769)
        if response.status!=200 or len(data)>32768: raise ValueError('Invalid service response')
    root=plistlib.loads(data)
    assert len(root['items'])==1
    assert root['items'][0]['assets']==[{'kind':'software-package','url':payload}]
    assert root['items'][0]['metadata']=={'bundle-identifier':params['bundleid'],'bundle-version':'2','kind':'software','title':'XSign'}
    print('PASS: Feather manifest service returned the expected bundle, build and loopback URL. No IPA or certificate was uploaded.')

if __name__=='__main__':
    try: verify()
    except urllib.error.HTTPError as error: raise SystemExit('Feather manifest service returned HTTP '+str(error.code)+'. No signing material was sent.')
    except Exception: raise SystemExit('Could not verify the external manifest service from this runner. This does not verify iPhone installation.')
