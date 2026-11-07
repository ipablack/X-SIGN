
    'use strict';
    // All application behavior is contained in this file. No external JavaScript.
    const PRIMARY_SOURCE_URL = 'https://appiraq.com/source.php?action=getAll';
    const SECONDARY_SOURCE_URL = 'https://appiraq.com/han.json';
    const OWNED_CANONICAL_URL = 'https://raw.githubusercontent.com/ipablack/repo/main/repo.json';
    const STORAGE_KEY = 'xsign.studio.state.v3';
    const LEGACY_STORAGE_KEY = 'xsign.studio.state.v2';
    const META_KEY = 'xsign.studio.workspace.v3';
    const PAGE_SIZE = 30;
    const $ = id => document.getElementById(id);
    const $$ = selector => [...document.querySelectorAll(selector)];
    const clone = value => JSON.parse(JSON.stringify(value));
    const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
    const own = (o,k) => Object.prototype.hasOwnProperty.call(o,k);
    const text = (tag, value, className = '') => { const el=document.createElement(tag); el.textContent=String(value ?? ''); el.className=className; return el; };
    const icon = name => { const el=document.createElementNS('http://www.w3.org/2000/svg','svg'); el.setAttribute('class','icon'); el.setAttribute('aria-hidden','true'); const use=document.createElementNS('http://www.w3.org/2000/svg','use'); use.setAttribute('href','#i-'+name); el.append(use); return el; };
    const button = (label, action, name, className='btn btn-ghost btn-small') => { const b=text('button', '', className); b.type='button'; if(name)b.append(icon(name)); if(label)b.append(document.createTextNode(label)); b.addEventListener('click',action); return b; };
    const safeInteger = (value, fallback=1) => Number.isSafeInteger(Number(value)) && Number(value)>=1 ? Number(value) : fallback;
    const dateToday = () => new Date().toISOString().slice(0,10);
    const padded = number => String(number).padStart(2,'0');
    const uid = () => globalThis.crypto?.randomUUID?.() || Date.now().toString(36)+'-'+Math.random().toString(36).slice(2);
    function createDefaultState() {
      return {
        name:'IPA BLACK',identifier:'xsign.core.owned',subtitle:'المصدر الرسمي لتطبيق X-SIGN',
        description:'المكتبة الرسمية وتكوين لوحة تحكم X-SIGN المعتمدة.',iconURL:'https://up6.cc/2026/11/179399545145851.png',website:'https://x-sign.web.app',tintColor:'#005BBB',repo_revision_id:1,
        featuredApps:[],categories:[{id:'social',name:'التواصل الاجتماعي',isGame:false},{id:'media',name:'صور وفيديو ووسائط',isGame:false},{id:'tools',name:'أدوات التطوير',isGame:false},{id:'productivity',name:'إنتاجية',isGame:false},{id:'games',name:'ألعاب',isGame:true}],news:[],apps:[],
        xsign_config:{
          splash_screen:{engine:'vector',animation_style:'laser_draw',show_sign_feather:true,duration_seconds:3.2,custom_code:'',size_px:225,stroke_width:8,glow_radius:18,subtitle:'IPA BLACK'},
          theme:{app_tint_hex:'#005BBB',splash_bg_top_hex:'#002B66',splash_bg_bottom_hex:'#00183B',splash_logo_hex:'#FFFFFF'},
          maintenance:{enabled:false,title:'التطبيق قيد الصيانة',message:'نقوم حالياً بتحديث الخدمات، يرجى المحاولة لاحقاً.',button_url:'https://x-sign.web.app'},
          force_update:{enabled:false,min_version:'1.0.0',update_url:'https://x-sign.web.app',message:'يتوفر تحديث جديد ومهم لتطبيق X-SIGN.'},
          security_locks:{allow_app_metadata_editing:true,lock_bundle_rename:false,lock_icon_change:false,lock_dylib_injection:false,anti_vpn_proxy:false,require_online_handshake:false,vpn_warning_message:'عذراً، لا يمكن استخدام تطبيق X-Sign أو تحميل التطبيقات أثناء تشغيل VPN أو برامج مراقبة الشبكة (Proxy).'},
          app_control:{top_banner_enabled:false,top_banner_text:'',top_banner_url:'https://x-sign.web.app',cache_flush_id:1,purge_sources_id:1,core_sources:[]}
        }
      };
    }
    // Merge defaults recursively, preserve unknown keys, and reject prototype keys.
    function mergeSafe(base, incoming) {
      if(!isObject(incoming)) throw new Error('يجب أن يكون جذر الملف كائن JSON.');
      const result=clone(base);
      for(const [key,value] of Object.entries(incoming)) {
        if(['__proto__','constructor','prototype'].includes(key)) throw new Error('يحتوي الملف على اسم حقل غير مسموح.');
        if(isObject(value)) result[key]=mergeSafe(isObject(result[key])?result[key]:{},value);
        else result[key]=clone(value);
      }
      return result;
    }
    function assertSafeTree(value, depth=0) {
      if(depth>50) throw new Error('تداخل الحقول أعمق من الحد المسموح.');
      if(Array.isArray(value)) { for(const item of value)assertSafeTree(item,depth+1); }
      else if(isObject(value)) for(const [key,item] of Object.entries(value)) {
        if(['__proto__','constructor','prototype'].includes(key))throw new Error('حقل غير مسموح: '+key);
        assertSafeTree(item,depth+1);
      }
    }
    function enforceCoreSources(target) {
      target.identifier='xsign.core.owned';
      const configured=target.xsign_config.dashboard?.sources;
      const sources=Array.isArray(configured)?configured.filter(s=>isObject(s)&&s.enabled!==false):[
        {name:'IPA BLACK',id:'xsign.core.owned',url:OWNED_CANONICAL_URL},
        {name:'ipasoon',id:'xsign.core.primary',url:PRIMARY_SOURCE_URL},
        {name:'متجر Zsign الرسمي',id:'xsign.core.zsign',url:SECONDARY_SOURCE_URL}
      ];
      target.xsign_config.app_control.core_sources=sources.map(s=>({name:s.name,id:s.id,url:s.url}));
      return target;
    }
    function normalizeState(parsed) {
      if(!isObject(parsed))throw new Error('جذر repo.json يجب أن يكون كائن JSON.');
      assertSafeTree(parsed);
      for(const key of ['apps','news','categories','featuredApps']) if(own(parsed,key)&&!Array.isArray(parsed[key]))throw new Error('الحقل '+key+' يجب أن يكون قائمة.');
      if(parsed.apps?.length>30000)throw new Error('الملف يتجاوز 30000 تطبيق.');
      const base=createDefaultState();
      if(own(parsed,'xsign_config')) {
        if(!isObject(parsed.xsign_config))throw new Error('xsign_config يجب أن يكون كائناً.');
        for(const key of Object.keys(base.xsign_config))if(own(parsed.xsign_config,key)&&!isObject(parsed.xsign_config[key]))throw new Error('التكوين '+key+' يجب أن يكون كائناً.');
      }
      const next=mergeSafe(base,parsed);
      for(const key of ['apps','news','categories'])if(next[key].some(item=>!isObject(item)))throw new Error('يوجد عنصر غير صالح في '+key+'.');
      for(const app of next.apps)if(own(app,'versions')&&(!Array.isArray(app.versions)||app.versions.some(v=>!isObject(v))))throw new Error('قائمة إصدارات أحد التطبيقات غير صالحة.');
      next.repo_revision_id=safeInteger(next.repo_revision_id);
      next.xsign_config.app_control.cache_flush_id=safeInteger(next.xsign_config.app_control.cache_flush_id);
      next.xsign_config.app_control.purge_sources_id=safeInteger(next.xsign_config.app_control.purge_sources_id);
      // A partial imported theme inherits a valid legacy tint if present.
      if(!own(parsed.xsign_config?.theme||{},'app_tint_hex')&&/^#[0-9a-f]{6}$/i.test(parsed.tintColor||''))next.xsign_config.theme.app_tint_hex=parsed.tintColor;
      next.tintColor=next.xsign_config.theme.app_tint_hex;
      return enforceCoreSources(next);
    }
    function httpsUrl(value, optional=false) {
      if(optional&&!value)return true;
      if(typeof value!=='string')return false;
      try{const url=new URL(value);return url.protocol==='https:'&&!url.username&&!url.password&&!!url.hostname;}catch{return false;}
    }
    function httpImage(value) {
      if(typeof value!=='string')return '';
      try{const u=new URL(value);return u.protocol==='https:'&&!u.username&&!u.password?u.href:'';}catch{return '';}
    }
    function validateState(data) {
      const errors=[];
      if(typeof data.name!=='string'||!data.name.trim())errors.push('أدخل اسم السورس.');
      for(const key of ['subtitle','description','iconURL','website'])if(data[key]!==undefined&&typeof data[key]!=='string')errors.push('الحقل '+key+' يجب أن يكون نصاً.');
      for(const key of ['iconURL','website'])if(data[key]&&!httpsUrl(data[key]))errors.push('رابط '+key+' يجب أن يكون HTTPS.');
      if(!Number.isSafeInteger(data.repo_revision_id)||data.repo_revision_id<1)errors.push('رقم المراجعة غير صالح.');
      const theme=data.xsign_config.theme;
      for(const [key,value] of Object.entries(theme))if(['app_tint_hex','splash_logo_hex','splash_bg_top_hex','splash_bg_bottom_hex'].includes(key)&&!/^#[0-9a-f]{6}$/i.test(value))errors.push('قيمة اللون '+key+' غير صالحة.');
      const splash=data.xsign_config.splash_screen;
      for(const [key,min,max] of [['duration_seconds',1.5,7],['size_px',150,310],['stroke_width',2,18],['glow_radius',0,45]])if(typeof splash[key]!=='number'||!Number.isFinite(splash[key])||splash[key]<min||splash[key]>max)errors.push('قيمة '+key+' خارج المدى المسموح.');
      if(!['vector','native_vector','custom_css'].includes(splash.engine))errors.push('محرك الإقلاع غير مدعوم في هذه اللوحة.');
      if(!['laser_draw','twin_slash','neon_pulse','liquid_shine','cyber_glitch','apple_minimal'].includes(splash.animation_style))errors.push('اختر نمط إقلاع مدعوماً.');
      if(typeof splash.custom_code!=='string'||typeof splash.subtitle!=='string')errors.push('نصوص شاشة الإقلاع غير صالحة.');
      if(typeof splash.custom_code==='string'&&splash.custom_code.length>200000)errors.push('كود الإقلاع يتجاوز 200 KB.');
      if(splash.engine==='custom_css'&&!String(splash.custom_code||'').trim())errors.push('أضف كود شاشة الإقلاع المخصص.');
      const cfg=data.xsign_config;
      for(const [label,obj,key] of [['الشريط العلوي',cfg.app_control,'top_banner_enabled'],['الصيانة',cfg.maintenance,'enabled'],['التحديث الإجباري',cfg.force_update,'enabled']])if(typeof obj[key]!=='boolean')errors.push('حالة '+label+' يجب أن تكون true أو false.');
      for(const key of ['allow_app_metadata_editing','lock_bundle_rename','lock_icon_change','lock_dylib_injection','anti_vpn_proxy','require_online_handshake'])if(typeof cfg.security_locks[key]!=='boolean')errors.push('قيمة '+key+' يجب أن تكون true أو false.');
      if(typeof splash.show_sign_feather!=='boolean')errors.push('حالة إظهار Sign غير صالحة.');
      if(cfg.app_control.top_banner_enabled&&!String(cfg.app_control.top_banner_text||'').trim())errors.push('الشريط العلوي مفعّل دون نص.');
      if(cfg.app_control.top_banner_enabled&&!httpsUrl(cfg.app_control.top_banner_url,true))errors.push('رابط الشريط العلوي يجب أن يكون HTTPS.');
      if(cfg.maintenance.enabled&&(!String(cfg.maintenance.title||'').trim()||!String(cfg.maintenance.message||'').trim()))errors.push('أكمل عنوان ورسالة الصيانة.');
      if(cfg.maintenance.enabled&&!httpsUrl(cfg.maintenance.button_url,true))errors.push('رابط الصيانة يجب أن يكون HTTPS.');
      if(cfg.force_update.enabled) {
        if(!/^\d+(\.\d+){0,3}([+-][A-Za-z0-9.-]+)?$/.test(cfg.force_update.min_version))errors.push('أقل إصدار للتحديث الإجباري غير صالح.');
        if(!httpsUrl(cfg.force_update.update_url))errors.push('أدخل رابط HTTPS للتحديث الإجباري.');
      }
      const catIds=new Set();
      data.categories.forEach((cat,i)=>{if(typeof cat.id!=='string'||!cat.id.trim()||typeof cat.name!=='string'||!cat.name.trim())errors.push('التصنيف '+(i+1)+' يحتاج اسماً ومعرفاً.');if(catIds.has(cat.id))errors.push('معرف تصنيف مكرر: '+cat.id);catIds.add(cat.id);if(typeof cat.isGame!=='boolean')errors.push('قيمة isGame غير صالحة للتصنيف '+(i+1)+'.');});
      const catalogs=new Set();
      data.apps.forEach((app,i)=>{
        const prefix='التطبيق '+(typeof app.name==='string'?app.name.slice(0,65):i+1)+': ';
        if(typeof app.name!=='string'||!app.name.trim())errors.push(prefix+'الاسم مطلوب.');
        if(typeof app.bundleIdentifier!=='string'||!/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(app.bundleIdentifier))errors.push(prefix+'معرف الحزمة غير صالح.');
        if(own(app,'versions')&&!Array.isArray(app.versions))errors.push(prefix+'versions يجب أن تكون قائمة.');
        const versions=Array.isArray(app.versions)?app.versions:[];
        if(!httpsUrl(app.downloadURL||versions[0]?.downloadURL))errors.push(prefix+'رابط التنزيل يجب أن يكون HTTPS.');
        if(typeof (app.version||versions[0]?.version)!=='string')errors.push(prefix+'الإصدار مطلوب.');
        if(app.iconURL&&!httpsUrl(app.iconURL))errors.push(prefix+'رابط الأيقونة يجب أن يكون HTTPS.');
        if(app.size!==undefined&&(!Number.isSafeInteger(app.size)||app.size<0))errors.push(prefix+'الحجم بالبايت غير صالح.');
        for(const version of versions)if(!isObject(version)||!String(version.version||'').trim()||!httpsUrl(version.downloadURL)) {errors.push(prefix+'أحد الإصدارات له بيانات أو رابط غير صالح.');break;}
        if(app.catalogID){if(catalogs.has(app.catalogID))errors.push(prefix+'catalogID مكرر.');catalogs.add(app.catalogID);}
      });
      data.news.forEach((item,i)=>{if(typeof item.title!=='string'||!item.title.trim())errors.push('عنوان الخبر '+(i+1)+' مفقود.');if(item.url&&!httpsUrl(item.url))errors.push('رابط الخبر '+(i+1)+' يجب أن يكون HTTPS.');});
      return errors;
    }
    function getPath(target,path){return path.split('.').reduce((obj,key)=>obj?.[key],target);}
    function setPath(target,path,value){const keys=path.split('.');let node=target;for(const key of keys.slice(0,-1))node=node[key];node[keys.at(-1)]=value;}
    let state=normalizeState(createDefaultState());
    let connection={owner:'ipablack',repo:'repo',branch:'main',path:'repo.json'};
    let activePage='overview', appPage=1, editingApp=null, editingNews=null, editingCategory=null;
    let activity=[],baseline='',remoteBaseline=null,lastPublishedAt=null,operationBusy=false,pendingPublish=null,storageError=false;
    let saveTimer=null,previewAnimation=null;
    const PAGE_META={
      overview:['نظرة عامة','YOUR WORKSPACE, AT A GLANCE','كل ما تحتاجه لإدارة X-SIGN، في مساحة واحدة.'],
      apps:['مكتبة التطبيقات','YOUR APPS, PERFECTLY ORGANIZED','أضف تطبيقاتك وأدر تفاصيلها وإصداراتها بسهولة.'],
      sources:['المصادر والاتصال','CONNECTED TO YOUR WORKFLOW','مصادرك المعتمدة ووجهة النشر، من مكان واحد.'],
      appearance:['المظهر والإقلاع','MAKE IT DISTINCTLY YOURS','هوية X-SIGN، بالتفاصيل التي تختارها.'],
      controls:['التحكم والحماية','EVERY DETAIL, UNDER CONTROL','اضبط الصلاحيات وحالة التطبيق ورسائل المستخدمين.'],
      editorial:['الأخبار والتصنيفات','CONTENT WITH A CLEAR PURPOSE','أبقِ محتواك واضحاً، منظماً، ومحدثاً.'],
      publish:['المراجعة والنشر','READY WHEN YOU ARE','راجع ملف التكوين، ثم انشره بثقة إلى مستودعك.']
    };
    function toast(message,variant='success') {
      const el=text('div','', 'toast '+variant);el.setAttribute('role',variant==='error'?'alert':'status');
      el.append(icon(variant==='success'?'check':'info'),text('span',message));
      const close=button('',()=>el.remove(),'close','');close.setAttribute('aria-label','إغلاق الإشعار');el.append(close);
      $('toasts').append(el);while($('toasts').children.length>4)$('toasts').firstElementChild.remove();
      setTimeout(()=>el.remove(),6500);
    }
    function confirmAction(title,message,action,label='تأكيد',danger=true) {
      $('confirmTitle').textContent=title;$('confirmMessage').textContent=message;
      $('confirmAction').textContent=label;$('confirmAction').className=danger?'btn btn-danger':'btn btn-primary';
      $('confirmAction').onclick=()=>{$('confirmDialog').close();action();};$('confirmDialog').showModal();
    }
    function setMenu(open){$('sidebar').classList.toggle('open',open);$('mobileBackdrop').classList.toggle('open',open);$('menuButton').setAttribute('aria-expanded',String(open));if(open)$('sidebar').querySelector('.nav-btn.active').focus();}
    function openPage(name, updateHash=true) {
      if(!PAGE_META[name])name='overview';activePage=name;
      $$('[data-panel]').forEach(el=>el.hidden=el.dataset.panel!==name);
      $$('[data-page]').forEach(el=>{const selected=el.dataset.page===name;el.classList.toggle('active',selected);if(selected)el.setAttribute('aria-current','page');else el.removeAttribute('aria-current');});
      const [title,eyebrow,description]=PAGE_META[name];$('pageTitle').textContent=title;$('breadcrumbCurrent').textContent=title;$('pageEyebrow').textContent=eyebrow;$('pageDescription').textContent=description;
      const actions=$('pageActions');actions.replaceChildren();
      if(name==='apps'){actions.append(button('رفع IPA',()=>openPage('ingest'),'download','btn'));actions.append(button('إضافة تطبيق',()=>openAppEditor(),'plus','btn btn-primary'));}
      else if(name==='sources')actions.append(button('جلب الملف الحي',requestPull,'refresh','btn'));
      else if(name==='publish')actions.append(button('استيراد',()=>$('importFile').click(),'download','btn'));
      else {const badge=text('span','', 'tag '+(isDirty()?'tag-yellow':'tag-green'));const dot=text('span','', 'dot');badge.append(dot,document.createTextNode(isDirty()?'مسودة محلية':'مساحة العمل جاهزة'));actions.append(badge);}
      if(name==='apps')renderApps();if(name==='editorial')renderEditorial();if(name==='publish')renderPublish();if(name==='appearance')renderPreview(true);if(name==='ingest')renderIngestContext();if(name==='operations')renderRuns();$$('.mobile-dock [data-go]').forEach(b=>b.classList.toggle('active',b.dataset.go===name));
      if(name!=='appearance'&&previewAnimation)previewAnimation.cancel();
      setMenu(false);if(updateHash&&location.hash!=='#'+name)history.replaceState(null,'','#'+name);window.scrollTo({top:0,behavior:'instant'});
    }
    function isDirty(){return JSON.stringify(state)!==baseline;}
    function addActivity(label){activity.unshift({label,at:new Date().toISOString()});activity=activity.slice(0,5);}
    function persist() {
      clearTimeout(saveTimer);saveTimer=null;enforceCoreSources(state);
      try{localStorage.setItem(STORAGE_KEY,JSON.stringify(state));localStorage.setItem(META_KEY,JSON.stringify({connection,activity,lastPublishedAt}));storageError=false;}
      catch{if(!storageError)toast('تعذر الحفظ على هذا الجهاز. نزّل repo.json للاحتفاظ بتعديلاتك.','error');storageError=true;}
      updateStatus();
    }
    function loadLocal() {
      try {
        const raw=localStorage.getItem(STORAGE_KEY)||localStorage.getItem(LEGACY_STORAGE_KEY);
        if(raw)state=normalizeState(JSON.parse(raw));
        const metaRaw=localStorage.getItem(META_KEY);
        if(metaRaw){const meta=JSON.parse(metaRaw);if(isObject(meta.connection)){for(const key of Object.keys(connection))if(typeof meta.connection[key]==='string')connection[key]=meta.connection[key];}if(Array.isArray(meta.activity))activity=meta.activity.filter(item=>typeof item.label==='string'&&typeof item.at==='string').slice(0,5);lastPublishedAt=typeof meta.lastPublishedAt==='string'?meta.lastPublishedAt:null;}
      }catch{toast('تعذر استعادة المسودة المحفوظة. احتفظ بنسختك السابقة واستوردها مجدداً.','error');}
      baseline=JSON.stringify(normalizeState(createDefaultState()));
    }
    function mutate(action,label,bump=true) {
      const before=JSON.stringify(state);action();enforceCoreSources(state);
      if(JSON.stringify(state)===before)return;
      if(bump)state.repo_revision_id=safeInteger(state.repo_revision_id)+1;
      if(label)addActivity(label);persist();renderOverview();
      if(activePage==='apps')renderApps();if(activePage==='editorial')renderEditorial();if(activePage==='publish')renderPublish();
    }
    function updateStatus() {
      const dirty=isDirty();$('navAppsCount').textContent=state.apps.length;$('navDirtyBadge').hidden=!dirty;
      $('saveIndicator').classList.toggle('unsaved',dirty||storageError);
      $('saveIndicatorText').textContent=storageError?'تعذر الحفظ على الجهاز':dirty?'مسودة محفوظة على الجهاز':remoteBaseline?'الملف مطابق لآخر مزامنة':'مسودة جاهزة على الجهاز';
      $$('[data-action="prepare-publish"]').forEach(b=>b.disabled=operationBusy);
      $$('[data-action="pull"]').forEach(b=>b.disabled=operationBusy);
      if(!['apps','sources','publish'].includes(activePage)){
        const badge=$('pageActions').querySelector('.tag');if(badge){badge.className='tag '+(dirty?'tag-yellow':'tag-green');badge.replaceChildren(text('span','','dot'),document.createTextNode(dirty?'مسودة محلية':'مساحة العمل جاهزة'));}
      }
    }
    function renderOverview() {
      $('statApps').textContent=padded(state.apps.length);$('statRevision').textContent=padded(state.repo_revision_id);
      const maintenance=state.xsign_config.maintenance.enabled;
      $('statMaintenance').textContent=maintenance?'قيد الصيانة':'متاح';$('statMaintenance').style.color=maintenance?'var(--yellow)':'';
      $('statMaintenanceNote').textContent=maintenance?'الصيانة مفعّلة في التكوين':'الصيانة غير مفعّلة في التكوين';
      $('statPublishStatus').textContent=lastPublishedAt?'آخر نشر: '+formatTime(lastPublishedAt):'لم يُسجل نشر من هذه الصفحة';
      $('overviewTarget').textContent=connection.owner+' / '+connection.repo;$('overviewBranch').textContent=connection.branch+' · '+connection.path;
      $('overviewConnection').textContent=remoteBaseline&&remoteBaseline.key===connectionKey()?'تمت المزامنة':'لم يتم الاتصال';
      const theme=state.xsign_config.theme, splash=state.xsign_config.splash_screen;
      const color=(v,f)=>/^#[0-9a-f]{6}$/i.test(v)?v:f;
      $('overviewPhone').style.background='linear-gradient(180deg,'+color(theme.splash_bg_top_hex,'#000000')+','+color(theme.splash_bg_bottom_hex,'#000000')+')';
      $('overviewLogo').style.color=color(theme.splash_logo_hex,'#FFFFFF');$('overviewSign').style.color=color(theme.splash_logo_hex,'#FFFFFF');$('overviewSign').hidden=splash.show_sign_feather===false;$('overviewSubtitle').textContent=typeof splash.subtitle==='string'?splash.subtitle:'';
      const box=$('activityList');box.replaceChildren();
      if(!activity.length)box.append(text('p','لم تُجرِ أي تغييرات بعد. ابدأ من القسم الذي تحتاجه.','empty-activity'));
      else activity.forEach(item=>{const row=text('div','','activity-line');const symbol=text('div','','activity-dot');symbol.append(icon('check'));row.append(symbol,text('p',item.label),text('time',formatTime(item.at)));box.append(row);});
    }
    function formatTime(date){try{return new Intl.DateTimeFormat('ar-IQ',{timeZone:'Asia/Baghdad',hour:'2-digit',minute:'2-digit',hour12:true}).format(new Date(date));}catch{return '—';}}
    function syncInputs() {
      $$('[data-path]').forEach(el=>{const value=getPath(state,el.dataset.path);if(el.type==='checkbox')el.checked=value===true;else if(el.type==='color')el.value=/^#[0-9a-f]{6}$/i.test(value)?value:'#000000';else el.value=typeof value==='string'||typeof value==='number'?value:'';});
      $$('[data-connection]').forEach(el=>el.value=connection[el.dataset.connection]);
      updateAppearanceControls();renderCategoryOptions();renderCounters();renderTargetWarning();
    }
    function renderCounters(){$('cacheFlushValue').textContent=state.xsign_config.app_control.cache_flush_id;$('purgeSourcesValue').textContent=state.xsign_config.app_control.purge_sources_id;}
    function renderCategoryOptions() {
      for(const id of ['appCategory','categoryFilter']){
        const select=$(id),old=select.value;select.replaceChildren();
        const empty=text('option',id==='categoryFilter'?'كل التصنيفات':'دون تصنيف');empty.value='';select.append(empty);
        state.categories.forEach(cat=>{const option=text('option',cat.name||cat.id||'تصنيف');option.value=String(cat.id||'');select.append(option);});
        if([...select.options].some(opt=>opt.value===old))select.value=old;
      }
    }
    function renderAll(){syncInputs();renderOverview();if(activePage==='apps')renderApps();if(activePage==='editorial')renderEditorial();if(activePage==='publish')renderPublish();if(activePage==='appearance')renderPreview(true);updateStatus();}
    function fieldInput(el, final=false) {
      let value=el.type==='checkbox'?el.checked:el.value;
      if(el.dataset.number) {
        const [min,max,fallback]=el.dataset.number.split(',').map(Number),num=Number(value);
        if(!final&&(value===''||!Number.isFinite(num)||num<min||num>max))return;
        value=Number.isFinite(num)&&value!==''?Math.min(max,Math.max(min,num)):fallback;
        if(final)el.value=String(value);
      }
      const path=el.dataset.path;
      if(getPath(state,path)===value)return;
      setPath(state,path,value);
      if(path==='xsign_config.theme.app_tint_hex')state.tintColor=value;
      if(path.startsWith('xsign_config.theme.')||path.startsWith('xsign_config.splash_screen.')){
        updateAppearanceControls();if(activePage==='appearance')renderPreview(path!=='xsign_config.splash_screen.custom_code');
      }
      renderOverview();updateStatus();if(activePage==='publish')renderPublish();
      clearTimeout(saveTimer);saveTimer=setTimeout(persist,260);
    }
    function updateAppearanceControls() {
      $$('[data-color-label]').forEach(el=>el.textContent=$(el.dataset.colorLabel).value.toUpperCase());
      const splash=state.xsign_config.splash_screen;
      $('durationBadge').textContent=splash.duration_seconds;
      $('vectorControls').hidden=splash.engine==='custom_css';$('customControls').hidden=splash.engine!=='custom_css';
      $$('[data-style]').forEach(btn=>{const selected=btn.dataset.style===splash.animation_style;btn.classList.toggle('active',selected);btn.setAttribute('aria-pressed',String(selected));});
    }
    const logoMarkup='<svg class="splash-logo" viewBox="0 0 100 100" aria-hidden="true"><polygon class="rib rib-first" points="31.57,19.61 44.31,19.61 48.63,27.25 63.73,5.69 48.63,31.76 42.75,21.96 35.29,21.96 43.73,38.24 25.49,69.41 41.57,38.24"/><polygon class="rib rib-second" points="74.51,5.69 57.65,39.61 67.45,57.45 53.53,57.45 50,50.20 35.88,69.80 50.20,45.49 55.29,54.71 63.53,54.71 54.71,39.61"/><g class="sign-group"><text x="45" y="83" font-family="Georgia,serif" font-style="italic" font-size="16" text-anchor="middle">Sign</text><path d="M60.4 81.2C62.5 78.2 66.5 78.5 72.5 76C70.2 77 68.6 77.2 66.8 77C70.8 75.2 73.8 72.5 74.6 67.2C72.2 71.5 68.8 73.2 64.6 74.5C67.2 72.8 69.5 71.2 70.4 69.2C67.4 71.8 64.2 72.6 62.2 75.2C61.2 76.5 60.2 79.5 59.4 81.6Z"/></g></svg>';
    function renderPreview(replay=true) {
      const cfg=state.xsign_config,sp=cfg.splash_screen,theme=cfg.theme,stage=$('splashStage'),frame=$('customFrame');
      const color=(v,f)=>/^#[0-9a-f]{6}$/i.test(v)?v:f;
      const seconds=typeof sp.duration_seconds==='number'?sp.duration_seconds:3.2;
      stage.style.background='linear-gradient(180deg,'+color(theme.splash_bg_top_hex,'#000000')+','+color(theme.splash_bg_bottom_hex,'#000000')+')';
      stage.style.setProperty('--dur',seconds+'s');stage.style.setProperty('--logo',color(theme.splash_logo_hex,'#FFFFFF'));
      stage.style.setProperty('--glow',(Number(sp.glow_radius)||0)*.7+'px');stage.style.setProperty('--stroke',String((Number(sp.stroke_width)||2)/4));
      frame.hidden=sp.engine!=='custom_css';stage.hidden=sp.engine==='custom_css';
      if(sp.engine==='custom_css'){
        // The sandbox has no capabilities; CSP also blocks scripts and requests.
        const source='<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;; img-src data:; font-src data:; base-uri &#39;none&#39;; form-action &#39;none&#39;"><meta name="referrer" content="no-referrer"><style>html,body{margin:0;min-height:100%;background:#000;color:white;overflow:hidden}</style></head><body>'+String(sp.custom_code||'')+'<\/body><\/html>';
        if(frame.srcdoc!==source||replay)frame.srcdoc=source;
      }else{
        if(replay||!stage.firstChild){stage.innerHTML=logoMarkup;stage.append(text('div',sp.subtitle,'splash-subtitle'));}
        else stage.querySelector('.splash-subtitle').textContent=sp.subtitle;
        const svg=stage.querySelector('.splash-logo');const size=(Number(sp.size_px)||225)*.72;svg.style.width=size+'px';svg.style.height=size+'px';svg.querySelector('.sign-group').style.display=sp.show_sign_feather===false?'none':'';
        stage.className='splash-stage '+(replay?sp.animation_style:'');
      }
      $('previewStyleLabel').textContent=sp.engine==='custom_css'?'CUSTOM HTML / CSS':String(sp.animation_style).replaceAll('_',' ').toUpperCase();
      $('previewDurationText').textContent=seconds+' seconds';
      if(previewAnimation)previewAnimation.cancel();
      const progress=$('previewProgress');progress.style.width=replay?'0':'100%';
      if(replay&&activePage==='appearance'&&progress.animate)previewAnimation=progress.animate([{width:'0%'},{width:'100%'}],{duration:seconds*1000,fill:'forwards',easing:'linear'});
    }
    function bytes(value){if(!Number.isFinite(Number(value))||Number(value)<=0)return '—';const units=['B','KB','MB','GB'];const power=Math.min(3,Math.floor(Math.log(Number(value))/Math.log(1024)));return (Number(value)/1024**power).toFixed(power<2?0:1)+' '+units[power];}
    function categoryName(id){return state.categories.find(cat=>cat.id===id)?.name||id||'دون تصنيف';}
    function renderApps() {
      const query=$('appSearch').value.trim().toLocaleLowerCase(),cat=$('categoryFilter').value;
      const filtered=state.apps.filter(app=>(!cat||app.category===cat)&&(!query||[app.name,app.bundleIdentifier,app.category].some(value=>String(value||'').toLocaleLowerCase().includes(query))));
      const pages=Math.max(1,Math.ceil(filtered.length/PAGE_SIZE));appPage=Math.min(pages,Math.max(1,appPage));
      $('appsTotal').textContent=state.apps.length;$('appsResultText').textContent=filtered.length+' من '+state.apps.length+' تطبيق';$('pageNumber').textContent=appPage+' / '+pages;
      $('previousPage').disabled=appPage<=1;$('nextPage').disabled=appPage>=pages;
      const box=$('appsList');box.replaceChildren();
      if(!filtered.length){const empty=text('div','','empty'),symbol=text('div','','empty-symbol');symbol.append(icon(query||cat?'search':'apps'));empty.append(symbol,text('h3',query||cat?'لا توجد نتائج مطابقة':'مكتبتك تبدأ بتطبيق واحد.'),text('p',query||cat?'جرّب اسماً آخر أو اختر جميع التصنيفات.':'أضف أول تطبيق إلى IPA BLACK، وحدد إصداره ورابطه. ستجد كل تطبيقاتك هنا مرتبة وجاهزة للإدارة.'));if(!query&&!cat)empty.append(button('إضافة أول تطبيق',()=>openAppEditor(),'plus','btn btn-primary'));box.append(empty);return;}
      const fragment=document.createDocumentFragment();
      filtered.slice((appPage-1)*PAGE_SIZE,appPage*PAGE_SIZE).forEach(app=>{
        const row=text('div','','app-row'),identity=text('div','','app-identity'),appIcon=text('div',String(app.name||'A').charAt(0).toUpperCase(),'app-icon');
        const src=httpImage(app.iconURL);if(src){const img=document.createElement('img');img.src=src;img.alt='';img.loading='lazy';img.referrerPolicy='no-referrer';img.addEventListener('error',()=>img.remove(),{once:true});appIcon.append(img);}
        const info=text('div','');info.style.minWidth='0';info.append(text('h3',app.name||'دون اسم'),text('p',app.bundleIdentifier||'—'));
        identity.append(appIcon,info);row.append(identity,text('div',categoryName(app.category),'app-cell app-category-cell'),text('div','v'+(app.version||app.versions?.[0]?.version||'—'),'app-cell latin app-version-cell'),text('div',bytes(app.size||app.versions?.[0]?.size),'app-cell latin app-size-cell'));
        const actions=text('div','','app-actions');const edit=button('',()=>openAppEditor(app),'edit'),del=button('',()=>deleteApp(app),'trash');edit.setAttribute('aria-label','تعديل '+app.name);edit.title='تعديل';del.setAttribute('aria-label','حذف '+app.name);del.title='حذف';actions.append(edit,del);row.append(actions);fragment.append(row);
      });box.append(fragment);
    }
    function openAppEditor(app=null) {
      editingApp=app;$('appForm').reset();$('appFormError').hidden=true;
      $('appDialogTitle').textContent=app?'تعديل التطبيق':'إضافة تطبيق';renderCategoryOptions();
      const values={appName:'name',appBundle:'bundleIdentifier',appVersion:'version',appDownload:'downloadURL',appIcon:'iconURL',appSize:'size',appDeveloper:'developerName',appSubtitle:'subtitle',appDescription:'localizedDescription',appCategory:'category'};
      for(const [id,key] of Object.entries(values)){
        let value=app?.[key]??'';if(app&&['version','downloadURL','size'].includes(key)&&!value)value=app.versions?.[0]?.[key]??'';
        if(id==='appCategory'&&value&&![...$(id).options].some(opt=>opt.value===value)){const option=text('option',String(value));option.value=String(value);$(id).append(option);}
        $(id).value=typeof value==='string'||typeof value==='number'?value:'';
      }
      if(!app){$('appDeveloper').value='IPA BLACK';$('appCategory').value=state.categories[0]?.id||'';}
      $('appSkipLookup').checked=app?.skipAppStoreLookup===true;
      const count=Array.isArray(app?.versions)?app.versions.length:0;$('appVersionsInfo').hidden=!count;$('appVersionsInfo').textContent=count+' إصدار محفوظ. إضافة إصدار جديد تحتفظ بالإصدارات السابقة وحقول التطبيق الإضافية.';
      $('appDialog').showModal();
    }
    function saveApp(event) {
      event.preventDefault();
      const name=$('appName').value.trim(),bundleIdentifier=$('appBundle').value.trim(),version=$('appVersion').value.trim(),downloadURL=$('appDownload').value.trim(),iconURL=$('appIcon').value.trim(),sizeRaw=$('appSize').value.trim();
      let error='';
      if(!name||!bundleIdentifier||!version||!downloadURL)error='أكمل الاسم ومعرف الحزمة والإصدار ورابط التنزيل.';
      else if(!/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(bundleIdentifier))error='معرف الحزمة يجب أن يكون مثل com.example.app.';
      else if(!httpsUrl(downloadURL))error='رابط تنزيل IPA يجب أن يبدأ بـ https:// ويكون رابطاً صالحاً.';
      else if(iconURL&&!httpsUrl(iconURL))error='رابط الأيقونة يجب أن يكون HTTPS.';
      else if(sizeRaw&&(!Number.isSafeInteger(Number(sizeRaw))||Number(sizeRaw)<0))error='الحجم يجب أن يكون عدداً صحيحاً غير سالب بالبايت.';
      else if(state.apps.some(app=>app!==editingApp&&app.bundleIdentifier===bundleIdentifier&&String(app.name).toLocaleLowerCase()===name.toLocaleLowerCase()))error='يوجد تطبيق بالاسم ومعرف الحزمة نفسيهما. عدّل التطبيق الموجود.';
      if(error){$('appFormError').textContent=error;$('appFormError').hidden=false;$('appFormError').scrollIntoView({block:'nearest'});return;}
      if(editingApp&&!state.apps.includes(editingApp)){toast('تغيرت القائمة. أعد فتح التطبيق المطلوب.','error');$('appDialog').close();return;}
      const existing=editingApp?clone(editingApp):{},versions=Array.isArray(existing.versions)?existing.versions:[],previous=versions.find(v=>v.version===version);
      const description=$('appDescription').value.trim(),subtitle=$('appSubtitle').value.trim();
      const date=previous?.date||(existing.version===version?existing.versionDate:'')||dateToday();
      const latest={...(previous||{}),version,date,downloadURL,localizedDescription:description||subtitle||name};
      if(sizeRaw!=='')latest.size=Number(sizeRaw);else delete latest.size;
      const entry={...existing,name,bundleIdentifier,catalogID:existing.catalogID||'xsign.owned.'+uid(),version,versionDate:date,downloadURL,developerName:$('appDeveloper').value.trim()||'IPA BLACK',category:$('appCategory').value,subtitle,localizedDescription:description,skipAppStoreLookup:$('appSkipLookup').checked,versions:[latest,...versions.filter(v=>v.version!==version)]};
      if(iconURL)entry.iconURL=iconURL;else delete entry.iconURL;
      if(sizeRaw!=='')entry.size=Number(sizeRaw);else delete entry.size;
      const edit=editingApp;
      mutate(()=>{if(edit)state.apps[state.apps.indexOf(edit)]=entry;else state.apps.unshift(entry);},(edit?'تحديث التطبيق: ':'إضافة التطبيق: ')+name);
      editingApp=null;$('appDialog').close();toast(edit?'تم تحديث التطبيق مع الاحتفاظ بإصداراته وحقوله.':'تمت إضافة التطبيق إلى المسودة.');
    }
    function deleteApp(app){confirmAction('حذف التطبيق','حذف «'+String(app.name||'التطبيق')+'» من المسودة؟ يصل الحذف إلى المستودع بعد النشر.',()=>{mutate(()=>{const index=state.apps.indexOf(app);if(index>=0)state.apps.splice(index,1);},'حذف التطبيق: '+app.name);toast('تم حذف التطبيق من المسودة.');},'حذف التطبيق');}
    function renderEditorial() {
      const newsBox=$('newsList');newsBox.replaceChildren();
      if(!state.news.length){const empty=text('div','','empty');empty.style.minHeight='235px';const symbol=text('div','','empty-symbol');symbol.append(icon('news'));empty.append(symbol,text('h3','قصص جديدة لمستخدمينك.'),text('p','أضف أخبار التطبيقات والتنبيهات المهمة لتظهر ضمن محتوى المستودع.'));newsBox.append(empty);}
      state.news.forEach(item=>{
        const row=text('div','','editorial-row'),info=text('div','');info.style.minWidth='0';info.append(text('strong',item.title||'دون عنوان'),text('p',item.caption||''));
        const actions=text('div','','row'),edit=button('',()=>openNewsEditor(item),'edit'),del=button('',()=>confirmAction('حذف الخبر','حذف «'+item.title+'» من المسودة؟',()=>mutate(()=>{const index=state.news.indexOf(item);if(index>=0)state.news.splice(index,1);},'حذف بطاقة خبر')),'trash');
        edit.setAttribute('aria-label','تعديل الخبر '+item.title);del.setAttribute('aria-label','حذف الخبر '+item.title);actions.append(edit,del);row.append(info,actions);newsBox.append(row);
      });
      $('categoriesCount').textContent=state.categories.length;const catBox=$('categoriesList');catBox.replaceChildren();
      state.categories.forEach(cat=>{
        const row=text('div','','editorial-row'),info=text('div','');info.append(text('strong',cat.name),text('p',cat.id+(cat.isGame?' · ألعاب':''),'mono'));
        const actions=text('div','','row'),edit=button('',()=>editCategory(cat),'edit'),del=button('',()=>deleteCategory(cat),'trash');edit.setAttribute('aria-label','تعديل التصنيف '+cat.name);del.setAttribute('aria-label','حذف التصنيف '+cat.name);actions.append(edit,del);row.append(info,actions);catBox.append(row);
      });
    }
    function openNewsEditor(item=null){editingNews=item;$('newsForm').reset();$('newsFormError').hidden=true;$('newsDialogTitle').textContent=item?'تعديل بطاقة خبر':'إضافة بطاقة خبر';for(const [id,key] of Object.entries({newsTitle:'title',newsCaption:'caption',newsUrl:'url',newsAppId:'appID'}))$(id).value=item?.[key]||'';$('newsDialog').showModal();}
    function saveNews(event) {
      event.preventDefault();const title=$('newsTitle').value.trim(),url=$('newsUrl').value.trim();
      if(!title||!httpsUrl(url,true)){$('newsFormError').textContent=!title?'عنوان الخبر مطلوب.':'رابط الخبر يجب أن يكون HTTPS.';$('newsFormError').hidden=false;return;}
      const existing=editingNews,entry={...(existing||{}),identifier:existing?.identifier||'news_'+uid(),title,caption:$('newsCaption').value.trim()||title,date:existing?.date||dateToday(),notify:existing?.notify??true};
      if(url)entry.url=url;else delete entry.url;const appID=$('newsAppId').value.trim();if(appID)entry.appID=appID;else delete entry.appID;
      mutate(()=>{if(existing&&state.news.includes(existing))state.news[state.news.indexOf(existing)]=entry;else state.news.unshift(entry);},existing?'تحديث بطاقة خبر':'إضافة بطاقة خبر');$('newsDialog').close();editingNews=null;toast('تم حفظ بطاقة الخبر.');
    }
    function editCategory(cat){editingCategory=cat;$('categoryId').value=cat.id;$('categoryName').value=cat.name;$('categoryIsGame').checked=cat.isGame===true;$('cancelCategoryEdit').hidden=false;$('categoryName').focus();}
    function resetCategoryEditor(){editingCategory=null;$('categoryForm').reset();$('cancelCategoryEdit').hidden=true;}
    function saveCategory(event) {
      event.preventDefault();const id=$('categoryId').value.trim().toLowerCase(),name=$('categoryName').value.trim(),isGame=$('categoryIsGame').checked;
      if(!/^[a-z0-9_-]+$/.test(id)||!name){toast('أدخل اسماً ومعرفاً إنجليزياً صالحاً للتصنيف.','error');return;}
      const duplicate=state.categories.find(cat=>cat.id===id);
      if(editingCategory&&duplicate&&duplicate!==editingCategory){toast('هذا المعرف مستخدم لتصنيف آخر.','error');return;}
      const old=editingCategory||duplicate,entry={...(old||{}),id,name,isGame};
      mutate(()=>{if(old){state.categories[state.categories.indexOf(old)]=entry;if(old.id!==id)state.apps.forEach(app=>{if(app.category===old.id)app.category=id;});}else state.categories.push(entry);},'حفظ التصنيف: '+name);
      resetCategoryEditor();renderCategoryOptions();toast('تم حفظ التصنيف.');
    }
    function deleteCategory(cat) {
      const used=state.apps.filter(app=>app.category===cat.id).length;
      if(used){toast('التصنيف مستخدم في '+used+' تطبيق. غيّر تصنيفها أولاً ثم احذفه.','error');return;}
      confirmAction('حذف التصنيف','حذف تصنيف «'+cat.name+'» من المسودة؟',()=>{mutate(()=>{const index=state.categories.indexOf(cat);if(index>=0)state.categories.splice(index,1);},'حذف التصنيف: '+cat.name);if(editingCategory===cat)resetCategoryEditor();renderCategoryOptions();});
    }
    function readinessRow(label,ok) {const row=text('div','','checkline'),left=text('div','','row');left.append(icon(ok?'check':'info'),text('span',label));left.firstChild.classList.add(ok?'check-ok':'check-bad');row.append(left,text('span',ok?'جاهز':'يحتاج مراجعة','tiny '+(ok?'muted':'')));return row;}
    function renderPublish() {
      const json=JSON.stringify(state,null,2),errors=validateState(state);$('jsonPreview').textContent=json;$('jsonSize').textContent=bytes(new TextEncoder().encode(json).length);
      $('validationBadge').textContent=errors.length?'يحتاج مراجعة':'صالح';$('validationBadge').className='tag '+(errors.length?'tag-yellow':'tag-green');
      $('validationSummary').replaceChildren(readinessRow('بنية JSON والتكوين',!errors.length),readinessRow('المصادر حسب إعداداتك',Array.isArray(state.xsign_config.app_control.core_sources)),readinessRow('بيانات التطبيقات',!errors.some(e=>e.startsWith('التطبيق '))));
      $('validationErrors').replaceChildren(...errors.slice(0,15).map(e=>text('li',e)));if(errors.length>15)$('validationErrors').append(text('li','و '+(errors.length-15)+' ملاحظة أخرى.'));
      $('reviewTarget').textContent=connection.owner+'/'+connection.repo;$('reviewBranch').textContent=connection.branch;$('reviewRevision').textContent=state.repo_revision_id;$('lastPublish').textContent=lastPublishedAt?formatTime(lastPublishedAt):'—';
    }
    function connectionKey(c=connection){return [c.owner,c.repo,c.branch,c.path].join('/');}
    function validateConnection(c) {
      if(!/^[A-Za-z0-9-]+$/.test(c.owner)||!/^[A-Za-z0-9_.-]+$/.test(c.repo))throw new Error('أدخل حساب GitHub واسم المستودع بشكل صالح.');
      if(!c.branch||/[\x00-\x20?*\[\\~^:]/.test(c.branch)||c.branch.includes('..'))throw new Error('اسم فرع GitHub غير صالح.');
      if(!c.path||c.path.startsWith('/')||c.path.split('/').some(p=>!p||p==='.'||p==='..')||/[\x00-\x1f]/.test(c.path))throw new Error('مسار الملف داخل المستودع غير صالح.');
      return c;
    }
    function renderTargetWarning() {
      const differs=connectionKey()!=='ipablack/repo/main/repo.json';$('targetWarning').hidden=!differs;
      if(differs)$('targetWarning').textContent='وجهة النشر مختلفة عن مصدر المالك المعتمد. تغييرها هنا لا يغيّر رابط المصدر الذي يقرأه التطبيق.';
      $('reviewTarget').textContent=connection.owner+'/'+connection.repo;$('reviewBranch').textContent=connection.branch;
    }
    async function fetchTimed(url,options={}) {
      const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20000);
      try{return await fetch(url,{...options,signal:controller.signal,cache:'no-store',credentials:'omit',referrerPolicy:'no-referrer',redirect:'error'});}
      catch(error){if(error.name==='AbortError')throw new Error('انتهت مهلة الاتصال. حاول مجدداً.');throw new Error('تعذر الاتصال. تحقق من الشبكة، وقد يمنع الخادم طلبات المتصفح (CORS).');}
      finally{clearTimeout(timer);}
    }
    function apiBase(c){return 'https://api.github.com/repos/'+encodeURIComponent(c.owner)+'/'+encodeURIComponent(c.repo);}
    function contentsUrl(c){return apiBase(c)+'/contents/'+c.path.split('/').map(encodeURIComponent).join('/');}
    function apiHeaders(token,raw=false){const h={Accept:raw?'application/vnd.github.raw+json':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28'};if(token)h.Authorization='Bearer '+token;return h;}
    function decodeBase64(value){const binary=atob(value.replace(/\s/g,''));return new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(binary,c=>c.charCodeAt(0)));}
    function encodeBase64(value){const bytes=new TextEncoder().encode(value);let binary='';for(let index=0;index<bytes.length;index+=16384)binary+=String.fromCharCode(...bytes.subarray(index,index+16384));return btoa(binary);}
    async function apiError(response,verb) {
      const explanations={401:'رمز الوصول غير صالح أو منتهي.',403:'لا توجد صلاحية كافية، أو تم تجاوز حد GitHub.',404:'المستودع أو الفرع أو الملف غير موجود، أو لا تملك صلاحية قراءته.',409:'تغير الملف على GitHub أثناء العمل. اجلب النسخة الحية ثم أعد المحاولة.',422:'رفض GitHub البيانات. تحقق من الفرع وصلاحية الملف وحدود النشر.'};
      return new Error(verb+' (HTTP '+response.status+'). '+(explanations[response.status]||'حاول مجدداً بعد التحقق من إعدادات الاتصال.'));
    }
    async function readRemote(c,token,allowMissing=false) {
      const endpoint=contentsUrl(c)+'?ref='+encodeURIComponent(c.branch),headers=apiHeaders(token);
      const response=await fetchTimed(endpoint,{headers});
      if(response.status===404&&allowMissing){
        // Verify access and branch before interpreting 404 as a new file.
        const repoRes=await fetchTimed(apiBase(c),{headers});if(!repoRes.ok)throw await apiError(repoRes,'تعذر الوصول إلى المستودع');
        const branchRes=await fetchTimed(apiBase(c)+'/branches/'+encodeURIComponent(c.branch),{headers});if(!branchRes.ok)throw await apiError(branchRes,'تعذر الوصول إلى الفرع');
        return {sha:null,parsed:null,missing:true};
      }
      if(!response.ok)throw await apiError(response,'تعذرت قراءة الملف');
      const meta=await response.json();if(!isObject(meta)||meta.type!=='file'||!meta.sha)throw new Error('المسار المختار ليس ملفاً عادياً.');
      let content='';
      if(meta.encoding==='base64'&&typeof meta.content==='string')content=decodeBase64(meta.content);
      else {const raw=await fetchTimed(endpoint,{headers:apiHeaders(token,true)});if(!raw.ok)throw await apiError(raw,'تعذرت قراءة محتوى الملف');content=await raw.text();}
      if(new TextEncoder().encode(content).length>15*1024*1024)throw new Error('الملف الحي أكبر من 15 MB.');
      let parsed=null,parseError='';
      try{parsed=JSON.parse(content.replace(/^\uFEFF/,''));}catch{parseError=content.trim()?'الملف الحي ليس JSON صالحاً.':'الملف الحي فارغ.';}
      return {sha:meta.sha,parsed,parseError,missing:false};
    }
    async function requestPull() {
      if(operationBusy)return;
      const proceed=async()=>{
        operationBusy=true;updateStatus();
        try {
          const c=validateConnection({...connection}),token=$('ghToken').value.trim(),remote=await readRemote(c,token);
          if(remote.parseError)throw new Error(remote.parseError+' لم تتغير مسودتك.');
          const next=normalizeState(remote.parsed);state=next;baseline=JSON.stringify(next);remoteBaseline={key:connectionKey(c),sha:remote.sha};appPage=1;
          addActivity('جلب repo.json من GitHub');persist();resetCategoryEditor();renderAll();toast('تم جلب النسخة الحية وحفظها على الجهاز.');
        }catch(error){toast(error.message,'error');}finally{operationBusy=false;updateStatus();}
      };
      if(isDirty())confirmAction('جلب النسخة الحية','سيستبدل الجلب المسودة المحلية بمحتوى GitHub. يمكنك تنزيل المسودة أولاً من زر التصدير.',proceed,'جلب واستبدال',false);else await proceed();
    }
    async function preparePublish() {
      if(operationBusy)return;
      const errors=validateState(state);if(errors.length){openPage('publish');toast('راجع ملاحظات الملف قبل النشر.','error');return;}
      const token=$('ghToken').value.trim();
      if(!token){openPage('sources');$('ghToken').focus();toast('أدخل رمز GitHub في إعدادات الاتصال أولاً.','info');return;}
      operationBusy=true;updateStatus();
      try {
        const c=validateConnection({...connection}),remote=await readRemote(c,token,true);
        if(remoteBaseline?.key===connectionKey(c)&&remoteBaseline.sha!==remote.sha)throw new Error('تغير الملف على GitHub منذ آخر مزامنة. نزّل مسودتك ثم اجلب النسخة الحية قبل النشر.');
        const snapshot=clone(state);snapshot.repo_revision_id=Math.max(safeInteger(state.repo_revision_id),safeInteger(remote.parsed?.repo_revision_id,0))+1;
        pendingPublish={connection:c,snapshot,sha:remote.sha,localAtReview:JSON.stringify(state)};
        const review=$('publishReview');review.replaceChildren();
        for(const [label,value] of [['المستودع',c.owner+'/'+c.repo],['الفرع',c.branch],['الملف',c.path],['المراجعة الجديدة',snapshot.repo_revision_id],['التطبيقات',snapshot.apps.length],['الإجراء',remote.missing?'إنشاء الملف':'تحديث الملف الحالي']]){const row=text('div','','review-metric');row.append(text('span',label),text('strong',value));review.append(row);}
        const warnings=[];
        if(!remote.missing&&remoteBaseline?.key!==connectionKey(c))warnings.push('لم تُجلب النسخة الحية في هذه الجلسة. سيستبدل النشر محتوى الملف الحالي بمسودتك؛ لن يدمج محتواه تلقائياً.');
        if(remote.parseError)warnings.push(remote.parseError+' النشر سيكتب ملف JSON صالحاً بدلاً منه.');
        if(connectionKey(c)!=='ipablack/repo/main/repo.json')warnings.push('وجهة النشر مختلفة عن مصدر المالك الثابت. يلزم تحديث ربط التطبيق مستقلاً إذا أردت استخدام هذه الوجهة.');
        $('publishWarning').hidden=!warnings.length;$('publishWarning').textContent=warnings.join('\n');$('publishError').hidden=true;
        $('publishDialog').showModal();
      }catch(error){toast(error.message,'error');}finally{operationBusy=false;updateStatus();}
    }
    async function publishNow() {
      if(operationBusy||!pendingPublish)return;
      const job=pendingPublish,token=$('ghToken').value.trim();if(!token){$('publishError').textContent='أدخل رمز GitHub ثم أعد فتح مراجعة النشر.';$('publishError').hidden=false;return;}
      if(JSON.stringify(state)!==job.localAtReview){$('publishError').textContent='تغيرت المسودة بعد المراجعة. أعد فتح المراجعة قبل النشر.';$('publishError').hidden=false;return;}
      operationBusy=true;$('publishNow').disabled=true;$('publishNow').textContent='جارٍ النشر…';updateStatus();
      try {
        const body={message:'Update repo.json (revision '+job.snapshot.repo_revision_id+') via X-SIGN STUDIO',content:encodeBase64(JSON.stringify(job.snapshot,null,2)+'\n'),branch:job.connection.branch};if(job.sha)body.sha=job.sha;
        const response=await fetchTimed(contentsUrl(job.connection),{method:'PUT',headers:{...apiHeaders(token),'Content-Type':'application/json'},body:JSON.stringify(body)});
        if(!response.ok)throw await apiError(response,'تعذر نشر الملف');
        const result=await response.json();if(!result.content?.sha)throw new Error('استجاب GitHub دون معرف الملف. تحقق من المستودع قبل إعادة المحاولة.');
        remoteBaseline={key:connectionKey(job.connection),sha:result.content.sha};baseline=JSON.stringify(job.snapshot);
        if(JSON.stringify(state)===job.localAtReview)state.repo_revision_id=job.snapshot.repo_revision_id;
        lastPublishedAt=new Date().toISOString();addActivity('نشر المراجعة '+job.snapshot.repo_revision_id+' إلى GitHub');persist();renderOverview();renderPublish();$('publishDialog').close();pendingPublish=null;toast('تم نشر repo.json بنجاح · المراجعة '+job.snapshot.repo_revision_id);
      }catch(error){$('publishError').textContent=error.message;$('publishError').hidden=false;}
      finally{operationBusy=false;$('publishNow').disabled=false;$('publishNow').replaceChildren(icon('cloud'),document.createTextNode('نشر الآن'));updateStatus();}
    }
    async function testSource(kind) {
      const primary=kind==='primary',btn=$(primary?'testPrimarySource':'testOwnedSource'),status=$(primary?'primarySourceStatus':'ownedSourceStatus');btn.disabled=true;status.textContent='جارٍ فحص الاستجابة…';
      try {
        const url=primary?PRIMARY_SOURCE_URL+'?order=id.asc&limit=1&offset=0':OWNED_CANONICAL_URL+'?t='+Date.now();
        const response=await fetchTimed(url,{headers:{Accept:'application/json'}});
        if(!response.ok)throw new Error('HTTP '+response.status+(response.status===401||response.status===403?' · الخادم يطلب صلاحية قراءة.':' · لم ينجح طلب القراءة.'));
        const parsed=await response.json();
        if(primary&&!Array.isArray(parsed))throw new Error('استجاب الخادم، لكن المحتوى ليس قائمة تطبيقات.');
        if(!primary&&(!isObject(parsed)||!Array.isArray(parsed.apps)))throw new Error('الاستجابة لا تحتوي على قائمة apps صالحة.');
        status.textContent=primary?'استجابة JSON صالحة · HTTP '+response.status:'ملف صالح · '+parsed.apps.length+' تطبيق · مراجعة '+(parsed.repo_revision_id??'—');status.style.color='var(--green)';toast('نجح فحص '+(primary?'المصدر الأساسي.':'مصدر IPA BLACK.'));
      }catch(error){status.textContent=error.message;status.style.color='var(--yellow)';toast('لم يكتمل فحص المصدر. راجع نتيجة الاتصال.','error');}
      finally{btn.disabled=false;}
    }
    function downloadJson(){enforceCoreSources(state);persist();const blob=new Blob([JSON.stringify(state,null,2)+'\n'],{type:'application/json;charset=utf-8'}),url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download='repo.json';document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),1500);toast('تم تجهيز repo.json للتنزيل.');}
    async function copyJson(){const json=JSON.stringify(state,null,2);try{if(!navigator.clipboard?.writeText)throw new Error();await navigator.clipboard.writeText(json);toast('تم نسخ repo.json بالكامل.');}catch{const area=text('textarea','');area.value=json;area.style.position='fixed';area.style.opacity='0';document.body.append(area);area.select();let copied=false;try{copied=document.execCommand('copy');}catch{}area.remove();toast(copied?'تم نسخ repo.json بالكامل.':'تعذر النسخ. استخدم زر التنزيل.',copied?'success':'error');}}
    async function importFile(file) {
      if(!file)return;
      if(file.size>15*1024*1024){toast('الحد الأقصى للاستيراد 15 MB.','error');return;}
      try{
        const content=await file.text(),next=normalizeState(JSON.parse(content.replace(/^\uFEFF/,'')));
        const apply=()=>{state=next;remoteBaseline=null;appPage=1;resetCategoryEditor();addActivity('استيراد ملف repo.json');persist();renderAll();toast('تم الاستيراد مع استكمال الإعدادات الناقصة.');};
        if(isDirty())confirmAction('استيراد الملف','سيستبدل الاستيراد المسودة المحلية. هل تريد استخدام الملف المحدد؟',apply,'استيراد واستبدال',false);else apply();
      }catch(error){toast('لم يُستورد الملف: '+(error instanceof SyntaxError?'JSON غير صالح.':error.message),'error');}
    }
    function bumpCounter(key,label){mutate(()=>{state.xsign_config.app_control[key]=safeInteger(state.xsign_config.app_control[key])+1;},label);renderCounters();toast('تم تجهيز الأمر في المسودة. انشر الملف لإرساله ضمن التكوين.');}
    function bindEvents() {
      $$('[data-page]').forEach(btn=>btn.addEventListener('click',()=>openPage(btn.dataset.page)));
      $$('[data-go]').forEach(btn=>btn.addEventListener('click',()=>openPage(btn.dataset.go)));
      $$('[data-action]').forEach(btn=>btn.addEventListener('click',()=>{const action=btn.dataset.action;if(action==='download')downloadJson();if(action==='import')$('importFile').click();if(action==='pull')requestPull();if(action==='prepare-publish')preparePublish();}));
      $$('[data-close-dialog]').forEach(btn=>btn.addEventListener('click',()=>{if(operationBusy&&btn.dataset.closeDialog==='publishDialog')return;$(btn.dataset.closeDialog).close();}));
      $$('dialog').forEach(dialog=>dialog.addEventListener('click',event=>{if(event.target!==dialog)return;const rect=dialog.getBoundingClientRect();if(event.clientX<rect.left||event.clientX>rect.right||event.clientY<rect.top||event.clientY>rect.bottom){if(['publishDialog','ingestReviewDialog'].includes(dialog.id)&&(operationBusy||transferBusy))return;dialog.close();}}));
      $('publishDialog').addEventListener('cancel',event=>{if(operationBusy)event.preventDefault();});
      $('publishDialog').addEventListener('close',()=>{if(!operationBusy)pendingPublish=null;});
      $('menuButton').addEventListener('click',()=>setMenu(!$('sidebar').classList.contains('open')));$('mobileBackdrop').addEventListener('click',()=>setMenu(false));
      document.addEventListener('keydown',event=>{if(event.key==='Escape'&&$('sidebar').classList.contains('open')){setMenu(false);$('menuButton').focus();}});
      window.addEventListener('hashchange',()=>openPage(location.hash.slice(1),false));
      window.addEventListener('pagehide',()=>{if(saveTimer)persist();$('ghToken').value='';});
      $$('[data-path]').forEach(el=>{
        el.addEventListener('input',()=>fieldInput(el));
        el.addEventListener('change',()=>{fieldInput(el,true);persist();});
      });
      $$('[data-style]').forEach(btn=>btn.addEventListener('click',()=>{mutate(()=>state.xsign_config.splash_screen.animation_style=btn.dataset.style,'تحديث حركة الإقلاع',false);updateAppearanceControls();renderPreview(true);}));
      $$('[data-connection]').forEach(el=>el.addEventListener('input',()=>{connection[el.dataset.connection]=el.value.trim();renderTargetWarning();renderOverview();clearTimeout(saveTimer);saveTimer=setTimeout(persist,260);}));
      $('toggleToken').addEventListener('click',()=>{const hidden=$('ghToken').type==='password';$('ghToken').type=hidden?'text':'password';$('toggleToken').setAttribute('aria-pressed',String(hidden));$('toggleToken').setAttribute('aria-label',hidden?'إخفاء رمز الوصول':'إظهار رمز الوصول');});
      $('clearToken').addEventListener('click',()=>{$('ghToken').value='';$('ghToken').type='password';$('toggleToken').setAttribute('aria-pressed','false');$('toggleToken').setAttribute('aria-label','إظهار رمز الوصول');toast('تم مسح رمز الوصول من هذه الصفحة.');});
      $('testPrimarySource').addEventListener('click',()=>testSource('primary'));$('testOwnedSource').addEventListener('click',()=>testSource('owned'));
      $('appForm').addEventListener('submit',saveApp);$('appSearch').addEventListener('input',()=>{appPage=1;renderApps();});$('categoryFilter').addEventListener('change',()=>{appPage=1;renderApps();});
      $('previousPage').addEventListener('click',()=>{appPage--;renderApps();});$('nextPage').addEventListener('click',()=>{appPage++;renderApps();});
      $('newNews').addEventListener('click',()=>openNewsEditor());$('newsForm').addEventListener('submit',saveNews);$('categoryForm').addEventListener('submit',saveCategory);$('cancelCategoryEdit').addEventListener('click',resetCategoryEditor);
      $('replaySplash').addEventListener('click',()=>renderPreview(true));$('replaySplashText').addEventListener('click',()=>renderPreview(true));
      $('bumpCache').addEventListener('click',()=>bumpCounter('cache_flush_id','تجهيز أمر تنظيف كاش الصور'));$('bumpSources').addEventListener('click',()=>bumpCounter('purge_sources_id','تجهيز أمر تحديث كاش المصادر'));
      $('bumpRevision').addEventListener('click',()=>{mutate(()=>state.repo_revision_id++,'زيادة رقم المراجعة',false);toast('تم رفع رقم المراجعة إلى '+state.repo_revision_id);});
      $('copyJson').addEventListener('click',copyJson);$('importFile').addEventListener('change',event=>{const file=event.target.files?.[0];event.target.value='';importFile(file);});
      $('resetState').addEventListener('click',()=>confirmAction('مسودة جديدة','سيتم حذف التطبيقات والأخبار والإعدادات في المسودة المحلية. لا يتغير ملف GitHub حتى تنشره. يمكنك تنزيل نسخة أولاً.',()=>{const revision=state.repo_revision_id+1;state=normalizeState(createDefaultState());state.repo_revision_id=revision;remoteBaseline=null;appPage=1;resetCategoryEditor();addActivity('بدء مسودة نظيفة');persist();renderAll();toast('تمت إعادة ضبط المسودة المحلية.');},'إعادة ضبط المسودة'));
      $('publishNow').addEventListener('click',publishNow);
    }
