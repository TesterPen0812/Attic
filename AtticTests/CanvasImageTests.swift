import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

final class CanvasImageImportTests: XCTestCase {
    func testTextRendererProducesAReusableTransparentPNG() async throws {
        let prepared = try await CanvasTextRenderer.prepare(
            text: "Capture and organise",
            color: .blue,
            prefersDarkSurface: true
        )

        XCTAssertEqual(prepared.contentType, UTType.png.identifier)
        XCTAssertGreaterThan(prepared.pixelWidth, prepared.pixelHeight)
        XCTAssertGreaterThan(prepared.encodedData.count, 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(
            prepared.encodedData as CFData,
            nil
        ))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
    }

    func testTextRendererRejectsWhitespaceOnlyContent() async {
        do {
            _ = try await CanvasTextRenderer.prepare(
                text: "  \n ",
                color: .ink,
                prefersDarkSurface: false
            )
            XCTFail("Expected whitespace-only text to be rejected")
        } catch {
            XCTAssertEqual(error as? CanvasTextRenderError, .emptyText)
        }
    }

    func testFileImportStoresCanonicalBytesRatherThanSourcePath() async throws {
        let sourceData = try makeTestImageData(width: 120, height: 60)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try sourceData.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let prepared = try await CanvasImageImporter.prepare(url: sourceURL)
        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertFalse(prepared.encodedData.isEmpty)
        XCTAssertEqual(prepared.pixelWidth, 120)
        XCTAssertEqual(prepared.pixelHeight, 60)
        XCTAssertNotNil(CGImageSourceCreateWithData(
            prepared.encodedData as CFData,
            nil
        ))
        XCTAssertFalse(
            String(data: prepared.encodedData, encoding: .utf8)?
                .contains(sourceURL.path) ?? false
        )
    }

    func testCorruptImageInputIsRejectedWithoutCreatingAnAsset() async {
        do {
            _ = try await CanvasImageImporter.prepare(
                data: Data("not an image".utf8)
            )
            XCTFail("Expected corrupt image data to be rejected")
        } catch {
            XCTAssertEqual(error as? CanvasImageImportError, .unsupportedOrCorrupt)
        }
    }

    func testLargeImageIsDownsampledAndAspectRatioIsPreserved() async throws {
        let sourceData = try makeTestImageData(width: 2_400, height: 1_200)
        let policy = CanvasImageImportPolicy(
            maximumInputBytes: 64 * 1_024 * 1_024,
            maximumEncodedBytes: 2 * 1_024 * 1_024,
            maximumPixelDimension: 600
        )

        let prepared = try await CanvasImageImporter.prepare(
            data: sourceData,
            policy: policy
        )

        XCTAssertLessThanOrEqual(max(prepared.pixelWidth, prepared.pixelHeight), 600)
        XCTAssertEqual(
            Double(prepared.pixelWidth) / Double(prepared.pixelHeight),
            2,
            accuracy: 0.01
        )
        XCTAssertLessThanOrEqual(
            prepared.encodedData.count,
            policy.maximumEncodedBytes
        )
    }

    func testSmallImageIsAcceptedEvenWhenItsMaximumDimensionIsBelowRetryFloor() async throws {
        let sourceData = try makeTestImageData(width: 32, height: 16)

        let prepared = try await CanvasImageImporter.prepare(data: sourceData)

        XCTAssertEqual(prepared.pixelWidth, 32)
        XCTAssertEqual(prepared.pixelHeight, 16)
        XCTAssertFalse(prepared.encodedData.isEmpty)
    }

    func testInputLargerThanTheReadBudgetIsRejectedBeforeDecode() async {
        let policy = CanvasImageImportPolicy(
            maximumInputBytes: 8,
            maximumEncodedBytes: 8,
            maximumPixelDimension: 128
        )

        do {
            _ = try await CanvasImageImporter.prepare(
                data: Data(repeating: 0, count: 9),
                policy: policy
            )
            XCTFail("Expected the input budget to reject the payload")
        } catch {
            XCTAssertEqual(error as? CanvasImageImportError, .inputTooLarge)
        }
    }

    private func makeTestImageData(
        width: Int,
        height: Int
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(
            red: 0.15,
            green: 0.42,
            blue: 0.77,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

final class CanvasImageDomainTests: XCTestCase {
    func testDefaultPlacementIsBoundedAndPreservesAspectRatio() {
        let size = CanvasImagePlacement.defaultSize(
            pixelWidth: 4_000,
            pixelHeight: 2_000
        )

        XCTAssertEqual(size.width, 360, accuracy: 0.000_001)
        XCTAssertEqual(size.height, 180, accuracy: 0.000_001)
    }

    func testCustomMaximumCannotShrinkPlacementBelowInteractionMinimum() {
        let size = CanvasImagePlacement.defaultSize(
            pixelWidth: 10,
            pixelHeight: 10,
            maximumDimension: 1
        )

        XCTAssertEqual(size.width, CanvasImagePlacement.minimumDimension)
        XCTAssertEqual(size.height, CanvasImagePlacement.minimumDimension)
    }

    func testResizeOverflowKeepsOriginalTransform() {
        let original = CanvasImageTransform(
            center: CanvasPoint(
                x: Double.greatestFiniteMagnitude / 2,
                y: 1.5e308
            ),
            width: Double.greatestFiniteMagnitude,
            height: 1e308,
            zIndex: 1
        )

        let resized = CanvasImagePlacement.resizedTransform(
            from: original,
            handle: .bottomRight,
            to: CanvasPoint(
                x: Double.greatestFiniteMagnitude,
                y: 1e308
            )
        )

        XCTAssertEqual(resized, original)
    }

    func testDropCoordinatesRemainCorrectUnderZoomAndPan() {
        let viewport = CanvasViewport(
            center: CanvasPoint(x: 300, y: -120),
            scale: 2.5
        )
        let size = CGSize(width: 300, height: 500)
        let dropPoint = CGPoint(x: 75, y: 350)

        let world = viewport.worldPoint(for: dropPoint, in: size)

        XCTAssertEqual(world.x, 270, accuracy: 0.000_001)
        XCTAssertEqual(world.y, -80, accuracy: 0.000_001)
        XCTAssertEqual(viewport.viewPoint(for: world, in: size), dropPoint)
    }
}

final class CanvasImageStoreTests: XCTestCase {
    @MainActor
    func testImageBytesAndTransformPersistAcrossFreshStore() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let prepared = CanvasPreparedImage(
            encodedData: Data([0x89, 0x50, 0x4E, 0x47]),
            contentType: UTType.png.identifier,
            pixelWidth: 400,
            pixelHeight: 200
        )
        var store = CanvasStore(container: container)
        let image = try XCTUnwrap(store.addImage(
            prepared,
            center: CanvasPoint(x: 42, y: -17)
        ))
        let transformed = CanvasImageTransform(
            center: CanvasPoint(x: 100, y: 90),
            width: 500,
            height: 250,
            zIndex: 7
        )

        XCTAssertTrue(store.updateImage(image.id, transform: transformed))
        store = CanvasStore(container: container)

        let restored = try XCTUnwrap(store.images.first)
        XCTAssertEqual(restored.encodedData, prepared.encodedData)
        XCTAssertEqual(restored.contentType, UTType.png.identifier)
        XCTAssertEqual(restored.transform, transformed)
        let context = ModelContext(container)
        let row = try XCTUnwrap(
            context.fetch(FetchDescriptor<CanvasImageItem>()).first
        )
        XCTAssertEqual(row.encodedData, prepared.encodedData)
        XCTAssertFalse(row.tombstoned)
    }

    @MainActor
    func testDuplicateImageTombstoneWinsAndMutationsTouchEveryReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        let canvasID = CanvasBoardItem.logicalBoardID
        let older = CanvasImageItem(
            id: sharedID,
            canvasID: canvasID,
            encodedData: Data([1]),
            contentType: UTType.png.identifier,
            pixelWidth: 10,
            pixelHeight: 10,
            centerX: 0,
            centerY: 0,
            width: 100,
            height: 100,
            zIndex: 0,
            boardGeneration: 0,
            mutationVersion: 4,
            tombstoned: false,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let tombstone = CanvasImageItem(
            id: sharedID,
            canvasID: canvasID,
            encodedData: Data([1]),
            contentType: UTType.png.identifier,
            pixelWidth: 10,
            pixelHeight: 10,
            centerX: 0,
            centerY: 0,
            width: 100,
            height: 100,
            zIndex: 0,
            boardGeneration: 0,
            mutationVersion: 4,
            tombstoned: true,
            updatedAt: Date(timeIntervalSince1970: 1),
            deletedAt: Date(timeIntervalSince1970: 1)
        )
        context.insert(older)
        context.insert(tombstone)
        try context.save()

        let store = CanvasStore(container: container)
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertTrue(store.restoreImages([
            CanvasPlacedImage(
                id: sharedID,
                encodedData: Data([2]),
                contentType: UTType.png.identifier,
                pixelWidth: 20,
                pixelHeight: 10,
                transform: CanvasImageTransform(
                    center: CanvasPoint(x: 5, y: 6),
                    width: 200,
                    height: 100,
                    zIndex: 2
                ),
                boardGeneration: 0,
                mutationVersion: 4
            )
        ]))

        let verification = ModelContext(container)
        let replicas = try verification.fetch(FetchDescriptor<CanvasImageItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy {
            !$0.tombstoned
                && $0.encodedData == Data([2])
                && $0.mutationVersion == 5
                && $0.centerX == 5
                && $0.centerY == 6
        })
    }

    @MainActor
    func testAddingAnExistingImageIDUpdatesEveryReplicaInsteadOfCreatingAHiddenDuplicate() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        for tombstoned in [false, true] {
            context.insert(CanvasImageItem(
                id: sharedID,
                encodedData: Data([1]),
                contentType: UTType.png.identifier,
                pixelWidth: 20,
                pixelHeight: 10,
                centerX: 0,
                centerY: 0,
                width: 100,
                height: 50,
                zIndex: 0,
                mutationVersion: 4,
                tombstoned: tombstoned,
                createdAt: timestamp,
                updatedAt: timestamp,
                deletedAt: tombstoned ? timestamp : nil
            ))
        }
        try context.save()

        let store = CanvasStore(container: container)
        let prepared = CanvasPreparedImage(
            encodedData: Data([2, 3]),
            contentType: UTType.png.identifier,
            pixelWidth: 40,
            pixelHeight: 20
        )

        let added = try XCTUnwrap(store.addImage(
            prepared,
            center: CanvasPoint(x: 8, y: 9),
            id: sharedID
        ))

        XCTAssertEqual(added.id, sharedID)
        XCTAssertEqual(store.images.count, 1)
        XCTAssertEqual(store.images.first?.encodedData, prepared.encodedData)
        let verification = ModelContext(container)
        let replicas = try verification.fetch(FetchDescriptor<CanvasImageItem>())
            .filter { $0.id == sharedID }
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy {
            !$0.tombstoned
                && $0.encodedData == prepared.encodedData
                && $0.mutationVersion == 5
                && $0.centerX == 8
            && $0.centerY == 9
        })
    }

    @MainActor
    func testInvalidImageSnapshotIsRejectedWithoutPersistingIt() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let snapshot = CanvasPlacedImage(
            encodedData: Data([1]),
            contentType: UTType.png.identifier,
            pixelWidth: -1,
            pixelHeight: 20,
            transform: CanvasImageTransform(
                center: .zero,
                width: 100,
                height: 50,
                zIndex: 0
            )
        )

        XCTAssertFalse(store.restoreImages([snapshot]))
        let verification = ModelContext(container)
        XCTAssertEqual(
            try verification.fetchCount(FetchDescriptor<CanvasImageItem>()),
            0
        )
    }

    @MainActor
    func testUnchangedImageRefreshRetainsRenderTokenButTransformInvalidatesIt() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let image = try XCTUnwrap(store.addImage(
            CanvasPreparedImage(
                encodedData: Data([1, 2, 3]),
                contentType: UTType.png.identifier,
                pixelWidth: 100,
                pixelHeight: 50
            ),
            center: .zero
        ))

        store.refresh()
        XCTAssertEqual(store.images.first?.renderToken, image.renderToken)

        XCTAssertTrue(store.updateImage(
            image.id,
            transform: CanvasImageTransform(
                center: CanvasPoint(x: 10, y: 20),
                width: image.width,
                height: image.height,
                zIndex: image.zIndex
            )
        ))
        XCTAssertNotEqual(store.images.first?.renderToken, image.renderToken)
    }

    @MainActor
    func testChangedImagePayloadWithSameMetadataInvalidatesContentToken() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let image = try XCTUnwrap(store.addImage(
            CanvasPreparedImage(
                encodedData: Data([1, 2, 3]),
                contentType: UTType.png.identifier,
                pixelWidth: 100,
                pixelHeight: 50
            ),
            center: .zero
        ))

        let externalContext = ModelContext(container)
        let row = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<CanvasImageItem>()).first
        )
        row.encodedData = Data([4, 5, 6])
        row.mutationVersion += 1
        row.updatedAt = row.updatedAt.addingTimeInterval(1)
        try externalContext.save()

        store.refresh()

        let changed = try XCTUnwrap(store.images.first)
        XCTAssertNotEqual(changed.renderToken, image.renderToken)
        XCTAssertNotEqual(changed.contentToken, image.contentToken)
        XCTAssertEqual(changed.encodedData, Data([4, 5, 6]))
    }
}

final class CanvasImageSessionTests: XCTestCase {
    @MainActor
    func testTopmostImageCannotMoveForwardOrCreatePersistenceOrHistory() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = CanvasStore(container: container, persist: gate.save)
        let session = CanvasSession(store: store)
        let prepared = CanvasPreparedImage(
            encodedData: Data([1]),
            contentType: UTType.png.identifier,
            pixelWidth: 40,
            pixelHeight: 20
        )

        XCTAssertTrue(session.importPreparedImage(prepared, at: .zero))
        let bottom = try XCTUnwrap(session.images.first)
        XCTAssertTrue(session.importPreparedImage(
            prepared,
            at: CanvasPoint(x: 20, y: 20)
        ))
        let top = try XCTUnwrap(session.images.max { $0.zIndex < $1.zIndex })
        session.selectImage(top.id)
        let saveCount = gate.saveCount
        let revision = store.revision

        XCTAssertFalse(session.canBringSelectedImageForward)
        XCTAssertFalse(session.bringSelectedImageForward())
        XCTAssertEqual(gate.saveCount, saveCount)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(session.selectedImage?.zIndex, top.zIndex)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.images.map(\.id), [bottom.id])
    }

    @MainActor
    func testBottommostImageCannotMoveBackwardOrCreatePersistenceOrHistory() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = PersistenceGate()
        let store = CanvasStore(container: container, persist: gate.save)
        let session = CanvasSession(store: store)
        let prepared = CanvasPreparedImage(
            encodedData: Data([2]),
            contentType: UTType.png.identifier,
            pixelWidth: 40,
            pixelHeight: 20
        )

        XCTAssertTrue(session.importPreparedImage(prepared, at: .zero))
        let bottom = try XCTUnwrap(session.images.first)
        XCTAssertTrue(session.importPreparedImage(
            prepared,
            at: CanvasPoint(x: 20, y: 20)
        ))
        session.selectImage(bottom.id)
        let saveCount = gate.saveCount
        let revision = store.revision

        XCTAssertFalse(session.canSendSelectedImageBackward)
        XCTAssertFalse(session.sendSelectedImageBackward())
        XCTAssertEqual(gate.saveCount, saveCount)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(session.selectedImage?.zIndex, bottom.zIndex)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.images.map(\.id), [bottom.id])
    }

    @MainActor
    func testImportMoveResizeDeleteUndoRedo() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let session = CanvasSession(store: store)
        let prepared = CanvasPreparedImage(
            encodedData: Data([7, 8, 9]),
            contentType: UTType.png.identifier,
            pixelWidth: 200,
            pixelHeight: 100
        )

        XCTAssertTrue(session.importPreparedImage(
            prepared,
            at: CanvasPoint(x: 20, y: 30)
        ))
        let imported = try XCTUnwrap(session.images.first)
        let moved = CanvasImageTransform(
            center: CanvasPoint(x: 80, y: 90),
            width: 480,
            height: 240,
            zIndex: imported.zIndex
        )
        XCTAssertTrue(session.transformImage(imported.id, to: moved))
        XCTAssertEqual(session.images.first?.transform, moved)

        XCTAssertTrue(session.deleteImage(imported.id))
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.images.first?.transform, moved)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.images.first?.transform, imported.transform)
        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.images.isEmpty)

        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.images.first?.transform, imported.transform)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.images.first?.transform, moved)
        XCTAssertTrue(session.redo())
        XCTAssertTrue(session.images.isEmpty)
    }

    @MainActor
    func testClearUndoRestoresInkAndImagesIntoCurrentGeneration() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = CanvasStore(container: container)
        let session = CanvasSession(store: store)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: 1, y: 2)]))
        XCTAssertTrue(session.importPreparedImage(
            CanvasPreparedImage(
                encodedData: Data([3]),
                contentType: UTType.png.identifier,
                pixelWidth: 20,
                pixelHeight: 10
            ),
            at: .zero
        ))

        XCTAssertTrue(session.clear())
        XCTAssertTrue(session.strokes.isEmpty)
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.undo())

        XCTAssertEqual(session.strokes.count, 1)
        XCTAssertEqual(session.images.count, 1)
        XCTAssertEqual(session.strokes.first?.boardGeneration, session.boardGeneration)
        XCTAssertEqual(session.images.first?.boardGeneration, session.boardGeneration)
    }
}

private actor ControlledCanvasImagePreparer {
    struct PreparationFailure: LocalizedError {
        let index: Int

        var errorDescription: String? {
            "Preparation failed for item \(index)."
        }
    }

    private var continuations: [Int: CheckedContinuation<CanvasPreparedImage, Error>] = [:]
    private var startedIndices: Set<Int> = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelledIndices: Set<Int> = []
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    func prepare(_ source: CanvasImageImportSource) async throws -> CanvasPreparedImage {
        let index: Int
        switch source {
        case let .data(data):
            guard let byte = data.first else {
                throw PreparationFailure(index: -1)
            }
            index = Int(byte)
        case .file, .deliveryFailure:
            throw PreparationFailure(index: -1)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation, for: index)
            }
        } onCancel: {
            Task { await self.cancel(index) }
        }
    }

    func waitUntilStarted(count: Int) async {
        guard startedIndices.count < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func release(_ index: Int) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            return
        }
        activeCount -= 1
        continuation.resume(returning: CanvasPreparedImage(
            encodedData: Data([UInt8(index), 0x50, 0x4E, 0x47]),
            contentType: UTType.png.identifier,
            pixelWidth: 100 + index,
            pixelHeight: 50 + index
        ))
    }

    func activePreparationCount() -> Int {
        activeCount
    }

    func cancellationCount() -> Int {
        cancelledIndices.count
    }

    func maximumActivePreparationCount() -> Int {
        maximumActiveCount
    }

    private func register(
        _ continuation: CheckedContinuation<CanvasPreparedImage, Error>,
        for index: Int
    ) {
        continuations[index] = continuation
        startedIndices.insert(index)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)

        let ready = startWaiters.filter { startedIndices.count >= $0.count }
        startWaiters.removeAll { startedIndices.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func cancel(_ index: Int) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            return
        }
        cancelledIndices.insert(index)
        activeCount -= 1
        continuation.resume(throwing: CancellationError())
    }
}

final class CanvasImageImportBatchTests: XCTestCase {
    @MainActor
    func testDecodeCompletionAfterPageSwitchPersistsOnlyToCapturedTarget() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = ControlledCanvasImagePreparer()
        let session = makeSession(container: container, gate: gate)
        _ = try XCTUnwrap(session.createCanvas(name: "Target"))
        let target = session.captureImageImportTarget()
        let batch = makeBatch(target: target, indices: [0])

        let importTask = Task { await session.importImageBatch(batch) }
        await gate.waitUntilStarted(count: 1)
        let second = try XCTUnwrap(session.createCanvas(name: "Second"))
        await gate.release(0)

        let result = await importTask.value

        XCTAssertEqual(result.items.map(\.requestID), batch.items.map(\.id))
        XCTAssertEqual(result.items.first?.outcome.importedImageID, batch.items.first?.id)
        XCTAssertEqual(session.selectedCanvasID, second.id)
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.selectCanvas(target.canvasID))
        XCTAssertEqual(session.images.map(\.id), batch.items.map(\.id))
        XCTAssertTrue(session.images.allSatisfy {
            $0.canvasID == target.canvasID && $0.boardGeneration == target.boardGeneration
        })
    }

    @MainActor
    func testDecodeCompletionAfterTargetPageDeletionDoesNotPersist() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = ControlledCanvasImagePreparer()
        let session = makeSession(container: container, gate: gate)
        _ = try XCTUnwrap(session.createCanvas(name: "Survivor"))
        _ = try XCTUnwrap(session.createCanvas(name: "Delete me"))
        let target = session.captureImageImportTarget()
        let batch = makeBatch(target: target, indices: [0])

        let importTask = Task { await session.importImageBatch(batch) }
        await gate.waitUntilStarted(count: 1)
        XCTAssertTrue(session.deleteSelectedCanvas())
        await gate.release(0)

        let result = await importTask.value

        XCTAssertEqual(result.items.first?.outcome, .failed(.targetUnavailable))
        let rows = try ModelContext(container).fetch(FetchDescriptor<CanvasImageItem>())
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(session.canvases.contains { $0.id == target.canvasID })
    }

    @MainActor
    func testDecodeCompletionAfterClearRejectsStaleGeneration() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let gate = ControlledCanvasImagePreparer()
        let session = makeSession(container: container, gate: gate)
        XCTAssertTrue(session.completeStroke(points: [CanvasPoint(x: 1, y: 2)]))
        let target = session.captureImageImportTarget()
        let batch = makeBatch(target: target, indices: [0])

        let importTask = Task { await session.importImageBatch(batch) }
        await gate.waitUntilStarted(count: 1)
        XCTAssertTrue(session.clear())
        XCTAssertEqual(session.boardGeneration, target.boardGeneration + 1)
        await gate.release(0)

        let result = await importTask.value

        XCTAssertEqual(result.items.first?.outcome, .failed(.targetGenerationChanged))
        let rows = try ModelContext(container).fetch(FetchDescriptor<CanvasImageItem>())
        XCTAssertTrue(rows.isEmpty)
    }

    @MainActor
    func testCancellationStopsInFlightPreparationCleansTemporaryFilesAndDoesNotSave() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let gate = ControlledCanvasImagePreparer()
        let session = makeSession(
            container: container,
            gate: gate,
            persist: persistence.save
        )
        let cleanupRoot = try makeCleanupRoot()
        let target = session.captureImageImportTarget()
        let batch = makeBatch(
            target: target,
            indices: [0, 1],
            cleanupURL: cleanupRoot
        )

        let importTask = Task { await session.importImageBatch(batch) }
        await gate.waitUntilStarted(count: 2)
        importTask.cancel()
        let result = await importTask.value
        let cancellationCount = await gate.cancellationCount()
        let activePreparationCount = await gate.activePreparationCount()

        XCTAssertEqual(
            result.items.map(\.outcome),
            [.failed(.cancelled), .failed(.cancelled)]
        )
        XCTAssertEqual(cancellationCount, 2)
        XCTAssertEqual(activePreparationCount, 0)
        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupRoot.path))
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<CanvasImageItem>()),
            0
        )
    }

    @MainActor
    func testOutOfOrderCompletionIsBoundedStableAndPersistsSuccessfulItemsOnce() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let gate = ControlledCanvasImagePreparer()
        let session = makeSession(
            container: container,
            gate: gate,
            maximumConcurrency: 2,
            persist: persistence.save
        )
        let target = session.captureImageImportTarget()
        let batch = makeBatch(target: target, indices: [0, 1, 2, 3])

        let importTask = Task { await session.importImageBatch(batch) }
        await gate.waitUntilStarted(count: 2)
        let initialMaximumActiveCount = await gate.maximumActivePreparationCount()
        XCTAssertEqual(initialMaximumActiveCount, 2)
        await gate.release(1)
        await gate.waitUntilStarted(count: 3)
        await gate.release(0)
        await gate.waitUntilStarted(count: 4)
        await gate.release(3)
        await gate.release(2)

        let result = await importTask.value
        let maximumActiveCount = await gate.maximumActivePreparationCount()

        XCTAssertEqual(maximumActiveCount, 2)
        XCTAssertEqual(result.items.map(\.requestID), batch.items.map(\.id))
        XCTAssertEqual(
            result.items.compactMap { $0.outcome.importedImageID },
            batch.items.map(\.id)
        )
        XCTAssertEqual(session.images.map(\.id), batch.items.map(\.id))
        XCTAssertEqual(session.images.map(\.zIndex), [0, 1, 2, 3])
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(session.imageImportProgress?.completedCount, 4)
        XCTAssertEqual(
            session.imageImportProgress?.items.map(\.requestID),
            batch.items.map(\.id)
        )
    }

    @MainActor
    func testDeliveryFailureKeepsStablePerItemResultAndCleansBatchResources() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let persistence = PersistenceGate()
        let gate = ControlledCanvasImagePreparer()
        let session = makeSession(
            container: container,
            gate: gate,
            persist: persistence.save
        )
        let cleanupRoot = try makeCleanupRoot()
        let target = session.captureImageImportTarget()
        let baseBatch = makeBatch(
            target: target,
            indices: [0, 1, 2],
            cleanupURL: cleanupRoot
        )
        let batch = CanvasImageImportBatch(
            id: baseBatch.id,
            target: target,
            items: [
                baseBatch.items[0],
                CanvasImageImportRequest(
                    id: baseBatch.items[1].id,
                    source: .deliveryFailure("Provider stopped responding."),
                    center: baseBatch.items[1].center,
                    cleanupURL: cleanupRoot
                ),
                baseBatch.items[2]
            ]
        )

        let importTask = Task { await session.importImageBatch(batch) }
        await gate.waitUntilStarted(count: 2)
        await gate.release(2)
        await gate.release(0)
        let result = await importTask.value

        XCTAssertEqual(result.items.map(\.requestID), batch.items.map(\.id))
        XCTAssertEqual(result.items[0].outcome.importedImageID, batch.items[0].id)
        XCTAssertEqual(
            result.items[1].outcome,
            .failed(.deliveryFailed("Provider stopped responding."))
        )
        XCTAssertEqual(result.items[2].outcome.importedImageID, batch.items[2].id)
        XCTAssertEqual(session.images.map(\.id), [batch.items[0].id, batch.items[2].id])
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupRoot.path))
    }

    @MainActor
    private func makeSession(
        container: ModelContainer,
        gate: ControlledCanvasImagePreparer,
        maximumConcurrency: Int = 2,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) -> CanvasSession {
        CanvasSession(
            store: CanvasStore(container: container, persist: persist),
            maximumConcurrentImageImports: maximumConcurrency,
            prepareImage: { source in
                try await gate.prepare(source)
            }
        )
    }

    private func makeBatch(
        target: CanvasImportTarget,
        indices: [Int],
        cleanupURL: URL? = nil
    ) -> CanvasImageImportBatch {
        CanvasImageImportBatch(
            target: target,
            items: indices.map { index in
                CanvasImageImportRequest(
                    id: UUID(),
                    source: .data(Data([UInt8(index)])),
                    center: CanvasPoint(x: Double(index) * 12, y: Double(index) * 12),
                    cleanupURL: cleanupURL
                )
            }
        )
    }

    private func makeCleanupRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticCanvasImportTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("payload.tmp"))
        return root
    }
}
