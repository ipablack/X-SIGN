const fs=require('node:fs');
const vm=require('node:vm');
const test=require('node:test');
const assert=require('node:assert/strict');
const yaml=require('js-yaml');
const {TextEncoder,TextDecoder}=require('node:util');
class Element {
 constructor(){this.value='';this.hidden=false;this.disabled=false;this.children=[];this.style={};this.dataset={};this.classList={toggle(){},add(){},remove(){}};}
 append(...v){this.children.push(...v)} replaceChildren(...v){this.children=v} setAttribute(){} addEventListener(){} close(){this.open=false} showModal(){this.open=true}
}
function runtime(handler,sharedStore){
 const elements=new Map(),stored=sharedStore||new Map(),session=new Map(),calls=[];
 const ctx=vm.createContext({URL,TextEncoder,TextDecoder,AbortController,setTimeout,clearTimeout,atob,btoa,jsyaml:yaml,Event:class{},fetch:async(url,opts)=>{calls.push({url,opts});return handler(url,opts,calls)},localStorage:{setItem:(k,v)=>stored.set(k,v),getItem:k=>stored.get(k)??null,removeItem:k=>stored.delete(k)},sessionStorage:{setItem:(k,v)=>session.set(k,v),getItem:k=>session.get(k)??null,removeItem:k=>session.delete(k)},document:{getElementById(id){if(!elements.has(id))elements.set(id,new Element());return elements.get(id)},querySelectorAll(){return []},createElement(){return new Element()},createElementNS(){return new Element()},createTextNode(v){return String(v)}}});
 let source=['contract.js','base.js','store.js'].map(name=>fs.readFileSync(require.resolve('../src/'+name),'utf8')).join('\n');
 source=source.replace("loadLocal();bindEvents();bindStoreEvents();renderAll();openPage(location.hash.slice(1)||'overview',false);",'');
 vm.runInContext(source,ctx);vm.runInContext("renderAll=()=>{};renderOverview=()=>{};renderPublish=()=>{};updateStatus=()=>{};toast=m=>{this.lastMessage=m};",ctx);
 const el=id=>ctx.document.getElementById(id);el('ghToken').value='test-token-not-a-real-secret';
 return {ctx,el,calls,stored,session,run:code=>vm.runInContext(code,ctx)};
}
const response=(status,value)=>({status,ok:status>=200&&status<300,json:async()=>value});
const file=data=>({type:'file',sha:'blob-sha',size:200,encoding:'base64',content:btoa(unescape(encodeURIComponent(JSON.stringify(data))))});
function configureJob(r){r.run("connection.branch='release/v2';state=normalizeState(createDefaultState());state.name='نسخة محلية';state.repo_revision_id=4;pendingPublish={connection:{...connection},remote:{head:'head-1',tree:'tree-1',data:normalizeState(createDefaultState())},snapshot:clone(state),local:clone(state),localAtReview:JSON.stringify(state)};pendingPublish.snapshot.repo_revision_id=5;");}
test('successful publication writes both files in one tree and uses the selected branch',async()=>{
 const r=runtime(async(url,opts)=>{if(url.endsWith('/git/trees'))return response(201,{sha:'tree-new'});if(url.endsWith('/git/commits'))return response(201,{sha:'commit-new'});if(url.includes('/git/refs/'))return response(200,{object:{sha:'commit-new'}});throw Error('Unexpected endpoint '+url);});configureJob(r);await r.run('publishNow()');
 const tree=JSON.parse(r.calls[0].opts.body);assert.equal(tree.base_tree,'tree-1');assert.deepEqual(tree.tree.map(x=>x.path),['repo.json','xsign-config.json']);
 const a=JSON.parse(tree.tree[0].content),b=JSON.parse(tree.tree[1].content);assert.equal(a.repo_revision_id,5);assert.equal(b.repo_revision_id,5);assert.equal(a.name,'نسخة محلية');assert.equal(b.name,a.name);assert(!('apps' in b));
 const patch=r.calls.find(x=>x.opts.method==='PATCH');assert(patch.url.endsWith('/git/refs/heads/release/v2'));assert.equal(JSON.parse(patch.opts.body).force,false);assert.equal(r.run('state.repo_revision_id'),5);assert.equal(r.run('isDirty()'),false);
 assert(![...r.stored.values(),...r.session.values()].some(v=>v.includes('test-token-not-a-real-secret')));
});
test('failed branch update preserves draft, revision, and last known baseline',async()=>{
 const r=runtime(async(url)=>{if(url.endsWith('/git/trees'))return response(201,{sha:'tree-new'});if(url.endsWith('/git/commits'))return response(201,{sha:'commit-new'});if(url.includes('/git/refs/'))return response(403,{});throw Error('Unexpected endpoint');});configureJob(r);await r.run('publishNow()');assert.equal(r.run('state.repo_revision_id'),4);assert.equal(r.run('lastPublishedAt'),null);assert(r.el('publishError').textContent.includes('403'));assert.equal(r.run('operationBusy'),false);
});
test('a reference race re-reads the branch and preserves a new server app',async()=>{
 let patches=0,trees=0;const remote={name:'IPA BLACK',repo_revision_id:8,apps:[{name:'Server upload',bundleIdentifier:'com.example.server',version:'1',downloadURL:'https://example.com/server.ipa'}]};
 const r=runtime(async(url,opts)=>{
  if(opts.method==='POST'&&url.endsWith('/git/trees'))return response(201,{sha:'new-tree-'+ ++trees});
  if(opts.method==='POST'&&url.endsWith('/git/commits'))return response(201,{sha:'new-commit-'+trees});
  if(opts.method==='PATCH'){patches++;return patches===1?response(422,{}):response(200,{object:{sha:'new-commit-'+trees}});}
  if(url.includes('/git/ref/heads/'))return response(200,{object:{sha:'new-head'}});
  if(url.endsWith('/git/commits/new-head'))return response(200,{tree:{sha:'server-tree'}});
  if(url.includes('/contents/repo.json?ref='))return response(200,file(remote));throw Error('Unexpected endpoint '+url);
 });configureJob(r);await r.run('publishNow()');assert.equal(patches,2);assert.equal(r.run('state.apps.length'),1);assert.equal(r.run('state.name'),'نسخة محلية');assert.equal(r.run('state.repo_revision_id'),9);
});
test('a same-field race stops before a second ref update',async()=>{
 let patches=0;const remote={name:'Remote rename',repo_revision_id:8,apps:[]};
 const r=runtime(async(url,opts)=>{if(opts.method==='POST'&&url.endsWith('/git/trees'))return response(201,{sha:'new-tree'});if(opts.method==='POST')return response(201,{sha:'new-commit'});if(opts.method==='PATCH'){patches++;return response(409,{})}if(url.includes('/git/ref/heads/'))return response(200,{object:{sha:'new-head'}});if(url.endsWith('/git/commits/new-head'))return response(200,{tree:{sha:'server-tree'}});if(url.includes('/contents/repo.json?ref='))return response(200,file(remote));throw Error('Unexpected endpoint');});configureJob(r);await r.run('publishNow()');assert.equal(patches,1);assert.equal(r.run('state.name'),'نسخة محلية');assert.equal(r.run('state.repo_revision_id'),4);assert(r.el('publishError').textContent.includes('name'));
});
test('snapshot reads file at the exact head, including a branch containing slash',async()=>{
 const r=runtime(async(url)=>{if(url.includes('/git/ref/heads/'))return response(200,{object:{sha:'exact-head'}});if(url.endsWith('/git/commits/exact-head'))return response(200,{tree:{sha:'exact-tree'}});if(url.includes('/contents/repo.json?ref=exact-head'))return response(200,file({name:'حفظ عربي',apps:[]}));throw Error('Non-snapshot read '+url)});
 const snapshot=await r.run("readCatalogueSnapshot({...connection,branch:'release/v2'},'test-token')");assert.equal(snapshot.data.name,'حفظ عربي');assert.equal(snapshot.head,'exact-head');assert(r.calls[0].url.endsWith('/git/ref/heads/release/v2'));
});
test('live snapshot also reads the configuration revision at the same commit',async()=>{
 const r=runtime(async(url)=>{
  if(url.includes('/git/ref/heads/'))return response(200,{object:{sha:'head'}});
  if(url.endsWith('/git/commits/head'))return response(200,{tree:{sha:'tree'}});
  if(url.includes('/contents/repo.json?ref=head'))return response(200,file({repo_revision_id:20,apps:[]}));
  if(url.includes('/contents/xsign-config.json?ref=head'))return response(200,file({repo_revision_id:25,xsign_config:{}}));
  throw Error('Unexpected endpoint '+url);
 });
 const snapshot=await r.run("readCatalogueSnapshot(connection,'test-token')");
 assert.equal(snapshot.data.repo_revision_id,20);
 assert.equal(snapshot.liveRevision,25);
});
test('workflow dispatch accepts 204 and sends the chosen branch and real inputs',async()=>{
 const r=runtime(async(url,opts)=>{if(url.includes('/runs?'))return response(200,{workflow_runs:[]});if(url.endsWith('/dispatches'))return response(204,null);throw Error('Unexpected endpoint '+url)});
 r.run("preparedUpload={c:{...connection,branch:'release/v2'},mode:'url',inputs:{ipa_url:'https://example.com/a.ipa',skip_appstore:true},metadata:{}};");await r.run('sendIngest()');const request=r.calls.find(x=>x.opts.method==='POST'),body=JSON.parse(request.opts.body);assert.equal(body.ref,'release/v2');assert.equal(body.inputs.skip_appstore,true);assert.equal(r.run('preparedUpload'),null);assert(r.ctx.lastMessage.includes('أُرسلت'));
});
test('queue guard checks status endpoints rather than only the most recent 30 runs',async()=>{
 const r=runtime(async(url)=>response(200,{workflow_runs:url.includes('status=waiting')?[{id:1,status:'waiting',head_branch:'main'}]:[]}));r.run("preparedUpload={c:{...connection},mode:'url',inputs:{ipa_url:'https://example.com/a.ipa'},metadata:{}};");await r.run('sendIngest()');assert(!r.calls.some(x=>x.opts.method==='POST'));assert(r.el('ingestReviewError').textContent.includes('عملية أخرى'));
});
test('publication cannot use the same path for catalogue and configuration',()=>{const r=runtime(()=>{throw Error('No request expected')});assert.throws(()=>r.run("validateConnection({...connection,configPath:'repo.json'})"),/مسارين مختلفين/);});
test('IPA and its sidecar share one commit; sending does not invent a catalogue entry',async()=>{
 const r=runtime(async(url,opts)=>{
  if(url.includes('/runs?'))return response(200,{workflow_runs:[]});
  if(url.endsWith('/git/blobs'))return response(201,{sha:'ipa-blob'});
  if(url.endsWith('/git/trees'))return response(201,{sha:'queue-tree'});
  if(url.endsWith('/git/commits'))return response(201,{sha:'queue-commit'});
  if(url.includes('/git/refs/'))return response(200,{object:{sha:'queue-commit'}});
  throw Error('Unexpected endpoint '+url);
 });
 r.ctx.fixtureFile={arrayBuffer:async()=>new Uint8Array([80,75,3,4,97,98]).buffer};
 r.run("preparedUpload={c:{...connection,branch:'release/v2'},mode:'file',file:fixtureFile,path:'uploads/pkg_qa.ipa',contract:{metadataPath:'uploads/pkg_qa.json'},head:{head:'head-reviewed',tree:'tree-reviewed'},metadata:{name:'IPA BLACK QA',skip_appstore:true}};");
 await r.run('sendIngest()');
 const tree=JSON.parse(r.calls.find(c=>c.url.endsWith('/git/trees')).opts.body);
 assert.equal(tree.base_tree,'tree-reviewed');assert.deepEqual(tree.tree.map(f=>f.path),['uploads/pkg_qa.ipa','uploads/pkg_qa.json']);assert.equal(tree.tree[0].sha,'ipa-blob');assert.equal(JSON.parse(tree.tree[1].content).skip_appstore,true);
 const commit=JSON.parse(r.calls.find(c=>c.url.endsWith('/git/commits')).opts.body);assert.deepEqual(commit.parents,['head-reviewed']);assert.equal(r.run('state.apps.length'),0);assert.equal(r.run('preparedUpload'),null);
});
test('IPA queue ref conflicts never force or silently retry a stale upload',async()=>{
 let patches=0;
 const r=runtime(async(url,opts)=>{if(url.includes('/runs?'))return response(200,{workflow_runs:[]});if(url.endsWith('/git/blobs'))return response(201,{sha:'ipa'});if(url.endsWith('/git/trees'))return response(201,{sha:'tree'});if(url.endsWith('/git/commits'))return response(201,{sha:'commit'});if(opts.method==='PATCH'){patches++;assert.equal(JSON.parse(opts.body).force,false);return response(422,{})}throw Error('Unexpected endpoint')});
 r.ctx.fixtureFile={arrayBuffer:async()=>new Uint8Array([80,75]).buffer};
 r.run("preparedUpload={c:{...connection},mode:'file',file:fixtureFile,path:'uploads/pkg_qa.ipa',contract:{metadataPath:'uploads/meta.json'},head:{head:'old-head',tree:'old-tree'},metadata:{}};");
 await r.run('sendIngest()');assert.equal(patches,1);assert.equal(r.run('preparedUpload'),null);assert(r.el('ingestReviewError').textContent.includes('أعد فحص المحرك'));
});
test('a local edit made while a baseline-free pull is pending is never discarded',async()=>{
 let r;
 r=runtime(async(url)=>{
  if(url.includes('/git/ref/heads/')){r.run("state.name='Edit while fetching'");return response(200,{object:{sha:'head'}})}
  if(url.endsWith('/git/commits/head'))return response(200,{tree:{sha:'tree'}});
  if(url.includes('/contents/repo.json?ref='))return response(200,file({name:'Remote catalogue',apps:[]}));
  if(url.includes('/contents/xsign-config.json?ref='))return response(404,{});
  throw Error('Unexpected endpoint');
 });
 r.run('baseline=JSON.stringify(state)');await r.run('requestPull()');
 assert.equal(r.run('state.name'),'Edit while fetching');assert.equal(r.run('remoteBaseline'),null);assert(r.ctx.lastMessage.includes('تغيرت المسودة أثناء الجلب'));
});
test('a stale window cannot overwrite a newer local draft, and can load the latest explicitly',()=>{
 const shared=new Map(),noFetch=()=>{throw Error('No network expected')},a=runtime(noFetch,shared),b=runtime(noFetch,shared);
 a.run('loadLocal()');b.run('loadLocal()');
 a.run("state.name='Newest window';persist()");
 b.run("state.name='Stale window';persist()");
 const stored=JSON.parse(shared.get('xsign.studio.state.v3'));
 assert.equal(stored.name,'Newest window');assert.equal(b.run('externalDraftChanged'),true);assert.equal(b.run('storageError'),true);assert.equal(b.run('state.name'),'Stale window');
 b.run('loadNewestLocalDraft()');assert.equal(b.run('state.name'),'Newest window');assert.equal(b.run('externalDraftChanged'),false);
});
