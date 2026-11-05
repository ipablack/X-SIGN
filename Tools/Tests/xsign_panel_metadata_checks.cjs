const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('Tools/XSign_Studio.html', 'utf8');
let script = html.split('<script>')[1].split('</script>')[0];
const boot = script.indexOf("$('cfg-repo').value = localStorage");
assert(boot > 0, 'Missing panel boot boundary');
script = script.slice(0, boot);
const elements = new Map();
const document = {getElementById(id) {
  if (!elements.has(id)) elements.set(id, {value:'', checked:false, addEventListener(){}});
  return elements.get(id);
}};
const context = vm.createContext({document, structuredClone, URL, TextEncoder, TextDecoder});
vm.runInContext(script, context);
vm.runInContext(`
  repoData = {apps: [], xsign_config:{security_locks:{lock_bundle_rename:true}}};
  for (const field of fields) {
    if (field.type === 'checkbox') $(field.id).checked = field.value;
    else $(field.id).value = String(field.value);
  }
`, context);
let collected = vm.runInContext('collect()', context);
assert.equal(collected.xsign_config.security_locks.allow_app_metadata_editing, true);
assert.equal(collected.xsign_config.security_locks.lock_bundle_rename, false);
vm.runInContext("$('sec-lock-rename').checked=false", context);
collected = vm.runInContext('collect()', context);
assert.equal(collected.xsign_config.security_locks.allow_app_metadata_editing, false);
assert.equal(collected.xsign_config.security_locks.lock_bundle_rename, true);
assert.throws(() => vm.runInContext(`C.validate({apps:[],xsign_config:{security_locks:{allow_app_metadata_editing:'true'}}})`, context));
console.log('PASS: actual panel writes metadata permission and legacy compatibility flags coherently');
