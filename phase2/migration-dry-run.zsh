#!/bin/zsh
# Owner opt-in only: no default store path and no discovery of owner containers.
set -euo pipefail
usage() {
  print -u2 -- 'usage: phase2/migration-dry-run.zsh (--approve-owner-store | --fixture) --source-quiescent --store-directory ABSOLUTE_PATH [--store-name default.store]'
  print -u2 -- 'Quit the app writing that store first. The entire supplied directory (WAL and external blobs included) is copied to a retained temporary folder.'
  exit 2
}
mode='' source_dir='' store_name=default.store quiescent=0
while (( $# )); do
  case $1 in
    --approve-owner-store) [[ -z $mode ]] || usage; mode=owner; shift ;;
    --fixture) [[ -z $mode ]] || usage; mode=fixture; shift ;;
    --source-quiescent) quiescent=1; shift ;;
    --store-directory) (( $# >= 2 )) || usage; source_dir=$2; shift 2 ;;
    --store-name) (( $# >= 2 )) || usage; store_name=$2; shift 2 ;;
    *) usage ;;
  esac
 done
# All authorization and argument checks precede any access to the supplied path.
[[ -n $mode && $quiescent == 1 && $source_dir == /* && $store_name != */* && -n $store_name ]] || usage
if [[ $mode == fixture ]]; then
  # Fixtures only in the worktree .build or an OS temporary directory.
  case $source_dir in
    ${0:A:h:h}/.build/* | /tmp/* | /private/tmp/* | ${TMPDIR:-/nonexistent}*) ;;
    *) print -u2 -- 'refusing: fixture must be under this worktree .build or an OS temporary directory'; exit 2 ;;
  esac
fi
repo=${0:A:h:h}
mkdir -p "$repo/.build"
request="$repo/.build/migration-dry-run-request.json"
lock="$repo/.build/migration-request.lock"
mkdir "$lock" 2>/dev/null || { print -u2 -- 'Another migration dry run is active'; exit 2; }
cleanup() { rm -f "$request"; rmdir "$lock"; }
trap cleanup EXIT
out=$(mktemp -d "${TMPDIR:-/tmp/}AtticS6Migration.XXXXXX")
print -- "Report directory: $out"
# Hash and copy only the explicitly supplied source, after opt-in. Symlinks are
# refused so a copied external-storage directory cannot point back to its source.
python3 - "$source_dir" "$store_name" "$out" "$mode" "$repo" <<'PY'
import hashlib, json, os, pathlib, shutil, sys
source, name, out = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
if sys.argv[4] == 'fixture':
    resolved = source.resolve()
    allowed = [pathlib.Path(sys.argv[5]) / '.build', pathlib.Path('/tmp').resolve(), pathlib.Path(os.environ.get('TMPDIR', '/tmp')).resolve()]
    if not any(root == resolved or root in resolved.parents for root in allowed): raise RuntimeError('Fixture resolves outside allowed roots')
def inventory(root):
    if root.is_symlink(): raise RuntimeError('Symlink source refused')
    result = {}
    for base, dirs, files in os.walk(root):
        for entry in dirs + files:
            if (pathlib.Path(base) / entry).is_symlink(): raise RuntimeError('Symlink entry refused')
        for entry in sorted(files):
            path = pathlib.Path(base) / entry
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
            result[str(path.relative_to(root))] = digest.hexdigest()
    return result
if not source.is_dir() or not (source / name).is_file(): raise RuntimeError('Explicit store directory/file missing')
before = inventory(source)
shutil.copytree(source, out / 'copy')
if inventory(source) != before: raise RuntimeError('Source changed during copy; quit its writer and retry')
if inventory(out / 'copy') != before: raise RuntimeError('Copy does not match source')
(out / 'before.json').write_text(json.dumps(before, sort_keys=True))
# SQLite's read-only WAL reader also must not update its shared-memory sidecar.
for base, dirs, files in os.walk(out / 'copy'):
    for entry in files: (pathlib.Path(base) / entry).chmod(0o400)
    pathlib.Path(base).chmod(0o500)
PY
python3 - "$request" "$out" "$store_name" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'copy': str(pathlib.Path(sys.argv[2]) / 'copy' / sys.argv[3]), 'report': str(pathlib.Path(sys.argv[2]) / 'migration-report.json')}))
PY
wrapper=/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh
# The isolated unit-test host is used, never Attic S6 or the owner's app.
result=0
"$wrapper" -project "$repo/Attic.xcodeproj" -scheme Attic -configuration Local \
  -destination 'platform=macOS' -derivedDataPath "$repo/.build/dd" \
  -only-testing:AtticTests/NotesMigrationAcceptanceTests/testOwnerApprovedCopiedStoreDryRun \
  CODE_SIGNING_ALLOWED=NO test > "$out/test.log" 2>&1 || result=$?
python3 - "$source_dir" "$out" "$result" <<'PY'
import hashlib, json, os, pathlib, sys
source, out, exit_code = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
def inventory(root):
    result = {}
    for base, dirs, files in os.walk(root):
        for entry in sorted(files):
            p = pathlib.Path(base) / entry
            if p.is_symlink(): raise RuntimeError('Symlink appeared during run')
            h = hashlib.sha256()
            with p.open('rb') as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b''): h.update(chunk)
            result[str(p.relative_to(root))] = h.hexdigest()
    return result
before = json.loads((out / 'before.json').read_text())
verification = {'source_unchanged': inventory(source) == before, 'copy_unchanged': inventory(out / 'copy') == before, 'test_exit': exit_code}
(out / 'integrity-report.json').write_text(json.dumps(verification, indent=2))
report = out / 'migration-report.json'
if not report.exists(): report.write_text(json.dumps({'status': 'blocked', 'reason': 'Runner did not finish; see test.log'}))
print(json.dumps(verification))
if not all(verification[k] for k in ('source_unchanged', 'copy_unchanged')): sys.exit(1)
PY
print -- "Migration report: $out/migration-report.json"
print -- "Integrity report: $out/integrity-report.json"
exit $result
