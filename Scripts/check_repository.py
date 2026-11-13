#!/usr/bin/env python3
"""Check portable source/docs. --release additionally rejects unfinished release metadata."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '.build', '.swiftpm', 'Build', 'DerivedData', 'TestResults', 'xcuserdata', '__pycache__'}


def main(release=False):
    failures = []
    for path in ROOT.rglob('*'):
        if not path.is_file() or any(p in IGNORED or p.endswith('.xcresult') for p in path.relative_to(ROOT).parts):
            continue
        if path.suffix not in {'.swift', '.py', '.md', '.yml', '.yaml', '.json'}:
            continue
        text = path.read_text()
        if re.search(r'/(?:Users|home)/[^/\s]+/', text):
            failures.append(f'{path.relative_to(ROOT)}: personal absolute path')
        if path.suffix == '.md':
            for target in re.findall(r'(?<!!)\[[^\]]+\]\(([^)]+)\)', text):
                if '://' in target or target.startswith('#'):
                    continue
                if not (path.parent / target.split('#')[0]).exists():
                    failures.append(f'{path.relative_to(ROOT)}: broken link {target}')
    if release:
        for name in ['LICENSE', 'README.md', 'Documentation/README.zh-CN.md']:
            if re.search(r'COPYRIGHT_HOLDER|YOUR_ACCOUNT', (ROOT / name).read_text()):
                failures.append(f'{name}: release metadata is incomplete')
    if failures:
        raise SystemExit('\n'.join(failures))
    print('Repository checks passed' + (' (release metadata included).' if release else '.'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', action='store_true')
    main(parser.parse_args().release)
