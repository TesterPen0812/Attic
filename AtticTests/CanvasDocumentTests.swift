import AppKit
import CoreGraphics
import Foundation
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

final class CanvasImageInteractionTests: XCTestCase {
    func testDefaultPlacementPreservesExtremeAspectRatio() {
        let size = CanvasImagePlacement.defaultSize(
            pixelWidth: 4_000,
            pixelHeight: 100
        )

        XCTAssertEqual(size.width, 360, accuracy: 0.000_001)
        XCTAssertEqual(size.height, 9, accuracy: 0.000_001)
        XCTAssertEqual(size.width / size.height, 40, accuracy: 0.000_001)
    }

    func testResizePreservesAspectRatioAndOppositeCorner() {
        let original = CanvasImageTransform(
            center: CanvasPoint(x: 100, y: 100),
            width: 200,
            height: 100,
            zIndex: 4
        )

        let resized = CanvasImagePlacement.resizedTransform(
            from: original,
            handle: .bottomRight,
            to: CanvasPoint(x: 400, y: 260)
        )

        XCTAssertEqual(resized.width / resized.height, 2, accuracy: 0.000_001)
        XCTAssertEqual(resized.center.x - resized.width / 2, 0, accuracy: 0.000_001)
        XCTAssertEqual(resized.center.y - resized.height / 2, 50, accuracy: 0.000_001)
        XCTAssertEqual(resized.zIndex, original.zIndex)
    }

    func testImageHitTestingSelectsOnlyTopmostClickedImage() {
        let back = CanvasPlacedImage(
            id: UUID(),
            encodedData: Data([1]),
            contentType: UTType.png.identifier,
            pixelWidth: 20,
            pixelHeight: 20,
            transform: CanvasImageTransform(
                center: .zero,
                width: 100,
                height: 100,
                zIndex: 1
            )
        )
        let front = CanvasPlacedImage(
            id: UUID(),
            encodedData: Data([2]),
            contentType: UTType.png.identifier,
            pixelWidth: 20,
            pixelHeight: 20,
            transform: CanvasImageTransform(
                center: .zero,
                width: 80,
                height: 80,
                zIndex: 9
            )
        )

        XCTAssertEqual(
            CanvasImagePlacement.topmostImage(at: .zero, images: [back, front])?.id,
            front.id
        )
        XCTAssertNil(CanvasImagePlacement.topmostImage(
            at: CanvasPoint(x: 200, y: 200),
            images: [back, front]
        ))
    }

    func testResizeHandleHitTestingUsesViewCoordinatesAfterZoomAndPan() {
        let image = CanvasPlacedImage(
            encodedData: Data([1]),
            contentType: UTType.png.identifier,
            pixelWidth: 100,
            pixelHeight: 50,
            transform: CanvasImageTransform(
                center: CanvasPoint(x: 300, y: -100),
                width: 200,
                height: 100,
                zIndex: 0
            )
        )
        let viewport = CanvasViewport(
            center: CanvasPoint(x: 250, y: -50),
            scale: 2.5
        )
        let size = CGSize(width: 500, height: 400)
        let corner = viewport.viewPoint(
            for: CanvasPoint(x: image.worldRect.maxX, y: image.worldRect.maxY),
            in: size
        )

        XCTAssertEqual(
            CanvasImagePlacement.resizeHandle(
                at: corner,
                image: image,
                viewport: viewport,
                viewportSize: size
            ),
            .bottomRight
        )
    }
}

final class CanvasDocumentStoreTests: XCTestCase {
    @MainActor
    func testCreateRenameSwitchDeletePersistsAndIsolatesContent() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let session = CanvasSession(store: store)
        let defaultID = session.selectedCanvasID

        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: 1, y: 2)]))
        let created = try XCTUnwrap(session.createCanvas(name: "Ideas"))
        XCTAssertEqual(session.canvases.count, 2)
        XCTAssertEqual(session.selectedCanvasID, created.id)
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.images.isEmpty)

        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: 9, y: 10)]))
        XCTAssertTrue(session.importPreparedImage(
            CanvasPreparedImage(
                encodedData: Data([7, 8, 9]),
                contentType: UTType.png.identifier,
                pixelWidth: 120,
                pixelHeight: 60
            ),
            at: CanvasPoint(x: 30, y: 40)
        ))
        XCTAssertTrue(session.renameSelectedCanvas(to: "Reference"))
        XCTAssertEqual(session.selectedCanvas.name, "Reference")

        let relaunchedStore = CanvasStore(container: container)
        XCTAssertEqual(relaunchedStore.canvases.map(\.name), ["Canvas", "Reference"])
        XCTAssertEqual(relaunchedStore.selectedCanvasID, defaultID)
        XCTAssertEqual(relaunchedStore.strokes.count, 1)
        XCTAssertTrue(relaunchedStore.images.isEmpty)

        XCTAssertTrue(relaunchedStore.selectCanvas(created.id))
        XCTAssertEqual(relaunchedStore.strokes.count, 1)
        XCTAssertEqual(relaunchedStore.images.count, 1)
        XCTAssertEqual(relaunchedStore.images.first?.center, CanvasPoint(x: 30, y: 40))

        XCTAssertTrue(relaunchedStore.deleteCanvas(created.id))
        XCTAssertEqual(relaunchedStore.canvases.map(\.id), [defaultID])
        XCTAssertEqual(relaunchedStore.selectedCanvasID, defaultID)
        XCTAssertEqual(relaunchedStore.strokes.count, 1)

        let verification = ModelContext(container)
        let boards = try verification.fetch(FetchDescriptor<CanvasBoardItem>())
            .filter { $0.id == created.id }
        let strokes = try verification.fetch(FetchDescriptor<CanvasStrokeItem>())
            .filter { $0.canvasID == created.id }
        let images = try verification.fetch(FetchDescriptor<CanvasImageItem>())
            .filter { $0.canvasID == created.id }
        XCTAssertFalse(boards.isEmpty)
        XCTAssertTrue(boards.allSatisfy { $0.tombstoned })
        XCTAssertTrue(strokes.allSatisfy { $0.tombstoned })
        XCTAssertTrue(images.allSatisfy { $0.tombstoned })
    }

    @MainActor
    func testDuplicateBoardTombstoneWinsWithoutDeletingPhysicalReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 50)
        context.insert(CanvasBoardItem(
            id: id,
            name: "Active",
            sortIndex: 1,
            mutationVersion: 3,
            tombstoned: false,
            updatedAt: timestamp
        ))
        context.insert(CanvasBoardItem(
            id: id,
            name: "Deleted",
            sortIndex: 1,
            mutationVersion: 3,
            tombstoned: true,
            updatedAt: timestamp,
            deletedAt: timestamp
        ))
        try context.save()

        let store = CanvasStore(container: container)

        XCTAssertFalse(store.canvases.contains(where: { $0.id == id }))
        let verification = ModelContext(container)
        XCTAssertEqual(
            try verification.fetch(FetchDescriptor<CanvasBoardItem>())
                .filter { $0.id == id }.count,
            2
        )
    }

    @MainActor
    func testCanvasSwitchFlushesPendingHistoryAndSelection() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let session = CanvasSession(store: CanvasStore(container: container))
        XCTAssertTrue(session.importPreparedImage(
            CanvasPreparedImage(
                encodedData: Data([1]),
                contentType: UTType.png.identifier,
                pixelWidth: 20,
                pixelHeight: 10
            ),
            at: .zero
        ))
        XCTAssertNotNil(session.selectedImageID)
        XCTAssertTrue(session.canUndo)

        XCTAssertNotNil(session.createCanvas(name: "Second"))

        XCTAssertNil(session.selectedImageID)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.undo())
    }

    @MainActor
    func testExplicitDefaultTombstoneDoesNotResurrectDeletedIdentity() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let timestamp = Date(timeIntervalSince1970: 100)
        context.insert(CanvasBoardItem(
            id: CanvasBoardItem.logicalBoardID,
            name: "Canvas",
            sortIndex: 0,
            mutationVersion: 4,
            tombstoned: true,
            updatedAt: timestamp,
            deletedAt: timestamp
        ))
        try context.save()

        let store = CanvasStore(container: container)

        XCTAssertFalse(store.canvases.contains {
            $0.id == CanvasBoardItem.logicalBoardID
        })
        XCTAssertEqual(store.canvases.map(\.id), [CanvasBoardItem.recoveryBoardID])
        XCTAssertEqual(store.selectedCanvasID, CanvasBoardItem.recoveryBoardID)

        XCTAssertNotNil(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 2, y: 3)]
        ))
        let relaunched = CanvasStore(container: container)
        XCTAssertEqual(relaunched.canvases.map(\.id), [CanvasBoardItem.recoveryBoardID])
        XCTAssertEqual(relaunched.strokes.count, 1)
    }

    @MainActor
    func testTransformInvalidatesRenderTokenButRetainsContentToken() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let image = try XCTUnwrap(store.addImage(
            CanvasPreparedImage(
                encodedData: Data([1, 2, 3]),
                contentType: UTType.png.identifier,
                pixelWidth: 100,
                pixelHeight: 50
            ),
            center: .zero
        ))
        let transform = CanvasImageTransform(
            center: CanvasPoint(x: 20, y: 30),
            width: image.width,
            height: image.height,
            zIndex: image.zIndex
        )

        XCTAssertTrue(store.updateImage(image.id, transform: transform))
        let updated = try XCTUnwrap(store.images.first)
        XCTAssertNotEqual(updated.renderToken, image.renderToken)
        XCTAssertEqual(updated.contentToken, image.contentToken)
    }

    @MainActor
    func testDeletingOnlyCanvasIsRejectedWithoutDataLoss() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        XCTAssertNotNil(store.addStroke(
            color: .ink,
            width: 3,
            points: [CanvasPoint(x: 1, y: 1)]
        ))

        XCTAssertFalse(store.deleteCanvas(store.selectedCanvasID))
        XCTAssertEqual(store.canvases.count, 1)
        XCTAssertEqual(store.strokes.count, 1)
    }
}

@MainActor
private final class DrivenViewportMagnificationRecognizer:
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

final class CanvasViewportGestureRoutingTests: XCTestCase {
    @MainActor
    func testPinchReclaimsViewportAfterResizeInterruptsScrollTerminalPhase() throws {
        let view = configuredCanvasView()
        var deliveredViewports: [CanvasViewport] = []
        view.onViewportChange = { deliveredViewports.append($0) }
        let (recognizer, action) = try drivenMagnificationRecognizer(in: view)

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

        view.scrollWheel(with: try scrollEvent(
            deltaY: 8,
            command: true,
            phase: 1
        ))
        let viewportAfterScroll = view.interaction.viewport
        XCTAssertGreaterThan(viewportAfterScroll.scale, 1)
        XCTAssertEqual(
            view.activeViewportGesture,
            CanvasNSView.ViewportGestureSequence(source: .scroll, mode: .zoom)
        )
        XCTAssertEqual(view.interaction.machine.state, .panning)

        // Live panel resizing can interrupt AppKit's terminal scroll phase.
        view.setFrameSize(CGSize(width: 520, height: 640))
        drive(.began, magnification: 0)
        drive(.changed, magnification: 0.20)

        let viewportAfterPinch = view.interaction.viewport
        XCTAssertGreaterThan(viewportAfterPinch.scale, viewportAfterScroll.scale)
        XCTAssertEqual(
            view.activeViewportGesture,
            CanvasNSView.ViewportGestureSequence(
                source: .magnification,
                mode: .zoom
            )
        )
        XCTAssertEqual(view.interaction.machine.state, .panning)

        // The interrupted scroll tail must not retake or terminate pinch ownership.
        view.scrollWheel(with: try scrollEvent(
            deltaY: 6,
            command: true,
            phase: 2
        ))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 0,
            command: true,
            phase: 4
        ))
        XCTAssertEqual(view.interaction.viewport, viewportAfterPinch)
        XCTAssertEqual(
            view.activeViewportGesture?.source,
            .magnification
        )

        drive(.ended, magnification: 0)
        XCTAssertNil(view.activeViewportGesture)
        XCTAssertEqual(view.interaction.machine.state, .idle)

        let scaleBeforeSecondPinch = view.interaction.viewport.scale
        drive(.began, magnification: 0)
        drive(.changed, magnification: -0.10)
        drive(.ended, magnification: 0)
        XCTAssertLessThan(view.interaction.viewport.scale, scaleBeforeSecondPinch)
        XCTAssertNil(view.activeViewportGesture)
        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertGreaterThanOrEqual(deliveredViewports.count, 3)
    }

    @MainActor
    func testDirectPanReclaimsViewportAfterResizeInterruptsMagnification() throws {
        let view = configuredCanvasView()
        let (recognizer, action) = try drivenMagnificationRecognizer(in: view)

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
        let viewportAfterPinch = view.interaction.viewport
        XCTAssertGreaterThan(viewportAfterPinch.scale, 1)
        XCTAssertEqual(
            view.activeViewportGesture?.source,
            .magnification
        )

        view.setFrameSize(CGSize(width: 420, height: 560))
        view.scrollWheel(with: try scrollEvent(
            deltaY: 8,
            command: false,
            phase: 1
        ))

        let viewportAfterPanBegan = view.interaction.viewport
        XCTAssertNotEqual(viewportAfterPanBegan.center, viewportAfterPinch.center)
        XCTAssertEqual(viewportAfterPanBegan.scale, viewportAfterPinch.scale)
        XCTAssertEqual(
            view.activeViewportGesture,
            CanvasNSView.ViewportGestureSequence(source: .scroll, mode: .pan)
        )

        // A late magnification callback is from the interrupted recognizer.
        drive(.changed, magnification: 0.15)
        XCTAssertEqual(view.interaction.viewport, viewportAfterPanBegan)
        XCTAssertEqual(view.activeViewportGesture?.source, .scroll)

        view.scrollWheel(with: try scrollEvent(
            deltaY: 5,
            command: false,
            phase: 2
        ))
        XCTAssertNotEqual(view.interaction.viewport.center, viewportAfterPanBegan.center)
        view.scrollWheel(with: try scrollEvent(
            deltaY: 0,
            command: false,
            phase: 4
        ))
        XCTAssertNil(view.activeViewportGesture)
        XCTAssertEqual(view.interaction.machine.state, .idle)

        drive(.ended, magnification: 0)
        XCTAssertNil(view.activeViewportGesture)
        XCTAssertEqual(view.interaction.machine.state, .idle)
    }

    @MainActor
    private func configuredCanvasView() -> CanvasNSView {
        let view = CanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 300, height: 380)
        )
        view.configure(
            canvasID: CanvasBoardItem.logicalBoardID,
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
        return view
    }

    @MainActor
    private func drivenMagnificationRecognizer(
        in view: CanvasNSView
    ) throws -> (DrivenViewportMagnificationRecognizer, Selector) {
        let installed = try XCTUnwrap(
            view.gestureRecognizers.compactMap {
                $0 as? NSMagnificationGestureRecognizer
            }.first
        )
        let action = try XCTUnwrap(installed.action)
        let recognizer = DrivenViewportMagnificationRecognizer(
            target: installed.target,
            action: action
        )
        view.removeGestureRecognizer(installed)
        view.addGestureRecognizer(recognizer)
        return (recognizer, action)
    }

    private func scrollEvent(
        deltaY: Int32,
        command: Bool,
        phase: Int64
    ) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        event.flags = command ? .maskCommand : []
        event.location = CGPoint(x: 120, y: 160)
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: phase
        )
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}
