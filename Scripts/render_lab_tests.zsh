#!/bin/zsh
set -euo pipefail

# Air only, in its agents tmux. The unit host is headless; this run starts
# after the real screen capture batches to avoid changing their timing.
export PATH=/opt/homebrew/opt/ruby/bin:/opt/homebrew/bin:$PATH
cd "${0:A:h:h}"
while tmux -L sshjobs has-session -t renderlab-followup 2>/dev/null; do
    /bin/sleep 10
done
[[ "$(/usr/bin/tail -n 1 /tmp/renderlab-followup.log)" == STATUS=0 ]] || {
    print -u2 'Screen batch incomplete; unit checks not run'
    exit 4
}
print "TEST_START load=$(/usr/bin/uptime)"
Scripts/xcodebuild_locked.sh test -project Attic.xcodeproj -scheme Attic \
    -configuration Local -destination 'platform=macOS' \
    -derivedDataPath "$HOME/Projects/attic/attic-air/.build/render-test-dd" \
    CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
    -only-testing:AtticTests/AdaptiveTasksTests \
    -only-testing:AtticTests/CalendarPageTests \
    -only-testing:AtticTests/PanelChromeTests \
    -only-testing:AtticTests/PanelFrameTests \
    -only-testing:AtticTests/PanelSharedChromeTests \
    -only-testing:AtticTests/PanelShellTests
print 'TEST_PASSED'
