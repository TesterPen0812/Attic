import Foundation
import SwiftData
import XCTest
@testable import Attic

/// Deliberately uses the pinned production editor, not the candidate core.
/// CI archives f445310 and copies only this measurement test into that archive.
/// Upper-middle median = sorted[count/2]. Two independent CI runs freeze
/// ceiling = max(run medians) + abs(run median difference), likewise maxima.
/// Raw samples and runner/configuration identity are retained in the report.
@MainActor
final class CanvasCoreReferenceTests: XCTestCase {
    func testPinnedEmptyProductionReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Reference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let seed = ModelContext(container); seed.autosaveEnabled = false
        seed.insert(CanvasBoardItem()); try seed.save()
        var saves: [Double] = []
        let store = CanvasStore(container: container, persist: { context in
            let start = CFAbsoluteTimeGetCurrent(); try context.save()
            saves.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        })
        saves.removeAll()
        let points = (0..<400).map { CanvasPoint(x: Double($0) * 0.7, y: Double($0 % 7)) }
        var adds: [Double] = []
        for _ in 0..<8 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertNotNil(store.addStroke(color: .ink, width: 3, points: points))
            adds.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        var erases: [Double] = []
        for _ in 0..<12 {
            let start = CFAbsoluteTimeGetCurrent()
            var hits = 0
            for _ in 0..<1_000 {
                hits += CanvasHitTesting.strokeIDs(hitBy: [CanvasPoint(x: -100, y: -100)],
                    radius: 3, strokes: []).count
            }
            erases.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            XCTAssertEqual(hits, 0)
        }
        XCTAssertEqual(saves.count, 8)
        let samples = ["add": adds, "save": saves, "erase1000": erases]
        let data = try JSONEncoder().encode(samples)
        print("P4_REFERENCE_JSON \(String(decoding: data, as: UTF8.self))")
    }
}
