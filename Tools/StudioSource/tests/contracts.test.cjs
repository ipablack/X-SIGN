const test=require('node:test');
const assert=require('node:assert/strict');
const yaml=require('js-yaml');
const C=require('../src/contract.js');
const app=(id,extra={})=>({name:id,bundleIdentifier:'com.example.'+id,version:'1.0',downloadURL:'https://example.com/'+id+'.ipa',...extra});
const copy=C.copy;
test('independent local and remote edits merge without losing unknown fields',()=>{
 const base={name:'IPA BLACK',xsign_config:{theme:{tint:'#fff'},extra:{a:1}},apps:[app('a')]},local=copy(base),remote=copy(base);
 local.name='New name';remote.xsign_config.extra.b=2;remote.apps.push(app('b'));
 const merged=C.merge(base,local,remote);assert.equal(merged.name,'New name');assert.equal(merged.xsign_config.extra.b,2);assert.equal(merged.apps.length,2);
});
test('same-field edits produce a concrete conflict',()=>assert.throws(()=>C.merge({name:'A'},{name:'B'},{name:'C'}),e=>e.name==='MergeConflict'&&e.path==='name'));
test('remote upload remains visible when admin reorders the catalogue',()=>{
 const a=app('a'),b=app('b'),uploaded=app('new');const result=C.merge({apps:[a,b]},{apps:[b,a]},{apps:[uploaded,a,b]});
 assert.deepEqual(result.apps.map(a=>a.name),['new','b','a']);
});
test('two conflicting order changes stop publication',()=>{
 const a=app('a'),b=app('b'),c=app('c');assert.throws(()=>C.merge({apps:[a,b,c]},{apps:[b,a,c]},{apps:[a,c,b]}),e=>e.path==='apps.order');
});
test('delete vs server edit conflicts rather than losing either edit',()=>{
 const a=app('a');assert.throws(()=>C.merge({apps:[a]},{apps:[]},{apps:[{...a,name:'Edited'}]}),e=>e.name==='MergeConflict');
});
test('variants sharing a bundle use stable catalogue identities',()=>{
 const a=app('a',{catalogID:'a',bundleIdentifier:'com.shared.app'}),b=app('b',{catalogID:'b',bundleIdentifier:'com.shared.app'});
 const base={apps:[a,b]},local=copy(base),remote=copy(base);local.apps[0].name='New A';remote.apps[1].version='2.0';
 const merged=C.merge(base,local,remote);assert.equal(merged.apps[0].name,'New A');assert.equal(merged.apps[1].version,'2.0');
});
test('ambiguous variants without catalogue ids are refused for a merge',()=>{
 const base={apps:[app('a'),app('b',{bundleIdentifier:'com.example.a'})]},local=copy(base),remote=copy(base);
 local.apps[0].name='Changed';remote.apps[1].version='2';assert.throws(()=>C.merge(base,local,remote),/catalogID/);
});
test('independent version additions and unknown version metadata survive',()=>{
 const original={version:'1.0',downloadURL:'https://example.com/v1.ipa',minOSVersion:'15.0'};
 const base={apps:[app('a',{versions:[original]})]},local=copy(base),remote=copy(base);
 local.apps[0].versions.unshift({version:'2.0',downloadURL:'https://example.com/v2.ipa'});remote.apps[0].versions.unshift({version:'1.1',downloadURL:'https://example.com/v11.ipa'});
 const versions=C.merge(base,local,remote).apps[0].versions;assert.equal(versions.length,3);assert.equal(versions.find(v=>v.version==='1.0').minOSVersion,'15.0');
});
test('prototype keys and cyclic YAML structures are rejected',()=>{
 assert.throws(()=>C.safeTree(JSON.parse('{"__proto__":{"polluted":true}}')));const circular={};circular.self=circular;assert.throws(()=>C.safeTree(circular),/دائري/);assert.equal({}.polluted,undefined);
});
test('projection includes the same revision and nested config but no catalogue payload',()=>{
 const projected=C.project({name:'IPA BLACK',repo_revision_id:7,xsign_config:{theme:{app_tint_hex:'#000000'},future:{v:true}},apps:[app('a')],news:[{title:'Hi'}]});
 assert.equal(projected.repo_revision_id,7);assert.equal(projected.xsign_config.future.v,true);assert(!('apps' in projected));assert(!('news' in projected));
});
const modern=`name: IPA Manager
on:
  workflow_dispatch:
    inputs:
      operation:
        type: choice
        options: [publish, inspect]
        required: true
      ipa_url:
        type: string
        required: true
      skip_appstore:
        type: boolean
        default: true
  push:
    branches: [main, release/**]
    paths: [uploads/**]
env:
  XSIGN_STUDIO_UPLOAD_SCHEMA: sidecar-v1
jobs:
  ingest:
    steps:
      - uses: actions/checkout@v4
      - run: python3 scripts/ipa_manager.py
`;
test('workflow inputs are parsed from YAML rather than indentation guesses',()=>{
 const engine=C.readWorkflow(modern,yaml);assert(engine.dispatch);assert.deepEqual(engine.scripts,['scripts/ipa_manager.py']);
 const inputs=C.dispatchInputs(engine,{operation:'publish',ipa_url:'https://example.com/app.ipa',skip_appstore:true,unknown:'ignored'});assert.equal(inputs.operation,'publish');assert.equal(inputs.skip_appstore,true);assert(!('unknown' in inputs));
});
test('unsupported operation and unknown required inputs are blocked before dispatch',()=>{
 const engine=C.readWorkflow(modern.replace('[publish, inspect]','[inspect]'),yaml);assert.throws(()=>C.dispatchInputs(engine,{operation:'publish',ipa_url:'https://example.com/a.ipa'}));
 const extra=C.readWorkflow(modern.replace('      ipa_url:','      secret_input:\n        required: true\n        type: string\n      ipa_url:'),yaml);assert.throws(()=>C.dispatchInputs(extra,{operation:'publish',ipa_url:'https://example.com/a.ipa'}),/secret_input/);
});
test('file contracts honor branch, path, metadata layout, and checkout ref',()=>{
 const engine=C.readWorkflow(modern,yaml),contract=C.fileContract(engine,'release/v2','uploads/a.ipa');assert.equal(contract.metadataPath,'uploads/a.json');assert.equal(contract.manual,false);
 assert.throws(()=>C.fileContract(engine,'other','uploads/a.ipa'),/فرع/);assert.throws(()=>C.fileContract(engine,'main','somewhere/a.ipa'),/مسار/);
 const wrongCheckout=C.readWorkflow(modern.replace('- uses: actions/checkout@v4','- uses: actions/checkout@v4\n        with:\n          ref: main'),yaml);assert.throws(()=>C.fileContract(wrongCheckout,'release/v2','uploads/a.ipa'),/فرعاً ثابتاً/);
});
test('unknown upload contract stays blocked; explicit known legacy adapter is visible',()=>{
 const unknown=C.readWorkflow(modern.replace('  XSIGN_STUDIO_UPLOAD_SCHEMA: sidecar-v1','  OTHER: value'),yaml);assert.throws(()=>C.fileContract(unknown,'main','uploads/a.ipa'),/عقد/);
 const manual=C.fileContract(unknown,'main','uploads/a.ipa','legacy');assert.equal(manual.manual,true);assert.equal(manual.metadataPath,'uploads/meta.json');
 const automatic=C.fileContract(unknown,'main','uploads/a.ipa','auto',["metadata = json.load(open('uploads/meta.json'))"]);assert.equal(automatic.mode,'legacy');
});
test('URL validation never accepts credentials or non-HTTPS source links',()=>{for(const bad of ['http://example.com/a','https://user:pass@example.com','javascript:alert(1)','//example.com'])assert.equal(C.https(bad),false);assert(C.https('https://example.com/a.ipa'));});
