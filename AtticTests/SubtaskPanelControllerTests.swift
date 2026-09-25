import AppKit
import SwiftUI
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

    /// Visible rows for several families at once, stacked downward.
    private func installAnchors(_ harness: Harness, for ids: [UUID]) {
        harness.controller.updateTaskRowFrames(Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: 300, y: 400 - CGFloat(index) * 60, width: 300, height: 42))
        }))
        harness.controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 800, height: 800))
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
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.contains(parent.id))

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
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.contains(parentA.id))
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
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.contains(parentA.id))
        XCTAssertEqual(harness.controller.transientFamilyID, parentB.id)
    }

    // MARK: - R3: edit-busy surfaces resist replacement; drafts live in uiState

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
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.contains(parent.id))
        XCTAssertEqual(harness.uiState.editingTaskID, child.id)
        XCTAssertEqual(harness.uiState.editingDraftTitle, "Half-typed rename")

        harness.controller.unpinPinned(parent.id)
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.isEmpty)
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

    func testMultiplePinnedFamiliesKeepAllDrafts() throws {
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
        XCTAssertEqual(harness.controller.pinnedFamilyIDs, [parentA.id, parentB.id])
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
        harness.controller.unpinPinned(parent.id)
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.isEmpty)
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

    /// TP-023: every surface-owned confirmation mark is released with the
    /// surface, the completion confirmation included.
    func testTeardownReleasesChildCompletionConfirmation() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.confirmingTaskCompletionID = child.id
        XCTAssertTrue(harness.uiState.interactionLockReasons.contains(.taskConfirmation))
        harness.controller.dismissTransient()
        XCTAssertNil(harness.uiState.confirmingTaskCompletionID)
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.taskConfirmation))

        // The parent's own confirmation lives on its main-list row and survives.
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.confirmingTaskCompletionID = parent.id
        harness.controller.dismissTransient()
        XCTAssertEqual(harness.uiState.confirmingTaskCompletionID, parent.id)
    }

    func testPinnedCloseReleasesConfirmation() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        harness.controller.pinFamily(parent.id)
        harness.uiState.confirmingTaskDeletionID = child.id

        harness.controller.closePinned(parent.id)
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
        harness.controller.unpinPinned(parent.id)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
        XCTAssertEqual(harness.uiState.editingTaskID, child.id)
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

        harness.controller.unpinPinned(parentA.id)
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.isEmpty)
        XCTAssertEqual(harness.controller.transientFamilyID, parentB.id)
        XCTAssertEqual(harness.uiState.editingTaskID, childB.id)
    }

    /// Replacing a pinned family that's mid-edit is refused — the explicit
    /// affordance never erases an in-flight interaction.
    func testPinningAnotherFamilyPreservesBusyPinnedFamily() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let childA = try XCTUnwrap(harness.store.create(title: "A child", parentID: parentA.id))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)
        harness.uiState.beginEditing(childA)

        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        harness.controller.pinFamily(parentB.id)
        XCTAssertEqual(harness.controller.pinnedFamilyIDs, [parentA.id, parentB.id])
        XCTAssertEqual(harness.uiState.editingTaskID, childA.id)
    }

    /// A clean replace (no in-flight edit) still proceeds and releases the
    /// displaced family's state.
    func testPinningAnotherFamilyKeepsBothWindows() throws {
        let harness = try makeHarness()
        let parentA = try XCTUnwrap(harness.store.create(title: "A"))
        let parentB = try XCTUnwrap(harness.store.create(title: "B"))
        installAnchor(harness, for: parentB.id)
        harness.controller.pinFamily(parentA.id)
        harness.controller.openFamilyPanel(for: parentB.id, focusEntry: false)
        harness.controller.pinFamily(parentB.id)
        XCTAssertEqual(harness.controller.pinnedFamilyIDs, [parentA.id, parentB.id])
        XCTAssertNil(harness.controller.transientFamilyID)
    }

    // MARK: - Review round 3 regressions (local continuation)

    /// The parent's own rename field lives on the MAIN-list row — only child
    /// rows are hosted by the auxiliary surface. Tearing a surface down must
    /// release child edits but never discard the parent's live editor. (F1)
    func testPinnedClosePreservesMainListParentRename() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.pinFamily(parent.id)
        harness.uiState.beginEditing(parent)
        harness.uiState.editingDraftTitle = "Half-typed rename"

        harness.controller.closePinned(parent.id)
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.isEmpty)
        XCTAssertEqual(harness.uiState.editingTaskID, parent.id)
        XCTAssertEqual(harness.uiState.editingDraftTitle, "Half-typed rename")
    }

    func testMainHideWithTransientPreservesParentRename() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.beginEditing(parent)
        harness.uiState.editingDraftTitle = "Draft"

        harness.controller.mainPanelDidHide()
        XCTAssertNil(harness.controller.transientFamilyID)
        XCTAssertEqual(harness.uiState.editingTaskID, parent.id)
        XCTAssertEqual(harness.uiState.editingDraftTitle, "Draft")
    }

    func testPinnedClosePreservesParentDeleteConfirmation() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        harness.controller.pinFamily(parent.id)
        harness.uiState.confirmingTaskDeletionID = parent.id

        harness.controller.closePinned(parent.id)
        XCTAssertEqual(harness.uiState.confirmingTaskDeletionID, parent.id)
        XCTAssertTrue(harness.uiState.interactionLockReasons.contains(.taskConfirmation))
    }

    /// Complement: child edits ARE surface-hosted, so an unpin that cannot
    /// re-anchor (main hidden) still releases them — the orphan-lock fix
    /// keeps working on the state the surface actually owned.
    func testUnpinWithoutAnchorReleasesChildEdit() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        harness.controller.pinFamily(parent.id)
        harness.uiState.beginEditing(child)

        harness.controller.mainPanelVisibleForTesting = false
        harness.controller.unpinPinned(parent.id)
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.isEmpty)
        XCTAssertNil(harness.controller.transientFamilyID)
        XCTAssertNil(harness.uiState.editingTaskID)
    }

    /// Focus teardown consults surface ownership so a dying host's late
    /// resign can't clear focus state its replacement asserted. (F2)
    func testLiveSurfaceOwnershipTracksPinAndUnpin() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)

        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertTrue(harness.controller.isLiveSurface(for: parent.id, mode: .transient))
        XCTAssertFalse(harness.controller.isLiveSurface(for: parent.id, mode: .pinned))

        harness.controller.pinFamily(parent.id)
        XCTAssertFalse(harness.controller.isLiveSurface(for: parent.id, mode: .transient))
        XCTAssertTrue(harness.controller.isLiveSurface(for: parent.id, mode: .pinned))

        harness.controller.unpinPinned(parent.id)
        XCTAssertTrue(harness.controller.isLiveSurface(for: parent.id, mode: .transient))
        XCTAssertFalse(harness.controller.isLiveSurface(for: parent.id, mode: .pinned))

        harness.controller.dismissTransient()
        XCTAssertFalse(harness.controller.isLiveSurface(for: parent.id, mode: .transient))
    }

    /// A pin/unpin press resigns the entry on mouse-down, before the button
    /// action runs — the recorded resign keeps the entry "engaged" so the
    /// swap still restores focus. (F2 click-ordering)
    func testEntryResignWithinClickStillRefocusesAfterPin() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: true)
        XCTAssertEqual(harness.uiState.focusedSubtaskParentID, parent.id)

        // The pin button's mouse-down resigns the field editor first.
        harness.controller.noteSubtaskEntryResigned(for: parent.id)
        XCTAssertNil(harness.uiState.focusedSubtaskParentID)

        harness.controller.pinFamily(parent.id)
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.contains(parent.id))
        XCTAssertEqual(harness.uiState.focusedSubtaskParentID, parent.id)
    }

    /// A resign older than the click window means the user really left the
    /// field — pin must not resurrect focus. (F2)
    func testAgedEntryResignDoesNotRefocusOnPin() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: true)
        harness.controller.noteSubtaskEntryResigned(for: parent.id)

        RunLoop.main.run(until: Date(
            timeIntervalSinceNow: SubtaskPanelLayout.entryResignReuseWindow + 0.15
        ))
        harness.controller.pinFamily(parent.id)
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.contains(parent.id))
        XCTAssertNil(harness.uiState.focusedSubtaskParentID)
    }

    /// A real teardown with no surviving surface drops the stale focus
    /// pointer — the entry row and draft still survive, but the next open
    /// doesn't grab focus unprompted. (F2 residual)
    func testTeardownClearsStaleEntryFocusPointer() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        harness.controller.pinFamily(parent.id)
        harness.uiState.activateSubtaskEntry(for: parent.id)
        XCTAssertEqual(harness.uiState.focusedSubtaskParentID, parent.id)

        harness.controller.closePinned(parent.id)
        XCTAssertNil(harness.uiState.focusedSubtaskParentID)
        XCTAssertTrue(harness.uiState.subtaskEntryActiveIDs.contains(parent.id))
    }

    // MARK: - Lifecycle bookkeeping

    // MARK: - Round 5: hit geometry and pinned drag ownership

    /// The rendered squircle, the AppKit hit test, auto-hide coverage and
    /// outside-click dismissal all read this one value.
    func testSurfaceCornerSizeTracksTheLiveSetting() throws {
        let harness = try makeHarness()
        XCTAssertEqual(
            harness.controller.surfaceCornerSize,
            CGFloat(harness.settings.panelCornerSize),
            accuracy: 0.001
        )
        harness.settings.panelCornerSize = PanelCornerSize.maximum.rawValue
        XCTAssertEqual(
            harness.controller.surfaceCornerSize,
            CGFloat(PanelCornerSize.maximum.rawValue),
            accuracy: 0.001
        )
    }

    func testClosingOnePinnedFamilyKeepsOtherAndItsDraft() throws {
        let harness = try makeHarness()
        let a = try XCTUnwrap(harness.store.create(title: "A"))
        let b = try XCTUnwrap(harness.store.create(title: "B"))
        harness.controller.pinFamily(a.id)
        harness.controller.pinFamily(b.id)
        harness.uiState.subtaskDrafts[b.id] = "Keep this"
        harness.controller.closePinned(a.id)
        XCTAssertEqual(harness.controller.pinnedFamilyIDs, [b.id])
        XCTAssertEqual(harness.uiState.subtaskDrafts[b.id], "Keep this")
        harness.controller.mainPanelDidHide()
        XCTAssertEqual(harness.controller.pinnedFamilyIDs, [b.id])
        harness.controller.tearDown()
        XCTAssertTrue(harness.controller.pinnedFamilyIDs.isEmpty)
    }

    func testDetachedTransientSurvivesAnchorLossButNotMainHide() throws {
        let harness = try makeHarness()
        let a = try XCTUnwrap(harness.store.create(title: "A"))
        installAnchor(harness, for: a.id)
        harness.controller.openFamilyPanel(for: a.id, focusEntry: false)
        harness.controller.detachTransient()
        harness.controller.updateTaskRowFrames([:])
        harness.controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(harness.controller.transientFamilyID, a.id)
        harness.controller.mainPanelDidHide()
        XCTAssertNil(harness.controller.transientFamilyID)
    }

    // MARK: - TP-003: pointer position never opens a workspace

    /// Rows publish anchors and viewports continuously; none of that, nor
    /// time passing with a family under the pointer, may present a surface.
    /// Only a deliberate open does.
    func testAnchorsAndViewportsNeverOpenASurfaceWithoutADeliberateAction() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        harness.uiState.subtaskDrafts[parent.id] = "draft"
        for _ in 0..<3 {
            installAnchor(harness, for: parent.id)
            harness.controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 400, height: 800))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        XCTAssertNil(harness.controller.transientFamilyID)
        XCTAssertFalse(harness.uiState.interactionLockReasons.contains(.subtaskComposer),
                       "a retained draft on a closed family locks nothing")

        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
    }

    /// Row anchors republish on every scroll frame. Unchanged frames do no
    /// work, and a burst of changed frames coalesces into one re-fit.
    func testRowAnchorPublicationsCoalesceIntoOneRepositionPerTurn() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let baseline = harness.controller.transientRepositionCount

        for _ in 0..<5 {
            harness.controller.updateTaskRowFrames([parent.id: CGRect(x: 300, y: 400, width: 300, height: 42)])
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(harness.controller.transientRepositionCount, baseline, "unchanged frames re-fit nothing")

        for y in stride(from: 398, through: 380, by: -2) {
            harness.controller.updateTaskRowFrames([parent.id: CGRect(x: 300, y: CGFloat(y), width: 300, height: 42)])
            harness.controller.updateTaskListViewport(CGRect(x: 0, y: CGFloat(y) - 400, width: 400, height: 800))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertLessThanOrEqual(harness.controller.transientRepositionCount - baseline, 1,
                                 "a burst of anchor changes within one turn re-fits at most once")
    }

    // MARK: - Batch 4 (R6): latch ruling, placement and trackpad gates

    /// ROOT RULING: a deliberately opened panel stays until an outside click.
    /// Its source row scrolling out never closes it; explicit actions still
    /// switch tasks.
    func testOpenPanelSurvivesScrollOut() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        _ = try XCTUnwrap(harness.store.create(title: "Other child", parentID: other.id))
        installAnchors(harness, for: [parent.id, other.id])
        let controller = harness.controller
        controller.openFamilyPanel(for: parent.id, focusEntry: false)

        // The source row scrolls out of the list, then back.
        controller.updateTaskListViewport(CGRect(x: 0, y: 600, width: 800, height: 200))
        controller.updateTaskRowFrames([other.id: CGRect(x: 300, y: 340, width: 300, height: 42)])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(controller.transientFamilyID, parent.id, "scroll-out keeps the panel")
        installAnchors(harness, for: [parent.id, other.id])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(controller.transientFamilyID, parent.id, "still open after the row returns")

        // An explicit action switches tasks.
        controller.openFamilyPanel(for: other.id, focusEntry: false)
        XCTAssertEqual(controller.transientFamilyID, other.id)
        controller.dismissTransient()
        XCTAssertNil(controller.transientFamilyID)
    }

    // MARK: - No swipe dismissal: scrolling and drag residue never close

    /// Everything a dismissal gesture once consumed — a horizontal pan over
    /// the surface, the source list scrolling its row's anchor away, the
    /// surface dragged clear of the row — now leaves the latched panel
    /// alone. No controller path remains that scroll input could reach.
    func testScrollAndDragResidueNeverDismissesTheLatchedSurface() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        installAnchors(harness, for: [parent.id, other.id])
        let controller = harness.controller
        controller.openFamilyPanel(for: parent.id, focusEntry: false)

        // The list scrolling under an open panel republishes anchors and
        // the viewport — including the row leaving the list entirely.
        for index in 0..<10 {
            let y = CGFloat(400 - index * 40)
            controller.updateTaskRowFrames([parent.id: CGRect(x: 300, y: y, width: 300, height: 42)])
            controller.updateTaskListViewport(CGRect(x: 0, y: 400 - y, width: 800, height: 400))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(controller.transientFamilyID, parent.id, "scrolling the source list keeps the panel")

        // Dragged clear of its row, it stays until a deliberate close.
        controller.detachTransient()
        controller.updateTaskRowFrames([:])
        controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 10, height: 10))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(controller.transientFamilyID, parent.id, "a detached panel stays put")

        // A pinned sibling arriving meanwhile does not evict it either.
        controller.pinFamily(other.id)
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.pinnedFamilyIDs, [other.id])
    }

    /// What still dismisses: outside-click/explicit dismissal, the count
    /// control's toggle, a section switch, main-panel hide — and the pinned
    /// window's own close for a pinned family.
    func testEveryPreservedClosePathStillDismisses() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        installAnchors(harness, for: [parent.id, other.id])
        let controller = harness.controller

        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        controller.dismissTransient()
        XCTAssertNil(controller.transientFamilyID, "outside click / explicit close")

        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        controller.toggleFamilyPanel(for: parent.id)
        XCTAssertNil(controller.transientFamilyID, "the idle panel's own count control toggles it closed")

        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.uiState.selectSection(.notes)
        XCTAssertNil(controller.transientFamilyID, "a section switch dismisses")
        harness.uiState.selectSection(.tasks)

        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        controller.mainPanelDidHide()
        XCTAssertNil(controller.transientFamilyID, "main-panel hide dismisses")

        controller.pinFamily(other.id)
        XCTAssertEqual(controller.pinnedFamilyIDs, [other.id])
        controller.closePinned(other.id)
        XCTAssertTrue(controller.pinnedFamilyIDs.isEmpty, "a pinned window closes only deliberately")
    }

    /// A closed family re-opens as a fresh presentation: the dismissals
    /// above leave no half-finished state behind, so the next deliberate
    /// open starts on Subtasks and stays until a real close path.
    func testReopenAfterDismissalIsAFreshStablePresentation() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        let controller = harness.controller

        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        controller.showPanelView(.attachments, for: parent.id)
        controller.dismissTransient()

        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks, "a fresh open starts on Subtasks")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(controller.transientFamilyID, parent.id, "nothing lingers that could still close it")
    }

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

    // MARK: - Task panel V2 batch 1: the row opens its family panel

    func testRowClickResolvesToOpenOrStatusShortcut() {
        XCTAssertEqual(TaskRowClick.resolve(clickCount: 1, isTopLevel: true, isEditing: false), .openFamilyPanel)
        XCTAssertEqual(TaskRowClick.resolve(clickCount: 2, isTopLevel: true, isEditing: false), .statusShortcut)
        // One-level subtasks: a child row has no nested panel, but keeps
        // the double-click status shortcut it already had.
        XCTAssertEqual(TaskRowClick.resolve(clickCount: 1, isTopLevel: false, isEditing: false), .none)
        XCTAssertEqual(TaskRowClick.resolve(clickCount: 2, isTopLevel: false, isEditing: false), .statusShortcut)
        XCTAssertEqual(TaskRowClick.resolve(clickCount: 3, isTopLevel: true, isEditing: false), .none)
        for count in 1...3 {
            XCTAssertEqual(TaskRowClick.resolve(clickCount: count, isTopLevel: true, isEditing: true), .none)
        }
    }

    func testRowHelpLeadsWithOpenActionAndKeepsDoubleClickShortcut() {
        XCTAssertEqual(
            TaskRowClick.help(status: .todo, isTopLevel: true, isFamilyPinned: false),
            "Click to show subtasks. Double-click to start"
        )
        XCTAssertEqual(
            TaskRowClick.help(status: .backlog, isTopLevel: true, isFamilyPinned: true),
            "Click to reveal the pinned panel. Double-click to move to To do"
        )
        // Done has no double-click shortcut, so only the primary action shows.
        XCTAssertEqual(TaskRowClick.help(status: .done, isTopLevel: true, isFamilyPinned: false), "Click to show subtasks")
        // Child rows open no panel and keep their status-shortcut help.
        for status in TaskStatus.allCases {
            XCTAssertEqual(TaskRowClick.help(status: status, isTopLevel: false, isFamilyPinned: false), status.doubleClickTitle)
        }
    }

    func testKeyboardFocusDisclosesOnlyClippedTitlesOutsideEditing() {
        XCTAssertTrue(TaskTitleDisclosure.isClipped(idealWidth: 240, renderedWidth: 180))
        XCTAssertFalse(TaskTitleDisclosure.isClipped(idealWidth: 180, renderedWidth: 180))
        // Sub-point rounding between the two measurements is not clipping.
        XCTAssertFalse(TaskTitleDisclosure.isClipped(idealWidth: 180.4, renderedWidth: 180))
        // Before measurement both widths are zero: nothing is disclosed.
        XCTAssertFalse(TaskTitleDisclosure.isClipped(idealWidth: 0, renderedWidth: 0))

        XCTAssertTrue(TaskTitleDisclosure.showsFullTitle(isClipped: true, hasRowFocus: true, isEditing: false))
        XCTAssertFalse(TaskTitleDisclosure.showsFullTitle(isClipped: false, hasRowFocus: true, isEditing: false),
                       "a title that fits gets no redundant overlay")
        XCTAssertFalse(TaskTitleDisclosure.showsFullTitle(isClipped: true, hasRowFocus: false, isEditing: false),
                       "hover keeps its tooltip; only focus discloses")
        XCTAssertFalse(TaskTitleDisclosure.showsFullTitle(isClipped: true, hasRowFocus: true, isEditing: true),
                       "editing already shows the whole title")
    }

    /// Only the row whose title is presented observes key changes and
    /// scrolling; every other visible row installs nothing. Observers stay
    /// through key loss (so the title returns) and go on dismissal, window
    /// removal and dismantle.
    func testTitleExpansionObservesOnlyWhilePresentedInWindow() {
        func expansion(isPresented: Bool) -> TaskTitleExpansion {
            TaskTitleExpansion(title: "A long task title", isPresented: isPresented, weight: .regular,
                               reduceTransparency: false, increasedContrast: false)
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scrollView.documentView = document
        window.contentView = scrollView
        let inactive = TaskTitleExpansion.AnchorView(frame: CGRect(x: 0, y: 0, width: 200, height: 20))
        let focused = TaskTitleExpansion.AnchorView(frame: CGRect(x: 0, y: 40, width: 200, height: 20))
        inactive.update(expansion(isPresented: false))
        focused.update(expansion(isPresented: false))
        document.addSubview(inactive)
        document.addSubview(focused)
        XCTAssertEqual(inactive.observerCount, 0, "an unfocused row joining a window observes nothing")
        XCTAssertEqual(focused.observerCount, 0)

        focused.update(expansion(isPresented: true))
        XCTAssertEqual(focused.observerCount, 3, "become key, resign key and the list's clip-view bounds")
        XCTAssertEqual(inactive.observerCount, 0)
        focused.update(expansion(isPresented: true))
        XCTAssertEqual(focused.observerCount, 3, "a repeated update does not stack observers")
        // Key loss and scrolling keep the set so the title can return.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: 300))
        XCTAssertEqual(focused.observerCount, 3)

        focused.update(expansion(isPresented: false))
        XCTAssertEqual(focused.observerCount, 0, "focus loss removes the observers immediately")

        focused.update(expansion(isPresented: true))
        focused.removeFromSuperview()
        XCTAssertEqual(focused.observerCount, 0, "leaving the window removes the observers")
        document.addSubview(focused)
        XCTAssertEqual(focused.observerCount, 3, "a presented row re-registers when it rejoins a window")

        focused.tearDown()
        XCTAssertEqual(focused.observerCount, 0, "dismantle removes the observers")
        focused.removeFromSuperview()
        document.addSubview(focused)
        XCTAssertEqual(focused.observerCount, 0, "a dismantled anchor never re-registers")
        window.close()
    }

    /// Clicking a row whose panel is open must keep it: the row "opens"
    /// rather than toggles, and the panel stays until an outside click.
    func testRowActivationIsIdempotentAndNeverCloses() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)

        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id, "a repeated row click is idempotent")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id, "time alone never closes it")
    }

    func testRowActivationForChildlessParentOpensAndPinnedFamilyRaisesWithoutDuplicate() throws {
        let harness = try makeHarness()
        let childless = try XCTUnwrap(harness.store.create(title: "No children yet"))
        let pinned = try XCTUnwrap(harness.store.create(title: "Pinned"))
        _ = try XCTUnwrap(harness.store.create(title: "Kid", parentID: pinned.id))
        installAnchor(harness, for: childless.id)
        harness.controller.openFamilyPanel(for: childless.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, childless.id)

        harness.controller.pinFamily(pinned.id)
        harness.controller.openFamilyPanel(for: pinned.id, focusEntry: false)
        XCTAssertEqual(harness.controller.pinnedFamilyIDs, [pinned.id])
        XCTAssertEqual(harness.controller.transientFamilyID, childless.id, "revealing a pinned family never opens a second surface")
        XCTAssertFalse(harness.uiState.subtaskEntryActiveIDs.contains(pinned.id), "revealing does not start subtask entry")
    }

    func testChildRowCannotOpenNestedPanel() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let child = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: child.id)
        harness.controller.openFamilyPanel(for: child.id, focusEntry: false)
        XCTAssertNil(harness.controller.transientFamilyID)
    }

    /// A press on the open family's own source row is not an outside click:
    /// the row's click raises the same panel instead of close-then-reopen.
    func testSourceRowPointIsRecognizedOnlyForVisibleAnchor() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        harness.controller.updateTaskRowFrames([
            parent.id: CGRect(x: 300, y: 400, width: 300, height: 42),
            other.id: CGRect(x: 300, y: 460, width: 300, height: 42)
        ])
        harness.controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 800, height: 800))
        XCTAssertTrue(harness.controller.isSourceRowPoint(CGPoint(x: 320, y: 420), for: parent.id))
        XCTAssertFalse(harness.controller.isSourceRowPoint(CGPoint(x: 320, y: 470), for: parent.id))
        XCTAssertTrue(harness.controller.isSourceRowPoint(CGPoint(x: 320, y: 470), for: other.id))

        harness.controller.mainPanelVisibleForTesting = false
        XCTAssertFalse(harness.controller.isSourceRowPoint(CGPoint(x: 320, y: 420), for: parent.id),
                       "a hidden main panel has no clickable source row")
    }
    // MARK: - Task panel V2 batch 2: one family panel, two views

    func testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        let controller = harness.controller
        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks)

        controller.showPanelView(.attachments, for: parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments)

        // Row movement, main-panel movement, a repeated row click and
        // dragging the panel away never reset the view.
        controller.updateTaskRowFrames([parent.id: CGRect(x: 300, y: 360, width: 300, height: 42)])
        controller.mainPanelFrameDidChange()
        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        controller.detachTransient()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments)

        // Once dismissed, the next explicit open starts on Subtasks again.
        controller.dismissTransient()
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks)
        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks)
        XCTAssertTrue(controller.panelViews.views.isEmpty)
    }

    func testPinUnpinAndPinnedRevealKeepTheSamePanelView() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        let controller = harness.controller
        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        controller.showPanelView(.attachments, for: parent.id)

        controller.pinFamily(parent.id)
        XCTAssertEqual(controller.pinnedFamilyIDs, [parent.id])
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments, "pinning keeps the view")
        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertNil(controller.transientFamilyID, "revealing never duplicates the family")
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments, "revealing keeps the view")

        controller.unpinPinned(parent.id)
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments, "unpinning keeps the same panel's view")

        controller.pinFamily(parent.id)
        controller.closePinned(parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks)
        XCTAssertTrue(controller.panelViews.views.isEmpty)
    }

    func testExplicitViewRequestsAndSubtaskEntryChooseTheirView() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        installAnchor(harness, for: parent.id)
        let controller = harness.controller

        // A closed family is not presented, so a stray switch is ignored.
        controller.showPanelView(.attachments, for: parent.id)
        XCTAssertTrue(controller.panelViews.views.isEmpty)

        // Every fresh open starts on Subtasks, whatever view was requested:
        // Attachments is reached from the switch inside the open panel.
        controller.openFamilyPanel(for: parent.id, focusEntry: false, view: .attachments)
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks)
        controller.openFamilyPanel(for: parent.id, focusEntry: false, view: .attachments)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments, "the open panel switches in place")

        // "Add subtask…" always shows Subtasks and activates the entry.
        controller.openFamilyPanel(for: parent.id, focusEntry: true)
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks)
        XCTAssertTrue(harness.uiState.subtaskEntryActiveIDs.contains(parent.id))

        // A pinned family switches in its own window.
        controller.pinFamily(other.id)
        controller.openFamilyPanel(for: other.id, focusEntry: false, view: .attachments)
        XCTAssertEqual(controller.panelView(for: other.id), .attachments)
        XCTAssertEqual(controller.transientFamilyID, parent.id, "the pinned request leaves the transient alone")
        XCTAssertEqual(controller.panelView(for: parent.id), .subtasks)
    }

    /// An import reveal is the one path that lands on Attachments, and it
    /// still opens the workspace on Subtasks first and switches deliberately.
    /// Round 2 #5: "Open page" from the Tasks page opens the old panel on
    /// the task's files and never offers its Subtasks editor.
    func testTheTasksPageOpensTheFilesPanelWithoutASubtasksRoute() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        let controller = harness.controller
        controller.openFilesPanel(for: parent.id)
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments)
        XCTAssertTrue(controller.panelViews.isFilesOnly(parent.id))
        controller.showPanelView(.subtasks, for: parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments, "no way back to Subtasks")
        controller.openFamilyPanel(for: parent.id, focusEntry: true)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments, "nor through the entry request")
        XCTAssertFalse(harness.uiState.subtaskEntryActiveIDs.contains(parent.id), "and no subtask field takes the keyboard")
    }

    func testImportRevealOpensOnSubtasksThenSwitchesToAttachments() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        installAnchor(harness, for: parent.id)
        let controller = harness.controller
        let context = controller.revealContext
        controller.revealImportedAttachments([UUID()], for: parent.id, since: context)
        XCTAssertEqual(controller.transientFamilyID, parent.id)
        XCTAssertEqual(controller.panelView(for: parent.id), .attachments)

        // A panel the user moved to another family since the drop is left alone.
        controller.dismissTransient()
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        installAnchors(harness, for: [parent.id, other.id])
        let staleContext = controller.revealContext
        controller.openFamilyPanel(for: other.id, focusEntry: false)
        controller.revealImportedAttachments([UUID()], for: parent.id, since: staleContext)
        XCTAssertEqual(controller.transientFamilyID, other.id, "a reveal never steals a panel the user moved to")
        XCTAssertEqual(controller.panelView(for: other.id), .subtasks)
    }

    func testOpeningAnotherFamilyOpensItOnSubtasks() throws {
        let harness = try makeHarness()
        let first = try XCTUnwrap(harness.store.create(title: "First"))
        _ = try XCTUnwrap(harness.store.create(title: "First child", parentID: first.id))
        let second = try XCTUnwrap(harness.store.create(title: "Second"))
        _ = try XCTUnwrap(harness.store.create(title: "Second child", parentID: second.id))
        harness.controller.updateTaskRowFrames([
            first.id: CGRect(x: 300, y: 400, width: 300, height: 42),
            second.id: CGRect(x: 300, y: 340, width: 300, height: 42)
        ])
        harness.controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 800, height: 800))
        harness.controller.openFamilyPanel(for: first.id, focusEntry: false)
        harness.controller.showPanelView(.attachments, for: first.id)

        harness.controller.openFamilyPanel(for: second.id, focusEntry: false)
        XCTAssertEqual(harness.controller.transientFamilyID, second.id)
        XCTAssertEqual(harness.controller.panelView(for: second.id), .subtasks)
        XCTAssertEqual(harness.controller.panelView(for: first.id), .subtasks, "the closed family forgets its view")
    }

    /// The surface window fits the content's ideal height, and that height
    /// follows the active view: a long checklist shrinks to a one-row gallery
    /// and grows back.
    // MARK: - Batch 2 review fixes

    func testPickerAndChildPopoverKeepSeparateMarksAndNeitherSilentlyBlocks() throws {
        let harness = try makeHarness()
        let (store, uiState, controller) = (harness.store, harness.uiState, harness.controller)
        let first = try XCTUnwrap(store.create(title: "First"))
        let firstChild = try XCTUnwrap(store.create(title: "First child", parentID: first.id))
        let second = try XCTUnwrap(store.create(title: "Second"))
        XCTAssertTrue(TaskAttachmentPicker.isAvailable(for: firstChild.id, store: store, uiState: uiState))

        // A child's legacy popover no longer disables Add attachment (the
        // old shared mark made the picker return without a word).
        uiState.presentedTaskAttachmentsID = firstChild.id
        XCTAssertTrue(TaskAttachmentPicker.isAvailable(for: second.id, store: store, uiState: uiState))
        XCTAssertTrue(controller.familyEditBusy(first.id))

        // The picker for another family keeps its own mark while the popover
        // is up, and the popover closing cannot clear it.
        uiState.taskAttachmentPickerOwnerID = second.id
        XCTAssertTrue(controller.familyEditBusy(second.id))
        XCTAssertTrue(controller.familyEditBusy(first.id))
        XCTAssertFalse(TaskAttachmentPicker.isAvailable(for: first.id, store: store, uiState: uiState),
                       "one picker at a time, and every affordance shows it disabled")
        uiState.presentedTaskAttachmentsID = nil
        XCTAssertTrue(controller.familyEditBusy(second.id), "the popover closing leaves the picker's protection")
        XCTAssertFalse(controller.familyEditBusy(first.id))
        XCTAssertTrue(uiState.interactionLockReasons.contains(.taskConfirmation))

        // The picker is still up across a section switch; only its
        // completion clears the mark.
        uiState.selectSection(.backlog)
        XCTAssertEqual(uiState.taskAttachmentPickerOwnerID, second.id)
        uiState.taskAttachmentPickerOwnerID = nil
        XCTAssertFalse(uiState.interactionLockReasons.contains(.taskConfirmation))
        XCTAssertTrue(TaskAttachmentPicker.isAvailable(for: first.id, store: store, uiState: uiState))
        XCTAssertFalse(TaskAttachmentPicker.isAvailable(for: UUID(), store: store, uiState: uiState))
    }

    func testFrameAnimationTargetsBelongToTheirLiveSurfaceOnly() {
        final class Surface {}
        var targets = SurfaceFrameAnimationTargets()
        let frame = CGRect(x: 10, y: 20, width: 300, height: 180)
        var closed: Surface? = Surface()
        targets.set(frame, for: closed!)
        XCTAssertEqual(targets.target(for: closed!), frame)

        // Closed mid-animation: the completion handler never clears it. The
        // entry must not survive for a later surface (which AppKit may place
        // at the same address).
        closed = nil
        let replacement = Surface()
        XCTAssertNil(targets.target(for: replacement))
        targets.set(CGRect(x: 0, y: 0, width: 300, height: 90), for: replacement)
        XCTAssertEqual(targets.count, 1, "dead entries are pruned on the next animation")
        targets.clear(for: replacement)
        XCTAssertEqual(targets.count, 0)
    }

    func testExplicitViewRequestOnAnOpenFamilySwitchesInPlace() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)

        // The slide/crossfade itself is live-only; state must match a switch.
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false, view: .attachments)
        XCTAssertEqual(harness.controller.panelView(for: parent.id), .attachments)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
        XCTAssertEqual(harness.controller.panelView(for: parent.id), .attachments)
    }

    func testViewSwitchPagesBothLayersTheSameWay() {
        let subtasksSide = SubtaskPanelLayout.viewSwitchOffset(for: .subtasks)
        let attachmentsSide = SubtaskPanelLayout.viewSwitchOffset(for: .attachments)
        // Attachments sit to the right. Going there, the gallery enters from
        // the right and the list leaves to the left; going back mirrors it.
        XCTAssertLessThan(subtasksSide, 0)
        XCTAssertGreaterThan(attachmentsSide, 0)
        XCTAssertEqual(subtasksSide, -attachmentsSide)
        XCTAssertEqual(attachmentsSide, SubtaskPanelLayout.viewSwitchSlide)
    }

    func testMeasuredChromeRequestsARefitForAnAttachmentsFirstPanel() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Childless"))
        let closed = try XCTUnwrap(harness.store.create(title: "Closed"))
        installAnchor(harness, for: parent.id)
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
        harness.controller.showPanelView(.attachments, for: parent.id)

        func host(_ id: UUID) -> NSHostingView<SubtaskPanelContent> {
            NSHostingView(rootView: SubtaskPanelContent(
                store: harness.store, uiState: harness.uiState, settings: harness.settings,
                subtaskPanels: harness.controller, panelViews: harness.controller.panelViews,
                parentID: id, mode: .transient
            ))
        }
        func settle(_ view: NSView) {
            for _ in 0..<3 {
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            }
        }
        // No list measurement exists for this panel; the chrome measurement
        // is what corrects the estimated first fit.
        let live = host(parent.id)
        settle(live)
        XCTAssertNil(harness.controller.measuredListHeight(for: parent.id))
        let requests = harness.controller.chromeRefitRequestCount
        XCTAssertGreaterThan(requests, 0)
        settle(live)
        XCTAssertEqual(harness.controller.chromeRefitRequestCount, requests, "unchanged chrome asks for nothing")

        // A stale host for a family without a live surface never re-fits.
        settle(host(closed.id))
        XCTAssertEqual(harness.controller.chromeRefitRequestCount, requests)
    }

    func testPanelContentIdealHeightFollowsTheActiveView() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Itinerary.txt")
        try Data("Day one".utf8).write(to: file)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("storage")))
        let uiState = PanelUIState()
        let controller = SubtaskPanelController(store: store, uiState: uiState, settings: AppSettings(defaults: defaults))
        controller.presentationEnabled = false
        controller.mainPanelVisibleForTesting = true
        controller.anchorsAreScreenCoordinatesForTesting = true
        let parent = try XCTUnwrap(store.create(title: "Plan weekend"))
        for index in 0..<10 { _ = store.create(title: "Step \(index)", parentID: parent.id) }
        let attached = expectation(description: "attached")
        Task {
            let succeeded = await store.attachFiles([file], to: parent.id)
            XCTAssertTrue(succeeded)
            attached.fulfill()
        }
        wait(for: [attached], timeout: 5)
        controller.updateTaskRowFrames([parent.id: CGRect(x: 300, y: 400, width: 300, height: 42)])
        controller.openFamilyPanel(for: parent.id, focusEntry: false)

        let host = NSHostingView(rootView: SubtaskPanelContent(
            store: store, uiState: uiState, settings: AppSettings(defaults: defaults),
            subtaskPanels: controller, panelViews: controller.panelViews,
            parentID: parent.id, mode: .transient
        ))
        // Header/footer heights are measured by preference on a later pass;
        // let those settle before reading the ideal height.
        func idealHeight() -> CGFloat {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            }
            return host.fittingSize.height
        }
        let subtasksHeight = idealHeight()
        controller.showPanelView(.attachments, for: parent.id)
        let attachmentsHeight = idealHeight()
        XCTAssertEqual(host.fittingSize.width, SubtaskPanelLayout.panelWidth, accuracy: 0.5)
        XCTAssertEqual(
            subtasksHeight - attachmentsHeight,
            SubtaskPanelLayout.maximumListHeight - SubtaskPanelLayout.galleryContentHeight(itemCount: 1),
            accuracy: 1,
            "only the content region changes; header and footer stay"
        )
        controller.showPanelView(.subtasks, for: parent.id)
        XCTAssertEqual(idealHeight(), subtasksHeight, accuracy: 1)

        // Mid-animation the window is shorter than the content's ideal
        // height; the fitting target must not follow the current frame.
        host.frame = CGRect(x: 0, y: 0, width: SubtaskPanelLayout.panelWidth, height: attachmentsHeight)
        XCTAssertEqual(idealHeight(), subtasksHeight, accuracy: 1)
    }

    // MARK: - Final review F1: a family drop target never owns itself

    /// The production callback setup, configured again the way a reused host
    /// reconfigures it: routing still ends the whole-panel highlight and
    /// keeps the open family, and the callbacks do not keep the target
    /// alive once its surface lets go of it.
    func testFamilyDropCallbacksKeepRoutingWithoutRetainingTheirTarget() throws {
        let harness = try makeHarness()
        let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
        _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
        let other = try XCTUnwrap(harness.store.create(title: "Other"))
        installAnchors(harness, for: [parent.id, other.id])
        harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)

        weak var released: TaskFileDropTarget?
        autoreleasepool {
            let target = TaskFileDropTarget()
            SubtaskPanelContent.configureFileDrop(target, parentID: parent.id, mode: .transient,
                                                  store: harness.store, subtaskPanels: harness.controller)
            target.setTargeted(true, source: "surface")
            target.setTargeted(true, source: "row")
            target.perform(.task, [])
            XCTAssertFalse(target.isTargeted, "a drop still ends the highlight for the whole panel")
            SubtaskPanelContent.configureFileDrop(target, parentID: other.id, mode: .pinned,
                                                  store: harness.store, subtaskPanels: harness.controller)
            released = target
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released, "a target nothing else holds must not survive through its own callback")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(harness.controller.transientFamilyID, parent.id)
    }

    /// The real surface host: content configured on appear, reused for
    /// another family and for the pinned mode, then dismantled. Nothing the
    /// drop callbacks captured may outlive it.
    func testDismantledFamilySurfaceReleasesTheOwnersItsDropTargetCaptured() throws {
        weak var releasedController: SubtaskPanelController?
        weak var releasedStore: TaskStore?
        weak var releasedHost: NSView?
        try autoreleasepool {
            let harness = try makeHarness()
            let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
            _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
            let other = try XCTUnwrap(harness.store.create(title: "Other"))
            installAnchors(harness, for: [parent.id, other.id])
            harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)

            @MainActor func content(_ id: UUID, _ mode: SubtaskPanelContent.Mode) -> SubtaskPanelContent {
                SubtaskPanelContent(
                    store: harness.store, uiState: harness.uiState, settings: harness.settings,
                    subtaskPanels: harness.controller, panelViews: harness.controller.panelViews,
                    parentID: id, mode: mode
                )
            }
            let host = PanelSurfaceHostingView(rootView: content(parent.id, .transient))
            let window = PanelSurfaceWindow(
                contentView: host,
                initialSize: CGSize(width: SubtaskPanelLayout.panelWidth, height: 160)
            )
            @MainActor func settle() {
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                }
            }
            settle()
            host.rootView = content(other.id, .transient)
            settle()
            host.rootView = content(other.id, .pinned)
            settle()
            window.contentView = nil
            window.close()
            releasedController = harness.controller
            releasedStore = harness.store
            releasedHost = host
        }
        for _ in 0..<5 {
            autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
        }
        XCTAssertNil(releasedHost)
        XCTAssertNil(releasedController, "the drop target's callback kept the controller alive")
        XCTAssertNil(releasedStore, "the drop target's callback kept the store alive")
    }

    // MARK: - Lifetime

    /// A controller with an open surface under an active lock holds no work
    /// or observer that keeps it alive, and the lock lifting afterwards is
    /// harmless.
    func testControllerWithAnOpenSurfaceStillDeallocates() throws {
        weak var released: SubtaskPanelController?
        var uiState: PanelUIState?
        var parentID: UUID?
        try autoreleasepool {
            let harness = try makeHarness()
            let parent = try XCTUnwrap(harness.store.create(title: "Parent"))
            _ = try XCTUnwrap(harness.store.create(title: "Child", parentID: parent.id))
            installAnchor(harness, for: parent.id)
            harness.controller.openFamilyPanel(for: parent.id, focusEntry: false)
            harness.uiState.setInteractionLock(.menuTracking, isActive: true)
            harness.uiState.subtaskDrafts[parent.id] = "draft"
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            released = harness.controller
            uiState = harness.uiState
            parentID = parent.id
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNil(released)
        uiState?.setInteractionLock(.menuTracking, isActive: false)
        uiState?.subtaskDrafts[try XCTUnwrap(parentID)] = "later"
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNil(released)
    }
}
