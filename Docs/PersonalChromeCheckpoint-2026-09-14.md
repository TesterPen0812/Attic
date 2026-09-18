# Personal chrome checkpoint — September 14, 2026

## Scope and current status

SAFE SOURCE CHECKPOINT REACHED. Root has stopped before implementation delegation, as requested. This is a continuation record, not full-app visual sign-off or release approval.

The user requested root personally recover Fable's work, address task-opening latency and Siri-inspired scrolling/composer chrome, then STOP at a safe checkpoint before delegating implementation again. The September 14 follow-up permits the plus inside the composer and requires consistent controls/proportions. Do not restart Fable or dispatch SWE implementation automatically from this record.

## Source and recovery

- Checkout: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`, intentionally dirty; no commit/merge/push performed.
- Pre-root recovery: `/Users/taha/.codex/visualizations/2026/09/11/01a0920b-4833-7e52-9c7a-83c2d5ba570c/fable-recovery-20260914/` contains a verified 297-file archive, hashes, patch, Fable prompt, logs and worker reports.
- Root compared current files to that archive: exactly seven source/test files plus the consolidated checklist were changed. No missing archived files or unrelated source changes detected.
- Existing Fable changes remain intact. They are not all validated just because they compile.

## Root changes

- Main task composer: integrated neutral plus menu and text field in one slim Liquid Glass capsule, separate submit circle; 36-point height matches the main pin's visible size. Attachment picker and priority controls remain reachable from plus.
- Subpanel: integrated plus/entry capsule plus destination-view switch; composer, switch, pin and close use 32-point visible controls. Errors sit below the composer rather than wrapping inside it. Content sizing responds to measured header/footer height.
- Shared static opacity gradient retains a faint impression of scrolling content behind fixed chrome, fades at the panel edges, and preserves click shields. Reduce Transparency and increased contrast remove the underlay. No snapshotting, timer or extra blur pass added.
- Task changes reset the content identity; hosted root replacement disables insertion animation, and AppKit surface ordering has no default animation. View-switch and content-height transitions remain separate. Temporary diagnostics established one-click dispatch and synchronous visible-window presentation; the sampled replacement took about 24 ms including diagnostic writes. This is not a frame-pacing benchmark.
- Notes' existing 42-point composer clearance is preserved. No arbitrary shrink of the user's saved main window dimensions.
- Consolidated TP-002 wording now reflects the user's explicit under-scroll depth requirement, rather than implying content must be fully hidden.

## Validation recorded so far

- Local unit build succeeded; confirmation log `/tmp/attic-chrome-tests-confirm.log` reports TEST BUILD SUCCEEDED. A preceding quiet incremental invocation emitted a contradictory exit-zero compiler diagnostic; the explicit follow-up build succeeded.
- Final source: `/tmp/attic-offline-xctest/chrome-final-serial.log`: 182 tests, 2 skipped, no failures, exit 0. Suites: PanelGeometryTests, PanelSurfaceHostingViewTests, SubtaskPanelControllerTests, SubtaskPanelTests, TaskPerformanceGateTests.
- Both skips require an exclusive desktop visual-test run: native swipe completion/resource profile and swipe release/display-frame position. Neither is a pass.
- `git diff --check` passed. Final preview build, unit build (`chrome-tests-final-build.log`) and live process provenance verification passed.
- The preceding `chrome-final.log` run had one failure in `testInterruptedSwipeRestoresOnceAndRequiresAnotherBegin` while native pointer actions ran concurrently. Production routing consults `NSEvent.pressedMouseButtons`; overlap is a plausible environmental cause. The unchanged final source passed when the suite was rerun without automated UI input. Preserve both results; do not weaken the assertion.
- Root inspected native main composer, plus menu, task creation, priority expansion, scrolling under top/bottom chrome and an empty subpanel in the earlier preview revision. That inspection exposed stripped menu-label glass styling, corrected before the later integrated-plus direction.
- The initial Luna/root apparent single-click failure was corrected: CUA was returning the still-focused main window. Temporary diagnostics confirmed a single click reached the row handler with clickCount=1, the parent/controller were ready, and a visible subpanel was presented synchronously. A subsequent click replaced the 112-point empty panel with the 154-point one-subtask panel; trace file timestamps span about 24 ms, including diagnostic IO. Logs preserved in the checkpoint evidence directory. All diagnostic code was then removed; TaskRowView matches the recovered Fable version.
- Root visually confirmed the neutral integrated plus in the main panel and Subtasks/Attachments composers. Created a labelled task and eight disposable subtasks, verified bounded growth, scrolled under both header/composer, and switched to an empty gallery that shrank the panel. Text behind the subpanel title prompted a lower header-underlay opacity than the bottom underlay.
- Luna observed Subtasks ↔ Attachments, pin/unpin, Escape, subtask submission and retained counts, plus picker invocation; root cancelled that picker. No import occurred during this check.
- Root confirmed the plus menu exposes attachments and priority options, and task creation works. Real import, pending strip, oversized-error presentation, external dragging, physical trackpad cancellation, VoiceOver, full theme/contrast matrix and quantitative frame pacing remain hard review gates. Static screenshots are not passes for them.
- The final lower header-opacity refinement is build/test verified, but its final rendered scrolled state remains an explicit native review item: the user was actively operating Notes/Canvas during the final capture attempts.
- Native tool calls sometimes returned stale/no-window observations or user-interruption errors. Refresh full state and distinguish the focused-window screenshot from all visible panel state before filing defects.

## Preview

- App: `/tmp/attic-chrome-checkpoint-dd/Build/Products/Local/AtticChromeCheckpoint.app`
- Bundle: `com.taha.Attic.chromecheckpoint`
- Build/launch: `Scripts/launch_local_preview.zsh --display-name 'Attic Chrome Checkpoint' --bundle-id com.taha.Attic.chromecheckpoint --executable-name AtticChromeCheckpoint --derived-data /tmp/attic-chrome-checkpoint-dd --appearance dark`
- Verify the running image with the same command plus `--verify` before UAT. Preserve existing app data; only create clearly labelled disposable checks.

## Future SWE workflow after user continues beyond checkpoint

One SWE-2 Max implementer owns the working checkout at a time. Four SWE-2 Max reviewers inspect the same frozen source revision, with separate lanes:

1. Correctness/data: lifecycle, race conditions, persistence, failure/rollback, attachments, teardown.
2. Performance/resources: measured scrolling/typing/dragging/switching, main-thread work, memory and CPU. No smoothness claim from source inspection alone.
3. Requirements/regression/accessibility: entire consolidated checklist, not only changed lines; preserved prior protections, keyboard/focus, contrast, reduced motion/transparency and edge cases.
4. Native visual/interaction: actual app operations and every reachable changed state, including failures, cancellations, empty/full content, long names, attachment errors, drop previews, pinned/moved panels and scrolling.

Hard gates: baseline/source identity recorded; focused test/build success; fixes linked to reproducible evidence; reviewer findings reconciled; original reproduction rechecked; no unsupported closure. A blocked check stays blocked. Only one visual agent controls the pointer at a time. Do not overlap native AppKit swipe tests with pointer automation: the real pressed-mouse state is part of their production routing. Send confirmed findings back to the implementer and repeat focused review. Use Luna Max native fallback if SWE cannot operate a state, then return its evidence to the reviewers. Do not create redundant full review loops over unchanged passing areas.

## Orchestration and Synara

- Obsolete paused `continue-attic-batches-and-reviews` schedule deleted.
- `attic-fable-repair-review-loop` now named Attic SWE repair and verification, configured every 20 minutes and PAUSED at the requested stop point; prompt points to this checkpoint and holds implementation dispatch until user continues. Resume the schedule when orchestration resumes. Quiet for unchanged status.
- Main live Synara Coding agent concurrency raised 5 to 10 by delegated agent, verified by live overview. Database integrity passed; other integration fields unchanged.
- Protected DB backup: `/Users/taha/.synara/backups/state-before-concurrency-ten-20260914T014444Z.sqlite`.
