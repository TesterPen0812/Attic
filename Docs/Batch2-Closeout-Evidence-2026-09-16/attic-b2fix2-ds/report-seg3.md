# Attic B2 closeout — live-tester SEGMENT 3 report

Self-reported identity: deepseek-v4.1-flash via ollama-cloud proxy, effort max (recorded harness config).
This identity is self-reported and must be checked against harness metadata; it is not trusted.
Date: 2026-09-16 (Europe/London). All timestamps UTC. Repo was treated read-only; no repo writes occurred.

## Provenance
- Lock /tmp/attic-native-ui.lock: acquired 13:51:38Z (O_EXCL, owner=b2fix2-ds-seg3, pid 65337).
  Released ~13:53:55Z via mv to /tmp/attic-native-ui.lock.released-b2fix2-ds-seg3. Final state: LOCK_ABSENT.
- Repo: /Users/taha/Developer/attic-task-panels-v2; branch codex/attic-task-panels-v2;
  HEAD ae6418c1af690e29d15a20344cdb9765a23d3f85; dirty entries 191 (checked at start 13:51:3xZ and end ~13:53:55Z — unchanged).
- Source freeze hashes checked 13:51:3xZ — ALL 7 MATCH the segment-2 post-fix expectations:
  9c19f2e426d665fc5b18523247285d2865a3c1da7cbf0d8985b5dc963bd4c2ba  Attic/App/CanvasEditCommandRoute.swift
  0da5cc84d5a13bb0a8be8d9c4465a799180e4cb002d8bffdc5fe493f518fcd94  Attic/Canvas/CanvasSemanticInteraction.swift
  b1fa3d8f3a5e9771811bdfaf37a19499554309ed8a9b1f25025da201c8f624e6  Attic/Canvas/CanvasSurfaceMac.swift
  467505742dbff69b70a317b9f013408cd3f362dfb0405671fe5982139d2a3e84  Attic/Canvas/CanvasSession.swift
  84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8  Attic/Views/Panel/CanvasPanelContent.swift
  a4386aff8b9ff2bd6accf8f11aeadc4e16d33dc51f6a78ca4eff9adb40e00db5  AtticTests/CanvasDomainTests.swift
  f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd  AtticTests/CanvasSessionTests.swift
- Launch: start ~13:51:5xZ; PID 66018 (app started 13:52:21Z); launch verified 13:52:30Z; direct PID-to-binary re-verify 13:52:52Z
  (lsof inode 144152529 -> executable sha256 b1a11dd70170f8015fc88a780ec3fe31dd6e7948ea97f7b806b591b37ef4dd74;
  debug dylib inode 144152523 -> c01963b599d6e2d653aebbc1f8341708edd87931ae51c76cb415e3eb004a5ff3).
  Bundle com.taha.Attic.b2fix2.ds3.20260916; executable name AtticB2Fix2DSS3; appearance dark; derived data /tmp/attic-b2fix2-ds3-dd.
  The executable sha256 differs from segment 2's (72f0b62a...) because the executable name and bundle/derived-data path differ;
  the 7 frozen source inputs are identical (hashes above) and launch provenance recorded the same dirty tree at the same HEAD.
- Fixtures: corrupt /tmp/attic-b2trial-corrupt.png sha256 400550e9a647b49b1ba4e3517f5456a97d35f18a1cbc410771b6254cfb612162
  verified untouched at start (13:51:3xZ) and end (~13:53:55Z). Valid /tmp/attic-b2fix2-ds/valid-fixture.png
  sha256 fc4a82118b689607dd463efb3b3ca6c2864c2e59c4c2d6a9dd596723529f0144 verified; copy
  /tmp/attic-b2fix2-ds/valid-fixture-s3.png created 13:51:4xZ with identical sha256 (staged; unused — no scenario reached import).
- Output dir /tmp/attic-b2fix2-ds/ only. No /tmp/attic-b2fix2-ds/screenshots/seg3-* files created.

## Budget
- Firm 20-minute active-UI budget. UI phase began at first UI action ~13:52:55Z (cua.getApp) and ENDED IMMEDIATELY ~13:53:1xZ
  when the harness reported the Mac locked (the harness's automatic unlock attempt failed). Active UI used: ~15-20 seconds.
  Remaining time reverted to the checkpoint list per protocol (screen lock => UI ends immediately; no auto-unlock).
- No scenario action was ever reached; no screenshots were obtainable during the lock.
- Cleanup + report executed after the terminal lock condition (within the 3-minute reserve by protocol).

## Terminal blocker (verbatim evidence)
1. ~13:52:55Z cua.getApp("Attic B2 Fix2 DS S3 20260916") -> "Invalid app: Attic B2 Fix2 DS S3 20260916"
   (display-name resolution failed while the app WAS running as PID 66018 per ps/lsof re-check at 13:52:52Z).
2. ~13:53:1xZ cua.listApps(...) -> verbatim: "The Mac is locked and automatic unlock could not unlock it. Ask the user to
   unlock the Mac manually before continuing."
3. 13:53:48Z corroboration via shell: ioreg Root -> IOConsoleLocked: true.
Per protocol, the screen lock ended the UI phase immediately; no auto-unlock was attempted. No retries were made against the
lock state (a lock is not an interaction to retry; retry cap respected). The lock's exact onset (before or after launch) is not
retrospectively establishable from these logs; the 13:53:48Z read is direct current-state evidence only.

## Scenario outcomes
All five scenarios BLOCKED-BEFORE-START by the terminal screen-lock condition. The only CUA calls made were the two above;
nothing was clicked, typed, dragged, or read inside the app.

### T1 D1 sub-item (a): click DISABLED toolbar Undo in a fresh editor over non-empty history — UNVERIFIED (blocked)
### T2 D1 sub-item (b): app Edit menu PLAIN Undo/Redo acting on a focused editor holding a draft — UNVERIFIED (blocked)
### T3 S2 disambiguation: reopened editor, typed draft, cmd+z / cmd+shift+z — UNVERIFIED (blocked)
### T4 S5 resize two routes (pointer drag; AX resize-like secondary actions) — UNVERIFIED (blocked)
### T5 S6 corrupt->retry->valid image recovery — UNVERIFIED (blocked)

## Screenshots
- None. The screen was locked before any scenario action; the one state request the harness served returned the lock message.
  No inline screenshots were emitted and no seg3 screenshots were written to disk.

## Tool-call accounting
- cua_repl calls: 2 (1 getApp attach attempt -> "Invalid app"; 1 listApps -> lock message). No other CUA calls.
- Shell: 12 exec_command calls + 1 write_stdin poll of the launch session (preflight, hashes, launch x2, PID re-verify,
  lock corroboration, cleanup, integrity re-checks, seg2 report read for structure, stray-process check).
- Screenshot attempts: 0; emitted: 0; disk-persisted: 0.

## Interaction / friction log
- The display-name resolution failure occurred while the app was confirmed running (PID 66018, started 13:52:21Z,
  re-verified 13:52:52Z); it is not attributable to a failed launch or to the launch script's provenance chain.
- No tunnel failure ("Tunnel-client has not been seen...") occurred; launch -> verify chain was healthy.
- Nothing else was attempted in the UI after the lock message (protocol: UI ends immediately; no auto-unlock).

## Honestly-unverified
- Everything in T1-T5. No behavior of the revised candidate (post-fix Canvas undo/redo routes, resize, image recovery) was
  observed in this segment. Segment 2's recorded observations remain the last native UI evidence for these frozen source hashes,
  with its own recorded gaps (S2 expectation mismatch, S5 NOT ACHIEVED, S6 not run).
- Any app UI state: the app ran behind the locked screen for ~2 minutes; no state was read.

## Continuation list (checkpoint for the next segment)
1. T1: commit "gamma" first (non-empty history) -> fresh editor -> toolbar Undo DISABLED -> click the disabled toolbar Undo
   anyway -> record verbatim (expected: no change anywhere; if the AX click throws/refuses, record that shape).
2. T2: focused editor, draft "gamma" -> "gammax" -> app Edit menu -> PLAIN Undo -> expect draft "gamma"; PLAIN Redo ->
   expect "gammax" restored; record before/after + toolbar states.
3. T3: reopened editor -> type " x" (e.g. "gamma delta x") -> cmd+z (expect draft reverts one step; Undo disabled, Redo enabled)
   -> cmd+shift+z (draft restored).
4. T4: S5 resize, two routes — (a) select object, screenshot handles visible, app.drag from EXACT handle centers with 40-60px
   deltas (corner + edge; also try slow two-click: click handle center then drag from there); fallback cua.computer.drag
   positional-array shape cua.computer.drag([98,200],[78,180]) (no app key). (b) labeled functional proxy: AX secondary actions
   on the selected object (resize-like e.g. "Make larger"/"Make smaller"), before/after AX center/size, then one undo restores.
   Record every call + rejection verbatim. If both routes fail -> NOT ACHIEVED with full evidence (no unavailability claim).
5. T5: corrupt import -> failure banner + "Choose Failed Files Again..." (verify verbatim) -> retry -> import valid fixture
   (/tmp/attic-b2fix2-ds/valid-fixture-s3.png) via recents-row route; success = canvas +1 image, banner clears; log friction verbatim.
6. Standing route/control context: Settings-close reveals panel; cmd+4 section cycler (click into panel first on a fresh process);
   pin deliberately if it helps focus stability; canvas IDs canvas-tool-*, canvas-add-text, canvas-document-menu, canvas-undo,
   canvas-redo, canvas-surface, canvas-object-*; menu-stuck recovery performSecondaryAction(0, "Cancel"); Edit menu via menu-bar
   AX click; screenshots unavailable while a menu is presented (record AX reads instead). Fixtures staged in /tmp/attic-b2fix2-ds/.

## Cleanup evidence
- App quit ~13:53:55Z by exact bundle path (SIGTERM after PID/path match against
  /private/tmp/attic-b2fix2-ds3-dd/Build/Products/Local/AtticB2Fix2DSS3.app/Contents/MacOS/AtticB2Fix2DSS3);
  PROCESS_ABSENT confirmed; pgrep -fl 'AtticB2Fix2DSS3' -> NO_STRAY_PROCESS; pgrep -fl 'attic-b2fix2-ds3-dd' -> NO_STRAY_DD.
- Lock released via mv ~13:53:55Z -> /tmp/attic-native-ui.lock.released-b2fix2-ds-seg3; LOCK_ABSENT verified.
- Fixtures re-hashed ~13:53:55Z: corrupt 400550e9a647b49b1ba4e3517f5456a97d35f18a1cbc410771b6254cfb612162 (unchanged);
  valid-fixture.png and valid-fixture-s3.png both fc4a82118b689607dd463efb3b3ca6c2864c2e59c4c2d6a9dd596723529f0144 (unchanged).
- Repo re-check ~13:53:55Z: HEAD ae6418c1af690e29d15a20344cdb9765a23d3f85; dirty entries 191 — no repo writes by this tester.
- No canvases created or deleted (no UI interaction reached the canvas). Daily store, real user stores, other preview stores
  untouched. Agent Access/MCP untouched. No commits/pushes. No security/permission changes. No auto-unlock attempted.

