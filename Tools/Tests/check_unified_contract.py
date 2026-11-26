"""Check shared release inputs, real panel output, and producer/consumer locations."""
from pathlib import Path
import json
import plistlib

root = Path(__file__).resolve().parents[2]
contract = json.loads((root / 'Tools/Integration/contract.json').read_text())
example = json.loads((root / 'Tools/Delivery/repo.example.json').read_text())
assert contract['app_version'] == '1.0'
assert contract['default_build_number'] == 'workflow_run_number'
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
registry = json.loads((root / contract['public_source_registry']).read_text())
assert registry['catalog_profile'] == contract['catalog_profile']
assert len(registry['items']) == 6
assert len([item for item in registry['items'] if item['enabled']]) == 3
assert all(item['enabled'] == (item['state'] == 'available') for item in registry['items'])
assert [s['url'] for s in sources if s.get('enabled') is not False] == contract['active_source_urls']
assert not (root / 'Feather/Resources/XSignSoonLaunchPreview.json').exists()
endpoint = (root/'Feather/Utilities/XSignCatalogueEndpoint.swift').read_text()
assert '"xsign-catalog://owner"' in endpoint
assert 'activateGatewayAccess' not in endpoint and 'gatewayAccessCredential' not in endpoint
assert 'XSign-Client' not in endpoint and 'XSIGN_PRIVATE_CATALOG' not in endpoint
assert 'url.host == "catalog-access"' not in (root/'Feather/FeatherApp.swift').read_text()
assert 'https://raw.githubusercontent.com/' not in endpoint
assert not any('الوصول إلى المتجر' in p.read_text() or 'XSignCatalogAccess' in p.read_text()
               for p in (root/'Feather').rglob('*.swift'))
# The checks run after the workflow applies its embedded source to a fresh checkout.
# A file present in the ZIP can still be missing from that embedded update.
storage = (root / 'Feather/Backend/Storage/Storage+Imported.swift').read_text()
background_tasks = (root / 'Feather/Utilities/BackgroundTaskManager.swift').read_text()
assert 'func deleteInterruptedImport(uuid: String)' in storage, (
    'The embedded update must include Storage+Imported.swift alongside the download cancellation callers.')
assert 'cancel(taskRequestWithIdentifier: taskIdentifier)' in background_tasks, (
    'The embedded update must include BackgroundTaskManager.swift to cancel queued iOS downloads.')
assert [source['id'] for source in sources] == ['xsign.core.owned', 'xsign.core.primary']
assert example['apps'] == [], 'An example cannot replace a live catalogue with invented apps.'
assert all(field in example['xsign_config']['dashboard']['update'] for field in contract['publisher_to_update_fields'].values())
preview = root / 'Tools/StudioSource/src/XSignInstall.html'
native_template = root / 'Feather/Resources/XSignUpdateScreen.html'
assert native_template.read_bytes() == preview.read_bytes(), 'Studio and the app must use the same installation template.'
panel = (root / 'Tools/StudioSource/dist/index.html').read_bytes()
assert panel == (root / 'Tools/XSign_Studio.html').read_bytes() == (root / 'Tools/XSign_Studio_v2.html').read_bytes()
assert b'studioPushForm' in panel and b'studioPushTitle-ckb' in panel
settings = (root / 'Feather/Views/Settings/SettingsView.swift').read_text()
assert settings.index('_feedback()') < settings.index('XSignLanguageMenu()')
assert not any((root / path).exists() for path in (
    'Feather/Views/Settings/XSignFileManagerView.swift',
    'Feather/Views/Signing/XSignSigningJournal.swift'))
assert b'managedSourceForm' in panel and 'مصدران ثابتان'.encode() not in panel
info = plistlib.loads((root / 'Feather/Resources/Info.plist').read_bytes())
assert info.get('UIFileSharingEnabled') is False
updater = (root / 'Feather/Views/Settings/XSignAppUpdateView.swift').read_text()
assert 'FR.importPackageFile' not in updater and 'NSFetchRequest' not in updater, (
    'Self-update packages must stay outside the visible library.')
assert 'ZsignHandler(appUrl: appDirectory' in updater and 'handler.sign(with: credentials)' in updater
stages = ['XSignSelfUpdateCertificate.select(', 'XSignUpdateFileDownload.fetch(', 'guard hash == expected.lowercased()', 'XSignIPAExtractor.extract(', 'removeItem(at: file)', 'handler.sign(with: credentials)']
positions = [updater.index(stage) for stage in stages]
assert positions == sorted(positions), 'Check the certificate before downloading, verify bytes before unpacking, then reclaim disk before signing.'
assert 'signedProfile.canReplace(installed' in updater
assert not any(option in updater for option in ('Mango', 'LCSign', 'exportForSigning', 'XSignUpdateExport'))
assert 'button: xsignText("تثبيت")' in updater and 'XSignOTAInstaller(confirmationTimeout: 90)' in updater
project = (root / 'Feather.xcodeproj/project.pbxproj').read_text()
assert project.count('INFOPLIST_KEY_CFBundleDisplayName = "$(XSIGN_APP_DISPLAY_NAME)";') == 2
template = json.loads((root / 'Tools/Delivery/workflow.template.json').read_text())
build_steps = template['jobs']['build']['steps']
build = next(step for step in build_steps if step.get('name') == 'Build and verify the iOS application')
assert 'XSign_Release.py build' in build['run'] and contract['original_interface_revision'] in build['env']['XSIGN_ORIGINAL_UI']
assert 'GITHUB_RUN_NUMBER' in (root / 'Tools/XSign_Release.py').read_text()
assert set(template['jobs']) == {'preflight', 'build', 'apply_source'}
assert template['permissions'] == {'contents': 'read'}
assert b'xsign-build.json' in panel and b'xsign-inspect-ipa' in panel
assert not any('git push' in step.get('run', '') or 'Bootstrap_Source_Repository' in step.get('run', '') for name, job in template['jobs'].items() if name != 'apply_source' for step in job['steps'])
for name in ['preflight', 'build']:
    steps = template['jobs'][name]['steps']
    deps = [i for i, s in enumerate(steps) if s.get('working-directory') == 'Tools/StudioSource' and 'npm ci' in s.get('run', '')]
    checks = [i for i, s in enumerate(steps) if 'xsign_studio_v2_checks.cjs' in s.get('run', '')]
    assert deps and (name == 'build' or checks and min(deps) < min(checks)), 'Studio dependencies must be installed before its build and tests.'
print('PASS: app 1.0, live panel outputs, source template, native bindings, updater fields and independent-runner dependency contract')

dispatch = template['on']['workflow_dispatch']['inputs']
assert set(dispatch) == {'apply_source'} and dispatch['apply_source']['default'] is False
source_job = template['jobs']['apply_source']
assert source_job['permissions'] == {'contents': 'write'}
assert "github.event_name == 'workflow_dispatch' && inputs.apply_source" in source_job['if']
assert 'github.event.repository.default_branch' in source_job['if']
assert '!inputs.apply_source' in template['jobs']['preflight']['if']
stage = next(step for step in source_job['steps'] if step.get('name') == 'Commit and push to the selected branch')
assert 'git push origin "HEAD:$GITHUB_REF"' in stage['run'] and '--force' not in stage['run']
assert template['on']['push'] == {'branches': ['main'], 'paths': [contract['studio_build']['settings_file']]}
assert template['on']['repository_dispatch']['types'] == [contract['studio_build']['inspection_event'], 'xsign-publish-ipa']
assert not any('inputs.studio' in str(step) or 'inputs.ipa_url' in str(step) for job in template['jobs'].values() for step in job['steps'])
assert info.get('XSignStudioBuildRequest') == '$(XSIGN_STUDIO_BUILD_REQUEST)'
assert template['jobs']['build']['runs-on'] == "${{ needs.preflight.outputs.runner }}"
assert "macos-26-intel|macos-15-intel" in next(step['run'] for step in template['jobs']['preflight']['steps'] if step.get('id') == 'release_settings')
print('PASS: Studio saves exact build settings, the manual source job cannot publish an IPA, and the IPA verification event is separate')

personal = next(step for step in build_steps if step.get('id') == 'owner_release')
assert "owner_draft == 'true'" in personal['if'] and "publish == 'false'" in personal['if']
assert '-F draft=true' in personal['run']
for step in build_steps:
    path = step.get('with', {}).get('path', '')
    if 'xcresult' in path:
        assert "owner_draft == 'false'" in path
    if 'X-SIGN.ipa' in path:
        assert "owner_draft == 'false'" in step['if']
receipt = next(step for step in build_steps if 'XSign-draft-' in step.get('with', {}).get('name', ''))
assert receipt['if'] == personal['if'] and receipt['with']['path'] == 'packages/BUILD_MODE.txt'

security = (root / 'Feather/FeatherApp.swift').read_text()
assert 'packageNetworkFailure: String? { isVPNOrProxyDetected ?' in security
assert 'if blocked { stopProtectedTransfers(Self.vpnFailure) }' in security
assert 'if detected { stopProtectedTransfers(' not in security
catalogue = (root / 'Feather/Views/Sources/SourcesView.swift').read_text()
assert 'XSignStoreCataloguePage(page: "apps")' in catalogue
assert 'XSignStoreCataloguePage(page: "games")' in catalogue
