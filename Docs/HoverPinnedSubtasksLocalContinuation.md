# Hover + pinned subtasks: local continuation checkpoint

Durable handoff between the interrupted cloud sessions and the local
implementer/reviewer pair. Update this file whenever the checkpoint moves.

## Current work — multiple independent surfaces (2026-09-12)

The historical rounds below describe earlier candidates, including the obsolete
single-pinned-window and remembered-position behavior. The current uncommitted
candidate in `/Users/taha/Developer/attic-hover-pinned-subtasks` changes that contract:

- Any number of distinct families can remain pinned. Closing/unpinning one does
  not evict another or discard its draft.
- Pinning promotes the actual visible window in place. It never reads the old
  remembered window position. Unpinning while the main panel is visible keeps
  the window in place as a detached transient; otherwise it closes.
- Both kinds of surface drag from the measured header except its controls.
  Dragging a transient cancels hover timers and detaches it from row layout.
  It stays open until outside-click/explicit dismissal or main-panel hide.
  Pinned windows survive main-panel hide.
- Header and footer dividers are removed; the existing compact glass styling,
  corner padding, real checklist rows, and durable TaskStore mutation paths stay.
- `PanelSurfaceWindow`, generic `PanelSurfaceHostingView<Content>`, and measured
  `PanelSurfaceDragGeometry` provide native behavior independent of tasks, for
  reuse by future content. Header routing precedes child hit testing; other
  content retains control events, and empty painted space has a host fallback.
  The main panel also has the empty-space fallback. Unmeasured headers do not
  steal events from controls.

The click-through cause is now reproduced: disabling hit testing on the shared
`AtticPanelSurface` background excludes blank glass from the native event region.
`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` selected the underlying
ChatGPT window at top and bottom padding, while selecting Attic over text. A
standalone native probe varied backing opacity from 0 to 20% without affecting
that result; enabling hit testing fixed the native region even at zero opacity.
The actual app then selected its own window at all three sampled points. The
shared background now participates in hit testing, with no visual fill added.
Verification completed: 671 unit tests executed (one skipped, zero failures),
16 full-suite UI passes plus the matching-settings Frosted UI pass. Native
preview inspection confirmed independent pinned windows across main-panel hide;
see the ledger for exact provenance and the manual gesture limitation.
The new native tests cover a grid across the painted shape and a header with
an event-owning child; real UI tests cover dragging, controls, typing, multiple
windows, and a covered underlying input.

## Coordination handshake (authoritative)

- **Phase:** `REVIEW_CONVERGED` — local adversarial loop ran in-session
  (spawned reviewer subagent, iterated fixes) and returned **CLEAN on
  `b2453087d3b1279a86198e519b8950ba764ee9db`**. The file-based handshake
  below is kept for audit; the separate `.build/LocalAdversarialReview.md`
  reviewer reviewed only immutable `7535d00` (baseline) — its findings map
  1:1 onto the F-ids fixed here.
- **Baseline report consumed:** `.build/LocalAdversarialReview.md` verdict
  on `7535d00` = NOT CLEAN, findings F1–F4 (confirmed by both reviewers).
- **Fix commit:** `209a0eb20967c98770c2b7326b63e226f950cbe9` ("Address
  local adversarial-review findings F1-F5") — F1 child-keyed release,
  F2 host-aware focus handoff + resign-reuse window + stale-pointer clear,
  F3 disabled Replace affordance, F4 uniform teardown, F5 @Published
  willSet lag (`.subtaskComposer` engaged/released one change late — the
  R1 mechanism never actually worked; exposed by the first native run).
- **Review pass 1 on `209a0eb`:** all five fixes verified; one new P3
  found — N1: duplicate `.id("subtask-entry-…")` shared by the
  `+ Add subtask` Button and the entry HStack.
- **N1 fix commit:** `b2453087d3b1279a86198e519b8950ba764ee9db` — distinct
  `.id("subtask-add-…")` on the affordance.
- **Review pass 2 on `b245308`:** **CLEAN** — N1 resolved, `unpinPinned`
  ordering confirmed, `noteSubtaskEntryResigned` guard confirmed safe in
  all interleavings, no new P1–P3 issues on a full feature-surface sweep.
- **Unresolved finding IDs:** none. Residual decisions taken: real
  teardowns clear `focusedSubtaskParentID` (entry row + draft survive);
  same-click resign reuse window = 0.5 s; family-swap leaves focus memory
  for the displaced family (baseline "arguably desirable" remark).
- **Verification at HEAD (`b245308`):** `verify_project_generation.rb`
  PASS; `xcodebuild build -scheme Attic` PASS; AtticTests 637 pass /
  0 fail / 1 skip (includes all 37 controller tests, 9 of them round-3
  regressions). AtticUITests (signed runner) + manual UAT remain with the
  user.

## Round 4 — genuine macOS XCUITest + interaction-layer repair (2026-09-11)

The user reported the pinned panel took control presses but not body
interaction, text entry, or dragging — and required real XCUITest evidence.
Root causes found on this worktree, all fixed (uncommitted on top of
`9199ac9`):

- **`SubtaskHostingView`** (new private `NSHostingView` subclass, both
  surfaces): `acceptsFirstMouse` true (first click reaches content instead
  of being spent on key-making) and `dragsWindowFromHeader` — a press that
  hit-tests to the hosting view inside the top 44 pt calls
  `window.performDrag(with:)`. The previous `.background` drag-handle
  representable never landed in the hit-test chain, so header dragging was
  dead for both real and synthetic input.
- **`SubtaskWindowDragHandle`** now takes `familyID` and exposes
  `subtask-drag-<id>` ("Drag window" AX group) — the drag affordance
  landmark tests and VoiceOver can resolve.
- **`makeKey()` before entry-focus assertions** in `raisePinned`,
  `openFamilyPanel`, `pinFamily`/`unpinPinned` refocus — `.focused` cannot
  land on a non-key nonactivating panel.
- **Phantom focus gate:** `onChange(isEntryFocused)` only re-arms
  `focusedSubtaskParentID` while the family is focused or its live surface
  is key (`isLiveSurfaceKey`); stale `isEntryFocused` cleared on appear.
- **`commitPendingOpen`** re-arms on `menuTrackingActive` and widened the
  busy check to `shouldDeferPointerClose`.
- `isMovableByWindowBackground` off — the explicit hosting-view path owns
  header dragging; background dragging would claim presses on empty list
  space.

UI test repairs: `testPinnedReplacementDisabledWhilePinnedFamilyIsBusy`
now creates a real in-flight rename (a draft alone is not "busy" —
`familyEditBusy` covers editing/confirmation only), and
`testPinnedWindowDragsAndRemembersPosition` presses the handle's left
stretch — presses starting past x≈1292 on this desktop are claimed by a
Supaste overlay's edge-activation region (automation-only limitation).

**Result (genuine XCUITest, this worktree):**
`SubtaskHoverPinnedUITests` **9/9 PASS**
(`.build/DevinHoverUI-full.xcresult`, ~6.4 min); `AtticTests`
**635/0 fail/1 skip**; `verify_project_generation.rb` current/repeatable.
Bundle: `com.taha.Attic`, Local configuration, ad-hoc signed
(`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`).

## Round 5 — sub-panel repair (Opus 5, local, 2026-09-11 night)

Uncommitted on top of `ae6418c`, in
`/Users/taha/Developer/attic-hover-pinned-subtasks` only. The user reported
that the sub-panel's blank glass, header and padding passed clicks through to
windows underneath while the child rows worked; the pinned header could not be
dragged; hover open/dismiss and family switching felt slow; and the surface was
bigger than wanted.

- **Click-through (hypothesis NOT confirmed — see the ledger's S1
  correction):** an A/B XCUITest run (inert bottom-padding point of the pinned
  window parked over the main panel's quick-entry field) shows no click-through
  either with or without the `hitTest` override, so the reported symptom is
  unreproduced and the override is hardening, not a demonstrated fix. Original
  reading retained below for context. `AtticPanelSurface` paints its
  glass inside an `.allowsHitTesting(false)` background, so
  `NSHostingView.hitTest` answers `nil` over the header, the padding and empty
  list space, and `SubtaskHostingView` had no fallback for those points. That
  is read from source and matches the symptom (rows work, inert regions do
  not). Where the unclaimed press actually ENDS UP — another Attic window,
  another application, or nowhere — was NOT observed at runtime and remains
  unproven; no desktop automation was run this round. Fixed with a
  geometry-aware `SubtaskHostingView.hitTest`: `super.hitTest(point) ?? self`
  inside the drawn squircle, `nil` outside it — the same policy
  `AtticPanelHostingView` already applies on the main panel. Child controls
  keep their hits; the transparent corner wedges stay genuinely click-through.
- **Pinned header drag:** the hard-coded 44 pt strip could not follow
  corner-aware padding and had no notion of the header's own controls. The
  content now measures its header and its control cluster
  (`SubtaskDragGeometryPreferenceKey`) and the hosting view drags only from
  unclaimed header space. Geometry is accepted only from the live pinned
  surface and reset when the pinned family changes.
- **Hit geometry unified:** `containsTransientPoint`, the AppKit hit test and
  the rendered shape all read `settings.panelCornerSize` through
  `SubtaskPanelLayout.surfaceContains`; the fixed radius 18 is gone. Content
  padding moved to `SubtaskPanelLayout.surfaceInsets` so the same corner value
  drives spacing, and a live corner change re-applies to both hosts.
- **Corridor transit (round-5 review fix):** the first version of this repair
  treated the row→surface corridor as arrival — it called
  `noteTransientPointer(inside: true)`, which CANCELS the pending close. A
  pointer that paused in the gap past the grace and then left downward never
  entered the surface, so no hover callback existed to re-arm the close and the
  panel was stranded open; the corridor also spanned the full height of both
  windows, over-suppressing outside-click dismissal. Now
  `SubtaskPanelLayout.pointerCoverage` answers `.surface` / `.transit` /
  `.outside`: only `.surface` cancels, `.transit` DEFERS via
  `rearmPendingClose` within a bounded `corridorTransitBudget` (0.6 s), so
  leaving the corridor in any direction closes the surface on the next
  maturity with no further callback, and parking in it cannot hold the surface
  forever. The corridor is now bounded vertically by the row/surface band plus
  one row of slack instead of both windows' full height. A pending open for
  another family skips the transit path entirely, so a deliberate switch is
  never swallowed.
- **Transit budget reset (round-5 review follow-up):** a genuine surface
  arrival now clears `corridorTransitDeadline`. It previously survived the
  arrival, so a later leave into the corridor inherited the spent deadline and
  the second crossing closed the surface mid-gap.
- **Timings:** `noteRowHover`/`noteTransientPointer` are now idempotent — a
  repeated `onHover(true)` (SwiftUI re-emits it on every row rebuild) no
  longer pushes the dwell deadline into the future, which is what made hover
  feel slow. Discovery keeps the 0.35 s dwell; browsing to another family
  while a surface is open uses `familySwitchDwell` 0.075 s; `closeGrace` drops
  0.45 → 0.14 s. Gap travel stays reliable because `commitPendingClose` now
  cancels when the pointer is actually inside the surface or its corridor at
  maturity, instead of relying on a long timer. Pending family changes,
  menu/edit deferral, drafts and focus handling are untouched.
- **Size:** `panelWidth` 292 → 272, `maximumListHeight` 264 → 240. Height still
  follows content (`clampedListHeight`); nothing forces an aspect ratio.
  Trade-off: at the largest corner setting the corner-aware padding grows to
  ~23.6 pt a side, leaving ~151 pt of title column beside the 66 pt control
  cluster — `testSurfaceInsetsClearTheCurveAndKeepATitleColumn` guards that
  floor at every `PanelCornerSize`.

Checks actually run on this worktree (logs under
`.build/opus5-subpanel-repair/`):

- `xcodebuild build -scheme Attic -destination 'platform=macOS'
  CODE_SIGNING_ALLOWED=NO` — **BUILD SUCCEEDED** (`build-1.log`).
- `xcodebuild test … -only-testing:AtticTests CODE_SIGNING_ALLOWED=NO` —
  **664 tests, 0 failures, 1 skipped** (`unit-tests-4.log`, after the review
  fix; `unit-tests-2.log` recorded 656 before it). Baseline was 635. One obsolete assertion updated:
  `testRowLeaveSchedulesCancellableCloseGrace` hard-coded a 0.2 s "before the
  grace" instant, which is after the new 0.14 s grace; it now expresses its
  times against `SubtaskPanelLayout.closeGrace`.
- `xcodebuild build-for-testing … CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` —
  TEST BUILD SUCCEEDED (`uitest-compile.log`) — **unit target only**.
  `AtticUITests` is not in the `Attic` scheme; UI tests build and run only via
  `Scripts/run_local_ui_tests.zsh` (AtticUI scheme).
- `bundle exec ruby Scripts/verify_project_generation.rb` — project current and
  repeatable (no project inputs changed; edits are to existing files only).

NOT run here, by instruction — Astra owns the desktop and validates after
review: `AtticUITests` (no pointer automation, no preview launch, no installs).
`commitPendingClose` reads `NSEvent.mouseLocation` in production, but the
decision it drives is now a pure classifier plus a controller seam
(`pointerCoverageForTesting`), so transit-defer, gap-exit closure, the transit
budget, arrival-cancels and switch-preservation all have deterministic unit
coverage; only the real cursor's path through the gap remains native
(`testPointerCorridorAndInsideHoverKeepTransientOpen`,
`testExitingTheGapWithoutEnteringSurfaceStillCloses`).

Runtime routing of the unclaimed presses (which window received them before the
fix) is still unproven — the click-through cause is a source-level hypothesis
consistent with the symptom, and the XCUITests that would demonstrate the fixed
behaviour have not been run here.

## Provenance

- Writable checkout: `/Users/taha/Developer/attic-hover-pinned-subtasks`
  (linked worktree of `/Users/taha/Developer/attic-recovery-20260907`;
  do not confuse with the read-only user checkout
  `/Users/taha/Documents/Codex/2026-07-19/d/work/Attic`).
- Branch: `codex/attic-hover-pinned-subtasks`, remote
  `https://github.com/TesterPen0812/Attic.git` (fetch refspec is narrow —
  `git fetch origin codex/attic-hover-pinned-subtasks` lands in FETCH_HEAD,
  there is no `origin/codex/attic-hover-pinned-subtasks` tracking ref).
- Recovered 2026-09-11: local HEAD was `c59e4e5` (clean tree), fetched and
  fast-forwarded to the cloud implementer's push:
  `7535d0028b50c03fcd4532122ec078d5c8c35cb2` "Address adversarial-review
  findings 1-14" (+377/-59, 6 files). No uncommitted work was found or lost.
- Cloud implementer session 54864f9d: wrote 23ede87 → c59e4e5 → 7535d00.
- Cloud reviewer session dbe59721 (read-only): round-1 report found 14
  findings (all addressed by 7535d00); round-2 pass over 7535d00 was cut off
  by quota with NO final verdict. Its unfinished candidate list is carried
  forward below.

## Review round 2 (local pass over 7535d00) — findings

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| F1 | P2 | `releaseFamilyInteractionState` matches `id == familyID` — the parent's own rename (`editingTaskID`) and delete confirmation (`confirmingTaskDeletionID`) are hosted by the MAIN-list row (main list filters `parent(of:) == nil`; the surface renders only child `TaskRowView`s and a display-only title). Surface teardown (`closePinned`, `windowWillClose`, `unpinPinned` without re-anchor, `closeTransientSurface` via Escape/scroll-out/`mainPanelDidHide`) discards a live parent rename or silently dismisses its alert. Release must be child-keyed (`parentID == familyID`) only. | Fix implemented locally |
| F2 | P3 | Dying-host focus race: on pin/unpin the old host's `isEntryFocused → false` `.onChange` can nil `focusedSubtaskParentID` AFTER the controller's `focusSubtaskEntry` re-bump (AppKit field-editor resignation is not synchronous with `orderOut`), leaving the new surface's entry unfocused. Fix: the resign path only clears when the view still hosts the family's live surface (`isLiveSurface(for:mode:)`). | Fix implemented locally |
| F3 | P3 | Replace-pinned refusal while the displaced family is edit-busy (`pinFamily` early return) is a silent no-op — the affordance shows no disabled state or reason. Fix: disabled + dimmed + explanatory help/accessibility hint while `pinReplacementBlocked`. | Fix implemented locally |
| F4 | P3 | `commitPendingOpen`'s anchor-nil/unworthy branch is the only transient teardown that skips `releaseFamilyInteractionState`. Reachable lock-orphan interleavings are unlikely (busy surfaces re-arm), but the asymmetry leaves a residual path. Fix: route through `closeTransientSurface()`. | Fix implemented locally |

Reviewer-remark carried without action: the panel↔surface pointer corridor
counts as "inside" for both dismissal and auto-hide (accepted trade-off,
reviewer downgraded). Discarded suspicion: stale same-family suppression on
unpin — reviewed, likely impossible.

## Verification status

- Project regeneration + `verify_project_generation.rb`: PASS on 7535d00
  (PATH=/opt/homebrew/opt/ruby/bin:… + `bundle exec ruby`).
- `xcodebuild` build + AtticTests: see ledger/checks below once run.
- Manual UX acceptance (hover dwell, corridor, pin drag, VoiceOver, …):
  NATIVE-UAT, left for the user — do NOT take over the desktop.
- Existing preview `com.taha.Attic.devin.subtasks.preview`
  (`.build/DevinPreview`) contains user data — preserve; use separate
  verification artifacts.
