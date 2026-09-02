import XCTest
@testable import Attic

final class PanelMotionTests: XCTestCase {
    // MARK: - Emergence geometry per corner

    func testEmergenceFrameStagesCloserToCornerThanDockedFrame() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_920, height: 1_055)
        let size = CGSize(width: 340, height: 500)

        for corner in ScreenCorner.allCases {
            let dockedFrame = PanelGeometry.panelFrame(
                in: visibleFrame,
                size: size,
                corner: corner
            )
            let emergenceFrame = PanelGeometry.hiddenFrame(
                from: dockedFrame,
                corner: corner,
                in: visibleFrame
            )

            // The staged frame must differ: the panel travels the inset
            // distance toward its attached corner, which proves the reveal
            // emerges from that physical origin.
            XCTAssertNotEqual(
                emergenceFrame,
                dockedFrame,
                "Emergence frame must stage away from the docked anchor for \(corner)"
            )
            XCTAssertEqual(emergenceFrame.size, dockedFrame.size)

            // The staging frame stays inside the usable visible frame: it
            // approaches the corner but never leaves the display, so it
            // can never slide under the Dock or menu bar.
            XCTAssertTrue(
                visibleFrame.contains(emergenceFrame),
                "Emergence frame escaped the visible frame for \(corner)"
            )

            // Motion direction: the origin moves strictly toward the
            // attached corner along each attaching axis.
            switch corner {
            case .topLeft:
                XCTAssertLessThan(emergenceFrame.minX, dockedFrame.minX)
                XCTAssertGreaterThan(emergenceFrame.maxY, dockedFrame.maxY)
            case .topRight:
                XCTAssertGreaterThan(emergenceFrame.maxX, dockedFrame.maxX)
                XCTAssertGreaterThan(emergenceFrame.maxY, dockedFrame.maxY)
            case .bottomLeft:
                XCTAssertLessThan(emergenceFrame.minX, dockedFrame.minX)
                XCTAssertLessThan(emergenceFrame.minY, dockedFrame.minY)
            case .bottomRight:
                XCTAssertGreaterThan(emergenceFrame.maxX, dockedFrame.maxX)
                XCTAssertLessThan(emergenceFrame.minY, dockedFrame.minY)
            }
        }
    }

    func testEmergenceFrameMatchesDockedFrameOnClampSaturatedDisplays() {
        // A display exactly as large as the panel leaves no travel room:
        // the staging frame equals the docked frame and the reveal
        // presents as an alpha-only motion with no teleport.
        let tinyVisibleFrame = CGRect(x: 0, y: 0, width: 336, height: 476)
        let dockedFrame = CGRect(origin: .zero, size: tinyVisibleFrame.size)
        let emergenceFrame = PanelGeometry.hiddenFrame(
            from: dockedFrame,
            corner: .topRight,
            in: tinyVisibleFrame
        )
        XCTAssertEqual(emergenceFrame, dockedFrame)
    }

    // MARK: - Progress model

    func testProgressInterpolationIsExactAlongCornerDiagonal() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_920, height: 1_055)
        let dockedFrame = PanelGeometry.panelFrame(
            in: visibleFrame,
            size: CGSize(width: 340, height: 500),
            corner: .bottomRight
        )
        let emergenceFrame = PanelGeometry.hiddenFrame(
            from: dockedFrame,
            corner: .bottomRight,
            in: visibleFrame
        )
        let geometry = PanelMotion.Geometry(
            visibleFrame: dockedFrame,
            hiddenFrame: emergenceFrame
        )

        XCTAssertEqual(
            PanelMotion.progress(of: emergenceFrame, in: geometry),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PanelMotion.progress(of: dockedFrame, in: geometry),
            1,
            accuracy: 0.001
        )

        let midpoint = geometry.frame(at: 0.5)
        XCTAssertEqual(
            PanelMotion.progress(of: midpoint, in: geometry),
            0.5,
            accuracy: 0.001
        )
    }

    func testProgressClampsOutsideStagedRange() {
        let geometry = PanelMotion.Geometry(
            visibleFrame: CGRect(x: 100, y: 100, width: 300, height: 400),
            hiddenFrame: CGRect(x: 82, y: 82, width: 300, height: 400)
        )
        XCTAssertEqual(PanelMotion.progress(of: CGRect(x: 40, y: 40, width: 300, height: 400), in: geometry), 0)
        XCTAssertEqual(PanelMotion.progress(of: CGRect(x: 200, y: 200, width: 300, height: 400), in: geometry), 1)
        XCTAssertEqual(
            PanelMotion.progress(
                of: CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 300, height: 400),
                in: geometry
            ),
            0
        )
    }

    func testMatchingFramesReportFullyRevealedProgress() {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 400)
        let geometry = PanelMotion.Geometry(
            visibleFrame: frame,
            hiddenFrame: frame
        )
        XCTAssertEqual(PanelMotion.progress(of: frame, in: geometry), 1)
    }

    // MARK: - Transition state machine

    func testTransitionPhasesExposeVisibilityAndActivity() {
        var transition = PanelMotion.Transition()
        XCTAssertEqual(transition.phase, .hidden)
        XCTAssertFalse(transition.isVisible)
        XCTAssertFalse(transition.isTransitioning)

        transition.beginReveal()
        XCTAssertTrue(transition.isVisible)
        XCTAssertTrue(transition.isTransitioning)

        transition.finishPresentation(at: 1)
        XCTAssertEqual(transition.phase, .visible)
        XCTAssertTrue(transition.isVisible)
        XCTAssertFalse(transition.isTransitioning)

        transition.beginHide()
        XCTAssertTrue(transition.isVisible)
        XCTAssertTrue(transition.isTransitioning)

        transition.finishPresentation(at: 0)
        XCTAssertEqual(transition.phase, .hidden)
    }

    func testReversalRetainsPresentedProgress() {
        var transition = PanelMotion.Transition()
        transition.beginReveal()
        transition.presentedProgress = 0.35

        transition.reverseToHide()
        XCTAssertEqual(transition.phase, .hiding)
        XCTAssertEqual(transition.presentedProgress, 0.35, accuracy: 0.001)

        transition.reverseToReveal()
        XCTAssertEqual(transition.phase, .revealing)
        XCTAssertEqual(transition.presentedProgress, 0.35, accuracy: 0.001)
    }

    func testMidFlightFinishUsesProgressThresholdCoherently() {
        var transition = PanelMotion.Transition()
        transition.beginReveal()
        transition.finishPresentation(at: 0.7)
        XCTAssertEqual(transition.phase, .visible)

        transition.beginHide()
        transition.finishPresentation(at: 0.2)
        XCTAssertEqual(transition.phase, .hidden)
    }

    func testDockingPhaseIsVisibleButActive() {
        var transition = PanelMotion.Transition()
        transition.beginDock()
        XCTAssertTrue(transition.isVisible)
        XCTAssertTrue(transition.isTransitioning)
        transition.finishPresentation(at: 1)
        XCTAssertEqual(transition.phase, .visible)
    }

    // MARK: - Intent ownership across interruption

    func testInterruptedAnimationCompletionIsRejectedByStaleIntent() {
        // The scenario: a hide starts, a reveal retargets it mid-flight,
        // and the window server then delivers the interrupted hide's
        // completion. The stale intent must not complete presentation.
        var transition = PanelMotion.Transition()
        transition.beginHide()
        let hideIntent = transition.intentSequence

        transition.beginReveal()
        let revealIntent = transition.intentSequence
        XCTAssertGreaterThan(revealIntent, hideIntent)

        // The interrupted hide's completion arrives late.
        XCTAssertFalse(transition.ownsCompletion(hideIntent))
        XCTAssertEqual(transition.phase, .revealing)

        // The current reveal's completion is accepted.
        XCTAssertTrue(transition.ownsCompletion(revealIntent))
        transition.finishPresentation(at: 1)
        XCTAssertEqual(transition.phase, .visible)
    }

    func testRapidReversalSequenceKeepsOnlyNewestIntent() {
        var transition = PanelMotion.Transition()
        transition.beginReveal()
        let first = transition.intentSequence
        transition.reverseToHide()
        let second = transition.intentSequence
        transition.reverseToReveal()
        let third = transition.intentSequence
        transition.reverseToHide()
        let fourth = transition.intentSequence

        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThan(third, second)
        XCTAssertGreaterThan(fourth, third)
        XCTAssertTrue(transition.ownsCompletion(fourth))
        XCTAssertEqual(transition.phase, .hiding)
    }

    func testUserTakeoverSupersedesEveryInFlightIntent() {
        var transition = PanelMotion.Transition()
        transition.beginReveal()
        let revealIntent = transition.intentSequence

        transition.beginUserTakeover()
        XCTAssertFalse(transition.ownsCompletion(revealIntent))
        XCTAssertEqual(transition.phase, .visible)
        XCTAssertEqual(transition.presentedProgress, 1)
        XCTAssertFalse(transition.isTransitioning)
    }

    // MARK: - Timing family

    func testDurationsAreImmediateButLegible() {
        XCTAssertLessThanOrEqual(PanelMotion.revealDuration, 0.25)
        XCTAssertLessThanOrEqual(PanelMotion.hideDuration, PanelMotion.revealDuration)
        XCTAssertLessThanOrEqual(PanelMotion.dockDuration, 0.3)
        XCTAssertGreaterThan(PanelMotion.revealDuration, 0)
    }

    func testReduceMotionUsesShortCrossfadeDurations() {
        XCTAssertEqual(
            PanelMotion.duration(for: .revealing, reduceMotion: true),
            PanelMotion.reduceMotionDuration
        )
        XCTAssertEqual(
            PanelMotion.duration(for: .hiding, reduceMotion: true),
            PanelMotion.reduceMotionDuration
        )
        XCTAssertEqual(
            PanelMotion.duration(for: .docking, reduceMotion: true),
            PanelMotion.reduceMotionDuration
        )
        XCTAssertGreaterThan(PanelMotion.reduceMotionDuration, 0)
    }

    func testTimingCurvesMatchNativeRevealAndHideFamilies() {
        XCTAssertEqual(
            PanelMotion.timingFunction(for: .revealing)?.controlPoints.0,
            0.16
        )
        XCTAssertEqual(
            PanelMotion.timingFunction(for: .hiding)?.controlPoints.0,
            0.4
        )
        XCTAssertNil(PanelMotion.timingFunction(for: .visible))
    }

    // MARK: - Two-finger swipe dismissal

    func testSwipeTowardAttachedCornerTriggersForEveryCorner() {
        // Natural scrolling (inverted): the delivered delta is negated
        // from the finger's physical direction. Finger flicks toward each
        // attached corner must trigger dismissal.
        let cases: [(ScreenCorner, CGFloat, CGFloat)] = [
            // Finger toward top-left: physical (-x, +y) → content (+x, -y)
            (.topLeft, 60, -60),
            // Finger toward top-right: physical (+x, +y) → content (-x, -y)
            (.topRight, -60, -60),
            // Finger toward bottom-left: physical (-x, -y) → content (+x, +y)
            (.bottomLeft, 60, 60),
            // Finger toward bottom-right: physical (+x, -y) → content (-x, +y)
            (.bottomRight, -60, 60)
        ]

        for (corner, deltaX, deltaY) in cases {
            var accumulator = PanelSwipeDismissalPolicy.Accumulator()
            let triggered = accumulator.record(
                scrollingDeltaX: deltaX,
                scrollingDeltaY: deltaY,
                corner: corner,
                isDeviceDirectionInverted: true
            )
            XCTAssertTrue(triggered, "Expected dismissal for \(corner)")
        }
    }

    func testClassicScrollingStillTriggersForPhysicalFingerDirection() {
        // Classic scrolling (not inverted): the delivered delta follows
        // the finger. The same physical top-left flick delivers the
        // opposite sign and must still trigger.
        var accumulator = PanelSwipeDismissalPolicy.Accumulator()
        XCTAssertTrue(accumulator.record(
            scrollingDeltaX: -60,
            scrollingDeltaY: 60,
            corner: .topLeft,
            isDeviceDirectionInverted: false
        ))
    }

    func testSwipeAwayFromAttachedCornerDoesNotTrigger() {
        // A flick directly away from the attached corner points at neither
        // attached edge and must never accumulate. From top-left that is
        // physically down-and-right: content delta (-x, +y) inverted.
        var accumulator = PanelSwipeDismissalPolicy.Accumulator()
        XCTAssertFalse(accumulator.record(
            scrollingDeltaX: -60,
            scrollingDeltaY: 60,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
        XCTAssertFalse(accumulator.record(
            scrollingDeltaX: -600,
            scrollingDeltaY: 600,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
    }

    func testSwipeRequiresDeliberateDistance() {
        var accumulator = PanelSwipeDismissalPolicy.Accumulator()
        // Two-thirds of the trigger distance along one axis only.
        XCTAssertFalse(accumulator.record(
            scrollingDeltaX: 30,
            scrollingDeltaY: 0,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
        // Crosses the threshold on the next deliberate sample.
        XCTAssertTrue(accumulator.record(
            scrollingDeltaX: 25,
            scrollingDeltaY: 0,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
    }

    func testSwipeTriggersOnlyOncePerGesture() {
        var accumulator = PanelSwipeDismissalPolicy.Accumulator()
        XCTAssertTrue(accumulator.record(
            scrollingDeltaX: 80,
            scrollingDeltaY: -80,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
        XCTAssertFalse(accumulator.record(
            scrollingDeltaX: 80,
            scrollingDeltaY: -80,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))

        accumulator.reset()
        XCTAssertTrue(accumulator.record(
            scrollingDeltaX: 80,
            scrollingDeltaY: -80,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
    }

    func testPerpendicularJitterDoesNotCancelDeliberateSwipe() {
        var accumulator = PanelSwipeDismissalPolicy.Accumulator()
        // Deliberate swipe toward the top-left with perpendicular jitter:
        // only components pointing at the corner accumulate, so jitter
        // never cancels the deliberate gesture.
        XCTAssertFalse(accumulator.record(
            scrollingDeltaX: 30,
            scrollingDeltaY: 10,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
        XCTAssertTrue(accumulator.record(
            scrollingDeltaX: 30,
            scrollingDeltaY: -40,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
    }

    func testNonFiniteSwipeDeltasAreIgnored() {
        var accumulator = PanelSwipeDismissalPolicy.Accumulator()
        XCTAssertFalse(accumulator.record(
            scrollingDeltaX: .nan,
            scrollingDeltaY: -80,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
        XCTAssertFalse(accumulator.record(
            scrollingDeltaX: 80,
            scrollingDeltaY: CGFloat.infinity,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
    }

    func testDiagonalSwipeTowardEitherAttachedEdgeTriggers() {
        // A corner attaches to two edges; a deliberate swipe along either
        // one is a dismissal toward that corner.
        var horizontalOnly = PanelSwipeDismissalPolicy.Accumulator()
        XCTAssertTrue(horizontalOnly.record(
            scrollingDeltaX: 70,
            scrollingDeltaY: 0,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))

        var verticalOnly = PanelSwipeDismissalPolicy.Accumulator()
        XCTAssertTrue(verticalOnly.record(
            scrollingDeltaX: 0,
            scrollingDeltaY: -70,
            corner: .topLeft,
            isDeviceDirectionInverted: true
        ))
    }
}