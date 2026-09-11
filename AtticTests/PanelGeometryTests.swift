import AppKit
import Combine
import QuartzCore
import XCTest
@testable import Attic

final class PanelGeometryTests: XCTestCase {
    // MARK: - Genie geometry

    private let geniePanelSize = CGSize(width: 492, height: 644)

    private func genieAnchor(
        corner: ScreenCorner,
        workArea: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 945),
        panelOrigin: CGPoint = .zero
    ) -> CGPoint {
        let anchor = PanelGenieGeometry.anchorPoint(in: workArea, corner: corner)
        return CGPoint(x: anchor.x - panelOrigin.x, y: anchor.y - panelOrigin.y)
    }

    private func genieSamplePoints(in size: CGSize) -> [CGPoint] {
        var points: [CGPoint] = []
        for row in 0...6 {
            for column in 0...6 {
                points.append(CGPoint(
                    x: size.width * CGFloat(column) / 6,
                    y: size.height * CGFloat(row) / 6
                ))
            }
        }
        return points
    }

    func testGenieAnchorLandsOnTheConfiguredCornerInsideTheWorkArea() {
        let workAreas = [
            CGRect(x: 0, y: 0, width: 1512, height: 945),
            CGRect(x: -1920, y: 24, width: 1920, height: 1040),
            CGRect(x: 300, y: -700, width: 640, height: 480),
        ]
        let inset = PanelGenieGeometry.Spec.standard.anchorInset
        for workArea in workAreas {
            for corner in ScreenCorner.allCases {
                let anchor = PanelGenieGeometry.anchorPoint(in: workArea, corner: corner)
                XCTAssertTrue(workArea.contains(anchor))
                let expectedX = [.topRight, .bottomRight].contains(corner)
                    ? workArea.maxX - inset : workArea.minX + inset
                let expectedY = [.topRight, .topLeft].contains(corner)
                    ? workArea.maxY - inset : workArea.minY + inset
                XCTAssertEqual(anchor.x, expectedX, accuracy: 0.001)
                XCTAssertEqual(anchor.y, expectedY, accuracy: 0.001)
            }
        }
    }

    func testGenieWarpIsIdentityAtRestAndFullyConsumedAtThePoint() {
        for corner in ScreenCorner.allCases {
            let anchor = genieAnchor(corner: corner)
            for point in genieSamplePoints(in: geniePanelSize) {
                let rest = PanelGenieGeometry.warpedPoint(
                    point, in: geniePanelSize, progress: 0,
                    corner: corner, anchor: anchor
                )
                XCTAssertEqual(rest, point)
                let consumed = PanelGenieGeometry.warpedPoint(
                    point, in: geniePanelSize, progress: 1,
                    corner: corner, anchor: anchor
                )
                XCTAssertEqual(consumed.x, anchor.x, accuracy: 0.001)
                XCTAssertEqual(consumed.y, anchor.y, accuracy: 0.001)
            }
        }
    }

    func testGenieWarpContractsMonotonicallyTowardTheAnchorAlongRays() {
        for corner in ScreenCorner.allCases {
            let anchor = genieAnchor(corner: corner)
            for point in genieSamplePoints(in: geniePanelSize) {
                var previousDistance = CGFloat.greatestFiniteMagnitude
                for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let warped = PanelGenieGeometry.warpedPoint(
                        point, in: geniePanelSize, progress: CGFloat(progress),
                        corner: corner, anchor: anchor
                    )
                    XCTAssertTrue(warped.x.isFinite && warped.y.isFinite)
                    // Every destination stays on the segment source → anchor,
                    // so the sheet can never fold, tear, or overshoot.
                    let distance = hypot(warped.x - anchor.x, warped.y - anchor.y)
                    let sourceDistance = hypot(point.x - anchor.x, point.y - anchor.y)
                    XCTAssertLessThanOrEqual(distance, sourceDistance + 0.001)
                    XCTAssertLessThanOrEqual(distance, previousDistance + 0.001)
                    previousDistance = distance
                }
            }
        }
    }

    func testGenieWarpDoesNotCollapseDistinctRaysEarly() {
        // Points on different rays from the anchor keep distinct destinations
        // until fully consumed — the mesh is injective before the tip.
        let corner = ScreenCorner.topRight
        let anchor = genieAnchor(corner: corner)
        let progress: CGFloat = 0.6
        let sources = genieSamplePoints(in: geniePanelSize)
        var destinations = Set<String>()
        for point in sources {
            let warped = PanelGenieGeometry.warpedPoint(
                point, in: geniePanelSize, progress: progress,
                corner: corner, anchor: anchor
            )
            destinations.insert("\(warped.x.rounded())-\(warped.y.rounded())")
        }
        XCTAssertGreaterThan(destinations.count, sources.count / 2)
    }

    func testGenieWarpFailsSafeOnInvalidInput() {
        let point = CGPoint(x: 10, y: 10)
        XCTAssertEqual(PanelGenieGeometry.warpedPoint(
            point, in: .zero, progress: 0.5, corner: .topRight,
            anchor: genieAnchor(corner: .topRight)
        ), point)
        XCTAssertEqual(PanelGenieGeometry.warpedPoint(
            point, in: geniePanelSize, progress: .nan, corner: .topRight,
            anchor: genieAnchor(corner: .topRight)
        ), point)
        XCTAssertEqual(PanelGenieGeometry.warpedPoint(
            point, in: geniePanelSize, progress: 0.5, corner: .topRight,
            anchor: CGPoint(x: .nan, y: 0)
        ), point)
    }

    func testGenieDestinationGridIsIdentityAtRestAndMeshIsBounded() {
        let divisions = PanelGenieGeometry.meshDivisions(for: geniePanelSize)
        XCTAssertGreaterThanOrEqual(divisions.columns, 16)
        XCTAssertLessThanOrEqual(divisions.columns, 56)
        let sources = PanelGenieGeometry.sourcePositions(
            columns: divisions.columns, rows: divisions.rows
        )
        XCTAssertEqual(sources.count, (divisions.columns + 1) * (divisions.rows + 1))
        let rested = PanelGenieGeometry.destinationPositions(
            columns: divisions.columns, rows: divisions.rows,
            size: geniePanelSize, progress: 0,
            corner: .topRight, anchor: genieAnchor(corner: .topRight)
        )
        XCTAssertEqual(rested, sources)
        for size in [CGSize.zero, CGSize(width: -1, height: .infinity),
                     CGSize(width: 4000, height: 3000)] {
            let bounded = PanelGenieGeometry.meshDivisions(for: size)
            XCTAssertLessThanOrEqual(bounded.columns, 56)
            XCTAssertLessThanOrEqual(bounded.rows, 56)
            XCTAssertGreaterThanOrEqual(bounded.columns, 16)
            XCTAssertGreaterThanOrEqual(bounded.rows, 16)
        }
        // Degenerate size returns the identity field rather than NaNs.
        XCTAssertEqual(
            PanelGenieGeometry.destinationPositions(
                columns: 4, rows: 4, size: .zero, progress: 0.5,
                corner: .topRight, anchor: genieAnchor(corner: .topRight)
            ).count,
            25
        )
    }

    func testGenieTimingCurvesAreBoundedMonotonicAndDirectional() {
        for timing in [PanelGenieGeometry.CubicBezierTiming.conceal,
                       .reveal] {
            XCTAssertEqual(timing.solve(0), 0)
            XCTAssertEqual(timing.solve(1), 1)
            var previous: CGFloat = -0.001
            for step in stride(from: 0.0, through: 1.0, by: 0.02) {
                let y = timing.solve(CGFloat(step))
                XCTAssertTrue(y.isFinite)
                XCTAssertGreaterThanOrEqual(y, -0.001)
                XCTAssertLessThanOrEqual(y, 1.001)
                XCTAssertGreaterThanOrEqual(y, previous)
                previous = y
            }
        }
        // Reveal answers earlier than conceal through the whole middle.
        for step in stride(from: 0.05, through: 0.95, by: 0.05) {
            XCTAssertGreaterThan(
                PanelGenieGeometry.CubicBezierTiming.reveal.solve(CGFloat(step)),
                PanelGenieGeometry.CubicBezierTiming.conceal.solve(CGFloat(step))
            )
        }
        XCTAssertEqual(
            PanelGenieGeometry.CubicBezierTiming.conceal.solve(.nan), 0
        )
    }

    func testGenieRunsAreDeterministicBoundedAndComplete() {
        let run = PanelGenieGeometry.planRun(
            from: 0.25, to: 1, direction: .conceal
        )
        XCTAssertNil(run.startTime)
        XCTAssertGreaterThanOrEqual(run.duration, 0.09)
        XCTAssertLessThanOrEqual(run.duration, 0.34)
        var started = run
        started.startTime = 100
        XCTAssertEqual(started.progress(at: 99), 0.25)
        XCTAssertEqual(started.progress(at: 100), 0.25, accuracy: 0.001)
        XCTAssertEqual(started.progress(at: 100 + run.duration), 1, accuracy: 0.001)
        XCTAssertTrue(started.isComplete(at: 100 + run.duration))
        let mid = started.progress(at: 100 + run.duration / 2)
        XCTAssertGreaterThan(mid, 0.25)
        XCTAssertLessThan(mid, 1)
        XCTAssertFalse(started.isComplete(at: 100 + run.duration / 2))
        // A full hide is always within budget; a reversal scales down.
        let full = PanelGenieGeometry.transitionDuration(distance: 1, direction: .conceal)
        XCTAssertEqual(full, 0.34, accuracy: 0.001)
        let reveal = PanelGenieGeometry.transitionDuration(distance: 1, direction: .reveal)
        XCTAssertEqual(reveal, 0.38, accuracy: 0.001)
        let partial = PanelGenieGeometry.transitionDuration(distance: 0.3, direction: .conceal)
        XCTAssertLessThan(partial, full)
        XCTAssertGreaterThanOrEqual(partial, 0.09)
    }

    func testGenieSwipeProgressIsBoundedAndReversible() {
        let forward = PanelGenieGeometry.swipeProgress(forSwipeDistance: 60, panelWidth: 332)
        let reverse = PanelGenieGeometry.swipeProgress(forSwipeDistance: 20, panelWidth: 332)
        XCTAssertGreaterThan(forward, reverse)
        XCTAssertGreaterThan(reverse, 0)
        XCTAssertEqual(PanelGenieGeometry.swipeProgress(forSwipeDistance: -10, panelWidth: 332), 0)
        XCTAssertEqual(PanelGenieGeometry.swipeProgress(forSwipeDistance: 10_000, panelWidth: 332), 0.95)
        XCTAssertEqual(PanelGenieGeometry.swipeProgress(forSwipeDistance: .infinity, panelWidth: 332), 0)
        XCTAssertEqual(PanelGenieGeometry.swipeProgress(forSwipeDistance: 10, panelWidth: .nan), 0)
    }

    func testGenieDisplayProgressNeverDegeneratesTheMesh() {
        let ceiling = PanelGenieGeometry.Spec.standard.displayProgressCeiling
        XCTAssertEqual(PanelGenieGeometry.displayProgress(1), ceiling)
        XCTAssertEqual(PanelGenieGeometry.displayProgress(-2), 0)
        XCTAssertEqual(PanelGenieGeometry.displayProgress(.nan), 0)
        XCTAssertEqual(PanelGenieGeometry.displayProgress(0.4), 0.4, accuracy: 0.001)
    }

    func testVerySlowPreciseSwipeAccumulatesIntentAndReportsEveryLaterSample() {
        for corner in ScreenCorner.allCases {
            for inverted in [false, true] {
                let side: CGFloat = [.topRight, .bottomRight].contains(corner) ? -1 : 1
                let delta = 0.2 * side * (inverted ? -1 : 1)
                var intent = PanelTrackpadSwipeIntent()
                var tracker = PanelTrackpadDismissTracker()
                for index in 0..<300 {
                    intent.accumulate(deltaX: delta, deltaY: 0)
                    let update = tracker.update(sample: PanelTrackpadSwipeSample(
                        deltaX: delta, deltaY: 0, phase: index == 0 ? .began : .changed,
                        isPrecise: true, isDirectionInvertedFromDevice: inverted
                    ), dockedCorner: corner)
                    XCTAssertEqual(intent.isReady, index >= 2)
                    XCTAssertTrue(intent.isHorizontal)
                    XCTAssertEqual(update, index >= 2 ? .tracking : .passThrough)
                    if index >= 2 {
                        XCTAssertEqual(tracker.progress, CGFloat(index + 1) * 0.2, accuracy: 0.001)
                    }
                }
                XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
                    deltaX: 0, deltaY: 0, phase: .ended,
                    isPrecise: true, isDirectionInvertedFromDevice: inverted
                ), dockedCorner: corner), .requestHide)
            }
        }
    }

    func testTinyVerticalSamplesRemainContentOwnedEvenAfterTurningHorizontal() {
        var intent = PanelTrackpadSwipeIntent()
        var tracker = PanelTrackpadDismissTracker()
        for index in 0..<300 {
            intent.accumulate(deltaX: 0, deltaY: 0.2)
            XCTAssertFalse(intent.isHorizontal)
            XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
                deltaX: 0, deltaY: 0.2, phase: index == 0 ? .began : .changed,
                isPrecise: true, isDirectionInvertedFromDevice: false
            ), dockedCorner: .topRight), .passThrough)
        }
        intent.accumulate(deltaX: -100, deltaY: 0)
        XCTAssertFalse(intent.isHorizontal, "Initial content direction cannot turn into panel dismissal")
        for phase in [PanelTrackpadSwipePhase.changed, .ended] {
            XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
                deltaX: -100, deltaY: 0, phase: phase,
                isPrecise: true, isDirectionInvertedFromDevice: false
            ), dockedCorner: .topRight), .passThrough)
        }
    }

    func testTinyInitialMovementAwayCannotBeReinterpretedAsDismissal() {
        var tracker = PanelTrackpadDismissTracker()
        XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
            deltaX: 0.2, deltaY: 0, phase: .began,
            isPrecise: true, isDirectionInvertedFromDevice: false
        ), dockedCorner: .topRight), .passThrough)
        XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
            deltaX: -80, deltaY: 0, phase: .changed,
            isPrecise: true, isDirectionInvertedFromDevice: false
        ), dockedCorner: .topRight), .passThrough)
        XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
            deltaX: 0, deltaY: 0, phase: .ended,
            isPrecise: true, isDirectionInvertedFromDevice: false
        ), dockedCorner: .topRight), .passThrough)
    }

    @MainActor
    func testSwipeReportsFingerProgressAndRestoresAfterReversalBelowThreshold() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var samples: [CGFloat] = []
        var cancellations = 0
        var hides = 0
        panel.onTrackpadDismissProgress = { samples.append($0) }
        panel.onTrackpadDismissCancelled = { cancellations += 1 }
        panel.onTrackpadDismissRequest = { hides += 1 }
        panel.sendEvent(try panelScrollEvent(deltaX: -20, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: -40, deltaY: 0, phase: .changed))
        panel.sendEvent(try panelScrollEvent(deltaX: 35, deltaY: 0, phase: .changed))
        XCTAssertEqual(samples, [20, 60, 25], "The surface follows every delivered sample before fingers lift")
        XCTAssertEqual(hides, 0)
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(hides, 0)
        panel.cancelTrackpadSwipe()
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testCommittedSwipeDoesNotRestoreBeforeStartingTheCommonHideTransition() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var events: [String] = []
        panel.onTrackpadDismissProgress = { _ in events.append("progress") }
        panel.onTrackpadDismissCancelled = { events.append("restore") }
        panel.onTrackpadDismissRequest = { events.append("hide") }
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(events, ["progress", "hide"])
        panel.cancelTrackpadSwipe()
        XCTAssertEqual(events, ["progress", "hide"])
    }

    @MainActor
    func testInterruptedSwipeRestoresOnceAndRequiresAnotherBegin() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var cancellations = 0
        var hides = 0
        panel.onTrackpadDismissCancelled = { cancellations += 1 }
        panel.onTrackpadDismissRequest = { hides += 1 }
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.resignKey()
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .changed))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(hides, 0)
    }

    @MainActor
    func testDirectInputSettlesTheCancelledSwipeBeforeResponderDispatch() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var events: [String] = []
        panel.onTrackpadDismissCancelled = { events.append("restore") }
        panel.onDirectContentInteraction = { events.append("settle") }
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        let modifier = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .shift,
            timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
        ))
        panel.sendEvent(modifier)
        XCTAssertEqual(events, ["restore", "settle"])
        panel.cancelTrackpadSwipe()
        XCTAssertEqual(events, ["restore", "settle"], "Stale gesture cleanup cannot restart the return animation")
    }

    @MainActor
    func testHostedGenieSessionVirtualizesWithoutChangingNativeOrSwiftUILayout() throws {
        try withHiddenHostedPanel { panel, host in
            let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
            let nativeFrame = panel.frame
            let hostingFrame = host.frame
            let hostingBounds = host.bounds
            let screen = try XCTUnwrap(NSScreen.main)
            guard let session = PanelGenieSession.begin(
                panel: panel, contentContainer: container,
                motionView: container.motionView,
                screen: screen, corner: .bottomLeft, initialProgress: 0
            ) else {
                XCTFail("Snapshot capture must succeed for hosted content")
                return
            }
            XCTAssertTrue(session.isPresenting)
            XCTAssertTrue(container.motionView.isHidden,
                          "Virtualized content draws nothing while the snapshot presents")
            session.applyImmediately(0.65)
            XCTAssertEqual(session.progress, 0.65, accuracy: 0.001)
            XCTAssertEqual(panel.frame, nativeFrame)
            XCTAssertEqual(host.frame, hostingFrame)
            XCTAssertEqual(host.bounds, hostingBounds)
            session.teardown()
            XCTAssertFalse(container.motionView.isHidden)
            XCTAssertFalse(session.isPresenting)
            XCTAssertEqual(host.bounds, hostingBounds)
        }
    }

    @MainActor
    func testGenieRunCompletionFiresExactlyOnceAndSupersessionDiscardsStale() throws {
        try withHiddenHostedPanel { panel, host in
            let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
            let screen = try XCTUnwrap(NSScreen.main)
            let session = try XCTUnwrap(PanelGenieSession.begin(
                panel: panel, contentContainer: container,
                motionView: container.motionView,
                screen: screen, corner: .topRight, initialProgress: 0.5
            ))
            var hides = 0
            var reveals = 0
            session.animate(to: 1, direction: .conceal) { hides += 1 }
            XCTAssertTrue(session.isMotionActive)
            // Rapid reversal: the newer run replaces the stale completion
            // without firing it — the interruption contract.
            session.animate(to: 0, direction: .reveal) { reveals += 1 }
            session.finishImmediately()
            XCTAssertEqual(session.progress, 0)
            XCTAssertEqual(hides, 0, "The superseded hide must never complete")
            XCTAssertEqual(reveals, 1)
            XCTAssertFalse(session.isMotionActive)
            session.finishImmediately()
            XCTAssertEqual(reveals, 1, "A finished session has nothing left to complete")
            session.teardown()
        }
    }

    @MainActor
    func testSettingsSizeAndCornerResetWarpedPresentationBeforeReanchoring() throws {
        let suite = "AtticPanelMotionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore())
        let settings = AppSettings(defaults: defaults)
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: PanelUIState()
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
        XCTAssertFalse(panel.isVisible, "This regression must not display a test window")
        let screen = try XCTUnwrap(controller.currentScreen)
        for corner in ScreenCorner.allCases {
            controller.genieSession = PanelGenieSession.begin(
                panel: panel, contentContainer: container,
                motionView: container.motionView,
                screen: screen, corner: controller.currentCorner, initialProgress: 0.5
            )
            XCTAssertTrue(container.motionView.isHidden)
            settings.corner = corner
            XCTAssertNil(controller.genieSession,
                         "Re-anchoring must tear down the in-flight presentation")
            XCTAssertFalse(container.motionView.isHidden)
            XCTAssertEqual(controller.currentCorner, corner)
            controller.genieSession = PanelGenieSession.begin(
                panel: panel, contentContainer: container,
                motionView: container.motionView,
                screen: screen, corner: corner, initialProgress: 0.5
            )
            settings.persistPanelSize(CGSize(
                width: settings.panelContentSize == 480 ? 420 : 480,
                height: settings.panelHeight == 620 ? 600 : 620
            ))
            XCTAssertNil(controller.genieSession)
            XCTAssertFalse(container.motionView.isHidden)
            let expected = PanelGeometry.workAreaPlacement(
                preferredSize: CGSize(width: settings.panelContentSize, height: settings.panelHeight),
                in: screen.visibleFrame, corner: corner
            ).frame
            XCTAssertEqual(panel.visibleContentFrame, expected)
            XCTAssertEqual(container.hostingView.frame.size, expected.size)
            XCTAssertFalse(panel.isVisible)
        }
        withExtendedLifetime(controller) {}
    }

    @MainActor
    func testStaleHideCannotCompleteAfterReveal() {
        var transitions = PanelVisibilityTransitionState()
        var hidden = 0
        var superseded = 0
        let hide = transitions.beginHideTransition { result in
            if result == .hidden { hidden += 1 } else { superseded += 1 }
        }
        _ = transitions.beginTransition()
        XCTAssertEqual(superseded, 1)
        XCTAssertFalse(transitions.completeHideTransition(hide))
        XCTAssertFalse(transitions.ownsCompletion(hide))
        XCTAssertEqual(hidden, 0,
                       "A stale hide completion can never order out a re-shown panel")
    }

    @MainActor
    func testHideCompletionStillFiresThroughItsOwnGeneration() {
        var transitions = PanelVisibilityTransitionState()
        var results: [PanelHideCompletion] = []
        let hide = transitions.beginHideTransition { results.append($0) }
        XCTAssertTrue(transitions.ownsCompletion(hide))
        XCTAssertTrue(transitions.completeHideTransition(hide))
        XCTAssertEqual(results, [.hidden])
    }

    @MainActor
    func testHostedResizeUsesDeliveredMovementWithoutMovingGlobalCursor() throws {
        try withHiddenHostedPanel { panel, host in
            let initial = panel.visibleContentFrame
            let down = CGPoint(x: initial.midX, y: initial.minY + 1)
            let dragged = CGPoint(x: down.x, y: down.y + 40)
            var endedSize: CGSize?
            host.onLiveResizeEnded = { endedSize = $0 }

            host.mouseDown(with: try panelMouseEvent(.leftMouseDown, at: down, in: panel, timestamp: 1))
            host.mouseDragged(with: try panelMouseEvent(.leftMouseDragged, at: dragged, in: panel, timestamp: 1.1))
            host.mouseUp(with: try panelMouseEvent(.leftMouseUp, at: dragged, in: panel, timestamp: 1.2))

            XCTAssertEqual(panel.visibleContentFrame.height, initial.height - 40, accuracy: 0.01)
            XCTAssertEqual(panel.visibleContentFrame.maxY, initial.maxY, accuracy: 0.01)
            XCTAssertEqual(endedSize, panel.visibleContentFrame.size)
        }
    }

    @MainActor
    func testHostedMoveAndReleaseUseDeliveredScreenPoints() throws {
        try withHiddenHostedPanel { panel, host in
            let initial = panel.visibleContentFrame
            let down = CGPoint(x: initial.midX, y: initial.maxY - 6)
            let dragged = CGPoint(x: down.x - 40, y: down.y - 30)
            let released = CGPoint(x: dragged.x - 5, y: dragged.y - 3)
            var releasedPoint: CGPoint?
            var translation: CGPoint?
            host.onWindowDragEnded = { _, point, _, delta in
                releasedPoint = point
                translation = delta
            }

            host.mouseDown(with: try panelMouseEvent(.leftMouseDown, at: down, in: panel, timestamp: 1))
            host.mouseDragged(with: try panelMouseEvent(.leftMouseDragged, at: dragged, in: panel, timestamp: 1.1))
            host.mouseUp(with: try panelMouseEvent(.leftMouseUp, at: released, in: panel, timestamp: 1.2))

            XCTAssertEqual(panel.visibleContentFrame.minX, initial.minX - 40, accuracy: 0.01)
            XCTAssertEqual(panel.visibleContentFrame.minY, initial.minY - 30, accuracy: 0.01)
            XCTAssertEqual(releasedPoint, released)
            XCTAssertEqual(translation, CGPoint(x: -45, y: -33))
        }
    }

    func testInterruptedDockTransitionReleasesItsInteractionLockExactlyOnce() {
        var state = PanelVisibilityTransitionState()
        var releases = 0
        let docking = state.beginTransition(onSuperseded: { releases += 1 })
        state.invalidatePendingTransition()
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(state.completeTransition(docking))
        _ = state.beginTransition()
        XCTAssertEqual(releases, 1)
    }

    func testCompletedDockDoesNotRunCancellationOnNextReveal() {
        var state = PanelVisibilityTransitionState()
        var cancellations = 0
        let docking = state.beginTransition(onSuperseded: { cancellations += 1 })
        XCTAssertTrue(state.completeTransition(docking))
        state.invalidatePendingTransition()
        XCTAssertEqual(cancellations, 0)
    }

    func testTinyVisibleAreaWinsOverPreferredMinimumAndPreservesPreference() {
        let visible = CGRect(x: -400, y: 120, width: 320, height: 460)
        for corner in ScreenCorner.allCases {
            let placement = PanelGeometry.workAreaPlacement(
                preferredSize: PanelGeometry.minimumPanelSize, in: visible, corner: corner
            )
            XCTAssertEqual(placement.preferredSize, PanelGeometry.minimumPanelSize)
            XCTAssertEqual(placement.frame.size, CGSize(width: 296, height: 436))
            XCTAssertTrue(visible.insetBy(dx: 12, dy: 12).contains(placement.frame))
        }
    }

    @MainActor
    func testNativeDisplayedSizeIsNotEnlargedBackToPreferredMinimum() {
        let state = PanelUIState()
        state.updatePanelSize(CGSize(width: 296, height: 436))
        XCTAssertEqual(state.panelSize, CGSize(width: 296, height: 436))
        state.updatePanelSize(CGSize(width: CGFloat.infinity, height: 20))
        XCTAssertEqual(state.panelSize, CGSize(width: 296, height: 436))
    }

    func testCancelledSwipeCannotResumeWithoutFreshBegin() {
        var tracker = PanelTrackpadDismissTracker()
        _ = tracker.update(sample: PanelTrackpadSwipeSample(
            deltaX: -30, deltaY: 0, phase: .began, isPrecise: true,
            isDirectionInvertedFromDevice: false
        ), dockedCorner: .topRight)
        tracker.cancel()
        XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
            deltaX: -80, deltaY: 0, phase: .changed, isPrecise: true,
            isDirectionInvertedFromDevice: false
        ), dockedCorner: .topRight), .passThrough)
        XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
            deltaX: 0, deltaY: 0, phase: .ended, isPrecise: true,
            isDirectionInvertedFromDevice: false
        ), dockedCorner: .topRight), .passThrough)
    }

    func testSwipeCountsTerminalMovementAndNormalizesBothScrollSettingsAtEveryCorner() {
        for corner in ScreenCorner.allCases {
            for inverted in [false, true] {
                let left = corner == .topLeft || corner == .bottomLeft
                let delta: CGFloat = (left ? 1 : -1) * (inverted ? -1 : 1)
                var tracker = PanelTrackpadDismissTracker()
                _ = tracker.update(sample: PanelTrackpadSwipeSample(
                    deltaX: delta * 30, deltaY: 0, phase: .began, isPrecise: true,
                    isDirectionInvertedFromDevice: inverted
                ), dockedCorner: corner)
                XCTAssertEqual(tracker.update(sample: PanelTrackpadSwipeSample(
                    deltaX: delta * 18, deltaY: 0, phase: .ended, isPrecise: true,
                    isDirectionInvertedFromDevice: inverted
                ), dockedCorner: corner), .requestHide)
            }
        }
    }

    @MainActor
    func testBlockedPanelGestureKeepsItsContentOwnershipUntilNextBegin() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var eligible = false
        panel.canBeginTrackpadSwipe = { _ in eligible }
        var hides = 0
        panel.onTrackpadDismissRequest = { hides += 1 }
        panel.sendEvent(try panelScrollEvent(deltaX: -20, deltaY: 0, phase: .began))
        eligible = true
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .changed))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 0)
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 1)
    }

    @MainActor
    func testPanelSwipeCannotFinishAfterLosingKeyWindow() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var hides = 0
        panel.onTrackpadDismissRequest = { hides += 1 }
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.resignKey()
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 0)
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 1)
    }

    @MainActor
    func testInteractionLockStartingDuringSwipeCancelsDismissal() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var eligible = true
        panel.canBeginTrackpadSwipe = { _ in eligible }
        var hides = 0
        panel.onTrackpadDismissRequest = { hides += 1 }
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        eligible = false
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 0)
    }

    @MainActor
    func testReregisteredNotesTargetRequiresFreshSwipe() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let target = SwipeNotesTarget(frame: CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
        panel.contentView = SwipeHitTargetView(target: target)
        panel.notesSwipeTarget = target
        panel.sendEvent(try panelScrollEvent(deltaX: 60, deltaY: 0, phase: .began))
        panel.notesSwipeTarget = nil
        panel.notesSwipeTarget = target
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(target.navigationCount, 0)
        panel.sendEvent(try panelScrollEvent(deltaX: 60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(target.navigationCount, 1)
    }

    @MainActor
    func testPanelNeverClaimsCanvasPanBeforeCanvasReceivesItsEvents() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let target = CanvasNSView()
        let root = SwipeHitTargetView(target: target)
        panel.contentView = root
        var hides = 0
        panel.onTrackpadDismissRequest = { hides += 1 }
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 0)
    }

    @MainActor
    func testNotesNavigationAndPanelHidingHaveOneDirectionOwner() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let target = SwipeNotesTarget(frame: CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
        panel.contentView = SwipeHitTargetView(target: target)
        panel.notesSwipeTarget = target
        var hides = 0
        panel.onTrackpadDismissRequest = { hides += 1 }

        panel.sendEvent(try panelScrollEvent(deltaX: 60, deltaY: 0, phase: .began))
        XCTAssertEqual(target.navigationCount, 0, "Navigation waits until fingers lift")
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(target.navigationCount, 1)
        XCTAssertEqual(hides, 0)

        target.isNotesLibraryPresented = true
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(target.navigationCount, 2, "Library returns to draft before edgeward hiding")
        XCTAssertEqual(hides, 0)

        target.isNotesLibraryPresented = false
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 1)
    }

    @MainActor
    func testNotesGestureCannotNavigateReplacementWorkspace() throws {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let original = SwipeNotesTarget(frame: CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
        panel.contentView = SwipeHitTargetView(target: original)
        panel.notesSwipeTarget = original
        panel.sendEvent(try panelScrollEvent(deltaX: 60, deltaY: 0, phase: .began))
        let replacement = SwipeNotesTarget(frame: original.frame)
        panel.notesSwipeTarget = replacement
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(original.navigationCount, 0)
        XCTAssertEqual(replacement.navigationCount, 0)
    }
    func testCanvasControlsReserveMeasuredErrorBannerFootprint() {
        XCTAssertEqual(
            PanelGeometry.canvasErrorBannerOffset(measuredHeight: 0),
            0
        )
        XCTAssertEqual(
            PanelGeometry.canvasErrorBannerOffset(measuredHeight: -20),
            0
        )
        XCTAssertEqual(
            PanelGeometry.canvasErrorBannerOffset(measuredHeight: .infinity),
            0
        )

        let measuredBannerHeight: CGFloat = 46
        let offset = PanelGeometry.canvasErrorBannerOffset(
            measuredHeight: measuredBannerHeight
        )
        XCTAssertEqual(offset, 50)
        XCTAssertGreaterThanOrEqual(10 + offset, measuredBannerHeight + 4)
        XCTAssertEqual(60 + offset, 110)
    }

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

    func testPreciseTrackpadSwipeTowardDockedSideRequestsHideForEveryCorner() {
        let cases: [(ScreenCorner, CGFloat)] = [
            (.topLeft, 1),
            (.bottomLeft, 1),
            (.topRight, -1),
            (.bottomRight, -1)
        ]

        for (corner, direction) in cases {
            var tracker = PanelTrackpadDismissTracker()

            XCTAssertEqual(
                tracker.update(
                    sample: PanelTrackpadSwipeSample(
                        deltaX: 18 * direction,
                        deltaY: 2,
                        phase: .began,
                        isPrecise: true,
                        isDirectionInvertedFromDevice: false
                    ),
                    dockedCorner: corner
                ),
                .tracking
            )
            XCTAssertEqual(
                tracker.update(
                    sample: PanelTrackpadSwipeSample(
                        deltaX: 34 * direction,
                        deltaY: 1,
                        phase: .changed,
                        isPrecise: true,
                        isDirectionInvertedFromDevice: false
                    ),
                    dockedCorner: corner
                ),
                .tracking
            )
            XCTAssertEqual(
                tracker.update(
                    sample: PanelTrackpadSwipeSample(
                        deltaX: 0,
                        deltaY: 0,
                        phase: .ended,
                        isPrecise: true,
                        isDirectionInvertedFromDevice: false
                    ),
                    dockedCorner: corner
                ),
                .requestHide
            )
        }
    }

    func testTrackpadDismissDoesNotClaimGestureThatStartedAwayFromDockedSide() {
        var tracker = PanelTrackpadDismissTracker()

        XCTAssertEqual(
            tracker.update(
                sample: PanelTrackpadSwipeSample(
                    deltaX: 20,
                    deltaY: 1,
                    phase: .began,
                    isPrecise: true,
                    isDirectionInvertedFromDevice: false
                ),
                dockedCorner: .topRight
            ),
            .passThrough
        )
        XCTAssertEqual(
            tracker.update(
                sample: PanelTrackpadSwipeSample(
                    deltaX: -80,
                    deltaY: 0,
                    phase: .changed,
                    isPrecise: true,
                    isDirectionInvertedFromDevice: false
                ),
                dockedCorner: .topRight
            ),
            .passThrough
        )
        XCTAssertEqual(
            tracker.update(
                sample: PanelTrackpadSwipeSample(
                    deltaX: 0,
                    deltaY: 0,
                    phase: .ended,
                    isPrecise: true,
                    isDirectionInvertedFromDevice: false
                ),
                dockedCorner: .topRight
            ),
            .passThrough
        )
    }

    func testTrackpadDirectionNormalizationReservesPhysicalDockSide() {
        XCTAssertTrue(
            PanelTrackpadDismissTracker.isTowardDockedSide(
                deltaX: 12,
                deltaY: -1,
                isDirectionInvertedFromDevice: true,
                dockedCorner: .topRight
            )
        )
        XCTAssertFalse(
            PanelTrackpadDismissTracker.isTowardDockedSide(
                deltaX: -12,
                deltaY: 1,
                isDirectionInvertedFromDevice: true,
                dockedCorner: .topRight
            )
        )
        XCTAssertTrue(
            PanelTrackpadDismissTracker.isTowardDockedSide(
                deltaX: 12,
                deltaY: 1,
                isDirectionInvertedFromDevice: false,
                dockedCorner: .bottomLeft
            )
        )
    }

    @MainActor
    func testPanelRoutesPreciseTrackpadSwipeToInteractiveHideCallback() throws {
        let panel = AtticPanel(
            contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.trackpadDismissCorner = .topRight
        var hideRequestCount = 0
        panel.onTrackpadDismissRequest = {
            hideRequestCount += 1
        }

        panel.sendEvent(try panelScrollEvent(deltaX: -18, deltaY: 2, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: -34, deltaY: 1, phase: .changed))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))

        XCTAssertEqual(hideRequestCount, 1)
    }

    @MainActor
    func testModifiedScrollCancelsPendingPanelDismissGesture() throws {
        let panel = AtticPanel(
            contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.trackpadDismissCorner = .topRight
        var hideRequestCount = 0
        panel.onTrackpadDismissRequest = {
            hideRequestCount += 1
        }

        panel.sendEvent(try panelScrollEvent(deltaX: -52, deltaY: 1, phase: .began))
        panel.sendEvent(try panelScrollEvent(
            deltaX: 4,
            deltaY: 0,
            phase: .changed,
            modifiers: .maskCommand
        ))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))

        XCTAssertEqual(hideRequestCount, 0)
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

    func testDragIntentRetainsFastThrowAcrossEdgeStallAndReleasePause() {
        var intent = PanelDragIntentTracker(
            location: CGPoint(x: 800, y: 500),
            timestamp: 10
        )
        intent.record(
            location: CGPoint(x: 860, y: 560),
            timestamp: 10.05
        )
        intent.record(
            location: CGPoint(x: 900, y: 600),
            timestamp: 10.09
        )
        // Window/screen clamping can leave several physical pointer events at
        // the same coordinate before mouse-up. Those stationary tail samples
        // must not erase the deliberate throw.
        intent.record(
            location: CGPoint(x: 900, y: 600),
            timestamp: 10.20
        )

        let release = intent.release(
            location: CGPoint(x: 900, y: 600),
            timestamp: 10.34
        )

        XCTAssertEqual(release.translation, CGPoint(x: 100, y: 100))
        XCTAssertGreaterThan(hypot(release.velocity.x, release.velocity.y), 650)
        XCTAssertGreaterThan(release.velocity.x, 0)
        XCTAssertGreaterThan(release.velocity.y, 0)
    }

    func testDragIntentUsesCumulativeDirectionInsteadOfOpposingFinalSample() {
        var intent = PanelDragIntentTracker(
            location: CGPoint(x: 600, y: 600),
            timestamp: 20
        )
        intent.record(
            location: CGPoint(x: 510, y: 690),
            timestamp: 20.08
        )
        // A tiny corrective sample immediately before release must not flip
        // the corner classification back to the final-sample direction.
        intent.record(
            location: CGPoint(x: 514, y: 686),
            timestamp: 20.09
        )

        let release = intent.release(
            location: CGPoint(x: 514, y: 686),
            timestamp: 20.12
        )

        XCTAssertEqual(release.translation, CGPoint(x: -86, y: 86))
        XCTAssertLessThan(release.velocity.x, 0)
        XCTAssertGreaterThan(release.velocity.y, 0)
        XCTAssertEqual(
            PanelDockingPolicy.flickCorner(
                velocity: release.velocity,
                translation: release.translation,
                panelFrame: CGRect(x: 500, y: 300, width: 332, height: 480),
                in: CGRect(x: 0, y: 25, width: 1_600, height: 900)
            ),
            .topLeft
        )
    }

    func testDragIntentExpiresAfterAnAbandonedGestureTail() {
        var intent = PanelDragIntentTracker(
            location: CGPoint(x: 100, y: 100),
            timestamp: 30
        )
        intent.record(
            location: CGPoint(x: 180, y: 180),
            timestamp: 30.06
        )

        let release = intent.release(
            location: CGPoint(x: 180, y: 180),
            timestamp: 31
        )

        XCTAssertEqual(release.translation, CGPoint(x: 80, y: 80))
        XCTAssertEqual(release.velocity, .zero)
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

    func testWorkAreaEventsAlsoCancelInteractionsWhenApplicationDeactivates() {
        let center = NotificationCenter()
        var received: [PanelWorkAreaEvent] = []
        let observation = PanelWorkAreaEvents.publisher(center: center)
            .sink { received.append($0) }

        center.post(name: NSApplication.didResignActiveNotification, object: nil)

        XCTAssertEqual(received, [.applicationDeactivated])
        withExtendedLifetime(observation) {}
    }

    func testInteractionLifecycleCancelsEveryInterruptionExactlyOnce() {
        for reason in PanelInteractionCancellationReason.allCases {
            var lifecycle = PanelInteractionLifecycle()
            lifecycle.begin(.windowMove)

            XCTAssertEqual(
                lifecycle.cancel(reason: reason),
                PanelInteractionCancellation(
                    interaction: .windowMove,
                    reason: reason
                )
            )
            XCTAssertNil(lifecycle.cancel(reason: reason))
            XCTAssertNil(lifecycle.activeInteraction)
        }
    }

    func testNormalMouseUpFinishesOnlyItsOwnedInteraction() {
        var lifecycle = PanelInteractionLifecycle()
        lifecycle.begin(.windowResize)

        XCTAssertFalse(lifecycle.finish(.windowMove))
        XCTAssertEqual(lifecycle.activeInteraction, .windowResize)
        XCTAssertTrue(lifecycle.finish(.windowResize))
        XCTAssertNil(lifecycle.activeInteraction)
        XCTAssertNil(lifecycle.cancel(reason: .interruptedEventDelivery))
    }

    func testInteractionCaptureWatchdogRecoversOnlyAfterLeftButtonIsReleased() {
        XCTAssertLessThanOrEqual(
            PanelInteractionCaptureWatchdogPolicy.intervalMilliseconds,
            250
        )
        XCTAssertFalse(PanelInteractionCaptureWatchdogPolicy.shouldRecover(
            hasActiveInteraction: false,
            pressedMouseButtons: 0
        ))
        XCTAssertFalse(PanelInteractionCaptureWatchdogPolicy.shouldRecover(
            hasActiveInteraction: true,
            pressedMouseButtons: 1
        ))
        XCTAssertTrue(PanelInteractionCaptureWatchdogPolicy.shouldRecover(
            hasActiveInteraction: true,
            pressedMouseButtons: 0
        ))
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
        let expanded = TaskScrollMaskLayout.stops(panelHeight: 480, bottomObscuredHeight: 122)
        XCTAssertLessThan(expanded.bottomFadeStart, compact.bottomFadeStart)
        XCTAssertEqual((1 - expanded.bottomFadeStart) * 480, 122, accuracy: 0.001)
        XCTAssertEqual(
            TaskScrollMaskLayout.stops(panelHeight: 480, bottomObscuredHeight: CGFloat.infinity).bottomFadeStart,
            compact.bottomFadeStart
        )
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

    @MainActor
    private func withHiddenHostedPanel(
        _ body: (AtticPanel, AtticPanelHostingView) throws -> Void
    ) throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = PanelGeometry.workAreaPlacement(
            preferredSize: CGSize(width: 480, height: 620),
            in: screen.visibleFrame, corner: .topRight
        ).frame
        guard visible.height >= PanelGeometry.minimumPanelSize.height + 40 else {
            throw XCTSkip("The hosted resize regression needs 40 points above the minimum height")
        }
        let suite = "AtticPanelPointerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        state.updatePanelSize(visible.size)
        let chrome = PanelChromeInteractionState()
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store, noteStore: notes,
                canvasSession: CanvasSession(store: CanvasStore(container: container)),
                noteDraft: NoteDraftController(noteStore: notes),
                chromeInteractionState: chrome, uiState: state,
                settings: AppSettings(defaults: defaults),
                subtaskPanels: SubtaskPanelController(
                    store: store,
                    uiState: state,
                    settings: AppSettings(defaults: defaults)
                )
            ),
            panelCornerRadius: 80, dockedCorner: .topRight, chromeInteractionState: chrome
        )
        let panel = AtticPanel(contentRect: visible, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        panel.resizePerimeter = AtticPanelResizePolicy.outsideGripThickness
        panel.setVisibleContentFrame(visible, display: false)
        panel.contentView = AtticPanelContentContainer(
            hostingView: host, visibleSize: visible.size, perimeter: panel.resizePerimeter
        )
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            panel.contentView = nil
        }
        // Direct delivery exercises the real hosting responder without
        // posting HID events or changing the user's physical mouse position.
        try body(panel, host)
    }

    @MainActor
    private func panelMouseEvent(
        _ type: NSEvent.EventType, at screenPoint: CGPoint,
        in panel: AtticPanel, timestamp: TimeInterval
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: panel.convertPoint(fromScreen: screenPoint),
            modifierFlags: [], timestamp: timestamp, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func panelScrollEvent(
        deltaX: Int32,
        deltaY: Int32,
        phase: NSEvent.Phase,
        modifiers: CGEventFlags = []
    ) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ))
        event.flags = modifiers
        event.location = CGPoint(x: 120, y: 160)
        let cgPhase: Int64
        if phase == .began {
            cgPhase = 1
        } else if phase == .changed || phase == .stationary {
            cgPhase = 2
        } else if phase == .ended {
            cgPhase = 4
        } else if phase == .cancelled {
            cgPhase = 8
        } else {
            cgPhase = 0
        }
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: cgPhase
        )
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}

@MainActor
private final class SwipeHitTargetView: NSView {
    let target: NSView
    init(target: NSView) {
        self.target = target
        super.init(frame: .zero)
        addSubview(target)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { target }
}

@MainActor
private final class SwipeNotesTarget: NSView, PanelNotesSwipeTarget {
    var swipeView: NSView { self }
    var isNotesLibraryPresented = false
    var navigationCount = 0
    func performNotesSwipe() { navigationCount += 1 }
}
