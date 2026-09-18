# Hover + pinnable subtasks: fix-round verification ledger

## Current candidate — September 12, multiple surfaces and native click routing

The historical rounds below are evidence for earlier candidates. This candidate
is uncommitted on `codex/attic-hover-pinned-subtasks` at
`ae6418c1af690e29d15a20344cdb9765a23d3f85` in the Developer worktree.

### Confirmed cause and fix

`AtticPanelSurface` disabled hit testing on its visual background. On the tested
macOS 27 build, this removes blank visible glass from the native event region:
WindowServer picks an underlying application before `NSHostingView.hitTest` can
run. The actual unpinned surface selected ChatGPT window 5688 at header and
bottom padding, but selected its own window over title content. A standalone
AppKit/SwiftUI probe varied backing alpha through 0, 1, 5, 10 and 20 percent:
all missed with background hit testing disabled; all selected the surface with
it enabled, including zero alpha. No opacity/backing-fill experiment remains.

The shared background now participates in hit testing. Actual-app diagnostics
then selected its own window at all three points. Temporary diagnostics were
removed from product source; measurements are in
`.build/WindowServer-click-routing.txt`. The generic host also owns unclaimed
header drags before child hit testing and absorbs empty interior presses. The
main host has an interior fallback. Transparent outside corners retain their
existing geometry policy.

### Current checks

- Project generation: repeatable/current using Homebrew Ruby (`xcodeproj` is
  unavailable in the system Ruby). `git diff --check` passed.
- Full unit suite: **671 executed, 1 skipped, 0 failures**. Result:
  `.build/MultiPanelUnit/Logs/Test/Test-Attic-2026.09.12_00-30-33-+0100.xcresult`.
  Includes independent pin lifetimes/drafts, detached-anchor loss, header/control
  routing through a real hosted representable, and painted-area hit grids for
  auxiliary and main surfaces.
- Focused real UI checks: **3 passed, 0 failed** in
  `.build/MultiPanelUI-hitregion.xcresult`: unpinned blank-strip drag followed by
  single-click entry; four painted points over a verified underlying input;
  button drag-out cancellation followed by normal unpin.
- Complete subpanel UI suite: **16 passed, 0 failed**, no skips, in
  `.build/MultiPanelUI-full.xcresult` (575.7 seconds). This includes the new Add
  affordance and submit-button flow as well as the drag, hover, Escape, scrolling,
  pin-in-place, independent windows, and click-routing regressions.
- Additional matching-settings run (Frosted, corner size 70): **1 passed,
  0 failed** in `.build/MultiPanelUI-frosted2.xcresult`. This verifies blank-header
  dragging, single-click text entry, pin/unpin without movement, Add affordance,
  and submit-button creation under the actual preview appearance settings.
  The first attempt timed out enabling macOS automation before any test started;
  the retry initialized and passed. There are 17 distinct passing UI tests in
  the final candidate across the complete and matching-settings runs.
- Signed local-only preview: built, sandbox/network entitlements verified with
  no CloudKit/APNs. Executable hash:
  `4912dc957a023b75726aa10b717515e8cc32ad3aa44a7ec647b890203684c715`.
  Manifest: `.build/MultiPanelPreview/PreviewState/manifest.txt`.
  App: `.build/MultiPanelPreview/Build/Products/Local/AtticSubtasksMultiPreview.app`.
  Bundle: `com.taha.Attic.local.6c0c7a3d8681`; display: `Attic Subtasks Preview`.
  This intentionally reuses the existing isolated preview store.

### Installed-preview inspection

The old isolated preview was quit cleanly with empty entry fields, and the new
executable was launched against the same preview bundle/store. Its two existing
families, child counts, completion states, and priorities were preserved.

Computer-use inspection confirmed the compact rendered checklist with both
dividers removed, both pin controls working, two separate pinned windows with
the main panel hidden, and one pinned window surviving the other's close. The
main panel was returned to its original unpinned state and both inspection pins
were closed; no tasks were created, edited, completed or deleted.

Native routing snapshots checked top, side margins, bottom and center on the
main and auxiliary windows. Every sampled visible point selected an Attic
window, including the two-pinned/main-hidden state. Evidence:
`.build/ManualRouting-main-and-unpinned.txt`,
`.build/ManualRouting-main-two-pinned.txt`, and
`.build/ManualRouting-two-pinned-main-hidden.txt`.

The computer-use tool's drag calls did not establish a frame change. Real signed
XCUITest press/drags did; continuous physical-hand feel is not claimed by the
computer-use check. The additional signed test also passed with the preview's Frosted style and
70-point corner setting. Physical-hand drag feel remains a user UAT item;
there is no failing product drag assertion in either tested appearance.

Screenshot: `.build/MultiPanelPreview/PreviewState/subpanel.png`.

### Test corrections and negative evidence

- The first UI launch did not initialize due to a macOS authentication-in-progress
  error. No tests passed in that attempt; retry initialized successfully.
- The blank top-strip drag failed before the shared-background fix and passed
  afterward. The former bottom-only test had not exposed this defect.
- Dragging out of a button must cancel its action. The older test incorrectly
  required unpin after releasing outside; it now requires no action/no movement,
  then verifies a normal click works.
- The new native fixture initially mixed hosting-local and window coordinates.
  It now attaches to a hidden panel and converts into the parent's space. Its
  child is installed through `NSViewRepresentable`, as required by SwiftUI.

### Reuse contract

Future note or other auxiliary content can use `PanelSurfaceWindow`,
`PanelSurfaceHostingView<Content>` and `PanelSurfaceDragGeometry`. Content renders
with the shared `atticPanelSurface` modifier and publishes its header and each
control's bounds; its owner supplies lifecycle callbacks. The native types have
no task IDs, checklist data, pin registry, persistence, or fixed content width.


Branch `codex/attic-hover-pinned-subtasks`, fix round on top of `1464ddb`
(the test-only compile fix over feature commit `23ede87`). This ledger covers
the R1–R7 review findings: cause, fix, regression coverage, actual check
result, and the residual native UAT that remains for macOS execution.

Legend: **UNRUN** = not executed in this environment (no macOS/Xcode on the
cloud VM); source-reviewed only. **SCRIPT-VERIFIED** = checked by a repo script
or static analysis run on this box. **NATIVE-UAT** = requires the installed
macOS build to confirm.

| # | Finding (cause) | Fix | Regression coverage | Actual result | Residual native UAT |
|---|-----------------|-----|--------------------|---------------|---------------------|
| R1 | `.subtaskComposer` was derived in `PanelUIState.interactionLockReasons` from *any* draft/focused entry — including drafts inside the independent pinned window and drafts retained after dismissal — so pinned/hidden work held the main panel against auto-hide. | Removed the derived reason; the controller now owns `.subtaskComposer` as a managed lock engaged only while the *transient* surface is open for the drafting/focused family (`syncComposerLock`, driven by `subtaskDrafts`/`focusedSubtaskParentID` sinks + `syncState`). Pin, close, focus loss, main hide/reopen and section switches all release it; pinned work never takes it. | `SubtaskPanelControllerTests`: transient draft locks while open, retained draft after dismissal does not, pinned surface draft/focus never locks, focus-open transient locks then releases on close, main hide releases, section switch with draft releases. `SubtaskTests.testSubtaskDraftSurvivesSurfaceDismissalWithoutLockingMain` updated to the new semantics. | SCRIPT-VERIFIED (regen + static); tests UNRUN | On device: draft in pinned window, move pointer away — main auto-hides; close pinned — stays hidden-normal; hide/reopen main — no stuck lock. |
| R2 | `openTransient` refused the pinned family silently; the controller still replaced the transient's hosted content, producing a window whose family disagreed with lifecycle state. | `openTransient` returns `Bool` and the controller never presents a transient for a pinned family; opens for the pinned family route to `raisePinned` (deminiaturize + order front + optional entry activation), leaving any other transient's family untouched. | `SubtaskPanelControllerTests`: open-for-pinned leaves transient family/state consistent; toggle-on-pinned raises without swapping. | SCRIPT-VERIFIED; UNRUN | Pin A, open B, invoke A's Show subtasks — A's pinned window raises and (when requested) its entry focuses; no duplicate A surface. |
| R3 | Child rename text lived only in a row's `@State`; promoting or swapping the surface rebuilt the row with an empty draft, and hover replacement ignored an in-flight edit. | Rename draft hoisted to `uiState.editingDraftTitle` (seeded by `beginEditing`, cleared by `endEditing`); the field binds it directly so host replacement resumes mid-edit. `surfaceInteractionBusy` (rename/confirmation in the family, or any tracked menu) defers hover-pending opens, explicit other-family opens, and same-family toggle-close. | `SubtaskPanelControllerTests`: hover switch deferred while a child is being renamed, explicit switch deferred during delete-confirmation, toggle-close deferred, draft survives pin→unpin round-trip. `SubtaskTests`: draft seeded/cleared and survives a failed save. | SCRIPT-VERIFIED; UNRUN | Type half a rename, pin/unpin and hover another family — text resumes; complete a rename after a failed save. |
| R4 | Every outside mousedown dismissed the latched surface, including clicks on the surface's own context menu (`.popUpMenu` windows), sheets, or while an in-family confirmation/menu was active. | `noteOutsideMouseDown` now returns early for clicks inside the frame, on the surface/its sheets, on menu/status-bar windows, and while `familyEditBusy` or `menuTrackingActive`. The toggle-suppression pairing is also narrowed from the whole row to the count control's own frame so a same-row dismissal can't swallow the next deliberate toggle. | `SubtaskPanelControllerTests`: menu-tracking sets the busy gate; `familyEditBusy` covers child/parent IDs. Event.window/menu-window branch coverage is native-only (no menu windows constructible in unit tests). | SCRIPT-VERIFIED; UNRUN | Right-click a child, choose from the menu; open delete confirmation and click its Cancel; click a truly unrelated window — surface dismisses only in the last case. |
| R5 | Growth resize applied `framePreservingTop` raw — a growing checklist could extend below the display, and header/error/entry changes weren't reliably re-measured. | `refreshSurfaceSizes` now handles transient (re-anchored `repositionTransient`) and pinned (`pinnedResizedFrame`: host screen by center→intersection→first, top-preserving, `constrainedFrame` clamp) paths; it's driven by store revisions, `lastErrorMessage`, and entry-activation sinks, so child/error/entry changes re-measure and re-clamp. | `SubtaskPanelControllerTests`: growth below a display edge clamps inside the safe area; growth taller than the display shrinks to fit. `SubtaskPanelTests` placement suite still covers initial-show clamping. | SCRIPT-VERIFIED; UNRUN | Near the bottom edge, add long children / trigger an error row / activate entry — every control stays reachable; check a second display. |
| R6 | The entry was a permanent text field; the plus was a disabled submit; Escape only defocused (keeping draft+focus, feeding R1); the transient surface had no Escape dismissal once not editing. | Deliberate entry state `subtaskEntryActiveIDs` on uiState: `+ Add subtask` affordance activates/focuses; Enter saves and stays open for chaining; `.onExitCommand` calls `cancelSubtaskEntry` (deactivates + drops draft). Focus loss, pin/unpin, hides preserve active entry + draft. `SubtaskSurfacePanel` now gives both surfaces a window-level `keyDown` Escape (`onEscape` → dismiss), deferred to the field editor while one is active. | `SubtaskTests.testSubtaskEntryStateLifecycle`; UI test rewrites: affordance appears after Escape-cancel, reopens/focuses on click, defocus+outside-click preserves draft. | SCRIPT-VERIFIED; UNRUN | Escape inside entry cancels; Escape with no field editing dismisses the window — both surfaces; focus loss keeps the draft; pin keeps entry state. |
| R7 | Pinning a second family silently replaced the existing pinned window — an unexplained swap of someone's live checklist. | The pin control is now explicit: when another family owns the pin it shows `pin.fill` in the accent color, help "Replace the currently pinned list", accessibility label "Replace pinned subtask list". Drafts and in-flight edits on both families survive (state in uiState); edit-busy blocks accidental swaps mid-interaction. | `SubtaskPanelControllerTests`: replacement keeps both families' drafts; pinned family moves with no transient for the new family. | SCRIPT-VERIFIED; UNRUN | With A pinned, open B and press pin — control advertises replace; confirm A's pinned window closes only on that deliberate press and A's draft persists. |

## Polish / docs

- Subtle presentation: surfaces fade in (`alphaValue` 0→1 via the window
  animator) unless Reduce Motion is on; pinned surface reuse keeps alpha at 1.
  No genie import — the separate main-panel animation branch is untouched.
- Count control now reports "Hide subtasks" while its family is presented and
  carries an `isSelected` trait for VoiceOver.
- README updated (chevron/collapsible wording removed; hover/pin/replace
  documented). Handoff spec remains the design source.

## Review round 2 — dedicated adversarial reviewer (session `dbe59721`)

A separate Devin reviewer audited `23ede87..c59e4e5` against the handoff and
the R1–R7 claims. All seven fixes verified; it filed 14 findings. Resolution:

| # | Severity | Verdict | Resolution |
|---|----------|---------|------------|
| 1 | P2 | Fixed | `openFamilyPanel` rejected-open path now raises the surface and honors `focusEntry` — repeated "Add subtask…" on an open family works. |
| 2 | P2 | Fixed | `releaseFamilyInteractionState(_:)` runs on every teardown (transient close, pinned close/unpin, Cmd-W, scroll-out, tearDown) — orphaned `taskEditing`/`taskConfirmation` locks can no longer hold the main panel. |
| 3 | P2 (suspicion) | Fixed proactively | Explicit opens now gate on `familyEditBusy` only — a menu's own tracking lock can never eat its menu command. menuTracking still defers pointer-driven paths only. |
| 4 | P3 | Fixed | Hover-enter always schedules; `commitPendingOpen` re-arms via `rearmPendingOpen` while busy — resting pointer opens once the interaction resolves. |
| 5 | P3 | Fixed (residual noted) | Suppression TTL tightened to the click's down→up span (0.3 s) and cleared on every successful open; a stale record can still only affect a same-family toggle inside 300 ms — native UAT to confirm no user-visible residue. |
| 6 | P3 | Fixed | Pointer-leave retry now consults `shouldDeferPointerClose` (surface-owned locks only) instead of global `isInteractionLocked`. |
| 7 | P3 | Fixed | `unpinPinned` skips the transient restore while another family is edit-busy (pinned simply dissolves); `pinFamily` refuses replacement while the displaced family is mid-edit and releases its state otherwise. |
| 8 | P3 | Fixed | `orderSurfaceFront` skips the fade when the surface is already visible. |
| 9 | P3 | Fixed | `setPinnedFrameProgrammatically` suppresses `windowDidMove` persistence during clamps/resizes — position memory only records user drags. |
| 10 | P3 | Fixed | One containment predicate (`containsTransientPoint`) shared by auto-hide coverage and outside-dismissal, extended with the panel↔surface corridor so gap travel counts inside for both. |
| 11 | P3 | Fixed | Count control announces "Reveal pinned subtasks" (no `.isSelected`) when the family's surface is the pinned window. |
| 12 | P3 (suspicion) | Fixed proactively | `pinFamily`/`unpinPinned` re-bump `focusSubtaskEntry` when the family was focused — refocus survives either resign/onAppear ordering. |
| 13 | P3 | Fixed | Removed duplicate didMove/didResize observers in `attach()`; the main panel's delegate path is canonical. |
| 14 | P3 | Partially fixed | Geometry caches now prune on store revisions. Acknowledged: surface error row reflects the global `lastErrorMessage` (store errors carry no provenance); very short displays (<~200 pt usable) can still clip header+entry — extreme edge, documented here rather than chased. |

New controller tests cover: same-family re-open activating the entry,
teardown lock release (transient/pinned/confirmation), unpin re-anchor keeping
the edit, hover re-arm while busy then open, unrelated locks not deferring
close, unpin not evicting a busy surface, pin-replace refusal while busy and
success when idle.

## Review round 3 — local adversarial review of `7535d00`

The cloud reviewer's pass-2 over `7535d00` was cut off mid-analysis; a local
read-only reviewer completed it (report: `.build/LocalAdversarialReview.md`)
and the local implementer independently reached the same four findings plus
one test-proven defect the first native run exposed. Resolution:

| # | Severity | Verdict | Resolution |
|---|----------|---------|------------|
| F1 | P2 | Fixed | `releaseFamilyInteractionState` was host-over-scoped: `belongsToFamily` matched the parent's own id, but the parent's rename field and delete alert live on the MAIN-list row (the surface hosts only child rows + display-only title). Every unguarded teardown (`closePinned`, `windowWillClose`, `unpinPinned` dissolve, transient Escape/scroll-out/`mainPanelDidHide`) discarded a live parent rename or dismissed its alert. Release is now child-keyed (`parentID == familyID`) only; the parent-scope stays in `familyEditBusy`, where it is the correct deferral predicate. |
| F2 | P3 | Fixed | Dying-host focus race: the old host's `isEntryFocused → false` `.onChange` could nil `focusedSubtaskParentID` after the pin/unpin re-bump (AppKit resign isn't synchronous with `orderOut`). Resign now routes through `noteSubtaskEntryResigned` gated by `isLiveSurface(for:mode:)` — only a live host clears the pointer. Two residuals also handled: a same-click pin/unpin resigns the field before its action, so `entryFocusEngaged` treats a resign within `entryResignReuseWindow` (0.5 s) as still-engaged; and `releaseFamilyInteractionState` now clears a stale `focusedSubtaskParentID` when the family's last surface dies (entry row + draft still survive; focus is not grabbed unprompted on reopen). |
| F3 | P3 | Fixed | Replace-pinned refusal while the displaced family is edit-busy was a silent no-op. The pin affordance now disables + dims with "Finish the pinned list's current edit first" help / VoiceOver hint while `pinReplacementBlocked`. |
| F4 | P3 | Fixed | `commitPendingOpen`'s anchor-nil/not-hoverWorthy branch was the only transient teardown skipping `releaseFamilyInteractionState`; it now routes through `closeTransientSurface()`. |
| F5 | P2 | Fixed | First-ever native test run exposed a willSet lag: `@Published` sinks for `subtaskDrafts`/`focusedSubtaskParentID` called `syncComposerLock()` which read the OLD stored values, so the `.subtaskComposer` lock engaged one change late and released one change late — the R1 mechanism never actually worked. Sinks now hand the just-emitted values to `syncComposerLock(drafts:focusedParentID:)`; `refreshSurfaceSizes` triggers (`$lastErrorMessage`, `$subtaskEntryActiveIDs`, `reconcileStore`'s re-fit) defer one runloop turn so the hosting view has applied the change, matching the `noteMeasuredListHeight` precedent. |

New controller tests cover: parent rename surviving pinned close and
main-hide-with-transient, parent delete-confirmation surviving pinned close,
child edit still released on unpin-without-anchor, live-surface ownership
across pin/unpin/dismiss, same-click resign refocus, aged resign not
refocusing, teardown clearing the stale focus pointer, and anchor-nil
maturation releasing the family's state.

Round-3 review loop converged: the spawned adversarial reviewer verified
F1–F5, found N1 (duplicate `.id("subtask-entry-…")` on the `+ Add subtask`
Button and entry HStack — fixed by giving the affordance
`.id("subtask-add-…")`), and returned **CLEAN** on `b245308`.

## Checks actually run

Cloud environment (`7535d00` and earlier):

- `ruby Scripts/generate_project.rb` — project regenerated; new controller
  test file globbed into AtticTests.
- `ruby Scripts/verify_project_generation.rb` — reported current/repeatable.
- Static consistency sweep of all touched files (balanced delimiters,
  call-site/parameter agreement, stale references removed).

Local Mac (this checkout, round-3 fixes on top of `7535d00`):

- `bundle exec ruby Scripts/verify_project_generation.rb` — current and
  repeatable (no project-input changes this round; existing files only).
- `xcodebuild test -scheme Attic -destination 'platform=macOS'
  -only-testing:AtticTests CODE_SIGNING_ALLOWED=NO` — **637 tests, 0
  failures, 1 skipped** (includes all 37 `SubtaskPanelControllerTests`,
  `SubtaskTests`, `SubtaskPanelTests`, `PanelGeometryTests`,
  `PanelSquircleGeometryTests`). The first native run also exposed F5:
  five lock tests failed at `7535d00` before the fix, all pass after.
- `xcodebuild build -scheme Attic -destination 'platform=macOS'
  CODE_SIGNING_ALLOWED=NO` — **BUILD SUCCEEDED** (Local configuration).
  Note: default Debug signing wants a `Mac Development` cert for team
  ZGZWS73268 that is absent from this keychain; `CODE_SIGNING_ALLOWED=NO`
  covers local verification only — preview installs keep using
  `Scripts/launch_local_preview.zsh`'s ad-hoc path.

## Review round 4 — real interaction layer (local Mac, 2026-09-11 evening)

The user's report that the pinned panel accepted button presses but not body
interaction, text entry, or dragging turned out to be three separate
event-delivery problems, all found and fixed on this worktree.

| # | Finding (cause) | Fix | Regression coverage | Actual result |
|---|-----------------|-----|--------------------|---------------|
| I1 | `NSHostingView.acceptsFirstMouse` returns false, so the first click on the nonactivating panel was consumed by key-making and never reached content — first-click focus into the entry looked dead. | `SubtaskHostingView` (both surfaces) answers `acceptsFirstMouse` true. | UI: entry click, child toggle, and controls all exercised by the passing class. | XCUITEST-PASS |
| I2 | The header drag handle was a SwiftUI `.background` representable (`SubtaskWindowDragHandle`); NSHostingView hit-testing never descends into it — presses on empty header space resolve to the hosting view itself — so `performDrag` never ran and the window could not be dragged at all. | `SubtaskHostingView.mouseDown` calls `window.performDrag(with:)` when a press hit-tests to the hosting view inside the top 44 pt header strip (`dragsWindowFromHeader`, pinned only). Controls/fields keep their own presses. `isMovableByWindowBackground` is off — the explicit path only drags the header strip. The representable stays as the AX landmark (`subtask-drag-<id>`, "Drag window"). | `testPinnedWindowDragsAndRemembersPosition` — real press-drag moves the window by the asserted delta and re-pin restores the remembered frame. | XCUITEST-PASS |
| I3 | Entry refocus after pin/unpin/raise asserted `.focused` while the surface wasn't key — no-op on nonactivating panels; a dying host's late resign could also clear `focusedSubtaskParentID` after the re-bump. | `makeKey()` before every entry-focus assertion (raisePinned, openFamilyPanel focusEntry, pin/unpin refocus); `onChange(isEntryFocused)` focus claim gated by `isLiveSurfaceKey`; stale `isEntryFocused` cleared on appear. | `testPinnedWindowSurvivesAppDeactivation`, entry-focus flows across pin/unpin in the class. | XCUITEST-PASS |
| I4 | `commitPendingOpen` re-armed only on `surfaceInteractionBusy` — a live context menu's tracking lock didn't defer the pending open, so ordering a surface front mid-menu could tear the menu down. | Re-arm when `menuTrackingActive`; the busy branch widened to `shouldDeferPointerClose`. | Unit-covered earlier; UI class green. | XCUITEST-PASS |

Environment note discovered during I2: XCUI press-drags starting past
x≈1292 on this desktop never reached the app — a desktop overlay
(Supaste, layer-25 window spanning x 508–1292 with an edge activation
region) claims the press outside its visible bounds. Pressing the handle's
left stretch (x≈1212) delivers the full down→drag→up stream. Real pointer
input is unaffected — the overlay only intercepts during automation.

## Review round 5 — sub-panel repair (local Mac, Opus 5, 2026-09-11 night)

User report: the sub-panel's blank glass, header and padding let clicks reach
windows underneath while rows worked; the pinned header would not drag; hover
open/dismiss and family switching felt slow; the surface was too big.

| # | Finding (cause) | Fix | Regression coverage | Actual result |
|---|-----------------|-----|--------------------|---------------|
| S1 | *(source-level hypothesis, runtime routing unproven)* `AtticPanelSurface` draws its glass in an `.allowsHitTesting(false)` background, so `NSHostingView.hitTest` returns nil over the header, padding and empty list space. On a borderless non-opaque panel that leaves the press unclaimed — the child rows worked because SwiftUI has real content there. Which window actually received those presses was not observed at runtime. `SubtaskHostingView` had `acceptsFirstMouse`/`mouseDown` but no hit-test fallback, unlike `AtticPanelHostingView`. | Geometry-aware `SubtaskHostingView.hitTest`: nil outside the drawn squircle (corners stay click-through), `super.hitTest(point) ?? self` inside — child controls keep their hits, inert interior points are absorbed. Flip-safe by construction (the containment test is symmetric in y for a full-bounds rect) and the conversion is explicit for the drag geometry. | Unit: `testSurfaceContainmentFollowsTheConfiguredCorner`. UI (added, UNRUN): `testPinnedSurfaceAbsorbsInertHeaderAndPaddingClicks`, `testTransientCornerIsOutsideAndPaddingIsInside`, `testFirstClickReachesPinnedControlAfterDeactivation`. | BUILD + unit PASS; pointer proof pending Astra |
| S2 | Pinned header drag used a hard-coded 44 pt strip; corner-aware padding moves the header and its controls, and the strip had no notion of pin/unpin/close ownership. | The content measures its header and control cluster into `SubtaskDragGeometry` (`SubtaskDragGeometryPreferenceKey`, surface-local coordinate space); the hosting view drags only from unclaimed header space, falling back to the 44 pt strip until the first measurement. The controller accepts geometry only from the live pinned surface and resets it when the pinned family changes. | Unit: `testHeaderDragRegionExcludesItsControls`, `testHeaderDragRegionFollowsCornerAwarePadding`, `testDragRegionFallsBackToTheDefaultStripBeforeMeasurement`, `testDragGeometryMergeKeepsEveryControlAndTheLatestHeader`, `testPinnedDragGeometryAcceptedOnlyFromTheLivePinnedSurface`. UI (added, UNRUN): `testPinnedHeaderControlPressDoesNotDragTheWindow` plus the existing drag/position test. | Unit PASS; drag delta pending Astra |
| S3 | `containsTransientPoint` used a fixed radius 18 while the content rendered `settings.panelCornerSize` — coverage and outside-click dismissal disagreed with the painted shape at every non-default corner. | One definition: `SubtaskPanelLayout.surfaceContains(_:in:cornerSize:)` used by the hit test, auto-hide coverage and outside-click dismissal, reading the live setting; padding moved to `SubtaskPanelLayout.surfaceInsets(cornerSize:)`; a live corner change re-applies to both hosts in `refreshSurfaceSizes`. The shared `AtticPanelSurface` is untouched — no global surface redesign. | Unit: `testSurfaceCornerSizeTracksTheLiveSetting`, `testSurfaceContainmentFollowsTheConfiguredCorner`, `testSurfaceInsetsClearTheCurveAndKeepATitleColumn`. | PASS |
| S4 | `SubtaskPanelLifecycle.noteRowHover`/`noteTransientPointer` re-armed the open/close deadline on every callback. SwiftUI re-emits `onHover(true)` whenever the row body rebuilds (store revisions, presentation animation), so a resting pointer's dwell was pushed into the future — the "hover feels slow" report — and repeated leaves postponed dismissal. | Both are idempotent: an existing pending open/close for the same family keeps its deadline. Discovery keeps `openDwell` 0.35 s; `familySwitchDwell` 0.075 s applies while a surface is already open; `closeGrace` 0.45 → 0.14 s, with `commitPendingClose` cancelling when the pointer is genuinely inside the surface or its corridor at maturity so gap travel stays reliable without a sticky timer. Pending family changes, menu/edit deferral, drafts and focus paths unchanged. | Unit: `testRepeatedHoverEnterKeepsTheOriginalDwellDeadline`, `testRepeatedLeaveKeepsTheOriginalCloseDeadline`, `testFamilySwitchUsesFastDwellWhileASurfaceIsOpen`, `testFirstOpenStillPaysTheDiscoveryDwell`, `testCancelledOpenStaysCancelledAcrossRepeatedLeaves`, `testTimingBudgetsStayWithinTheIntendedFeel`, `testHoverSwitchWhileOpenUsesFastDwellThroughTheController`. UI (added, UNRUN): `testBrowsingToAnotherFamilySwapsQuickly`; corridor test reworked to rest 0.35 s in the gap. | PASS (corridor cancellation is native-only) |
| S5 | Surface felt oversized. | `panelWidth` 292 → 272 (still inside the handoff's 260–310 band), `maximumListHeight` 264 → 240. Height still follows content via `clampedListHeight`; no aspect-ratio coupling. Trade-off: at `PanelCornerSize.maximum` the corner-aware padding reaches ~23.6 pt a side, leaving ~151 pt of title column beside the 66 pt control cluster — guarded, not assumed. | Unit: `testSurfaceSizeStaysInsideTheSpecifiedBounds`, `testSurfaceInsetsClearTheCurveAndKeepATitleColumn`. UI: bounded-height test re-based to the 240 pt cap. | PASS |

| S6 | Review finding (Luna Max, P1): the first cut of S4's gap handling called `noteTransientPointer(inside: true)` for corridor points, which CANCELS the pending close. A pointer pausing in the gap past the grace and then leaving downward never enters the surface, so nothing re-arms the close — the panel is stranded open. The corridor also spanned both windows' full height, over-suppressing outside-click dismissal, and cancelling this way could drop a pending family switch. | `SubtaskPanelLayout.pointerCoverage` now returns `.surface` / `.transit` / `.outside`. Only `.surface` cancels. `.transit` DEFERS through the new `SubtaskPanelLifecycle.rearmPendingClose`, bounded by `corridorTransitBudget` (0.6 s), so vacating the corridor closes on the next maturity with no callback and parking in it cannot hold the surface open. The corridor's vertical extent is the row∪surface band plus one row of slack. `commitPendingClose` skips the transit path whenever a pending open for another family exists. | Unit: `testRearmPendingCloseDefersWithoutCancelling`, `testRearmPendingCloseIsANoOpWithoutOne`, `testPointerCoverageSeparatesSurfaceTransitAndOutside`, `testPointerCoverageWithoutAMainPanelHasNoCorridor`, `testCorridorTransitDefersThenClosesOnExitWithoutAnyHoverCallback`, `testCorridorTransitBudgetEventuallyCloses`, `testPointerReachingTheSurfaceCancelsTheCloseOutright`, `testCorridorTransitDoesNotSwallowAPendingFamilySwitch`. UI (added, UNRUN): `testExitingTheGapWithoutEnteringSurfaceStillCloses`. | PASS |

| S7 | Review finding (Luna, P2): `corridorTransitDeadline` survived a real surface arrival. `noteTransientPointer(inside: true)` cleared the pending close but left the spent budget behind, so a later leave into the corridor inherited an already-expired deadline and the second crossing closed the surface mid-gap. | The controller resets `corridorTransitDeadline` on genuine arrival, so every crossing gets a full allowance. | Unit: `testSurfaceArrivalResetsTheTransitBudgetForTheNextCrossing` — arrival → leave → second traversal → vacate. Verified to FAIL without the reset (`unit-tests-6-without-fix.log`) and pass with it. | PASS |

Checks run for this round (logs kept under `.build/opus5-subpanel-repair/`,
unique paths — earlier evidence bundles untouched):

- `xcodebuild build -scheme Attic -destination 'platform=macOS'
  CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED** (`build-1.log`).
- `xcodebuild test … -only-testing:AtticTests CODE_SIGNING_ALLOWED=NO` →
  **664 tests, 0 failures, 1 skipped** (`unit-tests-4.log`, after the S6
  review fix; `unit-tests-2.log` is the 656-test run before it).
  `unit-tests-1.log` records the single obsolete failure first:
  `testRowLeaveSchedulesCancellableCloseGrace` asserted "not yet closed at
  +0.2 s", which is after the new 0.14 s grace; its times are now expressed
  against `SubtaskPanelLayout.closeGrace`.
- `xcodebuild build-for-testing … CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` →
  TEST BUILD SUCCEEDED (`uitest-compile.log`) — **unit target only**; the
  `Attic` scheme does not contain `AtticUITests`, so this said nothing about
  the UI tests. See the round-5 UI evidence section.
- `bundle exec ruby Scripts/verify_project_generation.rb` → current and
  repeatable.

Deliberately NOT run this round: `AtticUITests`, desktop pointer automation,
preview install/launch. Astra owns the desktop and validates the candidate
after independent review. Note that `ATTIC_UI_TESTING` forces the main panel
visible, so no UI test in this class can prove normal main-hide/pinned
coexistence — that stays human UAT.

## Round 5 UI evidence and corrections (Opus 5, 2026-09-11 late)

Real XCUITests were run through `Scripts/run_local_ui_tests.zsh` (AtticUI
scheme, unique identities, isolated derived data/result bundles, exclusive UI
lock). Results, all on this worktree:

| Test | Result | Evidence |
|---|---|---|
| `testPinnedWindowDragsAndRemembersPosition` | PASS | `.build/SubtasksR5UI-smoke.xcresult` |
| `testExitingTheGapWithoutEnteringSurfaceStillCloses` | PASS after test fix | `ui-r5c/ui-r5e.xcresult` |
| `testPointerCorridorAndInsideHoverKeepTransientOpen` | PASS after test fix | `ui-r5c.xcresult` |
| `testTransientCornerIsOutsideAndPaddingIsInside` | PASS | `ui-r5c.xcresult` |
| `testFirstClickReachesPinnedControlAfterDeactivation` | PASS | `ui-r5c.xcresult` |
| `testBrowsingToAnotherFamilySwapsQuickly` | PASS after test fix | `ui-r5e.xcresult` |
| `testPinnedSurfaceAbsorbsInertPaddingInsteadOfPassingThrough` | PASS — but see S1 correction | `ui-r5f.xcresult` |

Test-logic defects found and fixed (no product change was needed for any of
them):

1. **Corridor point computed from the row, not the surface.** The gap midpoint
   between `row.maxX` and `surface.minX` lands ~3 pt INSIDE the main panel,
   because the row's edge sits behind the panel's content padding while the
   real gap is `sideGap` = 10 pt wide. The old corridor test only passed
   because the 0.45 s grace outlived the mistake. Both hover tests now take
   the corridor point from the surface edge.
2. **~1 s polling reported as latency.** `XCTNSPredicateExpectation`
   re-evaluates on a ~1 s timer, so "dismissal took 1.148 s" and "switch took
   1.051 s" measured the poller, not the app. A tight `measureUntil` poll
   replaced it; the family-switch test now compares switch latency against its
   own discovery baseline so accessibility-query overhead cancels.
3. **Racy setup helper.** `makeFamily` called `field.typeText` immediately
   after clicking the entry; `typeText` refuses to dispatch without keyboard
   focus and the menu-open → surface-key → field-editor handoff occasionally
   lands later. The helper now probes focus with an app-level keystroke and
   retries the click.

### S1 correction — the click-through cause is NOT established

The absorption test was rebuilt to avoid the earlier Escape/key-window
confound: it parks a genuinely inert point of the pinned window (the bottom
padding strip below the add affordance) over the main panel's quick-entry
field, clicks it, and requires a subsequent keystroke NOT to land in the
covered field, with a positive control proving the field does take focus from
a direct click.

That test passes **with and without** the `SubtaskHostingView.hitTest`
override (`ui-r5f.xcresult` vs `ui-r5-ab-control-2.xcresult`, the override
removed and restored around the control run). An earlier control with a probe
point inside the child list also passed both ways — that point was not inert
at all, since a SwiftUI `ScrollView` claims its whole frame.

Therefore: **no runtime click-through was reproduced**, and the hit-test
override is NOT demonstrated to fix the user's reported symptom. S1's cause
remains a source-level reading only. The override is retained as narrow
hardening — it makes the AppKit hit shape follow the painted squircle, which
is what keeps the transparent corner wedges click-through at large corner
settings — but it must not be described as the fix for the report. What the
user actually experienced (which surface, which region, which window received
the click, which build) is still unknown and is the main open blocker.

### Build-command correction

An earlier entry claimed `xcodebuild build-for-testing -scheme Attic` showed
the new XCUITests compile. That is wrong: `AtticUITests` is not a member of
the `Attic` scheme (`xcodebuild` refuses the selection outright). UI
compilation and execution go through `Scripts/run_local_ui_tests.zsh` on the
`AtticUI` scheme; the earlier "TEST BUILD SUCCEEDED" lines only covered the
unit target.

## UNRUN — macOS acceptance checklist (not passes)

Unit coverage ran locally (see above). Remaining manual/native items:

Executed locally on this worktree (Local config, ad-hoc signed UI runner,
`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` against the real desktop):

- `AtticUITests/SubtaskHoverPinnedUITests` — **9/9 PASS**
  (`.build/DevinHoverUI-full.xcresult`): hover dwell open/brief-hover
  rejection, pointer-corridor persistence, rapid family switch, pinned
  survival across app deactivation, header drag + remembered position
  restore, pinned count-control announce, busy-family replace disabled,
  Escape matrix (entry-cancel vs window dismiss, both surfaces), bounded
  height on a 12-child family.
- `AtticTests` — **635 pass / 0 fail / 1 skip**
  (`.build/DevinHoverUI/Logs/Test/Test-Attic-2026.09.11_18-40-22-+0100.xcresult`).
- `verify_project_generation.rb` — project current and repeatable.

Still manual/native-only (human pointer, not automation):

- Physical-pointer hover feel: dwell timing, corridor breadth, close grace.
- VoiceOver rotor/FKA walk over affordance, entry, pin/replace, unpin,
  close; Reduce Motion suppressing the fade.
- Pinned window across real Space switches and multi-display clamps.
- AtticUITests outside this class (main-panel, canvas, notes suites) —
  untouched by this branch but unverified here.
