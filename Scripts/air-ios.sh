#!/bin/sh
# A single file so phase1/air-ios.sh can also run before this branch is merged.
# --check performs only read-only preflights. New project inputs must be git-added.
exec /usr/bin/python3 - "$0" "$@" <<'AIR_IOS_PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess as sp
import sys
import xml.etree.ElementTree as XML

BASE = Path('/Users/taha/Projects/attic')
JOBS = BASE / 'attic-air/.build/jobs'
RECORD = BASE / 'attic-redesign-assets/iphone/overnight-astra/run/air-simulator.udid'
DEVICE = 'Attic Overnight iPhone'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
MODEL = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
APP, UNIT, UI = 'AtticMobile', 'AtticMobileTests', 'AtticMobileUITests'
PROJECT = 'Attic.xcodeproj'
PBX = PROJECT + '/project.pbxproj'
SCHEME = PROJECT + '/xcshareddata/xcschemes/AtticMobile.xcscheme'
PINS = PROJECT + '/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
LOCK = 'Scripts/xcodebuild_locked.sh'
SSH = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'air']
RSYNC = ['/usr/bin/rsync', '-e', shlex.join(SSH[:-1])]
USAGE = 'usage: air-ios.sh [--check] <worktree> <unique-run-name> <build|test> [-only-testing:AtticMobileTests[/Suite[/method]] ...]'


def need(ok, message):
    if not ok:
        raise ValueError(message)


def output(args, **kwargs):
    return sp.check_output(args, text=True, **kwargs).strip()


def args_ok(job, name, action, filters):
    need(re.fullmatch(r'attic-px-iphone(?:-[a-z0-9][a-z0-9-]*)?', job), 'not an iPhone job')
    need(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', name), 'invalid run name')
    need(action in ('build', 'test'), USAGE)
    need(action == 'test' or not filters, 'build does not accept test filters')
    for f in filters:
        need(re.fullmatch(r'-only-testing:AtticMobileTests(?:/[A-Za-z_][A-Za-z0-9_]*){0,2}', f), 'only hosted AtticMobileTests filters are accepted')


def uuid_ok(value):
    need(re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', value), 'invalid saved simulator UDID')
    return value.upper()


def plain(path):
    need(path.is_absolute() and path.resolve() == path, 'symlink or unsafe path: ' + str(path))
    return path


def inputs(wt, action):
    # PBX membership, not directory contents, defines the transfer. No recursive rsync.
    indexed = set(sp.check_output(['git', 'ls-files', '-z'], cwd=wt).decode().split('\0'))
    selected = set()

    def add(s):
        rel = Path(s)
        need(not rel.is_absolute() and str(rel) == s and '..' not in rel.parts and
             all(re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_. +@-]*', p) for p in rel.parts), 'unsafe input: ' + s)
        need(not re.search(r'(?i)(secret|credential|password|recovery[ _-]?(?:key|code)|backup[ _-]?code|seed[ _-]?phrase|preview\.(personal|notesv2|main)|owner[ _-]?(?:run|compare|data)|\.(?:pem|key|p12|pfx|env|mobileprovision|sqlite|store)(?:\.|$))', s), 'private input refused: ' + s)
        need(s in indexed and plain(wt / s).is_file(), 'missing, untracked or non-regular input (stage it or regenerate): ' + s)
        selected.add(s)
        return wt / s

    for s in (PBX, SCHEME, PINS, LOCK):
        add(s)
    # An edited wrapper could silently bypass the shared lock or run on the Mac screen.
    need(output(['git', 'hash-object', LOCK], cwd=wt) == '1ea86659a57555802252f91038c4662fed13ebc9' and os.access(wt / LOCK, os.X_OK), 'unreviewed or non-executable machine lock wrapper')
    scheme = XML.parse(wt / SCHEME)
    need(not scheme.findall('.//ExecutionAction') and not scheme.findall('.//TestPlanReference'), 'unexpected scheme action or test plan')
    def names(xpath):
        return {n.attrib['BlueprintName'] for n in scheme.findall(xpath)}
    need(names('.//BuildActionEntry/BuildableReference') == {APP}, 'unexpected scheme build target')
    testables = names('.//TestableReference/BuildableReference')
    need(UNIT in testables and testables <= {UNIT, UI}, 'unexpected scheme test targets')
    proj = json.loads(output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(wt / PBX)]))
    obj = proj['objects']
    parent = {child: key for key, group in obj.items() if group['isa'] == 'PBXGroup' for child in group['children']}
    def file_path(key):
        parts = []
        while True:
            node = obj[key]
            need(node['sourceTree'] in ('<group>', 'SOURCE_ROOT'), 'external project input')
            if node.get('path'):
                parts.insert(0, node['path'])
            if key not in parent or node['sourceTree'] == 'SOURCE_ROOT':
                return '/'.join(parts)
            key = parent[key]

    def resource(s, target, phase):
        # This one hosted test compiles on both platforms. Never admit AtticTests wholesale.
        if target == UNIT and phase == 'PBXSourcesBuildPhase' and s == 'AtticTests/SharedPersistenceParityTests.swift':
            add(s)
            return
        # Fixtures must be individual, indexed resources of the hosted test target.
        if target == UNIT and phase == 'PBXResourcesBuildPhase' and s.startswith('AtticMobileTests/Fixtures/Synthetic/') and Path(s).suffix in ('.json', '.txt', '.png'):
            add(s)
            return
        need(s.split('/')[0] in ('Attic', APP, UNIT, UI, 'AtticCore'), 'unexpected project source root: ' + s)
        if s.endswith('.xcassets'):
            # Include only catalogue descriptors and the actual images they reference.
            catalogs = sorted(p for p in indexed if p.startswith(s + '/') and p.endswith('/Contents.json'))
            need(s + '/Contents.json' in catalogs, 'incomplete asset catalogue: ' + s)
            def visit(v, folder):
                if isinstance(v, list):
                    for x in v:
                        visit(x, folder)
                elif isinstance(v, dict):
                    if 'filename' in v:
                        f = v['filename']
                        need(Path(f).name == f and Path(f).suffix.lower() in ('.png', '.jpg', '.jpeg', '.pdf', '.svg', '.heic', '.webp'), 'unsupported catalogue file')
                        add(str(folder / f))
                    for x in v.values():
                        visit(x, folder)
            for p in catalogs:
                visit(json.loads(add(p).read_bytes()), Path(p).parent)
        else:
            need(Path(s).suffix in ('.swift', '.m', '.mm', '.h', '.metal', '.xcprivacy', '.xcstrings', '.strings', '.storyboard', '.xib') or Path(s).name in ('Info.plist', 'ThirdPartyNotices.txt'), 'unsupported input: ' + s)
            add(s)

    targets = {v['name']: v for v in obj.values() if v['isa'] == 'PBXNativeTarget'}
    for name in [APP, UNIT] + ([UI] if action == 'test' and UI in testables else []):
        t = targets[name]
        cfg = next(obj[i]['buildSettings'] for i in obj[t['buildConfigurationList']]['buildConfigurations'] if obj[i]['name'] == 'Local')
        need(cfg.get('PRODUCT_BUNDLE_IDENTIFIER') == 'com.taha.' + name, 'Local target identity must be com.taha.' + name)
        if name == APP:
            flags = str(cfg.get('OTHER_SWIFT_FLAGS', '')) + ' ' + str(cfg.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ''))
            need('ATTIC_LOCAL_ONLY' in flags and 'ATTIC_CLOUD_SYNC' not in flags, 'Local iPhone target must enable ATTIC_LOCAL_ONLY only')
        if name == UNIT and action == 'build':
            continue
        need(all(obj[obj[i]['target']]['name'] == APP for i in t['dependencies']), 'unexpected mobile target dependency')
        if cfg.get('INFOPLIST_FILE'):
            resource(cfg['INFOPLIST_FILE'], name, None)
        for pid in t['buildPhases']:
            phase = obj[pid]
            if phase['isa'] == 'PBXFrameworksBuildPhase':
                continue  # SDK frameworks / resolved Swift packages are supplied on the Air.
            need(phase['isa'] in ('PBXSourcesBuildPhase', 'PBXResourcesBuildPhase'), 'unsupported mobile build phase: ' + phase['isa'])
            for fid in phase['files']:
                resource(file_path(obj[fid]['fileRef']), name, phase['isa'])
    return sorted(selected)


def fingerprint(root, paths):
    h = hashlib.sha256()
    for s in sorted(paths):
        h.update(s.encode() + b'\0' + hashlib.sha256(plain(root / s).read_bytes()).digest())
    return h.hexdigest()


def names_digest(paths):
    return hashlib.sha256('\0'.join(sorted(paths)).encode()).hexdigest()


def device_check(devices, udid, action):
    hits = [(r, d) for r, ds in devices.items() for d in ds if d['udid'].upper() == udid]
    need(len(hits) == 1, 'saved UDID is absent or ambiguous; no fallback')
    runtime, d = hits[0]
    need((runtime, d['name'], d.get('deviceTypeIdentifier'), d.get('isAvailable')) == (RUNTIME, DEVICE, MODEL, True), 'saved UDID has wrong name, model, runtime or availability')
    need(action != 'test' or d.get('state') == 'Booted', 'owner must boot the dedicated simulator before testing')


def preflight(udid, action, volume):
    fs = os.statvfs(volume)
    free = fs.f_bavail * fs.f_frsize
    need(free >= 10 * 1024**3, 'Air disk below 10 GiB: %d bytes available' % free)
    device_check(json.loads(output(['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices'], udid, action)
    print(f'Air: {DEVICE}; {udid}; iPhone 17 Pro; iOS 26.5; {free} bytes free', flush=True)


def air(operation, job, name, action, udid, branch, commit, digest, manifest, *filters):
    args_ok(job, name, action, filters)
    uuid_ok(udid)
    need(os.environ.get('SSH_CONNECTION') and output(['/bin/hostname', '-s']).lower() == 'tahas-macbook-air' and output(['/usr/sbin/sysctl', '-n', 'hw.model']) == 'Mac14,2', 'only the dedicated Air may execute this worker')
    base = plain(JOBS / job / '.build/air-ios')
    run = plain(base / 'runs' / name)
    src, dd = run / 'src', plain(base / 'DerivedData')
    if operation in ('check', 'prepare'):
        preflight(udid, action, plain(JOBS))
        if operation == 'prepare':
            run.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            run.mkdir(mode=0o700)  # never overlay a previous source tree, log or result
            src.mkdir(mode=0o700)
        return 0
    need(operation == 'run', 'unknown Air operation')
    with (plain(run / 'air.log')).open('x', buffering=1) as log:
        os.dup2(log.fileno(), 1)
        os.dup2(log.fileno(), 2)
        print(f'branch={branch} commit={commit} inputs.sha256={digest} scheme={APP} configuration=Local action={action}', flush=True)
        with plain(base / 'job.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)  # includes result inspection on this job's single DD
            preflight(udid, action, base)
            actual = []
            for p in plain(src).rglob('*'):
                need(not p.is_symlink() and (p.is_file() or p.is_dir()), 'unexpected non-regular snapshot entry')
                if p.is_file():
                    actual.append(str(p.relative_to(src)))
            # Verify the names first, so an unexpected file is never opened to hash it.
            need(names_digest(actual) == manifest, 'transferred file list differs from local manifest')
            need(fingerprint(src, actual) == digest, 'transferred inputs differ from local manifest')
            products = plain(dd / 'Build/Products' / name / 'Local-iphonesimulator')
            need(not products.exists(), 'product path already exists')
            app = products / (APP + '.app')
            result = run / 'tests.xcresult'
            argv = [str(src / LOCK), action, '-project', PROJECT, '-scheme', APP, '-configuration', 'Local', '-sdk', 'iphonesimulator', '-destination', 'platform=iOS Simulator,id=' + udid,
                    '-derivedDataPath', str(dd), '-parallel-testing-enabled', 'NO', '-maximum-parallel-testing-workers', '1', '-maximum-concurrent-test-simulator-destinations', '1',
                    'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=', 'CODE_SIGN_ENTITLEMENTS=', 'CONFIGURATION_BUILD_DIR=' + str(products)]
            if action == 'test':
                argv += ['-resultBundlePath', str(result)] + (list(filters) or ['-only-testing:' + UNIT])
            # Pin the checked Air toolchain; do not forward Pro or GUI/test environment settings.
            env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()), 'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer', 'LANG': 'en_US.UTF-8'}
            print(shlex.join(argv), flush=True)
            rc = sp.run(argv, cwd=src, env=env).returncode
            print('AIR EXIT', rc, flush=True)
            try:
                if action == 'test' and (result.is_dir() or rc == 0):
                    s = json.loads(output(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], env=env))
                    print('TEST COUNTS: ' + ' '.join(f'{k}={s[k]}' for k in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests', 'expectedFailures')), flush=True)
                    need(s['totalTestCount'] > 0 and s['passedTests'] + s['expectedFailures'] > 0 and s['failedTests'] == 0, 'no passing tests or failed tests in result')
                if rc == 0:
                    def identity(bundle, expected):
                        need(plistlib.loads((bundle / 'Info.plist').read_bytes())['CFBundleIdentifier'] == 'com.taha.' + expected, 'wrong built identity: ' + str(bundle))
                        print(f'BUNDLE: com.taha.{expected} {bundle}', flush=True)
                    identity(app, APP)
                    if action == 'test':
                        candidates = [p / (UNIT + '.xctest') for p in (app / 'PlugIns', products)]
                        identity(next(p for p in candidates if p.is_dir()), UNIT)
            except Exception as error:
                print('result verification failed:', repr(error), file=sys.stderr, flush=True)
                return rc or 1
            return rc


def main(args):
    if args[:1] == ['--air-worker']:
        return air(*args[1:])
    if args in (['-h'], ['--help']):
        print(USAGE)
        return 0
    check = args[:1] == ['--check']
    if check:
        args = args[1:]
    need(len(args) >= 3, USAGE)
    wt, name, action, *filters = args
    wt = Path(wt).resolve(strict=True)
    job = wt.name
    args_ok(job, name, action, filters)
    need(wt.parent == BASE, 'wrong worktree directory')
    def git(*flags):
        return output(['git', '-C', str(wt), *flags])
    branch = 'iphone/build' + job[len('attic-px-iphone'):]
    need(git('rev-parse', '--show-toplevel') == str(wt) and git('rev-parse', '--path-format=absolute', '--git-common-dir') == str(BASE / 'attic-task-panels-v2/.git') and git('symbolic-ref', '--quiet', '--short', 'HEAD') == branch, 'worktree/branch mismatch: expected ' + branch)
    commit = git('rev-parse', 'HEAD')
    need(plain(RECORD).is_file() and RECORD.stat().st_size <= 38, 'missing or malformed dedicated device record: ' + str(RECORD))
    udid = uuid_ok(RECORD.read_text().rstrip('\r\n'))
    paths = inputs(wt, action)
    digest = fingerprint(wt, paths)
    payload = Path(sys.argv[1]).read_bytes()
    dest = JOBS / job / '.build/air-ios/runs' / name
    def remote(op, **kwargs):
        cmd = shlex.join(['/bin/sh', '-s', '--', '--air-worker', op, job, name, action, udid, branch, commit, digest, names_digest(paths), *filters])
        return sp.run(SSH + [cmd], input=payload, **kwargs).returncode
    print(f'{branch} {commit}; {len(paths)} inputs; sha256={digest}', flush=True)
    if check:
        return remote('check')
    local = plain(wt / '.build/air-ios' / name)
    local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    local.mkdir(mode=0o700)
    print('Driver log:', local / 'driver.log', flush=True)
    with (local / 'driver.log').open('x') as driver:
        io = dict(stdout=driver, stderr=sp.STDOUT)
        rc = remote('prepare', **io)
        if rc == 0:
            rc = sp.run(RSYNC + ['-ptR', '--files-from=-', str(wt) + '/', 'air:' + str(dest / 'src') + '/'], input=('\n'.join(paths) + '\n').encode(), **io).returncode
        if rc == 0:
            rc = remote('run', **io)
            # Always fetch the build log, even if the worker or xcodebuild failed.
            fetch = sp.run(RSYNC + ['-t', 'air:' + str(dest / 'air.log'), str(local / 'air.log')], **io).returncode
            if fetch:
                print('Log fetch failed; Air log: air:' + str(dest / 'air.log'), file=sys.stderr)
            rc = rc or fetch
    log = local / 'air.log'
    if log.is_file():
        print('Full log:', log)
        with log.open(errors='replace') as f:
            for line in f:
                if line.startswith(('Air:', 'AIR EXIT ', 'TEST COUNTS:', 'BUNDLE:', 'result verification failed:', 'air-ios:')):
                    print(line.rstrip())
    if rc:
        print((local / 'driver.log').read_text(errors='replace').rstrip(), file=sys.stderr)
    return rc


if __name__ == '__main__':
    os.umask(0o077)
    try:
        status = main(sys.argv[2:])
    except (ValueError, OSError, KeyError, StopIteration, XML.ParseError, sp.SubprocessError) as e:
        print('air-ios:', str(e) or repr(e), file=sys.stderr, flush=True)
        status = 2
    sys.exit(status if status >= 0 else 128 - status)
AIR_IOS_PY
