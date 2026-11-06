"""Check shared release inputs, real panel output, and producer/consumer locations."""
from pathlib import Path
import json
import plistlib

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
assert [s['url'] for s in example['xsign_config']['app_control']['core_sources']] == contract['source_priority']
assert contract['config_url'] == contract['source_priority'][0]
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
