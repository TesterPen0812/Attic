# Batch 3 (R4 + R5) — SWE-A review

Scope: `.build/batch3.diff` (sha256 `dfc2d67…51a`, matches `.build/batch3/diffs.txt`)
against pre-batch tree `98cb0b6e…`. Source review of the 16 changed files plus their
actual callers; no builds, tests, UI, or commits run by this reviewer.

## Verdict

Implementable and largely correct; **not clean for acceptance as-is**. Three
contract/durability gaps need a fix round or an explicit deferral decision: the
blanket refusal of in-app gallery-card drops (R3/R4 "draggable everywhere they
appear" / "onto any task"), orphaned pending-composer private copies on quit,
and silently excluded general promised types (e.g. `.docx` from Mail). Everything
else — atomic create+attachments, reservation-before-staging, reveal policy,
composer races, cleanup on failure — is solid and well-tested.

## Evidence checked

- `build-local-2.log`: `** BUILD SUCCEEDED **` on final source (Local config).
- `build-for-testing-1.log`: `** TEST BUILD SUCCEEDED **` — all `AtticTests`
  files compile, including the `SubtaskPanelContent` explicit-init callers in
  `SubtaskPanelControllerTests` (lines 1264, 1318).
- `unit-focused-1.log` + `Batch3Focused-1.xcresult`: 24 tests, 0 failures,
  `** TEST SUCCEEDED **` (11 `TaskAttachmentDropTests` + 13 `TaskImageTests`).
- `verify-project-2.log`: "Project generation is repeatable and
  Attic.xcodeproj is current"; both new sources are in the app and
  `AtticUnitTestHost` phases (not AtticMobile — consistent with existing
  shared-source layout).
- Adjacent suites genuinely never ran: `unit-adjacent-1..5.log` show
  `AtticUnitTestHost` launching then stalling before any test (linkd/testmanagerd
  handshake), ending `** BUILD INTERRUPTED **`. Claimed environmental stall is
  corroborated, not self-reported.
- Diff excludes orchestrator/reviewer/live docs as declared; no entitlements,
  signing, store, schema, or `ATTIC_LOCAL_ONLY` changes in batch3.diff.

## What is correct

- `TaskStore.create(…, attachments:)` encodes refs before `context.insert` so
  task + references share one save; `save()` failure rolls back the context and
  reloads, composer keeps pending for retry (`TaskStore.swift:262-271, 774-793`).
- `attachStagedFiles` reserves the owner before `stage()` runs, updates every
  replica via `storedTasks(matching:)` (duplicate-safe per contract), and on any
  failure removes only the new private copies and owned staging
  (`TaskStore.swift:409-449`). Originals are read-only throughout.
- Task-drop reorder rules moved verbatim into `acceptTaskDrop`;
  `beginTaskDrop` → `endDragging()` now runs before async payload load, which
  correctly fixes the race against the 150 ms release watcher in
  `CornerHoverMonitor.swift:200-214`.
- Reveal policy (`SubtaskPanelController.swift:570-596`) never reopens a closed
  panel or steals a different family opened since the drop; `familyEditBusy`
  still guards; fresh-card marks are pruned in `retain` and expire after the
  entrance.
- Composer: generation counter + `didBind`-only-after-save + per-copy `remove`
  give correct cancel/retry semantics; limits count pending items; one batch at
  a time; `.taskComposer`/`.taskConfirmation` locks cover pending items and the
  picker. Strip growth feeds hit height, scroll padding, mask, and error-banner
  offset consistently (`AtticPanelView.swift:67-72, 360-363, 428, 449, 684-688`).
- Drop overlay is hit-test and accessibility inert, layout-neutral; card
  provider ordering (file first, own-process marker second) preserves
  drag-out-to-Finder behavior.

## Findings

### F1 — Medium: blanket refusal of gallery-card drops violates R3/R4
`TaskAttachmentDrop.swift:27-28` classifies any provider carrying
`com.taha.attic.task-attachment` as `.attachmentCard`, refused by every task
drop target (rows, panel surface, composer). This prevents self-duplication but
also bans dropping a card onto a *different* task — a gesture the contract
implies ("draggable everywhere they appear", "drop images/files onto any task
row"). The marker already carries `reference.id` (`TaskDragPayload.swift:52`),
so identity is recoverable.
Repro: drag a gallery card onto another task's row → `.forbidden`, nothing
attaches.
Narrow fix: keep the marker; add self-vs-other routing instead of the ban.
Record the dragged card's `(referenceID, resolvedOwnerID)` in a process-local
drag-session value set in `.onDrag` (`TaskImageAttachments.swift:277`) — resolve
the owner through `attachmentOwnerID` so legacy child-owned cards compare
against their parent. A stale record is harmless: it is only consulted while a
marker is present in a live drag, and every card drag overwrites it. In
`validateDrop`, `.attachmentCard` returns `.forbidden` when the target owner
equals the session's source owner and `.copy` otherwise; `performDrop` then
loads the file representation and funnels it through `TaskDroppedFiles`/
`attachStagedFiles` (copy semantics, matching the `.copy` proposal and
non-destructive). Safety net: at perform time, decode the marker's
`reference.id` and no-op if the resolved owner matches the target, so a stale
session can never self-duplicate.

### F2 — Medium-low: pending composer copies orphan on quit
`TaskComposerAttachments` imports straight into `Attic/TaskImages/<id>/<digest>/`
(`TaskImageReference.swift:31-34`), indistinguishable from bound attachments.
`remove`/`didBind` cover in-session cleanup, but nothing runs at quit or next
launch for the task path: `NoteStore.reconcileFileStorage` (`NoteStore.swift:938`)
only covers the notes `Attic/Attachments` store, and `AttachmentFileStore.reconcileMetadata`/`cleanOrphans` is never invoked for
`taskImageFiles`. Each abandoned draft leaves permanent orphans; unbounded over
repeated use.
Narrow fix (bounded, never touches originals or live refs): reconcile
`taskImageFiles` once per launch after tasks load — expected set = union of all
task attachment `id/digest` keys — and skip entries modified within a grace
window (e.g. 1 h) so a just-bound or in-flight import cannot be swept. If any
mid-session reconcile is added later, the composer's pending refs must join the
expected set.

### F3 — Medium-low: general promised types (Mail `.docx`, etc.) silently excluded
`TaskDropContent.fileTypes` (`TaskAttachmentDrop.swift:24`) lists fileURL, image,
pdf, movie, audio, archive, spreadsheet, presentation. A promised `.docx` from
Mail that offers no `public.file-url` doesn't conform to any entry, so the
destination never becomes a candidate — refused without even `.forbidden`
feedback. The ledger documents this as an open risk, but R3/R4 say "files"
generically; this is a real gap, not just checklist noise.
Narrow fix: classify `.files` when `hasItemsConforming(fileTypes)` OR
(`hasItemsConforming([.data])` AND NOT `hasItemsConforming([.text, .url])`) —
keeps text selections and links unsupported (they carry text/url), keeps folders
refused (`public.directory` does not conform to `public.data`), and admits
promise-only documents. Mirror the same rule in `fileContentType` (prefer the
most faithful registered non-text type) so staged copies keep a real extension
for `importOne`'s pathExtension-based type derivation.

### F4 — Low: possible stuck panel highlight from stale drop-target sources
`TaskRowDropDelegate.clearTargets`/`TaskFileDropDelegate.performDrop` clear only
the row's own source (`TaskAttachmentDrop.swift:338-342, 260-261`). If nested
`dropExited` ordering leaves the surface's `"surface"` source registered when a
child row performs the drop, `TaskFileDropTarget.isTargeted` stays true and the
overlay can linger with no drag active.
Narrow fix: on `performDrop` (and as belt-and-suspenders in `perform`), call
`fileDrop.end()` to clear all sources, not just the performing one.

### F5 — Low: reveal treats "opened and closed another family" as unchanged
`revealImportedAttachments` compares only `transientFamilyID == transientAtDrop`
(`SubtaskPanelController.swift:580`). Drop on a main row with no panel up
(`transientAtDrop = nil`), user opens then dismisses another family during the
import → both nil → the target family still pops open on Attachments. Rare and
arguably still desirable drop feedback, but it is a wider window than the
documented "same one that was up at drop time" implies. Acceptable to defer; at
minimum keep it on the UAT list.

### F6 — Low: `attachStagedFiles` discard contract is asymmetric
`TaskStore.swift:424-448`: the outer `staging` var only discards what `stage()`
*returned*; a custom stage closure that throws after creating an owned directory
leaks it. Both current closures are safe (`TaskDroppedFiles.stage` self-discards;
the picker stage can't throw), so this is latent, not live. Narrow fix: document
"stage must discard its owned directory on throw" on the `stage` parameter, or
return the staging for the store to discard.

## Test adequacy

`TaskAttachmentDropTests` covers the important seams with real providers and a
real store (routing incl. an actual card provider, staging ownership, refused
overlap inside the reservation, reveal matrix, single-save binding, cancel
cleanup, limits). Gaps worth adding in the fix round: delegate-level proposal
routing (`TaskRowDropDelegate`/`TaskFileDropDelegate` are plain structs and
testable without UI), stale-source clearing (F4), and a promised `.docx`-type
provider once F3 lands.

## Unmet gates (honest)

- Adjacent suites never ran (testmanagerd stall, verified in logs):
  `SubtaskPanelControllerTests`, `SubtaskPanelTests`, `SubtaskTests`,
  `TaskStoreTests`, `CornerHoverStateMachineTests`. They cover `familyEditBusy`,
  `FamilyPanelViewState.retain`, hosted `SubtaskPanelContent` callers, and
  `create` — compile-only evidence exists for all of them.
- No UI was driven; every item in the ledger's "Unverified — needs live
  validation" list stands, plus F1's card-drag feedback and F4's overlay state.
- Preview executable untouched (sha matches `diffs.txt`); UAT still owed on a
  uniquely named local-only preview per the development contract.
