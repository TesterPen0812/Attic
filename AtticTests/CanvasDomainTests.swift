import CoreGraphics
import Foundation
import SwiftData
import XCTest
@testable import Attic

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
