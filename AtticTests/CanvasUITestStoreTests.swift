import Foundation
import SwiftData
import XCTest
@testable import Attic

final class CanvasUITestStoreTests: XCTestCase {
    @MainActor
    func testUITestStorePersistsAcrossReopenAndResetRemovesOnlyItsRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let container = try PersistenceController.makeCanvasUITestContainer(
                reset: true,
                baseDirectory: root
            )
            let context = ModelContext(container)
            context.insert(CanvasStrokeItem(
                payloadVersion: CanvasStrokeCodec.currentVersion,
                payload: try CanvasStrokeCodec.encode(
                    color: .ink,
                    width: 3,
                    points: [CanvasPoint(x: 1, y: 2)]
                )
            ))
            try context.save()
        }

        do {
            let container = try PersistenceController.makeCanvasUITestContainer(
                reset: false,
                baseDirectory: root
            )
            let context = ModelContext(container)
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<CanvasStrokeItem>()),
                1
            )
        }

        do {
            let container = try PersistenceController.makeCanvasUITestContainer(
                reset: true,
                baseDirectory: root
            )
            let context = ModelContext(container)
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<CanvasStrokeItem>()),
                0
            )
        }
    }
}
