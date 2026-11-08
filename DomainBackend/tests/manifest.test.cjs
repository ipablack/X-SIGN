'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {createHandler, validate, seal, unseal, manifest} = require('../functions/core.cjs');
const key = crypto.randomBytes(32), now = 1762350000;
const descriptor = {payloadURL:'http://127.0.0.1:52345/ota/'+'a'.repeat(64)+'/payload.ipa',
 bundleIdentifier:'com.ipablack.demo', bundleVersion:'1.2', title:'تجربة <X> & "توقيع"', expiresAt:now+1800};
function invoke(handler, path, method='GET', body, headers={}) {
 let result = {statusCode:200, headers:{}, body:''};
 result.setHeader = (name,value) => {result.headers[name.toLowerCase()]=value;};
 result.end = text => {result.body=text||'';};
 handler({url:path,method,headers,rawBody:body,ip:'127.0.0.1'},result);
 return result;
}
const handler = () => createHandler({keyProvider:()=>key.toString('hex'),clock:()=>now});
test('opaque authenticated tickets hide the local IPA URL and preserve metadata',()=>{
 const ticket=seal(validate(descriptor,now),key);
 assert.ok(!ticket.includes('127.0.0.1') && !Buffer.from(ticket,'base64url').includes(Buffer.from('payload.ipa')));
 assert.deepEqual(unseal(ticket,key,now),descriptor);
 assert.throws(()=>unseal(ticket,crypto.randomBytes(32),now));
 const changed=Buffer.from(ticket,'base64url'); changed[30]^=1;
 assert.throws(()=>unseal(changed.toString('base64url'),key,now));
 assert.throws(()=>unseal(ticket,key,now+1801));
});
test('prepare and manifest route round trip without returning a download link in prepare',()=>{
 const app=handler();
 const prepared=invoke(app,'/native/prepare','POST',Buffer.from(JSON.stringify(descriptor)),{'content-type':'application/json'});
 assert.equal(prepared.statusCode,200);
 const reply=JSON.parse(prepared.body);assert.equal(new URL(reply.manifestURL).hostname,'x-sign.web.app');
 assert.ok(!prepared.body.includes('127.0.0.1') && !prepared.body.includes('payload.ipa'));
 const xml=invoke(app,new URL(reply.manifestURL).pathname+new URL(reply.manifestURL).search);
 assert.equal(xml.statusCode,200);assert.match(xml.body,/software-package/);assert.match(xml.body,/&lt;X&gt; &amp;/);
 assert.equal(xml.headers['cache-control'],'no-store, max-age=0');
 assert.ok(!('access-control-allow-origin' in xml.headers));
});
test('unsafe schemes, paths, credentials and arbitrary hosts are rejected; no URL is fetched',()=>{
 for(const payloadURL of ['http://localhost.backloop.dev:52345/ota/'+'a'.repeat(64)+'/payload.ipa',
 'https://example.org:52345/ota/'+'a'.repeat(64)+'/payload.ipa',
 'https://localhost.backloop.dev.evil.test:52345/ota/'+'a'.repeat(64)+'/payload.ipa',
 descriptor.payloadURL+'?query=1',descriptor.payloadURL+'#fragment',
 descriptor.payloadURL.replace('http://','http://user:password@'),descriptor.payloadURL.replace('/ota/','/other/'),
 descriptor.payloadURL.replace('127.0.0.1','127.1'), descriptor.payloadURL.replace('127.0.0.1','192.168.1.1')]) {
  assert.throws(()=>validate({...descriptor,payloadURL},now));
 }
 assert.throws(()=>validate({...descriptor,extra:'unexpected'},now));
 assert.throws(()=>validate({...descriptor,title:'\0invalid'},now));
});
test('request method, origin, oversized body, content type and fake tickets fail closed',()=>{
 const app=handler();
 assert.equal(invoke(app,'/native/prepare','GET').statusCode,405);
 assert.equal(invoke(app,'/native/prepare','POST',Buffer.alloc(9000),{'content-type':'application/json'}).statusCode,413);
 assert.equal(invoke(app,'/native/prepare','POST',Buffer.from('{}'),{'content-type':'text/plain'}).statusCode,415);
 assert.equal(invoke(app,'/native/status','GET',undefined,{origin:'https://evil.test'}).statusCode,403);
 assert.equal(invoke(app,'/native/manifest.plist?ticket=invalid').statusCode,400);
 assert.equal(invoke(app,'/native/payload.ipa').statusCode,404);
 assert.equal(invoke(createHandler({keyProvider:()=>'',clock:()=>now}),'/native/status').statusCode,503);
});
test('best-effort per-instance limits reject excess requests',()=>{
 const app=createHandler({keyProvider:()=>key.toString('hex'),clock:()=>now,rateLimit:1});
 assert.equal(invoke(app,'/native/status').statusCode,200);
 assert.equal(invoke(app,'/native/status').statusCode,429);
});

test('a newline from openssl secret generation is accepted',()=>{
 const app=createHandler({keyProvider:()=>key.toString('hex')+'\n',clock:()=>now});
 assert.equal(invoke(app,'/native/status').statusCode,200);
});
