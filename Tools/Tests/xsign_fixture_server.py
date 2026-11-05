"""Local-only HTTP fixtures for the real Swift catalog transport tests."""
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit,parse_qs
import json,sys,time,threading

lock=threading.Lock()
state={'catalog_requests':0,'body_requests':0,'broken':False}
catalog=Path('Feather/Resources/XSignCatalogIPAOMTKLive.json').read_bytes()
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path=urlsplit(self.path).path
        if path.startswith('/ipa/'):
            if path=='/ipa/forbidden': self.send(403,b'<html>permission required</html>');return
            if path=='/ipa/missing': self.send(200,b'{"success":false,"error":"not available"}');return
            if path=='/ipa/insecure': self.send(200,b'{"success":true,"download_url":"http://example.org/app.ipa"}');return
            query=parse_qs(urlsplit(self.path).query)
            expected={'bundleId':['org.fixture.app'],'name':['تطبيق + Test'],'id':['123']}
            if query!=expected or self.headers.get('Authorization'):
                self.send(400,b'{"success":false}');return
            self.send(200,b'{"success":true,"download_url":"https://example.org/app.ipa?signature=a%2Bb"}');return
        if path=='/stats':
            with lock: body=json.dumps(state).encode()
            self.send(200,body);return
        if path=='/break':
            with lock: state['broken']=True
            self.send(200,b'{}');return
        if path=='/invalid': self.send(200,b'<html>not a source</html>');return
        if path!='/catalog': self.send(503,b'{}');return
        with lock:
            state['catalog_requests']+=1
            broken=state['broken']
        time.sleep(.15)
        if broken: self.send(200,b'{"apps": "invalid"}');return
        if self.headers.get('If-None-Match')=='"fixture-v1"':
            self.send(304,b'');return
        with lock: state['body_requests']+=1
        self.send(200,catalog,'"fixture-v1"')
    def send(self,status,body,etag=None):
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body)))
        if etag: self.send_header('ETag',etag)
        self.end_headers()
        if body:self.wfile.write(body)
    def log_message(self,*args): pass

server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
