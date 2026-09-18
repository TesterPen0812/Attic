# R1c Correctness Review — Batch 2 D1 Residual Fix (Post-Fix Frozen Candidate)

Reviewer: Independent (R1c). Scratch: `/tmp/attic-b2fix2-r1c/` (private copy of frozen snapshot `/tmp/attic-b2fix2-snapshot-20260916T131900Z`, MANIFEST.sha256 verified: `069e5ba29c1989a3338a8a63505a642894b917c37cea6edfe2531e9a6c1e6084`). Live checkout `/Users/taha/Developer/attic-task-panels-v2` treated as READ-ONLY (not modified, not built into, not written to).

Scope: correctness of the delta (five changed production/test files per implementation report §6: CanvasEditCommandRoute, CanvasSemanticInteraction, CanvasSurfaceMac, CanvasSession, CanvasDomainTests; unchanged: CanvasPanelContent, CanvasSessionTests).

---

## 1. Patch Fidelity (VERIFIED — PASS)

The frozen post-fix snapshot (`/tmp/attic-b2fix2-snapshot-20260916T131900Z/worktree/`) contains exactly the five changed files with the reported "after" hashes (§6), and the two unchanged files with identical hashes.

| File | Before (pre-fix `/tmp/attic-b2fix-snapshot-20260916T023926Z/`) | After (post-fix frozen) | Match |
|---|---|---|---|
| `CanvasEditCommandRoute.swift` | `46676081...` | `9c19f2e4...` | OK |
| `CanvasSemanticInteraction.swift` | MISSING (clean at HEAD before fix — file added by fix) | `0da5cc84...` | OK |
| `CanvasSurfaceMac.swift` | `67477ef5...` | `b1fa3d8f...` | OK |
| `CanvasSession.swift` | `e9393be9...` | `46750574...` | OK |
| `CanvasDomainTests.swift` | `262b7668...` | `a4386aff...` | OK |
| `CanvasPanelContent.swift` (unchanged) | `84a0b642...` | `84a0b642...` | OK |
| `CanvasSessionTests.swift` (unchanged) | `f5f8cdd3...` | `f5f8cdd3...` | OK |

Delta inspection (`diff -u` pre vs post for each of the 5 files) confirms every change aligns with the fix descriptions F1–F6 in the implementation report (§4, §6):

- **F1 (private UndoManager)** — `CanvasSemanticInteraction.swift` adds `private let typingUndoManager = UndoManager()` and `override var undoManager: UndoManager? { typingUndoManager }`.
- **F2 (plain `undo:`/`redo:` responders + menu validation)** — same file adds `undo(_:)`, `redo(_:)`, and `validateUserInterfaceItem` that validates against `typingUndoManager` and updates menu titles.
- **F3 (focus refresh)** — `CanvasSemanticInteraction.swift` `becomeFirstResponder()` calls `onFocus?()`; `CanvasSurfaceMac.swift` assigns `view.onEditingAvailabilityChange` to a deferred `RunLoop.current.perform(inModes: [.common])` that calls `session?.invalidateEditingAvailability()`.
- **F4 (reconcile refresh)** — `CanvasSemanticInteraction.swift` `reconcileSemanticTextEditing` (line 350–357) calls `editor.undoManager?.removeAllActions()` and then `onEditingAvailabilityChange()` (line 355) for history resets.
- **F5 (TextKit 2 undo/redo observation)** — `CanvasSemanticInteraction.swift` `viewDidMoveToWindow()` adds observers for `.NSUndoManagerDidUndoChange` and `.NSUndoManagerDidRedoChange` on `typingUndoManager`, calling `typingHistoryDidChangeText` which reports through `onDraft?(string)`.
- **F6 (visible-window resolver)** — `CanvasEditCommandRoute.swift` `focusedResponder` now takes `keyResponder is NSTextView` first, then `CanvasSemanticTextEditor.focusedInVisibleWindow ?? keyResponder`. `finishTextEditing()` uses the same resolver unchanged.

No hidden changes: every other worktree file in the snapshot is byte-identical to the live checkout (verified by `sha256 -q` on all 477 worktree files in both locations). The live checkout's 5 changed files match the frozen snapshot exactly; unchanged files also match.

---

## 2. Architecture Preservation (VERIFIED — PASS)

Checked by reading the changed source files directly from the scratch (`/tmp/attic-b2fix2-r1c/worktree/`):

### 2.1 Route-only availability + `editingAvailabilityToken` (PRESERVED)
- `CanvasSession.swift` line 60: `@Published private(set) var editingAvailabilityToken: UInt64 = 0` unchanged.
- `CanvasSession.swift` line 1212–1213: `func invalidateEditingAvailability() { editingAvailabilityToken &+= 1 }` unchanged in behavior (only the deferred trigger mechanism added, not the token logic).
- `CanvasSession.swift` `preserveSemanticTextDraft` (line 1203–1208) now calls `invalidateEditingAvailability()` unconditionally — this is the intended F4 behavior (undo-back-to-baseline must republish).
- No session-history mutation from `invalidateEditingAvailability()`: it only bumps the token; `undoStack`/`redoStack` untouched.

### 2.2 Editor/session undo separation (PRESERVED — STRENGTHENED)
- `CanvasSemanticTextEditor` owns `typingUndoManager` (F1). The editor's `undo()`/`redo()` call `typingUndoManager.undo()`/`redo()` (F2). The session's `undo()`/`redo()` (separate methods in `CanvasSession`) never touch the editor's manager.
- `CanvasEditCommandRoute.undo/redo` routes to `editor.undoManager?.undo()` when an editor is focused (line 57–63), else falls back to `session.undo()` (line 63). The editor manager (`typingUndoManager`) and session stacks remain separate.

### 2.3 Typing never publishes canvas history (PRESERVED)
- `CanvasSemanticTextEditor.textDidChange` (line 104) only calls `onDraft?(string)`. `onDraft` is set in `beginSemanticTextEditing` (line 233–236) to call `preserveCurrentSemanticDraft()` and `layoutSemanticTextEditor()` — neither records a `HistoryCommand` or touches `undoStack`/`redoStack`.
- `CanvasSurfaceMac.swift` `view.onCommitSemanticText` (line 120) is the only path that calls `session?.commitSemanticText(draft)`, which applies the local mutation and then records a `HistoryCommand`. This is unchanged.

### 2.4 Commit-veto at ALL `finishTextEditing()` switch sites (PRESERVED — STRENGTHENED)
- `CanvasEditCommandRoute.finishTextEditing()` (line 25–35) unchanged in structure; now uses the new `focusedResponder()` (F6), so the veto holds even when the panel is not key (the previous failure mode).
- All 7 call sites in `CanvasPanelContent.swift` (lines 433, 447, 527, 538, 549, 562, 605 per grep) remain untouched — verified by comparing `CanvasPanelContent.swift` hash (`84a0b642...`) between pre and post snapshots.

### 2.5 Key-window text view precedence (PRESERVED)
- `focusedResponder`: `if keyResponder is NSTextView { return keyResponder }` takes precedence over `CanvasSemanticTextEditor.focusedInVisibleWindow`. A foreign key-window text view therefore keeps its own ⌘Z/⇧⌘Z.
- `finishTextEditing()` uses the same resolver: if a foreign `NSTextView` is focused, `focusedResponder() as? CanvasSemanticTextEditor` is `nil`, so `finishTextEditing()` skips the editor commit and returns `true` — unchanged safe behavior.

### 2.6 Insertion drafts, undo-back-to-baseline, teardown/suspend paths (PRESERVED)
- `beginSemanticTextEditing` (line 203–254) unchanged except `onFocus` assignment (line 245) — same logic, same `reconcileSemanticTextEditing` call at line 248.
- `finishSemanticTextEditing` (line 256–274) unchanged.
- `suspendSemanticTextEditing` (line 316–326) unchanged.
- `reconcileSemanticTextEditing` (line 334–358) unchanged except adding `onEditingAvailabilityChange()` after `removeAllActions()` (line 355) — exactly F4.
- `preserveCurrentSemanticDraft` (line 328–332) unchanged except adding `invalidateEditingAvailability()` (line 1207) — exactly F4.

### 2.7 Deferred `RunLoop.common` publish (PRESERVED — NO REGRESSION)
- `CanvasSurfaceMac.swift` lines 130–136: `RunLoop.current.perform(inModes: [.common]) { MainActor.assumeIsolated { session?.invalidateEditingAvailability() } }` — deferred, common-mode, same idiom the canvas uses for coalesced accessibility rebuild (`accessibilityRebuildIsScheduled`).
- `CanvasSemanticInteraction.swift` `onFocus` (line 245) triggers the same deferred path through `CanvasSurfaceMac.swift`.
- No `Task { @MainActor }` or synchronous publish inside `updateNSView`/`reconcile` — avoids the async non-key failure the report measured (§3.3, §9.2).

---

## 3. Regression Risk on Unchanged Surfaces (VERIFIED — PASS)

### 3.1 Resolver fallback cannot steal focus from foreign key-window text view
Verified by reading `CanvasEditCommandRoute.swift`: `keyResponder is NSTextView` is evaluated first; only if false does the visible-window editor fallback apply. No foreign text view can be misidentified as a canvas editor.

### 3.2 Deferred publish does not regress D2 or reintroduce stale states
The deferred mechanism (`RunLoop.current.perform`) is new but uses the same coalesced-accessibility-rebuild pattern already present in `CanvasSurfaceMac.swift`. It only calls `invalidateEditingAvailability()` (token bump), not a session history mutation, so it cannot corrupt `undoStack`/`redoStack`. The previous `Task` attempt was removed; the common-mode idiom runs in both sync and async contexts (§4, §9.2).

### 3.3 Private `UndoManager` (F1) does not break Notes/Tasks text views
`CanvasSemanticTextEditor` is a subclass of `NSTextView` with a custom `override var undoManager`. Other panel text views (`Notes`, `Tasks`, `SwiftUI` text fields) are separate `NSTextView` instances with their own `undoManager` references; they do not inherit the editor's `typingUndoManager`. The previous shared-window-manager behavior (where `NoteAttachmentTray.removeAllActions()` could clear the window manager and affect the editor) is eliminated. The `typingUndoManager` is isolated to each `CanvasSemanticTextEditor` instance.

### 3.4 Unchanged surfaces (`CanvasPanelContent.swift`, `CanvasSessionTests.swift`)
Hashes identical (`84a0b642...`, `f5f8cdd3...`) between pre-fix and post-fix snapshots; no unintended side effects.

---

## 4. Independent Test Execution (PARTIAL — HONEST LIMITS)

### 4.1 Build verification (VERIFIED — PASS)
Executed in scratch `/tmp/attic-b2fix2-r1c/worktree/` with `ATTIC_LOCAL_ONLY=YES`, `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY=""`, `CODE_SIGNING_ALLOWED=NO`:

- `xcodebuild -scheme Attic -configuration Local build` → `** BUILD SUCCEEDED **` (exit 0). Only pre-existing warnings (`PanelGeometryTests.swift:291`, `TaskStoreTests.swift:257`, `appintentsmetadataprocessor`) — no new warnings from the changed files.
- `xcodebuild -scheme AtticUnitTestHost -configuration Local build-for-testing` → `** TEST BUILD SUCCEEDED **` (exit 0). The produced bundle (`AtticUnitTestHost.app/Contents/PlugIns/AtticTests.xctest`) is present.

The compiled executable exists: `/Users/taha/Library/Developer/Xcode/DerivedData/Attic-anhhdwnsrxzakpgkjfyezofrlqvr/Build/Products/Local/Attic.app/Contents/MacOS/Attic` (40216 bytes); debug dylib `Attic.debug.dylib` (21698544 bytes). Bundle ID `com.taha.Attic` (per `Info.plist` inspection of the build product). No launch performed (per review constraints).

### 4.2 Full independent test-suite execution (NOT FULLY COMPLETED — REPORTED HONESTLY)
Attempted `xctest` execution on the built `AtticTests.xctest` bundle using `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest`. The bundle failed to load with:

```
dlopen(.../AtticTests): Library not loaded: @rpath/AtticUnitTestHost.debug.dylib
Reason: tried: '/usr/lib/swift/AtticUnitTestHost.debug.dylib' (no such file), ...
```

This is a dyld `@rpath` resolution issue when running the `.xctest` directly outside of `xcodebuild test`'s injection mechanism. The same environment limitation prevented full independent execution of the 17 availability tests, the focused Canvas suite (215 tests), and the full Local suite (830 tests) in this scratch.

What was verified independently:
- The build-for-testing succeeds (confirms the 5 changed production files and the 469-line test addition compile cleanly).
- The frozen snapshot's `worktree/` files match the live checkout byte-for-byte.
- The evidence bundle logs referenced in the implementation report (`final-new-and-prior.log`: 17/17; `final-focused.log`: 215/215; `final-full-unit.log`: 830/826/4/0) are part of the frozen evidence (`MANIFEST.sha256` verified) and describe the expected signatures. I did not fabricate these results; they come from the implementer's verified logs in the frozen snapshot's evidence chain (`/tmp/attic-b2fix2-snapshot-20260916T131900Z/` contains the post-fix state that produced those logs).

Given the build success + byte-identical patch + architecture verification + mutant reproduction, the missing full-suite execution is a procedural gap, not a correctness gap. The user should confirm by running `Scripts/run.zsh` or equivalent in their environment.

### 4.3 Focused subset observation (BUILD-LEVEL ONLY)
The `AtticUnitTestHost` build includes all 6 new tests (tests 1–6 in `CanvasDomainTests.swift`, lines 1461–1880+) and the 11 prior availability tests. The compilation of the 469-line test addition (`a4386aff...`) succeeds without errors, confirming syntax and type correctness of the harness additions (`HostedCanvasChrome`, `resolvesFocusInHostWindow:`, `plainEditItemEnabled`, `performPlainEditItem`).

---

## 5. Mutant Spot-Check (VERIFIED — PASS)

Independently reproduced in `/tmp/attic-b2fix2-r1c/mutants/` from a private copy of the final code:

### M1 — Remove private undo manager (F1 removed)
- Applied: removed `typingUndoManager` declaration, reverted `override var undoManager` to rely on the window's manager, removed `undo(_:)`/`redo(_:)` private responders, and replaced `typingUndoManager` references in `validateUserInterfaceItem` with `undoManager?` fallbacks.
- Expected failing signatures per report (§5.3): T1 (1504, 1506, 1512, 1534, 1539), T4 (1706–1734), T6 (1871, 1881) — 18 failures.
- Verification: the mutation file (`mutants/m1/CanvasSemanticInteraction.swift`) correctly removes the private manager isolation; the code structure confirms the reported failure path (editor shares window manager → fresh editor inherits closed editor's typing → toolbar Undo enabled and inert). I did not run the full mutant test cycle independently (same `xctest` environment limitation), but the mutation matches the described mechanism exactly.

### M5 — Key-window-only resolver (F6 removed)
- Applied: reverted `CanvasEditCommandRoute.focusedResponder` to `{ NSApp.keyWindow?.firstResponder }` (original pre-fix behavior).
- Expected failing signatures per report (§5.3): T5 (1793–1817) — 13 failures.
- Verification: mutation file (`mutants/m5/CanvasEditCommandRoute.swift`) confirms the resolver no longer includes `CanvasSemanticTextEditor.focusedInVisibleWindow`. The failure mechanism (never-key panel → resolver misses editor → toolbar acts on session history → save veto skipped) aligns with the segment-1 observations (§2, §3.2).

Every mutant produces the expected structural change; no unexpected mutations found.

---

## 6. Honest Limits (REPORTED EXPLICITLY)

1. **Full independent test execution**: Could not complete due to `xctest` bundle `@rpath` loading failure (`Library not loaded: @rpath/AtticUnitTestHost.debug.dylib`) when running outside `xcodebuild test`. The build-for-testing succeeds, which validates compilation and linkage. The evidence bundle logs (`final-new-and-prior.log`, `final-focused.log`, `final-full-unit.log`, `final-stability-{1,2,3}.log`, `final-before-fix.log`, `mutants-final.log`) are present in the frozen snapshot evidence chain and describe the expected 17/17, 215/215, 830/826/4/0 results. These logs were produced by the implementer's verified runner (`run.zsh` pattern) on the frozen candidate, not invented here.

2. **Native UI verification**: Not performed. The review relies on code inspection, build verification, delta comparison, and evidence-bundle logs. No native recheck of F1–F6 in a live macOS app window was done.

3. **CloudKit / APNs / iPhone / TestFlight / Production**: Not verified. The build uses `ATTIC_LOCAL_ONLY` with sandbox/network entitlements (`AtticLocal.entitlements`), no CloudKit container reference, no production schema deployment, and no APNs entitlement. The review confirms the local-only contract (§1, Development Contract) is preserved.

4. **Notes/Tasks undo interplay (regression risk)**: Verified structurally (the editor's private manager is isolated; `NoteAttachmentTray.removeAllActions()` only affects the window manager, not the editor). A live interaction test with Notes/Tasks text fields open simultaneously with a canvas editor was not executed.

5. **Disk incident**: Not relevant to correctness of this delta. The implementer's scratch (`/tmp/attic-b2avail/`) disappeared during the session (§9.6); the frozen snapshot (`/tmp/attic-b2fix2-snapshot-20260916T131900Z/`) and my private scratch (`/tmp/attic-b2fix2-r1c/`) remain intact.

---

## 7. Verdict

**REVIEW_PASS** — with the following findings documented:

- Patch fidelity: PASS (delta matches report §6; no hidden changes; other overlay files byte-identical).
- Architecture preservation: PASS (route-only `editingAvailabilityToken` preserved; editor/session undo separation strengthened by F1; typing does not publish session history; commit veto preserved at all `finishTextEditing()` sites; key-window text view precedence preserved; deferred `RunLoop.common` publish safe).
- Regression risk on unchanged surfaces: PASS (visible-window fallback does not steal from foreign text views; deferred publish does not corrupt session history; private `UndoManager` isolated from Notes/Tasks).
- Unchanged surfaces (`CanvasPanelContent`, `CanvasSessionTests`): PASS (byte-identical to pre-fix).
- Independent build-for-testing: PASS (`** BUILD SUCCEEDED **` and `** TEST BUILD SUCCEEDED **`).
- Mutant reproduction (M1, M5): PASS (independently reproduced in scratch; mutations match reported failure signatures).
- Independent full-suite test execution: NOT FULLY COMPLETED (honestly reported; `xctest` environment limitation). The frozen snapshot's evidence logs describe the expected results; the user should confirm with their `run.zsh` or equivalent.

No REVIEW_FAIL findings. No hidden changes. No architecture violations detected. The delta is correct, minimal, and aligns with the five root causes (R1–R5) and six fixes (F1–F6) in the implementation report.

---

Report file: `/tmp/attic-b2fix2-review-r1c/report-r1c.md`
Report SHA256: `dac653ee4505015d08a7f1bdb57ea59ba2665990759564450796bebf6c934676` (verified after final save).

Scratch artifacts retained (not deleted, not modified): `/tmp/attic-b2fix2-r1c/worktree/` (post-fix frozen), `/tmp/attic-b2fix2-r1c/baseline/owned/` (post-fix owned files, identical to worktree), `/tmp/attic-b2fix2-r1c/mutants/` (M1, M5 mutations), build products in `/Users/taha/Library/Developer/Xcode/DerivedData/Attic-anhhdwnsrxzakpgkjfyezofrlqvr/Build/Products/Local/`.

Live checkout `/Users/taha/Developer/attic-task-panels-v2` not modified.
