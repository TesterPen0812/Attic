# Batch 2 Editing Availability Fix — Sol Native Verification Retry

**Overall verdict: NATIVE_PARTIAL — the native desktop-control tunnel remained disconnected across the three permitted fresh attempts. No product defect was confirmed and no promotion claim is made.**

## Provenance and isolation

- Live checkout: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- Required source hashes matched before launch:
  - `Attic/Views/Panel/CanvasPanelContent.swift`: `84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8`
  - `Attic/Canvas/CanvasSession.swift`: `e9393be9fa8b3a1fed8ed6b814b9ccbf91d99bdbdc40d68f436b920788c542d3`
  - `Attic/App/CanvasEditCommandRoute.swift`: `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf`
- The exclusive physical-desktop lock `/tmp/attic-native-ui.lock` was acquired with `O_EXCL` before launch. Its recorded owner was `Sol-retry`, PID `30535`, UTC `2026-09-16T03:13:55Z`. It was held for the whole run and removed during cleanup.
- No source, project, permission/TCC, or store was changed. This new report is the only live-tree write made by this retry. No commit, push, reset, release, install, or board deletion was performed.
- `com.taha.Attic` (Daily) was neither launched nor read. Only the isolated preview and its isolated fresh local store were in scope.

## Preview and runtime identity

- Reused app: `/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app`
- Display name: `Attic B2 Availability Sol Native 20260916`
- Bundle ID: `com.taha.Attic.b2avail.solnative.20260916`
- Executable: `AtticB2AvailSolNative`
- Executable SHA-256: `e635451ce6d4d2787a8e1beb5e1290e60e5419849b7dcf4e0efa4008c3c645dc`
- Debug dylib SHA-256: `320944869fb29ac6e181bf46dfb6457959e4cf7c3048dcb2f355e07d8e6734f4`
- Launch PID: `30570`; parent PID: `1` (launchd-owned).
- `Scripts/launch_local_preview.zsh ... --verify` succeeded at `2026-09-16T03:14:18Z`, mapping PID `30570` to the exact on-disk executable and debug dylib, including matching inode and size.
- Signed entitlements were local-only: app sandbox, user-selected file read/write, get-task-allow, and network client/server. No CloudKit, ubiquity, or APNs entitlement was present.
- The pre-existing verification metadata emitted `recorded_pid=28751`; live verification independently established the current launchd-owned PID as `30570`.

## Native scenario results

| Scenario | Result | Observation |
|---|---|---|
| A. Provenance, isolated launch, and runtime identity | **PASS** | All required source and binary hashes matched. Bundle identity, local-only entitlements, launchd ownership, and mapped executable/debug-dylib identity were verified live. |
| B. D1 no-inert-chrome | **UNVERIFIED** | The tunnel failed before any UI could be observed or driven. Empty-editor Undo/Redo availability, toolbar state, Add-menu state, app Edit-menu agreement, and preservation of canvas history were not observed. |
| C. D2 live enable while typing | **UNVERIFIED** | No text editor could be focused or typed into. Live enablement, toolbar Undo, canvas item count, and Cmd-Z equivalence were not observed. |
| D. Redo path and commit | **UNVERIFIED** | Editor Undo/Redo, commit coalescing into one canvas-history entry, and canvas Redo were not driven or observed. |
| E. Cancel | **UNVERIFIED** | Escape-during-edit draft cancellation and settled command availability were not driven or observed. |
| F. Focus switching | **UNVERIFIED** | A different object or panel could not be focused; target accuracy and app Edit-menu agreement were not observed. |
| G. Image recovery | **UNVERIFIED** | No corrupt fixture was imported because the native UI could not be controlled. Failure banner, Retry, and recovery were not observed. |
| H. Text resize | **UNVERIFIED** | Multiline text creation, pointer narrowing, commit, and post-commit visibility were not driven or observed. |
| I. Board hygiene | **UNVERIFIED** | No disposable canvases were created because the UI was unavailable. No existing board or store was touched. |
| Board deletion | **BLOCKED** | Deletion requires action-time confirmation under the native playbook. It was not attempted or claimed. |

## Harness failure and screenshot accounting

The desktop-control surface returned the same error on three separate fresh attempts:

`McpServerError: Tunnel-client has not been seen for 300 seconds. Ensure tunnel-client is running and connected.`

Between attempts, the exact isolated preview was raised again and its process/identity was re-read. Attempt 2 followed a successful full `--verify`; attempt 3 followed another app raise and live PID/lock check. After the third separate failure, driving stopped as required. The failure is classified as a verification-harness limitation, not a product failure.

Evidence directory: `/tmp/attic-b2avail-sol-evidence/`

- Screenshot count: **0**
- Screenshot hashes: **none**
- Reason: the tunnel failed before the desktop could be observed or captured. No source-only inference, fallback automation, or fabricated screenshot was substituted for native proof.

## Accounting

- PASS: 1 scenario (A)
- FAIL: 0 scenarios
- UNVERIFIED: 8 scenarios (B–I)
- BLOCKED: board deletion

## Cleanup and processes left running

- The isolated preview was cleanly asked to quit at the end of the run and its PID was checked for termination.
- `/tmp/attic-native-ui.lock` was removed after preview termination.
- Processes left running by this retry: **none**.
- The isolated evidence directory remains in `/tmp` and contains no screenshots.
- All Daily, user, and pre-existing preview stores were preserved.

## Verdict

**NATIVE_PARTIAL.** Scenario A passed again. Scenarios B–I remain **UNVERIFIED** because the desktop-control tunnel failed on all three permitted fresh attempts. Board deletion remains **BLOCKED**. This retry makes no promotion claim.
