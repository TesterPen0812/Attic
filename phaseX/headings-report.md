# P3 headings and Notes behaviour

Branch: `phase-x/headings`. Base: `origin/phase-x/int11` at `a1b663f32afc6ba2a677cecf0dc49a77a95122c8`.
Scope: owner N-1 option C, plain note titles, table Select All including empty cells, polite error announcements. Canvas and dormant sync excluded. Owner identities and macOS settings excluded.

## Findings recorded before fixes

- P3-H1 · headings · P2 · choose Fold on a heading · content through the next same/higher heading disappears without deleting text · baseline has no folding command or document metadata · source `NoteBlockLayout`, `NoteCommandCatalog`.
- P3-H2 · title · P2 · select title text and apply an inline mark · title stays plain · baseline accepts selected-title marks but refuses a title caret · `PlainNoteTitleTests.testTitleSelectionCannotAcquireAnyInlineMark`; owner P3 policy supersedes H13 asymmetry.
- P3-H3 · tables · P2 · enter an empty cell and press Cmd-A twice · first selects empty cell text; second selects table · baseline first press selects table because a zero-length caret equals all cell text · `NotesV2TablesFeatureTests.testEmptyCellSelectAllRequiresTwoPresses`.
- P3-H4 · accessibility · P2 · display an error notice · announce once at low priority · baseline notice components have no announcement delivery hook · `AtticFeedback`, `NoteStatusSlot`.

## Verification

The strict macOS build passes. Final relevant local verification passes: 114 tests, 108 passed and 6 explicit key-window skips; the later policy-fixture check adds 3 passes with no skips. Optimized native UAT was completed. Fast CI is failed; all three focused FKA runs pass (8 checks each, no skips). Hindsight tools advertised by repository instruction are not callable in this session; supplied TextKit attachment memory and owner decision files were read directly. No subagents.

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

## Local checks

- Final strict local invocation uses `Scripts/xcodebuild_locked.sh build test`, Local configuration, `SWIFT_STRICT_CONCURRENCY=complete`, `.build/dd-headings`, and serial testing. macOS build passes. At `c6da88f4`, 114 relevant tests ran: 108 passed, 6 explicit key-window skips, no failures. This includes all 12 heading tests and native captures, full NotesFormatControls and NotesV2TablesFeature suites, plain-title and notice tests. `headings/local-final-summary.json` preserves the result; `/tmp/attic-headings-final.log` is the build/test log.
- The wider Notes invocation ran 496 tests: 484 passed, 11 explicit skips and one failed format-bar placement fixture. The title policy moved its selection into the body, but its short document could not scroll that body beneath the header. The corrected fixture uses enough body lines and asserts scrollability while retaining every geometry assertion; it passes in the final invocation. Other wider-suite cases passed in `wide2`; this is not a claim that the original 496-test invocation was green.
- Earlier focused counterexamples exposed copied headings sharing fold IDs and EOF caret positions falling outside a half-open folded range. Both causes are fixed and covered. The initial implementation test builds stopped on fixture API mistakes; those stops were not product regressions or valid red evidence.
- The final TextKit bridge uses compiler-supported `@preconcurrency` storage-delegate conformance, retaining runtime actor isolation checks. A strict SDK probe passes. Strict builds still emit warnings in unchanged delegate/layout and other repository code; no warning-free claim is made.
- `Scripts/verify_project_generation.rb` passes with the repository Ruby/Bundler environment. No project inputs changed. Finished xcresults were read, summarized and moved to Trash.
- The later body-link policy-fixture test runs through the same locked wrapper, strict concurrency and derived data: 3 passed, no skips/failures. `headings/local-cursor-summary.json` preserves it.
- No subagents were launched, per the job's explicit restriction; the skill's different-model review recommendation is therefore not followed.

## Commits

- `76c7e5e3`: empty-cell Select All.
- `2f05ae4f`: polite, deduplicated error announcements.
- `44859228`: plain title selections, loaded marks and typed marks.
- `e7844a56`: concrete application target for announcements.
- `24aa128b`: initial main-actor TextKit bridge and corrected capture/placement fixtures.
- `e5bf00f3`: runtime-checked TextKit delegate conformance, verified by SDK probe.
- `c6da88f4`: scrollable placement fixture with its scrollability assertion.
- `896b09c6`: retained-range TextKit folds, trailing chevrons, menu/shortcut, persistence, exports, Find, caret, identity and undo coverage.
- `eff23be5`: report, captures and final local summary; CI source revision.
- `9f732ce0`: move the read-only link-cursor fixture into the body under the new plain-title policy, preserving its assertions. Its test and both plain-title tests pass (3/3, no skips); `headings/local-cursor-summary.json`.

## Manual UAT

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

## CI

Exactly one fast and three sequential FKA dispatches completed after push. Same-ref concurrency makes simultaneous runs cancel each other. CI uses `eff23be5b4a84b37792e78a540e118f2cc7ce4ea`; subsequent changes are the read-only link test fixture and evidence/report files, with no product-code changes.

- [Fast run 38126936746](https://github.com/TesterPen0812/Attic/actions/runs/38126936746): **failed**. Regular and strict builds, project generation, static analysis and final worktree checks passed. Full unit suite: 2,604 tests, 2,587 passed, 10 skipped, 7 failed (29 assertions). The unit step's displayed success is masked by `continue-on-error`; the required final gate correctly fails. `headings/ci-fast-unit-summary.json` preserves the actual result.
- `OwnerTasks1010Tests.testReadOnlyLinkCursorStopsAtTheGlyphBounds` expected a linked title. The owner now requires plain titles, so its link belongs in a body paragraph. Corrected in `9f732ce0` without weakening cursor-boundary assertions; local strict test invocation passes it and both plain-title tests. This correction was made after the requested fast dispatch and has not had another remote fast run.
- Five unchanged `NotesKeyboardUndoTests` fail the fixture's initial `window.isKeyWindow` / `NSApp.keyWindow` checks, followed by cascading responder/delete/undo assertions: `testAToastThatDoesNotClaimTheKeyLeavesCommandZToTheText`, `testSearchFieldUndoWhileTheDeleteToastShowsUndoesTheSearchTextThenTheLibrary`, `testTypingUndoAfterDeletingAnotherNoteAndReturningToTheSameNoteUndoesTheTyping`, `testUndoDispatchUsesTheKeyResponderBeforeQueuedFocusChanges`, `testUndoOfDeletingTheLastNoteWorksFromTheEmptyLibraryAfterTheToastExpires`. These fixture assertions remain intact; this job does not change them. Their failures remain unresolved; a pinned-base run was not performed, so no pre-existing-cause claim is made.
- Unchanged `AtticDropdownTests.testOpenAndFilterCostNoMoreThanBeforeWithAccessibilityOn` fails `tagOpen_AX`: measured ratio `0.9405855631133273`, accepted maximum `0.932` (`0.727 + 0.205`). Its threshold remains intact. This failure remains unresolved; this run alone does not establish causality.

| Lane | Run | Result | Tests |
| --- | --- | --- | --- |
| FKA 1 | [38128680374](https://github.com/TesterPen0812/Attic/actions/runs/38128680374) | Passed | 8 passed, no skips/failures |
| FKA 2 | [38128944003](https://github.com/TesterPen0812/Attic/actions/runs/38128944003) | Passed | 8 passed, no skips/failures |
| FKA 3 | [38129235338](https://github.com/TesterPen0812/Attic/actions/runs/38129235338) | Passed | 8 passed, no skips/failures |

Each FKA run requires the native Full Keyboard Access test, four H5-04 unit focus regressions and three task-focus regressions. Hosted CI changes its runner's FKA setting; this job never changed the owner's macOS settings. Run conclusions, tested SHAs and job evidence are recorded in `headings/ci-results.json`; individual passing FKA tests are in `headings/ci-fka-tests.json`.

## Review and limits

Diff checked against the pinned starting commit `a1b663f3` (the shared remote-tracking `origin/phase-x/int11` may advance during parallel jobs). Changes are confined to Notes and shared notice delivery; no Canvas, sync, system-setting or protected-identity changes. Local generated output is about 1 GB, below the 3 GB limit; finished xcresults are read and moved to Trash. Project generation is repeatable and current; no project inputs were changed.
The comparative performance script uses another worktree's reference app, so it was not run under this job's worktree boundary. No comparative performance or audible VoiceOver acceptance is claimed. Native before/after captures are in `phaseX/headings/`; optimized captures have distinct names.
