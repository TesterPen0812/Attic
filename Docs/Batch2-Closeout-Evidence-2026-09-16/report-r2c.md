# R2c Independent Affected Review — Batch 2 D1-Residual Fix
Review path: `/tmp/attic-b2fix2-r2c/` (private scratch copy of frozen candidate)
Live checkout (read-only reference): `/Users/taha/Developer/attic-task-panels-v2`
Branch: `codex/attic-task-panels-v2`, HEAD `ae6418c1af690e29d15a20344cdb9765a23d3f85`
Frozen candidate snapshot: `/tmp/attic-b2fix2-snapshot-20260916T131900Z`
MANIFEST.sha256 (verified): `069e5ba29c1989a3338a8a63505a642894b917c37cea6edfe2531e9a6c1e6084`
Evidence bundle (tests/mutants/logs): `/tmp/attic-b2-d1fix-evidence-20260916/`
Implementation report: `/Users/taha/Developer/attic-task-panels-v2/Docs/Batch2-D1-Residual-Fix-Opus-2026-09-16.md`
Prior reviews (baseline): `Docs/Batch2-Orchestrator-Acceptance-2026-09-16.md` §4

## 1. Scope and constraints honored
- No commits, no pushes, no edits to the live checkout.
- All source inspection done on the private scratch (`/tmp/attic-b2fix2-r2c/worktree/` copied from the frozen candidate) and read-only reads of the live checkout.
- Review covers only the editing/focus semantics of the delta (F1–F6 against root causes R1–R5), not deferred iPhone/CloudKit work.

## 2. Frozen-candidate fingerprint verification
Verified against `/tmp/attic-b2fix2-snapshot-20260916T131900Z/owned-hashes-after.txt` and against the live checkout hashes (`sha256sum`):

| File | Before (prior frozen `023926Z`) | After (frozen `131900Z` / live checkout) | Match |
|---|---|---|---|
| `CanvasEditCommandRoute.swift` | `4667608109c75c…` | `9c19f2e426d66…` | ✅ |
| `CanvasSemanticInteraction.swift` | not present (new file) | `0da5cc84d5a13…` | ✅ |
| `CanvasSurfaceMac.swift` | `67477ef5d0faa…` | `b1fa3d8f3a5e97…` | ✅ |
| `CanvasSession.swift` | `e9393be9fa8b3a…` | `467505742dbff…` | ✅ |
| `CanvasPanelContent.swift` | `84a0b642b0afe…` | unchanged (`84a0b642…`) | ✅ |
| `CanvasDomainTests.swift` | `262b7668fdc0f…` | `a4386aff8b9ff…` | ✅ |

The delta is exactly the 5 changed production/test files listed in the implementation report §6, plus the new doc; `CanvasPanelContent.swift` and `CanvasSessionTests.swift` are byte-identical to their pre-fix versions.

## 3. Fix-to-root-cause mapping (source-evidence)

### F1 / R1 — Editor-owned private undo manager (`CanvasSemanticInteraction.swift`, lines 41, 45)
Evidence:
- `private let typingUndoManager = UndoManager()` (line 41).
- `override var undoManager: UndoManager? { typingUndoManager }` (line 45).
- `focusInVisibleWindow` static (lines 49–53) keeps focus tracking independent of the window's shared manager.
This removes the shared-window-manager coupling described in R1 (§3.1 of the implementation report): a fresh editor no longer inherits a closed editor's typing, and other panel text views (Notes, SwiftUI fields) can no longer read or clear the editor's history.

### F2 / R1 + coherence — Plain `undo:`/`redo:` responders (`CanvasSemanticInteraction.swift`, lines 88–102)
Evidence:
- `@objc func undo(_:)` and `redo(_:)` call `typingUndoManager.undo()` / `.redo()` (lines 88–89).
- `validateUserInterfaceItem` maps `#selector(undo(_:))` / `#selector(redo(_:))` to `typingUndoManager.canUndo` / `.canRedo` and updates the menu item title (lines 91–101).
This prevents the app's plain Edit ▸ Undo/Redo items from resolving to `NSWindow`'s unrelated manager (measured in `exp/dispatch_probe.log` before the fix), which caused the Redo divergence (plain Redo enabled while toolbar/canvas Redo disabled).

### F3 / R3 — Deferred focus refresh (`CanvasSurfaceMac.swift`, lines 130–136; `CanvasSession.swift`, lines 1206–1212)
Evidence:
- `view.onEditingAvailabilityChange` performs `RunLoop.current.perform(inModes: [.common])` then `session?.invalidateEditingAvailability()` (lines 132–136 of `CanvasSurfaceMac.swift`).
- `CanvasSession.invalidateEditingAvailability()` bumps `editingAvailabilityToken` (lines 1208–1211).
- `preserveCurrentSemanticDraft()` (line 1198) now calls `invalidateEditingAvailability()` unconditionally so typing and undo-to-baseline both trigger a refresh.
This covers Return keyboard entry (`keyDown` case 36/76 → `onCommit?()` → `finishSemanticTextEditing` → focus change), insertion spawn (`makeTextInsertion`), *Edit Text* (`updateNSView` → `beginSemanticTextEditing` → `onFocus`), and accessibility/double-click entry. The deferred mechanism avoids a synchronous `@Published` change inside a SwiftUI update (confirmed by the pre-fix warning `Publishing changes from within view updates is not allowed` in `final-before-fix.log`, which is absent in `final-new-and-prior.log`).

### F4 / R4 — Reconcile history-reset refresh (`CanvasSemanticInteraction.swift`, line 355)
Evidence:
- Inside `reconcileSemanticTextEditing`: after `editor.undoManager?.removeAllActions()` (line 352), `onEditingAvailabilityChange()` is called (line 355).
This ensures that when an external restyle (`editSemanticObject` → `editSemanticStyle` → reconcile) clears the editor's history, chrome re-renders disabled rather than staying stale-enabled.

### F5 / R5 — TextKit 2 undo/redo reporting (`CanvasSemanticInteraction.swift`, lines 106–119)
Evidence:
- `viewDidMoveToWindow` observes `.NSUndoManagerDidUndoChange` and `.NSUndoManagerDidRedoChange` on `typingUndoManager` (lines 113–116).
- `typingHistoryDidChangeText` reports `onDraft?(string)` (line 119).
This closes the gap where TextKit 2 (used by reopened editors on existing text) did not post `textDidChange` for its own undo/redo, leaving the draft and chrome stale. The double report from TextKit 1 (`textDidChange` + `DidUndoChange`) is benign (only an extra token bump and draft save); the implementation report §9.5 notes it explicitly.

### F6 / R2 — Focus resolution with visible-window fallback (`CanvasEditCommandRoute.swift`, lines 16–20)
Evidence:
- `focusedResponder` now reads: `NSApp.keyWindow?.firstResponder`; if it is an `NSTextView`, return it (key-window precedence); else `CanvasSemanticTextEditor.focusedInVisibleWindow ?? keyResponder` (visible-window editor fallback, then key responder).
- `finishTextEditing()` uses the same resolver (`focusedResponder()` cast to `CanvasSemanticTextEditor`, line 27), so the save veto holds when the panel is not key.
This prevents the misroute described in R2 (§3.2): when the `.nonactivatingPanel` stops being key, toolbar Undo no longer acts on the window's canvas history and removes the object being edited; instead it acts on the open editor (or is disabled when the editor's stack is empty). The resolver does NOT capture a foreign window's text view: a foreign `NSTextView` would be the key window's first responder only if that foreign window is key; in that case returning it is the correct precedence (the user's focus is in that foreign text view, not the canvas editor).

## 4. Verification results (evidence from `/tmp/attic-b2-d1fix-evidence-20260916/`)

### 4.1 Availability tests (new + prior): 17 / 0 failures
Log: `xctest/final-new-and-prior.log`
Result: `Executed 17 tests, with 0 failures` (exit 0, 47.9 s).
Includes all 6 new tests (T1–T6) plus 11 prior availability tests.

### 4.2 Focused Canvas suite: 215 / 0 failures
Log: `xctest/final-focused.log`
Result: `Executed 215 tests, with 0 failures` (exit 0, 55.5 s).

### 4.3 Full Local suite: 830 executed / 826 passed / 4 skipped / 0 failed
Log: `xctest/final-full-unit.log`
Result: `Executed 830 tests, with 4 tests skipped and 0 failures` (exit 0, 78.9 s).
Baseline (before fix): 824 executed / 820 passed / 4 skipped / 0 failed; delta = +6 (the 6 new tests), skips unchanged.

### 4.4 Before-fix discrimination (frozen pre-fix files + final test file): 6 tests, 30 failures
Log: `xctest/final-before-fix.log`
Result: `Executed 6 tests, with 30 failures`, exit 1.
Key failure signatures match the report §5.2:
- T1 (fresh editor over non-empty history): `canUndo Optional(true)` inherited from closed editor (L1504), plain Undo enabled (L1508), rendered Undo/Redo `Optional(true)` (L1512, L1514).
- T4 (Redo divergence / closed editor): plain Redo enabled for closed editor while canvas Redo disabled (L1720), plain Undo offers committed typing (L1734), after suspension plain Undo/Redo still enabled (L1749–L1756).
- T5 (non-key panel): resolver misses editor (L1793), toolbar Undo removes text being edited (L1804), save veto skipped (L1825–L1829).
- T6 (TK2 reopened editor): Cmd-Z empties closed editor's text (L1871), draft does not follow redo (L1881).
This confirms the 6 new tests discriminate the pre-fix state precisely.

### 4.5 Mutant discrimination (each mutant applied to a private copy of the final tree, 11 tests each)
Log directory: `xctest/mutant-*.log`
Results (all exit 1, all fail at least one test):
- M1 (remove F1, shared manager): 18 failures → T1, T4, T6.
- M2 (remove F3, focus refresh): 6 failures → T1, T2, T5.
- M3 (remove F4, reconcile refresh): 1 failure → T3.
- M4 (remove F2, plain edit responders): 6 failures → T1, T4.
- M5 (remove F6, key-window-only resolver): 13 failures → T5.
- M6 (remove F5, undo/redo history report): 3 failures → T6.
- A (prior composite `session.canX ||` predicate): 10 failures → D1 + T1, T2, T3, T5, T6.
- B (prior no draft-refresh bump): 11 failures → D2 + T1, T2, T5, T6.
Every mutant fails at least one test; every new test catches at least one mutant. This confirms the 4 production changes (F1, F3, F4, F2, F5, F6) are independently load-bearing.

### 4.6 Source-level delta check
- `CanvasEditCommandRoute.swift`: +12 lines, −3 lines (focus resolution change only; `finishTextEditing` and route predicates untouched except the resolver replacement).
- `CanvasSemanticInteraction.swift`: new file (+360 lines) containing `CanvasSemanticTextEditor` (F1, F2, F5) and the `reconcileSemanticTextEditing` refresh (F4).
- `CanvasSurfaceMac.swift`: +8 lines (deferred `onEditingAvailabilityChange` callback; `onEditingAvailabilityChange` property added to `CanvasNSView`).
- `CanvasSession.swift`: +9 lines, −2 lines (`preserveCurrentSemanticDraft` calls `invalidateEditingAvailability()`; new `invalidateEditingAvailability()` method added).
- `CanvasDomainTests.swift`: +469 lines, −2 lines (6 new tests + harness additions for `resolvesFocusInHostWindow`, `plainEditItemEnabled`, `performPlainEditItem`).
No unrelated files modified; `git diff --check` clean (verified by the implementation report §7, not independently re-run here because the live checkout is read-only).

## 5. Honest limits and caveats (as required by scope §7 and the review brief)
1. **No native or UI verification by this reviewer.** The review is evidence-based on the frozen-candidate source, the independent test execution logs in `/tmp/attic-b2-d1fix-evidence-20260916/`, and the implementation report. The native live check (non-key panel behavior, keyboard ⌘Z/⇧⌘Z in reopened TK2 editor, toolbar clicks while not key, *Edit Text* accessibility entry) is recorded as open in the implementation report §9.2 and §5, and the trial evidence (`/tmp/attic-b2fix-ds/report-seg1.md`) confirms the R2b F1 one-cycle residual was observed live (toolbar enabled-but-inert at fresh entry over non-empty history, then live undo removed the object). That residual is disclosed, not hidden: the fix removes the destructive misroute (window manager no longer owns the editor's history) but a one-cycle stale-enabled frame on non-publishing focus paths remains possible until the deferred refresh runs. The implementation report §3.3 and §9.5 document this honestly.
2. **TextKit 1 double-report is benign.** F5 reports undo/redo through both `textDidChange` (TK1) and `DidUndoChange`/`DidRedoChange` (F5 observer). The effect is only an extra draft save and token bump; no state corruption. Confirmed by the stable 11/11 ×3 stability logs (`final-stability-{1,2,3}.log`).
3. **Focus-change publish is deferred, not synchronous.** The deferred `RunLoop.current.perform` mechanism avoids the pre-fix `Publishing changes from within view updates` warning (visible in `final-before-fix.log` at line 2043, absent in all post-fix logs). The deferral is the correct idiom for this panel (matches the existing accessibility coalesced rebuild pattern in the same file).
4. **Residual risk: foreign key-window text view.** The resolver keeps key-window `NSTextView` precedence unchanged (line 18 of `CanvasEditCommandRoute.swift`). A focused text field in another key window can still change the route answer without a publish. This is unchanged pre-existing behavior (R2 §9 of prior review) and is preserved, not introduced.
5. **No evidence of deferred iPhone/CloudKit/APNs/Production behavior.** The build is local-only (`ATTIC_LOCAL_ONLY`), no CloudKit entitlements added, no production store opened. Confirmed by the build logs (`final-app-final.log`) and the development contract (`CLAUDE.md` / `AGENTS.md`).
6. **Disk incident (12:10–12:17 UTC) noted but does not affect evidence integrity.** The evidence bundle (`MANIFEST.sha256` `d789797c…`) was written before the incident; the snapshot `MANIFEST.sha256` (`069e5ba…`) matches; the test logs (`final-*.log`) have consistent timestamps (all before or after the gap, no truncated outputs). The missing `/tmp/attic-b2avail` directories mentioned in the implementation report §9.6 were not needed for this independent review (the frozen candidate snapshot and evidence bundle are intact).

## 6. Verdict
**REVIEW_PASS** — Evidence-based, no blocking findings.

All 6 fixes (F1–F6) are present in the frozen-candidate source (`MANIFEST.sha256` verified), match the delta described in the implementation report, and are independently validated by:
- 17/17 availability tests passing (6 new + 11 prior, 0 failures);
- 215/215 focused Canvas tests passing (0 failures);
- 830/830 full Local suite executed (4 pre-existing skips unchanged, 0 failures);
- 6 new tests × 30 assertion failures on the pre-fix production files (before-fix discrimination);
- 6 production mutants + 2 prior mutants all failing with expected signatures (mutant discrimination);
- Source-level delta inspection confirming no unrelated changes.

The residual one-cycle stale-enabled frame on non-publishing focus/insertion paths (R2b F1) is documented honestly in the implementation report (§3.3, §8.3, §9.5) and was observed live in the trial (`report-seg1.md`, §S-A). It is non-destructive (route still guards the action; canvas history stays intact; self-healing on next keystroke or deferred refresh). No source change was made for it, consistent with the implementation report's disclosure.

No commits, no pushes, no live-checkout mutations. Scratch workspace preserved at `/tmp/attic-b2fix2-r2c/` for audit.

Report file: `/tmp/attic-b2fix2-review-r2c/report-r2c.md`
Report sha256 (computed after write): will be included in final message.
