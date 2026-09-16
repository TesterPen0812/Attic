# Concurrent SWE Review — Lane 3: Persistence, Attachments, Drag/Drop Data Integrity, and Recovery

- Checkout reviewed: `/Users/taha/Developer/attic-task-panels-v2`, branch `codex/attic-task-panels-v2`, baseline `ae6418c1af690e29d15a20344cdb9765a23d3f85` (including the pre-existing dirty working tree).
- Method: source and focused-test inspection only. No builds, no test execution, no GUI, no source edits.
- Classifications: CONFIRMED / STRONG EVIDENCE / CANDIDATE / PASS / UNVERIFIED.

## Summary

The persistence and attachment layers are unusually well defended: every store writes through a single save that rolls back and reloads through a fresh `ModelContext` on failure; duplicate-UUID replicas are presentation-deduplicated while mutations fan out to every physical replica; attachment imports are serialized, verified by digest, and rolled back on partial failure; file promises, composer batches, and card drags all carry cancellation and late-arrival cleanup.

One confirmed infrastructure-boundary defect and one strong-evidence lifecycle defect were found, plus three lower-severity candidates. No reachable data-loss, corruption, orphan, or resurrection defect was confirmed in this lane.

## Findings

### D1 — CONFIRMED — P2 — TaskStore's deferred CloudKit machinery is not dormant in local-only builds

**Evidence.** `Attic/Services/TaskStore.swift`:

- `init` unconditionally registers both observers (lines 220–222).
- Every `save()` runs `cloudSyncProtection.noteLocalSave()` and `reconcileProtectedCloudSyncActivity(.exportData)` with no local-only gate (868–869).
- `protectsExport` is `exportedSaveGeneration < localSaveGeneration` (96–98). `exportedSaveGeneration` can only advance through a *successful* `.exportData` CloudKit event (115–118), which never arrives in a local-only build. After the first task save, `protectsExport` is permanently true.
- `reconcileProtectedCloudSyncActivity` (999–1015) and `beginProtectedCloudSyncActivity` (1021–1052) are gated only by `#if os(macOS)`, so they compile and run under `ATTIC_LOCAL_ONLY`. The first save acquires a real `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep, reason: "Exporting Attic changes to iCloud")` token (1030–1035) and every subsequent save re-arms its 120-second timeout task (1036–1037, 1077–1086).
- `observeRemoteChanges()` and `observeCloudKitEvents()` (941–970) hold live `NotificationCenter` subscriptions. A `NSPersistentCloudKitContainer.eventChangedNotification` posted anywhere in-process drives `handleCloudSyncEvent` (976–997), which mutates `cloudSyncProtection`, `cloudSyncStatus`, and can schedule a `refresh()`.

**Contrast.** The other two stores gate the identical machinery off:

- `NoteStore.swift:661–663` returns immediately from `handleCloudSyncEvent` under `ATTIC_LOCAL_ONLY`; `720–726` wraps `noteLocalSave`/`reconcile` in `#if !ATTIC_LOCAL_ONLY`; `1057–1089` compiles out both observer registrations.
- `CanvasStore.swift:225–233, 290–293` gates observers on `CanvasCloudInfrastructurePolicy.isEnabled`; `CanvasStoreCloudSync.swift:8, 19, 43` runtime-guards the same three paths and `64, 95, 117` compile-gates the activity-token functions with `os(macOS) && !ATTIC_LOCAL_ONLY`; `CanvasStorePersistence.swift:55–58` gates `noteLocalSave`.
- `AppCoordinator.swift:210–215` builds local-only containers with `cloudSyncEnabled: false`.

**Test evidence.** `AtticTests/NoteStoreTests.swift:6–33` (`testLocalOnlyNotesDoNotStartDeferredCloudActivity`) and `AtticTests/CanvasStoreTests.swift:708–746` (`testLocalOnlyStoreCreatesNoDeferredCloudInfrastructure`) both assert nil observers, nil refresh task, nil activity tokens, and unchanged `cloudSyncStatus` after a save plus a synthetic event. No equivalent `TaskStore` test exists; `TaskStore`'s observation/token fields are `private` (193–201), so the same assertions cannot currently be written.

**Causal chain.** Local-only build → first `TaskStore.save()` → `localSaveGeneration` becomes 1, `exportedSaveGeneration` stays 0 → `protectsExport` true forever → `beginProtectedCloudSyncActivity(.exportData)` acquires the App-Nap-suppressing token → each save cancels and re-arms the 120s timeout, so the token is effectively held for the whole session while tasks are being edited. The observers are dead weight for a `.none` CloudKit container but remain a live notification surface.

**User impact.** No data loss, but: (a) the development contract requires deferred sync machinery to "stay dormant in current local-only builds" — this is not dormant; (b) an `LSUIElement` utility that should idle at zero holds a `userInitiatedAllowingIdleSystemSleep` assertion for up to 120s after each save — a real energy/thermal side effect; (c) phantom "Exporting Attic changes to iCloud" activity reasons exist in local-only logs; (d) inconsistent behavior across the three stores, which is exactly the class of drift that makes the dormant-sync boundary hard to reason about.

**Recommended causal repair.** Apply the same gate the other stores use — either `#if !ATTIC_LOCAL_ONLY` around the observer call sites, the `noteLocalSave`/`reconcile` block in `save()`, and `handleCloudSyncEvent`'s body (matching `NoteStore`), or a shared `CanvasCloudInfrastructurePolicy.isEnabled`-style runtime gate for consistency. Do not merely skip `beginProtectedCloudSyncActivity`; the observers and event handler should be inert too, as they are elsewhere.

**Validation required.** Add `testLocalOnlyTasksDoNotStartDeferredCloudActivity` mirroring `NoteStoreTests.swift:6–33` (requires exposing the observation/token fields as internal like `NoteStore`'s): assert nil `remoteChangeObservation`, `cloudKitEventObservation`, `cloudImportRefreshTask`, both activity tokens and timeout tasks after a save and a synthetic `handleCloudSyncEvent`. Confirm the non-local-only path is still covered by existing CloudKit tests.

### D2 — STRONG EVIDENCE — P2 — Attachment-picker owner flag has exactly one clear path; a stranded NSOpenPanel deadlocks every Add-attachment affordance

**Evidence.** `Attic/Views/Panel/TaskImageAttachments.swift`: `uiState.taskAttachmentPickerOwnerID` is set at line 75 and cleared only inside `NSOpenPanel.begin`'s completion handler (77–79); `isComposerAttachmentPickerPresented` likewise (93–95). `isPresenting`/`isAvailable` (58–69) gate every picker affordance on those flags. A repository-wide search confirms no other clear path exists for either flag. `ConsolidatedDefectChecklist-2026-09-13.md` §A TP-005 records the reproduced failure in the current build: an `NSOpenPanel` present in the window and accessibility lists but unavailable onscreen, which "retained the picker-owner state, disabled other add-attachment actions, and made an enabled-looking subpanel action do nothing."

**Causal chain.** `choose` sets the owner flag → `present` calls `panel.begin` → if AppKit never delivers the begin-completion (the stranded-window state TP-005 reproduced), the flag is never cleared → `isPresenting` stays true → `isAvailable` returns false for every task and the composer → all picker affordances are permanently dead for the session.

**User impact.** Attachment-by-picker is lost for the session; drag/drop still works (`TaskFileDrop.canAccept`, `TaskAttachmentDrop.swift:307–315`, checks `importingAttachmentTaskIDs`, not picker flags), but users may not discover the escape hatch. Requires relaunch to restore the picker.

**Recommended causal repair.** Give the flag a teardown that does not depend on the begin-completion: observe the panel's close, add a watchdog that clears the owner when the completion never arrives, or bind ownership to an object whose lifetime matches the panel's. All exit paths (OK, cancel, orphaned panel) must converge on the same clear.

**Validation required.** Reproduce the stranded-panel state and verify the flag clears and the affordance re-enables; this is also the regression gate for TP-005.

### C1 — CANDIDATE — P3 — Note-attachment Open hands the private digest-keyed file to external editors; in-place saves are silently overwritten

**Evidence.** `Attic/Services/NoteAttachmentPlatformSupport.swift:17–28` — `NoteAttachmentActions.open` calls `NSWorkspace.shared.open(url)` on the private materialized file. Task attachments deliberately avoid this: `TaskAttachmentActions.open` uses `openableCopy` — a disposable read-only copy — "so no editor can save over the private file" (`TaskImageAttachments.swift:118–141`, `TaskImageReference.swift:120–129`). On the note side, `AttachmentFileStore.verifiedMaterializedURL`/`ensureMaterialized` (343+) rewrites the materialization from the SwiftData payload whenever bytes no longer match the digest, so an external in-place edit is silently reverted on next access.

**Causal chain.** Open a note attachment in an app that saves in place → save → bytes diverge from digest → next preview/open re-materializes from payload → the edit disappears with no warning.

**User impact.** Silent loss of work done in the external editor. The attachment itself is safe (payload wins), but the two attachment systems make opposite promises to the same user gesture.

**Recommended causal repair.** Route note-attachment Open through the same disposable copy path as tasks, or document the divergence as a deliberate choice.

**Validation required.** Open a note attachment in an in-place editor, modify, save, re-preview — confirm the chosen behavior is consistent and, if reverted, that the revert is at least surfaced.

### C2 — CANDIDATE — P3 — Pasted image data and file-promise drops are silently swallowed while an import is in flight or the draft can't flush

**Evidence.** `Attic/Views/Panel/NoteAttachmentTray.swift:1485` — pasted png/tiff data returns `true` with no error when `captureFileImportReceiver()` yields nil; `1503` — `receivePromisedFiles` returns silently in the same case. The receiver is nil while `isImporting` or when `prepareAttachmentImport` fails (`NotesPanelContent.swift:560–562`, which also flushes the draft). The equivalent busy condition on the URL-import path does report: "Finish or cancel the current attachment import before adding more files" (`NotesPanelContent.swift:541–546`, `578–581`).

**Causal chain.** Paste an image (or drop a file promise) while a multi-file import runs, or while a save error/conflict blocks `flush()` → receiver is nil → the paste is accepted and dropped with no feedback.

**User impact.** The paste appears to do nothing — indistinguishable from data loss to the user, though nothing is actually persisted or removed.

**Recommended causal repair.** Surface the same busy/conflict message on the paste and promise paths when the receiver cannot be captured.

**Validation required.** Paste during a multi-file import and during a simulated save failure; expect the calm error instead of a silent no-op.

### C3 — CANDIDATE — P3 — Attachment file removal trusts per-task id-uniqueness; delete/purge/remove do not re-check surviving references

**Evidence.** `TaskStore.swift:638–643` — `delete` collects `removedImages` from the deleted family's replicas and removes the files post-save; `683–687` — `purgeCompleted` does the same for expired families; `565–575` — `removeAttachment` removes the file post-save. The once-per-launch sweep is stricter: `sweepUnreferencedAttachmentStorage` collects referenced IDs from *every* physical replica before removing anything (522–531). Legitimate sharing cannot arise through imports (fresh UUIDs) or card copies (new identities), and `attachmentSource` (442–450) refuses ambiguous cards — so a shared id requires crafted/corrupt imported data.

**Causal chain.** Crafted store where two logical tasks reference one attachment id → delete the first → its materialization is removed → the survivor's reference dangles; task attachments carry no payload (unlike notes), so the card is permanently broken ("missing or changed in Attic's private storage", 177–179).

**User impact.** Only reachable through corrupt/imported state, but the failure mode is irreversible attachment loss for the surviving task — worth the same defensive rigor the sweep already applies.

**Recommended causal repair.** Filter post-delete/post-purge file removals through a surviving-reference check (the same replica-wide query the sweep performs), or explicitly document the uniqueness invariant these paths rely on.

**Validation required.** Test with two tasks referencing one attachment id: deleting one must leave the other's preview/export intact.

## Passes (source-verified)

- **Save/rollback discipline.** `TaskStore.save()` (TaskStore.swift:863–882), `NoteStore.save()` (NoteStore.swift:691–708), and `CanvasStore.save()` (CanvasStorePersistence.swift:25–84) all persist through one injected closure, roll back on failure, and reload through a fresh context; `discardPendingChanges` (CanvasStorePersistence.swift:11–22) clears stranded mutations after pre-save failures. Canvas also handles the save-succeeded/reload-failed case with a resolved fallback presentation (`.persistedButRefreshFailed`, 60–72).
- **Fresh-context replacement.** `TaskStore.reloadTasks` (884–894), `NoteStore.reloadModels` (710–718), and `CanvasStore.reloadCanvas` (86–102) replace the live `ModelContext` rather than refreshing objects in place; CloudKit import completion schedules the same fresh reload (TaskStore.swift:986–996, NoteStore.swift:674–684, CanvasStoreLifecycle.swift).
- **Duplicate UUID handling.** Presentation dedup only (`visibleUniqueTasks`, TaskStore.swift:900–920; note/attachment equivalents in NoteStore) — no replica deletion during refresh; mutations write every physical replica (`update` 372–382, `attachImported` 490–493, `removeAttachment` 570–572, `delete` 638–639); `storedTaskGroups` throws `missingReplica` on absent groups (930–939); `delete` refuses divergent parent groups and nested/cyclic links (623–632); `purgeCompleted` refuses divergent replicas via full-snapshot comparison including `completedAt` and `imageReferencesData` (135–158, 657–668).
- **Completion timestamps and daily cleanup.** `completedAt` stamps only on the done transition and clears on reopen (365–370); purge cutoff is `calendar().startOfDay` (DailyCleanupService.swift:63–67); expiry is family-coherent — neither side of a parent/child link can expire alone (672–680); triggers cover day change, timezone change, activation, and wake (27–47); purge removes attachment files post-save (683–687).
- **Parent/subtask invariants.** Child creation requires an unfinished top-level parent across all replicas (239–244); completing a task with unfinished children requires explicit override (322–326) routed through the calm confirmation in `TaskRowView.swift:119–131, 433–451` and `TaskSectionView.swift:58–84` (TASK-001); reopening a child under a done parent is refused (327–331); drops are same-parent only (784); orphaned parent links stay visible as roots instead of being hidden (715–722).
- **Task attachment ownership and import.** `attachmentOwnerID` resolves children to parents (547–551); `importingAttachmentTaskIDs` serializes per-owner imports with a calm refusal (475–480); `attachImported` re-validates owner existence after the async copy, writes every replica, and removes imported copies on save failure or error (466–503); per-owner progress is visible in the panel chrome (SubtaskPanelContent.swift:504–536, 544–567).
- **Pending composer attachments.** Generation-counter cancellation — a cancelled batch's late-finishing copies are deleted (`TaskComposerAttachments.swift:56–66, 79–86`); per-chip removal deletes only composer-owned copies (88–92); one batch at a time and submit blocked during import (26–32); single-save bind with `didBind()` only on success, draft kept for retry on failure (`AtticPanelView.swift:715–727`); abandoned copies reclaimed by the once-per-launch, 24-hour-minimum-age sweep that collects references across all replicas and is capped at 500 removals (`TaskStore.swift:505–539`, `AttachmentFileStore.swift:274–339`).
- **AttachmentFileStore.** Actor-serialized; `<UUID>/<digest>/<name>` layout validated before path construction; rejects traversal, non-files, symlinks, malformed entries, and size mismatches; 1 MiB chunked reads with `Task.checkCancellation()`; byte-count + SHA-256 verification; limits (20 attachments, 15 MiB each, 100 MiB total) enforced pre-read where possible; per-batch rollback of staging and committed directories; balanced security-scope access and `NSFileCoordinator` reads (405–464); metadata-first reconciliation with lazy payload repair.
- **Drag/drop classification and card copies.** `TaskDropContent.classify` prioritizes task-marker, card-marker, listed file types, then generic data minus text/url/Attic markers (TaskAttachmentDrop.swift:45–60); task drags never classify as files despite exporting a folder (8–10); providers handed on are exactly the accepted kind (64–70); `TaskFileDropTarget` shares panel-level targeting across surface and rows with `end()` clearing all sources (350–369); card copies verify the own-process marker against the recorded source, refuse the owning task, and mint new private identities inside the import reservation (250–291, TaskStore.swift:429–461).
- **Task export payloads.** `TaskDragPayload.transferRepresentation` exposes the own-process task type, a folder export (only when attachments exist) containing `Task.txt` plus verified private copies, and a plain-title fallback (TaskDragPayload.swift:74–82); exports land in disposable directories pruned after a day (TaskImageReference.swift:158–182); card drags register a file representation under the recorded content type plus an own-process marker and copy only on accepted drop (23–56).
- **File promises and paste.** `AttachmentAcceptingTextView` creates a unique destination per batch, tracks each expected index exactly once, sorts by original index, times out at 30s, cancels on teardown, and idempotently removes failed/late destinations (NoteAttachmentTray.swift:1378–1390, 1502–1545, `PromisedFileBatch` 1555+); `captureFileImportReceiver` pins the logical note before bytes arrive (1547–1552 → NotesPanelContent.swift:560–572); pasted images are size-checked before writing (1479–1498).
- **Note attachment import transaction.** Immutable origin captured before any yield; `invalidatedAttachmentImportIDs` checked inside the MainActor-atomic critical section (NoteStore.swift:357); `delete` invalidates in-flight imports targeting the deleted note (241–258); imported files removed on every failure path; only the exact initiating blank session may adopt a reserved note (`NoteDraftController.completeAttachmentImport`, 344–379); reserved-ID merge prevents autosave/import duplicate creation (439–460).
- **Inline anchors and cards.** `NoteInlineAnchor.moved` rebases UTF-16 offsets via prefix/suffix matching and normalizes to paragraph starts; the editor rebases stored offsets from persisted body to current draft; every placement mutation flushes the draft first (NoteInlineCards.swift:115, 128, 133, 146, 151; NotesPanelContent.swift:296–297); paragraph space is reserved through `paragraphSpacingBefore` with undo registration disabled and typing attributes cleaned (215–232); out-of-range cards hide rather than misposition (240–242).
- **Autosave and recovery.** Trailing debounce plus a maximum deadline that typing does not extend (NoteDraftController.swift:598–631); conflicts cancel autosave (601, 633–637); a persisted-snapshot comparison prevents autosave from overwriting remote changes (404–408); clearing every field reverts to the persisted snapshot instead of erasing the note (410–421); recovery checkpoints are generation-guarded (650–669); `saveAsNew` covers the missing-original path; `beginNew`/`beginEditing` flush before switching sessions (303–326).
- **Hide/termination durability.** Panel hide flushes before any destructive UI teardown (AtticPanelController.swift:459–461 — a failed flush rejects the hide, keeping the error visible); section switches close the draft first (AtticPanelView.swift:768–770); `onDisappear` flushes (NotesPanelContent.swift:257–263); `prepareForTermination` flushes and vetoes quit on failure while revealing the notes panel (AppCoordinator.swift:391–399, AppDelegate.swift:25–33); `stop()` flushes again (376).
- **Sandbox and permissions.** Balanced `startAccessingSecurityScopedResource`/`stopAccessing` around source reads (AttachmentFileStore.swift:416–421, CanvasImageImporter.swift:97–100); no bookmark persistence anywhere — private copies mean no long-lived references to user originals; unsafe types can preview/export but not Open (`TaskAttachmentActions.canOpen` → `NoteAttachmentActions.isSafeToOpen`); task Open uses a disposable read-only copy; sweeps and staging cleanup never traverse symlinks (AttachmentFileStore.swift:299–302, TaskAttachmentDrop.swift:115–117).
- **Serialization.** One import per note (`attachmentImportInFlight`), per task owner (`importingAttachmentTaskIDs`), per composer batch (`canAdd`), and one picker at a time (`isPresenting`) — overlapping requests produce calm messages rather than silent drops (except the C2 paste gap).

## Unverified

These areas read as designed but were not exercised; per the audit contract they are not passes:

- Relaunch durability end-to-end (session restore, sweep, recovery checkpoint replay) — no app launch was performed.
- Real file-promise delivery from Photos/Mail/Finder — receiver logic is source-verified only.
- Large/oversized file behavior under real memory pressure — limits are source-verified, not stress-tested.
- Quick Look presenter behavior when the underlying materialization is removed while previewed.
- The window-state half of the picker defect (why the `NSOpenPanel` stranded offscreen) — TP-005's visual/lifecycle portion belongs to the panel lanes; only the flag-retention mechanism is established here.
- Whether real external editors write in place to the handed URL (C1's trigger condition).
- Canvas content-level items (CANVAS-009/011/012): the persistence layer passed review, but large-image stalls, real Finder/file-promise imports, and missing-asset UX were not exercised.

## Validation checklist for the repair effort

- Durable saves and clean rollback on injected persist failures (all three stores) — covered by existing focused tests; rerun after any change.
- Fresh-context replacement after external/imported writes — `NoteStoreTests.swift:30–31` asserts it for notes; add the TaskStore local-only twin per D1.
- Duplicate-UUID replicas: presentation dedup, replica-wide mutation, divergent-replica cleanup refusal — covered in `TaskStoreTests`/`SubtaskTests`; keep green.
- Completion sorting, `completedAt` day-boundary cleanup, family-coherent expiry — `DailyCleanupServiceTests`, `TaskStoreTests`.
- Parent/subtask invariants and the unfinished-subtask confirmation — `SubtaskTests`, row/section drop tests in `TaskAttachmentDropTests`.
- Pending composer attachments: cancellation, failed-submit retention (`testFailedSubmitKeepsTheDraftItemsAndTheirCopiesForRetry`, `TaskAttachmentDropTests.swift:789`), sweep reclamation.
- Import partial failure/retry, missing/corrupt materialization repair — `NoteAttachmentTests`, `TaskImageTests`/`TaskImageFileTests`.
- File-promise timeout and late delivery — `PromisedFileBatch` tests where present; manual verification against real source apps still owed.
- Drag/drop classification, ownership routing, card copy identity — `TaskAttachmentDropTests`.
- Autosave deadline/cancellation/conflict — `NoteDraftControllerTests`.
- Hide/termination durability and relaunch persistence — manual UAT owed; the flush gates are source-verified only.
- Local-only absence of CloudKit activity — add the TaskStore test per D1; `NoteStoreTests.swift:6–33` and `CanvasStoreTests.swift:708–746` already pin the other two stores.
