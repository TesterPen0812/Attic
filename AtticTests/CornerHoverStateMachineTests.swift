import XCTest
@testable import Attic

final class CornerHoverStateMachineTests: XCTestCase {
    func testRevealsOnlyAfterConfiguredDwell() {
        var machine = CornerHoverStateMachine()

        XCTAssertEqual(machine.update(at: 10, isInHotspot: true, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .none)
        XCTAssertEqual(machine.update(at: 10.49, isInHotspot: true, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .none)
        XCTAssertEqual(machine.update(at: 10.5, isInHotspot: true, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .reveal)
        XCTAssertTrue(machine.isVisible)
    }

    func testLeavingHotspotBeforeDelayResetsDwell() {
        var machine = CornerHoverStateMachine()
        _ = machine.update(at: 1, isInHotspot: true, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5)
        _ = machine.update(at: 1.4, isInHotspot: false, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5)
        XCTAssertEqual(machine.update(at: 1.6, isInHotspot: true, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .none)
    }

    func testPanelUsesTransitAndExitGracePeriods() {
        var machine = CornerHoverStateMachine()
        machine.forceVisible(at: 5, grace: 0.8)

        XCTAssertEqual(machine.update(at: 5.7, isInHotspot: false, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .none)
        XCTAssertEqual(machine.update(at: 5.81, isInHotspot: false, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .none)
        XCTAssertEqual(machine.update(at: 6.12, isInHotspot: false, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .hide)
    }

    func testInteractionLockKeepsPanelVisible() {
        var machine = CornerHoverStateMachine()
        machine.forceVisible(at: 0, grace: 0)

        XCTAssertEqual(machine.update(at: 10, isInHotspot: false, isInPanel: false, isInteractionLocked: true, revealDelay: 0.5), .none)
        XCTAssertTrue(machine.isVisible)
    }

    func testConfiguredHideDelayControlsExitTiming() {
        var machine = CornerHoverStateMachine()
        machine.forceVisible(at: 0, grace: 0)

        XCTAssertEqual(machine.update(
            at: 1,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.7
        ), .none)
        XCTAssertEqual(machine.update(
            at: 1.69,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.7
        ), .none)
        XCTAssertEqual(machine.update(
            at: 1.7,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.7
        ), .hide)
    }

    func testPinKeepsVisiblePanelOpenUntilUnpinnedHideDelayCompletes() {
        var machine = CornerHoverStateMachine()
        machine.forceVisible(at: 0, grace: 0)

        XCTAssertEqual(machine.update(
            at: 10,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: true,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .none)
        XCTAssertTrue(machine.isVisible)

        XCTAssertEqual(machine.update(
            at: 11,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .none)
        XCTAssertEqual(machine.update(
            at: 11.29,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .none)
        XCTAssertEqual(machine.update(
            at: 11.3,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .hide)
    }

    @MainActor
    func testInteractiveForceHideRequiresHotspotExitBeforeFreshRevealDwell() {
        let uiState = PanelUIState()
        uiState.isPanelPinned = true
        var machine = CornerHoverStateMachine()
        machine.forceVisible(at: 0, grace: 0)

        machine.forceHidden(untilHotspotExit: true)

        XCTAssertFalse(machine.isVisible)
        XCTAssertTrue(uiState.isPanelPinned)
        XCTAssertEqual(machine.update(
            at: 10,
            isInHotspot: true,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: uiState.isPanelPinned,
            revealDelay: 0.2
        ), .none)
        XCTAssertEqual(machine.update(
            at: 10.21,
            isInHotspot: true,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: uiState.isPanelPinned,
            revealDelay: 0.2
        ), .none)
        XCTAssertEqual(machine.update(
            at: 10.3,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: uiState.isPanelPinned,
            revealDelay: 0.2
        ), .none)
        XCTAssertEqual(machine.update(
            at: 10.4,
            isInHotspot: true,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: uiState.isPanelPinned,
            revealDelay: 0.2
        ), .none)
        XCTAssertEqual(machine.update(
            at: 10.61,
            isInHotspot: true,
            isInPanel: false,
            isInteractionLocked: false,
            isPinned: uiState.isPanelPinned,
            revealDelay: 0.2
        ), .reveal)
        XCTAssertTrue(uiState.isPanelPinned)
    }
}

final class PanelUIStateTests: XCTestCase {
    @MainActor
    func testReleaseOutsideReturnsDraggedTaskOnce() {
        let state = PanelUIState()
        let task = TaskItem(title: "External drag")

        state.beginDragging(task)

        XCTAssertEqual(state.finishDragging(releasedOutsidePanel: true), task.id)
        XCTAssertNil(state.draggedTaskID)
        XCTAssertNil(state.finishDragging(releasedOutsidePanel: true))
    }

    @MainActor
    func testReleaseInsideClearsDragWithoutStartingTask() {
        let state = PanelUIState()
        let task = TaskItem(title: "Internal drag")

        state.beginDragging(task)

        XCTAssertNil(state.finishDragging(releasedOutsidePanel: false))
        XCTAssertNil(state.draggedTaskID)
    }

    @MainActor
    func testReconcileClearsEditingAndDragStateForDeletedTask() {
        let state = PanelUIState()
        let task = TaskItem(title: "Removed remotely")

        state.beginEditing(task)
        state.beginDragging(task)
        state.reconcileTaskIDs([])

        XCTAssertNil(state.editingTaskID)
        XCTAssertNil(state.draggedTaskID)
        XCTAssertFalse(state.isInteractionLocked)
    }

    @MainActor
    func testPanelPinIsSessionOnlyAndDoesNotLockInteraction() {
        let state = PanelUIState()

        XCTAssertFalse(state.isPanelPinned)
        state.isPanelPinned = true

        XCTAssertTrue(state.isPanelPinned)
        XCTAssertFalse(state.isInteractionLocked)
    }
}
