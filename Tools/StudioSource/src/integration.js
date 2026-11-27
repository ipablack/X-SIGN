/* XSign native dashboard v2. Published settings match the reviewed Swift readers. */
const XSIGN_LEGACY_BUNDLE='com.ipablack.xsign';
const XSIGN_INTEGRATION={schema:2,minimumOS:'15.0',name:'Xsign',version:'1.0',bundle:'Xsign',source:'IPA BLACK',
  features:[['المظهر الداكن والفاتح والألوان','theme'],['الإقلاع وحركة X وHTML/CSS','splash_screen'],
  ['المصادر وترتيب المتجر والتبويبات','dashboard'],['التوقيع وتحرير البيانات والأيقونة والحقن','security_locks'],
  ['الصيانة والتحديث الإجباري ورقم البناء','force_update'],['صفحة HTML والتحديث الموقّع','dashboard.update'],
  ['الشريط العلوي وتجديد الكاش','app_control'],['التطبيقات والإصدارات والأخبار والتصنيفات','catalogue']]};
const DASHBOARD_DEFAULTS={schema_version:2,catalog_profile:'iosboom-public-v1',experience_version:3,allow_user_sources:true,signing_enabled:true,
  today_show_date:true,today_show_account:true,today_show_download_buttons:true,
  tab_order:['today','games','apps','library','search'],
  sources:[{id:'xsign.core.owned',name:'IPA BLACK',url:OWNED_CANONICAL_URL,enabled:true,format:'auto'},
    {id:'xsign.core.primary',name:'IPA SOON',url:PRIMARY_SOURCE_URL,enabled:true,format:'auto'}],
  sections:[['today-news','الأخبار','today','news'],['today-featured','مختارات اليوم','today','featured'],
    ['today-apps','جديد المتجر','today','apps'],
    ['apps-categories','التصنيفات','apps','categories'],['apps-featured','مختارات التطبيقات','apps','featured'],['apps-list','التطبيقات','apps','apps'],
    ['games-categories','أقسام الألعاب','games','categories'],['games-featured','مختارات الألعاب','games','featured'],['games-list','الألعاب','games','apps']].map(([id,title,page,kind])=>({id,title,page,kind,enabled:true,limit:id==='today-featured'?2:kind==='apps'?60:12})),
  bundle_updates:{}, signing_libraries:[],
  update:{enabled:false,latest_version:'',build_version:'',ipa_url:'',sha256:'',manifest_url:'',notes:'',html:''}};
const TAB_TITLES={today:'اليوم',apps:'التطبيقات',games:'الألعاب',search:'البحث',library:'التوقيع والمكتبة'};
const KIND_TITLES={apps:'قائمة تطبيقات',featured:'تطبيقات مميزة',sources:'المصادر',categories:'التصنيفات',news:'الأخبار'};
const defaultTodaySourceIDs=new Set(['xsign.core.owned','xsign.core.primary']);
function todaySelection(d){
  const selected=Array.isArray(d.today_source_ids)?new Set(d.today_source_ids):defaultTodaySourceIDs;
  return d.sources.filter(source=>selected.has(source.id)).map(source=>source.id);
}
function canonicalManagedSourceURL(value){
  if(typeof value!=='string')return value;
  try {
    const url=new URL(value.trim()),parts=url.pathname.split('/').filter(Boolean);
    if(url.hostname==='github.com'&&parts.length>=5&&['raw','blob'].includes(parts[2])){
      url.hostname='raw.githubusercontent.com';
      url.pathname='/'+[...parts.slice(0,2),...parts.slice(3)].join('/');
      url.searchParams.delete('raw');
    }
    if(url.hostname==='raw.githubusercontent.com'){
      url.pathname=url.pathname.replace('/refs/heads/','/');
      const parts=url.pathname.split('/').filter(Boolean);
      if(/^\/ipablack\/x-sign\/main\/public\/sources\/ipasoon\.json$/i.test(url.pathname)&&
         url.protocol==='https:'&&!url.username&&!url.password&&!url.port&&!url.search&&!url.hash)return IPA_SOON_SNAPSHOT;
      if(parts.length===4&&parts[0].toLowerCase()==='ipablack'&&parts[1].toLowerCase()==='repo'&&
         parts[2]==='main'&&parts[3]==='repo.json'&&url.protocol==='https:'&&!url.username&&!url.password&&!url.port&&!url.hash){
        return OWNED_CANONICAL_URL;
      }
    }
    return url.href;
  }catch{return value;}
}
function managedSourceKey(value){return canonicalManagedSourceURL(value)?.replace(/\/$/,'');}
function pinnedSource(source){return source?.id==='xsign.core.owned'||managedSourceKey(source?.url)===OWNED_CANONICAL_URL;}
const integrationCoreSources=enforceCoreSources;
enforceCoreSources=function(value){
  const dashboard=value.xsign_config.dashboard;
  if(Array.isArray(dashboard?.sources)){
    const sources=dashboard.sources,owned=DASHBOARD_DEFAULTS.sources[0];
    for(let i=sources.length-1;i>=1;i--)if(pinnedSource(sources[i]))sources.splice(i,1);
    if(pinnedSource(sources[0])){
      if(JSON.stringify(sources[0])!==JSON.stringify(owned))sources[0]=clone(owned);
    }else sources.unshift(clone(owned));
  }
  syncReleaseGate(value);
  return integrationCoreSources(value);
};
const integrationDefaults=createDefaultState;
createDefaultState=function(){const value=integrationDefaults();value.xsign_config.dashboard=clone(DASHBOARD_DEFAULTS);
  value.xsign_config.usage_stats={enabled:false,endpoint:''};
  value.xsign_config.push_endpoint='';
  value.xsign_config.theme.appearance='system';value.xsign_config.force_update.min_build_version='';return value;};
const integrationNormalize=normalizeState;
function migrateDashboard(parsed){
  const input=clone(parsed),cfg=input?.xsign_config;
  if(!isObject(cfg))return input;
  if(!own(cfg,'dashboard')&&Array.isArray(cfg.app_control?.core_sources)){
    cfg.dashboard={sources:cfg.app_control.core_sources};
  }
  const d=cfg.dashboard;
  if(!isObject(d))return input;
  if(d.compatibility_update_bundle==='xsign'&&isObject(d.bundle_updates?.[XSIGN_LEGACY_BUNDLE])){
    d.update=clone(d.bundle_updates[XSIGN_LEGACY_BUNDLE]);
    delete d.bundle_updates[XSIGN_LEGACY_BUNDLE];
    delete d.compatibility_update_bundle;
  }
  if(!own(d,'sources')&&Array.isArray(cfg.app_control?.core_sources))d.sources=cfg.app_control.core_sources;
  if(Array.isArray(d.sections)){
    const appsIndex=d.sections.findIndex(section=>section?.page==='apps'&&section.kind==='apps');
    if(appsIndex!==-1&&!d.sections.some(section=>section?.page==='apps'&&section.kind==='featured')){
      d.sections.splice(appsIndex,0,clone(DASHBOARD_DEFAULTS.sections.find(section=>section.id==='apps-featured')));
    }
    const gamesIndex=d.sections.findIndex(section=>section?.id==='games-featured'&&section.page==='games');
    if(gamesIndex!==-1&&!d.sections.some(section=>section?.page==='games'&&section.kind==='categories')){
      const standard=DASHBOARD_DEFAULTS.sections.find(section=>section.id==='games-categories');
      d.sections.splice(gamesIndex,0,clone(standard));
    }
    if((d.experience_version??0)<3&&d.sections.some(s=>s?.page==='today')&&
       !d.sections.some(s=>s?.page==='today'&&['apps','featured'].includes(s.kind))){
      d.sections.push(...DASHBOARD_DEFAULTS.sections.filter(s=>s.page==='today'&&s.kind!=='news').map(clone));
    }
  }
  if((d.experience_version??0)<2)d.allow_user_sources=true;
  d.experience_version=Math.max(3,d.experience_version||0);
  return input;
}
normalizeState=function(parsed){
  const value=integrationNormalize(migrateDashboard(parsed)),cfg=value.xsign_config;
  cfg.push_endpoint=typeof parsed?.xsign_config?.push_endpoint==='string'?parsed.xsign_config.push_endpoint.trim():'';
  const old=parsed?.xsign_config?.security_locks;
  if(old&&!own(old,'allow_app_metadata_editing')&&typeof old.lock_bundle_rename==='boolean')cfg.security_locks.allow_app_metadata_editing=!old.lock_bundle_rename;
  cfg.security_locks.lock_bundle_rename=!cfg.security_locks.allow_app_metadata_editing;
  const d=cfg.dashboard;
  if(Array.isArray(d.sources))d.sources=d.sources.map(s=>{
    if(!isObject(s))return s;
    const name=s.id==='xsign.core.primary'&&/^ipa\s*soon$/i.test(s.name)?'IPA SOON':s.name;
    return {...s,name,enabled:s.enabled!==false,format:s.format||'auto',url:canonicalManagedSourceURL(s.url)};
  });
  if(Array.isArray(d.today_source_ids)&&Array.isArray(d.sources))d.today_source_ids=todaySelection(d);
  if(Array.isArray(d.sections)){
    const categoryPages=new Set();
    d.sections=d.sections.map(s=>{
      if(!isObject(s))return s;
      let enabled=s.enabled!==false;
      if(enabled&&s.kind==='categories'){
        enabled=!categoryPages.has(s.page);
        categoryPages.add(s.page);
      }
      return {limit:12,...s,enabled};
    });
  }
  return enforceCoreSources(value);
};
const numericRelease=value=>typeof value==='string'&&/^[0-9]{1,9}(\.[0-9]{1,9}){0,3}$/.test(value);
const nativeHTTPS=value=>typeof value==='string'&&httpsUrl(value.trim())&&!new URL(value.trim()).hash;
function releaseLink(u){const link=u.manifest_url||u.ipa_url;return typeof link==='string'?link.trim():'';}
function syncReleaseGate(root){
  const cfg=root.xsign_config,u=cfg?.dashboard?.update,f=cfg?.force_update;
  if(!f||typeof u?.required!=='boolean')return;
  f.enabled=u.enabled===true&&u.required;
  if(f.enabled){f.min_version=u.latest_version||'';f.min_build_version=u.build_version||'';f.update_url=releaseLink(u);}
}
function publicationConfiguration(root){
  const projected=Store.project(root),dashboard=projected.xsign_config.dashboard;
  if(isObject(projected.xsign_config.usage_stats)){
    const usage=projected.xsign_config.usage_stats;
    projected.xsign_config.usage_stats={enabled:usage.enabled,endpoint:usage.endpoint};
  }
  projected.xsign_config.push_endpoint=root.xsign_config.push_endpoint||'';
  const primary=dashboard.bundle_updates?.xsign;
  if(primary){
    dashboard.bundle_updates[XSIGN_LEGACY_BUNDLE]=clone(dashboard.update);
    dashboard.update={...clone(primary),bundle_identifier:'xsign'};
    dashboard.compatibility_update_bundle='xsign';
  }
  return projected;
}
function releasePublicationSummary(root){
  const dashboard=root.xsign_config.dashboard;
  const bundle=typeof managedUpdateBundle==='string'?managedUpdateBundle:bundleKey(XSIGN_INTEGRATION.bundle);
  const release=bundle===XSIGN_LEGACY_BUNDLE?dashboard.update:dashboard.bundle_updates?.[bundle];
  return {bundle,mode:release?.enabled===true?(release.required===true?'إجباري':'اختياري'):'متوقف'};
}
function compareRelease(a,b){if(!numericRelease(a)||!numericRelease(b))throw Error('رقم إصدار أو بناء غير صالح.');const x=a.split('.').map(Number),y=b.split('.').map(Number);for(let i=0;i<Math.max(x.length,y.length);i++){const d=(x[i]||0)-(y[i]||0);if(d)return Math.sign(d);}return 0;}
function dashboardErrors(root){
  const errors=[],cfg=root.xsign_config,d=cfg.dashboard;
  if(cfg.push_endpoint&&!pushServiceURL(cfg.push_endpoint))errors.push('الإشعارات تحتاج عنوان خدمة HTTPS صالحًا.');
  const usage=cfg.usage_stats;
  if(!isObject(usage)||typeof usage.enabled!=='boolean'||typeof usage.endpoint!=='string'||
     ((usage.enabled||usage.endpoint.trim())&&!usageServiceURL(usage.endpoint))){
    errors.push('الإحصاءات تحتاج عنوان خدمة HTTPS دون مسار أو بيانات دخول.');
  }
  if(!d||d.schema_version!==2)return ['يتطلب الربط عقد XSign dashboard v2.'];
  const libraryError=signingLibraryError(d.signing_libraries);
  if(libraryError)errors.push(libraryError);
  if(!['system','light','dark'].includes(cfg.theme.appearance))errors.push('اختر المظهر التلقائي أو الفاتح أو الداكن.');
  if(typeof d.signing_enabled!=='boolean'||typeof d.allow_user_sources!=='boolean')errors.push('صلاحيات المتجر والتوقيع غير صالحة.');
  for(const key of ['today_show_date','today_show_account','today_show_download_buttons']){
    if(typeof d[key]!=='boolean')errors.push('خيارات صفحة اليوم تحتاج قيمة تشغيل أو إيقاف.');
  }
  if(d.today_show_account===false&&Array.isArray(d.tab_order)&&!d.tab_order.some(key=>['apps','games','search','library'].includes(key))){
    errors.push('أبقِ الوصول إلى الإعدادات عبر تبويب آخر أو أظهر زر الحساب في اليوم.');
  }
  if(!Array.isArray(d.sources)||d.sources.length>50)errors.push('قائمة المصادر غير صالحة أو تتجاوز 50 مصدراً.');
  else {const ids=new Set(),urls=new Set();for(const s of d.sources){
    if(!isObject(s)||typeof s.id!=='string'||!s.id.trim()||ids.has(s.id)||typeof s.name!=='string'||!s.name.trim()||!nativeHTTPS(s.url)||typeof s.enabled!=='boolean'||!['auto','json','altstore','rest'].includes(s.format||'auto')){errors.push('أحد المصادر يحتاج هوية واسم ورابط HTTPS وصيغة صحيحة.');continue;}
    ids.add(s.id);const canonical=managedSourceKey(s.url);if(urls.has(canonical))errors.push('رابط مصدر مكرر.');urls.add(canonical);
    if(s.icon_url&&!nativeHTTPS(s.icon_url))errors.push('رابط صورة المصدر يجب أن يكون HTTPS.');
    if(s.fields&&(!isObject(s.fields)||Object.values(s.fields).some(v=>typeof v!=='string')))errors.push('تعيين حقول المصدر يجب أن يكون قاموس نصوص.');
    if(s.numeric_types!=null&&typeof s.numeric_types!=='boolean')errors.push('تفسير أنواع المصدر الرقمية يحتاج قيمة تشغيل أو إيقاف.');
  }}
  if(d.today_source_ids!=null&&(!Array.isArray(d.today_source_ids)||d.today_source_ids.some(id=>typeof id!=='string'||!d.sources?.some?.(source=>source.id===id)))){
    errors.push('مصادر اليوم يجب أن تكون من المصادر المسجلة في اللوحة.');
  }
  if(!Array.isArray(d.sections)||d.sections.length>120)errors.push('قائمة أقسام المتجر غير صالحة.');
  else {const ids=new Set();for(const s of d.sections){
    if(!isObject(s)||!s.id||ids.has(s.id)||!s.title||!['today','apps','games'].includes(s.page)||!own(KIND_TITLES,s.kind)||typeof s.enabled!=='boolean'||!Number.isInteger(s.limit)||s.limit<1||s.limit>120){errors.push('أحد أقسام المتجر غير صالح.');continue;}ids.add(s.id);
    if(s.source_url&&!nativeHTTPS(s.source_url))errors.push('رابط تصفية المصدر يجب أن يكون HTTPS.');
    if(s.enabled&&s.source_url&&s.page==='today'&&nativeHTTPS(s.source_url)&&
       !d.sources?.some?.(source=>managedSourceKey(source.url)===managedSourceKey(s.source_url))){
      errors.push('اختر مصدراً موجوداً في لوحة التحكم لقسم اليوم.');
    }
    if(s.sort&&!['name','reverse'].includes(s.sort))errors.push('ترتيب قسم غير مدعوم.');
    if(s.app_ids&&(!Array.isArray(s.app_ids)||s.app_ids.length>300||s.app_ids.some(id=>typeof id!=='string'||!id)))errors.push('تطبيقات القسم تحتاج قائمة معرفات نصية.');
  }}
  if(!Array.isArray(d.tab_order)||!d.tab_order.length||new Set(d.tab_order).size!==d.tab_order.length||d.tab_order.some(key=>!own(TAB_TITLES,key)))errors.push('أبقِ تبويباً واحداً على الأقل واختر ترتيباً دون تكرار.');
  const u=d.update,f=cfg.force_update;
  errors.push(...releasePolicyErrors(u,XSIGN_LEGACY_BUNDLE,f));
  if(!isObject(d.bundle_updates))errors.push('إعدادات تحديث البندلات الإضافية غير صالحة.');
  else for(const [bundle,release] of Object.entries(d.bundle_updates)){
    if(!validReleaseBundle(bundle)||bundle!==bundleKey(bundle)||bundle===XSIGN_LEGACY_BUNDLE)errors.push('معرف تحديث إضافي غير صالح.');
    else errors.push(...releasePolicyErrors(release,bundle).map(error=>bundle+' — '+error));
  }
  if(new TextEncoder().encode(JSON.stringify(publicationConfiguration(root),null,2)+'\n').length>524288)errors.push('إعدادات التطبيق كبيرة جداً للمزامنة؛ قلّل حجم HTML أو الصور المضمّنة.');
  return errors;
}
function releasePolicyErrors(u,bundle,f){
  const errors=[];
  if(!isObject(u)||typeof u.enabled!=='boolean')return ['إعداد التحديث الداخلي غير صالح.'];
  if(u.bundle_identifier&&(!validReleaseBundle(u.bundle_identifier)||bundleKey(u.bundle_identifier)!==bundle))errors.push('هوية ملف IPA تختلف عن البندل المحدد.');
  if(u.app_name&&!validAppName(u.app_name))errors.push('اسم عرض التحديث غير صالح.');
  if(u.build_request_id!=null&&(typeof u.build_request_id!=='string'||u.build_request_id&&!/^[a-f0-9]{32}$/.test(u.build_request_id)))errors.push('معرّف بناء Studio غير صالح. أعد فحص رابط IPA.');
  if((u.required!=null&&typeof u.required!=='boolean')||(u.required===true&&!u.enabled))errors.push('حالة إلزام الإصدار غير صالحة.');
  if(u.required_policy!=null&&!['approved','approved_origin','minimum'].includes(u.required_policy))errors.push('اختر سياسة السماح بالإصدارات.');
  if(typeof u.html!=='string'||u.html.length>100000)errors.push('حد صفحة HTML هو 100000 حرف.');
  if(u.enabled){
    if(!numericRelease(u.latest_version)||u.build_version&&!numericRelease(u.build_version))errors.push('الإصدار الجديد ورقم البناء يحتاجان أرقاماً مفصولة بنقاط.');
    if(u.required===true&&!numericRelease(u.build_version))errors.push('أدخل رقم البناء للتحديث الإجباري.');
    if(u.manifest_url){if(!nativeHTTPS(u.manifest_url))errors.push('رابط manifest يجب أن يكون HTTPS.');}
    else if(!nativeHTTPS(u.ipa_url)||!/^[a-f0-9]{64}$/i.test(u.sha256||''))errors.push('التحديث الداخلي يحتاج رابط IPA وبصمة SHA-256 من الملف نفسه.');
  }
  if(f?.enabled){
    if(!nativeHTTPS(f.update_url))errors.push('رابط التحديث الإجباري يجب أن يكون HTTPS من دون جزء #.');
    if(!numericRelease(f.min_version)||f.min_build_version&&!numericRelease(f.min_build_version))errors.push('حد الإصدار الإجباري أو البناء غير صالح.');
    else if(u.enabled&&numericRelease(u.latest_version)){
      const order=compareRelease(u.latest_version,f.min_version);
      if(order<0||order===0&&f.min_build_version&&(!numericRelease(u.build_version)||compareRelease(u.build_version,f.min_build_version)<0))errors.push('النسخة المنشورة أقل من الحد الإجباري؛ صحّح الحد قبل النشر.');
    }
  }
  return errors;
}
const integrationValidate=validateState;
validateState=function(data){return [...integrationValidate(data),...dashboardErrors(data)];};
state=normalizeState(createDefaultState());
let usageRequest=0,usageAbort=null,usageTarget='';
const pushLanguages=['ar','en','ckb'];
let pushService='', pushRequest=null, pushDraft=null, pushCampaign=null;
function pushServiceURL(value){
  try{
    const url=new URL(value);
    if(url.protocol!=='https:'||url.username||url.password||url.port||url.search||url.hash||
       !/^\/[a-z0-9_/-]*$/i.test(url.pathname))return null;
    return url.href.replace(/\/+$/,'');
  }catch{return null;}
}
function renderPushTargets(){
  const options=$('studioPushTargets');if(!options)return;
  const kind=$('studioPushKind').value;
  const items=kind==='app'?state.apps:
    kind==='tweak'?(state.xsign_config.dashboard.signing_libraries||[]).filter(item=>item.enabled):[];
  options.replaceChildren(...items.slice(0,1500).map(item=>{
    const id=kind==='app'?(item.catalogID||item.bundleIdentifier):item.id;
    const option=text('option',item.name||id||'');option.value=id||'';return option;
  }));
}
function renderPushService(){
  const endpoint=pushServiceURL(state.xsign_config.push_endpoint||'')||'';
  if(pushService!==endpoint){
    pushService=endpoint;pushRequest?.abort();pushRequest=null;pushDraft=null;pushCampaign=null;
    $('studioPushToken').value='';$('studioPushStatus').textContent='';$('studioPushStatusButton').disabled=true;
    $('studioPushSend').disabled=false;
  }
}
function readPushDraft(){
  const encoder=new TextEncoder(), length=value=>encoder.encode(value).length;
  const kind=$('studioPushKind').value,target=$('studioPushTarget').value.trim();
  if(!['app','tweak','link'].includes(kind)||!target||/[\x00-\x1f\x7f]/.test(target))throw Error('حدد وجهة الإشعار.');
  if(kind==='app'&&length(target)>220)throw Error('معرّف التطبيق طويل جدًا.');
  if(kind==='tweak'&&!/^[a-f0-9]{32}$/.test(target))throw Error('اختر التعديل من القائمة.');
  if(kind==='link'){
    const url=new URL(target);
    if(url.protocol!=='https:'||url.username||url.password||length(target)>1000)throw Error('أدخل رابط HTTPS صالحًا.');
  }
  const messages={};
  for(const language of pushLanguages){
    const title=$('studioPushTitle-'+language).value.trim(),body=$('studioPushBody-'+language).value.trim();
    if(!title||!body||length(title)>240||length(body)>1200)throw Error('اكتب العنوان والنص بكل اللغات ضمن الحد المسموح.');
    messages[language]={title,body};
  }
  return {kind,target,messages};
}
function pushCredentials(){
  const endpoint=pushServiceURL(state.xsign_config.push_endpoint||''),token=$('studioPushToken').value.trim();
  if(!endpoint||token.length<32)throw Error('أدخل عنوان خدمة الإشعارات ورمز الإرسال.');
  return {endpoint,token};
}
async function doPushRequest(credentials,path,body){
  if(pushRequest)return;
  const {endpoint,token}=credentials;
  const controller=new AbortController();pushRequest=controller;
  const timeout=setTimeout(()=>controller.abort(),15000),submit=$('studioPushSend'),status=$('studioPushStatus');
  submit.disabled=true;$('studioPushStatusButton').disabled=true;status.textContent='جارٍ الاتصال بخدمة الإشعارات…';
  try{
    const headers={Authorization:'Bearer '+token};
    if(body)headers['Content-Type']='application/json';
    const response=await fetch(endpoint+path,{method:body?'POST':'GET',headers,
      body:body?JSON.stringify(body):undefined,credentials:'omit',cache:'no-store',redirect:'error',
      referrerPolicy:'no-referrer',signal:controller.signal});
    if(!response.ok)throw Error('تعذّر الاتصال بخدمة الإشعارات (HTTP '+response.status+').');
    const result=await response.json();
    if(pushRequest!==controller||endpoint!==pushService)return;
    if(body){
      if(result.id!==body.id)throw Error('معرّف الإرسال في الاستجابة غير صالح.');
      pushCampaign=result.id;pushDraft=null;
      status.textContent='أُضيف الإشعار إلى طابور الإرسال.';
    }else{
      const labels={queued:'بالطابور',sending:'جارٍ الإرسال',finished:'اكتملت المعالجة',expired:'انتهت المهلة'};
      if(!labels[result.status]||!Number.isSafeInteger(result.accepted)||!Number.isSafeInteger(result.failed))throw Error('استجابة حالة غير صالحة.');
      status.textContent=labels[result.status]+' · قبله APNs: '+result.accepted+' · تعذّر: '+result.failed;
    }
  }catch(error){
    if(pushRequest===controller)status.textContent=controller.signal.aborted?'انتهت مهلة الاتصال. حاول مجدداً.':error.message;
  }finally{
    clearTimeout(timeout);
    if(pushRequest===controller){pushRequest=null;submit.disabled=false;$('studioPushStatusButton').disabled=!pushCampaign;}
  }
}
function reviewPushCampaign(event){
  event.preventDefault();
  try{
    const notice=readPushDraft(),credentials=pushCredentials(),key=JSON.stringify(notice);
    if(pushDraft?.key!==key)pushDraft={key,id:Array.from(crypto.getRandomValues(new Uint8Array(16)),b=>b.toString(16).padStart(2,'0')).join('')};
    const body={id:pushDraft.id,...notice};
    confirmAction('إرسال إشعار إلى مستخدمي XSign',notice.messages.ar.title+' · '+notice.target+' · '+new URL(credentials.endpoint).host,
      ()=>{if(pushService===credentials.endpoint)doPushRequest(credentials,'/send',body);},'إرسال',false);
  }catch(error){$('studioPushStatus').textContent=error.message;}
}
function refreshPushStatus(){
  try{if(pushCampaign)doPushRequest(pushCredentials(),'/status?id='+encodeURIComponent(pushCampaign));}
  catch(error){$('studioPushStatus').textContent=error.message;}
}
async function checkPushHealth(){
  const status=$('studioPushStatus'),btn=$('studioPushHealthButton');
  const endpoint=pushServiceURL(state.xsign_config.push_endpoint||'');
  if(!endpoint){status.textContent='أدخل رابط Cloudflare Worker (HTTPS) أولاً.';return;}
  btn.disabled=true;status.textContent='جارٍ فحص اتصال Cloudflare Worker…';
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
  try{
    const res=await fetch(endpoint+'/health',{method:'GET',credentials:'omit',cache:'no-store',redirect:'error',referrerPolicy:'no-referrer',signal:controller.signal});
    if(!res.ok)throw Error('استجاب الخادم برمز HTTP '+res.status+'.');
    const data=await res.json().catch(()=>null);
    status.textContent=data?.ok?'متصل بنجاح بخدمة إشعارات Cloudflare Workers.':'استجاب الخادم، لكن تأكد من نشر ملف worker.js الصحيح.';
  }catch(error){status.textContent=controller.signal.aborted?'انتهت مهلة الفحص. تحقق من رابط الـ Worker.':error.message;}
  finally{clearTimeout(timer);btn.disabled=false;}
}
function usageServiceURL(value){
  try{
    const raw=value.trim(),url=new URL(raw);
    if(raw.includes('?')||raw.includes('#')||url.protocol!=='https:'||!url.hostname||url.username||url.password||url.search||url.hash||
       !['','/'].includes(url.pathname))return null;
    return url.origin;
  }catch{return null;}
}
function clearUsageStats(message){
  for(const id of ['usageTotal','usageOnline','usageToday','usageMonth','usageCountryCount'])$(id).textContent='—';
  $('usageCountries').replaceChildren();$('usageStatus').textContent=message;
}
function renderUsageStats(){
  const target=usageServiceURL(state.xsign_config.usage_stats?.endpoint||'')||'';
  if(target!==usageTarget){
    usageTarget=target;usageRequest++;usageAbort?.abort();$('usageAdminToken').value='';
    clearUsageStats(target?'أدخل رمز المالك لعرض الأعداد.':'اربط خدمة الإحصاءات لعرض الاستخدام الفعلي.');
  }
}
function checkedUsageSummary(value){
  const keys=['total_installations','online','active_today','active_30d'];
  if(!isObject(value)||value.schema_version!==1||value.timezone!=='UTC'||value.online_window_seconds!==300||
     !Number.isSafeInteger(value.generated_at)||value.generated_at<=0||value.generated_at>8640000000000||
     keys.some(key=>!Number.isSafeInteger(value[key])||value[key]<0)||
     value.online>value.active_30d||value.active_today>value.active_30d||value.active_30d>value.total_installations||
     !Array.isArray(value.countries)||value.countries.length>300)throw Error('استجابة إحصاءات غير صالحة.');
  const codes=new Set();let total=0;
  for(const item of value.countries){
    if(!isObject(item)||typeof item.country!=='string'||!/^[A-Z]{2}$/.test(item.country)||
       codes.has(item.country)||!Number.isSafeInteger(item.users)||item.users<=0)throw Error('بيانات البلدان غير صالحة.');
    codes.add(item.country);total+=item.users;
  }
  if(total!==value.active_30d)throw Error('توزيع البلدان لا يطابق عدد النشطين.');
  return value;
}
function showUsageSummary(value){
  const number=new Intl.NumberFormat('ar');
  for(const [id,key] of [['usageTotal','total_installations'],['usageOnline','online'],['usageToday','active_today'],['usageMonth','active_30d']]){
    $(id).textContent=number.format(value[key]);
  }
  $('usageCountryCount').textContent=number.format(value.countries.filter(item=>item.country!=='XX').length);
  const container=$('usageCountries');container.replaceChildren();
  if(!value.countries.length){container.append(text('p','لم يصل استخدام خلال آخر 30 يومًا.','muted'));}
  else{
    const table=document.createElement('table'),head=document.createElement('thead'),body=document.createElement('tbody'),row=document.createElement('tr');
    row.append(text('th','البلد'),text('th','التثبيتات النشطة'),text('th','النسبة'));head.append(row);
    const percent=new Intl.NumberFormat('ar',{style:'percent',maximumFractionDigits:1});
    let names;try{names=new Intl.DisplayNames(['ar'],{type:'region'});}catch{}
    for(const item of value.countries){
      const row=document.createElement('tr');let name=item.country;
      if(item.country==='XX')name='غير معروف';else if(names)name=names.of(item.country)||item.country;
      row.append(text('td',name),text('td',number.format(item.users)),
        text('td',percent.format(item.users/value.active_30d)));body.append(row);
    }
    table.append(head,body);container.append(table);
  }
  $('usageStatus').textContent='آخر تحديث: '+new Date(value.generated_at*1000).toLocaleString('ar-IQ');
}
async function refreshUsageStats(){
  renderUsageStats();
  const endpoint=usageTarget,token=$('usageAdminToken').value.trim();
  if(!endpoint||token.length<32){$('usageStatus').textContent='أدخل عنوان الخدمة ورمز المالك الصحيح ثم حدّث الأعداد.';return;}
  usageAbort?.abort();const controller=new AbortController();usageAbort=controller;const serial=++usageRequest;
  $('usageStatus').textContent='جارٍ جلب الأعداد…';
  const timer=setTimeout(()=>controller.abort(),20000);
  try{
    const response=await fetch(endpoint+'/v1/summary',{headers:{Authorization:'Bearer '+token},
      credentials:'omit',cache:'no-store',redirect:'error',referrerPolicy:'no-referrer',signal:controller.signal});
    if(!response.ok)throw Error(response.status===404?'تحقق من عنوان الخدمة ورمز المالك.':'تعذر جلب الإحصاءات. حاول مجددًا.');
    if(Number(response.headers.get('Content-Length')||0)>65536)throw Error('استجابة الإحصاءات كبيرة جدًا.');
    const raw=await response.text();if(new TextEncoder().encode(raw).length>65536)throw Error('استجابة الإحصاءات كبيرة جدًا.');
    const summary=checkedUsageSummary(JSON.parse(raw));
    if(serial===usageRequest)showUsageSummary(summary);
  }catch(error){
    if(serial===usageRequest)$('usageStatus').textContent=controller.signal.aborted?'انتهت مهلة جلب الإحصاءات. أعد المحاولة.':error.message;
  }finally{clearTimeout(timer);if(serial===usageRequest)usageAbort=null;}
}
connection.appBundle=XSIGN_INTEGRATION.bundle;
const integrationLoadLocal=loadLocal;
loadLocal=function(){integrationLoadLocal();
  if(!connection.appBundle||['thewonderofyou.Feather',XSIGN_LEGACY_BUNDLE].includes(connection.appBundle))connection.appBundle=XSIGN_INTEGRATION.bundle;
};
Object.assign(PAGE_META,{
  layout:['ترتيب المتجر والمصادر','XSIGN / STORE LAYOUT','أقسام المتجر، المصادر المدارة والتبويبات كما يقرأها التطبيق.'],
  sources:['مصادر المتجر والاتصال','XSIGN / SOURCES','أضف واحذف المصادر وانشر التغييرات. يبقى IPA BLACK ثابتاً.'],
  updates:['بناء ونشر Xsign','XSIGN / RELEASE','احفظ الهوية والأيقونة، ثم انشر الإصدار برابط IPA.'],
  integration:['ربط التطبيق','XSIGN / INTEGRATION','عقد الربط الفعلي وما يلزم لتطبيق الإعدادات على الأجهزة.']
});
let editingManagedSource=null,editingStoreSection=null;
function integrationChange(action,label){mutate(action,label);syncInputs();renderIntegration();}
function integrationMove(list,index,offset){const other=index+offset;if(other<0||other>=list.length)return;
  if(list===state.xsign_config.dashboard.sources&&(pinnedSource(list[index])||pinnedSource(list[other]))){
    toast('يبقى IPA BLACK أولاً. رتّب المصادر الأخرى كما تريد.');return;}
  integrationChange(()=>{[list[index],list[other]]=[list[other],list[index]];},'تغيير ترتيب المتجر');}
function deleteManagedSource(item,list){
  const sections=state.xsign_config.dashboard.sections;
  for(const section of sections){
    if(managedSourceKey(section.source_url)===managedSourceKey(item.url))section.enabled=false;
  }
  list.splice(list.indexOf(item),1);
  const dashboard=state.xsign_config.dashboard;
  if(Array.isArray(dashboard.today_source_ids))dashboard.today_source_ids=todaySelection(dashboard);
}
function toggleSection(item){
  if(!item.enabled&&item.kind==='categories'){
    for(const section of state.xsign_config.dashboard.sections){
      if(section!==item&&section.page===item.page&&section.kind==='categories')section.enabled=false;
    }
  }
  item.enabled=!item.enabled;
}
function sourceOrSectionRow(item,index,list,isSource){
  const row=text('div','','entry row'),details=text('div','','grow');
  details.append(text('strong',isSource?item.name:item.title),text('small',isSource?item.url:(TAB_TITLES[item.page]||item.page)+' · '+KIND_TITLES[item.kind]+' · '+item.limit,'muted'));
  row.append(details);
  if(isSource){
    row.classList.add('studio-source-row');
    if(!pinnedSource(item))row.append(text('span',item.enabled!==false?'مفعّل':'متوقف','studio-source-state '+(item.enabled!==false?'is-on':'')));
    const dashboard=state.xsign_config.dashboard;
    const label=text('label','','check-field'),input=document.createElement('input');
    input.type='checkbox';input.checked=todaySelection(dashboard).includes(item.id);input.disabled=item.enabled===false;
    input.setAttribute('aria-label','عرض '+item.name+' في اليوم');
    input.addEventListener('change',()=>integrationChange(()=>{
      const selected=new Set(todaySelection(dashboard));
      if(input.checked)selected.add(item.id);else selected.delete(item.id);
      dashboard.today_source_ids=dashboard.sources.filter(source=>selected.has(source.id)).map(source=>source.id);
    },'اختيار مصادر اليوم'));
    label.append(input,document.createTextNode('في اليوم'));row.append(label);
  }
  if(isSource&&pinnedSource(item)){
    row.append(text('small','المصدر الثابت','muted'));
    return row;
  }
  const enabled=item.enabled!==false;
  const toggleLabel=isSource?(enabled?'إيقاف':'تشغيل'):(enabled?'إخفاء':'إظهار');
  const toggle=button(toggleLabel,()=>integrationChange(()=>toggleSection(item),'تغيير ظهور عنصر المتجر'));
  if(isSource)toggle.setAttribute('aria-label',toggleLabel+' '+item.name);
  row.append(button('تعديل',()=>isSource?editManagedSource(item):editStoreSection(item),'edit'),toggle);
  row.append(button('↑',()=>integrationMove(list,index,-1)),button('↓',()=>integrationMove(list,index,1)));
  row.append(button('حذف',()=>confirmAction('حذف من المتجر','يُحذف هذا العنصر من المسودة. يصل التغيير إلى التطبيق بعد النشر.',()=>integrationChange(()=>{if(isSource)deleteManagedSource(item,list);else list.splice(list.indexOf(item),1);},'حذف عنصر متجر')),'trash'));
  return row;
}
function editManagedSource(item=null){editingManagedSource=item?.id||null;
  for(const [id,key]of [['managedName','name'],['managedURL','url'],['managedIcon','icon_url'],['managedFormat','format'],['managedRoot','root_path']])$(id).value=item?.[key]||(key==='format'?'auto':'');
  $('managedNumericTypes').checked=item?.numeric_types??(item?.id?.startsWith('xsign.iosboom.')===true);
  const advanced=$('studioSourceOptions');
  if(advanced)advanced.open=Boolean(item?.fields||item?.root_path||item?.icon_url||(item?.format&&item.format!=='auto'));
  $('managedFields').value=item?.fields?JSON.stringify(item.fields,null,2):'';$('saveManagedSource').textContent=item?'حفظ تعديل المصدر':'إضافة المصدر';$('managedName').focus();}
function saveManagedSource(event){event.preventDefault();try{
  const d=state.xsign_config.dashboard,existing=d.sources.find(s=>s.id===editingManagedSource);
  const fields=$('managedFields').value.trim();let mapping=fields?JSON.parse(fields):undefined;if(mapping)assertSafeTree(mapping);
  const url=canonicalManagedSourceURL($('managedURL').value.trim());
  const defaultsToSoon=!d.sources.some(source=>source.id==='xsign.core.primary')&&
    [PRIMARY_SOURCE_URL,IPA_SOON_SNAPSHOT].some(source=>managedSourceKey(source)===managedSourceKey(url));
  const id=existing?.id||(defaultsToSoon?'xsign.core.primary':'source-'+uid());
  const item={...existing,id,name:$('managedName').value.trim(),url,
    enabled:existing?.enabled??true,format:$('managedFormat').value,icon_url:$('managedIcon').value.trim()||undefined,
    root_path:$('managedRoot').value.trim()||undefined,fields:mapping,numeric_types:$('managedNumericTypes').checked};
  if(pinnedSource(item))throw Error('IPA BLACK مضاف بالفعل بصفته المصدر الثابت.');
  const next=clone(state),list=next.xsign_config.dashboard.sources,index=list.findIndex(s=>s.id===item.id);if(index>=0)list[index]=item;else list.push(item);
  if(existing&&managedSourceKey(existing.url)!==managedSourceKey(item.url)){
    for(const section of next.xsign_config.dashboard.sections){
      if(managedSourceKey(section.source_url)===managedSourceKey(existing.url))section.source_url=item.url;
    }
  }
  const errors=dashboardErrors(storeSettingsDraft(next));if(errors.length)throw Error(errors[0]);
  integrationChange(()=>state=next,'حفظ مصدر متجر');editManagedSource();
}catch(error){toast(error.message,'error');}}
const IOSBOOM_PUBLIC_SOURCE={
  id:'xsign.iosboom.public',name:'iOSBoom Public',format:'auto',enabled:true,
  url:'https://raw.githubusercontent.com/ipablack/repo/main/sources/iosboom-public.json'
};
const SOURCE_PRESETS = [
  ['xsign.zsign.it','iTorrent','https://xitrix.github.io/iTorrent/AltStore.json'],
  ['xsign.zsign.ksign','Ksign','https://raw.githubusercontent.com/Nyasami/Ksign/main/repo.json'],
  ['xsign.zsign.lc','LiveContainer','https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps.json'],
  ['xsign.zsign.apptesters','AppTesters','https://repository.apptesters.org/'],
  ['xsign.plus','متجر بلس','https://supapi.trystore.net/rest/v1/plus_library_apps','rest'],
  ['xsign.sidelix','Sidelix','https://appstore.sidelix.vip/repos/altstore.json'],
  ['xsign.provenance','Provenance','https://provenance-emu.com/apps.json']
];

function sameManagedSource(existing, candidate) {
  return existing.id===candidate.id||managedSourceKey(existing.url)===managedSourceKey(candidate.url);
}

function addSourcePreset(candidate) {
  const sources=state.xsign_config.dashboard.sources;
  if(sources.some(source=>sameManagedSource(source,candidate)))return;
  if(sources.length>=50)return toast('قائمة المصادر تتجاوز الحد المسموح (50 مصدراً).','error');
  integrationChange(()=>sources.push(candidate),'إضافة '+candidate.name);
  toast('أضيف '+candidate.name+' إلى المسودة.');
}

function renderSourcePresets(sources) {
  const quick=$('studioIOSBoom');
  if(quick){
    const existing=sources.find(source=>sameManagedSource(source,IOSBOOM_PUBLIC_SOURCE));
    quick.textContent=existing?(existing.enabled===false?'تشغيل iOSBoom':'مضاف'):'إضافة iOSBoom';
    quick.disabled=Boolean(existing&&existing.enabled!==false);
    quick.onclick=()=>existing
      ? integrationChange(()=>{existing.enabled=true;},'تشغيل iOSBoom Public')
      : addSourcePreset({...IOSBOOM_PUBLIC_SOURCE});
  }
  $('sourcePresets').replaceChildren(...SOURCE_PRESETS.map(([id,name,url,format='auto'])=>{
    const candidate={id,name,url,format,enabled:true};
    const existing=sources.find(source=>sameManagedSource(source,candidate));
    const row=text('div','','entry row wrap'), details=text('div','','grow');
    details.append(text('strong',name),text('small',url,'muted'));
    const add=button(existing ? (existing.enabled===false?'مضاف · مخفي':'مضاف') : 'إضافة '+name,
      ()=>addSourcePreset(candidate));
    add.disabled=Boolean(existing);
    row.append(details,add);
    return row;
  }));
}

function sectionAppIDs() {
  return $('sectionAppsV2').value.split(',').map(id=>id.trim()).filter(Boolean);
}
function featuredAppID(app) {
  return app.catalogID || app.bundleIdentifier;
}
function featuredAppMatchesPage(app, page, categories) {
  const primary=categories.get(categoryKey(appCategoryReferences(app)[0]));
  const kind=primary?.isGame ?? app.isGame;
  return typeof kind!=='boolean' || kind===(page==='games');
}
function updateFeaturedSelection(ids) {
  $('sectionAppsV2').value=ids.join(', ');
  renderFeaturedPicker();
}
function renderFeaturedPicker() {
  const picker=$('sectionFeaturedPicker');
  const page=$('sectionPageV2').value;
  $('todayContinuousControl').hidden=!(page==='today' && $('sectionKindV2').value==='apps' && !$('sectionSourceV2').value.trim() && !$('sectionCategoryV2').value.trim() && !sectionAppIDs().length);
  picker.hidden=$('sectionKindV2').value!=='featured' || !['apps','games'].includes(page);
  if(picker.hidden)return;

  const ids=sectionAppIDs(), selected=new Set(ids.map(id=>id.toLowerCase()));
  const select=$('sectionFeaturedApp'), previous=select.value;
  const query=$('sectionFeaturedQuery').value.trim().toLocaleLowerCase();
  const source=managedSourceKey($('sectionSourceV2').value.trim());
  const categories=categoryIndex();
  const apps=state.apps.filter(app=>typeof featuredAppID(app)==='string' && featuredAppID(app));
  const byID=new Map();
  for(const app of apps) {
    byID.set(featuredAppID(app).toLowerCase(),app);
    if(app.bundleIdentifier && !byID.has(app.bundleIdentifier.toLowerCase()))byID.set(app.bundleIdentifier.toLowerCase(),app);
  }

  const options=[text('option','اختر بطاقة')];
  options[0].value='';
  if(!source || source===managedSourceKey(OWNED_CANONICAL_URL)) {
    const available=apps.filter(app=>!selected.has(featuredAppID(app).toLowerCase()) &&
      !selected.has(app.bundleIdentifier?.toLowerCase()) && featuredAppMatchesPage(app,page,categories) &&
      (!query || [app.name,app.bundleIdentifier].some(value=>value?.toLocaleLowerCase().includes(query))));
    available.sort((a,b)=>(a.name || featuredAppID(a)).localeCompare(b.name || featuredAppID(b)));
    for(const app of available) {
      const option=text('option',(app.name || featuredAppID(app))+' · '+(app.bundleIdentifier || featuredAppID(app)));
      option.value=featuredAppID(app);
      options.push(option);
    }
  }
  select.replaceChildren(...options);
  select.disabled=options.length===1;
  select.value=options.some(option=>option.value===previous)?previous:'';
  $('addSectionFeaturedApp').disabled=!select.value;
  const limit=Math.min(18, Number($('sectionLimitV2').value)||12);
  $('sectionFeaturedCount').textContent=ids.length
    ? ids.length+' مختارة · يظهر حتى '+limit
    : (select.disabled?'لا توجد بطاقات مطابقة في الكتالوج الحالي.':'لم تختر بطاقات بعد.');

  $('sectionFeaturedOrder').replaceChildren(...ids.map((id,index)=>{
    const app=byID.get(id.toLowerCase());
    const label=app?.name || id, row=text('li','','entry row');
    const name=text('div','','grow');
    name.append(text('strong',label));
    if(app && app.bundleIdentifier)name.append(text('small',app.bundleIdentifier,'mono muted'));
    const move=(offset)=>{
      const destination=index+offset;
      [ids[index],ids[destination]]=[ids[destination],ids[index]];
      $('sectionSortV2').value='';
      updateFeaturedSelection(ids);
    };
    const earlier=button('↑',()=>move(-1)), later=button('↓',()=>move(1));
    earlier.disabled=index===0;later.disabled=index===ids.length-1;
    earlier.setAttribute('aria-label','تقديم '+label);
    later.setAttribute('aria-label','تأخير '+label);
    const remove=button('إزالة',()=>updateFeaturedSelection(ids.filter((id,i)=>i!==index)));
    remove.setAttribute('aria-label','إزالة '+label);
    row.append(name,earlier,later,remove);
    return row;
  }));
}
function addSectionFeaturedApp() {
  const id=$('sectionFeaturedApp').value;
  if(!id)return;
  const ids=sectionAppIDs();
  if(ids.length>=300){toast('حد البطاقات المحددة لهذا القسم 300 معرّف.','error');return;}
  if(ids.some(value=>value.toLowerCase()===id.toLowerCase()))return;
  updateFeaturedSelection([...ids,id]);
}
function editStoreSection(item=null){editingStoreSection=item?.id||null;
  for(const [id,key,fallback]of [['sectionTitleV2','title',''],['sectionPageV2','page','today'],['sectionKindV2','kind','apps'],
    ['sectionLimitV2','limit',12],['sectionSourceV2','source_url',''],['sectionCategoryV2','category_id',''],['sectionSortV2','sort','']])$(id).value=item?.[key]??fallback;
  $('todayContinuous').checked=item?.continuous??(item?.id==='today-apps');
  $('sectionAppsV2').value=(item?.app_ids||[]).join(', ');
  $('sectionFeaturedQuery').value='';
  $('sectionFeaturedApp').value='';
  renderFeaturedPicker();
  $('saveStoreSection').textContent=item?'حفظ تعديل القسم':'إضافة القسم';$('sectionTitleV2').focus();}
function saveStoreSection(event){event.preventDefault();try{
  const d=state.xsign_config.dashboard,existing=d.sections.find(s=>s.id===editingStoreSection);
  const item={...existing,id:existing?.id||'section-'+uid(),title:$('sectionTitleV2').value.trim(),page:$('sectionPageV2').value,
    kind:$('sectionKindV2').value,limit:Number($('sectionLimitV2').value),enabled:existing?.enabled??true,
    source_url:$('sectionSourceV2').value.trim()||undefined,category_id:$('sectionCategoryV2').value.trim()||undefined,
    sort:$('sectionSortV2').value||undefined,app_ids:sectionAppIDs()};
  if(!item.app_ids.length)delete item.app_ids;
  if(item.page==='today' && item.kind==='apps' && !item.source_url && !item.category_id && !item.app_ids){
    item.continuous=$('todayContinuous').checked;
  }else delete item.continuous;
  if(item.kind==='categories'&&item.enabled&&d.sections.some(section=>
     section.id!==item.id&&section.page===item.page&&section.kind==='categories'&&section.enabled)){
    throw Error('عدّل قسم التصنيفات الموجود في هذه الصفحة.');
  }
  const next=clone(state),list=next.xsign_config.dashboard.sections,index=list.findIndex(s=>s.id===item.id);if(index>=0)list[index]=item;else list.push(item);
  const errors=dashboardErrors(storeSettingsDraft(next));if(errors.length)throw Error(errors[0]);
  integrationChange(()=>state=next,'حفظ قسم متجر');editStoreSection();
}catch(error){toast(error.message,'error');}}
const XSIGN_BUILD_REPO={owner:'ipablack',repo:'X-SIGN',branch:'main',workflow:'XSign_Full_Link.yml'};
const XSIGN_BUILD_FILE='xsign-build.json';
const XSIGN_BUILD_SCHEMA=1;
const XSIGN_WORKFLOW_NAME='Xsign — Studio Release';
const XSIGN_SETTINGS_KEY='xsign-studio-build-settings-v2';
const XSIGN_REQUEST_KEY='xsign-studio-last-build';
const XSIGN_INSPECTION_KEY='xsign-studio-ipa-inspection-v2';
const XSIGN_VERIFICATION_KEY='xsign-studio-verified-ipa-links-v1';
const validReleaseBundle=value=>typeof value==='string'&&value.length<=155&&/^[a-z0-9-]+(?:\.[a-z0-9-]+)*$/i.test(value);
const validBuildValue=value=>typeof value==='string'&&/^\d{1,9}(?:\.\d{1,9}){0,2}$/.test(value);
const validAppName=value=>typeof value==='string'&&value.trim()===value&&Array.from(value).length>=1&&Array.from(value).length<=64&&!/[\x00-\x1f\x7f$]/.test(value);
const validReleaseURL=value=>nativeHTTPS(value)&&value.length<=2048&&!/[\s\\#]/.test(value)&&!new URL(value).port;
const bundleKey=value=>value.toLowerCase();
const gitSHA=value=>typeof value==='string'&&/^[0-9a-f]{40,64}$/.test(value);
const newReleaseRequest=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),value=>value.toString(16).padStart(2,'0')).join('');
let managedUpdateBundle=bundleKey(XSIGN_INTEGRATION.bundle),releaseRequestBusy=false;
const verifiedReleaseDrafts=new Map();
const RELEASE_WORKFLOW_URL='https://github.com/ipablack/X-SIGN/actions/workflows/XSign_Full_Link.yml';
const BUILD_FIELDS=[['buildAppName','appName',XSIGN_INTEGRATION.name],['buildBundleID','bundleIdentifier',XSIGN_INTEGRATION.bundle],
  ['buildVersion','version',XSIGN_INTEGRATION.version],['buildNumber','buildVersion',''],['buildIconURL','iconURL',''],
  ['buildManifestURL','manifestURL',''],['buildDelivery','delivery','']];
let studioBuildRequest=null;
let buildRunLookup=0;

function buildSettingsFromForm(){
  return Object.fromEntries(BUILD_FIELDS.map(([id,key])=>[key,$(id).value.trim()]));
}
function setBuildForm(settings){
  for(const [id,key,fallback] of BUILD_FIELDS)$(id).value=typeof settings[key]==='string'?settings[key]:fallback;
  renderBuildSummary();
}
function renderBuildSummary(){
  const current=buildSettingsFromForm();
  $('overviewBuildName').textContent=current.appName||'—';
  $('overviewBuildBundle').textContent=current.bundleIdentifier||'—';
  $('overviewBuildVersion').textContent=current.version||'—';
}
function restoreRequestedIdentity(){
  const settings={...buildSettingsFromForm(),appName:XSIGN_INTEGRATION.name,
    bundleIdentifier:XSIGN_INTEGRATION.bundle,version:XSIGN_INTEGRATION.version,buildVersion:''};
  useSavedBuild(settings);
  $('buildRequestStatus').textContent='تم اختيار Xsign للبندل والاسم والإصدار 1.0. احفظ الإعدادات أو ابدأ البناء.';
}
function validateBuildSettings(settings){
  if(settings.delivery&&!['private','release','everyone'].includes(settings.delivery))throw Error('اختر طريقة تسليم البناء.');
  if(!validAppName(settings.appName))throw Error('أدخل اسم التطبيق، بحد أقصى 64 حرفاً ومن دون الرمز $.');
  if(!validReleaseBundle(settings.bundleIdentifier))throw Error('أدخل Bundle ID صحيحاً، مثل Xsign.');
  if(!validBuildValue(settings.version))throw Error('أدخل إصداراً رقمياً مثل 1.0 أو 1.2.1.');
  if(settings.buildVersion!==undefined&&settings.buildVersion!==''&&(!validBuildValue(settings.buildVersion)||!settings.buildVersion.split('.').some(Number)))throw Error('أدخل رقم بناء موجباً مثل 14.');
  if(settings.iconURL!==undefined&&settings.iconURL!==''&&!validReleaseURL(settings.iconURL))throw Error('أدخل رابط HTTPS مباشراً لأيقونة PNG.');
  if(settings.manifestURL!==undefined&&settings.manifestURL!==''&&!validReleaseURL(settings.manifestURL))throw Error('أدخل رابط HTTPS صحيحاً لملف manifest.');
  return Object.fromEntries(Object.entries(settings).filter(([key,value])=>key!=='catalogOrigin'&&value!==''));
}
function readBuildDocument(file){
  const data=JSON.parse(file.source.replace(/^\uFEFF/,''));
  if(!isObject(data)||Object.keys(data).length!==3||data.schema_version!==XSIGN_BUILD_SCHEMA||
      !/^[a-f0-9]{32}$/.test(data.request_id||'')||!isObject(data.settings)||
      Object.entries(data.settings).some(([key,value])=>(key!=='catalogOrigin'&&!BUILD_FIELDS.some(([,field])=>field===key))||typeof value!=='string')){
    throw Error('ملف إعدادات البناء على GitHub يحتاج مراجعة.');
  }
  return {...data,settings:validateBuildSettings(data.settings)};
}
function rememberStudioBuild(request){
  const bundle=bundleKey(request.record.settings.bundleIdentifier);
  studioBuildRequest=request;
  try{localStorage.setItem(XSIGN_REQUEST_KEY+':'+bundle,JSON.stringify(request));}catch{}
}
function pendingBuildFor(bundle){
  try{
    const value=JSON.parse(localStorage.getItem(XSIGN_REQUEST_KEY+':'+bundle)||'null');
    if(value?.record?.schema_version===XSIGN_BUILD_SCHEMA&&/^[a-f0-9]{32}$/.test(value.record.request_id||'')&&
        validReleaseBundle(value.record.settings?.bundleIdentifier)&&bundleKey(value.record.settings.bundleIdentifier)===bundle&&gitSHA(value.commit))return value;
  }catch{}
  if(studioBuildRequest&&bundleKey(studioBuildRequest.record.settings.bundleIdentifier)===bundle)return studioBuildRequest;
  return null;
}
function saveVerifiedRelease(bundle,patch,buildRequestID,fromPublicRelease=false){
  verifiedReleaseDrafts.set(bundle,{patch,buildRequestID,fromPublicRelease});
  try{sessionStorage.setItem(XSIGN_VERIFICATION_KEY,JSON.stringify([...verifiedReleaseDrafts]));}catch{}
}
function loadVerifiedReleases(){
  try{
    const saved=JSON.parse(sessionStorage.getItem(XSIGN_VERIFICATION_KEY)||'[]');
    for(const [bundle,evidence] of saved){
      if(validReleaseBundle(bundle)&&isObject(evidence?.patch)&&evidence.patch.bundle_identifier===bundle){
        verifiedReleaseDrafts.set(bundle,evidence);
      }
    }
  }catch{}
}
function matchesVerifiedRelease(release,bundle){
  const evidence=verifiedReleaseDrafts.get(bundle);
  if(!evidence||!Store.same(releaseIdentity(release,bundle),releaseIdentity(evidence.patch,bundle)))return false;
  const pending=pendingBuildFor(bundle);
  return evidence.fromPublicRelease===true||!pending||evidence.buildRequestID===pending.record.request_id;
}
function useSavedBuild(settings){
  setBuildForm(settings);
  try{localStorage.setItem(XSIGN_SETTINGS_KEY,JSON.stringify(buildSettingsFromForm()));}catch{}
  selectUpdateBundle(settings.bundleIdentifier);
}
function buildRunLink(id){return `https://github.com/${XSIGN_BUILD_REPO.owner}/${XSIGN_BUILD_REPO.repo}/actions/runs/${id}`;}
function showBuildRun(message,id){
  $('buildRequestStatus').textContent=message;
  const link=$('buildRunLink');link.href=id?buildRunLink(id):RELEASE_WORKFLOW_URL;
  link.hidden=false;
  $('refreshStudioBuild').hidden=false;
}
function releaseToken(){
  try{return requireToken();}catch(error){openPage('sources');$('ghToken').focus();throw error;}
}
async function verifyStudioWorkflow(token){
  try{
    const workflow=await github(XSIGN_BUILD_REPO,'actions/workflows/'+XSIGN_BUILD_REPO.workflow,'GET',undefined,token);
    if(workflow?.name===XSIGN_WORKFLOW_NAME&&workflow.state==='active')return;
  }catch(error){if(error.status!==404)throw error;}
  throw Error('استبدل ملف XSign_Full_Link.yml على main بالنسخة الجديدة وفعّل الـWorkflow.');
}
async function writeStudioBuild(settings,token,saveOnly){
  const file=await repositoryFile(XSIGN_BUILD_REPO,XSIGN_BUILD_FILE,XSIGN_BUILD_REPO.branch,token,true);
  const record={schema_version:XSIGN_BUILD_SCHEMA,request_id:newReleaseRequest(),settings};
  const message=saveOnly?'Save XSign build settings from Studio [skip ci]':'Build XSign from Studio settings';
  const data={branch:XSIGN_BUILD_REPO.branch,message,
    content:encodeBase64(JSON.stringify(record,null,2)+'\n'),...(file?{sha:file.sha}:{})};
  let written;
  try{written=await github(XSIGN_BUILD_REPO,'contents/'+XSIGN_BUILD_FILE,'PUT',data,token);}
  catch(error){
    if([409,422].includes(error.status))throw Error('تغيّر ملف إعدادات البناء أو رفض الفرع التعديل. اجلب الإعدادات المحفوظة ثم أعد الطلب.');
    throw error;
  }
  if(!gitSHA(written?.commit?.sha))throw Error('لم يؤكد GitHub التزام إعدادات البناء. اجلب الإعدادات ثم راجع التشغيل.');
  return {record,commit:written.commit.sha,queued:!saveOnly};
}
async function findStudioBuild(request){
  const lookup=++buildRunLookup;
  const endpoint='actions/workflows/'+XSIGN_BUILD_REPO.workflow+'/runs?branch='+encodeURIComponent(XSIGN_BUILD_REPO.branch)+
    '&per_page=20&head_sha='+encodeURIComponent(request.commit);
  for(let attempt=0;attempt<12;attempt++){
    if(lookup!==buildRunLookup)return;
    if(attempt)await new Promise(resolve=>setTimeout(resolve,3000));
    try{
      let runs;
      try{runs=await github(XSIGN_BUILD_REPO,endpoint,'GET',undefined,'');}
      catch(error){
        const token=$('ghToken').value.trim();
        if(!token||![403,404].includes(error.status))throw error;
        runs=await github(XSIGN_BUILD_REPO,endpoint,'GET',undefined,requireToken());
      }
      if(lookup!==buildRunLookup||pendingBuildFor(bundleKey(request.record.settings.bundleIdentifier))?.record.request_id!==request.record.request_id)return;
      const run=runs?.workflow_runs?.find(row=>row.head_sha===request.commit&&Number.isSafeInteger(row.id)&&row.id>0&&row.conclusion!=='skipped');
      if(run){
        rememberStudioBuild({...request,id:run.id});
        await displayBuildResult(run,lookup);
        return;
      }
    }catch{return;}
  }
}
async function displayBuildResult(run,lookup){
  const artifactLink=$('buildIPAArtifactLink');
  artifactLink.hidden=true;
  if(run.conclusion==='success'){
    showBuildRun('اكتمل التشغيل. نتيجة التسليم موجودة في ملخص GitHub.',run.id);
    try{
      const token=requireToken();
      const data=await github(XSIGN_BUILD_REPO,'actions/runs/'+run.id+'/artifacts?per_page=100','GET',undefined,token);
      if(lookup!==buildRunLookup)return;
      if(data?.artifacts?.some(row=>row.name==='XSign-release-'+run.run_number+'-'+run.run_attempt)){
        artifactLink.href='https://github.com/'+XSIGN_BUILD_REPO.owner+'/'+XSIGN_BUILD_REPO.repo+'/releases/download/xsign-build-'+run.id+'-'+run.run_attempt+'/X-SIGN.ipa';
        artifactLink.textContent='تنزيل X-SIGN.ipa من Releases';
        artifactLink.hidden=false;
        return;
      }
      const artifact=data?.artifacts?.find(row=>row.name==='XSign-IPA-'+run.run_number+'-'+run.run_attempt&&
        row.expired===false&&Number.isSafeInteger(row.id)&&row.id>0);
      if(lookup!==buildRunLookup)return;
      if(artifact){
        artifactLink.href=buildRunLink(run.id)+'/artifacts/'+artifact.id;
        artifactLink.textContent='تنزيل مرفق IPA';
        artifactLink.hidden=false;
        return;
      }
      const prefix='XSign-draft-'+run.run_number+'-'+run.run_attempt+'-';
      const row=data?.artifacts?.find(item=>item.name?.startsWith(prefix));
      const id=row?.name.slice(prefix.length);
      if(!id||!/^\d+$/.test(id))return;
      const release=await github(XSIGN_BUILD_REPO,'releases/'+id,'GET',undefined,token);
      if(lookup!==buildRunLookup||release?.draft!==true||release.tag_name!=='xsign-personal-'+run.id+'-'+run.run_attempt)return;
      const asset=release.assets?.find(item=>item.name==='X-SIGN.ipa'&&item.state==='uploaded');
      if(!asset)return;
      const url=new URL(asset.browser_download_url);
      const base='/'+XSIGN_BUILD_REPO.owner+'/'+XSIGN_BUILD_REPO.repo+'/releases/download/';
      if(url.origin!=='https://github.com'||!url.pathname.toLowerCase().startsWith(base.toLowerCase()))return;
      artifactLink.href=url.href;
      artifactLink.textContent='تنزيل IPA من المسودة';
      artifactLink.hidden=false;
    }catch{/* The workflow link is still available. */}
    return;
  }
  if(run.status!=='completed')return showBuildRun('البناء قيد التنفيذ. حدّث النتيجة لمتابعة الحالة.',run.id);
  const message=run.conclusion==='failure'?'توقف البناء. افتح تشغيل GitHub لقراءة السجل.':'انتهى التشغيل '+(run.conclusion==='cancelled'?'بالإلغاء.':'دون إصدار.');
  showBuildRun(message,run.id);
  if(run.conclusion!=='failure')return;
  try{
    const token=$('ghToken').value.trim();
    const jobs=await github(XSIGN_BUILD_REPO,'actions/runs/'+run.id+'/jobs?per_page=20','GET',undefined,token);
    const job=jobs?.jobs?.find(row=>row.conclusion==='failure');
    if(!job||lookup!==buildRunLookup)return;
    const step=job.steps?.find(row=>row.conclusion==='failure');
    const checkID=/^https:\/\/api\.github\.com\/repos\/ipablack\/x-sign\/check-runs\/([0-9]+)$/i.exec(job.check_run_url||'')?.[1];
    if(step?.name)showBuildRun('توقف البناء في '+step.name+'.',run.id);
    if(!checkID)return;
    const entries=await github(XSIGN_BUILD_REPO,'check-runs/'+checkID+'/annotations','GET',undefined,token);
    const details=Array.isArray(entries)?entries.filter(row=>typeof row?.message==='string'):[];
    const detail=details.find(row=>row.title==='XSign build cause')??details.find(row=>row.title==='XSign build'&&
      !/\*\* BUILD FAILED \*\*|Command '\['make'\]'/.test(row.message))??details.find(row=>row.title==='XSign build');
    if(detail&&lookup===buildRunLookup)showBuildRun(detail.message.slice(0,400),run.id);
  }catch{/* The run link and last confirmed status remain available. */}
}
async function refreshBuildResult(){
  const bundle=bundleKey(buildSettingsFromForm().bundleIdentifier),request=pendingBuildFor(bundle);
  if(!request)return loadSavedStudioBuild();
  if(!request.id)return findStudioBuild(request);
  const lookup=++buildRunLookup,control=$('refreshStudioBuild');
  control.disabled=true;
  try{
    const run=await github(XSIGN_BUILD_REPO,'actions/runs/'+request.id,'GET',undefined,$('ghToken').value.trim());
    if(lookup===buildRunLookup&&run?.id===request.id&&run.head_sha===request.commit)await displayBuildResult(run,lookup);
  }catch(error){toast(error.message,'error');}
  finally{control.disabled=false;}
}
async function requestStudioBuild(event){
  event.preventDefault();if(releaseRequestBusy)return;
  if(transferBusy){toast('انتظر اكتمال رفع الأيقونة ثم احفظ طلب البناء.','error');return;}
  const saveOnly=event.submitter?.id==='saveStudioBuild';
  $('queueStudioBuild').disabled=true;$('saveStudioBuild').disabled=true;releaseRequestBusy=true;
  try{
    const settings=validateBuildSettings(buildSettingsFromForm()),token=releaseToken();
    if(!settings.delivery&&!saveOnly)throw Error('اختر طريقة تسليم ملف IPA قبل البناء.');
    $('buildIPAArtifactLink').hidden=true;
    await verifyStudioWorkflow(token);
    $('buildRequestStatus').textContent='جارٍ حفظ إعدادات البناء على GitHub…';
    const request=await writeStudioBuild(settings,token,saveOnly);
    buildRunLookup++;
    rememberStudioBuild(request);
    useSavedBuild(settings);
    if(saveOnly){showBuildRun('حُفظت إعدادات الإصدار. يمكنك تشغيل Actions مباشرة.');return;}
    showBuildRun('حُفظت الإعدادات وأُرسل طلب البناء. تابع التشغيل في Actions.');
    void findStudioBuild(request);
  }catch(error){
    const message=error.accountSuspended?error.message:error.status===403?'يلزم رمز يتيح تعديل Contents في مستودع X-SIGN.':
      error.status===404?'تعذّر الوصول إلى ملف Actions. تحقق من تثبيت النسخة الجديدة ومن صلاحية الرمز.':error.message;
    showBuildRun(message);
    toast($('buildRequestStatus').textContent,'error');
  }finally{$('queueStudioBuild').disabled=false;$('saveStudioBuild').disabled=false;releaseRequestBusy=false;}
}
async function loadSavedStudioBuild(){
  if(releaseRequestBusy)return;
  releaseRequestBusy=true;
  try{
    const token=releaseToken();
    const head=await github(XSIGN_BUILD_REPO,'git/ref/heads/'+XSIGN_BUILD_REPO.branch,'GET',undefined,token);
    const commit=head?.object?.sha;
    if(!gitSHA(commit))throw Error('تعذّر تحديد الالتزام الحالي لفرع البناء.');
    const file=await repositoryFile(XSIGN_BUILD_REPO,XSIGN_BUILD_FILE,commit,token,true);
    if(!file)throw Error('لا توجد إعدادات بناء محفوظة في المستودع بعد.');
    const record=readBuildDocument(file);
    const known=pendingBuildFor(bundleKey(record.settings.bundleIdentifier));
    buildRunLookup++;
    const request=known?.record.request_id===record.request_id?known:{record,commit,queued:false};
    rememberStudioBuild(request);
    useSavedBuild(record.settings);
    showBuildRun('تم جلب إعدادات البناء المحفوظة.',request.id);
  }catch(error){toast(error.message,'error');}
  finally{releaseRequestBusy=false;}
}
function initReleaseBuildForm(){
  let saved={};try{const value=JSON.parse(localStorage.getItem(XSIGN_SETTINGS_KEY)||'{}');if(isObject(value))saved=value;}catch{}
  setBuildForm(saved);
  for(const id of ['buildAppName','buildBundleID','buildVersion'])$(id).addEventListener('input',renderBuildSummary);
  for(const [id] of BUILD_FIELDS)$(id).addEventListener('change',()=>{try{localStorage.setItem(XSIGN_SETTINGS_KEY,JSON.stringify(buildSettingsFromForm()));}catch{}});
  if(validReleaseBundle(saved.bundleIdentifier))managedUpdateBundle=bundleKey(saved.bundleIdentifier);
  loadVerifiedReleases();
  const pending=pendingBuildFor(managedUpdateBundle);
  if(pending?.id)showBuildRun('آخر تشغيل بناء أرسلته من هذه اللوحة.',pending.id);
  else if(pending?.queued){showBuildRun('تابع طلب البناء المحفوظ في Actions.');void findStudioBuild(pending);}
  $('studioBuildForm').addEventListener('submit',requestStudioBuild);
  $('loadStudioBuild').addEventListener('click',loadSavedStudioBuild);
  $('setDefaultBuildIdentity').addEventListener('click',restoreRequestedIdentity);
  $('refreshStudioBuild').addEventListener('click',refreshBuildResult);
}
function releaseDraftFor(bundle,create=false){
  const d=state.xsign_config.dashboard,key=bundleKey(bundle);
  if(key===XSIGN_LEGACY_BUNDLE)return d.update;
  if(!own(d.bundle_updates,key)&&create)d.bundle_updates[key]={...clone(DASHBOARD_DEFAULTS.update),bundle_identifier:key};
  return own(d.bundle_updates,key)?d.bundle_updates[key]:undefined;
}
function selectUpdateBundle(value){
  value=value.trim();if(!validReleaseBundle(value))throw Error('أدخل Bundle ID صحيحاً.');
  if(bundleKey(value)!==managedUpdateBundle){$('ipaVerificationStatus').textContent='';$('ipaInspectionRunLink').hidden=true;}
  managedUpdateBundle=bundleKey(value);
  renderIntegration();
}
function normalizeReleaseEvidence(info, link){
  if(info?.isXSign!==true||!validAppName(info.appName)||!validReleaseBundle(info.bundleIdentifier)||
      !numericRelease(info.version)||!numericRelease(info.buildVersion)||!/^[a-f0-9]{64}$/i.test(info.sha256||'')){
    throw Error('تعذر التحقق من بيانات XSign داخل الملف. استخدم IPA ناتجاً من بناء XSign.');
  }
  const build_request_id=/^[a-f0-9]{32}$/.test(info.buildRequestID||'')?info.buildRequestID:'';
  return {app_name:info.appName,bundle_identifier:bundleKey(info.bundleIdentifier),latest_version:info.version,
    build_version:info.buildVersion,ipa_url:link,manifest_url:'',sha256:info.sha256.toLowerCase(),build_request_id};
}
function rememberedInspection(link){
  try{
    const saved=JSON.parse(sessionStorage.getItem(XSIGN_INSPECTION_KEY)||'null');
    if(saved?.link===link&&saved.privateQueue===true&&/^[a-f0-9]{32}$/.test(saved.requestId||'')&&Date.now()-saved.at<3600000)return saved;
  }catch{}
  return null;
}
function rememberInspection(link,job){
  try{
    if(job)sessionStorage.setItem(XSIGN_INSPECTION_KEY,JSON.stringify({...job,link}));
    else if(rememberedInspection(link))sessionStorage.removeItem(XSIGN_INSPECTION_KEY);
  }catch{}
}
async function inspectPublicRelease(storage,link,token){
  if(storage.branch!=='main'||(storage.owner+'/'+storage.repo).toLowerCase()!=='ipablack/repo'){
    throw Error('لمزامنة التحديث مع XSign، اختر ipablack/repo على main في المصادر والاتصال.');
  }
  const asset=publicUpdateAsset(link);
  await checkPublicUpdateAsset(asset);
  const id=newReleaseRequest(),workflow='xsign-inspect-public.yml';
  const bundle=managedUpdateBundle;
  try {
    await github(storage,'actions/workflows/'+workflow+'/dispatches','POST',{
      ref:'main',inputs:{ipa_url:link,request_id:id,bundle_id:bundle,build_request_id:''}
    },token);
  }catch(error){
    if(error.status===404)throw Error('ضع xsign-inspect-public.yml في .github/workflows على main في ipablack/repo وفعّله.');
    if(error.status===422){
      const path='.github/workflows/'+workflow;
      const file=await repositoryFile(storage,path,'main',token,true).catch(()=>null);
      let compatible=false;
      if(file){
        try{
          const engine=Store.readWorkflow(file.source,jsyaml);
          compatible=engine.dispatch&&['ipa_url','request_id','bundle_id','build_request_id'].every(key=>own(engine.inputs,key));
        }catch{}
      }
      if(file&&!compatible){
        throw Error('ملف GitHub الحالي ليس أكشن فحص IPA المتوافق. استبدل '+path+' بالملف المخصص للفحص على main في ipablack/repo، ثم أعد المحاولة.');
      }
      throw Error('رفض GitHub تشغيل أكشن فحص IPA (HTTP 422). تأكد من تفعيل xsign-inspect-public.yml على main في ipablack/repo.');
    }
    throw error;
  }
  const status=$('ipaVerificationStatus'),runLink=$('ipaInspectionRunLink');
  status.textContent='جارٍ فحص IPA من Releases العامة…';
  runLink.href='https://github.com/ipablack/repo/actions/workflows/'+workflow;
  runLink.hidden=false;
  for(let attempt=0;attempt<90;attempt++){
    if(attempt)await new Promise(resolve=>setTimeout(resolve,5000));
    const file=await repositoryFile(storage,'.xsign-inspect/'+id+'.json','main',token,true);
    if(!file)continue;
    const report=JSON.parse(file.source);
    if(report.requestID!==id)throw Error('تقرير الفحص يخص طلباً مختلفاً.');
    if(report.requestDigest&&globalThis.crypto?.subtle){
      const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(link));
      const expected=Array.from(new Uint8Array(bytes),value=>value.toString(16).padStart(2,'0')).join('');
      if(report.requestDigest!==expected)throw Error('تقرير الفحص يخص رابطاً مختلفاً.');
    }else if(report.ipaURL&&report.ipaURL!==link)throw Error('تقرير الفحص يخص رابطاً مختلفاً.');
    if(report.error)throw Error(report.error);
    return {...report,fromPublicRelease:true};
  }
  throw Error('لم يصل تقرير فحص IPA. راجع تشغيل الفحص في Actions.');
}
function publicUpdateAsset(link){
  const match=/^https:\/\/github\.com\/ipablack\/(repo|x-sign|xsign)\/releases\/download\/([A-Za-z0-9][A-Za-z0-9._-]{0,127})\/([A-Za-z0-9][A-Za-z0-9._-]{0,180}\.ipa)$/i.exec(link);
  if(!match)throw Error('استخدم رابط ملف IPA من Releases في أحد مستودعات XSign العامة التابعة لحساب ipablack.');
  const [,repo,tag,filename]=match;
  return {owner:'ipablack',repo,tag,filename};
}
async function checkPublicUpdateAsset(asset){
  let release;
  try{release=await github(asset,'releases/tags/'+encodeURIComponent(asset.tag),'GET',undefined,'');}
  catch(error){
    if(error.status===404)throw Error('التحديث لا يصل إلى المستخدمين من هذا الرابط. تأكد من وجود الإصدار العام أو ارفع ملف IPA إلى Releases العامة في ipablack/repo.');
    throw error;
  }
  if(release?.draft!==false||!Array.isArray(release.assets)||
      !release.assets.some(entry=>entry?.name===asset.filename&&entry.state==='uploaded')){
    throw Error('تعذّر العثور على ملف IPA في الإصدار العام. انسخ رابط الملف من قسم Assets بعد اكتمال رفعه.');
  }
}
async function inspectReleaseWithActions(link,token){
  const target=validateConnection({...connection});
  const repository=await github(target,'','GET',undefined,token);
  if(repository?.private===false)return inspectPublicRelease(target,link,token);
  const storage=await requirePrivateIPAStorage(target,token,repository);
  if(!privateIPARelease(link,storage))throw Error('الرابط يجب أن يكون لملف IPA في Releases بمستودع التخزين الخاص.');
  let job=rememberedInspection(link);
  if(!job){
    job={requestId:newReleaseRequest(),at:Date.now(),privateQueue:true};
    try{
      await submitPrivateIPA(storage,{kind:'inspect',ipa_url:link},job.requestId,token,null);
    }catch(error){
      if(error.status)throw error;
      rememberInspection(link,job);
      throw Error('تعذّر تأكيد إرسال الفحص. اضغط فحص الرابط مرة أخرى لمتابعة الطلب.');
    }
    rememberInspection(link,job);
  }
  $('ipaVerificationStatus').textContent='جارٍ فحص ملف IPA في GitHub…';
  const path='actions/workflows/'+XSIGN_BUILD_REPO.workflow;
  const title='XSign · IPA check '+job.requestId;
  const since=new Date(job.at-120000).toISOString();
  const list=path+'/runs?event=repository_dispatch&branch='+encodeURIComponent(XSIGN_BUILD_REPO.branch)+'&per_page=50&created='+encodeURIComponent('>='+since);
  const inspectionLink=$('ipaInspectionRunLink');
  inspectionLink.href=job.id?buildRunLink(job.id):RELEASE_WORKFLOW_URL;
  inspectionLink.hidden=false;
  for(let attempt=0;attempt<60;attempt++){
    if(attempt)await new Promise(resolve=>setTimeout(resolve,attempt<12?5000:10000));
    let run;
    if(job.id)run=await github(XSIGN_BUILD_REPO,'actions/runs/'+job.id,'GET',undefined,token);
    else{
      const runs=await github(XSIGN_BUILD_REPO,list,'GET',undefined,token);
      run=runs?.workflow_runs?.find(row=>row.display_title===title&&Number.isSafeInteger(row.id)&&row.id>0);
      if(!run){
        if(attempt>=15){
          rememberInspection(link,null);
          throw Error('لم يظهر تشغيل الفحص. تأكد من تثبيت ملف YML الجديد على main ثم أعد الفحص.');
        }
        continue;
      }
      job.id=run.id;
      rememberInspection(link,job);
      inspectionLink.href=buildRunLink(job.id);
    }
    if(run?.status!=='completed')continue;
    if(run.conclusion!=='success'){
      rememberInspection(link,null);
      throw Error('توقف فحص IPA. افتح سجل التشغيل لمعرفة السبب.');
    }
    const record=await repositoryFile(storage,'.xsign-queue/results/'+job.requestId+'.json','main',token,true);
    if(!record){
      if(attempt<59)continue;
      rememberInspection(link,null);
      throw Error('لم يصل تقرير الفحص إلى مستودع التخزين الخاص. تحقق من إعدادات المعالجة.');
    }
    const info=JSON.parse(record.source);
    if(info.requestID!==job.requestId)throw Error('تقرير الفحص يخص طلباً مختلفاً.');
    if(globalThis.crypto?.subtle){
      const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(link));
      const expected=Array.from(new Uint8Array(digest),value=>value.toString(16).padStart(2,'0')).join('');
      if(info.requestDigest!==expected)throw Error('تقرير الفحص يخص رابطاً مختلفاً.');
    }
    rememberInspection(link,null);
    return info;
  }
  throw Error('فحص IPA مستمر في GitHub. اضغط فحص الرابط مجدداً لمتابعة التشغيل الحالي.');
}

function ownerUpdateFromApp(app,bundle){
  if(!app||!validReleaseBundle(app.bundleIdentifier)||bundleKey(app.bundleIdentifier)!==bundleKey(bundle)){
    throw Error('معرف IPA لا يطابق Bundle ID الخاص ببناء XSign. لم تتغير إعدادات التحديث.');
  }
  if(!numericRelease(app.version)||app.buildVersion&&!numericRelease(app.buildVersion)||!validReleaseURL(app.downloadURL)||
      !/^[a-f0-9]{64}$/i.test(app.sha256||''))throw Error('هذا الإصدار لا يحتوي بيانات الناشر الكاملة. أعد جلب الكتالوج بعد نجاح Actions.');
  return {latest_version:app.version,build_version:app.buildVersion||'',ipa_url:app.downloadURL,sha256:app.sha256.toLowerCase(),
    manifest_url:'',bundle_identifier:bundleKey(app.bundleIdentifier),app_name:validAppName(app.name)?app.name:'',build_request_id:''};
}
function adoptCatalogueUpdate(){try{
  const app=state.apps.find(a=>catalogueKey(a)===$('selfUpdateApp').value);
  const patch=ownerUpdateFromApp(app,managedUpdateBundle);
  integrationChange(()=>Object.assign(releaseDraftFor(managedUpdateBundle,true),patch),'ربط إصدار XSign من الكتالوج');
  toast('نُقلت بيانات IPA وبصمته إلى المسودة. راجع الصفحة ثم فعّل التحديث وانشر.');
}catch(error){toast(error.message,'error');}}
function catalogueRelease(link,bundle=managedUpdateBundle){
  return state.apps.find(a=>validReleaseBundle(a.bundleIdentifier)&&bundleKey(a.bundleIdentifier)===bundle&&a.downloadURL===link&&
    numericRelease(a.version)&&/^[a-f0-9]{64}$/i.test(a.sha256||''));
}
function setReleaseLink(link,kind){
  const u=releaseDraftFor(managedUpdateBundle,true),previous=releaseLink(u);
  link=link.trim();
  if(!kind){try{kind=new URL(link).pathname.toLowerCase().endsWith('.plist')?'manifest':(link===previous&&u.manifest_url?'manifest':'ipa');}catch{kind='ipa';}}
  if(link!==previous||(kind==='manifest')!==Boolean(u.manifest_url)){
    u.sha256='';u.build_version='';u.app_name='';u.build_request_id='';
  }
  u.ipa_url=kind==='ipa'?link:'';u.manifest_url=kind==='manifest'?link:'';
  const app=kind==='ipa'&&catalogueRelease(link);
  if(app)Object.assign(u,ownerUpdateFromApp(app,managedUpdateBundle));
  syncReleaseGate(state);
}
function setReleaseMode(mode){
  if(!['off','optional','required'].includes(mode))return;
  const u=releaseDraftFor(managedUpdateBundle,true);
  u.enabled=mode!=='off';
  u.required=mode==='required';
  if(u.required&&!u.required_policy)u.required_policy='approved';
  syncReleaseGate(state);
}
function matchPendingBuild(pending,info){
  if(!pending)return;
  const expected=pending.record.settings;
  if(info.buildRequestID!==pending.record.request_id){
    throw Error('هذا الملف لا يخص طلب البناء المحدد. نزّل X-SIGN.ipa من التشغيل المرتبط في Studio.');
  }
  if(info.appName!==expected.appName||compareRelease(info.version,expected.version)!==0||
      expected.buildVersion&&compareRelease(info.buildVersion,expected.buildVersion)!==0){
    throw Error('هوية IPA تختلف عن إعدادات البناء المحفوظة. استخدم الملف الناتج من طلب Studio.');
  }
}
async function fillReleaseMetadata(reviewAfter=false){
  const bundle=managedUpdateBundle,u=releaseDraftFor(bundle),link=releaseLink(u||{}),button=$('fillReleaseMetadata');
  if(!link||!validReleaseURL(link)){toast('أدخل رابط HTTPS مباشراً للإصدار أولاً.','error');return false;}
  if(u.manifest_url){
    $('releaseAdvanced').open=true;
    if(reviewAfter)return preparePublish();
    toast('أدخل بيانات النسخة الموقعة كما تظهر في ملف الوصف.');return false;
  }
  if(releaseRequestBusy)return;
  releaseRequestBusy=true;button.disabled=true;
  $('ipaVerificationStatus').textContent='جارٍ التحقق من الرابط…';
  try{
    const info=await inspectReleaseWithActions(link,releaseToken());
    const patch=normalizeReleaseEvidence(info,link);
    if(managedUpdateBundle!==bundle||releaseLink(releaseDraftFor(bundle)||{})!==link){
      $('ipaVerificationStatus').textContent='تغيّر الرابط أو البندل أثناء الفحص. أعد فحص الرابط المحدد.';return false;
    }
    if(patch.bundle_identifier!==bundle)throw Error('الملف يخص '+patch.bundle_identifier+'، اختر هذا البندل لإدارة تحديثه.');
    const pending=pendingBuildFor(bundle);
    if(!info.fromPublicRelease||pending?.record.request_id===info.buildRequestID)matchPendingBuild(pending,info);
    saveVerifiedRelease(bundle,patch,info.buildRequestID||'',info.fromPublicRelease===true);
    integrationChange(()=>Object.assign(releaseDraftFor(bundle,true),patch),'التحقق من ملف إصدار XSign');
    $('ipaVerificationStatus').textContent='تم التحقق من IPA. راجع وضع التحديث وانشر من اللوحة.';
    toast('تمت مطابقة البندل وجلب الاسم والإصدار ورقم البناء والبصمة.');
    if(reviewAfter)await preparePublish();
    return true;
  }catch(error){$('releaseAdvanced').open=true;$('ipaVerificationStatus').textContent=error.message;toast(error.message,'error');return false;}
  finally{button.disabled=false;releaseRequestBusy=false;}
}
function releaseIdentity(release,bundle){
  return [release?.ipa_url||'',release?.manifest_url||'',(release?.sha256||'').toLowerCase(),
    release?.latest_version||'',release?.build_version||'',bundleKey(release?.bundle_identifier||bundle),release?.build_request_id||''];
}
function validateReleasePublication(next,previous){
  const dashboard=next.xsign_config.dashboard,prior=previous?.xsign_config?.dashboard;
  const records=[[XSIGN_LEGACY_BUNDLE,dashboard.update,prior?.update],
    ...Object.entries(dashboard.bundle_updates).map(([bundle,release])=>[bundle,release,prior?.bundle_updates?.[bundle]])];
  for(const [bundle,release,live] of records){
    if(!release.enabled||release.manifest_url||!release.ipa_url)continue;
    const identity=releaseIdentity(release,bundle);
    const previouslyVerified=Store.same(identity,releaseIdentity(live,bundle));
    if(previouslyVerified)continue;
    if(numericRelease(live?.latest_version)&&numericRelease(live?.build_version||'0')){
      const order=compareRelease(release.latest_version,live.latest_version);
      if(order<0||order===0&&compareRelease(release.build_version||'0',live.build_version||'0')<=0)
        throw Error('استخدم إصداراً أو رقم بناء أعلى من التحديث المنشور للبندل '+bundle+'.');
    }
    if(!matchesVerifiedRelease(release,bundle))throw Error('افحص رابط IPA للبندل '+bundle+' قبل اعتماد النسخة.');
  }
}
function privateReleaseLocation(value,c){
  try{
    const url=new URL(value),segments=url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    return url.origin==='https://github.com'&&!url.username&&!url.password&&!url.search&&!url.hash&&segments.length===6&&
      segments[0].toLowerCase()===c.owner.toLowerCase()&&segments[1].toLowerCase()===c.repo.toLowerCase()&&
      segments[2]==='releases'&&segments[3]==='download'&&/^[A-Za-z0-9._-]+$/.test(segments[4])&&
      /^[A-Za-z0-9._-]+\.ipa$/i.test(segments[5]);
  }catch{return false;}
}
function validatePrivateCatalogReleases(data,c){
  const dashboard=data.xsign_config.dashboard;
  for(const update of [dashboard.update,...Object.values(dashboard.bundle_updates)]){
    if(update.enabled&&!update.manifest_url&&!privateReleaseLocation(update.ipa_url,c)){
      throw Error('ربط تحديث IPA بالخدمة يحتاج ملفاً من Releases في مستودع الكتالوج الخاص نفسه.');
    }
  }
}
function showPublicationStatus(c,revision,isPrivate){
  const box=$('liveDeliveryStatus');
  const release=releasePublicationSummary(state);
  if(!isPrivate){box.textContent='نُشرت المراجعة '+revision+' إلى GitHub. التحديث للبندل '+release.bundle+' '+release.mode+'. يقرأ XSign الأمر عند المزامنة.';return;}
  if(c.branch!=='main'||c.path!=='repo.json'||c.configPath!=='xsign-config.json'){
    box.textContent='نُشرت المراجعة '+revision+' إلى الوجهة المختارة. خدمة Xsign تقرأ الملفين القياسيين من فرع main.';return;
  }
  box.textContent='نُشرت المراجعة '+revision+' إلى المستودع الخاص. تصل إلى XSign عبر عنوان خدمة الكتالوج المحدد في بناء التطبيق.';
}
function installEscape(value){return String(value??'').replace(/[&<>"{}]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;','{':'&#123;','}':'&#125;'}[c]));}
function currentUpdateDraft(){return releaseDraftFor(managedUpdateBundle)||DASHBOARD_DEFAULTS.update;}
function defaultInstallFragment(u,required,tint='#005BBB'){
  const template=typeof XSIGN_INSTALL_TEMPLATE==='string'?XSIGN_INSTALL_TEMPLATE:'<h1>{{heading}}</h1><p>{{name}} · {{version}}</p><p>{{details}}</p>{{action}}';
  const name=u.app_name||XSIGN_INTEGRATION.name;
  const values={tint,heading:required?'حدّث '+name+' للمتابعة':'تحديث '+name,name,version:'الإصدار '+(u.latest_version||'—'),details:u.notes||'ثبّت الإصدار ووافق على طلب iOS.'};
  return template.replace(/\{\{(\w+)\}\}/g,(_,key)=>key==='action'?'<a class="install-action" href="xsign-update://install">تثبيت</a>':installEscape(values[key]));
}
function renderUpdateHTML(){const frame=$('ownerHTMLPreview');if(!frame)return;
  const cfg=state.xsign_config,u=currentUpdateDraft(),required=u.required??(managedUpdateBundle===XSIGN_LEGACY_BUNDLE&&cfg.force_update.enabled);
  const tint=/^#[0-9a-f]{6}$/i.test(cfg.theme.app_tint_hex)?cfg.theme.app_tint_hex:'#005BBB';
  const content=u.html||defaultInstallFragment(u,required,tint);
  const doc='<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;;style-src &#39;unsafe-inline&#39;;img-src data:;form-action &#39;none&#39;;base-uri &#39;none&#39;"></head><body>'+content+'</body></html>';
  if(frame.srcdoc!==doc)frame.srcdoc=doc;
}
function renderReleaseEditor(){
  const u=currentUpdateDraft(),isPrimary=managedUpdateBundle===XSIGN_LEGACY_BUNDLE;
  const legacyEnabled=isPrimary&&state.xsign_config.force_update.enabled;
  for(const field of $$('[data-release-field]'))field.value=u[field.dataset.releaseField]||'';
  const bundleLabel=bundle=>pendingBuildFor(bundle)?.record.settings.bundleIdentifier||
    (bundle===bundleKey(XSIGN_INTEGRATION.bundle)?XSIGN_INTEGRATION.bundle:bundle);
  $('expectedBundle').value=bundleLabel(managedUpdateBundle);
  $('ownerLatest').readOnly=!u.manifest_url;
  $('ownerBuild').readOnly=!u.manifest_url;
  $('ownerSHA').readOnly=true;
  $('ownerReleaseLinkLabel').textContent=u.manifest_url?'رابط ملف التثبيت':'رابط IPA المباشر';
  const bundles=new Set([bundleKey(XSIGN_INTEGRATION.bundle),XSIGN_LEGACY_BUNDLE,managedUpdateBundle,...Object.keys(state.xsign_config.dashboard.bundle_updates||{})]);
  $('releaseBundleChoices').replaceChildren(...[...bundles].map(bundle=>{const label=bundleLabel(bundle),option=text('option',label);option.value=label;return option;}));
  $('ownerReleaseLink').value=releaseLink(u);$('ownerLinkKind').value=u.manifest_url?'manifest':'ipa';
  $('ownerReleaseMode').value=u.enabled&&u.required===true?'required':u.required==null&&legacyEnabled?'legacy':u.enabled?'optional':'off';
  $('reviewStudioRelease').textContent=u.enabled?'مراجعة ونشر التحديث':'مراجعة ونشر · التحديث متوقف';
  $('releasePolicyField').hidden=u.required!==true;
  $('legacyReleasePolicy').hidden=!isPrimary;
  $('ownerReleasePolicy').value=u.required_policy||(isPrimary?'legacy':'approved');
  $('legacyReleaseSettings').hidden=typeof u.required==='boolean'||!legacyEnabled;
  $('ownerReleaseState').textContent=!u.enabled&&!legacyEnabled
    ? 'التحديث متوقف لهذا البندل. اختر اختياري أو إجباري ثم انشر لتظهر صفحة التحديث في التطبيق.'
    : u.required===true
    ? 'يظهر التحديث قبل المتجر لكل نسخة خارج سياسة السماح. استخدم رقم بناء جديداً لكل ملف تنشره.'
    : u.enabled ? 'تظهر الصفحة تلقائياً مرة لكل إصدار جديد، ويمكن فتحها مجدداً من الإعدادات.'
      : legacyEnabled ? 'يُستخدم حد الإصدار الإجباري من الإعداد السابق.'
        : 'التحديث متوقف. اختر اختياري أو إجباري ثم انشر الملفين.';
  renderUpdateHTML();
}
let editingSigningLibrary=null;
function signingLibraryError(items){
  if(!Array.isArray(items)||items.length>40)return 'يمكن نشر 40 دايلب جاهزًا كحد أقصى.';
  const ids=new Set();
  for(const item of items){
    if(!isObject(item)||typeof item.id!=='string'||!/^[a-f0-9]{32}$/.test(item.id)||ids.has(item.id)||
      typeof item.name!=='string'||!item.name.trim()||Array.from(item.name).length>80||
      typeof item.enabled!=='boolean'||typeof item.sha256!=='string'||!/^[a-f0-9]{64}$/.test(item.sha256)||
      !Array.isArray(item.bundles)||!item.bundles.length||item.bundles.length>30||
      item.bundles.some(bundle=>!validReleaseBundle(bundle)))return 'كل مكتبة تحتاج اسمًا وبصمة SHA-256 ومعرّفات حزم صالحة.';
    try{
      if(!nativeHTTPS(item.url))throw Error();
      const url=new URL(item.url);
      if(url.port||url.search||!/^[A-Za-z0-9][A-Za-z0-9._-]{0,100}\.dylib$/i.test(
        decodeURIComponent(url.pathname.split('/').pop())))throw Error();
    }catch{return 'رابط المكتبة يجب أن يكون HTTPS مباشرًا وينتهي باسم ملف dylib صالح.';}
    ids.add(item.id);
  }
  return '';
}
function editSigningLibrary(item){
  editingSigningLibrary=item?.id??null;
  $('libraryName').value=item?.name??'';$('libraryBundles').value=item?.bundles.join(', ')??'';
  $('libraryURL').value=item?.url??'';$('librarySHA').value=item?.sha256??'';$('libraryEnabled').checked=item?.enabled??true;
  $('libraryHashFile').value='';
  $('saveSigningLibrary').textContent=item?'حفظ التعديل':'إضافة إلى المسودة';
  $('cancelSigningLibrary').hidden=!item;
  if(item)$('libraryName').focus();
}
function saveSigningLibrary(event){
  event.preventDefault();
  const d=state.xsign_config.dashboard,items=Array.isArray(d.signing_libraries)?d.signing_libraries:[];
  const item={id:editingSigningLibrary??newReleaseRequest(),name:$('libraryName').value.trim(),url:$('libraryURL').value.trim(),
    sha256:$('librarySHA').value.trim().toLowerCase(),bundles:[...new Set($('libraryBundles').value.toLowerCase().split(/[,،\s]+/).filter(Boolean))],
    enabled:$('libraryEnabled').checked};
  const exists=items.some(row=>row.id===item.id);
  if(editingSigningLibrary&&!exists){editSigningLibrary();toast('لم تعد المكتبة موجودة في المسودة.','error');return;}
  const next=exists?items.map(row=>row.id===item.id?item:row):[...items,item];
  const error=signingLibraryError(next);if(error){toast(error,'error');return;}
  integrationChange(()=>{d.signing_libraries=next;},'حفظ الدايلبات الجاهزة');editSigningLibrary();
}
function renderSigningLibraries(items){
  const list=$('signingLibraryRows');if(!list)return;
  list.replaceChildren();
  if(!Array.isArray(items)||!items.length){list.append(text('p','لا توجد مكتبات في المسودة.','muted'));return;}
  for(const item of items){
    if(!isObject(item)||!Array.isArray(item.bundles))continue;
    const row=text('div','','row wrap between'),label=text('div','','grow');
    label.append(text('strong',item.name),text('div',item.bundles.join(', '),'muted tiny'));
    row.append(label,text('span',item.enabled?'ظاهر':'متوقف','tag'),
      button('تعديل',()=>editSigningLibrary(item),'edit','btn btn-small'),
      button('حذف',()=>confirmAction('حذف المكتبة','ستختفي بعد نشر التغييرات.',()=>{
        integrationChange(()=>{const d=state.xsign_config.dashboard;d.signing_libraries=d.signing_libraries.filter(row=>row.id!==item.id);},'حذف دايلب');
        if(editingSigningLibrary===item.id)editSigningLibrary();
      }),'trash','btn btn-small'));
    list.append(row);
  }
}
async function fillSigningLibraryHash(event){
  const field=event.target,file=field.files?.[0];if(!file)return;
  const form=$('signingLibraryForm'),save=$('saveSigningLibrary');
  save.disabled=true;
  try{
    if(!/\.dylib$/i.test(file.name)||file.size<32||file.size>8388608)throw Error('اختر ملف dylib لا يتجاوز 8 ميغابايت.');
    const hash=await crypto.subtle.digest('SHA-256',await file.arrayBuffer());
    if(field.files?.[0]===file&&form.isConnected)$('librarySHA').value=Array.from(new Uint8Array(hash),byte=>byte.toString(16).padStart(2,'0')).join('');
  }catch(error){toast(error.message,'error');}
  finally{save.disabled=false;}
}
function renderIntegration(){
  renderUsageStats();
  renderPushService();
  if(!$('managedSourcesV2'))return;const d=state.xsign_config.dashboard;
  $('managedSourcesV2').replaceChildren(...d.sources.map((item,i)=>sourceOrSectionRow(item,i,d.sources,true)));
  renderSourcePresets(d.sources);
  renderSigningLibraries(d.signing_libraries);
  $('storeSectionsV2').replaceChildren(...d.sections.map((item,i)=>sourceOrSectionRow(item,i,d.sections,false)));
  renderFeaturedPicker();
  const tabs=$('storeTabsV2');tabs.replaceChildren();
  const available=[...d.tab_order,...Object.keys(TAB_TITLES).filter(k=>!d.tab_order.includes(k))];
  for(const key of available){const index=d.tab_order.indexOf(key),row=text('div','','row entry'),label=text('label','','grow'),input=document.createElement('input');input.type='checkbox';input.checked=index>=0;
    input.addEventListener('change',()=>{if(!input.checked&&d.tab_order.length===1){input.checked=true;toast('أبقِ تبويباً واحداً على الأقل.','error');return;}
      integrationChange(()=>{if(input.checked)d.tab_order.push(key);else d.tab_order.splice(d.tab_order.indexOf(key),1);},'تغيير تبويبات التطبيق');});
    label.append(input,document.createTextNode(' '+TAB_TITLES[key]));row.append(label);
    if(index>=0)row.append(button('↑',()=>integrationMove(d.tab_order,index,-1)),button('↓',()=>integrationMove(d.tab_order,index,1)));tabs.append(row);
  }
  const selected=$('selfUpdateApp').value;const select=$('selfUpdateApp');select.replaceChildren();const empty=text('option','اختر إصداراً من الكتالوج');empty.value='';select.append(empty);
  for(const app of state.apps.filter(a=>validReleaseBundle(a.bundleIdentifier)&&bundleKey(a.bundleIdentifier)===managedUpdateBundle)){const option=text('option',(app.name||app.bundleIdentifier)+' · '+app.version);option.value=catalogueKey(app);select.append(option);}select.value=selected;
  $('integrationRevision').textContent=String(state.repo_revision_id);
  $('integrationIdentity').textContent=XSIGN_INTEGRATION.name+' '+XSIGN_INTEGRATION.version+' · '+XSIGN_INTEGRATION.bundle+' · iOS '+XSIGN_INTEGRATION.minimumOS+'+';
  $('integrationTarget').textContent='يقرأ XSign الكتالوج وسياسة التحديث من فرع main في ipablack/repo العام.';
  $('integrationSource').textContent=XSIGN_INTEGRATION.source;
  $('integrationFeatures').replaceChildren(...XSIGN_INTEGRATION.features.map(([title,path])=>{const row=text('div','','entry');row.append(text('strong',title),text('small',path,'muted latin'));return row;}));
  renderReleaseEditor();
}
const integrationRenderAll=renderAll;
renderAll=function(){integrationRenderAll();renderIntegration();};
const integrationOpenPage=openPage;
openPage=function(name,updateHash=true){integrationOpenPage(name,updateHash);if(['sources','layout','updates','integration','controls'].includes(name))renderIntegration();};
const integrationField=fieldInput;
fieldInput=function(el,final=false){integrationField(el,final);const path=el.dataset.path,locks=state.xsign_config.security_locks;
  if(path==='xsign_config.usage_stats.endpoint')renderUsageStats();
  if(path==='xsign_config.push_endpoint')renderPushService();
  if(path==='xsign_config.security_locks.lock_bundle_rename'){locks.allow_app_metadata_editing=!locks.lock_bundle_rename;$('allowMetadata').checked=locks.allow_app_metadata_editing;}
  if(path==='xsign_config.security_locks.allow_app_metadata_editing'){locks.lock_bundle_rename=!locks.allow_app_metadata_editing;$('lockBundle').checked=locks.lock_bundle_rename;}
  if(path.startsWith('xsign_config.dashboard.update.')){syncReleaseGate(state);renderUpdateHTML();}
  if(path==='xsign_config.force_update.enabled')renderReleaseEditor();
};
const integrationBind=bindStoreEvents;
bindStoreEvents=function(){integrationBind();
  $('studioPushForm').addEventListener('submit',reviewPushCampaign);
  $('studioPushStatusButton').addEventListener('click',refreshPushStatus);
  $('studioPushHealthButton')?.addEventListener('click',checkPushHealth);
  $('studioPushTarget').addEventListener('focus',renderPushTargets);
  $('studioPushKind').addEventListener('change',()=>{$('studioPushTarget').value='';renderPushTargets();});
  window.addEventListener('pagehide',()=>{pushRequest?.abort();$('studioPushToken').value='';});
  $('usageRefresh').addEventListener('click',refreshUsageStats);
  $('usageAdminToken').addEventListener('input',()=>{usageRequest++;usageAbort?.abort();clearUsageStats('أدخل رمز المالك واضغط تحديث الأعداد.');});
  window.addEventListener('pagehide',()=>{usageRequest++;usageAbort?.abort();$('usageAdminToken').value='';clearUsageStats('أدخل رمز المالك لعرض الأعداد.');});
  $('managedSourceForm').addEventListener('submit',saveManagedSource);$('storeSectionForm').addEventListener('submit',saveStoreSection);
  $('cancelManagedSource').addEventListener('click',()=>editManagedSource());$('cancelStoreSection').addEventListener('click',()=>editStoreSection());
  for(const id of ['sectionPageV2','sectionKindV2','sectionLimitV2','sectionSourceV2','sectionCategoryV2','sectionFeaturedQuery','sectionAppsV2']){
    $(id).addEventListener('input',renderFeaturedPicker);
  }
  $('sectionFeaturedApp').addEventListener('change',()=>{$('addSectionFeaturedApp').disabled=!$('sectionFeaturedApp').value;});
  $('addSectionFeaturedApp').addEventListener('click',addSectionFeaturedApp);

  $('signingLibraryForm').addEventListener('submit',saveSigningLibrary);
  $('cancelSigningLibrary').addEventListener('click',()=>editSigningLibrary());
  $('libraryHashFile').addEventListener('change',fillSigningLibraryHash);
  initReleaseBuildForm();
  const releaseTabs=$$('.release-navigation [data-release-jump]');
  const releasePanes=$$('[data-release-pane]');
  for(const button of $$('[data-release-jump]'))button.addEventListener('click',()=>{
    const pane=$(button.dataset.releaseJump);
    for(const section of releasePanes)section.hidden=section!==pane;
    for(const tab of releaseTabs)tab.setAttribute('aria-pressed',String(tab.dataset.releaseJump===pane.id));
    pane.focus({preventScroll:true});
  });
  $('expectedBundle').addEventListener('change',event=>{try{selectUpdateBundle(event.target.value);}catch(error){toast(error.message,'error');event.target.value=managedUpdateBundle;}});
  for(const field of $$('[data-release-field]')){
    field.addEventListener('input',()=>{releaseDraftFor(managedUpdateBundle,true)[field.dataset.releaseField]=field.value;syncReleaseGate(state);renderUpdateHTML();updateStatus();clearTimeout(saveTimer);saveTimer=setTimeout(persist,260);});
    field.addEventListener('change',persist);
  }
  $('adoptCatalogueUpdate').addEventListener('click',adoptCatalogueUpdate);
  $('ownerReleaseLink').addEventListener('input',event=>{setReleaseLink(event.target.value);$('ipaVerificationStatus').textContent='';$('ipaInspectionRunLink').hidden=true;renderOverview();updateStatus();clearTimeout(saveTimer);saveTimer=setTimeout(persist,260);});
  $('ownerReleaseLink').addEventListener('change',renderReleaseEditor);
  $('ownerLinkKind').addEventListener('change',event=>integrationChange(()=>setReleaseLink(releaseLink(currentUpdateDraft()),event.target.value),'تغيير نوع رابط الإصدار'));
  $('ownerReleaseMode').addEventListener('change',event=>integrationChange(()=>setReleaseMode(event.target.value),'تغيير حالة الإصدار'));
  $('ownerReleasePolicy').addEventListener('change',event=>integrationChange(()=>{
    const update=releaseDraftFor(managedUpdateBundle,true);
    if(event.target.value==='legacy')delete update.required_policy;
    else update.required_policy=event.target.value;
  },'تغيير سياسة السماح بالإصدارات'));
  $('fillReleaseMetadata').addEventListener('click',()=>fillReleaseMetadata());
  $('studioStoreOnlyPublish').addEventListener('click',()=>preparePublish(true));
  $('reviewStudioRelease').addEventListener('click',()=>{
    const draft=currentUpdateDraft(),link=releaseLink(draft);
    if(!draft.enabled||!link||draft.manifest_url||matchesVerifiedRelease(draft,managedUpdateBundle))return preparePublish();
    return fillReleaseMetadata(true);
  });
  $('ownerHTMLFile').addEventListener('change',async event=>{try{const bundle=managedUpdateBundle,file=event.target.files[0];if(!file)return;if(file.size>200000)throw Error('اختر صفحة HTML أصغر من 200 KB.');const html=await file.text();if(html.length>100000)throw Error('حد الصفحة 100000 حرف.');integrationChange(()=>releaseDraftFor(bundle,true).html=html,'استيراد صفحة التحديث');}catch(error){toast(error.message,'error');}finally{event.target.value='';}});
  $('ownerHTMLSample').addEventListener('click',()=>confirmAction('قالب صفحة التثبيت','استبدال HTML الحالي بقالب قابل للتعديل؟',()=>integrationChange(()=>releaseDraftFor(managedUpdateBundle,true).html=defaultInstallFragment(currentUpdateDraft(),currentUpdateDraft().required===true),'تغيير صفحة التثبيت'),'تطبيق القالب',false));
  $('resetInstallHTML').addEventListener('click',()=>integrationChange(()=>releaseDraftFor(managedUpdateBundle,true).html='','استعادة صفحة التثبيت الافتراضية'));
};
