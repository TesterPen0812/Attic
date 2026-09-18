# Attic B2 closeout — live-tester SEGMENT 2 report

Self-reported identity: deepseek-v4.1-flash via ollama-cloud proxy, effort max (recorded harness config).
This identity is self-reported and must be checked against harness metadata; it is not trusted.
Date: 2026-09-16 (Europe/London). All timestamps UTC. Repo was treated read-only; no repo writes occurred.

## Provenance
- Lock /tmp/attic-native-ui.lock: acquired 13:27:22Z (O_EXCL, owner=b2fix2-ds-seg2, pid 41821).
  Released 13:41:23Z; re-acquired 13:41:52Z (pid 59329, phase seg2-resume); released 13:45:24Z;
  re-acquired 13:46:00Z (phase seg2-resume2); released 13:47:37Z. Final state: LOCK_ABSENT.
- Repo: /Users/taha/Developer/attic-task-panels-v2; branch codex/attic-task-panels-v2;
  HEAD ae6418c1af690e29d15a20344cdb9765a23d3f85; dirty entries 191.
- Source freeze hashes checked 13:27:22Z — ALL 7 MATCH the POST-FIX expectations:
  9c19f2e426d665fc5b18523247285d2865a3c1da7cbf0d8985b5dc963bd4c2ba  Attic/App/CanvasEditCommandRoute.swift
  0da5cc84d5a13bb0a8be8d9c4465a799180e4cb002d8bffdc5fe493f518fcd94  Attic/Canvas/CanvasSemanticInteraction.swift
  b1fa3d8f3a5e9771811bdfaf37a19499554309ed8a9b1f25025da201c8f624e6  Attic/Canvas/CanvasSurfaceMac.swift
  467505742dbff69b70a317b9f013408cd3f362dfb0405671fe5982139d2a3e84  Attic/Canvas/CanvasSession.swift
  84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8  Attic/Views/Panel/CanvasPanelContent.swift
  a4386aff8b9ff2bd6accf8f11aeadc4e16d33dc51f6a78ca4eff9adb40e00db5  AtticTests/CanvasDomainTests.swift
  f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd  AtticTests/CanvasSessionTests.swift
- Launch 1: start 13:27:32Z; PID 42052; launch verified 13:28:03Z; --verify 13:28:11Z; quit 13:41:23Z.
- Launch 2: start 13:41:52Z; PID 59439; verified 13:42:03Z; quit 13:45:24Z.
- Launch 3: start 13:46:00Z; PID 61817; verified 13:46:08Z; quit 13:47:37Z.
- Every launch: executable sha256 72f0b62af2eb600b7e32a0398c1e97e2f84175e206ca10f121f0533dca57000f;
  debug dylib e1390a23751c907bcfe1fb89f2d3f1d9947835453984bf37de72900f2fcda332;
  bundle com.taha.Attic.b2fix2.ds.20260916; appearance dark; derived data /tmp/attic-b2fix2-ds-dd.
- Fixtures: corrupt /tmp/attic-b2trial-corrupt.png 96 bytes,
  sha256 400550e9a647b49b1ba4e3517f5456a97d35f18a1cbc410771b6254cfb612162 — verified untouched at start and end.
  Valid /tmp/attic-b2fix2-ds/valid-fixture.png created 13:27:5xZ, 160x160,
  sha256 fc4a82118b689607dd463efb3b3ca6c2864c2e59c4c2d6a9dd596723529f0144 (staged; unused — S6 not run).
- Output dir /tmp/attic-b2fix2-ds/ only. screenshots/ exists but is EMPTY (no disk persistence attempted).

## Budget
- Firm 20-minute active-UI segment, from first UI action 13:28:20Z (cua.getApp).
  Phase 1 UI 13:28:20Z–13:41:1xZ (~12.9 min); Phase 2 UI 13:42:05Z–13:45:1xZ (~3.2 min);
  Phase 3 UI 13:46:1xZ–13:47:2xZ (~1.3 min). Total active UI ~17.4 min (within budget; ~2.5 min unspent).
- Cleanup + report executed in the 3-minute reserve after the final UI action (quits 13:41:23Z / 13:45:24Z / 13:47:37Z).
- No screen lock occurred. No tunnel-failure ("Tunnel-client has not been seen") occurred.

## Scenario outcomes

### S1 D1-changed-behavior recheck — PASS (core), 3 sub-items unverified
Committed text object via Add Text: "gamma" (object EA3BBBB7-F3AB-4AC8-A618-CACFEE85639A, center -1232,-104), ~13:34:40Z.
- Fresh editor (click canvas + Tab + Return), first session ~13:35:10Z: toolbar canvas-undo DISABLED while canvas history
  existed (canvas-undo was ENABLED immediately before in canvas context). Re-confirmed in a second fresh editor ~13:40:20Z.
- App Edit menu (opened via AX element click on menu-bar "Edit") while fresh editor focused, ~13:35:30Z — verbatim items:
  "Undo Canvas Change (disabled)", "Redo Canvas Change (disabled)", "Undo (disabled)", "Redo (disabled)",
  Cut/Copy/Paste/Delete/Select All (all disabled), AutoFill, Start Dictation (disabled), Emoji & Symbols.
  (Screenshot unavailable while the Edit menu is presented — harness "Screenshot unavailable for <app>"; recorded.)
- After Escape cancelled the editor (~13:36:20Z), the same menu revalidated: "Undo Canvas Change" ENABLED,
  plain "Undo"/"Redo" still disabled — canvas history exists but is not the editor's stack; plain items not left enabled
  in canvas context. (Read was post-Escape-cancel, not post-commit — noted.)
- Typing one character in the reopened editor (~13:40:40Z): draft "gamma" -> "gammax"; toolbar Undo became ENABLED. PASS.
- Toolbar Undo click with draft open (~13:41:00Z): draft reverted "gammax" -> "gamma"; toolbar Undo disabled;
  toolbar Redo enabled; text object REMAINED (no canvas-undo removal, no draft discard). PASS.
- Toolbar Redo click (~13:41:10Z): draft "gammax" restored; Undo enabled; Redo disabled. PASS.
- Cmd+Return commit (~13:41:15Z): object text "gammax", editor closed, object selected.
- Exactly-one-entry check: cmd+z with editor closed (~13:41:1xZ): text back to "gamma", object INTACT. PASS
  (one undo restored pre-edit text -> the edit was exactly one history entry).
- UNVERIFIED sub-items: (a) clicking the DISABLED toolbar Undo in the fresh-editor state (inert-click recording) — not performed;
  (b) app Edit menu PLAIN Undo acting on a focused editor with a typed draft (only the disabled state in an empty editor was read);
  (c) a literal "Add menu" was NOT FOUND — no menu titled/described "Add" exists in the Canvas panel AX or the app menu bar
  (AtticB2Fix2DS / Edit / View / Window / Help). An "add"-labelled menu button exists only in the Tasks section
  (ID: add-task-button); it was not opened. The closest verified match is the Edit menu carrying both
  Undo/Redo Canvas Change and plain Undo/Redo (states above).

### S2 Reopened-editor undo/redo (TK2 check) — DEVIATION from expected; recorded verbatim
Phase 3 (~13:46:2xZ-13:47:2xZ), on committed object "gamma":
- Tab selected gamma; Return opened editor (Value: gamma). Typed " delta" -> Value "gamma delta"; toolbar Undo ENABLED. PASS.
- Cmd+Return commit -> object "gamma delta" (same object ID, selected). PASS.
- Return reopened the editor -> Value "gamma delta"; toolbar Undo DISABLED (fresh editor stack). PASS.
- cmd+z in the reopened, unmodified draft: NO CHANGE — "There has been no change in the accessibility tree";
  draft stayed "gamma delta"; toolbar Undo stayed DISABLED; toolbar Redo stayed DISABLED; the other object
  (draft-one) unchanged; item count stayed 2. The scenario expectation ("draft reverts; Undo renders disabled; Redo live")
  was NOT observed. Flagged as expectation mismatch / possible remaining gap for orchestrator review (could also be my
  sequencing; the observed behavior is: cmd+z is inert in a reopened unmodified editor and the canvas history is not consumed).

### S3 Keyboard canvas-history after commit (editor closed) — PASS
- cmd+z with editor closed (~13:41:05Z, phase 1): reverted the text edit "gammax" -> "gamma", object intact.
- cmd+z again (~13:41:12Z): "Canvas · 0 items" — object removed, toolbar Undo DISABLED, selection cleared (1 -> 0).
- cmd+shift+z (~13:41:18Z): "Canvas · 1 item" — gamma restored and selected, toolbar Undo enabled (0 -> 1).
  One history entry per change; toolbar states matched each leg. PASS.

### S4 Insertion-spawn path — PASS (deviation: canvas not blank)
Phase 2, fresh process (history empty; toolbar Undo+Redo disabled) but the persisted document reloaded with 1 object
("gamma") — history is session-local, documents persist.
- Armed Add Text (selected), placed via coordinate click [120,230], typed "draft-one":
  toolbar Undo ENABLED during the draft (D2 behavior preserved). ~13:44:0xZ.
- Toolbar Undo click: editor emptied, toolbar Undo DISABLED, toolbar Redo ENABLED, no object spawned
  (item count unchanged) — draft reverted on the insertion path. ~13:44:2xZ. PASS.
- cmd+shift+z: draft restored "draft-one"; Undo enabled; Redo disabled. ~13:44:4xZ.
- Cmd+Return commit: "Canvas · 2 items"; exactly one new object added (9F0543E6-D353-4B2A-AC4F-645AE0D8F59B,
  selected). ~13:45:0xZ. PASS.

### S5 Pointer-drag text resize — NOT ACHIEVED
- Selected draft-one; screenshot located 4 corner handles at ~ (98,200) TL, (293,200) TR, (98,245) BL, (293,245) BR
  in the 302x428 panel image. ~13:46:3xZ.
- app.drag([98,200] -> [78,180]) (top-left handle, outward 20px): ACCEPTED (no error thrown) but behaved as
  click-to-deselect: object center unchanged (-1308, 8), size visually unchanged, selection cleared. ~13:46:5xZ.
- cua.computer.drag attempts, verbatim:
  1. cua.computer.drag(app, [98,200], [78,180]) -> REJECTED: "Computer Use app approval requires app to be a plain data property"
  2. cua.computer.drag({target: app, from: [98,200], to: [78,180]}) -> REJECTED: same message
  3. cua.computer.drag({app: "com.taha.Attic.b2fix2.ds.20260916", from: [98,200], to: [78,180]})
     -> REJECTED: "from must include finite x and y coordinates"
  4. cua.computer.drag({app: "com.taha.Attic.b2fix2.ds.20260916", from: {x:98,y:200}, to: {x:78,y:180}})
     -> REJECTED: "from must include finite x and y coordinates"
- After attempt 1, reselect via click [160,225] verified (draft-one selected again, center unchanged).
- Resize undo semantics untested (no resize achieved). NOT ACHIEVED (not declared unavailable).

### S6 Image recovery completion — NOT RUN (budget)
Valid fixture staged; corrupt fixture verified untouched; the failure-banner retry flow was not exercised this segment.

## Screenshots (inline emissions only; no disk persistence, no hashes)
1. ~13:28:5xZ — Tasks panel after Settings close (route state).
2. ~13:30:2xZ — Canvas initial: 0 items, Undo/Redo disabled.
3. ~13:33:5xZ — Canvas armed "Text placement" (0 items, hint chip).
4. ~13:34:0xZ — Canvas after stroke undo (0 items; Redo enabled).
5. ~13:41:1xZ — Canvas: "gammax" committed, selected, handles visible (1 item).
6. ~13:46:3xZ — Canvas 2 items (gamma + draft-one selected, 4 handles visible).
7. ~13:46:5xZ — Canvas after failed drag (draft-one deselected, unchanged).
No screenshot of the 0-item post-undo state and none while the Edit menu was open (harness unavailable).

## Tool-call accounting
- cua_repl calls: 48 across the three phases (single getApp attaches, 42 action/observation calls, 5 diagnostics).
- Shell (exec) calls: 8 (preflight lock+hashes, launch, --verify, clock/pgrep anchor, relaunch x2, cleanup x2, report+marker).
- Screenshot attempts: 9; emitted: 7; refused while Edit menu presented: 2.

## Interaction / friction log
- 4x transient harness error "Computer Use server error -10005: noWindowsAvailable"
  (approx 13:29:10Z, 13:30:40Z, 13:31:00Z, 13:38:00Z). All recovered on retry (<=800 ms) except during the stuck-menu period.
  Not the known tunnel failure mode.
- Element-index clicks on the transient panel window fail fast (-10005) or after re-index ("22 is an invalid element ID");
  IDs shift after most state changes, so indices must be re-derived from the latest diff. Coordinate clicks deliver real
  mouse events at ~panel-relative 1:1 (pen dot drawn at click; editor placed at click point). Element clicks on toolbar
  buttons and menu-bar items work with retry. performSecondaryAction("Delete") not needed; "Cancel" used on the menu root.
- Menu-stuck incident: after reading the Edit menu (~13:35:30Z) the harness kept presenting the menu tree as the app UI;
  Escape x2 and canvas coordinate clicks did not dismiss it; the panel became unresolvable for stretches and
  getScreenshot returned "Screenshot unavailable for <app>". Recovery: performSecondaryAction(0, "Cancel") on the menu root
  restored the panel (~13:39:30Z).
- Panel pin state changed from unpinned ("Pin Attic panel") to pinned ("Unpin Attic panel") during phase 1
  (between ~13:30Z and ~13:39Z); cause not tracked (likely a stray coordinate click on the pin-button region). No functional
  impact observed; relaunches showed unpinned again.
- "Return edits text" requires the panel to hold keyboard focus; the first Return after the menu incident was ignored
  (no change) until a canvas click re-established focus.
- Panel auto-hides on Escape/focus loss when unpinned (observed as noWindowsAvailable windows); pinning was not performed
  deliberately.

## Honestly-unverified
- S1 (a) disabled-Undo inert click; (b) Edit>plain-Undo acting on a focused editor; (c) "Add-menu" identification
  (Tasks add menu and canvas document menu contents not enumerated).
- S2 as scripted (expectation mismatch recorded above); redo leg of the reopened-draft flow.
- S5 resize (no mechanism accepted); resize undo semantics.
- S6 entire flow.
- Screenshots: inline only; no disk copies or hashes. Post-commit Edit-menu re-read (only post-Escape read obtained).

## Continuation list (next segment)
1. S1 sub-items: click disabled toolbar Undo in fresh editor (record inertness shape); open Edit menu while a focused editor
   has a typed draft and activate plain Undo; enumerate the Tasks "add" menu (add-task-button) and canvas-document-menu
   contents to settle the "Add-menu Edit>Undo" item.
2. S2: disambiguate the reopened-editor cmd+z expectation (typed-draft cmd+z vs unmodified-draft cmd+z); verify Redo-live leg.
3. S5: resolve a working drag mechanism (app.drag deselects; cua.computer.drag accepts {app, from, to} shape but rejects both
   [x,y] and {x,y} for from) or use object Secondary Actions ("Make larger"/"Make smaller") as a labeled functional proxy,
   then resize-undo semantics.
4. S6: corrupt-fixture import -> failure banner + "Choose Failed Files Again..." -> retry -> valid fixture import
   (valid fixture staged at /tmp/attic-b2fix2-ds/valid-fixture.png).
5. Optional: screenshot disk persistence via base64 route if budget allows.

## Cleanup evidence
- Launch 1 quit 13:41:23Z (graceful by exact bundle path), NO_PROCESS_LEFT; lock released; LOCK_ABSENT.
- Launch 2 quit 13:45:24Z, NO_PROCESS_LEFT; lock released; LOCK_ABSENT.
- Launch 3 quit 13:47:37Z, NO_PROCESS_LEFT; lock released FINAL; LOCK_ABSENT.
- Corrupt fixture re-hashed 13:47:37Z: 400550e9a647b49b1ba4e3517f5456a97d35f18a1cbc410771b6254cfb612162 (unchanged).
- No canvases deleted; the session canvas was created by this tester inside the isolated preview store only;
  Daily store (com.taha.Attic) untouched; Agent Access/MCP untouched; no commits/pushes; no security/permission changes.
