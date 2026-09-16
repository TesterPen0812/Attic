# Rolling Reliability R-01/R-02 Implementation

Date: 2026-09-14
Branch: `codex/attic-task-panels-v2` @ `ae6418c` (unchanged during work)
Scope: confirmed defects **R-01** (persisted-save inline-attachment anchor
corruption) and **R-02** (dirty-draft anchor corruption via lossy edit
composition), per `Docs/Rolling-Reliability-Audit.md`. The no-swipe change's
six files were not touched.

## Changed files (exact)

| File | Delta vs pre-edit snapshot |
|---|---|
| `Attic/Models/NoteInlineAnchor.swift` | Removed `unchanged(length:)`, `composing(_:)`, and the single-replacement `moved(_:by:in:)` overload (no callers remain); added `maxDiffedParagraphs` (8192), `edits(from:to:)` (ordered paragraph-granular diff), `paragraphRanges(in:)`; `moved(_:from:to:)` now rebases through the ordered list; added `moved(_:by:[NoteTextReplacement],in:)` |
| `Attic/Views/Panel/NoteInlineCards.swift` | `NoteBodyEditLedger` stores `pendingEdits: [NoteTextReplacement]` (was one composed `pending`); `record(_:resulting:)` gains an ordered-list overload that validates every edit against the running intermediate length plus the final UTF-16 length; `replacement(from:to:)` renamed to `edits(from:to:)` returning the ordered list (recorded stream when it matches, derived diff otherwise); `NoteInlineCardResolver.resolve` folds anchors through the list |
| `Attic/Views/Panel/NoteAttachmentTray.swift` | `Coordinator.pendingStorageEdits: [NoteTextReplacement]` (was one composed `pendingStorageEdit`); each `.editedCharacters` callback appends; `textDidChange` records the ordered batch; external text replacement clears the list and invalidates the ledger; the tray's ledger-free fallback now derives `edits(from:to:)` instead of one `diffing` span |
| `Attic/Services/NoteStore.swift` | `update` computes `NoteTextReplacement.edits(from: note.body, to: destinationBody)` once when any stored attachment is inline, and rebases every `inlineOffset` through the ordered list (was one `moved(_:from:to:)` per attachment, i.e. one spanning diff per attachment) |
| `AtticTests/NoteInlineCardsTests.swift` | Added 2 tests to `NoteInlineCardsTests`, 3 to `NoteInlineCardsPerformanceTests`; rewrote `testRecordedEditsRebaseAnchorsLikeAWholeBodyDiff` as `testRecordedEditsRebaseAnchorsExactlyInOrder`; updated 4 tests to the list API |
| `Docs/Rolling-Reliability-R01-R02-Implementation.md` | This report |

`NoteInlineAnchor.swift`, `NoteInlineCards.swift`, and
`NoteInlineCardsTests.swift` are untracked at HEAD (created during the current
rolling batch); `NoteStore.swift` and `NoteAttachmentTray.swift` were already
modified before this task — pre-edit snapshots for all five sit at
`/tmp/attic-r01r02-baseline/` (SHA-256 recorded before the first edit), and
diffs against that baseline contain only the changes described above.

## Before / after algorithm

**R-01 (persisted save).** Before: `NoteStore.update` rebased each stored
`inlineOffset` through `NoteInlineAnchor.moved(offset, from: old, to: new)`,
which built one `NoteTextReplacement.diffing` span from the first to the last
differing UTF-16 unit. Disjoint edits flanking an unchanged attachment
paragraph put the paragraph inside the replaced span, so the anchor collapsed
to the diff start and snapped to the first edited paragraph. Reproduced
verbatim in `/tmp/attic-r01r02-verify-old.swift`: body
`"one\ntwo\nthree\nfour"`, anchor 8 (`"three"`), save to
`"one!\ntwo\nthree\nfour!"` → stored offset **0** (correct: **9**).

After: `edits(from:to:)` diffs the two bodies at paragraph granularity
(`CollectionDifference` over `NSString` paragraph ranges — the same boundaries
`paragraphStart` snaps to), coalescing only *adjacent* changed runs into one
replacement. Unchanged paragraphs stay outside every replaced span, so
`moved(offset, by: edits, in:)` folds the anchor through each real change in
order and lands on the surviving paragraph. Paragraph count is bounded by
`maxDiffedParagraphs` (8192); beyond that the bounded `diffing` single span is
the documented fallback. The diff is computed once per save, not once per
attachment.

**R-02 (dirty draft).** Before: `composing(_:)` merged disjoint edits into one
enclosing replacement — `Coordinator` composed every `.editedCharacters`
event, `NoteBodyEditLedger` composed again per `textDidChange` batch.
Audited counterexample reproduced verbatim: body length 30, inserts
(10,0,5) then (30,0,5) compose to **(10,15,25)**; anchor 12 should rebase to
**17** but the composed span collapses it (paragraphStart → **0**).

After: no composition exists anywhere. The coordinator appends each real
`NSTextStorage` edit to `pendingStorageEdits` in callback order;
`textDidChange` hands the ordered batch to the ledger. The ledger keeps the
concatenated ordered history (`pendingEdits`), validates each edit's
`location + oldLength` against the running intermediate length and the batch's
final length against `text.utf16.count`, and invalidates to the diff path on
any disagreement (or on external replacement). `resolve` and the tray
fallback both rebase through ordered lists.

Single-edit behavior is unchanged (a one-element list), `paragraphStart`
snapping is unchanged, and a save with no inline attachments still skips the
diff entirely.

## Regression coverage added

`AtticTests/NoteInlineCardsTests.swift`:

- `testOneSaveWithEditsOnBothSidesKeepsTheCardOnItsParagraph` (R-01):
  real `NoteStore` + SwiftData — place a card at offset 8 on `"three"` in
  `"one\ntwo\nthree\nfour"`, one `update` to `"one!\ntwo\nthree\nfour!"`,
  assert the persisted `inlineOffset` is **9** (the surviving paragraph's new
  start), seen through a fresh `NoteStore`.
- `testDisjointEditsAroundAParagraphKeepItsAnchor` (R-01): pure anchor math
  asserting each paragraph's start maps to its new start (0→0, 4→5, 8→9,
  14→15) under the flanking edits.
- `testDisjointRecordedEditsKeepTheAnchorOnItsParagraph` (R-02): one recorded
  batch of two disjoint inserts; asserts exact ordered rebasing and that the
  result equals the whole-body diff for surviving-paragraph anchors.
- `testOrderedLedgerEditsMatchSequentialRebasing` (R-02): the audit's
  counterexample — 30-unit body, edits (10,0,5) then (30,0,5), anchor 12 must
  rebase to **17**.
- `testResolverRebasesCardsThroughOrderedRecordedEdits` (R-02): end-to-end —
  `NoteStore` + `NoteDraftController` + `NoteInlineCardResolver`; a dirty
  draft carrying both inserts resolves the card at offset **9** and keeps it
  out of the tray.
- `testRecordedEditsRebaseAnchorsExactlyInOrder` (rewritten): 200
  deterministic pseudo-random edit streams; the ledger's rebase now must
  equal folding the anchor through the actual edits — the property the old
  test only pretended to assert.

Preserved/updated: `testSingleRecordedEditMatchesTheWholeBodyDiffExactly`
(single-edit equivalence, all offsets), paragraph-boundary and end-of-body
assertions in `testAnchorsFollowTextInsertionsDeletionAndUnicode`,
`testLedgerFallsBackToAFullDiffWhenTheRecordedHistoryDoesNotFit`,
`testExternalReplacementInvalidationRestoresTheDiffPath`, and
`testLedgerRebasePerKeystrokeOnLargeNote` (now exercising the list API).

The new tests were verified non-vacuous: a standalone reimplementation of the
old `diffing`/`composing` semantics reproduces anchor **0** for the R-01 case
and composed span **(10,15,25)** → anchor **0** for R-02 — both fail the new
assertions.

## Commands run and outcomes

```sh
# build-for-testing (Local = ATTIC_LOCAL_ONLY)
xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic \
  -configuration Local -derivedDataPath /tmp/attic-r01r02-dd \
  -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
# → ** TEST BUILD SUCCEEDED ** (pre-existing deprecation warnings only)

# offline in-host XCTest harness (same as prior runs; xcodebuild test
# discovery stalls under testmanagerd in this environment)
ATTIC_TEST_PRODUCTS=/tmp/attic-r01r02-dd/Build/Products/Local \
  zsh /tmp/attic-offline-xctest/run.zsh r01r02-focused 240 \
  NoteInlineCardsTests NoteInlineCardsPerformanceTests
# → 22 tests, 0 failures, exit_status=0
#   NoteInlineCardsTests 6 · NoteInlineCardsPerformanceTests 16

ATTIC_TEST_PRODUCTS=… zsh run.zsh r01r02-notes 300 \
  NoteStoreTests NoteDraftControllerTests NoteAttachmentTests
# → 98 tests, 0 failures, exit_status=0
#   NoteAttachmentTests 47 · NoteDraftControllerTests 37 · NoteStoreTests 14

git diff --check   # → clean
```

## Failure classification

- **Code failures:** two of mine, both caught at compile time and fixed —
  `CollectionDifference.Change` needs `case`-pattern offset extraction, and
  `NSString.replacingCharacters` returns `String` (`.length` → `.utf16.count`).
- **Environment failures:** one transient build job reported "exit code 0 but
  produced no further output" on unrelated `TaskStoreTests.swift`; the
  identical rerun succeeded. `xcodebuild test` remains unusable in this
  environment (pre-existing; the offline harness is the established
  workaround).
- **Pre-existing warnings only:** `CGWindowListCreateImage` deprecation,
  unreachable code after `XCTSkip`, ad-hoc signing notes. No test failures,
  no weakened assertions, no suppressed diagnostics.

## Remaining validation limits

- The app was not launched; no live editor, gesture, visual, or accessibility
  validation was performed or is claimed.
- Ordered-edit recording was exercised at the ledger/resolver level; the live
  `NSTextStorage` callback stream was not.
- CloudKit, iPhone, TestFlight, and production behavior are deferred and were
  not exercised; all validation ran under `ATTIC_LOCAL_ONLY` with in-memory
  stores.
- `edits(from:to:)` past `maxDiffedParagraphs` falls back to the single
  spanning diff by design — a bounded degenerate-document limit, unchanged in
  kind from the old always-single-span behavior.

## Diff integrity

`git diff --check` clean on tracked files; the three untracked files were
checked for trailing whitespace and conflict markers (none). No files outside
the owned set were modified; `Docs/RollingWork-2026-09-14.md` untouched;
nothing was staged, committed, or pushed.

IMPLEMENTATION_READY
