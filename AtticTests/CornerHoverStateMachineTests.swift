import Combine
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
        XCTAssertEqual(machine.update(at: 6.12, isInHotspot: false, isInPanel: false, isInteractionLocked: false, revealDelay: 0.5), .requestHide)
        XCTAssertTrue(machine.isVisible)
        XCTAssertTrue(machine.isHidePending)
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
        ), .requestHide)
        XCTAssertTrue(machine.isVisible)
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
        ), .requestHide)
        XCTAssertTrue(machine.isVisible)
    }

    func testRejectedHideRequestKeepsPanelVisibleAndRestartsDelay() {
        var machine = CornerHoverStateMachine()
        machine.forceVisible(at: 0, grace: 0)

        XCTAssertEqual(machine.update(
            at: 1,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .none)
        XCTAssertEqual(machine.update(
            at: 1.3,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .requestHide)
        XCTAssertTrue(machine.isVisible)
        XCTAssertTrue(machine.isHidePending)

        machine.resolveHideCompletion(didOrderOut: false)

        XCTAssertTrue(machine.isVisible)
        XCTAssertFalse(machine.isHidePending)
        XCTAssertEqual(machine.update(
            at: 1.31,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: true,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .none)
        XCTAssertTrue(machine.isVisible)
    }

    func testAcceptedHideRemainsVisibleUntilOwnedAnimationCompletion() {
        var machine = pendingHideStateMachine()
        var outcomes: [PanelHideCompletion] = []
        var transition = PanelVisibilityTransitionState()
        let generation = transition.beginHideTransition { outcome in
            outcomes.append(outcome)
            machine.resolveHideCompletion(didOrderOut: outcome == .hidden)
        }

        XCTAssertEqual(outcomes, [])
        XCTAssertTrue(machine.isVisible)
        XCTAssertTrue(machine.isHidePending)

        XCTAssertTrue(transition.completeHideTransition(generation))

        XCTAssertEqual(outcomes, [.hidden])
        XCTAssertFalse(machine.isVisible)
        XCTAssertFalse(machine.isHidePending)
    }

    func testRevealSupersedesAcceptedHideAndKeepsModelVisible() {
        var machine = pendingHideStateMachine()
        var outcomes: [PanelHideCompletion] = []
        var transition = PanelVisibilityTransitionState()
        let hideGeneration = transition.beginHideTransition { outcome in
            outcomes.append(outcome)
            machine.resolveHideCompletion(didOrderOut: outcome == .hidden)
        }

        transition.invalidatePendingTransition()

        XCTAssertEqual(outcomes, [.superseded])
        XCTAssertTrue(machine.isVisible)
        XCTAssertFalse(machine.isHidePending)
        XCTAssertFalse(transition.completeHideTransition(hideGeneration))
        XCTAssertEqual(outcomes, [.superseded])
        XCTAssertTrue(machine.isVisible)
    }

    private func pendingHideStateMachine() -> CornerHoverStateMachine {
        var machine = CornerHoverStateMachine()
        machine.forceVisible(at: 0, grace: 0)
        XCTAssertEqual(machine.update(
            at: 1,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .none)
        XCTAssertEqual(machine.update(
            at: 1.3,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ), .requestHide)

        return machine
    }

    func testLocalOnlyRevealRefreshUsesOneImmediatePassWithoutCloudRetry() throws {
        #if ATTIC_LOCAL_ONLY
        XCTAssertEqual(RevealRefreshPolicy.current, .singleEventDrivenPass)
        XCTAssertEqual(RevealRefreshPolicy.current.maximumPassCount, 1)
        XCTAssertNil(RevealRefreshPolicy.current.retryDelay)
        #else
        throw XCTSkip("The Local target owns this regression.")
        #endif
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
    func testNestedMenuTrackingKeepsLockUntilEverySessionEnds() {
        var tracking = PanelMenuTrackingState()
        let state = PanelUIState()

        tracking.begin()
        tracking.begin()
        state.setInteractionLock(.menuTracking, isActive: tracking.isTracking)

        tracking.end()
        state.setInteractionLock(.menuTracking, isActive: tracking.isTracking)
        XCTAssertTrue(state.isInteractionLocked)
        XCTAssertEqual(tracking.depth, 1)

        tracking.end()
        state.setInteractionLock(.menuTracking, isActive: tracking.isTracking)
        XCTAssertFalse(state.isInteractionLocked)
        XCTAssertEqual(tracking.depth, 0)

        tracking.end()
        XCTAssertFalse(tracking.isTracking)
        XCTAssertEqual(tracking.depth, 0)
    }

    @MainActor
    func testManagedInteractionLockChangesPublish() {
        let state = PanelUIState()
        var publicationCount = 0
        let observation = state.objectWillChange.sink {
            publicationCount += 1
        }

        state.setInteractionLock(.notesImport, isActive: true)
        state.setInteractionLock(.notesImport, isActive: true)

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(state.interactionLockReasons, [.notesImport])

        state.setInteractionLock(.notesImport, isActive: false)
        state.setInteractionLock(.notesImport, isActive: false)

        XCTAssertEqual(publicationCount, 2)
        XCTAssertFalse(state.isInteractionLocked)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testTaskComposerAndEditingRemainExplicitLocks() {
        let state = PanelUIState()

        state.beginAdding()
        XCTAssertEqual(state.interactionLockReasons, [.taskComposer])

        state.endAdding()
        let task = TaskItem(title: "Edit me")
        state.beginEditing(task)
        XCTAssertEqual(state.interactionLockReasons, [.taskEditing])

        state.endEditing()
        XCTAssertFalse(state.isInteractionLocked)
    }

    @MainActor
    func testNotesPresentationLocksOnlyForExplicitWorkReasons() {
        let state = PanelUIState()
        let note = NoteItem(title: "Saved", body: "Clean")

        state.selectSection(.notes)
        state.beginEditingNote(note)

        XCTAssertTrue(state.isComposerPresented)
        XCTAssertFalse(state.isInteractionLocked)
        XCTAssertEqual(state.interactionLockReasons, [])

        let notesReasons: [PanelInteractionLockReason] = [
            .notesEditorFocus,
            .notesDirty,
            .notesConflict,
            .notesImport,
            .notesPopover,
            .blockingSave
        ]
        for reason in notesReasons {
            state.setInteractionLock(reason, isActive: true)
            XCTAssertTrue(state.isInteractionLocked, "Expected \(reason) to lock auto-hide")
            XCTAssertTrue(state.interactionLockReasons.contains(reason))
            state.setInteractionLock(reason, isActive: false)
            XCTAssertFalse(state.isInteractionLocked, "Expected clearing \(reason) to unlock clean Notes")
        }
    }

    @MainActor
    func testQuickEntryMenuAndWindowReasonsComposeWithoutChangingPin() {
        let state = PanelUIState()

        state.setInteractionLock(.quickEntryFocus, isActive: true)
        state.setInteractionLock(.menuTracking, isActive: true)
        state.setInteractionLock(.windowMove, isActive: true)
        state.setInteractionLock(.windowResize, isActive: true)

        XCTAssertEqual(state.interactionLockReasons, [
            .quickEntryFocus,
            .menuTracking,
            .windowMove,
            .windowResize
        ])
        XCTAssertTrue(state.isInteractionLocked)
        XCTAssertFalse(state.isPanelPinned)

        state.setInteractionLock(.menuTracking, isActive: false)
        XCTAssertFalse(state.interactionLockReasons.contains(.menuTracking))
        XCTAssertTrue(state.isInteractionLocked)
        XCTAssertFalse(state.isPanelPinned)

        state.setInteractionLock(.quickEntryFocus, isActive: false)
        state.setInteractionLock(.windowMove, isActive: false)
        state.setInteractionLock(.windowResize, isActive: false)
        XCTAssertFalse(state.isInteractionLocked)
        XCTAssertFalse(state.isPanelPinned)
    }

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
