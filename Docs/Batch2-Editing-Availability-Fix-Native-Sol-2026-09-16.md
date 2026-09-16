# Batch 2 Editing Availability Fix — Sol Native Verification

**Overall native verdict: NATIVE_PARTIAL — native interaction blocked by the desktop-control harness; no product defect confirmed and no promotion claim.**

## Provenance and isolation

- Live checkout: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- Required source hashes matched before building:
  - `Attic/Views/Panel/CanvasPanelContent.swift`: `84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8`
  - `Attic/Canvas/CanvasSession.swift`: `e9393be9fa8b3a1fed8ed6b814b9ccbf91d99bdbdc40d68f436b920788c542d3`
  - `Attic/App/CanvasEditCommandRoute.swift`: `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf`
- The exclusive physical-desktop lock `/tmp/attic-native-ui.lock` was created before the build, held throughout the run, and removed at cleanup.
- No source, project, permission/TCC, or store was changed. This report is the only live-tree file written by Sol. No commit, push, reset, release, or install action was performed.
- `com.taha.Attic` (Daily) was not launched or read. The isolated preview used its fresh local store.

## Preview build and runtime identity

- Build/launch command: `Scripts/launch_local_preview.zsh --display-name 'Attic B2 Availability Sol Native 20260916' --bundle-id com.taha.Attic.b2avail.solnative.20260916 --executable-name AtticB2AvailSolNative --derived-data /tmp/attic-b2avail-sol-dd --appearance dark`
- App: `/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app`
- Bundle ID: `com.taha.Attic.b2avail.solnative.20260916`
- Executable: `/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app/Contents/MacOS/AtticB2AvailSolNative`
- Executable SHA-256: `e635451ce6d4d2787a8e1beb5e1290e60e5419849b7dcf4e0efa4008c3c645dc`
- Debug dylib: `/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app/Contents/MacOS/AtticB2AvailSolNative.debug.dylib`
- Debug dylib SHA-256: `320944869fb29ac6e181bf46dfb6457959e4cf7c3048dcb2f355e07d8e6734f4`
- Verified PID: `28751`; parent PID `1` (launchd-owned).
- `--verify` succeeded immediately before native interaction and again at `2026-09-16T03:11:38Z`. The process mapped the exact executable and debug-dylib inodes from the built bundle.
- Signed entitlements were local-only: app sandbox, user-selected file read/write, get-task-allow, and network client/server; no CloudKit, ubiquity, or APNs entitlement was present.

## Native scenarios

| Scenario | Result | Direct observation |
|---|---|---|
| A. Baseline canvas identity | **PASS** | The launch script's `--verify` semantics tied launchd-owned PID `28751` to the exact built executable and debug dylib immediately before interaction and again before cleanup. No relaunch occurred. |
| B. D1 no-inert-chrome | **UNVERIFIED** | No UI action could be sent. The native desktop-control surface returned `Tunnel-client has not been seen for 300 seconds` on two observation attempts. Toolbar, Add-menu, and app Edit-menu availability were therefore not observed. |
| C. D2 live enable while typing | **UNVERIFIED** | The disconnected native-control tunnel prevented creating/focusing a text item, typing, checking live availability, invoking toolbar Undo, or comparing Cmd-Z. |
| D. Redo and commit path | **UNVERIFIED** | The disconnected native-control tunnel prevented editor undo/redo and commit-history observation. |
| E. Cancel path | **UNVERIFIED** | Escape-during-edit behavior could not be driven or observed. |
| F. Focus switching | **UNVERIFIED** | A second object/panel could not be focused, so editor-versus-session target agreement with the app Edit menu was not observed. |
| G. Corrupt-image retry/recovery | **UNVERIFIED** | Import, failure banner, and Retry could not be driven. No disposable corrupt fixture was imported and no product outcome is claimed. |
| H. Multiline text resize | **UNVERIFIED** | Pointer resize and post-commit clipping could not be driven or observed. |
| I. Board/board-switch hygiene | **UNVERIFIED** | No disposable board was created or switched because the native-control tunnel was unavailable. No board or store was touched. |
| Board deletion | **BLOCKED** | Per the mandatory playbook, deletion is destructive and gated by action-time confirmation. It was not attempted or claimed. |
| Physical pinch and held foreign interaction tails | **UNVERIFIED** | The available control surface does not provide physical-trackpad pinch or the held phased-interaction sequence required for this evidence. No synthesized gesture is claimed. |
| Failed-save seams | **UNVERIFIED** | The playbook provides no safe native failure-injection seam; no save failure was injected or claimed. |

## Harness failure and evidence

The real desktop-control plugin failed before the first UI observation with `McpServerError: Tunnel-client has not been seen for 300 seconds`. After re-reading the exact preview identity, a second native observation attempt returned the same error. This is classified as a tooling failure, not a product defect. No fallback automation or source-only inference was used to manufacture native results.

The requested evidence directory exists at `/tmp/attic-b2avail-sol-evidence/`, but it contains no screenshots because the native surface failed before it could capture the desktop. Consequently there are no screenshot SHA-256 hashes to report.

## Cleanup and limitations

- The exact isolated preview bundle was asked to quit, and PID `28751` was confirmed stopped.
- Processes left running by this pass: none.
- Daily and every existing user/preview store were preserved.
- Scenarios B–I require a fresh serialized native run after the desktop-control tunnel is connected. This report does not promote the candidate and does not convert implementation tests or source review into native evidence.

## Verdict

**NATIVE_PARTIAL.** Candidate provenance, isolated build identity, launchd ownership, and mapped executable/debug-dylib identity passed. The desktop-control harness prevented all requested interactive native scenarios, so no interactive scenario passed or failed and no product defect was confirmed. Board deletion remains **BLOCKED**; physical gestures, held foreign tails, and failed-save seams remain **UNVERIFIED** by method.
