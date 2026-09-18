# Batch 2 Follow-up Review — R2b: Editing-Availability Fix, Editing/Focus Semantics

Independent review of `Docs/Batch2-Editing-Availability-Fix-Implementation-2026-09-16.md`,
the follow-up targeting R2-D1 (enabled-but-inert) and R2-D2 (stale-disabled while
typing) from `Docs/Batch2-Review-R2-Editing-Semantics.md` §4. Reviewer surface:
editing/focus semantics only — predicate correctness, re-render triggers, route
coherence, undo-stack separation, test adequacy. This is a code review, not an
implementation task. No production files were modified.

## 1. Method and inputs

- Snapshot: `/tmp/attic-b2fix-snapshot-20260916T023926Z` (read-only, never
  modified). `MANIFEST.sha256` file hash verified against the expected
  `c9ed8fa8ff0843859d9f95d22309b218c8d75bcaba79d344407b8d3b3d5a1924`, then all
  **391** manifest entries verified with `shasum -a 256 -c` (all OK).
- Private reconstruction: `/tmp/r2b-review/tree` = `git archive
  ae6418c1af690e29d15a20344cdb9765a23d3f85` + `worktree/` overlay (`cp -a`).
  All **342** overlay files re-hashed against the snapshot — zero mismatches.
- Live checkout was read-only for me except this report. Owned-file hashes in
  the live checkout match the snapshot `owned-hashes-after.txt` exactly;
  `CanvasEditCommandRoute.swift` is bit-identical to its baseline
  (`46676081…6d74`), `CanvasSessionTests.swift` likewise (`f5f8cdd3…0dd`).
- Private DerivedData: `/tmp/r2b-review/dd` (fixed tree),
  `/tmp/r2b-review/before-dd` (before-tree = final tests + baseline production
  files, restored from snapshot `baseline/owned/` and re-hashed: `169ead83`,
  `c268412d`, `46676081` — all confirmed).
- Runner: the snapshot's `xctest/` directory ships logs only; I reused the
  offline host-injection runner (`run.zsh` + `makeconfig`) from the
  implementer's run dir, copied into `/tmp/r2b-review/xctest/`, against my own
  products. Local configuration, `CODE_SIGNING_ALLOWED=NO`, in-memory stores,
  no app launch, no UI automation beyond the tests' own synthesized events.
- `AGENTS.md` contract observed: macOS-first, local-only, no
  CloudKit/APNs/iPhone/Production claims.

## 2. Delta verification

`baseline/owned` vs reconstructed worktree diffs on the owned set:

- `CanvasPanelContent.swift`: exactly the two hunks in `patches/fix-only.patch`
  — `canUndoCanvasEdit`/`canRedoCanvasEdit` are now route-only
  (`CanvasEditCommandRoute.canX(session:section:)`), each preceded by
  `let _ = session.editingAvailabilityToken` as the reactivity dependency, with
  an explanatory comment. No call-site changes.
- `CanvasSession.swift`: exactly two hunks — new
  `@Published private(set) var editingAvailabilityToken: UInt64 = 0` (line 59,
  outside `#if os(macOS)`, so the cross-platform panel compiles), and
  `preserveSemanticTextDraft` now ends with `editingAvailabilityToken &+= 1`
  (line 1206).
- `CanvasDomainTests.swift`: the `tests.patch` delta — renamed toolbar test,
  two dedicated Add ▸ Edit tests, two defect tests, and the extracted
  `HostedCanvasChrome` helper.
- `CanvasEditCommandRoute.swift`, `CanvasSessionTests.swift`: **unchanged**
  (diff clean, hash-identical to baseline).

No other production edits exist. The delta is exactly what the report claims.

## 3. Per-defect resolution

### R2-D1 — enabled-but-inert (§4.1): RESOLVED for the defined trigger

Trigger walk: canvas history non-empty + focused editor with empty undo
manager.

- Route truth: `CanvasEditCommandRoute.canUndo` casts `focusedResponder()` to
  `NSTextView`; `CanvasSemanticTextEditor` is an `NSTextView`, so the route
  returns `editor.undoManager?.canUndo ?? false` → `false`. Predicates are now
  route-only → `canUndoCanvasEdit == false` → toolbar button and Add ▸ Edit ▸
  Undo render **disabled**, matching the app Edit menu (`AtticApp.swift:65`,
  already route-only). The composite `session.canX ||` term that caused the
  disagreement is gone.
- Re-render trigger: the double-click path calls `onSelectSemanticObject` →
  `session.selectSemanticObject` → assigns `selectedSemanticObjectID`
  (`CanvasSession.swift:1270`). `@Published` fires `objectWillChange` on every
  assignment — including same-value — so the publish lands even when the
  object was already selected, and the scheduled render evaluates **after**
  `beginSemanticTextEditing` has made the editor first responder. Post-focus
  render → route reads the empty editor → disabled. The D1 test mirrors this
  order and asserts the rendered menu items read `false`.
- Misfire: impossible by construction — `route.undo` returns `false` exactly
  when the rendered predicate is `false`, and the disabled button suppresses
  delivery anyway. The test clicks the (formerly located) toolbar points and
  asserts editor text, first responder, and both history stacks are untouched.

### R2-D2 — stale-disabled while typing (§4.2): RESOLVED

Trigger walk: empty canvas history + focused editor + first keystroke.

- `CanvasSemanticTextEditor.textDidChange` → `onDraft` →
  `preserveCurrentSemanticDraft()` → `onPreserveSemanticDraft` →
  `session.preserveSemanticTextDraft` → `editingAvailabilityToken &+= 1` →
  `objectWillChange` → panel re-render → `route.canUndo` →
  `editor.undoManager.canUndo == true` → rendered **enabled**. Toolbar Undo
  then routes to the editor's undo manager — verified end-to-end by the D2
  test's rendered-button click (`editor.string` returns to `""`).
- The bump is unconditional precisely because editor undo back to baseline
  stores `nil` (`preserveCurrentSemanticDraft` maps equal strings to nil) yet
  still changes `canUndo`/`canRedo` — a conditional bump on "draft changed"
  would miss exactly that transition. Correct design detail.
- Editor Cmd-Z / Cmd-Shift-Z (`performKeyEquivalent`,
  `CanvasSemanticInteraction.swift:75–76`) runs `undoManager.undo()/redo()`,
  which mutates text storage → `textDidChange` → same bump → chrome tracks the
  editor's stacks live in both directions. Cmd-Z equivalence holds and is
  asserted (`editor.performKeyEquivalent` in the D2 test).
- Side benefit, previously unnoted: the app Edit menu (`CanvasEditCommands`)
  was *equally* stale-disabled while typing pre-fix — same missing publish.
  The token fixes that surface too, since it observes the same `session`.

### Bump-site coverage audit (my own sweep)

Every site where the focused editor's undo availability can change:

| Site | Mechanism | Republished? |
|---|---|---|
| Typing / paste / cut | `textDidChange` → `onDraft` → `preserveCurrentSemanticDraft` | yes (token) |
| Editor undo/redo (any entry: Cmd-Z, route, `undoManager` direct) | text-storage mutation → `textDidChange` → `onDraft` | yes (token) |
| `finishSemanticTextEditing` (commit & cancel) | `preserveCurrentSemanticDraft` (commit path) + `onPreserveSemanticDraft(key, nil)` (always) | yes (token ×2) + history publish on successful commit |
| `suspendSemanticTextEditing` (board switch, object deletion) | `preserveCurrentSemanticDraft` | yes (token) + canvas/selection publish |
| `reconcileSemanticTextEditing` external replace → `removeAllActions` | `editor.string = text` fires `textDidChange` → `onDraft` → bump **before** the clear; the scheduled render resolves after it | yes — settles correct next pass (see §6.1) |
| Editor creation / focus gain | no draft write | **not always** — see finding F1 |

No `undoManager` mutation site lacks a nearby publish except focus gain, which
is a *render-trigger* gap rather than a bump gap.

## 4. Coherence

Toolbar Undo/Redo, Add ▸ Edit ▸ Undo/Redo, and the app Edit menu now share one
predicate semantics — route-only — and one publisher (`session.objectWillChange`,
which `editingAvailabilityToken` drives). Formula-level disagreement (the D1
symptom: panel enabled while the app menu disabled) is structurally
eliminated: given identical responder state at evaluation time, all three
compute identically, and every publish re-evaluates all of them. The only
remaining divergence channel is render staleness, which affects all surfaces
equally and self-corrects on the next publish.

Enabled-but-inert cannot recur through the predicate: `route.undo` refuses
exactly the states `route.canUndo` reports false. Permanently-wrong state
cannot occur either: every user-reachable availability change either publishes
(draft callbacks, history updates, selection) or is bounded by the next
publish (F1).

One benign note: the `let _ = session.editingAvailabilityToken` read is not
strictly load-bearing today — `@ObservedObject` re-renders on any
`objectWillChange` regardless of which property was read. It documents intent
and is the correct idiom if the model later moves to per-key-path
`@Observable` tracking. Harmless, arguably good hygiene.

## 5. Semantics preservation

- **Editor/session undo separation:** unchanged. `preserveSemanticTextDraft`
  writes only the draft dictionary plus the token — it never calls
  `recordNewCommand`, so typing still records no canvas commands. The route's
  editor-branch/session-fallback logic is untouched (file hash identical).
- **Commit-veto:** `CanvasEditCommandRoute.finishTextEditing` unchanged; every
  guarded call site verified intact in the current file (canvas switch
  `CanvasPanelContent.swift:433`, New Canvas `:447`, tool dock `:527/:538`,
  text tool `:562`, shape menu `:605`; `CanvasSurfaceMac.swift:669,1295,1304`;
  `CanvasControls.swift:33`). The fix touched only the two predicates.
- **Commit republish:** `commitSemanticText` → `insertSemanticObject` /
  `editSemanticObject` → `recordNewCommand` → `updateHistoryAvailability`
  publishes `canUndo`/`canRedo`; editor teardown adds two more token bumps.
  Post-commit renders evaluate with no focused editor → session history →
  controls enable correctly.
- **No regression direction found:** the new predicate renders disabled only
  where the route would refuse; it can never disable a command that would
  have worked (the old `session.canX ||` term could only ever widen enabled
  states into inert ones).

## 6. Residual-risk assessment

### 6.1 Disclosed risk #1 (reconcile stack-clear lag): accurate, possibly over-pessimistic

`reconcileSemanticTextEditing` (`CanvasSemanticInteraction.swift:289–291`)
sets `editor.string = text` *before* `undoManager.removeAllActions()`.
Programmatic `string` assignment posts `textDidChange` → `onDraft` →
`preserveCurrentSemanticDraft` → token bump → a publish is scheduled that
resolves **after** the clear runs. Combined with the `semanticObjects` publish
that triggered `configure`, the chrome settles correct on the immediately
following render — "lag one cycle" is accurate, and the failure mode is
bounded stale-enabled (inert click), never a wrong action. Low severity,
correctly disclosed.

### 6.2 Disclosed risk #2 (focus without publish): real, but the enumeration is incomplete — F1

**F1 (low): two focus-gain paths carry no post-focus publish.** The
implementation claims "a focus gain rides on a publish (double-click →
`selectSemanticObject`; commit → history publish)". Verified:

- Double-click on existing text — **does** publish (`selectSemanticObject`
  assigns unconditionally; `@Published` fires even on same-value set), and the
  render resolves after focus. ✓
- **Insertion spawn does not publish at all.** Text tool armed → click empty
  canvas → `mouseDown` → `onBeginTextInsertion` → `session.makeTextInsertion`
  (no `@Published` write — reads `pendingPlacement`, returns a draft) →
  `beginSemanticTextEditing(_, insertion:)` → editor first responder, and for
  insertions `reconcileSemanticTextEditing` early-returns on
  `editingSemanticIsInsertion`. No publish lands after focus.
- **`semanticTextEditRequest` publishes pre-focus.** "Edit Text" dock button →
  `requestSelectedSemanticTextEditing` sets the request → the scheduled
  render evaluates `body` (no editor yet → session-derived availability) and
  *then* `updateNSView`→`configure`→`beginSemanticTextEditing` takes focus.
  The render's value predates the focus change.

Consequence on both paths: if canvas history was non-empty at the last render,
chrome (and the app menu — same staleness) can show Undo **enabled** while a
fresh editor with an empty undo manager is focused; a click is inert — the
D1 symptom, on a narrower trigger than R2's. It self-corrects on the first
keystroke (token bump) and can never misfire destructively. A fresh editor
always starts with an empty undo manager, so the stale direction is only
enabled-when-should-be-disabled; a stale-*disabled* editor undo is not
reachable through focus alone. Severity: low — same class as the disclosed
risk, arguably inside it, but the claim that production focus gains ride on
publishes should be narrowed to "selection/commit-driven focus gains". If a
future pass wants it closed, the cheap seams are a token bump in
`beginSemanticTextEditing` or a publish inside `makeTextInsertion` (e.g.
recording the live insertion draft immediately).

### 6.3 Disclosed risks #3–4 (harness freeze, `&+=` wrap): accurate

The menu-freeze claim is evidenced in `xctest/diag.log`:
`DIAG beforeMenu … editorCanUndo=Optional(true) … route=true` while the
rendered item read `Optional(false)` — truth enabled, chrome frozen. That is
frozen items at first open, not the fix refusing; the split is justified by
measurement, not speculation. The `UInt64` wrap is unobservable — the token is
compared for change only (and under whole-object `objectWillChange`, even that
is moot).

### 6.4 Inherited suspicion (R2 §9): unchanged, still non-blocking

The route casts `focusedResponder()` to `NSTextView`, broader than
`finishTextEditing`'s `CanvasSemanticTextEditor` check — a foreign text view
in the key window could transiently drive availability. Unchanged by this
delta, cosmetic-only, no such view exists in the canvas section today. Worth a
follow-up note, not a blocker.

## 7. Test-split adequacy

`testToolbarAndMenuUndoRedoFollowFocusedTextEditor` → split into:

- `testToolbarUndoRedoFollowFocusedTextEditor` — keeps both toolbar directions
  through rendered buttons, with a settle between commands and no reused click
  point (both constraints are real: frozen-at-open menus and dropped
  same-timestamp clicks were measured).
- `testAddMenuUndoRoutesToFocusedTextEditor` /
  `testAddMenuRedoRoutesToFocusedTextEditor` — each owns a hosted panel and
  exactly one menu open, asserting the editor string changed **and** canvas
  history (`session.strokes`, `semanticObjects.count`, `canUndo`/`canRedo`)
  did not.
- `testFocusedEmptyTextEditorDisablesToolbarAndMenuUndoRedo` (D1) — asserts
  route truth is false, *rendered* menu items read `false`
  (`perform: false`), and stray clicks reach neither the editor text nor
  canvas history.
- `testTypingInFocusedTextEditorEnablesToolbarUndoWithEmptyCanvasHistory`
  (D2) — asserts the draft save path received the text, then clicks the
  *rendered* toolbar button (discriminates: a stale-disabled button swallows
  the click, `editor.string` stays `"abc"` — exactly the before-fix failure),
  then re-verifies the Cmd-Z path.

M3-class misrouting (panel calling `session.undo()` directly) is now
discriminated by **three** tests instead of one — each would let the click pop
canvas history and trip `strokes.isEmpty`/`semanticObjects.count` assertions.
The only coverage lost is single-session menu interleaving (Redo then Undo in
one panel), which the measured harness constraint makes impossible; the split
is the right resolution and net coverage is better (adds rendered-disabled
assertions, which did not exist before).

`HostedCanvasChrome` is a faithful extraction of the prior harness
(off-screen borderless window, `orderFrontRegardless`, injected
`focusedResponder` seam, `CATransaction.flush` in settle) with correct
restoration in `tearDown`.

## 8. Commands run and results

All in `/tmp/r2b-review/` (private tree `/tmp/r2b-review/tree`, private
DerivedData, `ATTIC_TEST_PRODUCTS=/tmp/r2b-review/dd/Build/Products/Local`):

```
snapshot verify:
  MANIFEST.sha256 hash  → c9ed8fa8…1924 (matches expected)
  shasum -a 256 -c MANIFEST.sha256 → 391/391 OK
  overlay re-hash → 342/342 identical to snapshot worktree

xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic \
  -configuration Local -derivedDataPath /tmp/r2b-review/dd \
  -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
  → ** TEST BUILD SUCCEEDED **, exit 0
  warnings: only the three pre-existing, out-of-scope ones
    (PanelGeometryTests.swift:291 CGWindowListCreateImage deprecation,
     TaskStoreTests.swift:257 unreachable code, appintentsmetadataprocessor);
    none in owned files. Identical warning set on the before-tree build.

before-tree (baseline production + final tests) build-for-testing
  → ** TEST BUILD SUCCEEDED **, exit 0

run.zsh r2b-before-fix 600 <4 new + renamed toolbar test>
  → Executed 5 tests, with 4 failures, exit_status=1 — identical signature
    to the implementer's before-fix-final.log:
      CanvasDomainTests.swift:1368/1370 Optional(true)≠Optional(false) (D1,
        rendered menu items stayed enabled with focused empty editor)
      CanvasDomainTests.swift:1435 "abc"≠"" / :1445 "xyabc"≠"xy" (D2,
        stale-disabled swallowed the toolbar click)

run.zsh r2b-eleven 900 <4 new + 7 prior Batch 2 tests>
  → Executed 11 tests, with 0 failures, exit_status=0

run.zsh r2b-canvas-focused 1200 <17 Canvas classes>
  → Executed 209 tests, with 0 failures, exit_status=0

run.zsh r2b-full-unit 2400 <all 42 classes>
  → Executed 824 tests, 4 skipped, 0 failures, exit_status=0
```

Test artifacts: host `AtticUnitTestHost` and `AtticTests.xctest` hashes logged
in `/tmp/r2b-review/xctest/*.log`. Logs kept in `/tmp/r2b-review/xctest/` and
`/tmp/r2b-review/*.log`.

## 9. Findings

### CONFIRMED DEFECTS

None blocking.

- **F1 (low):** residual risk #2 is under-enumerated — the insertion-spawn
  path (`makeTextInsertion` → `beginSemanticTextEditing`) publishes nothing,
  and the `semanticTextEditRequest` path publishes before focus lands, so both
  can leave chrome stale-enabled over a fresh empty-undo editor until the
  first keystroke. Inert-only, self-healing, same class as the disclosed risk.
  §6.2.

### VERIFIED CLAIMS

- D1 and D2 are resolved as defined in R2 §4; before-fix failure signatures
  reproduced independently, then pass on the fixed tree.
- Route coherence across toolbar / Add ▸ Edit / app Edit is now structural.
- Semantics preservation: undo separation, commit-veto coverage, post-commit
  re-enable — all intact.
- The test split is measurement-justified and net-positive for coverage.

### LIMITS

- No app launch, no real key-panel responder chain (the `focusedResponder`
  seam is injected in tests, as before). F1's production-visible impact was
  reasoned from code paths, not observed live.
- The claim that `editor.string =` posts `textDidChange` is AppKit behavior I
  rely on for the §6.1 ordering analysis; it is the well-known NSTextView
  delegate behavior and consistent with the passing tests, but not separately
  instrumented.
- `editor.undoManager` availability changes I enumerated exhaustively from
  `CanvasSemanticInteraction.swift` + `CanvasSurfaceMac.swift` call sites;
  any future site that mutates the editor undo stack without a draft write
  reopens a D1-shaped stale window — that is the standing constraint, same as
  before.
- CloudKit, APNs, iPhone, TestFlight, Production: not in scope, not claimed.
- Elapsed: ~35 minutes wall-clock.

## 10. Verdict

**REVIEW_PASS**

The fix resolves R2-D1 and R2-D2 as defined: predicates are route-only, the
`editingAvailabilityToken` publishes every editor-side availability change that
flows through the draft callback (typing, editor undo, editor redo), and the
unconditional bump correctly covers undo-back-to-baseline. Coherence across
toolbar, Add ▸ Edit, and the app Edit menu is now structural rather than
accidental; undo separation and commit-veto are untouched. The test split is
justified by a measured harness constraint and discriminates both defects
(reproduced: 4 failures before, 0 after; 209 focused, 824 full-suite). F1 is a
narrower, inert-only residual of the already-disclosed focus-publish class and
does not block; correcting the risk-#2 enumeration in the implementation
record would make the disclosure exact.
