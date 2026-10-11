# P3 headings and Notes behaviour

Branch: `phase-x/headings`. Base: `origin/phase-x/int11` at `a1b663f32afc6ba2a677cecf0dc49a77a95122c8`.
Scope: owner N-1 option C, plain note titles, table Select All including empty cells, polite error announcements. Canvas and dormant sync excluded. Owner identities and macOS settings excluded.

## Findings recorded before fixes

- P3-H1 · headings · P2 · choose Fold on a heading · content through the next same/higher heading disappears without deleting text · baseline has no folding command or document metadata · source `NoteBlockLayout`, `NoteCommandCatalog`.
- P3-H2 · title · P2 · select title text and apply an inline mark · title stays plain · baseline accepts selected-title marks but refuses a title caret · `PlainNoteTitleTests.testTitleSelectionCannotAcquireAnyInlineMark`; owner P3 policy supersedes H13 asymmetry.
- P3-H3 · tables · P2 · enter an empty cell and press Cmd-A twice · first selects empty cell text; second selects table · baseline first press selects table because a zero-length caret equals all cell text · `NotesV2TablesFeatureTests.testEmptyCellSelectAllRequiresTwoPresses`.
- P3-H4 · accessibility · P2 · display an error notice · announce once at low priority · baseline notice components have no announcement delivery hook · `AtticFeedback`, `NoteStatusSlot`.

## Verification

Local strict build and wider Notes suites are queued behind the machine-wide build lock. Hindsight tools advertised by repository instruction are not callable in this session; supplied TextKit attachment memory and owner decision files read directly. No subagents.

## Baseline evidence

- `before-native.png`: native editor capture from the integration base, on an opaque white background; not an optimized on-screen preview.
- `/tmp/attic-headings-red3.log`: persisted fold layout and selected-title marks fail on unchanged product source. The initial table assertion used the editor-creation flag and was rejected as an invalid oracle.
- `/tmp/attic-headings-red4.log`: corrected empty-cell test fails on the first press retaining the cell's first responder. 2 tests, 1 expected failure; baseline capture passes.
- Two initial test builds stopped on fixture API mistakes (missing caret argument, then treating the Void method as Bool). These are not product regressions or valid red evidence.
- Xcresults are summarized, then moved to Trash as required. Product source was edited only after valid red evidence.

## Implementation

- N-1: TextKit 2 content-manager enumeration skips folded paragraphs, keeping all text and objects in storage. The heading's stable block UUID is saved in additive `foldedHeadings` document metadata; original unrecognized metadata remains intact until folding is changed. Nested boundaries use the next same/higher heading. Existing attachment hosting/focus patterns remain in use.
- The thin chevron follows the final heading glyph, down when open and rotated right when folded. No count or ellipsis. Its native button has an accessible label and shared overlay lifetime handling. The Format menus and shortcut router include Fold or Unfold Heading, Ctrl-Cmd-H.
- Fold toggles use editor-owned undo. Heading typing retains IDs and folds. Find and caret entry open every folded ancestor. Folded objects are excluded from accessibility traversal; Markdown, plain copy projection and print use the complete document.
- Titles reject inline commands and discard title marks in native rendering/extraction, including mixed title/body selections; body marks continue to work.
- Empty cells track the first Select All explicitly, then escalate on the second press. Mouse, typing, cell changes and other commands reset this state.
- Error notices, error lines, failed toasts and Notes error status deliver one low-priority accessibility announcement per active error message, allowing a later occurrence after dismissal.

## Checks in progress

Project generation verification passes. The first implementation test build (`green1`) stopped on two fixture API mistakes (`show`, and the test attachment store), corrected from declarations before rerunning. `focused2` compiled and ran 14 tests: 11 passed, one capture-only test skipped, and two edge-case tests failed (three assertions). Those counterexamples confirmed that copying retained a heading ID and EOF fell outside a half-open folded range. The fixes give copied headings independent IDs and include final body insertion points without unfolding an edited final heading. The strict macOS build in `wide` passed; 496 tests ran, with 483 passes, 12 intentional skips and one failed placement fixture (two assertions). The title policy changed that fixture to body text, which had enough space above it; it now scrolls the body under the header while retaining every geometry assertion. Native capture activation also now reads Xcode's unprefixed environment key. The `wide2` strict build passed; all 12 folding tests, including native captures, passed. Across 496 tests: 484 passes, 11 explicit skips and the same placement fixture failure. A short document constrains the attempted scroll; the final fixture uses enough body lines to scroll and asserts that precondition. The final TextKit bridge uses the compiler-supported `@preconcurrency` storage-delegate conformance, which keeps runtime actor isolation checking; a strict SDK probe passes. Final focused strict verification (`/tmp/attic-headings-final.log`) passes at source commit `c6da88f4`: macOS build plus 114 tests, 108 passed, 6 explicit key-window skips, no failures. The scrollable placement fixture passes; all 12 folding tests and native captures pass. The rerun includes full NotesFormatControls and NotesV2TablesFeature suites, plain-title and notice tests. The wider suites' other cases passed in `wide2`; its sole failed fixture is green in the final run. Finished result summary: `headings/local-final-summary.json`. Strict mode still emits warnings in unchanged delegate/layout code and other repository code; no warning-free claim is made. No app identities or settings outside scope have been used. No subagents were launched, per the job's explicit restriction; the skill's different-model review recommendation is therefore not followed.

## Commits

- `76c7e5e3`: empty-cell Select All.
- `2f05ae4f`: polite, deduplicated error announcements.
- `44859228`: plain title selections, loaded marks and typed marks.
- `e7844a56`: concrete application target for announcements.
- `24aa128b`: initial main-actor TextKit bridge and corrected capture/placement fixtures.
- `e5bf00f3`: runtime-checked TextKit delegate conformance, verified by SDK probe.
- `c6da88f4`: scrollable placement fixture with its scrollability assertion.
- `896b09c6`: retained-range TextKit folds, trailing chevrons, menu/shortcut, persistence, exports, Find, caret, identity and undo coverage.

## Manual UAT and CI

Optimized preview built and was inspected on screen under `/tmp/attic-screen.lock`, then quit by bundle ID and the lock released. Only the job preview was launched or captured.

- Branch `phase-x/headings`, source commit `24aa128b9a783bb343331c0bbacf9fdd44ae2ad8`. Build provenance says dirty because report/capture files were untracked; tracked product and tests were committed.
- Bundle `com.taha.Attic.preview.phasex`, display `Attic Phase X`, executable `/Users/taha/Developer/attic-px-tasks/.build/dd-preview/Build/Products/Local/AtticPhaseX.app/Contents/MacOS/AtticPhaseX`.
- Optimized executable SHA-256 `afc3c7a42ec6902bf33cdd49e309e08d567ebdc07dc4c8cb161995f69c7ad270`; no debug dylib. Ad-hoc local-only sandbox/network entitlements, no sync entitlements.
- Launch used `ATTIC_UI_TESTING=1`, `ATTIC_UI_TEST_DISPLAY=external`, the existing typography scene, then Notes was selected. UI-testing uses disposable in-memory data.
- Visually observed thin trailing down/right chevrons, no folded count/ellipsis, click and Ctrl-Cmd-H folding, heading typing remaining folded, separate typing/fold undo and fold redo, caret entry unfolding, body Find unfolding.
- A real inserted table was edited. Empty and nonempty cell Cmd-A stayed in the cell first, selected the table second; Cmd-A outside the cell selected the entire note. Folding with the cell editor active returned focus to the note and hid the table; a cell Find match unfolded it. A library return retained the fold.
- The Notes Format submenu exposes the enabled Fold or Unfold Heading command; engine/router menu execution is covered by the tests. A selected title rejected Cmd-I on screen. Full mark-kind validation and persisted title cleanup are covered by unit tests.
- Captures: `after-open-preview.png`, `after-folded-preview.png`, `after-typing-folded-preview.png`, `after-find-preview.png`, `after-empty-cell-first-select-all-preview.png`, `after-empty-cell-second-select-all-preview.png`, `after-table-folded-preview.png`, `after-table-find-preview.png`, `after-reopen-preview.png`.
- Durable fold storage is established by the store save/fresh-load test, not by the in-memory UI-testing launch. Audible VoiceOver speech remains unverified; deduplication and low-priority delivery are checked without changing a system setting.
CI dispatches starting after local verification and push: one fast run and three sequential FKA runs (same-ref concurrency cancels overlapping runs). Final conclusions will be added after completion.

## Review and limits

Diff checked against the pinned starting commit `a1b663f3` (the shared remote-tracking `origin/phase-x/int11` may advance during parallel jobs). Changes are confined to Notes and shared notice delivery; no Canvas, sync, system-setting or protected-identity changes. Local generated output is about 1 GB, below the 3 GB limit; finished xcresults are read and moved to Trash. Project generation is repeatable and current; no project inputs were changed.
The comparative performance script uses another worktree's reference app, so it was not run under this job's worktree boundary. No comparative performance or audible VoiceOver acceptance is claimed. Native before/after captures are in `phaseX/headings/`; optimized captures have distinct names.
