# Batch 2 Review — R2: Canvas Editing Semantics, Focus Chain, and Text Layout

Independent review of the Deep Audit Batch 2 remediation. Reviewer surface:
CVD-06 (Undo/Redo routing through `CanvasEditCommandRoute`), Undo/Redo
enabled-state correctness, CVD-08 (committed text-resize refit), CVX-06
(keyboard/pointer minimum-size parity), and text measurement consistency
between editing, rendering, and persistence.

This is a code review, not an implementation task. No fixes were made.

## 1. Method and inputs

- Snapshot: `/tmp/attic-b2-snapshot-20260915T1845Z` (read-only).
  `MANIFEST.sha256` file hash verified against the expected
  `9af3fc17a070842e7ce8a4975cd66efa7b4ce5a3b297b79bfd5371a5380ca339`, then all
  598 manifest entries verified with `shasum -a 256 -c MANIFEST.sha256`
  (all OK).
- Private reconstruction: `/tmp/attic-b2-review-r2` = `git archive
  ae6418c1af690e29d15a20344cdb9765a23d3f85` + `worktree/` overlay.
  SHA-256 of every reviewed file re-verified against the snapshot worktree
  copies (identical; see §8). Naked HEAD and the live checkout were never
  built or tested.
- Private DerivedData: `/tmp/attic-b2-r2-dd`.
- The snapshot worktree does **not** contain `Attic/App/AtticApp.swift`,
  `Attic/Canvas/CanvasSemanticRenderer.swift`, or
  `Attic/Canvas/CanvasSemanticInteraction.swift` — those files are unchanged
  at HEAD. The actual Batch 2 source delta for my surface is exactly three
  files: `CanvasEditCommandRoute.swift`, `CanvasPanelContent.swift`,
  `CanvasSession.swift` (verified by diffing `baseline/` vs `worktree/`).
- `AGENTS.md` development contract observed: macOS-first, local-only,
  `Local` configuration, private DerivedData, no app launch, no UI
  automation, no CloudKit/APNs/iPhone/Production claims.

## 2. What Batch 2 actually changed (verified delta)

Baseline-vs-worktree diffs on my surface:

- `CanvasEditCommandRoute.swift`: extracted `static var focusedResponder`
  (macOS-only, defaults to `NSApp.keyWindow?.firstResponder`) and replaced
  five inline responder lookups with it (lines 8–12, 18, 31, 39, 48, 61).
  The routing logic itself is **pre-existing**, unchanged.
- `CanvasPanelContent.swift`: added `canUndoCanvasEdit`/`canRedoCanvasEdit`
  (`session.canX || CanvasEditCommandRoute.canX(...)`, lines 28–35); toolbar
  buttons (368–373) and Add ▸ Edit menu items (477–485) now call
  `CanvasEditCommandRoute.undo/redo` and use those predicates. Previously
  they called `session.undo()/redo()` directly with `!session.canX`.
- `CanvasSession.swift`: `transformSemanticObject` gained the text refit
  (1288–1307); `resizeSelectedSemanticObject` floor changed `24` →
  `CanvasImagePlacement.minimumDimension` = 48 (1356–1357). The same file
  also carries the CVD-03/04 retry changes (not my surface).
- Tests: seven new tests plus the `canvasSemanticTextIsFullyVisible` helper.

## 3. CVD-06 — edit routing

### 3.1 Entry-point coverage: complete

Every production Undo/Redo entry point now funnels through
`CanvasEditCommandRoute`:

| Entry point | Location | Path |
|---|---|---|
| Toolbar Undo/Redo | `CanvasPanelContent.swift:368,372` | route |
| Add ▸ Edit ▸ Undo/Redo | `CanvasPanelContent.swift:478,483` | route |
| App-menu Cmd-Z / Cmd-Shift-Z | `AtticApp.swift:58–80` | route (pre-existing) |
| Editor Cmd-Z/⇧Z while editing | `CanvasSemanticInteraction.swift:75–76` | `editor.undoManager` directly — this **is** the route's target, not a bypass |
| Session fallback | `CanvasEditCommandRoute.swift:54,67` | the only `session.undo()/redo()` callers left in production code |

A tree-wide grep for `\.undo()`/`\.redo()`/`undo\b`/`redo\b` confirms no
remaining bypass; `session.undo()/redo()` appear only inside the route and
in test code.

### 3.2 Focused-editor targeting: correct

`route.undo/redo` checks `focusedResponder() as? NSTextView`; the canvas
editor (`CanvasSemanticTextEditor`) is an `NSTextView` subclass, so while it
is first responder the editor's own `undoManager` receives undo/redo.
`AtticPanel`/`PanelSurfaceWindow` both set `canBecomeKey = true`
(`AtticPanel.swift:55`, `PanelSurfaceHostingView.swift:10`), so
`NSApp.keyWindow?.firstResponder` does resolve to the editor in production;
the panel is `.nonactivatingPanel` but still a valid key window.

History separation is clean: the editor's `undoManager` is per-instance and
dies with the editor view on commit/cancel/suspend; the session's stacks are
untouched while editing (typing goes through `preserveSemanticTextDraft`,
never `recordNewCommand`). On external content replacement
`reconcileSemanticTextEditing` clears the editor undo stack
(`CanvasSemanticInteraction.swift:291`), preventing an undo into a stale
baseline. After commit, one `.changeSemantic` command covers the whole edit;
undo restores the pre-edit snapshot verbatim (`CanvasSession.swift:1100–1103`).

`finishTextEditing`'s commit-veto is preserved on every live tool/canvas
switch (`CanvasPanelContent.swift:427,441,521,532,543,556,599`;
`CanvasControls.swift:33`; `CanvasSurfaceMac.swift:669,1115,1295,1304`).

### 3.3 Test quality

`testToolbarAndMenuUndoRedoFollowFocusedTextEditor`
(`CanvasDomainTests.swift:1139–1263`) is a genuine end-to-end check: it hosts
the real `CanvasPanelContent`, clicks rendered toolbar buttons via
`window.sendEvent`, opens the real `NSPopUpButtonCell` menu and performs Edit
▸ Undo/Redo items, and asserts both the editor string **and** untouched
canvas history after each step. Mutant M3 (restoring direct `session.undo()`
in the panel) fails exactly this test — the coverage discriminates.

Pre-existing `testInlineEscapeCancelsDraftWithoutDeletingObjectAndNativeUndoStaysInEditor`
(line 693) covers the keyboard path; the new test adds toolbar + menu.

Gaps: no test exercises the stale enabled-state cases (§4), the app-menu
`CanvasEditCommands` disabled predicate, or Cmd-Z key events routed through
the real `NSApp.keyWindow` (the seam is injected — acknowledged in §6.9 of
the implementation record).

## 4. Undo/Redo enabled-state correctness

`canUndoCanvasEdit` = `session.canUndo || route.canUndo`. With an editor
focused, the route returns `editor.undoManager?.canUndo`, so the composite
is `session.canUndo || editor.canUndo`. Two warts result — both disclosed in
implementation record §6.1, verified here:

### 4.1 Enabled-but-inert controls (introduced by this batch; replaces worse behavior)

**Trigger:** (a) create any canvas history — inserting a text object already
records a command; (b) double-click the text object → the editor takes focus
with an empty undo manager; (c) toolbar Undo and Add ▸ Edit ▸ Undo render
**enabled** (`session.canUndo` term true); (d) click →
`route.undo` → editor branch → `editor.canUndo == false` → returns `false`,
nothing happens. Symmetric for Redo. This is the *common* state at edit
entry whenever any canvas history exists — not an edge case.

Same instant, the app-level Edit menu item (`AtticApp.swift:65`, disabled by
route-only `canUndo`) shows **disabled** — two controls for the same command
disagree simultaneously.

**Severity: low.** Pre-batch, that same click executed `session.undo()` and
popped canvas history mid-edit — it could delete the object being edited.
Batch 2 replaced a destructive misfire with an inert one. Net improvement;
the residual is cosmetic-but-confusing chrome, disclosed by the implementer.
Fix would need `NSUndoManager` observation or an editing-state publisher in
SwiftUI — reasonably deferred.

### 4.2 Stale-disabled while typing (mechanism inherited; consequence newly inaccurate)

**Trigger:** fresh canvas, empty history → begin a text insertion → type.
`editor.canUndo` becomes `true`, but typing writes `semanticTextDrafts`
(`CanvasSession.swift:58`), a plain dictionary — nothing republishes
`CanvasSession`, so `.disabled(!canUndoCanvasEdit)` is never re-evaluated.
Toolbar/menu Undo stay disabled until the next unrelated publish (commit,
viewport change, another command). Cmd-Z still works via the editor's
`performKeyEquivalent`.

Pre-batch the identical staleness existed (`isDisabled: !session.canUndo`),
but it coincidentally matched the action's applicability — a disabled button
correctly reflected that `session.undo()` had nothing to pop. Now the
disabled state masks a legitimate routed target (the editor's undo manager).
**Severity: low** — the keyboard path is unaffected; the workaround is any
session publish.

### 4.3 No new disabled-forever defect

After commit, `recordNewCommand` → `updateHistoryAvailability` publishes
`canUndo`/`canRedo`, so controls correctly enable once editing ends. No case
was found where controls stay permanently wrong.

## 5. CVD-08 — committed text-resize refit

`transformSemanticObject` (`CanvasSession.swift:1288–1307`):

```swift
if let content = before.content, content.text != nil, transform.width.isFinite, transform.height.isFinite,
   transform.width != before.transform.width || transform.height != before.transform.height {
    let proposedHeight = transform.height
    transform.height = max(proposedHeight, CanvasSemanticRenderer.textSize(content, width: transform.width).height)
    transform.center.y += (transform.height - proposedHeight) / 2
}
guard transform.isValid, before.transform != transform else { return false }
```

Verified:

- **Top edge fixed:** world space is y-down (`CanvasViewport.viewPoint`
  adds `+Δy·scale` to view y; `CanvasNSView.isFlipped = true`; `worldRect`
  uses `center.y − height/2`). Growing height and adding Δ/2 to `center.y`
  holds `minY` — the visual top — fixed.
- **Validation order is right:** refit runs before `isValid` and the
  no-change guard, so a proposed squash refits back to the existing
  transform and is rejected as a no-op — the session test's negative
  control (`CanvasSessionTests.swift:313–318`) proves exactly this
  round-trip.
- **All resize paths funnel through it:** pointer via
  `finishImageInteraction` → `onTransformSemanticObject`
  (`CanvasSurfaceMacHelpers.swift:1081`); keyboard via
  `resizeSelectedSemanticObject`; accessibility resize via the same session
  method. Nudge and z-order changes pass identical w/h and skip the refit.
  `editSemanticObject` independently refits on content change
  (1323–1328). Insertion commits are sized by `textSize`
  (`commitSemanticText`, 1216–1221). `insertText` births fitted boxes
  (`defaultTextSize`, 673). No other production writer of semantic
  transforms exists — `updateSemanticObject`/`restoreBoardContents` callers
  are all inside the session or verbatim restore paths.
- **Persistence:** `store.updateSemanticObject` validates and applies the
  refitted transform to all physical replicas of the UUID — consistent with
  the duplicate-safe mutation contract.
- **Undo/redo fidelity:** `.changeSemantic` restores verbatim snapshots; an
  undo returns the exact pre-resize transform (tests assert this). Faithful,
  and correctly excludes refit (restoring must not re-derive).

Disclosed trade-offs, all verified in code and all acceptable:

- **Drag preview can clip until release** — preview uses the unrefitted
  `previewImageTransform` (`semanticObjectsForDisplay`,
  `CanvasSemanticInteraction.swift:93–101`); renderer clips to the rect.
  Commit applies the refit. Acceptable UX trade-off.
- **Top-handle drags grow downward** — refit anchors the *proposed* top,
  so the corner the user pinned (bottom) moves. Cosmetic, disclosed.
- **Grow-only** — `max(proposedHeight, measured)` never shrinks; widening
  leaves slack. Matches the audit's grow-only guidance.
- **Legacy clipped objects self-heal only on next resize/content change** —
  a pure move skips the refit (w/h unchanged). Nothing *newly* persists
  clipping; acceptable.

## 6. CVX-06 — keyboard/pointer minimum parity

- Keyboard: `resizeSelectedSemanticObject` floors both axes at
  `CanvasImagePlacement.minimumDimension` = 48 (`CanvasSession.swift:1356–1357`). Was 24.
- Pointer: `resizedTransform` floors each axis at 48
  (`CanvasImageTypes.swift:567–568`).
- At the floor, further keyboard shrink is a no-op returning `false` (falls
  through to `super.keyDown` → beep). For text, the refit then grows height
  so 48-wide text stays fully visible (asserted by the new test's CT
  visible-range check).

Remaining divergences between the two resize paths (all pre-existing, none
introduced by the batch):

- **Anchor semantics differ:** keyboard scales both axes around the center;
  pointer anchors the opposite corner (then refit re-anchors the top).
- **Aspect handling differs:** keyboard resize is inherently
  aspect-preserving (uniform factor); semantic pointer drags are free-form
  by default and aspect-preserving only with Shift
  (`CanvasSurfaceMac.swift:823–825`). Shift+drag on a text object produces
  an aspect-preserved proposal the refit then breaks on commit — acceptable.
- **Sub-48 minor axis exists on pointer only:** `aspectPreservingSize`
  floors the non-dominant axis at `minimumDimension / aspectRatio`
  (`CanvasImageTypes.swift:502,506`), so a Shift-drag can legitimately yield
  e.g. 48×24. Keyboard cannot reach sub-48. Pre-existing carve-out; CVX-06's
  parity claim holds for the dominant-axis floor.

## 7. Text measurement consistency

| Concern | Editing (NSLayoutManager) | Persistence/render (Core Text) |
|---|---|---|
| Wrap width | `frame.width − 2×(4·scale)` via `textContainerInset`, `lineFragmentPadding = 0` | `max(24, width − 8)` measure; `rect.width − 8` draw |
| Horizontal inset | 4 pt each side | `minX + 4`, width − 8 |
| Height slack | `ceil(usedHeight + 12·scale)` (insertion auto-grow) | `ceil(size.height) + 12` |
| Font | `CanvasSemanticRenderer.font(content, scale:)` | same function at scale 1 (world units) |
| Minimum | `48·scale` | `max(48, …)` |

Insets and slack are deliberately mirrored — persistence and rendering share
the *same* CT measurement, so the committed box can never clip the committed
rendering. Residual: NSLayoutManager (live editing) and CTFramesetter can
wrap/measure differently by a point or a line on boundary strings, and the
editor's `extraLineFragmentRect` may count a trailing empty line that CT
measures tighter — the editing preview can be ~one line taller than the
committed box. This is a WYSIWYG drift, not a clipping defect: the persisted
object always fits its own rendering. Worth noting, not worth blocking.

## 8. Commands run and results

All in `/tmp/attic-b2-review-r2` (git archive of HEAD `ae6418c` + snapshot
`worktree/` overlay) with `ATTIC_TEST_PRODUCTS=/tmp/attic-b2-r2-dd/Build/Products/Local`.

```
cd /tmp/attic-b2-snapshot-20260915T1845Z && shasum -a 256 -c MANIFEST.sha256
  → 598/598 OK; manifest file hash matches expected value.

xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic \
  -configuration Local -derivedDataPath /tmp/attic-b2-r2-dd \
  -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
  → TEST BUILD SUCCEEDED, no warnings observed in log tail.

zsh xctest-r2/run.zsh <label> <limit> <7 new test ids>
  → all 7 new tests PASS (in two invocations; one selector needed a rerun):
    testRetryFailedImageDecodesRequeuesEveryVisibleFailure     pass
    testRetryFailedImageDecodesRequeuesOffScreenFailure        pass
    testToolbarAndMenuUndoRedoFollowFocusedTextEditor          pass (4.98s)
    testPointerNarrowingTextResizeGrowsHeightToFitCommittedText pass
    testRetryDecodeRequeuesOffScreenFailureAcrossCandidatePruning pass
    testNarrowingTextResizeGrowsHeightSoPersistedTextIsNotClipped pass
    testKeyboardSemanticResizeSharesPointerMinimumDimension    pass

zsh xctest-r2/run.zsh canvas-focused 900 <17 Canvas test classes>
  → 205 tests, 0 failures (15.6s) — matches implementer's focused claim.

zsh xctest-r2/run.zsh full-suite 1800 <all 40 test classes>
  → 820 tests, 4 skipped, 0 failures (37.5s) — matches implementer's
    full-suite claim independently.
```

Test artifacts: host `2287db13…e2d`, test bundle `466f0a9f…aab1`
(SHA-256, logged in `xctest-r2/*.log`).

Reviewed-file SHA-256 (private tree == snapshot worktree, verified):

```
46676081…6d74  Attic/App/CanvasEditCommandRoute.swift
169ead83…336b  Attic/Views/Panel/CanvasPanelContent.swift
c268412d…c81   Attic/Canvas/CanvasSession.swift
2777a07d…62b   AtticTests/CanvasDomainTests.swift
f5f8cdd3…0dd   AtticTests/CanvasSessionTests.swift
dac3e3aa…9f79  AtticTests/CanvasRenderCacheTests.swift
78f2820f…98f65 Docs/DeepAudit-Batch2-Implementation.md
```

Unchanged-at-HEAD files inspected: `AtticApp.swift`,
`CanvasSemanticRenderer.swift`, `CanvasSemanticInteraction.swift`,
`CanvasImageTypes.swift`, `CanvasSurfaceMac.swift`,
`CanvasSurfaceMacHelpers.swift`, `CanvasSemanticObject.swift`,
`CanvasViewport.swift`, `CanvasControls.swift`, `PanelSection.swift`,
`CanvasStoreSemanticObjects.swift`, `AtticPanel.swift`,
`PanelSurfaceHostingView.swift`.

Mutant evidence reviewed (snapshot `mutants/summary*.txt`): M3
(panel-direct-session) fails only the routed test; M4 (no refit) fails both
narrowing tests plus the text-leg of the floor test; M5 (floor 24) fails the
floor test. Coverage discriminates.

## 9. Findings

### CONFIRMED DEFECTS

None blocking. The two below are real but low-severity, and both are
accurately disclosed in implementation record §6.1:

- **R2-D1 (low): toolbar/menu Undo/Redo can be enabled but inert.**
  `CanvasPanelContent.swift:28–35` + `CanvasEditCommandRoute.swift:48–51,61–64`.
  Editor focused + empty editor undo + non-empty canvas history → enabled
  control, silent no-op. Also produces simultaneous chrome divergence: the
  app-level Edit item (`AtticApp.swift:65`) shows disabled in the same state.
  Trigger sequence in §4.1. Strictly better than the pre-fix destructive
  misfire it replaced. Suggested fix (not applied): observe editor undo
  state or commit-on-invoke; requires `NSUndoManager`→SwiftUI plumbing.
- **R2-D2 (low): Undo stays disabled while typing with empty canvas
  history.** Same locations; `semanticTextDrafts` (plain dict) never
  republishes, so `.disabled` captures a stale value. Mechanism inherited;
  consequence newly inaccurate since the routed target would now work.
  Cmd-Z unaffected. Trigger sequence in §4.2.

### SUSPICIONS (unverified, non-blocking)

- **Foreign `NSTextView` hijack.** The route casts `focusedResponder()` to
  `NSTextView` while `finishTextEditing` checks the narrower
  `CanvasSemanticTextEditor`. If the app's key window ever hosts another
  text view while the canvas section is displayed (e.g., a Settings text
  field while the Settings window is key), `canUndo/undo` read that
  field-editor's undo manager; enabled state could transiently reflect a
  foreign editor. No such view exists in the canvas section today and the
  action path re-keys the panel on click, so impact is at most cosmetic
  enabled-state flicker. Consider narrowing the cast for symmetry.
- **NSLayoutManager vs CTFramesetter drift.** Editing preview and committed
  box can differ ~1 line on boundary strings/trailing newlines
  (`extraLineFragmentRect` semantics). Never persists clipping. No test
  pins the two engines together; a comparison test could quantify it.
- **Menu `.disabled` re-evaluation timing.** Whether SwiftUI re-evaluates
  the Add ▸ Edit menu's disabled items on each open was not verifiable
  without launching the app; if it re-evaluates, the stale-disabled wart
  narrows to the toolbar only.

### OPTIONAL IMPROVEMENTS

- `CanvasToolControls` (`CanvasControls.swift:3–19`) calls
  `session.selectTool` without `finishTextEditing` — dead code today
  (never instantiated; the live tool buttons all guard). Delete it or add
  the guard so a future revival doesn't skip the commit/veto.
- Each Option+Arrow keypress records a `.changeSemantic` command — key
  repeat floods undo history. Pre-existing for all keyboard object ops;
  consider coalescing consecutive keyboard resizes.
- `Rename Canvas`/`Delete Canvas` (`CanvasPanelContent.swift:448–460`) open
  alerts without `finishTextEditing`, unlike their guarded neighbors;
  drafts survive, so it's consistency-only. Pre-existing.
- Toolbar "Fit Canvas" and menu "Fit Content"/"Reset View" don't commit
  editing while keyboard Cmd-9/0 does (`CanvasSurfaceMac.swift:1115`).
  Harmless — the editor re-anchors on viewport publish — but divergent.
  Pre-existing.
- The `session.canUndo ||` term's comment ("Typing does not republish…")
  oversimplifies: the term does not help typing-driven staleness; it only
  converts "disabled-while-history-exists" into "enabled-but-inert".
  Consider documenting the real trade-off.

## 10. Limits

- No app launch, no native UI automation, no physical input — per
  constraints. The production `focusedResponder` path (`NSApp.keyWindow`)
  is reasoned from code (`canBecomeKey = true` verified on both panel
  classes) plus the injected-seam test; real key-panel responder behavior
  remains a UAT item.
- `before-fix-final.log` and mutant logs are the implementer's evidence; I
  re-verified the failure signatures in `before-errors.txt` match the
  claimed defects and independently reproduced passes on the fixed tree,
  but did not re-run mutants myself (build+7 tests ≈ my remaining budget;
  mutant *results* were inspected, not re-executed).
- CloudKit, APNs, iPhone, TestFlight, Production: not in scope, not claimed.
- Elapsed: ~45 minutes wall-clock (manifest verification through full-suite
  completion; snapshot created 18:45Z, review test runs finished 19:33Z).

## 11. Verdict

**REVIEW_PASS**

CVD-06's routing is complete and correctly targets the focused text editor
with a clean history separation; every production entry point goes through
`CanvasEditCommandRoute`. CVD-08's refit is correct (top-edge anchored,
validated after refit, applied to all replicas, faithful under undo/redo)
and covers every transform-mutation path. CVX-06 achieves the 48-pt floor
parity for the dominant axis. The two enabled-state warts are low-severity,
accurately disclosed, and the introduced one strictly improves on the
destructive behavior it replaced. Tests are discriminating (mutant-verified)
and independently reproduced: 7/7 new, 205/205 focused canvas, 820/820
full suite (4 skipped). Findings R2-D1/R2-D2 are worth a follow-up ticket
but do not block.
