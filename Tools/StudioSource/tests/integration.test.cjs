const fs=require('node:fs'),vm=require('node:vm'),test=require('node:test'),assert=require('node:assert/strict');
const C=require('../src/contract.js');
function runtime(){
  const nodes=new Map(),local=new Map(),session=new Map();
  class Element {constructor(){this.value='';this.checked=false;this.style={};this.dataset={};this.children=[];this.options=[];this.classList={toggle(){},add(){},remove(){}};}append(...nodes){this.children.push(...nodes);this.options.push(...nodes);}replaceChildren(...nodes){this.children=nodes;this.options=nodes;}setAttribute(){}removeAttribute(){}addEventListener(){}focus(){}}
  const el=id=>{if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id);};
  const ctx=vm.createContext({URL,TextEncoder,TextDecoder,AbortController,atob,btoa,crypto:require('node:crypto').webcrypto,
    setTimeout:()=>1,clearTimeout(){},document:{getElementById:el,querySelectorAll:()=>[],createElement:()=>new Element(),createElementNS:()=>new Element(),createTextNode:s=>s},
    localStorage:{getItem:k=>local.get(k)??null,setItem:(k,v)=>local.set(k,v)},
    sessionStorage:{getItem:k=>session.get(k)??null,setItem:(k,v)=>session.set(k,v),removeItem:k=>session.delete(k)}});
  const boot="loadLocal();bindEvents();bindStoreEvents();renderAll();openPage(location.hash.slice(1)||'overview',false);";
  vm.runInContext(['contract.js','base.js','store.js','integration.js'].map(f=>fs.readFileSync(require.resolve('../src/'+f),'utf8').replace(boot,'')).join('\n'),ctx);
  const run=s=>vm.runInContext(s,ctx);run('renderOverview=()=>{};updateStatus=()=>{};toast=()=>{};');
  return {run,el,ctx};
}
test('defaults provide native dashboard v2 and validate without sample apps',()=>{const r=runtime();assert.equal(r.run('state.xsign_config.dashboard.schema_version'),2);assert.equal(r.run('validateState(state).length'),0);assert.equal(r.run('state.apps.length'),0);});
test('published signing libraries retain app selection and reject malformed downloads',()=>{
  const r=runtime();
  r.run("this.library={id:'1'.repeat(32),name:'Example',url:'https://example.test/Test.dylib',sha256:'a'.repeat(64),bundles:['com.example.app'],enabled:true}");
  r.run("state=normalizeState({xsign_config:{dashboard:{signing_libraries:[library]}}})");
  assert.equal(r.run('dashboardErrors(state).length'),0);
  assert.equal(r.run('publicationConfiguration(state).xsign_config.dashboard.signing_libraries[0].bundles[0]'),'com.example.app');
  assert.equal(r.run('signingLibraryError([{...library,enabled:false}])'),'');
  for(const changes of [
    {sha256:''},{bundles:['*']},{bundles:[]},{url:'http://example.test/example.dylib'},
    {url:'https://example.test/example.ipa'},{url:'https://example.test/example.dylib?token=key'}
  ]){
    r.ctx.changes=changes;
    assert.notEqual(r.run('signingLibraryError([{...library,...changes}])'),'');
  }
  assert.notEqual(r.run('signingLibraryError([library, library])'),'');
});
test('usage reporting is optional and survives import and publication without owner credentials',()=>{
  const r=runtime();assert.equal(r.run('state.xsign_config.usage_stats.enabled'),false);
  r.run("state=normalizeState({xsign_config:{usage_stats:{enabled:true,endpoint:'https://usage.example',ADMIN_TOKEN:'never-publish'}}})");
  assert.equal(r.run('validateState(state).length'),0);
  r.el('usageAdminToken').value='owner-secret-in-memory';
  assert.equal(r.run('publicationConfiguration(state).xsign_config.usage_stats.endpoint'),'https://usage.example');
  assert(!r.run('JSON.stringify(publicationConfiguration(state))').includes('never-publish'));
  assert(!r.run('JSON.stringify(publicationConfiguration(state))').includes('owner-secret-in-memory'));
  for(const endpoint of ['http://usage.example','https://a:b@usage.example','https://usage.example/path','https://usage.example?secret=1','https://usage.example#key']){
    r.ctx.endpoint=endpoint;r.run('state.xsign_config.usage_stats.endpoint=endpoint');
    assert(r.run('dashboardErrors(state)').some(e=>e.includes('الإحصاءات')));
  }
  r.run("state.xsign_config.usage_stats={enabled:true,endpoint:''}");
  assert(r.run('dashboardErrors(state)').some(e=>e.includes('الإحصاءات')));
});
test('usage summary validates counts and unique countries before displaying data',()=>{
  const r=runtime();r.run("this.summary={schema_version:1,generated_at:1780000000,timezone:'UTC',online_window_seconds:300,total_installations:4,online:1,active_today:2,active_30d:3,countries:[{country:'IQ',users:2},{country:'DE',users:1}]}");
  assert.equal(r.run('checkedUsageSummary(summary).total_installations'),4);
  r.run('summary.countries.push({country:"IQ",users:1})');assert.throws(()=>r.run('checkedUsageSummary(summary)'));
  r.run('summary.countries.pop();summary.active_30d=2');assert.throws(()=>r.run('checkedUsageSummary(summary)'));
  r.run('summary.active_30d=3;summary.online=-1');assert.throws(()=>r.run('checkedUsageSummary(summary)'));
});
test('owner stats fetch uses no cookies or redirect and ignores an old service response',async()=>{
  const r=runtime();r.run("state.xsign_config.usage_stats={enabled:true,endpoint:'https://usage.example'};renderUsageStats()");
  r.el('usageAdminToken').value='a'.repeat(48);
  let complete;
  r.ctx.fetch=async(url,options)=>{
    assert.equal(url,'https://usage.example/v1/summary');
    assert.equal(options.headers.Authorization,'Bearer '+'a'.repeat(48));
    assert.equal(options.credentials,'omit');assert.equal(options.redirect,'error');assert.equal(options.referrerPolicy,'no-referrer');
    await new Promise(resolve=>complete=resolve);
    return {ok:true,headers:{get:()=>null},text:async()=>JSON.stringify({schema_version:1,generated_at:1780000000,
      timezone:'UTC',online_window_seconds:300,total_installations:1,online:1,active_today:1,active_30d:1,countries:[{country:'IQ',users:1}]})};
  };
  const pending=r.run('refreshUsageStats()');
  r.run("state.xsign_config.usage_stats.endpoint='https://new.example';renderUsageStats()");
  complete();await pending;
  assert.equal(r.el('usageTotal').textContent,'—');assert.equal(r.el('usageAdminToken').value,'');
});
test('real zero stats display as zero; authentication errors never fabricate usage',async()=>{
  const r=runtime();r.run("state.xsign_config.usage_stats={enabled:true,endpoint:'https://usage.example'};renderUsageStats()");
  r.el('usageAdminToken').value='a'.repeat(48);
  r.ctx.fetch=async()=>({ok:false,status:404});
  await r.run('refreshUsageStats()');assert.equal(r.el('usageTotal').textContent,'—');
  assert(r.el('usageStatus').textContent.includes('رمز المالك'));
  r.ctx.fetch=async()=>({ok:true,headers:{get:()=>null},text:async()=>JSON.stringify({schema_version:1,generated_at:1780000000,
    timezone:'UTC',online_window_seconds:300,total_installations:0,online:0,active_today:0,active_30d:0,countries:[]})});
  await r.run('refreshUsageStats()');assert.equal(r.el('usageTotal').textContent,new Intl.NumberFormat('ar').format(0));
  assert(r.el('usageStatus').textContent.includes('آخر تحديث'));
});
test('uploaded Studio keeps an old draft while migrating its known previous app identity',()=>{const r=runtime();
 const meta=r.run('META_KEY'),key=r.run('STORAGE_KEY');
 const draft={apps:[{name:'Keep my app',bundleIdentifier:'com.example.keep',version:'1.0',downloadURL:'https://example.com/app.ipa'}],future:{keep:true},xsign_config:{theme:{app_tint_hex:'#112233'},dashboard:{sources:[]}}};
 r.ctx.localStorage.getItem=name=>name===meta?JSON.stringify({connection:{appBundle:'thewonderofyou.Feather'}}):name===key?JSON.stringify(draft):null;
 r.run('loadLocal()');assert.equal(r.run('connection.appBundle'),'Xsign');assert.equal(r.run('state.apps[0].name'),'Keep my app');
 assert.equal(r.run('state.future.keep'),true);assert.equal(r.run('state.xsign_config.theme.app_tint_hex'),'#112233');assert.equal(r.run('state.xsign_config.dashboard.sources.length'),1);
});
test('self update adoption rejects an IPA from the previous bundle after the identity change',()=>{const r=runtime();
 r.run("this.previous={bundleIdentifier:'thewonderofyou.Feather',version:'1.0',downloadURL:'https://example.com/old.ipa',sha256:'a'.repeat(64)}");
 assert.throws(()=>r.run('ownerUpdateFromApp(previous,XSIGN_INTEGRATION.bundle)'),/Bundle ID/);
 assert.equal(r.run('state.xsign_config.dashboard.update.enabled'),false);
});
test('managed source ordering matches native priority and preserves custom order',()=>{const r=runtime();
 r.run("state.xsign_config.dashboard.sources=[{id:'b',name:'B',url:'https://example.com/b'},{id:'plus',name:'Plus',url:PRIMARY_SOURCE_URL},{id:'a',name:'A',url:'https://example.com/a'},{id:'owner',name:'Owner',url:'https://github.com/ipablack/repo/raw/refs/heads/main/repo.json'}];state=normalizeState(state)");
 assert.equal(r.run('state.xsign_config.dashboard.sources.map(s=>s.id).join(",")'),'xsign.core.owned,b,plus,a');
 r.run('enforceCoreSources(state)');assert.equal(r.run('state.xsign_config.dashboard.sources.map(s=>s.id).join(",")'),'xsign.core.owned,b,plus,a');
 r.run('state.xsign_config.dashboard.sources=[];state=normalizeState(state)');assert.equal(r.run('state.xsign_config.dashboard.sources.length'),1);
});
test('GitHub aliases cannot publish duplicate managed sources',()=>{const r=runtime();r.run("state.xsign_config.dashboard.sources.push({id:'alias',name:'Alias',url:'https://github.com/ipablack/repo/raw/refs/heads/main/repo.json',enabled:true,format:'auto'})");assert(r.run('dashboardErrors(state)').some(e=>e.includes('مكرر')));});
test('only IPA BLACK is permanent and other default sources stay deleted',()=>{const r=runtime();
 assert.equal(r.run('state.xsign_config.dashboard.sources.map(s=>s.id).join(",")'),'xsign.core.owned,xsign.core.primary');
 r.run("state.xsign_config.dashboard.sources=[];state=normalizeState(state)");
 assert.equal(r.run('state.xsign_config.dashboard.sources.length'),1);
 assert.equal(r.run('state.xsign_config.app_control.core_sources.length'),1);
 assert.equal(r.run('state.xsign_config.app_control.core_sources[0].url'),r.run('OWNED_CANONICAL_URL'));
 r.run('state.xsign_config.dashboard.sources=[];state=normalizeState(state)');
 assert.equal(r.run('state.xsign_config.app_control.core_sources.length'),1);
 assert.equal(r.run('dashboardErrors(state).length'),0);
});
test('explicit legacy sources survive without inserting previously absent providers',()=>{const r=runtime();
 r.run("state=normalizeState({apps:[],xsign_config:{app_control:{core_sources:[{id:'legacy',name:'Plus',url:'https://supapi.trystore.net/rest/v1/plus_library_apps'}]}}})");
 assert.equal(r.run('state.xsign_config.dashboard.sources.map(s=>s.id).join(",")'),'xsign.core.owned,legacy');
});
test('legacy Today gets content and explicit v3 removal remains authoritative',()=>{const r=runtime();
 r.run("state=normalizeState({apps:[],xsign_config:{dashboard:{experience_version:2,sections:[{id:'today-news',title:'News',page:'today',kind:'news'}]}}})");
 assert.equal(r.run('state.xsign_config.dashboard.sections.map(s=>s.id).join(",")'),'today-news,today-featured,today-apps');
 r.run("state.xsign_config.dashboard.sections=state.xsign_config.dashboard.sections.slice(0,1);state.xsign_config.dashboard.today_show_account=false;state=normalizeState(state)");
 assert.equal(r.run('state.xsign_config.dashboard.sections.length'),1);
 assert.equal(r.run('Store.project(state).xsign_config.dashboard.today_show_account'),false);
 assert.equal(r.run('Store.project(state).xsign_config.dashboard.experience_version'),3);
});
test('VPN control is saved in the same projection as release and Today controls',()=>{const r=runtime();
 r.run("managedUpdateBundle=XSIGN_LEGACY_BUNDLE;state.xsign_config.security_locks.anti_vpn_proxy=true;setReleaseMode('required');state.xsign_config.dashboard.today_show_download_buttons=false");
 assert.equal(r.run('Store.project(state).xsign_config.security_locks.anti_vpn_proxy'),true);
 assert.equal(r.run('Store.project(state).xsign_config.dashboard.update.required_policy'),'approved');
 assert.equal(r.run('Store.project(state).xsign_config.dashboard.today_show_download_buttons'),false);
});
test('non-AltStore source mapping survives export without changing owner configuration endpoint',()=>{const r=runtime();
 r.run("state.xsign_config.dashboard.sources=[{id:'custom',name:'Custom JSON',url:'https://example.com/catalogue',enabled:true,format:'json',root_path:'data.items',icon_url:'https://example.com/logo.png',fields:{name:'title',bundleIdentifier:'bundle_id',downloadURL:'files.ipa',iconURL:'logo'}}];state=normalizeState(state)");
 assert.equal(r.run('validateState(state).length'),0);assert.equal(r.run('state.xsign_config.app_control.core_sources[1].id'),'custom');
 assert.equal(r.run('state.xsign_config.dashboard.sources[1].fields.downloadURL'),'files.ipa');assert.equal(r.run('XSIGN_INTEGRATION.source'),'IPA BLACK');
});
test('Today uses the active primary source slot and preserves its REST options',()=>{const r=runtime();
 r.run("const dashboard=state.xsign_config.dashboard;const source=dashboard.sources.find(source=>source.id==='xsign.core.primary');Object.assign(source,{url:'https://catalog.example.test/rest/apps',format:'rest',numeric_types:true});dashboard.sections[0].source_url=source.url");
 assert.equal(r.run('dashboardErrors(state).length'),0);
 assert.equal(r.run("Store.project(state).xsign_config.dashboard.sources.find(source=>source.id==='xsign.core.primary').numeric_types"),true);
 r.run('dashboard.sections[0].source_url=PRIMARY_SOURCE_URL');
 assert(r.run('dashboardErrors(state)').some(error=>error.includes('مصدراً موجوداً')));
});
test('Today accepts custom managed sources and preserves explicit empty selection',()=>{
  const r=runtime();
  r.run(`const d=state.xsign_config.dashboard;
    d.sources.push({id:'curated',name:'Curated',url:'https://catalogue.example.test/apps',enabled:true,format:'auto'});
    d.today_source_ids=['xsign.core.primary','curated'];
    d.sections[0].source_url=d.sources.at(-1).url;`);
  assert.equal(r.run('dashboardErrors(state).length'),0);
  assert.equal(r.run("Store.project(state).xsign_config.dashboard.today_source_ids.includes('curated')"),true);
  r.run("deleteManagedSource(d.sources.find(source=>source.id==='xsign.core.primary'),d.sources)");
  assert.equal(r.run('d.today_source_ids.join()'),'curated');
  r.run('d.today_source_ids=[];state=normalizeState(state)');
  assert.equal(r.run('todaySelection(state.xsign_config.dashboard).length'),0);
});
test('one active category section per page preserves the panel layout and saved alternatives',()=>{
  const r=runtime();
  r.run("const layout=state.xsign_config.dashboard.sections;layout.push({id:'apps-extra-category',title:'Other categories',page:'apps',kind:'categories'});state=normalizeState(state)");
  assert.equal(r.run("state.xsign_config.dashboard.sections.filter(s=>s.page==='apps'&&s.kind==='categories'&&s.enabled).length"),1);
  assert.equal(r.run("state.xsign_config.dashboard.sections.find(s=>s.id==='apps-extra-category').enabled"),false);
  r.run("toggleSection(state.xsign_config.dashboard.sections.find(s=>s.id==='apps-extra-category'))");
  assert.equal(r.run("state.xsign_config.dashboard.sections.find(s=>s.id==='apps-categories').enabled"),false);
  assert.equal(r.run("state.xsign_config.dashboard.sections.find(s=>s.id==='apps-extra-category').enabled"),true);
});
test('editing or removing IPA SOON updates the existing Today source filters',()=>{
  const r=runtime();
  r.run("const d=state.xsign_config.dashboard;d.sections[0].source_url=PRIMARY_SOURCE_URL;editingManagedSource='xsign.core.primary';integrationChange=(action)=>action();editManagedSource=()=>{}");
  r.el('managedName').value='IPA SOON';r.el('managedURL').value='https://example.test/soon.json';
  r.el('managedFormat').value='auto';
  for(const id of ['managedFields','managedIcon','managedRoot'])r.el(id).value='';
  r.run('saveManagedSource({preventDefault(){}})');
  assert.equal(r.run('state.xsign_config.dashboard.sections[0].source_url'),'https://example.test/soon.json');
  r.run("const sources=state.xsign_config.dashboard.sources;deleteManagedSource(sources.find(s=>s.id==='xsign.core.primary'),sources)");
  assert.equal(r.run('state.xsign_config.dashboard.sections[0].enabled'),false);
  assert.equal(r.run('validateState(state).length'),0);
});
test('source management form is in Sources and the old fixed-provider claim is gone',()=>{const html=fs.readFileSync(require.resolve('../src/template.html'),'utf8');const page=html.match(/<section data-panel="sources"[\s\S]*?<\/section>/)[0];assert(page.includes('id="managedSourceForm"'));assert(!html.includes('مصدران ثابتان'));});
test('Zsign picks add one source at a time and preserve hidden duplicate URLs',()=>{
  const r=runtime();
  r.run(`integrationChange=action=>action(); renderSourcePresets(state.xsign_config.dashboard.sources);
    this.pick={id:'xsign.zsign.it',name:'iTorrent',url:SOURCE_PRESETS[0][2],format:'auto',enabled:true}`);
  assert.equal(r.el('sourcePresets').children.length,7);
  r.run('addSourcePreset(pick);addSourcePreset(pick)');
  assert.equal(r.run("state.xsign_config.dashboard.sources.filter(source=>source.id.startsWith('xsign.zsign.')).map(source=>source.name).join(',')"),'iTorrent');
  r.run(`state.xsign_config.dashboard.sources.find(source=>source.id===pick.id).enabled=false;
    addSourcePreset({...pick,id:'alias'});renderSourcePresets(state.xsign_config.dashboard.sources)`);
  assert.equal(r.el('sourcePresets').children[0].children[1].disabled,true);
  assert.equal(r.el('sourcePresets').children[1].children[1].disabled,false);
  assert.equal(r.run('state.xsign_config.dashboard.sources.find(source=>source.id===pick.id).enabled'),false);
});
test('legacy source imports gain the contract and preserve unknown nested settings',()=>{const r=runtime();r.run("state=normalizeState({apps:[],xsign_config:{theme:{app_tint_hex:'#ABCDEF',unknown:7},security_locks:{lock_bundle_rename:true}},future:{keep:true}})");assert.equal(r.run('state.xsign_config.theme.unknown'),7);assert.equal(r.run('state.future.keep'),true);assert.equal(r.run('state.xsign_config.security_locks.allow_app_metadata_editing'),false);assert.equal(r.run('state.xsign_config.dashboard.schema_version'),2);});
test('empty sources retain only the fixed source, and hidden sections stay empty',()=>{const r=runtime();r.run('state.xsign_config.dashboard.sources=[];state.xsign_config.dashboard.sections=[];state.featuredApps=[];state=normalizeState(state)');assert.equal(r.run('state.xsign_config.dashboard.sources.length'),1);assert.equal(r.run('state.xsign_config.dashboard.sections.length'),0);assert.equal(r.run('dashboardErrors(state).length'),0);});
test('existing legacy store sections keep their order, visibility and kind',()=>{const r=runtime();
 r.run("state=normalizeState({xsign_config:{dashboard:{sections:[{id:'apps-sources',title:'Sources',page:'apps',kind:'sources'},{id:'games-list',title:'Games',page:'games',kind:'apps'},{id:'games-categories',title:'Categories',page:'games',kind:'categories',enabled:false}]}}})");
 assert.equal(r.run("state.xsign_config.dashboard.sections.map(s=>s.id+':'+s.kind).join(',')"),'apps-sources:sources,games-list:apps,games-categories:categories');
 assert.equal(r.run('state.xsign_config.dashboard.sections.at(-1).enabled'),false);
});
test('optional native source and section fields receive defaults on import',()=>{const r=runtime();r.run("state=normalizeState({apps:[],xsign_config:{dashboard:{sources:[{id:'a',name:'Source',url:'https://example.com/repo.json'}],sections:[{id:'s',title:'A',kind:'apps',page:'apps'}]}}})");assert.equal(r.run('dashboardErrors(state).length'),0);});
test('invalid sources, tabs and unsupported schema are rejected before publishing',()=>{const r=runtime();r.run("state.xsign_config.dashboard.sources[0].url='https://example.com/repo.json#fragment';state.xsign_config.dashboard.tab_order=[]");assert(r.run('dashboardErrors(state).length')>=2);r.run('state.xsign_config.dashboard.schema_version=99');assert(r.run('dashboardErrors(state)[0]').includes('v2'));});
test('force update accepts same version newer build but rejects an unavailable build',()=>{const r=runtime();r.run("Object.assign(state.xsign_config.dashboard.update,{enabled:true,latest_version:'2.9',build_version:'2',ipa_url:'https://example.com/x.ipa',sha256:'a'.repeat(64)});Object.assign(state.xsign_config.force_update,{enabled:true,min_version:'2.9.0',min_build_version:'3'})");assert(r.run('dashboardErrors(state)').some(e=>e.includes('الحد الإجباري')));r.run("state.xsign_config.dashboard.update.build_version='3'");assert.equal(r.run('dashboardErrors(state).length'),0);});
test('one release form fills publisher metadata and projects the required policy atomically',()=>{const r=runtime();
 r.run("managedUpdateBundle=XSIGN_LEGACY_BUNDLE;state.apps=[{name:'XSign',bundleIdentifier:XSIGN_LEGACY_BUNDLE,version:'1.0',buildVersion:'7',downloadURL:'https://github.com/ipablack/repo/releases/download/current/app.ipa',sha256:'b'.repeat(64)}];setReleaseLink(state.apps[0].downloadURL);setReleaseMode('required');state=normalizeState(state)");
 assert.equal(r.run('validateState(state).length'),0);
 assert.equal(r.run('Store.project(state).xsign_config.dashboard.update.required'),true);
 assert.equal(r.run('state.xsign_config.dashboard.update.sha256'),'b'.repeat(64));
 assert.equal(r.run('state.xsign_config.force_update.min_build_version'),'7');
 assert.equal(r.run('state.xsign_config.force_update.update_url'),r.run('state.apps[0].downloadURL'));
 r.run("setReleaseLink('https://example.com/a-different-build.ipa')");
 assert.equal(r.run('state.xsign_config.dashboard.update.sha256'),'');
 assert(r.run('validateState(state)').some(e=>e.includes('SHA-256')));
 r.run("setReleaseMode('off')");assert.equal(r.run('state.xsign_config.force_update.enabled'),false);
});
test('a required ready-to-install manifest needs a build and retains its exact link',()=>{const r=runtime();
 r.run("managedUpdateBundle=XSIGN_LEGACY_BUNDLE;setReleaseLink('https://example.com/install.plist');setReleaseMode('required');state.xsign_config.dashboard.update.latest_version='1.0';syncReleaseGate(state)");
 assert(r.run('validateState(state)').some(e=>e.includes('رقم البناء')));
 r.run("state.xsign_config.dashboard.update.build_version='7';syncReleaseGate(state)");
 assert.equal(r.run('validateState(state).length'),0);
 assert.equal(r.run('state.xsign_config.dashboard.update.manifest_url'),'https://example.com/install.plist');
});
test('required IPA needs a build and optional mode clears the legacy gate',()=>{const r=runtime();
 r.run("managedUpdateBundle=XSIGN_LEGACY_BUNDLE;Object.assign(state.xsign_config.dashboard.update,{latest_version:'1.0',ipa_url:'https://example.com/x.ipa',sha256:'a'.repeat(64)});setReleaseMode('required')");
 assert(r.run('validateState(state)').some(e=>e.includes('رقم البناء')));
 r.run("state.xsign_config.dashboard.update.build_version='8';syncReleaseGate(state)");
 assert.equal(r.run('validateState(state).length'),0);
 r.run("setReleaseMode('optional')");
 assert.equal(r.run('Store.project(state).xsign_config.dashboard.update.enabled'),true);
 assert.equal(r.run('Store.project(state).xsign_config.force_update.enabled'),false);
});
test('the default installation preview escapes metadata and only uses the internal install action',()=>{const r=runtime();
 const html=r.run("defaultInstallFragment({latest_version:'1.0',build_version:'47',notes:'<script>alert(1)</script>'},true)");
 assert(html.includes('xsign-update://install'));assert(html.includes('&lt;script&gt;'));assert(!html.includes('<script>'));assert(!html.includes('البناء 47'));
});
test('native version ordering rejects prerelease labels and oversize HTML',()=>{const r=runtime();r.run("state.xsign_config.dashboard.update.html='x'.repeat(100001)");assert(r.run('dashboardErrors(state)').some(e=>e.includes('HTML')));assert.equal(r.run("numericRelease('2.0-beta')"),false);assert.equal(r.run("compareRelease('2.9.0','2.9')"),0);});
test('adopting publisher metadata checks real bundle and requires SHA256',()=>{const r=runtime();r.run("this.app={bundleIdentifier:'com.ipablack.xsign',version:'3.0',buildVersion:'4',downloadURL:'https://github.com/o/r/releases/download/a/app.ipa',sha256:'A'.repeat(64)}");const value=r.run("ownerUpdateFromApp(app,'com.ipablack.xsign')");assert.equal(value.latest_version,'3.0');assert.equal(value.sha256,'a'.repeat(64));assert.equal(value.manifest_url,'');assert.throws(()=>r.run("ownerUpdateFromApp(app,'com.fake.xsign')"),/Bundle ID/);r.run('delete app.sha256');assert.throws(()=>r.run("ownerUpdateFromApp(app,'com.ipablack.xsign')"),/الناشر/);});
test('adopting an IPA does not silently enable forced or internal updates',()=>{const r=runtime();r.run("this.app={bundleIdentifier:XSIGN_INTEGRATION.bundle,version:'3.0',downloadURL:'https://example.com/a.ipa',sha256:'a'.repeat(64)};Object.assign(state.xsign_config.dashboard.update,ownerUpdateFromApp(app,XSIGN_INTEGRATION.bundle))");assert.equal(r.run('state.xsign_config.dashboard.update.enabled'),false);assert.equal(r.run('state.xsign_config.force_update.enabled'),false);});
test('bundle rename switch and metadata permission remain consistent with Swift',()=>{const r=runtime();r.run("fieldInput({dataset:{path:'xsign_config.security_locks.lock_bundle_rename'},type:'checkbox',checked:true},true)");assert.equal(r.run('state.xsign_config.security_locks.allow_app_metadata_editing'),false);r.run("fieldInput({dataset:{path:'xsign_config.security_locks.allow_app_metadata_editing'},type:'checkbox',checked:true},true)");assert.equal(r.run('state.xsign_config.security_locks.lock_bundle_rename'),false);});
test('different managed source edits merge by stable source ID',()=>{const base={xsign_config:{dashboard:{sources:[{id:'a',name:'A'},{id:'b',name:'B'}]}}},local=C.copy(base),remote=C.copy(base);local.xsign_config.dashboard.sources[0].name='Local';remote.xsign_config.dashboard.sources[1].name='Remote';const merged=C.merge(base,local,remote);assert.deepEqual(merged.xsign_config.dashboard.sources.map(s=>s.name),['Local','Remote']);});
test('independent store section edits merge without replacing the whole layout',()=>{const base={xsign_config:{dashboard:{sections:[{id:'a',title:'A'},{id:'b',title:'B'}]}}},local=C.copy(base),remote=C.copy(base);local.xsign_config.dashboard.sections[0].title='Local';remote.xsign_config.dashboard.sections[1].enabled=false;const result=C.merge(base,local,remote);assert.equal(result.xsign_config.dashboard.sections[0].title,'Local');assert.equal(result.xsign_config.dashboard.sections[1].enabled,false);});
test('HTML stays in a sandbox and no external script gains access to token',()=>{const html=fs.readFileSync(require.resolve('../src/template.html'),'utf8');assert(html.includes('id="ownerHTMLPreview" sandbox=""'));assert(html.includes('id="requireOnline" disabled'));assert(html.includes('id="antiVpn" data-path="xsign_config.security_locks.anti_vpn_proxy"'));assert(!/<script\s+src=/i.test(html));});


test('Studio adds and moves existing app and game categories without losing aliases or layout sections',()=>{
  const r=runtime();
  r.el('categoryForm').reset=()=>{};
  r.el('categoryId').value='board';
  r.el('categoryName').value='ألعاب الطاولة';
  r.el('categoryAliases').value='7012, puzzle، ألغاز';
  r.el('categoryIsGame').checked=true;
  const initial=r.run('state.categories.length');
  r.run('saveCategory({preventDefault(){}})');
  assert.equal(r.run('state.categories.length'),initial+1);
  r.run('moveCategory(state.categories.at(-1),-1)');
  assert.equal(r.run('Store.project(state).categories.at(-2).id'),'board');
  assert.equal(r.run('state.categories.at(-2).aliases.join("|")'),'7012|puzzle|ألغاز');
  assert.equal(r.run('state.categories.at(-2).isGame'),true);
  const before=r.run('state.xsign_config.dashboard.sections.length');
  r.run("state.xsign_config.dashboard.sections[0].category_id='board';state.xsign_config.dashboard.sections[0].source_url=OWNED_CANONICAL_URL;editCategory(state.categories.at(-2))");
  r.el('categoryId').value='board-games';
  r.run('saveCategory({preventDefault(){}})');
  assert.equal(r.run('state.xsign_config.dashboard.sections[0].category_id'),'board-games');
  assert.equal(r.run('state.xsign_config.dashboard.sections.length'),before);
  assert(r.run("state.categories.at(-2).aliases.includes('board')"));
});

test('category filters resolve old name/numeric aliases and reassignment drops only old references',()=>{
  const r=runtime();
  r.run(`state.categories.unshift({id:'racing',name:'سباقات',isGame:true,aliases:['7013','race']});
    state.apps=[{name:'Arcade',bundleIdentifier:'example.arcade',version:'1.0',downloadURL:'https://example.test/arcade.ipa',
      category_id:7013,categories:[{id:'race',label:'Legacy'},'tools'],genres:['Racing']}];`);
  r.el('categoryFilter').value='racing';
  assert.equal(r.run('catalogueResults().length'),1);
  assert.equal(r.run('categoryName(state.apps[0],categoryIndex())'),'سباقات');
  r.run('setAppCategory(state.apps[0],"media",categoryIndex())');
  assert.equal(r.run('catalogueResults().length'),0);
  assert.equal(r.run('state.apps[0].categories.join()'),'tools');
  assert.equal(r.run('state.apps[0].category'),'media');
  assert.equal(r.run("'category_id' in state.apps[0]"),false);
});

test('renaming and deleting categories preserve linked applications and section filters',()=>{
  const r=runtime();r.el('categoryForm').reset=()=>{};
  r.run(`state.categories.unshift({id:'racing',name:'سباقات',isGame:true,aliases:['7013']});
    state.apps=[{name:'Arcade',category:{id:'RACING',label:'سباقات'},genres:[7013,'Unrelated']}];
    state.xsign_config.dashboard.sections[0].category_id='racing';editCategory(state.categories[0]);
    this.message='';toast=value=>message=value;`);
  r.el('categoryId').value='motorsport';
  r.run('saveCategory({preventDefault(){}});deleteCategory(state.categories[0])');
  assert.equal(r.run('state.apps[0].category.id'),'motorsport');
  assert.equal(r.run('state.apps[0].category.label'),'سباقات');
  assert(r.run("state.categories[0].aliases.includes('racing')"));
  assert.match(r.run('message'),/مستخدم في 1 تطبيق/);
  r.run('state.apps=[];deleteCategory(state.categories[0])');
  assert.match(r.run('message'),/مستخدم في ترتيب المتجر/);
});

const buildForm={buildAppName:'نسخة XSign',buildBundleID:'Com.Owner.New',buildVersion:'1.2.3',buildNumber:'23',buildIconURL:'https://example.com/icon.png',buildManifestURL:''};
const workflowName='Xsign — Studio Release';
const jsonResponse=(status,value)=>({ok:status>=200&&status<300,status,json:async()=>value});

function mockStudioBuild(r,state='new'){
  r.el('buildDelivery').value='private';
  const calls=[];const commit='a'.repeat(40);const fileHash='b'.repeat(40);
  r.run('renderIntegration=()=>{};');
  for(const [id,value] of Object.entries(buildForm))r.el(id).value=value;
  r.el('ghToken').value='test-token';
  r.ctx.fetch=async(url,request)=>{
    calls.push({url,request});
    if(url.endsWith('/actions/workflows/XSign_Full_Link.yml'))return jsonResponse(200,{name:state==='old'?'Legacy build':workflowName,state:'active'});
    if(request.method==='GET'&&url.includes('/contents/xsign-build.json?ref=main')){
      if(state==='existing')return jsonResponse(200,{type:'file',sha:fileHash,size:48,encoding:'base64',content:'e30='});
      return jsonResponse(404,{});
    }
    if(request.method==='PUT'&&url.endsWith('/contents/xsign-build.json'))return jsonResponse(200,{commit:{sha:commit}});
    if(url.includes('&head_sha='+commit))return jsonResponse(200,{workflow_runs:[{id:812,status:'queued',head_sha:commit}]});
    throw Error('Unexpected '+url);
  };
  return {calls,commit,fileHash};
}

test('Studio saves exact Xcode settings to main and follows the build for that commit',async()=>{
  const r=runtime();const {calls,commit}=mockStudioBuild(r);
  await r.run('requestStudioBuild({preventDefault(){}})');
  await new Promise(resolve=>setImmediate(resolve));
  const published=calls.find(x=>x.request.method==='PUT');
  assert.match(published.url,/\/ipablack\/X-SIGN\/contents\/xsign-build\.json$/);
  const body=JSON.parse(published.request.body);
  assert.equal(body.branch,'main');assert.equal(body.sha,undefined);assert(!body.message.includes('[skip ci]'));
  const record=JSON.parse(Buffer.from(body.content,'base64').toString('utf8'));
  assert.equal(record.schema_version,1);assert.match(record.request_id,/^[a-f0-9]{32}$/);
  assert.deepEqual(record.settings,{appName:'نسخة XSign',bundleIdentifier:'Com.Owner.New',version:'1.2.3',buildVersion:'23',iconURL:'https://example.com/icon.png',delivery:'private'});
  assert(calls.some(x=>x.url.includes('head_sha='+commit)));
  assert(!calls.some(x=>x.request.method==='POST'));
  assert.equal(r.el('buildRunLink').href,'https://github.com/ipablack/X-SIGN/actions/runs/812');
  assert.equal(r.run('managedUpdateBundle'),'com.owner.new');
});

test('Studio requires a choice before building and records public distribution only after selection',async()=>{
  const r=runtime();const {calls}=mockStudioBuild(r);
  r.el('buildDelivery').value='';
  await r.run('requestStudioBuild({preventDefault(){}})');
  assert.equal(calls.length,0);
  r.el('buildDelivery').value='everyone';
  await r.run('requestStudioBuild({preventDefault(){}})');
  const published=calls.find(call=>call.request.method==='PUT');
  const record=JSON.parse(Buffer.from(JSON.parse(published.request.body).content,'base64').toString());
  assert.equal(record.settings.delivery,'everyone');
});

test('Studio refreshes the exact run and shows the build failure annotation',async()=>{
  const r=runtime();const {commit}=mockStudioBuild(r);
  await r.run('requestStudioBuild({preventDefault(){}})');
  await new Promise(resolve=>setImmediate(resolve));
  r.ctx.fetch=async url=>{
    if(url.endsWith('/actions/runs/812'))return jsonResponse(200,{id:812,head_sha:commit,status:'completed',conclusion:'failure'});
    if(url.endsWith('/jobs?per_page=20'))return jsonResponse(200,{jobs:[{conclusion:'failure',check_run_url:'https://api.github.com/repos/ipablack/X-SIGN/check-runs/9',steps:[{name:'Packaging',conclusion:'failure'}]}]});
    if(url.endsWith('/check-runs/9/annotations'))return jsonResponse(200,[
      {title:'XSign build',message:"XSign release error: Command '['make']' returned non-zero exit status 2."},
      {title:'XSign build',message:'** BUILD FAILED **'},
      {title:'XSign build',message:'XSign release error: invalid identity.'}]);
    throw Error('Unexpected '+url);
  };
  await r.run('refreshBuildResult()');
  assert.equal(r.el('buildRequestStatus').textContent,'XSign release error: invalid identity.');
});

test('Save only uses the current file SHA and leaves the build available from the Actions button',async()=>{
  const r=runtime();const {calls,fileHash}=mockStudioBuild(r,'existing');
  await r.run("requestStudioBuild({preventDefault(){},submitter:{id:'saveStudioBuild'}})");
  const body=JSON.parse(calls.find(x=>x.request.method==='PUT').request.body);
  assert.equal(body.sha,fileHash);assert.match(body.message,/\[skip ci\]/);
  assert.equal(calls.filter(x=>x.url.includes('/runs?')).length,0);
  assert.equal(r.run("pendingBuildFor('com.owner.new').queued"),false);
});

test('a stale live workflow cannot consume Studio settings from the new panel',async()=>{
  const r=runtime();const {calls}=mockStudioBuild(r,'old');
  await r.run('requestStudioBuild({preventDefault(){}})');
  assert.equal(calls.length,1);
  assert.match(r.el('buildRequestStatus').textContent,/استبدل ملف XSign_Full_Link/);
});

test('a different Studio session restores the build identity at the selected GitHub commit',async()=>{
  const r=runtime();const commit='a'.repeat(40),requestId='b'.repeat(32);
  r.run('renderIntegration=()=>{};');
  r.el('ghToken').value='test-token';
  const record={schema_version:1,request_id:requestId,settings:{appName:'XSign',bundleIdentifier:'com.owner.new',version:'1.2'}};
  r.ctx.fetch=async(url,request)=>{
    assert.equal(request.method,'GET');
    if(url.endsWith('/git/ref/heads/main'))return jsonResponse(200,{object:{sha:commit}});
    if(url.endsWith('/contents/xsign-build.json?ref='+commit))return jsonResponse(200,{
      type:'file',sha:'c'.repeat(40),size:200,encoding:'base64',content:Buffer.from(JSON.stringify(record)).toString('base64')});
    throw Error('Unexpected '+url);
  };
  await r.run('loadSavedStudioBuild()');
  assert.equal(r.el('buildVersion').value,'1.2');
  assert.equal(r.run("pendingBuildFor('com.owner.new').record.request_id"),requestId);
  assert.throws(()=>r.run("matchPendingBuild(pendingBuildFor('com.owner.new'),{buildRequestID:'old'})"),/لا يخص طلب البناء/);
});

test('IPA inspection uses a public runner and reads the exact report from private storage',async()=>{
  const r=runtime();const calls=[];const url='https://github.com/ipablack/repo/releases/download/v23/owner-23.ipa';
  const buildRequestID='c'.repeat(32), info={requestDigest:require('node:crypto').createHash('sha256').update(url).digest('hex'),isXSign:true,
    bundleIdentifier:'com.owner.new',appName:'نسخة XSign',version:'1.2.3',buildVersion:'23',sha256:'a'.repeat(64),buildRequestID};
  let checkRequest;
  r.ctx.fetch=async(endpoint,request)=>{
    calls.push({endpoint,request});
    if(endpoint.endsWith('/repos/ipablack/repo'))return jsonResponse(200,{private:true,default_branch:'main'});
    if(endpoint.endsWith('/repos/ipablack/X-SIGN'))return jsonResponse(200,{private:false,default_branch:'main'});
    if(endpoint.endsWith('/repo/git/ref/heads/main'))return jsonResponse(200,{object:{sha:'1'.repeat(40)}});
    if(endpoint.endsWith('/repo/git/commits/'+'1'.repeat(40)))return jsonResponse(200,{tree:{sha:'2'.repeat(40)}});
    if(endpoint.endsWith('/repo/git/trees')){
      const file=JSON.parse(request.body).tree[0];assert.match(file.path,/^\.xsign-queue\/requests\/[a-f0-9]{32}\.json$/);
      assert.equal(JSON.parse(file.content).ipa_url,url);
      return jsonResponse(200,{sha:'3'.repeat(40)});
    }
    if(endpoint.endsWith('/repo/git/commits'))return jsonResponse(200,{sha:'4'.repeat(40)});
    if(endpoint.endsWith('/repo/git/refs/heads/main'))return jsonResponse(200,{object:{sha:'4'.repeat(40)}});
    if(endpoint.endsWith('/actions/workflows/XSign_Full_Link.yml'))return jsonResponse(200,{name:workflowName,state:'active'});
    if(endpoint.endsWith('/X-SIGN/dispatches')){checkRequest=JSON.parse(request.body);return jsonResponse(204,null);}
    if(endpoint.includes('/runs?event=repository_dispatch'))return jsonResponse(200,{workflow_runs:[{id:912,display_title:'XSign · IPA check '+checkRequest.client_payload.request_id,status:'completed',conclusion:'success'}]});
    if(endpoint.includes('/repo/contents/.xsign-queue/results/')){
      const bytes=Buffer.from(JSON.stringify({...info,requestID:checkRequest.client_payload.request_id}));
      return jsonResponse(200,{type:'file',sha:'8'.repeat(40),size:bytes.length,encoding:'base64',content:bytes.toString('base64')});
    }
    throw Error('Unexpected '+endpoint);
  };
  r.ctx.buildRequest={commit:'a'.repeat(40),record:{schema_version:1,request_id:buildRequestID,settings:{appName:info.appName,bundleIdentifier:info.bundleIdentifier,version:info.version,buildVersion:info.buildVersion}}};
  r.el('ghToken').value='test-token';r.run('renderIntegration=()=>{};');
  r.ctx.releaseURL=url;
  r.run("rememberStudioBuild(buildRequest);selectUpdateBundle('com.owner.new');setReleaseLink(releaseURL);setReleaseMode('required');");
  assert.equal(await r.run('fillReleaseMetadata()'),true);
  assert.equal(checkRequest.event_type,'xsign-inspect-ipa');assert.deepEqual(Object.keys(checkRequest.client_payload),['request_id']);
  assert(!calls.filter(call=>call.endpoint.includes('/X-SIGN/')).some(call=>(call.request.body||'').includes(url)));
  assert.equal(r.run('currentUpdateDraft().build_version'),'23');
  assert.equal(r.run('currentUpdateDraft().app_name'),'نسخة XSign');
  assert.equal(r.run('currentUpdateDraft().sha256'),'a'.repeat(64));
  assert.equal(r.run('state.xsign_config.force_update.enabled'),false);
  assert.equal(r.run('Store.project(state).xsign_config.dashboard.bundle_updates["com.owner.new"].required'),true);
  assert.equal(r.run('Store.project(state).xsign_config.dashboard.bundle_updates["com.owner.new"].build_request_id'),buildRequestID);
  r.run('verifiedReleaseDrafts.clear();loadVerifiedReleases()');
  assert.doesNotThrow(()=>r.run('validateReleasePublication(state,null)'));
  r.run("currentUpdateDraft().build_version='24';");
  assert.throws(()=>r.run('validateReleasePublication(state,null)'),/افحص رابط IPA/);
  r.run("currentUpdateDraft().build_version='23';");
  info.buildRequestID='d'.repeat(32);
  assert.equal(await r.run('fillReleaseMetadata()'),false);
  assert.match(r.el('ipaVerificationStatus').textContent,/لا يخص طلب البناء/);
  assert.equal(r.run('currentUpdateDraft().build_request_id'),buildRequestID);
});

test('a verified public IPA link can be published after an unrelated private build',async()=>{
  const r=runtime();
  const url='https://github.com/ipablack/repo/releases/download/v42/X-SIGN.ipa';
  r.ctx.link=url;
  r.el('ghToken').value='test-token';
  r.run(`renderIntegration=()=>{};
    inspectReleaseWithActions=async()=>({fromPublicRelease:true,isXSign:true,appName:'Xsign',bundleIdentifier:'Xsign',
      version:'1.0',buildVersion:'42',sha256:'a'.repeat(64),buildRequestID:'b'.repeat(32)});
    rememberStudioBuild({record:{request_id:'c'.repeat(32),settings:{bundleIdentifier:'Xsign'}}});
    setReleaseLink(link);setReleaseMode('required');`);
  assert.equal(await r.run('fillReleaseMetadata()'),true);
  assert.equal(r.run('currentUpdateDraft().required'),true);
  assert.equal(r.run('currentUpdateDraft().ipa_url'),url);
  assert.doesNotThrow(()=>r.run('validateReleasePublication(state,null)'));
});

test('the original bundle retains its policy and additional bundles cannot change the original force gate',()=>{
  const r=runtime();r.run('renderIntegration=()=>{};');
  r.run("managedUpdateBundle=XSIGN_LEGACY_BUNDLE;setReleaseLink('https://example.com/original.ipa');setReleaseMode('required');selectUpdateBundle('com.owner.new');setReleaseLink('https://example.com/new.ipa');setReleaseMode('off');");
  assert.equal(r.run('state.xsign_config.dashboard.update.required'),true);
  assert.equal(r.run('state.xsign_config.force_update.update_url'),'https://example.com/original.ipa');
  assert.equal(r.run('currentUpdateDraft().required'),false);
  assert.equal(r.run('currentUpdateDraft().bundle_identifier'),'com.owner.new');
});

test('the published Xsign update reaches old readers and round trips without changing other bundles',()=>{
  const r=runtime();
  r.run(`
    const original=state.xsign_config.dashboard.update;
    original.latest_version='9.0';
    original.notes='Keep the original bundle policy';
    selectUpdateBundle('Xsign');
    setReleaseMode('required');
    Object.assign(currentUpdateDraft(),{latest_version:'1.0',build_version:'34',
      ipa_url:'https://example.com/Xsign.ipa',sha256:'a'.repeat(64)});
    this.originalDraft=JSON.stringify(state);
    this.published=publicationConfiguration(state);
  `);
  assert.equal(r.run('published.xsign_config.dashboard.update.enabled'),true);
  assert.equal(r.run('published.xsign_config.dashboard.update.required'),true);
  assert.equal(r.run('published.xsign_config.dashboard.update.bundle_identifier'),'xsign');
  assert.equal(r.run('published.xsign_config.dashboard.update.build_version'),'34');
  assert.equal(r.run('published.xsign_config.dashboard.bundle_updates["com.ipablack.xsign"].latest_version'),'9.0');
  assert.equal(r.run('JSON.stringify(state)'),r.run('originalDraft'));
  assert.equal(r.run('JSON.stringify(normalizeState(published).xsign_config)'),r.run('JSON.stringify(state.xsign_config)'));
  r.run("setReleaseMode('optional');this.optional=publicationConfiguration(state)");
  assert.equal(r.run('optional.xsign_config.dashboard.update.enabled'),true);
  assert.equal(r.run('optional.xsign_config.dashboard.update.required'),false);
  r.run("setReleaseMode('off');this.disabled=publicationConfiguration(state)");
  assert.equal(r.run('disabled.xsign_config.dashboard.update.enabled'),false);
  assert.equal(r.run('releasePublicationSummary(state).mode'),'متوقف');
});

test('the release review states the target bundle and its required or optional mode',()=>{
  const r=runtime();
  r.run("selectUpdateBundle('Xsign');setReleaseMode('required')");
  assert.equal(r.run('releasePublicationSummary(state).bundle'),'xsign');
  assert.equal(r.run('releasePublicationSummary(state).mode'),'إجباري');
  r.run("setReleaseMode('optional')");
  assert.equal(r.run('releasePublicationSummary(state).mode'),'اختياري');
});

test('featured picks save names as stable IDs independently for apps and games',()=>{
  const r=runtime();
  r.run(`
    state.apps=[
      {name:'Notes', bundleIdentifier:'example.notes', catalogID:'notes-id',category:'tools'},
      {name:'Race', bundleIdentifier:'example.race', catalogID:'race-id',category:'games'},
      {name:'Arcade',bundleIdentifier:'example.arcade',isGame:true}
    ];
    integrationChange=action=>action();
    editStoreSection(state.xsign_config.dashboard.sections.find(s=>s.id==='apps-featured'));
  `);
  assert.equal(r.el('sectionFeaturedPicker').hidden,false);
  assert.deepEqual(r.el('sectionFeaturedApp').options.map(option=>option.value),['','notes-id']);
  r.el('sectionFeaturedApp').value='notes-id';
  r.run('addSectionFeaturedApp();saveStoreSection({preventDefault(){}})');
  r.run("editStoreSection(state.xsign_config.dashboard.sections.find(s=>s.id==='games-featured'))");
  assert.deepEqual(r.el('sectionFeaturedApp').options.map(option=>option.value),['','example.arcade','race-id']);
  r.run("updateFeaturedSelection(['race-id','example.arcade']);saveStoreSection({preventDefault(){}})");
  assert.equal(r.run("Store.project(state).xsign_config.dashboard.sections.find(s=>s.id==='apps-featured').app_ids.join()"),'notes-id');
  assert.equal(r.run("Store.project(state).xsign_config.dashboard.sections.find(s=>s.id==='games-featured').app_ids.join()"),'race-id,example.arcade');
  assert.equal(r.run("state.xsign_config.dashboard.sections.find(s=>s.id==='today-featured').app_ids"),undefined);
});

test('public self-update sends an accessible app repository asset to the catalogue inspector',async()=>{
  const r=runtime();
  const link='https://github.com/ipablack/X-SIGN/releases/download/v2/X-SIGN.ipa';
  r.ctx.digest=require('node:crypto').createHash('sha256').update(link).digest('hex');
  r.ctx.ipa=link;
  r.run(`
    connection={...connection,owner:'ipablack',repo:'repo',branch:'main'};
    this.calls=[];
    github=async(c,path,method,body,token)=>{
      calls.push({repo:c.owner+'/'+c.repo,path,method,body,token});
      if(path==='')return {private:false};
      if(path==='releases/tags/v2')return {draft:false,assets:[{name:'X-SIGN.ipa',state:'uploaded'}]};
    };
    repositoryFile=async(c,path)=>({source:JSON.stringify({
      requestID:calls.at(-1).body.inputs.request_id,requestDigest:digest,isXSign:true
    })});
  `);
  assert.equal((await r.run("inspectReleaseWithActions(ipa,'fixture')")).isXSign,true);
  assert.equal(r.run('calls[1].repo'),'ipablack/X-SIGN');
  assert.equal(r.run('calls[1].token'),'');
  assert.equal(r.run('calls[2].repo'),'ipablack/repo');
  assert.equal(r.run('calls[2].path'),'actions/workflows/xsign-inspect-public.yml/dispatches');
  assert.equal(r.run('calls[2].body.inputs.bundle_id'),'xsign');
  await assert.rejects(r.run("inspectReleaseWithActions('https://example.com/a.ipa','fixture')"),/مستودعات XSign العامة/);
  r.ctx.digest='0'.repeat(64);
  await assert.rejects(r.run("inspectReleaseWithActions(ipa,'fixture')"),/تقرير الفحص يخص رابطاً مختلفاً/);
});

test('an inaccessible public update asset is rejected before starting Actions',async()=>{
  const r=runtime();
  r.run(`
    connection={...connection,owner:'ipablack',repo:'repo',branch:'main'};
    this.dispatched=false;
    github=async(c,path,method)=>{
      if(path==='')return {private:false};
      if(path.startsWith('releases/tags/'))throw Object.assign(new Error('Not found'),{status:404});
      if(method==='POST')dispatched=true;
    };
  `);
  await assert.rejects(r.run("inspectReleaseWithActions('https://github.com/ipablack/X-SIGN/releases/download/v2/X-SIGN.ipa','fixture')"),/التحديث لا يصل إلى المستخدمين/);
  assert.equal(r.run('dispatched'),false);
});

test('a 422 from the build workflow installed as the IPA inspector identifies the file to replace',async()=>{
  const r=runtime();
  r.ctx.jsyaml=require('js-yaml');
  r.run(`
    connection={...connection,owner:'ipablack',repo:'repo',branch:'main'};
    github=async(c,path)=>{
      if(path==='')return {private:false};
      if(path==='releases/tags/v2')return {draft:false,assets:[{name:'X-SIGN.ipa',state:'uploaded'}]};
      throw Object.assign(new Error('Unprocessable Entity'),{status:422});
    };
    repositoryFile=async(c,path)=>path==='.github/workflows/xsign-inspect-public.yml'
      ?{source:'name: Xsign Studio Release\\non:\\n  workflow_dispatch:\\njobs: {}\\n'}:null;
  `);
  await assert.rejects(r.run("inspectReleaseWithActions('https://github.com/ipablack/X-SIGN/releases/download/v2/X-SIGN.ipa','fixture')"),
    /استبدل \.github\/workflows\/xsign-inspect-public\.yml/);
});

test('an old Apps layout regains the missing hero without overriding an explicit disabled section',()=>{
  const r=runtime();
  r.run(`state=normalizeState({apps:[],xsign_config:{dashboard:{experience_version:3,sections:[
    {id:'apps-categories',title:'الأقسام',page:'apps',kind:'categories',enabled:true,limit:12},
    {id:'apps-list',title:'التطبيقات',page:'apps',kind:'apps',enabled:true,limit:60},
    {id:'games-featured',title:'مختارات الألعاب',page:'games',kind:'featured',enabled:true,limit:12}
  ]}}})`);
  assert.equal(r.run("state.xsign_config.dashboard.sections.filter(s=>s.page==='apps').map(s=>s.kind).join(',')"),'categories,featured,apps');
  r.run("state.xsign_config.dashboard.sections.find(s=>s.id==='apps-featured').enabled=false;state=normalizeState(state)");
  assert.equal(r.run("state.xsign_config.dashboard.sections.filter(s=>s.id==='apps-featured').length"),1);
  assert.equal(r.run("state.xsign_config.dashboard.sections.find(s=>s.id==='apps-featured').enabled"),false);
});

test('Today continuation follows the saved unfiltered list',()=>{
  const r=runtime();
  r.run("integrationChange=action=>action();editStoreSection(state.xsign_config.dashboard.sections.find(s=>s.id==='today-apps'))");
  assert.equal(r.el('todayContinuous').checked,true);
  assert.equal(r.el('todayContinuousControl').hidden,false);
  r.el('todayContinuous').checked=false;
  r.run('saveStoreSection({preventDefault(){}})');
  assert.equal(r.run("Store.project(state).xsign_config.dashboard.sections.find(s=>s.id==='today-apps').continuous"),false);
  r.run("editStoreSection(state.xsign_config.dashboard.sections.find(s=>s.id==='today-apps'))");
  r.el('sectionCategoryV2').value='tools';
  r.run('renderFeaturedPicker();saveStoreSection({preventDefault(){}})');
  assert.equal(r.run("state.xsign_config.dashboard.sections.find(s=>s.id==='today-apps').continuous"),undefined);
});

test('personal build button resolves only its own unpublished release asset',async()=>{
  const r=runtime();
  const url='https://github.com/ipablack/X-SIGN/releases/download/untagged-example/X-SIGN.ipa';
  const release={draft:true,tag_name:'xsign-personal-50-2',assets:[{name:'X-SIGN.ipa',state:'uploaded',browser_download_url:url}]};
  r.ctx.fetchBuildResult=async(repo,route)=>{
    if(route==='actions/runs/50/artifacts?per_page=100')return {artifacts:[{name:'XSign-draft-8-2-71'}]};
    assert.equal(route,'releases/71');return release;
  };
  r.run("github=fetchBuildResult;requireToken=()=>'fixture'");
  const show=()=>r.run("displayBuildResult({id:50,run_number:8,run_attempt:2,conclusion:'success'},buildRunLookup)");
  await show();
  const button=r.el('buildIPAArtifactLink');assert.equal(button.hidden,false);assert.equal(button.href,url);
  release.draft=false;await show();assert.equal(button.hidden,true);
  release.draft=true;release.tag_name='xsign-personal-50-1';await show();assert.equal(button.hidden,true);
});

test('push service config and multilingual notices keep the owner token separate',()=>{
  const r=runtime();
  r.run("state=normalizeState({xsign_config:{push_endpoint:'https://project.example/push'}});renderPushService()");
  assert.equal(r.run('publicationConfiguration(state).xsign_config.push_endpoint'),'https://project.example/push');
  r.el('studioPushToken').value='x'.repeat(38);
  assert(!r.run('JSON.stringify(state)').includes('x'.repeat(38)));
  r.el('studioPushKind').value='app';r.el('studioPushTarget').value='com.example.app';
  for(const language of ['ar','en','ckb']){
    r.el('studioPushTitle-'+language).value='Title '+language;
    r.el('studioPushBody-'+language).value='Notice '+language;
  }
  assert.deepEqual(JSON.parse(r.run('JSON.stringify(readPushDraft())')),{
    kind:'app',target:'com.example.app',messages:{ar:{title:'Title ar',body:'Notice ar'},
      en:{title:'Title en',body:'Notice en'},ckb:{title:'Title ckb',body:'Notice ckb'}}
  });
  r.el('studioPushBody-ckb').value='';
  assert.throws(()=>r.run('readPushDraft()'));
  r.run("state.xsign_config.push_endpoint='https://different.example/push';renderPushService()");
  assert.equal(r.el('studioPushToken').value,'');
});
