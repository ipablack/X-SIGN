/* Operational layer: catalogue management, atomic publication, and IPA workflows. */
const Store=XSignStore;
Object.assign(connection,{configPath:'xsign-config.json',workflow:'ipa_manager.yml',processingRepo:'',processingBranch:'',uploadAdapter:'auto'});
Object.assign(PAGE_META,{
  overview:['لوحة المعلومات','STORE OPERATIONS','كتالوج التطبيقات، حالة العمليات، والتغييرات المنتظرة للنشر.'],
  apps:['كتالوج التطبيقات','CATALOGUE / APPLICATIONS','حرّر الإصدارات، رتّب الظهور، وأدر عدة تطبيقات في خطوة واحدة.'],
  ingest:['رفع ومعالجة IPA','CATALOGUE / IMPORT','أرسل رابطاً أو ملفاً إلى محرك المستودع بعد فحص عقده.'],
  operations:['مركز العمليات','OPERATIONS / ACTIVITY','تابع حالات المعالجة الفعلية، ثم زامن نتائجها مع الكتالوج.']
});
const SYNC_KEY='xsign.studio.sync.v4';
let loadedDraftRaw=undefined,externalDraftChanged=false;
let selectedApps=new Set(),visibleApps=[],uploadMode='url',preparedUpload=null,runData=null,runContext='',runsFetchedAt=null,runBusy=false,iconTarget=null,transferBusy=false;
let appEditorGeneration=0;
const openAppEditorOriginal=openAppEditor;openAppEditor=function(app=null){appEditorGeneration++;openAppEditorOriginal(app);};
const catalogueKey=app=>String(app.catalogID||app.bundleIdentifier+'\u001f'+app.name);
const currentProcessing=()=>{
  const repo=connection.processingRepo.trim();let c={...connection};
  if(repo){const [owner,name,...extra]=repo.split('/');if(extra.length||!owner||!name)throw Error('مستودع المعالجة يجب أن يكون بصيغة owner/repo.');c.owner=owner;c.repo=name;}
  c.branch=connection.processingBranch.trim()||connection.branch;return validateConnection(c);
};
const workflowKey=c=>[c.owner,c.repo,c.branch,c.workflow].join('/');
const branchPath=branch=>branch.split('/').map(encodeURIComponent).join('/');
function requireToken(){const token=$('ghToken').value.trim().replace(/^(Bearer|token)\s+/i,'');if(!token)throw Error('أدخل رمز GitHub في قسم المصادر والاتصال أولاً.');return token;}
function validRepoPath(path){return typeof path==='string'&&path&&!path.startsWith('/')&&!/[\x00-\x1f]/.test(path)&&!path.split('/').some(x=>!x||x==='.'||x==='..');}
const baseValidateConnection=validateConnection;
validateConnection=function(c){baseValidateConnection(c);if(!validRepoPath(c.configPath||'xsign-config.json'))throw Error('مسار ملف الإعدادات المختصر غير صالح.');if(c.configPath===c.path)throw Error('repo.json وملف الإعدادات المختصر يحتاجان مسارين مختلفين.');if(!/^[A-Za-z0-9_.-]+\.ya?ml$/.test(c.workflow||'ipa_manager.yml'))throw Error('أدخل اسم ملف Workflow مثل ipa_manager.yml.');return c;};
async function github(c,path,method='GET',body,token=$('ghToken').value.trim(),timeout=20000){
  if(method!=='GET'&&!token)throw Error('يلزم رمز GitHub لإجراء هذا التغيير.');
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeout);
  try{
    const response=await fetch(apiBase(c)+(path?'/'+path:''),{method,headers:{...apiHeaders(token),'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:controller.signal,credentials:'omit',cache:'no-store',redirect:'error',referrerPolicy:'no-referrer'});
    const value=response.status===204?null:await response.json().catch(()=>null);
    if(!response.ok){const error=await apiError(response,'تعذر تنفيذ طلب GitHub');error.status=response.status;throw error;}
    return value;
  }catch(error){if(error.name==='AbortError')throw Error('انتهت مهلة الاتصال. تحقق من الحالة قبل إعادة إرسال العملية.');if(error instanceof TypeError)throw Error('تعذر الاتصال بـ GitHub. تحقق من الشبكة وسياسة CORS.');throw error;}
  finally{clearTimeout(timer);}
}
async function repositoryFile(c,path,ref,token,optional=false){
  let file;
  try{file=await github(c,'contents/'+path.split('/').map(encodeURIComponent).join('/')+'?ref='+encodeURIComponent(ref),'GET',undefined,token);}
  catch(error){if(optional&&error.status===404)return null;throw error;}
  if(!isObject(file)||file.type!=='file'||!file.sha)throw Error('المسار '+path+' ليس ملفاً عادياً.');
  if(Number(file.size)>15*1024*1024)throw Error('ملف '+path+' أكبر من حد الفحص (15 MB).');
  let encoded=file.content;if(file.encoding!=='base64'||typeof encoded!=='string'){const blob=await github(c,'git/blobs/'+encodeURIComponent(file.sha),'GET',undefined,token);if(blob?.encoding!=='base64'||typeof blob.content!=='string')throw Error('تعذر قراءة الملف بترميز مدعوم.');encoded=blob.content;}
  const source=decodeBase64(encoded);if(new TextEncoder().encode(source).length>15*1024*1024)throw Error('الملف أكبر من 15 MB.');return {sha:file.sha,source};
}
async function readCatalogueSnapshot(c,token){
  const ref=await github(c,'git/ref/heads/'+branchPath(c.branch),'GET',undefined,token);
  if(!ref?.object?.sha)throw Error('تعذر تحديد رأس الفرع المختار.');
  const commit=await github(c,'git/commits/'+encodeURIComponent(ref.object.sha),'GET',undefined,token);
  if(!commit?.tree?.sha)throw Error('تعذر قراءة شجرة المستودع.');
  const file=await repositoryFile(c,c.path,ref.object.sha,token,true);
  let data=null,parseError='';
  if(file){try{data=normalizeState(JSON.parse(file.source.replace(/^\uFEFF/,'')));}catch(error){parseError=error instanceof SyntaxError?'الملف الحي ليس JSON صالحاً.':error.message;}}
  return {head:ref.object.sha,tree:commit.tree.sha,sha:file?.sha||null,data,missing:!file,parseError};
}
function withRevision(data,minimum){const result=normalizeState(data);result.repo_revision_id=Math.max(safeInteger(result.repo_revision_id),safeInteger(minimum,0));return result;}
function mergeCatalogue(base,local,remote){return withRevision(Store.merge(base,local,remote),Math.max(local.repo_revision_id||1,remote.repo_revision_id||1));}
function setRemoteSnapshot(c,remote){remoteBaseline={key:connectionKey(c),sha:remote.sha,head:remote.head,tree:remote.tree,data:clone(remote.data)};baseline=JSON.stringify(remote.data);}
const persistOriginal=persist;
persist=function(){
  try{const current=localStorage.getItem(STORAGE_KEY);if(loadedDraftRaw!==undefined&&current!==loadedDraftRaw&&current!==JSON.stringify(state)){clearTimeout(saveTimer);saveTimer=null;externalDraftChanged=true;storageError=true;updateStatus();toast('تغيرت المسودة في نافذة أخرى. لم تُستبدل؛ نزّل نسختك أو حمّل أحدث مسودة.','error');return;}}catch{}
  persistOriginal();try{loadedDraftRaw=localStorage.getItem(STORAGE_KEY);}catch{}
  try{if(remoteBaseline?.data){const serialized=JSON.stringify(remoteBaseline);if(serialized.length<1800000)sessionStorage.setItem(SYNC_KEY,serialized);else sessionStorage.removeItem(SYNC_KEY);}else sessionStorage.removeItem(SYNC_KEY);}catch{/* Large merge baselines may remain in memory only. The draft is saved independently. */}
};
const loadLocalOriginal=loadLocal;
loadLocal=function(){loadLocalOriginal();try{loadedDraftRaw=localStorage.getItem(STORAGE_KEY);}catch{}try{const raw=sessionStorage.getItem(SYNC_KEY);if(raw){const saved=JSON.parse(raw);if(saved.key===connectionKey()&&saved.data){saved.data=normalizeState(saved.data);remoteBaseline=saved;baseline=JSON.stringify(saved.data);}}}catch{remoteBaseline=null;}};
const updateStatusOriginal=updateStatus;
updateStatus=function(){updateStatusOriginal();if(transferBusy){$$('[data-action="prepare-publish"],[data-action="pull"],#prepareIngest,#sendIngest,[data-select-icon]').forEach(b=>b.disabled=true);}else if(!operationBusy){$$('#prepareIngest,[data-select-icon]').forEach(b=>b.disabled=false);}$('sendIngest').disabled=transferBusy||operationBusy||!preparedUpload;if($('localDraftConflict'))$('localDraftConflict').hidden=!externalDraftChanged;if(externalDraftChanged){$('saveIndicatorText').textContent='تعارض مع نافذة أخرى';$$('[data-action="prepare-publish"],[data-action="pull"]').forEach(b=>b.disabled=true);}};
function showConflict(error){
  const detail=error.name==='MergeConflict'?'\nالحقل: '+error.path+'\nلم تُحذف المسودة ولم يُستبدل الملف الحي. نزّل نسختك وراجع الاختلاف قبل المزامنة.':'';
  toast(error.message+detail,'error');
}
requestPull=async function(){
  if(operationBusy||transferBusy)return;
  const execute=async()=>{
    operationBusy=true;updateStatus();
    try{
      const c=validateConnection({...connection}),before=JSON.stringify(state),token=$('ghToken').value.trim().replace(/^(Bearer|token)\s+/i,''),remote=await readCatalogueSnapshot(c,token);
      if(JSON.stringify(c)!==JSON.stringify(connection))throw Error('تغيرت وجهة الاتصال أثناء الجلب. أعد المزامنة للوجهة الحالية.');
      if(remote.missing)throw Error('لا يوجد '+c.path+' على هذا الفرع. يمكنك إنشاؤه من مراجعة النشر.');
      if(remote.parseError)throw Error(remote.parseError+' لم تتغير مسودتك.');
      const canMerge=remoteBaseline?.key===connectionKey(c)&&remoteBaseline.data;
      if(!canMerge&&JSON.stringify(state)!==before)throw Error('تغيرت المسودة أثناء الجلب. لم تُستبدل؛ أعد المزامنة بعد حفظها.');
      const merged=canMerge?mergeCatalogue(remoteBaseline.data,state,remote.data):remote.data;
      state=merged;setRemoteSnapshot(c,remote);selectedApps.clear();appPage=1;resetCategoryEditor();addActivity(canMerge&&isDirty()?'مزامنة الكتالوج مع إبقاء التعديلات المحلية':'جلب النسخة الحية من الكتالوج');persist();renderAll();toast(isDirty()?'تم دمج التحديثات؛ بقيت تعديلات محلية جاهزة للمراجعة.':'تمت مزامنة الكتالوج بنجاح.');
    }catch(error){showConflict(error);}finally{operationBusy=false;updateStatus();}
  };
  if(isDirty()&&!(remoteBaseline?.key===connectionKey()&&remoteBaseline.data))confirmAction('مزامنة دون نسخة أساس','لا توجد نسخة مزامنة موثوقة لهذه الوجهة في الجلسة. سيستبدل الجلب المسودة المحلية. نزّلها أولاً إن كنت تريد الاحتفاظ بها.',execute,'جلب واستبدال',false);else await execute();
};
function metricRow(label,value){const row=text('div','','review-metric');row.append(text('span',label),text('strong',value));return row;}
function appendChangeSummary(container,before,after){
  const changes=Store.summary(before,after),box=text('div','','publish-change-list');
  for(const [key,label] of [['apps','التطبيقات'],['categories','التصنيفات'],['news','الأخبار']]){const item=changes.lists[key],row=text('div','','change-row');row.append(text('span',label),text('span','+'+item.added+' / ~'+item.updated+' / −'+item.removed));box.append(row);}
  const note=text('p',changes.fields.length?'الحقول المتغيرة: '+changes.fields.slice(0,8).join('، '):'لا توجد فروق في المحتوى.','field-hint');note.style.overflowWrap='anywhere';box.append(note);container.append(box);
}
preparePublish=async function(){
  if(operationBusy||transferBusy)return;
  const errors=validateState(state);if(errors.length){openPage('publish');toast('راجع ملاحظات الملف قبل النشر.','error');return;}
  let token;try{token=requireToken();}catch(error){openPage('sources');$('ghToken').focus();toast(error.message,'info');return;}
  operationBusy=true;updateStatus();
  try{
    const c=validateConnection({...connection}),remote=await readCatalogueSnapshot(c,token);
    if(JSON.stringify(c)!==JSON.stringify(connection))throw Error('تغيرت وجهة النشر أثناء المراجعة. أعد فتح المراجعة للوجهة الحالية.');
    const hasBase=remoteBaseline?.key===connectionKey(c)&&remoteBaseline.data;
    if(remote.parseError&&hasBase)throw Error(remote.parseError+' تعذر الدمج؛ لم تتغير مسودتك.');
    let snapshot=hasBase&&remote.data?mergeCatalogue(remoteBaseline.data,state,remote.data):clone(state);
    snapshot.repo_revision_id=Math.max(safeInteger(snapshot.repo_revision_id),safeInteger(remote.data?.repo_revision_id,0))+1;
    const problems=validateState(snapshot);if(problems.length)throw Error('النسخة المدمجة تحتاج مراجعة: '+problems[0]);
    pendingPublish={connection:c,snapshot,remote,local:clone(state),localAtReview:JSON.stringify(state)};
    const review=$('publishReview');review.replaceChildren(metricRow('المستودع',c.owner+'/'+c.repo),metricRow('الفرع',c.branch),metricRow('المراجعة الجديدة',snapshot.repo_revision_id));
    for(const path of [c.path,c.configPath])review.append(text('div',path,'publish-file'));
    appendChangeSummary(review,remote.data||normalizeState(createDefaultState()),snapshot);
    const warnings=[];
    if(!hasBase&&!remote.missing)warnings.push('هذه المسودة ليست مبنية على مزامنة موثوقة في الجلسة. سيستبدل النشر محتوى الملف الحالي. يفضّل جلبه أولاً.');
    if(remote.parseError)warnings.push(remote.parseError+' سيتم استبداله بملف صالح.');
    if(connectionKey(c)!=='ipablack/repo/main/repo.json')warnings.push('وجهة النشر تختلف عن مصدر المالك الثابت؛ ربط التطبيق بهذه الوجهة يحتاج التحقق مستقلاً.');
    warnings.push('ينشر ملفا الكتالوج والإعدادات المختصرة معاً في التزام واحد.');
    $('publishWarning').textContent=warnings.join('\n');$('publishWarning').hidden=false;$('publishError').hidden=true;$('publishDialog').showModal();
  }catch(error){showConflict(error);}finally{operationBusy=false;updateStatus();}
};
async function writeAtomicFiles(c,remote,entries,message,token){
  const tree=await github(c,'git/trees','POST',{base_tree:remote.tree,tree:entries},token);
  if(!tree?.sha)throw Error('لم يعد GitHub معرف الشجرة الجديدة.');
  const commit=await github(c,'git/commits','POST',{message,tree:tree.sha,parents:[remote.head]},token);
  if(!commit?.sha)throw Error('لم يعد GitHub معرف الالتزام الجديد.');
  try{
    const ref=await github(c,'git/refs/heads/'+branchPath(c.branch),'PATCH',{sha:commit.sha,force:false},token);
    if(ref?.object?.sha!==commit.sha)throw Error('تعذر تأكيد نتيجة تحديث الفرع. زامن المستودع قبل إعادة المحاولة.');
    return {head:commit.sha,tree:tree.sha};
  }catch(error){error.refUpdate=true;throw error;}
}
publishNow=async function(){
  if(operationBusy||transferBusy||!pendingPublish)return;
  const job=pendingPublish;let token;
  try{token=requireToken();if(JSON.stringify(state)!==job.localAtReview)throw Error('تغيرت المسودة بعد المراجعة. أعد فتح المراجعة قبل النشر.');}catch(error){$('publishError').textContent=error.message;$('publishError').hidden=false;return;}
  operationBusy=true;$('publishNow').disabled=true;$('publishNow').textContent='جارٍ نشر الملفين…';updateStatus();
  try{
    let remote=job.remote,data=clone(job.snapshot),written;
    for(let attempt=0;attempt<3;attempt++){
      const entries=[{path:job.connection.path,mode:'100644',type:'blob',content:JSON.stringify(data,null,2)+'\n'},{path:job.connection.configPath,mode:'100644',type:'blob',content:JSON.stringify(Store.project(data),null,2)+'\n'}];
      try{written=await writeAtomicFiles(job.connection,remote,entries,'Update X-SIGN catalogue and configuration (Rev '+data.repo_revision_id+')',token);break;}
      catch(error){
        if(!error.refUpdate||![409,422].includes(error.status)||attempt===2)throw error;
        const latest=await readCatalogueSnapshot(job.connection,token);if(!latest.data||latest.parseError)throw Error('تغير الملف الحي إلى نسخة لا يمكن دمجها؛ لم تُنشر المسودة.');
        if(!remote.data)throw Error('ظهر ملف كتالوج جديد أثناء النشر. زامنه أولاً.');
        data=mergeCatalogue(remote.data,data,latest.data);data.repo_revision_id=Math.max(data.repo_revision_id,latest.data.repo_revision_id)+1;
        const errors=validateState(data);if(errors.length)throw Error('تحتاج النسخة المدمجة إلى مراجعة: '+errors[0]);remote=latest;
      }
    }
    if(!written)throw Error('لم تكتمل عملية النشر.');
    state=normalizeState(data);setRemoteSnapshot(job.connection,{...written,sha:null,data:state});lastPublishedAt=new Date().toISOString();addActivity('نشر ملفي الكتالوج والتكوين · مراجعة '+state.repo_revision_id);persist();renderAll();$('publishDialog').close();pendingPublish=null;toast('تم نشر repo.json وملف التكوين معاً بنجاح.');
    if(typeof observePublishedProjection==='function')void observePublishedProjection(job.connection,state.repo_revision_id);
  }catch(error){$('publishError').textContent=error.message;$('publishError').hidden=false;}
  finally{operationBusy=false;$('publishNow').disabled=false;$('publishNow').replaceChildren(icon('cloud'),document.createTextNode('نشر الآن'));updateStatus();}
};
const renderOverviewOriginal=renderOverview;
renderOverview=function(){
  renderOverviewOriginal();const box=$('categoryDistribution');box.replaceChildren();
  const counts=new Map();for(const app of state.apps){const label=categoryName(app.category);counts.set(label,(counts.get(label)||0)+1);}
  if(!state.apps.length){const empty=text('div','','distribution-empty');empty.append(icon('apps'),text('span','لا توجد بيانات للعرض بعد. أضف تطبيقاً أو زامن مستودعك.'));box.append(empty);}
  [...counts.entries()].sort((a,b)=>b[1]-a[1]).slice(0,5).forEach(([label,count])=>{const row=text('div','','distribution-row'),track=text('div','','distribution-track'),bar=text('span','');bar.style.width=(count/state.apps.length*100)+'%';track.append(bar);row.append(text('span',label),track,text('span',count,'mono'));box.append(row);});
  const ready=state.apps.filter(app=>appReady(app)).length;$('catalogueReadyLabel').textContent=state.apps.length?ready+' من '+state.apps.length+' تطبيق جاهز بالبيانات الأساسية':'ابدأ من كتالوج التطبيقات أو رفع IPA';
  renderIngestContext();
};
const renderAllOriginal=renderAll;
renderAll=function(){renderAllOriginal();renderIngestContext();renderStoreCategories();if(activePage==='operations')renderRuns();};
const renderPublishOriginal=renderPublish;
renderPublish=function(){renderPublishOriginal();let box=$('localChangeSummary');if(!box){box=text('div','','');box.id='localChangeSummary';$('validationSummary').after(box);}box.replaceChildren();try{appendChangeSummary(box,remoteBaseline?.key===connectionKey()&&remoteBaseline.data?remoteBaseline.data:normalizeState(createDefaultState()),state);}catch(error){box.append(text('p',error.message,'field-hint'));}};
function appReady(app){return !!(String(app.name||'').trim()&&/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(app.bundleIdentifier||'')&&String(app.version||app.versions?.[0]?.version||'').trim()&&httpsUrl(app.downloadURL||app.versions?.[0]?.downloadURL)&&(!app.iconURL||httpsUrl(app.iconURL)));}
function catalogueResults(){
  const query=$('appSearch').value.trim().toLocaleLowerCase(),category=$('categoryFilter').value,readiness=$('appReadiness').value,sort=$('appSort').value;
  const list=state.apps.filter(app=>(!category||app.category===category)&&(!query||[app.name,app.bundleIdentifier,app.category].some(v=>String(v||'').toLocaleLowerCase().includes(query)))&&(!readiness||(readiness==='ready')===appReady(app)));
  if(sort==='name')list.sort((a,b)=>String(a.name).localeCompare(String(b.name),'ar'));
  if(sort==='updated')list.sort((a,b)=>String(b.versionDate||b.versions?.[0]?.date||'').localeCompare(String(a.versionDate||a.versions?.[0]?.date||'')));
  if(sort==='size')list.sort((a,b)=>(Number(b.size||b.versions?.[0]?.size)||0)-(Number(a.size||a.versions?.[0]?.size)||0));
  return list;
}
renderApps=function(){
  const known=new Set(state.apps.map(catalogueKey));selectedApps=new Set([...selectedApps].filter(k=>known.has(k)));
  const filtered=catalogueResults(),pages=Math.max(1,Math.ceil(filtered.length/PAGE_SIZE));appPage=Math.min(pages,Math.max(1,appPage));visibleApps=filtered.slice((appPage-1)*PAGE_SIZE,appPage*PAGE_SIZE);
  $('appsTotal').textContent=state.apps.length;$('appsResultText').textContent=filtered.length+' من '+state.apps.length+' تطبيق';$('pageNumber').textContent=appPage+' / '+pages;$('previousPage').disabled=appPage<=1;$('nextPage').disabled=appPage>=pages;
  const box=$('appsList');box.replaceChildren();
  if(!filtered.length){const empty=text('div','','empty'),symbol=text('div','','empty-symbol');symbol.append(icon(state.apps.length?'search':'apps'));empty.append(symbol,text('h3',state.apps.length?'لا توجد نتائج مطابقة':'ابدأ كتالوج IPA BLACK.'),text('p',state.apps.length?'غيّر البحث أو التصنيف أو حالة الجاهزية.':'أضف بيانات تطبيق يدوياً، أو أرسل IPA إلى محرك المعالجة في مستودعك.'));if(!state.apps.length){const actions=text('div','','row wrap');actions.append(button('إضافة تطبيق',()=>openAppEditor(),'plus','btn btn-primary'),button('رفع IPA',()=>openPage('ingest'),'download','btn'));empty.append(actions);}box.append(empty);}
  const fragment=document.createDocumentFragment(),canReorder=$('appSort').value==='manual'&&!$('appSearch').value.trim()&&!$('categoryFilter').value&&!$('appReadiness').value;
  for(const app of visibleApps){
    const key=catalogueKey(app),row=text('div','','app-row'+(selectedApps.has(key)?' selected':''));
    const cell=text('label','','select-cell'),check=document.createElement('input');check.type='checkbox';check.checked=selectedApps.has(key);check.setAttribute('aria-label','تحديد '+app.name);check.addEventListener('change',()=>{if(check.checked)selectedApps.add(key);else selectedApps.delete(key);renderApps();});cell.append(check);
    const identity=text('div','','app-identity'),avatar=text('div',String(app.name||'A').charAt(0).toUpperCase(),'app-icon'),src=httpImage(app.iconURL);
    if(src){const img=document.createElement('img');img.src=src;img.alt='';img.loading='lazy';img.referrerPolicy='no-referrer';img.addEventListener('error',()=>img.remove(),{once:true});avatar.append(img);}
    const info=text('div','');info.style.minWidth='0';info.append(text('h3',app.name||'دون اسم'),text('p',app.bundleIdentifier||'—'));
    const meta=text('div','','app-meta-row');meta.append(text('span',appReady(app)?'جاهز':'بيانات ناقصة','tag '+(appReady(app)?'tag-green':'tag-yellow')),text('span',(app.versions?.length||1)+' إصدار'));info.append(meta);identity.append(avatar,info);
    row.append(cell,identity,text('div',categoryName(app.category),'app-cell app-category-cell'),text('div','v'+(app.version||app.versions?.[0]?.version||'—'),'app-cell latin app-version-cell'),text('div',bytes(app.size||app.versions?.[0]?.size),'app-cell latin app-size-cell'));
    const actions=text('div','','app-actions');
    for(const [delta,label] of [[-1,'أعلى'],[1,'أسفل']]){const b=button(delta===-1?'↑':'↓',()=>moveCatalogueApp(app,delta),null);b.disabled=!canReorder||state.apps.indexOf(app)+delta<0||state.apps.indexOf(app)+delta>=state.apps.length;b.title='نقل '+label;b.setAttribute('aria-label','نقل '+app.name+' '+label);actions.append(b);}
    const edit=button('',()=>openAppEditor(app),'edit'),del=button('',()=>deleteApp(app),'trash');edit.title='تعديل';edit.setAttribute('aria-label','تعديل '+app.name);del.title='حذف';del.setAttribute('aria-label','حذف '+app.name);actions.append(edit,del);row.append(actions);fragment.append(row);
  }
  box.append(fragment);$('bulkToolbar').hidden=!selectedApps.size;$('selectedAppsCount').textContent=selectedApps.size;
  $('selectVisibleApps').checked=!!visibleApps.length&&visibleApps.every(a=>selectedApps.has(catalogueKey(a)));$('selectVisibleApps').indeterminate=visibleApps.some(a=>selectedApps.has(catalogueKey(a)))&&!$('selectVisibleApps').checked;$('selectVisibleApps').disabled=!visibleApps.length;
}
function moveCatalogueApp(app,offset){const index=state.apps.indexOf(app),target=index+offset;if(index<0||target<0||target>=state.apps.length)return;mutate(()=>[state.apps[index],state.apps[target]]=[state.apps[target],state.apps[index]],'تغيير ترتيب التطبيقات');}
function renderStoreCategories(){
  for(const id of ['ingestCategory','bulkCategory']){const select=$(id),value=select.value;select.replaceChildren();const empty=text('option',id==='bulkCategory'?'اختر التصنيف الجديد':'دون تصنيف');empty.value='';select.append(empty);state.categories.forEach(cat=>{const option=text('option',cat.name);option.value=cat.id;select.append(option);});if([...select.options].some(o=>o.value===value))select.value=value;}
}
const renderCategoryOptionsOriginal=renderCategoryOptions;
renderCategoryOptions=function(){renderCategoryOptionsOriginal();renderStoreCategories();};
function applyBulkCategory(){const category=$('bulkCategory').value;if(!category||!state.categories.some(c=>c.id===category)){toast('اختر تصنيفاً موجوداً أولاً.','info');return;}const count=selectedApps.size;mutate(()=>state.apps.forEach(app=>{if(selectedApps.has(catalogueKey(app)))app.category=category;}),'تغيير تصنيف '+count+' تطبيق');toast('تم تحديث تصنيف التطبيقات المحددة في المسودة.');}
function deleteSelectedApps(){if(!selectedApps.size)return;const count=selectedApps.size;confirmAction('حذف التطبيقات المحددة','سيتم حذف '+count+' تطبيق من المسودة. لا يصل الحذف إلى المستودع حتى تنشر التغييرات.',()=>{mutate(()=>state.apps=state.apps.filter(app=>!selectedApps.has(catalogueKey(app))),'حذف '+count+' تطبيق من المسودة');selectedApps.clear();renderApps();toast('تم حذف التطبيقات المحددة من المسودة.');},'حذف '+count+' تطبيق');}
function renderIngestContext(){try{const c=currentProcessing();$('ingestTarget').textContent=c.owner+' / '+c.repo;$('ingestWorkflow').textContent=c.branch+' · '+c.workflow;}catch{$('ingestTarget').textContent='تحقق من إعدادات الاتصال';$('ingestWorkflow').textContent='';}}
function setPipeline(stage,message){$$('.pipeline-step').forEach(el=>{el.classList.toggle('done',Number(el.dataset.stage)<stage);el.classList.toggle('active',Number(el.dataset.stage)===stage);});$('uploadPhaseText').textContent=message;}
function setUploadMode(mode){uploadMode=mode;$('ingestUrlGroup').hidden=mode!=='url';$('ingestFileGroup').hidden=mode!=='file';$$('[data-upload-mode]').forEach(b=>{b.classList.toggle('active',b.dataset.uploadMode===mode);b.setAttribute('aria-pressed',String(b.dataset.uploadMode===mode));});preparedUpload=null;}
async function inspectEngine(c,token){
  const repository=await github(c,'','GET',undefined,token);
  const workflowMeta=await github(c,'actions/workflows/'+encodeURIComponent(c.workflow),'GET',undefined,token);
  if(workflowMeta?.state!=='active')throw Error('محرك المعالجة غير مفعّل في المستودع.');
  const source=await repositoryFile(c,'.github/workflows/'+c.workflow,c.branch,token);
  const engine=Store.readWorkflow(source.source,jsyaml);
  if(repository.default_branch&&repository.default_branch!==c.branch){
    const defaultSource=await repositoryFile(c,'.github/workflows/'+c.workflow,repository.default_branch,token);
    const defaultEngine=Store.readWorkflow(defaultSource.source,jsyaml);
    if(uploadMode==='url'&&(!defaultEngine.dispatch||!Store.same(defaultEngine.inputs,engine.inputs)))throw Error('مدخلات Workflow في الفرع المختار تختلف عن الفرع الافتراضي. وحّد تعريف المدخلات أولاً.');
  }
  const scripts=[];for(const path of engine.scripts.slice(0,3)){const file=await repositoryFile(c,path,c.branch,token,true);if(file&&file.source.length<400000)scripts.push(file.source);}
  return {engine,scripts,repository};
}
async function activeWorkflowRuns(c,token){const lists=await Promise.all(['queued','in_progress','waiting','pending','requested'].map(async status=>{const data=await github(c,'actions/workflows/'+encodeURIComponent(c.workflow)+'/runs?per_page=1&branch='+encodeURIComponent(c.branch)+'&status='+status,'GET',undefined,token);if(!Array.isArray(data?.workflow_runs))throw Error('تعذر فحص طابور المعالجة.');return data.workflow_runs.filter(r=>r.head_branch===c.branch&&r.status!=='completed');}));return lists.flat();}
async function getRuns(c,token,perPage=30){const data=await github(c,'actions/workflows/'+encodeURIComponent(c.workflow)+'/runs?per_page='+perPage+'&branch='+encodeURIComponent(c.branch),'GET',undefined,token);if(!Array.isArray(data?.workflow_runs))throw Error('لم يعد GitHub قائمة عمليات صالحة.');return data.workflow_runs.filter(run=>run.head_branch===c.branch);}
async function prepareIngest(event){
  event?.preventDefault();if(operationBusy||transferBusy)return;
  $('ingestError').hidden=true;setPipeline(1,'التحقق من الرابط والبيانات…');
  try{
    const c=currentProcessing(),file=$('ingestFile').files?.[0],url=$('ingestUrl').value.trim();
    if(uploadMode==='url'&&!httpsUrl(url))throw Error('أدخل رابط HTTPS صالحاً لملف IPA.');
    if(uploadMode==='file'&&(!file||!/\.ipa$/i.test(file.name)||file.size===0||file.size>25*1024*1024))throw Error('اختر ملف IPA غير فارغ بحجم لا يتجاوز 25 MB.');
    const metadata={name:$('ingestName').value.trim(),desc:$('ingestDescription').value.trim(),icon:$('ingestIcon').value.trim(),category:$('ingestCategory').value,skip_appstore:$('ingestSkipStore').checked};
    if(metadata.icon&&!httpsUrl(metadata.icon))throw Error('رابط الأيقونة اليدوية يجب أن يكون HTTPS.');
    const token=requireToken();
    transferBusy=true;updateStatus();setPipeline(2,'قراءة المحرك والتحقق من فرعه ومدخلاته…');
    const inspected=await inspectEngine(c,token),runs=await activeWorkflowRuns(c,token);
    if(runs.some(run=>run.status!=='completed'))throw Error('توجد عملية معالجة غير مكتملة على الفرع المختار. تابعها من مركز العمليات أولاً.');
    let inputs=null,contract=null,path=null,head=null;
    if(uploadMode==='url')inputs=Store.dispatchInputs(inspected.engine,{ipa_url:url,custom_name:metadata.name,custom_desc:metadata.desc,custom_icon:metadata.icon,category_id:metadata.category,skip_appstore:metadata.skip_appstore,operation:'publish'});
    else{
      path='uploads/pkg_'+uid()+'.ipa';contract=Store.fileContract(inspected.engine,c.branch,path,c.uploadAdapter,inspected.scripts);
      const ref=await github(c,'git/ref/heads/'+branchPath(c.branch),'GET',undefined,token);const commit=await github(c,'git/commits/'+encodeURIComponent(ref.object.sha),'GET',undefined,token);
      head={head:ref.object.sha,tree:commit.tree.sha};
      const tree=await github(c,'git/trees/'+encodeURIComponent(head.tree)+'?recursive=1','GET',undefined,token);
      if(tree.truncated||!Array.isArray(tree.tree))throw Error('لم يمكن فحص ملفات الرفع المنتظرة بأمان. استخدم الرابط المباشر.');
      if(tree.tree.some(entry=>/^uploads\/.*\.ipa$/i.test(entry.path)))throw Error('يوجد IPA في مجلد الرفع ينتظر المعالجة. راجع المحرك قبل إضافة ملف آخر.');
    }
    preparedUpload={c,mode:uploadMode,file,url,metadata,inputs,contract,path,head,private:inspected.repository.private===true};
    const body=$('ingestReviewBody');body.replaceChildren(metricRow('مستودع المعالجة',c.owner+'/'+c.repo),metricRow('الفرع',c.branch),metricRow('المحرك',c.workflow),metricRow('الطريقة',uploadMode==='url'?'تشغيل Workflow بالرابط':'رفع IPA وبياناته في التزام واحد'),metricRow('ظهور المستودع',inspected.repository.private?'خاص':'عام'));
    if(file&&uploadMode==='file')body.append(metricRow('الملف',file.name),metricRow('الحجم',bytes(file.size)),metricRow('عقد البيانات',contract.mode==='legacy'?'uploads/meta.json':'بيانات بجانب ملف IPA'));
    if(inputs)body.append(metricRow('مدخلات معرّفة فعلياً',Object.keys(inputs).length));
    const warnings=[];if(!inspected.repository.private&&uploadMode==='file')warnings.push('سيُرفع IPA إلى مستودع عام. تأكد أن هذا هو مكان توزيعه المقصود.');
    if(c.owner!==connection.owner||c.repo!==connection.repo)warnings.push('محرك المعالجة في مستودع مختلف عن الكتالوج. نجاحه لا يثبت تحديث مصدر المالك؛ يلزم ربط الوجهة داخل المحرك والتحقق بالمزامنة.');
    if(!inspected.engine.workflow.concurrency)warnings.push('المحرك لا يعرّف تسلسل تشغيل؛ تجنب إرسال عمليات متزامنة من أكثر من نافذة.');
    if(contract?.manual)warnings.push('عقد البيانات مختار يدوياً؛ توافق سكربت المعالجة معه مسؤولية إعداد المحرك.');
    warnings.push('الإرسال يبدأ المعالجة على GitHub؛ لا تعني هذه الخطوة اكتمال إضافة التطبيق إلى السورس.');$('ingestReviewWarning').textContent=warnings.join('\n');$('ingestReviewError').hidden=true;$('ingestReviewDialog').showModal();
    setPipeline(2,'اكتمل الفحص. بانتظار مراجعتك للإرسال.');
  }catch(error){$('ingestError').textContent=error.message;$('ingestError').hidden=false;setPipeline(1,'لم تُرسل العملية: '+error.message);}
  finally{transferBusy=false;updateStatus();}
}
async function sendIngest(){
  if(transferBusy||operationBusy||!preparedUpload)return;const job=preparedUpload;
  transferBusy=true;updateStatus();$('sendIngest').textContent='جارٍ الإرسال…';$('ingestReviewError').hidden=true;
  try{
    const token=requireToken();
    // Recheck the queue immediately before the external mutation.
    const active=await activeWorkflowRuns(job.c,token);if(active.some(r=>r.status!=='completed'))throw Error('بدأت عملية أخرى بعد المراجعة. حدّث الحالة ثم أعد الإرسال.');
    setPipeline(3,'إرسال العملية إلى GitHub…');
    if(job.mode==='url'){
      const result=await github(job.c,'actions/workflows/'+encodeURIComponent(job.c.workflow)+'/dispatches','POST',{ref:job.c.branch,inputs:job.inputs},token);
      setPipeline(4,result?.workflow_run_id?'أُرسل الطلب · العملية #'+result.workflow_run_id:'قُبل طلب التشغيل. حدّث مركز العمليات لظهور معرفه وحالته.');
    }else{
      // A non-forced ref update prevents an IPA queue race. No automatic retry.
      const blob=await github(job.c,'git/blobs','POST',{content:encodeBase64Bytes(new Uint8Array(await job.file.arrayBuffer())),encoding:'base64'},token,120000);
      if(!blob?.sha)throw Error('لم يُرجع GitHub معرف ملف IPA.');
      await writeAtomicFiles(job.c,job.head,[{path:job.path,mode:'100644',type:'blob',sha:blob.sha},{path:job.contract.metadataPath,mode:'100644',type:'blob',content:JSON.stringify(job.metadata,null,2)+'\n'}],'Queue IPA and metadata via X-SIGN STUDIO',token);
      setPipeline(4,'تم رفع IPA وبياناته. تحقق من ظهور تشغيل المحرك في مركز العمليات.');
    }
    addActivity('إرسال عملية IPA إلى '+job.c.owner+'/'+job.c.repo);persist();$('ingestReviewDialog').close();preparedUpload=null;runData=null;renderOverview();toast('أُرسلت العملية. تابع الحالة ثم زامن الكتالوج عند اكتمالها.');
  }catch(error){if(error.refUpdate&&[409,422].includes(error.status)){preparedUpload=null;error.message='تغير رأس الفرع بعد المراجعة. أغلق هذه النافذة وأعد فحص المحرك لإنشاء عملية على النسخة الأحدث؛ لم يُفرض أي تغيير على الفرع.';}$('ingestReviewError').textContent=error.message;$('ingestReviewError').hidden=false;setPipeline(3,'لم يتأكد اكتمال الإرسال. راجع حالة المستودع قبل إعادة المحاولة.');}
  finally{transferBusy=false;$('sendIngest').replaceChildren(icon('cloud'),document.createTextNode('إرسال العملية'));updateStatus();}
}
function encodeBase64Bytes(bytes){let binary='';for(let i=0;i<bytes.length;i+=16384)binary+=String.fromCharCode(...bytes.subarray(i,i+16384));return btoa(binary);}
async function uploadImage(file,target){
  if(operationBusy||transferBusy)return;
  const editorGenerationAtStart=appEditorGeneration;
  if(!file||!['image/png','image/jpeg','image/webp'].includes(file.type)||file.size===0||file.size>5*1024*1024){toast('اختر PNG أو JPEG أو WebP غير فارغ، بحجم لا يتجاوز 5 MB.','error');return;}
  transferBusy=true;updateStatus();
  try{
    const c=validateConnection({...connection}),token=requireToken(),repo=await github(c,'','GET',undefined,token);
    if(repo.private)throw Error('المستودع خاص. رابط الصورة الخام لن يكون متاحاً للتطبيق دون مصادقة؛ استخدم رابط صورة عاماً بدلاً من الرفع هنا.');
    const ext={'image/png':'png','image/jpeg':'jpg','image/webp':'webp'}[file.type],path='assets/icons/img_'+uid()+'.'+ext;
    const result=await github(c,'contents/'+path,'PUT',{message:'Upload catalogue icon via X-SIGN STUDIO',branch:c.branch,content:encodeBase64Bytes(new Uint8Array(await file.arrayBuffer()))},token,60000);
    if(!result?.content?.sha)throw Error('تعذر تأكيد رفع الصورة.');
    const uploadedUrl='https://raw.githubusercontent.com/'+encodeURIComponent(c.owner)+'/'+encodeURIComponent(c.repo)+'/'+branchPath(c.branch)+'/'+path;
    if(target==='appIcon'&&editorGenerationAtStart!==appEditorGeneration){toast('رُفعت الصورة، لكن نافذة التطبيق تغيرت. الرابط: '+uploadedUrl,'info');return;}
    $(target).value=uploadedUrl;$(target).dispatchEvent(new Event('input',{bubbles:true}));toast('تم رفع الصورة. احفظ التطبيق أو انشر إعدادات الهوية لاعتماد الرابط.');
  }catch(error){toast(error.message,'error');}finally{transferBusy=false;updateStatus();}
}
async function refreshRuns(){
  if(runBusy||operationBusy||transferBusy)return;runBusy=true;$('refreshRuns').disabled=true;
  try{const c=currentProcessing(),data=await getRuns(c,requireToken());runData=data;runContext=workflowKey(c);runsFetchedAt=new Date().toISOString();renderRuns();}
  catch(error){toast(error.message,'error');}finally{runBusy=false;$('refreshRuns').disabled=false;}
}
function runState(run){if(run.status!=='completed')return 'active';if(run.conclusion==='success')return 'success';return 'failed';}
function runLabel(run){const states={queued:'بانتظار التشغيل',in_progress:'قيد المعالجة',waiting:'بانتظار موافقة',pending:'بانتظار المعالجة',requested:'طلب تشغيل'};if(run.status!=='completed')return states[run.status]||'غير مكتملة';return {success:'مكتملة بنجاح',failure:'فشلت',cancelled:'أُلغيت',timed_out:'انتهت المهلة',skipped:'تُخطّيت',neutral:'انتهت دون نتيجة نجاح',action_required:'تحتاج إجراءً'}[run.conclusion]||'نتيجة غير معروفة';}
function runDuration(run){if(!run.run_started_at||run.status!=='completed')return '—';const ms=Date.parse(run.updated_at)-Date.parse(run.run_started_at);if(!Number.isFinite(ms)||ms<0)return '—';return Math.floor(ms/60000)+'m '+Math.floor(ms/1000%60)+'s';}
function safeRunLink(value,c){try{const u=new URL(value);return u.protocol==='https:'&&u.hostname==='github.com'&&!u.username&&!u.password&&u.pathname.toLowerCase().startsWith('/'+c.owner.toLowerCase()+'/'+c.repo.toLowerCase()+'/actions/runs/')?u.href:'';}catch{return '';}}
function renderRuns(){
  const box=$('runsList');box.replaceChildren();let c;try{c=currentProcessing();}catch{c={owner:'',repo:'',branch:'',workflow:''};}
  const current=runData&&runContext===workflowKey(c)?runData:null;
  $('runsContext').textContent=c.owner?c.owner+'/'+c.repo+' · '+c.branch+' · '+c.workflow:'راجع إعدادات محرك المعالجة';
  for(const [id,status] of [['runsActive','active'],['runsSuccess','success'],['runsFailed','failed']])$(id).textContent=current?padded(current.filter(r=>runState(r)===status).length):'—';
  $('operationsNavCount').textContent=current?String(current.filter(r=>runState(r)==='active').length):'—';$('runsFetchedAt').textContent=current&&runsFetchedAt?'آخر تحديث: '+formatTime(runsFetchedAt)+' · آخر '+current.length+' عملية':'لم تُجلب عمليات هذه الوجهة بعد';
  const filter=$('runsFilter').value,filtered=current?.filter(r=>filter==='all'||runState(r)===filter);
  if(!filtered?.length){const empty=text('div','','empty runs-empty'),symbol=text('div','','empty-symbol');symbol.append(icon('zap'));empty.append(symbol,text('h3',current?'لا توجد عمليات مطابقة':'تابع العمل من لحظة إرساله.'),text('p',current?'يمكنك تغيير التصفية أو تحديث القائمة.':'اربط محركك، ثم حدّث القائمة لعرض حالات GitHub الفعلية. لا تُنشئ اللوحة عمليات أو إحصاءات تجريبية.'));if(!current)empty.append(button('جلب العمليات',refreshRuns,'refresh','btn'));box.append(empty);return;}
  for(const run of filtered){
    const status=runState(run),row=text('div','','run-row'),symbol=text('div','','run-status-icon '+status);symbol.append(icon(status==='success'?'check':status==='active'?'refresh':'info'));
    const info=text('div','');info.append(text('div',run.display_title||run.name||'معالجة IPA','run-title'),text('div','#'+run.run_number+' · '+run.event+' · '+run.head_branch,'run-sub'));
    row.append(symbol,info,text('span',runLabel(run),'tag '+(status==='success'?'tag-green':status==='active'?'tag-yellow':'tag-red')),text('span',runDuration(run),'run-duration mono'),text('span',formatTime(run.created_at),'run-date'));
    const href=safeRunLink(run.html_url,c);if(href){const link=text('a','','btn btn-ghost icon-btn');link.href=href;link.target='_blank';link.rel='noopener noreferrer';link.setAttribute('aria-label','تفاصيل العملية '+run.run_number);link.append(icon('arrow'));row.append(link);}else row.append(text('span','—','muted'));box.append(row);
  }
}
function applyRaw(){
  try{
    const parsed=JSON.parse($('rawEditor').value),next=normalizeState(parsed),errors=validateState(next);if(errors.length)throw Error(errors.slice(0,5).join('\n'));
    state=next;selectedApps.clear();appPage=1;addActivity('تعديل JSON المتقدم في المسودة');persist();renderAll();$('rawDialog').close();toast('طُبّق JSON على المسودة. راجع الفروق قبل النشر.');
  }catch(error){$('rawError').textContent=error instanceof SyntaxError?'JSON غير صالح: '+error.message:error.message;$('rawError').hidden=false;}
}
function loadNewestLocalDraft(){try{const raw=localStorage.getItem(STORAGE_KEY);if(!raw)throw Error('لا توجد مسودة أحدث على الجهاز.');state=normalizeState(JSON.parse(raw));loadedDraftRaw=raw;externalDraftChanged=false;storageError=false;remoteBaseline=null;baseline=JSON.stringify(normalizeState(createDefaultState()));selectedApps.clear();appPage=1;addActivity('تحميل أحدث مسودة من الجهاز');persist();renderAll();toast('تم تحميل أحدث مسودة. زامن المستودع قبل النشر عند الحاجة.');}catch(error){toast(error.message,'error');}}
function bindStoreEvents(){
  window.addEventListener('storage',event=>{if(event.storageArea!==localStorage||(event.key!==STORAGE_KEY&&event.key!==null))return;try{const raw=localStorage.getItem(STORAGE_KEY);if(raw!==loadedDraftRaw&&raw!==JSON.stringify(state)){externalDraftChanged=true;storageError=true;updateStatus();toast('توجد مسودة أحدث في نافذة أخرى. لم تتغير النسخة المعروضة.','info');}}catch{}});
  $('loadNewestDraft').addEventListener('click',()=>confirmAction('تحميل أحدث مسودة','سيستبدل هذا المسودة المعروضة بأحدث مسودة محفوظة على الجهاز. يمكنك تنزيل نسختك أولاً.',loadNewestLocalDraft,'تحميل الأحدث',false));
  for(const id of ['appSort','appReadiness'])$(id).addEventListener('change',()=>{appPage=1;renderApps();});
  $('selectVisibleApps').addEventListener('change',event=>{for(const app of visibleApps){if(event.target.checked)selectedApps.add(catalogueKey(app));else selectedApps.delete(catalogueKey(app));}renderApps();});
  $('clearSelection').addEventListener('click',()=>{selectedApps.clear();renderApps();});$('bulkCategorize').addEventListener('click',applyBulkCategory);$('bulkDelete').addEventListener('click',deleteSelectedApps);
  $$('[data-upload-mode]').forEach(b=>b.addEventListener('click',()=>setUploadMode(b.dataset.uploadMode)));
  $('ingestFile').addEventListener('change',()=>{const file=$('ingestFile').files?.[0];$('ingestFileLabel').textContent=file?file.name+' · '+bytes(file.size):'اختر ملف IPA من الجهاز';preparedUpload=null;});
  $('ingestForm').addEventListener('submit',prepareIngest);$('sendIngest').addEventListener('click',sendIngest);
  $('refreshRuns').addEventListener('click',refreshRuns);$('runsFilter').addEventListener('change',renderRuns);
  $$('[data-select-icon]').forEach(b=>b.addEventListener('click',()=>{iconTarget=b.dataset.selectIcon;$('iconFile').click();}));
  $('iconFile').addEventListener('change',()=>{const file=$('iconFile').files?.[0];$('iconFile').value='';if(file&&iconTarget)uploadImage(file,iconTarget);});
  $('openRawEditor').addEventListener('click',()=>{$('rawEditor').value=JSON.stringify(state,null,2);$('rawError').hidden=true;$('rawDialog').showModal();});$('applyRaw').addEventListener('click',applyRaw);
  $('restoreDisplay').addEventListener('click',()=>confirmAction('استعادة إعدادات العرض','سيُوقف وضع الصيانة والتحديث الإجباري، وتُستعاد إعدادات حركة الإقلاع الافتراضية في المسودة. تبقى التطبيقات وألوان الهوية كما هي.',()=>{mutate(()=>{state.xsign_config.maintenance.enabled=false;state.xsign_config.force_update.enabled=false;state.xsign_config.splash_screen={...state.xsign_config.splash_screen,...createDefaultState().xsign_config.splash_screen,engine:'native_vector'};},'استعادة إعدادات العرض');syncInputs();},'تطبيق على المسودة',false));
  $$('[data-preset]').forEach(b=>b.addEventListener('click',()=>{const [tint,top,bottom,logo]=b.dataset.preset.split(',');mutate(()=>{Object.assign(state.xsign_config.theme,{app_tint_hex:tint,splash_bg_top_hex:top,splash_bg_bottom_hex:bottom,splash_logo_hex:logo});state.tintColor=tint;},'تغيير لوحة ألوان الهوية',false);syncInputs();renderPreview(true);}));
  $('dockMore').addEventListener('click',()=>setMenu(true));
  $('ingestReviewDialog').addEventListener('cancel',event=>{if(transferBusy)event.preventDefault();});
  $('ingestReviewDialog').addEventListener('close',()=>{if(!transferBusy)preparedUpload=null;});
  // Guard both Escape and close controls during an in-flight external write.
  $$('[data-close-dialog="ingestReviewDialog"]').forEach(b=>b.addEventListener('click',event=>{if(transferBusy){event.stopImmediatePropagation();event.preventDefault();}},true));
  $$('[data-connection]').forEach(el=>el.addEventListener('change',()=>{renderIngestContext();renderRuns();}));
  document.addEventListener('keydown',event=>{if(event.key==='/'&&!event.ctrlKey&&!event.metaKey&&!['INPUT','TEXTAREA','SELECT'].includes(document.activeElement?.tagName)&&!document.querySelector('dialog[open]')){event.preventDefault();openPage('apps');$('appSearch').focus();}});
}
loadLocal();bindEvents();bindStoreEvents();renderAll();openPage(location.hash.slice(1)||'overview',false);
