/* Export the real panel defaults; never read or overwrite a live catalogue. */
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'../StudioSource');
const context=vm.createContext({URL,TextEncoder,TextDecoder,AbortController,atob,btoa,
 crypto:require('node:crypto').webcrypto,setTimeout:()=>1,clearTimeout(){},
 document:{getElementById:()=>({}),querySelectorAll:()=>[]},
 localStorage:{getItem:()=>null,setItem(){}},sessionStorage:{getItem:()=>null,setItem(){},removeItem(){}}});
const boot="loadLocal();bindEvents();bindStoreEvents();renderAll();openPage(location.hash.slice(1)||'overview',false);";
for(const name of ['contract.js','base.js','store.js','integration.js']){
 vm.runInContext(fs.readFileSync(path.join(root,'src',name),'utf8').replace(boot,''),context,{filename:name});
}
const errors=vm.runInContext('validateState(state)',context);
if(errors.length)throw Error('Invalid panel defaults: '+errors.join('; '));
const destination=process.argv[2];
if(!destination)throw Error('Specify a destination for the empty source template.');
fs.writeFileSync(destination,vm.runInContext('JSON.stringify(normalizeState(createDefaultState()),null,2)',context)+'\n');
console.log('Exported the current panel defaults with no sample IPA or credentials.');
