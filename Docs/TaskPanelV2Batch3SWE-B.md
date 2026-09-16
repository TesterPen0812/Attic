# Task panel V2 — batch 3 (R4 drops + R5 composer) independent review (SWE-B)

Reviewer scope: `.build/batch3.diff` (sha256 `dfc2d677…`, verified against
`diffs.txt`) against prefix tree `98cb0b6e14fedd6d78b5a431a9529e14e6fc9bdb`;
`GIT_INDEX_FILE=.build/batch3/prefix.index git diff` against the worktree
reproduces the diff's file set (new untracked files plus orchestrator docs
handled per `diffs.txt`), and the diff already contains the post-test one-line
`.onChange(of: mode)` refresh — current sources are the reviewed ones. Focus:
drag classification and task reorder/status parity, cross-task card drops,
panel overlay and child-row crossings, success reveal and card entrance,
composer growth/picker/keyboard/AX/error interaction, and resource lifecycle.
Ledger claims were checked against the code, not taken on faith.

## Verdict

**Approved with two contract gaps to fix before acceptance** — one P1
(cross-task attachment-card drops refused outright, against the user's stated
"drops onto any task" intent) and two P2s (promised general-file coverage,
pending-composer orphans on quit). The mechanics underneath — staging
ownership, serialized owner reservation, rollback, calm failure wording,
reveal policy, composer upward growth and single-save binding — are correct,
well-scoped and well-tested. No P0; no data-loss or durability defect found.

## Findings

### P1 — Every task surface refuses attachment-card drags, including onto other tasks

`Attic/Views/Panel/TaskAttachmentDrop.swift:26-30` (`classify` →
`.attachmentCard`), refused at `TaskFileDropDelegate.validateDrop` (:245) and
`TaskRowDropDelegate.validateDrop`/`performDrop` (:290, :333). The marker is
`.ownProcess`, so external drag-out still works — but a card dragged from
family A's gallery onto family B's row or panel gets `.forbidden`. That
overreaches the self-duplication guard: R3/R4 say images/files are draggable
wherever they appear and droppable onto any task, and the user confirmed that
intent. Repro: open A's gallery, drag a card onto B's row → nothing.

The marker already carries the identity needed for precise routing:
`TaskDragPayload.swift` registers `item.reference.id.uuidString` under
`com.taha.attic.task-attachment`. Narrow fix: in the `.attachmentCard` arm,
`loadDataRepresentation` → reference UUID → find the owning task
(`store.tasks.first { $0.attachments.contains(id) }`) → refuse only when
`attachmentOwnerID(source) == attachmentOwnerID(target)`; otherwise copy via
`taskImageFiles.verifiedURL(for:)` → `attachStagedFiles` (a real second
private copy is required — per-owner `remove` deletes the file, so sharing
would corrupt the source on removal). Composer drops can reuse the same
decode → `addComposerAttachments`. Copy-vs-move is a product decision; copy
matches the non-destructive "attach" wording. Keep the blanket refusal as the
fallback when the UUID resolves to no task.

### P2 — Promised non-listed types are refused silently (`.forbidden`, no message)

`fileTypes` (`TaskAttachmentDrop.swift:24`) is a fixed list. Verified via
UTType conformance on this machine: `.docx`, `.doc`, `.pages`, `.epub`, `.eml`,
`.7z`, `.dmg`, fonts, `.txt`, `.md`, `.rtf`, `.csv` etc. do not conform to any
listed type, so promised/in-memory drags of them (Mail attachments, browser
files) get `.forbidden` with no explanation. Finder files are unaffected —
they arrive as `public.file-url` and take the in-place path. The ledger lists
this as an open risk, but contract R3/R4 promises "files" generally.

Narrow fix, verified conformances: treat a provider as `.files` when it has a
registered type conforming to `.data` **and not** `.text` **and not**
`.url` — docx/doc/pages/eml/7z/dmg all pass; text selections, `.rtf`/`.html`,
`.csv` and links stay refused; folders/packages don't conform to `.data`;
task/card markers are classified first so unaffected. This must be applied
consistently in three places — `TaskDropContent.classify`, the
`itemProviders(for:)` fetch (append the fallback type or fetch differently),
and `fileContentType(of:)` (pick the most faithful registered type matching
the same predicate so the staged file gets the right extension). Note `.ics`,
`.vcf`, `.gpx` conform to `.text` and stay refused under this rule — decide
explicitly whether contacts/events should attach.

### P2 — Pending-composer private copies orphan if the app quits mid-draft

`TaskComposerAttachments` imports pending items into `Attic/TaskImages`
immediately (correct — enables thumbnails/Quick Look before submit). All
in-session paths clean up (`remove`, `cancelImport`, post-cancel generation
check, `didBind`), but a quit/kill with pending items leaves unreferenced
private copies nothing reclaims. Bounded: ≤ 20 items × ≤ 15 MiB per abandoned
draft; originals are never touched.

Narrow fix: fold into the already-backlogged `Attic/TaskImages` orphan
reconciliation — at launch (before any import can be in flight), union
`attachments` across all tasks *including every duplicate-UUID replica* and
remove unreferenced files. It must be launch-time only: mid-session, a copy
sitting between `importAttachments` and `save()` in `attachStagedFiles` is
unreferenced-but-live, and pending composer items are live by definition.

### Verification risk (not a defect without live evidence) — drop-target source staleness

`TaskFileDropTarget.sources` (`TaskAttachmentDrop.swift:206-223`) relies on the
framework delivering `dropExited` to non-innermost destinations when a drag
enters a child row or ends there. If the surface's `"surface"` source is never
exited, the panel overlay stays lit after the drop. Correctness holds under
the usual nested-destination event model; harden cheaply by calling
`panelTarget.end()` (not just `setTargeted(false, source:)`) in the row's
`performDrop`, and/or `fileDrop.end()` at the top of the configured `perform`
closure in `SubtaskPanelContent.swift:281-289`. On the already-listed live
crossing test.

## Per-area verification

- **Classification/reorder parity:** task drags classify first, before the
  folder export and title (verified: a row's provider registers
  `internalTaskType` + `.folder` + `.utf8PlainText`; `TaskDragPayload.swift:74-84`).
  `acceptTaskDrop` (`TaskRowView.swift:426-440`) reproduces the old
  reorder/status/unfinished-confirmation rules verbatim. `beginTaskDrop`
  (`uiState.endDragging()`) runs synchronously inside `performDrop` before
  `loadTransferable` — earlier than the old post-decode call, matching the
  150 ms-watcher rationale. Section-level `dropDestination`
  (`TaskSectionView.swift:29`) is untouched; row `.onDrop` nests inside it
  without conflict.
- **Panel coverage:** one `TaskFileDropTarget` per `SubtaskPanelContent`,
  environment-injected to child rows which forward via `sources` — the whole
  surface reads as one target; child drops resolve to the parent through
  `attachmentOwnerID` (`TaskStore.swift:458-462`). Overlay is hit-test/AX
  inert and layout-neutral (`.overlay` after the ideal-height frame).
- **Serialization:** the owner is reserved before `stage()` runs
  (`TaskStore.swift:418-423`); a second same-owner import is refused before
  loading with a calm message. Verified against `importingAttachmentTaskIDs`
  being `@Published` — the footer's `Attaching…` state and row gating update.
- **Reveal:** `revealImportedAttachments` (`SubtaskPanelController.swift:576-596`)
  matches the contract — in-place switch when presented, open-on-Attachments
  only when the transient is unchanged since drop, never steals or reopens a
  replaced/closed panel; fresh marks are cleared on failed presentation and
  expire via a bounded one-shot `asyncAfter` (1.2 s). `retain` prunes the
  marks with views.
- **Composer:** pending strip sits above the text row inside the same shell;
  `taskEntryHeight` feeds hit height (:362), scroll padding (:428), mask
  (:449) and error-banner offset (:687) — growth is upward and complete.
  `canSubmit` gates both the button and `.onSubmit` (`saveQuickTask` guard),
  so Return can't outrun an import. `create(…, attachments:)` encodes before
  insert → one save; `save()`'s rollback + `reloadTasks` leaves no ghost
  task on failure, and `didBind` only runs after success.
- **Picker parity:** `isPresenting` unions task and composer pickers;
  `isComposerAttachmentPickerPresented` joins the `.taskConfirmation` lock
  (`PanelUIState.swift:74`). Both `choose` call sites updated to the
  `([UUID], UUID)` completion.
- **Resource use:** staging discards only its owned directory — originals are
  read in place; per-provider subdirs prevent same-name collisions; oversized
  content is refused before copying into the owned dir; `importingCount`/
  limits enforced before loads. Thumbnail cache bounded (64); no new timers
  or pollers.
- **Failure surfaces:** store keeps the task-worded message; nothing reveals
  or announces on failure — `AccessibilityNotification.Announcement` fires
  only on `ids != nil`.

## Observations (non-blocking)

- `performDrop` now returns `true` before the async `perform(taskID)` runs,
  so a `store.drop` that returns false no longer produces the system reject
  animation — rare path, cosmetic.
- A main-row drop while that family's hover-transient is up latches the panel
  on reveal (via `openFamilyPanel`) — plausibly desired; consistent with the
  reveal contract but worth a live look.
- `escape` on the composer collapses options only (`endAdding`); the draft
  and pending items persist — consistent with draft semantics, and it's also
  why the P2 orphan path exists.
- Composer chips handle Space but not Return (`TaskAttachmentCard` handles
  both) — minor inconsistency.
- `TaskFileDrop.attach` doesn't check `familyEditBusy` — but the reveal's
  `openFamilyPanel` guard returns early and clears fresh marks, so a busy
  other-family confirmation just skips the reveal; attachments still bind.
  Calm degradation.
- `Info.plist` new UTI dict uses spaces amid the file's tabs — cosmetic.
- The busy-owner refusal now writes `lastErrorMessage` where the old
  `attachFiles` guard returned `false` silently — an improvement, but a
  double-drop during an import can flash the banner; acceptable.

## Evidence

- Full source read of the two new files and every changed file's diff;
  surrounding source read for `TaskStore` (`create`/`save`/`attachStagedFiles`/
  `attachmentOwnerID`), `SubtaskPanelController` (`openFamilyPanel`,
  `showPanelView`, `revealImportedAttachments`, `FamilyPanelViewState`),
  `AtticPanelView` (composer layout, locks, banner), `TaskRowView`,
  `SubtaskPanelContent`, `TaskImageAttachments`, `TaskDragPayload`,
  `TaskImageReference`/`TaskImageFiles`, `PanelUIState`, `TaskSectionView`.
- UTType conformance verified by direct query (not assumed): the P1 marker
  carries a usable reference UUID; the P2 type matrix above is measured.
- Logs verified, not re-run: `build-local-2.log` ends `** BUILD SUCCEEDED **`
  on final source; `unit-focused-1.log` reports 24 tests / 0 failures /
  `** TEST SUCCEEDED **`; `build-for-testing-1.log` `** TEST BUILD SUCCEEDED **`
  on final source — every `AtticTests` file including the unchanged callers
  of the new `SubtaskPanelContent` init and picker API compiles.
- `unit-adjacent-1..5.log` + `unit-envcheck-1.log` confirm the claim the
  adjacent suites never ran: zero `Test Suite` lines; the host stalls after
  `linkd.autoShortcut` 4097 connection failures and ends `** BUILD
  INTERRUPTED **` — consistent with the reported testmanagerd/IDE-session
  handshake hang before any test code. No blind retry attempted.
- `generate-project`/`verify-project` logs confirm `Attic.xcodeproj` current.
- No production source, test, or other report modified; no UI driven; no
  user data touched.

## Unmet gates / unverified (honest list)

- Adjacent suites (`SubtaskPanelControllerTests`, `SubtaskPanelTests`,
  `SubtaskTests`, `TaskStoreTests`, `CornerHoverStateMachineTests`) never
  executed — environment hang, not a product failure. They cover paths this
  batch touches (`familyEditBusy`/picker availability, `retain`, hosted
  panel content, `create`). Compile-only coverage via the successful test
  build; they must run once the runner recovers.
- The 24 focused tests ran before the final `.onChange(of: mode)` line; that
  line is build- and test-build-verified only.
- All live items stand: real Finder/promise drags, folder refusal, sandboxed
  file-URL access from other apps' drags, nested drop hit-routing and
  crossing highlights (incl. the source-staleness risk above), overlay in
  every theme/Reduce-Motion, switch→entrance timing, drop-latch of a
  hover-opened transient, composer strip hit-testing/keyboard/VoiceOver,
  NSOpenPanel from the non-activating panel, error-banner position.
- Batch-2 carry-over: keyboard full-title focus overlay still unverified.
