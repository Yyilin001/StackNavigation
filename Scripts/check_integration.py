#!/usr/bin/env python3
"""Compile both README quick starts against an exact tag in a disposable Git repository."""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = {'EnglishUsage': 'README.md', 'ChineseUsage': 'Documentation/README.zh-CN.md'}


def isolated_git_environment():
    # Preserve the selected toolchain and other process settings, but do not inherit
    # Git config, repository paths, author identity or template overrides.
    environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    environment.update(
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_SYSTEM=os.devnull,
        GIT_CONFIG_NOSYSTEM='1',
        GIT_TERMINAL_PROMPT='0',
    )
    return environment


def run(*args, cwd, env):
    subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True)


def main():
    environment = isolated_git_environment()
    # A failed or interrupted run must not leave an earlier success as its result.
    result = ROOT / 'TestResults'
    result.mkdir(exist_ok=True)
    report = result / 'integration.json'
    report.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory(prefix='stack-navigation-integration-') as directory:
        temp = Path(directory)
        source = temp / 'StackNavigation'
        source.mkdir()
        shutil.copy(ROOT / 'Package.swift', source)
        shutil.copytree(ROOT / 'Sources', source / 'Sources')
        shutil.copytree(ROOT / 'Tests', source / 'Tests')
        run('git', 'init', '--template=', '-b', 'main', cwd=source, env=environment)
        run('git', 'add', '.', cwd=source, env=environment)
        run('git', '-c', 'user.name=Local integration fixture', '-c', 'user.email=fixture@example.invalid',
            'commit', '-m', 'Disposable package fixture', cwd=source, env=environment)
        run('git', 'tag', '0.1.0', cwd=source, env=environment)
        client = temp / 'Client'
        for module, document in EXAMPLES.items():
            blocks = re.findall(r'```swift\n(.*?)\n```', (ROOT / document).read_text(), re.DOTALL)
            snippets = [block for block in blocks if 'import StackNavigation' in block]
            if len(snippets) != 1:
                raise SystemExit(f'{document}: expected one self-contained quick start importing StackNavigation.')
            target = client / 'Sources' / module
            target.mkdir(parents=True)
            (target / 'Usage.swift').write_text(snippets[0] + '\n')
        (client / 'Package.swift').write_text('''// swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "Client", platforms: [.iOS(.v17)],
        products: [.library(name: "Client", targets: ["EnglishUsage", "ChineseUsage"])],
        dependencies: [.package(url: "''' + source.as_uri() + '''", exact: "0.1.0")],
        targets: [
            .target(name: "EnglishUsage", dependencies: [.product(name: "StackNavigation", package: "stacknavigation")]),
            .target(name: "ChineseUsage", dependencies: [.product(name: "StackNavigation", package: "stacknavigation")])
        ]
    )
    ''')
        run('xcodebuild', '-scheme', 'Client', '-configuration', 'Debug',
            '-destination', 'generic/platform=iOS Simulator',
            '-derivedDataPath', temp / 'DerivedData', '-clonedSourcePackagesDirPath', temp / 'Dependencies',
            'CODE_SIGNING_ALLOWED=NO', 'build', cwd=client, env=environment)
        resolved = list(client.rglob('Package.resolved'))
        if not any(pin.get('identity') == 'stacknavigation' and pin.get('state', {}).get('version') == '0.1.0'
                   for p in resolved for pin in json.loads(p.read_text()).get('pins', [])):
            raise SystemExit('Missing exact-version resolution evidence.')
        report.write_text(json.dumps({
            'result': 'Passed', 'dependency': 'disposable local Git URL', 'exact_version': '0.1.0',
            'compiled_examples': list(EXAMPLES.values()), 'deployment_target': '17.0',
            'public_release_created': False, 'remote_repository_verified': False,
            'git_user_config_isolated': True,
            'consumer_build': 'iOS Simulator; isolated source checkout and DerivedData'
        }, indent=2) + '\n')
        print('Both README quick starts and exact-tag integration passed. Fixture removed; no public tag created.')


if __name__ == '__main__':
    main()
