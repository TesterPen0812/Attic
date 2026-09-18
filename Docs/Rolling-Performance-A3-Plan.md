# Rolling PERF-A3 Plan — One Body-Diff Derivation Per `NoteStore.update` Save

**Date:** 2026-09-14
**Author:** read-only SWE-2 Max performance planning worker (Synara thread `agent-1ce35bd2bf839ae9552932aedaf82b1a`, request `attic-performance-a3-plan-20260914-v1`)
**Repository:** `/Users/taha/Developer/attic-task-panels-v2` · branch `codex/attic-task-panels-v2` · HEAD `ae6418c`
**Owned file:** `Docs/Rolling-Performance-A3-Plan.md` only. No source, test, project, or user file was read for modification or modified.

## Planning status and evidence limits

This is **read-only planning on a moving dirty worktree**, prepared while a
separate active writer (Synara thread `agent-b943a1e073b2d9d13aa644327eb88286`,
request `attic-reliability-r01-r02-implementation-20260914-v1`) owns the
Reliability R-01/R-02 ordered inline-anchor correction in the same checkout
(`Docs/RollingWork-2026-09-14.md:89-91`).

- I ran **no** build, test, app launch, profiler, or measurement. Every claim
  below is source inspection only; no timing, CPU, or memory magnitude is
  claimed. PERF-A3's mechanism is `CONFIRMED` by
  `Docs/Rolling-Performance-Audit.md:200-239`; its magnitude remains
  `UNVERIFIED`.
- At inspection time the five files the R-01/R-02 task owns still matched the
  coordinator's 09:53 SHA-256 checkpoint (`Docs/RollingWork-2026-09-14.md:102`):
  `NoteInlineAnchor.swift` `e59d21e3…` (measured `e59d21e368e4…`),
  `NoteInlineCards.swift` `de6bce1f…` (`de6bce1fce60…`), `NoteAttachmentTray.swift`
  `387333f5…` (`387333f50a3f…`), `NoteStore.swift` `cb4b381e…` (`cb4b381e0ce7…`),
  `NoteInlineCardsTests.swift` `f2b13668…` (`f2b136687cfc…`). **The writer had
  not yet modified them; every line number below is pre-R-01 and will shift.**
  The future implementer must re-read the settled files and
  `Docs/Rolling-Reliability-R01-R02-Implementation.md` before applying this plan.
- `NoteInlineAnchor.swift`, `NoteInlineCards.swift`, and
  `NoteInlineCardsTests.swift` are untracked files added in the current
  task-panel batch; `NoteStore.swift` is a tracked modification (121+/2− vs
  HEAD at inspection).

## 1. Confirmed mechanism (current source)

`NoteStore.update` (`Attic/Services/NoteStore.swift:188-232`):

- `bodyChanged` is computed at `:206`; `guard titleChanged || bodyChanged ||
  replicasNeedRepair else { return true }` early-outs at `:209`.
- `if bodyChanged` (`:212-224`) fetches `storedAttachments(forNoteID: note.id)`
  once (`:214`) and loops every returned row, calling
  `NoteInlineAnchor.moved(offset, from: note.body, to: destinationBody)` (`:216`)
  for each row whose `inlineOffset` is non-nil.
- `storedAttachments(forNoteID:in:)` (`:913-924`, inside `#if os(macOS)`
  `:895-1126`) is **noteID-predicated and returns every physical replica row**,
  not the deduplicated presentation set. So k = anchored *replica rows*: two
  physical replicas of one anchored attachment each pay a diff today.
- `moved(_:from:to:)` (`Attic/Models/NoteInlineAnchor.swift:77-80`) delegates to
  `NoteTextReplacement.diffing` (`:52-64`): two whole-document `[UInt16]`
  allocations plus an O(document) prefix/suffix scan — **once per anchored
  replica row per save**.
- The O(1) entry point already exists: `moved(_:by:in:)` (`:83-85`) =
  `paragraphStart(replacement.rebasing(offset), in: newText)`, with
  `rebasing` at `:30-34` and `paragraphStart` (`NSString.paragraphRange`) at
  `:68-73`.
- `paragraphStart` remains an O(paragraph-local) scan **per anchor** in every
  design — PERF-A3 removes only the per-attachment *document-wide* diff, not
  the per-anchor paragraph snap.
- Fetch failure inside the `do` runs `context.rollback()` + `lastErrorMessage`
  + `return false` (`:219-223`); a `persist` failure inside `save()`
  (`:737-754`) rolls back the context and reloads models — speculative
  `inlineOffset` writes are discarded with everything else.

## 2. Exact callers of `update` (body-changing or potentially so)

| Caller | Site | Edit description available? |
|---|---|---|
| `NoteDraftController.flush()` — existing note | `Attic/Services/NoteDraftController.swift:423` | Only via the view-layer ledger (see §3) |
| `flush()` — reserved blank-note merge | `NoteDraftController.swift:445` | Same |
| `NoteDraftController.overwriteRemoteVersion()` | `NoteDraftController.swift:541` | Same |
| `AgentTaskTools.updateNote` (`update_note` tool) | `Attic/Services/AgentServer/AgentTaskTools.swift:412` | None — no editor session |
| `MobileNotesScreen.save()` (deferred iOS) | `AtticMobile/Views/MobileNotesScreen.swift:353` | None — no ledger on iOS |
| Tests | `AtticTests/NoteStoreTests.swift` (`:105,141,156,254`…), `NoteInlineCardsTests.swift` (`:25,360,383`…), `NoteDraftControllerTests.swift` (`:976,994,1012`…), `NoteAttachmentTests.swift` | n/a |

Flush triggers that reach `:423`/`:445`: the 500 ms trailing debounce and 5 s
maximum deadline (`NoteDraftController.swift:598-631`), `close()`/`beginNew()`/
`beginEditing`/`prepareAttachmentImport`/`retryRecovery`, panel hide and
termination (per `Docs/Rolling-Reliability-Audit.md:269-273`), and every
`placeAttachment` UI path that guards `noteDraft.flush()` first —
`NoteInlineCards.swift:135,148,153,169,174` and `NotesPanelContent.swift:301-304`
(`onMoveAttachment`). So PERF-A3's reduction also applies to move/place/resize
actions taken while the draft is dirty.

`NoteStore.swift` is compiled into the deferred iOS target via
`shared_mobile_sources` (`Scripts/generate_project.rb:109`), while
`NoteAttachment` and `NoteInlineAnchor` are not shared and
`storedAttachments(forNoteID:)` exists only under `#if os(macOS)` — `update`
already references it ungated at `:214`, so this region is currently
macOS-coupled. **Any signature change must remain source-compatible** (e.g. a
defaulted parameter) for `MobileNotesScreen.swift:353` and all test callers.

**Adjacent diffs that are NOT this finding** (do not "fix" or count them):
the tray's per-evaluation `NoteTextReplacement.diffing` at
`NoteAttachmentTray.swift:40` and the ledger's fallback diff at
`NoteInlineCards.swift:295` are presentation/typing-path costs tracked under
PERF-A2 (`Docs/Rolling-Performance-Audit.md:129-197`).

## 3. API/ownership conflict with the R-01/R-02 ordered-edit work

The reliability audit recommends describing multi-edit saves as an **ordered
list of real edits** rather than one collapsed span
(`Docs/Rolling-Reliability-Audit.md:99-106` for the save path R-01, `:153-157`
for the transient ledger R-02). Consequences for PERF-A3:

- **The audit's own suggested PERF-A3 fix** — "compute
  `NoteTextReplacement.diffing(note.body, destinationBody)` once inside
  `if bodyChanged`, then `moved(offset, by:in:)` per attachment"
  (`Docs/Rolling-Performance-Audit.md:227-234`) — is semantics-identical only
  under *today's* single-replacement model. If the R-01 worker lands ordered
  edits, "one `diffing` per save" would preserve the exact collapse class R-01
  exists to remove. **The perf target therefore reframes as: ≤1 whole-document
  derivation per body-changing update — whatever representation the settled
  correctness design uses — never "one collapsed span".**
- If R-01 lands the audit's option (a), `update` likely gains an ordered-edit
  input (e.g. `bodyEdits: [NoteTextReplacement]?` or a new edits type). That
  parameter *is* the zero-diff channel; PERF-A3 must reuse it rather than add
  a second plumbing path.
- If R-01 instead lands paragraph-granularity or a multi-span `diffing`
  variant inside the anchor layer, PERF-A3 hoists that settled derivation to
  once per save.
- The natural ordered-edit source is `NoteBodyEditLedger`
  (`NoteInlineCards.swift:238-299`) fed by
  `Coordinator.pendingStorageEdit`/`textStorage(didProcessEditing:)`
  (`NoteAttachmentTray.swift:1291,1442-1467`). **It is currently unreachable
  from the save path**: the ledger lives on `NoteInlineCardResolver`, a
  `@State` member of `NoteComposerView` (`NotesPanelContent.swift:163`), wired
  into the editor at `:300`; `NoteDraftController` holds no reference. Whether
  the composer can hand edits to `update` depends on where the R-01 design
  lands the authoritative edit record — a decision that belongs to that task.
- `NoteStore.update` is `@MainActor`, synchronous, and the ledger callbacks are
  UI-thread synchronous (`NoteInlineCards.swift:235-237` notes deliberate
  non-isolation) — no actor boundary blocks the plumbing if R-01 creates it.

## 4. Proposed smallest architecture-compatible change

Apply **after** the R-01/R-02 task reports `IMPLEMENTATION_READY` (or, if that
task is descoped, against the current single-replacement semantics — see §7).

**Phase 1 (required; valid under every R-01 outcome).** Inside
`update`'s `if bodyChanged` block, replace the per-row `moved(from:to:)` with:

1. Fetch once: `let stored = try storedAttachments(forNoteID: note.id)` inside
   the existing `do`/`catch` (unchanged fetch, unchanged rollback).
2. `let anchored = stored.filter { $0.inlineOffset != nil }` — **required**
   parity guard: today a note whose attachments all sit in the tray performs
   *zero* diffs (the `if let offset` skips `moved`); a naive unconditional
   hoist would pay one diff and regress that case.
3. If `anchored` is non-empty, obtain the save's edit description **once**:
   - caller-supplied validated ordered edits, if the settled API provides them
     (zero derivations); otherwise
   - the settled whole-body derivation — today exactly one
     `NoteTextReplacement.diffing(note.body, destinationBody)`; after an
     ordered-list R-01, the ordered-list equivalent owned by the anchor layer.
   Increment the diagnostic seam (§5) once per derivation.
4. Rebase every anchored replica through that description:
   `attachment.inlineOffset = NoteInlineAnchor.moved(offset, by: description,
   in: destinationBody)` — identical per-anchor outputs, k× less document-wide
   work. Per-anchor `paragraphStart` cost is unchanged and stays inside
   `moved`.

Preserved invariants: identical offsets per anchor vs. the settled rebase
semantics; **every physical replica row written**; the `:209` early-out, the
`:203` empty-content refusal, and the `replicasNeedRepair` path untouched;
`do/catch → context.rollback()` on fetch error; `save()`'s rollback-and-reload
on persist failure. The derivation is a pure value computation — it adds no
new failure mode and nothing new to roll back.

**Phase 2 (optional, strictly conditional).** If the settled R-01 design
exposes an ordered-edit source reachable from `NoteDraftController.flush()`
(e.g. a draft-held edit list the coordinator records into), pass it into
`update` so the autosave path pays **zero** derivations. Preconditions:

- The supplied description must be verified to map `note.body` →
  `destinationBody` — at minimum the ledger's existing length self-check
  (`NoteInlineCards.swift:262-267`), plus `flush()`'s existing
  `currentSnapshot == persistedSnapshot` guard (`:405`) which already makes
  `note.body` the ledger's anchor text. **An unverified caller-supplied edit
  description is an R-01-class corruption vector** — a wrong list misplaces
  anchors permanently. If the settled design cannot prove the mapping cheaply,
  skip Phase 2; once-per-save derivation is already the bounded win.
- Non-composer callers (`AgentTaskTools`, `overwriteRemoteVersion`, iOS, tests)
  pass `nil` and take the single-derivation path.
- If R-01 does **not** create this channel, do not build one solely for
  performance — that would add ledger-to-store coupling with no correctness
  owner. Record the residual once-per-save derivation cost in the requirements
  ledger instead.

## 5. Test additions and seams

**Seam (source):** one `private(set)` instance counter on `NoteStore`
incremented once per whole-document derivation in the save path — same
convention as `attachmentReconciliationPasses` (`NoteStore.swift:137-138`),
`fullDiffs`/`incrementalRebases` (`NoteInlineCards.swift:248-249`), `rebuilds`
(`:315-316`). Name per settled code style (e.g. `savePathBodyDerivations`).
Count **derivations**, not list elements, so the bound reads identically
whether the description is one replacement or an ordered list. A static
counter inside `NoteTextReplacement.diffing` is **rejected**: it cannot
separate the save path from the presentation fallbacks
(`NoteInlineCards.swift:295`, `NoteAttachmentTray.swift:40`).

**Focused tests** — home: `NoteInlineCardsPerformanceTests` in
`AtticTests/NoteInlineCardsTests.swift` (existing home of the PERF-12/PERF-14
store-level gates, `:98`, `:330-392`), unless the settled R-01/R-02 diff makes
`AtticTests/NoteStoreTests.swift` cleaner. A *new* file instead requires
project regeneration (§6).

1. **Bound:** seed a note (in-memory container, per existing tests) with ≥3
   attachments anchored inline — including **one physical replica pair** (two
   `NoteAttachment` rows sharing `id`/`noteID`, the seeding trick of
   `testMutationsAndDeleteApplyToEveryPhysicalDuplicate`,
   `NoteStoreTests.swift:236-264`). One body `update` → counter delta ≤ 1
   (== 0 only if a caller-supplied description is plumbed and used). Never k.
   A second `update` adds ≤ 1 more.
2. **Zero-diff cases:** title-only `update` → 0; body `update` with all
   `inlineOffset == nil` → 0; body `update` with no attachments → 0.
3. **Parity:** every anchored replica's new `inlineOffset` equals the settled
   public rebase API applied to the pre-update offset — computed in-test via
   that public API as oracle, **never** a hand-encoded single-span
   expectation, so the test stays correct under ordered edits.
4. **Single-edit + `paragraphStart`/end:** extend the existing style
   (`testAnchorsFollowTextInsertionsDeletionAndUnicode`, :84-91;
   `testPlacementReorderingResizingAndBodyEditsPersistTogether`, :9-32) through
   the store path: one insertion before the anchor shifts it by delta; an
   anchor inside the replaced span lands on `paragraphStart`; an anchor at
   `body.length` follows the settled rule (`NoteInlineAnchor.swift:68-73`;
   resolver tray rule `NoteInlineCards.swift:359-361`).
5. **Replica writes:** assert *both* physical rows of the replica pair received
   the identical rebased offset via a fresh-context fetch.
6. **Failure rollback:** `PersistenceGate.shouldFail` (`TestSupport.swift:
   54-65`) → `update` returns `false` → a fresh context/store shows the
   original offsets and body, `lastErrorMessage` non-nil — mirroring
   `testFailedSaveRestoresNote` (`NoteStoreTests.swift:147-161`). Assert the
   restoration, not the counter (the derivation legitimately ran).
7. **Disjoint-edit correctness is owned by the R-01/R-02 suite.** PERF-A3 adds
   no assertion that would fail under ordered edits; its parity test (3) uses
   the public API as oracle precisely so it cannot re-encode the collapse.
8. **Optional** `measure(metrics: [XCTClockMetric()])` on a large-body update
   with k anchors (pattern: `testLedgerRebasePerKeystrokeOnLargeNote`,
   `NoteInlineCardsTests.swift:287-306`) — documentation only, no hard bound;
   timing gates have already flaked once on this host
   (`Docs/Rolling-NoSwipe-Implementation.md:159-162`).

## 6. Ownership boundary

**Implementer gate:** do not start until `Docs/Rolling-Reliability-R01-R02-
Implementation.md` exists and ends `IMPLEMENTATION_READY` (independent review
underway or complete, matching the coordinator's sequencing in
`Docs/RollingWork-2026-09-14.md:90-91`). First act: re-read the settled
`NoteStore.swift`, `NoteInlineAnchor.swift`, `NoteInlineCards.swift`,
`NoteAttachmentTray.swift` and the R-01/R-02 report — line numbers and type
shapes will have moved.

**Implementer owns:**

- `Attic/Services/NoteStore.swift` — the `update` save path and the counter
  seam.
- Test additions in `AtticTests/NoteInlineCardsTests.swift` (or
  `AtticTests/NoteStoreTests.swift`; or a new test file — see regeneration
  note).
- `Docs/Rolling-Performance-A3-Implementation.md` — the evidence report
  (established naming pattern).
- **Only if Phase 2 is adopted and the settled design placed the edit record
  on `NoteDraftController`:** `Attic/Services/NoteDraftController.swift` plus
  the minimal view wiring. These files overlapped the R-01/R-02 task; the
  implementer must confirm they are no longer owned before touching them.

**Implementer must not modify:** `NoteInlineAnchor.swift` semantics
(`rebasing`/`paragraphStart`/`diffing` and any ordered-edit types stay exactly
as R-01 settled them); `NoteBodyEditLedger`/`pendingStorageEdit` recording;
`NoteAttachment` schema; any R-01/R-02 test or the ledger fallback paths;
`NotesPanelContent`/`NoteAttachmentTray` presentation code; project inputs —
**except** that adding a new test file requires `ruby
Scripts/generate_project.rb` + `ruby Scripts/verify_project_generation.rb`
(AGENTS contract step 2; sources are globbed at generation time,
`Scripts/generate_project.rb:50-58,72`). No git stage/commit/push, no app
launch, no native input.

**Independent reviewer owns:** `Docs/Rolling-Performance-A3-Review.md` only
(read-only). Verifies: (1) ≤1 derivation per body-changing update, proven by
the seam and source shape; (2) per-anchor outputs identical to the settled
rebase semantics, including disjoint edits; (3) the change does not re-collapse
multi-edit saves into one span and does not bypass the ordered-edit design;
(4) replica writes, rollback, and early-outs preserved; (5) no unmeasured
magnitude claimed.

## 7. Commands, checks, and what each proves

Source/test/build evidence (for the implementer — **this planner ran none**):

```sh
# Only if a new test file is added:
ruby Scripts/generate_project.rb && ruby Scripts/verify_project_generation.rb
# → proves project inputs stay consistent (required by the dev contract).

xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic \
  -configuration Local -derivedDataPath <fresh-path> \
  -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO -quiet
# → proves compilation incl. the seam and new tests (invocation per
#   Docs/Rolling-NoSwipe-Implementation.md:122-125).

ATTIC_TEST_PRODUCTS=<dd>/Build/Products/Local \
  zsh .build/final-fixes/offline-xctest/run.zsh perf-a3 240 \
  NoteStoreTests NoteInlineCardsTests NoteInlineCardsPerformanceTests \
  NoteDraftControllerTests NoteAttachmentTests
# → focused deterministic run of update/rebase/draft-flush/attachment suites
#   via the in-repo offline harness (.build/final-fixes/offline-xctest/run.zsh;
#   usage: run.zsh LABEL SECONDS TESTID…). Proves the counter bound, parity,
#   replica writes, and rollback assertions in one host process.

git diff --check
# → whitespace/conflict-marker cleanliness.
```

**What these prove:** compile-level integration; a deterministic "≤1
whole-document derivation per body-changing update" bound; anchor parity
against the public oracle; replica and rollback behavior.

**What they do not prove — native/live validation, separate gate:** any
wall-clock improvement. That requires `os_signpost` intervals around the
derivation + rebase loop and an Instruments/`powermetrics` typing session on a
seeded large note with several inline cards — work reserved for an assigned
native worker (Sol Low class) per the project's evidence-separation rule
(`Docs/RollingWork-2026-09-14.md:9`). The 24 ms diagnostics-inclusive sample
in `Docs/PersonalChromeCheckpoint-2026-09-14.md` is not a benchmark and must
not be cited as one (`Docs/Rolling-Performance-Audit.md:26-28`).

## 8. Unresolved risks

- **Settled R-01/R-02 API unknown until it lands.** Three cases: (a) `update`
  gains an ordered-edit parameter — PERF-A3 becomes "reuse the supplied
  description, else derive once"; (b) correctness stays inside the anchor
  layer (paragraph-granular or multi-span derivation) — hoist that settled
  derivation to once per save; (c) R-01/R-02 blocked/descoped — the audit's
  trivial hoist is *still* semantics-identical under the current model and may
  land alone, leaving R-01 as a known defect for its own fix. In no case may
  PERF-A3 present single-span collapsing as a correctness fix, and it must
  never reintroduce a collapsed span where the settled design forbids it.
- **Double-churn on the same lines.** Both tasks touch `update`'s
  `bodyChanged` block. If PERF-A3 lands first, the hoisted call site is the
  exact place R-01 must edit — compatible but creates review overlap; the
  ordering gate in §6 exists to avoid it.
- **Ledger reachability.** Phase 2's zero-derivation path exists only if R-01
  puts an ordered-edit record where `flush()` can reach it (the ledger is
  currently view-layer `@State`). Do not invent that channel in a perf task.
- **Unverified supplied edits are a corruption vector.** Any `bodyEdits:`
  parameter must be length/mapping-checked against `note.body` before use, or
  the perf change becomes a new R-01 producer.
- **k counts replica rows, not unique attachments** — the counter is
  per-`update`, and per-anchor `paragraphStart` work remains O(k × paragraph
  scan) in every design; that is unchanged and bounded, not part of this
  finding.
- **Tray-only parity.** Skipping the `anchored.isEmpty` guard would turn
  today's zero diffs into one for notes with only tray attachments — a
  regression the bound test (§5.2) exists to catch.
- **iOS shared source.** `update`'s signature must stay source-compatible for
  `MobileNotesScreen.swift:353`; the function already calls macOS-only
  attachment APIs ungated, so this region's iOS compilability is a pre-existing
  deferred-scope question, not one this plan resolves.
- **Counter seam drift.** If the settled design derives edits lazily inside a
  helper the store calls once, the seam must wrap the derivation itself, not
  the call site, or the bound becomes unprovable.

PERFORMANCE_A3_PLAN_READY
