# 2026-08-31 Comprehensive Audit Fix Resolution Ledger

Integration branch: `codex/attic-comprehensive-audit-fixes`

Audited baseline: `87c2062a536c42badac78a5ce2b21bbad7315d12`

Baseline verification: 333/333 Attic macOS unit tests passed in the Local configuration. This is source/test evidence only; no installed behavior is inferred from it.

## Status vocabulary

- `Planned`: accepted finding is mapped to this fixing task but has no integrated fix yet.
- `In progress`: a regression test or production fix is being developed in an isolated workstream.
- `Fixed`: the owning commit is integrated and focused automated checks pass.
- `UAT verified`: the integrated fix also passed the listed installed-app scenario.
- `Decision required`: implementation would change a public model, SwiftData schema, or storage format and awaits explicit approval.
- `Blocked`: a required environmental or user-only verification cannot be completed here.
- `Disproved`: the source hypothesis was reproduced with an integration test and shown not to be a product defect.

## Canvas

| Finding | Status | Owning commit | Focused tests | Installed UAT | Performance evidence | Residual risk |
| --- | --- | --- | --- | --- | --- | --- |
| C-01 | In progress | — | Regression development on `codex/attic-comprehensive-canvas` | — | — | Async target/generation race remains until integrated. |
| C-02 | In progress | — | Regression development on `codex/attic-comprehensive-canvas` | — | — | Mixed clear/restore and persisted-refresh outcomes remain non-atomic. |
| C-03 | Planned | — | — | — | — | VoiceOver and Full Keyboard Access object navigation unverified. |
| C-04 | Planned | — | — | — | Baseline stress evidence pending capture | Decode/import/history resources remain unbounded. |
| C-05 | Decision required | — | — | — | — | Semantic text/shape persistence requires a backward-compatible schema/storage decision; truthful legacy affordances can proceed independently. |
| C-06 | Planned | — | — | — | — | Page viewport/history/relaunch state remains unverified. |
| C-07 | Planned | — | — | — | Baseline mutation/payload comparison evidence pending capture | Main-actor whole-table and payload work remains. |
| C-08 | Fixed | `b436066` | `CanvasStoreTests`: 11/11 passed in Local; regression asserts nil remote/Cloud observers, import-refresh task, activity tokens, timeout tasks, and unchanged sync status before and after a save/event | Awaiting installed process-activity observation during Canvas saves | Local save now bypasses Cloud protection/status work; affected Local build passed, and an unsigned Debug compile verified deferred non-Local source still compiles | Automated token/task/observer state is verified; installed energy/process-activity sampling remains to confirm no platform-level wakeups. |
| C-09 | Fixed | `0055518` | `CanvasSessionTests`: 11/11 passed in Local; route is Canvas-scoped and exercises Undo/Redo without constructing the width-dependent toolbar | Awaiting installed Command-Z/Command-Shift-Z matrix at 332, 360, custom, and expanded widths | Stable Commands observation is event-driven and adds no polling or persistence | Automated route and affected Local build pass; menu key-equivalent precedence and every required width remain installed-UAT pending. |
| C-10 | Planned | — | — | — | Baseline corrupt-decode retry count pending capture | Corrupt assets lack complete recovery/memoization. |
| C-11 | Planned | — | — | — | — | Import fit/reachability matrix unverified. |
| C-12 | Planned | — | — | — | — | Hosted content-versus-shell resize hit matrix unverified. |
| C-13 | Fixed | `bb762ea` | `CanvasImageSessionTests`: 4/4 passed in Local; includes 2 boundary regressions | Awaiting installed keyboard/button UAT | Boundary regressions prove zero additional save, revision, history command, or z-index change | Automated source behavior is verified; installed disabled-state and shortcuts remain to UAT. |
| C-14 | Planned | — | — | — | Baseline rapid-input sample fidelity pending capture | Coalesced sample handling remains incomplete. |
| C-15 | Planned | — | — | — | — | Real hosted input suite and test-only production path removal remain. |
| C-16 | In progress | — | Regression development on `codex/attic-comprehensive-canvas` | — | Baseline batch resource evidence pending capture | Drag/drop batch target, progress, cleanup, and concurrency remain. |
| C-17 | Planned | — | — | — | — | Canvas documentation still contains stale mobile/Cloud and implementation claims. |
| C-18 | Planned | — | — | — | — | Compact global-error overlap has not yet been reproduced after integration. |

## Notes

| Finding | Status | Owning commit | Focused tests | Installed UAT | Performance evidence | Residual risk |
| --- | --- | --- | --- | --- | --- | --- |
| N-001 | In progress | — | Regression development on `codex/attic-comprehensive-notes` | — | Audit reproduction captured draft text loss | Draft-session attachment race remains. |
| N-002 | In progress | — | Regression development on `codex/attic-comprehensive-notes` | — | Audit reproduction captured `NSRangeException` | Cross-note Undo/Redo can still crash. |
| N-003 | In progress | `507e13c`, `51377e2` | `CornerHoverStateMachineTests`, `PanelUIStateTests`, and `PanelGeometryTests`: 40/40 passed in Local | Awaiting clean-unfocused/focused/dirty/import installed matrix | Explicit lock composition is integrated; no added polling | Dirty/conflict and quick-entry producers are wired, but Notes editor focus, import, popover, and blocking-save producers still need integration. |
| N-004 | Planned | — | — | — | — | Note/cursor/selection/scroll session restoration remains. |
| N-005 | Fixed | `3957a27`, `69fafe6` | `NoteStoreTests`, `NoteDraftControllerTests`, `NoteAttachmentTests`, and `MCPRequestHandlerTests`: 82/82 passed in Local; every helper call requires an explicit injected root | Not applicable: test-harness isolation only | A separate default-shaped sentinel root remained byte-identical while reconciliation created state only under the unique injected root; no real app root was accessed | Automated isolation is verified; temporary test-root reclamation remains ordinary `/tmp` housekeeping rather than app-data risk. |
| N-006 | In progress | — | Regression development on `codex/attic-comprehensive-notes` | — | Audit continuous-typing probe captured unbounded trailing debounce window | Maximum durability checkpoint remains undefined. |
| N-007 | Planned | — | — | — | Audit attachment lifecycle probe captured stale recency/empty note | Lifecycle invariants remain decentralized. |
| N-008 | Planned | — | — | — | — | Broad scroll monitor and non-directional swipe remain. |
| N-009 | Planned | — | — | — | Audit missing-attachment probe returned no URL and no error | Missing/corrupt recovery states/actions remain. |
| N-010 | Planned | — | — | — | Audit late-promise probe left delivered file behind | Reconciler/provider cleanup ownership remains incomplete. |
| N-011 | Planned | — | — | — | — | Save/import/conflict status and relative-time refresh remain incomplete. |
| N-012 | Planned | — | — | — | Baseline: 5000-note update median 27.98 ms; attachment lookup median 5.78 ms; 168 MB peak footprint | Predicate/caching/thumbnail improvements not integrated. |
| N-013 | Planned | — | — | — | — | Editor labels, announcements, tab order, hit targets, contrast, and Reduce Motion remain. |
| N-014 | Planned | — | — | — | — | Compact long-text/mixed-attachment scroll handoff unverified. |
| N-015 | Planned | — | — | — | — | Deterministic focus teardown and recursion-warning failure policy remain. |
| N-016 | In progress | `507e13c`, `51377e2` | 40/40 panel state/geometry tests passed; accepted hide remains model-visible until owned native completion and a superseding reveal cancels it | Awaiting installed failed-save/retry and reveal-during-hide UAT | Audit hide latency baseline 927–1435 ms; final latency remeasurement pending | The controller now checks `NoteDraftController.flush()` before destructive state and commits hidden state only after `orderOut`; a direct hosted flush-failure regression and retry affordance verification are still required. |

## Panel and shell

| Finding | Status | Owning commit | Focused tests | Installed UAT | Performance evidence | Residual risk |
| --- | --- | --- | --- | --- | --- | --- |
| PANEL-01 | In progress | `507e13c`, `51377e2` | `CornerHoverStateMachineTests`, `PanelUIStateTests`, and `PanelGeometryTests`: 40/40 passed in Local, including nested menu and independent-reason composition | Awaiting all-mode installed interaction-lock matrix | Set-based locks add no polling or timers | Shell reasons and quick-entry/dirty/conflict producers are integrated; remaining Notes focus/import/popover/blocking-save producers keep this item open. |
| PANEL-02 | Fixed | `507e13c`, `51377e2` | 40/40 panel state/geometry tests passed, including rejection, owned native completion, reveal supersession, and nested locks | Awaiting installed native animation and failed-flush UAT | Audit hide latency baseline 927–1435 ms; final latency remeasurement pending | Source transaction is integrated, but the real `NSPanel` completion path and visible retry error still require installed verification. |
| PANEL-03 | In progress | — | Regression development on `codex/attic-comprehensive-panel` | — | — | Dynamic Dock/work-area recovery and preferred-size separation remain until the next panel checkpoint is integrated. |
| PANEL-04 | Planned | — | — | — | — | Clear-mode foreground matrix requires installed visual judgment; transmission must remain unchanged. |
| PANEL-05 | Planned | — | — | Physical trackpad required after automation | Baseline fast edge pass: 0/5 reveals; dismissal intent metrics pending | Phase-aware chrome flick and robust mouse throw remain. |
| PANEL-06 | Planned | — | — | — | — | Move/resize cancellation and passthrough safety remain incomplete. |
| PANEL-07 | Planned | — | — | — | — | Single-selection accessibility semantics unverified. |
| PANEL-08 | Planned | — | — | — | Baseline hidden sample: 3478 voluntary and 6370 involuntary context switches over 6.2 s; 20 Hz activity remains | Adaptive idle sampling/reveal-latency balance not integrated. |
| PANEL-09 | Planned | — | — | — | Baseline UI runner exited before connection | Signed unique real-host UI suite remains broken. |
| PANEL-10 | Planned | — | — | — | — | Cursor/drag/resize acquisition matrix remains. |
| PANEL-11 | Fixed | `507e13c` | Local-only refresh-policy regression included in the 40/40 panel pass; asserts one immediate pass, no retry delay, and maximum pass count 1 | Awaiting installed reveal-latency remeasurement | Baseline reveal 249–339 ms; Local policy now schedules no 900 ms retry or second all-store refresh | Installed timing remains to measure; deferred non-Local sync source remains feature-gated and was not removed. |
| PANEL-12 | Fixed | `d14ae77` | `Scripts/test_launch_local_preview.rb`: 6/6 passed (43 assertions); `zsh -n` passed; real signed `--build-only` invocation validated requested display name/bundle/executable and local-only entitlements | Final preview launch and exact-process replacement UAT pending under exclusive UI lock | Default DerivedData and build product are under `/tmp`; build-only verification produced an ad-hoc signed arm64 app and no UI process | Actual launch/replace and explicit appearance override remain installed-UAT pending; `/Applications` requires a second explicit opt-in. |
| PANEL-13 | Fixed | `4639220` | `PanelSquircleGeometryTests`: 54/54 passed in Local; modern selector permission and dock-corner-authoritative frame routing covered | Awaiting installed Accessibility Inspector/VoiceOver resize UAT | Affected Local build succeeded with the prior `accessibilityIsAttributeSettable` deprecation warning eliminated | Automated routing and warning removal are verified; assistive-client behavior remains installed-UAT pending. |

## Exclusive live UI automation

Before any command that drives the installed app, cursor, keyboard, trackpad events, screenshots requiring UI manipulation, or the real UI test host, the fixing task must atomically create `/tmp/attic-exclusive-ui.lock`. If creation fails because the path already exists, live UI automation waits while non-UI work continues. The owner records its task, PID, and start time inside the lock directory and removes only its own lock in a guaranteed cleanup path. Builds, unit tests, analyzer runs, static screenshots, and read-only process inspection do not acquire the lock.

## Checkpoint history

| Integration commit | Contents | Verification |
| --- | --- | --- |
| `4b246f6` | Initial ledger and verified clean baseline | 333/333 Local Attic unit tests passed at `87c2062a536c42badac78a5ce2b21bbad7315d12`. |
| `e6946fb` | Marked the first isolated fix streams active | Workstream branches and focused regression ownership recorded. |
| `bb762ea` | C-13 true Canvas layer-boundary no-ops and disabled unavailable controls | `CanvasImageSessionTests` 4/4 passed; zero additional persistence/revision/history/z-index mutations asserted. |
| `507e13c`, `51377e2` | Explicit interaction-lock vocabulary, local-only single reveal refresh, and native-completion-aware transactional hide | Central Local run passed 40/40 `CornerHoverStateMachineTests`, `PanelUIStateTests`, and `PanelGeometryTests`; affected Local build succeeded. |
| `3957a27`, `69fafe6` | N-005 unique explicit attachment roots for every Notes/MCP test initializer plus a default-shaped sentinel regression | Central Local run passed 82/82 Notes/MCP tests; affected Local build succeeded. |
| `4639220` | PANEL-13 modern `NSAccessibility` selector permission while retaining dock-corner-authoritative frame routing | `PanelSquircleGeometryTests` 54/54 passed; affected Local build succeeded without the deprecated attribute-settable warning. |
| `d14ae77` | PANEL-12 parameterized local-only preview build/launch with exact PID+path ownership, `/tmp` defaults, optional appearance, provenance, signature, hash, and entitlement emission | Launcher tests passed 6/6 (43 assertions); a real build-only run produced `Attic Launcher Verification`, `com.taha.Attic.launcher.verification`, executable SHA-256 `c478b8d8758382c3fb2c3ef0ecee2a36208b4f4e4571b38c8db9db9306d604e2`, and only sandbox/get-task-allow/network entitlements. |
| `0055518` | C-09 app-level Canvas Undo/Redo commands independent of compact toolbar rendering; removed button-owned key equivalents | `CanvasSessionTests` 11/11 passed; affected Local build succeeded. |
| `b436066` | C-08 compile-time Local policy gates Canvas remote/Cloud observers, Cloud event/status work, activity assertions, and timeout creation while retaining deferred source | `CanvasStoreTests` 11/11 passed; Local build and unsigned non-Local Debug compile both succeeded. |
