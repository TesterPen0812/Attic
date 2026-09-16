# Rolling Reliability Audit — Notes Autosave, Attachments, Task Integrity

**Date:** 2026-09-14 · **Auditor:** SWE-2 Max (read-only reliability worker)
**Branch/HEAD:** `codex/attic-task-panels-v2` @ `ae6418c` (no new commits during audit)

## Scope and validation limits

Source-review-only audit of the current dirty worktree (124 modified/untracked
entries at write time). Areas covered:

- Notes draft/autosave/deletion lifecycle (`NoteDraftController`, `NoteStore`,
  `NotesPanelContent`, `AtticPanelView`, `AtticPanelController`,
  `AppCoordinator`, `AppDelegate`).
- Note attachment persistence, import, export, open/reveal/preview, cleanup,
  and inline-card anchoring (`AttachmentFileStore`,
  `NoteAttachmentPlatformSupport`, `NoteAttachmentTray`, `NoteInlineCards`,
  `NoteInlineAnchor`, `NoteAttachment`).
- Task data integrity, duplicate-replica handling, attachment
  import/copy/remove/export, composer pending files, and done-task cleanup
  (`TaskStore`, `TaskItem`, `TaskImageReference`/`TaskImageFiles`,
  `TaskAttachmentDrop`, `TaskComposerAttachments`, `TaskImageAttachments`,
  `DailyCleanupService`, `PanelUIState`).

**Not performed (explicitly out of scope):** no build, no tests, no app
launch/relaunch, no pointer operation, no mutation of user data or stores, no
staging/commit/push, no edits to source or tests. All findings below are
established by code inspection with caller and persistence-lifecycle tracing;
none were executed. Line numbers reflect the dirty worktree at write time and
may shift under concurrent edits. CloudKit/iPhone behavior is deferred scope —
reviewed statically only; `ATTIC_LOCAL_ONLY` keeps those paths dormant.

## Workspace reconciliation

An implementation worker edited this checkout while the audit was paused.
Reconciled changes that intersect this audit's scope:

- `TaskStore.swift` grew substantially (now ~1415 lines): new
  `attachImported` owner-reservation path, `sweepUnreferencedAttachmentStorage`,
  `removeAttachmentFiles` surviving-replica check, stricter `delete` family
  checks, and `purgeCompleted` replica-agreement gating — all re-reviewed in
  current form.
- `NoteStore.swift` gained `makeFreshContext`/`persistImport` transaction
  machinery and the two-phase metadata/repair attachment reconciler — re-read
  fully.
- `AttachmentFileStore.swift` gained `reconcileMetadata` /
  `repairMaterializations` / `removeUnreferencedMaterializations` — re-read.
- New in-scope files reviewed in full: `NoteInlineAnchor.swift`,
  `TaskImageReference.swift`, `TaskAttachmentDrop.swift`,
  `TaskComposerAttachments.swift`, `TaskImageAttachments.swift`,
  `NoteInlineCards.swift`.
- `Docs/Rolling-NoSwipe-Implementation.md` (ended `IMPLEMENTATION_READY`),
  `Docs/Rolling-Performance-Audit.md`, and
  `Docs/Rolling-Requirements-Audit.md` now exist; the performance audit's
  PERF-A3 covers the *cost* of `NoteStore.update`'s per-attachment diff and is
  cross-referenced from defect R-01 below, whose finding is the *correctness*
  consequence of the same code.

## Confirmed current defects

### R-01 — A single autosave containing edits on both sides of an inline attachment permanently re-anchors the card to the wrong paragraph

**Where:**

- `Attic/Services/NoteStore.swift:212-224` — when `bodyChanged`, `update`
  rewrites every stored attachment's `inlineOffset` via
  `NoteInlineAnchor.moved(offset, from: note.body, to: destinationBody)`, then
  writes all replicas and saves (`:225-231`).
- `Attic/Models/NoteInlineAnchor.swift:52-64` — `NoteTextReplacement.diffing`
  fabricates **one** replacement spanning the first to the last differing
  UTF-16 unit, swallowing every unchanged paragraph in between.
- `Attic/Models/NoteInlineAnchor.swift:30-34` — `rebasing` collapses any
  offset inside the replaced span to `location`.
- `Attic/Models/NoteInlineAnchor.swift:83-85` — `moved` then snaps the result
  to `paragraphStart`.

**Reproduction (deterministic, source-level):** persisted body
`"one\ntwo\nthree\nfour"` (18 UTF-16 units) with an attachment anchored at
`inlineOffset = 8` (start of "three"). One flush delivers
`"one!\ntwo\nthree\nfour!"` — an insert at offset 3 and an insert at offset 18,
batched into one save. `diffing` yields `(location: 3, oldLength: 15,
newLength: 17)`; `rebasing(8)` sees `8 ∈ [3, 18)` and collapses to `3`;
`paragraphStart(3, in: newBody)` = `0`. The stored anchor becomes `0` on every
replica: the card permanently moves from "three" to the "one!" paragraph. The
correct answer is `9` — paragraph "three" survived both edits unchanged.

**Trigger:** ordinary multi-site editing inside one debounced autosave (500 ms
trailing / 5 s maximum, `NoteDraftController.swift:598-631`) or one `flush()`
(`:388-468`, store call at `:423`). Typing above a card, clicking below it, and
continuing to type before the next save is enough; the same applies to any
other `update`-with-body caller. The anchor paragraph itself does not need to
be edited — it only needs to sit between two edited regions.

**Impact:** silent, permanent misplacement of a user-placed attachment card,
written to every physical replica. No error or conflict is surfaced; the wrong
offset survives relaunch and later saves keep rebasing from it. The attachment
is not lost and can be re-placed manually, but the user's explicit placement is
corrupted without notice.

**Bounded recommended fix:** stop describing multi-edit saves as one
replacement on the persisted path. Either (a) keep the ordered list of real
`NSTextStorage` edits the draft's ledger already records and rebase each
anchor through the list (exact per anchor, O(#edits)); or (b) rebase at
paragraph granularity — when an anchor's own paragraph text survives
unchanged, keep it bound to that paragraph instead of collapsing to the diff
start. Note the sibling performance finding PERF-A3 proposes computing the
diff once per save; that reduces cost but does not repair this defect.

### R-02 — `NoteTextReplacement.composing` over-covers disjoint editor edits, so the presentation anchor can collapse to an earlier paragraph while the draft is dirty

**Where:**

- `Attic/Models/NoteInlineAnchor.swift:39-48` — `composing` merges two
  replacements into the smallest enclosing span; the unchanged gap between
  disjoint edits is folded into the "replaced" range.
- `Attic/Views/Panel/NoteAttachmentTray.swift:1448-1455` —
  `Coordinator.textStorage(didProcessEditing:)` composes every
  `.editedCharacters` edit into `pendingStorageEdit`; `:1457-1467` then records
  the composition into the ledger per `textDidChange`.
- `Attic/Views/Panel/NoteInlineCards.swift:255-271` —
  `NoteBodyEditLedger.record` composes again into `pending` and accepts
  disjoint compositions: its guards check only bounds and total length
  (`:262-264`), never interior preservation.
- `Attic/Views/Panel/NoteInlineCards.swift:350-358` —
  `NoteInlineCardResolver.resolve` rebases each stored `inlineOffset` through
  the composed replacement for display.

**Counterexample (passes every guard):** anchor text `A` of length 30; record
insert `(10, 0, 5)` then insert `(30, 0, 5)` — resulting length 40. Composed:
`(10, 15, 25)`; checks `10+15 ≤ 30`, `10+25 ≤ 40`, `30+10 == 40` all pass, but
the span claims `A[10,25)` was replaced when it actually survives at
`C[15,30)`. An anchor at `A:12` rebases to `10` instead of `17`; if the first
insert ends with a newline, `paragraphStart` lands the card a full paragraph
early.

**Trigger:** two disjoint character edits recorded between ledger reads —
autocorrect/text-replacement or spelling substitution on an earlier word while
typing continues elsewhere, dictation or IME multi-part edits within one
`textDidChange`, or batched undo — with a card anchored between the edits.

**Impact:** transient wrong-paragraph placement while the draft is dirty.
Self-corrects on the next save *unless* R-01 persists a similarly wrong offset
(the save path diffs the same span and collapses to the same start, so the two
defects typically converge on the same wrong paragraph rather than healing).

**Coverage gap that lets it through:**
`testRecordedEditsRebaseAnchorsLikeAWholeBodyDiff`
(`AtticTests/NoteInlineCardsTests.swift:128-168`) asserts only bounds and
paragraph-boundary landing — it never compares the incremental result to the
whole-body diff it is named for;
`testSingleRecordedEditMatchesTheWholeBodyDiffExactly` (`:170-190`) exercises
exactly one edit.

**Bounded recommended fix:** store the ordered `[NoteTextReplacement]` edit
list instead of composing to one span and rebase through each element —
strictly exact for every anchor and still O(#edits) per card. (Falling back to
`diffing` on disjoint edits is *not* sufficient: the diff carries the same
collapse, see R-01.)

### R-03 — `cleanOrphans` deletes freshly imported note-attachment files belonging to an uncommitted in-flight import

**Where:**

- `Attic/Services/AttachmentFileStore.swift:356-380` — `cleanOrphans` removes
  every `<uuid>/<digest>` directory under the note-attachment root whose key is
  absent from `expected`, with **no modification-time guard**. Contrast the
  same function's staging cleanup (`:382-391`, 24-hour age check) and the
  task-side sweep `removeUnreferencedMaterializations` (`:284-339`), which
  requires `created < cutoff && modified < cutoff` precisely because "an
  import that starts while the sweep runs" must be kept
  (`TaskStore.swift:665-666`).
- `expected` is computed from a reference list captured on the main actor when
  `reconcileFileStorage` spawns its task (`NoteStore.swift:1002-1017`); rows
  committed after that snapshot cannot be in it.
- The interleave point is real: `importFiles` awaits the caller's `progress`
  closure between files (`AttachmentFileStore.swift:106-118`), which suspends
  the actor mid-import and lets a queued `reconcileMetadata` (`:194-224`) run
  `cleanOrphans` against the batch's already-placed directories.

**Trigger (local-only reachable):** `installPresentation` →
`reconcileFileStorage` (`NoteStore.swift:786-798`) fires after every
`persistImport` commit and after save-failure recovery (`:745-753`,
`:808-816`) or a `locateAttachment` error (`:634-645`). Concretely: import #1
commits and spawns a reconcile task holding snapshot S; import #2 begins,
copies its first files, suspends at the progress await; the queued reconcile
runs `cleanOrphans` with S (which lacks #2's uncommitted rows) and deletes the
new directories before `importAttachments` commits them. A save failure during
any import hits the same window.

**Impact:** bounded — `importOne` (`:403-512`) is await-free internally, so
only already-copied items lose their materialization while their `payload` is
already in memory; the commit still succeeds and `ensureMaterialized`
(`:152-174`) transparently rewrites the file from `payload` on next access or
on the reconcile repair pass (`NoteStore.swift:1019-1035`). Observable effects
are wasted copy work, a transient missing-file state, and — if a preview/Quick
Look request lands inside the window — a spurious "The original file is
missing" failure row (`NoteStore.swift:559-561`) that later clears. No durable
data loss because note attachments always persist `payload`, but the race is a
real correctness gap asymmetric with the rest of the cleanup design.

**Bounded recommended fix:** apply the sweep's recency rule inside
`cleanOrphans` — skip materialization directories created or modified within a
short cutoff (minutes, not the sweep's 24 h) — or track in-flight import
directory prefixes on the store and exclude them.

## Hypotheses — reviewed, not confirmed as current defects

- **Repair payloads drawn from visible replicas only.** `reconcileFileStorage`
  builds repair references from `attachmentsByNoteID` (deduplicated;
  `NoteStore.swift:1022-1025`) while `reconcileMetadata` inventories every
  physical replica. If a divergent hidden replica carries `payload` while the
  visible one lacks it, repair reports a spurious failure instead of healing.
  No current producer for payload divergence was found; unresolved.
- **`TaskStore.update` converges hidden replicas' `imageReferencesData` to the
  visible representative** (`TaskStore.swift:524-534`): a title-only edit can
  overwrite a divergent replica's richer attachment list, orphaning those
  private files until the launch sweep. Divergent task replicas have no
  current producer in local-only builds, and convergence is the documented
  "mutations apply to every replica" contract — noted, not a defect.
- **Note-side materialization removal skips the surviving-reference check the
  task side performs** (`removeAttachmentFiles`, `TaskStore.swift:736-747` vs.
  `removeMaterializationsAfterSuccessfulSave`, `NoteStore.swift:1102-1109`).
  A crafted store sharing one attachment id across two notes could lose the
  survivor's file on delete — but note attachments persist `payload`, so it
  self-heals; no current producer for cross-note id sharing.
- **Drawer-delete divergence (investigated, benign).** `SavedNoteRow`
  (`NotesPanelContent.swift:845-852`) calls only `noteStore.delete`, skipping
  `noteDraft.discardDeletedNote`/`uiState.endAdding` used by
  `NoteRowView.deleteNote` (`:965-971`). Traced: a dirty draft of the deleted
  note is preserved via `.missingOriginal` conflict
  (`NoteDraftController.swift:482-515`); a clean draft is discarded and the
  panel reopens the most recent note (`AtticPanelView.swift:854-868`,
  `:823-852`). The difference is cosmetic, not a data defect.
- **`placeAttachment` at the terminal newline.** An offset at `body.length`
  snaps `paragraphStart` to `length` (`NoteInlineAnchor.swift:68-73`), and
  `resolve` sends `offset >= length` anchors to the tray
  (`NoteInlineCards.swift:359-361`) — "Place at text cursor" at the very end
  of a trailing-newline body lands in the tray. Edge-case UX, recoverable via
  context menu; not reported as a defect.

## Verified repaired — prior findings re-checked, not re-reported

Confirmed fixed in the current dirty source; listed only for context:

- **D1 — local-only gating:** `TaskStore` guards remote observers behind
  `#if !ATTIC_LOCAL_ONLY` (`TaskStore.swift:258-261`);
  `RevealRefreshPolicy.inProcessAuthoritative` disables reveal refreshes
  (`CornerHoverMonitor.swift:14-22`); the coordinator builds the local-only
  container (`AppCoordinator.swift:210-238`).
- **C3 — task persistence/reconciliation:** `update` writes every physical
  replica in one save and repairs divergent replicas
  (`TaskStore.swift:443-536`); `delete`/`purgeCompleted` refuse ambiguous
  families and require replica agreement (`:787-840`, `:842-904`).
- **D2 / TP-005 — picker single finish:** `TaskAttachmentPickerSession.finish`
  is idempotent and the only exit (`TaskImageAttachments.swift:215-230`).
- **C1 — attachment Open path:** Open hands a disposable read-only copy, never
  the private materialization (`NoteAttachmentPlatformSupport.swift:25-45`;
  `TaskImageFiles.openableCopy`, `TaskImageReference.swift:120-129`).
- **C2 — swallowed paste/promise failures:** every import path reports
  (`captureReportingFileImportReceiver`/`handleAttachmentPasteboard`,
  `NoteAttachmentTray.swift:1611-1666`; `importUnavailableMessage`,
  `NotesPanelContent.swift:557-564`; `PromisedFileBatch` timeout/failure,
  `NoteAttachmentTray.swift:1721-1833`).
- **F-04 / F-11** — `releaseFamilyInteractionState` and section-switch focus
  ordering: verified corrected during this audit's earlier pass.

## What was verified sound (not defects)

- **Autosave durability:** 500 ms debounce plus an un-shifted 5 s maximum
  deadline (`NoteDraftController.swift:598-631`); `flush()` is called before
  panel hide (`AtticPanelController.requestHide`), termination
  (`AppCoordinator.prepareForTermination`, `AppDelegate.swift:25-33`), note
  switching, and every `placeAttachment`; a failed flush vetoes termination
  and reveals the panel rather than discarding.
- **Deletion preservation:** a dirty draft whose note was deleted survives as
  a `.missingOriginal` conflict with "Save as New" recovery; clean drafts
  reconcile or reopen.
- **Crash recovery:** the recovery journal is generation-guarded and preserves
  the persisted snapshot so a post-crash restore can distinguish clean replay,
  remote change, and missing original (`NoteDraftController.swift:220-267`,
  `650-678`).
- **Attachment import atomicity:** imports reserve the origin, copy into
  private storage first, write all replicas in one fresh-context transaction,
  and roll back + remove materializations on every failure path
  (`NoteStore.swift:300-477`, `:800-832`).
- **Task attachment lifecycle:** owner reservation serializes imports; failed
  saves remove new private copies; removal/export delete bytes only after a
  successful save and only when no surviving replica references them; the
  launch sweep is age-gated and replica-aware (`TaskStore.swift:618-764`).
- **Done-task cleanup:** `purgeCompleted` uses `completedAt` against the start
  of the local day, requires replica agreement, and keeps families together
  via a fixpoint (`TaskStore.swift:842-904`; `DailyCleanupService.swift:62-80`).

## Residual validation limits

- No code was executed: reproductions above are deterministic at source level
  but were not run; race windows (R-03) are confirmed reachable by inspection
  of actor suspension points, not by timing measurement.
- The worktree is dirty and was reconciled once during the audit; line numbers
  were re-verified at write time but may drift under the implementation
  worker's ongoing edits.
- CloudKit-only paths (`observeRemoteChanges`, `handleCloudSyncEvent`,
  protected activity) are dormant under `ATTIC_LOCAL_ONLY` and were reviewed
  statically; nothing here asserts behavior of deferred sync.
- UI-visible severity of R-01/R-02 (how far a card visibly jumps) was assessed
  from layout code only; no rendered verification was permitted.
