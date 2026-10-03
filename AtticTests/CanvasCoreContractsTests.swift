import Foundation
import XCTest
@testable import Attic

final class CanvasCoreContractsTests: XCTestCase {
    private let board = UUID()
    private func item(_ x: Double, _ y: Double = 0, kind: CanvasCoreKind = .stroke, rank: Int64 = 0) -> CanvasCoreMetadata {
        .init(id: .init(canvasID: board, objectID: UUID()), kind: kind,
            bounds: .init(minX: x, minY: y, maxX: x + 2, maxY: y + 2), rank: rank)
    }
    func testP4CommandCatalogBudgetAllRoutesUseTheSameScalarReasons() {
        var context = CanvasCoreCommandContext(); context.installed = Set(CanvasCoreCommand.allCases)
        XCTAssertEqual(Set(CanvasCoreCommandCatalog.entries.map(\.id)).count, CanvasCoreCommand.allCases.count)
        XCTAssertFalse(CanvasCoreCommandCatalog.entries.contains { $0.id.rawValue.lowercased().contains("clear") })
        for command in CanvasCoreCommand.allCases {
            let reasons = CanvasCoreRoute.allCases.map { CanvasCoreCommandCatalog.validate(command, context: context, route: $0).reason }
            XCTAssertTrue(reasons.allSatisfy { $0 == reasons[0] }, "P4CommandCatalogBudget \(command)")
        }
        XCTAssertTrue(CanvasCoreCommandCatalog.validate(.delete, context: context, route: .shortcut).consumeShortcut)
        context.nativeTyping = true
        XCTAssertFalse(CanvasCoreCommandCatalog.validate(.pen, context: context, route: .shortcut).enabled)
        XCTAssertFalse(CanvasCoreCommandCatalog.validate(.undo, context: context, route: .shortcut).consumeShortcut)
        context.markedText = true
        XCTAssertEqual(CanvasCoreCommandCatalog.validate(.fit, context: context, route: .menu).reason, "Finish text composition first")
        context.nativeTyping = false; context.markedText = false; context.readOnly = true
        XCTAssertFalse(CanvasCoreCommandCatalog.validate(.pen, context: context, route: .external).enabled)
        context.readOnly = false; context.unresolvedSave = true
        XCTAssertFalse(CanvasCoreCommandCatalog.validate(.paste, context: context, route: .menu).enabled)
        context.unresolvedSave = false; context.installed.remove(.paste)
        XCTAssertEqual(CanvasCoreCommandCatalog.validate(.paste, context: context, route: .menu).reason, "This command is not available yet")
    }
    func testP4SelectionAllKindsShiftToggleMarqueeAndTopmost() throws {
        let values = CanvasCoreKind.allCases.enumerated().map { item(0, kind: $1, rank: Int64($0)) }
        let index = try CanvasCoreSpatialIndex(values)
        XCTAssertEqual(index.topmost(in: values[0].bounds, exact: { _ in true })?.kind, .image)
        var selection = CanvasCoreSelection()
        selection.selectAll(values); XCTAssertEqual(selection.ids.count, 4)
        selection.click(values[0].id, extending: true); XCTAssertEqual(selection.ids.count, 3)
        selection.click(values[0].id, extending: true); XCTAssertEqual(selection.ids.count, 4)
        selection.marquee(index.query(values[0].bounds), extending: false, exactIntersection: { $0.kind == .text || $0.kind == .stroke })
        XCTAssertEqual(selection.ids, Set(values.prefix(2).map(\.id)))
        selection.click(nil, extending: false); XCTAssertTrue(selection.ids.isEmpty)
    }
    func testP4SpatialCandidateBudgetSTRMatchesExhaustiveOracleOnSparseAndTotalOverlap() throws {
        for overlapping in [false, true] {
            let values = (0..<2_000).map { item(overlapping ? 0 : Double($0 * 50), Double($0 % 5)) }
            let index = try CanvasCoreSpatialIndex(values)
            XCTAssertTrue(index.structurallyValid())
            for i in 0..<80 {
                let query = CanvasCoreBounds(minX: Double(i * 700), minY: -5, maxX: Double(i * 700 + 60), maxY: 20)
                XCTAssertEqual(Set(index.query(query).map(\.id)), Set(values.filter { $0.bounds.intersects(query) }.map(\.id)), "P4SpatialCandidateBudget")
            }
            if overlapping { XCTAssertEqual(index.query(values[0].bounds.inflated(10)).count, 2_000) }
            else { XCTAssertTrue(index.query(.init(minX: -100, minY: -100, maxX: -90, maxY: -90)).isEmpty); XCTAssertEqual(index.lastQueryNodes, 1) }
        }
    }
    func testP4IndexDeltaBudgetOrderedInsertMoveDeleteKeepsBalanceAndExactOracle() throws {
        let index = try CanvasCoreSpatialIndex()
        var values: [CanvasCoreMetadata] = []
        for i in 0..<2_000 {
            let value = item(Double(i * 10)); values.append(value); try index.update(value)
        }
        XCTAssertTrue(index.structurallyValid()); XCTAssertLessThanOrEqual(index.height, 6)
        for i in stride(from: 0, to: values.count, by: 19) {
            values[i].bounds = .init(minX: -Double(i), minY: -20, maxX: 0, maxY: -10)
            try index.update(values[i]); XCTAssertLessThan(index.lastMutationNodes, 200, "P4IndexDeltaBudget")
            XCTAssertTrue(index.structurallyValid())
        }
        for i in stride(from: values.count - 1, through: 0, by: -3) { index.remove(values[i].id); values.remove(at: i) }
        XCTAssertTrue(index.structurallyValid()); XCTAssertEqual(index.count, values.count)
        for i in 0..<100 {
            let query = CanvasCoreBounds(minX: Double(i * 100), minY: -30, maxX: Double(i * 100 + 100), maxY: 10)
            XCTAssertEqual(Set(index.query(query).map(\.id)), Set(values.filter { $0.bounds.intersects(query) }.map(\.id)))
        }
        for value in values { index.remove(value.id) }
        XCTAssertEqual(index.count, 0); XCTAssertTrue(index.structurallyValid())
    }
    func testP4SpatialExtremeLongBoundsAndInvalidUpdatesPreserveOldEntry() throws {
        var value = item(-1e14); value.bounds.maxX = 1e14
        let index = try CanvasCoreSpatialIndex([value])
        XCTAssertEqual(index.query(.init(minX: 0, minY: 0, maxX: 1, maxY: 1)).count, 1)
        value.bounds.minX = .nan
        XCTAssertThrowsError(try index.update(value)); XCTAssertEqual(index.count, 1)
        XCTAssertThrowsError(try CanvasCoreSpatialIndex([item(0), value]))
    }
    func testP4AccessibilityBudgetClustersAreTransitiveStableAndCached() throws {
        let a = item(0), b = item(9), c = item(18), d = item(100), text = item(5, -10, kind: .text)
        var values = [d, c, text, b, a]
        let index = try CanvasCoreSpatialIndex(values), order = CanvasCoreReadingOrder()
        order.refresh(values, index: index)
        XCTAssertEqual(order.stops.first, .object(text.id))
        XCTAssertEqual(Set(order.enter(1)), [a.id, b.id, c.id])
        XCTAssertEqual(order.exitDrawing(c.id), 1)
        for _ in 0..<100 { order.refresh(values.reversed(), index: index); _ = order.enter(1) }
        XCTAssertEqual(order.rebuilds, 1, "P4AccessibilityBudget: repeated query/pan/selection cannot rebuild")
        values[1].bounds = .init(minX: 200, minY: 0, maxX: 202, maxY: 2)
        try index.update(values[1]); order.refresh(values, index: index)
        XCTAssertEqual(order.rebuilds, 2)
    }
    func testP4InputSampleBudgetPreservesOver24000SamplesAndStationaryPressure() {
        var reducer = CanvasCoreInputReducer()
        _ = reducer.reduce(.begin(.ink, 1, .init(x: 3, y: 5, scale: 2)))
        let samples = (0..<24_001).map { CanvasCoreSample(x: Double($0 / 3), y: 7, time: UInt64($0), pressure: Double($0 % 3) / 2) }
        for (i, sample) in samples.enumerated() {
            _ = reducer.reduce(.sample(.init(device: 4, sequence: 1, event: UInt64(i)), sample))
        }
        _ = reducer.reduce(.space); _ = reducer.reduce(.incidentalGesture(2))
        XCTAssertEqual(reducer.samples, samples); XCTAssertEqual(reducer.mode, .ink)
        XCTAssertEqual(reducer.frozenViewport.scale, 2); XCTAssertTrue(reducer.deferredPan)
        let effects = reducer.reduce(.end(1))
        guard case let .commit(id, saved) = effects.first else { return XCTFail("P4InputSampleBudget missing commit") }
        XCTAssertEqual(saved, samples)
        XCTAssertTrue(reducer.reduce(.interrupt).isEmpty)
        _ = reducer.reduce(.saveResolved(false))
        XCTAssertEqual(reducer.reduce(.retry), [.commit(id, samples)])
        XCTAssertEqual(reducer.reduce(.begin(.ink, 3, .init())), [.refuse])
        _ = reducer.reduce(.saveResolved(true)); XCTAssertTrue(reducer.samples.isEmpty)
        _ = reducer.reduce(.begin(.ink, 3, .init()))
        _ = reducer.reduce(.gestureEnd(2)); XCTAssertEqual(reducer.mode, .ink)
    }
    func testP4InputSampleBudgetCapCommitsOnceAndSuppressesTailUntilUp() {
        var reducer = CanvasCoreInputReducer(); _ = reducer.reduce(.begin(.ink, 7, .init()))
        var commits = 0
        for i in 0..<CanvasCoreInkCodec.maximumSamples + 100 {
            let effects = reducer.reduce(.sample(.init(device: 1, sequence: 7, event: UInt64(i)),
                .init(x: Double(i), y: 0, time: UInt64(i), pressure: nil)))
            commits += effects.filter { if case .commit = $0 { return true }; return false }.count
        }
        XCTAssertEqual(commits, 1); XCTAssertEqual(reducer.samples.count, 81_000)
        _ = reducer.reduce(.saveResolved(true)); XCTAssertEqual(reducer.reduce(.begin(.ink, 7, .init())), [.refuse])
        _ = reducer.reduce(.end(7)); XCTAssertTrue(reducer.reduce(.begin(.ink, 8, .init())).isEmpty)
    }
    func testP4InkCodecCapRoundtripEscapesTimeAndPressureWithoutDroppingSamples() throws {
        let samples = (0..<81_000).map { i in CanvasCoreSample(x: Double(i) * 0.25, y: -3,
            time: UInt64(i) * 70_000, pressure: i % 2 == 0 ? 0.5 : nil) }
        let ink = CanvasCoreInk(color: "red", width: 3, samples: samples)
        XCTAssertEqual(try CanvasCoreInkCodec.decode(CanvasCoreInkCodec.encode(ink)), ink)
        var over = ink; over.samples.append(samples.last!)
        XCTAssertThrowsError(try CanvasCoreInkCodec.encode(over))
        var bad = ink; bad.samples = [.init(x: 1e14 + 0.1, y: 0, time: 0, pressure: nil)]
        XCTAssertThrowsError(try CanvasCoreInkCodec.encode(bad))
        bad.samples = [.init(x: 0, y: 0, time: 0, pressure: .nan)]
        XCTAssertThrowsError(try CanvasCoreInkCodec.encode(bad))
    }
    func testP4InkCodecRejectsEveryTruncationUnknownFlagsAndOverflowWithoutRewritingLegacy() throws {
        let bytes = try CanvasCoreInkCodec.encode(.init(color: "ink", width: 3,
            samples: [.init(x: 1, y: 2, time: UInt64.max, pressure: 1)]))
        for i in 0..<bytes.count { XCTAssertThrowsError(try CanvasCoreInkCodec.decode(bytes.prefix(i))) }
        var unknown = bytes; unknown[4] = 99; XCTAssertThrowsError(try CanvasCoreInkCodec.decode(unknown))
        unknown = bytes; unknown[6] = 1; XCTAssertThrowsError(try CanvasCoreInkCodec.decode(unknown))
        unknown = bytes; unknown.append(0); XCTAssertThrowsError(try CanvasCoreInkCodec.decode(unknown))
        let legacy = Data(#"{"version":1,"color":"blue","width":3,"points":[{"x":1,"y":2}]}"#.utf8)
        let decoded = try CanvasCoreInkCodec.decodeLegacy(legacy)
        XCTAssertEqual(decoded.samples.first?.x, 1); XCTAssertEqual(decoded.color, "blue")
        XCTAssertEqual(legacy, Data(#"{"version":1,"color":"blue","width":3,"points":[{"x":1,"y":2}]}"#.utf8))
    }
    func testP4TextBudgetLegacyAppearanceWrapSizesUnicodeAndConditionalCorners() throws {
        let bytes = Data(#"{"text":"é🙂\n\n","color":"ink","strokeWidth":3,"fontSize":37,"fontWeight":"bold","alignment":"right","futureStyle":99}"#.utf8)
        var text = try CanvasCoreSemanticContract.decode(bytes)
        XCTAssertEqual(text.resolvedFontSize, 37); XCTAssertNil(text.wrapWidth)
        XCTAssertEqual(text.text, "é🙂\n\n")
        for size in CanvasCoreSemanticContract.Size.allCases {
            text.size = size; text.wrapWidth = 120
            XCTAssertEqual(try CanvasCoreSemanticContract.decode(text.encode()), text)
            XCTAssertEqual(text.resolvedFontSize, size.points)
        }
        text.wrapWidth = .nan; XCTAssertThrowsError(try text.encode())
        var rectangle = try CanvasCoreSemanticContract.decode(Data(#"{"shape":"rectangle","color":"ink","strokeWidth":3}"#.utf8))
        XCTAssertEqual(rectangle.resolvedCornerRadius, 0)
        rectangle.rounded = true; XCTAssertEqual(rectangle.resolvedCornerRadius, 8)
        rectangle.shape = "ellipse"; XCTAssertThrowsError(try rectangle.encode())
        XCTAssertThrowsError(try CanvasCoreSemanticContract.decode(Data(#"{"text":"a","color":"ink","strokeWidth":3,"size":"future"}"#.utf8)))
    }
}
