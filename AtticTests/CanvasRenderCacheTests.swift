import CoreGraphics
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

    @MainActor
    func testImageDecodeSchedulerBoundsConcurrencyAndPreservesInputPriority() async {
        let decodedImage = makeCGImage()
        let probe = HeldCanvasDecoderProbe(image: decodedImage)
        let images = (0..<12).map(makePlacedImage)
        let ready = expectation(description: "all scheduled images become ready")
        ready.expectedFulfillmentCount = images.count
        let cache = CanvasImageDecodeCache(
            maximumConcurrentDecodes: 2,
            decode: { data in await probe.decode(data) }
        )
        cache.onImageReady = { ready.fulfill() }

        cache.prepare(for: images)

        let initialWorkersStarted = await waitUntil { await probe.startedCount == 2 }
        XCTAssertTrue(initialWorkersStarted)
        var snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.started, [0, 1])
        XCTAssertEqual(snapshot.maximumActive, 2)

        for identifier in 0..<images.count {
            await probe.release(UInt8(identifier))
            let expectedStartedCount = min(images.count, identifier + 3)
            let nextWorkerStarted = await waitUntil {
                await probe.startedCount == expectedStartedCount
            }
            XCTAssertTrue(nextWorkerStarted)
        }

        await fulfillment(of: [ready], timeout: 2)
        snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.started, (0..<images.count).map(UInt8.init))
        XCTAssertEqual(snapshot.finished, (0..<images.count).map(UInt8.init))
        XCTAssertEqual(snapshot.maximumActive, 2)
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertTrue(images.allSatisfy { cache.state(for: $0) == .ready })
    }

    @MainActor
    func testPreparingNewVisibleSetCancelsActiveAndQueuedDecodes() async {
        let probe = HeldCanvasDecoderProbe(image: makeCGImage())
        let images = (0..<4).map(makePlacedImage)
        let cache = CanvasImageDecodeCache(
            maximumConcurrentDecodes: 2,
            decode: { data in await probe.decode(data) }
        )

        cache.prepare(for: images)
        let initialWorkersStarted = await waitUntil { await probe.startedCount == 2 }
        XCTAssertTrue(initialWorkersStarted)

        cache.prepare(for: [images[2]])

        let replacementStarted = await waitUntil {
            let snapshot = await probe.snapshot()
            return snapshot.cancelled == Set([0, 1])
                && snapshot.started.contains(2)
        }
        XCTAssertTrue(replacementStarted)
        var snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.started, [0, 1, 2])
        XCTAssertFalse(snapshot.started.contains(3))
        XCTAssertLessThanOrEqual(snapshot.maximumActive, 2)

        await probe.release(2)
        let replacementReady = await waitUntil { cache.state(for: images[2]) == .ready }
        XCTAssertTrue(replacementReady)
        snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(cache.state(for: images[0]), .idle)
        XCTAssertEqual(cache.state(for: images[1]), .idle)
        XCTAssertEqual(cache.state(for: images[3]), .idle)
    }

    @MainActor
    func testReappearingCancelledTokenWaitsForNonCooperativeDecodeSlot() async {
        let probe = NonCooperativeCanvasDecoderProbe(image: makeCGImage())
        let images = (10..<13).map(makePlacedImage)
        let cache = CanvasImageDecodeCache(
            maximumConcurrentDecodes: 3,
            decode: { data in await probe.decode(data) }
        )

        cache.prepare(for: [images[0]])
        let firstDecodeStarted = await waitUntil { await probe.startedCount == 1 }
        XCTAssertTrue(firstDecodeStarted)

        cache.prepare(for: [])
        cache.prepare(for: images)

        let availableSlotsFilled = await waitUntil { await probe.startedCount >= 3 }
        XCTAssertTrue(availableSlotsFilled)
        var snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.started, [10, 11, 12])
        XCTAssertLessThanOrEqual(snapshot.maximumActive, 3)

        await probe.releaseAll()
        let replacementsFinished = await waitUntil {
            images.allSatisfy { cache.state(for: $0) == .ready }
        }
        XCTAssertTrue(replacementsFinished)
        snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.started.filter { $0 == 10 }.count, 2)
    }

    @MainActor
    func testDecodeFailureIsMemoizedAndRetryInvalidatesStablePlaceholder() async {
        let probe = FailingCanvasDecoderProbe()
        let image = makePlacedImage(42)
        let stateChanged = expectation(description: "failure and retry notify renderer")
        stateChanged.expectedFulfillmentCount = 2
        let cache = CanvasImageDecodeCache(
            maximumConcurrentDecodes: 1,
            decode: { data in await probe.decode(data) }
        )
        cache.onImageReady = { stateChanged.fulfill() }

        cache.prepare(for: [image])
        let initialFailureRecorded = await waitUntil { cache.state(for: image) == .failed }
        XCTAssertTrue(initialFailureRecorded)
        var attemptCount = await probe.attemptCount
        XCTAssertEqual(attemptCount, 1)

        cache.prepare(for: [image])
        cache.prepare(for: [image])
        await Task.yield()
        attemptCount = await probe.attemptCount
        XCTAssertEqual(attemptCount, 1)

        let firstPlaceholder = cache.image(for: image)
        let secondPlaceholder = cache.image(for: image)
        XCTAssertNotNil(firstPlaceholder)
        XCTAssertTrue(firstPlaceholder === secondPlaceholder)
        XCTAssertEqual(firstPlaceholder?.width, 64)
        XCTAssertEqual(firstPlaceholder?.height, 64)

        cache.retryDecode(for: image)
        let retryFinished = await waitUntil {
            await probe.attemptCount == 2 && cache.state(for: image) == .failed
        }
        XCTAssertTrue(retryFinished)
        await fulfillment(of: [stateChanged], timeout: 2)
        attemptCount = await probe.attemptCount
        XCTAssertEqual(attemptCount, 2)
        XCTAssertTrue(firstPlaceholder === cache.image(for: image))
    }

    @MainActor
    func testDefaultImageIODecoderMemoizesCorruptBytes() async {
        let image = makePlacedImage(73)
        let cache = CanvasImageDecodeCache(maximumConcurrentDecodes: 1)
        var renderInvalidations = 0
        cache.onImageReady = { renderInvalidations += 1 }

        cache.prepare(for: [image])
        let failureRecorded = await waitUntil { cache.state(for: image) == .failed }
        XCTAssertTrue(failureRecorded)
        XCTAssertEqual(renderInvalidations, 1)
        XCTAssertNotNil(cache.image(for: image))

        for _ in 0..<4 {
            cache.prepare(for: [image])
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(cache.state(for: image), .failed)
        XCTAssertEqual(renderInvalidations, 1)
    }

    @MainActor
    func testFailureMemoDoesNotEvictCurrentlyVisibleCorruptImages() async {
        let probe = FailingCanvasDecoderProbe()
        let images = (80..<83).map(makePlacedImage)
        let cache = CanvasImageDecodeCache(
            maximumConcurrentDecodes: 1,
            failedDecodeLimit: 2,
            decode: { data in await probe.decode(data) }
        )

        cache.prepare(for: images)
        let initialBatchFinished = await waitUntil { await probe.attemptCount == 3 }
        XCTAssertTrue(initialBatchFinished)

        cache.prepare(for: images)
        for _ in 0..<20 {
            await Task.yield()
        }

        let attemptCount = await probe.attemptCount
        XCTAssertEqual(attemptCount, 3)
        XCTAssertTrue(images.allSatisfy { cache.state(for: $0) == .failed })
    }

    @MainActor
    func testDecodeSchedulerStressKeepsNinetySixImagesWithinFourWorkers() async {
        let image = makeCGImage()
        let probe = DelayedCanvasDecoderProbe(image: image)
        let images = (0..<96).map(makePlacedImage)
        let ready = expectation(description: "stress batch completes")
        ready.expectedFulfillmentCount = images.count
        let cache = CanvasImageDecodeCache(
            maximumConcurrentDecodes: 4,
            decode: { data in await probe.decode(data) }
        )
        cache.onImageReady = { ready.fulfill() }
        let startedAt = ProcessInfo.processInfo.systemUptime

        cache.prepare(for: images)
        await fulfillment(of: [ready], timeout: 5)

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, images.count)
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertLessThanOrEqual(snapshot.maximumActive, 4)
        XCTAssertLessThan(elapsed, 3)
        print(
            "Canvas decode stress: \(images.count) images in "
                + String(format: "%.3f", elapsed)
                + "s, max active \(snapshot.maximumActive)"
        )
    }

    private func makePlacedImage(_ identifier: Int) -> CanvasPlacedImage {
        CanvasPlacedImage(
            encodedData: Data([UInt8(identifier)]),
            contentType: "application/octet-stream",
            pixelWidth: 1,
            pixelHeight: 1,
            transform: CanvasImageTransform(
                center: CanvasPoint(x: 0, y: 0),
                width: 1,
                height: 1,
                zIndex: Int64(identifier)
            )
        )
    }

    private func makeCGImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}

private actor HeldCanvasDecoderProbe {
    struct Snapshot: Sendable {
        let started: [UInt8]
        let finished: [UInt8]
        let cancelled: Set<UInt8>
        let active: Int
        let maximumActive: Int
    }

    private let decodedImage: CanvasDecodedImage
    private var started: [UInt8] = []
    private var finished: [UInt8] = []
    private var cancelled: Set<UInt8> = []
    private var active = 0
    private var maximumActive = 0
    private var released: Set<UInt8> = []
    private var waiters: [UInt8: CheckedContinuation<Void, Never>] = [:]

    init(image: CGImage) {
        decodedImage = CanvasDecodedImage(image: image)
    }

    var startedCount: Int { started.count }

    func decode(_ data: Data) async -> CanvasDecodedImage {
        let identifier = data.first!
        started.append(identifier)
        active += 1
        maximumActive = max(maximumActive, active)

        await withTaskCancellationHandler {
            await waitForRelease(identifier)
        } onCancel: {
            Task { await self.cancel(identifier) }
        }

        active -= 1
        if Task.isCancelled {
            cancelled.insert(identifier)
            return CanvasDecodedImage(image: nil)
        }
        finished.append(identifier)
        return decodedImage
    }

    func release(_ identifier: UInt8) {
        guard let waiter = waiters.removeValue(forKey: identifier) else {
            released.insert(identifier)
            return
        }
        waiter.resume()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            started: started,
            finished: finished,
            cancelled: cancelled,
            active: active,
            maximumActive: maximumActive
        )
    }

    private func waitForRelease(_ identifier: UInt8) async {
        if Task.isCancelled || released.remove(identifier) != nil { return }
        await withCheckedContinuation { continuation in
            waiters[identifier] = continuation
        }
    }

    private func cancel(_ identifier: UInt8) {
        cancelled.insert(identifier)
        guard let waiter = waiters.removeValue(forKey: identifier) else { return }
        waiter.resume()
    }
}

private actor FailingCanvasDecoderProbe {
    private(set) var attemptCount = 0

    func decode(_ data: Data) -> CanvasDecodedImage {
        attemptCount += 1
        return CanvasDecodedImage(image: nil)
    }
}

private actor NonCooperativeCanvasDecoderProbe {
    struct Snapshot: Sendable {
        let started: [UInt8]
        let active: Int
        let maximumActive: Int
    }

    private let decodedImage: CanvasDecodedImage
    private var started: [UInt8] = []
    private var active = 0
    private var maximumActive = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(image: CGImage) {
        decodedImage = CanvasDecodedImage(image: image)
    }

    var startedCount: Int { started.count }

    func decode(_ data: Data) async -> CanvasDecodedImage {
        started.append(data.first!)
        active += 1
        maximumActive = max(maximumActive, active)

        await withTaskCancellationHandler {
            await waitForRelease()
        } onCancel: {
            // ImageIO may not return until its current decode call completes.
        }

        active -= 1
        guard !Task.isCancelled else { return CanvasDecodedImage(image: nil) }
        return decodedImage
    }

    func releaseAll() {
        released = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            started: started,
            active: active,
            maximumActive: maximumActive
        )
    }

    private func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor DelayedCanvasDecoderProbe {
    struct Snapshot: Sendable {
        let attempts: Int
        let active: Int
        let maximumActive: Int
    }

    private let decodedImage: CanvasDecodedImage
    private var attempts = 0
    private var active = 0
    private var maximumActive = 0

    init(image: CGImage) {
        decodedImage = CanvasDecodedImage(image: image)
    }

    func decode(_ data: Data) async -> CanvasDecodedImage {
        attempts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(nanoseconds: 2_000_000)
        active -= 1
        return decodedImage
    }

    func snapshot() -> Snapshot {
        Snapshot(
            attempts: attempts,
            active: active,
            maximumActive: maximumActive
        )
    }
}
