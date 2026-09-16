# Sol final native verification — PERF-A1

Date: 2026-09-14  
Checkout: `/Users/taha/Developer/attic-task-panels-v2`  
Branch/HEAD: `codex/attic-task-panels-v2` / `ae6418c1af690e29d15a20344cdb9765a23d3f85`  
Source state: dirty shared checkout; no source edits, commits, pushes, installs, or release actions were performed by this pass.  
Verdict: **CANVAS PERF-A1 NATIVE PASS; TASK-SUBPANEL SMOKE BLOCKED/INCONCLUSIVE**

## Coordination

The dedicated screenshot task `01a0a010-4eef-7ec3-81a5-443bdb68f782` was checked before native access. Its terminal record reports completion at 2026-09-14T13:56:08Z after 63 captures (62 usable window captures and one excluded full-screen capture), and says the `AtticChromeCheckpoint` app was left running with QA fixtures intact. Native access began only after that terminal completion. The stale checkpoint process and its data were left untouched.

## Current-source preview provenance

A separate local-only preview was built and launched with the repository launcher:

`Scripts/launch_local_preview.zsh --display-name 'Attic PERF-A1 Final' --bundle-id com.taha.Attic.perfa1final --executable-name AtticPERFA1Final --derived-data /tmp/attic-perfa1-final-dd --appearance dark`

- App: `/tmp/attic-perfa1-final-dd/Build/Products/Local/AtticPERFA1Final.app`
- Bundle ID: `com.taha.Attic.perfa1final`
- PID: `28822`, launchd parent `1`
- Executable SHA-256: `240f6bca600b6f53422e8a8bbe41805891e2e478a893541c31b6282408230af9`
- Debug dylib SHA-256: `dade942ac3fd405a87c4f7de9888eba6e14b9b3b6a6e58387bca73a6191c07de`
- Local-only entitlements contained app sandbox, user-selected file access, get-task-allow, and network client/server; no CloudKit or APNs entitlement was present.
- `--verify` at 2026-09-14T16:28:04Z matched the running executable and debug dylib inode/size to those exact on-disk artifacts.

## Live interaction checks

All checks below were performed in the actual `Attic PERF-A1 Final` AppKit preview through native accessibility/pointer actions. AX state was refreshed after each transition.

| Check | Result | Live evidence |
| --- | --- | --- |
| Draw | PASS | Drag in Pen mode changed `Canvas · 0 items` to `Canvas · 1 item`; AX exposed one ink stroke. |
| Undo / redo | PASS | Undo returned to 0 strokes and enabled Redo; Redo restored the same stroke and disabled Redo. |
| Erase / undo erase | PASS | Eraser drag removed the live stroke; Undo restored it. |
| Multiple items | PASS | A second pen drag produced 2 strokes with distinct UUID-backed AX items. |
| Clear / undo clear | PASS | `Canvas actions > Edit > Clear Canvas`, followed by the confirmation sheet, changed 2 items to 0. Undo restored both strokes. |
| Create Canvas | PASS | Created `[QA] PERF-A1 final 20260914`; it immediately became the active empty board. |
| Rename Canvas | PASS | Renamed it to `[QA] PERF-A1 renamed`; title and Canvas menu value updated immediately. |
| Board switching | PASS | Switching to `Canvas` restored the original board with its 2 strokes; switching back restored the empty renamed board. Transitions completed within each bounded native call with no visible loading or stale board contents. This is qualitative responsiveness evidence, not frame-time measurement. |
| Delete Canvas | PASS | Deleting the disposable renamed board through its confirmation sheet returned to the original populated board. |
| Main Tasks | PASS | `Command-1` opened Tasks. Two uniquely labelled QA tasks were created successfully and appeared in the correct To do/In Progress sections. |
| Notes | PASS | `Command-3` opened the empty Notes state with accessible `New Note`; no note data was modified. |
| Task subpanel | BLOCKED / INCONCLUSIVE | A task-row click did not produce a subpanel in the accessible app surface. The required fallback was executed: double-clicked the task (it moved to In Progress), then used Add Task to create `[QA] PERF-A1 Add Task fallback`, then clicked that row. `Show subtasks` secondary action was also invoked. The native target continued to expose only the main panel. Because this tooling can return the focused main panel while a nonfocused subpanel exists, this is not classified as a confirmed product defect; it is not a pass either. Subpanel-specific visual/content checks were not claimed. |

The original board retains two clearly isolated strokes created by this pass. The disposable secondary board was deleted. Two `[QA] PERF-A1 ...` task fixtures remain in the isolated `com.taha.Attic.perfa1final` store; no user or checkpoint-preview data was touched.

## Automated and review evidence (separate from native checks)

- `Docs/SWE-PERFA1-Correctness-Review.md`: `REVIEW_PASS`; current 23-file snapshot integrity independently checked; supplied full-suite artifact reported 799 tests, 4 skipped, 0 failures.
- `Docs/SWE-PERFA1-Efficiency-Review.md`: `REVIEW_PASS`; Release counter-symbol absence and bounded remaining costs reviewed; explicitly no Instruments or real-user-store measurement.
- `Docs/SWE-PERFA1-Verification-Review.md`: `REVIEW_PASS`; independent rerun reported 799 tests, 4 skipped, 0 failures; focused DEBUG/non-DEBUG runs passed with the expected non-DEBUG gate skip.
- `Docs/Opus-PERFA1-Review-Fixes.md`: recorded the DEBUG-only counter fix, corrected item-provider expectation, durable pending-context test, and successful Local/non-DEBUG/Release builds.

This pass did not rerun those automated suites. Their evidence supports source/build correctness and is not substituted for the live results above.

## Captured screenshots and remaining limits

The prior screenshot task captured the stale `AtticChromeCheckpoint` preview and is useful for visual-state coverage only; it does not prove this current source build. This pass used live screenshots transiently for inspection but did not add a second screenshot catalog.

No quantitative frame pacing, Instruments trace, large real-user store, VoiceOver session, physical trackpad gesture, attachment import, Notes autosave edit, or subpanel content interaction was performed. The Canvas acceptance paths requested for PERF-A1 all passed in the current-source preview. The task-subpanel smoke remains explicitly blocked/inconclusive for the reason above.
