import XCTest
@testable import Attic

/// Controller-level behavior coverage: these exercise the real state
/// machine, draft/focus wiring, and interaction locks with window
/// presentation suppressed. Anything genuinely pointer- or pixel-bound is
/// listed in the native UAT ledger instead of being simulated here.
@MainActor
final class SubtaskPanelControllerTests: XCTestCase {
    private struct Harness {
        let store: TaskStore
        let uiState: PanelUIState
        let settings: AppSettings
        let controller: SubtaskPanelController
    }

    private let suite = "SubtaskPanelControllerTests"

    private func makeHarness() throws -> Harness {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let uiState = PanelUIState()
        let settings = AppSettings(defaults: defaults)
        let controller = SubtaskPanelController(store: store, uiState: uiState, settings: settings)
        // Tests steer "main panel visible" and screen-space anchors through
        // the seams; actual window presentation stays off.
        controller.presentationEnabled = false
        controller.mainPanelVisibleForTesting = true
        controller.anchorsAreScreenCoordinatesForTesting = true
        return Harness(store: store, uiState: uiState, settings: settings, controller: controller)
    }

    private func installAnchor(_ harness: Harness, for id: UUID) {
        harness.controller.updateTaskRowFrames([id: CGRect(x: 300, y: 400, width: 300, height: 42)])
        harness.controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 400, height: 800))
    }

    // MARK: - R1: only a live transient surface may hold the composer lock

    func testTransientDraftLocksMainPanelWhileSurfaceOpen() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)

        harness.uiState.subtaskDrafts[parent.id] = "unsaved"
        XCTAssertTrue(harness.uiState.interactionLockReasons.contains(.subtaskComposer))

        harness.uiState.subtaskDrafts[parent.id] = nil
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
    }

    func testRetainedDraftAfterDismissalDoesNotLockMain() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.subtaskDrafts[parent.id] = "kept"
        harness.controller.dismissTransient()
        XCTAssertNil(harness.controller.transientFamilyID)
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
        XCTAssertEqual(harness.uiState.subtaskDrafts[parent.id], "kept")
    }

    func testPinnedSurfaceDraftNeverLocksMain() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.pinFamily(parent.id)
        XCTAssertEqual(harness.controller.pinnedFamilyID, parent.id)

        harness.uiState.subtaskDrafts[parent.id] = "pinned draft"
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer))

        // Even the pinned surface's focused entry must not lock the main
        // panel: focus inside the pinned window is its own surface's affair.
        harness.uiState.focusedSubtaskParentID = parent.id
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
    }

    func testFocusedTransientEntryLocksWhileOpenAndReleasesOnClose() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.focusSubtaskEntry(for: parent.id)
        XCTAssertTrue(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
        harness.controller.dismissTransient()
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
    }

    func testMainPanelHideReleasesComposerLock() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.subtaskDrafts[parent.id] = "draft"
        XCTAssertTrue(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
        harness.controller.mainPanelDidHide()
        XCTAssertNil(harness.controller.transientFamilyID)
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
    }

    func testSectionSwitchWithDraftReleasesLock() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.subtaskDrafts[parent.id] = "draft"
        harness.uiState.selectSection(.notes)
        XCTAssertNil(harness.controller.transientFamilyID)
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer))
        XCTAssertEqual(harness.uiState.subtaskDrafts[parent.id], "draft")
    }

    // MARK: - R2: a pinned family's surface is the pinned window

    func testOpenForPinnedFamilyDoesNotCreateTransient() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        installAnchor(harness, for: parentA.id)
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)

        // Transient for B exists; opening A must not swap the transient's
        // family or touch B's content — A's surface is its pinned window.
        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, parentB.id)
        harness.controller.openFamilyPanel(for: parentA.id, focusEntry: true)
        XCTAssertEqual(harness.controller.transientFamilyID, parentB.id)
        XCTAssertEqual(harness.controller.pinnedFamilyID, parentA.id)
        XCTAssertTrue(harness.uiState.subtaskEntryActiveIDs.contains(parentA.id))
    }

    func testToggleOnPinnedFamilyKeepsTransientAlone() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)
        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        harness.controller.toggleFamilyPanel(for: parentA.id)
        XCTAssertEqual(harness.controller.pinnedFamilyID, parentA.id)
        XCTAssertEqual(harness.controller.transientFamilyID, parentB.id)
    }

    // MARK: - R3: edit-busy surfaces resist replacement; drafts live in uiState

    func testHoverSwitchDeferredWhileFamilyEditingChild() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        _ = try XCTUnwrap(harness.store.create(title: "Other child", parentID: other.id))
        installAnchor(harness, for: parent.id)
        installAnchor(harness, for: other.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.beginEditing(child)

        harness.controller.noteRowHover(familyID: other.id, isHovering: true)
        // The busy surface must not even schedule the pending open.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: SubtaskPanelLayout.openDwell + 0.2))
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)

        // Once the edit resolves, hover resumes normal behavior.
        harness.uiState.endEditing()
        harness.controller.noteRowHover(familyID: other.id, isHovering: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: SubtaskPanelLayout.openDwell + 0.2))
        XCTAssertEqual(harness.controller.transientFamilyID, other.id)
    }

    func testExplicitSwitchDeferredWhileFamilyConfirmationOpen() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        installAnchor(harness, for: parent.id)
        installAnchor(harness, for: other.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.confirmingTaskDeletionID = child.id

        harness.controller.openFamilyPanel(for: other.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)

        harness.uiState.confirmingTaskDeletionID = nil
        harness.controller.openFamilyPanel(for: other.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, other.id)
    }

    func testRenameDraftSurvivesPinAndUnpin() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.beginEditing(child)
        harness.uiState.editingDraftTitle = "Half-typed rename"

        harness.controller.pinFamily(parent.id)
        XCTAssertEqual(harness.controller.pinnedFamilyID, parent.id)
        XCTAssertEqual(harness.uiState.editingTaskID, child.id)
        XCTAssertEqual(harness.uiState.editingDraftTitle, "Half-typed rename")

        harness.controller.unpinPinned()
        XCTAssertNil(harness.controller.pinnedFamilyID)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
        XCTAssertEqual(harness.uiState.editingDraftTitle, "Half-typed rename")
    }

    func testToggleCloseDeferredWhileFamilyEditing() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.beginEditing(child)
        harness.controller.toggleFamilyPanel(for: parent.id)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
        harness.uiState.endEditing()
        harness.controller.toggleFamilyPanel(for: parent.id)
        XCTAssertNil(harness.controller.transientFamilyID)
    }

    // MARK: - R4: outside-click dismissal yields to owned surfaces

    func testMenuTrackingDefersOutsideDismissal() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.setInteractionLock(.menuTracking, isActive: true)
        // The dismissal decision consults locks; verify via the shared gate.
        XCTAssertTrue(harness.controller.surfaceInteractionBusy(parent.id))
        harness.uiState.setInteractionLock(.menuTracking, isActive: false)
        XCTAssertFalse(harness.controller.surfaceInteractionBusy(parent.id))
    }

    func testFamilyEditBusyCoversChildAndParent() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))

        harness.uiState.editingTaskID = child.id
        XCTAssertTrue(harness.controller.familyEditBusy(parent.id))
        XCTAssertFalse(harness.controller.familyEditBusy(other.id))
        harness.uiState.editingTaskID = parent.id
        XCTAssertTrue(harness.controller.familyEditBusy(parent.id))
        harness.uiState.editingTaskID = other.id
        XCTAssertFalse(harness.controller.familyEditBusy(parent.id))
        harness.uiState.editingTaskID = nil
        harness.uiState.confirmingTaskDeletionID = child.id
        XCTAssertTrue(harness.controller.familyEditBusy(parent.id))
    }

    // MARK: - R5: growth is clamped into the host screen

    func testPinnedGrowthBelowDisplayEdgeClampsInside() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 30, y: 10, width: 292, height: 120)
        let adjusted = SubtaskPanelLayout.pinnedResizedFrame(
            frame,
            newHeight: 390,
            screenVisibleFrames: [screen]
        )
        let resized = try XCTUnwrap(adjusted)
        let safe = screen.insetBy(
            dx: SubtaskPanelLayout.screenInset,
            dy: SubtaskPanelLayout.screenInset
        )
        XCTAssertLessThanOrEqual(resized.maxY, safe.maxY + 0.5)
        XCTAssertGreaterThanOrEqual(resized.minY, safe.minY - 0.5)
    }

    func testPinnedGrowthTallerThanDisplayShrinksToFit() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 30, y: 100, width: 292, height: 200)
        let resized = try XCTUnwrap(SubtaskPanelLayout.pinnedResizedFrame(
            frame,
            newHeight: 2000,
            screenVisibleFrames: [screen]
        ))
        XCTAssertLessThanOrEqual(resized.height, 900 - 2 * SubtaskPanelLayout.screenInset + 0.5)
    }

    // MARK: - R7: explicit replacement preserves drafts and edits

    func testReplacingPinnedFamilyKeepsAllDrafts() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        installAnchor(harness, for: parentA.id)
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)
        harness.uiState.subtaskDrafts[parentA.id] = "A draft"
        harness.uiState.subtaskDrafts[parentB.id] = "B draft"

        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        harness.controller.pinFamily(parentB.id)
        XCTAssertEqual(harness.controller.pinnedFamilyID, parentB.id)
        XCTAssertNil(harness.controller.transientFamilyID)
        // Replacement is explicit, and nothing typed anywhere is lost.
        XCTAssertEqual(harness.uiState.subtaskDrafts[parentA.id], "A draft")
        XCTAssertEqual(harness.uiState.subtaskDrafts[parentB.id], "B draft")
    }

    func testUnpinWithoutAnchorClosesCleanly() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        harness.controller.pinFamily(parent.id)
        // No row anchor published (main panel hidden): unpin simply dismisses.
        harness.controller.mainPanelVisibleForTesting = false
        harness.controller.unpinPinned()
        XCTAssertNil(harness.controller.pinnedFamilyID)
        XCTAssertNil(harness.controller.transientFamilyID)
    }

    // MARK: - Review round 2 regressions

    /// A repeated "Add subtask…"/"Show subtasks" on an already-latched family
    /// must still raise and activate the entry — the lifecycle rejects the
    /// duplicate open, but the user's intent is not the open itself.
    func testSameFamilyOpenStillActivatesEntry() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
        XCTAssertFalse(harness.uiState.subtaskEntryActiveIDs.contains(parent.id))

        harness.controller.openFamilyPanel(for: parent.id, focusEntry: true)
        XCTAssertTrue(harness.uiState.subtaskEntryActiveIDs.contains(parent.id))
        XCTAssertEqual(harness.uiState.focusedSubtaskParentID, parent.id)
    }

    /// Tearing down the surface that hosts an in-flight edit must not orphan
    /// the interaction lock — the main panel would stay unhidable forever.
    func testDismissalReleasesFamilyEditState() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.beginEditing(child)
        XCTAssertTrue(harness.uiState.interactionLockReasons.contains(.taskEditing))

        harness.controller.dismissTransient()
        XCTAssertNil(harness.uiState.editingTaskID)
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.taskEditing))
    }

    func testPinnedCloseReleasesConfirmation() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        harness.controller.pinFamily(parent.id)
        harness.uiState.confirmingTaskDeletionID = child.id

        harness.controller.closePinned()
        XCTAssertNil(harness.uiState.confirmingTaskDeletionID)
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.taskConfirmation))
    }

    /// Unpin returns to a transient for the same family — the edit survives
    /// because a surface still hosts it.
    func testUnpinKeepsEditWhenTransientReanchors() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.pinFamily(parent.id)
        harness.uiState.beginEditing(child)
        harness.controller.unpinPinned()
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
        XCTAssertEqual(harness.uiState.editingTaskID, child.id)
    }

    /// A resting pointer's dwell re-arms while the open surface is busy and
    /// still delivers the open once the interaction resolves.
    func testHoverPendingRearmsWhileBusyAndOpensAfter() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        _ = try XCTUnwrap(harness.store.create(title: "Other child", parentID: other.id))
        installAnchor(harness, for: parent.id)
        installAnchor(harness, for: other.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.beginEditing(child)

        harness.controller.noteRowHover(familyID: other.id, isHovering: true)
        // Busy the whole time: the claim re-arms rather than dying.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: SubtaskPanelLayout.openDwell + 0.25))
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)

        harness.uiState.endEditing()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: SubtaskPanelLayout.openDwell + 0.25))
        XCTAssertEqual(harness.controller.transientFamilyID, other.id)
    }

    /// Locks belonging to OTHER panel surfaces (main composer, notes editor)
    /// must not pin the transient open — only surface-owned locks defer.
    func testUnrelatedLocksDoNotDeferSurfaceClose() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.setInteractionLock(.quickEntryFocus, isActive: true)
        harness.uiState.setInteractionLock(.notesDirty, isActive: true)
        XCTAssertFalse(harness.controller.shouldDeferPointerClose(for: parent.id))
        // Surface-owned locks still defer.
        harness.uiState.setInteractionLock(.menuTracking, isActive: true)
        XCTAssertTrue(harness.controller.shouldDeferPointerClose(for: parent.id))
        harness.uiState.setInteractionLock(.menuTracking, isActive: false)
        harness.uiState.subtaskDrafts[parent.id] = "draft"
        XCTAssertTrue(harness.controller.shouldDeferPointerClose(for: parent.id))
    }

    /// Unpin must not evict a different family mid-edit: the pinned window
    /// simply dissolves, the other family's transient keeps its surface.
    func testUnpinDoesNotEvictBusyTransient() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        let childB = try XCTUnwrap(harness.store.create(title: "B child", parentID: parentB.id))
        installAnchor(harness, for: parentA.id)
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)
        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        harness.uiState.beginEditing(childB)

        harness.controller.unpinPinned()
        XCTAssertNil(harness.controller.pinnedFamilyID)
        XCTAssertEqual(harness.controller.transientFamilyID, parentB.id)
        XCTAssertEqual(harness.uiState.editingTaskID, childB.id)
    }

    /// Replacing a pinned family that's mid-edit is refused — the explicit
    /// affordance never erases an in-flight interaction.
    func testPinReplaceRefusedWhileDisplacedFamilyBusy() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let childA = try XCTUnwrap(harness.store.create(title: "A child", parentID: parentA.id))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)
        harness.uiState.beginEditing(childA)

        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        harness.controller.pinFamily(parentB.id)
        XCTAssertEqual(harness.controller.pinnedFamilyID, parentA.id)
        XCTAssertEqual(harness.uiState.editingTaskID, childA.id)
    }

    /// A clean replace (no in-flight edit) still proceeds and releases the
    /// displaced family's state.
    func testPinReplaceProceedsWhenIdle() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)
        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        harness.controller.pinFamily(parentB.id)
        XCTAssertEqual(harness.controller.pinnedFamilyID, parentB.id)
        XCTAssertNil(harness.controller.transientFamilyID)
    }

    // MARK: - Lifecycle bookkeeping

    func testDeletingFamilyClosesItsSurfaces() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        installAnchor(harness, for: other.id)
        harness.controller.openFamilyPanel(for: other.id, focusEntry: false)
        XCTAssertTrue(harness.store.delete(other))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNil(harness.controller.transientFamilyID)
    }
}
