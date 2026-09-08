# Attic interaction and visual refinement — 8 September 2026

Status: integrated implementation and final 535-unit-test gate pass. Native UI coverage is partial because recorded concurrent desktop input interrupted several checks. Preview build/identity is recorded below when available. This document does not claim physical trackpad, complete visual/accessibility, or sustained performance acceptance.

## Scope and provenance

- Baseline: `codex/attic-recovery-20260907` at `2255f107b450a661b6ea87a1e20de2579a91c2cc`.
- Integration: `codex/attic-refinement-20260908`, `/Users/taha/Developer/attic-recovery-20260907`.
- Three independent worktrees were created from that exact baseline: `codex/attic-motion-20260908`, `codex/attic-canvas-input-20260908`, and `codex/attic-notes-layout-20260908`, at identically named sibling directories. The parent owns shared visual files, integration, all Xcode runs, and GUI access.
- Preserves the accepted b0a6c41 → adaptive themes → corrected trackpad-hide lineage. No discarded Pro experiments were merged. The old dirty `squircle-panel` checkout, official user stores, iPhone target, CloudKit/APNs and production signing remain outside scope.

## Changes

- Motion: one corner-collapse presentation path, continuous two-finger swipe progress, cancellation/reversal restoration, matching reveal, reduced-motion behavior, and interruption fences. Native panel bounds remain authoritative during the layer presentation; no captured background or continuous polling was introduced.
- Composer: task entry row increased from 42 to 54 points, retaining 42-point hit targets/34-point visible actions; horizontal inner padding increased from 2 to 8. Expanded height is 100 points, with matching content clearance. Notes composer dimensions are not silently changed.
- Clear foreground: restrained centered opposite-tone edge, stronger task labels/counters/actions/neutral indicators, and matching native Notes/Canvas paint. No surface opacity, blur, refraction, broad scrim, or captured-background processing change. This is foreground contrast treatment, not pixel-sampled background adaptation.
- Notes: removed the 96–170-point editor cap and nested scrolling. A stable native text editor and inline attachments share one document scroll view; an empty document fills the available viewport. Thumbnail demand is bounded by visible card size and stops when scrolled out, the panel hides/is occluded, or the library covers the writer.
- Canvas: I-beam Text tool with direct click-to-type, no macOS placement popover. Failed saves retain reachable drafts. Native text layout reuses its layout manager during typing. Viewport event ownership/lifecycle and focused Fit/Reset routing are corrected.

## Verification ledger

All result bundles and logs are under `.build/evidence/` in the integration worktree.

| Checkpoint | Result | Follow-up |
| --- | --- | --- |
| refinement-focused-1 |186/187 | Notes empty-host phantom accessory height; corrected |
| refinement-focused-2 |189/189 | Focused Notes/Canvas domain/session/storage/settings |
| refinement-panel-1 |142/142 | Motion, geometry and window-state regressions |
| refinement-full-1 |524/526 | Native optical-font test assumption and virtual-first-board failed-draft navigation; investigated and corrected |
| refinement-full-2 |531/532 | Canvas paint fixture sampled semantic edge and mixed appearances; corrected without weakening image-state isolation |
| refinement-full-3 |534/534 | No failures, skips or runtime warnings; before final section-return shortcut correction |
| refinement-full-4 |535/535 | Final production source; no failures, skips or runtime warnings |
| refinement-ui-focused-1 |3/3 | Native composer padding, Notes full-height typing/library, panel resize/minimum/docked edges |
| refinement-canvas-ui-1 |0/1 | Reproduced Fit shortcut failure immediately after inline editing |
| refinement-canvas-ui-2 |0/1 | Editing/zoom/shape operations passed; reproduced zoom failure on section return |
| refinement-ui-full-1 |10/13 | Complete semantic text/shape/zoom/section-return/relaunch flow passes. Eraser, image flow, and Notes library checks failed with recorded concurrent desktop/input transitions; not a green full suite |
| refinement-ui-recheck-1 |2/3 | Notes library and image flow pass unchanged. Eraser test fails before Canvas opens; recording shows typing into another Codex task during its Cmd4 setup |

The final eraser-selection assertion added after these runs is not yet executed; it distinguishes a missed tool click from actual eraser behavior, without retries or weakened assertions. A quiet-input rerun is required. Earlier failing checkpoints are retained here rather than presented as passes.

Project-generation verification passes and the generated project is current. No project inputs or file memberships changed, so no regenerated-project diff is needed. Static analysis before the last viewport-focus correction passed with exit0/no output; that checkpoint alone does not prove the later change analyzed.

## Workstream ownership and source commits

| Workstream | Branch final SHA | Changed files |
| --- | --- | --- |
| Canvas | `codex/attic-canvas-input-20260908` at `78e3fb5750453a4fe081f403e251302f7d1e1fa3` | `Attic/App/CanvasEditCommandRoute.swift`; `Attic/Canvas/CanvasControls.swift`, `CanvasSemanticInteraction.swift`, `CanvasSemanticObject.swift`, `CanvasSemanticRenderer.swift`, `CanvasSession.swift`, `CanvasSurfaceMac.swift`, `CanvasSurfaceRenderer.swift`, `CanvasTypes.swift`; `Attic/Views/Panel/CanvasPanelContent.swift`; `AtticTests/CanvasDomainTests.swift`; `AtticUITests/CanvasUITests.swift` |
| Notes | `codex/attic-notes-layout-20260908` at `a20ab111a65095301f462fba3af2f76c260897b9` | `Attic/Views/Panel/NotesPanelContent.swift`, `NoteAttachmentTray.swift`; `AtticTests/NoteAttachmentTests.swift`, `NoteDraftControllerTests.swift` |
| Motion | `codex/attic-motion-20260908` at `f211d3d8c472b6375e8723cec4a65509146a90e1` | `Attic/Window/AtticPanel.swift`, `AtticPanelController.swift`, `PanelUIState.swift`; `Attic/Services/PanelGeometry.swift`; `AtticTests/PanelGeometryTests.swift`, `PanelSquircleGeometryTests.swift` |
| Parent visual/integration | Runtime-source head `a085ac3` on integration branch | `Attic/Design/AtticStyle.swift`, `AtticTheme.swift`; `Attic/Views/Panel/AtticPanelView.swift`, `TaskRowView.swift`, `TaskSectionView.swift`; `AtticUITests/AtticUITests.swift`; this report |

All three implementation worktrees are clean. Read-only reviews used the integrated commits, not extra review branches: the Notes owner reviewed motion; the motion owner reviewed Notes, shared visuals, and final Canvas routing. Meaningful findings were returned to their existing owners and cherry-picked separately. The baseline branch remains at2255f10. No push occurred.

## Commands

Unit runs use this exact command with the checkpoint name substituted for `NAME`:

```sh
xcodebuild -quiet -jobs 2 -project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData -resultBundlePath .build/evidence/NAME.xcresult CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=com.taha.Attic.recovery20260907.unithost ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME=AtticRecoveryUnitHost ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME=AtticRecoveryUnitHost ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER=com.taha.Attic.recovery20260907.tests test
```

Native UI runs use:

```sh
Scripts/run_local_ui_tests.zsh --app-bundle-id com.taha.Attic.refinement20260908.ui --ui-test-bundle-id com.taha.Attic.refinement20260908.uitests --unit-test-bundle-id com.taha.Attic.refinement20260908.unituitests --product-name AtticRefinementUI --display-name 'Attic Refinement UI' --derived-data /Users/taha/Developer/attic-recovery-20260907/.build/UI --result-bundle /Users/taha/Developer/attic-recovery-20260907/.build/evidence/NAME.xcresult
```

Focused UI runs append `--only-testing AtticUITests/Class/testName`. The three-test checkpoint selects `AtticUITests/testCreateAdvanceCompleteAndOpenContextMenu`, `AtticUITests/testNotesEditorKeepsDraftWhileBrowsingSavedNotes`, and `AtticUITests/testNativePanelResizeKeepsDockedEdgesAndMinimumSize`. Canvas checkpoints select `CanvasUITests/testSemanticTextAndShapesEditTransformUndoAndSurviveRelaunch`.

## Review and performance boundaries

- Independent motion review: no concrete source-level finding after settings reanchor and cumulative slow-intent corrections. Actual animation completion timing/physical swipe feel remain separate proof gates.
- Independent visual/Notes review found hidden-panel/library thumbnail demand remaining active; corrected with event-driven visibility gates. No new observer polling or text-editor recreation.
- Native UI exposed missing menu-shortcut routing and section-return behavior, not assumed deleted-editor focus; failures are investigated from AX/event evidence.
- Review also caught Caps Lock/numeric-keypad modifier handling in the new viewport shortcut path; corrected and re-reviewed. Explicit viewport commands may claim unassigned window focus after section return, but never grab a foreign editor's focus on appearance.
- Native layout reuse avoids a fresh full CoreText layout on each draft keystroke. Visible-card QuickLook demand avoids eagerly decoding every attachment at a fixed 2×960×720 target. These are structural improvements, not measured CPU/GPU/energy or user-perceived latency claims.
- Remaining acceptance includes physical pinch/swipe direction and reversal, all corner/size combinations, visual judgment of the foreground treatment across backgrounds, IME/VoiceOver/full keyboard access, large attachments/long notes and sustained resource profiling. Passing builds/tests are not substitutes.
- Full UI run emitted two AppKit quality-of-service warnings. They are not suppressed or classified as application defects without a matching stack/profile. The host also had substantial concurrent CPU activity from unrelated apps; no quiet before/after CPU/GPU/memory/energy benchmark was obtained.
- Notes and Canvas reviewers inspected saved failure videos/AX/events. Notes Browse overlapped a desktop/window transition; image disappearance preceded the resize commands; the isolated eraser rerun never entered Canvas and overlapped typing into a different Codex task. No speculative eraser/persistence fix was made from contaminated events.
