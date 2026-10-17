# D3 measurement evidence

Branch `phase-x/d2`, base `6f875428`. Measurement and design only.
Read [the report](../round-d3-report.md) before treating an experimental variant
as a proposed product implementation. An attractive numeric box is not sufficient:
`E-typographic` deliberately records the missing native segments it causes.

The D2 stock harness is reproduced in `RoundD3CaretGeometryTests`: ordinary
TextKit 2 `NSTextView`, never-ordered windows at (-9000, -9000), and test-only
key/main getters. AppKit creates the real `NSTextInsertionIndicator`. No stand-in
indicator, geometry mutation, screen access, application activation, user store,
or owner identity is used. Only the prohibited-activation XCTest host runs.

`F-default` uses a default paragraph style with the same actual Attic font.
It is a TextEdit-style reference, not a run of TextEdit or Apple Notes.
Measurements are on macOS 27.0 (26A5425a), SDK 27.0, arm64; PNGs are 2x.

## Reproduce

```zsh
F=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
I=(ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=org.attic.d3.unithost ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER=org.attic.d3.tests ATTIC_MACOS_BUNDLE_IDENTIFIER=org.attic.d3.measurement ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME=AtticD3UnitHost ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME=AtticD3UnitHost)
Scripts/xcodebuild_locked.sh build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local -destination platform=macOS -derivedDataPath .build/dd-d3 "${F[@]}" "${I[@]}"
Scripts/xcodebuild_locked.sh test-without-building -project Attic.xcodeproj -scheme Attic -configuration Local -destination platform=macOS -derivedDataPath .build/dd-d3 -only-testing:AtticTests/RoundD3CaretGeometryTests -only-testing:AtticTests/RoundO3NotesTests -only-testing:AtticTests/PhaseXCaretTests -only-testing:AtticTests/RoundD2DiagnosisTests/testO1803GreyBarBelowHeadingIsQuoteDecorationWithOneIndicator -only-testing:AtticTests/RoundD2DiagnosisTests/testO1804ContextualRestyleRestoresLoadedExitPaddingWithoutTyping -only-testing:AtticTests/RoundD2DiagnosisTests/testPreO3CalloutDisplayPolicyStillHasTheContinuationAndBodyGapDefects -resultBundlePath .build/d3-recheck.xcresult "${F[@]}" "${I[@]}"
xcrun xcresulttool export attachments --path .build/d3-recheck.xcresult --output-path .build/d3-recheck-attachments
python3 Scripts/measure_round_d3.py .build/d3-recheck-attachments phaseX/round-d3
PATH=/opt/homebrew/opt/ruby/bin:$PATH bundle exec ruby Scripts/verify_project_generation.rb
```

Result/export paths must be new. Wait for the test command to finish before
exporting. The packager requires Pillow, installed on the measurement machine.

## Files

- `measurements.json`: complete point measurements, including all neighbouring
  line baselines, actual indicator frames, standard insertion segments and
  one-character selection segments. Null segments in the proxy experiment are
  failures of that option, not missing measurements silently filled in.
- `geometry.csv`: flat table of every measurement, with visual baseline changes
  relative to A for the same font and fixture.
- `renders/`, `render-manifest.json`: original native-view cached bitmaps and
  their XCTest attachment identities.
- `comparison-*.png`: crops of those bitmaps at their original 2x pixel scale.
  The same document coordinates are retained across columns.
- `caret-pixels.json`: independent blue-stroke pixel bounding boxes, using the
  same colour threshold as D2. Selection images are excluded. A missing stroke
  is recorded as null; no replacement is drawn.
- `glyph-position-check.json`: thresholded white-ink differences between A and
  E-shell for typed/first/middle wrapped renders, excluding a nine-pixel strip
  at the insertion anchor. All twelve comparisons have zero changed pixels.
- `test-summary.json`, `test-outcome.txt`: final verification results.

The earlier exploratory result bundles remain under ignored `.build/`. The final
evidence is `.build/d3-verified.xcresult`. D2's five known red product regression
tests are unchanged and are excluded from this passing measurement run.
