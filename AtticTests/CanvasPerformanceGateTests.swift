import AppKit
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// Reproducible performance gates for the Canvas repairs tracked as
/// CANVAS-016/PERF-08, CANVAS-017/PERF-09, CANVAS-018/PERF-10,
/// CANVAS-010/PERF-11, PERF-007/PERF-13 and PERF-A1.
///
/// Each gate pairs a timing `measure` with an exact counter assertion. The
/// counters are the real regression guard: wall-clock numbers on a shared
/// developer machine are noisy, while "did this path fault an image blob" or
/// "did this path rebuild accessibility elements" is a yes-or-no fact.
@MainActor
final class CanvasPerformanceGateTests: XCTestCase {
    private var temporaryStoreDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryStoreDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryStoreDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - CANVAS-016 / PERF-08

    func testStrokeSaveOnImageHeavyBoardDoesNotReadImageBytes() throws {
        let store = try makeOnDiskCanvasStore()
        try seedImages(count: 50, byteCount: 96 * 1024, in: store)
        XCTAssertEqual(store.images.count, 50)

        // Warm the presentation once so the measured save is the steady state.
        _ = store.addStroke(color: .ink, width: 3, points: strokePoints(offset: 0))

        var payloadReadsPerSave: [Int] = []
        measure(metrics: [XCTClockMetric()]) {
            CanvasImagePayloadAccessCounter.reset()
            _ = store.addStroke(
                color: .ink,
                width: 3,
                points: strokePoints(offset: Double(payloadReadsPerSave.count + 1))
            )
            payloadReadsPerSave.append(CanvasImagePayloadAccessCounter.count)
        }

        XCTAssertFalse(payloadReadsPerSave.isEmpty)
        XCTAssertEqual(
            payloadReadsPerSave.filter { $0 != 0 },
            [],
            "A stroke save must not fault any unchanged image payload."
        )
        XCTAssertEqual(store.images.count, 50)
    }

    func testChangedImageMaterialisesOnlyItsOwnBytes() throws {
        let store = try makeOnDiskCanvasStore()
        try seedImages(count: 12, byteCount: 32 * 1024, in: store)
        let target = try XCTUnwrap(store.images.first)

        CanvasImagePayloadAccessCounter.reset()
        let replacement = CanvasPreparedImage(
            encodedData: Data(repeating: 0x5A, count: 32 * 1024),
            contentType: UTType.png.identifier,
            pixelWidth: 40,
            pixelHeight: 40
        )
        XCTAssertNotNil(store.addImage(replacement, center: target.center, id: target.id))

        // Only the replaced row is new content. Eleven unchanged images must
        // stay untouched, so a handful of reads for the one changed row is the
        // whole cost of the save.
        XCTAssertLessThanOrEqual(
            CanvasImagePayloadAccessCounter.count,
            2,
            "Only the changed image may be materialised during a resolve."
        )
        XCTAssertEqual(store.images.count, 12)
        XCTAssertEqual(
            store.images.first { $0.id == target.id }?.encodedData,
            replacement.encodedData
        )
    }

    func testTransformOnlySaveDoesNotTouchImagePayloads() throws {
        let store = try makeOnDiskCanvasStore()
        try seedImages(count: 8, byteCount: 64 * 1024, in: store)
        let target = try XCTUnwrap(store.images.first)

        CanvasImagePayloadAccessCounter.reset()
        var moved = target.transform
        moved.center = CanvasPoint(x: moved.center.x + 24, y: moved.center.y + 24)
        XCTAssertTrue(store.updateImage(target.id, transform: moved))

        XCTAssertEqual(
            CanvasImagePayloadAccessCounter.count,
            0,
            "Moving an image must not fault or rewrite any encoded payload."
        )
        let updated = try XCTUnwrap(store.images.first { $0.id == target.id })
        XCTAssertEqual(updated.center.x, moved.center.x)
        XCTAssertEqual(updated.encodedByteCount, 64 * 1024)
    }

    func testTransformOnlySaveMeasuresImageHeavyBoardCost() throws {
        let store = try makeOnDiskCanvasStore()
        try seedImages(count: 50, byteCount: 96 * 1024, in: store)
        let target = try XCTUnwrap(store.images.first)
        var offset = 0.0
        var payloadReads: [Int] = []
        measure(metrics: [XCTClockMetric()]) {
            CanvasImagePayloadAccessCounter.reset()
            offset += 1
            var moved = target.transform
            moved.center = CanvasPoint(x: moved.center.x + offset, y: moved.center.y)
            _ = store.updateImage(target.id, transform: moved)
            payloadReads.append(CanvasImagePayloadAccessCounter.count)
        }
        XCTAssertEqual(payloadReads.filter { $0 != 0 }, [])
    }

    func testLegacyImageRowsAreBackfilledWithScalarPayloadMetadata() throws {
        let store = try makeOnDiskCanvasStore()
        try seedImages(count: 3, byteCount: 4 * 1024, in: store)

        // Simulate rows written before the scalar columns existed.
        let context = ModelContext(store.container)
        let legacyRows = try context.fetch(FetchDescriptor<CanvasImageItem>())
        XCTAssertEqual(legacyRows.count, 3)
        for row in legacyRows {
            row.encodedByteCount = 0
            row.contentDigest = ""
        }
        try context.save()

        store.refresh()
        let refreshed = try ModelContext(store.container)
            .fetch(FetchDescriptor<CanvasImageItem>())
        XCTAssertEqual(refreshed.count, 3)
        for row in refreshed {
            XCTAssertEqual(row.encodedByteCount, Int64(4 * 1024))
            XCTAssertFalse(row.contentDigest.isEmpty)
        }

        // Once backfilled, saves stop reading payloads again.
        CanvasImagePayloadAccessCounter.reset()
        _ = store.addStroke(color: .ink, width: 3, points: strokePoints(offset: 4))
        XCTAssertEqual(CanvasImagePayloadAccessCounter.count, 0)
        XCTAssertEqual(store.images.count, 3)
    }

    func testBackfillLeavesReplicaResolutionFieldsAlone() throws {
        let store = try makeOnDiskCanvasStore()
        try seedImages(count: 1, byteCount: 2 * 1024, in: store)
        let context = ModelContext(store.container)
        let row = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CanvasImageItem>()).first
        )
        let mutationVersion = row.mutationVersion
        let updatedAt = row.updatedAt
        let boardGeneration = row.boardGeneration
        row.encodedByteCount = 0
        row.contentDigest = ""
        try context.save()

        store.refresh()
        let refreshed = try XCTUnwrap(
            try ModelContext(store.container)
                .fetch(FetchDescriptor<CanvasImageItem>()).first
        )
        XCTAssertEqual(refreshed.mutationVersion, mutationVersion)
        XCTAssertEqual(refreshed.updatedAt, updatedAt)
        XCTAssertEqual(refreshed.boardGeneration, boardGeneration)
        XCTAssertFalse(refreshed.tombstoned)
    }

    // MARK: - CANVAS-017 / PERF-09

    func testViewportOnlyConfigureDoesNotRebuildAccessibilityElements() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let strokes = makeStrokes(count: 400)
        let images = makeImages(count: 100)
        view.configure(
            canvasID: view.canvasID,
            strokes: strokes,
            images: images,
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(center: .zero, scale: 1),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        // An accessibility client engaging is what makes the elements exist.
        _ = view.accessibilityChildren()
        let rebuildsBefore = view.accessibilityRebuildCount
        XCTAssertGreaterThan(rebuildsBefore, 0)

        var scale = 1.0
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<20 {
                scale += 0.01
                view.configure(
                    canvasID: view.canvasID,
                    strokes: strokes,
                    images: images,
                    selectedImageID: nil,
                    tool: .select,
                    color: .ink,
                    width: 3,
                    viewport: CanvasViewport(center: .zero, scale: scale),
                    pendingPlacement: nil,
                    clearReadabilityEnabled: false
                )
            }
        }

        XCTAssertEqual(
            view.accessibilityRebuildCount,
            rebuildsBefore,
            "Viewport-only changes must not rebuild accessibility elements."
        )

        // A content change must still rebuild, or the gate would be vacuous.
        view.configure(
            canvasID: view.canvasID,
            strokes: strokes,
            images: Array(images.dropLast()),
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(center: .zero, scale: scale),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        view.flushPendingAccessibilityRebuild()
        XCTAssertGreaterThan(view.accessibilityRebuildCount, rebuildsBefore)
        XCTAssertEqual(view.canvasAccessibilityNavigationOrder.count, 400 + 99)
    }

    func testCoalescedAccessibilityRebuildRunsOncePerRunLoopTurn() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let strokes = makeStrokes(count: 4)
        var images = makeImages(count: 6)
        view.configure(
            canvasID: view.canvasID,
            strokes: strokes,
            images: images,
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(center: .zero, scale: 1),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        _ = view.accessibilityChildren()
        let rebuildsBefore = view.accessibilityRebuildCount

        for _ in 0..<5 {
            images.removeLast()
            view.configure(
                canvasID: view.canvasID,
                strokes: strokes,
                images: images,
                selectedImageID: nil,
                tool: .select,
                color: .ink,
                width: 3,
                viewport: CanvasViewport(center: .zero, scale: 1),
                pendingPlacement: nil,
                clearReadabilityEnabled: false
            )
        }
        XCTAssertEqual(view.accessibilityRebuildCount, rebuildsBefore)
        view.flushPendingAccessibilityRebuild()
        XCTAssertEqual(view.accessibilityRebuildCount, rebuildsBefore + 1)
        XCTAssertEqual(view.canvasAccessibilityNavigationOrder.count, 4 + 1)
    }

    func testAccessibilityFramesFollowTheViewportWithoutARebuild() throws {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let strokes = makeStrokes(count: 2)
        let images = makeImages(count: 3)
        view.configure(
            canvasID: view.canvasID,
            strokes: strokes,
            images: images,
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(center: .zero, scale: 1),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        let elements = try XCTUnwrap(
            view.accessibilityChildren() as? [CanvasAccessibilityObjectElement]
        )
        let before = elements.map { $0.accessibilityFrameInParentSpace() }
        let rebuildsBefore = view.accessibilityRebuildCount

        view.configure(
            canvasID: view.canvasID,
            strokes: strokes,
            images: images,
            selectedImageID: nil,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(center: CanvasPoint(x: 120, y: 90), scale: 2),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )

        let after = elements.map { $0.accessibilityFrameInParentSpace() }
        XCTAssertEqual(before.count, after.count)
        XCTAssertNotEqual(before, after, "Zooming must move accessibility frames.")
        XCTAssertEqual(
            view.accessibilityRebuildCount,
            rebuildsBefore,
            "Frames must follow the viewport without a full rebuild."
        )
    }

    // MARK: - CANVAS-018 / PERF-10

    func testTopmostImageHitTestingOverTwoHundredImages() {
        let images = (0..<200).map { index in
            makeImage(
                index: index,
                center: CanvasPoint(
                    x: Double(index % 20) * 90,
                    y: Double(index / 20) * 90
                )
            )
        }
        let order = CanvasImageHitTestOrder(images: images)
        let probes = (0..<500).map { step in
            CanvasPoint(
                x: Double(step % 20) * 90 + 1,
                y: Double(step % 10) * 90 + 1
            )
        }

        var hits = 0
        measure(metrics: [XCTClockMetric()]) {
            hits = 0
            for probe in probes where order.topmostImage(at: probe) != nil {
                hits += 1
            }
        }
        XCTAssertGreaterThan(hits, 0)

        // The shared order must agree with the reference implementation, both
        // for hits and for points outside every image.
        for probe in probes + [CanvasPoint(x: -5_000, y: -5_000)] {
            XCTAssertEqual(
                order.topmostImage(at: probe)?.id,
                CanvasImagePlacement.topmostImage(at: probe, images: images)?.id
            )
        }
    }

    func testDisplayOrderIsReusedAcrossPointerEventsDuringATransform() {
        let view = CanvasNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 360))
        let images = makeImages(count: 25)
        view.configure(
            canvasID: view.canvasID,
            strokes: [],
            images: images,
            selectedImageID: images[3].id,
            tool: .select,
            color: .ink,
            width: 3,
            viewport: CanvasViewport(center: .zero, scale: 1),
            pendingPlacement: nil,
            clearReadabilityEnabled: false
        )
        view.previewImageTransform = CanvasImageTransform(
            center: CanvasPoint(x: 500, y: 500),
            width: 64,
            height: 64,
            zIndex: images[3].zIndex
        )

        let first = view.imagesForDisplay
        let second = view.imagesForDisplay
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(
            first.first { $0.id == images[3].id }?.center.x,
            500,
            "The live preview transform must be reflected in the display array."
        )
        XCTAssertEqual(
            view.imageDisplayOrder.topmostImage(at: CanvasPoint(x: 500, y: 500))?.id,
            images[3].id,
            "Hit-testing must see the previewed position."
        )
    }

    // MARK: - CANVAS-010 / PERF-11

    func testHistoryByteBudgetEvictsOldestCommandsFirst() throws {
        let session = CanvasSession(
            store: try makeTestCanvasStore(),
            historyByteBudget: 4 * 1024
        )
        var placedIDs: [UUID] = []
        for index in 0..<6 {
            let prepared = CanvasPreparedImage(
                encodedData: Data(repeating: UInt8(index + 1), count: 1024),
                contentType: UTType.png.identifier,
                pixelWidth: 30,
                pixelHeight: 30
            )
            XCTAssertTrue(session.importPreparedImage(prepared, at: CanvasPoint(
                x: Double(index) * 10,
                y: 0
            )))
            placedIDs.append(try XCTUnwrap(session.images.last?.id))
        }

        XCTAssertEqual(session.images.count, 6)
        XCTAssertLessThanOrEqual(session.historyPayloadByteCount, 4 * 1024)
        XCTAssertLessThan(session.undoCommandCount, 6)
        XCTAssertGreaterThan(session.undoCommandCount, 0)

        // Eviction drops the oldest commands, so the surviving history undoes
        // the most recent imports, newest first.
        let survivors = session.undoCommandCount
        for offset in 0..<survivors {
            XCTAssertTrue(session.undo())
            let removed = placedIDs[placedIDs.count - 1 - offset]
            XCTAssertFalse(session.images.contains { $0.id == removed })
        }
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.images.count, 6 - survivors)
    }

    func testHistoryAlwaysKeepsTheNewestCommandEvenWhenItExceedsTheBudget() throws {
        let session = CanvasSession(
            store: try makeTestCanvasStore(),
            historyByteBudget: 16
        )
        let prepared = CanvasPreparedImage(
            encodedData: Data(repeating: 7, count: 8 * 1024),
            contentType: UTType.png.identifier,
            pixelWidth: 30,
            pixelHeight: 30
        )
        XCTAssertTrue(session.importPreparedImage(prepared, at: .zero))
        XCTAssertEqual(session.undoCommandCount, 1)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.images.count, 1)
        XCTAssertEqual(session.images.first?.encodedData.count, 8 * 1024)
    }

    func testImageHistoryRetentionStaysWithinItsByteBudget() throws {
        // The memory metric is the point of CANVAS-010: a bounded stack must
        // not let deleted image payloads accumulate.
        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()]) {
            guard let session = try? CanvasSession(
                store: makeTestCanvasStore(),
                historyByteBudget: 2 * 1024 * 1024
            ) else {
                return XCTFail("Canvas store unavailable")
            }
            for index in 0..<12 {
                let prepared = CanvasPreparedImage(
                    encodedData: Data(repeating: UInt8(index + 1), count: 1024 * 1024),
                    contentType: UTType.png.identifier,
                    pixelWidth: 64,
                    pixelHeight: 64
                )
                XCTAssertTrue(session.importPreparedImage(prepared, at: CanvasPoint(
                    x: Double(index) * 12,
                    y: 0
                )))
            }
            XCTAssertLessThanOrEqual(session.historyPayloadByteCount, 2 * 1024 * 1024)
        }
    }

    func testStrokeHistoryStaysWithinItsByteBudget() throws {
        measure(metrics: [XCTClockMetric()]) {
            guard let session = try? CanvasSession(
                store: makeTestCanvasStore(),
                historyByteBudget: 64 * 1024
            ) else {
                return XCTFail("Canvas store unavailable")
            }
            for index in 0..<40 {
                _ = session.completeStroke(points: strokePoints(offset: Double(index)))
            }
            XCTAssertLessThanOrEqual(session.historyPayloadByteCount, 64 * 1024)
        }
    }

    // MARK: - PERF-007 / PERF-13

    func testUnchangedStoreRevisionDoesNotResynchroniseSession() throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        _ = session.completeStroke(points: strokePoints(offset: 1))
        let syncsBefore = session.storeSynchronizationCount

        store.refresh()
        XCTAssertEqual(
            session.storeSynchronizationCount,
            syncsBefore,
            "A refresh that resolves identical content must not republish."
        )

        _ = session.completeStroke(points: strokePoints(offset: 2))
        XCTAssertGreaterThan(session.storeSynchronizationCount, syncsBefore)
        XCTAssertEqual(session.strokes.count, 2)
    }

    func testStrokeOnlyChangeDoesNotRepublishImages() throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let prepared = CanvasPreparedImage(
            encodedData: Data([0x89, 0x50, 0x4E, 0x47, 1]),
            contentType: UTType.png.identifier,
            pixelWidth: 24,
            pixelHeight: 24
        )
        XCTAssertTrue(session.importPreparedImage(prepared, at: .zero))
        let publishedImages = session.images

        _ = session.completeStroke(points: strokePoints(offset: 9))
        XCTAssertTrue(store.lastContentChange.strokesChanged)
        XCTAssertFalse(store.lastContentChange.imagesChanged)
        XCTAssertEqual(session.images.count, publishedImages.count)
        XCTAssertEqual(
            session.images.map(\.renderToken),
            publishedImages.map(\.renderToken),
            "An unchanged image collection must keep its render identity."
        )
        XCTAssertEqual(session.strokes.count, 1)
    }

    // MARK: - CANVAS-008

    func testLongChainedErrorsAreCompactedForTheBanner() {
        let long = String(repeating: "The canvas image could not be saved. ", count: 20)
        let chained = "\(long) · A second detail · A third detail"
        let compacted = CanvasSession.compactErrorMessage(chained)
        XCTAssertLessThanOrEqual(compacted.count, 180)
        XCTAssertTrue(compacted.hasSuffix("· 2 more details"))
        XCTAssertTrue(compacted.hasPrefix("The canvas image could not be saved."))

        XCTAssertEqual(
            CanvasSession.compactErrorMessage("Short failure"),
            "Short failure"
        )
        XCTAssertEqual(
            CanvasSession.compactErrorMessage("Short failure · One detail"),
            "Short failure · 1 more detail"
        )
    }

    func testErrorBannerCanBeDismissedAndReturnsOnTheNextFailure() throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        session.reportError("Something went wrong")
        XCTAssertEqual(session.lastErrorMessage, "Something went wrong")

        session.dismissErrorMessage()
        XCTAssertNil(session.lastErrorMessage)
        XCTAssertNil(store.lastErrorMessage)

        session.reportError("A later failure")
        XCTAssertEqual(session.lastErrorMessage, "A later failure")
    }

    // MARK: - PERF-A1

    #if DEBUG
    func testStrokeMutationsReadOnlyTheSelectedCanvasReplicas() throws {
        let setup = try makeOnDiskCanvasStore()
        let otherBoard = UUID()
        let selectedBoard = UUID()
        let boardCount = 3
        let seed = ModelContext(setup.container)
        seed.insert(CanvasBoardItem(id: CanvasBoardItem.logicalBoardID, name: "Canvas", sortIndex: 0))
        seed.insert(CanvasBoardItem(id: otherBoard, name: "Other", sortIndex: 1))
        seed.insert(CanvasBoardItem(id: selectedBoard, name: "Selected", sortIndex: 2))
        // Realistic ink: 400 points is roughly 7 KB per payload.
        let payload = try CanvasStrokeCodec.encode(
            color: .ink,
            width: 3,
            points: (0..<400).map { CanvasPoint(x: Double($0), y: Double($0) * 0.5) }
        )
        for board in [CanvasBoardItem.logicalBoardID, otherBoard] {
            for index in 0..<300 {
                seed.insert(CanvasStrokeItem(
                    canvasID: board,
                    payload: payload,
                    tombstoned: index % 10 == 0,
                    createdAt: Date(timeIntervalSince1970: Double(index))
                ))
            }
        }
        for index in 0..<10 {
            seed.insert(CanvasStrokeItem(
                canvasID: selectedBoard,
                payload: payload,
                createdAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        try seed.save()

        let store = CanvasStore(container: setup.container)
        XCTAssertTrue(store.selectCanvas(otherBoard))
        try seedImages(count: 20, byteCount: 16 * 1024, in: store)
        XCTAssertTrue(store.selectCanvas(selectedBoard))
        XCTAssertEqual(store.strokes.count, 10)
        let unselectedRowCount = 600 + 20

        // A save resolves twice and a mutation looks its replicas up once, so
        // three reads of the selected canvas bound the cost. Before PERF-A1
        // each read also returned the 620 rows of the other canvases.
        func assertReadsStayOnSelectedCanvas(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            let bound = 3 * (boardCount + store.strokes.count)
            XCTAssertLessThanOrEqual(
                CanvasReplicaFetchCounter.rows,
                bound,
                "\(label) read \(CanvasReplicaFetchCounter.rows) replica rows; the selected canvas bounds it at \(bound).",
                file: file,
                line: line
            )
            XCTAssertLessThan(bound, unselectedRowCount, file: file, line: line)
        }

        CanvasReplicaFetchCounter.reset()
        XCTAssertNotNil(store.addStroke(color: .ink, width: 3, points: strokePoints(offset: 1)))
        assertReadsStayOnSelectedCanvas("addStroke")

        var rowsPerSave: [Int] = []
        measure(metrics: [XCTClockMetric()]) {
            CanvasReplicaFetchCounter.reset()
            _ = store.addStroke(
                color: .ink,
                width: 3,
                points: strokePoints(offset: Double(rowsPerSave.count + 2))
            )
            rowsPerSave.append(CanvasReplicaFetchCounter.rows)
        }
        XCTAssertFalse(rowsPerSave.isEmpty)
        XCTAssertEqual(rowsPerSave.filter { $0 > 3 * (boardCount + store.strokes.count) }, [])

        let deletedIDs = Set(store.strokes.prefix(3).map(\.id))
        CanvasReplicaFetchCounter.reset()
        XCTAssertTrue(store.setDeleted(true, strokeIDs: deletedIDs))
        assertReadsStayOnSelectedCanvas("setDeleted")
        XCTAssertTrue(store.strokes.allSatisfy { !deletedIDs.contains($0.id) })

        let clearedCount = store.strokes.count
        CanvasReplicaFetchCounter.reset()
        XCTAssertTrue(store.clearBoard())
        XCTAssertLessThanOrEqual(CanvasReplicaFetchCounter.rows, 3 * (boardCount + clearedCount))
        XCTAssertTrue(store.strokes.isEmpty)

        // The other canvases were neither shown nor rewritten.
        let verification = ModelContext(setup.container)
        let untouched = try verification.fetch(FetchDescriptor<CanvasStrokeItem>())
            .filter { $0.canvasID != selectedBoard }
        XCTAssertEqual(untouched.count, 600)
        XCTAssertEqual(untouched.filter(\.tombstoned).count, 60)
        XCTAssertTrue(untouched.allSatisfy { $0.mutationVersion == 1 })
        XCTAssertTrue(store.selectCanvas(otherBoard))
        XCTAssertEqual(store.strokes.count, 270)
        XCTAssertEqual(store.images.count, 20)
    }
    #else
    func testStrokeMutationsReadOnlyTheSelectedCanvasReplicas() throws {
        throw XCTSkip("CanvasReplicaFetchCounter is compiled only in DEBUG builds.")
    }
    #endif

    // MARK: - Helpers

    private func makeOnDiskCanvasStore() throws -> CanvasStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticCanvasPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryStoreDirectories.append(directory)
        let configuration = ModelConfiguration(
            url: directory.appendingPathComponent("Canvas.store"),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: CanvasBoardItem.self,
            CanvasStrokeItem.self,
            CanvasImageItem.self,
            CanvasSemanticObjectItem.self,
            configurations: configuration
        )
        return CanvasStore(container: container)
    }

    private func seedImages(count: Int, byteCount: Int, in store: CanvasStore) throws {
        for index in 0..<count {
            var payload = Data(repeating: UInt8(index % 251), count: byteCount)
            payload.replaceSubrange(0..<4, with: Data([0x89, 0x50, 0x4E, 0x47]))
            let prepared = CanvasPreparedImage(
                encodedData: payload,
                contentType: UTType.png.identifier,
                pixelWidth: 48,
                pixelHeight: 48
            )
            XCTAssertNotNil(store.addImage(
                prepared,
                center: CanvasPoint(x: Double(index % 10) * 70, y: Double(index / 10) * 70)
            ))
        }
    }

    private func makeStrokes(count: Int) -> [CanvasStroke] {
        (0..<count).map { index in
            CanvasStroke(
                color: .ink,
                width: 3,
                points: strokePoints(offset: Double(index)),
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
    }

    private func makeImages(count: Int) -> [CanvasPlacedImage] {
        (0..<count).map { index in
            makeImage(
                index: index,
                center: CanvasPoint(
                    x: Double(index % 10) * 80,
                    y: Double(index / 10) * 80
                )
            )
        }
    }

    private func makeImage(index: Int, center: CanvasPoint) -> CanvasPlacedImage {
        CanvasPlacedImage(
            id: UUID(),
            encodedData: Data([0x89, 0x50, 0x4E, 0x47, UInt8(index % 251)]),
            contentType: UTType.png.identifier,
            pixelWidth: 64,
            pixelHeight: 64,
            transform: CanvasImageTransform(
                center: center,
                width: 64,
                height: 64,
                zIndex: Int64(index)
            ),
            createdAt: Date(timeIntervalSince1970: Double(index))
        )
    }

    private func strokePoints(offset: Double) -> [CanvasPoint] {
        (0..<12).map { step in
            CanvasPoint(x: offset + Double(step), y: offset + Double(step) * 0.5)
        }
    }
}
