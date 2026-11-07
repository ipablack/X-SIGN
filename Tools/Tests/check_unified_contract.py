"""Check shared release inputs, real panel output, and producer/consumer locations."""
from pathlib import Path
import json
import plistlib
import re

root = Path(__file__).resolve().parents[2]
contract = json.loads((root / 'Tools/Integration/contract.json').read_text())
example = json.loads((root / 'Tools/Delivery/repo.example.json').read_text())
assert contract['app_version'] == '1.0'
assert contract['default_build_number'] == 1
assert 'FEATHER_PROJECT_VERSION=1.0' in (root / 'Feather.xcconfig').read_text()
assert contract['minimum_ios'] == '15.0'
assert contract['canonical_workflow'] == 'XSign_Full_Link.yml'
for key, relative in contract['bindings'].items():
    assert (root / relative).is_file(), (key, relative)
    value = example
    for field in key.split('.'):
        assert isinstance(value, dict) and field in value, key
        value = value[field]
sources = example['xsign_config']['dashboard']['sources']
assert [s['url'] for s in sources] == contract['source_priority']
assert [s['url'] for s in example['xsign_config']['app_control']['core_sources']] == contract['active_source_urls']
assert contract['config_url'] == contract['source_priority'][0]
registry = json.loads((root / contract['public_source_registry']).read_text())
assert registry['catalog_profile'] == contract['catalog_profile']
assert len(registry['items']) == 6
assert len([item for item in registry['items'] if item['enabled']]) == 3
assert all(item['enabled'] == (item['state'] == 'available') for item in registry['items'])
assert [s['url'] for s in sources if s.get('enabled') is not False] == contract['active_source_urls']
swift = (root / 'Feather/Utilities/XSignDashboardPolicy.swift').read_text()
definition = swift.split('static let iosboomSources:', 1)[1].split('static let profileKey', 1)[0]
native = [dict(id=json.loads(i), name=json.loads(n), url=json.loads(u), enabled=e == 'true')
    for i, n, u, e in re.findall(r'\.init\(id:("[^"]+"),name:("[^"]+"),url:("[^"]+"),enabled:(true|false)\)', definition)]
assert native == [{key: item[key] for key in ['id','name','url','enabled']} for item in registry['items']]
assert [{key: item[key] for key in ['id','name','url','enabled','format']} for item in registry['items']] == sources[3:]
assert example['apps'] == [], 'An example cannot replace a live catalogue with invented apps.'
assert all(field in example['xsign_config']['dashboard']['update'] for field in contract['publisher_to_update_fields'].values())
panel = (root / 'Tools/StudioSource/dist/index.html').read_bytes()
assert panel == (root / 'Tools/XSign_Studio.html').read_bytes() == (root / 'Tools/XSign_Studio_v2.html').read_bytes()
assert b'managedSourceForm' in panel and 'مصدران ثابتان'.encode() not in panel
info = plistlib.loads((root / 'Feather/Resources/Info.plist').read_bytes())
assert info.get('UIFileSharingEnabled') is False
project = (root / 'Feather.xcodeproj/project.pbxproj').read_text()
assert project.count('INFOPLIST_KEY_CFBundleDisplayName = XSign;') == 2
template = json.loads((root / 'Tools/Delivery/workflow.template.json').read_text())
for name in ['preflight', 'build']:
    steps = template['jobs'][name]['steps']
    deps = [i for i, s in enumerate(steps) if s.get('working-directory') == 'Tools/StudioSource' and 'npm ci' in s.get('run', '')]
    checks = [i for i, s in enumerate(steps) if 'xsign_studio_v2_checks.cjs' in s.get('run', '')]
    assert deps and checks and min(deps) < min(checks), 'Each independent runner needs its own dashboard test dependencies.'
print('PASS: app 1.0, live panel outputs, source template, native bindings, updater fields and independent-runner dependency contract')

runner=template["on"]["workflow_dispatch"]["inputs"]["macos_runner"]
assert runner["default"]=="macos-15-intel"
assert runner["options"]==["macos-15-intel","macos-26-intel"]
assert template["jobs"]["build"]["runs-on"]=="${{ inputs.macos_runner || 'macos-15-intel' }}"
print("PASS: default and fallback runners use supported standard Intel labels, without the affected ARM64/latest pool")
