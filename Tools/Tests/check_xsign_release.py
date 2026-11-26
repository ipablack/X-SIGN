"""Exercise the Studio build inputs and the release verifier without using Xcode or GitHub."""
from pathlib import Path
from contextlib import redirect_stdout
import hashlib
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools'))
import XSign_Release as release
import XSign_Publish_Update as publication


class ReleaseChecks(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.work = Path(work.name)
        self.package = self.work / 'X-SIGN.ipa'
        self.settings = release.read_settings({'appName': 'تطبيق XSign & Studio', 'bundleIdentifier': 'com.test.studio',
                                                'version': '1.4.2', 'buildVersion': '75'}, '22')

    def make_fixture(self, bundled=(), **extra):
        info = {'CFBundleDisplayName': self.settings['appName'], 'CFBundleName': self.settings['appName'],
                'CFBundleIdentifier': self.settings['bundleIdentifier'], 'CFBundleShortVersionString': self.settings['version'],
                'CFBundleVersion': self.settings['buildVersion'], 'CFBundleExecutable': 'XSign', 'MinimumOSVersion': '15.0',
                'XSignStudioRelease': True, 'XSignReleaseOrigin': '', 'UIFileSharingEnabled': False,
                'CFBundleIcons': {'CFBundlePrimaryIcon': {'CFBundleIconName': 'AppIcon'}}, **extra}
        with zipfile.ZipFile(self.package, 'w') as archive:
            archive.writestr('Payload/X-SIGN.app/Info.plist', plistlib.dumps(info))
            archive.writestr('Payload/X-SIGN.app/XSign', b'\xcf\xfa\xed\xfe' + bytes(8192))
            for path, data in bundled:
                archive.writestr('Payload/X-SIGN.app/' + path, data)

    def test_private_queue_reports_missing_settings_without_logging_payload(self):
        event = self.work / 'event.json'
        request_id = 'ab' * 16
        event.write_text(json.dumps({'repository': {'private': False}, 'action': 'xsign-inspect-ipa',
                                     'client_payload': {'request_id': request_id}}))
        result = subprocess.run([sys.executable, str(ROOT / 'Tools/XSign_Private_Queue.py')],
                                env={**os.environ, 'GITHUB_EVENT_PATH': str(event),
                                     'XSIGN_IPA_STORAGE_TOKEN': '', 'XSIGN_CATALOG_REPOSITORY': ''},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('::error::Set XSIGN_IPA_STORAGE_REPOSITORY', result.stdout)
        self.assertNotIn(request_id, result.stdout + result.stderr)

    def test_legacy_cloudflare_setting_does_not_affect_build(self):
        settings = release.read_settings({'catalogOrigin': 'https://old.example.test', 'appName': 'Xsign'}, '24')
        self.assertNotIn('catalogOrigin', settings)
        self.assertEqual(settings['appName'], 'Xsign')

    def test_automatic_policy_preserves_html_and_rejects_out_of_order_builds(self):
        old = {'latest_version': '1.0', 'build_version': '5', 'html': '<h1>Update</h1>'}
        dashboard = {'schema_version': 2, 'bundle_updates': {'xsign': old}, 'update': {'enabled': False}}
        data = {'repo_revision_id': 31, 'xsign_config': {'dashboard': dashboard, 'usage_stats': {'enabled': True}}}
        info = {'bundleIdentifier': 'Xsign', 'appName': 'XSign', 'version': '1.0', 'buildVersion': '6',
                'sha256': 'a'*64, 'buildRequestID': 'a'*32}
        url = 'https://github.com/ipablack/repo/releases/download/build/X-SIGN.ipa'
        self.assertTrue(publication.update_policy(data, info, url))
        result = dashboard['bundle_updates']['xsign']
        self.assertTrue(result['required'])
        self.assertEqual(result['required_policy'], 'minimum')
        self.assertEqual(result['html'], old['html'])
        self.assertEqual(data['repo_revision_id'], 32)
        self.assertFalse(publication.update_policy(data, info, url))
        with self.assertRaisesRegex(ValueError, 'Increase the build number'):
            publication.update_policy(data, dict(info, sha256='b'*64, buildVersion='4'), url)
        self.assertTrue(data['xsign_config']['usage_stats']['enabled'])

    def test_publishing_paused_asset_reactivates_its_update(self):
        info = {'bundleIdentifier': 'Xsign', 'appName': 'XSign', 'version': '1.0', 'buildVersion': '33',
                'sha256': 'a' * 64, 'buildRequestID': 'b' * 32}
        old = {'latest_version': '1.0', 'build_version': '33', 'sha256': info['sha256'],
               'enabled': False, 'required': False}
        dashboard = {'schema_version': 2, 'bundle_updates': {'xsign': old}, 'update': old}
        data = {'repo_revision_id': 46, 'xsign_config': {'dashboard': dashboard}}
        url = 'https://example.test/X-SIGN.ipa'
        self.assertTrue(publication.update_policy(data, info, url))
        self.assertEqual(data['repo_revision_id'], 47)
        self.assertTrue(dashboard['bundle_updates']['xsign']['enabled'])
        self.assertTrue(dashboard['update']['required'])
        self.assertFalse(publication.update_policy(data, info, url))

    def test_build_distribution_validates_visibility_and_secret_before_preparation(self):
        config = self.work / 'xsign-build.json'
        output = self.work / 'validated.json'
        result_path = self.work / 'outputs'
        for target, event, private, secret, expected in [
                ('private', 'push', 'true', 'true', 'false'),
                ('private', 'push', 'false', 'false', 'false'),
                ('release', 'push', 'false', 'false', 'false'),
                ('everyone', 'workflow_dispatch', 'false', 'false', 'false'),
                ('everyone', 'push', 'false', 'true', 'true'),
                ('everyone', 'push', 'true', 'false', 'XSIGN_RELEASE_PUBLISH_TOKEN'),
                ('everyone', 'workflow_dispatch', 'true', 'true', 'false')]:
            with self.subTest(target=target, event=event, private=private, secret=secret):
                config.write_text(json.dumps({'schema_version': 1, 'request_id': 'a'*32, 'settings': {
                    'appName': 'Xsign', 'bundleIdentifier': 'Xsign', 'version': '1.0', 'delivery': target}}))
                result_path.write_text('')
                env = dict(os.environ, GITHUB_ACTIONS='true', GITHUB_EVENT_NAME=event, GITHUB_OUTPUT=str(result_path),
                           XSIGN_BUILD_REPO_PRIVATE=private, XSIGN_RELEASE_PUBLISH_READY=secret)
                run = subprocess.run([sys.executable, str(ROOT/'Tools/XSign_Release.py'), 'validate', str(output),
                                      '--studio-file', str(config)], env=env, capture_output=True, text=True)
                if expected in ('true', 'false'):
                    self.assertEqual(run.returncode, 0, run.stderr)
                    public = target == 'release' or expected == 'true'
                    draft = str(not public and private != 'true').lower()
                    self.assertEqual(result_path.read_text(), f'publish={expected}\nowner_draft={draft}\npublic_release={str(public).lower()}\n')
                else:
                    self.assertNotEqual(run.returncode, 0)
                    self.assertIn(expected, run.stderr)
                    self.assertEqual(result_path.read_text(), '')

    def test_default_build_keeps_release_version_and_uses_run_number(self):
        settings = release.read_settings({}, '24')
        self.assertEqual((settings['appName'], settings['bundleIdentifier'], settings['version'], settings['buildVersion']),
                         ('Xsign', 'Xsign', '1.0', '24'))
        self.assertEqual(settings['releaseOrigin'], '')

    def test_clear_validation_of_earlier_failure_inputs(self):
        invalid = {'appName': '$(COMMAND)', 'bundleIdentifier': 'wrong id', 'version': '1.0-beta',
                   'buildVersion': '0.0', 'iconURL': 'http://example.com/icon.png', 'manifestURL': 'https://example.com/m#x'}
        for key, value in invalid.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.read_settings({key: value}, '18')
        stamp = 'https://example.com/manifest.plist'
        self.assertEqual(release.read_settings({'manifestURL': stamp}, '18')['releaseOrigin'], hashlib.sha256(stamp.encode()).hexdigest())

    def test_saved_settings_are_read_without_workflow_inputs(self):
        saved = self.work / 'xsign-build.json'
        request = '3' * 32
        record = {'schema_version': 1, 'request_id': request, 'settings': {
            'appName': 'نسخة XSign', 'bundleIdentifier': 'com.test.studio', 'version': '2.2',
            'buildVersion': '19', 'iconURL': 'https://example.com/icon.png'}}
        release.write_json(saved, record)
        result = release.read_studio_settings(saved, '25')
        self.assertEqual(result['appName'], 'نسخة XSign')
        self.assertEqual(result['version'], '2.2')
        self.assertEqual(result['buildVersion'], '19')
        self.assertEqual(result['requestID'], request)
        del record['settings']['buildVersion']
        release.write_json(saved, record)
        self.assertEqual(release.read_studio_settings(saved, '25')['buildVersion'], '25')
        saved.write_text('{')
        with self.assertRaisesRegex(ValueError, 'valid UTF-8 JSON'):
            release.read_studio_settings(saved, '25')

    def test_inspection_event_accepts_only_the_direct_link_and_request_id(self):
        event = self.work / 'event.json'
        request = '3' * 32
        link = 'https://example.com/releases/xsign.ipa'
        release.write_json(event, {'client_payload': {'request_id': request, 'ipa_url': link}})
        self.assertEqual(release.read_inspection_event(event), (request, link))
        release.write_json(event, {'client_payload': {'request_id': request, 'ipa_url': link, 'version': '2.0'}})
        with self.assertRaisesRegex(ValueError, 'Invalid inspection request'):
            release.read_inspection_event(event)

    @staticmethod
    def install_template():
        return ('XSignUpdateScreen.html', (ROOT / 'Feather/Resources/XSignUpdateScreen.html').read_bytes())

    def test_build_rejects_a_missing_or_mismatched_studio_install_template(self):
        for entries in ([], [('XSignUpdateScreen.html', b'outdated template')]):
            with self.subTest(entries=entries):
                with patch.object(release.subprocess, 'run', side_effect=lambda *a, **k: self.make_fixture(bundled=entries)):
                    with self.assertRaisesRegex(ValueError, 'missing the Studio installation template'):
                        release.build_ipa(self.settings, self.package, self.work)

    def test_built_ipa_has_the_same_release_request_as_the_panel(self):
        settings = {**self.settings, 'requestID': '1' * 32}
        def make(command, env, check):
            self.assertEqual(env['XSIGN_STUDIO_BUILD_REQUEST'], settings['requestID'])
            self.make_fixture(bundled=[self.install_template()], XSignStudioBuildRequest=env['XSIGN_STUDIO_BUILD_REQUEST'])
        with patch.object(release.subprocess, 'run', side_effect=make):
            self.assertEqual(release.build_ipa(settings, self.package, self.work)['buildRequestID'], settings['requestID'])

    def test_ipa_verifier_uses_embedded_identity_and_exact_file_fingerprint(self):
        self.make_fixture()
        info = release.inspect_ipa(self.package, require_xsign=True)
        self.assertTrue(info['isXSign'])
        self.assertEqual(info['bundleIdentifier'], 'com.test.studio')
        self.assertEqual(info['appName'], 'تطبيق XSign & Studio')
        self.assertEqual(info['version'], '1.4.2')
        self.assertEqual(info['buildVersion'], '75')
        self.assertEqual(info['sha256'], hashlib.sha256(self.package.read_bytes()).hexdigest())
        self.make_fixture(MinimumOSVersion='16.0')
        with self.assertRaisesRegex(ValueError, 'iOS 15'):
            release.inspect_ipa(self.package, require_xsign=True)

    def test_post_xcode_identity_fixes_run_20_and_preserves_executable(self):
        settings = release.read_settings({}, '20')
        settings.update(requestID='4' * 32)
        self.settings = settings
        self.make_fixture(CFBundleName='XSign', UILaunchScreen=False, UILaunchStoryboardName='Launch Screen')
        with self.assertRaisesRegex(ValueError, 'bundle name and app display name'):
            release.inspect_ipa(self.package, require_xsign=True)
        plist_file = self.work / 'Info.plist'
        with zipfile.ZipFile(self.package) as original:
            plist_file.write_bytes(original.read('Payload/X-SIGN.app/Info.plist'))
        release.finalize_info(plist_file, settings)
        result = plistlib.loads(plist_file.read_bytes())
        self.assertEqual(result['CFBundleExecutable'], 'XSign')
        self.assertEqual(result['CFBundleName'], result['CFBundleDisplayName'])
        self.assertEqual(result['CFBundleName'], 'Xsign')
        self.assertEqual(result['XSignStudioBuildRequest'], settings['requestID'])
        self.assertNotIn('XSignCatalogOrigin', result)
        self.assertNotIn('UILaunchStoryboardName', result)
        self.assertEqual(result['UILaunchScreen'], {})
        self.make_fixture(**result)
        self.assertEqual(release.inspect_ipa(self.package, require_xsign=True)['bundleIdentifier'], 'Xsign')
        with self.assertRaisesRegex(ValueError, 'unexpected CFBundleIdentifier'):
            release.finalize_info(plist_file, dict(settings, bundleIdentifier='com.example.other'))

    def test_privacy_gate_scans_resources_encodings_and_static_binary_strings(self):
        self.make_fixture(bundled=(('Settings.txt', b'https://catalog.example.test/'),))
        release.inspect_ipa(self.package, require_xsign=True)
        for path, value in [
            ('XSignSoonLaunchPreview.json', b'{}'),
            ('Sources/ipasoon.json', b'{}'),
            ('Keys/client.pem', b'private material'),
            ('Frameworks/Engine', b'\x00https://public.example.test/app.ipa?something=1\x00'),
            ('ar.lproj/Localizable.strings', 'https://example.test/repo.json'.encode('utf-16-be')),
            ('Other.json', b'"https:\\/\\/source.example.test\\/app%2Etipa"'),
            ('Other.bin', b'\0' * (1024 * 1024 - 9) + b'https://repo.ucerts.io/catalog\0'),
            ('Settings.dat', ('github_pat_' + 'A0' * 41).encode('utf-16-le')),
            ('Credentials.dat', ('ghp_' + 'a1' * 18).encode('ascii')),
            ('Release.txt', b'https://fixture-user:fixture-secret@profile.example.test/info'),
            ('Manifest.dat', b'-----BEGIN PRIVATE KEY-----\n' + b'A1' * 24 + b'\n-----END PRIVATE KEY-----'),
        ]:
            with self.subTest(path=path):
                self.make_fixture(bundled=((path, value),))
                with self.assertRaisesRegex(ValueError, 'Release privacy check'):
                    release.inspect_ipa(self.package, require_xsign=True)

    def test_public_bootstrap_does_not_embed_complete_catalogue_urls(self):
        swift_source = Path(release.__file__).resolve().parents[1] / 'Feather/Utilities/XSignCatalogueEndpoint.swift'
        self.make_fixture(bundled=(('CatalogueEndpoint', swift_source.read_bytes()),))
        release.inspect_ipa(self.package, require_xsign=True)
        for url in (
            'https://raw.githubusercontent.com/ipablack/repo/main/repo.json',
            'https://raw.githubusercontent.com/ipablack/repo/main/xsign-config.json',
            'https://raw.githubusercontent.com/ipablack/X-SIGN/main/public/sources/ipasoon.json',
        ):
            with self.subTest(url=url):
                self.make_fixture(bundled=(('Frameworks/CatalogueEndpoint', url.encode()),))
                with self.assertRaisesRegex(ValueError, 'found an embedded source or IPA URL'):
                    release.inspect_ipa(self.package, require_xsign=True)

    def test_reports_native_diagnostics_instead_of_make_wrappers(self):
        log = self.work / 'xsign-local-build.log'
        log.write_text(
            "/Users/runner/work/X-SIGN/X-SIGN/Feather/View.swift:19:57: error: missing member\n"
            "** BUILD FAILED **\n"
            "XSign release error: Command '['make']' returned non-zero exit status 2.\n"
        )
        summary = self.work / 'summary.md'
        output = io.StringIO()
        with redirect_stdout(output):
            release.report_failure(self.work, summary)
        self.assertIn('::error title=XSign build cause::Feather/View.swift:19:57: error:', output.getvalue())
        self.assertNotIn('exit status', summary.read_text())

    def test_private_release_is_downloaded_with_scoped_credentials_and_verified(self):
        name = 'fixture/app'
        link = 'https://github.com/fixture/app/releases/download/v1/Xsign.ipa'
        parts = release.private_release_parts(link, name)
        self.assertEqual(parts, ('v1', 'Xsign.ipa'))
        self.assertIsNone(release.private_release_parts(link, 'any/other'))
        self.assertIsNone(release.private_release_parts(link + '?signed=secret', name))
        data = b'fixture archive data'
        record = {'draft': False, 'assets': [{'id': 3, 'name': 'Xsign.ipa', 'state': 'uploaded', 'size': len(data),
                    'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}]}
        redirection = release.HTTPError('https://api.github.com/fixture', 302, 'Found',
            {'Location': 'https://release-assets.githubusercontent.com/files?token=fixture'}, io.BytesIO())
        with patch.object(release, 'build_opener') as builder:
            opener = builder.return_value
            opener.open.side_effect = [io.BytesIO(b'{"private":true}'), io.BytesIO(json.dumps(record).encode()),
                                       redirection, io.BytesIO(data)]
            release.download_private_release(parts, name, 'fixture-only', self.package)
        self.assertEqual(self.package.read_bytes(), data)
        requests = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual([r.get_header('Authorization') for r in requests], ['Bearer fixture-only'] * 3 + [None])

    def test_build_passes_studio_values_to_make_and_rejects_a_mismatch(self):
        def make(command, env, check):
            self.assertEqual(command, ['make'])
            self.assertEqual(env['XSIGN_APP_NAME'], self.settings['appName'])
            self.assertEqual(env['XSIGN_BUNDLE_ID'], 'com.test.studio')
            self.assertEqual(env['XSIGN_APP_VERSION'], '1.4.2')
            self.assertEqual(env['XSIGN_BUILD_NUMBER'], '75')
            self.make_fixture(bundled=[self.install_template()], CFBundleVersion='74')
        with patch.object(release.subprocess, 'run', side_effect=make), self.assertRaisesRegex(ValueError, 'buildVersion'):
            release.build_ipa(self.settings, self.package, self.work)

    def test_custom_icon_restores_the_original_assets_after_a_failure(self):
        icon, composer = self.work / 'default.png', self.work / 'AppIcon.icon'
        icon.write_bytes(b'original')
        composer.mkdir()
        (composer / 'icon.json').write_text('{}')
        with release.build_icon(None, self.work, icon, composer):
            self.assertEqual(icon.read_bytes(), b'original')
            self.assertFalse(composer.exists())
        with self.assertRaisesRegex(RuntimeError, 'build failed'):
            with release.build_icon(b'custom', self.work, icon, composer):
                self.assertEqual(icon.read_bytes(), b'custom')
                self.assertFalse(composer.exists())
                raise RuntimeError('build failed')
        self.assertEqual(icon.read_bytes(), b'original')
        self.assertTrue((composer / 'icon.json').is_file())

    def test_square_transparent_icon_is_prepared_before_build_and_bound_by_digest(self):
        settings = {**self.settings, 'iconURL': 'https://example.com/icon.png'}
        icon = self.work / 'xsign-build-icon.png'
        with patch.object(release, 'download', side_effect=lambda _url, file, _limit:
                         Image.new('RGBA', (512, 512), (240, 160, 80, 128)).save(file)):
            release.prepare_icon(settings, icon)
        with Image.open(icon) as prepared:
            self.assertEqual((prepared.mode, prepared.size), ('RGB', (1024, 1024)))
            self.assertEqual(prepared.getpixel((0, 0)), (120, 80, 40))
        icon.write_bytes(b'a different icon')
        with patch.object(release.subprocess, 'run') as make, self.assertRaisesRegex(ValueError, 'does not match'):
            release.build_ipa(settings, self.package, self.work)
        make.assert_not_called()

    def test_make_passes_name_as_data_to_xcodebuild(self):
        name = 'تطبيق XSign & "Studio"'
        work = self.work / 'fake-bin'
        work.mkdir()
        fake = work / 'xcodebuild'
        fake.write_text('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["XSIGN_ARGUMENTS"], "w") as file: json.dump(sys.argv[1:], file)\n')
        fake.chmod(0o755)
        args = self.work / 'args.json'
        env = dict(os.environ, XSIGN_APP_NAME=name, XSIGN_BUNDLE_ID='com.test.studio', XSIGN_APP_VERSION='1.4.2',
                   XSIGN_BUILD_NUMBER='75', XSIGN_ARGUMENTS=str(args), TMPDIR=str(self.work), PATH=str(work)+os.pathsep+os.environ['PATH'])
        # Replay only the emitted Xcode command, leaving the real app workspace untouched.
        dry_run = subprocess.check_output(['make', '-n', 'iphoneos'], cwd=ROOT, text=True, env=env)
        body = dry_run.split('\nxcodebuild ', 1)[1].split('\n\n', 1)[0]
        command = 'xcodebuild ' + body.split('\nmkdir ', 1)[0].strip()
        subprocess.run(['bash', '-c', command], cwd=ROOT, env=env, check=True)
        flags = json.loads(args.read_text())
        self.assertIn(f'XSIGN_APP_DISPLAY_NAME={name}', flags)
        self.assertIn('FEATHER_PRODUCT_BUNDLE_IDENTIFIER=com.test.studio', flags)
        self.assertIn('FEATHER_PROJECT_VERSION=1.4.2', flags)
        self.assertIn('CURRENT_PROJECT_VERSION=75', flags)


if __name__ == '__main__':
    unittest.main()
