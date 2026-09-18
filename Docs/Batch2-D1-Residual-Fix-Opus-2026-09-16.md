# Batch 2 closeout: D1 edit-entry residual fix and Redo divergence analysis (Opus, 2026-09-16)

Owner: Opus implementation thread `agent-d880c2fd430579b9e1a89c8459af311e`
(Synara request `b2-avail-fix-opus-6`). Checkout
`/Users/taha/Developer/attic-task-panels-v2`, branch
`codex/attic-task-panels-v2`, HEAD `ae6418c1af690e29d15a20344cdb9765a23d3f85`.
The dirty tree is the candidate. Nothing was committed, pushed, reset or
stashed. The only repository files I changed are the five listed in §6, plus
this report.

Verdict: **IMPLEMENTATION_READY for review.** Local-only unit and build
evidence only. The live native recheck of the changed behaviors is still open
(§9).

## 1. Sequencing and hold

| Time (UTC) | Event |
|---|---|
| 11:49:55 | Started. `/tmp/attic-b2fix-ds/seg1-complete.marker` absent, so the tree was frozen. Investigation was read-only. |
| 11:52–12:16 | Worked only outside the checkout, in `/tmp/attic-b2-opus-scratch/`: a private copy of the frozen snapshot and non-activating AppKit experiments. The brief's example scratch path lies inside the checkout and would have added a status entry during the freeze, so I used this `/tmp` path instead. |
| 12:10–12:17 | The disk filled up (§9.6). |
| 12:13:37 | The live tester wrote the marker (report sha256 `14c24d0c…fd26`, verified). I observed it at about 12:17. The 90-minute hold cap was never reached. |
| 12:22:06 | Patch applied to the dirty tree. The owned files matched the frozen candidate's hashes first (§6). |
| 12:22–13:10 | Iterated on the live tree, then ran the final verification (§7) on the final candidate. |

## 2. Evidence that set the direction

- **Prior trial, DeepSeek S1** (`/tmp/attic-b2trial-ds/report.md`). The editor
  was opened with Tab then Return on committed text over non-empty history.
  Toolbar Undo was enabled and did nothing. The app Edit menu showed *Undo
  Canvas Change* enabled **and plain Undo enabled**. Closing the editor made
  the same button undo canvas history.
- **Segment 1, DeepSeek S-A** (`/tmp/attic-b2fix-ds/report-seg1.md`). The same
  entry path gave a different failure. Toolbar Undo was enabled and **live on
  canvas history** while the fresh editor was open. It removed the committed
  object, and with a typed draft (`gammax`) it removed the object and dropped
  the draft. With that fresh editor open, the app Edit menu showed Cut, Copy,
  Paste and Select All **disabled** although text was present. The tester
  recorded this as "not reproduced / undo is live". By the route contract ("a
  focused text editor owns Undo/Redo") it is a D1-class misroute (§3.2). The
  session was noisy: misclicks, foreign characters in typed text, and a menu
  that Escape did not close. I rely only on the facts above.
- **Segment 1, S-B**: the Redo divergence was not reproduced. All seven menu
  reads showed plain Undo/Redo disabled, including with an editor open and
  holding typed text (§8.4).

The discriminating detail is plain Undo. AppKit validates the plain items
live, at menu open, against the key window's responder chain. SwiftUI's
*Canvas Change* items and the panel only update on publishes. A stale render
over an **empty** editor stack would have shown plain Undo disabled. It
showed enabled, so the fresh editor's stack was not empty.

## 3. Root cause (five mechanisms, all measured)

### 3.1 R1: every canvas text editor shared the panel window's undo manager

`CanvasSemanticTextEditor` did not provide an undo manager, so
`editor.undoManager` resolved up the responder chain to the panel window's
manager. Experiment `exp/undo_share.swift`
(`/tmp/attic-b2-opus-scratch/exp/undo_share.log`, non-activating process,
window never ordered in) measured these steps:

1. `e1.undoManager === window.undoManager: true`.
2. After typing in editor 1 and removing it, the window manager still reports
   `canUndo=true` ("Undo Typing"), and editor 1 stays alive.
3. A fresh editor 2 opened on the committed text reports `canUndo=true` with
   nothing typed.
4. A route-style `undo()` from editor 2 changes **editor 1's detached text**
   (`e1: 'gamma' → 'gam' → ''`) while editor 2 stays `'gamma'`. The click is
   inert.
5. The plain `undo:` action is handled by `NSWindow` and validates `true`.
   After those inert undos, the window manager has redo actions, which is the
   Redo divergence (§8).

This is not one-cycle staleness. The route truthfully reported a stack that
belonged to closed editors, and every new editor's typing re-armed it. It
also coupled canvas editors to every other text view in the panel window,
including Notes' `textView.undoManager?.removeAllActions()`.

### 3.2 R2: focus resolution through the key window only

`CanvasEditCommandRoute.focusedResponder` was
`{ NSApp.keyWindow?.firstResponder }`. The panel is a `.nonactivatingPanel`
in an `LSUIElement` app. It can stop being key while its editor remains its
first responder, and accessibility presses still reach its toolbar. The route
then fell back to `session.canUndo/undo()`, with two effects:

- Toolbar Undo rendered enabled from canvas history, and a click undid the
  insertion of the object being edited, which closed its editor.
- `finishTextEditing()` found no editor, so tool changes skipped the save
  veto.

The segment-1 facts in §2 match this. That the panel was not key is an
inference, based on:

- Cut, Copy and Select All were disabled with an editor open.
- Undo removed the object even while a typed draft was open.

The alternative, a toolbar click taking focus from the editor, would have
committed `gammax` first and left one object. The unit reproduction uses the
production resolver in the never-key test host (§5, test 5), and on the
frozen candidate the toolbar click removed the text being edited (§5.2).

### 3.3 R3: no publish after focus moves

Keyboard Return (`CanvasNSView.keyDown` case 36/76), the text-tool insertion
spawn (`makeTextInsertion` publishes nothing), and the *Edit Text* request
(publishes before `updateNSView` moves focus) all move focus into a new
editor with no publish afterwards. The chrome keeps the canvas-history state
it last rendered. This is R2b F1, and it would remain even with R1 fixed.

### 3.4 R4: an editor-history reset without a publish

`reconcileSemanticTextEditing` replaces an untouched editor's text and calls
`removeAllActions()`.

- Setting `string` programmatically does **not** send `textDidChange`. The
  experiment measured `draftBumps` unchanged. This contradicts R2b §6.1 and
  the earlier implementation record.
- `removeAllActions()` posts nothing.

The panel had already read the old stack earlier in that SwiftUI update, so
Undo stayed enabled with nothing to undo.

In the hosted app, an *external* store change also clears canvas history and
rebuilds the surface, which closes the editor. The live-editor path is
therefore reached through **local** content changes, for example the
selection dock's style menu (`editSemanticStyle` → `editSemanticObject`).

### 3.5 R5: TextKit 2 editors never republished their own undo or redo (found here)

Editors opened on existing text use TextKit 2. The harness measured
`textLayoutManager != nil`. Insertion editors fall back to TextKit 1 because
`layoutSemanticTextEditor` touches `layoutManager`.

`exp/tk2_undo_probe.log` measured:

```
forceTK1=false TK2=true  typing->changes=1 undo->+0 redo->+0 undoNotes=1 redoNotes=1
forceTK1=true  TK2=false typing->changes=1 undo->+1 redo->+1 undoNotes=1 redoNotes=1
```

After Cmd-Z in a reopened editor, nothing re-rendered and no draft was saved.
A hosted diagnostic measured the route at `canUndo=false, canRedo=true`
while the rendered chrome showed Undo **enabled** (inert) and Redo
**disabled**. The earlier claim that "NSTextView posts that notification for
typing and for its own undo and redo" holds only for TextKit 1.

On the frozen candidate this was partly masked in the test host by R1. The
two editors' typing shared one window undo group, so Cmd-Z also emptied the
closed insertion editor's text, and that editor's stale callback refreshed
the chrome (traced in the private before-tree; see the test 6 signature).

## 4. Fix (four production files)

| # | Change | Closes |
|---|---|---|
| F1 | `CanvasSemanticTextEditor` owns a private `UndoManager` (`override var undoManager`). A fresh editor starts empty, its history dies with it, and other panel text views can no longer read or clear it. | R1 |
| F2 | The editor answers `undo:`/`redo:` and validates them, including the menu titles, against its own manager. Without this, F1 would leave the app's plain Undo/Redo pointed at the window's unrelated history while typing: an `NSWindow` handles those actions using its own manager (`exp/dispatch_probe.log`). | R1, coherence |
| F3 | `becomeFirstResponder` calls `onFocus`, which calls `CanvasNSView.onEditingAvailabilityChange`. That runs `session.invalidateEditingAvailability()` (a token bump) on the next run-loop pass, in common modes. This covers Return, insertion spawn, *Edit Text* (inside `updateNSView`), accessibility *Edit Text*, and double-click. | R3 |
| F4 | `reconcileSemanticTextEditing` makes the same deferred refresh after its history reset. | R4 |
| F5 | The editor observes its manager's `DidUndoChange`/`DidRedoChange` and reports them through `onDraft`, as TextKit 1 already does. The draft and availability now follow undo and redo in both text systems. | R5 |
| F6 | The route's default resolver takes a text view focused in the key window first (precedence unchanged), then a canvas editor that still holds focus in its **visible** window, then the key window's responder. `finishTextEditing` uses the same resolver, so the save veto also holds when the panel is not key. | R2 |

Why the refresh is deferred:

- `beginSemanticTextEditing` can run inside `updateNSView`, and `reconcile`
  runs inside `configure`. A synchronous publish there would be a publish
  from within a view update.
- The deferral was first a `Task { @MainActor }`. I measured that such a Task
  cannot run while an async main-actor job spins the run loop: the async
  non-key test stayed stale with the token at `0`. SwiftUI updates are driven
  by the run loop. `RunLoop.current.perform(inModes: [.common])` is the idiom
  the canvas already uses for its coalesced accessibility rebuild, and it
  runs in both cases.

Preserved:

- Availability is still route-only, still driven by
  `editingAvailabilityToken`.
- Typing still never publishes canvas history, and editor undo never touches
  session history.
- Every `finishTextEditing()` switch site is untouched and is now also
  effective when the panel is not key.
- Insertion drafts, undo back to the baseline (an unconditional bump),
  teardown and suspension keep their behavior.
- The resolver keeps a key-window text view first, so a focused text field in
  another window keeps its own ⌘Z.

## 5. Tests

All tests are in `AtticTests/CanvasDomainTests.swift`
(`CanvasAccessibilityTests`). No project input changed, so the project was not
regenerated.

### 5.1 New tests

| # | Test | Guards |
|---|---|---|
| 1 | `testKeyboardEditEntryAfterCommittedTypingRendersFreshEditorUndoRedo` | The live S1 replica: type and commit through an insertion editor; make canvas history hold an undo and a redo; select; Return. The fresh editor has an empty stack; the route, the rendered Add ▸ Edit items and the app's plain Undo/Redo all read disabled; toolbar clicks change nothing (neither editor nor history); typing makes Undo live for this editor only. |
| 2 | `testTextToolInsertionSpawnRendersEditorUndoRedoOverCanvasHistory` | A real text-tool click on empty canvas. The chrome is disabled after focus; clicks are inert; the draft is saved; toolbar Undo and Redo act on the editor; one commit adds exactly one object. |
| 3 | `testRestyleThatClearsEditorHistoryRerendersUndoRedo` | A selection-dock restyle (`editSemanticObject`) while an untouched editor has undo history. The editor stays open, its history is cleared, Undo re-renders disabled, and canvas history (the restyle) survives. |
| 4 | `testClosedTextEditorLeavesNoTypingHistoryForPlainEditMenu` | While editing, plain Undo/Redo act on the editor only. After Escape, commit or suspension, plain Undo/Redo are not left enabled, and a reopened draft starts with an empty history. This is the unit-level reproduction of the Redo divergence (§8). |
| 5 | `testTextEditorInNonKeyPanelKeepsUndoRedoAndCommitVeto` | The production resolver in the never-key host: the open editor keeps Undo, Redo and the save veto, and the toolbar never removes the text being edited. |
| 6 | `testKeyboardUndoInReopenedTextEditorRerendersUndoRedoAndDraft` | A TextKit 2 editor: after Cmd-Z the draft follows, Undo renders disabled, toolbar Redo is live, and a closed editor's text never changes. |

Harness additions in `HostedCanvasChrome`:

- A `resolvesFocusInHostWindow:` flag (default `true`, the previous
  behavior).
- `plainEditItemEnabled(_:)` and `performPlainEditItem(_:)`, which resolve the
  app's plain `undo:`/`redo:` along the host window's responder chain as
  NSMenu does.

All menu reads keep the measured one-open-per-panel rule.

### 5.2 Failing on the frozen candidate, passing after

The before tree is `/tmp/attic-b2-opus-scratch/before`: the frozen
candidate's production files (hashes `46676081…`, `8e19f2d6…`, `67477ef5…`,
`e9393be9…`, `84a0b642…`) plus the final test file. Log
`xctest/final-before-fix.log`: `Executed 6 tests, with 30 failures`,
`exit_status=1`. Key signatures:

```
T1 L1504 fresh editor canUndo Optional(true) (inherits closed editor's typing)
   L1508 plain Undo enabled · L1512/L1514 rendered Undo/Redo Optional(true)
T2 L1584/L1586 rendered Undo/Redo Optional(true) after insertion spawn
T3 L1666 rendered Undo Optional(true) after the restyle cleared the stack
T4 L1720 plain Redo enabled for a closed editor while canvas Redo is disabled
   L1734 plain Undo offers committed typing · L1749/L1754–L1756 after suspension
T5 L1793 resolver misses the editor · L1796/L1798 rendered Optional(true)
   L1804 toolbar Undo removed the text being edited · L1825–L1829 veto skipped
T6 L1871 Cmd-Z emptied the closed editor's text · L1881 draft did not follow redo
```

After the fix, the same six tests pass. Log `xctest/final-new-and-prior.log`,
with the eleven prior availability tests included: `Executed 17 tests, with 0
failures`.

### 5.3 Mutant discrimination (final code)

Each mutant was applied alone to a private copy of the final tree, built
incrementally, and run against the six new tests plus the five hosted D1/D2
tests. Runner: `/tmp/attic-b2-opus-scratch/mutants.py`. Logs:
`xctest/mutant-*.log`. The private tree was restored and byte-checked
afterwards.

| Mutant | What it removes | Result (11 tests) | Tests that catch it (failing lines) |
|---|---|---|---|
| M1 | F1, the private undo manager (editors use the window's again) | 18 failures | T1 (1504, 1506, 1512, 1534, 1539), T4 (1706–1734), T6 (1871, 1881) |
| M2 | F3, the focus refresh | 6 failures | T1 (1512, 1514), T2 (1584, 1586), T5 (1796, 1798) |
| M3 | F4, the reconcile refresh | 1 failure | T3 (1666) |
| M4 | F2, the plain `undo:`/`redo:` responders | 6 failures | T1 (1534), T4 (1706–1712) |
| M5 | F6, key-window-only resolver | 13 failures | T5 (1793–1817) |
| M6 | F5, the undo/redo history report | 3 failures | T6 (1872 draft, 1876 rendered Undo, 1880 toolbar Redo) |
| A (prior) | `session.canX \|\|` added back to the panel predicates | 10 failures | D1 test (1368, 1370), T1, T2, T3, T5, T6 |
| B (prior) | The draft-save bump | 11 failures | D2 test (1435, 1445), T1, T2, T5, T6 |

Every mutant fails at least one test and every new test catches at least one
mutant.

## 6. Changed files

The pre-apply hashes equal the frozen candidate
(`/tmp/attic-b2fix-snapshot-20260916T023926Z`) and the segment-1 freeze
check.

| File | Before (frozen candidate) | After | Lines |
|---|---|---|---|
| `Attic/App/CanvasEditCommandRoute.swift` | `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf` | `9c19f2e426d665fc5b18523247285d2865a3c1da7cbf0d8985b5dc963bd4c2ba` | +12 −3 |
| `Attic/Canvas/CanvasSemanticInteraction.swift` | `8e19f2d6f27a487ab01307166f475c09b9932f5a909903401b63b252f1863eef` (clean at HEAD) | `0da5cc84d5a13bb0a8be8d9c4465a799180e4cb002d8bffdc5fe493f518fcd94` | +64 −0 |
| `Attic/Canvas/CanvasSurfaceMac.swift` | `67477ef5d0faa803d713e6758a746e6cd42a7189449d4281c687dbc096040a6e` | `b1fa3d8f3a5e9771811bdfaf37a19499554309ed8a9b1f25025da201c8f624e6` | +8 −0 |
| `Attic/Canvas/CanvasSession.swift` | `e9393be9fa8b3a1fed8ed6b814b9ccbf91d99bdbdc40d68f436b920788c542d3` | `467505742dbff69b70a317b9f013408cd3f362dfb0405671fe5982139d2a3e84` | +9 −2 |
| `AtticTests/CanvasDomainTests.swift` | `262b7668fdc0fe87d41dc011f0fac489624497cdbd5fbafd1da76773ddf8ca96` | `a4386aff8b9ff2bd6accf8f11aeadc4e16d33dc51f6a78ca4eff9adb40e00db5` | +469 −2 |
| `Docs/Batch2-D1-Residual-Fix-Opus-2026-09-16.md` | new (this report) | reported in the handoff message | — |

- `CanvasPanelContent.swift` (`84a0b642…`) and `CanvasSessionTests.swift`
  (`f5f8cdd3…`) are unchanged.
- Patch from the frozen candidate to the final state:
  `/tmp/attic-b2-opus-scratch/d1-residual-fix-final.patch` (13 hunks, sha256
  `8f03e6a12fcc73825319a191566344cc806a3160e046465e7cd8cb118301f51c`).
- Status went from 189 to 190 entries (` M
  Attic/Canvas/CanvasSemanticInteraction.swift`), and to 191 with this
  report.
- Every other snapshot overlay file is byte-identical in the live tree. The
  exception is `Docs/Batch2-Orchestrator-Ledger-2026-09-16.md`, which the
  orchestrator owns and which had already changed before I started.
- Read-only evidence bundle: `/tmp/attic-b2-d1fix-evidence-20260916/`. It
  holds the baseline and final copies of the owned files, the final patch,
  the final and mutant logs, build logs, the AppKit probes with their
  outputs, the runner and mutant scripts, status and hash files, and a copy
  of the segment-1 report. 51 files; `MANIFEST.sha256` has sha256
  `d789797c69358c95d7c59ea9b044cdb1cd90a7fe1c47f2a97c8ac8d62b8b4b7b`.
- Reconstruction of the build-relevant candidate: `git archive ae6418c`,
  then the `worktree/` overlay from
  `/tmp/attic-b2fix-snapshot-20260916T023926Z`, then the bundle's `final/`
  files. Docs added later by other participants do not affect builds.

## 7. Verification (final candidate)

Configuration: `Local` (`ATTIC_LOCAL_ONLY`), `CODE_SIGNING_ALLOWED=NO`,
private DerivedData `/tmp/attic-b2-opus-scratch/dd-live`, offline XCTest
injection into `AtticUnitTestHost`. The host runs with activation policy
`.prohibited` and never becomes key. Stores are in memory. **No app was
launched.**

The runner is `run.zsh` (`f13edc4a…`) with `makeconfig` (`d3f3a06e…`),
byte-identical to the R1b/R2b/R1/R5 reviewer copies. The implementer's
original directory `/tmp/attic-b2avail/` disappeared during this session. I
did not delete it (§9.6).

| Gate | Result | Log (`/tmp/attic-b2-opus-scratch/`) |
|---|---|---|
| `build-for-testing` (live tree) | exit 0, `** TEST BUILD SUCCEEDED **`. The first full build of the patched tree (an earlier revision) warned only in the pre-existing `PanelGeometryTests.swift:291`, `TaskStoreTests.swift:257` and `appintentsmetadataprocessor`. The final incremental build recompiled the changed files with no new warnings. | `logs/build-live-for-testing.log`, `logs/build-live-for-testing-final.log` |
| 6 new + 11 prior availability tests | `Executed 17 tests, with 0 failures`, exit 0 | `xctest/final-new-and-prior.log` |
| Focused, 17 Canvas classes | `Executed 215 tests, with 0 failures`, exit 0 (209 + 6) | `xctest/final-focused.log` |
| Full Local suite, 42 classes | `Executed 830 tests, with 4 tests skipped and 0 failures`, exit 0: **830 executed / 826 passed / 4 skipped / 0 failed** (baseline 824/820/4/0 + 6). The skips are the same four as the baseline. | `xctest/final-full-unit.log` |
| Stability: 11 hosted availability tests, 3 repeats | 11/11 ×3, exit 0 ×3 | `xctest/final-stability-{1,2,3}.log` |
| Before-fix discrimination | 6 tests, 30 failures (§5.2) | `xctest/final-before-fix.log` |
| Mutants | §5.3 | `logs/mutants-final.log` |
| `xcodebuild build` (app, full compile of the Attic target) | exit 0, `** BUILD SUCCEEDED **`. No Swift warnings, only the `appintentsmetadataprocessor` note. Bundle `com.taha.Attic`, executable `1a35de09…6c2aac`, debug dylib `8f587914…1e1493`. **Not launched.** | `logs/build-app-final.log` |
| `git diff --check` on the five owned files | exit 0, clean | — |

Test products: host `2287db13…`, host debug dylib `31880f8d…`, test bundle
`b8b43f57…`, recorded in `xctest/final-full-unit.log`.

## 8. Task 2: Redo divergence (investigation; no Redo-specific code)

### 8.1 Which item is "plain Redo"

`AtticApp.swift` inserts `CanvasEditCommands` as a
`CommandGroup(before: .undoRedo)`. Its items, *Undo Canvas Change* (⌘Z) and
*Redo Canvas Change* (⇧⌘Z), exist only while the Canvas section is selected.
They are enabled through `CanvasEditCommandRoute.canUndo/canRedo`, evaluated
when SwiftUI re-renders. Plain **Undo** and **Redo** are SwiftUI's default
`.undoRedo` group, the standard items that send `undo:`/`redo:` along the key
window's responder chain. Segment 1's menu dump shows all four.

### 8.2 What drives each

| Surface | State source |
|---|---|
| Toolbar canvas Redo | `CanvasPanelContent.canRedoCanvasEdit`: the route (the focused text view's `undoManager.canRedo`, otherwise `session.canRedo`), rendered on publishes |
| *Redo Canvas Change* | The same route, rendered on publishes |
| Plain Redo | AppKit validation **at menu open**. The canvas editor and canvas view did not respond to `redo:`, so `NSWindow` handled it and validated against the **window's own** undo manager. Measured in `exp/dispatch_probe.log` ("validation target: NSWindow … title now: Undo Window Thing"), and the action ran the window's entry rather than the editor's. |

### 8.3 Causal hypothesis (mechanism measured; native trigger inferred)

Before the fix, canvas editors kept their typing in that same window
manager, and the typing outlived the editor (R1). The divergent state arises
from this sequence:

1. Editor typing is undone. This happens through toolbar, Add ▸ Edit, ⌘Z or
   plain Undo, or through an **inert undo at fresh entry**, which pops a
   closed editor's group.
2. The window manager now holds a redo action.
3. The editor closes (Escape, ⌘Return, a tool or section change) or loses
   focus, so the route falls back to `session.canRedo == false`.
4. The toolbar and *Redo Canvas Change* show disabled, but plain Redo
   validates enabled. Choosing it would redo into a detached text storage.

This fits the prior run. S1's two inert toolbar Undo clicks (§3.1 step 4)
created such redo actions. The control step then closed the editor and used
canvas undo and redo, which left canvas Redo disabled. Later S4 typing would
have cleared the stale redo. The "recovered mistake", where a menu item fired
by ⌘Return undid a draft, is a second way to leave one behind.

- **Unit reproduction:** test 4 on the frozen candidate fails at L1720 with
  `route.canRedo == false` and `session.canRedo == false` asserted just
  before. It passes on the candidate.
- **Native reproduction: none.** Segment 1's S-B read plain Undo/Redo as
  disabled in all seven reads, including with an editor open and holding
  typed text, and with Cut/Copy/Select All disabled. The key window's chain
  therefore did not include the panel editor during those reads (§3.2), and
  this channel could not appear in that session.

### 8.4 Code effect and remaining channel

I added no Redo-specific code. F1 and F2 (needed for D1) remove the
canvas-editor channel as a side effect: editor history dies with the editor,
and while editing, plain Undo/Redo track the focused editor.

One channel remains, not reproduced and not changed: other text views in the
panel window (Tasks and Notes text views, SwiftUI text fields) still use the
window manager. Their leftover actions can enable plain Undo/Redo inside the
Canvas section while canvas history is empty. Notes also clears that manager
(`NoteAttachmentTray.swift:1356/1404`). A native reproduction of this channel
should come before any change.

## 9. Task 3 and honest limits

1. **Task 3 (image retry picker): no code.** Segment 1 confirmed the
   corrupt-file banner and that "Choose Failed Files Again..." reopens the
   picker. The valid-file leg failed on Open-panel input problems in the
   harness: dropped characters, mangled `setValue`, a paste timeout, and an
   unresponsive Go-to field. It is still undecided whether the product or the
   harness is at fault.
2. **No native or UI verification by me.** R2's non-key state is inferred from
   segment-1 facts. The test host models it with a never-key window. The live
   recheck of F1–F6 remains for the final native run. It should cover
   Tab/Return entry, the insertion spawn, *Edit Text*, ⌘Z/⇧⌘Z in a reopened
   editor, plain Edit ▸ Undo/Redo while editing and after closing, and
   toolbar presses while the panel is not key.
3. **Plain Edit items are modeled, not opened.** The unit-test host has no
   SwiftUI main menu, so tests resolve `undo:`/`redo:` along the host
   window's responder chain. That SwiftUI's default items send
   `undo:`/`redo:` matches AppKit convention and the live observations, but I
   did not instrument it.
4. **Test-host undo grouping.** Undo groups are not closed between synthetic
   steps (traced), which shaped test 6's pre-fix signature (§3.5). The
   TextKit 2 behavior itself is shown by the standalone probe and by mutant
   M6.
5. **Residual risks:**
   - A focused text view in another key window (for example, a Settings
     field) still takes precedence in the route, and in `finishTextEditing`,
     which then does not see the canvas editor. This is unchanged R2 §9
     behavior.
   - Changes to the panel's key status publish nothing. With F6 the
     canvas-editor answer no longer depends on key status, but a foreign
     key-window text view can still change the answer without a publish.
   - A reopened draft starts with an empty history. That is deliberate: the
     old inherited history was inert.
   - TextKit 1 editors report each undo and redo twice (once from
     `textDidChange`, once from F5). The effect is only a repeated draft save
     and token bump.
   - Extra per-focus and per-undo work was not measured.
6. **Disk incident.** Between 12:10 and 12:17 the data volume hit 0 bytes
   free. The harness itself failed with ENOSPC. My three private source
   copies (about 195 MB at peak) coincided with the last free space. I
   stopped my build, deleted my copies, and cut scratch to under 1 MB.
   Something outside my control then freed about 7 GB. At about 12:23 I
   found that the prior implementer's `/tmp/attic-b2avail`,
   `/tmp/attic-b2avail-dd` and `/tmp/attic-b2avail-before-dd` were gone. I
   did not delete them. I cannot tell whether any other
   process failed during the outage. Segment 1's screenshots directory is
   empty "on orchestrator instruction", per its report.
7. **Scope.** This is not evidence of CloudKit, APNs, iPhone, TestFlight or
   Production behavior. Environment: macOS 27.0 (26A5425a), Xcode 27.0
   (27A5252f).
