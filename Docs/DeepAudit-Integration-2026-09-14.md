# Deep Integration Audit — 2026-09-14

**Scope (assigned domain):** cross-feature workflows, app services, agent/MCP API and
command validation, settings persistence, startup/shutdown, error propagation,
lifecycle and security/reliability boundaries, test quality and missed regressions.

**Tree:** `/Users/taha/Developer/attic-task-panels-v2`, branch
`codex/attic-task-panels-v2`, HEAD `ae6418c`, audited with the large pre-existing
dirty worktree in place (unrelated edits preserved; source and tests untouched).
**Build flavor:** `Local` configuration (`ATTIC_LOCAL_ONLY`).

**Method:** full read of every file in the assigned domain, cross-domain caller
traces, second adversarial pass with counterexample search, a fresh
`build-for-testing` into private DerivedData (`/tmp/attic-audit-int-dd`), and an
offline windowless run inside `AtticUnitTestHost` via
`/tmp/attic-offline-xctest/run.zsh`.

## Verification evidence

- `xcodebuild build-for-testing -scheme Attic -configuration Local
  -derivedDataPath /tmp/attic-audit-int-dd -only-testing:AtticTests
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO` → `BUILD_EXIT=0`
  (pre-existing deprecation/unreachable-code warnings only).
- Offline in-host run `audit-int-domain` (products
  `/tmp/attic-audit-int-dd/Build/Products/Local`, log
  `/tmp/attic-offline-xctest/audit-int-domain.log`): **497 tests, 0 failures,
  4 skips**, all skips explained — official-SDK client gate (env-gated off),
  two exclusive-desktop visual tests, one deferred-CloudKit test.
- Earlier same-day full-suite baseline `swe-perfa1-full.log` (13:47 UTC,
  `/tmp/attic-perfa1-fixes-dd`): 799 tests, 0 failures, 4 skips on a tree
  differing from audited state only by canvas edits outside this domain.
- No performance magnitude is claimed without measurement; INT-01 is a
  structural finding (mechanism verified, energy impact unmeasured).

## Coverage matrix

| Subsystem | Files | Depth | Result |
|---|---|---|---|
| Startup/shutdown | `AtticApp.swift`, `AppDelegate.swift`, `AppCoordinator.swift` | Full read | Verified; termination gates on note flush (`.terminateCancel` on failure); `stop()` teardown symmetric with `start()`; test-host early-returns consistent |
| App services / DI | `AppCoordinator.swift` (runtime env), `PersistenceController` | Full read | Local-only container `cloudSyncEnabled:false`; UI/unit test hosts get in-memory store, isolated defaults suite, ephemeral credential, owner-token-gated temp attachment roots; no Keychain in tests |
| Agent server lifecycle | `AgentServer.swift` | Full read | Loopback-only `requiredLocalEndpoint`; deferred off-main credential load; generation-gated routing; fail-closed placeholder tokens; one residual: INT-03 |
| HTTP framing | `AgentHTTPRequest.swift` | Full read + tests | Incremental parse, conflicting Content-Length rejected, Transfer-Encoding rejected, 1 MiB cap pre-parse; smuggling dismissed |
| MCP protocol | `MCPRequestHandler.swift` | Full read + tests | Version negotiation correct (header default 2025-03-26), notification semantics correct, strict `params` validation; one residual: INT-02 |
| MCP tools | `AgentTaskTools.swift` | Full read | Validate-before-mutate in `update_task`; strict type checks; `parent_id` requires existing unfinished main task; note tools gated on `noteStore != nil` |
| Token store | `AgentAccessTokenStore.swift` | Full read + tests | 32-byte URL-safe tokens, insert-race handled, no ephemeral fallback, placeholder blacklist; no token ever logged (grep-verified) |
| Settings persistence | `AppSettings.swift`, `PanelUIState.swift`, settings views, `SettingsWindowController.swift` | Full read | Every key clamped/migrated; one-time agent-access opt-in forces `isAgentAccessEnabled=false` for existing installs; rect strings validated; window frame autosave constrained to live screens |
| Login item | `LoginItemService.swift`, `SettingsView.swift` | Full read | Refresh on settings appear + every app activation; error surfaced; external-change staleness dismissed (no API; activation refresh covers it) |
| Global hotkey | `GlobalHotKey.swift`, `MenuBarView.swift` | Full read | One residual: INT-04 silent registration failure while menu advertises ⌃⌥Space |
| Corner reveal/auto-hide | `CornerHoverMonitor.swift`, `CornerHoverStateMachine.swift` | Full read + tests | Event-driven while visible (zero timer), one-shot hide follow-up, epoch-guarded timers, dual-domain pointer monitors; one residual: INT-01 |
| Panel lifecycle | `AtticPanelController.swift`, `AtticPanel.swift`, `PanelSurfaceHostingView.swift`, `SubtaskPanelController.swift` | Full read | Generation-owned show/hide, hide gated on `noteDraft.flush()` before destructive state, watchdog+monitors bounded to capture, subtask surfaces tear down on hide and reconcile against live tasks |
| Note draft/recovery | `NoteDraftController.swift` | Full read | Conflict-aware flush, actor-owned generation-guarded recovery file, reserved-ID convergence with attachment imports, blocked navigation on failed flush |
| Note store/attachments | `NoteStore.swift`, `AttachmentFileStore.swift`, `NoteAttachmentTray.swift`, `NotesPanelContent.swift` | Full read | Replica-wide deletes, fresh transaction contexts, rollback + materialization cleanup on every failure path, staged imports, digest/byte verification; one bounded residual: INT-06 |
| Task store | `TaskStore.swift` | Full read + tests | Duplicate-safe UUID semantics, predicate-scoped fetches, rollback-on-failure, family rules enforced at store level, dormant sync in local-only |
| Canvas store | `CanvasStore*.swift`, `CanvasSession.swift` | Read for lifecycle/persistence/tombstones | Bounded history, debounced+termination view-state flush, gated cloud sync; one residual: INT-05 |
| Daily cleanup | `DailyCleanupService.swift` | Full read + tests | One-shot midnight timer (tolerance set), `completedAt` vs local day start, divergent-replica veto verified by tests |
| Task attachments | `TaskImageReference.swift`, `TaskImageFiles` | Read | Digest-verified copies, disposable read-only exports, bounded 64-entry thumbnail cache, cutoff/age-guarded launch sweep |
| Test host | `AtticUnitTestHost/main.swift` | Read | `.prohibited` activation policy — windowless by construction |

## Confirmed findings

### INT-01 — Parked pointer in the responsive ring holds a 50 ms timer and App Nap exemption indefinitely

- **Severity:** low-medium (idle work / battery) · **Confidence:** high (mechanism verified; energy impact unmeasured — structural finding)
- **Files:** `Attic/Services/CornerHoverStateMachine.swift:42-63` (cadence contract),
  `:89-90` (`activationDistance = 96`, `deactivationDistance = 144`),
  `Attic/Services/PanelGeometry.swift:15` (`triggerSize = 16`),
  `Attic/Services/CornerHoverMonitor.swift:376-429` (timer + `beginActivity`).
- **Mechanism:** the reveal hotspot is 16 pt, but "near the corner" is defined as
  within 96 pt (promote) / beyond 144 pt (demote). While the panel is hidden and
  the pointer sits inside that ring, `applySamplingCadence(.responsive)` keeps a
  repeating 50 ms `DispatchSourceTimer` and a
  `.userInitiatedAllowingIdleSystemSleep` activity. The state machine only demotes
  on distance, and a parked pointer generates no events — each timer tick
  re-evaluates the same in-ring position, so the hold has no time bound. The
  in-code comment states the fast timer and App Nap exemption are justified only
  for "the reveal decision window," but nothing bounds that window.
- **Trigger/reproduction:** park the cursor within ~96–144 pt of the configured
  corner but outside the 16 pt hotspot (e.g., top-right near menu-bar extras),
  panel hidden. Expected: approach pre-arming decays back to idle cadence after a
  bounded dwell with no hotspot entry. Actual: responsive cadence + activity
  assertion persist until the pointer moves >144 pt away.
- **Impact:** ~20 main-thread samples/s plus a continuous process-level
  "user-initiated" activity assertion that blocks App Nap for Attic for as long
  as the pointer lingers. Real but modest; on-laptop battery cost unmeasured.
- **Smallest fix:** add a bounded linger — after N seconds (e.g., 15–30 s) in
  `.responsive` with no hotspot entry, demote to `.idle` until the next pointer
  event re-enters the activation ring; alternatively shrink the ring toward the
  hotspot plus a small margin.
- **Verification plan:** unit test on `CornerHoverSamplingState` asserting decay
  to `.idle` after the dwell without movement; confirm `endActivity` via
  `holdsResponsivenessActivityForTesting`; native check with `powermetrics`
  before/after with a parked in-ring pointer.

### INT-02 — MCP `tools/call` silently coerces non-object `arguments` to `{}`

- **Severity:** low (protocol conformance / misleading success) · **Confidence:** high
- **File:** `Attic/Services/AgentServer/MCPRequestHandler.swift:106`
  (`let arguments = params["arguments"] as? [String: Any] ?? [:]`), contrasted
  with strict `params` validation at `:62-69`.
- **Mechanism:** `params` must be an object or the request gets `-32602`; the
  nested `arguments` member gets no such check — a string, array, number, or
  `true` becomes an empty object. Observable divergence:
  `tools/call {name:"list_tasks", arguments:"high"}` returns the full task list
  with `isError:false` instead of a protocol error; the client's intended filter
  is silently dropped. Mutating tools degrade gracefully (missing-field tool
  errors), so no data corruption results.
- **Expected vs actual:** per JSON-RPC/MCP, a present-but-non-object `arguments`
  is invalid params (`-32602`); actual behavior is silent coercion.
- **Smallest fix:** `if let raw = params["arguments"], !(raw is [String: Any])
  { return -32602 }` — mirror the `params` guard.
- **Verification plan:** add `MCPRequestHandlerTests` cases for `arguments` as
  string/array/number asserting `-32602`; confirm existing tool tests still pass.

### INT-03 — `AgentServer.stop()` does not tear down already-accepted connections

- **Severity:** low (lifecycle hygiene) · **Confidence:** high for mechanism; low for impact
- **Files:** `Attic/Services/AgentServer/AgentServer.swift:136-143` (`stop()`),
  `:145-173` (receive loop), `:203-207` (generation gate inside routed task).
- **Mechanism:** `stop()` cancels the listener and bumps `generation`, but no
  connection table exists — accepted `NWConnection`s are never cancelled. A
  client holding a socket with no data pending keeps it open indefinitely. Any
  completed request on a stale connection is cancelled at `route()`'s
  `self.generation == generation` check, and pre-route rejections (401/403/404/
  405/400/413) all end in `connection.cancel()` — so no handler access is
  possible after stop; this is bounded resource linger, not a security hole.
- **Trigger:** enable agent access, connect a client, open a socket and send
  nothing (or a partial request), disable access → socket remains established.
- **Smallest fix:** keep a weak/ID-keyed connection set; cancel all on `stop()`.
- **Verification plan:** integration test that opens a TCP connection, stops the
  server, and asserts the socket closes; existing restart test must still pass.

### INT-04 — Global hotkey registration failure is silent while the menu advertises the shortcut

- **Severity:** low (UX / reliability) · **Confidence:** high
- **Files:** `Attic/Services/GlobalHotKey.swift:27-78` (`register()` returns on
  `InstallEventHandler` failure at `:63` and swallows `RegisterEventHotKey`
  failure at `:74-77` with no log or status), `Attic/Views/MenuBarView.swift:16`
  (menu shows ⌃⌥Space unconditionally), `Attic/App/AppCoordinator.swift:174-176,345`
  (hardcoded chord, result ignored).
- **Trigger:** chord conflict (another app's hotkey, an Input Sources binding) or
  Carbon handler failure → the advertised New Task shortcut silently does nothing;
  no setting, no log, no UI indication distinguishes "registered" from "failed."
- **Smallest fix:** expose `isRegistered`/`registrationError`, `os_log` the
  failure, and surface a status/warning in General settings.
- **Verification plan:** inject a registration seam returning a Carbon error in a
  test; assert the failure state propagates. Manual: bind ⌃⌥Space elsewhere and
  confirm the warning appears.

### INT-05 — Canvas tombstones are never physically deleted; payloads retained and fetched forever

- **Severity:** low-medium (storage growth, fetch/memory inflation over time) ·
  **Confidence:** high (structural)
- **Files:** `Attic/Services/CanvasStorePersistence.swift` (tombstone writes at
  `:545-589`; replica fetches at `:458-535` load all replicas and filter
  `!tombstoned` post-fetch, e.g. `:135,149,199,270,368`); no `context.delete`
  exists anywhere under `Attic/Services/Canvas*.swift` or `Attic/Canvas/`
  (grep-verified; `compactMap`/`compactErrorMessage` hits are unrelated).
- **Mechanism:** every canvas delete (stroke, image, board, semantic object) is a
  tombstone flag preserving the row and its payload. Tombstones exist for
  CloudKit merge, but local-only builds never sync — dead rows accumulate
  permanently, are fetched on every per-canvas replica load, and keep their byte
  payloads in the store.
- **Impact:** unbounded growth of `CanvasStrokeItem`/`CanvasImageItem`/
  `CanvasBoardItem` tables proportional to lifetime edit-delete churn; each
  refresh pays fetch+memory for dead rows. Not measured; magnitude depends on
  usage.
- **Smallest fix:** a bounded compaction pass (startup or idle) that physically
  deletes tombstoned rows older than a grace window — in local-only builds all
  tombstones qualify; keep the machinery for future sync re-enablement.
- **Verification plan:** seed tombstoned rows via store ops, run compaction,
  assert physical row count drops and `fetchCanvasReplicas` presentation is
  unchanged; regression test pins "tombstone older than X is physically gone in
  local-only."

### INT-06 — Note-attachment orphan sweep can delete a file mid-import before its row commits

- **Severity:** low (bounded, self-healing race) · **Confidence:** high for the
  window; matches the reliability audit's R-03 classification
- **Files:** `Attic/Services/AttachmentFileStore.swift:491-498` (`importOne`
  moves each staged file into its final `<uuid>/<digest>` directory during the
  copy loop, before rows commit), `:356-399` (`cleanOrphans` deletes every
  digest dir not in `expected` — committed rows only — with no recency check),
  `Attic/Services/NoteStore.swift:1023-1064` (`reconcileFileStorage` task can
  acquire the file-store actor between `importOne` awaits).
- **Mechanism:** import file N lands in its final directory mid-loop → an
  unrelated save triggers refresh → `reconcileMetadata`'s orphan sweep sees no
  committed row → deletes the directory → commit proceeds → post-commit
  reconciliation flags `needsMaterialization` → `repairMaterializations`
  re-materializes from the row payload; `ensureMaterialized` also repairs
  on-demand reads. Net effect: a transient missing file between sweep and repair.
- **Asymmetry worth fixing:** the task-attachment sweep
  (`removeUnreferencedMaterializations`, `:284-339`) protects any directory
  created/modified after a cutoff precisely because "an import [is] still being
  bound"; the notes-side `cleanOrphans` applies no such age guard.
- **Smallest fix:** skip digest directories younger than a small grace window in
  `cleanOrphans` (same `isOld` logic as the task sweep), or include in-flight
  import IDs in `expected`.
- **Verification plan:** test that interleaves a suspended multi-file import with
  a reconcile pass and asserts the materialization exists at commit without
  relying on repair; existing `testReconcileRemovesOnlyUnreferencedMaterializations`
  must keep passing.

## Dismissed hypotheses (checked, not bugs)

- **Note orphan sweep deleting task attachments** — note attachments live under
  `Application Support/Attic/Attachments/v1`; task images under
  `Attic/TaskImages` (`TaskImageReference.swift`); separate roots, and the task
  sweep is ID-referenced + age-cutoff + bounded. False positive.
- **Post-stop handler access on a stale connection** — `route()` checks
  `self.listener != nil && self.generation == generation` inside the routed task
  before calling `handler.handle`; every other path ends in `send`→cancel.
- **HTTP request smuggling** — conflicting duplicate `Content-Length` rejected,
  `Transfer-Encoding` rejected, body cap enforced on the raw buffer before parse.
- **Browser/DNS-rebinding access** — any `Origin` header → 403; `Host` must be
  `127.0.0.1` (with a numeric port suffix only); listener is bound to the IPv4
  loopback endpoint via `requiredLocalEndpoint`; bearer compare is
  constant-time.
- **Token leakage** — no `print`/`NSLog`/`logger` emits the token; the copied
  setup prompt instructs the client to treat it as secret; settings shows only a
  summary string tested to never contain it.
- **Blank-draft import creating duplicate notes** — the reserved logical note ID
  is shared between autosave (`NoteDraftController.flush`, `:453-480`) and the
  import transaction (`NoteStore.swift:407-427`); both converge on one row, and
  `completeAttachmentImport` only lets the exact initiating session adopt it.
- **Termination losing a dirty note** — `applicationShouldTerminate` gates on
  `noteDraft.flush()` and answers `.terminateCancel` (revealing Notes); the
  discarded re-flush in `applicationWillTerminate` runs only after the gate
  passed.
- **Login-item staleness** — `refresh()` runs on settings appear and every app
  activation; `SMAppService` exposes no change notification, so this is the
  available ceiling.
- **`stop()`'s discarded `noteDraft.flush()`** — same reasoning as termination:
  a failure there is unreachable without an intervening user edit.
- **Keyboard-focus lock pinning the panel forever** — `MainPanelAutoHidePolicy`
  expires pure editor-focus locks after 1.5 s without keyboard input; drafts,
  conflicts, imports and menus retain independent locks.
- **Duplicate-UUID cross-device data loss** — dedup is presentation-only;
  mutations/deletes fan to all replicas; divergent replicas veto daily cleanup
  (tested); refresh never persists replica cleanup.

## Test-quality assessment

**Strengths (verified by reading assertions, not just pass counts):**

- `AgentServerIntegrationTests` runs a real listener on port 0 with real HTTP
  through `URLSession`, covering deferred off-main credential loading,
  stop-during-pending-approval, fail-closed placeholders, 401 for missing/wrong/
  placeholder tokens, 403 on `Origin`, and stop→restart rebind.
- `MCPRequestHandlerTests` covers parse errors, invalid JSON-RPC, notification
  semantics, ID validation, version negotiation/fallback, tool validation, and
  per-tool mutation effects against a real `TaskStore`/`NoteStore`.
- `AgentHTTPRequestTests` covers incremental parsing at 1-byte chunks, split
  terminators, conflicting Content-Length, Transfer-Encoding, negative lengths,
  and loopback Host/Auth enforcement.
- `NoteAttachmentTests` is the deepest suite: suspended blank-draft imports,
  external deletion mid-import, sort-index revalidation, refresh-failure
  retention, cancellation cleanup, promised-file timeout/late delivery,
  symlink/directory rejection, corruption repair, orphan-sweep scoping.
- `NoteDraftControllerTests` covers recovery generations, conflict paths
  (remote change/deletion, use-remote/overwrite/save-as-new), blocked switching
  on failed flush, autosave coalescing, and session restoration.
- `TaskStoreTests`/`DailyCleanupServiceTests` cover duplicate-replica semantics,
  rollback on every failed mutation, stale-reference no-ops, and divergent-
  replica cleanup veto.
- `CornerHoverStateMachineTests` encodes the cadence contract, hysteresis,
  timer epochs, and the hide-completion handshake.
- `AppSettingsTests` covers test-host isolation, attachment-root confinement
  with ownership tokens, migrations, and clamping.

**Gaps mapped to findings:**

- No test asserts `-32602` for non-object `params.arguments` (INT-02).
- No test asserts connection teardown on `AgentServer.stop()` (INT-03).
- Nothing testable exists for hotkey registration failure — no status surface
  (INT-04); a fix should add the seam and the test together.
- No test bounds the duration of `.responsive` cadence or the activity hold
  (INT-01); existing tests encode today's contract, so a decay fix needs a new
  assertion rather than relying on current ones.
- No test physically deletes tombstoned canvas rows or bounds their
  accumulation (INT-05).
- The orphan-vs-import window (INT-06) is not directly exercised; existing tests
  cover each side independently but not the interleaving.
- `AgentServer`/`MCPRequestHandler` run on `@MainActor`; there is no
  large-payload `tools/call` latency gate. Structural note only — `list_tasks`
  on a multi-thousand-row store serializes on the main thread; bounded by
  payload size, no test asserts it.

## Minor observations (not filed as findings)

- `NoteStore.lastErrorMessage` and `TaskStore.lastErrorMessage` are shared
  mutable slots read by both UI and the MCP layer; a failure on one surface can
  overwrite the other's message. Transient and self-correcting.
- `AgentServer.setupToken` keeps the live bearer token in a `@Published`
  property — required for the copy-prompt flow; never logged or sent anywhere
  else.
- `update_task`/`update_note` validate all arguments before mutating; verify
  future tools keep that ordering.

## Prioritized fixes

1. **INT-05** — bounded local-only tombstone compaction (storage growth compounds
   silently over the app's lifetime).
2. **INT-01** — decay the responsive hover ring after a bounded no-entry dwell
   (idle battery cost for a common pointer position).
3. **INT-02** — reject non-object `arguments` with `-32602` (one-line fix + test).
4. **INT-04** — surface hotkey registration failure (log + status + settings row).
5. **INT-06** — add the age guard to `cleanOrphans` for parity with the task
   sweep (cheap hardening of an already-bounded race).
6. **INT-03** — track and cancel accepted connections on `stop()` (hygiene).

## Verification plan for fixes

- Rebuild `build-for-testing` into private DerivedData, rerun the offline host
  suite plus new per-fix tests named above; keep the 799-test full-suite gate
  green.
- INT-01 additionally wants a `powermetrics`/sample comparison with a parked
  in-ring pointer before/after; INT-05 wants a seeded-store compaction test.
- No fix in this report touches CloudKit, APNs, iPhone, TestFlight, or
  production signing; local-only constraints stay intact.

## Limitations

- No GUI relaunch, pointer injection, or live menu-bar interaction was
  performed; all windowing conclusions are source- and host-test-based.
- INT-01's energy cost and INT-05's storage magnitude are structural claims;
  neither was measured.
- Deferred services (CloudKit, APNs, iPhone, TestFlight, Production) were
  checked for dormancy/gating only and are not claimed to work.
- `AgentServerIntegrationTests.testOfficialMCPClientInteroperability` is
  env-gated off in this environment; real-SDK interop was not exercised here.
- The worktree's dirty canvas edits were audited in their current state; a
  concurrently-evolving tree means line numbers may drift.
