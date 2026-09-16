# Task panel V2 Batch 3 — Fix delta review (SWE-B: routing/UI)

Scope: independent delta review of `.build/batch3-fixes.diff`
(sha256 `f1d03cece3ebe2b1db0989ff13125ecde48f2e8524121d9ba07a76c5ad2ba8b2`),
applied over the batch3 worktree. Live worktree verified identical to the
reviewed `current_tree` (`5686a349`) for all 13 changed files. Contract:
`Docs/TaskPanelV2Requirements.md` R3–R6 plus the interim SWE fix requests.
This review covers routing/interaction surfaces and the fix's data/launch
hooks; SWE-A covers the data/lifecycle half. No source, test, UI, or data
files were modified; no commits made.

## Verdict

**APPROVED — no P0/P1/P2 defects found.** All three requested fixes are
implemented correctly and consistently across every surface, and the two
minor hardening items (overlay end, reveal generation) are sound. The delta
is careful about the cases the interim reviews called out: duplicate
replicas, child-owned legacy attachments, stale drag records, tampered
markers, promise metadata, internal marker types, reserved imports, and
rollback. Remaining exposure is verification coverage, not known code
defects — the new test suite compiled but did not execute (pre-test
runner stall), and no live drop UI has run against this code. Both are
unmet gates below, not blockers in the source.

## What the fix does and why it is correct

### BF1 — Self-vs-other gallery-card routing (P1 in interim review)

- `TaskAttachmentCardDrag.begin` (`Attic/Models/TaskImageReference.swift:245`)
  is invoked from the single `.onDrag` site
  (`Attic/Views/Panel/TaskImageAttachments.swift:280`), which every gallery
  card shares — including the legacy child-attachment popover in
  `TaskRowView.swift:88`. So card drags from the panel gallery *and* the
  legacy popover resolve an owner.
- `TaskStore.attachmentSource(for:)` (`TaskStore.swift:442`) resolves the
  reference over the deduplicated task list, maps child-owned attachments to
  their top-level parent via `attachmentOwnerID` (`TaskStore.swift:1033`),
  and returns `nil` on ambiguity or a parentless child — conservative
  refusal, correct per contract.
- `canCopy(toOwner:)` refuses only `current.ownerID == toOwner`. Verified
  at every route: parent row (`TaskRowView.swift:221` →
  `canAcceptAttachment`/`panelTarget.canAccept`), child rows inside the
  panel (same env, `ownerID` collapses to `parentID`), panel surface
  (`SubtaskPanelContent.swift:57`), and composer (`AtticPanelView.swift:188`,
  `excludingOwner: nil` → any resolvable card). A self-drop fails at
  `validateDrop` (`.forbidden`, no false failure); a stale proposal that
  somehow reaches perform still throws `alreadyAttached` inside the import
  reservation.
- Copy, not move: `importCopies` (`TaskImageReference.swift:178`) opens
  each source only after `verifiedMaterializedURL` re-checks the id, the
  SHA-256 digest, and `isUnderRoot`; it streams each file into a fresh
  UUID/`<digest>` directory and builds `TaskImageReference`s that carry the
  source `contentTypeIdentifier` but derive filename/type from the new
  private file. `importFiles` is sequential and order-preserving
  (`AttachmentFileStore.swift:217`), so the digest-order equality check and
  the `zip` pairing are sound. The source is never touched — removing the
  copy can only delete the new UUID's directory.
- Defense in depth at perform time: `sources(from:expected:)` requires
  exactly one marker provider and a marker UUID equal to the recorded card;
  `verifiedCopySources` re-resolves the store inside the reservation and
  re-verifies equality + digest. A stale or tampered record fails closed.
- `TaskAttachmentCardDrag.current` is never cleared — acceptable: it is only
  consulted while the own-process marker is present in a live drag, every
  card drag overwrites it, and perform-time checks bind it to the marker.
- Finder drag-out preserved: the file representation is registered before
  the own-process marker (`TaskImageAttachments.swift:286-298`), and the
  marker is `.ownProcess` only.

### BF2 — General promised-file UTTypes (P2)

- One classifier, three stages: `classify(_ info:)` on `DropInfo`,
  `classify(provider:)` per `NSItemProvider` in `providers(for:)`, and
  `fileContentType` at materialization (`TaskAttachmentDrop.swift:27-60`).
  All surfaces register `attachmentCard + fileTypes + .data`
  (`rowDropTypes`/`dropTypes`, `TaskAttachmentDrop.swift:90-93`).
- `.data` acceptance is gated by *exclusions*, which is the right shape:
  `nonFileTypes` (text/URL) and `internalMarkerTypes` (task, card, note
  inline-card) are checked before the data fallback. The markers are
  matched by `hasItemConformingToTypeIdentifier` — identifier equality, not
  conformance — and all three types are verified declared as `public.data`
  in `Info.plist`, so the exclusion list is genuinely load-bearing.
- `.uti-matrix.txt` measured conformances confirm docx/doc/pages/eml/epub/
  ttf reach `.files` while txt/md/rtf/csv/html/ics/vcf/json do not; folders
  and packages do not conform to `.data`; Mail/file-promise metadata types
  conform to neither (handled by the promise path itself).
- `fileContentType` prefers `fileURL`, then a listed type, then the first
  declared non-dynamic data type that is not an internal marker — promised
  `.docx` materializes as `.docx` with its real extension through
  `filename(suggested:loaded:type:)`, and `importOne` re-derives the type
  from the preserved extension (`AttachmentFileStore.swift:255-262`).
- Ordering is load-bearing and correct: `fileURL`/`fileTypes` are checked
  before the `.data` fallback, so `public.file-url` (which conforms to
  `.url`) still classifies as `.files`.
- Deliberate conservative edge (documented in the ledger): a provider that
  carries *both* a document and a text/URL flavor is refused wholesale.
  This keeps text selections, link drags, and Cards.app/Contacts drags out
  at the cost of refusing mixed document+text providers. Consistent with
  the tested contract.

### BF3 — Launch-time orphan sweep (P2)

- `sweepUnreferencedAttachmentStorage` (`TaskStore.swift:1064`) is once
  per store instance, refuses while any import reservation is held, unions
  referenced ids across **all physical replicas** via `context.fetch` (not
  the deduplicated `tasks`), and aborts entirely on any undecodable replica
  — the conservative direction in every case.
- `removeUnreferencedMaterializations` (`AttachmentFileStore.swift:335`)
  enforces canonical `<UUID>/<64-hex>` shape, a 24h floor on *both*
  creation and modification times, a bounded count (500), skips
  `Thumbnails`, and sweeps `.staging` batches plus `tmp/AtticTaskDrops`
  children by the same floor. It never touches the user-visible originals
  or the notes tree.
- Call site is safe: `AppCoordinator.start` gates on `!isRunningTests`
  *and* the sweep line (AppCoordinator.swift:351-355) sits after the
  unit-test early return (:319) and the UI-testing early return (:342).
  Verified both early returns precede it — test containers cannot reach
  the sweep against persistent files.
- Standalone real-source harness passed 14/14 covering deletion limit,
  second-pass continuation, replica-union protection, recent-file floor,
  non-canonical names, staging roots, originals, and recent-content-keeps-
  directory.

### F4 — Overlay end cleanup

- `TaskFileDropTarget.end()` clears all four sources; the configured
  `perform` calls it at the top (`TaskAttachmentDrop.swift:220`), row
  `performDrop` calls `panelTarget?.end()` before forwarding
  (`TaskRowView.swift:238`), and `.onChange(of: parentID)` ends on family
  swap (`SubtaskPanelContent.swift:74`). Double-invocation is idempotent.
  A stale surface source cannot survive a consumed or performed drop.

### F5 — Reveal generation

- `RevealContext{transientFamilyID, transientChanges}`; the counter bumps
  in `syncState()` on mirror diff and in `tearDown` when a transient was
  presented (`SubtaskPanelController.swift:566-590, 788-806`). Traced every
  write to `transientFamilyID` — `maturePendingOpen`, `openTransient`,
  `closeTransient`, pin/unpin paths, `commitPendingOpen` — each reaches
  `syncState`/`tearDown`. `noteRowHover`, `noteTransientPointer`, `rearm*`,
  and `detachTransient` never write it. A family opened, closed, or
  replaced mid-import suppresses the reveal; an unpresented target stays
  closed. Behavior matches the contract's conservative rule.

### F6 — Staging discard contract

- The contract is now explicit on all three sites and both wrappers use
  `defer { staging.discard() }`, covering the throw-after-return case the
  interim review flagged. `TaskComposerAttachments.add` documents that the
  `importing` closure owns cleanup; both real closures satisfy it.

### Reorder/pointer regressions — none found

- `.task` remains first in `classify`; the `.task` arm of `performDrop`,
  `beginTaskDrop`, the synchronous `endDragging` flush, and the section
  `dropDestination` are untouched. A nested child-row task provider that
  also carries folder/file types still routes to `.task`.
- Row hover, pending-open, corridor, latch, and teardown paths are
  unchanged except the reveal signature rename (`transientAtDrop:` →
  `since:`), which is consistently applied at all three call sites.

## Findings

No blocking or major findings. The items below are minor or observational;
none require a fix before live verification.

### Low — Proposal-layer routing is unverifiable except live

`TaskFileDropDelegate`/`TaskRowDropDelegate.validateDrop`/`dropUpdated`/
`performDrop` consume `DropInfo`, which is not constructible in tests, so
the `.copy`/`.forbidden` proposal for card-on-own-owner, card-on-other-
owner, and text-over-surface can only be confirmed in a real drag. The
testable seams (`canAccept`, `canCopy`, `verifiedCopySources`,
`providers(for:)`) are covered by the new tests; the delegate layer is a
thin dispatch over them. **Live check:** drag a card over its own family
row → forbidden/no highlight; over another row → copy highlight; a text
selection over the surface → forbidden, no attach.

### Low — `.data` registration makes non-file drags visible to more surfaces

Registering `.data` on rows/surface/composer means task drags and text
drags now receive a `.forbidden` proposal over the panel surface and
composer instead of being ignored (previously they were not candidates).
Deliberate and documented in the ledger; **live check** that the forbidden
badge during a child-row reorder over panel gaps reads acceptably, and
that the row-level task highlight still wins while hovering an actual row.

### Low — `RevealContext` tracks the transient only

Pinning or unpinning a different family mid-import does not change the
context, so an import dropped on a closed family can still reveal it after
the user pinned another family. Same semantics as the pre-fix
`transientAtDrop` comparison (which also ignored the pinned set); the
counter closes the strictly-worse hole (transient changed since drop).
Acceptable scope for this delta; note as a candidate for the batch4
latch/pointer review if desired.

### Low — Sweep protects by UUID, not UUID+digest

A stale digest directory under a still-referenced attachment id is never
swept (union is over attachment ids only), and a foreign file (e.g.
`.DS_Store`) inside an otherwise-orphan id directory leaves the shell
behind. Both fail safe — residue, not loss — and a second pass within the
bound will catch the common cases. No change needed.

### Observational — `attachmentSource` decode cost

`attachmentSource(for:)` iterates `tasks` and `task.attachments` decodes
`imageReferencesData` per task per call (drag begin + once per perform +
once per `verifiedCopySources`). O(n) JSON decodes at local scale;
negligible, but if task counts grow large it is a candidate for a cached
attachment-index. Not a defect today.

### Observational — `current` retained after drop

`TaskAttachmentCardDrag.current` persists after the drag ends. Harmless
because it is only consulted alongside the own-process marker, but a
`DragSession`-end hook (when available) would make the lifetime explicit.

## Evidence reviewed

- `.build/batch3-fixes.diff` — full 13-file delta read line-by-line; hash
  matches `diffs.txt`. No new files, no schema/entitlement/signing/bundle
  changes, no `ATTIC_LOCAL_ONLY` changes.
- Live worktree == `current_tree 5686a349` for all 13 changed files
  (blank worktree column under `GIT_INDEX_FILE=.build/batch3-fixes/
  current.index git status`).
- `Attic/App/AppCoordinator.swift`, `TaskStore.swift`,
  `AttachmentFileStore.swift`, `TaskImageReference.swift`,
  `TaskAttachmentDrop.swift`, `TaskComposerAttachments.swift`,
  `AtticPanelView.swift`, `SubtaskPanelContent.swift`, `TaskRowView.swift`,
  `TaskImageAttachments.swift`, `SubtaskPanelController.swift`,
  `SubtaskPanelLayout.swift`, `Info.plist` (UTI declarations),
  `AtticTests/TaskAttachmentDropTests.swift` — read in final state.
- Build logs: `build-local-1.log` → **BUILD SUCCEEDED**;
  `build-for-testing-1.log` → **TEST BUILD SUCCEEDED**.
- `unit-focused-1.log` + `host-sample-1.txt`: runner stalled in XCTest
  pre-test handshake (host waiting on testmanagerd/IDE session); **zero
  test suites executed**. Not retried per instruction; not counted as
  pass or fail.
- `sweep-harness/` standalone run against the real
  `AttachmentFileStore.swift`/`NoteAttachment.swift`: **14/14 PASS** —
  covers sweep/store internals only, not SwiftUI/drop/store integration.
- `.build/batch3-fixes/uti-matrix.txt` — measured UTType conformances on
  this machine supporting the classifier claims.
- `Docs/TaskPanelV2Ledger.md`, `Docs/TaskPanelV2Requirements.md`,
  `Docs/TaskPanelV2Batch3SWE-A.md`, `Docs/TaskPanelV2Batch3SWE-B.md`,
  `Docs/TaskPanelV2Orchestration.md`, `AGENTS.md`.

## Test quality

The new `TaskAttachmentDropTests` section is well-targeted at the changed
seams: classifier matrix (listed types, general data, exclusions),
card-copy happy path, marker/tamper/stale-source rejection, composer copy,
legacy child-owner resolution, ambiguity refusal, sweep behavior, atomic
binding, cancellation ownership, and reveal matrix. Assertions are
meaningful (digest equality, directory shape, replica union, generation
guards) rather than smoke checks. Two honest gaps: the `DropInfo` proposal
layer cannot be constructed in tests (see finding above), and the suite
**compiled but never ran** — `TEST BUILD SUCCEEDED` proves syntax and
linkage only, not behavior.

## Unmet gates / unverified behavior

1. **Fix-round unit tests unexecuted.** `unit-focused-1.log` shows the
   runner stalled before any suite; `TEST BUILD SUCCEEDED` is compile
   evidence only. Per orchestration: no blind retries; suites remain
   owed until infrastructure recovers or a legitimate alternative run
   is arranged.
2. **Standalone sweep harness is partial evidence.** 14/14 real-source
   passes cover `AttachmentFileStore`/sweep internals only — not the
   `TaskStore` reservation interplay, drop delegates, or SwiftUI surfaces.
3. **No live UI evidence for this delta.** The preview executable is the
   frozen batch2 build (SHA `03708e9d…`); it was not rebuilt, launched,
   or driven. Everything on the ledger's live-check list remains
   unverified: self-vs-other card cursor/highlight, child-row and
   composer card routes, `.docx`/`.eml` promise attachment, text/link/
   folder refusal, forbidden-badge side effects during reorder, overlay
   cleanup after consumed/failed drops, reveal-suppression cases, and
   post-quit orphan reconciliation on the real store.
4. **Adjacent suites still unrun** — `TaskImageTests`, `SubtaskTests`,
   `SubtaskPanelControllerTests`, etc., from batch3 remain owed.
5. **SWE-A (data/cleanup) fix review still pending** — this report covers
   routing/UI plus an independent pass over the shared seams; the data-
   half verdict belongs to `TaskPanelV2Batch3FixSWE-A.md`.

## Recommendation

Advance to live batch3 verification (new preview build required — the
frozen executable predates batch3 entirely), keep the unrun-test gate
open for the final pass, and let SWE-A's data-half review complete the
pair. No source changes requested from this review.
