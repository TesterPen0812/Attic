# Attic whole-app audit — 2026-09-18

## Provenance and limits

- Imported checkout: `main` at `ea14c8e48e530558a7e0a701bf87a87a224f2562`.
- Intended source baseline: merged `main` containing
  `62b2e0e403040e4c88998ed02de11367ab3386e5`.
- The imported checkout is one Replit-configuration commit ahead of that source
  baseline. The import commit remains separate and was preserved unchanged.
- Audit branch: `audit/whole-app-2026-09-18`. Commits before this revision of
  the report: `75c9e12` (first audit report) and `586efb4` (F-01 fix, quit
  ordering). The second-pass fixes (F-02, F-03) and this report revision are
  committed after those; see `git log` on the branch for their hashes.
- Linux cannot build or execute AppKit, SwiftUI, SwiftData, Xcode tests, signing,
  native accessibility, gestures, or Instruments. Findings below are source and
  test-inventory evidence unless explicitly identified as historical native
  evidence. No secret, production store, CloudKit environment, or GitHub setting
  was accessed. No dependency was installed; the Ruby project-generation check
  could not run because its gems are absent from this environment.
- Only the Swift 5.8 parser is available here (`swiftc -parse`). It proves the
  edited files still parse; it does not type-check, build, or run tests. No
  compile or test success is claimed anywhere in this document.

## Method

The audit ran in two passes.

1. **First pass (journey tracing).** The main auditor traced startup, shutdown,
   failed quit, task/note/Canvas mutation and rollback, attachment import
   cancellation, panel lifetime, and agent-server security gates by reading the
   owning files directly (about 2,700 lines), which produced F-01.
2. **Second pass (repository-wide line coverage).** Every production Swift file
   was assigned to exactly one reader. Eleven read-only explorer passes were
   delegated, each instructed to read every line of its assigned files and to
   report the exact ranges read, candidate findings with decisive source quotes,
   disproved hypotheses, and existing defenses/tests. The app-lifecycle and
   agent-server group was read directly by the main auditor instead (its
   delegated pass did not finish within budget and was cancelled). Every
   candidate finding an explorer raised was re-read in source by the main
   auditor before it was accepted, downgraded, or rejected; the rejected ones
   are listed under "Disproved hypotheses" with the reason.

Fix policy for this environment: only narrow, type-obvious edits with a unit test
in an existing test file (so the generated Xcode project does not change), each
preserving the constraints listed in the brief (failed-save rollback, durable
drafts, duplicate-safe UUID handling, import cancellation ownership, undo
isolation, security gates, local-only behaviour). Anything else is documented
with a macOS validation plan instead of being changed.

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

### Production sources — 97 files, 37,270 lines, all read in full

Reader key: **main** = read directly by the main auditor; any other name is the
delegated explorer pass whose report lists the file with a full `1-N` range.
Line counts are those of the audited tree after the fixes: this audit grew
`AppCoordinator.swift` by 16 lines (F-01), `CanvasSurfaceMacHelpers.swift` by
11 (F-02), and `MCPRequestHandler.swift` by 11 (F-03); every other production
count is unchanged.

| Area | File | Lines | Reader |
| --- | --- | --- | --- |
| App lifecycle | `Attic/App/AppCoordinator.swift` | 453 | main (1-144, 145-160, 160-316, 316-420, 416-453) |
| App lifecycle | `Attic/App/AppDelegate.swift` | 43 | main |
| App lifecycle | `Attic/App/AtticApp.swift` | 84 | main |
| App lifecycle | `Attic/App/CanvasEditCommandRoute.swift` | 78 | canvas-session |
| App lifecycle | `Attic/Services/GlobalHotKey.swift` | 86 | main |
| App lifecycle | `Attic/Services/LoginItemService.swift` | 40 | main |
| App lifecycle | `Attic/Services/PersistenceController.swift` | 272 | main |
| Agent server | `Attic/Services/AgentServer/AgentAccessTokenStore.swift` | 93 | main |
| Agent server | `Attic/Services/AgentServer/AgentHTTPRequest.swift` | 72 | main |
| Agent server | `Attic/Services/AgentServer/AgentServer.swift` | 267 | main |
| Agent server | `Attic/Services/AgentServer/AgentTaskTools.swift` | 473 | main |
| Agent server | `Attic/Services/AgentServer/MCPRequestHandler.swift` | 168 | main |
| Tasks store | `Attic/Services/TaskStore.swift` | 1470 | tasks-store |
| Tasks store | `Attic/Services/DailyCleanupService.swift` | 96 | tasks-store |
| Tasks store | `Attic/Models/TaskItem.swift` | 77 | tasks-store |
| Tasks store | `Attic/Models/TaskTypes.swift` | 155 | tasks-store |
| Tasks store | `Attic/Models/TaskDragPayload.swift` | 143 | tasks-store |
| Tasks store | `Attic/Models/TaskImageReference.swift` | 183 | tasks-store; main re-read 110-183 |
| Tasks views | `Attic/Views/Panel/TaskRowView.swift` | 839 | tasks-views |
| Tasks views | `Attic/Views/Panel/TaskSectionView.swift` | 86 | tasks-views |
| Tasks views | `Attic/Views/Panel/TaskFamilyView.swift` | 57 | tasks-views |
| Tasks views | `Attic/Views/Panel/TaskStatusButton.swift` | 26 | tasks-views |
| Tasks views | `Attic/Views/Panel/TaskComposerAttachments.swift` | 274 | tasks-views |
| Tasks views | `Attic/Views/Panel/TaskImageAttachments.swift` | 521 | tasks-views |
| Tasks views | `Attic/Views/Panel/TaskAttachmentDrop.swift` | 556 | tasks-views |
| Tasks views | `Attic/Views/Panel/SubtaskPanelContent.swift` | 798 | tasks-views |
| Tasks views | `Attic/Design/TaskActionsMenu.swift` | 68 | tasks-views |
| Notes core | `Attic/Services/NoteStore.swift` | 1313 | notes-core; main re-read 191-256, 365-450, 955-970 |
| Notes core | `Attic/Services/NoteDraftController.swift` | 752 | notes-core |
| Notes core | `Attic/Services/AttachmentFileStore.swift` | 576 | notes-core |
| Notes core | `Attic/Services/NoteAttachmentPlatformSupport.swift` | 193 | notes-core |
| Notes core | `Attic/Models/NoteAttachment.swift` | 112 | notes-core |
| Notes core | `Attic/Models/NoteInlineAnchor.swift` | 208 | notes-core |
| Notes core | `Attic/Models/NoteItem.swift` | 27 | notes-core |
| Notes views | `Attic/Views/Panel/NotesPanelContent.swift` | 1048 | notes-views |
| Notes views | `Attic/Views/Panel/NoteAttachmentTray.swift` | 1890 | notes-views |
| Notes views | `Attic/Views/Panel/NoteInlineCards.swift` | 567 | notes-views |
| Canvas store | `Attic/Services/CanvasStore.swift` | 524 | canvas-store; main re-read 360-392 |
| Canvas store | `Attic/Services/CanvasStorePersistence.swift` | 609 | canvas-store; main re-read 376-392 |
| Canvas store | `Attic/Services/CanvasStoreBoards.swift` | 166 | canvas-store |
| Canvas store | `Attic/Services/CanvasStoreStrokes.swift` | 187 | canvas-store |
| Canvas store | `Attic/Services/CanvasStoreImages.swift` | 405 | canvas-store, canvas-session |
| Canvas store | `Attic/Services/CanvasStoreSemanticObjects.swift` | 168 | canvas-store |
| Canvas store | `Attic/Services/CanvasStoreReplicaResolution.swift` | 289 | canvas-store |
| Canvas store | `Attic/Services/CanvasStoreLifecycle.swift` | 129 | canvas-store |
| Canvas store | `Attic/Services/CanvasStoreCloudSync.swift` | 150 | canvas-store |
| Canvas store | `Attic/Canvas/CanvasTypes.swift` | 548 | canvas-store |
| Canvas store | `Attic/Canvas/CanvasStrokeCodec.swift` | 108 | canvas-store; main re-read 60-108 |
| Canvas store | `Attic/Canvas/CanvasImageTypes.swift` | 676 | canvas-store; main re-read 205-225 |
| Canvas store | `Attic/Models/CanvasBoardItem.swift` | 55 | canvas-store |
| Canvas store | `Attic/Models/CanvasStrokeItem.swift` | 42 | canvas-store |
| Canvas store | `Attic/Models/CanvasImageItem.swift` | 182 | canvas-store |
| Canvas store | `Attic/Models/CanvasSemanticObjectItem.swift` | 29 | canvas-store |
| Canvas session | `Attic/Canvas/CanvasSession.swift` | 1763 | canvas-session |
| Canvas session | `Attic/Canvas/CanvasImageImporter.swift` | 408 | canvas-session |
| Canvas session | `Attic/Canvas/CanvasSurfaceInteraction.swift` | 257 | canvas-session |
| Canvas session | `Attic/Canvas/CanvasInputStateMachine.swift` | 122 | canvas-session |
| Canvas session | `Attic/Canvas/CanvasSemanticInteraction.swift` | 360 | canvas-session |
| Canvas session | `Attic/Canvas/CanvasSemanticObject.swift` | 101 | canvas-session, canvas-store |
| Canvas session | `Attic/Canvas/CanvasViewport.swift` | 206 | canvas-session |
| Canvas session | `Attic/Canvas/CanvasControls.swift` | 241 | canvas-session |
| Canvas native | `Attic/Canvas/CanvasSurface.swift` | 94 | canvas-native |
| Canvas native | `Attic/Canvas/CanvasSurfaceMac.swift` | 1376 | canvas-native |
| Canvas native | `Attic/Canvas/CanvasSurfaceMacHelpers.swift` | 1353 | canvas-native; main re-read 340-412, 556-630 |
| Canvas native | `Attic/Canvas/CanvasSurfaceRenderer.swift` | 631 | canvas-native |
| Canvas native | `Attic/Canvas/CanvasSemanticRenderer.swift` | 110 | canvas-native |
| Canvas native | `Attic/Canvas/CanvasImageExportDocument.swift` | 19 | canvas-native |
| Canvas native | `Attic/Canvas/CanvasSendable.swift` | 6 | canvas-native |
| Canvas native | `Attic/Canvas/CanvasSurfaceIOS.swift` | 398 | canvas-native (deferred platform; read, not audited for defects) |
| Canvas native | `Attic/Views/Panel/CanvasPanelContent.swift` | 943 | canvas-native |
| Settings/design | `Attic/Services/AppSettings.swift` | 400 | settings-design |
| Settings/design | `Attic/Views/Settings/SettingsView.swift` | 148 | settings-design |
| Settings/design | `Attic/Views/Settings/GeneralSettingsView.swift` | 64 | settings-design |
| Settings/design | `Attic/Views/Settings/PanelSettingsView.swift` | 148 | settings-design |
| Settings/design | `Attic/Views/Settings/AppearanceSettingsView.swift` | 448 | settings-design |
| Settings/design | `Attic/Views/Settings/AgentAccessSettingsView.swift` | 196 | settings-design |
| Settings/design | `Attic/Views/Settings/AboutSettingsView.swift` | 64 | settings-design |
| Settings/design | `Attic/Views/Settings/SettingsComponents.swift` | 195 | settings-design |
| Settings/design | `Attic/Views/Settings/SettingsSection.swift` | 51 | settings-design |
| Settings/design | `Attic/Views/Settings/CornerPicker.swift` | 77 | settings-design |
| Settings/design | `Attic/Views/MenuBarView.swift` | 56 | settings-design |
| Settings/design | `Attic/Design/AtticTheme.swift` | 145 | settings-design |
| Settings/design | `Attic/Design/AtticStyle.swift` | 398 | settings-design |
| Settings/design | `Attic/Design/AtticPanelTheme.swift` | 631 | settings-design |
| Settings/design | `Attic/Design/Squircle.swift` | 106 | settings-design |
| Main window | `Attic/Window/AtticPanelController.swift` | 1171 | window-main |
| Main window | `Attic/Window/AtticPanel.swift` | 1418 | window-main; main re-read 800-820, 950-980 |
| Main window | `Attic/Window/PanelUIState.swift` | 253 | window-main |
| Main window | `Attic/Window/PanelSection.swift` | 69 | window-main |
| Main window | `Attic/Window/PanelSurfaceHostingView.swift` | 119 | window-main; main re-read 50-70 |
| Main window | `Attic/Views/Panel/AtticPanelView.swift` | 1020 | window-main |
| Subtask/corner | `Attic/Window/SubtaskPanelController.swift` | 1126 | window-sub-corner |
| Subtask/corner | `Attic/Services/SubtaskPanelLayout.swift` | 557 | window-sub-corner |
| Subtask/corner | `Attic/Services/CornerHoverMonitor.swift` | 521 | window-sub-corner |
| Subtask/corner | `Attic/Services/CornerHoverStateMachine.swift` | 337 | window-sub-corner |
| Subtask/corner | `Attic/Services/PanelGeometry.swift` | 640 | window-sub-corner; main re-read 92-175 |
| Subtask/corner | `Attic/Window/SettingsWindowController.swift` | 93 | window-sub-corner |

### Unit tests — 33 files, 24,477 lines

Tests were read to map which defenses are test-backed, not to audit them for
defects. "Full" means the reader reports a complete `1-N` read; "declarations"
means every `func test` declaration plus the bodies relevant to the assigned
production files; "grep-mapped" means coverage was located by search without a
full read; "inventory" means only the test names were listed by the main
auditor.

| Test file | Lines | Read depth (reader) |
| --- | --- | --- |
| `AppSettingsTests.swift` | 1153 | full (settings-design, window-main); F-01 tests added here |
| `CanvasDocumentTests.swift` | 303 | full (canvas-store) |
| `CanvasDomainTests.swift` | 3848 | full (canvas-session); grep-mapped (canvas-store); F-02 tests added here |
| `CanvasImageTests.swift` | 1137 | full (canvas-session) |
| `CanvasPerformanceGateTests.swift` | 775 | grep-mapped (canvas-native) |
| `CanvasPrecisionTests.swift` | 41 | grep-mapped (canvas-native) |
| `CanvasRenderCacheTests.swift` | 684 | grep-mapped (canvas-native) |
| `CanvasSessionTests.swift` | 781 | full (canvas-session) |
| `CanvasStoreTests.swift` | 1262 | full (canvas-store) |
| `CornerHoverStateMachineTests.swift` | 845 | declarations (window-sub-corner) |
| `MCPRequestHandlerTests.swift` | 404 | main: 1-130, 236-250, 357-372; F-03 tests added here |
| `NoteAttachmentTests.swift` | 1747 | grep-mapped (notes-core) |
| `NoteDraftControllerTests.swift` | 1162 | grep-mapped (notes-core); declarations (notes-views) |
| `NoteInlineCardsTests.swift` | 753 | declarations (notes-views) |
| `NoteStoreTests.swift` | 322 | full (notes-core) |
| `PanelGeometryTests.swift` | 1632 | declarations (window-sub-corner) |
| `PanelSquircleGeometryTests.swift` | 1436 | full (window-main) |
| `PanelSquircleSettingsTests.swift` | 141 | full (settings-design) |
| `PanelSurfaceHostingViewTests.swift` | 198 | full (window-main) |
| `SettingsPresentationTests.swift` | 268 | full (settings-design) |
| `SubtaskPanelControllerTests.swift` | 1403 | declarations (window-sub-corner) |
| `SubtaskPanelTests.swift` | 531 | full (tasks-views) |
| `SubtaskTests.swift` | 405 | declarations (window-sub-corner) |
| `TaskAttachmentDropTests.swift` | 873 | full (tasks-views) |
| `TaskImageTests.swift` | 400 | full (tasks-views) |
| `AgentAccessTokenStoreTests.swift` | 78 | inventory (main): 6 tests — persistence/reuse, per-identity isolation, unavailable Keychain fails closed, insert race, placeholder rejection |
| `AgentHTTPRequestTests.swift` | 150 | inventory (main): 12 tests — body/query parsing, incomplete head/body, malformed line, negative/conflicting Content-Length, Transfer-Encoding, chunked parsing, loopback Host + bearer gate |
| `AgentServerIntegrationTests.swift` | 224 | inventory (main): 8 tests — deferred off-main credential load, disable-while-pending, denied credential fails closed, official client interoperability, real HTTP handshake, token/Origin rejection, restart with same credential, empty credential never listens |
| `DailyCleanupServiceTests.swift` | 185 | inventory (main): 5 tests — day-boundary cutoff and duplicate-safe deletion |
| `TaskPerformanceGateTests.swift` | 123 | inventory (main): 4 tests — 6,000-task summary/toggle bounds, attachment memoization |
| `TaskStoreTests.swift` | 1093 | inventory (main): 45 tests — rollback on failed create/update/delete/reorder, replica fan-out, duplicate presentation, cleanup, ordering, cloud-status |
| `CanvasUITestStoreTests.swift` | 54 | inventory (main): 1 test — isolated UI-test store reset |
| `TestSupport.swift` | 66 | inventory (main) |

### Not line-audited

- `AtticUITests/` (3 files, 2,511 lines): native UI tests; inventoried only.
  They cannot run here and were not treated as evidence.
- `Scripts/` (project generation, install/preview/UI-test launchers, MCP client
  verification), `project.yml`, entitlements, and Info plists: configuration
  and tooling, outside the Swift defect audit. The generation verifier could not
  be executed (missing gems; installing dependencies was out of scope).

### Journey view of the same coverage

| Area / journey | Source paths traced | Result |
| --- | --- | --- |
| Startup, shutdown, failed quit | App delegate/coordinator, draft flush, Canvas cancellation, services | One confirmed ordering defect, fixed; see F-01. |
| Tasks, Backlog, subtasks | Store create/update/move/reorder/delete/cleanup, row/panel callers and tests | Replica fan-out and rollback defenses verified; no new confirmed defect. Two Low hygiene notes (F-05, F-06). |
| Task panels and windows | Main/transient/pinned controllers, corner state machine, focus/hide paths | Generation and barrier ownership verified; hit-test hypothesis disproved; native multi-display behaviour not run. |
| Keyboard and undo | Panel state, Canvas command route, history reset/cancellation | Focused-editor routing and bounded Canvas history verified; native responder-chain behaviour not run. |
| Notes and drafts | Store, draft controller, recovery, conflict and failed-save paths | Failed saves preserve dirty draft/recovery and can veto quit; no new confirmed defect. |
| Note attachments | Import staging, limits, cancellation, materialization, repair and cleanup | Cancellation and cleanup ownership verified; byte totals are already saturating; reconciliation retry hypothesis disproved. |
| Canvas | Session, store extensions, interaction, rendering/cache, accessibility, history, commands | One confirmed accessibility crash path on unbounded persisted geometry, fixed; see F-02. Cache-reuse hypothesis disproved. |
| Settings and themes | Settings model, appearance observation, settings controller/views | Startup observation and teardown ownership verified; visual behaviour not run. |
| Persistence and recovery | Task/note/Canvas rollback, fresh contexts, duplicate UUID resolution, cleanup | Existing duplicate-safe and failed-save defenses verified; crash/power-loss and malformed-store execution not run. |
| Agent integration | Listener, parser, auth/token, MCP routing, start/stop, tools | Security gates verified. One protocol-validation gap fixed (F-03); one diagnostic-message note (F-04); one unverified socket-option hypothesis (F-07); idle-connection hygiene remains backlog. |
| Accessibility and UX | Labels/actions and historical ledgers across panels/Canvas/settings | Source defenses read; VoiceOver, focus delivery, gestures, appearance, and performance require macOS. |
| Large data/resource growth | Existing performance gates, bounded history/cache, fetch/reconcile paths | Structural risks remain unmeasured; no latency or memory improvement is claimed. |

## Prioritized findings ledger

Severity is the user impact if triggered; confidence is how certain the causal
trace is from source alone. Status: **fixed on branch** means a code change
plus unit tests exist on the audit branch but have not been compiled or run;
**documented** means no code change was made.

### F-01 — failed quit cancels valid Canvas work (fixed on branch, `586efb4`)

- **Class:** new confirmed defect.
- **Severity / confidence:** Medium / high.
- **Locations:** `Attic/App/AppCoordinator.swift` (`AppTerminationPreparation`,
  `prepareForTermination`); Canvas session lifecycle cancellation; app-delegate
  termination decision.
- **Trigger:** start a Canvas image import, switch to Notes, leave a dirty draft
  whose flush fails or conflicts, then quit.
- **Causal trace:** termination preparation cancelled Canvas interaction and all
  session-owned imports, then attempted the note flush. A failed flush returned a
  termination veto, so the process and UI remained alive after irreversible
  Canvas cancellation.
- **Impact:** deliberate Canvas import work could be lost even though quit was
  rejected to protect unsaved note work. The native Canvas surface was also
  rebuilt unnecessarily.
- **Existing defenses/tests:** note flush correctly retains dirty recovery state
  and vetoes termination; Canvas imports intentionally survive transient panel
  changes; successful stop and termination cancel imports. No test covered the
  cross-subsystem failed-quit ordering.
- **Remedy applied:** the veto-capable note flush runs first; only after it
  succeeds does termination preparation cancel Canvas work and flush view state.
  Tests: `AtticTests/AppSettingsTests.swift` (failed and successful preparation
  ordering).
- **macOS validation:** run an in-flight import plus forced note-save failure
  quit scenario, confirm the import survives the veto; then the successful-quit
  counterpart.

#### Ownership change ledger (F-01)

- **Before:** termination preparation gave Canvas irreversible teardown ownership
  before Notes decided whether termination was allowed.
- **After:** Notes owns the veto phase. Canvas receives irreversible termination
  only after every veto-capable prerequisite succeeds. Normal `stop()` remains
  the final idempotent service teardown path.
- **Why this is bounded:** no model, schema, gesture, visual, signing, CloudKit,
  or replica behaviour changes. The successful-termination behaviour is
  unchanged; only the failed-termination path preserves ongoing Canvas work.

### F-02 — Canvas accessibility description traps on unbounded persisted geometry (fixed on branch)

- **Class:** new confirmed defect (crash), malformed-data trigger.
- **Severity / confidence:** Low (requires persisted geometry far outside any
  reachable drawing range) / high (the trap is language-defined).
- **Locations:** `Attic/Canvas/CanvasSurfaceMacHelpers.swift`
  `canvasAccessibilityNumber` (previously lines 609-613), called from
  `refreshCanvasAccessibilityElements` for every live stroke width and
  centre (lines 356-377), image size and centre (379-412), and semantic object
  centre (441).
- **Trigger:** any board whose persisted stroke point, image transform, or
  semantic-object frame contains a finite coordinate ≥ 2^63 or < -2^63 (or an
  infinite value that slipped past load validation), while an
  assistive client — VoiceOver, Accessibility Inspector, or any process using
  the accessibility API — asks the Canvas view for its children.
- **Causal trace:** (1) load-time validation is finiteness-only:
  `CanvasStrokeCodec.validate` (`CanvasStrokeCodec.swift:91-107`) accepts any
  finite point; `CanvasImageTransform.isValid` (`CanvasImageTypes.swift:212-218`)
  accepts any finite positive size; semantic frames are checked with
  `transform.isValid`/`rotation.isFinite` (`CanvasStorePersistence.swift:382`).
  (2) `canvasAccessibilityPositionDescription` passed `worldRect.midX/midY`
  straight to `canvasAccessibilityNumber`. (3) For integral values that
  function evaluated `Int(value)`, which traps for any `Double` outside
  `Int`'s range and for ±infinity (NaN never reached it, because `NaN == NaN`
  is false and it took the `%.1f` branch; exactly -2^63 is `Int.min` and was
  fine). The frame path
  (`canvasAccessibilityFrame`, lines 566-572) guards finiteness; the description
  path did not guard anything.
- **Impact:** deterministic process crash whenever the accessibility tree is
  built for the affected board, i.e. a board that opens fine visually becomes
  un-openable with VoiceOver running. The description is purely informational,
  so no correct value depends on the trapping conversion.
- **Existing defenses/tests:** `CanvasPerformanceGateTests` covers accessibility
  rebuild coalescing and frame movement; no test exercised extreme values.
- **Remedy applied:** the number text now goes through
  `CanvasAccessibilityNumberText.string(for:)`, which uses `Int(exactly:)` (nil,
  never a trap, for fractional, out-of-range, or non-finite values) and falls
  back to the existing `%.1f` formatting. Output is byte-identical to the old
  behaviour for every value the old code did not crash on. Tests:
  `AtticTests/CanvasDomainTests.swift` (`CanvasAccessibilityTests`, two tests
  covering unchanged formatting, `Int` boundaries, 2^64, 1e300, ±infinity, NaN).
- **macOS validation:** run `CanvasAccessibilityTests`; then, with VoiceOver on,
  open a board containing an image whose persisted `centerX` was set to `1e30`
  in a copy of the store and confirm the Canvas is navigable instead of crashing.

### F-03 — MCP `tools/call` ran tools when `arguments` was not an object (fixed on branch)

- **Class:** new confirmed defect (protocol validation).
- **Severity / confidence:** Low / high.
- **Location:** `Attic/Services/AgentServer/MCPRequestHandler.swift`
  `callTool` (previously line 106:
  `params["arguments"] as? [String: Any] ?? [:]`).
- **Trigger:** an authenticated client sends `"arguments": ["…"]`, a string, a
  number, or a boolean.
- **Causal trace:** the failed cast collapsed to an empty dictionary, so the tool
  executed with defaults the client never requested instead of receiving the
  JSON-RPC invalid-params error the handler already returns for non-object
  `params` and unknown tools.
- **Impact:** bounded. `create_task`, `update_task`, `delete_task`,
  `create_note`, `update_note`, and `delete_note` all require fields that an
  empty dictionary lacks, so they fail with a tool error rather than mutating
  anything;
  `list_tasks`/`list_notes` silently returned an unfiltered listing. The defect
  is a conformance and diagnostics problem, not a security or data-loss one;
  authentication, Host/Origin, size, and method gates are unaffected.
- **Remedy applied:** a missing or JSON `null` `arguments` value is still
  treated as absent; any other non-object value returns `-32602` ("Tool
  arguments must be an object") without invoking the tool. Tests:
  `AtticTests/MCPRequestHandlerTests.swift` (array/string/number/boolean are
  rejected and create nothing; `null` still lists).
- **macOS validation:** run `MCPRequestHandlerTests` and
  `AgentServerIntegrationTests`; optionally re-run `Scripts/verify_mcp_client.mjs`
  against a running local build to confirm the official client still
  negotiates and calls tools.

### F-04 — `update_note` reports a misleading error when a client tries to blank a note (documented)

- **Class:** diagnostic accuracy.
- **Severity / confidence:** Low / high.
- **Locations:** `Attic/Services/AgentServer/AgentTaskTools.swift:391-415`;
  `Attic/Services/NoteStore.swift:207`.
- **Trace:** the tool description promises "a title or body must remain
  non-empty". `NoteStore.update` enforces that rule by returning `false` without
  setting `lastErrorMessage`, so the tool reports "The change could not be
  saved: Unknown error." or, worse, whatever earlier failure message the store
  still holds. Data is correct; only the message is wrong.
- **Why not fixed here:** the correct pre-check must mirror the store's
  normalisation (`normalizedTitle`, `hasMeaningfulBody`), which should be
  exposed by the store rather than re-implemented in the tool. That is a small
  cross-file change best made with a compiler available.
- **Validation plan:** add a handler test that updates a note to empty title and
  body and asserts an invalid-arguments message; confirm the UI editor's own
  blank handling is unchanged.

### F-05 — failed task exports leave their disposable directory behind for up to a day (documented)

- **Class:** resource hygiene.
- **Severity / confidence:** Low / high.
- **Locations:** `Attic/Models/TaskImageReference.swift:120-129` (`openableCopy`)
  and `170-182` (`export`); pruning in `disposableDirectory()` (`156-168`).
- **Trace:** each call creates a fresh UUID directory under
  `<tmp>/AtticTaskExports`; if the copy or `Task.txt` write throws, nothing
  removes the partially populated directory until the next call prunes entries
  older than 24 hours. Contents are copies of the user's own attachments in the
  app's own temporary directory, so no cross-user exposure is added.
- **Why not fixed here:** a `defer`-based cleanup is easy but touches the same
  path whose ownership (durable attachments vs. disposable exports) the source
  comments guard carefully; it should be changed with the export tests running.
- **Validation plan:** force `copyItem` to fail in a test and assert the export
  directory is removed; confirm successful exports are untouched.

### F-06 — unchecked integer arithmetic on persisted counters (documented)

- **Class:** robustness against malformed stores.
- **Severity / confidence:** Low / high on mechanism, low on reachability.
- **Locations:** `Attic/Models/TaskImageReference.swift:50`
  (`existing.reduce(0) { $0 + $1.byteCount }` — an `Int64` sum of persisted
  task-attachment byte counts); `Attic/Services/NoteStore.swift:374` and `443`
  (`max(sortIndex) + 1`).
- **Trace:** each expression traps only if persisted values are absurd (byte
  counts summing past 9.2 × 10^18, or a stored `sortIndex` equal to
  `Int64.max`). The note byte totals are already saturating
  (`NoteStore.totalAttachmentBytes`, lines 963-970), and the task path is guarded
  immediately afterwards by `AttachmentFileStore` (`existingBytes >= 0 &&
  <= maxBytesPerNote`), so everything short of overflow fails gracefully.
- **Why not fixed here:** the values are unreachable through the app's own
  writers; hardening should reuse the existing saturating helper rather than add
  a second one, which is a small refactor to make with the compiler available.

### F-07 — listener address reuse may permit silent same-user port takeover (unverified hypothesis)

- **Class:** security hygiene hypothesis; requires macOS verification.
- **Severity / confidence:** Low / low-medium.
- **Location:** `Attic/Services/AgentServer/AgentServer.swift`
  (`NWParameters.allowLocalEndpointReuse = true` on the loopback listener).
- **Hypothesis:** Network.framework documents `allowLocalEndpointReuse` as
  allowing reuse of local addresses and ports; if it sets `SO_REUSEPORT` as
  well as `SO_REUSEADDR`, another process running as the same user could bind
  `127.0.0.1:<port>` while Attic is listening and receive some or all agent
  connections — including the bearer header — without Attic noticing. Without
  reuse, such a process could only squat the port before Attic starts, which
  Attic surfaces as a listener failure.
- **Why documented, not changed:** the option may be needed so that toggling
  Agent access off and on rebinds immediately instead of failing on a lingering
  `TIME_WAIT` socket; the source does not state its intent. Whether the takeover
  is possible, and whether removing the flag breaks the restart path, can only
  be established on macOS.
- **Validation plan:** with Agent access enabled, run a second process (e.g. a
  Python script setting `SO_REUSEADDR` and `SO_REUSEPORT`) that binds the same
  loopback endpoint; record whether `bind` succeeds and whether a subsequent
  client connection reaches it. If it does, evaluate dropping the flag and
  verify `testStopAndRestartReconnectsWithSamePrivateCredential` plus a manual
  off/on toggle still pass.

### F-08 — degenerate zero-size visible frame yields a zero-size panel (documented)

- **Class:** edge-case geometry.
- **Severity / confidence:** Low / high.
- **Location:** `Attic/Services/PanelGeometry.swift:109-124`.
- **Trace:** with a zero-width or zero-height visible frame the clamp produces
  a zero (never negative — the upper bound is `max(0, …)` and the minimum is
  clamped before the final `min`) width/height. That only happens during display
  reconfiguration when AppKit reports an empty visible frame; the next
  geometry pass with a real visible frame restores normal sizing. The
  explorer's "negative dimensions" claim was disproved; see below.

### Known backlog retained without implementation

- The non-local build path still contains the former-owner CloudKit identity.
  This is the documented release-only identity concern, not an active local-only
  defect. Identity, signing, container, mobile, CloudKit, and APNs edits are
  explicitly deferred.
- Accepted idle agent connections are not actively closed by `stop()`, there is
  no read deadline, and a request whose declared `Content-Length` already
  exceeds the 1 MiB cap is not rejected until the bytes actually arrive.
  Existing listener generation checks prevent post-stop handler access, so this
  remains bounded resource hygiene rather than an authentication bypass.
- The global hot-key registration swallows Carbon errors silently (the shortcut
  simply does not work if another app owns it); the setting has no failure UI.
- Historical Deep Audit batches 3–6 remain candidate work subject to their own
  reproduction, measurement, and native gates. They were not treated as blanket
  authority for this patch. Items reported by the second-pass explorers as
  already fixed in the current tree (CVD-02, CVD-05, CVD-06) were not
  independently re-verified by the main auditor.

## Disproved hypotheses and verified defenses

- **Panel hit-test "double conversion" (explorer WM-01, `AtticPanel.swift:810-814`,
  `956-976`; `PanelSurfaceHostingView.swift:57-64`):** disproved. AppKit
  documents the `NSView.hitTest(_:)` argument as a point in the coordinate
  system of the receiver's superview, not the receiver, so
  `convert(point, from: superview)` is the correct and only conversion (and
  the point handed on to `hostingView.hitTest` is correctly in the container's
  own coordinates, which is that child's superview space). The
  premise that the point was already local was wrong; no click-routing defect
  exists here, and the existing hosting-view tests cover the header/control
  routing.
- **Stale Canvas image cache when bytes change under equal metadata (explorer
  CS-01, `CanvasStore.swift:372-388`):** not a defect. The source deliberately
  trades a byte comparison for the digest column and already pays for the byte
  comparison in the one anomaly it can detect (version bump without transform
  change). The remaining scenario requires the external-storage bytes to change
  while digest, byte count, mutation version, and timestamp all stay equal —
  i.e. silent corruption of the payload file — in which case showing the
  previously decoded bitmap is the more useful outcome anyway.
- **Negative panel dimensions on a zero work area (explorer WS-01):** disproved
  as stated; the result can be zero, never negative (see F-08).
- **`TaskStore` byte-count overflow at `TaskStore.swift:48-51` (explorer
  TS-01):** wrong location — those lines are the sync-status title; the
  unchecked sum lives in `TaskImageReference.swift:50` and is recorded as F-06.
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
  metadata work; note attachment byte totals saturate instead of overflowing.
- Agent access is opt-in; listener binding is loopback-only; Host, Origin, path,
  method, request-size, malformed-length, duplicate/conflicting Content-Length,
  Transfer-Encoding, bearer, and JSON-RPC checks remain in place; credential
  failure does not open an unauthenticated listener; the credential is generated
  from `SecRandomCopyBytes`, stored `AfterFirstUnlockThisDeviceOnly`, and an
  insert race resolves to the persisted value rather than an ephemeral one.
- MCP mutating tools validate every argument before mutating and surface store
  failures as tool errors; `update_task` cannot leave a task half-updated.
- Local-only startup does not request CloudKit, APNs, or remote notifications;
  the local-only container is created with `cloudSyncEnabled: false` and no
  development-schema bootstrap runs in that configuration.
- Test hosts use an ephemeral in-memory agent credential and isolated defaults
  suites; the explicit test attachment root must prove temporary containment and
  ownership before it is used.

## Checks run in this environment

- `git diff --check` on every commit: clean.
- Swift 5.8 parse-only check (`swiftc -parse`) on each edited Swift file:
  `Attic/App/AppCoordinator.swift`, `AtticTests/AppSettingsTests.swift` (F-01);
  `Attic/Canvas/CanvasSurfaceMacHelpers.swift`,
  `Attic/Services/AgentServer/MCPRequestHandler.swift`,
  `AtticTests/CanvasDomainTests.swift`, `AtticTests/MCPRequestHandlerTests.swift`
  (F-02/F-03): all parse. This is not a type-check or build.
- Every hunk was re-read against the constraints in the brief before commit.
- Not run (unavailable here): `xcodebuild`, XCTest, UI tests, static analyzer,
  strict-concurrency diagnostics, `Scripts/verify_project_generation.rb`
  (missing gems), `Scripts/verify_mcp_client.mjs` (needs a running app).

## macOS gates to run before merging (in order)

1. `xcodebuild test -scheme Attic -only-testing:AtticTests/MCPRequestHandlerTests
   -only-testing:AtticTests/CanvasAccessibilityTests
   -only-testing:AtticTests/AppSettingsTests` — the three files with new tests.
2. Full `AtticTests` suite, then `Scripts/run_local_ui_tests.zsh`.
3. Manual F-01 scenario (in-flight Canvas import + forced note-save failure quit;
   then a successful quit).
4. Manual F-02 scenario with VoiceOver on a copied store containing an
   out-of-range image centre.
5. `Scripts/verify_mcp_client.mjs` against a local build for F-03 interop.
6. Optional: the F-07 second-bind experiment.

## Not examined or not executable here

- Native compilation, strict-concurrency diagnostics, static analyzer, XCTest,
  UI tests, signing, entitlements inspection, and generated app execution.
- VoiceOver, keyboard focus delivery, Reduce Motion/Transparency, physical
  trackpad and pointer behaviour, native drag/drop and file providers.
- Crash/power-loss durability, real SwiftData corruption, Keychain prompts,
  multi-process token startup, IPv6 loopback behaviour, and CloudKit imports.
- Instruments measurements for active Canvas drawing/import, large stores,
  long-running corner monitoring, attachment sweeps, and MCP bursts.
- Deferred iPhone, CloudKit, APNs, TestFlight, and production behaviour.
