"""Exercise the failed draft-to-published transition without writing to GitHub."""
from pathlib import Path
import base64
import hashlib
import importlib.util
import os
import re
import tempfile
import unittest
from unittest.mock import patch
import zlib

delivery = Path(__file__).resolve().parents[1] / 'Delivery'
spec = importlib.util.spec_from_file_location('publisher', delivery / 'ipa_publisher.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class ReleaseFixture:
    def __init__(self):
        self.release = None
        self.uploads = 0
        self.publishes = 0
        self.reads_after_publish = 0
        self.corrupt_asset = False
        self.stale_final_url = True

    def api(self, endpoint, method='GET', payload=None, optional=False):
        if endpoint.startswith('releases/tags/'):
            return self.release if self.release and not self.release['draft'] else None
        if endpoint.startswith('releases?'):
            return [self.release] if self.release else []
        if endpoint == 'releases' and method == 'POST':
            self.release = {**payload, 'id': 71, 'created_at': '2026-11-07T02:00:00Z', 'assets': []}
            return self.release
        if endpoint == 'releases/71':
            if method == 'PATCH':
                self.publishes += 1
                self.release.update(payload)
                return self.release
            if not self.release['draft']:
                self.reads_after_publish += 1
                if not self.stale_final_url or self.reads_after_publish > 1:
                    for asset in self.release['assets']:
                        asset['browser_download_url'] = 'https://github.com/ipablack/repo/releases/download/' + self.release['tag_name'] + '/' + asset['name']
            return self.release
        raise AssertionError((endpoint, method))

    def upload(self, repo_name, release_id, path):
        assert repo_name == 'ipablack/repo' and release_id == '71'
        assert self.release['draft']
        data = path.read_bytes(); name = path.name
        self.uploads += 1
        asset = {'id': self.uploads, 'name': name, 'state': 'uploaded', 'size': len(data),
                 'digest': 'sha256:' + ('0' * 64 if self.corrupt_asset else hashlib.sha256(data).hexdigest()),
                 'browser_download_url': 'https://github.com/ipablack/repo/releases/download/untagged-fixture/' + name}
        self.release['assets'].append(asset)
        return asset


class PublisherChecks(unittest.TestCase):
    def run_release(self, fixture, failure=None):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            ipa = folder / 'queued.ipa'; icon = folder / 'icon.png'
            ipa.write_bytes(b'fixture IPA bytes'); icon.write_bytes(b'fixture icon bytes')
            info = {'name':'Fixture', 'bundleIdentifier':'com.example.app', 'version':'1.0', 'buildVersion':'2',
                    'minOSVersion':'15.0', 'size':ipa.stat().st_size, 'sha256':hashlib.sha256(ipa.read_bytes()).hexdigest(),
                    'iconFile':'icon.png', 'iconSha256':hashlib.sha256(icon.read_bytes()).hexdigest()}
            job = {'info': info, 'metadata': {}, 'ipa': ipa, 'folder': folder}
            with patch.object(publisher, 'REPO', 'ipablack/repo'), patch.object(publisher, 'api', fixture.api), \
                 patch.object(publisher, 'upload_asset', fixture.upload), patch.object(publisher.time, 'sleep'), \
                 patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40}):
                if failure:
                    with self.assertRaisesRegex(ValueError, failure): publisher.publish_release(job, {'full_name': 'ipablack/repo'})
                else:
                    publisher.publish_release(job, {'full_name': 'ipablack/repo'})
                    self.assertIn('/releases/download/ipa-com.example.app-', info['downloadURL'])
                    self.assertNotIn('untagged', info['downloadURL'])

    def test_draft_urls_are_ignored_until_publish_and_retries_reuse_assets(self):
        fixture = ReleaseFixture()
        self.run_release(fixture); self.run_release(fixture)
        self.assertEqual((fixture.uploads, fixture.publishes), (3, 1))

    def test_corruption_leaves_draft_and_reports_the_failing_file(self):
        fixture = ReleaseFixture(); fixture.corrupt_asset = True
        self.run_release(fixture, r'app\.ipa: SHA-256 verification failed')
        self.assertTrue(fixture.release['draft'])
        self.assertEqual(fixture.publishes, 0)

    def test_missing_digest_verifies_the_actual_bytes(self):
        digest = 'a' * 64
        with patch.object(publisher, 'streamed_asset_digest', return_value=digest) as read:
            publisher.verify_asset({'id': 42, 'name':'app.ipa', 'size':10, 'state':'uploaded'}, 'app.ipa', 10, digest)
        read.assert_called_once_with(42, 10)

    def test_standalone_workflow_embeds_the_tested_engine(self):
        encoded = re.search(r'XSIGN_IPA_ENGINE_B64: ([A-Za-z0-9+/=]+)', (delivery / 'ipa_manager.yml').read_text())[1]
        self.assertEqual(zlib.decompress(base64.b64decode(encoded)), (delivery / 'ipa_publisher.py').read_bytes())


if __name__ == '__main__': unittest.main()
