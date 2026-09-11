# Hover + pinned subtasks: local continuation checkpoint

Durable handoff between the interrupted cloud sessions and the local
implementer/reviewer pair. Update this file whenever the checkpoint moves.

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
