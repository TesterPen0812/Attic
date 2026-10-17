# Round D2 diagnosis evidence

Base: `b07795e41a9cb44326b4614202ad9bfc85696dc7`, branch `phase-x/d2`.
Product sources are unchanged. The five regression tests intentionally remain red.

The test host uses `com.taha.Attic.preview.d2.unithost`, and has activation policy
`prohibited`. The only windows created by D2 are unshown, at (-9000, -9000).
A test-only `NSWindow.isKeyWindow` getter returns true so stock AppKit creates its
real `NSTextInsertionIndicator`; no window is ordered or actually made key.
Renders are `cacheDisplay` bitmaps, not screen captures. An opaque test background
makes the editor's transparent drawing readable; the geometry is unchanged.

On this machine: macOS 27.0 (26A5425a), SDK 27.0, arm64, 2x bitmap scale.
Use installed AppKit `NSTextView.h` and `NSTextInsertionIndicator.h` for the public
APIs. Each D2 test keeps PNG and JSON attachments in xcresult, including failures.

## Reproduce

```zsh
F=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
I=(ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=com.taha.Attic.preview.d2.unithost ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER=com.taha.Attic.preview.d2.tests ATTIC_MACOS_BUNDLE_IDENTIFIER=com.taha.Attic.preview.d2)
Scripts/xcodebuild_locked.sh build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local -destination platform=macOS -derivedDataPath .build/dd-d2 "${F[@]}" "${I[@]}"
Scripts/xcodebuild_locked.sh test-without-building -project Attic.xcodeproj -scheme Attic -configuration Local -destination platform=macOS -derivedDataPath .build/dd-d2 -only-testing:AtticTests/RoundD2DiagnosisTests -only-testing:AtticTests/RoundO3NotesTests -only-testing:AtticTests/PhaseXCaretTests -resultBundlePath .build/d2-evidence-recheck.xcresult "${F[@]}" "${I[@]}"
```

Wait for test-without-building to exit before exporting attachments or starting
another build. A result bundle path must be new for each run.

```zsh
xcrun xcresulttool export attachments --path .build/d2-evidence-recheck.xcresult --output-path .build/d2-evidence-recheck-attachments
PATH=/opt/homebrew/opt/ruby/bin:$PATH bundle exec ruby Scripts/verify_project_generation.rb
```

## Outcome

Build-for-testing passed; project regeneration verification passed.
28 tests: 23 pass, five fail, no skips. The five failing D2 cases contain 27
assertion failures. Three D2 causal controls, five existing PhaseXCaret tests,
and all 15 RoundO3Notes tests pass. No CI was requested or dispatched.

`measurements.json` contains exact point rectangles and native view trees.
`stock-vs-ours.csv` records the native indicator comparison.
`render-manifest.json` maps the 81 PNGs to their tests.
`pixel-measurements.json` independently measures the blue stroke in the PNGs
(blue >160, red <90, green between 60 and 200; 2 pixels per point).
`test-summary.json` and `test-outcome.txt` preserve the final run's results.

The pre-O3 control replays the old content-delegate policy for unstructured
callout paragraphs by returning to the default storage delegate. It first
invalidates with the current delegate to isolate stale layout. This is a
controlled policy comparison, not execution of an older binary.
