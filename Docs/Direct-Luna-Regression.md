# Direct Luna Max Regression Review

Date: 2026-09-14
Repository: `/Users/taha/Developer/attic-task-panels-v2`
Branch/HEAD: `codex/attic-task-panels-v2` / `ae6418c1af690e29d15a20344cdb9765a23d3f85`
Review state: dirty worktree; unrelated changes were preserved

## Scope and evidence

I read `AGENTS.md`, `Docs/RollingWork-2026-09-14.md`,
`Docs/Rolling-Reliability-R01-R02-Implementation.md`,
`Docs/Rolling-Performance-A3-Plan.md`, the settled R-01/R-02 source, its
focused tests, the NoteStore callers, and the generated mobile source graph.
This review owns this report only. I made no source or test edits, did not
build, run XCTest, launch the app, use native input, or profile.

The implementation agent reports a successful Local build, 126 focused Notes
tests, and 273 integration tests with two skips and zero failures. Those are
worker-reported results, not independent Luna execution. Earlier bounded pure
probes found no invalid ranges for generated valid edit streams; they do not
cover malformed external input, mobile compilation, AppKit delivery, or
wall-clock, CPU, and memory magnitude.

## Verdict

**CHANGES_REQUIRED.** The settled editor path addresses the original R-01 and
R-02 corruption cases and retains the PERF-A3 one-derivation hoist. The
current worktree still has concrete lifecycle and caller-compatibility gaps:

1. `saveAsNew()` leaves the prior note's ordered edit ledger and
   `NoteEditorSession` in place after creating the new note.
2. The generated iOS target compiles `NoteStore.swift` without the new
   `NoteTextReplacement`/`NoteBodyEditBatch`/`NoteInlineAnchor` source and
   without the macOS-only `storedAttachments` helper used by `update`.
3. `update_note` is still a body-only caller with no `body_edits` contract or
   ambiguity rejection in the current source. Repeated paragraph occurrence
   identity therefore remains unknowable to that public path.
4. Recovery compares body strings with canonical-equivalence `==`, so it can
   discard a canonically equal but different UTF-16 recovery body.

The smallest behavioral persistence fix is to reset the ledger to the newly
created body and start a new editor session after a successful `saveAsNew()`;
the smallest compatibility fix is to make the pure edit types shared and
guard the attachment rebase block for macOS (or provide an equivalent
platform-neutral implementation), then compile the mobile target.

## What R-01/R-02 and PERF-A3 now address

`NoteAttachmentTray.Coordinator` captures pre-coalescing proposed ranges and
replacement strings at `Attic/Views/Panel/NoteAttachmentTray.swift:1479-1507`.
It replays them against the exact prior body and accepts their shape list only
when the replay equals the resulting body by UTF-16. `textDidChange` then
records the ordered list at `:1509-1529`; same-session external replacement
clears it and invalidates the ledger at `:1393-1401`.

`NoteDraftController.flush()` creates a `NoteBodyEditBatch` from the persisted
body to the draft body and passes it to every ordinary body save at
`Attic/Services/NoteDraftController.swift:430-440,459-485`. The batch is
consumed only after success. `NoteStore.update` validates the exact base/result
body and uses the supplied ordered list at
`Attic/Services/NoteStore.swift:216-238`; body-only callers derive one ordered
paragraph list outside the attachment loop and increment the diagnostic seam
once. Every physical note and attachment replica is still written, while
`save()` rolls back and reloads a fresh context after persistence failure
(`NoteStore.swift:755-775`).

The final reported source hashes are:

```text
4264bbe8dc2f9ebb2c9f8cad77534c77cf4ee7d3189f5706158885a0b75d127d  Attic/Models/NoteInlineAnchor.swift
c4536ee2ac22ca0c6fdc3a1cc46cf2742eb0a85e2f906b4a77374bf30c78b09d  Attic/Views/Panel/NoteInlineCards.swift
ac270a4f1c165cebf9b7d184923ec9ece645ca415168c116c9b77c65086f4f6d  Attic/Views/Panel/NoteAttachmentTray.swift
0936d8a0a3850ab96b1a7c9e4e80843e9a4e9a0a0df6445b8b1b9afda3a0e17a  Attic/Services/NoteStore.swift
53cd6296c949d5fe86a8b0c904099e2a2eff54ffcd90f1635180b802e1c171d2  Attic/Services/NoteDraftController.swift
d9606e2acae7d14fc64a1a519d427a285567b354c2b22a9b1c2c181cef71f37f  Attic/Views/Panel/NotesPanelContent.swift
a07e71b6a576d7c2a5bccf847a5023c597f1193cbd96a09136a6d6f5fbf70103  AtticTests/NoteInlineCardsTests.swift
b2892c16bdeaf699c876fa4c6a49286026e26197fc7602f327115c8f4964be0f  AtticTests/NoteDraftControllerTests.swift
```

## REG-01: repeated paragraph identity is fixed for editor-originated saves

The original reproduction was:

```text
old body:       "A\nA\nB"
attachment:     inlineOffset = 2  // second A
editor action:   insert "A\n" at UTF-16 location 0
new body:       "A\nA\nA\nB"
exact edit:     (location: 0, oldLength: 0, newLength: 2)
```

The body-only `CollectionDifference` can choose the repeated occurrence at
the end and emit `(4,0,2)`, leaving the old anchor at 2. The editor batch maps
the same anchor to 4, the start of the surviving second paragraph. The current
draft-to-store channel and the duplicate physical-replica test cover this
editor-originated case. A failed-save retry retains the batch in the current
draft path.

## REG-02: `saveAsNew()` retains stale edit history and session identity

Affected code: `Attic/Services/NoteDraftController.swift:583-599`.
After `noteStore.create` succeeds, the method assigns `activeNoteID`,
`lastEditedNoteID`, and the persisted snapshot directly, but never calls
`bodyEditLedger.reset(to: body)` and never creates a new `NoteEditorSession`.
`applySnapshot` at `:707-742` is the existing path that performs both reset and
session generation.

Reproduction:

```text
1. Edit note 1, body "A\nA\nB", with an exact insertion "A\n" at offset 0.
2. Delete note 1 remotely; reconcile, leaving the dirty draft and its pending
   ordered batch.
3. Call saveAsNew(); note 2 is created with "A\nA\nA\nB".
4. Add an inline card to note 2 and make the next body edit.
```

The ledger still has note 1's anchor body and pending insertion. The next
`batch(from: note2.body, to: ...)` fails the old-body identity check and falls
back to an ambiguous body-only paragraph diff. With repeated paragraphs, the
new card can be rebased to the wrong occurrence. The unchanged session also
allows callbacks carrying note 1's `NoteEditorSession` to compare as current
after `activeNoteID` has become note 2. Expected behavior is a fresh session
for note 2 and an empty ledger anchored at note 2's exact body.

The existing `testSaveAsNewRecoversDraftAfterRemoteDeletion` at
`AtticTests/NoteDraftControllerTests.swift:920-941` checks only the new ID,
body, active ID, and cleared conflict. It does not exercise a subsequent
inline-anchor edit or session fencing.

## REG-03: recovery uses canonical equality where persistence uses UTF-16

`Attic/Services/NoteDraftController.swift:246-249` currently tests
`existing.body == saved.body`. Swift string equality treats decomposed
`"e\\u{301}"` and precomposed `"é"` as equal, while their UTF-16 lengths
differ. The rest of the settled anchor path deliberately uses
`NoteTextReplacement.utf16Equal`.

Reproduction: persist an existing body `"é\nA"`, then load a recovery snapshot
whose exact body is `"e\\u{301}\nA"` for that note. The recovery branch treats
the bodies as identical, applies the existing precomposed body, and clears the
recovery copy. Expected behavior is to preserve the exact recovery body and
take the existing remote-change/conflict path when the UTF-16 bodies differ.
Add a recovery test with these two bodies and use the exact equality helper in
the comparison.

## REG-04: current AgentTaskTools caller still has no occurrence-safe contract

`Attic/Services/AgentServer/AgentTaskTools.swift:193-214,391-414` exposes and
implements `update_note` with only `id`, `title`, and `body`; it calls
`noteStore.update(note, title: newTitle, body: newBody)` without a batch. The
same final body can result from inserting an identical paragraph at either end
of a repeated run, so no fallback algorithm can infer the intended physical
occurrence. A body-only update with inline anchors can therefore persist a
valid but wrong anchor. The current file hash is
`a8f516e72d530049764856dd58e93b902f97508f626f05580fec806f50816b61` and has
no `body_edits` property or parser.

If body-only ambiguity is an accepted API limitation, it must be stated in the
tool contract and tested as such. Sol's announced follow-up is a reasonable
bounded direction: accept optional replacement strings only after replaying
them against the exact source body, and reject ambiguous body-only updates
only when inline anchors make the ambiguity consequential. Before accepting
that follow-up, verify that rejection mutates nothing, sets a fresh
`lastErrorMessage`, preserves legacy title-only/body-without-anchor paths, and
accepts exact UTF-16 ranges. Bound the edit count and each range/replacement
length before arithmetic; `NoteTextReplacement.validates` at
`Attic/Models/NoteInlineAnchor.swift:31-43` can otherwise overflow on hostile
large integer input before a public parser has constrained it.

## REG-05: the generated mobile target is not caller-compatible with the new
signature

`Scripts/generate_project.rb:78-110` adds `Services/NoteStore.swift` to the
`AtticMobile` target, but does not add `Models/NoteInlineAnchor.swift`. The
generated mobile Sources phase confirms that only `NoteStore.swift` from this
feature is shared; `NoteInlineAnchor.swift` is in the macOS Attic source phase.
Meanwhile, unguarded `NoteStore.swift:210,218,226-237` references
`NoteTextReplacement`, `NoteBodyEditBatch`, `NoteInlineAnchor`, and
`storedAttachments(forNoteID:)`. The latter is declared only under
`#if os(macOS)` at `NoteStore.swift:916-945`.

Thus the reported macOS `AtticTests` build does not establish that
`AtticMobile` or `AtticMobileTests` compile. The smallest safe resolution is
to put the pure edit/batch types in a source shared with mobile and guard the
attachment-specific rebase/fetch on macOS, or provide a platform-neutral
attachment store implementation. Then run the mobile compile/test target.
Do not silently remove the fourth macOS argument from the editor path or
restore the old single-span semantics.

## Persistence, replicas, undo, bounds, and work shape

`NoteStore.update` still fetches all physical attachment rows by note ID and
rebases every inline row through one ordered description. The existing direct
duplicate test verifies both rows on a successful save, and the retry test
verifies one row across rollback/retry. There is no focused test combining two
physical attachment rows with a forced failed save and a fresh-context check
of both original offsets. Add that test before calling replica rollback fully
covered.

The ordered rebase is constant arithmetic per edit and `paragraphStart` clamps
to the UTF-16 body length. `paragraphRanges` advances through nonempty
`NSString` paragraph ranges, and the combined paragraph count is bounded at
8192 (`NoteInlineAnchor.swift:72-93,152-162`). The bound limits paragraph-array
work, but a single very long paragraph still causes whole-body UTF-16 arrays;
no magnitude or memory claim is made. Pending edit arrays also grow with the
number of edits retained through a dirty or failed draft. That is a residual
design cost, not a measured regression.

The focused source tests now cover canonical normalization, grouped
pre-coalescing proposals, duplicate physical rows, exact-batch retry, ordered
disjoint edits, undo, editor switching, and remote replacement
(`AtticTests/NoteInlineCardsTests.swift:84-225,363-454`). Missing coverage is
the `saveAsNew` transition, exact recovery normalization, mobile compilation,
public `body_edits` validation/rejection, and duplicate-replica rollback.

## Validation limits and report integrity

No visual, accessibility, installed-preview, CloudKit, iPhone, production, or
performance-magnitude result is claimed. The worker's reported build/test
results remain external evidence until independently rerun. No files outside
`Docs/Direct-Luna-Regression.md` were edited by this review; nothing was
staged, committed, or pushed.

CHANGES_REQUIRED
