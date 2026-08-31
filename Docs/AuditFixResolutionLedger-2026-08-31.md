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
| C-01 | Planned | — | — | — | — | Async target/generation race remains until integrated. |
| C-02 | Planned | — | — | — | — | Mixed clear/restore and persisted-refresh outcomes remain non-atomic. |
| C-03 | Planned | — | — | — | — | VoiceOver and Full Keyboard Access object navigation unverified. |
| C-04 | Planned | — | — | — | Baseline stress evidence pending capture | Decode/import/history resources remain unbounded. |
| C-05 | Decision required | — | — | — | — | Semantic text/shape persistence requires a backward-compatible schema/storage decision; truthful legacy affordances can proceed independently. |
| C-06 | Planned | — | — | — | — | Page viewport/history/relaunch state remains unverified. |
| C-07 | Planned | — | — | — | Baseline mutation/payload comparison evidence pending capture | Main-actor whole-table and payload work remains. |
| C-08 | Planned | — | — | — | Baseline local-only activity evidence pending capture | Deferred Cloud activity may still wake in local-only saves. |
| C-09 | Planned | — | — | — | — | Undo/Redo commands remain toolbar-visibility-dependent. |
| C-10 | Planned | — | — | — | Baseline corrupt-decode retry count pending capture | Corrupt assets lack complete recovery/memoization. |
| C-11 | Planned | — | — | — | — | Import fit/reachability matrix unverified. |
| C-12 | Planned | — | — | — | — | Hosted content-versus-shell resize hit matrix unverified. |
| C-13 | Planned | — | — | — | Baseline no-op persistence counts pending capture | Layer boundary operations may save/history on no-op. |
| C-14 | Planned | — | — | — | Baseline rapid-input sample fidelity pending capture | Coalesced sample handling remains incomplete. |
| C-15 | Planned | — | — | — | — | Real hosted input suite and test-only production path removal remain. |
| C-16 | Planned | — | — | — | Baseline batch resource evidence pending capture | Drag/drop batch target, progress, cleanup, and concurrency remain. |
| C-17 | Planned | — | — | — | — | Canvas documentation still contains stale mobile/Cloud and implementation claims. |
| C-18 | Planned | — | — | — | — | Compact global-error overlap has not yet been reproduced after integration. |

## Notes

| Finding | Status | Owning commit | Focused tests | Installed UAT | Performance evidence | Residual risk |
| --- | --- | --- | --- | --- | --- | --- |
| N-001 | Planned | — | — | — | Audit reproduction captured draft text loss | Draft-session attachment race remains. |
| N-002 | Planned | — | — | — | Audit reproduction captured `NSRangeException` | Cross-note Undo/Redo can still crash. |
| N-003 | Planned | — | — | — | — | Interaction-lock reasons are still conflated/incomplete. |
| N-004 | Planned | — | — | — | — | Note/cursor/selection/scroll session restoration remains. |
| N-005 | Planned | — | — | — | Audit sentinel showed default-root deletion | Tests can still reconcile the default attachment root. |
| N-006 | Planned | — | — | — | Audit continuous-typing probe captured unbounded trailing debounce window | Maximum durability checkpoint remains undefined. |
| N-007 | Planned | — | — | — | Audit attachment lifecycle probe captured stale recency/empty note | Lifecycle invariants remain decentralized. |
| N-008 | Planned | — | — | — | — | Broad scroll monitor and non-directional swipe remain. |
| N-009 | Planned | — | — | — | Audit missing-attachment probe returned no URL and no error | Missing/corrupt recovery states/actions remain. |
| N-010 | Planned | — | — | — | Audit late-promise probe left delivered file behind | Reconciler/provider cleanup ownership remains incomplete. |
| N-011 | Planned | — | — | — | — | Save/import/conflict status and relative-time refresh remain incomplete. |
| N-012 | Planned | — | — | — | Baseline: 5000-note update median 27.98 ms; attachment lookup median 5.78 ms; 168 MB peak footprint | Predicate/caching/thumbnail improvements not integrated. |
| N-013 | Planned | — | — | — | — | Editor labels, announcements, tab order, hit targets, contrast, and Reduce Motion remain. |
| N-014 | Planned | — | — | — | — | Compact long-text/mixed-attachment scroll handoff unverified. |
| N-015 | Planned | — | — | — | — | Deterministic focus teardown and recursion-warning failure policy remain. |
| N-016 | Planned | — | — | — | Audit hide latency baseline 927–1435 ms | Hide state can commit before failed flush/controller hide. |

## Panel and shell

| Finding | Status | Owning commit | Focused tests | Installed UAT | Performance evidence | Residual risk |
| --- | --- | --- | --- | --- | --- | --- |
| PANEL-01 | Planned | — | — | — | — | Shared explicit interaction locks not integrated. |
| PANEL-02 | Planned | — | — | — | Audit hide latency baseline 927–1435 ms | Shared transactional hide handshake not integrated. |
| PANEL-03 | Planned | — | — | — | — | Dynamic Dock/work-area recovery and preferred-size separation remain. |
| PANEL-04 | Planned | — | — | — | — | Clear-mode foreground matrix requires installed visual judgment; transmission must remain unchanged. |
| PANEL-05 | Planned | — | — | Physical trackpad required after automation | Baseline fast edge pass: 0/5 reveals; dismissal intent metrics pending | Phase-aware chrome flick and robust mouse throw remain. |
| PANEL-06 | Planned | — | — | — | — | Move/resize cancellation and passthrough safety remain incomplete. |
| PANEL-07 | Planned | — | — | — | — | Single-selection accessibility semantics unverified. |
| PANEL-08 | Planned | — | — | — | Baseline hidden sample: 3478 voluntary and 6370 involuntary context switches over 6.2 s; 20 Hz activity remains | Adaptive idle sampling/reveal-latency balance not integrated. |
| PANEL-09 | Planned | — | — | — | Baseline UI runner exited before connection | Signed unique real-host UI suite remains broken. |
| PANEL-10 | Planned | — | — | — | — | Cursor/drag/resize acquisition matrix remains. |
| PANEL-11 | Planned | — | — | — | Baseline reveal 249–339 ms stable; local reveal still schedules 900 ms second refresh | Local-only reveal still carries deferred-sync work. |
| PANEL-12 | Planned | — | — | — | — | Broad stale launcher still hard-codes process, bundle, signing, `/Applications`, and appearance. |
| PANEL-13 | Planned | — | — | — | — | Deprecated AX size override remains. |

## Exclusive live UI automation

Before any command that drives the installed app, cursor, keyboard, trackpad events, screenshots requiring UI manipulation, or the real UI test host, the fixing task must atomically create `/tmp/attic-exclusive-ui.lock`. If creation fails because the path already exists, live UI automation waits while non-UI work continues. The owner records its task, PID, and start time inside the lock directory and removes only its own lock in a guaranteed cleanup path. Builds, unit tests, analyzer runs, static screenshots, and read-only process inspection do not acquire the lock.

## Checkpoint history

| Integration commit | Contents | Verification |
| --- | --- | --- |
| Pending | Initial ledger and verified clean baseline | 333/333 Local Attic unit tests passed at `87c2062a536c42badac78a5ce2b21bbad7315d12`. |
