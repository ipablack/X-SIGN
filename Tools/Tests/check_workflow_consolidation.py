from pathlib import Path
import contextlib
import hashlib
import importlib.util
import io
import json
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('consolidation', Path(__file__).parents[1] / 'Disable_Legacy_Workflows.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConsolidationChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = '.github/workflows/old.yml'
        file = self.root / self.path
        file.parent.mkdir(parents=True)
        file.write_text('reviewed old workflow')
        (self.root / 'Tools/Delivery').mkdir(parents=True)
        (self.root / 'Tools/Delivery/legacy-workflows.json').write_text(json.dumps({self.path: [hashlib.sha256(file.read_bytes()).hexdigest()]}))
        self.calls = []
        self.workflows = [
            {'id': 10, 'path': self.path, 'state': 'active'},
            {'id': 11, 'path': '.github/workflows/XSign_Full_Link.yml', 'state': 'active'},
            {'id': 12, 'path': '.github/workflows/custom.yml', 'state': 'active'}]

    def api(self, repository, token, endpoint, method='GET'):
        self.calls.append((endpoint, method))
        if endpoint == '':
            return {'default_branch': 'main'}
        if endpoint.startswith('actions/workflows?'):
            return {'workflows': self.workflows}
        if method != 'PUT' or endpoint != 'actions/workflows/10/disable':
            raise AssertionError('Unreviewed mutation')

    def run_plan(self, branch='main'):
        with contextlib.redirect_stdout(io.StringIO()):
            return module.consolidate(self.root, 'owner/app', 'fixture-not-a-token', branch, call=self.api)

    def test_only_reviewed_old_workflow_is_disabled(self):
        self.assertEqual(self.run_plan(), [self.path])
        self.assertEqual([c for c in self.calls if c[1] != 'GET'], [('actions/workflows/10/disable', 'PUT')])

    def test_feature_branch_never_changes_default_workflows(self):
        self.assertEqual(self.run_plan('feature/review'), [])
        self.assertEqual(self.calls, [('', 'GET')])

    def test_unknown_edit_prevents_all_mutations(self):
        (self.root / self.path).write_text('custom user edit')
        with self.assertRaisesRegex(RuntimeError, 'changed legacy'):
            self.run_plan()
        self.assertTrue(all(method == 'GET' for _, method in self.calls))

    def test_disabled_workflow_is_idempotent(self):
        self.workflows[0]['state'] = 'disabled_manually'
        self.assertEqual(self.run_plan(), [])
        self.assertTrue(all(method == 'GET' for _, method in self.calls))

    def test_symlinks_are_rejected_before_any_mutation(self):
        file = self.root / self.path
        file.unlink()
        file.symlink_to(self.root / 'keep.yml')
        with self.assertRaises(RuntimeError):
            self.run_plan()
        self.assertTrue(all(method == 'GET' for _, method in self.calls))


if __name__ == '__main__':
    unittest.main()
