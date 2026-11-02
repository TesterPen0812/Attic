# Stage 2 iPhone note history — independent audit

**Baseline:** `iphone/build-history-audit` at `a6eb07669ae2735e80bdc8ecf04c5ee12aba0363`.
**Scope:** `AtticMobile/Core/PhoneNoteHistory.swift`, `AtticMobileTests/PhoneNoteHistoryTests.swift`, and read-only comparison with the Mac's `NoteStore+Documents.swift`, `WorkspaceRestoreNormalization.swift`, `NoteVersion.swift`, `TaskNotePageSnapshot` and history browser tests. No product changes.

## Confirmed safety gap — divergent circle-removal preservation copies can authorize restore

**Source:** Phone `PhoneNoteHistory.swift:290-300` fetches all physical `TaskDeletionPreservation` rows sharing the selected preservation UUID, but accepts them when only `snapshot`, `rootID`, `provenance` and `purgedAt` match. A member may disagree on `deletedAt`, `capturedAt`, `retiredAt`, or `dependencyOwnersData`. The Mac's circle-removal path, `WorkspaceRestoreNormalization.swift:17-29`, compares the **complete** physical fields via `WorkspaceModelFields.read` before rewriting historical task-note content; `WorkspaceModelToken.swift:422-433` includes these omitted lifecycle fields.

**Reproducer (synthetic SwiftData, no owner data):** Open a live ordinary note with a detached `TaskNoteAssociation` pointing to a circle-removed task's preserved ID. Store two `TaskDeletionPreservation` replicas with that UUID, identical snapshot/root/provenance/purge timestamp, but one has `retiredAt == nil` and the other `retiredAt != nil`. Add a historical `NoteVersion` containing `requires: ["taskNote"]`; load it and restore. Mac rejects the inconsistent recovery family. The phone's check admits it, uses the arbitrary first preservation, and proceeds to insert a before-restore checkpoint and change the note revision/content. Under ambiguous lifecycle ownership this should fail without any write.

**Required fix (product owner, outside this audit's write scope):** Before normalization, validate the entire preservation UUID family, including `id`, `rootID`, `deletedAt`, `capturedAt`, `provenance`, `snapshot`, `purgedAt`, `retiredAt` and `dependencyOwnersData`; refuse with `.mixedOwner` if any copies diverge. Apply the same conservative family admission to the soft-deletion branch if its lineage cannot be proven. Keep the comparison and writing in one transaction. Do not rebuild a payload from history display fields.

**Regression:** `testCircleRemovedRestoreRejectsConflictingPreservationLifecycleCopies` added to `PhoneNoteHistoryTests.swift`. It is **expected to fail on the audited product code** (not executed under the no-build instruction); passing requires rejecting the restore and leaving both the note and version count unchanged.

## Smaller Mac parity issue — stale live-note deletion manifest

`NoteItem.deletedAttachmentIDsRaw` is specified to be nil for a live note (`NoteItem.swift:19-26`). Mac history restore explicitly clears the field on every restored replica (`NoteStore+Documents.swift:1170-1183`); phone restore (`PhoneNoteHistory.swift:112-123`) leaves a pre-existing non-nil value intact. A synthetic live row with an obsolete deletion manifest therefore remains in an invalid lifecycle state after a successful phone restore. This is a definite state/parity discrepancy; no immediate payload loss is proven because normal deletion rewrites the manifest. Proposed fix: clear this field on all physical heads in the successful restore transaction after admission, consistent with the Mac. No regression test added for this lower-risk case.

## Checks supported by source and existing tests

- Opening retains immutable byte snapshots, including legacy nil fingerprints; checkpointing does not mutate live content or derive bytes from title/body.
- Restore re-fetches physical note/version/association families; rejects stale or deleted heads, different revision IDs, changed version tickets, unknown/future document formats, and ambiguous version copies. It refuses a revision overflow.
- Existing `testRestorePreservesOriginalAndAllReplicasMetadataAndOnlyReconcilesAttachmentVisibility` covers original historical bytes, a before-restore snapshot, all note replicas and pre-existing attachment payload preservation. Missing attachment objects remain document placements.
- For live task notes, historical task fields are not applied; the current task's head/subtasks are used. Historical rewriting requires a byte-exact codec round-trip and is rejected otherwise. Proposals are read-only on phone and remain unchanged on restore.
- The Mac calls `thinVersions` after `recordVersion`; the phone's `checkpoint` has no retention pass. This is a storage-growth parity gap to resolve when checkpoint scheduling is integrated; thinning must preserve rich versions, proposals, recovery bases and complete physical UUID families per the Mac policy. No existing phone production caller of `PhoneNoteHistory` was found beyond its tests.

## Verification boundary

Read-only source inspection, targeted test authored, and Git diff hygiene only. **No xcodebuild, Swift test run, Simulator, Air job, Mac UI, signing, device or real sync was run.** The new regression is intentionally unverified and expected to fail until product code is fixed. The existing test suite's runtime result and iPhone UI integration remain unverified. No files under `ref/` were modified.
