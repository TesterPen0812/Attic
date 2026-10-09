#!/bin/zsh
# Owner opt-in only: no default store path and no discovery of owner containers.
set -euo pipefail
usage() {
  print -u2 -- 'usage: phase2/migration-dry-run.zsh (--approve-owner-store | --fixture) --source-quiescent --store-directory ABSOLUTE_PATH [--store-name default.store]'
  print -u2 -- 'Quit the app writing that store first. The entire supplied directory (WAL and external blobs included) is copied to a disposable writable temporary folder.'
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
out=''
cleanup() {
  [[ -z $out ]] || python3 "$repo/phase2/migration_copy.py" cleanup "$out"
  rm -f "$request"
  rmdir "$lock"
}
trap cleanup EXIT
out=$(mktemp -d "${TMPDIR:-/tmp/}AtticS6Migration.XXXXXX")
print -- "Report directory: $out"
# Hash the staged source, make a writable copy, and fingerprint all legacy
# physical rows. Only the copy is ever opened by SQLite or the app stack.
python3 "$repo/phase2/migration_copy.py" prepare "$source_dir" "$store_name" "$out" "$mode" "$repo"
python3 - "$request" "$out" "$store_name" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'copy': str(pathlib.Path(sys.argv[2]) / 'copy' / sys.argv[3]), 'report': str(pathlib.Path(sys.argv[2]) / 'migration-report.json')}))
PY
wrapper=/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh
# The isolated unit-test host is used, never Attic S6 or the owner's app.
result=0
OS_ACTIVITY_MODE=disable "$wrapper" -project "$repo/Attic.xcodeproj" -scheme Attic -configuration Local \
  -destination 'platform=macOS' -derivedDataPath "$repo/.build/dd" \
  -only-testing:AtticTests/NotesMigrationAcceptanceTests/testOwnerApprovedCopiedStoreDryRun \
  CODE_SIGNING_ALLOWED=NO test 2>&1 \
  | python3 "$repo/phase2/migration_copy.py" filter-log > "$out/test.log" || result=$?
python3 "$repo/phase2/migration_copy.py" finalize "$source_dir" "$store_name" "$out" "$result"
print -- "Migration report: $out/migration-report.json"
print -- "Integrity report: $out/integrity-report.json"
exit $result
