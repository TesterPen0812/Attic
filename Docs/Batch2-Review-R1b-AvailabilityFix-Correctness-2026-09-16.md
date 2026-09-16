# Batch 2 Follow-up Review R1b — Editing-Availability Fix Correctness

Independent correctness/regression review of the availability-fix delta
implemented in
`Docs/Batch2-Editing-Availability-Fix-Implementation-2026-09-16.md`, which
targets exactly the two R2 §4 defects (R2-D1 enabled-but-inert, R2-D2
stale-disabled while typing). Reviewer stance: verify, don't trust.

**Verdict: REVIEW_PASS.**

## 1. Method

- Frozen snapshot `/tmp/attic-b2fix-snapshot-20260916T023926Z` (read-only):
  `MANIFEST.sha256` file hash verified —
  `c9ed8fa8ff0843859d9f95d22309b218c8d75bcaba79d344407b8d3b3d5a1924` matches the
  expected value — and **all 391 manifest entries verified `OK`** via
  `shasum -a 256 -c`.
- Private review tree `/tmp/attic-r1b-review`: `git archive
  ae6418c1af690e29d15a20344cdb9765a23d3f85` of the live checkout + `cp -a`
  overlay of the snapshot `worktree/` (342 files). Every overlaid file was
  re-hashed against the manifest: **342/342 OK**.
- Build: `xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic
  -configuration Local -derivedDataPath /tmp/attic-r1b-dd
  -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO`.
- Tests: offline XCTest host runner (`run.zsh` + `makeconfig`, carried over
  from the prior Batch 2 snapshot `xctest/` directory — the new snapshot's
  `xctest/` holds logs only), `ATTIC_TEST_PRODUCTS=/tmp/attic-r1b-dd/
  Build/Products/Local`, injecting `AtticTests.xctest` into
  `AtticUnitTestHost.app`. Logs in `/tmp/attic-r1b-xctest/`.
- Live checkout used read-only (hashes, `git diff --check`, `git status`);
  the only write to it is this report. No commits, no resets, no app launch.

## 2. Verified delta (snapshot-vs-snapshot discipline)

`diff -rq` between `/tmp/attic-b2-snapshot-20260915T1845Z/worktree` and the new
snapshot `worktree/` shows **exactly three changed files** plus **new Docs
only** (the implementation report, the orchestrator ledger, and the R1–R5
review files — all additive, no existing file touched):

| Changed file | Content of change |
|---|---|
| `Attic/Canvas/CanvasSession.swift` | +`@Published private(set) var editingAvailabilityToken: UInt64 = 0` (outside `#if os(macOS)`); `preserveSemanticTextDraft` rewritten to bump `editingAvailabilityToken &+= 1` unconditionally |
| `Attic/Views/Panel/CanvasPanelContent.swift` | `canUndoCanvasEdit`/`canRedoCanvasEdit` are now route-only (`CanvasEditCommandRoute.canX(session:section:)`), each reading `session.editingAvailabilityToken` as the reactivity dependency; comment updated |
| `AtticTests/CanvasDomainTests.swift` | +342/−38: 4 new tests, the combined toolbar/menu test renamed to `testToolbarUndoRedoFollowFocusedTextEditor` and slimmed to toolbar coverage, `performEditMenuItem` extracted into a private `HostedCanvasChrome` helper with a `perform:` flag |

The two production diffs are byte-equivalent to `patches/fix-only.patch` in the
snapshot. The test diff matches `patches/tests.patch`.

### Owned-file hashes (measured, matching the report's table)

| File | Before | After | Changed |
|---|---|---|---|
| `Attic/Views/Panel/CanvasPanelContent.swift` | `169ead83…336b` | `84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8` | yes |
| `Attic/Canvas/CanvasSession.swift` | `c268412d…c81` | `e9393be9fa8b3a1fed8ed6b814b9ccbf91d99bdbdc40d68f436b920788c542d3` | yes |
| `Attic/App/CanvasEditCommandRoute.swift` | `46676081…5b2bf` | `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf` | **no** |
| `AtticTests/CanvasDomainTests.swift` | `2777a07d…62b` | `262b7668fdc0fe87d41dc011f0fac489624497cdbd5fbafd1da76773ddf8ca96` | yes |
| `AtticTests/CanvasSessionTests.swift` | `f5f8cdd3…0dd` | `f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd` | **no** |

The live checkout's files hash to the same after-values, so the reviewed delta
is what is actually in the tree.

## 3. Mechanism correctness

**Route semantics** (`CanvasEditCommandRoute.swift`, hash-unchanged):
`canUndo`/`canRedo` return `editor.undoManager?.canX` when the focused
responder is an `NSTextView`, else `session.canX`. `undo`/`redo` take the same
branch and return `false` without acting when the editor stack is empty.
Making the panel predicates route-only therefore eliminates D1 structurally:
the rendered enabled state and the click action now evaluate the same
function, so a control cannot render enabled while its own action refuses.

**Consistency claim verified:** the app Edit menu (`AtticApp.swift:59–77`)
uses `CanvasEditCommandRoute.canX` directly for `.disabled`; the panel now
computes the identical expression, so both chrome surfaces derive availability
from one predicate.

**SwiftUI dependency:** `session` is `@ObservedObject` in `CanvasPanelContent`
and the predicates are evaluated inside `body` (toolbar `isDisabled:` at
lines 373/377; Add ▸ Edit `.disabled` at 486/491). Reading the token inside
the computed property registers the dependency.

**Unconditional bump:** `preserveSemanticTextDraft` stores the draft (or nil)
then bumps. The nil-store case — editor undo back to baseline — still changes
`editor.canUndo`/`canRedo`, so an unconditional bump is the correct choice; a
conditional one would reintroduce staleness exactly there.

**Caller enumeration** — every editor undo-availability change reaches the
bump except the two acknowledged residuals:

- Typing / editor undo / editor redo → `NSTextView` posts
  `textDidChange` for all three → `editor.onDraft`
  (`CanvasSemanticInteraction.swift:173`) → `preserveCurrentSemanticDraft`
  (:267) → `onPreserveSemanticDraft` → `session.preserveSemanticTextDraft`
  via `CanvasSurfaceMac.swift:128`. **Empirically proven for editor undo**:
  `testAddMenuRedoRoutesToFocusedTextEditor` calls
  `editor.undoManager?.undo()` then requires the rendered menu Redo to be
  enabled at first open — impossible without a publish on that path. It
  passed.
- `finishSemanticTextEditing(commit:)` → `preserveCurrentSemanticDraft`
  (:202) plus explicit `onPreserveSemanticDraft(key, nil)` (:205), and
  `commitSemanticText` bumps again on its draft-write branches
  (session :1219/:1233/:1242/:1251). Editor removal then drops the route to
  the session term, which publishes its own history state.
- `suspendSemanticTextEditing` (:257) and the reconcile-conflict branch
  (:281) both call `preserveCurrentSemanticDraft` → bump.
- **Uncovered:** `reconcileSemanticTextEditing` clears the editor undo stack
  via `editor.undoManager?.removeAllActions()` (:291) with no bump after.
  However it is only ever invoked inside a `semanticObjects` `@Published`
  publish (`CanvasSurfaceMac.swift:457`, guarded by
  `self.semanticObjects != semanticObjects`) or during editor setup, so a
  publish always coincides; the residual is ordering, not absence
  (§ Findings).
- Focus gain without a publish (`§7.2` of the implementation report): the
  insertion path `makeTextInsertion`→`beginSemanticTextEditing` publishes
  nothing at focus time, so chrome can hold its last-rendered state until the
  first keystroke. Never worse than the pre-fix state in the same window
  (§ Findings).

**Regression surface:**

- `finishTextEditing` commit-veto: untouched (route file hash-identical;
  all 8 call sites unchanged).
- Session fallback for the no-editor case: unchanged (route file identical).
- No canvas-history publish from typing: `semanticTextDrafts` remains a plain
  `private var` dictionary (`CanvasSession.swift:64`); the only new publish
  is the token.
- Publish volume: bounded — one `@Published` write per
  `preserveSemanticTextDraft` call, i.e. per `textDidChange` while editing.
  No feedback loop exists (re-render does not mutate editor text).
- Platform guards: token sits **outside** `#if os(macOS)` (line 59 vs. the
  macOS block at 60), so the cross-platform panel compiles; on iOS the route's
  editor branch is compiled out and the token is simply never load-bearing.
- Batch 1 + Batch 2 recovery surfaces: hash-identical to the prior snapshot —
  `CanvasSurfaceRenderer.swift` `48c81ecf…408b19`,
  `CanvasImageTypes.swift` `40d1ff26…0ce954`,
  `CanvasSurfaceMac.swift` `67477ef5…040a6e` (measured).

## 4. Independent test execution

All runs on my private tree/products; logs in `/tmp/attic-r1b-xctest/`.

| Gate | Expected | Measured |
|---|---|---|
| `build-for-testing` | success | `** TEST BUILD SUCCEEDED **`, exit 0 |
| 11 tests (4 new + 7 prior) | 11/0 fail | `Executed 11 tests, with 0 failures`, exit 0 (`r1b-11tests.log`) |
| 17 Canvas classes | 209/0 fail | `Executed 209 tests, with 0 failures`, exit 0 (`r1b-canvas17.log`) |
| Full Local unit suite (42 classes) | 824 exec, 820 pass, 4 skip, 0 fail | `Executed 824 tests, with 4 tests skipped and 0 failures`, exit 0 (`r1b-full.log`) |
| `git diff --check` (5 owned files, live checkout) | clean | exit 0 |
| Warnings in owned files | none | none; only the disclosed pre-existing ones elsewhere (`TaskStoreTests:257`, `PanelGeometryTests:291`, `appintentsmetadataprocessor` note) |

The 11-test list was taken from the implementer's run
(`xctest/after-new-and-prior.log` header) verbatim.

## 5. Mutant probes (independent)

Applied to my private tree only; rebuilt and ran against the same DerivedData;
tree restored afterward and re-verified by hash + a passing re-run of the five
hosted-chrome tests (`r1b-restored.log`, 5 tests, 0 failures, exit 0).

- **Mutant A** — restore the composite `session.canX || route.canX` predicates
  (no token read). Ran `testFocusedEmptyTextEditorDisablesToolbarAndMenuUndoRedo`:
  **failed as required**, `exit_status=1`, 2 failures —
  `XCTAssertEqual ("Optional(true)") vs ("Optional(false)")` for both Undo and
  Redo rendered-enabled reads (`r1b-mutA.log`). The D1 test discriminates the
  exact defect predicate.
- **Mutant B** — delete `editingAvailabilityToken &+= 1` (token declared,
  never bumped). Ran `testTypingInFocusedTextEditorEnablesToolbarUndoWithEmptyCanvasHistory`:
  **failed as required**, `exit_status=1`, 2 failures — `("abc") vs ("")` on
  the toolbar-Undo click and `("xyabc") vs ("xy")` downstream
  (`r1b-mutB.log`). The D2 test discriminates the missing publish.

## 6. Findings

**CONFIRMED DEFECTS:** none.

**SUSPICIONS (low, both already disclosed in the implementation record):**

1. *Reconcile `removeAllActions` ordering* (`CanvasSemanticInteraction.swift:291`).
   The clear rides on a coinciding `semanticObjects` publish; AppKit mutation
   runs synchronously in the surface sink while SwiftUI's re-render defers to
   the next cycle, so in practice the chrome settles correct on that same
   publish — but the ordering is not contractually guaranteed. Worst case is
   a one-cycle stale enabled flag on an external-replacement path that is
   currently only reachable through local mutations (sync is deferred). Not a
   blocker; if it ever matters, one line (`preserveSemanticTextDraft(key, …)`
   or a direct bump) after the clear closes it.
2. *Focus-gain without publish.* Verified the insertion path
   (`makeTextInsertion` → `beginSemanticTextEditing`) publishes nothing at the
   moment the editor takes focus, so the toolbar can keep its last-rendered
   enabled state until the first keystroke bumps. In that window the panel is
   no worse than the pre-fix composite (which also rendered enabled-but-inert),
   and it self-corrects on the first `textDidChange`. App-menu parity actually
   improves the story: both surfaces now share predicate *and* staleness
   mechanism.

**OPTIONAL:**

- The `let _ = session.editingAvailabilityToken` read is strictly redundant
  under Combine (`objectWillChange` re-renders `@ObservedObject` consumers on
  any `@Published` write), but it is harmless, self-documenting, and becomes
  load-bearing if the session ever migrates to `@Observable`, where per-key
  reads are the dependency. Keep it.
- New cost: one session-wide `objectWillChange` publish per `textDidChange`
  while editing (was: zero republish). Bounded, same class as selection/
  viewport publishes, and required for the fix's reactivity; no cheaper
  equivalent exists without dedicated availability plumbing.
- Harness constraint (not product): the offline host freezes popup enabled
  flags at first open; the test split into one-menu-open-per-test is a sound
  adaptation and coverage is net-positive (menu Undo routing, menu Redo
  routing, and rendered-disabled state with a focused empty editor are all
  still exercised, plus the new D1/D2 discriminators).

## 7. Limits

- macOS Local configuration only; iOS compile paths reviewed statically, not
  built (token is outside the guard and unused there).
- The app was built and unit-tested in the offline host; **never launched**.
  Nothing here is evidence about CloudKit, APNs, iPhone, TestFlight, or
  Production behavior.
- Real AppKit menu validation timing in a live panel (as opposed to the
  offline host's frozen-at-first-open flags) is asserted by code reading, not
  observed — the acknowledged harness limit.

## 8. Verdict

**REVIEW_PASS.** The delta is exactly the two production hunks plus owned test
changes; the mechanism is correct (route-only parity with the app Edit menu,
unconditional bump covering every draft-save caller including
undo-to-baseline); both new tests demonstrably discriminate their defects via
mutant probes; full-suite regression is clean at 824/4-skipped/0-failed; and
the two residual gaps are disclosed, bounded, and never worse than the
pre-fix behavior they replace.
