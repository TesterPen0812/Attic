# Segment 5 live-test report - Attic Batch 2 post-fix candidate (b2fix2-ds3)

Date: 2026-09-16 (Europe/London; timestamps UTC). Scope: ONLY the two remaining open subchecks, T2 and T3.
Repo READ-ONLY; no rebuild; no commits. All UI via the cua_repl harness ("Computer Use").
Identity: no app self-report surfaced; harness-side docs identify the tool only. Treated as untrusted; harness config authoritative.

## Provenance (orchestrator-verified; re-checked only as specified)

- Bundle: /private/tmp/attic-b2fix2-ds3-dd/Build/Products/Local/AtticB2Fix2DSS3.app (bundle id com.taha.Attic.b2fix2.ds3.20260916).
  - executable sha256 = b1a11dd70170f8015fc88a780ec3fe31dd6e7948ea97f7b806b591b37ef4dd74 (re-hashed pre-launch: MATCH)
  - debug dylib sha256 = c01963b599d6e2d653aebbc1f8341708edd87931ae51c76cb415e3eb004a5ff3 (re-hashed pre-launch: MATCH)
- Launch via `open` 16:15:05 BST; PID 13672. PID->binary via lsof: txt inode 144152529 -> bundle executable; txt inode 144152523 ->
  bundle AtticB2Fix2DSS3.debug.dylib (same inodes recorded for this build in segment 3). PASS.
- Isolated store confirmed in lsof: ~/Library/Containers/com.taha.Attic.b2fix2.ds3.20260916/... (development.store-shm). Daily store not involved.
- Repo /Users/taha/Developer/attic-task-panels-v2 (read-only): HEAD ae6418c1af690e29d15a20344cdb9765a23d3f85; 191 dirty entries;
  before/after snapshot diff = REPO_UNCHANGED (repo-status-before-seg5.txt / repo-status-after-seg5.txt). No repo writes.
- Single-controller lock: acquired O_EXCL 15:15:04Z, owner=b2fix2-ds-seg5, pid 13667 (content verbatim: "owner=b2fix2-ds-seg5 pid=13667 acquired=2026-09-16T15:15:04Z");
  released via mv to /tmp/attic-native-ui.lock.released-b2fix2-ds-seg5; final LOCK_ABSENT.
- Screen: IOConsoleLocked = No at start; no lock occurred during the segment; no unlock attempted.
- Known coordinate fact relied upon (segment 4, pre-proven): app-target click Vec2 = window-local points; harness screenshots 1:1 with window points. No drags needed here.

## Budget (firm 10-minute active UI + 3-minute reserve)

- UI phase: first UI action 15:16:26Z (panel focus + Cmd+4 to Canvas section) -> last UI action ~15:24:10Z = ~7m45s active UI. Within budget; no silent overtime.
- Elapsed after each scenario: T3 block 15:22:39Z->15:23:00Z (~21s); T2 menu block 15:23:05Z->15:23:40Z (~35s); editor close 15:23:51Z->~15:24:10Z;
  preceding setup + the two T2 draft-creation attempts 15:16:26Z->15:22:39Z (~6m13s). Cleanup/report ran in the reserve (final verification 15:25:33Z).

## Scenario results

### T3 (typed-draft cmd+z / cmd+shift+z in a reopened editor) - PASS

Existing committed text object on canvas "seg4-fresh": canvas-object-D95822BF-8B5F-4171-BF60-6FED77E41F2A, text "gammax", center 60.7,-4,
(segment-store fixture; the scenario's example text was "gamma delta" - this store holds "gammax", so values are "gammax" -> "gammax x": identical structure).

1. Return on the selected object opened the editor (verbatim): "27 text entry area (settable) Description: Edit canvas text, Help: Type directly on the canvas.
   Command-Return saves; Escape cancels., Value: gammax"; toolbar "20 button (disabled) Description: Undo, ID: canvas-undo" and "21 button (disabled) Description: Redo, ID: canvas-redo"
   - both disabled in the fresh editor session (expected per-process stack semantics, per the segment-4 note). Focused element: 27.
2. typeText(" x") -> "27 ... Value: gammax x"; toolbar "20 button Description: Undo" ENABLED; "21 (disabled) Redo". PASS.
3. cmd+z (pressKey super+z) -> "27 ... Value: gammax" (exactly one step reverted; toolbar Undo DISABLED, Redo ENABLED). PASS - matches expectation verbatim.
4. cmd+shift+z (super+shift+z) -> "27 ... Value: gammax x" restored; toolbar Undo ENABLED, Redo DISABLED. PASS.

Throughout: canvas "seg4-fresh - 1 item"; same object ID, center unchanged (60.7,-4); object never removed. Full verbatim reads in seg5-ax-evidence.txt.

### T2 (Edit-menu draft undo/redo on a focused editor) - DEVIATION: plain menu items are DISABLED and never act on the draft

- Scripted draft creation (attempt 1, Add Text armed -> placement click -> typeText("gamma") -> typeText("x")) reached the live-draft state and it was confirmed (verbatim):
  "27 text entry area (settable) Description: Edit canvas text, ... Value: gammax"; canvas "0 strokes, 0 images, 0 text and shape objects", "Text placement"; toolbar Undo ENABLED.
  By the next observation the harness/app showed this draft already committed to a selected canvas object ("seg4-fresh - 1 item", object "gammax" selected, tool back to
  "Select Object", canvas-undo ENABLED) - i.e. the draft left the live-editor state between calls (harness interaction; recorded, no app-defect claim).
- Edit menu read (a) - committed object selected, canvas history non-empty (verbatim):
  "2 Undo Canvas Change, ID: menuAction:" (ENABLED), "3 (disabled) Redo Canvas Change", "4 (disabled) Undo, ID: undo:", "5 (disabled) Redo, ID: redo:",
  "8 Paste, ID: paste:" (enabled), Cut/Copy/Delete/Select All all disabled, AutoFill submenu items disabled, "(disabled) Start Dictation", "Emoji & Symbols". Menu title "Edit".
- Edit menu read (b) - LIVE focused draft (Value "gammax x" in the focused editor; toolbar Undo ENABLED / Redo DISABLED): identical items and states -
  "4 (disabled) Undo, ID: undo:" and "5 (disabled) Redo, ID: redo:" DISABLED; "Undo Canvas Change" ENABLED; "Redo Canvas Change" disabled; in this state Paste was also disabled.
- Therefore the T2 expectation - activate the PLAIN "Undo" -> the DRAFT reverts to "gamma"; then PLAIN "Redo" -> "gammax" restored - is NOT achievable through this route in this build:
  the plain items are disabled whenever observed, so no click is possible. Menu dismissed via Cancel; draft unchanged ("gammax x"); toolbar states unchanged after dismiss
  (canvas-undo ENABLED / canvas-redo DISABLED before and after); item count stayed 1; object not removed.
- Draft undo/redo itself is functional via the other routes: cmd+z/cmd+shift+z (T3 PASS) and the toolbar buttons (segments 2/T1). The canvas-level menu item is "Undo Canvas Change" (ID menuAction:).
- Exact wording recorded in both reads: "Undo Canvas Change", "Redo Canvas Change", "Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All", "AutoFill"
  (children "Contact...", "Passwords...", "Credit Card..."), "Start Dictation", "Emoji & Symbols".

## Harness / friction log (verbatim notes)

- Menu-stuck (known from segment 2): after an Edit-menu AX read the harness presented the menu tree into the next invocation; recovered with performSecondaryAction(0, "Cancel") on the menu root; no further blockage.
- One misindexed click: a click aimed at menu-bar "Edit" using the previous tree's index resolved against a shifted tree and hit toolbar "Fit Canvas" (zoom 100 -> 164 percent; observed as "~ 23 menu button Zoom 164 percent ... ID: canvas-zoom").
- Draft-commit-between-calls (2 occurrences; see T2): the live typed draft was found committed (or cleared, in attempt 2, with no new object) by the next observation. Recorded; mechanism not investigated.
- Editor close on a live draft required Escape twice (first Escape ignored - focus timing, same class as segment 2's note); second Escape closed the editor; committed text reverted to "gammax"; object stayed selected.
- Panel pin state changed during the session from unpinned ("Pin Attic panel") to pinned ("Unpin Attic panel") - same stray-click phenomenon as segment 2; no functional impact recorded.
- No tunnel failure ("Tunnel-client has not been seen for 300 seconds") and no "-10005 noWindowsAvailable" occurred in this segment.

## Cleanup (verified)

- App quit by exact bundle path: SIGTERM to PID 13672 (comm path-matched to .../AtticB2Fix2DSS3.app/Contents/MacOS/AtticB2Fix2DSS3).
  PROCESS_ABSENT: pgrep -fl 'Contents/MacOS/AtticB2Fix2DSS3' -> APP_PROCESS_ABSENT; pgrep -fl 'com.taha.Attic.b2fix2' -> NO_B2FIX2_PROCESSES.
  (A loose pgrep -f string also matched an unrelated external zsh watcher script that merely references the app name in its command line - not an Attic process.)
- Lock released via mv; LOCK_ABSENT verified.
- Repo: HEAD ae6418c1af690e29d15a20344cdb9765a23d3f85; 191 dirty entries; REPO_UNCHANGED.
- Daily (com.taha.Attic) and all user stores untouched (daily app not running: DAILY_ATTIC_NOT_RUNNING); all activity confined to the isolated preview container.
- Screen never locked; no auto-unlock attempted; no security/TCC changes; no commits/pushes/merges/releases.
- Preview-store side effects (expected from testing, preview store only): canvas "seg4-fresh" holds the committed text object "gammax" created during the T2 draft flow; canvas zoom left at 164 percent; panel pin toggled to pinned.

## Evidence

- Inline screenshots emitted during the run: (1) pre-T2 state - "seg4-fresh - 0 items", toolbar Undo/Redo disabled, empty canvas; (2) post-draft - "seg4-fresh - 1 item", committed "gammax" object selected with handles, canvas Undo enabled.
  No screenshot is possible while a menu is presented (harness limitation, as in segment 2); AX reads used instead (menus recorded verbatim).
- Verbatim AX evidence per step: /tmp/attic-b2fix2-ds/seg5-ax-evidence.txt
- Repo snapshots: /tmp/attic-b2fix2-ds/repo-status-before-seg5.txt / repo-status-after-seg5.txt
- This report: /tmp/attic-b2fix2-ds/report-seg5.md ; marker: /tmp/attic-b2fix2-ds/seg5-complete.marker

## Limitations / honestly unverified

- T2's expected path (clicking plain Undo/Redo) could not be executed because both items are disabled; the deviation is based on two independent menu reads here (live draft; committed-object) plus segment 2's three earlier reads (all consistent).
- T3 used the fixture existing on this preview store ("gammax"), so "gammax x" stands in for the example "gamma delta x"; the append/undo/redo structure is identical.
- Draft-commit-between-calls is a recorded harness interaction observation; no mechanism conclusion.
- No claims about other builds, stores, or environments.
