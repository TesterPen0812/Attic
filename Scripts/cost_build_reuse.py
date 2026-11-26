#!/usr/bin/env python3
"""Reuse the costs lane's optimized builds of the pinned reference commits.

The costs job builds four -O wholemodule test hosts one after another; three
of them are pinned commits whose builds do not change between runs. A
reference build is uploaded once as an artifact named by a key over every
input of that build, and later runs on any branch download it instead of
building it again. The candidate is always built.

The key covers: the reference commit, every change made to its tree here (the
fixture overlay and prepare_cost_reference.py's edits, as a binary diff plus
untracked files), the build flags, the Xcode version and the macOS SDK. A
changed input gives a new key, so a stale reference is never reused.

Only artifacts from this repository's own macos-ci.yml runs, started by push
or workflow_dispatch, are accepted.
"""
import hashlib
import json
import os
import subprocess
import sys
import tarfile
from pathlib import Path

FORMAT = 'attic-cost-build-v1'
WORKFLOW_PATH = '.github/workflows/macos-ci.yml'
TRUSTED_EVENTS = {'push', 'workflow_dispatch'}


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True).stdout


def tree_digest(source):
    """Hash the commit and every local change made to the reference tree."""
    digest = hashlib.sha256()
    digest.update(run('git', '-C', str(source), 'rev-parse', 'HEAD'))
    digest.update(b'\0diff\0')
    digest.update(run('git', '-C', str(source), 'diff', '--binary', '--no-ext-diff', 'HEAD'))
    untracked = run('git', '-C', str(source), 'ls-files', '--others', '--exclude-standard', '-z')
    for name in sorted(filter(None, untracked.split(b'\0'))):
        digest.update(b'\0untracked\0' + name + b'\0')
        digest.update((Path(source) / name.decode()).read_bytes())
    return digest.hexdigest()


def toolchain():
    return (run('xcodebuild', '-version')
            + run('xcrun', '--sdk', 'macosx', '--show-sdk-version')
            + run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version')
            + run('uname', '-m'))


def build_key(name, source, flags, toolchain_text):
    digest = hashlib.sha256()
    for part in (FORMAT, name, tree_digest(source), flags):
        digest.update(part.encode() + b'\0')
    digest.update(toolchain_text)
    return digest.hexdigest()[:40]


def artifact_name(name, key):
    return f'attic-cost-build-{name}-{key}'


def trusted(run_info, repository):
    return (run_info.get('path') == WORKFLOW_PATH
            and run_info.get('event') in TRUSTED_EVENTS
            and (run_info.get('repository') or {}).get('full_name') == repository
            and (run_info.get('head_repository') or {}).get('full_name') == repository)


def gh_json(path):
    return json.loads(run('gh', 'api', path))


def find_artifact(name, repository):
    listing = gh_json(f'repos/{repository}/actions/artifacts?name={name}&per_page=100')
    candidates = sorted((a for a in listing.get('artifacts', []) if not a.get('expired')),
                        key=lambda a: a.get('created_at', ''), reverse=True)
    for artifact in candidates:
        run_id = (artifact.get('workflow_run') or {}).get('id')
        if run_id and trusted(gh_json(f'repos/{repository}/actions/runs/{run_id}'), repository):
            return run_id
    return None


def restore(archive, derived_data):
    Path(derived_data).mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as bundle:
        for member in bundle.getnames():
            if member != 'Build/Products' and not member.startswith('Build/Products/'):
                raise ValueError(f'unexpected archive member {member}')
    # bsdtar keeps the bundles' symlinks and executable bits.
    subprocess.run(['tar', '-xzf', str(archive), '-C', str(derived_data)], check=True)
    Path(archive).unlink()
    if not list((Path(derived_data) / 'Build/Products').glob('*.xctestrun')):
        raise ValueError('restored products have no .xctestrun')


def fetch(name, key, derived_data, download_dir):
    """Restore Build/Products into derived_data; print hit or miss."""
    repository = os.environ['GITHUB_REPOSITORY']
    artifact = artifact_name(name, key)
    try:
        run_id = find_artifact(artifact, repository)
        if run_id is None:
            print('miss')
            return
        target = Path(download_dir) / name
        subprocess.run(['gh', 'run', 'download', str(run_id), '-R', repository,
                        '-n', artifact, '-D', str(target)], check=True)
        restore(target / f'{name}-products.tar.gz', derived_data)
        print(f'hit run={run_id}')
    except (subprocess.CalledProcessError, OSError, ValueError, tarfile.TarError) as error:
        # Any doubt rebuilds; a failed reuse must never fail the gates.
        print(f'reuse of {artifact} failed: {error}', file=sys.stderr)
        subprocess.run(['rm', '-rf', str(Path(derived_data) / 'Build')], check=False)
        print('miss')


def pack(name, derived_data, out_dir):
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    archive = Path(out_dir) / f'{name}-products.tar.gz'
    subprocess.run(['tar', '--no-mac-metadata', '-czf', str(archive), '-C', str(derived_data),
                    'Build/Products'], check=True)
    print(archive)


def main(argv):
    command = argv[1] if len(argv) > 1 else ''
    if command == 'key' and len(argv) == 5:
        _, _, name, source, flags = argv
        print(build_key(name, source, flags, toolchain()))
    elif command == 'fetch' and len(argv) == 6:
        fetch(*argv[2:])
    elif command == 'pack' and len(argv) == 5:
        pack(*argv[2:])
    else:
        print('usage: cost_build_reuse.py key NAME SOURCE FLAGS | '
              'fetch NAME KEY DERIVED_DATA DOWNLOAD_DIR | pack NAME DERIVED_DATA OUT_DIR', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
