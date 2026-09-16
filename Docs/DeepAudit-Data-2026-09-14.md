# Deep Audit — Data & Reliability Domain — 2026-09-14

Independent read-only audit of the current Attic worktree, covering:

- Notes editing, drafts, anchors, Unicode, undo, autosave
- Task/subtask semantics and ordering
- Attachment import/export/drag and file lifetime
- Migrations, replicas, CloudKit/local-only behavior, save rollback/retry, data integrity

## Reviewed state

- Repo: `/Users/taha/Developer/attic-task-panels-v2`, branch `codex/attic-task-panels-v2`, HEAD `ae6418c`.
- The worktree is extensively dirty (the notes/attachments/subtasks feature stack
  is uncommitted). All domain files were read in their current dirty state;
  line numbers reference that state and may drift with further edits.
- Concurrent implementation work landed during the audit window (R-01/R-02 anchor
  pipeline, attachment platform support, task attachment layer). Reconciled by
  re-reading the current files rather than trusting prior reports.
- Orientation docs read first (not rubber-stamped): `ConsolidatedDefectChecklist-2026-09-13.md`,
  `RollingWork-2026-09-14.md`, `Opus-PERFA1-Review-Fixes.md`, `Sol-PERFA1-Native-Final.md`,
  plus `Rolling-Reliability-Audit.md` and the concurrent-review docs as prior evidence.

## Validation limits

- **No builds, no test runs, no app launches, no native UI interaction** were performed;
  every claim below is source/test-suite evidence, not runtime verification.
- No user stores or CloudKit state were touched. No delegation was used — the optional
  child-subagent slot was not needed; coverage was completed directly.
- CloudKit/iPhone code paths are dormant under `ATTIC_LOCAL_ONLY` on macOS and were
  audited as source only. Nothing here validates sync behavior on real CloudKit.
- Preview provenance (`com.taha.Attic.perfa1final`, SHA `240f6bca…`) was treated as
  provenance only; no UI conclusions depend on it.

## Coverage matrix

| Subsystem | Files audited | Depth |
|---|---|---|
| Note models | `Models/NoteItem.swift`, `Models/NoteAttachment.swift` | full |
| Note store | `Services/NoteStore.swift` (1313 lines) | full |
| Draft/autosave/recovery | `Services/NoteDraftController.swift` (752 lines) | full |
| Anchors/edits | `Models/NoteInlineAnchor.swift` | full |
| Inline cards/ledger/resolver/layout | `Views/Panel/NoteInlineCards.swift` (567 lines) | full |
| Editor, coordinator, paste/drop/promise | `Views/Panel/NoteAttachmentTray.swift` (1890 lines) | full |
| Note composer wiring | `Views/Panel/NotesPanelContent.swift` (1048 lines) | full |
| Task model | `Models/TaskItem.swift`, `Models/TaskTypes.swift` | full |
| Task store | `Services/TaskStore.swift` (1415 lines) | full |
| Task views | `TaskFamilyView`, `TaskSectionView`, `TaskRowView`, `SubtaskPanelContent` | full |
| Task attachments | `TaskImageReference.swift`, `TaskAttachmentDrop.swift`, `TaskComposerAttachments.swift`, `TaskImageAttachments.swift`, `TaskDragPayload.swift` | full |
| Attachment storage | `Services/AttachmentFileStore.swift` (576 lines), `NoteAttachmentPlatformSupport.swift` | full |
| Persistence/lifecycle | `PersistenceController.swift`, `AppCoordinator.swift`, `AppDelegate.swift`, `DailyCleanupService.swift`, `CornerHoverMonitor.swift` (policy), `AtticPanelController.swift` (hide path), `SubtaskPanelController.swift` (reveal), `PanelUIState.swift`, `AtticPanelView.swift` (wiring) | full |
| Canvas persistence (shared container) | `CanvasStore.swift`, `CanvasStorePersistence.swift`, `CanvasStoreReplicaResolution.swift`, `CanvasStoreCloudSync.swift`, `CanvasStoreLifecycle.swift`, `CanvasStoreBoards.swift` | full entry points |
| Agent/MCP surface | `AgentServer.swift`, `AgentHTTPRequest.swift`, `MCPRequestHandler.swift`, `AgentTaskTools.swift` | full |
| Project/target gating | `Scripts/generate_project.rb`, `AtticMobile/App/MobileAppModel.swift` | full |
| Tests (evidence, not run) | `AtticTests/*` — NoteStore, NoteDraftController, NoteInlineCards, NoteAttachment, TaskStore, TaskAttachmentDrop, TaskImage, Subtask, DailyCleanup, MCPRequestHandler suites | test-name inventory |

## Findings

### Confirmed

---

#### AUDIT-DATA-01 — Note-attachment orphan cleanup can delete an in-flight import's files

- **Severity:** Low (self-healing; no permanent data loss)
- **Confidence:** High for the mechanism; Medium for user-visible impact
- **Location:** `Attic/Services/AttachmentFileStore.swift:356-380` (`cleanOrphans`), invoked from `reconcileMetadata` at `:219`; reconciler launched by `NoteStore.reconcileFileStorage` at `Attic/Services/NoteStore.swift:1023-1064`.

**Mechanism.** `reconcileFileStorage` computes a signature over the presentation
attachment set, snapshots `expected` as `<attachmentID>/<digest>` keys, and runs
`reconcileMetadata` on the file-store actor. At the end of that pass,
`cleanOrphans` removes **every** materialization directory under the store root
whose key is not in `expected` — with no recency guard and no
in-flight-import exclusion. `expected` is fixed when the pass starts, so even an
attachment that *commits mid-pass* is unprotected.

Every sibling cleanup path in the codebase has the guard this one lacks:

- `removeUnreferencedMaterializations` (`AttachmentFileStore.swift:284-339`) —
  requires directory **and** contents created **and** modified before a cutoff.
- staging cleanup in the same function (`:382-391`) — 24-hour age gate.
- `TaskStore.sweepUnreferencedAttachmentStorage` (`TaskStore.swift:670-685`) —
  refuses to run while `importingAttachmentTaskIDs` is non-empty and applies a
  24-hour `minimumAge` on top of replica-wide reference collection.
- `TaskAttachmentStaging.removeAbandoned` (`TaskAttachmentDrop.swift:108-125`) —
  dual-date cutoff plus symlink refusal.

**Trigger / reproduction.** Any attachment-set change that starts a reconcile
(e.g., removing an attachment, or import A's commit) while a second import B is
materializing: B's `importFiles` writes `B-id/B-digest` through the same
file-store actor; the still-running reconcile-A pass reaches `cleanOrphans`
after the write but with an `expected` set that predates B's commit, and deletes
the directory. B's model commit then succeeds normally.

**Expected vs actual.** Expected: a materialization belonging to an in-flight or
just-committed import is never collected. Actual: it is deleted as an orphan.

**Evidence.** Source trace above; the design asymmetry is directly visible
between `cleanOrphans` (`:356-380`, no date checks) and
`removeUnreferencedMaterializations` (`:292-296` `isOld` gate). Prior audit noted
the same gap (R-03); confirmed still present in current code.

**Impact.** Bounded by design elsewhere: the payload is durable in the SwiftData
row, so the next access rebuilds the file via `ensureMaterialized`. Between
deletion and that rebuild, `verifiedMaterializedURL` returns nil — a drag-out,
Quick Look, or export in that window reports "the original file is missing," and
the card can briefly surface a spurious recovery prompt. Also wastes the
import's write.

**Smallest suggested fix.** Either (a) skip `cleanOrphans` while an import is in
flight — the store already tracks `attachmentImportInFlight`/`attachmentImportActivity`,
so the reconcile launch in `reconcileFileStorage` can defer or the flag can be
passed through `reconcileMetadata` — or (b) give `cleanOrphans` the same
created-and-modified-before-cutoff test `removeUnreferencedMaterializations` uses.

**Verification plan.** Unit test on an isolated `AttachmentFileStore`: start a
`reconcileMetadata` pass whose `expected` lacks a key, materialize a file under
that key mid-pass, assert it survives. Re-run existing reconciliation tests
(`testReconcileRemovesOnlyUnreferencedMaterializations`,
`testMixedBatchFailureRollsBackEarlierMaterializations`) to confirm true orphans
are still collected.

---

#### AUDIT-DATA-02 — Deferred CloudKit/mobile path still carries the former owner's identity

- **Severity:** Medium (contract violation + activation trap; no current data exposure in local-only builds)
- **Confidence:** High
- **Location:**
  - `Attic/Services/PersistenceController.swift:11` — `cloudKitContainerIdentifier = "iCloud.com.emanueledipietro.Attic"`; used by `makeConfiguration` at `:28` and the debug schema bootstrap at `:169-170`.
  - `Scripts/generate_project.rb:228-255` — AtticMobile target: `PRODUCT_BUNDLE_IDENTIFIER = com.emanueledipietro.Attic`, `DEVELOPMENT_TEAM = HR24WHR326`, iCloud container environment + APS environment wiring, and **no `-DATTIC_LOCAL_ONLY`** flag.
  - `AtticMobile/App/MobileAppModel.swift:82-94` — calls `initializeCloudKitDevelopmentSchemaIfNeeded()` (DEBUG, non-test) and `makeContainer(inMemory:)` with `cloudSyncEnabled` defaulting to `true`; `:131-132` queries `CKContainer(identifier: cloudKitContainerIdentifier).accountStatus()`.

**Mechanism.** The shared stores compile into the iOS target without
`ATTIC_LOCAL_ONLY`, so every `#if !ATTIC_LOCAL_ONLY` path (remote-change
observers, CloudKit event observation, sync-protection bookkeeping) is live
there, and the container configuration attaches `.private(cloudKitContainerIdentifier)`.

**Trigger.** Building or running the generated AtticMobile target, or producing
any non-`ATTIC_LOCAL_ONLY` macOS build.

**Expected vs actual.** Per the development contract: "Never restore the former
owner's bundle identifier, team, or CloudKit container as a shortcut," and
re-enabling CloudKit requires "a CloudKit container owned by Taha's Apple
developer account." The re-enable can therefore never legitimately use these
values — yet they remain the wired defaults, so the first mobile/non-local build
attempts Development/Production CloudKit against `iCloud.com.emanueledipietro.Attic`
under `com.emanueledipietro.Attic`/`HR24WHR326`.

**Evidence.** Build settings in `generate_project.rb` are unambiguous; macOS
local-only dormancy verified separately (`AppDelegate.swift:5`,
`AppCoordinator.swift:188-218`, `CanvasStore.swift:433-441`,
`CornerHoverMonitor.swift:14-20`, plus `#if !ATTIC_LOCAL_ONLY` gates in
`TaskStore`/`NoteStore`). Prior reports do not mention the identifier (checked
`ConsolidatedDefectChecklist`, `Rolling-Reliability-Audit`, `RollingWork`).

**Impact.** Latent today. On activation the realistic outcome is a signing or
entitlement failure (team/container mismatch) rather than silent sync to the
wrong account — but that outcome is luck, not design, and the debug schema
bootstrap could write record types into the former owner's Development container
if credentials ever resolve.

**Smallest suggested fix.** Remove the former-owner defaults from generated
targets: make `cloudKitContainerIdentifier` a value the re-enable project must
supply (no usable default), and either exclude AtticMobile from generation or
give it `ATTIC_LOCAL_ONLY` parity until the explicit CloudKit/iPhone activation
plan lands.

**Verification plan.** `grep -rn "emanueledipietro\|HR24WHR326"` returns nothing
outside this report; local-only build still launches; mobile target is absent or
builds local-only.

---

### Plausible but unverified concerns

#### AUDIT-DATA-03 — Corrupt `imageReferencesData` presents as "no attachments" rather than surfacing an error

- `Attic/Models/TaskItem.swift:33` — `try? JSONDecoder().decode(...) ?? []`: an
  undecodable payload yields an empty list, so a task with corrupt attachment
  metadata displays no attachments and no error. The file-cleanup side is
  conservative (`storedAttachmentIDs`, `TaskStore.swift:753-764`, throws on
  decode failure so files are kept), so the failure mode is "invisible but
  preserved," not loss — but nothing tells the user data failed to decode, and
  re-saving the row (any edit writes `imageReferencesData` back? — verified:
  only attach/remove write the field) — actually edits do NOT rewrite it, so
  the corrupt payload persists untouched. Reachable only with a corrupt/migrated
  store. **Suggested fix:** log or surface a decode failure once per row (e.g., a
  store-level warning), keeping the conservative file retention. **Verify:** unit
  test feeding malformed `imageReferencesData` asserts a surfaced error while the
  task still renders.

#### AUDIT-DATA-04 — Agent `update_note` anchor derivation runs a whole-document paragraph diff

- `Attic/Services/AgentServer/AgentTaskTools.swift:411-413` calls
  `noteStore.update(note, title:, body:)` with no `bodyEditBatch`, so
  `NoteStore.update` (`NoteStore.swift:216-244`) falls back to
  `NoteTextReplacement.edits(from:to:)` — an O(document) diff per agent call.
  Correct (the `attachmentAnchorFallbackDerivations` counter tracks it), and
  agent writes are rare, so this is structural only — no measurement taken.
  Flagged so a future high-frequency agent caller knows the path exists.

#### AUDIT-DATA-05 — Orphaned subtasks present as roots but cannot receive attachments

- `TaskStore.attachmentOwnerID` (`TaskStore.swift:696-700`) returns nil for a
  subtask whose `parentID` resolves to no live parent, while `snapshot(for:)`
  (`:944`) deliberately presents orphans as roots ("never hide data"). Such a row
  shows a normal task row whose attachment affordances are all disabled/refused
  with no explanation. Reachable only via malformed/migrated `parentID` data.
  Low severity; arguably acceptable for corrupt state. **Verify (if fixed):**
  orphan-fixture test asserting either an explanatory affordance state or
  attachment ownership resolution to the orphan itself.

### Measured performance findings

None. No builds or runtime measurements were permitted; all performance notes
above are explicitly structural. The codebase's own gate tests
(`TaskPerformanceGateTests`, `CanvasPerformanceGateTests`, per-keystroke ledger
tests in `NoteInlineCardsTests`) exist as evidence of intended complexity bounds
but were not executed here.

### Optional UX suggestions

- **Silent move refusal on failed flush.** `NoteMovableAttachmentCard` move/place
  actions (`NoteInlineCards.swift:135, 148, 153, 169, 174`) and the editor's
  `onMoveAttachment` (`NotesPanelContent.swift:301-304`) return false when the
  preceding `noteDraft.flush()` fails; the card snaps back with only the generic
  save-error line. Surfacing "attachment couldn't be moved because the note
  isn't saved" would make the refusal self-explanatory.
- **Accepted-then-ignored internal drops.** `NoteMovableAttachmentCard.onDrop`
  (`NoteInlineCards.swift:129-140`) returns `true` before the async marker load
  validates; a malformed marker is accepted then silently ignored. Cosmetic only —
  the drag type is same-process so malformed markers cannot arrive externally.

## Verified-sound areas

Each of these was traced end-to-end in source; where a prior report claimed a
fix, the current code was re-verified rather than assumed.

- **Draft durability lifecycle** (`NoteDraftController`): flush-gated
  `beginNew`/`beginEditing`/`close`; missing originals produce `.missingOriginal`
  conflicts instead of discarding dirty drafts; remote changes produce
  `.remoteChange`; `close()` refuses on flush failure; blank new drafts never
  persist; session journal is generation-guarded with atomic writes and
  restores cleanly over saved content (`NoteDraftController.swift:226-274`,
  `:391-497`, `:499-535`, `:603-616`, `:618-664`). Covered by
  `NoteDraftControllerTests` (recovery, conflict, autosave coalescing, failed
  save retention — not run here).
- **Anchor pipeline** (post-R-01/R-02): ordered pre-coalescing edit capture in
  the coordinator, running-coordinate ledger, validated batch application with
  paragraph-diff fallback, UTF-16-consistent offsets, undo/IME handling
  (`NoteInlineAnchor.swift`, `NoteInlineCards.swift`, `NoteAttachmentTray.swift`
  coordinator). Paragraph-diff algorithm verified against insert/remove/split/
  merge/disjoint cases by hand-trace plus the existing test inventory.
- **Note store mutation integrity** (`NoteStore.swift`): all mutations fan out to
  every physical replica; `save()` rolls back + reloads on failure
  (`:758-776`); `installPresentation` swaps in the fresh context so stale model
  instances are never presented (`:807-819`); attachment import is atomic —
  fresh transaction context created *after* materialization, owner rows
  re-fetched inside it, no suspension between validation and `persistImport`
  (`:393-475`); in-flight import to a deleted note is invalidated and reports
  `originUnavailable` (`:274-290`, `:390-392`); `removeAttachment` deletes all
  replicas then removes files only after save (`:536-565`); `materializedURL`
  re-verifies digest and refuses to hand back files for rows deleted mid-
  materialization (`:567-604`).
- **Import/restore seams**: blank-draft imports use a reserved logical ID so
  autosave and import completion converge on one note (`:335-346`,
  `NoteDraftController.swift:335-389`); `locateAttachment` requires digest
  match in a fresh context before restoring payload.
- **Task semantics** (`TaskStore.swift`): replica-agreement gates on purge,
  delete, and completion; family-cohesion fixpoint in `purgeCompleted`
  (`:843-904`); nil `completedAt` never expires (`:853`); divergent replicas
  refuse destructive ops; nested/cyclic links refuse deletion (`:787-840`);
  reorder keeps sparse `manualOrder` values with O(n) rebalance only when packed
  (`:1011-1055`); all agent and UI mutations route through the same store
  invariants (`AgentTaskTools.swift:287-341` validates before mutating; agent
  cannot complete a parent over unfinished subtasks).
- **Attachment transport security**: task drags promise the recorded content
  type and hand receivers a copy, never the private file in place
  (`TaskDragPayload.swift:40-73`); Open/Export hand out read-only disposable
  copies under a pruned temp root (`NoteAttachmentPlatformSupport.swift:25-73`,
  `TaskImageFiles.openableCopy`); `isSafeToOpen` refuses executables/scripts/
  packages/untyped data (`:129-144`); gallery-card moves revalidate the marker
  against the store before copying (`TaskAttachmentDrop.swift:256-291`); the
  picker session has a single idempotent finish path covering OK/cancel/
  close/stranded-panel (`TaskImageAttachments.swift:117-231`).
- **Staging/rollback**: `TaskDroppedFiles.stage` discards its owned directory on
  any failure (`TaskAttachmentDrop.swift:152-176`); `attachImported` removes
  imported private copies when the owner vanished mid-import or the save fails
  (`TaskStore.swift:618-655`); composer batches are generation-guarded with
  cancel-time cleanup (`TaskComposerAttachments.swift:55-115`); a failed submit
  keeps pending items for retry while the launch sweep reclaims abandoned copies
  (`AtticPanelView.swift:746-761`, `TaskStore.swift:670-685`).
- **Persistence boundaries** (`PersistenceController.swift`): `.none` cloud
  database when in-memory or sync-disabled (`:25-28`); Development and
  Production stores are disjoint (`:40-51`); one-time pre-CloudKit backup only
  on sync-enabled persistent stores (`:62-64`); schema bootstrap is DEBUG-only
  and environment-gated (`:147-199`); the UI-test container is a separate store
  family (`:91-141`).
- **Local-only dormancy** (macOS): `ATTIC_LOCAL_ONLY` set for app/unit-test
  targets (`generate_project.rb:163, 193, 209`); no APNs registration
  (`AppDelegate.swift:5-7`); no schema bootstrap (`AppCoordinator.swift:188`);
  `CanvasCloudInfrastructurePolicy.isEnabled == false` (`CanvasStore.swift:433-441`);
  `RevealRefreshPolicy.inProcessAuthoritative` (`CornerHoverMonitor.swift:14-20`);
  daily cleanup skips the pre-purge refresh in local-only
  (`DailyCleanupService.swift:69-80`).
- **Canvas replica discipline** (shared container): winner selection is a total
  deterministic order with a scalar-metadata shortcut avoiding blob faults
  (`CanvasStoreReplicaResolution.swift:72-158`); save resolves presentation,
  persists, reloads, and has an explicit persisted-but-refresh-failed path
  (`CanvasStorePersistence.swift`); tombstones (not deletes) protect against
  CloudKit merge resurrection; mutations fan out to all replicas with
  `nextMutationVersion` (`CanvasStoreLifecycle.swift`, `CanvasStoreBoards.swift`).
- **Agent transport** (`AgentServer.swift`, `AgentHTTPRequest.swift`,
  `MCPRequestHandler.swift`): loopback-only listener, Host allowlist, Origin
  rejection (DNS-rebinding defense), constant-time bearer compare, 64 KB request
  cap, duplicate-Content-Length and Transfer-Encoding rejection, incremental
  header scan, correct JSON-RPC error mapping.
- **Hide/termination durability gates**: `requestHide` flushes the draft before
  any destructive state change (`AtticPanelController.swift:447-498`);
  termination is vetoed on flush failure and reveals Notes
  (`AppCoordinator.swift:394-397`); `onDisappear` performs the final flush
  (`NotesPanelContent.swift:261-267`); section switches close Notes only after
  `noteDraft.close()` succeeds (`AtticPanelView.swift:800-805`,
  `CornerHoverMonitor.swift:197-207`).

## Dismissed hypotheses

- **Saved-note-drawer delete diverges from note-row delete** (doesn't call
  `noteDraft.discardDeletedNote`). Disposition: benign. Store deletion bumps
  `noteStore.revision` → `AtticPanelView.reconcileNoteDraft()` →
  `reconcileWithStore()` — a dirty active draft becomes a recoverable
  `.missingOriginal` conflict; a clean one discards and the UI selects another
  note. Matches the prior audit's disposition; verified in current source
  (`NotesPanelContent.swift:847`, `NoteDraftController.swift:499-535`,
  `AtticPanelView.swift:854-868`).
- **Paste/promise failures silently swallowed** (historical C2). Disposition:
  fixed — busy/unavailable messaging, unsupported-promise reporting, promised-
  batch timeout/cancellation with late-delivery cleanup all present
  (`NoteAttachmentTray.swift` router + `NotesPanelContent.swift:555-580`).
- **CloudKit still active in local-only builds** (historical D1). Disposition:
  fixed — dormancy verified at every gate listed above.
- **Multi-context lost update during import** (import holds a stale note
  snapshot across file-copy awaits). Disposition: not present — the transaction
  context is created fresh post-materialization and the commit section has no
  suspension points (`NoteStore.swift:393-475`).
- **Subtask rows leaking into status lists** (`orderedTasks` doesn't filter
  `parentID`). Disposition: `snapshot(for:)` excludes children via
  `parent(of:)` (`:944`); `reorder` re-filters by `parentID` (`:1023`); agent
  listings serialize `parent_id` so the flattening is self-describing
  (`AgentTaskTools.swift:463`).
- **Purge racing an in-flight attach to a done task**: `attachImported`
  re-resolves the owner after file work and purges run atomically on the main
  actor with no interleave into the commit section — covered (`:636-646`).

## Residual uncertainty

- Anchor/edit correctness is verified by source trace and test inventory; the
  XCTest suite was **not executed** (no builds permitted). If CI runs it green,
  confidence in the anchor pipeline becomes test-backed rather than source-only.
- AUDIT-DATA-01's real-world frequency is unmeasured; the window is real but
  narrow (requires an attachment-set reconcile overlapping an import's
  materialization).
- AtticMobile shared-store behavior was audited as source only; whether the
  deferred iOS target currently *compiles* is unverified.
- `attachmentReconciliationSignature` uses a non-cryptographic `Hasher` as a
  change gate; a collision would skip a needed reconcile. Inputs are
  app-generated and a miss self-heals via on-demand materialization — noted as
  residual risk, not a finding.
- No claim is made that every defect was found; concurrent dirty-worktree edits
  after the read timestamps could shift behavior.

## Prioritized fixes

1. **AUDIT-DATA-02** — remove former-owner CloudKit/bundle/team identity from
   generated targets and `PersistenceController` defaults before any non-local
   build exists. (Contract-level correctness; prevents the first mobile build
   from wiring the wrong account.)
2. **AUDIT-DATA-01** — add the recency/in-flight guard to `cleanOrphans`
   (align with `removeUnreferencedMaterializations`).
3. **AUDIT-DATA-03** — surface corrupt `imageReferencesData` decode failures
   once per row.
4. Optional UX items (move-refusal messaging, drop-accept ordering) at leisure.
