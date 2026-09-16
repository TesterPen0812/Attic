# Batch 3 (R4 + R5) — Fix delta review (SWE-A: data/lifecycle)

Scope: `.build/batch3-fixes.diff` (sha256 per `.build/batch3-fixes/diffs.txt`),
the fix round answering `Docs/TaskPanelV2Batch3SWE-A.md` (F1–F6) and
`Docs/TaskPanelV2Batch3SWE-B.md`. Delta-only review of the applied source and its
actual callers; no source, test, UI, data, or commit changes by this reviewer.
SWE-B covers the routing/UI half; this report covers marker/digest identity,
copy ownership, composer races, and launch cleanup.

## Verdict

**APPROVED — no blocking findings.** All three requested fixes are implemented
correctly end-to-end: card drops copy digest-verified bytes into independently
owned private storage with three-layer refusal of the owning family; composer
cancel/save/cleanup races are closed by generation + reservation; the launch
sweep is conservative in every failure direction (replica union, decode-abort,
24 h floor, bounded count, canonical shapes only). Two Low findings below are
hardening items, not correctness defects. The real gate is unexecuted tests and
live UAT, not known code defects.

## Evidence checked

- `build-local-1.log` → `** BUILD SUCCEEDED **`; `build-for-testing-1.log` →
  `** TEST BUILD SUCCEEDED **` (final source, Local config).
- `unit-focused-1.log` ends `** BUILD INTERRUPTED **` with zero `Test Suite`
  lines; `host-sample-1.txt` shows the host in
  `-[XCTestDriver _prepareTestConfigurationAndIDESession]` — a pre-test
  handshake stall. Tests compiled, **never executed**; not retried per
  instruction and not counted as pass or fail.
- `sweep-harness/` runs the real `AttachmentFileStore` against a temp root:
  **14/14 PASS** (`run-1.log`) covering the removal limit, old unreferenced
  removal, referenced/recent/unknown/non-canonical-name retention, staging age
  split, originals untouched, and recent-content-keeps-copy.
- `uti-matrix.txt` — measured UTType conformances backing the classifier claims.
- Full delta plus final-state reads of every touched file and its callers;
  `AGENTS.md` contract, requirements, ledger, both prior reviews.

## What the fixes get right

### BF1 — card copies (SWE-A F1, SWE-B P1)

- Identity chain is sound at every layer. `.onDrag`
  (`TaskImageAttachments.swift:277-281`) calls
  `TaskAttachmentCardDrag.begin`, which resolves the card's
  `TaskAttachmentSource` — reference plus resolved top-level owner — from the
  store (`TaskStore.swift:442-450`). The provider factory must run before any
  destination can see the own-process marker
  (`TaskDragPayload.swift:48-54`, registered after the file representation,
  `.ownProcess`), so `current` is always the live drag's card.
- Synchronous validation: `TaskFileDrop.canAccept(_:onto:store:)`
  (`TaskAttachmentDrop.swift:304-312`) resolves the row/panel id to its owner
  and refuses while an import reservation is held; `canCopy(toOwner:)`
  (`TaskAttachmentDrop.swift:264-267`) refuses only `current.ownerID`. Own
  owner, its child rows, and its panel surface all collapse to the same owner
  via `attachmentOwnerID` (`TaskStore.swift:547-551`) and are refused with no
  highlight — the deliberate no-op drop.
- Perform-time revalidation is defense in depth, not trust:
  `sources(from:expected:)` (`TaskAttachmentDrop.swift:271-287`) requires
  exactly one marker provider whose payload UUID equals the recorded reference
  id; `verifiedCopySources` (`TaskStore.swift:454-461`) then requires the store
  to still resolve the *exact same* `TaskAttachmentSource` (full reference
  equality — digest, filename, byteCount, type — and same owner) and throws
  `alreadyAttached` for the target's own family. A stale proposal, a mismatched
  marker, a record left by an earlier drag, or an attachment that changed hands
  mid-drag all fail closed with the calm message.
- Ownership rules: legacy subtask attachments resolve to their parent;
  a parentless subtask or an attachment held by two visible tasks is
  unresolvable and refused everywhere (`TaskStore.swift:442-450`). Composer is
  `excludingOwner: nil` — any resolvable card (`AtticPanelView.swift:642-655,
  746-757`).
- Independent private copies: `importCopies` (`TaskImageReference.swift:72-87`)
  reads each source only through `verifiedURL` → `verifiedMaterializedURL`
  (`AttachmentFileStore.swift:338-349`), which re-checks existence, regular-file
  status, byteCount, and SHA-256 against the *recorded* digest before a byte is
  copied. Each copy is a fresh UUID → its own `<UUID>/<digest>/<filename>`
  directory, so `removeAttachment`/`removeMaterializations` on either side can
  never touch the other. The copy's own recomputed digest must equal the
  source's or the batch is removed and nothing attaches; the recorded content
  type carries over. Sources and originals are read-only throughout.
- The whole copy runs inside the same owner reservation, bind and rollback as a
  file import (`attachImported`, `TaskStore.swift:466-503`): reservation is held
  while `sources()` loads and verifies, a second import for that owner refuses
  calmly, a deleted owner or failed save removes the new copies.

### BF2 — general promised files (SWE-A F3, SWE-B P2)

- One rule at all three levels: `classify` on `DropInfo`
  (`TaskAttachmentDrop.swift:45-55`), per-provider for the fetch
  (`TaskAttachmentDrop.swift:58-70`), and `fileContentType` at materialization
  (`TaskAttachmentDrop.swift:179-190`). `.data` is accepted only by *exclusion*
  — text, URL, and the three declared in-app markers are refused — which keeps
  text selections, links, folders (not `public.data`), note-card moves, and
  mixed document+text providers out. `uti-matrix.txt` corroborates the
  conformance claims on this machine.
- `fileContentType` prefers a listed type, then the first declared non-dynamic
  data type, so a promised document keeps a real extension and type through
  `filename(suggested:loaded:type:)`; `importOne` re-derives type from the
  preserved extension. The regular-file/15 MiB/20-item guards are unchanged.
- Deliberate side effect (ledger-documented): text and task drags now reach
  the composer and panel-surface destinations and are refused instead of
  ignored — `accepted` returns nil, so those destinations are simply not
  candidates; nested child-row task destinations still win on actual rows.

### BF3 — launch sweep (SWE-A F2, SWE-B P2)

- Reachability verified, not assumed: the sweep call
  (`AppCoordinator.swift:347-352`) sits after **both** the unit-test early
  return (`shouldStartInteractiveShellServices` guard, :319) and the
  `isUITesting` early return (:330-342), inside `!isRunningTests`. Because
  `inMemory` is exactly `isUITesting || isRunningTests` (:213), the sweep can
  only ever run against the persistent container — an empty in-memory
  reference set can never judge real files.
- `sweepUnreferencedAttachmentStorage` (`TaskStore.swift:518-537`): once per
  store via a flag set before the fetch; refuses while any import reservation
  is held (no suspension between the guard and the synchronous `context.fetch`,
  so no import can interleave); unions referenced ids across **every physical
  replica**, not the deduplicated list — a divergent hidden replica keeps its
  files; any undecodable `imageReferencesData` aborts the entire sweep.
- `removeUnreferencedMaterializations` (`AttachmentFileStore.swift:284-334`)
  deletes only canonical `<UPPERCASE-UUID>/<64-hex>` directory pairs where the
  id is unreferenced and the directory *and every item in it* predate the
  24 h cutoff; an unreadable date counts as recent. `Thumbnails` survives via
  the UUID-name guard, `.staging` is hidden-skipped at root and swept by age in
  its own pass, an emptied id dir is removed only if it was old before the
  sweep, and removals are capped at 500/launch with continuation next launch.
  `TaskAttachmentStaging.removeAbandoned`
  (`TaskAttachmentDrop.swift:107-122`) applies the same floor to owned
  `tmp/AtticTaskDrops` children only. Deletion ownership is confined to the
  task tree and owned staging; the notes tree is a separate root; originals
  are never touched.
- Concurrency: the actor serializes all filesystem work; an import starting
  mid-sweep writes files seconds old — protected by the floor. The
  composer-pending case the fix targets is covered: pending copies are young
  until bound or orphaned, and orphaned ones become collectible after 24 h.

### F4/F5/F6 — hardening items

- `TaskFileDropTarget.end()` clears every registered source
  (`TaskAttachmentDrop.swift:362-365`); both the row perform path (:488) and
  the panel's configured `perform` (`SubtaskPanelContent.swift:291`) call it,
  and family/mode changes reconfigure with an `end()`
  (`SubtaskPanelContent.swift:227-231`). A stale surface source cannot survive
  a completed file/card drop.
- `RevealContext` (`SubtaskPanelController.swift:573-583`) pairs the transient
  family with a counter bumped on every mirror change in `syncState` (:840-843)
  and in `tearDown` (:801). Every write to `lifecycle.transientFamilyID`
  funnels through `syncState` — including `closeTransientSurface`, which calls
  it internally — so "opened another family then closed it again" now
  suppresses the reveal. All callers pass `revealContext`
  (`SubtaskPanelContent.swift:507-509`, `TaskRowView.swift:392-394`,
  `TaskAttachmentDrop.swift:319-334`).
- The staging discard contract is now stated at all three sites and both
  wrappers use `defer { staging.discard() }` (`TaskStore.swift:417-419`,
  `TaskComposerAttachments.swift:42-44`), covering throw-after-return.

### Composer races

- `canSubmit` requires `!isImporting` (`TaskComposerAttachments.swift:30-32`),
  and `canAdd` likewise (:26-28) — submit, a new batch, and a card copy can
  never overlap an in-flight import.
- Cancel bumps `generation`, cancels the task, and clears the chip
  (:79-86); a late completion with a stale generation removes its own
  imported copies instead of repopulating (:63-65); a stale failure is
  dropped entirely (:70). Cancellation points exist after staging and inside
  `importFiles` per item and per 1 MiB chunk, and the importer's own rollback
  removes partial finals and the batch root (`AttachmentFileStore.swift:86,
  107, 120-133`). The `defer` discards returned staging even on cancellation.
- `didBind()` clears pending only after a successful `create` save; a failed
  save keeps pending for retry. `remove` deletes only the composer's own
  copies. Deallocation mid-import still cleans via the `[weak self]` path.
- Card copies into the composer share the same machinery through the
  generalized `add(count:files:importing:reportFailure:)`
  (`AtticPanelView.swift:746-757`) — same generation, limits and cleanup.

## Findings

### Low 1 — the sweep's directory checks follow symlinks out of the store root

`AttachmentFileStore.swift:289-334`. `isDirectoryKey` resolves through links, so
a planted `<UPPERCASE-UUID>` symlink inside `Attic/TaskImages` has its *target*
enumerated, and an old `<64-hex>`-named directory in the target is deleted
through the link (`removeItem(at:)` resolves the intermediate symlink).
Reproduction: `ln -s ~/Documents <root>/<UUID>` where the target contains a
`deadbeef…(64)` directory older than 24 h → next launch removes it, i.e.
deletion outside the owned tree. Containment requires write access to the
app-private sandboxed container, and the pre-existing `cleanOrphans` follows
the same pattern — so this is hardening, not an introduced vulnerability; the
new code is the one that now deletes through it. Narrow fix: add
`.isSymbolicLinkKey` to `keys` and skip link entries at both levels (and in the
`.staging` batch loop).

### Low 2 — `.task` arm of `performDrop` does not clear the panel target

`TaskAttachmentDrop.swift:470-496`. The `.files`/`.attachmentCard` arm calls
`panelTarget?.end()` (:488); the `.task` arm only `clearTargets()` (:471, 498),
which removes *this row's* source. If a stale source survives on
`panelTarget` (the exact F4 case — e.g. a "surface" entry whose `dropExited`
was never delivered) and a task reorder then performs on a child row, the
stale source persists and the drop overlay stays lit while nothing is
targeted. Cosmetic, rare, and self-heals on the next attach drop or family
switch. Narrow fix: call `panelTarget?.end()` unconditionally at the top of
`performDrop` (idempotent).

## Observations (no change requested)

- `hasSweptAttachmentStorage` is set before the reference fetch
  (`TaskStore.swift:520-521`), so a transient fetch or decode failure consumes
  the once-per-launch attempt rather than retrying. Conservative direction —
  nothing is deleted — and consistent with the abort contract.
- The UI-test exclusion depends on ordering: the `isUITesting` early return
  (`AppCoordinator.swift:330-342`), not the `!isRunningTests` guard, keeps a UI
  host's in-memory store away from the real `TaskImages` root. Correct today;
  if `start()` is ever refactored, keep the sweep below both returns.
- `attachmentSource` scans the deduplicated visible list; a reference held only
  by a hidden divergent replica is unresolvable and refused. Its card cannot
  render anyway (galleries decode the same list), and the sweep still protects
  the replica's bytes via the physical-replica union.
- `attachImported` writes `current.attachments + imported` to every replica —
  converge-on-write, the established mutation semantics; references divergent
  on a hidden replica are normalized away, and the sweep then owns the
  orphaned files under the age floor.
- `importCopies` reads each source twice (verify, then stream-copy) — bounded
  by the 15 MiB × 20 limits; fine.
- `performDrop` reports success before the async attach settles (no reject
  animation on a late failure); unchanged from batch 3, deliberately left.
- `importingCount` for a card drop echoes `providers.count`, which `sources()`
  then requires to be exactly 1 — a multi-provider marker drag briefly shows a
  count then fails calmly. Cosmetic.
- `TaskAttachmentCardDrag.current` intentionally persists after a drag; it is
  only consulted while the own-process marker is present and is re-bound to
  the marker at perform. The one externally verifiable ordering assumption —
  `.onDrag` running before the first `validateDrop` — is inherent to provider
  creation but remains on the live-check list.

## Unmet gates (carried, not cleared by this review)

1. **Fix-delta unit tests unexecuted** — `TEST BUILD SUCCEEDED` is compile
   evidence only; the runner stalled pre-test (`unit-focused-1.log`).
   `TaskAttachmentDropTests` (new card/sweep/classifier/reveal cases) plus the
   adjacent suites owed from batch 3 (`TaskImageTests`, `SubtaskTests`,
   `SubtaskPanelControllerTests`, `SubtaskPanelTests`, `NoteAttachmentTests`,
   `TaskStoreTests`, `CornerHoverStateMachineTests`) must run once the runner
   recovers. Not retried per instruction.
2. **Harness coverage is partial** — the 14/14 sweep-harness pass proves
   `AttachmentFileStore` semantics only; store-level replica union, drop
   delegates, marker/card UI, and the classifier in a real drag are unproven
   by execution.
3. **No live UI for this delta** — the frozen preview executable predates
   batch 3. Outstanding live checks: card `.copy`/forbidden proposals on own
   vs other family (row, child row, surface, composer), `.docx`/`.eml` promise
   attaches, text/link/folder refusal, overlay cleanup on crossed drops,
   reveal suppression after family churn mid-import, and post-quit orphan
   reclamation on an isolated preview store — never on `com.taha.Attic` user
   data.
4. **Later stages pending** — Batch 4 (R6/R7), integrated review, Astra High
   final review, and resource validation remain ahead; this verdict covers the
   fix delta only.

## Recommendation

Proceed to the second reviewer's consolidation and live batch-3 validation. The
two Low findings are safe to carry into live verification and can be fixed in
the final fixes round or deliberately declined.
