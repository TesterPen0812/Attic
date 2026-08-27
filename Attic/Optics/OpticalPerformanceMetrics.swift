import Foundation

struct OpticalPerformanceSnapshot: Equatable, Sendable {
    let capturedFrameCount: Int
    let renderedFrameCount: Int
    let droppedFrameCount: Int
    let incompleteFrameCount: Int
    let meanFrameTimeMilliseconds: Double
    let p95FrameTimeMilliseconds: Double
    let droppedFrameRate: Double
    let meanCaptureLatencyMilliseconds: Double
    let estimatedMemoryBytes: Int

    static let empty = OpticalPerformanceSnapshot(
        capturedFrameCount: 0,
        renderedFrameCount: 0,
        droppedFrameCount: 0,
        incompleteFrameCount: 0,
        meanFrameTimeMilliseconds: 0,
        p95FrameTimeMilliseconds: 0,
        droppedFrameRate: 0,
        meanCaptureLatencyMilliseconds: 0,
        estimatedMemoryBytes: 0
    )
}

final class OpticalPerformanceMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let windowCapacity: Int
    private var capturedFrameCount = 0
    private var renderedFrameCount = 0
    private var droppedFrameCount = 0
    private var incompleteFrameCount = 0
    private var frameDurations: [Double] = []
    private var captureLatencies: [Double] = []
    private var estimatedMemoryBytes = 0

    init(windowCapacity: Int = 120) {
        self.windowCapacity = max(1, windowCapacity)
    }

    func recordCapturedFrame(latencyMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        capturedFrameCount += 1
        appendBounded(sanitized(latencyMilliseconds), to: &captureLatencies)
    }

    func recordRenderedFrame(durationMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        renderedFrameCount += 1
        appendBounded(sanitized(durationMilliseconds), to: &frameDurations)
    }

    func recordDroppedFrame() {
        lock.lock()
        defer { lock.unlock() }
        droppedFrameCount += 1
    }

    func recordIncompleteFrame() {
        lock.lock()
        defer { lock.unlock() }
        incompleteFrameCount += 1
    }

    func updateMemoryEstimate(
        pixelWidth: Int,
        pixelHeight: Int,
        bytesPerPixel: Int,
        queueDepth: Int,
        rendererTextureCount: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        let width = max(0, pixelWidth)
        let height = max(0, pixelHeight)
        let bytes = max(0, bytesPerPixel)
        let surfaces = max(0, queueDepth) + max(0, rendererTextureCount)
        estimatedMemoryBytes = width * height * bytes * surfaces
    }

    func snapshot() -> OpticalPerformanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let dropDenominator = capturedFrameCount + droppedFrameCount
        return OpticalPerformanceSnapshot(
            capturedFrameCount: capturedFrameCount,
            renderedFrameCount: renderedFrameCount,
            droppedFrameCount: droppedFrameCount,
            incompleteFrameCount: incompleteFrameCount,
            meanFrameTimeMilliseconds: mean(frameDurations),
            p95FrameTimeMilliseconds: percentile95(frameDurations),
            droppedFrameRate: dropDenominator > 0
                ? Double(droppedFrameCount) / Double(dropDenominator)
                : 0,
            meanCaptureLatencyMilliseconds: mean(captureLatencies),
            estimatedMemoryBytes: estimatedMemoryBytes
        )
    }

    private func appendBounded(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > windowCapacity {
            values.removeFirst(values.count - windowCapacity)
        }
    }

    private func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}
