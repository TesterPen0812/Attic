# Task panel V2 — batch 2 independent SWE review (SWE-A)

Reviewer scope: storage and backward compatibility, duplicate-safe parent attachment
ownership, save-failure cleanup and rollback, file-access/security scope, preview/export
and drag data paths, test adequacy, plus obvious integration issues elsewhere. Diff
reviewed: `.build/batch2.diff` against pre-tree `11866767fbc5a85c261f3a3ed755855b502ad27c`
(current tree `45f1c04cc74549f2f3dc0c70a9b87361bf5f761c`; file mtimes confirm the working
sources match the diff snapshot). Requirements compared against
`Docs/TaskPanelV2Requirements.md` R2/R3, not only the ledger checklist.

## Verdict

**Approved for merge.** No P0/P1/P2 defect found in the assigned scope. The core
contract — durable private storage, byte-identical backward compatibility, duplicate-safe
all-replica mutation, parent ownership resolution, save-failure rollback, scoped
security access, and verified hand-out of private files — is implemented correctly and
is well tested. Six P3 findings follow; none block the batch. Live UI behavior remains
unverified and is listed separately at the end.

## Findings

### P3 — Outgoing view slides against the documented spatial model during view switch

**Location:** `Attic/Views/Panel/SubtaskPanelContent.swift:385-393`
(`viewTransition`), model comment at `SubtaskPanelContent.swift:371-372`, constants at
`Attic/Services/SubtaskPanelLayout.swift:181-182`.

The comment states "Attachments sit to the right of Subtasks." For `.attachments`,
`slide = +18`, insertion `+18`, removal `-18`; for `.subtasks`, `slide = -18`,
insertion `-18`, removal `+18`. On subtasks → attachments, the outgoing list exits
**right** (`+18`) while the gallery enters from the right moving left — the two layers
slide toward each other and cross rather than paging left in one direction. The
incoming direction is correct in both cases; only the outgoing view's removal direction
is inverted relative to the stated spatial model (carousel semantics would have the
outgoing view exit toward its own side). Each view instead exits toward the *other*
view's side — a positional swap, which is the opposite of the documented paging.

**Causal path:** user clicks the view switch → `showPanelView` → `withAnimation` →
the ZStack swaps `childList` for `gallery` → the removed view animates to `+18`
(into the incoming view's origin side) instead of `-18`.

**Narrow fix:** `removal: .offset(x: slide)` — same sign as insertion, so each view
exits toward its own resting side.

**Evidence:** source reading only; the effect is 18pt with a crossfade and may read as
a deliberate swap in live use. Needs a live look to confirm visual quality either way.

### P3 — Attachment drag-out declares `public.data` for every file, including images

**Location:** `Attic/Models/TaskDragPayload.swift:15`.

`FileRepresentation(exportedContentType: .data)` promises `public.data` for every
attachment card. A drop target that accepts only `public.image` can refuse a dragged
image card where a correctly typed promise would succeed; `public.data` does not
conform to `public.image`. Finder and generic file/URL targets accept `.data`, so the
feature works for the common case; the gap is type-filtered receivers. This partially
under-delivers "Images/files draggable everywhere they appear" for images.

**Narrow fix:** split the drag item by `reference.isImage` — a second `Transferable`
type (e.g. `TaskImageDragItem` with `exportedContentType: .image`) chosen per card —
since `exportedContentType` is static per type.

**Evidence:** source reading; which real receivers refuse `.data` needs a live drag.
No regression versus pre-batch (attachment drag-out is new in this batch).

### P3 — `presentedTaskAttachmentsID` is a single shared mark: a child popover can steal it from a live picker, and the picker silently no-ops while it is set

**Location:** `Attic/Views/Panel/TaskImageAttachments.swift:58-60` (guard),
`Attic/Views/Panel/TaskRowView.swift:425-428` (`syncAttachmentInteraction` sets
unconditionally), `TaskRowView.swift:382-387` (menu item not disabled for this case),
protection read at `Attic/Window/SubtaskPanelController.swift:379-389`.

Two reachable edges:

- **Dead click:** a child's legacy attachments popover sets the mark
  (`presentedTaskAttachmentsID = child.id`). While set, "Add attachment…" — on the
  parent row menu or the panel composer — calls `TaskAttachmentPicker.choose`, whose
  `presentedTaskAttachmentsID == nil` guard returns silently. The menu item and button
  are only disabled for an in-flight import or missing owner, so the user gets a click
  with no effect and no message.
- **Protection theft:** with a picker open for family B (mark = B's owner), opening a
  child popover in a different open family (e.g. a pinned window's child) overwrites
  the mark. Family B loses `familyEditBusy` coverage, so an outside click dismisses
  its transient panel mid-import; the completion callback then re-opens it via
  `attached` → `openFamilyPanel`. Self-healing flicker, no data risk.

**Narrow fix:** disable "Add attachment…" affordances while
`presentedTaskAttachmentsID != nil`, and have `syncAttachmentInteraction` refuse or
defer while the mark belongs to another interaction (or make the mark a small
stack/token).

**Evidence:** source trace. Both paths require a second simultaneous attachment UI;
low frequency, no data loss.

### P3 — Attachment card exposes a dead "Open" accessibility action for unopenable types

**Location:** `Attic/Views/Panel/TaskImageAttachments.swift:175` vs the same file's
`:94-104` (`canOpen`/`open`) and `:283` (context menu correctly disables).

`.accessibilityAction(named: "Open", open)` is unconditional. For executables,
scripts, packages and untyped data, `TaskAttachmentActions.open` guards `canOpen` and
returns silently — VoiceOver users get an action that does nothing with no feedback,
while the pointer context menu disables the same command.

**Narrow fix:** emit the action only when `TaskAttachmentActions.canOpen(reference)`,
or surface the refusal through `store.reportUnavailableAttachment`-style feedback.

### P3 — `importOne` re-reads every imported file fully into memory; the whole batch's payloads are held at once

**Location:** `Attic/Services/AttachmentFileStore.swift:415`
(`let payload = try Data(contentsOf: finalURL, ...)`), consumed at
`Attic/Models/TaskImageReference.swift:46-53`, discarded at `TaskImageReference.swift:19`.

After the chunked copy (which already hashed the bytes), `importOne` reads the whole
file a second time into `payload`, and `importFiles` accumulates every
`ImportedAttachment` — payload included — until the batch returns. For the task path
the payload is used only to validate `isImage` references via
`CGImageSourceCreateWithData`, then dropped (`fileReference.payload = nil`). Non-image
files therefore pay a second full read and all payloads sit in memory simultaneously —
up to ~300 MiB transient for a maximum batch (20 × 15 MiB). The pattern predates this
batch, but image-only imports made large payloads rare; general files (PDFs, zips)
make them routine.

**Narrow fix:** load the payload only when the caller needs it — an
`includePayload`-style flag on `importFiles`, or validate image references against the
already-materialized URL with `CGImageSourceCreateWithURL` instead of `CreateWithData`.

**Evidence:** source reading; bounded by per-task limits, so performance-only, P3.
Related note: `verifiedMaterializedURL` (`AttachmentFileStore.swift:260-271`) rehashes
the full file on every preview/open/drag/thumbnail-miss — acceptable, but it means a
15 MiB file is hashed per preview.

### P3 — An explicit view request on an already-visible hover-open family swaps content without the designed transition

**Location:** `Attic/Window/SubtaskPanelController.swift:514-531`
(`openFamilyPanel`), vs the animated path at `:547-557` (`showPanelView`).

When the transient is already open hover-origin for the same family,
`openTransient(familyID, latched: true)` returns true (origin `.hover` ≠ `.explicit`),
so the call is treated as a fresh open: `panelViews.set(requestedView, …)` at line 529
applies outside `withAnimation` while the surface is already on screen, and
`presentTransient` snap-resizes via `stopFrameAnimation`. "Show attachments" /
"Show subtasks" from the row menu on a hover-open family therefore switches content
instantly instead of with the designed slide/crossfade.

**Narrow fix:** when `lifecycle.transientFamilyID == familyID`, route the view request
through `showPanelView` (animated + refit) regardless of the origin change.

**Evidence:** source trace; cosmetic, only reachable via menu commands on a
hover-open family.

## Verified clean in the assigned scope

- **Storage / backward compatibility.** `TaskItem.imageReferencesData` is unchanged
  (`TaskItem.swift:22`); `TaskImageReference`'s Codable keys are byte-identical to the
  pre-tree version (verified via `git cat-file` on the pre-tree): `id`, `filename`,
  `digest`, `contentTypeIdentifier`, `byteCount`. The `images` → `attachments` rename
  is source-only; the decode path is identical. `TaskDragPayload.imageReferences` is
  retained for legacy payload decode (`TaskDragPayload.swift:31`), covered by
  `testLegacyImageReferencesDecodeAsImageAttachments` and the corrupt-image/legacy-
  payload test.
- **Duplicate-safe parent ownership.** `attachFiles` resolves the owner via
  `attachmentOwnerID` (child → parent, refusing ambiguous or orphaned parent links),
  encodes `current.attachments + imported`, and writes the same data to every physical
  replica via `storedTasks(matching:)` before one `save()` (`TaskStore.swift:383-409`).
  `removeAttachment` does the same for removals (`:430-445`). Covered by
  `testSubtaskAttachmentsResolveToTheParent` and
  `testAttachAndRemoveApplyToEveryPhysicalDuplicate` (two physical replicas, attach
  and remove propagate to both).
- **Save-failure cleanup / rollback.** `save()` rolls back the context and reloads.
  `attachFiles` removes the new private copies when the save fails or the task
  disappears mid-import (`:392-402`, catch at `:404-408`). Inside the actor,
  `importFiles` stages each file under `.staging/<batch>` and registers every final
  directory before creating it, so a partial multi-file failure removes exactly what
  it produced (`AttachmentFileStore.swift:82-117`). `removeAttachment` keeps both the
  reference and the private copy on save failure — verified by
  `testFailedFileSaveRollsBackAndRemovesOnlyTheNewPrivateCopies`, which counts
  on-disk UUID directories before and after.
- **File access / security scope.** `importOne` starts the security-scoped resource
  before reading attributes and balances it (`AttachmentFileStore.swift:330-335`),
  coordinates a chunked copy that rejects non-regular files, over-limit files, and
  mid-read changes (`:337-394`), and never moves or deletes the original. Private
  paths are confined to the app-owned root: digest validated as 64 hex, UUID dirs,
  `path.hasPrefix(rootURL)` checks (`:428-442`), filename sanitization blocks
  traversal (`:457+`). Every hand-out goes through `verifiedMaterializedURL`, which
  rehashes before returning a URL (`:260-271`); tampered private copies are refused
  (test at `TaskImageTests.swift:129-132`). `isSafeToOpen` blocks executables,
  scripts, packages, installer packages, and untyped data for Open while leaving
  preview available (`NoteAttachmentPlatformSupport.swift:71-86`).
- **Preview / export / drag paths.** Quick Look and Open read the verified private
  URL only (`TaskImageAttachments.swift:87-110`); failures report through
  `reportUnavailableAttachment` (`TaskStore.swift:177-179`). `TaskAttachmentDragItem`
  resolves the verified URL lazily inside the file promise — nothing is copied during
  layout or resize, and `SentTransferredFile(allowAccessingOriginalFile: false)` hands
  the receiver a copy, never write access to the private file (`TaskDragPayload.swift:
  14-21`). Task-row export builds a disposable folder of verified copies and prunes
  only its own export root (`TaskImageReference.swift:88-107`). A mid-drag task
  deletion degrades to `fileNoSuchFile`, not a crash.
- **No image data duplication on drag/resize.** Row glyphs and cards use
  `NSWorkspace` icons or cached thumbnails (`digest-pixels` key, 64-entry bound,
  `TaskImageReference.swift:67-86`); general files never enter image decoding
  (`isImage` gate at `:46-49`, asserted by test `TaskImageTests.swift:116-119`).
  Layout height is pure arithmetic (`SubtaskPanelLayout.galleryContentHeight`,
  `contentHeight`).
- **Panel contract (R2).** One surface per family (`mayOpenTransient` excludes
  pinned; `openTransient` idempotent); fresh opens default to Subtasks via
  `FamilyPanelViewState` normalization + `retain` pruning
  (`SubtaskPanelController.swift:1132-1152`); deliberate switch beside the composer
  with destination icon/label (`FamilyPanelView.switchSymbol/switchLabel`,
  `SubtaskPanelContent.swift:478-496`); both views share the 240pt maximum and
  natural-height sizing (`SubtaskPanelLayout.swift:166-177`); a single image is a
  half-width 100pt card (test asserts `< maximumListHeight / 2`); top-edge-holding
  height animation only for height-only visible changes
  (`SubtaskPanelController.swift:971-999`); movement/hover never resets the view
  (test `testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView`); latched and
  detached panels survive until outside click.
- **Integration.** No stale callers of the renamed APIs (`attachImages`,
  `removeImage`, `importingImageTaskIDs`, `TaskItem.images`) — remaining `images`
  hits are the unrelated Canvas subsystem. `TaskActionsMenu`, `AgentTaskTools`, and
  `AtticPanelView` are untouched. The old per-row `fileImporter` was fully replaced
  by `TaskAttachmentPicker`. R4/R5 drop-to-attach is untouched as intended.

## Interpretations the orchestrator should confirm

- **Row click on an already-open panel keeps the current view** rather than
  resetting to Subtasks (`openFamilyPanel` `view: nil` path,
  `SubtaskPanelController.swift:514-527`). "Explicit re-opening starts on Subtasks"
  is applied to fresh opens after close — consistent with "movement/hover of an
  already-open panel must not reset its view" — and the updated UI test asserts
  keep-view (`AtticUITests.swift:496`). If the product intent is that any deliberate
  row click resets to Subtasks, this is a spec deviation; I read the keep-view
  behavior as correct.
- **Attachment-only families never hover-open** — `hoverWorthy`/`canPresentPanel`
  count children, drafts, and active entry only (`SubtaskPanelController.swift:365-
  369`, `TaskFamilyView.swift:26-30`). A task with attachments but no subtasks opens
  by row click or menu. Consistent with the existing "no empty panels on hover" rule.
- **Attachment mutations converge replicas to the presentation replica's list** —
  `attachFiles`/`removeAttachment` encode the visible task's list and write it to all
  replicas, matching `update()`'s repair semantics (`TaskStore.swift:363`).
  Divergent attachment lists across replicas are only reachable via CloudKit import
  (deferred); note for the sync re-enablement checklist: replica-specific references
  dropped this way leave private files orphaned on disk.
- **Legacy child-owned attachments remain on the child** — viewable, draggable, and
  removable via the row popover (`TaskAttachmentsPopover`,
  `TaskImageAttachments.swift:294-311`), while new attachments always resolve to the
  parent. Deliberate dual ownership per the migration contract.

## Minor notes (not findings)

- `TaskStore.swift:423` hardcodes "100 MiB" in the `.noteTooLarge` message while the
  sibling `.tooManyAttachments` case formats `AttachmentLimits.maxAttachmentsPerNote`
  dynamically — a future limit change drifts the copy.
- `frameAnimationTargets` (`SubtaskPanelController.swift:966`) can retain a dead
  entry for a window closed mid-animation; it self-clears on the next
  `presentTransient`/`configureSurface` for the reused transient window, and
  pinned-window entries die with the window object. Bounded.
- iOS shared compile surface: `shared_mobile_sources` includes `TaskStore.swift` but
  not `TaskImageReference.swift`, `AttachmentFileStore.swift`, or
  `NoteAttachment.swift` (`Scripts/generate_project.rb:78-111`). The mobile target
  already could not compile `TaskStore` (pre-existing `TaskImageFiles` reference);
  batch 2 adds `AttachmentFileStoreError`/`AttachmentLimits` references
  (`TaskStore.swift:418-427`) to the same already-broken surface. Deferred iPhone
  work item, not a regression — add file sharing or `#if` gates to the
  re-enablement checklist.
- `attachFiles` returns `false` silently on the busy/missing-owner guards
  (`TaskStore.swift:384-386`) — consistent with store API style; every UI path
  disables the control first.
- `TaskAttachmentPicker` is a plain `NSOpenPanel` with `allowedContentTypes =
  [.data]` (`TaskImageAttachments.swift:67`) — this excludes directories and
  bundles, matching `importOne`'s regular-file requirement. `NSApp.activate()` at
  `:68` is needed for the nonactivating-panel app but its effect on main-panel
  auto-hide is a live-verification item.
- View switch drops keyboard focus from a mounted entry field and does not restore
  it on return (`SubtaskPanelContent.swift:201-219`); the entry's active flag and
  draft are preserved, matching "focus loss preserves state" semantics.

## Test adequacy

Coverage is strong for the assigned scope: persistence across contexts, parent
ownership resolution, all-replica attach/remove, save-failure model + file cleanup
(with on-disk directory counts), corrupt-image rejection, tamper refusal, non-image
no-thumbnail, task-specific limit wording, legacy reference and drag-payload decode,
openable-type matrix, view-state default/retention/fresh-open/pin/unpin/browse-away,
shared sizing bounds, destination icon labels, and a real hosted-view ideal-height
test that pins the mid-animation fitting behavior.

Minor gaps: no test exercises the `importingAttachmentTaskIDs` busy-guard silent-false
path or `attachmentOwnerID`'s ambiguous-parent refusal; the picker → import →
gallery-switch end-to-end path is covered only by compile-level UI tests.

## Evidence

- Diff provenance verified: pre-tree `11866767`, snapshot `45f1c04`, 15 changed files;
  mtimes predate the diff capture, so current sources are the reviewed ones. The
  pre-batch dirty/untracked baseline is intentional and was not mistaken for
  deletions.
- Independent compatibility check via `git cat-file` on the pre-tree
  `TaskItem.swift`, `TaskImageReference.swift`, `TaskStore.swift` — storage field,
  Codable keys, and mutation semantics confirmed identical/compatible.
- Build/test logs (`.build/batch2/`): `build-local-3.log` ends `BUILD SUCCEEDED`;
  `unit-tests-1.log` reports 711 executed, 3 skipped, 0 failed on final sources;
  `unit-focused-2.log` reports 108 focused tests, 0 failures; `uitest-compile-1.log`
  ends `TEST BUILD SUCCEEDED`. No suite was re-run.
- Project inputs unchanged; no regeneration needed. No source, test, or other report
  was modified; no UI was driven; no user data touched.

## Unverified live behavior (compile/test evidence only)

- View-switch slide/crossfade vs the animated window resize (incl. finding P3-1's
  direction and P3-6's unanimated path).
- `NSOpenPanel` over the nonactivating auxiliary panels; `NSApp.activate` interaction
  with main-panel auto-hide.
- Drag-out to real receivers, especially image-typed targets (P3-2) and Finder.
- Card click-vs-drag gesture disambiguation and Full Keyboard Access traversal inside
  the gallery; the 18×18 hover remove × hit target.
- Quick Look presentation and dismissal from the borderless panel.
- Reduce Motion behavior of `.contentTransition(.symbolEffect)` on the switch icon.
