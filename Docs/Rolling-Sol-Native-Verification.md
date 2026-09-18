# Rolling Sol Low Native Verification — 2026-09-14

## Outcome

The checkpoint preview's running binary provenance is verified, but native visual,
navigation, gesture, and accessibility verification is **BLOCKED** because the
desktop-control connector is disconnected. No interaction result or acceptance
verdict is claimed from source, unit-test, or process evidence.

The R-01/R-02 Notes source reviews were still pending when this pass began.
Consequently, even a successful visual observation would have remained provisional
with respect to source correctness.

## Exact app provenance

- Checkout: `/Users/taha/Developer/attic-task-panels-v2` (intentionally dirty)
- Verification command:
  `Scripts/launch_local_preview.zsh --display-name 'Attic Chrome Checkpoint' --bundle-id com.taha.Attic.chromecheckpoint --executable-name AtticChromeCheckpoint --derived-data /tmp/attic-chrome-checkpoint-dd --appearance dark --verify`
- Verified at: `2026-09-14T11:15:24Z`
- Running PID: `14206`
- Bundle ID: `com.taha.Attic.chromecheckpoint`
- Executable: `/private/tmp/attic-chrome-checkpoint-dd/Build/Products/Local/AtticChromeCheckpoint.app/Contents/MacOS/AtticChromeCheckpoint`
- Executable inode / size / SHA-256: `142018710 / 41024 / af455672e248e83cee28b743189fc955b8c9e19887a5df34d7ead89600d19017`
- Mapped debug dylib: `/private/tmp/attic-chrome-checkpoint-dd/Build/Products/Local/AtticChromeCheckpoint.app/Contents/MacOS/AtticChromeCheckpoint.debug.dylib`
- Debug dylib inode / size / SHA-256: `142018706 / 21417840 / 432dbce4176d27ca558903ab2d7bdff8d4b8213e579abc7f78c910f3ae24ea62`

The repository verifier confirmed one matching running instance and matching
mapped inode/size values. No rebuild or relaunch was performed by this reviewer.

## Exclusive UI preflight

Process inspection found no active `xcodebuild`, `xctest`, or
`AtticUnitTestHost` workload. The matching processes were long-lived
`xcodebuildmcp mcp` service processes, not test-host execution. The repository
lock `/tmp/attic-exclusive-ui.lock` was absent, then acquired for this pass.
It was released after the connector blocker was recorded. No pointer operation
overlapped a test host.

## Blocking evidence

The only discovered native desktop-control tool rejected two bounded attempts
before returning a frame or UI tree:

`McpServerError: Tunnel-client has not been seen for 300 seconds. Ensure tunnel-client is running and connected.`

The first attempt requested a fresh full-screen observation. A second bounded
retry requested a one-second wait followed by capture and returned the same
error. With no frame, refs, or connected input channel, this pass could not
safely focus Attic, operate disposable fixtures, or capture stable screenshots.

## Live no-swipe matrix

| Scenario | Result | Evidence / limitation |
| --- | --- | --- |
| Open a task subpanel with a single click; switch immediately to another task | BLOCKED | No connected pointer/UI tree |
| Fallback setup via double-click and Add Task | BLOCKED | No connected pointer/UI tree |
| Ordinary vertical scroll in Subtasks | BLOCKED | No native event injection or visual observation |
| Horizontal swipe-shaped scroll in both directions over Subtasks | BLOCKED | No native event injection; generic scroll would not prove a physical trackpad gesture |
| Horizontal swipe-shaped scroll over Attachments gallery | BLOCKED | No native event injection or gallery observation |
| Momentum tail and interrupted sequence | BLOCKED | No physical gesture/event channel |
| Confirm no subpanel move, fade, scale, rubber-band dismissal, or residual transform | BLOCKED | No frames or stable screenshots |
| Main-panel attached-edge two-finger swipe dismissal | BLOCKED | Physical trackpad proof unavailable |
| Notes library main-panel swipe/navigation | BLOCKED | Physical trackpad proof unavailable |
| Explicit close, Escape, and outside-click dismissal | BLOCKED | Keyboard/pointer channel unavailable |
| Rename field-editor Escape behavior | BLOCKED | Keyboard/UI tree unavailable |
| Pin, unpin, move, detach, and resize | BLOCKED | Pointer/UI tree unavailable |
| Subtasks/Attachments switching and responsive height changes | BLOCKED | No rendered-state observation |
| Floating header/footer chrome and scrolled underlay | BLOCKED | No screenshot/frame |
| Hover-only task-row ellipsis | BLOCKED | No pointer/frame |
| Attachment picker cancellation, import error, pending/error strip, and external drag preview | BLOCKED | No pointer/frame; no user data touched |
| Notes disjoint-edit inline-attachment anchor behavior | BLOCKED | No safe UI operation; source reviews pending, so no acceptance verdict is possible |
| Rapid open/close/pin cycles | BLOCKED | No pointer/frame |
| VoiceOver open/close affordance spot-check | BLOCKED | No accessibility/UI channel |

No disposable task, subtask, note, or attachment fixture was created. Existing
user data was not edited or deleted.

## Required setup for the resumed native pass

If the task sub-panel does not open, open it manually using double-click, then
“Add Task.” This setup may be necessary before the panel becomes available for
inspection.

The resumed pass must start by rerunning the exact provenance verification and
exclusive-owner preflight. It must prioritize the two-direction subpanel
no-swipe/momentum matrix, record the actual panel state before and after each
gesture, and keep physical two-finger proof distinct from generic programmatic
scrolling. Stable screenshot/reproduction paths: none produced in this blocked
pass.
