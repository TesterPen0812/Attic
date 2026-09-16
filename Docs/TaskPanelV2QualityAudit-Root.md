# Independent root quality audit

Independent findings frozen before reading either new SWE report. Source reviewed in `/Users/taha/Developer/attic-task-panels-v2`, branch `codex/attic-task-panels-v2`, HEAD `ae6418c1af690e29d15a20344cdb9765a23d3f85` plus existing working changes. Exact inspected source hashes and timestamp: `.build/quality-audit/root/source-manifest.json`. Contract: `Docs/TaskPanelV2QualityChecklist.txt`.

## Judgment

Not ready for an unconditional checklist pass. Two definite UX contract mismatches remain, and task-list rendering has avoidable scaling costs. Existing successful tests do not settle native polish or explain the reported lag. This independent pass is source inspection plus isolated executable benchmarks, **not** a native UI acceptance run. SWE-B has exclusive native pointer ownership; I did not interfere or read its findings. Prior suite/live reports are not substituted for my own evidence.

## Findings

### ROOT-01 — Repeated family scans and eager rows are a performance defect at scale (P1)

`TaskStore.swift:721` filters all tasks on every `subtasks(of:)` call, calls a linear parent lookup for each matching child, then sorts. `TaskFamilyView.swift:15–22` independently evaluates this three times for one displayed summary. `TaskSectionView.swift:34` instantiates the entire section in a VStack. A LazyVStack around sections does not make those rows lazy. The family and row views also observe shared store/UI/controller objects, so broad changes can revisit this work.

Executable evidence: `.build/quality-audit/root/FamilySummaryBenchmark.swift` embeds the actual current parent/subtasks method bodies, compiled with `swiftc -O`. Plain class fixtures have five children per parent, parents first in storage, equal creation dates and manual order; nine samples per size. Median summary passes: 30 parents/180 total tasks **0.705 ms**, 100/600 **4.582 ms**, 300/1,800 **33.141 ms**, 1,000/6,000 **357.285 ms**. Checksums prevent discarded results. These are synthetic algorithm timings, not app frame times; real SwiftData, sort ties, storage order and invalidation frequency may change the result. They establish costly repeated work, not a trace proving the user's particular lag.

Repair direction: revision-scoped family indexing/summary caching, calculate one children snapshot per evaluation, and assess row-level lazy rendering without breaking anchors, drag targets or retained panels. Cache invalidation must cover mutation, rollback, import/context replacement and duplicate-safe semantics. Profile active native scrolling/typing before and after with identical fixtures. Do not merely shorten animation durations.

### ROOT-02 — Attachment metadata is repeatedly JSON-decoded while drawing rows (P2)

`TaskItem.swift:25` decodes references afresh on each `attachments` read. `TaskRowView.swift:84,142,289–311` queries this repeatedly for presence, payload, previews and count/accessibility text. This is avoidable parsing on a display path; rows observe broad shared state.

Independent optimized Codable benchmark with matching stored fields, four references per row, six reads per row: 30 rows **2.923 ms**, 100 **5.081 ms**, 300 **12.817 ms** (median of nine). Evidence: `AttachmentDecodeBenchmark.swift` and matching `.txt` under the root evidence directory. This deliberately isolates decoding; it is not a measured count of native body evaluations and must not be added to ROOT-01 as a claimed frame duration. Reuse one decoded snapshot or an appropriately invalidated cache; no new file/image bytes should enter row queries.

### ROOT-03 — Neutral hover still opens/switches family panels (P2, definite contract failure)

`TaskFamilyView.swift:58–63` reports entry to `noteRowHover`; the controller/lifecycle still schedules hover opens. This contradicts latest section 13, “Neutral task-row hover only highlights the row.” Existing `testHoverSwitchWhileOpenUsesFastDwellThroughTheController` protects the old behavior, illustrating why passing tests alone cannot validate the new contract. Keep explicit row activation and dragged-panel retention, and update hover tests intentionally. No native reproduction performed by root in this pass.

### ROOT-04 — Outside-panel menu can open directly on Attachments (P2, definite contract failure)

`TaskRowView.swift:399–400` exposes Show attachments and calls `openFamilyPanel(... view: .attachments)`. `SubtaskPanelController.swift:579–629` honors the requested view on both existing and newly presented families. Latest section 3 requires opening on Subtasks and deliberate view switching inside the panel. Attachment-import reveal is an explicitly requested exception in section 7; a separate row-menu navigation shortcut is not. Remove that shortcut or route ordinary open to Subtasks while retaining import reveal. Existing `testExplicitViewRequestsAndSubtaskEntryChooseTheirView` tests implementation behavior, not this stricter contract.

### ROOT-05 — Resize motion can snap at display/overlap constraints (investigation, not confirmed visual defect)

`SubtaskPanelLayout.swift:282–350` recomputes overlap avoidance for a new height. `SubtaskPanelController.swift:1200–1215` animates only when the top, x and width remain unchanged; other geometry applies immediately. A taller view near the screen bottom or pinned neighbor can therefore take the immediate path. Some displacement is necessary to stay onscreen; source alone cannot judge whether it looks acceptable. Exercise small-to-large switches beside pinned windows and at all screen edges. If abrupt, animate a stable chosen anchor/clamped endpoint rather than snapping. Keep this distinct from confirmed failures.

## Checklist matrix

Partial means implementation support found but this independent pass has no fresh native screenshot/interaction proof. Listed tests are relevant existing coverage discovered in source, **not tests rerun by root**. No section earns Pass from code alone.

| Section | Result | Responsible components / evidence | Remaining verification |
|---|---|---|---|
| 1 Main task panel | Partial | TaskRowView; TaskFamilyView; `testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing` | Native fade, fixed height, full title focus, passive pointer styling; ROOT-01/02 |
| 2 Row actions | Partial | TaskRowView reserved 24-point glyph/menu, focus state | Real Tab/VoiceOver and repeated hover without shifts |
| 3 Task subpanel | Fail | ROOT-04; SubtaskPanelController; `testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView` | Remove external navigation exception, verify all opening paths |
| 4 View transition | Partial | SubtaskPanelContent/controller; `testViewSwitchPagesBothLayersTheSameWay` | Native rapid switches, constrained placement, Reduce Motion; ROOT-05 |
| 5 Sizing | Partial | SubtaskPanelContent; SubtaskPanelLayout; `testPanelContentIdealHeightFollowsTheActiveView` | Empty/small/large galleries and lists, fixed chrome, no excess empty area |
| 6 Attachments | Partial | TaskImageAttachments; TaskImageReference; TaskImageFiles | Native mixed files/counts, preview, hover removal; ROOT-02 |
| 7 Drag/drop | Partial | TaskAttachmentDrop; TaskRowView; `testDroppedFilesAttachToTheParentAndDiscardOnlyTheirStaging` | Actual Finder/card/task drags on all surfaces while scrolled |
| 8 Pinned panels | Partial | SubtaskPanelController; TaskRowView; `testOpenForPinnedFamilyDoesNotCreateTransient` | Native raise/focus/movement and repeated pin cycles |
| 9 Reachability | Partial | SubtaskPanelLayout/controller; `testPointerReachingTheSurfaceCancelsTheCloseOutright` | Native normal-speed paths with pinned obstacles after hover contract correction |
| 10 Trackpad dismissal | Partial | PanelSurfaceHostingView; SubtaskPanelLayout; `testHorizontalSwipeFollowsTheFingersInEitherDirection`, `testVerticalAndDiagonalScrollingNeverDismisses` | Physical two-finger movement, cancellation, pinning, Reduce Motion |
| 11 Composer attachments | Partial | AtticPanelView; TaskComposerAttachments | Native mixed picker/drop, pending removal, upward growth, submit failure/retry |
| 12 Appearance | Partial | AppearanceSettingsView exact explanatory copy; AtticStyle | Actual opaque/translucent surfaces with Glass controls in both modes |
| 13 Hierarchy/polish | Fail | ROOT-03; TaskFamilyView hover handler | Verify neutral hover only highlights and no hidden navigation |
| 14 Regressions | Partial | Store, lifecycle, drop and host tests | Native smoothness plus source-quality repairs, persistence/rollback checks |
| 15 Evidence | Partial | This report + two reproducible optimized benchmarks + source manifest | Native evidence still outstanding; no blanket completion claim |

## Scope and comparison protocol

Root changed no product code, tests, user data, settings or running-app state. Added only this audit and independent benchmark evidence. No unsolicited UX changes. No full suite was rerun merely to duplicate the preceding validation. Freeze this report before reading SWE-A/B, then compare overlap, unique findings, unsupported assertions, and native evidence. Deduplicate verified repair work into small Opus batches and require regression checks plus final Astra High review.
