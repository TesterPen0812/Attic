import Foundation
import XCTest
@testable import Attic

final class CanvasRenderCacheTests: XCTestCase {
    func testFreshRenderTokenInvalidatesCacheWithoutChangingStrokeSemantics() {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let first = CanvasStroke(
            id: id,
            renderToken: UUID(),
            color: .blue,
            width: 4,
            points: [CanvasPoint(x: 1, y: 2)],
            createdAt: timestamp
        )
        let second = CanvasStroke(
            id: id,
            renderToken: UUID(),
            color: .blue,
            width: 4,
            points: [CanvasPoint(x: 1, y: 2)],
            createdAt: timestamp
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first.renderKey, second.renderKey)
    }
}
