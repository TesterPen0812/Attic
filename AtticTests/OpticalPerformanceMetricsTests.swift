import XCTest
@testable import Attic

final class OpticalPerformanceMetricsTests: XCTestCase {
    func testMetricsCalculateFrameDropLatencyAndMemoryAggregates() {
        let metrics = OpticalPerformanceMetrics(windowCapacity: 4)
        metrics.recordCapturedFrame(latencyMilliseconds: 10)
        metrics.recordCapturedFrame(latencyMilliseconds: 30)
        metrics.recordRenderedFrame(durationMilliseconds: 4)
        metrics.recordRenderedFrame(durationMilliseconds: 8)
        metrics.recordDroppedFrame()
        metrics.recordIncompleteFrame()
        metrics.updateMemoryEstimate(
            pixelWidth: 100,
            pixelHeight: 50,
            bytesPerPixel: 4,
            queueDepth: 3,
            rendererTextureCount: 2
        )

        let snapshot = metrics.snapshot()

        XCTAssertEqual(snapshot.capturedFrameCount, 2)
        XCTAssertEqual(snapshot.renderedFrameCount, 2)
        XCTAssertEqual(snapshot.droppedFrameCount, 1)
        XCTAssertEqual(snapshot.incompleteFrameCount, 1)
        XCTAssertEqual(snapshot.meanFrameTimeMilliseconds, 6, accuracy: 0.001)
        XCTAssertEqual(snapshot.p95FrameTimeMilliseconds, 8, accuracy: 0.001)
        XCTAssertEqual(snapshot.droppedFrameRate, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.meanCaptureLatencyMilliseconds, 20, accuracy: 0.001)
        XCTAssertEqual(snapshot.estimatedMemoryBytes, 100_000)
    }

    func testRollingWindowIsBoundedToRecentMeasurements() {
        let metrics = OpticalPerformanceMetrics(windowCapacity: 4)
        for duration in [1.0, 2, 3, 4, 100] {
            metrics.recordRenderedFrame(durationMilliseconds: duration)
        }

        let snapshot = metrics.snapshot()

        XCTAssertEqual(snapshot.renderedFrameCount, 5)
        XCTAssertEqual(snapshot.meanFrameTimeMilliseconds, 27.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.p95FrameTimeMilliseconds, 100, accuracy: 0.001)
    }

    func testSnapshotContainsOnlyAggregateNumericFields() {
        let snapshot = OpticalPerformanceSnapshot.empty
        let labels = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))

        XCTAssertEqual(
            labels,
            [
                "capturedFrameCount",
                "renderedFrameCount",
                "droppedFrameCount",
                "incompleteFrameCount",
                "meanFrameTimeMilliseconds",
                "p95FrameTimeMilliseconds",
                "droppedFrameRate",
                "meanCaptureLatencyMilliseconds",
                "estimatedMemoryBytes"
            ]
        )
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("image") })
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("content") })
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("pixelBuffer") })
    }
}
