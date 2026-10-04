import Foundation
import SwiftData
import XCTest
@testable import Attic

/// Blocking assertions and strict expected-failure negative controls.
/// Frozen before candidate validation from baseline f4453108301a0d902235b0f4f8985a43b8a8b3d9.
/// References A=37161257397, B=37162377198: macos-26, Xcode 26.6,
/// Local -O/wholemodule, ENABLE_TESTABILITY=YES; identical reference host.
/// Upper-middle median = sorted[count/2]. Each ceiling is max(A,B)+abs(A-B).
/// Raw ordered samples (ms); candidate samples never change these values.
/// add A: [46.71204090118408, 7.165074348449707, 15.606045722961426, 11.5889310836792, 12.022972106933594, 6.494045257568359, 8.839964866638184, 11.821985244750977]
/// add B: [30.04300594329834, 13.35608959197998, 10.113954544067383, 13.135910034179688, 13.89610767364502, 12.158989906311035, 9.866952896118164, 7.767915725708008]
/// add median: max(11.821985244750977, 13.135910034179688) + abs(11.821985244750977 - 13.135910034179688) = 14.449834823608398.
/// add maximum: max(46.71204090118408, 30.04300594329834) + abs(46.71204090118408 - 30.04300594329834) = 63.381075859069824.
/// save A: [1.6570091247558594, 1.0339021682739258, 3.091096878051758, 1.031041145324707, 0.9270906448364258, 0.9380578994750977, 1.0489225387573242, 2.474069595336914]
/// save B: [5.856037139892578, 2.4950504302978516, 2.195000648498535, 2.9469728469848633, 3.515005111694336, 1.5690326690673828, 1.0689496994018555, 0.9859800338745117]
/// save median: max(1.0489225387573242, 2.4950504302978516) + abs(1.0489225387573242 - 2.4950504302978516) = 3.941178321838379.
/// save maximum: max(3.091096878051758, 5.856037139892578) + abs(3.091096878051758 - 5.856037139892578) = 8.620977401733398.
/// erase1000 A: [0.6049871444702148, 0.4210472106933594, 0.15497207641601562, 0.20599365234375, 0.15604496002197266, 0.15103816986083984, 0.15401840209960938, 0.15497207641601562, 0.15497207641601562, 0.15306472778320312, 0.1569986343383789, 0.15604496002197266]
/// erase1000 B: [0.1819133758544922, 0.14400482177734375, 0.14197826385498047, 0.1499652862548828, 0.13697147369384766, 0.1380443572998047, 0.13899803161621094, 0.16200542449951172, 0.1779794692993164, 0.13494491577148438, 0.1329183578491211, 0.15795230865478516]
/// erase1000 median: max(0.15604496002197266, 0.14400482177734375) + abs(0.15604496002197266 - 0.14400482177734375) = 0.16808509826660156.
/// erase1000 maximum: max(0.6049871444702148, 0.1819133758544922) + abs(0.6049871444702148 - 0.1819133758544922) = 1.0280609130859375.
@MainActor
final class CanvasCoreBudgetTests: XCTestCase {
    private func ceiling(_ name: String) throws -> (median: Double, maximum: Double) {
        switch name {
        case "add": return (14.449834823608398, 63.381075859069824)
        case "save": return (3.941178321838379, 8.620977401733398)
        case "erase1000": return (0.16808509826660156, 1.0280609130859375)
        default: throw CanvasCoreError.invalidPayload
        }
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
                    seed.insert(NoteAttachment(noteID: note.id, originalFilename: "unrelated.bin", byteCount: 65_536,
                        sortIndex: 0, contentDigest: "fixture", payload: Data(repeating: 7, count: 65_536)))
                }
                try seed.save()
                let writer = CanvasCoreWriter(gate: gate)
                try writer.capture([.init(entity: .board, id: board)])
                var saves: [Double] = [], adds: [Double] = [], undo: [Double] = [], redo: [Double] = []
                var moves: [Double] = [], deletes: [Double] = [], texts: [Double] = []
                WorkspacePayloadAccess.counts = [:]
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
                    XCTAssertEqual(writer.counters.changedReplicas, 2, "P4CommitDeltaBudget: stroke plus its one external payload row")
                    var t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.undo(), .committed)
                    undo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.redo(), .committed)
                    redo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    let move = CanvasCorePatch(owner: patch.owner, canvasID: board,
                        fields: ["offsetX": try WorkspaceModelFields.encode(40.0)])
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.perform(name: "Move", patches: [move]), .committed)
                    moves.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.undo(), .committed)
                    undo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.redo(), .committed)
                    redo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    let deletion = CanvasCorePatch(owner: patch.owner, canvasID: board,
                        fields: ["tombstoned": try WorkspaceModelFields.encode(true), "deletedAt": try WorkspaceModelFields.encode(Optional(Date()))])
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.perform(name: "Delete", patches: [deletion]), .committed)
                    deletes.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.undo(), .committed)
                    undo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    t = CFAbsoluteTimeGetCurrent(); XCTAssertEqual(writer.redo(), .committed)
                    redo.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                    t = CFAbsoluteTimeGetCurrent()
                    let text = try CanvasCoreSemanticContract.decode(Data(#"{"text":"Changed🙂\n","color":"ink","strokeWidth":3,"fontSize":24}"#.utf8))
                    let textPatch = try CanvasCoreWriter.semanticPatch(id: .init(canvasID: board, objectID: UUID()), content: text,
                        bounds: .init(minX: 0, minY: 0, maxX: 160, maxY: 48), inserting: true)
                    XCTAssertEqual(writer.perform(name: "Text", patches: [textPatch]), .committed)
                    texts.append((CFAbsoluteTimeGetCurrent() - t) * 1_000)
                }
                XCTAssertEqual(WorkspacePayloadAccess.counts.values.reduce(0, +), 0, "P4CommitDeltaBudget: unrelated original bytes remain unopened")
                print("P4_CANDIDATE_JSON \(String(decoding: try JSONEncoder().encode(["N": [Double(count)], "add": adds, "save": saves, "undo": undo, "redo": redo, "move": moves, "delete": deletes, "text": texts]), as: UTF8.self))")
                try check(moves, "add", label: "P4CommitDeltaBudget move N=\(count)")
                try check(deletes, "add", label: "P4CommitDeltaBudget delete N=\(count)")
                try check(texts, "add", label: "P4TextBudget N=\(count)")
                try check(adds, "add", label: "P4CommitDeltaBudget N=\(count)")
                try check(undo, "add", label: "P4HistoryBudget Undo N=\(count)")
                try check(redo, "add", label: "P4HistoryBudget Redo N=\(count)")
                try check(saves, "save", label: "P4CommitDeltaBudget save N=\(count)")
                XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>()), 0)
            }
        }
    }
    func testP4InputSampleBudgetAdmissionCapMainThreadCompletionWithinOneFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("P4Cap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let gate = try WorkspaceOperationCoordinator(container: container, journal: NoteDraftJournal(directory: root.appendingPathComponent("journal")))
        let board = UUID(), seed = gate.freshContext()
        seed.insert(CanvasBoardItem(id: board)); try seed.save()
        let writer = CanvasCoreWriter(gate: gate); try writer.capture([.init(entity: .board, id: board)])
        let samples: [CanvasCoreSample] = (0..<CanvasCoreInkCodec.maximumSamples).map { i in
            let x = Double(i % 1000) * 0.5, y = Double(i % 7)
            let time = UInt64(i * 8_000), pressure = Double(i % 1025) / 1024.0
            return .init(x: x, y: y, time: time, pressure: pressure)
        }
        let ink = CanvasCoreInk(color: "ink", width: 3, samples: samples)
        var totals: [Double] = [], encode: [Double] = [], commit: [Double] = []
        for _ in 0..<8 {
            let start = CFAbsoluteTimeGetCurrent()
            let patch = try await CanvasCoreWriter.preparedAdmissionCapInkPatch(id: .init(canvasID: board, objectID: UUID()), ink: ink)
            let prepared = CFAbsoluteTimeGetCurrent()
            XCTAssertEqual(writer.perform(name: "Cap ink", patches: [patch]), .committed)
            let end = CFAbsoluteTimeGetCurrent()
            totals.append((end - start) * 1000); encode.append((prepared - start) * 1000); commit.append((end - prepared) * 1000)
        }
        print("P4_CAP_JSON \(String(decoding: try JSONEncoder().encode(["total": totals, "encode": encode, "commit": commit]), as: UTF8.self))")
        // The synchronous cap path was measured at 12.7–16.6 ms and then
        // 7.5–10.6 ms after removing base64/bounds copies. §3.5 explicitly
        // permits off-main encoding for this exceptional gesture. Gate the
        // actual blocking completion (cold save included); preserve the full
        // preparation + completion wall time above, never call it an 8.33 ms
        // end-to-end or presented-frame pass.
        XCTAssertLessThanOrEqual(commit.max()!, 1000.0 / 120, "P4InputSampleBudget: cap main-thread composed completion is within one 120 Hz frame")
        let rows = try ModelContext(container).fetch(FetchDescriptor<CanvasInkPayloadItem>())
        XCTAssertEqual(rows.count, 8)
        for row in rows { XCTAssertEqual(try CanvasCoreInkCodec.decode(row.bytes).samples, ink.samples) }
    }
    func testP4SpatialCandidateBudgetAbsoluteSparseEraserMissCeiling() throws {
        for count in [0, 2_000, 10_000] {
            let board = UUID()
            let entries: [CanvasCoreMetadata] = (0..<count).map { i in
                let bounds = CanvasCoreBounds(minX: Double(i * 10), minY: 0, maxX: Double(i * 10 + 2), maxY: 2)
                let id = CanvasCoreID(canvasID: board, objectID: UUID())
                return CanvasCoreMetadata(id: id, kind: .stroke, bounds: bounds, rank: Int64(i))
            }
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
