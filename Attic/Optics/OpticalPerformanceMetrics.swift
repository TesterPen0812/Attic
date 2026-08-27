import Foundation
import OSLog

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
    private static let logger = Logger(
        subsystem: "com.emanueledipietro.Attic",
        category: "OpticalPerformance"
    )

    private let lock = NSLock()
    private let windowCapacity: Int
    private var capturedFrameCount = 0
    private var renderedFrameCount = 0
    private var droppedFrameCount = 0
    private var incompleteFrameCount = 0
    private var frameDurations: [Double] = []
    private var captureLatencies: [Double] = []
    private var frameOutcomes: [Bool] = []
    private var estimatedMemoryBytes = 0

    init(windowCapacity: Int = 120) {
        self.windowCapacity = max(1, windowCapacity)
    }

    func recordCapturedFrame(latencyMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        capturedFrameCount += 1
        appendBounded(sanitized(latencyMilliseconds), to: &captureLatencies)
        appendBounded(true, to: &frameOutcomes)
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
        appendBounded(false, to: &frameOutcomes)
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

    func clearMemoryEstimate() {
        lock.lock()
        estimatedMemoryBytes = 0
        lock.unlock()
    }

    func reset() {
        lock.lock()
        capturedFrameCount = 0
        renderedFrameCount = 0
        droppedFrameCount = 0
        incompleteFrameCount = 0
        frameDurations.removeAll(keepingCapacity: true)
        captureLatencies.removeAll(keepingCapacity: true)
        frameOutcomes.removeAll(keepingCapacity: true)
        estimatedMemoryBytes = 0
        lock.unlock()
    }

    func hasRecentPerformanceSamples() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !frameDurations.isEmpty
            || !captureLatencies.isEmpty
            || !frameOutcomes.isEmpty
    }

    func snapshot() -> OpticalPerformanceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let recentDropCount = frameOutcomes.reduce(into: 0) { count, wasCaptured in
            if !wasCaptured { count += 1 }
        }
        return OpticalPerformanceSnapshot(
            capturedFrameCount: capturedFrameCount,
            renderedFrameCount: renderedFrameCount,
            droppedFrameCount: droppedFrameCount,
            incompleteFrameCount: incompleteFrameCount,
            meanFrameTimeMilliseconds: mean(frameDurations),
            p95FrameTimeMilliseconds: percentile95(frameDurations),
            droppedFrameRate: frameOutcomes.isEmpty
                ? 0
                : Double(recentDropCount) / Double(frameOutcomes.count),
            meanCaptureLatencyMilliseconds: mean(captureLatencies),
            estimatedMemoryBytes: estimatedMemoryBytes
        )
    }

    /// Emits aggregate numeric diagnostics only. It never receives or records a
    /// pixel buffer, image, window title, application name, or screen content.
    func report(reason: String) {
        let value = snapshot()
        guard value.capturedFrameCount > 0
                || value.renderedFrameCount > 0
                || value.droppedFrameCount > 0
                || value.incompleteFrameCount > 0 else {
            return
        }
        Self.logger.info(
            "reason=\(reason, privacy: .public) captured=\(value.capturedFrameCount, privacy: .public) rendered=\(value.renderedFrameCount, privacy: .public) dropped=\(value.droppedFrameCount, privacy: .public) incomplete=\(value.incompleteFrameCount, privacy: .public) mean_frame_ms=\(value.meanFrameTimeMilliseconds, privacy: .public) p95_frame_ms=\(value.p95FrameTimeMilliseconds, privacy: .public) drop_rate=\(value.droppedFrameRate, privacy: .public) capture_latency_ms=\(value.meanCaptureLatencyMilliseconds, privacy: .public) estimated_bytes=\(value.estimatedMemoryBytes, privacy: .public)"
        )
    }

    private func appendBounded<Value>(_ value: Value, to values: inout [Value]) {
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
