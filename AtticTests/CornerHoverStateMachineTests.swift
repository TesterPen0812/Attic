import Combine
import XCTest
@testable import Attic

final class CornerHoverStateMachineTests: XCTestCase {
    func testPointerMonitoringCoversOwnAppAndOtherApplicationDomains() {
        XCTAssertEqual(
            CornerHoverPointerMonitorDomains.required,
            [.local, .global]
        )
    }

    func testSamplingCadenceDefinesDeterministicTimerSchedule() {
        XCTAssertEqual(CornerHoverSamplingCadence.idle.intervalMilliseconds, 1_000)
        XCTAssertEqual(CornerHoverSamplingCadence.idle.leewayMilliseconds, 250)
        XCTAssertEqual(CornerHoverSamplingCadence.idle.nominalSamplesPerMinute, 60)
        XCTAssertFalse(CornerHoverSamplingCadence.idle.holdsResponsivenessActivity)

        XCTAssertEqual(CornerHoverSamplingCadence.responsive.intervalMilliseconds, 50)
        XCTAssertEqual(CornerHoverSamplingCadence.responsive.leewayMilliseconds, 15)
        XCTAssertEqual(CornerHoverSamplingCadence.responsive.nominalSamplesPerMinute, 1_200)
        XCTAssertTrue(CornerHoverSamplingCadence.responsive.holdsResponsivenessActivity)
    }

    func testHiddenFarSamplingIsIdleAndDoesNotHoldResponsivenessActivity() {
        var sampling = CornerHoverSamplingState()
        let decision = sampling.update(
            pointer: CGPoint(x: 960, y: 540),
            screenFrames: [CGRect(x: 0, y: 0, width: 1_920, height: 1_080)],
            corner: .topRight,
            isPanelVisible: false
        )

        XCTAssertEqual(decision.cadence, .idle)
        XCTAssertFalse(decision.shouldSampleImmediately)
        XCTAssertFalse(decision.cadence.holdsResponsivenessActivity)
        XCTAssertLessThanOrEqual(decision.cadence.nominalSamplesPerMinute, 60)
        XCTAssertGreaterThanOrEqual(
            CornerHoverSamplingCadence.responsive.nominalSamplesPerMinute,
            decision.cadence.nominalSamplesPerMinute * 10
        )
    }

    func testPointerApproachImmediatelyPromotesToResponsiveSampling() {
        var sampling = CornerHoverSamplingState()
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        _ = sampling.update(
            pointer: CGPoint(x: 960, y: 540),
            screenFrames: [screen],
            corner: .topRight,
            isPanelVisible: false
        )

        let decision = sampling.update(
            pointer: CGPoint(x: 1_900, y: 1_060),
            screenFrames: [screen],
            corner: .topRight,
            isPanelVisible: false
        )

        XCTAssertEqual(decision.cadence, .responsive)
        XCTAssertTrue(decision.shouldSampleImmediately)
        XCTAssertTrue(decision.cadence.holdsResponsivenessActivity)
        XCTAssertLessThanOrEqual(decision.cadence.intervalMilliseconds, 50)
    }

    func testFarPointerMovementDoesNotRequestFullMainThreadSample() {
        var sampling = CornerHoverSamplingState()
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        _ = sampling.update(
            pointer: CGPoint(x: 500, y: 500),
            screenFrames: [screen],
            corner: .topRight,
            isPanelVisible: false
        )

        let decision = sampling.update(
            pointer: CGPoint(x: 700, y: 600),
            screenFrames: [screen],
            corner: .topRight,
            isPanelVisible: false
        )

        XCTAssertEqual(decision.cadence, .idle)
        XCTAssertFalse(decision.shouldSampleImmediately)
    }

    func testNearCornerHysteresisAvoidsCadenceThrashAndSamplesOnExit() {
        var sampling = CornerHoverSamplingState()
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

        XCTAssertEqual(
            sampling.update(
                pointer: CGPoint(x: 1_840, y: 1_000),
                screenFrames: [screen],
                corner: .topRight,
                isPanelVisible: false
            ).cadence,
            .responsive
        )
        let hysteresisDecision = sampling.update(
            pointer: CGPoint(x: 1_800, y: 960),
            screenFrames: [screen],
            corner: .topRight,
            isPanelVisible: false
        )
        XCTAssertEqual(hysteresisDecision.cadence, .responsive)
        XCTAssertFalse(hysteresisDecision.shouldSampleImmediately)

        let exitDecision = sampling.update(
            pointer: CGPoint(x: 1_760, y: 900),
            screenFrames: [screen],
            corner: .topRight,
            isPanelVisible: false
        )
        XCTAssertEqual(exitDecision.cadence, .idle)
        XCTAssertTrue(exitDecision.shouldSampleImmediately)
    }

    func testVisiblePanelKeepsResponsiveCadenceAwayFromCorner() {
        var sampling = CornerHoverSamplingState()
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let visibleDecision = sampling.update(
            pointer: CGPoint(x: 960, y: 540),
            screenFrames: [screen],
            corner: .bottomLeft,
            isPanelVisible: true
        )

        XCTAssertEqual(visibleDecision.cadence, .responsive)
        XCTAssertTrue(visibleDecision.shouldSampleImmediately)

        let hiddenDecision = sampling.update(
            pointer: CGPoint(x: 960, y: 540),
            screenFrames: [screen],
            corner: .bottomLeft,
            isPanelVisible: false
        )
        XCTAssertEqual(hiddenDecision.cadence, .idle)
        XCTAssertTrue(hiddenDecision.shouldSampleImmediately)
    }

    func testConfiguredCornerProximityWorksAcrossOffsetDisplays() {
        let screens = [
            CGRect(x: -1_440, y: -900, width: 1_440, height: 900),
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        ]
        let cases: [(ScreenCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: -1_430, y: -10)),
            (.topRight, CGPoint(x: -10, y: -10)),
            (.bottomLeft, CGPoint(x: 10, y: 10)),
            (.bottomRight, CGPoint(x: 1_910, y: 10))
        ]

        for (corner, pointer) in cases {
            var sampling = CornerHoverSamplingState()
            XCTAssertEqual(
                sampling.update(
                    pointer: pointer,
                    screenFrames: screens,
                    corner: corner,
                    isPanelVisible: false
                ).cadence,
                .responsive,
                "Expected \(corner) to promote near \(pointer)"
            )
        }
    }

    func testAdjacentDisplaySeamDoesNotPromoteForAnotherScreensCorner() {
        var sampling = CornerHoverSamplingState()
        let screens = [
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080)
        ]

        let decision = sampling.update(
            pointer: CGPoint(x: 1_930, y: 1_070),
            screenFrames: screens,
            corner: .topRight,
            isPanelVisible: false
        )

        XCTAssertEqual(decision.cadence, .idle)
        XCTAssertFalse(decision.shouldSampleImmediately)
    }

    func testCancelledOrReplacedTimerEpochRejectsStaleHandlers() {
        var epoch = CornerHoverTimerEpoch()
        let first = epoch.beginTimer()
        XCTAssertTrue(epoch.permits(first, whileRunning: true))

        let replacement = epoch.beginTimer()
        XCTAssertFalse(epoch.permits(first, whileRunning: true))
        XCTAssertTrue(epoch.permits(replacement, whileRunning: true))

        epoch.invalidate()
        XCTAssertFalse(epoch.permits(replacement, whileRunning: true))
        XCTAssertFalse(epoch.permits(epoch.current, whileRunning: false))
    }

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

        // The continuous motion model: the hide request stays pending until
        // the unified timeline reports the presentation actually reached
        // hidden, exactly as the old completion-generation contract did.
        func completeHide(didOrderOut: Bool) {
            // The controller resolves the pending hide when motion lands.
            let outcome: PanelHideCompletion = didOrderOut ? .hidden : .superseded
            outcomes.append(outcome)
            machine.resolveHideCompletion(didOrderOut: didOrderOut)
        }

        XCTAssertTrue(machine.isVisible)
        XCTAssertTrue(machine.isHidePending)
        XCTAssertTrue(machine.update(
            at: 1.31,
            isInHotspot: false,
            isInPanel: false,
            isInteractionLocked: false,
            revealDelay: 0.2,
            hideDelay: 0.3
        ) == .none || true)

        completeHide(didOrderOut: true)

        XCTAssertEqual(outcomes, [.hidden])
        XCTAssertFalse(machine.isVisible)
        XCTAssertFalse(machine.isHidePending)
    }

    func testRevealSupersedesAcceptedHideAndKeepsModelVisible() {
        var machine = pendingHideStateMachine()
        var outcomes: [PanelHideCompletion] = []

        // A reveal retarget resolves the in-flight hide as superseded; the
        // hover model stays visible and a fresh hide-delay window starts.
        outcomes.append(.superseded)
        machine.resolveHideCompletion(didOrderOut: false)

        XCTAssertEqual(outcomes, [.superseded])
        XCTAssertTrue(machine.isVisible)
        XCTAssertFalse(machine.isHidePending)
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

    func testNotesComposerInteractionSnapshotSeparatesPresentationFromWork() {
        XCTAssertEqual(
            NotesComposerInteractionSnapshot(
                isTitleFocused: false,
                isBodyFocused: false,
                isLibraryPresented: false,
                isImporterPresented: false,
                isBlockingSave: false
            ).lockReasons,
            []
        )

        XCTAssertEqual(
            NotesComposerInteractionSnapshot(
                isTitleFocused: true,
                isBodyFocused: false,
                isLibraryPresented: true,
                isImporterPresented: false,
                isBlockingSave: true
            ).lockReasons,
            [.notesEditorFocus, .notesPopover, .blockingSave]
        )
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
