#!/usr/bin/env python3
"""Local/CI verification entry point. Uses the selected Xcode, never a fixed device UUID."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / 'TestResults'
BUILD = ROOT / 'Build'
# Keep aligned with the iOS deployment target in Package.swift.
MINIMUM_IOS = (17, 0, 0)


def run(*args, cwd=ROOT):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)


def read_json(*args):
    return json.loads(subprocess.check_output(args, text=True))


def runtime_version(runtime):
    parts = tuple(map(int, runtime['version'].split('.')))
    return (parts + (0, 0, 0))[:3]


def simulator():
    devices = read_json('xcrun', 'simctl', 'list', 'devices', 'available', '-j')['devices']
    runtimes = {r['identifier']: r
                for r in read_json('xcrun', 'simctl', 'list', 'runtimes', '-j')['runtimes']
                if r['isAvailable'] and r['name'].startswith('iOS ')}
    minimum = '.'.join(map(str, MINIMUM_IOS[:2]))
    explicit = os.getenv('SIMULATOR_UDID')
    if explicit:
        match = [(runtime_id, d) for runtime_id, ds in devices.items()
                 for d in ds if d['udid'] == explicit]
        if not match:
            raise SystemExit('SIMULATOR_UDID is not an available simulator.')
        runtime_id, device = match[0]
        runtime = runtimes.get(runtime_id)
        if runtime is None:
            raise SystemExit('SIMULATOR_UDID must belong to an available iOS runtime.')
        if runtime_version(runtime) < MINIMUM_IOS:
            raise SystemExit(f'SIMULATOR_UDID requires iOS {minimum} or newer; selected {runtime["version"]}.')
    else:
        prefix = os.getenv('SIMULATOR_OS', '')
        eligible = [r for r in runtimes.values() if runtime_version(r) >= MINIMUM_IOS
                    and (not prefix or r['version'] == prefix or r['version'].startswith(prefix + '.'))]
        if not eligible:
            raise SystemExit(f'No matching iOS {minimum}+ runtime. Install one or set SIMULATOR_OS.')
        runtime = max(eligible, key=runtime_version)
        phones = [d for d in devices.get(runtime['identifier'], []) if 'iPhone' in d['name']]
        if phones:
            device = sorted(phones, key=lambda d: d['state'] != 'Booted')[0]
        else:
            types = runtime.get('supportedDeviceTypes', [])
            phones = [t for t in types if t['name'].startswith('iPhone')]
            if not phones:
                raise SystemExit('No compatible iPhone type found; create one and set SIMULATOR_UDID.')
            udid = subprocess.check_output(['xcrun', 'simctl', 'create', 'StackNavigation CI iPhone',
                                            phones[0]['identifier'], runtime['identifier']], text=True).strip()
            device = {'udid': udid, 'state': 'Shutdown'}
    if device['state'] != 'Booted':
        run('xcrun', 'simctl', 'boot', device['udid'])
    run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b')
    return 'platform=iOS Simulator,id=' + device['udid']


def build_args(configuration, destination):
    return ['-configuration', configuration, '-destination', destination,
            '-derivedDataPath', str(BUILD / ('package-' + configuration)), 'CODE_SIGNING_ALLOWED=NO']


def test_args(label):
    # Each run has its own bundle; rerunning never overwrites earlier evidence.
    RESULTS.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=label + '-', dir=RESULTS))
    return ['-resultBundlePath', str(output / 'Results.xcresult'),
            '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never']


def verify(mode, configuration):
    if mode == 'package-build':
        run('xcodebuild', '-scheme', 'StackNavigation',
            *build_args(configuration, 'generic/platform=iOS Simulator'), 'build')
    else:
        run('xcodebuild', '-scheme', 'StackNavigation',
            *build_args(configuration, simulator()), *test_args('package-' + configuration), 'test')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['package-build', 'package'])
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
    args = parser.parse_args()
    verify(args.mode, args.configuration)
