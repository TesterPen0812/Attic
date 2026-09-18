# Attic whole-app audit — 2026-09-18

## Provenance and limits

- Imported checkout: `main` at `ea14c8e48e530558a7e0a701bf87a87a224f2562`.
- Intended source baseline: merged `main` containing
  `62b2e0e403040e4c88998ed02de11367ab3386e5`.
- The imported checkout is one Replit-configuration commit ahead of that source
  baseline. The import commit remains separate and was preserved unchanged.
- Audit branch: `audit/whole-app-2026-09-18`.
- Linux cannot build or execute AppKit, SwiftUI, SwiftData, Xcode tests, signing,
  native accessibility, gestures, or Instruments. Findings below are source and
  test-inventory evidence unless explicitly identified as historical native
  evidence. No secret, production store, CloudKit environment, or GitHub setting
  was accessed.

## Architecture and ownership map

- `AppCoordinator` is the process-lifetime composition root. It owns the shared
  model container; task, note, and Canvas stores; `CanvasSession`; note draft;
  main and auxiliary panels; corner monitor; cleanup service; settings window;
  global shortcut; and loopback agent server. It orders startup, shutdown, and
  termination veto.
- `TaskStore` is the main-actor owner of task/subtask presentation and mutation.
  Presentation selects one UUID winner; mutation, deletion, family operations,
  and cleanup resolve every physical replica. Failed saves roll back and replace
  the context.
- `NoteStore` owns note and attachment metadata presentation and all-replica
  mutation. `NoteDraftController` owns editor state, autosave, conflicts, and
  recovery checkpoints. `AttachmentFileStore` owns private materializations,
  staged import cleanup, hashing, security-scoped reads, and orphan cleanup.
- `CanvasStore` owns persisted boards, strokes, images, semantic objects, replica
  resolution, and rollback/reload. `CanvasSession` owns transient selection,
  tools, view state, bounded history, command routing state, and image-import
  tasks. Native Canvas views own gesture and text-editing state; the session owns
  work intended to survive transient view teardown.
- `AtticPanelController`, `SubtaskPanelController`, `CornerHoverMonitor`, and
  panel-hosting views divide window lifetime, reveal/hide transitions, pinning,
  pointer corridors, focus, and transient interaction interruption.
- `AgentServer` owns the loopback listener and request generation. HTTP parsing,
  MCP validation, bearer-token storage, and task/note tools are separate layers.

## Coverage matrix

| Area / journey | Source paths traced | Result |
| --- | --- | --- |
| Startup, shutdown, failed quit | App delegate/coordinator, draft flush, Canvas cancellation, services | One new confirmed ordering defect; see F-01. |
| Tasks, Backlog, subtasks | Store create/update/move/reorder/delete/cleanup, row/panel callers and tests | Replica fan-out and rollback defenses verified; no new confirmed defect. |
| Task panels and windows | Main/transient/pinned controllers, corner state machine, focus/hide paths | Generation and barrier ownership verified; native multi-display and physical-input behavior not run. |
| Keyboard and undo | Panel state, Canvas command route, history reset/cancellation | Focused-editor routing and bounded Canvas history verified; native responder-chain behavior not run. |
| Notes and drafts | Store, draft controller, recovery, conflict and failed-save paths | Failed saves preserve dirty draft/recovery and can veto quit; no other new confirmed defect. |
| Note attachments | Import staging, limits, cancellation, materialization, repair and cleanup | Cancellation and cleanup ownership verified. A suspected reconciliation retry defect was disproved. |
| Canvas | Session, store extensions, interaction, rendering/cache, history, commands | Lifecycle/store boundaries mapped. A suspected deinit gap was disproved for the production owner. |
| Settings and themes | Settings model, appearance observation, settings controller/views | Startup observation and teardown ownership verified; visual/Reduce Transparency behavior not run. |
| Persistence and recovery | Task/note/Canvas rollback, fresh contexts, duplicate UUID resolution, cleanup | Existing duplicate-safe and failed-save defenses verified; crash/power-loss and malformed-store execution not run. |
| Agent integration | Listener, parser, auth/token, MCP routing, start/stop, tools | Security gates verified. Known idle-connection stop hygiene remains backlog, not a new finding. |
| Accessibility and UX | Labels/actions and historical ledgers sampled across panels/Canvas/settings | Source defenses sampled; VoiceOver, focus delivery, gestures, appearance, and performance require macOS. |
| Large data/resource growth | Existing performance gates, bounded history/cache, fetch/reconcile paths | Structural risks remain unmeasured; no latency or memory improvement is claimed. |

## Prioritized findings ledger

### F-01 — failed quit cancels valid Canvas work

- **Class:** new confirmed defect.
- **Severity / confidence:** Medium / high.
- **Locations:** `AppCoordinator.prepareForTermination`; Canvas session lifecycle
  cancellation; app-delegate termination decision.
- **Trigger:** start a Canvas image import, switch to Notes, leave a dirty draft
  whose flush fails or conflicts, then quit.
- **Causal trace:** termination preparation cancels Canvas interaction and all
  session-owned imports, then attempts the note flush. A failed flush returns a
  termination veto, so the process and UI remain alive after irreversible Canvas
  cancellation.
- **Impact:** deliberate Canvas import work can be lost even though quit was
  rejected to protect unsaved note work. The native Canvas surface is also
  rebuilt unnecessarily.
- **Existing defenses/tests:** note flush correctly retains dirty recovery state
  and vetoes termination; Canvas imports intentionally survive transient panel
  changes; successful stop and termination cancel imports. No test covered the
  cross-subsystem failed-quit ordering.
- **Minimal remedy:** attempt the veto-capable note flush first. Only after it
  succeeds may termination preparation cancel Canvas work and flush view state.
- **Validation:** focused ordering tests for failed and successful preparation;
  on macOS, run an in-flight import plus forced note-save failure quit scenario,
  then the successful-quit counterpart.

#### Ownership change ledger

- **Before:** termination preparation gave Canvas irreversible teardown ownership
  before Notes decided whether termination was allowed.
- **After:** Notes owns the veto phase. Canvas receives irreversible termination
  only after every veto-capable prerequisite succeeds. Normal `stop()` remains
  the final idempotent service teardown path.
- **Why this is bounded:** no model, schema, gesture, visual, signing, CloudKit,
  or replica behavior changes. The successful-termination behavior is unchanged;
  only the failed-termination path preserves ongoing Canvas work.

### Known backlog retained without implementation

- The non-local build path still contains the former-owner CloudKit identity.
  This is the documented release-only identity concern, not an active local-only
  defect. Identity, signing, container, mobile, CloudKit, and APNs edits are
  explicitly deferred.
- Accepted idle agent connections are not actively closed by `stop()`. Existing
  listener generation checks prevent post-stop handler access, so this remains
  bounded resource hygiene rather than an authentication bypass.
- Historical Deep Audit batches 3–6 remain candidate work subject to their own
  reproduction, measurement, and native gates. They were not treated as blanket
  authority for this patch.

## Disproved hypotheses and verified defenses

- **Attachment reconciliation cancellation:** disproved. Reconciliation is
  cancelled only when a newer, different metadata signature starts; the newer
  generation owns the signature and retry state. Same-signature presentation
  refresh does not cancel the active pass.
- **Canvas session deinit cancellation:** not a current production defect.
  `AppCoordinator` is the sole process-lifetime owner and explicitly cancels on
  successful termination and stop. Active import tasks retain the session, so a
  deinitializer would not be an effective cancellation boundary.
- Task, note, and Canvas failed saves roll back and refresh their contexts.
- Presentation UUID deduplication does not narrow mutations to one physical
  replica.
- Note import cancellation removes staged/final materializations and rolls back
  metadata work.
- Agent access is opt-in; listener binding is loopback-only; Host, Origin, path,
  method, request-size, malformed-length, bearer, and JSON-RPC checks remain in
  place; credential failure does not open an unauthenticated listener.
- Local-only startup does not request CloudKit, APNs, or remote notifications.

## Not examined or not executable here

- Native compilation, strict-concurrency diagnostics, static analyzer, XCTest,
  UI tests, signing, entitlements inspection, and generated app execution.
- VoiceOver, keyboard focus delivery, Reduce Motion/Transparency, physical
  trackpad and pointer behavior, native drag/drop and file providers.
- Crash/power-loss durability, real SwiftData corruption, Keychain prompts,
  multi-process token startup, IPv6 loopback behavior, and CloudKit imports.
- Instruments measurements for active Canvas drawing/import, large stores,
  long-running corner monitoring, attachment sweeps, and MCP bursts.
- Deferred iPhone, CloudKit, APNs, TestFlight, and production behavior.