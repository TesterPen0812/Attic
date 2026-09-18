# Segment 4 live-test report - Attic Batch 2 post-fix candidate (b2fix2-ds3)

Date: 2026-09-16 (Europe/London). Active UI window: 15:51:18 -> 16:08:42 = 17m24s (within the firm 20-minute UI budget; reporting done under the reserve).
No rebuild, no repo writes, no commits. All UI via cua_repl harness.

## Candidate + provenance (orchestrator-verified inputs re-checked only where specified)

- Bundle: /private/tmp/attic-b2fix2-ds3-dd/Build/Products/Local/AtticB2Fix2DSS3.app (bundle id com.taha.Attic.b2fix2.ds3.20260916).
  - executable sha256 = b1a11dd70170f8015fc88a780ec3fe31dd6e7948ea97f7b806b591b37ef4dd74 (pre + post: match)
  - debug dylib sha256 = c01963b599d6e2d653aebbc1f8341708edd87931ae51c76cb415e3eb004a5ff3 (pre + post: match)
- PID->binary mapping (lsof, both runs): run1 PID 83085, run2 PID 94729, both txt-mapped to the bundle's AtticB2Fix2DSS3 executable + debug dylib above.
- Repo /Users/taha/Developer/attic-task-panels-v2 (read-only): HEAD ae6418c1af690e29d15a20344cdb9765a23d3f85; 191 dirty entries. Snapshot diff before/after = REPO_UNCHANGED (files: repo-status-before-seg4.txt / repo-status-after-seg4.txt).
- Fixtures (pre + post, unchanged): /tmp/attic-b2trial-corrupt.png = 400550e9a647b49b1ba4e3517f5456a97d35f18a1cbc410771b6254cfb612162; /tmp/attic-b2fix2-ds/valid-fixture-s3.png = fc4a82118b689607dd463efb3b3ca6c2864c2e59c4c2d6a9dd596723529f0144.
- Single-controller lock: acquired O_EXCL owner=b2fix2-ds-seg4; released by mv to /tmp/attic-native-ui.lock.released-b2fix2-ds-seg4 then .released-b2fix2-ds-seg4-final; final LOCK_ABSENT.
- Self-reported identity: none surfaced from the app; harness-side docs identify the tool only ("Computer Use"). Treated as untrusted; harness config authoritative.
- Screen-lock: not locked (window screenshots + AX reads throughout; no unlock attempted).

## Harness/coordinate findings (needed to reproduce)

- App-target click/drag Vec2 = WINDOW-LOCAL points (proven by harness error "windowNotFoundAtPosition((3090,290))" for input (1628,245) with window origin (1462,45)).
- Window geometry (CGWindowList): origin (1462,45), size 332x476 pt. Harness screenshots = 332x476 JPEG (1:1 with window points). screencapture -x -o -l <id> = 664x952 (2x); divide by 2 for window-local points.
- Precise handle/pixel measurement used /tmp/attic-b2fix2-ds/measure_bright.py (BMP cluster analysis via sips conversion).

## Scenario results

### T1 - PASS (secondary; run last, after S5/S6)
1. Committed text "gamma" on the existing canvas: Canvas 3 items, new object canvas-object-2F4BB2B6-66B8-46BA-87B4-1CF8E2ABA655 selected; toolbar Undo became ENABLED (history non-empty).
2. Fresh editor via Canvas menu ("Canvas menu" > "New Canvas", named "seg4-fresh"): header "seg4-fresh - 0 items"; toolbar Undo (canvas-undo) DISABLED; Redo DISABLED; canvas "0 strokes, 0 images, 0 text and shape objects".
3. Clicked the disabled toolbar Undo anyway (harness click on element 14 = canvas-undo): "no error"; AX read-back: "There has been no change in the accessibility tree"; full re-read identical (0 items, Undo disabled, Redo disabled, empty canvas, no selection change). No throw, no refusal - the disabled control simply did nothing anywhere.
   - Also observed (fresh-process semantics): after relaunch on the persisted 2-item canvas, toolbar Undo/Redo were disabled until an edit - history is per-process/per-document, not persisted.

### T2 - NOT RUN (budget)
Not attempted. The 20-minute active-UI budget was consumed by the required scenarios (S5, S6) plus T1; remaining time (~2m30s at stop) was insufficient for a reliable draft-undo/redo run with verification. No evidence claimed either way.

### T3 - NOT RUN (budget)
Same as T2.

### T4 (S5 resize) - pointer routes NOT ACHIEVED; labeled AX functional proxy ACHIEVED

Object under test: text object "resize" (canvas-object-2BD54969-9B90-4CC7-9C0D-4F4A44A62D58), selected; selection box measured from screenshots: 166.0 x 47.5 pt; visible "handles" = exactly 4 white corner circles (bbox ~10.5 pt); NO edge/mid handles rendered; glyphs occupy only 57.5 x 12 pt inside the box.

(a) Pointer drags via app.drag (attic.drag), all recorded verbatim:
- app.drag([155.8,189.8],[115.8,159.8]) from TL handle center -> err null; object DESELECTED; box size unchanged (166.0 x 47.5).
- app.drag([95.8,267.8],[135.8,287.8]) from TL handle center (re-measured post-move) -> err null; deselected; size unchanged.
- app.drag([261.8,315.8],[221.8,285.8]) from BR handle center -> err null; deselected; size unchanged.
- Plain click at BR handle center [261.8,315.8] -> deselected (background-click behavior).
- Control proving drags reach the app: app.drag([238.6,213.8],[178.6,183.8]) starting INSIDE the object -> err null; object moved exactly (-60,-30) in canvas coords (AX center 73,-24 -> 13,-54).
- Interpretation (no unavailability/defect claim): corner-circle presses hit-tested as canvas background for this text object in this build; the pointer route did not initiate resize in these 4 interactions. An edge-handle variant was not possible - none is rendered.

(b) Positional-array fallback, recorded verbatim:
- cua.computer.drag([98,200],[78,180]) -> REJECTED: "Computer Use app approval requires app to be a plain data property". globalThis.computer does not exist in this session. Harness-level rejection; events never reached the screen.

(c) Labeled functional proxy (NOT pointer-drag) - ACHIEVED:
- performSecondaryAction(20, "Make larger") on selected object -> err null. Measured frame 166.0 x 47.5 -> 182.5 x 51.4 pt (+~10%, symmetrical about center); AX center unchanged (13,-54).
- One undo (Cmd+Z): frame restored EXACTLY to 166.0 x 47.5 pt at the same coordinates (AX: Redo button became enabled).
- Secondary actions exposed by the object verbatim: Delete, Select, Move left, Move right, Move up, Move down, Make smaller, Make larger, Edit text, Send backward/Bring forward, Delete.
- Extra observation (untouched): the imported image object exposes size in AX directly ("160 by 160, center 0, 0") and the same Make smaller/larger actions.
- S5 composite: resize semantics verified via AX proxy with before/after/undo; pointer-drag route not achieved (a/b above). NOT ACHIEVED via pointer; NOT claiming tool unavailability or app defect.

### T5 (S6 recovery) - PASS
Route: Canvas menu > "Import Image...". Recents list (iCloud) contained no /tmp entries, so the first (corrupt) import used GoTo (Cmd+Shift+G; allowed - the no-GoTo constraint applied to the retry import).

- Corrupt import (/tmp/attic-b2trial-corrupt.png): panel auto-selected the file after Return; "Open" enabled; clicked.
  Banner verbatim: "Import complete 1/1" + scroll row "Image 1: The dropped item is not a supported image or is corrupt." + button "Choose Failed Files Again..."; a duplicate surface text (ID panel-error-message) shows "The dropped item is not a supported image or is corrupt." with a dismiss button. Canvas stayed "1 item" (no partial add).
- Retry affordance: clicked "Choose Failed Files Again..." -> Open panel reopened in /tmp ("Where: tmp") with the /tmp rows (recents-style grid: attic-b2fix2-ds folder, attic-b2trial-corrupt.png, etc.).
- Valid import via recents-row route (no GoTo): opened the "attic-b2fix2-ds" folder row (AX secondary action "open"), scrolled the grid to the bottom, then activated "valid-fixture-s3.png" via the row's own AX "open" action (a same-coordinate row click had missed: "cannotClickOffscreenElement" pre-scroll, silent no-op post-scroll with Open still disabled - both recorded).
  Result: panel closed; canvas "2 items"; new object canvas-image-ECE6A5E7-CD05-4812-8645-C010B1A084EB, Details "160 by 160, center 0, 0", selected; banner now "Import complete 1/1" with NO failure rows (cleared).
- Friction log (verbatim): harness guard aborts "The user changed '<bundle path>'. Re-query the latest state with get_app_state before sending more actions." (3x; cleared by re-binding cua.getApp); "Computer Use server error -10005: noWindowsAvailable" (2x, transient, cleared on next probe); "cannotClickOffscreenElement" (1x, above).

## Cleanup (verified)

- App quit by exact bundle path after PID/path match (SIGTERM): PROCESS_ABSENT.
- No stray processes matching attic-b2fix2/AtticB2Fix2 (NO_STRAY_PROCESSES).
- Fixtures re-hashed post-run: both match pre-run values.
- Repo HEAD + dirty entries unchanged (REPO_UNCHANGED); no repo writes performed.
- Lock released via mv; LOCK_ABSENT.
- Daily (com.taha.Attic) and user stores: untouched. All activity confined to the isolated preview app (its own container/store, which now holds the test canvases "Canvas" (3 items incl. committed "gamma") and "seg4-fresh" (0 items) - preview-store data, expected from the test).

## Evidence files (all under /tmp/attic-b2fix2-ds/)

- seg4-win.png/.bmp - T4 pre-drag selection measurement (handles at (155.8,189.8)/(321.4,189.8)/(155.8,237.8)/(321.4,237.8))
- seg4-win3.png/.bmp - T4 post-drag measurement (box unchanged, 166.0 x 47.5)
- seg4-t4c-before.png/.bmp, seg4-t4c-after.png/.bmp, seg4-t4c-undo.png/.bmp - AX resize proxy before/after/undo (166.0x47.5 -> 182.5x51.4 -> 166.0x47.5, frame corners at (95.8,267.8)-(261.8,315.3))
- measure_bright.py, repo-status-before-seg4.txt, repo-status-after-seg4.txt

## Limitations / boundaries

- T2/T3 not run (budget): no claim either way on draft undo/redo via app Edit menu.
- T4 pointer-route failure is scoped to the observed object/method/build; no app-defect or tool-unavailability claim is made.
- Harness acted intermittently (guard aborts requiring re-bind; two transient noWindowsAvailable) - UI timing measured 15:51:18->16:08:42 total.
- No commits, pushes, merges, releases, security/TCC changes, or auto-unlock attempts; screen was never locked.
