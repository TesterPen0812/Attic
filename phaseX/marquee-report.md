# P2 marquee — N-3

Branch: `phase-x/marquee`; worktree: `/Users/taha/Developer/attic-px-notes`.
Base pinned at task start: `origin/phase-x/int11`, `a1b663f32afc6ba2a677cecf0dc49a77a95122c8` (the remote integration ref moved later).
Implementation is pushed. The single fast CI run failed: it found a Done-page row-source regression, alongside five Notes key-window failures and a 25-minute timeout also present on the pinned base. The Done regression is fixed in `77fa1dcd`, with its focused and four hosted regressions passing and the final screen check verified. The whole fast lane is not green. Sustained motion acceptance remains open as described below.

## Implementation

- Notes and Tasks share `AtticMarqueeController`, a narrow AppKit bridge. Sharp box: 4.5% black fill, 0.5 pt adaptive 22% edge; activation at 4 pt.
- A view-based display link samples the pointer every refresh without geometry easing. The origin remains in document coordinates. Auto-scroll starts within 24 pt of the viewport edges, accelerates with distance and clamps at the document bounds. Highlights enter over 80 ms and leave over 60 ms; the released box fades over 120 ms.
- Notes selects whole paragraphs and object blocks. Neighbours share one merged grey shape. Shift adds to the selection. Esc and a plain text/empty-space click clear it; native text selection and embedded controls retain their routes.
- Notes Copy exports RTF, Markdown, plain text and the existing private fragment/attachment payload in document order. Delete/Cut and dragging the selected blocks are one atomic engine-owned Undo operation. A move shows an insertion boundary. Selected blocks hide both the legacy and modern TextKit caret; clearing restores its public display mode.
- Tasks writes the existing selection model on Now, Later and Done. Row grab areas and controls retain their original routes, and batch delete/move/tag/complete remain the existing commands and selection bar. On release, the selected row nearest the pointer receives keyboard focus without collapsing the selection. Lazy-row measurements persist through an auto-scroll sweep.
- The existing frame-watch/signpost machinery records `MarqueeDragFrames` on the view's display; `ATTIC_FRAME_MONITOR=1` also emits its counters to the frame log.
- No Canvas, dormant sync, protected owner identity, macOS system-setting or user-store changes. No other worktrees were touched and no subagents were used. No merge was performed.

## Tests and build

- Red first: whole-block Copy had RTF but no Markdown. `marquee/red-summary.json` records the failed expectation.
- Initial focused suite: 10 passed. Initial wider suite: 133 passed, 5 skipped, 0 failed (138 executed). See `focused-summary.json` and `suites-summary.json`.
- The first screen pass exposed a modern caret over block highlights and Tasks Backspace lacking row focus. Both were fixed and rechecked on screen.
- The new caret restoration test then failed because AppKit reported private insertion-indicator mode 100. A standalone unshown AppKit probe reproduced mode 100 immediately after setting `.automatic`. The fitter now preserves explicit hidden/visible modes and restores public automatic mode for private blink states. The assertion was retained and expanded to cover all three public modes. Failure evidence: `caret-restoration-red-summary.json`, `caret-private-mode-red-summary.json`.
- Caret-fix focused run: **15 passed, 0 skipped, 0 failed**: `MarqueeSelectionTests`, `MarqueeInteractionTests` and the existing `PhaseXCaretTests`. See `final-focused-summary.json`. Compiled with `SWIFT_STRICT_CONCURRENCY=complete`.
- Final Done-fix focused run: **16 passed, 0 skipped, 0 failed**, including a new unshown regression for archived and today’s Done rows. See `done-focused-summary.json`. The four hosted Done tests that failed in CI were then run locally under both required locks: **4 passed, 0 skipped, 0 failed**. See `done-hosted-summary.json`. No assertions or guards were weakened.
- Coverage includes threshold/reverse/inclusive intersection geometry, Shift addition, whole object blocks, discontiguous deletion, one-step Undo/Redo, rich-text/Markdown/private copy payloads, attachment identity through moves, read-only mutation refusal, symmetric/rate-independent/clamped auto-scroll, Tasks row-grab pass-through, batch commands, focus handoff on release, hidden-page input isolation and normal caret sizing/restoration.
- Wider suites: `NoteEditorEngineTests`, `NotesKeyboardUndoTests`, `NotesV2TablesFeatureTests`, `TasksRound10Tests`, `TasksDragOutTests`. Their final wider run had 133 passes, five skips and only the subsequently fixed caret regression failing; the final focused rerun is the verification of that repair. Five native-window-gated Notes tests were skipped, not passed. Three hosted Tasks tests were excluded locally: row menu, Cmd-D, and leaving-window drag-out. The CI keyboard gate exercised native focus separately.
- Strict local-only build passed. Final local analysis/build on `77fa1dcd` passed with `SWIFT_STRICT_CONCURRENCY=complete` (`xcodebuild analyze`, `ANALYZE SUCCEEDED`), covering the analyzer gate skipped by failed CI. Optimized preview build passed. All local xcodebuild invocations used the shared lock and this worktree's derived data. Project generation/check passed using the locked Homebrew Ruby/Bundler toolchain. Generated UUID churn accounts for the mechanical project-file diff.
- Read xcresults were moved to Trash. Derived data totals approximately 1.05 GB (814 MB test/build + 234 MB preview), below 3 GB.

## Screen verification

Screen access was held only under `/tmp/attic-screen.lock`. The permitted preview was launched with `ATTIC_UI_TESTING=1`, `ATTIC_UI_TEST_DISPLAY=external` and disposable structured/long fixtures, then quit by bundle ID before releasing the lock.

- Tasks: drag from empty space selected all three Later rows, rendered one merged shape and the existing batch bar, and focused the row nearest release. **Backspace deleted all three; one Cmd-Z restored all three.**
- Done: a normal row-body click selected its row; a marquee selected six completed tasks across day groups; **Backspace deleted all six and one Cmd-Z restored all six**. Captures: `done-before.png`, `done-selected.png`, `done-deleted.png`, `done-restored.png`; readback: `done-readback.txt`.
- Notes: drag from empty space selected eleven whole blocks, including checklist and styled paragraphs. **No caret appeared over the selection.** Esc cleared it, a text click showed the normal caret, and a separate plain click cleared a fresh block selection.
- Dragging those selected blocks moved them before the introduction while retaining content and styles. **One Cmd-Z restored the original order.** Notes deletion and one-step Undo also passed in the first screen pass.
- Final captures: `marquee/tasks-final-before.png`, `tasks-final-selected.png`, `tasks-final-deleted.png`; `notes-final-before.png`, `notes-final-selected.png`, `notes-final-caret-restored.png`, `notes-final-moved.png`, `notes-final-move-undone.png`. `notes-final-readback.txt` records the restored note. Earlier captures retain the initial findings. Before images mean unselected fixtures in the implementation preview, not a separately compiled base build.

Preview identities:

- Notes/Later capture build: branch `phase-x/marquee`, stamped `7234a111dc7005bebfb70319feaf6c9af2a4c0b0` plus the source changes subsequently committed as `03d41eb5`. The changed caret object was compiled after those edits.
- Final Done capture build: stamped `03d41eb573f63f53c79ec1000d6ff5cffeb31b19` plus the Done row-source change subsequently committed as `77fa1dcd`; no application source changed between this build and that commit. Same isolated app path/identity below.
- App `/Users/taha/Developer/attic-px-notes/.build/dd-preview/Build/Products/Local/AtticPhaseX.app`.
- Executable `Contents/MacOS/AtticPhaseX`; bundle `com.taha.Attic.preview.phasex`; display name `Attic Phase X`.
- Both optimized, no debug dylib. Notes/Later executable SHA-256 `8786c826e62489ae93e0d042a629480e14a5e30d03bc7a401c0ae69db4358739`; final Done build `0c24b24c4ab0e901b13ec5563b89c036ff792398c1e03e1fc14bdacd75da8665`.
- Ad-hoc signing, sandbox/network/user-selected file entitlements; no CloudKit/APNs. Appearance unchanged.

## Motion acceptance still open

`marquee/frames.log`, `frames-final.log` and `frames-done.log` contain the real marquee begin/end and `MarqueeDragFrames` counters, extracted without changes from the raw preview logs; unrelated component frame events are omitted. CUA's short gestures yielded zero or one sampled display frame; there is no usable inter-frame interval from which to assess dropped frames. **This is not evidence of zero dropped frames or perfect smoothness.** Sustained pointer tracking, live box/fade appearance and edge auto-scroll still need a timed screen pass. Auto-scroll maths and selection behavior are tested independently.

A bounded four-second event driver is prepared in `marquee/drive.swift`, restricted to the permitted bundle **and this worktree's exact app path**. Its synthesized-input mode was not run. The computer-use tool says, “Do not use other technologies besides cua_repl for computer interactions, unless specifically requested by the user”; the explicit request for that exception remains unanswered. No system setting or automation permission was changed.

## CI

Three sequential FKA runs passed, each with 8 focused native/unit keyboard tests, on `8553bd6c` (the Tasks focus implementation is unchanged by the later caret-mode fixes):

1. https://github.com/TesterPen0812/Attic/actions/runs/38124013641
2. https://github.com/TesterPen0812/Attic/actions/runs/38124337674
3. https://github.com/TesterPen0812/Attic/actions/runs/38124636423

Exactly one fast run was dispatched on application/test commit `03d41eb5`: https://github.com/TesterPen0812/Attic/actions/runs/38125390370 — failed. All 11 marquee tests passed in this run; it logged 2,540 passing cases before the unit step timed out. Five Notes key-window failures and the same timeout also occur on pinned-base run https://github.com/TesterPen0812/Attic/actions/runs/38104419843. Four additional Done interaction failures were new: the adapter used Now/Later rows on Done, so it treated rows as blank space. A cause-level fix now reads Done day groups, including archived and today's rows; the final `77fa1dcd` repair passed 16 focused tests and all four originally failing hosted tests locally, plus the Done screen check. The final repair has not had another whole fast-lane run, respecting the one-dispatch instruction. Static analysis and final-worktree gates were skipped after the interrupted unit result failed to produce a readable summary. Detailed comparison: `marquee/fast-triage.json`. No second fast dispatch was made. Machine-readable results: `marquee/ci.json`.

## Commits

- `8553bd6c` — Add whole-block and task-row marquee selection.
- `7234a111` — Preserve caret mode before collapsing block selection.
- `03d41eb5` — Restore public caret modes after block selection.
- `77fa1dcd` — Use Done day groups for marquee hit testing and selection.

All implementation commits are pushed to `phase-x/marquee`; no merge into the integration branch.
