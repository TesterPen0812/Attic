#!/bin/sh
# Separate measurement app; never links Attic or opens an Attic data store.
set -eu
output=${1:?Usage: build_test_focus_sentinel.sh /tmp/unique-sentinel.app}
if [ -e "$output" ]; then
  echo "Refusing to replace an existing sentinel bundle: $output" >&2
  exit 1
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$output/Contents/MacOS"
cat > "$output/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.taha.Attic.TestFocusSentinelFG</string>
<key>CFBundleName</key><string>Attic FG Focus Sentinel</string>
<key>CFBundleExecutable</key><string>AtticFGFocusSentinel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -target "$(uname -m)-apple-macosx26.0" "$script_dir/sample_invisible_test_host.swift" -o "$output/Contents/MacOS/AtticFGFocusSentinel"
codesign --force --sign - "$output"
