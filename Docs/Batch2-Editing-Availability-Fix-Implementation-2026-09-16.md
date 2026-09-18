# Batch 2 Follow-up — Canvas Editing-Availability Fix (R2-D1, R2-D2)

Focused follow-up to Deep Audit Batch 2 (Canvas). Scope is exactly the two
availability defects recorded in `Docs/Batch2-Review-R2-Editing-Semantics.md`
§4.1 and §4.2. No other Batch 2 finding, no image retry/recovery surface, no
resize/refit tradeoff, and no app-menu command was touched.

Verdict: **IMPLEMENTATION_READY**.

## 1. Defects, reverified against live source before editing

**R2-D1 — enabled-but-inert.** `CanvasPanelContent.canUndoCanvasEdit` /
`canRedoCanvasEdit` were `session.canX || CanvasEditCommandRoute.canX(...)`
(baseline lines 30–35). With canvas history non-empty and a canvas text editor
focused with an empty undo manager, the session term rendered the toolbar and
the Add ▸ Edit items **enabled** while `CanvasEditCommandRoute.undo/redo` took
the editor branch, found `canUndo == false`, and returned `false`. The
app-level Edit menu (`AtticApp.swift`, route-only) showed **disabled** at the
same instant, so two controls for one command disagreed.

**R2-D2 — stale-disabled while typing.** `semanticTextDrafts`
(`CanvasSession.swift:58`, a plain dictionary) never republished the session.
With empty canvas history, typing grew the editor's undo manager but
`.disabled(!canUndoCanvasEdit)` was never re-evaluated, so toolbar and menu
Undo stayed disabled while Cmd-Z worked.

Both were confirmed in the live checkout before any edit.

## 2. Baseline (private, taken before editing)

`/tmp/attic-b2avail/baseline/` holds pre-edit copies of the owned files,
`git status --porcelain=v1`, the full dirty-tracked diff, and the untracked
list. The working tree was never reset, checked out, restored, committed, or
pushed; only the five owned paths were modified.

SHA-256 before:

| File | SHA-256 |
|---|---|
| `Attic/Views/Panel/CanvasPanelContent.swift` | `169ead83d88d118b6e0515e3f26967e529ff38e13837cd65bb1572802326336b` |
| `Attic/Canvas/CanvasSession.swift` | `c268412d6a25d33c910616823d1eef864b016bd935055443f21e83d688ea0c81` |
| `Attic/App/CanvasEditCommandRoute.swift` | `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf` |
| `AtticTests/CanvasDomainTests.swift` | `2777a07d58571a48de7c587f39bf646e2858f1e8fb5ce1a2fb07971b1d18562b` |
| `AtticTests/CanvasSessionTests.swift` | `f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd` |

SHA-256 after:

| File | SHA-256 | Changed |
|---|---|---|
| `Attic/Views/Panel/CanvasPanelContent.swift` | `84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8` | yes |
| `Attic/Canvas/CanvasSession.swift` | `e9393be9fa8b3a1fed8ed6b814b9ccbf91d99bdbdc40d68f436b920788c542d3` | yes |
| `Attic/App/CanvasEditCommandRoute.swift` | `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf` | **no** |
| `AtticTests/CanvasDomainTests.swift` | `262b7668fdc0fe87d41dc011f0fac489624497cdbd5fbafd1da76773ddf8ca96` | yes (tests) |
| `AtticTests/CanvasSessionTests.swift` | `f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd` | **no** |

## 3. Exact production delta (two files, two hunks each)

`Attic/Canvas/CanvasSession.swift`

- New published trigger next to the other session publishers, outside the
  `#if os(macOS)` block so the cross-platform panel can read it:

  ```swift
  @Published private(set) var editingAvailabilityToken: UInt64 = 0
  ```

- `preserveSemanticTextDraft` bumps it, unconditionally:

  ```swift
  func preserveSemanticTextDraft(_ key: CanvasReplicaKey, draft: CanvasSemanticTextDraft?) {
      semanticTextDrafts[key] = draft
      editingAvailabilityToken &+= 1
  }
  ```

  This single seam covers every way a focused editor's undo availability
  changes: `CanvasSemanticTextEditor.textDidChange` → `onDraft` →
  `preserveCurrentSemanticDraft` → `onPreserveSemanticDraft` → this method.
  NSTextView posts that notification for typing **and** for its own undo and
  redo, so typing, editor undo, and editor redo all republish. Nothing here
  reads or writes canvas history, and neither undo stack is touched.

`Attic/Views/Panel/CanvasPanelContent.swift`

- The predicates became route-only, with the token read as the reactivity
  dependency:

  ```swift
  private var canUndoCanvasEdit: Bool {
      let _ = session.editingAvailabilityToken
      return CanvasEditCommandRoute.canUndo(session: session, section: .canvas)
  }
  ```

  (same shape for `canRedoCanvasEdit`). Call sites were not changed.

`Attic/App/CanvasEditCommandRoute.swift` was read and needed no change; its
`canUndo`/`canRedo` already return editor-scoped availability when an editor is
focused and session availability otherwise. Its file hash is unchanged.

Preserved: editor/session undo separation (the route still falls back to the
session only when no editor is focused), `finishTextEditing`'s commit-veto on
every live tool/canvas/menu switch, and all Batch 1 + Batch 2 fixes.

## 4. Tests

Added to the existing `AtticTests/CanvasDomainTests.swift` only, so no project
input changed and project regeneration stayed unnecessary.
`AtticTests/CanvasSessionTests.swift` was not modified.

New tests, all in `CanvasAccessibilityTests`, all using the real
`CanvasPanelContent` hosted off-screen (the harness pattern of the Batch 2
toolbar test, extracted into a private `HostedCanvasChrome` helper):

1. `testFocusedEmptyTextEditorDisablesToolbarAndMenuUndoRedo` (**D1**) — canvas
   history holds an undo and a redo; the editor is focused with an empty undo
   manager; the route reports false, the rendered Add ▸ Edit Undo and Redo
   items must read disabled, and clicking the toolbar buttons must leave the
   editor text and canvas history untouched.
2. `testTypingInFocusedTextEditorEnablesToolbarUndoWithEmptyCanvasHistory`
   (**D2**) — empty canvas history (fresh board), insertion editor focused,
   nothing undoable; typing reaches the draft save path; the **rendered**
   toolbar Undo must then be live, its click reverts the typing through the
   editor, canvas history stays empty, and Cmd-Z still works afterwards.
3. `testAddMenuUndoRoutesToFocusedTextEditor` and
   `testAddMenuRedoRoutesToFocusedTextEditor` — the Add ▸ Edit routing halves
   split out of the Batch 2 test (see §6).

### Failing before, passing after

Before-fix run used a private copy of the live tree
(`/tmp/attic-b2avail/before-tree`) with the **final** test text and the three
owned production files restored to their baseline hashes (verified). Log:
`xctest/before-fix-final.log`, `Executed 5 tests, with 4 failures`,
`exit_status=1`.

```
CanvasDomainTests.swift:1368: testFocusedEmptyTextEditorDisablesToolbarAndMenuUndoRedo :
  XCTAssertEqual failed: ("Optional(true)") is not equal to ("Optional(false)")
  - Undo must not render enabled while the focused editor has nothing to undo
CanvasDomainTests.swift:1370: testFocusedEmptyTextEditorDisablesToolbarAndMenuUndoRedo :
  XCTAssertEqual failed: ("Optional(true)") is not equal to ("Optional(false)")
  - Redo must not render enabled while the focused editor has nothing to redo
CanvasDomainTests.swift:1435: testTypingInFocusedTextEditorEnablesToolbarUndoWithEmptyCanvasHistory :
  XCTAssertEqual failed: ("abc") is not equal to ("") 
  - toolbar Undo must undo the typing through the focused editor
CanvasDomainTests.swift:1445: testTypingInFocusedTextEditorEnablesToolbarUndoWithEmptyCanvasHistory :
  XCTAssertEqual failed: ("xyabc") is not equal to ("xy")
```

The two Add-menu routing tests and the toolbar routing test pass before the
fix as well; they are regression coverage, not defect discriminators.

An earlier before-fix run of the first test text is kept as
`xctest/before-fix.log` (`Executed 2 tests, with 6 failures`).

After the fix, the same tests pass: `xctest/after-new-and-prior.log`,
`Executed 11 tests, with 0 failures`, `exit_status=0`.

## 5. Gates

Environment: `Local` configuration (`ATTIC_LOCAL_ONLY`),
`CODE_SIGNING_ALLOWED=NO`, private DerivedData `/tmp/attic-b2avail-dd`
(before-tree: `/tmp/attic-b2avail-before-dd`), offline XCTest injection into
`AtticUnitTestHost` via the Batch 1/2 runner. In-memory stores. **No app
launch.**

| Gate | Result | Log |
|---|---|---|
| `build-for-testing`, before-tree (unfixed, final tests) | exit 0, `** TEST BUILD SUCCEEDED **` | `logs/build-before-final.log` |
| `build-for-testing`, fixed tree | exit 0, `** TEST BUILD SUCCEEDED **` | `logs/build-after-final.log` |
| `xcodebuild build` (app) | exit 0, `** BUILD SUCCEEDED **`; `Attic.app` bundle id `com.taha.Attic`, **not launched** | `logs/build-app-after.log` |
| 4 new tests + 7 prior Batch 2 tests | `Executed 11 tests, with 0 failures`, `exit_status=0` | `xctest/after-new-and-prior.log` |
| Focused: the 17 Canvas classes | `Executed 209 tests, with 0 failures`, `exit_status=0` (205 baseline + 4 new) | `xctest/after-focused.log` |
| Full Local unit suite, 42 classes | `Executed 824 tests, with 4 tests skipped and 0 failures`, `exit_status=0` (820 baseline + 4 new; 820 passed, 4 skipped) | `xctest/after-full-unit.log` |
| Stability, the 5 UI-hosted tests, 3 repeats | 5/5 passing each run, `exit_status=0` ×3 | `xctest/after-stability-{1,2,3}.log` |
| `git diff --check` on the 5 owned files | exit 0, clean | — |

**Warnings.** No Swift warning in any owned file, before or after. The build
logs carry only pre-existing warnings in files outside this scope:
`AtticTests/PanelGeometryTests.swift:291` (`CGWindowListCreateImage` deprecated
in macOS 14.0), `AtticTests/TaskStoreTests.swift:257` ("code after 'throw' will
never be executed"), and the `appintentsmetadataprocessor` "no
AppIntents.framework dependency" note.

**Counts.** 205 → 209 focused, 820 → 824 full. The delta is exactly the four
new tests; no test disappeared — the Batch 2 toolbar/menu test was renamed and
split, which is net +1 test name (see §6), and the remaining +3 are new.

## 6. Deviation: the Batch 2 toolbar/menu test was split

`testToolbarAndMenuUndoRedoFollowFocusedTextEditor` began failing under the
fix, at its Add ▸ Edit ▸ Undo step. Measured cause, not assumed:

- With a hosted panel, the popup's menu items **freeze their enabled flags at
  the first open**. Probe: with truth `canUndo=true, canRedo=false`, the first
  open read `Undo=true`; after a toolbar Undo click changed truth to
  `canUndo=false, canRedo=true`, later opens still read `Undo=true,
  Redo=false`, including after a settle.
- `NSMenu.performActionForItem` does **not** fire for an item whose flag reads
  disabled, so the step could not be forced either.
- Directly before the failing open, instrumentation showed the truth was
  `editorCanUndo=true`, `route=true`, editor still first responder — i.e. the
  frozen chrome, not the fix, refused the command.
- Pre-fix this was invisible: the session term kept every control enabled at
  all times, so a frozen snapshot never blocked anything.

Resolution, all inside the owned test file:

- The test kept its toolbar coverage (Undo then Redo through rendered buttons,
  with a settle between commands and no click point reused — a repeated click
  point at an identical synthesized timestamp was also observed to be dropped)
  and was renamed `testToolbarUndoRedoFollowFocusedTextEditor`.
- Its Add ▸ Edit halves moved to `testAddMenuUndoRoutesToFocusedTextEditor`
  and `testAddMenuRedoRoutesToFocusedTextEditor`, each with its own hosted
  panel and exactly one menu open, so each menu command is exercised while it
  is genuinely live. Both assert the editor text changed and canvas history did
  not.

Net Add ▸ Edit coverage is unchanged or better: menu Undo routing, menu Redo
routing, and (new) both items' disabled state with a focused empty editor.
Mutant M3 from Batch 2 (toolbar/menu calling `session.undo()` directly) is
still discriminated — by the toolbar test and by both menu tests.

No other deviation from the brief. The only bump site used is
`preserveSemanticTextDraft`; the two other sites the brief mentioned live in
`Attic/Canvas/CanvasSemanticInteraction.swift`, which is outside the owned set
(see §7.1, §7.2).

## 7. Unresolved risks

1. **External reconcile that clears the editor undo stack.**
   `reconcileSemanticTextEditing` calls `editor.undoManager?.removeAllActions()`
   (`CanvasSemanticInteraction.swift:291`) on external content replacement. That
   file is outside the owned set, so no bump was added there. The path is only
   reached from a session publish of `semanticObjects`, so a republish does
   occur, but the panel's re-render and the stack clear are not ordered within
   that cycle; the chrome can lag one cycle before settling correct. Not
   covered by a test.
2. **Focus changes do not themselves bump the token.** In production a focus
   gain rides on a publish (double-click → `selectSemanticObject`; commit →
   history publish), which is why the new D1 test mirrors that order. A focus
   change that publishes nothing would leave the chrome stale for one cycle.
3. **Harness, not product:** the offline hosted-panel menu freeze in §6 means
   no single test can drive more than one Add ▸ Edit command, and rendered
   availability needs an explicit settle between commands. This constrains
   future tests in this area.
4. `editingAvailabilityToken` uses `&+`, so it wraps; it is only ever compared
   for change by Combine, never read for meaning.
5. Every §6 finding of the Batch 2 record that this follow-up did not touch —
   top-edge anchoring, drag-preview clipping, no shrink-to-fit, legacy clipped
   objects, thin shapes — still stands.
6. Verified by build, unit tests, and source review only. Nothing here is
   evidence of CloudKit, APNs, iPhone, TestFlight, or Production behavior, and
   the app was built but never launched.
