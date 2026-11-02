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
}
