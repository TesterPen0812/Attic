import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneDrawExchangeTests: XCTestCase {
    private struct Records: Equatable {
        struct Canvas: Equatable {
            let id: UUID, name: String, tags: String, created: Date, updated: Date, deleted: Date?
            let thumbnailID: UUID?, thumbnailDark: Bool?, textIndex: String
        }
        struct Object: Equatable {
            let id: UUID, canvasID: UUID, header: String, version: Int, zIndex: Int64
            let deleted: Date?, textIndex: String, digest: String
        }
        struct Payload: Equatable {
            let id: UUID, canvasID: UUID, role: String, version: Int, digest: String, bytes: Data
        }
        let canvases: [Canvas], objects: [Object], payloads: [Payload]
    }

    private func records(in container: ModelContainer) throws -> Records {
        let context = ModelContext(container)
        return try Records(
            canvases: context.fetch(FetchDescriptor<DrawCanvasRecord>()).map {
                Records.Canvas(id: $0.id, name: $0.name, tags: $0.tagsJSON, created: $0.createdAt,
                               updated: $0.updatedAt, deleted: $0.deletedAt, thumbnailID: $0.thumbnailID,
                               thumbnailDark: $0.thumbnailDark, textIndex: $0.textIndex)
            },
            objects: context.fetch(FetchDescriptor<DrawObjectRecord>()).map {
                Records.Object(id: $0.id, canvasID: $0.canvasID, header: $0.header, version: $0.formatVersion,
                               zIndex: $0.zIndex, deleted: $0.deletedAt, textIndex: $0.textIndex, digest: $0.payloadDigest)
            },
            payloads: context.fetch(FetchDescriptor<DrawPayloadRecord>()).map {
                Records.Payload(id: $0.id, canvasID: $0.canvasID, role: $0.role, version: $0.formatVersion,
                                digest: $0.digest, bytes: $0.bytes)
            })
    }

    func testPersistedStrokeReopensAndExportsWithoutChangingRecords() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let writer = DrawPersistentStore(container: container)
        let board = writer.create(name: "Synthetic board")
        let stroke = DrawObject(content: .stroke([DrawPoint(x: 10, y: 15), DrawPoint(x: 90, y: 70)]))
        XCTAssertTrue(writer.perform(.put([stroke]), on: board.id).isSaved)

        let before = try records(in: container)
        XCTAssertEqual(before.canvases.count, 1)
        XCTAssertEqual(before.objects.count, 1)
        XCTAssertEqual(before.payloads.count, 1)
        // A new store opens through the repository's own fresh ModelContext.
        let reopened = try DrawPersistentStore(container: container).open(board.id)
        XCTAssertEqual(reopened.canvas.name, "Synthetic board")
        XCTAssertEqual(reopened.objects, [stroke])

        let png = try XCTUnwrap(DrawExport.render(reopened.objects, format: .png, dark: false))
        XCTAssertFalse(png.isEmpty)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        let pdf = try XCTUnwrap(DrawExport.render(reopened.objects, format: .pdf, dark: false))
        XCTAssertFalse(pdf.isEmpty)
        let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 1)
        let page = try XCTUnwrap(document.page(at: 1))
        XCTAssertGreaterThan(page.getBoxRect(.mediaBox).width, 0)
        XCTAssertGreaterThan(page.getBoxRect(.mediaBox).height, 0)
        XCTAssertEqual(try records(in: container), before)
    }

    func testSelectionHandlesUseEightPointsWithSpecializedTextAndLineHandles() throws {
        let shape = DrawObject(frame: DrawFrame(x: 10, y: 20, width: 80, height: 40),
                               content: .shape(.rectangle))
        let viewport = DrawViewport(x: 17, y: -25, zoom: 1.5)
        let spots = PhoneDrawSelectionGeometry.handles(for: [shape], in: viewport)
        XCTAssertEqual(spots.map { $0.handle }, [.topLeft, .top, .topRight, .left, .right,
                                                   .bottomLeft, .bottom, .bottomRight])

        let border = viewport.screen(try XCTUnwrap(DrawGeometry.union([shape]))).insetBy(dx: -4, dy: -4)
        let top = try XCTUnwrap(spots.first { $0.handle == .top })
        XCTAssertEqual(top.point.x, border.midX, accuracy: 0.001)
        XCTAssertEqual(top.point.y, border.minY, accuracy: 0.001)

        let text = DrawObject(frame: DrawFrame(x: 20, y: 30, width: 100, height: 18),
                              content: .text("Editable"))
        XCTAssertEqual(PhoneDrawSelectionGeometry.handles(for: [text], in: viewport).map { $0.handle },
                       [.left, .right])
        let line = DrawObject(frame: DrawGeometry.lineFrame(from: CGPoint(x: 80, y: 60),
                                                             to: CGPoint(x: 10, y: 90)),
                              content: .shape(.line))
        XCTAssertEqual(PhoneDrawSelectionGeometry.handles(for: [line], in: viewport).map { $0.handle },
                       [.start, .end])
    }

    func testSideResizeAnchorsOppositeEdgeAndGroupResizeKeepsProportions() {
        let shape = DrawObject(frame: DrawFrame(x: 10, y: 20, width: 80, height: 40),
                               content: .shape(.rectangle))
        let original = DrawGeometry.frame(shape.frame)
        let wider = PhoneDrawSelectionGeometry.resized([shape], handle: .left,
                                                       delta: CGPoint(x: -20, y: 0))[0]
        let widened = DrawGeometry.frame(wider.frame)
        XCTAssertGreaterThan(widened.width, original.width)
        XCTAssertEqual(widened.maxX, original.maxX, accuracy: 1)
        XCTAssertEqual(widened.height, original.height, accuracy: 0.001)

        let taller = PhoneDrawSelectionGeometry.resized([shape], handle: .top,
                                                        delta: CGPoint(x: 0, y: -10))[0]
        XCTAssertGreaterThan(taller.frame.height, shape.frame.height)
        XCTAssertEqual(taller.frame.width, shape.frame.width, accuracy: 0.001)
        XCTAssertEqual(DrawGeometry.frame(taller.frame).maxY, original.maxY, accuracy: 1)

        let second = DrawObject(frame: DrawFrame(x: 125, y: 42, width: 30, height: 20),
                                content: .shape(.ellipse))
        let group = PhoneDrawSelectionGeometry.resized([shape, second], handle: .right,
                                                       delta: CGPoint(x: 25, y: 0))
        let xScale = group[0].frame.width / shape.frame.width
        let yScale = group[0].frame.height / shape.frame.height
        XCTAssertGreaterThan(xScale, 1)
        XCTAssertEqual(xScale, yScale, accuracy: 0.001)
    }

    func testLineDirectionAndTextWidthSurviveResizeAndNoOpDoesNotMutateText() {
        let line = DrawObject(frame: DrawGeometry.lineFrame(from: CGPoint(x: 70, y: 10),
                                                             to: CGPoint(x: 15, y: 65)),
                              content: .shape(.arrow))
        let shorter = PhoneDrawSelectionGeometry.resized([line], handle: .start,
                                                         delta: CGPoint(x: -12, y: 9))[0]
        let (start, end) = DrawGeometry.endpoints(shorter.frame)
        XCTAssertEqual(start.x, 58, accuracy: 0.001)
        XCTAssertEqual(start.y, 19, accuracy: 0.001)
        XCTAssertEqual(end.x, 15, accuracy: 0.001)
        XCTAssertEqual(end.y, 65, accuracy: 0.001)
        XCTAssertLessThan(shorter.frame.width, 0)

        let text = DrawObject(frame: DrawFrame(x: 50, y: 70, width: 100, height: 18),
                              content: .text("A text box"))
        let resized = PhoneDrawSelectionGeometry.resized([text], handle: .right,
                                                         delta: CGPoint(x: 25, y: 0))[0]
        XCTAssertEqual(resized.textWidth, 125)
        XCTAssertEqual(resized.frame.x, text.frame.x)
        XCTAssertEqual(PhoneDrawSelectionGeometry.resized([text], handle: .bottomRight,
                                                          delta: .zero), [text])
    }

    func testAccessibleSelectionCyclesWithoutSkippingTheFirstOrLastObject() {
        let first = DrawObject(content: .shape(.ellipse))
        let second = DrawObject(content: .text("Second"))
        let third = DrawObject(content: .stroke([DrawPoint(x: 1, y: 2)]))
        let list = [first, second, third]
        XCTAssertNil(PhoneDrawSelectionGeometry.nextID(in: [], after: nil, forward: true))
        XCTAssertEqual(PhoneDrawSelectionGeometry.nextID(in: list, after: nil, forward: true), first.id)
        XCTAssertEqual(PhoneDrawSelectionGeometry.nextID(in: list, after: nil, forward: false), third.id)
        XCTAssertEqual(PhoneDrawSelectionGeometry.nextID(in: list, after: first.id, forward: false), third.id)
        XCTAssertEqual(PhoneDrawSelectionGeometry.nextID(in: list, after: third.id, forward: true), first.id)
        XCTAssertEqual(PhoneDrawSelectionGeometry.nextID(in: list, after: first.id, forward: true), second.id)
    }

    func testMovedAndResizedObjectsReopenFromTheStoreAndUndoExactly() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = DrawPersistentStore(container: container)
        let canvas = store.create(name: "Transform exchange")
        let shape = DrawObject(frame: DrawFrame(x: 10, y: 20, width: 80, height: 40),
                               zIndex: 0, content: .shape(.rectangle))
        let strokePoints = [DrawPoint(x: 120, y: 30), DrawPoint(x: 140, y: 90)]
        let ink = DrawObject(frame: DrawGeometry.strokeFrame(strokePoints), zIndex: 1,
                             content: .stroke(strokePoints))
        XCTAssertTrue(store.perform(.put([shape, ink]), on: canvas.id).isSaved)

        let resized = PhoneDrawSelectionGeometry.resized([shape, ink], handle: .bottomRight,
                                                         delta: CGPoint(x: 30, y: 15))
        XCTAssertNotEqual(resized, [shape, ink])
        XCTAssertTrue(store.perform(.put(resized), on: canvas.id).isSaved)
        let moved = resized.map { $0.translated(by: DrawPoint(x: -8, y: 12), id: $0.id) }
        XCTAssertTrue(store.perform(.put(moved), on: canvas.id).isSaved)

        func indexed(_ stored: [DrawObject]) -> [UUID: DrawObject] {
            Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        }
        let reopened = try DrawPersistentStore(container: container).open(canvas.id)
        XCTAssertEqual(indexed(reopened.objects), indexed(moved))

        XCTAssertTrue(store.undo(on: canvas.id).isSaved)
        let undone = try DrawPersistentStore(container: container).open(canvas.id)
        XCTAssertEqual(indexed(undone.objects), indexed(resized))

        XCTAssertTrue(store.redo(on: canvas.id).isSaved)
        XCTAssertEqual(indexed(try DrawPersistentStore(container: container).open(canvas.id).objects),
                       indexed(moved))
    }
}
