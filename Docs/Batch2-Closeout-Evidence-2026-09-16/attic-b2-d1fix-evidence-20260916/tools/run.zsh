#!/bin/zsh
# Bounded offline XCTest run inside the real AtticUnitTestHost: the injected
# XCTest reads a local configuration (no IDE session, no result reporting to
# xcodebuild), so testmanagerd's IDE handshake is not involved.
# Usage: run.zsh LABEL SECONDS TESTID...
set -u
readonly here=${0:A:h}
readonly label=$1 limit=$2; shift 2
readonly products=${ATTIC_TEST_PRODUCTS:-/Users/taha/Developer/attic-task-panels-v2/.build/DerivedData/Build/Products/Local}
readonly host=$products/AtticUnitTestHost.app/Contents/MacOS/AtticUnitTestHost
readonly bundle=$products/AtticUnitTestHost.app/Contents/PlugIns/AtticTests.xctest
readonly platform=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
readonly config=$here/$label.xctestconfiguration
readonly log=$here/$label.log
"$here/makeconfig" "$config" "$bundle" "$@" >/dev/null || exit 3
{
  print -- "label=$label limit=${limit}s started=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  print -- "tests=$*"
  print -- "products=$products"
  print -- "host_sha256=$(/usr/bin/shasum -a 256 "$host" | /usr/bin/awk '{print $1}')"
  print -- "host_debug_dylib_sha256=$(/usr/bin/shasum -a 256 "${host}.debug.dylib" | /usr/bin/awk '{print $1}')"
  print -- "bundle_binary_sha256=$(/usr/bin/shasum -a 256 "$bundle/Contents/MacOS/AtticTests" | /usr/bin/awk '{print $1}')"
} >"$log"
env XCTestConfigurationFilePath="$config" \
    DYLD_INSERT_LIBRARIES="$platform/usr/lib/libXCTestBundleInject.dylib" \
    DYLD_FRAMEWORK_PATH="$products:$platform/Library/Frameworks:$platform/Library/PrivateFrameworks" \
    DYLD_LIBRARY_PATH="$products:$platform/usr/lib" \
    __XCODE_BUILT_PRODUCTS_DIR_PATHS="$products" \
    "$host" >>"$log" 2>&1 &
readonly pid=$!
print -- "pid=$pid" >>"$log.meta"
elapsed=0
while /bin/kill -0 $pid 2>/dev/null; do
  if (( elapsed >= limit * 4 )); then
    print -- "WATCHDOG: still running after ${limit}s; stopping PID $pid" >>"$log"
    /bin/kill -TERM $pid 2>/dev/null; /bin/sleep 2; /bin/kill -KILL $pid 2>/dev/null
    break
  fi
  /bin/sleep 0.25; (( elapsed++ ))
done
wait $pid 2>/dev/null; code=$?
print -- "exit_status=$code finished=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
/usr/bin/grep -E "Test Suite '.*' (passed|failed)|Executed [0-9]+ test|error:|WATCHDOG|exit_status" "$log" | /usr/bin/tail -12
