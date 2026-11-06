"""Regression coverage for stable toolchain selection and fail-fast job ordering."""
from pathlib import Path
import contextlib
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('xsign_xcode', ROOT / 'Tools/Select_Xcode.py')
selector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selector)


class ToolchainChecks(unittest.TestCase):
    def app(self, root, name, version):
        app = root / name
        developer = app / 'Contents/Developer'
        (developer / 'usr/bin').mkdir(parents=True)
        (developer / 'usr/bin/xcodebuild').touch()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))
        return developer

    def test_deduplicates_symlinks_ignores_old_and_preview_sorts_versions_numerically(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.app(root, 'Xcode_16.4.app', '16.4')
            expected = self.app(root, 'Xcode_26.10.app', '26.10')
            self.app(root, 'Xcode_26.3.app', '26.3')
            self.app(root, 'Xcode_26.11_beta.app', '26.11')
            (root / 'Xcode.app').symlink_to(root / 'Xcode_26.10.app')
            values = selector.candidates(root)
            self.assertEqual(values[0], expected)
            self.assertEqual(len(values), 2)

    def test_rejects_broken_sdk_and_falls_back_to_installed_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            newest = self.app(root, 'Xcode_26.3.app', '26.3')
            good = self.app(root, 'Xcode_26.2.app', '26.2')
            def run(command, **kwargs):
                if kwargs['env']['DEVELOPER_DIR'] == str(newest):
                    raise subprocess.CalledProcessError(1, command)
                return '26.2\n' if command[0] == 'xcrun' else 'Xcode 26.2\nBuild version 17C52\n'
            with patch.object(selector.subprocess, 'check_output', side_effect=run):
                self.assertEqual(selector.select_xcode(root)[0], good)

    def test_missing_compatible_xcode_stops_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            self.app(Path(directory), 'Xcode_16.4.app', '16.4')
            with self.assertRaisesRegex(SystemExit, 'No usable stable Xcode 26'):
                selector.select_xcode(directory)

    def test_selected_directory_is_persisted_for_all_later_steps(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'github-env'
            developer = Path('/Applications/Xcode_26.3.app/Contents/Developer')
            with patch.object(selector, 'select_xcode', return_value=(developer, '26.2', 'Xcode 26.3')), \
                 patch.dict(os.environ, {'GITHUB_ENV': str(target)}), contextlib.redirect_stdout(io.StringIO()):
                selector.main()
            self.assertEqual(target.read_text(), f'DEVELOPER_DIR={developer}\n')

    def test_native_build_precedes_long_security_checks_and_logs_include_xcresult(self):
        template = json.loads((ROOT / 'Tools/Delivery/workflow.template.json').read_text())
        steps = template['jobs']['build']['steps']
        toolchain = next(i for i, step in enumerate(steps) if 'Select_Xcode.py' in step.get('run', ''))
        build = next(i for i, step in enumerate(steps) if step.get('name') == 'Build and verify the iOS application')
        checks = next(i for i, step in enumerate(steps) if 'swiftc -swift-version' in step.get('run', ''))
        self.assertLess(toolchain, build)
        self.assertLess(build, checks)
        logs = next(step for step in steps if step.get('name') == 'Preserve native check and build logs')
        self.assertEqual(logs['if'], 'always()')
        self.assertIn('xsign-build.xcresult', logs['with']['path'])


if __name__ == '__main__':
    unittest.main()
