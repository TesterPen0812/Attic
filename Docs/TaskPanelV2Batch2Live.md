# Task panel V2 — Batch 2 live UI validation

Date: 2026-09-13. Scope: Batch 2 R2 unified family panel and R3 general
attachments, including reviewed fixes. This is macOS local-only preview evidence, not
CloudKit, APNs, iPhone, TestFlight, production, or release validation.

## Frozen source and preview identity

- Worktree: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- Frozen pre-build dirty state: 71 porcelain paths; status SHA-256
  `370369b14d6b8bed700a944c5b46eca70d14d162deb52c5be12c2061224c24dc`.
- Batch 2 cumulative diff: `.build/batch2.diff`, SHA-256
  `6aea241c15487109c6f1befc5f262461cb5c65595be4d4d4559a6687f6d0c141`.
- Batch 2 review-fix delta: `.build/batch2-fixes.diff`, SHA-256
  `ab536c177dc272e393013eca48a3504359f9be9f06c657db837288599801c994`.
- Preview: `Attic Task Panels V2`; bundle `com.taha.Attic.taskpanels.v2`;
  executable `AtticTaskPanelsV2` at
  `.build/TaskPanelsV2Preview/Build/Products/Local/AtticTaskPanelsV2.app/Contents/MacOS/AtticTaskPanelsV2`.
- Preview executable SHA-256:
  `03708e9d898116646e6214deff63ef9f6c684cd40e4f45413bf2df44d46b5854`.
- `.build/batch2-live/launch.log` records the dirty source identity, build, ad-hoc
  signature and entitlements. The Local build contained no CloudKit, ubiquity or APNs
  entitlement.
- The frozen executable was not rebuilt after the orchestrator allowed later work in a
  separate output path.

## Unified family panel and sizing

Directly observed through the uniquely identified preview:

- Clicking the parent row opened one family surface on Subtasks. Its shared header stayed
  above three 42 pt child rows; the footer showed `Add subtask…` and the destination action
  `Show attachments`.
- Switching showed the Attachments view in the same surface. The title, `0 of 3 complete`
  subtitle and pin control stayed anchored while the footer changed to `Add attachment…`
  and destination action `Show subtasks`.
- The empty Attachments state shrank from the three-row Subtasks height to a compact panel.
  Switching back expanded to the same three-row height; returning to Attachments shrank to
  its card content. The top/header position stayed visually fixed through the settled states.
- The final layouts did not show a second sizing jump. Tool capture latency prevents a
  frame-by-frame claim about the 0.22-second paging/height animation itself.
- Escape dismissed the transient. A fresh click on the parent row opened Subtasks, rather
  than retaining Attachments. The main row then exposed passive `2 attachments` and
  `0 of 3 complete` metadata.
- The main panel was pinned only to keep CUA inspection stable, then restored to its original
  unpinned state.

## Attachment picker, cards and preview

Two isolated fixtures were attached to the existing preview-only parent:

- `.build/batch2-live/general-file-fixture.txt` — 50-byte plain-text fixture.
- `Docs/TaskPanelV2References/gallery.png` — existing 1.6 MB PNG reference used read-only as
  the picker source.

Observed behavior:

- The single `Add attachment…` picker accepted both the general text file and the PNG.
  Each successful import returned to the Attachments view.
- One text file produced a compact half-width system document card; adding the image produced
  a stable two-column row with the file and image cards together. The image did not dominate
  the panel. Both cards exposed filename and byte-size metadata with middle truncation.
- Accessibility described the cards as `general-file-fixture.txt, file, 50 bytes` and
  `gallery.png, image, 1.6 MB`. Both exposed Remove and Open named actions.
- Clicking the text card opened Quick Look with the fixture contents. Clicking the image card
  opened an image Quick Look window. Closing Quick Look returned to the same Attachments view
  and retained both cards.
- A temporary initial capture showed only the second card while the view transition was still
  settling; the next stable Attachments capture showed both columns correctly. No persistent
  missing-card defect reproduced.

The fixtures remain only in the isolated `com.taha.Attic.taskpanels.v2` store. The user's
original text/PNG sources were not moved, edited, or deleted.

## Updated compact composer UI test

`Scripts/run_local_ui_tests.zsh` was run with only
`AtticUITests.testCompactComposerAndSubtaskPanels`, fresh app/test identities and a new
result bundle. It did not reach application behavior: the test runner timed out while
enabling automation mode. One bounded retry with fresh identities failed the same way, so
no further automated retries were made.

Evidence:

- `.build/batch2-live/CompactComposer.xcresult`
- `.build/batch2-live/compact-composer.log`
- `.build/batch2-live/compact-composer-summary.json`
- `.build/batch2-live/CompactComposerRetry.xcresult`
- `.build/batch2-live/compact-composer-retry.log`
- `.build/batch2-live/compact-composer-retry-summary.json`

Both summaries contain: `The test runner failed to initialize for UI testing. (Underlying
Error: Timed out while enabling automation mode.)` This is an environment/automation
blocker, not a test assertion or product failure. Therefore the corrected Cancel and
Complete-anyway branches and child preservation were checked in the bounded manual follow-up
below. The automated switch/reopen assertions remain unverified; manual switching and fresh
reopen are covered above.

## Manual incomplete-child confirmation follow-up

A dedicated preview-only parent, `Batch 2 confirmation fixture parent`, was created with two
children. `Finished child fixture` was marked done and `Unfinished child fixture` was left to
do, producing the visible `1 of 2 complete` state.

- Clicking the parent's completion control presented the native `Complete this task?` sheet
  with the unfinished-child explanation and both `Complete anyway` and `Cancel` actions.
- Choosing `Cancel` returned to the task list with the parent still under `To do`, its
  completion control still `Mark done`, and the row still reporting `1 of 2 complete`.
- Reopening the same confirmation and choosing `Complete anyway` moved the parent to `Done`.
  Its row continued to report `1 of 2 complete`.
- Reopening the family surface directly confirmed `Unfinished child fixture` still exposed
  `Mark done`, while `Finished child fixture` remained selected with `Move back to To do`.

The dedicated fixture remains in the isolated preview store in this final state: parent done,
one child done and one child unfinished. The main panel was restored to unpinned state. No
existing fixture or user data was removed or reset. A compact observation transcript is in
`.build/batch2-live/confirmation-followup.txt`.

## Clipped-title keyboard disclosure

The exact prior global keyboard UI mode was `0`. A temporary `AppleKeyboardUIMode = 3` was
applied, the preview was restarted, and forward/reverse Tab traversal was attempted from an
unfocused and focused main panel. The task-row status/menu controls did not accept visible
keyboard focus through this route, so the expansion overlay could not be triggered or
visually assessed. No pass is claimed from the full accessibility label.

The prior setting was restored exactly to `0`; evidence is in
`.build/batch2-live/full-keyboard-access-prior.txt` and
`.build/batch2-live/full-keyboard-access-restore.txt`. No accessibility permission or
security control was changed.

## Remaining physical/live limits

- Card drag-out to Finder or an image-only receiver, copy name/type, and click-versus-drag
  disambiguation were not exercised. Cross-application destination geometry was not reliable
  enough in the available CUA surface.
- `Open` in the default editor, its read-only-copy behavior, and the editor's locked-file
  presentation were not exercised. Quick Look preview passed for both types.
- Hover-only remove ×, keyboard Delete removal and VoiceOver action filtering were not
  exercised. The fixtures were deliberately left in the isolated preview instead of deleting
  through UI without a separate destructive-action confirmation.
- One-image-only sizing was not isolated because the first fixture was retained. The observed
  two-card gallery stayed compact and the image occupied one 100 pt column.
- Long-list scrolling at the exact existing 240 pt cap, pinned-position retention, animation
  under Reduce Motion, and legacy pre-Batch-2 attachment stores were not exercised.
- The host automation-mode timeout blocked the full automated lifecycle flow; the confirmation
  branches and child preservation passed the bounded manual follow-up above.

No production or test source was edited. The exclusive UI lock was released after the pass.
