# Direct Luna correctness re-review: R-01/R-02

Date: 2026-09-14
Checkout: /Users/taha/Developer/attic-task-panels-v2
Branch: codex/attic-task-panels-v2, committed HEAD ae6418c with the current dirty candidate
Scope: re-review of the settled R-01/R-02 source and tests after the implementation fixes. Source was read-only; no native build, app launch, persistence store, or user data was modified. Small isolated UTF-16 probes were run outside the checkout.

## Verdict

**REVIEW_PASS**

The bounded editor and persistence path now carries an ordered edit batch from the pre-coalescing text-view callback through the draft into NoteStore, validates the proposed replacement strings by replaying them against the exact pre-change body, compares bodies and paragraph units by UTF-16, and resets the ledger only after a successful save. The original R-01 and R-02 corruption cases therefore pass on the current source.

One body-only API limitation remains by construction: a final body cannot identify which occurrence of a duplicated paragraph was edited. The current fallback makes a deterministic paragraph-diff choice and preserves a valid attachment row; callers that know the edit intent use the explicit batch. This is recorded below as an inherent ambiguity, not a source defect.

## Re-reviewed fixes

### Ordered edits and AppKit callback handling

`Attic/Views/Panel/NoteAttachmentTray.swift:1292-1307,1479-1523` keeps the proposed ranges and replacement strings before NSTextStorage can coalesce a grouped transaction. It sorts multi-range proposals from the end of the pre-edit body, replays them against `parent.text`, and chooses their exact UTF-16 shapes only when that replay reproduces `textView.string` exactly. If the proposal is unavailable or does not reproduce the result, the coordinator uses the storage callback list and the ledger's conservative validation path. External synchronization clears both pending lists and resets or invalidates the ledger as appropriate (`:1373-1408`).

This addresses the earlier grouped-callback probe: AppKit can report two inserts as one union callback (`range={3,17}`, `changeInLength=2`), which would otherwise become `(3,15,17)` and map old anchor 8 to 0. The exact proposed shapes `(18,0,1)` then `(3,0,1)` map that anchor to 9. The current `proposedEditsProduce` replay also prevents a stale or mismatched proposed list from being accepted as exact.

The focused test `testGroupedTextStorageTransactionUsesPreCoalescingEdits` (`AtticTests/NoteInlineCardsTests.swift:363-408`) exercises this coordinator path with a grouped NSTextStorage transaction and asserts the ordered shapes and anchor result.

### UTF-16 and grapheme-sensitive bodies

`Attic/Models/NoteInlineAnchor.swift:27-29,87-107` uses exact UTF-16 equality and diffs arrays of UTF-16 units for paragraph identity. `NoteInlineAnchor.moved` and `NoteBodyEditLedger` use the same equality rule (`NoteInlineAnchor.swift:176-180`; `Attic/Views/Panel/NoteInlineCards.swift:301-314`). This fixes the prior canonical-equivalence failure where decomposed `e + combining acute` and precomposed `é` compared equal as Swift Strings despite lengths 4 and 3.

The current pure probe produces one replacement at `(0,3,2)` and maps the old `A` paragraph start 3 to 2. A deterministic 100,000-case probe over ASCII, emoji/surrogate pairs, decomposed and precomposed forms, empty paragraphs, trailing newlines, insertions, and deletions found no invalid ordered range or final-length result.

### Draft, store, replicas, and retry

`NoteDraftController.flush` creates one `NoteBodyEditBatch` from the persisted body to the draft body and passes it to every body save (`Attic/Services/NoteDraftController.swift:430-440,459-485`). `NoteStore.update` validates the exact UTF-16 base/result pair, uses the supplied list when valid, computes it once per save, and applies it to every fetched physical attachment replica (`Attic/Services/NoteStore.swift:190-252`). The draft resets its ledger only after `update` succeeds. A failed save leaves the draft, exact batch, and attachment offsets intact for retry (`NoteDraftController.swift:430-444`; `NoteInlineCardsTests.swift:187-225`).

The duplicate test `testExactDuplicateParagraphBatchPersistsEveryAttachmentReplica` (`NoteInlineCardsTests.swift:146-185`) supplies insertion at old offset 0 for `A\nA\nB -> A\nA\nA\nB` and verifies both physical rows receive offset 4. The retry test verifies the failed attempt retains offset 2 and the successful retry applies offset 4. Session changes and remote replacement reset stale ledger state (`NoteInlineCardsTests.swift:428-454`).

## Accepted bounded limitations

### Body-only duplicate occurrence ambiguity

`NoteTextReplacement.edits` still deterministically derives `(location:4, oldLength:0, newLength:2)` for `A\nA\nB -> A\nA\nA\nB`. An insertion of the same `A\n` at old offset 0 requires old anchors `[0,2,4]` to map to `[2,4,6]`; inserting it at old offset 4 produces the same final body but a different required history. The final body alone cannot distinguish those histories.

`Attic/Services/AgentServer/AgentTaskTools.swift:391-414` is a body-only writer and therefore uses this documented fallback through `NoteStore.update`. The fallback keeps the attachment persisted at a valid paragraph boundary and is deterministic. When edit intent is available, the editor path carries `NoteBodyEditBatch`; no current code path can infer the missing physical occurrence from body text alone. Requiring the fallback to guess old offset 0 would be an impossible inference, so this is not a correctness failure for the stated API contract.

### Large-document fallback

`NoteTextReplacement.maxDiffedParagraphs` remains 8192 (`Attic/Models/NoteInlineAnchor.swift:72-75`). Beyond the bound, `edits(from:to:)` deliberately returns one UTF-16 prefix/suffix replacement. A current pure probe with 8194 paragraphs returns one edit whose accumulated final length exactly equals the destination. That fallback can collapse an unchanged paragraph between two body-only changes, just as the implementation document states; an editor-originated exact batch avoids it. No change is required for the bounded R-01/R-02 contract, but the limit remains a documented tradeoff.

### Storage-only callback fallback

A direct grouped NSTextStorage mutation without a preceding text-view proposal still exposes only the union callback, so the fallback cannot recover the hidden sub-edit boundaries. In the current editor, pre-coalescing proposals are captured; external text assignments are guarded by `isApplyingExternalText` and force a re-diff. The implementation's focused test covers the exact proposal path. The remaining storage-only behavior is therefore treated as the conservative fallback boundary rather than evidence that the exact editor path is unsound.

## Test parity and validation limits

The new source tests cover canonical normalization, grouped transaction handling through the coordinator seam, exact duplicate physical replicas, failed-save retry, session reset, ordered disjoint edits, and existing deletion/boundary behavior (`NoteInlineCardsTests.swift:84-225,363-454`). The large-note test remains below the 8192 cutoff, so the cutoff was checked with the isolated pure probe rather than an XCTest run.

The implementation agent reports 126 focused Notes tests and 273 integration tests with two skips and zero failures. I did not independently run Xcode or native tests under the requested read-only review scope. The independent pure checks completed here were the duplicate/Unicode/large-fallback examples and the 100,000-case UTF-16 ordered-range invariant fuzz. No visual, accessibility, live preview, CloudKit, or production claim is made.

REVIEW_PASS
