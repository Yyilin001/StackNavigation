"""Script regressions use disposable files and mock all simulator commands."""
import contextlib
import io
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import check_repository
import check_integration
import verify


class RepositoryChecks(unittest.TestCase):
    def test_python_personal_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / 'Scripts' / 'example.py'
            script.parent.mkdir()
            private_path = str(Path('/') / 'Users' / 'fixture' / 'project')
            script.write_text(f'path = {private_path!r}\n')
            with patch.object(check_repository, 'ROOT', root):
                with self.assertRaisesRegex(SystemExit, 'Scripts/example.py: personal absolute path'):
                    check_repository.main()

    def test_relative_python_paths_and_ignored_outputs_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'example.py').write_text('path = "Sources/StackNavigation"\n')
            (root / 'Build').mkdir()
            private_path = str(Path('/') / 'home' / 'fixture' / 'project')
            (root / 'Build' / 'output.py').write_text(f'path = {private_path!r}\n')
            with patch.object(check_repository, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                check_repository.main()


class IntegrationReports(unittest.TestCase):
    def test_validation_and_build_failures_remove_previous_success(self):
        for failure in ['readme', 'build']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in ['Scripts', 'Sources', 'Tests', 'Documentation', 'TestResults']:
                    (root / name).mkdir()
                script = root / 'Scripts' / 'check_integration.py'
                shutil.copy(SCRIPTS / script.name, script)
                shutil.copy(SCRIPTS.parent / 'Package.swift', root / 'Package.swift')
                snippet = '```swift\nimport StackNavigation\n```\n'
                (root / 'README.md').write_text('Missing quick start' if failure == 'readme' else snippet)
                (root / 'Documentation' / 'README.zh-CN.md').write_text(snippet)
                report = root / 'TestResults' / 'integration.json'
                report.write_text('{"result": "Passed"}\n')

                def command(args, **kwargs):
                    self.assertEqual(kwargs['env']['GIT_CONFIG_GLOBAL'], os.devnull)
                    self.assertEqual(kwargs['env']['GIT_CONFIG_NOSYSTEM'], '1')
                    if args[0] == 'xcodebuild':
                        raise subprocess.CalledProcessError(65, args)
                    return subprocess.CompletedProcess(args, 0)

                error = SystemExit if failure == 'readme' else subprocess.CalledProcessError
                with patch('subprocess.run', side_effect=command), self.assertRaises(error):
                    runpy.run_path(str(script), run_name='__main__')
                self.assertFalse(report.exists(), 'A failed run must not expose an older Passed report.')


class GitEnvironment(unittest.TestCase):
    def test_git_overrides_are_removed_without_mutating_parent_environment(self):
        overrides = {
            'GIT_DIR': 'unrelated-repository', 'GIT_WORK_TREE': 'unrelated-tree',
            'GIT_INDEX_FILE': 'unrelated-index', 'GIT_TEMPLATE_DIR': 'user-template',
            'GIT_AUTHOR_NAME': 'Personal identity', 'GIT_CONFIG': 'user-config',
            'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'commit.gpgsign', 'GIT_CONFIG_VALUE_0': 'true',
            'GIT_CONFIG_PARAMETERS': "'tag.gpgsign=true'", 'STACK_TEST_TOOLCHAIN': 'keep-this',
        }
        with patch.dict(os.environ, overrides):
            before = dict(os.environ)
            environment = check_integration.isolated_git_environment()
            self.assertEqual(dict(os.environ), before)
        for key in overrides:
            if key.startswith('GIT_'):
                self.assertNotIn(key, environment)
        self.assertEqual(environment['STACK_TEST_TOOLCHAIN'], 'keep-this')
        self.assertEqual(environment['GIT_CONFIG_GLOBAL'], os.devnull)
        self.assertEqual(environment['GIT_CONFIG_SYSTEM'], os.devnull)
        self.assertEqual(environment['GIT_CONFIG_NOSYSTEM'], '1')

    def test_real_commit_tag_and_clone_ignore_signing_and_hooks(self):
        for mode in ['signing', 'hooks']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo = root / 'source'
                repo.mkdir()
                marker = root / 'hook-ran'
                hooks = root / 'hooks'
                hooks.mkdir()
                hook = hooks / 'pre-commit'
                hook.write_text('#!/bin/sh\nprintf ran > ' + shlex.quote(str(marker)) + '\nexit 1\n')
                hook.chmod(0o755)
                config = root / 'global.gitconfig'
                contents = '[commit]\n gpgsign = true\n[tag]\n gpgsign = true\n[gpg]\n program = unavailable-signing-helper\n'
                if mode == 'hooks':
                    contents += '[core]\n hooksPath = ' + str(hooks) + '\n'
                config.write_text(contents)
                inherited = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
                inherited.update(GIT_CONFIG_GLOBAL=str(config), GIT_CONFIG_SYSTEM=os.devnull)
                with patch.dict(os.environ, inherited, clear=True):
                    isolated = check_integration.isolated_git_environment()

                def git(*args, env=isolated, check=True):
                    return subprocess.run(['git', *args], cwd=repo, env=env, check=check,
                                          text=True, capture_output=True)

                git('init', '--template=', '-b', 'main')
                (repo / 'file.txt').write_text('Local fixture\n')
                git('add', '.')
                commit = ['-c', 'user.name=Local integration fixture', '-c',
                          'user.email=fixture@example.invalid', 'commit', '-m', 'Fixture']
                failed = git(*commit, env=inherited, check=False)
                self.assertNotEqual(failed.returncode, 0)
                if mode == 'signing':
                    self.assertIn('gpg failed to sign', failed.stderr)
                else:
                    self.assertTrue(marker.exists())
                    marker.unlink()
                git(*commit)
                git('tag', '0.1.0')
                self.assertEqual(git('cat-file', '-t', 'refs/tags/0.1.0').stdout.strip(), 'commit')
                clone = root / 'clone'
                git('clone', '--branch', '0.1.0', repo.as_uri(), str(clone))
                self.assertEqual((clone / 'file.txt').read_text(), 'Local fixture\n')
                self.assertFalse(marker.exists())
                self.assertEqual(config.read_text(), contents)


class SimulatorSelection(unittest.TestCase):
    def setUp(self):
        self.runtimes = []
        self.devices = {}
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.reader = patch.object(verify, 'read_json', side_effect=self.read_json)
        self.reader.start()
        self.addCleanup(self.reader.stop)
        self.runner = patch.object(verify, 'run')
        self.run = self.runner.start()
        self.addCleanup(self.runner.stop)
        self.creator = patch.object(verify.subprocess, 'check_output', return_value='CREATED\n')
        self.create = self.creator.start()
        self.addCleanup(self.creator.stop)

    def read_json(self, *args):
        return {'devices': self.devices} if 'devices' in args else {'runtimes': self.runtimes}

    def add_runtime(self, version, platform='iOS', available=True, with_device=True):
        identifier = f'com.apple.CoreSimulator.SimRuntime.{platform}-{version.replace(".", "-")}'
        self.runtimes.append({
            'identifier': identifier, 'name': f'{platform} {version}', 'version': version,
            'isAvailable': available, 'supportedDeviceTypes': [{'name': 'iPhone', 'identifier': 'PHONE'}],
        })
        device_id = f'{platform}-{version}'
        self.devices[identifier] = ([{'udid': device_id, 'state': 'Shutdown', 'name': 'iPhone'}]
                                    if with_device else [])
        return device_id

    def reject(self, message):
        with self.assertRaisesRegex(SystemExit, message):
            verify.simulator()
        self.run.assert_not_called()
        self.create.assert_not_called()

    def test_explicit_non_ios_device_is_rejected_before_boot(self):
        os.environ['SIMULATOR_UDID'] = self.add_runtime('27.0', platform='watchOS')
        self.reject('available iOS runtime')

    def test_explicit_old_ios_is_rejected_before_boot(self):
        os.environ['SIMULATOR_UDID'] = self.add_runtime('16.4')
        self.reject('requires iOS 17.0 or newer')

    def test_unavailable_runtime_is_rejected_before_boot(self):
        os.environ['SIMULATOR_UDID'] = self.add_runtime('17.0', available=False)
        self.reject('available iOS runtime')

    def test_unknown_device_is_rejected_before_boot(self):
        os.environ['SIMULATOR_UDID'] = 'MISSING'
        self.reject('not an available simulator')

    def test_explicit_minimum_version_takes_precedence_over_os_filter(self):
        device = self.add_runtime('17.0')
        os.environ.update(SIMULATOR_UDID=device, SIMULATOR_OS='27')
        self.assertEqual(verify.simulator(), 'platform=iOS Simulator,id=' + device)
        self.run.assert_any_call('xcrun', 'simctl', 'boot', device)

    def test_automatic_selection_uses_newest_supported_ios(self):
        self.add_runtime('16.4')
        self.add_runtime('27.0', platform='watchOS')
        self.add_runtime('17.0')
        device = self.add_runtime('18.5')
        self.assertEqual(verify.simulator(), 'platform=iOS Simulator,id=' + device)

    def test_old_os_filter_does_not_fall_back_or_boot(self):
        self.add_runtime('16.4')
        self.add_runtime('18.5')
        os.environ['SIMULATOR_OS'] = '16'
        self.reject('No matching iOS 17.0\\+ runtime')

    def test_valid_filter_creates_a_compatible_phone_if_needed(self):
        self.add_runtime('17.0', with_device=False)
        self.add_runtime('18.5')
        os.environ['SIMULATOR_OS'] = '17'
        self.assertEqual(verify.simulator(), 'platform=iOS Simulator,id=CREATED')
        self.create.assert_called_once()
        self.run.assert_any_call('xcrun', 'simctl', 'boot', 'CREATED')

    def test_minimum_version_matches_package_manifest(self):
        manifest = (SCRIPTS.parent / 'Package.swift').read_text()
        major = int(re.search(r'\.iOS\(\.v(\d+)\)', manifest).group(1))
        self.assertEqual(verify.MINIMUM_IOS, (major, 0, 0))


if __name__ == '__main__':
    unittest.main()
