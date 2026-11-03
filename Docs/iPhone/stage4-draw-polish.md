# Stage 4 — iPhone Draw editor polish (D1/D2/D3/D5)

**Status: source-only implementation and review; iOS build, tests, visual review, and interaction sign-off are outstanding.** This work follows Claude's `ref/design/iphone-gap/index.html` Draw sheet, which **has not yet been reviewed by the owner**. It is not evidence that the Stage 4 gate has passed.

## Source audit before this polish

`AtticMobile/App/PhoneDrawEditor.swift` already had the main Draw implementation. Specifically:

- **D1:** shape picker for rectangle, ellipse, line, and arrow; expandable ink-colour swatches, with the Undo and New canvas controls hidden while a strip is expanded.
- **D2:** second-tap Pen and Text size strips with three sizes each.
- **D3:** object picking, selection and marquee, select-more/select-all, dragging, a selection action bar and Style colours/sizes/corners, duplicate/delete, front/back ordering, line-end adjustment, text-width adjustment, and four corner handles for other objects.
- **D5:** two-finger pan, pinch zoom clamped by `DrawViewport` to 10–400%, transient zoom percentage, and the Fit pill when content leaves the clear board area.

The page also already used coalesced Pencil/finger samples, smoothed pen strokes, whole-stroke erase, editable text, persistent Draw commands, Undo, PNG/PDF export, canvas switching and a generated thumbnail path. These are source-observed capabilities; they have **not** been verified on a device in this pass.

## Changes on `iphone/build-drawpolish`

- Draw selection now draws eight corner/edge handles for ordinary single- and multi-object selections. Edge handles resize on the relevant axis, while groups and images retain proportional scaling. Text retains its left/right width handles, line/arrow endpoint dragging retains direction, and a zero-distance resize leaves objects unchanged. The shared touch geometry is factored into an internal `PhoneDrawSelectionGeometry` in the owned editor file for direct unit tests.
- The accessibility board reports object count or selected-object details with zoom percentage. VoiceOver custom actions navigate objects in both directions, edit selected text, delete or nudge the selection, and fit the canvas; adjustable actions zoom around the clear board's centre. The zoom pill exposes its current state to assistive technology.
- Expanded Pen and Text size rows can be collapsed in place. Switching away from Select clears select-more mode, and switching canvases clears transient selection state.
- Switching canvases only commits the new active ID after a successful open, preserving the prior canvas if loading fails. Deleting a canvas cancels stale thumbnail work and opens the next available or a fresh canvas without scheduling a thumbnail for the deleted canvas.

## Regression tests added (not executed)

`AtticMobileTests/PhoneDrawExchangeTests.swift` adds five tests covering eight/specialized handles, opposite-edge anchors and proportional group resize, line direction/text width/no-op resize, accessible selection cycling, and persisted multi-object resize/move with reopen/Undo/Redo. The pre-existing persisted-stroke/PNG/PDF exchange test remains.

## Lead validation before sign-off

1. When the Air is free, **build the iOS target and run `PhoneDrawExchangeTests`** (then the relevant iOS test suite) on the child branch through the project's locked build/test workflow. Record any compiler or test failures. Nothing was built or executed in this source-only pass; do not count syntax parsing as typechecking or a test pass.
2. Capture **headless iPhone Simulator Light and Dark** screens and compare them at the same width with Draw screens D1, D2, D3, D5 in the immutable gap sheet. Exercise expanded/collapsed strips, shape/swatch sizes, tap vs drag, marquee/select-more, small and overlapping selections, eight handles, line endpoints, text wrapping, group/image resize, Style, and keyboard/Dynamic Type placement.
3. Exercise two-finger pan/pinch at its 10% and 400% limits; check zoom anchoring, the percentage/Fit pill, selection overlay after zoom, and recovery from a lost drawing. Verify VoiceOver focus, announced selection, custom actions and adjustable zoom in the running app. Test touch/Pencil input on hardware if that proof is required.
4. Verify canvas creation/switching/failed-open behavior, save/reopen, deletion with pending thumbnail work, Undo/Redo, and PNG/PDF exports against actual persistence. Review screenshots and device behavior separately from the source audit.

No Xcode, Simulator, iOS compile, unit-test execution, Apple Pencil hardware test, real-device test, signing, CloudKit, APNs, or owner-data operation was performed in this child task. This document is a handoff for the lead's remaining verification, not an acceptance record.
