from pathlib import Path
import base64
import copy
import importlib.util
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools'))
spec = importlib.util.spec_from_file_location('bootstrap', ROOT / 'Tools/Bootstrap_Source_Repository.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DEFAULTS = json.loads((ROOT / 'Tools/Delivery/repo.example.json').read_text())
PRIORITY = json.loads((ROOT / 'Tools/Integration/contract.json').read_text())['source_priority']


class SourceBootstrapChecks(unittest.TestCase):
    def test_previous_plus_default_migrates_without_resurrecting_an_empty_list(self):
        current = copy.deepcopy(DEFAULTS)
        dashboard = current['xsign_config']['dashboard']
        dashboard.pop('catalog_profile')
        dashboard['sources'] = [{'id': 'xsign.core.primary', 'name': 'Plus', 'url': 'https://supapi.trystore.net/rest/v1/plus_library_apps'}]
        result = module.normalize_catalogue(current, DEFAULTS, PRIORITY)
        self.assertEqual([source['url'] for source in result['xsign_config']['dashboard']['sources']], PRIORITY[1:])
        dashboard['sources'] = []
        self.assertEqual(module.normalize_catalogue(current, DEFAULTS, PRIORITY)['xsign_config']['dashboard']['sources'], [])

    def test_old_catalogue_gains_contract_without_losing_apps_or_unknown_fields(self):
        current = {'apps': [{'bundleIdentifier': 'com.fixture.app', 'versions': [{'version': '1'}], 'future': 7}],
            'repo_revision_id': 2, 'future_root': {'keep': True}, 'xsign_config': {'theme': {'app_tint_hex': '#ABCDEF'}}}
        result = module.normalize_catalogue(current, DEFAULTS, PRIORITY)
        self.assertEqual(result['apps'], current['apps'])
        self.assertEqual(result['future_root'], current['future_root'])
        self.assertEqual(result['xsign_config']['theme']['app_tint_hex'], '#ABCDEF')
        self.assertEqual(result['repo_revision_id'], 3)
        self.assertNotIn('dashboard', current['xsign_config'])

    def test_explicit_source_deletions_and_format_mappings_survive_initialization(self):
        current = copy.deepcopy(DEFAULTS)
        current['xsign_config']['dashboard']['sources'] = []
        result = module.normalize_catalogue(current, DEFAULTS, PRIORITY)
        self.assertEqual(result['xsign_config']['dashboard']['sources'], [])
        self.assertEqual(result['xsign_config']['app_control']['core_sources'], [])
        custom = {'id': 'json', 'name': 'JSON source', 'url': 'https://example.test/api', 'format': 'json',
            'root_path': 'data.items', 'fields': {'downloadURL': 'files.ipa'}, 'icon_url': 'https://example.test/icon.png'}
        current['xsign_config']['dashboard']['sources'] = [custom]
        result = module.normalize_catalogue(current, DEFAULTS, PRIORITY)
        self.assertEqual(result['xsign_config']['dashboard']['sources'], [custom])

    def api_fixture(self, current=None, files=None, reject_ref=False):
        calls = []
        available = {'repo.json': module.encode(current if current is not None else {'apps': [], 'repo_revision_id': 2})}
        available.update(files or {})

        def api(repository, token, endpoint, method='GET', payload=None):
            calls.append((endpoint, method, payload))
            if method == 'GET':
                if endpoint == '':
                    return {'default_branch': 'main'}
                if endpoint.startswith('git/ref/heads/'):
                    return {'object': {'sha': 'a' * 40}}
                if endpoint.startswith('git/commits/'):
                    return {'tree': {'sha': 'b' * 40}}
                if endpoint.startswith('contents/'):
                    path = endpoint.removeprefix('contents/').split('?')[0]
                    if path not in available:
                        raise module.GitHubAPIError(404)
                    data = available[path]
                    return {'type': 'file', 'size': len(data), 'encoding': 'base64', 'content': base64.b64encode(data).decode()}
            elif method == 'POST':
                return {'sha': ('c' if endpoint == 'git/trees' else 'd') * 40}
            elif method == 'PATCH':
                self.assertFalse(payload['force'])
                if reject_ref:
                    raise module.GitHubAPIError(422)
                return {}
            raise AssertionError('Unexpected API request')

        return calls, api

    def test_publisher_studio_and_both_json_files_share_one_commit(self):
        original = {'apps': [{'bundleIdentifier': 'com.fixture.app', 'custom': 9}], 'repo_revision_id': 2}
        calls, api = self.api_fixture(current=original)
        result = module.bootstrap(ROOT, 'fixture-not-a-token', call=api)
        self.assertEqual(result['status'], 'saved')
        trees = [c for c in calls if c[:2] == ('git/trees', 'POST')]
        self.assertEqual(len(trees), 1)
        entries = {r['path']: r for r in trees[0][2]['tree']}
        self.assertEqual(set(entries), {'repo.json', 'xsign-config.json', 'studio.html', '.github/workflows/ipa_manager.yml'})
        catalogue = json.loads(entries['repo.json']['content'])
        projection = json.loads(entries['xsign-config.json']['content'])
        self.assertEqual(catalogue['apps'], original['apps'])
        self.assertEqual(catalogue['repo_revision_id'], projection['repo_revision_id'])
        self.assertNotIn('apps', projection)
        self.assertEqual(len([c for c in calls if c[1] == 'PATCH']), 1)

    def test_custom_publisher_is_not_overwritten(self):
        calls, api = self.api_fixture(files={'.github/workflows/ipa_manager.yml': b'custom user workflow'})
        with self.assertRaisesRegex(ValueError, 'customized'):
            module.bootstrap(ROOT, 'fixture-not-a-token', call=api)
        self.assertTrue(all(method == 'GET' for _, method, _ in calls))

    def test_preview_and_idempotent_runs_do_not_write(self):
        calls, api = self.api_fixture()
        result = module.bootstrap(ROOT, '', preview=True, call=api)
        self.assertEqual(result['status'], 'preview')
        self.assertTrue(all(method == 'GET' for _, method, _ in calls))
        projection = {k: DEFAULTS[k] for k in ['name', 'identifier', 'subtitle', 'description', 'iconURL', 'tintColor',
            'repo_revision_id', 'xsign_config', 'categories'] if k in DEFAULTS}
        files = {'xsign-config.json': module.encode(projection),
            '.github/workflows/ipa_manager.yml': (ROOT / 'Tools/Delivery/ipa_manager.yml').read_bytes(),
            'studio.html': (ROOT / 'Tools/XSign_Studio.html').read_bytes()}
        calls, api = self.api_fixture(current=DEFAULTS, files=files)
        self.assertEqual(module.bootstrap(ROOT, 'fixture-not-a-token', call=api)['status'], 'unchanged')
        self.assertTrue(all(method == 'GET' for _, method, _ in calls))

    def test_reference_race_is_not_forced_or_retried(self):
        calls, api = self.api_fixture(reject_ref=True)
        with self.assertRaises(module.GitHubAPIError):
            module.bootstrap(ROOT, 'fixture-not-a-token', call=api)
        self.assertEqual(len([c for c in calls if c[1] == 'PATCH']), 1)


if __name__ == '__main__':
    unittest.main()
