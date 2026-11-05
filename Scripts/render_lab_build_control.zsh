#!/bin/zsh
set -euo pipefail
# Run only on the Air. Creates an isolated, ad-hoc signed control in /tmp.
readonly source=${0:A:h}/render_lab_control.swift
readonly app=/tmp/render-lab-control/RenderLabControl.app
/bin/mkdir -p "$app/Contents/MacOS"
/bin/cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.taha.renderlab.control</string>
<key>CFBundleExecutable</key><string>RenderLabControl</string>
<key>CFBundleName</key><string>RenderLabControl</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
/usr/bin/swiftc -O -parse-as-library "$source" -o "$app/Contents/MacOS/RenderLabControl"
/usr/bin/codesign --force --sign - "$app"
print "CONTROL_APP=$app"
