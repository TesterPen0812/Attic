# UX refinement — September 12, 2026

Baseline: approved original-motion candidate, `ae6418c1af690e29d15a20344cdb9765a23d3f85`
plus its uncommitted changes, copied from `/Users/taha/Developer/attic-funnel-redo`.
The approved candidate stays untouched. Work occurs on `codex/attic-ux-refinement`.

## Implemented scope

Checks below record implementation. Live evidence and remaining UAT are separated below.

- [x] Subpanels: content scrolls underneath floating top/bottom controls with safe spacing and hit regions.
- [x] Parent completion: unfinished children prompt a calm confirmation; user can complete the parent anyway. Preserve unfinished children unless explicitly chosen otherwise.
- [x] Completed items sort below unfinished items, including subtask lists.
- [x] Subpanel collision: transient families choose free space around pinned families; if the screen is full, placement minimizes overlap. Switching transient families remains predictable.
- [x] Canvas: completely redesign bottom toolbar; verify every control and consistent hover feedback, including Add Shape.
- [x] Canvas cursor: visible in dark/light, precise hotspot, ordinary arrow and interaction over controls.
- [x] Canvas: use full panel surface with floating controls instead of inset boxed workspace.
- [x] Canvas: reproduce/fix shape resizing and audit creation, selection, move, resize, delete, undo/redo and export.
- [x] Header dragging docks/repositions only; two-finger swipe remains explicit collapse gesture. Preserve normal idle auto-hide.
- [x] Docking preview indicator appears outside the panel without colliding with chrome or intercepting input.
- [x] Review compact panel/text/icon sizing; apply a restrained coherent density while preserving usable targets and existing user size preferences.
- [x] Investigate unpinned MAIN panel failure to auto-hide. Preserve the deliberate subpanel latching/outside-click behavior, including dragged subpanels and protected entry focus/drafts.
- [x] Notes: text sizing matches the panel and deleting selections never restores stale text.
- [x] Tasks: durable image attachments, compact thumbnail indication inspired by supplied image, and external drag export including attached image files.
- [x] Popovers/confirmations: coherent size, anchoring, dismissal and visual restraint.
- [x] Saved notes: squircle surface; remove heading and full-width Return to writing bar; floating back/close/new-note controls with scroll-under content.
- [x] Build, focused behavioral regression tests, project regeneration if needed, isolated preview and rendered inspection.
- [x] Record exact preview provenance, resource evidence, and remaining physical/accessibility UAT.

## Incoming observations

Additional user reports are appended here and incorporated without dropping this scope.

- [x] Fix unreliable Canvas zoom and verify fit/reset/gesture behavior.
- [x] Declutter Notes: floating plus for attachments and new-note button at bottom right;
  replace redundant manual-save control with access to saved notes (autosave remains).
- [x] Repair file attachment entry and show images initially as compact thumbnail/file
  cards matching the third screenshot. Support reordering/resizing cards and inline
  placement between note paragraphs, as confirmed by the user. Preserve all prior tasks.

- User clarified that the idle auto-hide bug affects the main panel only.
  Restored the original subpanel latching and composer-lock predicates immediately;
  explicit/dragged subpanels continue to wait for outside clicks.

## Evidence and decisions

The two supplied screenshots are references for overlapping image thumbnails and
the saved-notes drawer layout. They do not authorize changes to unrelated data.
Squircle geometry will remain consistent with the established panel shell.

## Verification

- `VerifiedUnit.xcresult`: 683 passed, 3 skipped, 0 failed, 0 runtime warnings.
  This predates the final native attachment handles and user-selected-file entitlement.
- `UXInitialUI.xcresult`: runner failed before executing tests (automation mode
  initialization timeout). Mac was subsequently unlocked; no UI passes claimed here.
- Direct CUA checks in the isolated `com.taha.Attic.ux.refinement` preview:
  parent completion confirmation/override leaves the unfinished child intact;
  completed child moves below unfinished child; subtask composer spacing;
  full-panel Canvas drawing, undo/redo, zoom menu, fit below chrome, rectangle
  creation and free resize; Notes text sizing and compact floating controls;
  selected text deletion stays deleted across app restart; saved-notes drawer
  floating controls and removal of heading/return bar; native file chooser;
  compact note image import; task image import/thumbnail/popover; inline image
  placement through the attachment menu.
- Live picker failure traced to the missing user-selected-file sandbox entitlement
  in `AtticNotesLocal.entitlements`. Added scoped user-selected read/write access;
  the rebuilt signed app opens the picker and imports the selected image.
- Native Notes drag and resize verified: an inline card moved to UTF-16 offset 36
  before the third paragraph; drag resizing persisted about 240 × 132 points.
  Rebuilt preview 6 reopens it in the correct paragraph gap at its saved size.
  Cards are sibling document views, preserving native hit testing and accessibility.
- `FinalUXUnit.xcresult`: 685 passed, 3 skipped, 0 failed, no runtime warnings.
- `UXUnlockedUI.xcresult`: five passed; the sixth assumed Fit must change width
  by >2 points. Recorded geometry showed a correct 99% fit and recentering.
  The test now checks scale OR position and still requires Reset to restore
  the exact original size and position. `CanvasFitVerifiedUI.xcresult` passes
  the full text/shape/edit/resize/undo/fit/reset/section-change/relaunch test.
- The unlocked UI run reported one QoS priority-inversion warning during the
  multiple-pinned-family test without a source location. It is not treated as
  proof of an app defect or a clean performance pass; attribution remains open.
- Finder exposed the transferred Plan weekend folder containing Task.txt and
  1-UX-attachment.png. The PNG SHA-256 matches the fixture exactly:
  `0f4d4c22bf8b2581ba94f2044c08bc520b90f2cb81a320e2e2fc22828a348501`.
  This verifies a materialized transfer representation, not every destination app.
- Project generation verification and `git diff --check` pass.

## Resource evidence

No new repeating timers were added. Task-image I/O and thumbnails run through an
actor with a bounded thumbnail cache. Attachment placement changes metadata only;
resizing commits once on mouse-up. Existing visible/hidden hover sampling is reused.
A 30-second open-preview sample measured 13.3% of one CPU core on average and
109–128 MiB RSS while user activity was uncontrolled. This is an interaction sample,
not an idle baseline or battery/energy measurement. Raw sample:
`.build/ux-resource-sample.json`.

## Remaining validation

Physical trackpad pinch and two-finger dismissal feel, corner destination indicator
placement during fast drags, VoiceOver, broad theme contrast, and Instruments energy
profiling still require dedicated UAT. The targeted native tests below pass; these remaining checks are not claimed as
completed by source review or the local-only preview.


## Final native checks and preview

`FinalCanvasIdleUI.xcresult`: four passed, zero failed. Native pointer input verifies
that a task draft protects the main panel, clearing it permits idle dismissal, and
an autosaved note can dismiss despite retained editor focus. Canvas image paste,
move, resize, delete/undo, pinning and document creation also pass. Together with
the earlier five successful tests and the corrected full Canvas test, all ten
selected native UI scenarios now pass. This final run also emitted the unattributed
QoS warning; diagnostics are retained under `.build/FinalCanvasIdleDiagnostics`.
The available stack contains unsymbolicated addresses, so no source cause is claimed.
The hover regression opts into the real production monitor only inside the existing
UI-test mode; ordinary UI tests keep their established presentation grace. Canvas
UI tests now restore the clipboard they found before running.

Final preview 7:

- Branch: `codex/attic-ux-refinement`
- Commit: `ae6418c1af690e29d15a20344cdb9765a23d3f85` plus uncommitted inherited and UX changes
- Display name: `Attic UX Preview`
- Bundle: `com.taha.Attic.ux.refinement`
- App: `/Users/taha/Developer/attic-ux-refinement/.build/Preview/Build/Products/Local/AtticUXPreview.app`
- Executable: the app's `Contents/MacOS/AtticUXPreview`
- Executable SHA-256: `0a8d6461094b6c713b921508583c5fdb02d984c7a539a43dc73c5c94dd7281b8`
- Local-only, ad-hoc signed, sandboxed; scoped user-selected read/write entitlement.
  No CloudKit or APNs entitlements. No official install, merge, push, or user-store reset.
- Approved fallback `/Users/taha/Developer/attic-funnel-redo` remains untouched.

Final idle sample (`.build/ux-idle-resource-sample.json`): pinned Tasks preview with
one image task, no automation during the 30-second interval, averaged 0.37% of one
CPU core. RSS moved from 112.5 MiB to 84.0 MiB. This is a small idle fixture baseline,
not a claim about heavy canvases, large libraries, battery life, or release builds.
