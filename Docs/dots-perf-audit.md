# Attic performance audit — in progress

Target: `phase-3/pd-batch17` at `d503231d6d33459e09b158d4e7f34d7ecbfd39cd`; comparison `phase-3/hosting-layout` at `0261cd2186091f42a9d12758d542afc0d9d97f9b`. Static Linux review only. No macOS build, run, profiling, or timing in this audit. The owner-supplied AX-on click measurements are baseline observations, not measurements made here. No app code changed. `AGENTS.md`, `README.md`, and `Docs/README.md` read. Dormant mobile and CloudKit are outside scope.

## O-1: resize — initial checkpoint

### DP-1 (P1, suspect): Every changed size publishes through the shell as well as AppKit layout
- Chain: `Attic/Window/AtticPanel.swift:2287–2302, 2333–2358, 2441–2445` → `Attic/Window/AtticPanelController.swift:1029–1036, 1230–1234` → `Attic/Window/PanelUIState.swift:200, 352–359` → `Attic/Views/Panel/AtticPanelView.swift:52–71, 145–149, 186–217`.
- Trigger: custom grip drag. Every delivered drag computes a frame, synchronously calls `setVisibleContentFrame(..., display: true)`, and calls `updatePanelSize`; `windowDidResize` also calls it. The 0.25-point equality guard prevents a second publication for an identical size; do not assume two actual publications per event. Each changed publication feeds `PanelRelevantUIStateObserver.objectWillChange` for the root shell, whose `panelSize` drives `PanelPageLayout`, page transitions and kept page positions. This is additional SwiftUI state propagation on top of the already assigned single-host hidden-page layout issue, not a claim that the existing hosting-layout fix solves resize.
- Scaling: approximately one root publication per distinct size (not necessarily per input event after the guard), plus work in size-dependent descendants; cost can grow with mounted pages and their current content. The exact number of body evaluations and AX updates is not established by static code. `settings.persistPanelSize` occurs at `endLiveResize` (controller 1265–1277), not on each drag, so per-frame preference writes are not supported by this path.
- Smallest cause-level direction: coalesce size publication to the latest size per display frame and isolate size-dependent shell/layout inputs from unrelated state, while AppKit remains authoritative and the actual visible geometry, hit regions and resize interaction stay live. Test whether eliminating the duplicate path is sufficient before changing architecture.
- Confidence: high for call chain, medium for contribution to visible jank. No independent attribution in milliseconds.
- Mac measurement: add signposts around `mouseDragged`, `setContentFrame`, `updatePanelSize` changes, root body and `panel_host_layout`; correlate event IDs and count per display frame, AX on/off, with 1 vs 5 previously built pages and 10/1,000 tasks. Count emitted panel sizes and root evaluations; ensure visual resize follows each presented frame. Guard test: feed a burst of size inputs to a controlled frame scheduler and assert at most one publication per frame, latest size delivered, and exact final size on release. Do not assert wall-clock timing.

### DP-2 (P1, suspect): Island follows resize through separate native windows and a size-dependent glass tree
- Chain: `AtticPanelController.windowDidResize` (1230–1235) → `layoutIsland` (1910–1917) → `PanelIslandWindows.layout` (`Attic/Window/PanelIsland.swift:1393–1404`). It calculates frames and, when changed, calls `setFrame(..., display: island.isVisible)` on the island and label windows; the stand-in is placed as well. Independently the changed `$panelSize` reaches `PanelIslandKeyed` (1095–1107), which updates its environment and `PanelIslandSurface` (944–975), including native glass sizing, multiple shadow layers and an offscreen destination-out mask.
- Scaling: up to two changed native child-window frame commands and one island size-state change per distinct resize step; visual material/mask work is fixed per island rather than per task. Window geometry may differ only on some resize edges and the equality checks avoid redundant `setFrame`s. Whether SwiftUI/AppKit recomputes or composites those layers on each change must be measured; do not assert GPU cost as measured fact.
- Smallest fix: coalesce frame positioning and island environment updates to one latest-frame transaction per display refresh; skip the label frame command when the computed frame is unchanged. Preserve the exact glass, shadows, alignment and accessibility. Do not replace or flatten the accepted look without visual equivalence.
- Confidence: high for call chain and per-change work, medium for contribution; likely smaller than large hidden-page layout until profiled.
- Mac measurement: signpost `windowDidResize`, island layout, each window `setFrame`, stand-in placement, island root/body, Core Animation commits and GPU offscreen passes. Compare with instrumented island updates suppressed in a disposable diagnostic build, not a product recommendation. Guard test: 100 synthetic resize callbacks in one frame produce at most one final island/label placement, no frame drift, and correct final geometry for all corners/spots.

### DP-3 (P1, suspect): Notes table remeasures every cell as width changes
- `Attic/Notes/Engine/NoteTableView.swift:184–199, 328–342` → `Attic/Notes/Engine/NoteTableAttachment.swift:58–87` → `Attic/Notes/Engine/NoteTableLayout.swift:121–135`.
- Trigger: resizing a panel that has a mounted Notes editor containing a table. A table view width change over 0.25 pt invalidates the attachment layout, then `refreshLayout()` requests the new width. A cache miss creates per-cell arrays and `make` visits natural width, minimum width and wrapped height for cells. Text caches can reduce actual text measurement, but new widths can miss height entries. This is a resize-specific path, distinct from PF-11's cell-edit cost. Whether a hidden editor is laid out under the already-known host behavior must be measured.
- Scaling: O(rows × columns) visits and array slots per invalidated table width, plus text measurement for cache misses; multiplied by mounted table attachments and distinct widths. Not all visits necessarily invoke expensive text measurement.
- Smallest fix: preserve natural/minimum per-cell metrics across width-only changes, compute only width-dependent height where its effective column width changed, and coalesce width updates per display frame. Preserve exact wrapping, geometry, selection and accessibility; do not defer visible geometry past its presented frame.
- Confidence: high for explicit loops and cache invalidation, medium for frequency and perceptible cost under AppKit.
- Mac measurement: signpost `setFrameSize`, attachment `layout(width:)`, `NoteTableLayout.make`, and text-cache hit/miss/height measurements; count cell visits per resize frame for 10×5, 100×20 and multiple tables, with Notes visible versus retained hidden and AX on/off. Guard test: unchanged widths perform no full grid recompute; changed widths recompute only affected columns' height metrics and preserve exact row heights and hit geometry.

### DP-4 (P2, stress-scale suspect): Draw recalculates full-scene coverage on every board frame-size call
- `Attic/Draw/Engine/DrawBoardView.swift:161–167, 191–210, 227–257, 262–274`.
- Trigger: resize while Draw's board view receives `setFrameSize`. It invalidates detail, repositions layers and calls `requestRaster`; before comparing `requestedKey`, `currentKey()` calls `rasterCoverage()`, which unions `model.objects` and may also scan moved/replaced objects. A matching key prevents a new world raster, so it would be incorrect to claim every size step rerenders the whole scene. Detail cancellation/rescheduling may still occur on this path when higher-density detail is needed (285–304).
- Scaling: O(number of scene objects) main-thread bounds work per size callback, plus selection/layer geometry; a detail request may be restarted after a 35 ms settling delay. Bitmap work depends on key changes and renderer cancellation, not proven per step.
- Smallest fix: cache scene coverage by content revision and movement/replacement identity; reuse on a viewport-size-only change. Coalesce detail settling without changing displayed content or input mapping. Preserve full-scene coverage and cancellation safety.
- Confidence: high for repeated `currentKey` traversal, medium for its frequency and effect; hidden board behavior and `model.isShown` guard matter.
- Mac measurement: signpost frame-size, coverage computation, object visits, world/detail raster requested/completed/cancelled and frame time; resize a board with 10, 1,000 and 10,000 objects, visible and retained hidden. Guard test: repeated frame sizes with unchanged content visit no scene objects after first cached coverage, and mutation/move invalidates it correctly.

### O-1 ranking and open questions
1. Known single-host layout across retained pages: already assigned; no new DP finding. It is likely a major contributor but no resize measurement isolates it.
2. DP-1 root size publication/invalidation, coupled with actual reflow: likely material, unmeasured.
3. DP-3 table remeasurement when a large table is mounted; DP-4 Draw coverage when a large scene is mounted. Relative order depends on page and data, unmeasured.
4. DP-2 island native windows and glass/mask work: plausible additive cost, unmeasured.
Fix/measure in that order, preserving geometry and visuals. Further trace Notes text reflow, Calendar geometry, AX frame propagation and floating-panel interaction before finalizing O-1. None of these suspects is assigned a percentage or independent millisecond cost.

## O-2: task scrolling
Not yet reviewed.

## O-3: first clicks
The `0261cd21` comparison was confirmed and its task row modifier changes `.focusable(enabled)` to `.focusable(enabled && (!focus.singleNativeResponder || focus.isFocused))` (`Attic/DesignSystem/Components/AtticTaskComponents.swift`, comparison branch around 413–425). This is H-01, already known and not re-filed. The branches differ in many unrelated changes, so a whole-branch diff cannot attribute any remaining timing to this change alone. Further review pending.

## Whole-app review
Not yet reviewed. PF-1–PF-50 and the assigned one-host issue are exclusions, not newly discovered findings.

## Summary and coverage at this checkpoint
- DP findings: 4 static resize suspects; neither is measured on the owner's Mac.
- O-2, O-3 and whole-app top 15 are not complete. No folder has been read fully file by file.
- Mac work: instrument resize input → frame set → size publication → host/layout → AX and Core Animation, separating island work from shell work.
- Checkpoint after O-1 shell, island, table and Draw tracing; remaining O-1 subpaths and all subsequent areas still need review. Continue rather than treat this checkpoint as a final audit.
