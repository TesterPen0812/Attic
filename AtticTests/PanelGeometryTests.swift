import AppKit
import Combine
import XCTest
@testable import Attic

final class PanelGeometryTests: XCTestCase {
    func testHotspotsOccupyExactScreenCorners() {
        let frame = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .topLeft), CGRect(x: -1_440, y: 884, width: 16, height: 16))
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .topRight), CGRect(x: -16, y: 884, width: 16, height: 16))
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .bottomLeft), CGRect(x: -1_440, y: 0, width: 16, height: 16))
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .bottomRight), CGRect(x: -16, y: 0, width: 16, height: 16))
    }

    func testPanelAnchorsInsideVisibleFrame() {
        let frame = CGRect(x: 0, y: 25, width: 1_920, height: 1_030)
        let size = CGSize(width: 340, height: 400)

        XCTAssertEqual(
            PanelGeometry.panelFrame(in: frame, size: size, corner: .topRight),
            CGRect(x: 1_568, y: 643, width: 340, height: 400)
        )
        XCTAssertEqual(
            PanelGeometry.panelFrame(in: frame, size: size, corner: .bottomLeft),
            CGRect(x: 12, y: 37, width: 340, height: 400)
        )
    }

    func testDockingSelectsNearestCornerForEveryQuadrant() {
        let visibleFrame = CGRect(x: -800, y: 25, width: 1_600, height: 900)
        let size = CGSize(width: 332, height: 480)

        for corner in ScreenCorner.allCases {
            let frame = PanelGeometry.panelFrame(
                in: visibleFrame,
                size: size,
                corner: corner
            )
            XCTAssertEqual(
                PanelDockingPolicy.nearestCorner(for: frame, in: visibleFrame),
                corner
            )
        }
    }

    func testDeliberateFlickChoosesDirectionWithoutRequiringBothAxes() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_600, height: 900)
        let frame = CGRect(x: 400, y: 520, width: 332, height: 480)

        XCTAssertEqual(
            PanelDockingPolicy.flickCorner(
                velocity: CGPoint(x: 900, y: -800),
                translation: CGPoint(x: 80, y: -70),
                panelFrame: frame,
                in: visibleFrame
            ),
            .bottomRight
        )
        XCTAssertEqual(
            PanelDockingPolicy.flickCorner(
                velocity: CGPoint(x: -900, y: 40),
                translation: CGPoint(x: -80, y: 4),
                panelFrame: frame,
                in: visibleFrame
            ),
            .topLeft
        )
    }

    func testShortOrSlowHeaderMovementDoesNotCountAsFlick() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_600, height: 900)
        let frame = CGRect(x: 400, y: 300, width: 332, height: 480)

        XCTAssertNil(
            PanelDockingPolicy.flickCorner(
                velocity: CGPoint(x: 900, y: 900),
                translation: CGPoint(x: 12, y: 12),
                panelFrame: frame,
                in: visibleFrame
            )
        )
        XCTAssertNil(
            PanelDockingPolicy.flickCorner(
                velocity: CGPoint(x: 120, y: 120),
                translation: CGPoint(x: 80, y: 80),
                panelFrame: frame,
                in: visibleFrame
            )
        )
    }

    func testFlickTowardAttachedCornerHidesForEveryCorner() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_600, height: 900)
        let frame = CGRect(x: 500, y: 300, width: 332, height: 480)
        let cases: [(ScreenCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: -900, y: 900)),
            (.topRight, CGPoint(x: 900, y: 900)),
            (.bottomLeft, CGPoint(x: -900, y: -900)),
            (.bottomRight, CGPoint(x: 900, y: -900))
        ]

        for (corner, velocity) in cases {
            let translation = CGPoint(
                x: velocity.x > 0 ? 80 : -80,
                y: velocity.y > 0 ? 80 : -80
            )
            XCTAssertEqual(
                PanelDockingPolicy.releaseAction(
                    velocity: velocity,
                    translation: translation,
                    attachedCorner: corner,
                    panelFrame: frame,
                    in: visibleFrame
                ),
                .hide
            )
        }
    }

    func testFlickTowardDifferentCornerMovesInsteadOfHiding() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_600, height: 900)
        let frame = CGRect(x: 500, y: 300, width: 332, height: 480)

        XCTAssertEqual(
            PanelDockingPolicy.releaseAction(
                velocity: CGPoint(x: -900, y: -900),
                translation: CGPoint(x: -80, y: -80),
                attachedCorner: .topRight,
                panelFrame: frame,
                in: visibleFrame
            ),
            .dock(.bottomLeft)
        )
    }

    func testSlowReleaseStillDocksInsteadOfHiding() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_600, height: 900)
        let frame = PanelGeometry.panelFrame(
            in: visibleFrame,
            size: CGSize(width: 332, height: 480),
            corner: .topRight
        )

        XCTAssertEqual(
            PanelDockingPolicy.releaseAction(
                velocity: CGPoint(x: 120, y: 120),
                translation: CGPoint(x: 80, y: 80),
                attachedCorner: .topRight,
                panelFrame: frame,
                in: visibleFrame
            ),
            .dock(.topRight)
        )
    }

    func testPreferredHeightIsClamped() {
        XCTAssertEqual(PanelGeometry.preferredHeight(taskCount: 0, sectionCount: 0, isComposing: false), PanelGeometry.minimumHeight)
        XCTAssertEqual(PanelGeometry.preferredHeight(taskCount: 100, sectionCount: 3, isComposing: true), PanelGeometry.preferredHeightCeiling)
    }

    func testLiveResizeLimitsAllowIndependentWidthAndHeightChanges() {
        XCTAssertEqual(PanelGeometry.minimumPanelSize, CGSize(width: 332, height: 480))
        XCTAssertEqual(PanelGeometry.defaultPanelSize.width, 332)
        XCTAssertEqual(PanelGeometry.defaultPanelSize.height, 481.4, accuracy: 0.001)

        XCTAssertEqual(
            PanelGeometry.clampedPanelSize(CGSize(width: 250, height: 620)),
            CGSize(width: 332, height: 620)
        )
        XCTAssertEqual(
            PanelGeometry.clampedPanelSize(CGSize(width: 640, height: 900)),
            CGSize(width: 640, height: 900)
        )
    }

    func testResizeMaximumSizeFitsTheVisibleScreen() {
        let compactVisibleFrame = CGRect(x: 0, y: 25, width: 600, height: 600)
        XCTAssertEqual(
            PanelGeometry.resizeMaximumSize(in: compactVisibleFrame),
            CGSize(width: 576, height: 576)
        )
        XCTAssertEqual(
            PanelGeometry.clampedPanelSize(
                CGSize(width: 700, height: 650),
                in: compactVisibleFrame
            ),
            CGSize(width: 576, height: 576)
        )
    }

    func testMaximumWorkAreaPlacementFitsEveryDockLayoutAndCorner() {
        let cases: [(visibleFrame: CGRect, expectedSize: CGSize)] = [
            (
                CGRect(x: 0, y: 70, width: 1_440, height: 800),
                CGSize(width: 1_416, height: 776)
            ),
            (
                CGRect(x: 80, y: 25, width: 1_360, height: 875),
                CGSize(width: 1_336, height: 851)
            ),
            (
                CGRect(x: -1_440, y: -850, width: 1_320, height: 825),
                CGSize(width: 1_296, height: 801)
            )
        ]

        for testCase in cases {
            let safeFrame = testCase.visibleFrame.insetBy(
                dx: PanelGeometry.screenInset,
                dy: PanelGeometry.screenInset
            )
            for corner in ScreenCorner.allCases {
                let placement = PanelGeometry.workAreaPlacement(
                    preferredSize: CGSize(width: 4_000, height: 4_000),
                    in: testCase.visibleFrame,
                    corner: corner
                )

                XCTAssertEqual(placement.frame.size, testCase.expectedSize)
                XCTAssertTrue(
                    safeFrame.contains(placement.frame),
                    "Maximum frame escaped for \(corner) in \(testCase.visibleFrame)"
                )
                XCTAssertTrue(placement.isTemporarilyClamped)
            }
        }
    }

    func testDockRelocationClampDoesNotReplacePreferredSize() {
        let preferredSize = CGSize(width: 1_200, height: 760)
        let sideDockVisibleFrame = CGRect(x: 100, y: 25, width: 1_000, height: 900)
        let roomyVisibleFrame = CGRect(x: 0, y: 25, width: 1_440, height: 900)

        let temporarilyClamped = PanelGeometry.workAreaPlacement(
            preferredSize: preferredSize,
            in: sideDockVisibleFrame,
            corner: .bottomRight
        )
        XCTAssertEqual(
            temporarilyClamped.frame,
            CGRect(x: 112, y: 37, width: 976, height: 760)
        )
        XCTAssertEqual(temporarilyClamped.preferredSize, preferredSize)
        XCTAssertTrue(temporarilyClamped.isTemporarilyClamped)

        let restored = PanelGeometry.workAreaPlacement(
            preferredSize: temporarilyClamped.preferredSize,
            in: roomyVisibleFrame,
            corner: .topRight
        )
        XCTAssertEqual(
            restored.frame,
            CGRect(x: 228, y: 153, width: 1_200, height: 760)
        )
        XCTAssertFalse(restored.isTemporarilyClamped)
    }

    func testScreenTransitionUsesDestinationVisibleFrameAndRestoresItsCornerAnchor() {
        let preferredSize = CGSize(width: 1_000, height: 760)
        let sourceVisibleFrame = CGRect(x: 0, y: 25, width: 1_920, height: 1_055)
        let destinationVisibleFrame = CGRect(x: -1_440, y: -900, width: 1_280, height: 720)
        let source = PanelGeometry.workAreaPlacement(
            preferredSize: preferredSize,
            in: sourceVisibleFrame,
            corner: .bottomLeft
        )

        let destination = PanelGeometry.workAreaPlacement(
            preferredSize: source.preferredSize,
            in: destinationVisibleFrame,
            corner: .bottomLeft
        )

        XCTAssertEqual(
            destination.frame,
            CGRect(x: -1_428, y: -888, width: 1_000, height: 696)
        )
        XCTAssertNotEqual(destination.frame.origin, source.frame.origin)
        XCTAssertTrue(destination.isTemporarilyClamped)
    }

    func testWorkAreaEventsIncludeScreenParametersAndApplicationActivation() {
        let center = NotificationCenter()
        var received: [PanelWorkAreaEvent] = []
        let observation = PanelWorkAreaEvents.publisher(center: center)
            .sink { received.append($0) }

        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(received, [.screenParametersChanged, .applicationActivated])
        withExtendedLifetime(observation) {}
    }

    func testTemporaryWorkAreaClampDuringResizeDoesNotBecomePreferredSize() {
        var state = PanelResizePersistenceState()
        state.beginUserResize()
        state.recordTemporaryWorkAreaClamp()

        XCTAssertNil(
            state.finishUserResize(at: CGSize(width: 976, height: 760))
        )
    }

    func testOrdinaryUserResizeStillProducesPreferredSize() {
        var state = PanelResizePersistenceState()
        state.beginUserResize()

        XCTAssertEqual(
            state.finishUserResize(at: CGSize(width: 680, height: 640)),
            CGSize(width: 680, height: 640)
        )
    }

    func testConstrainedFrameStaysAboveDockAndInsideMenuBarWorkArea() {
        let visibleFrame = CGRect(x: 0, y: 70, width: 1_440, height: 800)

        XCTAssertEqual(
            PanelGeometry.constrainedFrame(
                CGRect(x: 200, y: -180, width: 520, height: 620),
                to: visibleFrame
            ),
            CGRect(x: 200, y: 82, width: 520, height: 620)
        )
        XCTAssertEqual(
            PanelGeometry.constrainedFrame(
                CGRect(x: -400, y: 500, width: 2_000, height: 900),
                to: visibleFrame
            ),
            CGRect(x: 12, y: 82, width: 1_416, height: 776)
        )
    }

    func testHiddenTransitionFramesRemainInsideSafeAreaForEveryCorner() {
        let visibleFrame = CGRect(x: -1_440, y: 70, width: 1_440, height: 800)
        let safeFrame = visibleFrame.insetBy(
            dx: PanelGeometry.screenInset,
            dy: PanelGeometry.screenInset
        )
        let size = CGSize(width: 420, height: 560)

        for corner in ScreenCorner.allCases {
            let dockedFrame = PanelGeometry.panelFrame(
                in: visibleFrame,
                size: size,
                corner: corner
            )
            let hiddenFrame = PanelGeometry.hiddenFrame(
                from: dockedFrame,
                corner: corner,
                in: visibleFrame
            )

            XCTAssertTrue(safeFrame.contains(dockedFrame), "Docked frame escaped at \(corner)")
            XCTAssertTrue(safeFrame.contains(hiddenFrame), "Hidden frame escaped at \(corner)")

            for step in 0...10 {
                let progress = CGFloat(step) / 10
                let interpolated = CGRect(
                    x: hiddenFrame.minX + ((dockedFrame.minX - hiddenFrame.minX) * progress),
                    y: hiddenFrame.minY + ((dockedFrame.minY - hiddenFrame.minY) * progress),
                    width: hiddenFrame.width,
                    height: hiddenFrame.height
                )
                XCTAssertTrue(safeFrame.contains(interpolated), "Transition escaped at \(corner), step \(step)")
            }
        }
    }

    func testCrossDisplayTransitionIsEstablishedLocallyBeforeAnimation() {
        let sourceVisibleFrame = CGRect(x: 0, y: 70, width: 1_440, height: 800)
        let targetVisibleFrame = CGRect(x: 1_680, y: 25, width: 1_920, height: 1_055)
        let targetSafeFrame = targetVisibleFrame.insetBy(
            dx: PanelGeometry.screenInset,
            dy: PanelGeometry.screenInset
        )
        let size = CGSize(width: 420, height: 560)
        let sourceFrame = PanelGeometry.panelFrame(
            in: sourceVisibleFrame,
            size: size,
            corner: .bottomLeft
        )
        let targetFrame = PanelGeometry.panelFrame(
            in: targetVisibleFrame,
            size: size,
            corner: .topRight
        )

        XCTAssertNotEqual(
            PanelGeometry.constrainedFrame(sourceFrame, to: targetVisibleFrame),
            sourceFrame
        )

        let localInitialFrame = PanelGeometry.hiddenFrame(
            from: targetFrame,
            corner: .topRight,
            in: targetVisibleFrame
        )
        XCTAssertTrue(targetSafeFrame.contains(localInitialFrame))
        XCTAssertTrue(targetSafeFrame.contains(targetFrame))

        for step in 0...10 {
            let progress = CGFloat(step) / 10
            let interpolated = CGRect(
                x: localInitialFrame.minX + ((targetFrame.minX - localInitialFrame.minX) * progress),
                y: localInitialFrame.minY + ((targetFrame.minY - localInitialFrame.minY) * progress),
                width: localInitialFrame.width,
                height: localInitialFrame.height
            )
            XCTAssertTrue(targetSafeFrame.contains(interpolated), "Cross-display local transition escaped at step \(step)")
        }
    }

    func testMatchingFrameRevealInvalidatesPendingHideCompletion() {
        var state = PanelVisibilityTransitionState()
        let hideGeneration = state.beginTransition()

        // `show` invalidates before it can take the matching-frame path.
        state.invalidatePendingTransition()
        let revealGeneration = state.beginTransition()

        XCTAssertFalse(state.ownsCompletion(hideGeneration))
        XCTAssertTrue(state.ownsCompletion(revealGeneration))
    }

    func testDifferingFrameRevealInvalidatesPendingHideCompletion() {
        var state = PanelVisibilityTransitionState()
        let hideGeneration = state.beginTransition()

        // The frame animation receives a fresh owner after reveal invalidates
        // the hide, so only the new reveal may complete window state changes.
        state.invalidatePendingTransition()
        let revealGeneration = state.beginTransition()

        XCTAssertFalse(state.ownsCompletion(hideGeneration))
        XCTAssertTrue(state.ownsCompletion(revealGeneration))
        XCTAssertGreaterThan(revealGeneration, hideGeneration)
    }

    func testTaskScrollMaskUsesPointSizedFadesAcrossPanelHeights() {
        let compact = TaskScrollMaskLayout.stops(panelHeight: 480)
        let tall = TaskScrollMaskLayout.stops(panelHeight: 900)

        XCTAssertEqual(compact.topFadeEnd * 480, 18, accuracy: 0.001)
        XCTAssertEqual((1 - compact.bottomFadeStart) * 480, 76, accuracy: 0.001)
        XCTAssertEqual(tall.topFadeEnd * 900, 18, accuracy: 0.001)
        XCTAssertEqual((1 - tall.bottomFadeStart) * 900, 76, accuracy: 0.001)
    }

    @MainActor
    func testSectionSwitchingPreservesTheActualLivePanelSize() {
        let uiState = PanelUIState()
        let manuallySelectedSize = CGSize(width: 604, height: 638)
        uiState.updatePanelSize(manuallySelectedSize)

        for section in PanelSection.allCases {
            uiState.selectSection(section)
            XCTAssertEqual(uiState.panelSize, manuallySelectedSize)
        }
    }

    @MainActor
    func testWindowInteractionLocksAutoHideWithoutChangingPinState() {
        let uiState = PanelUIState()
        XCTAssertFalse(uiState.isPanelPinned)
        XCTAssertFalse(uiState.isInteractionLocked)

        uiState.setInteractionLock(.windowResize, isActive: true)
        XCTAssertTrue(uiState.isInteractionLocked)
        XCTAssertFalse(uiState.isPanelPinned)

        uiState.setInteractionLock(.windowResize, isActive: false)
        XCTAssertFalse(uiState.isInteractionLocked)
        XCTAssertFalse(uiState.isPanelPinned)
    }

    func testWorkspaceHeightIsStableAndResponsiveToConfiguredWidth() {
        XCTAssertEqual(PanelGeometry.preferredWorkspaceHeight(contentWidth: 300), 480)
        XCTAssertEqual(
            PanelGeometry.preferredWorkspaceHeight(contentWidth: 332),
            481.4,
            accuracy: 0.001
        )
        XCTAssertEqual(PanelGeometry.preferredWorkspaceHeight(contentWidth: 380), 551)
        XCTAssertEqual(
            PanelGeometry.preferredWorkspaceHeight(contentWidth: 1_000),
            PanelGeometry.preferredHeightCeiling
        )
    }
}
