# Task panel V2 — batch 2 fix-delta independent review (SWE-A, data/import focus)

Reviewer scope: importer memory, validation equivalence and rollback, promised
UTTypes, external-open disposable copy (cleanup/security), picker/popover mark
separation, Notes shared-import regressions, plus an obvious-error pass over the
remaining fixes (view-switch paging, hover-open latch path, chrome re-fit, VO
actions, frame-animation target hygiene). Diff reviewed: `.build/batch2-fixes.diff`
(prefix `11ad5b5c`, current `dcf980de`); prior reports `TaskPanelV2Batch2SWE-A/B.md`,
ledger "Review findings / fixes" (FX1–FX9), `TaskPanelV2Requirements.md` R2/R3.

## Verdict

**Approved.** No P0/P1/P2 in the fix delta. All nine fixes do what the ledger
claims, verified against the real sources and their callers — not just the diff.
Notes behavior is unchanged, rollback semantics are intact, and the private-store
invariants (digest-verified hand-out, sanitized names, confined roots, no original
mutation) all hold. Three P3 observations below; none block.

## Provenance (independently recomputed)

- Rebuilt the working tree via a throwaway index (`read-tree HEAD` + `add -A` +
  `write-tree`, real index untouched): `dcebe6a5…`. `git diff` against the
  recorded `current_tree` `dcf980de` shows only `Docs/TaskPanelV2Orchestration.md`
  (+3, the 05:32 UTC orchestrator note). Reviewed sources are current sources.
- `prefix_tree` `11ad5b5c` vs batch 2's `current_tree` `45f1c04`: differs only by
  the reviewer/orchestrator documents, matching the ledger claim.
- `.build/batch2-fixes/build-local-1.log` ends `** BUILD SUCCEEDED **`;
  `unit-focused-1.log` runs 181 tests, 0 failures, `** TEST SUCCEEDED **`. No
  warnings in any touched file (the one deprecation warning is pre-existing in
  `PanelGeometryTests`, unrelated). Suite not re-run.

## Per-fix verification

**FX1 — importer memory (AttachmentFileStore.swift:64-85, 432; TaskImageReference.swift:41-66).**
The 5-arg signature forwards `includePayload: true` and still satisfies
`NoteAttachmentFileImporting` (NoteStore.swift:9-19), so Notes is byte-for-byte
identical: `item.payload` (now `Data?`) feeds `NoteAttachment.payload` (`Data?`,
external storage). Task imports pass `includePayload: false` — `importOne` skips
the second full read, and nothing accumulates payloads. Validation now runs per
image against `materializedURL` + `CGImageSourceCreateWithURL(ShouldCache:false)`,
`GetCount > 0`. Equivalence holds: the URL is the just-written final file
(`materializedURL` needs no existence check inside the serialized actor), a
missing/unreadable file yields nil source → batch rejected. `sanitizedFilename`
is idempotent and the fresh digest is always 64-hex, so the `try?`-to-nil fold
cannot misfire on a valid import; a thrown `invalidFilename` would degrade to
`fileReadCorruptFile`, which still rejects and cleans — fail-safe either way.
Rollback: image failure → `remove(references)` (all batch copies) →
`fileReadCorruptFile`; per-file staging/final-dir rollback in `importFiles`
untouched. Test `testTaskImportReadsNoPayloadAndRejectsABatchWithABrokenImage`
proves nil payloads, whole-batch rejection with zero surviving UUID dirs, intact
originals, and correct `isImage` flags; the 8-input ImageIO equivalence probe in
`.build/batch2-fixes/imageio-equivalence.txt` is sound. Notes regression check:
`removeImportedMaterializations` (NoteStore.swift:1040-1054) never needed payload;
the `ControlledNoteAttachmentImporter` mock matches the unchanged protocol; 43
NoteAttachmentTests pass.

**FX2 — promised UTType (TaskDragPayload.swift:15-47, TaskImageAttachments.swift:213-217).**
`registerFileRepresentation` under the recorded type (`public.png` etc.), falling
back to `public.data` only when the recorded type doesn't conform to data;
`fileOptions: []` and `inPlace: false` keep copy-not-in-place semantics, so the
verified private URL is resolved lazily and never exposed writable. `suggestedName`
carries the filename. `.onDrag(_:preview:)` keeps the same preview; the type is no
longer `Transferable` and nothing else needed that conformance. File-URL receivers
(Finder) resolve file representations regardless of the specific UTI — the old
`public.data` promise relied on the same machinery, so this is strictly better for
typed receivers and parity for generic ones. The test asserts registration,
conformance (image/png/data; text → plainText+data, not image), and that a loaded
`public.image` yields a different URL with identical bytes.

**FX3 — picker mark separation (PanelUIState.swift:45-72, TaskImageAttachments.swift:54-90, controller:388-389).**
`taskAttachmentPickerOwnerID` is the picker's own mark: it feeds
`.taskConfirmation` and `familyEditBusy` via `belongsToFamily` (owner is always a
parent), exactly the coverage the shared mark gave. `isAvailable` gates both
affordances (row menu TaskRowView.swift:387, footer SubtaskPanelContent.swift:471)
and `choose` itself, so an offered click can no longer no-op, a child popover no
longer blocks the picker, and a popover can't steal the picker's protection.
`selectSection`/`reconcileTaskIDs` deliberately leave the picker mark alone — the
panel is still up; a deleted owner's stale mark just holds the lock until the
`begin` completion clears it, and `attachFiles` then fails safe on
`attachmentOwnerID == nil`. One picker at a time is enforced for all families.
Test `testPickerAndChildPopoverKeepSeparateMarksAndNeitherSilentlyBlocks` exercises
the mark coexistence, the disabled state, section-switch survival, and release.

**FX4 — stale frame targets (SubtaskPanelController.swift:976-1031, 1155-1188).**
`SurfaceFrameAnimationTargets` weakly owns each window and honors an entry only
for that same live object; mismatched/dead entries are evicted on lookup and
pruned on set. `clear(for:)` is safe: two live objects can't share an address, so
it can only remove an entry owned by the caller's own surface. The SWE-B F2 path
(recycled `ObjectIdentifier` reading a dead window's frame in
`resizeDetachedSurface`) is closed. `applyFrame`'s `target == frame` early-out and
`stopFrameAnimation` behave identically for the nil case.

**FX5 — view-switch paging (SubtaskPanelLayout.swift:187-189, SubtaskPanelContent.swift:388-394).**
Symmetric `.offset(x: viewSwitchOffset(for:)).combined(with: .opacity)`:
attachments +18 (right), subtasks −18 (left); each view enters from and exits
toward its own side, so on a switch both layers translate the same way — the
documented spatial model. Reduce Motion stays `.opacity`. Matches the fix intent.

**FX6 — hover-open latch path (SubtaskPanelController.swift:515-538).**
`alreadyPresented` (same family + visible, or presentation suppressed in tests)
catches the `openTransient`-returns-true origin-change case: `openTransient`
latches and clears pending work, `syncState()` arms outside-click monitoring, the
view request routes through `showPanelView` (animated + scheduled re-fit), and
raise/`focusEntry` run — no `presentTransient`, no un-animated `panelViews.set`,
no `stopFrameAnimation` snap. Order is right (sync before the view set, so
`panelViews.retain` can't drop it). `!openTransient && alreadyPresented` (already
latched, incl. detached — `isTransientDetached` survives because `openTransient`
returned before mutating) gets the same raise path plus a harmless `syncState`.
The `!openTransient && !alreadyPresented` and fresh-open paths are unchanged.

**FX7 — chrome re-fit (SubtaskPanelContent.swift:148-154, controller:771-792).**
Chrome changes >0.5 pt call `noteChromeMeasured`, gated by `isLiveSurface` —
stale hosts (pin/unpin swaps, dead families) can't schedule refits. The scheduled
`refreshSurfaceSizes` covers transient (`repositionTransient`) and pinned
(`resizeDetachedSurface`) surfaces, fixing the attachments-first/childless
estimate artifact for both. Convergent: identical frames no-op in `applyFrame`,
republished identical measurements don't retrigger. Test
`testMeasuredChromeRequestsARefitForAnAttachmentsFirstPanel` uses a real hosted
childless/attachments-first panel and asserts the request, its settle, and the
stale-host guard.

**FX8 — VO Open gating (TaskImageAttachments.swift:191-196).**
`accessibilityActions` emits Open only under `canOpen`, Remove always; default
action stays preview. Context menu keeps its disabled Open row. Parity achieved.

**FX9 — external open via disposable copy (TaskImageReference.swift:79-88, 117-127; TaskImageAttachments.swift:104-117).**
`openableCopy` verifies the private copy (tampered/missing → nil → "missing or
changed"), copies it into a fresh `AtticTaskExports/<UUID>/` dir under tmp with
the sanitized name, marks it 0444, and `NSWorkspace.open`s the copy. The private
file is never handed out; originals untouched. Cleanup: the shared
`disposableDirectory()` prunes the exports root's >1-day entries on every use —
same lifecycle as row-drag export folders; pruning a 0444 file inside a
user-writable dir works. Sandbox hand-off is the same class as the previous
private-copy open (container-confined file via Launch Services); live UAT covers
it. Notes was assessed and left alone with a correct rationale (its
materialization is re-derived from the SwiftData payload, so external edits are
overwritten, not fatal) — pre-existing, outside V2, backlog-recorded.
`reportAttachmentOpenFailure` is new and used only for copy-stage failures.

**F1 (latched-panel hover replacement):** unchanged per the root ruling — batch 4
scope. Not re-opened.

## Observations (P3 or below — not blockers)

- **FX6's test is state-equivalent pre/post fix.** With presentation suppressed,
  `presentTransient` no-ops, so the pre-fix code passes the same assertions; the
  actual difference (no snap/re-present, animated switch) is live-only. The test
  still pins the latch-and-switch state contract — just don't mistake it for
  regression coverage of the fix itself. Source inspection is the evidence here.
- **Mark→import handoff gap (pre-existing, parity maintained).** The picker's
  `begin` completion clears `taskAttachmentPickerOwnerID`, then hops a `Task` to
  `attachFiles`, which sets `importingAttachmentTaskIDs`. One runloop beat has
  neither protection; an outside click landing exactly there can dismiss a latched
  panel (or a leave can close a hover one) mid-handoff. Identical gap existed with
  the old shared mark; the import still lands and `attached` re-opens/raises. Note
  for batch-4 lifecycle work, not a new defect.
- **0444 is advisory for atomic-save editors.** A write-temp+rename save succeeds
  because the UUID directory stays writable — the edit lands in a disposable file
  nothing reads back (silently discarded instead of "locked"). The security
  property — the digest-protected private copy is never exposed — is unaffected;
  only the UX hint is partial. Already covered by the ledger's live-UAT item.
- Minor: a failed `copyItem`/`setAttributes` in `openableCopy` leaves an empty
  UUID dir behind — swept by the same next-day prune. `verifiedMaterializedURL`
  still full-hashes per preview/open/drag (unchanged, ledgered).

## Checked and clean

- No remaining caller treats `presentedTaskAttachmentsID` as the picker mark;
  popover set/clear (`syncAttachmentInteraction`, `onDisappear`, `selectSection`,
  `reconcileTaskIDs`) is internally consistent.
- `.taskConfirmation` lock composition unchanged in shape; `familyEditBusy`
  covers both marks for row or child IDs.
- `add-attachment-<id>` identifier unchanged; default state (no picker, no
  import) is enabled, so the compiled UI test's enabled assertion still holds.
- No new files/project inputs (no regeneration needed), no schema/keys/
  entitlements/`ATTIC_LOCAL_ONLY`/signing/store changes, no timers or pollers.
  `TaskDragPayload` (row drag: internal ID, folder export, title) untouched.
- No cosmetic-only blockers; nothing in the delta touches the deferred
  CloudKit/iPhone surface beyond the pre-existing shared `TaskStore` compile
  note (already backlog).

## Still live-only (as ledgered)

FX2 drag to image-only receivers and Finder; FX5/FX6 switch motion and the
hover-opened "Show attachments" path; FX7 first-fit settling; FX3 disabled-state
rendering while the picker is up; FX8 VO action list; FX9 open-in-editor
behavior incl. locked-file prompt and Quick Look having no Markup/editing path
(inspection agrees: presenter is `QLPreviewPanelDataSource` only, no delegate
editing opt-in anywhere in the codebase).
