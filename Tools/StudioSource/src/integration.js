/* XSign native dashboard v2. Published settings match the reviewed Swift readers. */
const XSIGN_INTEGRATION={schema:2,minimumOS:'15.0',name:'XSign',version:'1.0',bundle:'com.ipablack.xsign',source:OWNED_CANONICAL_URL,
  features:[['المظهر الداكن والفاتح والألوان','theme'],['الإقلاع وحركة X وHTML/CSS','splash_screen'],
  ['المصادر وترتيب المتجر والتبويبات','dashboard'],['التوقيع وتحرير البيانات والأيقونة والحقن','security_locks'],
  ['الصيانة والتحديث الإجباري ورقم البناء','force_update'],['صفحة HTML والتحديث الموقّع','dashboard.update'],
  ['الشريط العلوي وتجديد الكاش','app_control'],['التطبيقات والإصدارات والأخبار والتصنيفات','catalogue']]};
const DASHBOARD_DEFAULTS={schema_version:2,catalog_profile:'iosboom-public-v1',experience_version:2,allow_user_sources:true,signing_enabled:true,
  tab_order:['today','games','apps','library','search'],
  sources:[{id:'xsign.core.owned',name:'IPA BLACK',url:OWNED_CANONICAL_URL,enabled:true,format:'auto'},
    {id:'xsign.core.primary',name:'ipasoon',url:PRIMARY_SOURCE_URL,enabled:true,format:'auto'},
    {id:'xsign.core.zsign',name:'متجر Zsign الرسمي',url:SECONDARY_SOURCE_URL,enabled:true,format:'auto'},...IOSBOOM_PUBLIC_SOURCES.map(clone)],
  sections:[['today-news','الأخبار','today','news'],['today-featured','مختارات IPA BLACK','today','featured'],
    ['today-apps','جديد المتجر','today','apps'],
    ['apps-categories','التصنيفات','apps','categories'],['apps-featured','مختارات التطبيقات','apps','featured'],['apps-list','التطبيقات','apps','apps'],
    ['games-featured','مختارات الألعاب','games','featured'],['games-list','الألعاب','games','apps']].map(([id,title,page,kind])=>({id,title,page,kind,enabled:true,limit:kind==='apps'?60:12})),
  update:{enabled:false,latest_version:'',build_version:'',ipa_url:'',sha256:'',manifest_url:'',notes:'',html:''}};
const TAB_TITLES={today:'اليوم',apps:'التطبيقات',games:'الألعاب',search:'البحث',library:'التوقيع والمكتبة'};
const KIND_TITLES={apps:'قائمة تطبيقات',featured:'تطبيقات مميزة',sources:'المصادر',categories:'التصنيفات',news:'الأخبار'};
function canonicalManagedSourceURL(value){
  if(typeof value!=='string')return value;
  const aliases=['https://github.com/ipablack/repo/raw/refs/heads/main/repo.json',
    'https://github.com/ipablack/repo/blob/main/repo.json',
    'https://raw.githubusercontent.com/ipablack/repo/refs/heads/main/repo.json'];
  if(aliases.includes(value))return OWNED_CANONICAL_URL;
  try{const u=new URL(value),parts=u.pathname.split('/').filter(Boolean);
    if(u.hostname==='github.com'&&parts.length>=5&&['raw','blob'].includes(parts[2])){
      u.hostname='raw.githubusercontent.com';u.pathname='/'+[...parts.slice(0,2),...parts.slice(3)].join('/');u.searchParams.delete('raw');}
    if(u.hostname==='raw.githubusercontent.com'){u.pathname=u.pathname.replace('/refs/heads/','/');return u.href;}
  }catch{}
  return value;
}
function managedSourcePriority(source){const url=canonicalManagedSourceURL(source?.url);return url===OWNED_CANONICAL_URL?0:url===PRIMARY_SOURCE_URL?1:url===SECONDARY_SOURCE_URL?2:3;}
const integrationCoreSources=enforceCoreSources;
enforceCoreSources=function(value){const sources=value.xsign_config.dashboard?.sources;
  if(Array.isArray(sources))sources.sort((a,b)=>managedSourcePriority(a)-managedSourcePriority(b));
  syncReleaseGate(value);return integrationCoreSources(value);};
const integrationDefaults=createDefaultState;
createDefaultState=function(){const value=integrationDefaults();value.xsign_config.dashboard=clone(DASHBOARD_DEFAULTS);
  value.xsign_config.theme.appearance='system';value.xsign_config.force_update.min_build_version='';return value;};
const integrationNormalize=normalizeState;
function migrateZsignCatalogue(parsed){
  const input=clone(parsed),d=input?.xsign_config?.dashboard;
  if(d&&d.catalog_profile!=='iosboom-public-v1'){
    if(Array.isArray(d.sections)&&d.sections.some(s=>s.id==='apps-sources'&&s.kind==='sources'))d.sections=d.sections.flatMap(s=>{
      if(s.id==='apps-sources')return [clone(DASHBOARD_DEFAULTS.sections.find(row=>row.id==='apps-featured'))];
      if(s.id==='games-list')return [clone(DASHBOARD_DEFAULTS.sections.find(row=>row.id==='games-featured')),s];return [s];});
    if(Array.isArray(d.sources))d.sources=d.sources.flatMap(s=>s.id==='xsign.core.primary'&&s.url==='https://supapi.trystore.net/rest/v1/plus_library_apps'
      ?DASHBOARD_DEFAULTS.sources.slice(1,3).map(row=>({...clone(row),enabled:s.enabled!==false})):[s]);
    if(JSON.stringify(d.tab_order)===JSON.stringify(['today','apps','games','search','library']))d.tab_order=clone(DASHBOARD_DEFAULTS.tab_order);
    if(Array.isArray(d.sources)&&d.sources.length){const ids=new Set(d.sources.map(s=>s.id)),urls=new Set(d.sources.map(s=>canonicalManagedSourceURL(s.url)));d.sources.push(...IOSBOOM_PUBLIC_SOURCES.filter(s=>!ids.has(s.id)&&!urls.has(canonicalManagedSourceURL(s.url))).map(clone));}
    d.catalog_profile='iosboom-public-v1';d.allow_user_sources=false;
  }
  return input;
}
normalizeState=function(parsed){const value=integrationNormalize(migrateZsignCatalogue(parsed)),cfg=value.xsign_config;
  const old=parsed?.xsign_config?.security_locks;
  if(old&&!own(old,'allow_app_metadata_editing')&&typeof old.lock_bundle_rename==='boolean')cfg.security_locks.allow_app_metadata_editing=!old.lock_bundle_rename;
  cfg.security_locks.lock_bundle_rename=!cfg.security_locks.allow_app_metadata_editing;
  const d=cfg.dashboard;
  if((parsed?.xsign_config?.dashboard?.experience_version||0)<2){d.experience_version=2;d.allow_user_sources=true;}
  if(Array.isArray(d?.sources))d.sources=d.sources.map(s=>isObject(s)?{enabled:true,format:'auto',...s}:s);
  if(Array.isArray(d?.sections))d.sections=d.sections.map(s=>isObject(s)?{enabled:true,limit:12,...s}:s);
  syncReleaseGate(value);
  return value;};
const numericRelease=value=>typeof value==='string'&&/^[0-9]{1,9}(\.[0-9]{1,9}){0,3}$/.test(value);
const nativeHTTPS=value=>typeof value==='string'&&httpsUrl(value.trim())&&!new URL(value.trim()).hash;
function releaseLink(u){const link=u.manifest_url||u.ipa_url;return typeof link==='string'?link.trim():'';}
function syncReleaseGate(root){
  const cfg=root.xsign_config,u=cfg?.dashboard?.update,f=cfg?.force_update;
  if(!f||typeof u?.required!=='boolean')return;
  f.enabled=u.enabled===true&&u.required;
  if(f.enabled){f.min_version=u.latest_version||'';f.min_build_version=u.build_version||'';f.update_url=releaseLink(u);}
}
function compareRelease(a,b){if(!numericRelease(a)||!numericRelease(b))throw Error('رقم إصدار أو بناء غير صالح.');const x=a.split('.').map(Number),y=b.split('.').map(Number);for(let i=0;i<Math.max(x.length,y.length);i++){const d=(x[i]||0)-(y[i]||0);if(d)return Math.sign(d);}return 0;}
function dashboardErrors(root){
  const errors=[],cfg=root.xsign_config,d=cfg.dashboard;
  if(!d||d.schema_version!==2)return ['يتطلب الربط عقد XSign dashboard v2.'];
  if(!['system','light','dark'].includes(cfg.theme.appearance))errors.push('اختر المظهر التلقائي أو الفاتح أو الداكن.');
  if(typeof d.signing_enabled!=='boolean'||typeof d.allow_user_sources!=='boolean')errors.push('صلاحيات المتجر والتوقيع غير صالحة.');
  if(!Array.isArray(d.sources)||d.sources.length>50)errors.push('قائمة المصادر غير صالحة أو تتجاوز 50 مصدراً.');
  else {const ids=new Set(),urls=new Set();for(const s of d.sources){
    if(!isObject(s)||typeof s.id!=='string'||!s.id.trim()||ids.has(s.id)||typeof s.name!=='string'||!s.name.trim()||!nativeHTTPS(s.url)||typeof s.enabled!=='boolean'||!['auto','json','altstore'].includes(s.format||'auto')){errors.push('أحد المصادر يحتاج هوية واسم ورابط HTTPS وصيغة صحيحة.');continue;}
    ids.add(s.id);const canonical=new URL(canonicalManagedSourceURL(s.url)).href.replace(/\/$/,'');if(urls.has(canonical))errors.push('رابط مصدر مكرر.');urls.add(canonical);
    if(s.icon_url&&!nativeHTTPS(s.icon_url))errors.push('رابط صورة المصدر يجب أن يكون HTTPS.');
    if(s.fields&&(!isObject(s.fields)||Object.values(s.fields).some(v=>typeof v!=='string')))errors.push('تعيين حقول المصدر يجب أن يكون قاموس نصوص.');
  }}
  if(!Array.isArray(d.sections)||d.sections.length>120)errors.push('قائمة أقسام المتجر غير صالحة.');
  else {const ids=new Set();for(const s of d.sections){
    if(!isObject(s)||!s.id||ids.has(s.id)||!s.title||!['today','apps','games'].includes(s.page)||!own(KIND_TITLES,s.kind)||typeof s.enabled!=='boolean'||!Number.isInteger(s.limit)||s.limit<1||s.limit>120){errors.push('أحد أقسام المتجر غير صالح.');continue;}ids.add(s.id);
    if(s.source_url&&!httpsUrl(s.source_url))errors.push('رابط تصفية المصدر يجب أن يكون HTTPS.');
    if(s.sort&&!['name','reverse'].includes(s.sort))errors.push('ترتيب قسم غير مدعوم.');
    if(s.app_ids&&(!Array.isArray(s.app_ids)||s.app_ids.length>300||s.app_ids.some(id=>typeof id!=='string'||!id)))errors.push('تطبيقات القسم تحتاج قائمة معرفات نصية.');
  }}
  if(!Array.isArray(d.tab_order)||!d.tab_order.length||new Set(d.tab_order).size!==d.tab_order.length||d.tab_order.some(key=>!own(TAB_TITLES,key)))errors.push('أبقِ تبويباً واحداً على الأقل واختر ترتيباً دون تكرار.');
  const u=d.update,f=cfg.force_update;
  if(!isObject(u)||typeof u.enabled!=='boolean')errors.push('إعداد التحديث الداخلي غير صالح.');
  else {
    if((u.required!=null&&typeof u.required!=='boolean')||(u.required===true&&!u.enabled))errors.push('حالة إلزام الإصدار غير صالحة.');
    if(typeof u.html!=='string'||u.html.length>100000)errors.push('حد صفحة HTML هو 100000 حرف.');
    if(u.enabled){
      if(!numericRelease(u.latest_version)||u.build_version&&!numericRelease(u.build_version))errors.push('الإصدار الجديد ورقم البناء يحتاجان أرقاماً مفصولة بنقاط.');
      if(u.required===true&&!numericRelease(u.build_version))errors.push('أدخل رقم البناء للتحديث الإجباري.');
      if(u.manifest_url){if(!nativeHTTPS(u.manifest_url))errors.push('رابط manifest يجب أن يكون HTTPS.');}
      else if(!nativeHTTPS(u.ipa_url)||!/^[a-f0-9]{64}$/i.test(u.sha256||''))errors.push('التحديث الداخلي يحتاج رابط IPA وبصمة SHA-256 من الملف نفسه.');
    }
    if(f.enabled){
      if(!nativeHTTPS(f.update_url))errors.push('رابط التحديث الإجباري يجب أن يكون HTTPS من دون جزء #.');
      if(!numericRelease(f.min_version)||f.min_build_version&&!numericRelease(f.min_build_version))errors.push('حد الإصدار الإجباري أو البناء غير صالح.');
      else if(u.enabled&&numericRelease(u.latest_version)){
        const order=compareRelease(u.latest_version,f.min_version);
        if(order<0||order===0&&f.min_build_version&&(!numericRelease(u.build_version)||compareRelease(u.build_version,f.min_build_version)<0))errors.push('النسخة المنشورة أقل من الحد الإجباري؛ صحّح الحد قبل النشر.');
      }
    }
  }
  if(new TextEncoder().encode(JSON.stringify(Store.project(root),null,2)+'\n').length>524288)errors.push('إعدادات التطبيق كبيرة جداً للمزامنة؛ قلّل حجم HTML أو الصور المضمّنة.');
  return errors;
}
const integrationValidate=validateState;
validateState=function(data){return [...integrationValidate(data),...dashboardErrors(data)];};
state=normalizeState(state);
connection.appBundle=XSIGN_INTEGRATION.bundle;
const integrationLoadLocal=loadLocal;
loadLocal=function(){integrationLoadLocal();
  if(!connection.appBundle||connection.appBundle==='thewonderofyou.Feather')connection.appBundle=XSIGN_INTEGRATION.bundle;
};
Object.assign(PAGE_META,{
  layout:['ترتيب المتجر والمصادر','XSIGN / STORE LAYOUT','أقسام المتجر، المصادر المدارة والتبويبات كما يقرأها التطبيق.'],
  sources:['مصادر المتجر والاتصال','XSIGN / SOURCES','أضف أو احذف أي مصدر، حتى المصادر الأساسية، ثم انشر التغييرات.'],
  updates:['التحديث والتثبيت','XSIGN / APP UPDATE','اعتمد إصداراً واحداً وتحكّم في صفحة تثبيته.'],
  integration:['ربط التطبيق','XSIGN / INTEGRATION','عقد الربط الفعلي وما يلزم لتطبيق الإعدادات على الأجهزة.']
});
let editingManagedSource=null,editingStoreSection=null;
function integrationChange(action,label){mutate(action,label);syncInputs();renderIntegration();}
function integrationMove(list,index,offset){const other=index+offset;if(other<0||other>=list.length)return;
  if(list===state.xsign_config.dashboard.sources&&(managedSourcePriority(list[index])<3||managedSourcePriority(list[other])<3)){
    toast('أولوية IPA BLACK ثم مصدري Zsign. يمكنك ترتيب المصادر الإضافية.');return;}
  integrationChange(()=>{[list[index],list[other]]=[list[other],list[index]];},'تغيير ترتيب المتجر');}
function sourceOrSectionRow(item,index,list,isSource){
  const row=text('div','','entry row'),details=text('div','','grow');
  details.append(text('strong',isSource?item.name:item.title),text('small',isSource?item.url:(TAB_TITLES[item.page]||item.page)+' · '+KIND_TITLES[item.kind]+' · '+item.limit,'muted'));
  row.append(details,button('تعديل',()=>isSource?editManagedSource(item):editStoreSection(item),'edit'),
    button(item.enabled?'إخفاء':'إظهار',()=>integrationChange(()=>item.enabled=!item.enabled,'تغيير ظهور عنصر المتجر')));
  if(isSource&&managedSourcePriority(item)<3)row.append(text('small','أولوية ثابتة','muted'));
  else row.append(button('↑',()=>integrationMove(list,index,-1)),button('↓',()=>integrationMove(list,index,1)));
  row.append(button('حذف',()=>confirmAction('حذف من المتجر','يُحذف هذا العنصر من المسودة. يصل التغيير إلى التطبيق بعد النشر.',()=>integrationChange(()=>list.splice(list.indexOf(item),1),'حذف عنصر متجر')),'trash'));
  return row;
}
function editManagedSource(item=null){editingManagedSource=item?.id||null;
  for(const [id,key]of [['managedName','name'],['managedURL','url'],['managedIcon','icon_url'],['managedFormat','format'],['managedRoot','root_path']])$(id).value=item?.[key]||(key==='format'?'auto':'');
  $('managedFields').value=item?.fields?JSON.stringify(item.fields,null,2):'';$('saveManagedSource').textContent=item?'حفظ تعديل المصدر':'إضافة المصدر';$('managedName').focus();}
function saveManagedSource(event){event.preventDefault();try{
  const d=state.xsign_config.dashboard,existing=d.sources.find(s=>s.id===editingManagedSource);
  const fields=$('managedFields').value.trim();let mapping=fields?JSON.parse(fields):undefined;if(mapping)assertSafeTree(mapping);
  const item={...existing,id:existing?.id||'source-'+uid(),name:$('managedName').value.trim(),url:$('managedURL').value.trim(),
    enabled:existing?.enabled??true,format:$('managedFormat').value,icon_url:$('managedIcon').value.trim()||undefined,
    root_path:$('managedRoot').value.trim()||undefined,fields:mapping};
  const next=clone(state),list=next.xsign_config.dashboard.sources,index=list.findIndex(s=>s.id===item.id);if(index>=0)list[index]=item;else list.push(item);
  const errors=dashboardErrors(next);if(errors.length)throw Error(errors[0]);
  integrationChange(()=>state=next,'حفظ مصدر متجر');editManagedSource();
}catch(error){toast(error.message,'error');}}
function editStoreSection(item=null){editingStoreSection=item?.id||null;
  for(const [id,key,fallback]of [['sectionTitleV2','title',''],['sectionPageV2','page','today'],['sectionKindV2','kind','apps'],
    ['sectionLimitV2','limit',12],['sectionSourceV2','source_url',''],['sectionCategoryV2','category_id',''],['sectionSortV2','sort','']])$(id).value=item?.[key]??fallback;
  $('sectionAppsV2').value=(item?.app_ids||[]).join(', ');$('saveStoreSection').textContent=item?'حفظ تعديل القسم':'إضافة القسم';$('sectionTitleV2').focus();}
function saveStoreSection(event){event.preventDefault();try{
  const d=state.xsign_config.dashboard,existing=d.sections.find(s=>s.id===editingStoreSection);
  const item={...existing,id:existing?.id||'section-'+uid(),title:$('sectionTitleV2').value.trim(),page:$('sectionPageV2').value,
    kind:$('sectionKindV2').value,limit:Number($('sectionLimitV2').value),enabled:existing?.enabled??true,
    source_url:$('sectionSourceV2').value.trim()||undefined,category_id:$('sectionCategoryV2').value.trim()||undefined,
    sort:$('sectionSortV2').value||undefined,app_ids:$('sectionAppsV2').value.split(',').map(s=>s.trim()).filter(Boolean)};
  const next=clone(state),list=next.xsign_config.dashboard.sections,index=list.findIndex(s=>s.id===item.id);if(index>=0)list[index]=item;else list.push(item);
  const errors=dashboardErrors(next);if(errors.length)throw Error(errors[0]);
  integrationChange(()=>state=next,'حفظ قسم متجر');editStoreSection();
}catch(error){toast(error.message,'error');}}
function ownerUpdateFromApp(app,bundle){
  if(!app||app.bundleIdentifier!==bundle)throw Error('معرف IPA لا يطابق Bundle ID الخاص ببناء XSign. لم تتغير إعدادات التحديث.');
  if(!numericRelease(app.version)||app.buildVersion&&!numericRelease(app.buildVersion)||!httpsUrl(app.downloadURL)||!/^[a-f0-9]{64}$/i.test(app.sha256||''))throw Error('هذا الإصدار لا يحتوي بيانات الناشر الكاملة. أعد جلب الكتالوج بعد نجاح Actions.');
  return {latest_version:app.version,build_version:app.buildVersion||'',ipa_url:app.downloadURL,sha256:app.sha256.toLowerCase(),manifest_url:''};
}
function adoptCatalogueUpdate(){try{
  const app=state.apps.find(a=>catalogueKey(a)===$('selfUpdateApp').value),expected=$('expectedBundle').value.trim();
  const patch=ownerUpdateFromApp(app,expected);connection.appBundle=expected;
  integrationChange(()=>Object.assign(state.xsign_config.dashboard.update,patch),'ربط إصدار XSign من الكتالوج');
  toast('نُقلت بيانات IPA وبصمته إلى المسودة. راجع الصفحة ثم فعّل التحديث وانشر.');
}catch(error){toast(error.message,'error');}}
function catalogueRelease(link){return state.apps.find(a=>a.bundleIdentifier===XSIGN_INTEGRATION.bundle&&a.downloadURL===link&&numericRelease(a.version)&&/^[a-f0-9]{64}$/i.test(a.sha256||''));}
function setReleaseLink(link,kind){
  const u=state.xsign_config.dashboard.update,previous=releaseLink(u);
  link=link.trim();
  if(!kind){try{kind=new URL(link).pathname.toLowerCase().endsWith('.plist')?'manifest':(link===previous&&u.manifest_url?'manifest':'ipa');}catch{kind='ipa';}}
  if(link!==previous||(kind==='manifest')!==Boolean(u.manifest_url)){u.sha256='';u.build_version='';}
  u.ipa_url=kind==='ipa'?link:'';u.manifest_url=kind==='manifest'?link:'';
  const app=kind==='ipa'&&catalogueRelease(link);
  if(app)Object.assign(u,ownerUpdateFromApp(app,XSIGN_INTEGRATION.bundle));
  syncReleaseGate(state);
}
function setReleaseMode(mode){
  const u=state.xsign_config.dashboard.update;
  if(!['off','optional','required'].includes(mode))return;
  u.enabled=mode!=='off';
  u.required=mode==='required';
  syncReleaseGate(state);
}
function releaseMetadataURL(link){
  if(!nativeHTTPS(link))return null;
  const url=new URL(link),parts=url.pathname.split('/').filter(Boolean);
  if(url.hostname!=='github.com'||url.port||url.search||parts.length!==6||parts[2]!=='releases'||parts[3]!=='download')return null;
  if(!parts.slice(0,2).every(p=>/^[A-Za-z0-9_.-]+$/.test(p)))return null;
  return {url:'https://api.github.com/repos/'+parts.slice(0,2).join('/')+'/releases/tags/'+encodeURIComponent(decodeURIComponent(parts[4])),asset:decodeURIComponent(parts[5])};
}
async function publicReleaseJSON(url){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),8000);
  try {const res=await fetch(url,{credentials:'omit',cache:'no-store',redirect:'error',signal:controller.signal});
    if(!res.ok)throw Error('لم يصل الملف المنشور إلى الرابط العام بعد.');return await res.json();
  }finally{clearTimeout(timer);}
}
async function fillReleaseMetadata(){
  const u=state.xsign_config.dashboard.update,link=releaseLink(u),btn=$('fillReleaseMetadata');
  if(!link||!nativeHTTPS(link)){toast('أدخل رابط إصدار HTTPS أولاً.','error');return;}
  const app=catalogueRelease(link);
  if(app){integrationChange(()=>Object.assign(u,ownerUpdateFromApp(app,XSIGN_INTEGRATION.bundle)),'جلب إصدار XSign من الكتالوج');toast('تم ملء الإصدار والبناء والبصمة.');return;}
  if(u.manifest_url){$('releaseAdvanced').open=true;toast('أدخل رقم البناء كما يظهر في manifest.');return;}
  btn.disabled=true;
  try{
    const target=releaseMetadataURL(link);
    if(!target)throw Error('أدخل بصمة SHA-256 في الخيارات المتقدمة لهذا الرابط.');
    const release=await publicReleaseJSON(target.url);
    const asset=release.draft===false&&Array.isArray(release.assets)&&release.assets.find(a=>a.name===target.asset&&a.state==='uploaded');
    if(!asset||!/^sha256:[a-f0-9]{64}$/i.test(asset.digest||''))throw Error('الرابط لا يحتوي ملف Release منشوراً ببصمة SHA-256.');
    if(releaseLink(state.xsign_config.dashboard.update)!==link)return;
    integrationChange(()=>state.xsign_config.dashboard.update.sha256=asset.digest.slice(7).toLowerCase(),'جلب بصمة إصدار XSign');
    toast('تم جلب بصمة الملف. تأكد من رقم الإصدار ثم انشر.');
  }catch(error){$('releaseAdvanced').open=true;toast(error.message,'error');}
  finally{btn.disabled=false;}
}
let latestDeliveryProbe=0;
async function observePublishedProjection(c,revision){
  const current=++latestDeliveryProbe,box=$('liveDeliveryStatus');
  if(!isLiveAppTarget(c)){
    box.textContent='تم النشر إلى الوجهة المختارة. بناء XSign الحالي يقرأ ipablack/repo على main.';return;
  }
  box.textContent='تم النشر. جارٍ التحقق من ظهور المراجعة '+revision+' للأجهزة…';
  for(let attempt=0;attempt<3;attempt++){
    if(attempt)await new Promise(resolve=>setTimeout(resolve,3000));
    if(current!==latestDeliveryProbe)return;
    try{
      const config=await publicReleaseJSON('https://raw.githubusercontent.com/ipablack/repo/main/xsign-config.json?xsign_live='+Math.floor(Date.now()/5000));
      if(current!==latestDeliveryProbe)return;
      if(config.xsign_config&&Number.isSafeInteger(config.repo_revision_id)&&config.repo_revision_id>=revision){
        box.textContent='المراجعة '+config.repo_revision_id+' متاحة الآن لـ XSign. الأجهزة المفتوحة تقرأها في دورة المزامنة التالية.';return;
      }
    }catch{}
  }
  if(current===latestDeliveryProbe)box.textContent='تم النشر إلى GitHub. ظهور المراجعة للأجهزة ينتظر وصولها إلى الرابط العام.';
}
function installEscape(value){return String(value??'').replace(/[&<>"{}]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;','{':'&#123;','}':'&#125;'}[c]));}
function defaultInstallFragment(u,required){
  const template=typeof XSIGN_INSTALL_TEMPLATE==='string'?XSIGN_INSTALL_TEMPLATE:'<h1>{{heading}}</h1><p>{{name}} · {{version}}</p><p>{{details}}</p>{{action}}';
  const values={heading:required?'حدّث XSign للمتابعة':'تحديث XSign',name:'XSign',version:'الإصدار '+(u.latest_version||'—')+(u.build_version?' · البناء '+u.build_version:''),details:u.notes||'ثبّت الإصدار ووافق على طلب iOS.'};
  return template.replace(/\{\{(\w+)\}\}/g,(_,key)=>key==='action'?'<a class="install-action" href="xsign-update://install">تثبيت التحديث</a>':installEscape(values[key]));
}
function renderUpdateHTML(){const frame=$('ownerHTMLPreview');if(!frame)return;
  const cfg=state.xsign_config,u=cfg.dashboard.update,required=u.required??cfg.force_update.enabled;
  const content=u.html||defaultInstallFragment(u,required);
  const doc='<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;;style-src &#39;unsafe-inline&#39;;img-src data:;form-action &#39;none&#39;;base-uri &#39;none&#39;"></head><body>'+content+'</body></html>';
  if(frame.srcdoc!==doc)frame.srcdoc=doc;
}
function renderReleaseEditor(){
  const cfg=state.xsign_config,u=cfg.dashboard.update,f=cfg.force_update;
  $('ownerReleaseLink').value=releaseLink(u);$('ownerLinkKind').value=u.manifest_url?'manifest':'ipa';
  $('ownerReleaseMode').value=u.required===true?'required':u.required==null&&f.enabled?'legacy':u.enabled?'optional':'off';
  $('legacyReleaseSettings').hidden=typeof u.required==='boolean'||!f.enabled;
  $('ownerReleaseState').textContent=u.required===true
    ? 'بعد النشر يظهر التحديث قبل المتجر للأجهزة التي تحتاجه. حدّد إصداراً ورقم بناء أعلى عند نشر نسخة جديدة.'
    : u.enabled ? 'تظهر الصفحة تلقائياً مرة لكل إصدار جديد، ويمكن فتحها مجدداً من الإعدادات.'
      : f.enabled ? 'يُستخدم حد الإصدار الإجباري من الإعداد السابق.'
        : 'التحديث متوقف. اختر اختياري أو إجباري ثم انشر الملفين.';
  renderUpdateHTML();
}
function renderIntegration(){
  if(!$('managedSourcesV2'))return;const d=state.xsign_config.dashboard;
  $('managedSourcesV2').replaceChildren(...d.sources.map((item,i)=>sourceOrSectionRow(item,i,d.sources,true)));
  $('storeSectionsV2').replaceChildren(...d.sections.map((item,i)=>sourceOrSectionRow(item,i,d.sections,false)));
  const tabs=$('storeTabsV2');tabs.replaceChildren();
  const available=[...d.tab_order,...Object.keys(TAB_TITLES).filter(k=>!d.tab_order.includes(k))];
  for(const key of available){const index=d.tab_order.indexOf(key),row=text('div','','row entry'),label=text('label','','grow'),input=document.createElement('input');input.type='checkbox';input.checked=index>=0;
    input.addEventListener('change',()=>{if(!input.checked&&d.tab_order.length===1){input.checked=true;toast('أبقِ تبويباً واحداً على الأقل.','error');return;}
      integrationChange(()=>{if(input.checked)d.tab_order.push(key);else d.tab_order.splice(d.tab_order.indexOf(key),1);},'تغيير تبويبات التطبيق');});
    label.append(input,document.createTextNode(' '+TAB_TITLES[key]));row.append(label);
    if(index>=0)row.append(button('↑',()=>integrationMove(d.tab_order,index,-1)),button('↓',()=>integrationMove(d.tab_order,index,1)));tabs.append(row);
  }
  const selected=$('selfUpdateApp').value;const select=$('selfUpdateApp');select.replaceChildren();const empty=text('option','اختر إصداراً من الكتالوج');empty.value='';select.append(empty);
  for(const app of state.apps.filter(a=>a.bundleIdentifier===XSIGN_INTEGRATION.bundle)){const option=text('option',(app.name||app.bundleIdentifier)+' · '+app.version);option.value=catalogueKey(app);select.append(option);}select.value=selected;
  $('expectedBundle').value=XSIGN_INTEGRATION.bundle;
  $('integrationRevision').textContent=String(state.repo_revision_id);
  $('integrationIdentity').textContent=XSIGN_INTEGRATION.name+' '+XSIGN_INTEGRATION.version+' · '+XSIGN_INTEGRATION.bundle+' · iOS '+XSIGN_INTEGRATION.minimumOS+'+';
  const expected=isLiveAppTarget(connection)&&connection.appBundle===XSIGN_INTEGRATION.bundle;
  $('integrationTarget').textContent=expected?'وجهة النشر تطابق رابط القراءة في هذا البناء':'وجهة النشر مختلفة عن رابط بناء XSign. عدّل الربط قبل الاعتماد.';
  $('integrationSource').textContent=XSIGN_INTEGRATION.source;
  $('integrationFeatures').replaceChildren(...XSIGN_INTEGRATION.features.map(([title,path])=>{const row=text('div','','entry');row.append(text('strong',title),text('small',path,'muted latin'));return row;}));
  renderReleaseEditor();
}
const integrationRenderAll=renderAll;
renderAll=function(){integrationRenderAll();renderIntegration();};
const integrationOpenPage=openPage;
openPage=function(name,updateHash=true){integrationOpenPage(name,updateHash);if(['sources','layout','updates','integration'].includes(name))renderIntegration();};
const integrationField=fieldInput;
fieldInput=function(el,final=false){integrationField(el,final);const path=el.dataset.path,locks=state.xsign_config.security_locks;
  if(path==='xsign_config.security_locks.lock_bundle_rename'){locks.allow_app_metadata_editing=!locks.lock_bundle_rename;$('allowMetadata').checked=locks.allow_app_metadata_editing;}
  if(path==='xsign_config.security_locks.allow_app_metadata_editing'){locks.lock_bundle_rename=!locks.allow_app_metadata_editing;$('lockBundle').checked=locks.lock_bundle_rename;}
  if(path.startsWith('xsign_config.dashboard.update.')){syncReleaseGate(state);renderUpdateHTML();}
  if(path==='xsign_config.force_update.enabled')renderReleaseEditor();
};
const integrationBind=bindStoreEvents;
bindStoreEvents=function(){integrationBind();
  $('managedSourceForm').addEventListener('submit',saveManagedSource);$('storeSectionForm').addEventListener('submit',saveStoreSection);
  $('cancelManagedSource').addEventListener('click',()=>editManagedSource());$('cancelStoreSection').addEventListener('click',()=>editStoreSection());
  $('adoptCatalogueUpdate').addEventListener('click',adoptCatalogueUpdate);
  $('ownerReleaseLink').addEventListener('input',event=>{setReleaseLink(event.target.value);syncInputs();renderOverview();clearTimeout(saveTimer);saveTimer=setTimeout(persist,260);});
  $('ownerReleaseLink').addEventListener('change',renderReleaseEditor);
  $('ownerLinkKind').addEventListener('change',event=>integrationChange(()=>setReleaseLink(releaseLink(state.xsign_config.dashboard.update),event.target.value),'تغيير نوع رابط الإصدار'));
  $('ownerReleaseMode').addEventListener('change',event=>integrationChange(()=>setReleaseMode(event.target.value),'تغيير حالة الإصدار'));
  $('fillReleaseMetadata').addEventListener('click',fillReleaseMetadata);
  $('ownerHTMLFile').addEventListener('change',async event=>{try{const file=event.target.files[0];if(!file)return;if(file.size>200000)throw Error('اختر صفحة HTML أصغر من 200 KB.');const html=await file.text();if(html.length>100000)throw Error('حد الصفحة 100000 حرف.');integrationChange(()=>state.xsign_config.dashboard.update.html=html,'استيراد صفحة التحديث');}catch(error){toast(error.message,'error');}finally{event.target.value='';}});
  $('ownerHTMLSample').addEventListener('click',()=>confirmAction('قالب صفحة التثبيت','استبدال HTML الحالي بقالب قابل للتعديل؟',()=>integrationChange(()=>state.xsign_config.dashboard.update.html=defaultInstallFragment(state.xsign_config.dashboard.update,true),'تغيير صفحة التثبيت'),'تطبيق القالب',false));
  $('resetInstallHTML').addEventListener('click',()=>integrationChange(()=>state.xsign_config.dashboard.update.html='','استعادة صفحة التثبيت الافتراضية'));
};
