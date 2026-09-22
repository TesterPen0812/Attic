import AppKit
import Combine
import QuartzCore
import SwiftUI
import XCTest
@testable import Attic

final class PanelGeometryTests: XCTestCase {
    func testCollapseKeepsEveryAttachedCornerFixedInsideTheOriginalSurface() {
        let native = CGRect(x: 0, y: 0, width: 492, height: 632)
        let visible = native.insetBy(dx: 6, dy: 6)
        let center = CGPoint(x: native.midX, y: native.midY)
        for corner in ScreenCorner.allCases {
            let anchor = CGPoint(
                x: [.topRight, .bottomRight].contains(corner) ? visible.maxX : visible.minX,
                y: [.topLeft, .topRight].contains(corner) ? visible.maxY : visible.minY
            )
            for progress in [CGFloat(0), 0.25, 0.65, 1] {
                let transform = PanelCollapseGeometry.transform(
                    progress: progress, visibleBounds: visible, layerBounds: native, corner: corner
                )
                func presented(_ point: CGPoint) -> CGPoint {
                    let relative = CGPoint(x: point.x - center.x, y: point.y - center.y).applying(transform)
                    return CGPoint(x: relative.x + center.x, y: relative.y + center.y)
                }
                XCTAssertEqual(presented(anchor).x, anchor.x, accuracy: 0.001)
                XCTAssertEqual(presented(anchor).y, anchor.y, accuracy: 0.001)
                for point in [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.maxY)] {
                    let result = presented(point)
                    XCTAssertGreaterThanOrEqual(result.x, visible.minX - 0.001)
                    XCTAssertLessThanOrEqual(result.x, visible.maxX + 0.001)
                    XCTAssertGreaterThanOrEqual(result.y, visible.minY - 0.001)
                    XCTAssertLessThanOrEqual(result.y, visible.maxY + 0.001)
                }
            }
        }
        XCTAssertTrue(PanelCollapseGeometry.transform(
            progress: 1, visibleBounds: visible, layerBounds: native,
            corner: .topRight, reduceMotion: true
        ).isIdentity)
    }

    func testInteractiveCollapseProgressIsBoundedAndReversible() {
        let forward = PanelCollapseGeometry.progress(forSwipeDistance: 60, panelWidth: 332)
        let reverse = PanelCollapseGeometry.progress(forSwipeDistance: 20, panelWidth: 332)
        XCTAssertGreaterThan(forward, reverse)
        XCTAssertGreaterThan(reverse, 0)
        XCTAssertEqual(PanelCollapseGeometry.progress(forSwipeDistance: -10, panelWidth: 332), 0)
        XCTAssertEqual(PanelCollapseGeometry.progress(forSwipeDistance: 10_000, panelWidth: 332), 0.95)
        XCTAssertEqual(PanelCollapseGeometry.progress(forSwipeDistance: .infinity, panelWidth: 332), 0)
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
    func testHostedCollapseNeverChangesNativeOrSwiftUILayoutBounds() throws {
        try withHiddenHostedPanel { panel, host in
            let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
            let nativeFrame = panel.frame
            let hostingFrame = host.frame
            let hostingBounds = host.bounds
            container.setCollapseProgress(0.6, corner: .bottomLeft, reduceMotion: false)
            XCTAssertLessThan(container.presentationTransform.m11, 1)
            XCTAssertEqual(panel.frame, nativeFrame)
            XCTAssertEqual(host.frame, hostingFrame)
            XCTAssertEqual(host.bounds, hostingBounds)
            container.stopCollapseMotion()
            container.setCollapseProgress(0, corner: .bottomLeft, reduceMotion: true)
            XCTAssertTrue(CATransform3DIsIdentity(container.presentationTransform))
            XCTAssertEqual(host.bounds, hostingBounds)
        }
    }

    @MainActor
    func testSwipeReleasePreservesLatestFingerPositionBeforeNextDisplayFrame() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_MOTION_VISUAL_TEST"] == "1" else {
            throw XCTSkip("Requires the exclusive desktop visual-test run")
        }
        try withHiddenHostedPanel { panel, _ in
            let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            panel.onTrackpadDismissProgress = { distance in
                container.setCollapseProgress(
                    PanelCollapseGeometry.progress(forSwipeDistance: distance, panelWidth: panel.visibleContentFrame.width),
                    corner: .topRight, reduceMotion: false
                )
            }
            var releaseScale: CGFloat?
            panel.onTrackpadDismissRequest = {
                container.stopCollapseMotion()
                releaseScale = container.presentationTransform.m11
                container.setCollapseProgress(1, corner: .topRight, reduceMotion: false, duration: 0.22)
            }
            panel.sendEvent(try panelScrollEvent(deltaX: -20, deltaY: 0, phase: .began))
            panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .changed))
            // AppKit can deliver the last changed sample and finger lift in
            // one run-loop turn, before Core Animation refreshes presentation.
            panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
            let progress = PanelCollapseGeometry.progress(forSwipeDistance: 80, panelWidth: panel.visibleContentFrame.width)
            let expected = 1 - progress * (1 - PanelCollapseGeometry.collapsedScale)
            XCTAssertEqual(try XCTUnwrap(releaseScale), expected, accuracy: 0.0001,
                           "Finger lift must not restore the previous display frame")
        }
    }

    @MainActor
    func testNativeSwipeCompletionCancellationAndResourceProfile() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_MOTION_VISUAL_TEST"] == "1" else {
            throw XCTSkip("Requires the exclusive desktop visual-test run")
        }
        let suite = "AtticOriginalMotionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore())
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: NoteDraftController(noteStore: notes), settings: AppSettings(defaults: defaults), uiState: PanelUIState()
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let content = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
        let screen = try XCTUnwrap(controller.currentScreen)
        defer { panel.orderOut(nil) }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.35)) }
        func residentMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
        }
        controller.show(on: screen, corner: .topRight)
        settle()
        panel.onTrackpadDismissProgress?(70)
        panel.onTrackpadDismissCancelled?()
        settle()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(CATransform3DIsIdentity(content.presentationTransform))
        XCTAssertTrue(content.allowsContentInteraction)
        let nativeFrame = panel.frame
        let hostBounds = content.hostingView.bounds
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOriginalMotionFrames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for distance in [0, 45, 90, 150] {
            panel.onTrackpadDismissProgress?(CGFloat(distance))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("swipe-\(distance).png"))
            XCTAssertEqual(panel.frame, nativeFrame)
            XCTAssertEqual(content.hostingView.bounds, hostBounds)
        }
        panel.onTrackpadDismissCancelled?()
        settle()
        let cpuStart = clock()
        let wallStart = ProcessInfo.processInfo.systemUptime
        let before = residentMB()
        var residentSamples: [Double] = []
        for _ in 0..<12 {
            controller.show(on: screen, corner: .topRight)
            settle()
            panel.onTrackpadDismissProgress?(80)
            panel.onTrackpadDismissRequest?()
            var priorScale = content.presentationTransform.m11
            let deadline = Date().addingTimeInterval(0.6)
            while panel.isVisible, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.008))
                let scale = content.presentationTransform.m11
                XCTAssertLessThanOrEqual(scale, priorScale + 0.001, "Committed dismissal must not jump back toward full size")
                priorScale = scale
            }
            XCTAssertFalse(panel.isVisible, "The native hide completion must order out the panel")
            residentSamples.append(residentMB())
        }
        let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        let idleStart = clock()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let idleCPU = Double(clock() - idleStart) / Double(CLOCKS_PER_SEC)
        let report: [String: Any] = ["cycles": 12, "wall_seconds": wall,
            "process_cpu_seconds": cpu, "average_one_core_percent": cpu / wall * 100,
            "idle_process_cpu_seconds_over_one_second": idleCPU,
            "resident_mb_before": before, "resident_mb_after": residentMB(),
            "resident_mb_after_each_cycle": residentSamples]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("resource-profile.json"))
        withExtendedLifetime(controller) {}
    }

    @MainActor
    func testSettingsSizeAndCornerResetCollapsedPresentationBeforeReanchoring() throws {
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
            container.setCollapseProgress(0.65, corner: controller.currentCorner, reduceMotion: false)
            settings.corner = corner
            XCTAssertTrue(CATransform3DIsIdentity(container.presentationTransform))
            XCTAssertEqual(controller.currentCorner, corner)
            container.setCollapseProgress(0.65, corner: corner, reduceMotion: false)
            settings.persistPanelSize(CGSize(
                width: settings.panelContentSize == 480 ? 420 : 480,
                height: settings.panelHeight == 620 ? 600 : 620
            ))
            XCTAssertTrue(CATransform3DIsIdentity(container.presentationTransform))
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
    func testHideWaitsForPresentationAndStaleHideCannotCompleteAfterReveal() {
        var transitions = PanelVisibilityTransitionState()
        var hidden = 0
        var superseded = 0
        let hide = transitions.beginHideTransition { result in
            if result == .hidden { hidden += 1 } else { superseded += 1 }
        }
        let completion = PanelMotionCompletionBarrier { _ = transitions.completeHideTransition(hide) }
        completion.finishFrame()
        XCTAssertEqual(hidden, 0, "An unchanged native frame must not order out the collapsing surface early")
        transitions.invalidatePendingTransition()
        completion.finishPresentation()
        completion.finishPresentation()
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(superseded, 1)
    }

    @MainActor
    func testMotionCompletionBarrierFinishesExactlyOnceInEitherOrder() {
        for frameFirst in [false, true] {
            var count = 0
            let completion = PanelMotionCompletionBarrier { count += 1 }
            if frameFirst { completion.finishFrame() } else { completion.finishPresentation() }
            XCTAssertEqual(count, 0)
            completion.finishFrame()
            completion.finishPresentation()
            completion.finishFrame()
            XCTAssertEqual(count, 1)
        }
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
        let panel = makeSwipePanel()
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
    func testHeldPointerButtonOwnsTheGestureUntilItIsReleased() throws {
        var pressedButtons = 1
        let panel = makeSwipePanel()
        panel.pressedMouseButtonsQuery = { pressedButtons }
        var hides = 0
        panel.onTrackpadDismissRequest = { hides += 1 }
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 0, "A button held at the first sample keeps the gesture out of the panel")
        pressedButtons = 0
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        pressedButtons = 1
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 0, "A button pressed after the first sample invalidates the sequence")
        pressedButtons = 0
        panel.sendEvent(try panelScrollEvent(deltaX: -60, deltaY: 0, phase: .began))
        panel.sendEvent(try panelScrollEvent(deltaX: 0, deltaY: 0, phase: .ended))
        XCTAssertEqual(hides, 1)
    }

    @MainActor
    func testPanelSwipeCannotFinishAfterLosingKeyWindow() throws {
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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

    func testHeaderFlickTowardAttachedCornerDocksForEveryCorner() {
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
                .dock(corner)
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
        let panel = makeSwipePanel()
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
        let panel = makeSwipePanel()
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
        XCTAssertEqual(PanelGeometry.minimumPanelSize, CGSize(width: 320, height: 460))
        XCTAssertEqual(PanelGeometry.defaultPanelSize.width, 320)
        XCTAssertEqual(PanelGeometry.defaultPanelSize.height, 464, accuracy: 0.001)

        XCTAssertEqual(
            PanelGeometry.clampedPanelSize(CGSize(width: 250, height: 620)),
            CGSize(width: 320, height: 620)
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
        // Content is subdued for exactly the chrome band and fully visible
        // one fade past it, at every panel height.
        let compact = TaskScrollMaskLayout.stops(height: 480, topObscuredHeight: 70, bottomObscuredHeight: 76)
        let tall = TaskScrollMaskLayout.stops(height: 900, topObscuredHeight: 70, bottomObscuredHeight: 76)
        for (stops, height) in [(compact, CGFloat(480)), (tall, CGFloat(900))] {
            XCTAssertEqual(stops.topClearEnd * height, 70, accuracy: 0.001)
            XCTAssertEqual(stops.topFadeEnd * height, 70 + TaskScrollMaskLayout.fadeLength, accuracy: 0.001)
            XCTAssertEqual((1 - stops.bottomClearStart) * height, 76, accuracy: 0.001)
            XCTAssertEqual((1 - stops.bottomFadeStart) * height, 76 + TaskScrollMaskLayout.fadeLength, accuracy: 0.001)
        }
        // A taller composer pushes the bottom band up by exactly its growth.
        let expanded = TaskScrollMaskLayout.stops(height: 480, topObscuredHeight: 70, bottomObscuredHeight: 122)
        XCTAssertEqual((1 - expanded.bottomClearStart) * 480, 122, accuracy: 0.001)
        XCTAssertLessThan(expanded.bottomFadeStart, compact.bottomFadeStart)
        // Degenerate inputs never invert the gradient.
        let squeezed = TaskScrollMaskLayout.stops(height: 120, topObscuredHeight: 70, bottomObscuredHeight: 76)
        XCTAssertLessThanOrEqual(squeezed.topClearEnd, squeezed.topFadeEnd)
        XCTAssertLessThanOrEqual(squeezed.topFadeEnd, squeezed.bottomFadeStart)
        XCTAssertLessThanOrEqual(squeezed.bottomFadeStart, squeezed.bottomClearStart)
        XCTAssertLessThanOrEqual(squeezed.bottomClearStart, 1)
        let infinite = TaskScrollMaskLayout.stops(height: 480, topObscuredHeight: .infinity, bottomObscuredHeight: .nan)
        XCTAssertEqual(infinite.topClearEnd, 0)
        XCTAssertEqual(infinite.bottomClearStart, 1)
        let gradient = TaskScrollMaskLayout.gradientStops(compact)
        XCTAssertEqual(gradient.map(\.location), gradient.map(\.location).sorted(), "stops are monotone")
    }

    /// The saved-notes drawer overlaid its buttons on an unmasked list: the
    /// bottom "Return to writing" button sat permanently on top of the lowest
    /// row's preview text and the last row hard-clipped at the squircle edge.
    /// The bands must clear each button's whole footprint and fade the way the
    /// task list beside it does.
    func testSavedNotesDrawerBandsClearItsButtonsAndFadeLikeTheTaskList() {
        XCTAssertGreaterThan(
            SavedNotesDrawerLayout.chromeBandHeight,
            SavedNotesDrawerLayout.buttonFootprint,
            "a row must never come to rest under a drawer button"
        )
        // The empty state is placed past the fade, so the mask that exists for
        // scrolling rows cannot render "No saved notes yet" half-faded.
        XCTAssertGreaterThanOrEqual(
            SavedNotesDrawerLayout.emptyStateTopInset,
            SavedNotesDrawerLayout.chromeBandHeight + SavedNotesDrawerLayout.fadeLength
        )

        for height in [CGFloat(280), 480, 900] {
            let stops = SavedNotesDrawerLayout.stops(height: height)
            XCTAssertEqual(stops.topClearEnd * height,
                           SavedNotesDrawerLayout.chromeBandHeight, accuracy: 0.001)
            XCTAssertEqual(stops.topFadeEnd * height,
                           SavedNotesDrawerLayout.chromeBandHeight + SavedNotesDrawerLayout.fadeLength,
                           accuracy: 0.001)
            XCTAssertEqual((1 - stops.bottomClearStart) * height,
                           SavedNotesDrawerLayout.chromeBandHeight, accuracy: 0.001)
            XCTAssertEqual((1 - stops.bottomFadeStart) * height,
                           SavedNotesDrawerLayout.chromeBandHeight + SavedNotesDrawerLayout.fadeLength,
                           accuracy: 0.001)
            let gradient = TaskScrollMaskLayout.gradientStops(stops)
            XCTAssertEqual(gradient.map(\.location), gradient.map(\.location).sorted(),
                           "stops are monotone at height \(height)")
            // What the rendered mask does, not just where its stops sit: a row
            // resting at its inset is fully painted, while anything under a
            // button's footprint is subdued. (The previous assertion here
            // restated `topClearEnd == chromeBandHeight / height`, which the
            // lines above already pin, so it held for every possible value.)
            XCTAssertEqual(
                maskOpacity(gradient, at: SavedNotesDrawerLayout.rowRestingInset / height),
                1, accuracy: 0.001,
                "a resting row must be fully readable at height \(height)"
            )
            XCTAssertEqual(
                maskOpacity(gradient, at: 1 - SavedNotesDrawerLayout.rowRestingInset / height),
                1, accuracy: 0.001,
                "and so must the lowest one at height \(height)"
            )
            for depth in [CGFloat(2), SavedNotesDrawerLayout.buttonEdgePadding,
                          SavedNotesDrawerLayout.buttonFootprint] {
                XCTAssertLessThan(
                    maskOpacity(gradient, at: depth / height), 1,
                    "content \(depth)pt under a button must stay subdued at height \(height)"
                )
                XCTAssertLessThan(
                    maskOpacity(gradient, at: 1 - depth / height), 1,
                    "and so must content \(depth)pt above the bottom one"
                )
            }
        }

        // The pointer shields cover exactly what the mask dims, the rule the
        // task list uses, and a row comes to rest clear of them: a fully
        // opaque row with an inert top edge would be worse than either.
        XCTAssertEqual(SavedNotesDrawerLayout.shieldHeight,
                       SavedNotesDrawerLayout.chromeBandHeight + SavedNotesDrawerLayout.fadeLength)
        XCTAssertGreaterThan(SavedNotesDrawerLayout.shieldHeight,
                             SavedNotesDrawerLayout.buttonFootprint,
                             "a shield must cover the whole button it protects")
        XCTAssertGreaterThanOrEqual(SavedNotesDrawerLayout.rowRestingInset,
                                    SavedNotesDrawerLayout.shieldHeight)

        // Accessibility contrast settings remove the underlay here too.
        XCTAssertEqual(TaskScrollMaskLayout.underChromeOpacity(reduceTransparency: true, increasedContrast: false), 0)
    }

    /// The panel's primary action had no hover or keyboard-focus affordance on
    /// any treatment: the emphasis colors existed but nothing consumed them.
    /// Emphasis appears for either signal, stays away at rest, and never
    /// advertises a submit that cannot run.
    func testQuickSubmitEmphasisFollowsHoverFocusAndAvailability() {
        XCTAssertFalse(QuickSubmitEmphasis.isEmphasized(canSubmit: true, isHovered: false, isFocused: false))
        XCTAssertTrue(QuickSubmitEmphasis.isEmphasized(canSubmit: true, isHovered: true, isFocused: false))
        XCTAssertTrue(QuickSubmitEmphasis.isEmphasized(canSubmit: true, isHovered: false, isFocused: true))
        XCTAssertTrue(QuickSubmitEmphasis.isEmphasized(canSubmit: true, isHovered: true, isFocused: true))
        for hovered in [true, false] {
            for focused in [true, false] {
                XCTAssertFalse(
                    QuickSubmitEmphasis.isEmphasized(canSubmit: false, isHovered: hovered, isFocused: focused),
                    "a disabled submit stays quiet (hover: \(hovered), focus: \(focused))"
                )
            }
        }
        XCTAssertGreaterThan(
            QuickSubmitEmphasis.strokeWidth(isFocused: true),
            QuickSubmitEmphasis.strokeWidth(isFocused: false),
            "keyboard focus reads stronger than hover"
        )
    }

    /// Backlog and Tasks share one quick-entry composer. Creation already
    /// routed to `.backlog`, but every piece of its copy — placeholder, submit
    /// title, pending-import help, the options menu label and its two command
    /// titles — still called a backlog entry a task.
    func testQuickEntryCopyFollowsTheSelectedScope() {
        XCTAssertEqual(TaskScope.tasks.quickEntryPlaceholder, "Add a task…")
        XCTAssertEqual(TaskScope.tasks.quickEntrySubmitTitle, "Add task")
        XCTAssertEqual(TaskScope.tasks.quickEntryOptionsCommandTitle, "Task options")
        XCTAssertEqual(TaskScope.tasks.quickEntryCloseOptionsCommandTitle, "Close task options")

        XCTAssertEqual(TaskScope.tasks.quickEntryContainerLabel, "Quick task entry")

        let backlogCopy = [
            TaskScope.backlog.quickEntryPlaceholder,
            TaskScope.backlog.quickEntrySubmitTitle,
            TaskScope.backlog.quickEntryPendingSubmitTitle,
            TaskScope.backlog.quickEntryOptionsTitle,
            TaskScope.backlog.quickEntryOptionsCommandTitle,
            TaskScope.backlog.quickEntryCloseOptionsCommandTitle,
            // VoiceOver reads the composer's container before anything inside
            // it, and this one label was still hard-coded to "Quick task entry".
            TaskScope.backlog.quickEntryContainerLabel
        ]
        for copy in backlogCopy {
            XCTAssertFalse(copy.lowercased().contains("task"),
                           "Backlog quick entry must not call an idea a task: \(copy)")
            XCTAssertFalse(copy.isEmpty)
        }
        XCTAssertTrue(TaskScope.backlog.quickEntryPendingSubmitTitle.contains("attachments finish copying"),
                      "the pending-import help still has to explain the wait")
        XCTAssertEqual(TaskScope.backlog.creationStatus, .backlog,
                       "copy follows the scope; routing is unchanged")

        // Every scope answers with distinct, non-empty copy.
        for scope in TaskScope.allCases {
            XCTAssertFalse(scope.quickEntryPlaceholder.isEmpty)
            XCTAssertFalse(scope.quickEntryContainerLabel.isEmpty)
            XCTAssertNotEqual(scope.quickEntryOptionsCommandTitle, scope.quickEntryCloseOptionsCommandTitle)
        }
        XCTAssertNotEqual(TaskScope.tasks.quickEntryContainerLabel,
                          TaskScope.backlog.quickEntryContainerLabel)
        XCTAssertNotEqual(TaskScope.tasks.quickEntrySubmitTitle, TaskScope.backlog.quickEntrySubmitTitle)
    }

    /// The alpha the rendered mask applies at `location`, interpolated between
    /// the surrounding stops exactly as a `LinearGradient` does. Lets a test
    /// ask what the mask does to a given row rather than only where its stops
    /// are.
    private func maskOpacity(_ stops: [Gradient.Stop], at location: CGFloat) -> Double {
        func alpha(_ color: Color) -> Double {
            Double(NSColor(color).usingColorSpace(.deviceRGB)?.alphaComponent ?? 0)
        }
        guard let first = stops.first, let last = stops.last else { return 0 }
        if location <= first.location { return alpha(first.color) }
        if location >= last.location { return alpha(last.color) }
        for (lower, upper) in zip(stops, stops.dropFirst()) {
            guard location >= lower.location, location <= upper.location else { continue }
            let span = upper.location - lower.location
            guard span > 0 else { return alpha(upper.color) }
            let t = Double((location - lower.location) / span)
            return alpha(lower.color) + (alpha(upper.color) - alpha(lower.color)) * t
        }
        return alpha(last.color)
    }

    func testUnderChromeDepthRespectsContrastSettingsAndComposerTextSpace() {
        XCTAssertGreaterThan(TaskScrollMaskLayout.underChromeOpacity(reduceTransparency: false, increasedContrast: false), 0)
        XCTAssertLessThanOrEqual(TaskScrollMaskLayout.underChromeOpacity(reduceTransparency: false, increasedContrast: false), 0.2)
        XCTAssertEqual(TaskScrollMaskLayout.underChromeOpacity(reduceTransparency: true, increasedContrast: false), 0)
        XCTAssertEqual(TaskScrollMaskLayout.underChromeOpacity(reduceTransparency: false, increasedContrast: true), 0)
        let width = TaskEntryBarLayout.textFieldWidth(panelWidth: 320, chromeInsets: SwiftUI.EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22))
        XCTAssertGreaterThanOrEqual(width, 160, "The compact composer must leave space for a readable task title.")
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
        XCTAssertEqual(PanelGeometry.preferredWorkspaceHeight(contentWidth: 300), 460)
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
    func testMainPanelOwnsEveryPaintedInteriorPoint() throws {
        try withHiddenHostedPanel { _, host in
            host.layoutSubtreeIfNeeded()
            for y in stride(from: 4.0, through: host.bounds.height - 4, by: 17) {
                for x in stride(from: 4.0, through: host.bounds.width - 4, by: 17) {
                    let local = CGPoint(x: x, y: y)
                    guard Squircle.contains(local, in: host.bounds, cornerRadius: 80,
                                            exponent: AtticStyle.panelSquircleExponent) else { continue }
                    let input = host.convert(local, to: host.superview)
                    XCTAssertNotNil(host.hitTest(input), "Main panel dropped a painted point: \(local)")
                }
            }
        }
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
        panel.pressedMouseButtonsQuery = { 0 }
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

    /// Swipe delivery consults live pointer-button state, which belongs to the
    /// physical trackpad rather than the synthesized event. Pinning it keeps a
    /// stray click during the suite from silently rejecting the gesture.
    @MainActor
    private func makeSwipePanel() -> AtticPanel {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        panel.pressedMouseButtonsQuery = { 0 }
        return panel
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
