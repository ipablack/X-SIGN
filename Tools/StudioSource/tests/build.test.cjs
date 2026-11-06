const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
test('the complete delivered HTML has valid inline JavaScript after bundling',()=>{
 const html=fs.readFileSync(path.join(root,'dist/index.html'),'utf8');
 const scripts=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match=>match[1]);
 assert.equal(scripts.length,1);assert.doesNotThrow(()=>new vm.Script(scripts[0],{filename:'XSign_Studio.html'}));
 assert.ok(!html.endsWith('\n\n'),'The checked HTML must not add blank lines at EOF');
 assert.ok(scripts[0].includes('loadLocal();bindEvents();bindStoreEvents();renderAll();'));
});
test('the embedded YAML parser preserves literal Unicode separators byte for byte',()=>{
 const html=fs.readFileSync(path.join(root,'dist/index.html'),'utf8');
 const vendor=fs.readFileSync(path.join(root,'node_modules/js-yaml/dist/js-yaml.min.js'),'utf8').trimEnd();
 assert.ok(vendor.includes('\u0085'),'The regression fixture must contain the literal NEL');
 assert.ok(html.includes(vendor),'Bundling must not translate Unicode separators inside quoted JavaScript into line feeds');
});
