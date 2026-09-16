# Deep Audit — Runtime Architecture and Resource Behavior

**Date:** 2026-09-14
**Auditor:** Runtime-architecture lead (read-only source audit + one read-only process sample)
**Source root:** `/Users/taha/Developer/attic-task-panels-v2` (worktree dirty with unrelated user edits — preserved untouched)
**Domain:** whole-app runtime architecture, observation/invalidation, main-thread work, allocations/caches, timers/polling, startup/idle/shutdown, background tasks, concurrency, resource lifetime — traced across Tasks, Notes, Canvas, Settings, and service integration hot paths.

This audit is source-verified. Where a finding rests on mechanism alone (no measurement), it is marked *structural*. The only runtime evidence is a 3 s `sample(1)` of the running preview (see §2). No code was modified; no builds, tests, or UI hosts were run, per the audit's read-only mandate.

---

## 1. Coverage matrix

| Subsystem | Files | State |
|---|---|---|
| App entry / wiring / shutdown | `AtticApp`, `AppDelegate`, `AppCoordinator`, `CanvasEditCommandRoute` | ✅ audited |
| Task store + cleanup | `TaskStore`, `DailyCleanupService`, `TaskTypes`, `TaskItem`, `TaskDragPayload` | ✅ audited |
| Notes stack | `NoteStore`, `NoteDraftController`, `NoteItem`, `NoteAttachment`, `NoteInlineAnchor` | ✅ audited |
| Canvas store (7 extensions) | `CanvasStore`, `…Boards`, `…Strokes`, `…Images`, `…Lifecycle`, `…Persistence`, `…ReplicaResolution`, `…SemanticObjects`, `…CloudSync` | ✅ audited |
| Canvas runtime | `CanvasSession`, `CanvasSurface*`, `…Interaction`, `…MacHelpers`, `…Renderer`, `CanvasInputStateMachine`, `CanvasViewport`, `CanvasTypes`, `CanvasImageTypes`, `CanvasStrokeCodec`, `CanvasSemantic*`, `CanvasControls`, `CanvasImageImporter`, `CanvasImageExportDocument`, `CanvasSendable` | ✅ audited |
| Window/panel lifecycle | `AtticPanel`, `AtticPanelController`, `SubtaskPanelController`, `SubtaskPanelLayout`, `PanelUIState`, `PanelSection`, `PanelSurfaceHostingView`, `PanelGeometry`, `SettingsWindowController` | ✅ audited |
| Timers/monitors/hotkey | `CornerHoverMonitor`, `CornerHoverStateMachine`, `GlobalHotKey`, `LoginItemService` | ✅ audited |
| Agent server | `AgentServer`, `MCPRequestHandler`, `AgentTaskTools`, `AgentHTTPRequest`, `AgentAccessTokenStore` | ✅ audited |
| Attachment I/O | `AttachmentFileStore`, `TaskImageFiles`, `NoteAttachmentStore`, `CanvasImageStore`, `NoteAttachmentPlatformSupport`, `TaskImageReference` | ✅ audited |
| Panel view layer | `AtticPanelView`, `TaskRowView`, `TaskSectionView`, `TaskFamilyView`, `TaskStatusButton`, `SubtaskPanelContent`, `CanvasPanelContent`, `NotesPanelContent`, `TaskAttachmentDrop`, `TaskComposerAttachments`, `TaskImageAttachments`, `NoteAttachmentTray`, `NoteInlineCards`, `MenuBarView` | ✅ audited |
| Settings | `AppSettings`, `SettingsView`, `SettingsSection`, `SettingsComponents`, `GeneralSettingsView`, `PanelSettingsView`, `AppearanceSettingsView`, `AgentAccessSettingsView`, `AboutSettingsView`, `CornerPicker` | ✅ audited |
| Design layer | `AtticStyle`, `AtticTheme`, `AtticPanelTheme`, `Squircle`, `TaskActionsMenu` | ✅ audited |
| Persistence infra | `PersistenceController` | ✅ audited |
| iOS-only surface | `CanvasSurfaceIOS` (`#if os(iOS)`, dormant on macOS) | ✅ dormant-checked |

**Process sample (only runtime evidence):** `AtticPERFA1Final` (bundle `com.taha.Attic.perfa1final`, binary built 2026-09-14 17:21, PID 28822), 4 h 22 m elapsed at sample time, **0 % CPU, ~80 MB RSS, 4 threads**; main thread parked in `mach_msg_trap` inside `_DPSNextEvent`, `NSEventThread` parked, two idle workqueue threads. No periodic timer or polling activity observed — consistent with the event-driven design verified in source. Workload: idle, panel hidden, canvas not frontmost. Not measured: hide/show churn, canvas draw load, import batches, MCP traffic.

---

## 2. Confirmed findings

### RUN-001 — Canvas `.id(epoch)` teardown cancels in-flight image imports on panel hide, section switch, and zoom-button click — Medium, high confidence

**Mechanism.** `CanvasSurface` binds the native bridge's identity to `@Published interactionCancellationEpoch` (`Canvas/CanvasSurface.swift:23`). Bumping the epoch dismantles `CanvasNSView` → `dismantleNSView` → `deactivateRepresentation()` (`Canvas/CanvasSurfaceMac.swift:1253-1261`), which calls `cancelFilePromiseBatches()` and `onCancelImageImportBatches()` → `CanvasSession.cancelAllImageImportBatches()` (`Canvas/CanvasSession.swift:356-360`). Inside `importImageBatch`, cancellation marks every unfinished item `.cancelled` and reports the first failure (`Canvas/CanvasSession.swift:845-854, 913-918`).

**Triggers (all bump the epoch):**
- Panel hide while Canvas is the selected section — `AtticPanelController.swift:469` calls `canvasSession.cancelActiveInteraction()` right after the AppKit-level `hostingView.cancelActiveInteraction(reason: .explicitHide)` (line 468) which already discards ink without teardown.
- Switching sections away from Canvas — `AtticPanelView.swift:808-810`.
- Zoom +/- button — `CanvasPanelContent.swift:397-400` calls `cancelActiveInteraction()` before applying zoom.
- Board switch/create/delete — `CanvasSession.swift:498, 521, 544`; external revisions with cleared history — `:1685-1689`; stop/termination — `AppCoordinator.swift:375, 392` (legitimate).

**Expected vs actual.** Hiding the panel or nudging zoom is transient; it should not abort a multi-image import the user deliberately started. Actual: the batch is cancelled and the progress UI records `.cancelled` outcomes.

**Impact.** User-visible: imports aborted by unrelated UI transitions. Also discards file-promise deliveries in flight.

**Smallest fix.** Split the two effects: transient interruptions (hide, zoom, section switch) should call the AppKit-level `cancelInteraction()` only — reserving the epoch teardown for board change/create/delete and termination — and `deactivateRepresentation` should not cancel import batches (or import tasks should be owned by the session and orphaned on dismantle, not cancelled).

**Verification.** Unit-testable: start `startImageImportBatch` with a slow injected `prepareImage`, bump only the hide path, assert the batch completes. UI check: drop several images, hide the panel mid-import, confirm items import rather than report cancelled.

---

### RUN-002 — Same teardown discards all per-view caches on every hide/show while Canvas is selected — Medium (structural), high mechanism confidence

**Mechanism.** `CanvasNSView` owns the 256 MB `CanvasImageDecodeCache` (instantiated at `CanvasSurfaceMac.swift:259-261`; budgets at `CanvasSurfaceRenderer.swift:113-118`), `CanvasPathCache` (`:258`), `CanvasImageDisplayCache` (`:281`), `CanvasSemanticRenderCache` (`:223`), and the accessibility element map (`:306-309`). Each `.id` bump destroys the view; the next show rebuilds everything: drag-type registration, the magnification recognizer, tracking areas, and `imageCache.prepare(for:)` re-enqueues every visible image (≤ 3 concurrent decodes, `CanvasSurfaceRenderer.swift:226-238`).

**Expected vs actual.** Panel hide is the app's core gesture (corner-hover show/hide all day). The comment at `CanvasSurface.swift:20-22` justifies rebuild to "discard unfinished input" — but `cancelInteraction()` on the live view already does that (`CanvasSurfaceInteraction.swift:199-204`). Actual: every hide/show cycle on an image-heavy canvas restarts decodes and rebuilds caches.

**Impact.** Re-decode CPU + transient blank images on each re-show; unbounded count of cycles/day. Unmeasured magnitude — depends on image count/size.

**Smallest fix.** Same as RUN-001 — keep the NSView alive across hide (drop the session-level epoch bump on transient paths), or hoist `imageCache`/`pathCache`/`imageDisplayCache` into a session-scoped object so view recreation is cheap.

**Verification.** DEBUG: count `CanvasImageDecodeCache` init/`removeAll` across a hide→show; assert no decode re-queue when images unchanged. Time a show on a board with ~10 large images before/after.

---

### RUN-003 — Eraser hit-test is O(remaining strokes) per accepted drag sample — Low-Medium (structural)

**Mechanism.** `accumulateEraseHits` (`Canvas/CanvasSurfaceInteraction.swift:220-233`) filters `strokes` to exclude already-erased IDs, then runs `CanvasHitTesting.strokeIDs` over the remainder on **every** accepted `appendInk` sample (distance gate ≥ 0.65/scale pt, `:139-147`). For S strokes and E drag events, one gesture costs O(S×E) bounds/segment work. Point buffering is bounded (12 000 with compaction, `CanvasInputStateMachine.swift:4, 104-121`), so the per-event scan is the only unbounded input.

**Expected vs actual.** Erase cost should scale with strokes near the eraser, not the whole board. Actual: full-board scan per event; on a large board a slow erase drag performs thousands of bounds checks per second.

**Smallest fix.** Compute the candidate set once at `beginInk` (or maintain a decremental candidate list — remove erased IDs, never re-add); longer-term, a coarse spatial grid.

**Verification.** Instrument `strokeIDs` call count / strokes-scanned during a 500-point erase over a 5 000-stroke board.

---

### RUN-004 — Every canvas save resolves the presentation twice on a fresh context — Low (structural, by-design mitigations verified)

**Mechanism.** `CanvasStore.save()` (`Services/CanvasStorePersistence.swift:25-84`): resolve on the mutating context (:31), `persist` (:54), then `reloadCanvas` → `makeFreshContext()` + a second `resolveCanvasPresentation` (:93-100). Each resolve = `loadReplicas` (boards fetch + 3 canvas-scoped content fetches, `CanvasStore.swift:150-211`) + winner resolution + sorts. Per completed stroke/image op on the main actor.

**Mitigations verified (not defects):** payload blobs are not re-faulted — `CanvasImageCacheEntry` scalar-metadata comparison and `permitsEquivalentSourceReuse` reuse resident bytes (`:292-325`); `CanvasStoreContentChange` flags let the session skip unchanged collections (`:404-444`); DEBUG fetch counters exist to guard regressions (`CanvasStore.swift:76-90`).

**Impact.** Human stroke cadence (~1-3/s) → a few ms each; fine today. It becomes a hot path only if a future writer batches mutations (e.g. MCP bulk canvas ops don't exist today — `AgentTaskTools` covers tasks/notes only).

---

### RUN-005 — `scheduleViewStateSave` allocates and cancels a Task per pan/zoom event — Low

**Mechanism.** `Canvas/CanvasSession.swift:1440-1447`: `viewStateSaveTask?.cancel(); viewStateSaveTask = Task { @MainActor in sleep(400ms); flushViewState() }`. `setViewport`/`pan`/`zoom` all funnel here (:1396-1414), so a continuous pan/pinch allocates + cancels a Task per event. `flushViewState` itself encodes JSON + compares + writes UserDefaults synchronously (:1421-1438) — small, and correctly debounced.

**Impact.** Per-event Task allocation churn on the main actor during gestures; each is cheap. Low.

**Fix.** A single repeating debounce (cancel-and-reschedule a `DispatchWorkItem`, or one Task loop with a deadline field) avoids per-sample allocation.

---

### RUN-006 — `reconcileTaskIDs` allocates a full ID Set on every store revision — Low

**Mechanism.** `AtticPanelView.swift:182-184`: `.onChange(of: store.revision) { uiState.reconcileTaskIDs(Set(store.tasks.map(\.id))) }` → `PanelUIState.swift:211-238` checks ~8 state fields and filters `subtaskDrafts`/`subtaskEntryActiveIDs`. O(tasks + drafts) per committed mutation (each `save()` bumps `revision`, `TaskStore.swift:1067-1075`).

**Impact.** Trivial at realistic task counts; noted for completeness.

**Fix.** Optional: pass the changed/removed IDs through `lastContentChange`-style deltas instead of rebuilding the Set.

---

### RUN-007 — Agent server: all MCP work runs on the main actor; no connection read timeout or connection bound — Low-Medium

**Mechanism.** `AgentServer.route` hops to `@MainActor` for `handler.handle` (`Services/AgentServer/AgentServer.swift:203-213`); `MCPRequestHandler`/`AgentTaskTools` then run JSON parse + TaskStore mutations (each `persist` + `revision` bump + SwiftUI invalidation) on main. `receive` (:145-173) re-arms `connection.receive` with no deadline: an idle local client can hold a socket (plus ≤1 MB buffer) forever; no max-connection cap. Mitigations verified: loopback-only listener (`requiredLocalEndpoint`, :94), 1 MB request cap (:18,156-159), Host-header + Origin-rejection anti-DNS-rebinding (:178-181, 246-255), constant-time bearer compare (:257-266), generation-gated lifecycle (:51,66,126,204).

**Expected vs actual.** Acceptable for an opt-in local endpoint; a misbehaving or malicious *local* process can still stall the UI with large legit requests or hold connections open.

**Fix.** Add a per-connection read deadline and a small connection cap; keep tool calls on MainActor (stores require it) but bound request size already done.

**Verification.** Unit test: open a socket, send partial headers, never finish → assert the connection is reaped after the timeout.

---

### RUN-008 — Daily cleanup runs a SwiftData pass on every `didBecomeActive` — Low

**Mechanism.** `DailyCleanupService.start` observes `NSApplication.didBecomeActiveNotification` (plus day/timezone change and wake) → `cleanupAndReschedule()` → `performCleanup` → `TaskStore.purgeCompleted(before:)` (`Services/DailyCleanupService.swift:27-49, 69-80`; `TaskStore.swift:843-904`). Purge itself is well-shaped: predicated candidate fetch, divergent-replica refusal, family-consistency loop, attachment file removal.

**Expected vs actual.** Attic's panel is nonactivating so activations are rare (menu click, Settings, welcome). Each still pays 3 predicated fetches + possible delete+save on the main actor, even when the last cleanup was the same day.

**Fix.** Skip when `lastCleanupDay == today` unless day-change fired; keep the midnight timer as the source of truth.

---

### RUN-009 — `CanvasImageDecodeCache.prepare` runs `rebuildQueueOrder` twice per call — Trivial

`CanvasSurfaceRenderer.swift:146,150` — the queue is rebuilt before and after `enqueueIfNeeded` in one pass; the first call is redundant O(queued) work per configure. Cosmetic.

---

### RUN-010 — `CanvasPlacedImage.encodedData` keeps every image's encoded bytes resident in the session — Low-Medium (structural)

**Mechanism.** `CanvasImageTypes.swift:229`: the presentation struct holds `encodedData: Data` inline; the store materializes it into every `CanvasPlacedImage` (`CanvasStorePersistence.swift:321-330`). Persistence uses `.externalStorage` (`Models/CanvasImageItem.swift:55`) so disk is fine, but `session.images` retains all payloads while a board is loaded — up to 8 MB/image by import policy (`CanvasImageImporter.swift:47-51`), unbounded count. Combined ceiling ≈ payloads + 256 MB decode cache + 64 MB history.

**Impact.** A board with many large imports can hold hundreds of MB in the presentation layer; payloads are needed only when queued for decode.

**Fix.** Presentation carries `contentToken`+`payloadMetadata` and the store exposes a payload accessor; the decode cache faults bytes only for queued items (external storage already supports this).

**Verification.** Measure `session.images` payload residency (`encodedData.count` sum) on a board with N large images; assert near-zero after fix.

---

## 3. Plausible but unverified concerns

- **P-01 — Store-level `@Published` writes fire on every save even when unchanged.** `applyCanvasPresentation` assigns all published collections unconditionally (`CanvasStorePersistence.swift:429-438`); `contentRevision`/change flags shield `CanvasSession`, and today only the session subscribes. If a view ever observes `CanvasStore` directly, every save invalidates it. Structural note, zero cost now.
- **P-02 — `NSWorkspace.shared.icon(for:)` runs synchronously in `TaskAttachmentGlyph.body`** (`TaskImageAttachments.swift:42`) per body evaluation for non-image attachments. LaunchServices caches internally; residual per-eval cost unmeasured.
- **P-03 — `noteDraft.flush()` sits on the hide path and can reject the hide** (`AtticPanelController.swift:459-461`). Intended (conflict must not lose edits), but a blocked flush leaves the panel visible with no toast — worth one UX sanity check that the refusal is discoverable.
- **P-04 — `SettingsView.onReceive(didBecomeActive)` → `loginItemService.refresh()`** (`SettingsView.swift:60-62`): an SMAppService status query per activation while Settings is open. Cheap; listed for completeness.
- **P-05 — MCP batch/burst behavior:** `tools/call` is synchronous per request on main; a client issuing rapid mutations serializes saves + republishes. Loopback + opt-in bounds exposure.

## 4. Dismissed hypotheses

- **Idle polling burn — dismissed.** `CornerHoverMonitor` is event-driven while the panel is visible (no timer at all), runs a 1 s/250 ms-leeway `DispatchSourceTimer` only while hidden *and* the pointer is far from the corner, and 50 ms only while hidden *and* within 96 pt of the corner (`CornerHoverStateMachine.swift:36-64`; `CornerHoverMonitor.swift:376-406`). Process sample confirms 0 % CPU idle. Monitors coalesce bursts (one sample per `eventSampleInterval` + one trailing sample, `CornerHoverMonitor.swift:300-328`) and are epoch-guarded (`CornerHoverTimerEpoch`, `CornerHoverStateMachine.swift:71-86`).
- **Reveal-time refresh churn — dismissed for local-only builds.** `refreshStoreForReveal` is gated by `RevealRefreshPolicy.current.refreshesOnReveal` (`CornerHoverMonitor.swift:487-505`), false under `ATTIC_LOCAL_ONLY`. The triple `store.refresh()` + retry task never runs locally.
- **Cloud-sync churn — dismissed for local-only builds.** Every cloud path is gated by `CanvasCloudInfrastructurePolicy.isEnabled` (`CanvasStore.swift:433-441`) or `#if !ATTIC_LOCAL_ONLY` (`TaskStore.swift:1072-1075`); the remote-change/CloudKit publishers (`TaskStore.swift:1154,1166`; `NoteStore.swift:1151,1163`; `CanvasStoreCloudSync.swift:9,20`) subscribe but never fire locally.
- **Monitor/observer leaks — dismissed.** Cross-checked every `addLocalMonitor`/`addGlobalMonitor`/`addObserver` site against `removeMonitor`/`removeObserver`/`forEach remove` (CornerHoverMonitor, AtticPanelController, AtticPanel, SubtaskPanelController, DailyCleanupService, CanvasSurfaceMac, TaskRowView, TaskImageAttachments, NoteAttachmentTray, AppCoordinator). All paired; `deinit`s clean up.
- **Unbounded canvas memory — dismissed at the policy level.** History: 100 commands + 64 MB byte budget with oldest-first eviction (`CanvasSession.swift:14-22, 145, 1551-1568`); decode cache 256 MB/48 items/3 concurrent (`CanvasSurfaceRenderer.swift:113-118`); semantic framesetter cache 128 entries + live-ID pruning (`CanvasSemanticRenderer.swift:14-25`); input buffer 12 000 points with deterministic compaction; image imports ≤ 2 concurrent (`CanvasSession.swift:239, 783-843`); composer attachments generation-gated (`TaskComposerAttachments`); promised-file batches have a 30 s timeout + idempotent late-delivery cleanup (`NoteAttachmentTray.swift:1798-1849`). RUN-010 is the one residual structural gap.
- **Image blob re-fault per save — dismissed.** Scalar `payloadMetadata` comparison plus `permitsEquivalentSourceReuse` reuses resident payloads; only legacy rows or true payload swaps fault external storage (`CanvasStorePersistence.swift:292-325`; `CanvasImageItem.swift:120-173`).
- **Main-thread image import work — dismissed.** Import read/decode/encode run in `Task.detached` with cancellation handlers (`CanvasImageImporter.swift:81-134`); decode in `decodeOffMain` (`CanvasSurfaceRenderer.swift:336-367`).
- **SwiftUI body fan-out per mutation — mostly dismissed.** `TaskRowView` is `Equatable` and avoids whole-store observation; `snapshot(for:)`/`subtasks(of:)`/`orderedNotes()` are revision-memoized (`TaskStore.swift:924-962`; `NoteStore.swift:689-717`); canvas surface configure uses in-place renderKey compares and a content-revision split so viewport-only frames skip content rebuilds (`CanvasSurfaceInteraction.swift:37-71`; `CanvasSurfaceMac.swift:429-530`).

## 5. Prioritized fixes

1. **RUN-001 + RUN-002 (same root).** Stop bumping `interactionCancellationEpoch` for transient interruptions (panel hide, section switch, zoom-button click); reserve `.id` teardown for board lifecycle and termination. Move image-import cancellation out of `deactivateRepresentation`, and/or hoist the decode/path/display caches to session scope. Highest value: fixes a functional abort plus recurring cache churn on the app's most frequent gesture.
2. **RUN-010.** Defer payload residency in `CanvasPlacedImage`; bounds total canvas memory.
3. **RUN-007.** Add connection read-timeout + cap to `AgentServer.receive`; document main-actor serialization.
4. **RUN-003.** One-shot eraser candidate set per gesture.
5. **RUN-005.** Replace per-event Task churn with a single debounce.
6. **RUN-008.** Same-day guard before the activation cleanup pass.
7. **RUN-006, RUN-009, P-02.** Cosmetic; batch with nearby work.

## 6. Limitations

- **Source-only audit.** One 3 s sample of an idle preview is the only runtime measurement; no Instruments, no load testing, no canvas draw/erase measurement, no MCP traffic test. Performance severities are structural judgments, not measured regressions.
- **Preview provenance:** sampled `com.taha.Attic.perfa1final` (built 2026-09-14 17:21 from this worktree's branch); consistent with the audited source but not a fresh-checkout guarantee.
- **Unexercised paths:** deferred CloudKit/APNs/iPhone code reviewed for dormancy only — not validated as working; iOS canvas surface is compile-gated and untested on-device.
- **Findings reflect this snapshot of a dirty worktree**; unrelated in-flight user edits may shift line numbers.
- Not claimed: exhaustive proof that no further runtime defects exist — coverage is complete over the source inventory and the traced hot paths, residual risk remains in interaction timing that only live UI testing can expose.
