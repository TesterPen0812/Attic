# Batch 2 Editing Availability Fix — Sol Direct Native Verification

**Overall verdict: NATIVE_PARTIAL.** No product defect was confirmed. Native scenario driving stopped after the third separate direct computer-use control failure, as required by the run contract. This report makes no promotion claim.

## Route and control check

- Role: Sol direct native-verification owner via a Codex collaboration subagent, using the subagent's own direct `cua` computer-use surface. This was not the failed Synara codex-provider tunnel route (`Tunnel-client has not been seen for 300 seconds`).
- Runtime model disclosure: the requested role label named `gpt-5.6-sol`; the executing agent identifies as `glm-5.3-flash`, so this report does not misstate the runtime model.
- Effort: low.
- Mandatory first action: `cua.getState()` observation only, with no click, typing, or window manipulation.
- Read-only control check result: **PASS**. The call returned the direct Computer Use API documentation and a live app inventory without error.
- Physical-desktop lock: `/tmp/attic-native-ui.lock` acquired exclusively with `O_CREAT|O_EXCL`, owner `Sol-direct`, live holder PID `45484`, UTC `2026-09-16T03:20:30Z`; held for the run and released during cleanup.

## Provenance

- Live checkout: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- The worktree was already dirty with extensive tracked and untracked work. It was preserved. This new report is the only repository write by this verifier.

Required source hashes all matched:

| Path | SHA-256 |
|---|---|
| `Attic/Views/Panel/CanvasPanelContent.swift` | `84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8` |
| `Attic/Canvas/CanvasSession.swift` | `e9393be9fa8b3a1fed8ed6b814b9ccbf91d99bdbdc40d68f436b920788c542d3` |
| `Attic/App/CanvasEditCommandRoute.swift` | `4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf` |

The existing isolated preview matched and was reused without rebuilding:

- App: `/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app`
- Bundle ID: `com.taha.Attic.b2avail.solnative.20260916`
- Executable SHA-256: `e635451ce6d4d2787a8e1beb5e1290e60e5419849b7dcf4e0efa4008c3c645dc`
- Debug dylib SHA-256: `320944869fb29ac6e181bf46dfb6457959e4cf7c3048dcb2f355e07d8e6734f4`
- Runtime PID: `45655`, parent PID `1`
- Verified mapped executable: `/private/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app/Contents/MacOS/AtticB2AvailSolNative`
- Verified mapped debug dylib: `/private/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app/Contents/MacOS/AtticB2AvailSolNative.debug.dylib`
- `Scripts/launch_local_preview.zsh --verify` confirmed both mapped inode/size pairs matched the on-disk artifacts.
- `com.taha.Attic` (Daily) was neither launched nor read. No store other than the isolated preview store was touched.

## Control-surface stop condition

The preview launched and its initial Tasks panel was directly observed. Navigation toward Canvas then encountered three separate direct-control failures:

1. Target-change interruption: `The user changed '/tmp/attic-b2avail-sol-dd/Build/Products/Local/AtticB2AvailSolNative.app'. Re-query the latest state with get_app_state before sending more actions.` The app was re-read once as required.
2. Stale element failure while cancelling an app menu: `Computer Use server error -10005: The element ID is no longer valid.` The app was re-read once and the menu was then cancelled successfully.
3. Key dispatch failure while trying an alternate Canvas shortcut: `Computer Use server error -10005: keyNotFound("Meta")`.

After failure 3, all UI driving stopped. These are tooling failures, not product defects. The app had not reached a valid Canvas test setup, so no scenario outcome was inferred from source or prior reports.

## Scenario outcomes

| Scenario | Result | Direct observation |
|---|---|---|
| B — D1 no-inert-chrome | **UNVERIFIED** | Canvas setup and focused empty text editor were not reached before the control-failure stop threshold. |
| C — D2 live enable while typing | **UNVERIFIED** | Empty-history editor typing, live toolbar/menu enablement, toolbar Undo, item count, and Cmd-Z equivalence were not driven. |
| D — Redo/commit | **UNVERIFIED** | Editor redo, commit, single-entry canvas undo, and canvas redo were not driven. |
| E — Cancel | **UNVERIFIED** | Escape during semantic text editing was not driven. |
| F — Focus switching | **UNVERIFIED** | Editor/session target switching and app Edit-menu agreement were not driven. |
| G — Image recovery | **UNVERIFIED** | A disposable 96-byte truncated PNG fixture was created at `/tmp/attic-b2avail-sol-corrupt.png`, but no picker/import/retry UI was driven after the stop threshold. |
| H — Text resize | **UNVERIFIED** | Multi-line semantic text creation and pointer resize were not driven. |
| I — Board hygiene | **UNVERIFIED** | No disposable Canvas board was created. No board was deleted. The isolated preview remained isolated, but cross-board behavior was not exercised. |

Accounting: **0 PASS, 0 FAIL, 8 UNVERIFIED, 0 BLOCKED** across scenarios B–I. Preview identity/provenance and the initial read-only control check passed independently; they are not counted as product scenarios.

## Screenshot evidence

Evidence directory: `/tmp/attic-b2avail-sol-evidence/`

| File | SHA-256 | Observation |
|---|---|---|
| `01-before-canvas-navigation.png` | `cf93cc760d7e955985fef4a2aeadb850c41592b6ad3da5765e2b01a65762b7ac` | Initial isolated preview Tasks panel before attempted Canvas navigation. |

The required per-scenario before/after pairs do not exist because no scenario reached a valid starting state before the mandatory tooling stop. This absence is reported rather than backfilled with non-scenario screenshots.

## Cleanup and processes

- The exact verified preview PID `45655` was terminated with `SIGTERM` only after rechecking that its command path exactly matched the isolated preview executable. It exited successfully.
- No Attic preview process was intentionally left running.
- The lock-holder process was stopped after this report was written, releasing `/tmp/attic-native-ui.lock`.
- No source edit, commit, push, reset, permission/TCC change, security-prompt approval, board deletion, release, installation, or store access was performed.

## Verdict

**NATIVE_PARTIAL — direct native verification was curtailed by the required three-control-failure stop condition. No product defect was confirmed, and no promotion claim is made.**
