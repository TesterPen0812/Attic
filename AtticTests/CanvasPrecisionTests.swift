import AppKit
import XCTest
@testable import Attic

@MainActor
final class CanvasPrecisionTests: XCTestCase {
    func testToolbarUsesArrowAndRejectsDrawingEvenWhenPenIsSelected() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 320, height: 460))
        _ = view.interaction.configure(strokes: [], tool: .pen, color: .ink, width: 3, viewport: CanvasViewport())
        view.excludedControlRects = [CGRect(x: 40, y: 360, width: 240, height: 80)]
        XCTAssertEqual(view.cursorRole(at: CGPoint(x: 80, y: 390)), .arrow)
        XCTAssertEqual(view.cursorRole(at: CGPoint(x: 80, y: 200)), .pen)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(CGPoint(x: 80, y: 390), to: nil),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(view.interaction.machine.state, .idle)
        XCTAssertEqual(view.cursor(for: .pen).hotSpot, CGPoint(x: 12, y: 12))
    }

    func testSemanticShapeResizesFreelyAndShiftPreservesAspectRatio() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 320, height: 460))
        let original = CanvasImageTransform(center: CanvasPoint(x: 0, y: 0), width: 100, height: 50, zIndex: 1)
        let id = UUID()
        for flags: NSEvent.ModifierFlags in [[], .shift] {
            view.semanticPointerActive = true
            view.imagePointerMode = .resizing(id: id, handle: .bottomRight, original: original)
            let location = CGPoint(x: 250, y: 330)
            let world = view.interaction.viewport.worldPoint(for: location, in: view.bounds.size)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: view.convert(location, to: nil),
                modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            view.mouseDragged(with: event)
            let expected = CanvasImagePlacement.resizedTransform(from: original, handle: .bottomRight, to: world,
                preserveAspectRatio: flags.contains(.shift))
            XCTAssertEqual(view.previewImageTransform, expected)
            var committed: CanvasImageTransform?
            view.onTransformSemanticObject = { _, transform in committed = transform }
            XCTAssertTrue(view.finishImageInteraction())
            XCTAssertEqual(committed, expected)
        }
    }
}
