/* X-SIGN catalogue merging and workflow contracts. No network or DOM access. */
(function(root){
  'use strict';
  const object=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
  const copy=v=>v===undefined?undefined:JSON.parse(JSON.stringify(v));
  const normalize=v=>Array.isArray(v)?v.map(normalize):object(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,normalize(v[k])])):v;
  const same=(a,b)=>JSON.stringify(normalize(a))===JSON.stringify(normalize(b));
  class Conflict extends Error { constructor(path,base,local,remote){super('تعارض في '+(path||'الملف')+'؛ تغيّر الحقل محلياً وعلى GitHub.');this.name='MergeConflict';this.path=path;this.base=copy(base);this.local=copy(local);this.remote=copy(remote);} }
  function safeTree(value,depth=0,parents=new Set(),budget={nodes:0}){
    if(depth>50||++budget.nodes>100000)throw Error('بنية الملف تتجاوز حدود الفحص.');
    if(value&&typeof value==='object'){
      if(parents.has(value))throw Error('الملف يحتوي على مرجع دائري.');parents.add(value);
      for(const [key,item] of Object.entries(value)){if(['__proto__','constructor','prototype'].includes(key))throw Error('اسم حقل محظور: '+key);safeTree(item,depth+1,parents,budget);}parents.delete(value);
    }
  }
  function appKeyFunction(lists){
    const uniqueBundles=lists.every(list=>new Set(list.map(r=>r.bundleIdentifier)).size===list.length);
    if(uniqueBundles)return row=>row.bundleIdentifier;
    if(lists.every(list=>list.every(r=>typeof r.catalogID==='string'&&r.catalogID)&&new Set(list.map(r=>r.catalogID)).size===list.length))return row=>row.catalogID;
    throw Error('توجد نسخ بالـ Bundle ID نفسه دون catalogID ثابت. يلزم تصحيح المعرفات قبل الدمج.');
  }
  function keyFor(path,lists){const leaf=path.split('.').at(-1);if(leaf==='apps')return appKeyFunction(lists);if(['xsign_config.dashboard.sources','xsign_config.dashboard.sections'].includes(path))return row=>row.id;const key={categories:'id',news:'identifier',core_sources:'id',versions:'version'}[leaf];return key?row=>row[key]:null;}
  function mapRecords(list,key,path){const map=new Map();for(const row of list){const id=key(row);if(typeof id!=='string'||!id||map.has(id))throw Error('معرف مكرر أو مفقود في '+path);map.set(id,row);}return map;}
  function merge(base,local,remote,path=''){
    if(same(local,base))return copy(remote);
    if(same(remote,base)||same(local,remote))return copy(local);
    if([base,local,remote].every(object)){
      const out={};
      for(const key of new Set([...Object.keys(base),...Object.keys(local),...Object.keys(remote)])){
        if(['__proto__','constructor','prototype'].includes(key))throw Error('اسم حقل غير مسموح.');
        if(!path&&key==='repo_revision_id')continue;
        const result=merge(base[key],local[key],remote[key],path?path+'.'+key:key);if(result!==undefined)out[key]=result;
      }
      return out;
    }
    if([base,local,remote].every(Array.isArray)){
      const key=keyFor(path,[base,local,remote]);
      if(key){
        const b=mapRecords(base,key,path),l=mapRecords(local,key,path),r=mapRecords(remote,key,path),out=new Map();
        for(const id of new Set([...b.keys(),...l.keys(),...r.keys()])){const result=merge(b.get(id),l.get(id),r.get(id),path+'['+id+']');if(result!==undefined)out.set(id,result);}
        const sequence=list=>list.map(key).filter(id=>b.has(id)&&out.has(id));
        const initial=base.map(key).filter(id=>out.has(id)),lo=sequence(local),ro=sequence(remote);
        const lc=!same(initial,lo),rc=!same(initial,ro);
        if(lc&&rc&&!same(lo,ro))throw new Conflict(path+'.order',initial,lo,ro);
        const first=lc?local:remote,second=lc?remote:local;
        const keys=[...remote.map(key).filter(id=>!b.has(id)&&!l.has(id)),...first.map(key),...second.map(key)];
        return [...new Set(keys)].filter(id=>out.has(id)).map(id=>out.get(id));
      }
    }
    throw new Conflict(path,base,local,remote);
  }
  function project(data){const keys=['name','identifier','subtitle','description','iconURL','tintColor','repo_revision_id','xsign_config','categories'];return Object.fromEntries(keys.filter(k=>k in data).map(k=>[k,copy(data[k])]));}
  function summary(base,data){
    const lists={};for(const field of ['apps','categories','news']){
      const before=Array.isArray(base?.[field])?base[field]:[],after=Array.isArray(data[field])?data[field]:[];
      const key=keyFor(field,[before,after]);const a=mapRecords(before,key,field),b=mapRecords(after,key,field);
      lists[field]={added:[...b.keys()].filter(k=>!a.has(k)).length,removed:[...a.keys()].filter(k=>!b.has(k)).length,updated:[...b.keys()].filter(k=>a.has(k)&&!same(a.get(k),b.get(k))).length};
    }
    const fields=[];
    function walk(a,b,path=''){if(same(a,b))return;if(object(a)&&object(b)){for(const key of new Set([...Object.keys(a),...Object.keys(b)])){if(key==='repo_revision_id'&&!path)continue;walk(a[key],b[key],path?path+'.'+key:key);}}else fields.push(path||'root');}
    walk(base||{},data);return {lists,fields,total:fields.length};
  }
  const https=value=>{try{const u=new URL(value);return u.protocol==='https:'&&!u.username&&!u.password&&!!u.hostname;}catch{return false;}};
  function scalarPattern(pattern,value){
    if(typeof pattern!=='string'||/[\[\]{}()+\\]/.test(pattern))throw Error('نمط تشغيل متقدم؛ راجع شروط الفرع والمسار في ملف المعالجة.');
    let regex='';for(let i=0;i<pattern.length;i++){const c=pattern[i];if(c==='*'&&pattern[i+1]==='*'){regex+='.*';i++;}else if(c==='*')regex+='[^/]*';else if(c==='?')regex+='[^/]';else regex+=c.replace(/[.^$|]/g,'\\$&');}
    return new RegExp('^'+regex+'$').test(value);
  }
  function patternsMatch(patterns,value,defaultValue=true){if(patterns===undefined)return defaultValue;if(!Array.isArray(patterns))throw Error('قائمة شروط تشغيل غير صالحة.');let matched=false;for(const p of patterns){if(typeof p!=='string')throw Error('شرط تشغيل غير صالح.');const negative=p.startsWith('!');if(scalarPattern(negative?p.slice(1):p,value))matched=!negative;}return matched;}
  function readWorkflow(source,yaml){
    if(typeof source!=='string'||source.length>300000)throw Error('ملف المعالجة مفقود أو أكبر من حد الفحص.');
    const workflow=yaml.load(source,{schema:yaml.JSON_SCHEMA,json:false});safeTree(workflow);
    if(!object(workflow))throw Error('ملف المعالجة ليس Workflow صالحاً.');
    const events=typeof workflow.on==='string'?{[workflow.on]:{}}:Array.isArray(workflow.on)?Object.fromEntries(workflow.on.map(k=>[k,{}])):workflow.on;
    if(!object(events))throw Error('ملف المعالجة لا يعرّف أحداث تشغيل واضحة.');
    const dispatch=Object.prototype.hasOwnProperty.call(events,'workflow_dispatch');
    const inputs=object(events.workflow_dispatch?.inputs)?events.workflow_dispatch.inputs:{};
    const steps=Object.values(workflow.jobs||{}).flatMap(job=>Array.isArray(job.steps)?job.steps:[]);
    const texts=[source,...steps.filter(s=>typeof s.run==='string').map(s=>s.run)];
    const scripts=[];for(const s of steps)for(const match of String(s.run||'').matchAll(/\bpython(?:3)?\s+(?:-u\s+)?([A-Za-z0-9_./-]+\.py)\b/g))if(!match[1].startsWith('/')&&!match[1].split('/').includes('..'))scripts.push(match[1]);
    return {workflow,events,inputs,dispatch,steps,texts,scripts:[...new Set(scripts)],source};
  }
  function dispatchInputs(engine,values){
    if(!engine.dispatch||!engine.inputs.ipa_url)throw Error('المحرك لا يعرّف workflow_dispatch بمدخل ipa_url.');
    if(!https(values.ipa_url))throw Error('رابط IPA يجب أن يكون HTTPS.');
    const out={};for(const [name,spec] of Object.entries(engine.inputs)){
      if(!object(spec))throw Error('تعريف مدخل غير مدعوم: '+name);
      let value=values[name];
      if(value===undefined){if(spec.required===true&&spec.default===undefined)throw Error('المحرك يحتاج مدخلاً إضافياً: '+name);continue;}
      if(spec.type==='boolean'){if(typeof value==='string')value=value==='true';if(typeof value!=='boolean')throw Error('قيمة غير صالحة: '+name);}
      else if(spec.type==='number'){value=Number(value);if(!Number.isFinite(value))throw Error('قيمة رقمية غير صالحة: '+name);}
      else value=String(value);
      if(spec.type==='choice'&&(!Array.isArray(spec.options)||!spec.options.includes(value)))throw Error('المحرك لا يدعم قيمة '+value+' للمدخل '+name);
      out[name]=value;
    }
    if(Object.keys(out).length>25||JSON.stringify(out).length>65000)throw Error('مدخلات المعالجة أكبر من الحد المسموح.');return out;
  }
  function fileContract(engine,branch,path,adapter='auto',scripts=[]){
    if(!Object.prototype.hasOwnProperty.call(engine.events,'push'))throw Error('المحرك لا يدعم التشغيل عند رفع ملف إلى المستودع.');
    const push=engine.events.push||{};
    if(push.branches!==undefined&&!patternsMatch(push.branches,branch))throw Error('فرع المعالجة لا يطابق شرط push.branches.');
    if(push['branches-ignore']&&patternsMatch(push['branches-ignore'],branch,false))throw Error('الفرع مستثنى من تشغيل المعالجة.');
    if(push.paths!==undefined&&!patternsMatch(push.paths,path))throw Error('مسار IPA لا يطابق شرط تشغيل المعالجة.');
    if(push['paths-ignore']&&patternsMatch(push['paths-ignore'],path,false))throw Error('المسار مستثنى من المعالجة.');
    for(const step of engine.steps)if(/^actions\/checkout@/.test(step.uses||'')&&typeof step.with?.ref==='string'&&!step.with.ref.includes('${{')&&step.with.ref!==branch)throw Error('المحرك يسحب فرعاً ثابتاً مختلفاً: '+step.with.ref);
    const all=[...engine.texts,...scripts].join('\n');
    let detected='';if(/uploads\/meta\.json/.test(all))detected='legacy';
    if(/XSIGN_STUDIO_UPLOAD_SCHEMA\s*[:=]\s*["']?sidecar-v1/.test(all)||/with_suffix\(["']\.json["']\)/.test(all)||/\$\{[^}]+%\.ipa\}\.json/.test(all))detected='sidecar';
    const mode=adapter==='auto'?detected:adapter;if(!['legacy','sidecar'].includes(mode))throw Error('تعذر تحديد عقد بيانات الرفع. راجع المحرك أو اختر العقد المعروف في إعدادات المعالجة.');
    return {mode,detected,manual:adapter!=='auto',metadataPath:mode==='legacy'?'uploads/meta.json':path.replace(/\.ipa$/i,'.json')};
  }
  root.XSignStore={copy,same,safeTree,merge,Conflict,project,summary,https,readWorkflow,dispatchInputs,fileContract,patternsMatch,appKeyFunction};
  if(typeof module!=='undefined')module.exports=root.XSignStore;
})(globalThis);
