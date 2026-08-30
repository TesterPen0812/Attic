import CoreGraphics
import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
private final class DrivenMagnificationGestureRecognizer:
    NSMagnificationGestureRecognizer {
    private var drivenState: NSGestureRecognizer.State = .possible

    override var state: NSGestureRecognizer.State {
        get { drivenState }
        set { drivenState = newValue }
    }

    func drive(
        _ state: NSGestureRecognizer.State,
        magnification: CGFloat
    ) {
        self.magnification = magnification
        self.state = state
    }
}

final class CanvasDomainTests: XCTestCase {
    func testStrokeCodecRoundTripsVersionedPlatformNeutralArchive() throws {
        let points = [
            CanvasPoint(x: -12.5, y: 8.25),
            CanvasPoint(x: 40, y: 64.5)
        ]

        let data = try CanvasStrokeCodec.encode(
            color: .blue,
            width: 3.75,
            points: points
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["version"] as? Int, CanvasStrokeCodec.currentVersion)
        XCTAssertEqual(object["color"] as? String, CanvasInkColor.blue.rawValue)
        XCTAssertEqual(object["width"] as? Double, 3.75)
        let decoded = try CanvasStrokeCodec.decode(
            data,
            expectedVersion: CanvasStrokeCodec.currentVersion
        )
        XCTAssertEqual(decoded.color, .blue)
        XCTAssertEqual(decoded.width, 3.75)
        XCTAssertEqual(decoded.points, points)
    }

    func testStrokeCodecRejectsUnsupportedArchiveVersion() {
        let data = Data(
            #"{"version":99,"color":"ink","width":3,"points":[{"x":0,"y":0}]}"#
                .utf8
        )

        XCTAssertThrowsError(
            try CanvasStrokeCodec.decode(data, expectedVersion: CanvasStrokeCodec.currentVersion)
        )
    }

    func testStrokeCodecRejectsEmptyOrInvalidGeometry() {
        let empty = Data(
            #"{"version":1,"color":"ink","width":3,"points":[]}"#.utf8
        )
        let invalidWidth = Data(
            #"{"version":1,"color":"ink","width":0,"points":[{"x":0,"y":0}]}"#
                .utf8
        )

        XCTAssertThrowsError(
            try CanvasStrokeCodec.decode(empty, expectedVersion: CanvasStrokeCodec.currentVersion)
        )
        XCTAssertThrowsError(
            try CanvasStrokeCodec.decode(
                invalidWidth,
                expectedVersion: CanvasStrokeCodec.currentVersion
            )
        )
    }

    func testCodecRejectsPointCountsAboveTheInteractiveBufferLimit() {
        let points = (0...CanvasInputStateMachine.maximumBufferedPointCount).map {
            CanvasPoint(x: Double($0), y: 0)
        }

        XCTAssertThrowsError(
            try CanvasStrokeCodec.encode(
                color: .ink,
                width: 3,
                points: points
            )
        ) { error in
            XCTAssertEqual(error as? CanvasStrokeCodecError, .tooManyPoints)
        }
    }

    func testViewportWorldViewRoundTripSurvivesResize() {
        let viewport = CanvasViewport(
            center: CanvasPoint(x: 120, y: -40),
            scale: 2.5
        )
        let world = CanvasPoint(x: 152.25, y: 4.5)

        for size in [CGSize(width: 300, height: 380), CGSize(width: 380, height: 700)] {
            let view = viewport.viewPoint(for: world, in: size)
            let roundTrip = viewport.worldPoint(for: view, in: size)
            assertEqual(roundTrip, world)
        }
    }

    func testWorldPointRejectsInvalidViewportGeometry() {
        let viewport = CanvasViewport()

        XCTAssertFalse(viewport.worldPoint(
            for: CGPoint(x: 20, y: 20),
            in: CGSize(width: CGFloat.infinity, height: 100)
        ).isFinite)
        XCTAssertFalse(viewport.worldPoint(
            for: CGPoint(x: CGFloat.nan, y: 20),
            in: CGSize(width: 100, height: 100)
        ).isFinite)
    }

    func testAppendInkRejectsNonFiniteWorldPointWithoutPoisoningStroke() {
        let controller = CanvasInteractionController()

        XCTAssertTrue(controller.beginInk(
            at: CGPoint(x: 20, y: 20),
            in: CGSize(width: 100, height: 100)
        ))
        XCTAssertFalse(controller.appendInk(
            at: CGPoint(x: 25, y: 25),
            in: CGSize(width: CGFloat.infinity, height: 100)
        ))
        XCTAssertEqual(controller.machine.bufferedPointCount, 1)

        guard case let .stroke(points, _, _) = controller.finishInk() else {
            return XCTFail("Expected the valid starting point to remain finishable")
        }
        XCTAssertEqual(points.count, 1)
        XCTAssertTrue(points[0].isFinite)
    }

    func testZoomKeepsAnchorWorldPointStationaryAndClampsScale() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 30, y: -20),
            scale: 1
        )
        let size = CGSize(width: 300, height: 380)
        let anchor = CGPoint(x: 62, y: 147)
        let anchoredWorldPoint = viewport.worldPoint(for: anchor, in: size)

        viewport.zoom(by: 3, anchoredAt: anchor, in: size)

        assertEqual(viewport.worldPoint(for: anchor, in: size), anchoredWorldPoint)
        XCTAssertEqual(viewport.scale, 3, accuracy: 0.000_001)

        viewport.zoom(by: 1_000, anchoredAt: anchor, in: size)
        XCTAssertEqual(viewport.scale, CanvasViewport.maximumScale)
        viewport.zoom(by: 0.000_001, anchoredAt: anchor, in: size)
        XCTAssertEqual(viewport.scale, CanvasViewport.minimumScale)
    }

    func testShapeGeometryUsesTheChosenDragInsteadOfViewportCentre() {
        let start = CanvasPoint(x: 70, y: 40)
        let end = CanvasPoint(x: -10, y: 130)

        XCTAssertEqual(
            CanvasShapeKind.rectangle.points(from: start, to: end),
            [
                CanvasPoint(x: -10, y: 40),
                CanvasPoint(x: 70, y: 40),
                CanvasPoint(x: 70, y: 130),
                CanvasPoint(x: -10, y: 130),
                CanvasPoint(x: -10, y: 40)
            ]
        )
        XCTAssertEqual(
            CanvasShapeKind.line.points(from: start, to: end),
            [start, end]
        )
        XCTAssertTrue(CanvasShapeKind.ellipse.points(
            from: start,
            to: end
        ).allSatisfy {
            (-10...70).contains($0.x) && (40...130).contains($0.y)
        })
    }

    func testArrowGeometryPreservesUserChosenDirection() throws {
        let start = CanvasPoint(x: 10, y: 15)
        let end = CanvasPoint(x: -40, y: -25)
        let points = CanvasShapeKind.arrow.points(from: start, to: end)

        XCTAssertEqual(points.first, start)
        XCTAssertEqual(points.dropFirst().first, end)
        XCTAssertEqual(points.count, 5)
        XCTAssertTrue(points.allSatisfy(\.isFinite))
    }

    func testShapeGeometryRejectsClickWithoutDrag() {
        let point = CanvasPoint(x: 4, y: 8)

        for shape in CanvasShapeKind.allCases {
            XCTAssertTrue(shape.points(from: point, to: point).isEmpty)
        }
    }

    @MainActor
    func testCanvasCursorRoleFollowsToolAndPlacementMode() {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))

        _ = view.interaction.configure(
            strokes: [],
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        XCTAssertEqual(view.baseCursorRole, .arrow)

        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        XCTAssertEqual(view.baseCursorRole, .pen)

        _ = view.interaction.configure(
            strokes: [],
            tool: .eraser,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        XCTAssertEqual(view.baseCursorRole, .eraser)

        view.pendingPlacement = .text(CanvasTextPlacement(
            text: "Here",
            prefersDarkSurface: false
        ))
        XCTAssertEqual(view.baseCursorRole, .textPlacement)
        view.pendingPlacement = .shape(.ellipse)
        XCTAssertEqual(view.baseCursorRole, .shapePlacement)
    }

    func testZoomOverflowClampsToMaximumInsteadOfResettingToOne() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 30, y: -20),
            scale: 2
        )

        viewport.zoom(
            by: Double.greatestFiniteMagnitude,
            anchoredAt: CGPoint(x: 150, y: 190),
            in: CGSize(width: 300, height: 380)
        )

        XCTAssertEqual(viewport.scale, CanvasViewport.maximumScale)
        XCTAssertTrue(viewport.center.isFinite)
    }

    func testZoomWithInvalidViewportRestoresScaleAndCenter() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 30, y: -20),
            scale: 2
        )
        let original = viewport

        viewport.zoom(
            by: 2,
            anchoredAt: CGPoint(x: 150, y: 190),
            in: CGSize(width: CGFloat.infinity, height: 380)
        )

        XCTAssertEqual(viewport, original)
    }

    func testPanOverflowLeavesViewportUnchanged() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: Double.greatestFiniteMagnitude, y: 4),
            scale: 0.25
        )
        let original = viewport

        viewport.pan(byViewTranslation: CGSize(
            width: -CGFloat(Double.greatestFiniteMagnitude),
            height: 0
        ))

        XCTAssertEqual(viewport, original)
    }

    func testPanUsesViewTranslationWithoutMutatingWorldGeometry() {
        var viewport = CanvasViewport(
            center: CanvasPoint(x: 10, y: 20),
            scale: 2
        )
        let strokePoint = CanvasPoint(x: 50, y: 80)

        viewport.pan(byViewTranslation: CGSize(width: 20, height: -10))

        assertEqual(viewport.center, CanvasPoint(x: 0, y: 25))
        XCTAssertEqual(strokePoint, CanvasPoint(x: 50, y: 80))
    }

    func testFitCentersBoundsAndUsesAvailableViewport() {
        var viewport = CanvasViewport()
        let bounds = CGRect(x: -50, y: -25, width: 100, height: 50)

        viewport.fit(
            bounds: bounds,
            in: CGSize(width: 300, height: 200),
            padding: 20
        )

        assertEqual(viewport.center, .zero)
        XCTAssertEqual(viewport.scale, 2.6, accuracy: 0.000_001)
    }

    func testWorldRectTracksZoomAndPanForRenderCulling() {
        let viewport = CanvasViewport(
            center: CanvasPoint(x: 100, y: -50),
            scale: 2
        )

        let worldRect = viewport.worldRect(
            for: CGRect(x: 0, y: 0, width: 300, height: 200),
            in: CGSize(width: 300, height: 200)
        )

        XCTAssertEqual(worldRect.minX, 25, accuracy: 0.000_001)
        XCTAssertEqual(worldRect.maxX, 175, accuracy: 0.000_001)
        XCTAssertEqual(worldRect.minY, -100, accuracy: 0.000_001)
        XCTAssertEqual(worldRect.maxY, 0, accuracy: 0.000_001)
    }

    func testHitTestingErasesWholeIntersectedStrokeOnly() {
        let hitID = UUID()
        let missID = UUID()
        let strokes = [
            CanvasStroke(
                id: hitID,
                color: .ink,
                width: 4,
                points: [
                    CanvasPoint(x: 0, y: 0),
                    CanvasPoint(x: 100, y: 0)
                ]
            ),
            CanvasStroke(
                id: missID,
                color: .red,
                width: 4,
                points: [
                    CanvasPoint(x: 0, y: 100),
                    CanvasPoint(x: 100, y: 100)
                ]
            )
        ]

        let hits = CanvasHitTesting.strokeIDs(
            hitBy: [
                CanvasPoint(x: 40, y: 6),
                CanvasPoint(x: 60, y: 6)
            ],
            radius: 8,
            strokes: strokes
        )

        XCTAssertEqual(hits, Set([hitID]))
    }

    func testPanTakeoverDiscardsInProgressInkAndNeverCompletesStroke() {
        var machine = CanvasInputStateMachine()

        XCTAssertTrue(machine.beginInk(tool: .pen, at: CanvasPoint(x: 1, y: 2)))
        machine.append(CanvasPoint(x: 3, y: 4))
        XCTAssertTrue(machine.beginPan())
        XCTAssertNil(machine.finishInk())
        XCTAssertEqual(machine.state, .panning)

        machine.finishPan()
        XCTAssertEqual(machine.state, .idle)
    }

    @MainActor
    func testTrackpadViewportDeltaCannotLeaveCanvasInputCaptured() {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )

        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))
        XCTAssertTrue(view.beginViewportGestureSequence(
            source: .magnification,
            mode: .zoom
        ))
        view.applyViewportZoom(
            by: 1.2,
            anchoredAt: CGPoint(x: 120, y: 160),
            in: view.bounds.size
        )
        view.finishViewportGestureSequence(
            source: .magnification,
            at: CGPoint(x: 120, y: 160)
        )

        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 80, y: 90),
            in: view.bounds.size
        ))
    }

    @MainActor
    func testTrackpadDoesNotStealSpaceHeldPointerPan() {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let viewPoint = CGPoint(x: 120, y: 160)
        defer { NSCursor.arrow.set() }

        view.spacePressed = true
        view.beginPan(at: viewPoint)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)

        XCTAssertFalse(view.beginViewportGestureSequence(
            source: .magnification,
            mode: .zoom
        ))

        XCTAssertEqual(view.interaction.machine.state, .panning)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)
        view.finishPointerInteraction(finalInkPoint: nil)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testTrackpadDoesNotStealRightOrOtherPointerPan() {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let viewPoint = CGPoint(x: 120, y: 160)
        defer { NSCursor.arrow.set() }
        _ = view.interaction.configure(
            strokes: [],
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )

        view.beginPan(at: viewPoint)
        XCTAssertTrue(NSCursor.current === NSCursor.closedHand)

        XCTAssertFalse(view.beginViewportGestureSequence(
            source: .scroll,
            mode: .pan
        ))

        XCTAssertEqual(view.interaction.machine.state, .panning)
        view.finishPointerInteraction(finalInkPoint: nil)
        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertEqual(view.cursorRole(at: viewPoint), .arrow)
    }

    @MainActor
    func testCanvasOwnsReentrantPinchRecognitionAcrossInteractionLifecycle() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let firstCanvasID = UUID()
        view.configure(
            canvasID: firstCanvasID,
            strokes: [],
            images: [],
            selectedImageID: nil,
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        let recognizer = try XCTUnwrap(
            view.gestureRecognizers.compactMap {
                $0 as? NSMagnificationGestureRecognizer
            }.first
        )
        XCTAssertTrue(recognizer.view === view)
        XCTAssertTrue(recognizer.target === view)
        XCTAssertTrue(recognizer.delaysMagnificationEvents)
        XCTAssertFalse(recognizer.delaysPrimaryMouseButtonEvents)

        func applyPinch(
            _ magnification: CGFloat,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let previousScale = view.interaction.viewport.scale
            recognizer.magnification = magnification
            let action = try XCTUnwrap(
                recognizer.action,
                file: file,
                line: line
            )
            XCTAssertTrue(
                NSApplication.shared.sendAction(
                    action,
                    to: recognizer.target,
                    from: recognizer
                ),
                file: file,
                line: line
            )
            XCTAssertNotEqual(
                view.interaction.viewport.scale,
                previousScale,
                file: file,
                line: line
            )
            XCTAssertEqual(recognizer.magnification, 0, file: file, line: line)
            XCTAssertEqual(
                view.interaction.machine.state,
                .idle,
                file: file,
                line: line
            )
        }

        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))
        XCTAssertTrue(view.interaction.appendInk(
            at: CGPoint(x: 80, y: 90),
            in: view.bounds.size
        ))
        XCTAssertNotNil(view.interaction.finishInk())
        try applyPinch(0.20)

        view.configure(
            canvasID: firstCanvasID,
            strokes: [],
            images: [],
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: view.interaction.viewport,
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        view.beginPan(at: CGPoint(x: 120, y: 160))
        view.continuePan(to: CGPoint(x: 135, y: 170))
        view.finishPointerInteraction(finalInkPoint: nil)
        try applyPinch(-0.10)

        view.cancelInteraction()
        view.setFrameSize(CGSize(width: 520, height: 640))
        view.configure(
            canvasID: UUID(),
            strokes: [],
            images: [],
            selectedImageID: nil,
            tool: .eraser,
            color: .blue,
            width: 8,
            viewport: view.interaction.viewport,
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        try applyPinch(0.15)

        // Three pinch callbacks plus the explicit space-pan delta above.
        XCTAssertEqual(deliveredViewports.count, 4)
    }

    @MainActor
    func testCommandScrollUsesReentrantCanvasZoomPath() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveredViewport: CanvasViewport?
        view.onViewportChange = { deliveredViewport = $0 }
        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))

        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 12,
            wheel2: 0,
            wheel3: 0
        ))
        event.flags = .maskCommand
        event.location = CGPoint(x: 120, y: 160)
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))

        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertGreaterThan(view.interaction.viewport.scale, 1)
        XCTAssertEqual(deliveredViewport, view.interaction.viewport)
    }

    @MainActor
    func testScrollSequenceLatchesModeThroughMomentumAndModifierChanges() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 8,
            command: true,
            phase: 1
        ))
        let scaleAfterBegin = view.interaction.viewport.scale
        XCTAssertEqual(view.interaction.machine.state, .panning)

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 6,
            command: false,
            phase: 2
        ))
        let scaleAfterChanged = view.interaction.viewport.scale
        XCTAssertGreaterThan(scaleAfterChanged, scaleAfterBegin)
        XCTAssertEqual(view.interaction.machine.state, .panning)

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            phase: 4
        ))
        XCTAssertEqual(view.interaction.machine.state, .idle)

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 4,
            command: false,
            momentumPhase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 3,
            command: true,
            momentumPhase: 2
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            momentumPhase: 3
        ))
        XCTAssertGreaterThan(view.interaction.viewport.scale, scaleAfterChanged)
        XCTAssertEqual(view.interaction.machine.state, .idle)

        let scaleBeforePan = view.interaction.viewport.scale
        let centerBeforePan = view.interaction.viewport.center
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 7,
            command: false,
            phase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 5,
            command: true,
            phase: 2
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: true,
            phase: 4
        ))

        XCTAssertEqual(view.interaction.viewport.scale, scaleBeforePan)
        XCTAssertNotEqual(view.interaction.viewport.center, centerBeforePan)
        XCTAssertEqual(deliveredViewports.count, 6)
    }

    @MainActor
    func testLateZeroAndMomentumTailCannotCancelNewInk() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveryCount = 0
        view.onViewportChange = { _ in deliveryCount += 1 }

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 8,
            command: true,
            phase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            phase: 4
        ))
        XCTAssertEqual(deliveryCount, 1)

        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 5,
            command: false,
            momentumPhase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: false,
            momentumPhase: 3
        ))

        XCTAssertEqual(view.interaction.machine.state, .drawing)
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertNotNil(view.interaction.finishInk())
    }

    @MainActor
    func testInterruptedDirectScrollTailCannotReacquireNewInk() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        _ = view.interaction.configure(
            strokes: [],
            tool: .pen,
            color: .ink,
            width: 3,
            viewport: CanvasViewport()
        )
        var deliveryCount = 0
        view.onViewportChange = { _ in deliveryCount += 1 }

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 8,
            command: true,
            phase: 1
        ))
        XCTAssertEqual(deliveryCount, 1)
        view.interruptViewportGestureForPointer()
        XCTAssertTrue(view.interaction.beginInk(
            at: CGPoint(x: 40, y: 50),
            in: view.bounds.size
        ))

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 6,
            command: false,
            phase: 2
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 4,
            command: false,
            phase: 4
        ))

        XCTAssertEqual(view.interaction.machine.state, .drawing)
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertNotNil(view.interaction.finishInk())

        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 5,
            command: true,
            phase: 1
        ))
        view.scrollWheel(with: try canvasScrollEvent(
            deltaY: 0,
            command: true,
            phase: 4
        ))
        XCTAssertEqual(deliveryCount, 2)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testCancelledMagnificationTailCannotRestartUntilNewBegan() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        let installed = try XCTUnwrap(
            view.gestureRecognizers.compactMap {
                $0 as? NSMagnificationGestureRecognizer
            }.first
        )
        let action = try XCTUnwrap(installed.action)
        let recognizer = DrivenMagnificationGestureRecognizer(
            target: installed.target,
            action: action
        )
        view.removeGestureRecognizer(installed)
        view.addGestureRecognizer(recognizer)
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }

        func drive(
            _ state: NSGestureRecognizer.State,
            magnification: CGFloat
        ) {
            recognizer.drive(state, magnification: magnification)
            XCTAssertTrue(NSApplication.shared.sendAction(
                action,
                to: recognizer.target,
                from: recognizer
            ))
        }

        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.20)
        XCTAssertEqual(deliveredViewports.count, 1)
        let viewportBeforeCancellation = view.interaction.viewport

        view.cancelInteraction()
        drive(.changed, magnification: 0.15)
        drive(.ended, magnification: 0.10)
        XCTAssertEqual(view.interaction.viewport, viewportBeforeCancellation)
        XCTAssertEqual(deliveredViewports.count, 1)

        recognizer.drive(.possible, magnification: 0)
        drive(.began, magnification: 0)
        drive(.changed, magnification: -0.10)
        drive(.ended, magnification: 0.05)
        XCTAssertEqual(deliveredViewports.count, 2)
        XCTAssertNotEqual(view.interaction.viewport, viewportBeforeCancellation)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    func testDetachedCanvasRecognizerCannotPublishViewportTail() throws {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }
        let recognizer = try XCTUnwrap(
            view.gestureRecognizers.compactMap {
                $0 as? NSMagnificationGestureRecognizer
            }.first
        )
        let action = try XCTUnwrap(recognizer.action)

        CanvasNSViewRepresentable.dismantleNSView(view, coordinator: ())
        recognizer.magnification = 0.2
        XCTAssertTrue(NSApplication.shared.sendAction(
            action,
            to: recognizer.target,
            from: recognizer
        ))

        XCTAssertFalse(view.isRepresentationActive)
        XCTAssertFalse(recognizer.isEnabled)
        XCTAssertTrue(deliveredViewports.isEmpty)
        XCTAssertEqual(view.interaction.viewport, CanvasViewport())
    }

    private func canvasScrollEvent(
        deltaX: Int32 = 0,
        deltaY: Int32,
        command: Bool,
        phase: Int64 = 0,
        momentumPhase: Int64 = 0
    ) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ))
        if command { event.flags = .maskCommand }
        event.location = CGPoint(x: 120, y: 160)
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: phase
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: momentumPhase
        )
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    func testSelectToolNeverStartsAnInkOperation() {
        var machine = CanvasInputStateMachine()

        XCTAssertFalse(machine.beginInk(
            tool: .select,
            at: CanvasPoint(x: 1, y: 2)
        ))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.bufferedPointCount, 0)
        XCTAssertNil(machine.finishInk())
    }

    func testInterruptedEraseIsDiscardedDeterministically() {
        var machine = CanvasInputStateMachine()

        XCTAssertTrue(machine.beginInk(tool: .eraser, at: CanvasPoint(x: 1, y: 2)))
        machine.append(CanvasPoint(x: 3, y: 4))
        XCTAssertTrue(machine.cancel())
        XCTAssertNil(machine.finishInk())
        XCTAssertEqual(machine.state, .idle)
    }

    func testPointerUpCompletesExactlyOneBufferedOperation() {
        var machine = CanvasInputStateMachine()
        let points = [
            CanvasPoint(x: 1, y: 2),
            CanvasPoint(x: 3, y: 4),
            CanvasPoint(x: 5, y: 6)
        ]

        XCTAssertTrue(machine.beginInk(tool: .pen, at: points[0]))
        machine.append(points[1])
        machine.append(points[2])

        XCTAssertEqual(machine.finishInk(), .stroke(points))
        XCTAssertNil(machine.finishInk())
        XCTAssertEqual(machine.state, .idle)
    }

    func testLongGestureCompactsWithoutLosingItsEndpoints() throws {
        var machine = CanvasInputStateMachine()
        let first = CanvasPoint(x: 0, y: 0)
        XCTAssertTrue(machine.beginInk(tool: .pen, at: first))

        let finalIndex = CanvasInputStateMachine.maximumBufferedPointCount * 3
        for index in 1...finalIndex {
            machine.append(CanvasPoint(x: Double(index), y: Double(index % 13)))
        }

        guard case let .stroke(points) = try XCTUnwrap(machine.finishInk()) else {
            return XCTFail("Expected a completed stroke")
        }
        XCTAssertLessThanOrEqual(
            points.count,
            CanvasInputStateMachine.maximumBufferedPointCount
        )
        XCTAssertEqual(points.first, first)
        XCTAssertEqual(
            points.last,
            CanvasPoint(x: Double(finalIndex), y: Double(finalIndex % 13))
        )
    }

    @MainActor
    func testUnchangedRefreshReusesDecodedStrokeAndRenderToken() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var decodeCount = 0
        let store = CanvasStore(
            container: container,
            decodeStroke: { data, version in
                decodeCount += 1
                return try CanvasStrokeCodec.decode(
                    data,
                    expectedVersion: version
                )
            }
        )

        let first = try XCTUnwrap(store.addStroke(
            color: .blue,
            width: 4,
            points: [CanvasPoint(x: 1, y: 2)]
        ))
        XCTAssertEqual(decodeCount, 1)

        store.refresh()
        XCTAssertEqual(decodeCount, 1)
        XCTAssertEqual(store.strokes.first?.renderToken, first.renderToken)

        XCTAssertNotNil(store.addStroke(
            color: .red,
            width: 3,
            points: [CanvasPoint(x: 10, y: 20)]
        ))
        XCTAssertEqual(decodeCount, 2)
        XCTAssertEqual(
            store.strokes.first(where: { $0.id == first.id })?.renderToken,
            first.renderToken
        )
    }

    @MainActor
    func testChangedReplicaInvalidatesOnlyItsRenderToken() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        var decodeCount = 0
        let store = CanvasStore(
            container: container,
            decodeStroke: { data, version in
                decodeCount += 1
                return try CanvasStrokeCodec.decode(
                    data,
                    expectedVersion: version
                )
            }
        )
        let original = try XCTUnwrap(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 0, y: 0)]
        ))
        XCTAssertEqual(decodeCount, 1)

        let externalContext = ModelContext(container)
        let row = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<CanvasStrokeItem>()).first
        )
        row.payload = try CanvasStrokeCodec.encode(
            color: .green,
            width: 5,
            points: [CanvasPoint(x: 8, y: 9)]
        )
        row.mutationVersion += 1
        row.updatedAt = row.updatedAt.addingTimeInterval(1)
        try externalContext.save()

        store.refresh()

        XCTAssertEqual(decodeCount, 2)
        let changed = try XCTUnwrap(store.strokes.first)
        XCTAssertNotEqual(changed.renderToken, original.renderToken)
        XCTAssertEqual(changed.color, .green)
    }

    private func assertEqual(
        _ lhs: CanvasPoint,
        _ rhs: CanvasPoint,
        accuracy: Double = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
    }
}
