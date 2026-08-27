import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Attic

final class CanvasImageImportTests: XCTestCase {
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
