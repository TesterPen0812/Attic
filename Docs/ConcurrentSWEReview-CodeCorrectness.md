# Concurrent SWE Review — Lane 1: Code Correctness, Architecture, Concurrency, Lifecycle

- **Checkout:** `/Users/taha/Developer/attic-task-panels-v2` (branch `codex/attic-task-panels-v2`)
- **Baseline:** `ae6418c1af690e29d15a20344cdb9765a23d3f85` + existing dirty working tree (~51 files, +7.6k/−2.1k)
- **Method:** Read-only source inspection. No builds, no tests run, no app launch, no pointer use. Native/visual items are marked `UNVERIFIED` even where the mechanism looks right.
- **References:** `Docs/ConsolidatedDefectChecklist-2026-09-13.md`, pasted UX spec (`pasted-text.txt`), `AGENTS.md`.

## Coverage

Fully traced: `SubtaskPanelController` (all 1439 lines), `SubtaskPanelLayout`, `SubtaskPanelLifecycle`, `AtticPanelController`, `AtticPanel` + `AtticPanelHostingView`/`AtticPanelContentContainer` (all 1418 lines), `PanelSurfaceWindow`, `PanelSurfaceHostingView`, `PanelUIState`, `AtticPanelView`, `TaskRowView`, `TaskFamilyView`, `TaskSectionView`, `SubtaskPanelContent`, `TaskAttachmentDrop`, `TaskImageAttachments`, `TaskComposerAttachments`, `TaskDragPayload`, `TaskImageReference`/`TaskImageFiles`, `AttachmentFileStore`, `PanelGeometry`, `CornerHoverMonitor`, `CornerHoverStateMachine`, `TaskStore`, `AppCoordinator`, `DailyCleanupService`, `NoteAttachmentPlatformSupport`, `TaskActionsMenu`, `AtticApp`. Skim-verified: `NoteStore` (error/lock surface), `NoteDraftController` (generation-gated tasks, `flush`/`close` semantics), Canvas bridge call sites.

Tests read: `SubtaskPanelControllerTests` (1807 lines, complete), plus test-name surveys of `SubtaskPanelTests`, `TaskAttachmentDropTests`, `CornerHoverStateMachineTests`, `SubtaskHoverPinnedUITests`.

---

## Findings

### F-01 — TP-003: Neutral hover still opens the task workspace — `CONFIRMED` · `P1`

- **Location:** `Attic/Window/SubtaskPanelController.swift` — `noteRowHover` → pending open → `lifecycle.openTransient(latched: false)` after `SubtaskPanelLayout.openDwell`; hover-governed presentation is the designed default and is cemented by tests (`SubtaskPanelTests.HoverOpenRequiresDwellToMature`, `SubtaskHoverPinnedUITests.testHoverDwellOpensTransientAndBriefHoverDoesNot`, `SubtaskPanelControllerTests.openByHover` used throughout).
- **Checklist ruling:** TP-003 — "A neutral hover should only reveal the row surface/actions; opening the workspace must require a deliberate action."
- **Causal chain:** `TaskFamilyView` installs hover reporting for hover-worthy families → `noteRowHover(enter)` arms `pendingOpen` at `openDwell` → timer matures → `presentTransient` shows the surface unlatched. Row-leave schedules `pendingClose` at `closeGrace`. None of this requires a click.
- **Impact:** Exactly the behavior the checklist orders removed — the workspace still navigates on ~0.5 s of dwell.
- **Assessment:** The code is internally consistent and heavily defended (corridor transit, approach tracking, latch, busy-defer, suspended close). This is a **deliberate design retained against an explicit defect ruling**, not an implementation accident. If TP-003 stands, hover-open must be removed outright — the corridor/dwell machinery only remains meaningful for *dismissal* safety around deliberately opened panels. If the product owner re-scopes TP-003 to "no *unexpected* hover navigation," the current latched/unlatched split is a defensible answer and this finding downgrades.
- **Recommended repair (if ruling stands):** Remove the hover `pendingOpen` path; keep hover only for row affordance reveal and for the safe-dismissal corridor of already-open surfaces. Re-home entry affordances (count control, row click, menus) as the sole open paths.
- **Validation:** Native: neutral hover over a family row for >1 s opens nothing; deliberate open paths all still work; existing hover-open tests replaced with hover-non-navigation tests.

### F-02 — TP-004: Row-menu "Show attachments" opens a fresh workspace on Attachments — `CONFIRMED` · `P2`

- **Location:** `Attic/Views/Panel/TaskRowView.swift:399-400` — `Button("Show attachments") { subtaskPanels.openFamilyPanel(for: task.id, focusEntry: false, view: .attachments) }`. Honored for a fresh open at `SubtaskPanelController.swift:629` (`panelViews.set(requestedView, …)` before `presentTransient`).
- **Checklist ruling:** TP-004 — "A newly opened task workspace must begin on Subtasks; switching to Attachments happens from the control inside the subpanel."
- **Causal chain:** Menu action on a closed family → `openFamilyPanel(view: .attachments)` → `panelViews.set(.attachments)` → `presentTransient` → first paint is the gallery.
- **Impact:** New workspaces can appear on Attachments from a main-list menu, contradicting the predictable-entry ruling.
- **Note:** The `view:` parameter itself is correct and required — `revealImportedAttachments` (`SubtaskPanelController.swift:687`) uses it so a completed import surfaces Attachments. The defect is only this call site.
- **Recommended repair:** Drop `view: .attachments` from the menu action (open on Subtasks), or remove the menu item and let the in-panel switch own Attachments.
- **Validation:** Update `testExplicitViewRequestsAndSubtaskEntryChooseTheirView` expectations; native check that the menu path lands on Subtasks.

### F-03 — TP-005: Attachment-picker owner mark has no recovery when `NSOpenPanel` is unreachable — `CONFIRMED` mechanism · `P1`

- **Location:** `Attic/Views/Panel/TaskImageAttachments.swift:71-115`.
- **Causal chain:** `choose`/`chooseForComposer` set `taskAttachmentPickerOwnerID` / `isComposerAttachmentPickerPresented` **before** `panel.begin`, and clear them **only inside the `begin` completion**. `NSApp.activate()` precedes `begin`, but `begin` is an unanchored floating panel — nothing re-verifies that it ordered in on a visible screen, and no watchdog, cancel path, or owner-teardown binding exists. If the panel is present-but-unreachable (the TP-005 reproduction: in the window list and a11y tree, not on screen), the mark is held forever.
- **Impact when triggered:** `isPresenting` stays true → every Add-attachment affordance is `.disabled` permanently (consistency is uniform — the "enabled-looking dead button" sub-symptom is fixed). Worse, the mark feeds `.taskConfirmation` (`PanelUIState.swift:73-74`) → `isInteractionLocked` → main-panel auto-hide refuses, and `familyEditBusy`/`surfaceInteractionBusy` (`SubtaskPanelController.swift:471,532`) pins the owning surface open. An invisible picker deadlocks the panel system until the mark is cleared, and nothing clears it.
- **Recommended repair:** After `begin`, assert the panel window is ordered onto a connected screen (re-order/re-center if not); clear the mark if the panel fails to become visible or its screen disconnects; bind picker teardown to surface teardown where appropriate so a dead host can't strand the mark.
- **Validation:** Native repro (space/display changes during presentation; forced offscreen frame). Unit seam: mark clears when the presented window never becomes visible.

### F-04 — `releaseFamilyInteractionState` omits `confirmingTaskCompletionID` — `CANDIDATE` · `P3`

- **Location:** `Attic/Window/SubtaskPanelController.swift:979-999` vs. writer `TaskRowView.swift:119-135` and contributor `PanelUIState.swift:73`.
- **Causal chain:** A child row inside a surface can raise "Complete this task?" (`acceptTaskDrop` at `TaskRowView.swift:432-441`) → `confirmsIncompleteCompletion` → `uiState.confirmingTaskCompletionID`. Surface teardown calls `releaseFamilyInteractionState`, which clears `editingTaskID`, `confirmingTaskDeletionID`, `focusedSubtaskParentID` for surface-hosted children — but not `confirmingTaskCompletionID`, even though the function's own comment exists to prevent exactly this orphaned-lock class. The row's clearing writer is `@State`-local and dies with the host.
- **Reachability analysis:** I could not confirm a live trigger. While the alert holds the mark: pointer-close defers (`familyEditBusy` covers it, `:469`), `toggleFamilyPanel` refuses (`:711`), main-panel hide is refused by the `.taskConfirmation` lock itself, `closePinned`/`unpinPinned` are sheet-blocked on the same window, family deletion clears the mark via `reconcileTaskIDs` (`PanelUIState.swift:207-209`), `selectSection` clears it (`:169`), and SwiftUI's `isPresented` write-back clears it if the host row dismantles. The gap is real but appears defended by accident on every path I traced.
- **Impact if reached:** Stale `.taskConfirmation` → `isInteractionLocked` permanently → auto-hide dead with no user-visible cause.
- **Recommended repair:** Add `if isSurfaceHostedChild(uiState.confirmingTaskCompletionID) { uiState.confirmingTaskCompletionID = nil }` beside the delete-confirmation clear. One line, defense-in-depth.
- **Validation:** Unit test mirroring `testPinnedCloseReleasesConfirmation` for completion confirmations.

### F-05 — TP-007: Attachment-error row is bounded but not dismissible/recoverable — `STRONG EVIDENCE` · `P2`

- **Location:** `Attic/Views/Panel/SubtaskPanelContent.swift:663-672` (`errorRow`: 11 pt red, `lineLimit(3)`, inside the footer capsule below the composer); clearing relies on `TaskStore.lastErrorMessage`, which only changes on subsequent store writes.
- **Checklist asks:** "compact, readable, dismissible/recoverable message that preserves composer layout."
- **Assessment:** "Compact" and "layout-preserving" are now met in source (3-line cap, footer-scoped). "Dismissible/recoverable" is not — no dismiss control exists and the message persists across unrelated later work. Whether a long error still visually dominates needs native confirmation.
- **Recommended repair:** Dismiss affordance (clear `lastErrorMessage`) and/or auto-expiry; keep the bounded presentation.
- **Validation:** Native: oversized-file failure in both panel views; confirm dismissal and that composer layout is undisturbed.

### F-06 — TP-006: Ghost-panel lifecycle after pin → drag → unpin → detach — `UNVERIFIED`

- **Source assessment:** The sequence is coherent in code. `pinFamily` retains the live window (`SubtaskPanelController.swift:817-822`); pinned drags use `DragHandleNSView`/`performDrag` without touching transient state; `unpinPinned` (`:835-867`) reuses the same window as a detached transient and `configureSurface` re-arms transient-mode swipe/Escape/drag callbacks (`:1036-1049`); `releaseFamilyInteractionState` correctly no-ops because a live surface remains. `windowWillClose`, generation-owned swipe sessions, and `SurfaceFrameAnimationTargets` pruning all check out. The 272×246 flicker, dead hover, and stuck help-tag a11y tree from the reproduction are AppKit/SwiftUI-runtime phenomena that source inspection cannot confirm or clear.
- **Validation:** Native replay of the exact sequence; watch `lifecycle`/`pinnedSurfaces` consistency and the a11y tree after each step.

### F-07 — TP-002: Fixed-chrome scroll masking — mechanism present, adequacy `UNVERIFIED`

- **Location:** `SubtaskPanelContent.swift:142-157` (header gradient `windowBackgroundColor` 0.92→clear), `:456-467`/`:576-607` (scroll content padded by measured `headerHeight`/`footerHeight`), footer `.atticGlassControl(Capsule())` at `:489-500`.
- **Assessment:** The under-scroll depth effect is deliberately preserved and bounded by measured chrome heights — `STRONG EVIDENCE` the masking design is implemented. Whether 0.92→clear gradient gives enough separation that "text and controls never collide" is a pixel call → `UNVERIFIED`.

### F-08 — TP-008: External attachment drag preview — `STRONG EVIDENCE` improved · visual `UNVERIFIED`

- **Location:** `TaskImageAttachments.swift:326-332` — `dragPreview` is now a single-line `Label(filename, systemImage:)` on a `.regularMaterial` capsule: compact, icon-led, tail-truncated. The "large dark multiline pill" mechanism is gone from source.

### F-09 — TP-009: Attachment drag jank — `UNVERIFIED`

- **Source assessment:** Providers are lazy (`TaskDragPayload.swift:23-56` registers file reps resolved only on demand; the own-process card marker is a second, lower-fidelity rep); staging is async and sequential (`TaskAttachmentDrop.swift:152-176`); nothing copies during layout (per `TaskDragPayload.swift:7-9`); `TaskAttachmentCardDrag.begin` is a cheap store lookup; drop-targeted state is set-union'd and reset on any drop (`:350-369,490-493`). No eager work on the drag path remains in source; actual frame behavior is native-only.

### F-10 — TP-001: Hidden row overflow menus — `PASS` in source · pixels `UNVERIFIED`

- **Location:** `TaskRowView.swift:56` (`showsRowAffordances`), `:359-384` (glyph `.opacity(showsRowAffordances ? 1 : 0)` + `.allowsHitTesting(showsRowAffordances)` + `.accessibilityHidden(!showsRowAffordances)`, footprint reserved via `.fixedSize`/`frame`).
- **Assessment:** Hidden means inert — no invisible click target, no VoiceOver element, no layout shift, context menu still reachable. All rows (main list and subpanel children) share this one view. Visual confirmation is a native check.

### F-11 — Section switch drops quick-entry focus before note-draft close refusal — `CANDIDATE` · `P3`

- **Location:** `AtticPanelView.swift:766-769` — `isQuickEntryFocused = false` and `.quickEntryFocus` released before `guard noteDraft.close() else { return }`. A refused close returns with the side effects already applied. Nearly unreachable (the field can't be focused while Notes is selected), but the ordering is wrong: the refusal check should precede mutations.

### F-12 — Dead `.hide` branch in dock-release policy — `PASS` (note) · `P3`

- **Location:** `PanelGeometry.swift:322-339` — `PanelDockingPolicy.releaseAction` only ever returns `.dock`; the `.hide` case handled in `AtticPanelController.endWindowDrag` is unreachable. Intentional per the comment ("header drags only reposition") — harmless leftover, no action needed beyond awareness.

### TP-020 — Composer/list collision — `UNVERIFIED` (layout-dependent; native lane).

---

## Important passing areas (`PASS`)

- **Suspended close, no timer spin:** an expired close that finds its surface locked moves to `suspendedClose`, dispatches nothing while locked, and re-judges exactly once on lock release (`SubtaskPanelController.swift:389-433`). Tested exhaustively (`testProtectedHoverClose…`, `testRepeatedProtectedDeadlines…`, `testWaitingCloseNeverOutlivesReplacementPinDetachOrTeardown`, `testControllerWaitingOnALockStillDeallocates`).
- **Corridor/dismissal safety:** transit defers closes with a bounded budget, arrival cancels outright and resets the budget, approach tracking defers row switches only while measurably approaching (`SubtaskPanelLayout` pointer coverage + `TransientTravel`). Tested (`testCorridorTransit*`, `TravelDefers…`, `TravelYields…`).
- **Swipe dismissal:** precise-scroll only, horizontal dominance, velocity-aware completion, eligibility re-checked at completion (busy/pinned/stale sessions all decline) — `PanelSurfaceWindow` + controller session keys. Tested.
- **Pin/unpin ownership:** pin retains the live window and position; pinned families are independent; unpin re-anchors as detached transient or dismisses cleanly without the main panel; busy-transient eviction is guarded (`:837-839`). Tested.
- **Teardown hygiene:** child edits, delete-confirmations, and stale focus pointers are released on every close path (`releaseFamilyInteractionState`); parent-owned work on the main-list row correctly survives. Tested (F1–F4 regression tests). See F-04 for the one missed field.
- **Lock scoping:** `shouldDeferPointerClose` counts only surface-owned locks + `.subtaskComposer` — unrelated panel work can't pin a surface (`:439-442`). Tested (`testUnrelatedLocksDoNotDeferSurfaceClose`).
- **Composer lock:** `.subtaskComposer` engages only while a live transient holds a draft/focused entry — pinned-surface and retained drafts never lock the main panel (`:542-557`). Tested (R1 suite).
- **Focus ownership:** `isLiveSurface`/`isLiveSurfaceKey` gate resign/reclaim so dying hosts can't clear a replacement's focus claim (`:485-504`, `SubtaskPanelContent.swift:243-262`). Tested.
- **Outside-click:** source-row exclusion, transit-gap clamp, `lastOutsideDismissal` toggle-eat protection (`:715-724`). Tested.
- **Drag/drop routing:** task > card > files > data-minus-markers classification is coherent; own-owner card refusal + marker revalidation + digest-verified copy (`TaskAttachmentDrop.swift:45-71,274-290`, `TaskImageFiles.importCopies`). Tested (`TaskAttachmentDropTests` suite).
- **Drop-target lifecycle:** panel-wide highlight uses a source set reset on any drop; callbacks hold the target weakly — deallocation proven by `testDismantledFamilySurfaceReleasesTheOwnersItsDropTargetCaptured`.
- **Import durability:** `AttachmentFileStore` serializes all FS work on the actor, balances security-scope, coordinates reads, enforces count/size limits, stages + rolls back batches, verifies SHA-256 on every materialized use, and the orphan sweep is conservative (dates, symlinks, shape checks). Tested.
- **Composer attachments:** generation-gated imports — cancel/delete cleans only the composer's own copies; `didBind` transfers ownership on the single save. Tested.
- **Reveal context:** import-reveal only re-opens when the transient hasn't changed since drop time (`:669-700`) — no stealing a panel the user moved to. Tested.
- **Window interaction lifecycle:** `PanelInteractionLifecycle` + escape monitor + local/global mouse-up monitors + 200 ms capture watchdog recover any lost mouse-up (`AtticPanel.swift:1170-1252`); resign-key cancels sessions; docked-edge resize constraints.
- **Attachment safety:** Quick Look reads the digest-verified private copy; external Open gets a 0o444 disposable copy; executable/script/package types preview-only (`NoteAttachmentPlatformSupport.swift:65-86`, `TaskImageFiles.openableCopy`).
- **Auto-hide state machine:** generation-owned transitions, hide gated on `noteDraft.flush()`, locks block hide (tested in `CornerHoverStateMachineTests`).
- **Popover mark hygiene:** `presentedTaskAttachmentsID` cleared by row `onDisappear` (`TaskRowView.swift:115-118`) and `reconcileTaskIDs` — the pattern F-04 should mirror.
- **Local-first:** cloud-sync paths exist but stay dormant; `AppCoordinator` uses isolated test defaults/roots; daily cleanup uses local-day `completedAt`; duplicate-UUID mutations apply to every replica (`storedTasks(matching:)`).

## Test-suite assessment

- **Strong:** controller semantics are deeply protected with presentation suppressed — lifecycle, locks, corridor, swipe, pin/unpin, drafts, view state, drop-target lifetime, deallocation. `TaskAttachmentDropTests` cover classification, staging, rollback, card-copy, sweep, reveal-context. `CornerHoverStateMachineTests` cover dwell/locks/pin/hide timing. `SubtaskHoverPinnedUITests` are genuine native tests for hover-open, pin, drag, escape, padding hit-testing.
- **Gaps (invariant protection):**
  - `presentationEnabled = false` in every controller test — no unit test ever creates a `PanelSurfaceWindow`; window-level invariants (ordering, delegate callbacks, a11y tree, ghost states like TP-006) are only covered by the small UI suite.
  - `confirmingTaskCompletionID` has no release-path test — the F-04 omission survives precisely because the suite only protects the fields that were remembered.
  - No test asserts picker-mark clearing on a failed/invisible presentation (F-03's watchdog would need a seam).
  - No rendered-pixel coverage anywhere for TP-001/TP-002/TP-007/TP-008/TP-020 — all remain native-verification items.

## Deferred-scope note

CloudKit/APNs/iPhone behavior was not evaluated — `handleCloudSyncEvent` exists in `TaskStore` but the contract keeps it dormant in `ATTIC_LOCAL_ONLY` builds; nothing here validates or claims deferred functionality.
