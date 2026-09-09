# Scroll-under-controls validation — 2026-09-09

Branch: `codex/attic-scroll-under-controls`. Baseline: `bd5e246`.

## Change

The panel previously shortened its scrollable viewport with outer padding, and
Notes placed its header and composer outside the native scroll view. Content
therefore clipped at internal horizontal boundaries instead of moving behind
the stationary controls.

Tasks, saved notes, and the note editor now use full-height viewports with
document padding for reachable first/last content. The Notes title scrolls with
its body and attachments; the composer stays overlaid. Native caret scrolling
reserves room above/below the controls without shortening the wheel viewport.
Canvas bounds and the approved Balanced Glass materials are preserved.

## Evidence

- `.build/evidence/scroll-full-1.xcresult`: 548 unit tests passed, zero failures,
  skipped tests, or runtime warnings. Includes a rendered AppKit/SwiftUI harness
  asserting full viewport height, content entering the top control band, bottom
  reserve, retained text, and a caret reachable above the composer.
- `.build/evidence/scroll-ui-2.xcresult`: incremental typing/focus and browsing
  saved notes while preserving the draft passed. The new scrolling test failed
  during XCTest's automatic hit-point lookup for the native text view.
- The UI scrolling test uses a visible viewport coordinate and app-level key
  events to avoid XCTest trying to scroll the oversized text view into view.
- `.build/evidence/scroll-ui-4.xcresult`: XCTest timed out synthesizing the long
  typing event. Shortened fixture text retains 30 lines and scroll overflow.
- `.build/evidence/scroll-ui-5.xcresult`: scrolling UI test passed with zero
  runtime warnings. Verifies viewport underlap, stationary top/bottom controls,
  and the title moving upward on Page Down. Inspected exported attachment
  `scroll-ui-5-attachments/528BBA27-AE37-43B2-ABD5-FCDAAEDA8F6F.png`: numbered
  text visibly continues behind the pin control to the outer rounded edge.

## Isolated preview

- Display name: `Attic Scroll Under Preview`
- Bundle identifier: `com.taha.Attic.scrollunder.preview`
- Executable: `.build/ScrollUnderPreview/Build/Products/Local/AtticScrollUnderPreview.app/Contents/MacOS/AtticScrollUnderPreview`
- Launcher provenance: `.build/ScrollUnderPreview/PreviewState/`
- Build log: `.build/evidence/scroll-preview-build.log`

## Remaining manual acceptance

Physical trackpad/wheel inertia, text selection across control bands, resize at
all panel sizes, active/inactive appearances, multiple desktop backgrounds,
and VoiceOver navigation still need user acceptance. Automated layout and
keyboard checks do not establish those results.

This is macOS/local-only evidence, not iPhone, CloudKit, APNs, TestFlight, or
Production validation. Existing app stores and other worktrees are untouched.
