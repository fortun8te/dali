#!/usr/bin/env python3
"""Check the bundled OwnTone snapshot, or regenerate its upstream patch.

Default verification is offline. --upstream supplies a local upstream Git
checkout for full archive+patch reconstruction. This script never builds,
installs, starts, or modifies that upstream checkout.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'third_party/owntone'
PATCH = ROOT / 'engine/patches/dali-owntone.patch'
MANIFEST = ROOT / 'engine/patches/owntone-source.json'
UPSTREAM = '84e3755198c44c36ddf91e9919634807d68f69f9'

def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_file() and '.git' not in path.relative_to(root).parts:
            if path.is_symlink():
                raise SystemExit(f'Unexpected symlink in source snapshot: {path}')
            result[path.relative_to(root).as_posix()] = {
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                'executable': bool(path.stat().st_mode & 0o111),
            }
    return result

def git(*args, cwd=None, input=None):
    return subprocess.run([os.environ.get('GIT', 'git'), *args], cwd=cwd, input=input,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout

def extract_upstream(checkout, destination):
    archive = git('-C', str(checkout), 'archive', UPSTREAM)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        # Members come from the specified Git tree; enforce bounded relative
        # paths before extraction, including on older supported Python versions.
        for member in source.getmembers():
            if member.name.startswith('/') or '..' in Path(member.name).parts or member.issym() or member.islnk():
                raise SystemExit(f'Unexpected upstream archive member: {member.name}')
        source.extractall(destination)

def record():
    return {
        'schema': 1,
        'upstream_repository': 'https://github.com/owntone/owntone-server',
        'upstream_commit': UPSTREAM,
        'patch_sha256': hashlib.sha256(PATCH.read_bytes()).hexdigest(),
        'files': inventory(SOURCE),
    }

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--upstream', type=Path, help='Local upstream Git checkout, read only')
parser.add_argument('--update', action='store_true', help='Regenerate patch and manifest from the bundled snapshot')
args = parser.parse_args()
if args.update and not args.upstream:
    parser.error('--update requires --upstream')

if args.upstream:
    with tempfile.TemporaryDirectory(prefix='dali-engine-provenance-') as temporary:
        base = Path(temporary)
        extract_upstream(args.upstream, base)
        if args.update:
            # An ephemeral index records the exact upstream bytes and modes.
            git('init', '-q', str(base))
            git('add', '.', cwd=base)
            for path in base.iterdir():
                if path.name == '.git':
                    continue
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            shutil.copytree(SOURCE, base, dirs_exist_ok=True)
            git('add', '-N', '.', cwd=base)
            PATCH.write_bytes(git('diff', '--binary', '--no-ext-diff', cwd=base))
            MANIFEST.write_text(json.dumps(record(), indent=2) + '\n')
        else:
            git('apply', str(PATCH), cwd=base)
            reconstructed = inventory(base)
            bundled = inventory(SOURCE)
            mismatches = sorted(path for path in set(reconstructed) | set(bundled)
                                if reconstructed.get(path) != bundled.get(path))
            if mismatches:
                raise SystemExit('Upstream + patch differs from bundled source: ' + ', '.join(mismatches))
            print(f'Exact upstream + patch parity verified: {len(bundled)} files')

expected = json.loads(MANIFEST.read_text())
current = record()
if current != expected:
    differences = sorted(path for path in set(expected['files']) | set(current['files'])
                         if expected['files'].get(path) != current['files'].get(path))
    if expected['patch_sha256'] != current['patch_sha256']:
        differences.append('dali-owntone.patch')
    raise SystemExit('Engine provenance record is stale: ' + ', '.join(differences))
print(f'Engine source and patch hashes verified: {len(current["files"])} files')
