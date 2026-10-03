import Foundation
import SwiftData
import XCTest
@testable import Attic

/// Blocking assertions, with explicit expected-failure negative controls.
/// CI supplies the two pinned f445310 sample arrays; candidate measurements
/// can never contribute to these ceilings. Raw CI numbers are frozen in the
/// slice report and this comment after extraction (not re-baselined on a fix).
@MainActor
final class CanvasCoreBudgetTests: XCTestCase {
    private func ceiling(_ name: String) throws -> (median: Double, maximum: Double) {
        guard let path = ProcessInfo.processInfo.environment["ATTIC_P4_CEILINGS"] else {
            if ProcessInfo.processInfo.environment["CI"] == "true" { XCTFail("P4 missing pinned ceilings") }
            // Historical LOCAL empty baseline only, never substituted for CI.
            switch name { case "save": return (0.895250, 3.624791)
            case "erase1000": return (0.271957, 0.344083)
            default: return (2.825167, 14.550625) }
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: [String: Double]]
        return (object[name]!["median"]!, object[name]!["maximum"]!)
    }
    private func check(_ values: [Double], _ name: String, label: String) throws {
        let limit = try ceiling(name)
        XCTAssertFalse(values.isEmpty, label)
        XCTAssertLessThanOrEqual(values.sorted()[values.count / 2], limit.median, "\(label) median")
        XCTAssertLessThanOrEqual(values.max()!, limit.maximum, "\(label) maximum")
    }
    func testP4CommitDeltaBudgetAbsoluteComposedGateAtEverySizeIncludingUndoRedo() throws {
        for count in [0, 2_000, 10_000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Budget-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try autoreleasepool {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let gate = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root.appendingPathComponent("journal")))
                let board = UUID(), seed = gate.freshContext()
                seed.insert(CanvasBoardItem(id: board))
                let legacy = Data(#"{"version":1,"color":"ink","width":3,"points":[{"x":0,"y":0}]}"#.utf8)
                for _ in 0..<count { seed.insert(CanvasStrokeItem(canvasID: board, payload: legacy)) }
                for _ in 0..<8 {
                    let note = NoteItem(body: String(repeating: "Unrelated", count: 8_000)); seed.insert(note)
                    seed.insert(TaskItem(title: "Unrelated"))
                }
                try seed.save()
                let writer = CanvasCoreWriter(gate: gate)
                try writer.capture([.init(entity: .board, id: board)])
                var saves: [Double] = [], adds: [Double] = [], undo: [Double] = [], redo: [Double] = []
                gate.save = { context in
                    XCTAssertFalse(context.autosaveEnabled)
                    let start = CFAbsoluteTimeGetCurrent(); try context.save()
                    saves.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                }
                let ink = CanvasCoreInk(color: "ink", width: 3, samples: (0..<400).map {
                    .init(x: Double($0) * 0.7, y: Double($0 % 7), time: UInt64($0 * 8_000), pressure: nil)
                })
                for _ in 0..<8 {
                    writer.resetCounters()
                    let start = CFAbsoluteTimeGetCurrent()
                    let patch = try CanvasCoreWriter.inkPatch(id: .init(canvasID: board, objectID: UUID()), ink: ink)
                    XCTAssertEqual(writer.perform(name: "Ink", patches: [patch]), .committed)
                    adds.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                    XCTAssertEqual(writer.counters.fetchedReplicas, 1, "P4CommitDeltaBudget: one scalar parent guard, no content scan")
                    XCTAssertEqual(writer.counters.changedReplicas, 1)
                    var t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.undo(), .committed)
                    undo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.redo(), .committed)
                    redo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                }
                try check(adds, "add", label: "P4CommitDeltaBudget N=\(count)")
                try check(undo, "add", label: "P4HistoryBudget Undo N=\(count)")
                try check(redo, "add", label: "P4HistoryBudget Redo N=\(count)")
                try check(saves, "save", label: "P4CommitDeltaBudget save N=\(count)")
                XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>()), 0)
                print("P4_CANDIDATE_JSON \(String(decoding: try JSONEncoder().encode(["N": [Double(count)], "add": adds, "save": saves, "undo": undo, "redo": redo]), as: UTF8.self))")
            }
        }
    }
    func testP4SpatialCandidateBudgetAbsoluteSparseEraserMissCeiling() throws {
        for count in [0, 2_000, 10_000] {
            let board = UUID(), entries = (0..<count).map { i in CanvasCoreMetadata(id: .init(canvasID: board, objectID: UUID()), kind: .stroke,
                bounds: .init(minX: Double(i * 10), minY: 0, maxX: Double(i * 10 + 2), maxY: 2), rank: Int64(i)) }
            let index = try CanvasCoreSpatialIndex(entries)
            let query = CanvasCoreBounds(minX: -100, minY: -100, maxX: -90, maxY: -90)
            var elapsed: [Double] = []
            for _ in 0..<12 {
                let start = CFAbsoluteTimeGetCurrent(); var hits = 0
                for _ in 0..<1_000 { hits += index.query(query).count }
                elapsed.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                XCTAssertEqual(hits, 0); XCTAssertEqual(index.lastQueryNodes, 1)
            }
            try check(elapsed, "erase1000", label: "P4SpatialCandidateBudget N=\(count)")
        }
    }
    func testP4NegativeControlFixedCommitDelayMustFailAbsoluteCeiling() throws {
        let limit = try ceiling("add")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Delay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let gate = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root.appendingPathComponent("journal")))
        gate.save = { context in
            Thread.sleep(forTimeInterval: (limit.median + 2) / 1_000)
            try context.save()
        }
        let writer = CanvasCoreWriter(gate: gate), creation = CanvasCoreCreation()
        let ink = CanvasCoreInk(color: "ink", width: 3, samples: [.init(x: 0, y: 0, time: 0, pressure: nil)])
        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertEqual(writer.perform(name: "Delayed commit", patches: try creation.firstInk(ink)), .committed)
        let delayed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        XCTExpectFailure("P4CommitDeltaBudget negative control: fixed extra delay", options: .init())
        XCTAssertLessThanOrEqual(delayed, limit.median, "P4CommitDeltaBudget negative fixed delay")
    }
    func testP4NegativeControlFullBoardFetchMustFailChangedReplicaBound() throws {
        let container = try ModelContainer(for: CanvasStrokeItem.self, configurations: .init(isStoredInMemoryOnly: true))
        let context = ModelContext(container); context.autosaveEnabled = false
        for _ in 0..<200 { context.insert(CanvasStrokeItem()) }; try context.save()
        let fetched = try ModelContext(container).fetch(FetchDescriptor<CanvasStrokeItem>())
        XCTExpectFailure("P4CommitDeltaBudget negative control: full-board fetch", options: .init())
        XCTAssertLessThanOrEqual(fetched.count, 1, "P4CommitDeltaBudget changed-only bound")
    }
    func testP4NegativeControlSampleDropMustFailLosslessContract() {
        let supplied = (0..<24_001).map { CanvasCoreSample(x: Double($0), y: 0, time: UInt64($0), pressure: nil) }
        let dropped = Array(supplied.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
        XCTExpectFailure("P4InputSampleBudget negative control: thinning", options: .init())
        XCTAssertEqual(dropped.count, supplied.count, "P4InputSampleBudget no thinning")
    }
}
