# Task panel V2 — batch 2 fix-delta independent review (SWE-B)

Reviewer scope: the batch-2 review-fix delta — primary focus on the picker/popover
lock split, disabled affordance parity, live-window animation-target lifecycle,
slide direction, chrome-measurement height refit, animated deliberate view switch,
and accessibility; all other fixes checked for obvious errors. Delta reviewed:
`.build/batch2-fixes.diff` (sha256 `ab536c17…`, 14 files) against prefix tree
`11ad5b5cd293f65cdb7946a374031c880729c402`; verified `GIT_INDEX_FILE=.build/
batch2-fixes/prefix.index git diff` against the worktree reproduces the diff's
file set exactly — current sources are the reviewed ones. Prior findings per
`Docs/TaskPanelV2Batch2SWE-A.md` / `TaskPanelV2Batch2SWE-B.md`; ledger narrative
cross-checked against real code, not taken on faith.

## Verdict

**Approved.** All nine fixes (FX1–FX9) are correctly implemented, address the
reported root causes, and introduce no P0–P2 defect I can find in source. The SWE-B
findings F2–F5 are fixed; F1 is deliberately untouched per the root ruling (batch
4 scope) — verified unchanged at `SubtaskPanelLayout.swift:433-449` (the
pending-open arm still ignores `isTransientLatched`), so the ruling is honored, not
silently reopened. No regressions found in callers, lock composition, rollback, or
the shared Notes import path. Build/test claims verified against logs (below).

## Per-fix verification

**FX1 — `includePayload` split** (`AttachmentFileStore.swift:64-85`, `:432`;
`NoteAttachment.swift:88`). Correct. The original signature forwards
`includePayload: true`, so the `NoteAttachmentFileImporting` protocol and both
NoteStore call sites (`NoteStore.swift:343`, `:597`) keep payload behavior.
`ImportedAttachment.payload` → `Data?`; its only consumer (`NoteStore.swift:421`)
feeds `NoteAttachment(payload: Data?)` — source-compatible. Task path validates
each image-typed reference from its just-written private copy via
`materializedURL` + `decodesAsImage` (`TaskImageReference.swift:49-66`) — same
predicate as `CreateWithData` + `GetCount>0` (equivalence evidence in
`.build/batch2-fixes/imageio-equivalence.txt` covers 8 edge inputs and matches).
Rollback unchanged: first failure removes the whole batch (`remove(references)`)
and the actor's per-batch `finalDirectories` rollback is untouched. Memory claim
holds: no `Data(contentsOf:)` on the task path.

**FX2 — drag type** (`TaskDragPayload.swift:15-47`, `TaskImageAttachments.swift:
213-217`). Correct. `NSItemProvider` registers one file representation under the
attachment's recorded type with `.data` fallback; `suggestedName` uses the stored
(sanitized) filename. `fileOptions: []` omits `.openInPlace`, so receivers are
copied — verified by `drag-type-control.txt` and
`testAttachmentDragPromisesItsRecordedTypeAndHandsOutACopy` (loaded URL ≠ private
URL, bytes equal). Verified URL resolves lazily inside the load — nothing copied
on layout. `TaskAttachmentDragItem` dropped `Transferable`; grep confirms no
remaining `Transferable`/`dropDestination` dependency on it. The unrelated task-row
drag payload is untouched.

**FX3 — picker/popover lock split** (`PanelUIState.swift:45-51,71-72`,
`TaskImageAttachments.swift:55-91`, `SubtaskPanelController.swift:379-390`,
`TaskRowView.swift:110-114,387,425-428`, `SubtaskPanelContent.swift:471`).
Correct and complete. `taskAttachmentPickerOwnerID` is written only by `choose`
and cleared only by its completion (grep: no other writers). The popover mark
`presentedTaskAttachmentsID` can no longer overwrite it — protection theft and
the dead-click are both gone. `isAvailable` is the single gate for both
affordances (row menu + panel footer) and `choose`'s guard, so an offered click
is never ignored. `familyEditBusy` covers the picker owner (always the top-level
family ID, so `belongsToFamily` matches directly); `.taskConfirmation` locks the
main panel while the picker is up; outside clicks on the `NSOpenPanel` itself
fall through to the `familyEditBusy` early-return at `SubtaskPanelController.swift:
1096`. `selectSection`/`reconcileTaskIDs` deliberately leave the mark (picker is
genuinely up); a deleted owner during pick degrades to `attachFiles` → false →
no callback, mark still cleared by completion. Covered by
`testPickerAndChildPopoverKeepSeparateMarksAndNeitherSilentlyBlocks`.

**FX4 — `SurfaceFrameAnimationTargets`** (`SubtaskPanelController.swift:976-1031`,
`:1155-1188`). Correct. Weak owner + `===` identity check on lookup means a window
closed mid-animation can never hand its `ObjectIdentifier` (address reuse) to a
new surface; mismatched entries drop on read and dead entries prune on `set`.
Same-live-window entries stay honored — correct, since `presentTransient` always
calls `stopFrameAnimation` before re-presenting and `resizeDetachedSurface`
prefers the in-flight target over `surface.frame`. The unpin path reuses the
window object itself, so a legit in-flight target remains valid there.
`clear(for:)` on a reused identifier removing a stale entry is also correct.
Covered by `testFrameAnimationTargetsBelongToTheirLiveSurfaceOnly`.

**FX5 — slide direction** (`SubtaskPanelLayout.swift:184-189`,
`SubtaskPanelContent.swift:388-394`). Correct. Symmetric `.offset(x:)` animates
removal *to* the same offset as insertion *from*, so each view exits toward its
own side (Subtasks −18, Attachments +18) — both layers page one direction,
matching the documented spatial model and SWE-A's suggested fix. Reduce Motion
still returns `.opacity`. Covered by `testViewSwitchPagesBothLayersTheSameWay`.

**FX6 — animated switch on hover-opened family** (`SubtaskPanelController.swift:
515-538`). Correct. `alreadyPresented` is computed *before* `openTransient`
mutates the lifecycle, so the hover→explicit latch returns true and takes the
raise path: `syncState()` arms outside-click monitoring (required by the new
latch), `openTransient`'s pending-close clear prevents a stale leave from closing
the just-latched surface, and `showPanelView` routes the switch through
`withAnimation` + deferred `refreshSurfaceSizes` — no `panelViews.set` outside
animation, no `presentTransient`/`stopFrameAnimation` snap. A detached (explicit)
transient keeps `isTransientDetached` (openTransient returns false → same raise
path). If lifecycle says open but the window isn't visible, `alreadyPresented` is
false and the fresh-open path re-presents — correct fallback. Covered by
`testExplicitViewRequestOnAHoverOpenedFamilySwitchesInPlaceAndLatches`.

**FX7 — chrome refit** (`SubtaskPanelContent.swift:148-154`,
`SubtaskPanelController.swift:774-781`). Correct. >0.5 pt delta gate prevents
no-change republishes from re-fitting; `isLiveSurface(for:mode:)` gates out stale
hosts after pin/unpin/family swaps; next-turn `refreshSurfaceSizes` matches the
`noteMeasuredListHeight` pattern so the refit reads post-layout `fittingSize`. No
feedback loop: unchanged measurements re-request nothing, and `applyFrame`/`pinnedResizedFrame` no-op on identical frames. Attachments-first and childless
panels now get their correcting fit. Covered by
`testMeasuredChromeRequestsARefitForAnAttachmentsFirstPanel`, including the
stale-host and settled-layout cases.

**FX8 — conditional VoiceOver "Open"** (`TaskImageAttachments.swift:191-196`).
Correct. `.accessibilityActions` builder emits "Open" only when `canOpen`;
"Remove" always; the `.accessibilityAction(.default, preview)` and the context
menu's visibly-disabled Open are unchanged. Identifier `task-attachment-<id>`
unchanged.

**FX9 — disposable read-only open copy** (`TaskImageReference.swift:74-88`,
`TaskAttachmentActions.open` `:104-117`, `TaskStore.swift:181-183`). Correct for
tasks. `openableCopy` verifies the private copy, copies it into a fresh
`AtticTaskExports/<UUID>/` dir (shared day-pruned disposable root via
`disposableDirectory()`, extracted cleanly from `export`), keeps the sanitized
name, and chmods 0444. Verify failure → nil → `reportUnavailableAttachment`; copy
failure → `reportAttachmentOpenFailure` — distinct messages, both surfacing
through the panel error row. Private copy never leaves for writing; user
originals untouched. Notes' Open deliberately unchanged (payload re-derives on
verify failure — the attachment survives external edits there; backlogged).
Covered by `testOpenHandsOutADisposableReadOnlyCopyAndThePrivateCopyStaysVerified`.

## Regression checks

- **Callers/all-sites consistency:** every writer/reader of both marks audited
  by grep; `selectSection` clears the popover mark but not the picker mark —
  matches the comment and the real picker lifetime. `AtticUITests` still finds
  `add-attachment-<id>` (`AtticUITests.swift:488`) — unchanged identifier,
  enabled in the default state the test exercises.
- **Shared mobile surface:** `shared_mobile_sources` compiles `TaskStore.swift` /
  `NoteStore.swift` but not `TaskRowView.swift`, `TaskImageAttachments.swift`, or
  `AttachmentFileStore.swift` (`Scripts/generate_project.rb:78-111`) — the new
  `isAvailable`/`TaskAttachmentPicker` references add nothing to the mobile
  target; `TaskStore`'s additions reference no new types. The pre-existing
  broken surface is unchanged; still an iPhone-re-enablement backlog item.
- **Lock composition:** `.taskConfirmation` now also covers the picker —
  semantically a name stretch but mechanically identical (previously the picker
  already locked via the shared mark). `CornerHoverStateMachineTests` (13) still
  passes.
- **Diff fidelity:** prefix-index diff against the worktree yields exactly the 14
  diff files plus a 3-line orchestrator bookkeeping update; `sha256` matches
  `diffs.txt`.

## Observations (non-blocking)

- `openableCopy`'s 0444 is advisory, not enforcement: the temp *directory* stays
  user-writable, so an atomic-save editor (write-temp + rename) can still replace
  the copy and its save will silently succeed on the disposable file. Edits still
  never reach Attic either way — the read-only bit just makes the common
  non-atomic path surface a locked-file prompt. Acceptable as designed; worth a
  line in live UAT notes.
- `openableCopy` swallows all `verifiedMaterializedURL` errors into "missing or
  changed" — a transient I/O error reads as tamper. Same semantics as the
  existing preview path; consistent.
- While the picker is up for family A, a hover dwell on family B defers via
  `shouldDeferPointerClose` → `familyEditBusy(A)` and matures after the picker
  completes — correct, and arguably the desired browsing behavior.
- `chromeRefitRequestCount` is a production property existing purely as a test
  seam (`private(set)`, documented). Fine; flag only if the codebase objects to
  test-only counters.
- Picker completing after its family's surface closed (e.g. main-panel hide mid-
  pick): the footer path's `showPanelView` no-ops and the row path's
  `openFamilyPanel` returns on `!mainPanelVisible` — attachments still import;
  user re-opens normally. Consistent with pre-fix behavior.

## Evidence

- Full source read of all 13 changed source/test files plus callers:
  `SubtaskPanelController.swift` (whole file), `SubtaskPanelContent.swift`,
  `TaskImageAttachments.swift`, `TaskRowView.swift`, `TaskImageReference.swift`,
  `TaskDragPayload.swift`, `AttachmentFileStore.swift`, `PanelUIState.swift`,
  `SubtaskPanelLayout.swift` (incl. `SubtaskPanelLifecycle`), `TaskStore.swift`,
  `NoteAttachment.swift`, `NoteStore.swift:343-444`, `Scripts/generate_project.rb`.
- Logs verified, not re-run: `build-local-1.log` ends `** BUILD SUCCEEDED **`;
  `unit-focused-1.log` reports 181 executed / 0 failures (22+43+64+39+13),
  `** TEST SUCCEEDED **` — matches Opus's claim.
- Diff provenance: `shasum -a 256` on `batch2-fixes.diff` matches `diffs.txt`;
  prefix-index-vs-worktree diff reproduces the published file set.
- No source, test, or other report modified; no UI driven; no user data touched.

## Unverified — live-only items carried forward

- FX2: real drop targets (image-only receivers, Finder), `.onDrag` preview parity,
  click-vs-drag disambiguation.
- FX5/FX6: paging reads as one direction; "Show attachments" on a hover-opened
  panel animates instead of snapping.
- FX7: Attachments-first/childless opens settle without a visible second jump.
- FX3: both Add-attachment affordances visibly disabled while a picker is up;
  panels survive under the picker when a child popover opens elsewhere.
- FX8: VoiceOver rotor shows Open only for openable types.
- FX9: Open launches the editor on the read-only copy; locked-file prompt tone;
  attachment still previews afterward.
