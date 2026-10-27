import Foundation
import XCTest
import CoreGraphics
import AppKit

final class Box<T>: @unchecked Sendable {
    let lock = NSLock(); private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func change(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}
final class RendererTests: XCTestCase {
    func testLatestPendingReplacesIntermediateAndCancelsBusyWork() {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let executed = Box<[Int]>([]), installed = Box<[Int]>([]), cancelled = Box(false)
        let delivery = DispatchQueue(label: "test.delivery")
        let renderer = LatestRenderer<Int, Int>(delivery: delivery, work: { value, stale in
            executed.change { $0.append(value) }
            if value == 1 { started.signal(); _ = release.wait(timeout: .now() + 3); cancelled.change { $0 = stale() } }
            return value
        }, install: { _, value in installed.change { $0.append(value) } })
        renderer.request(1); XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        renderer.request(2); renderer.request(3); release.signal()
        let end = Date().addingTimeInterval(3)
        while installed.value.isEmpty && Date() < end { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(executed.value, [1, 3]); XCTAssertEqual(installed.value, [3]); XCTAssertTrue(cancelled.value)
    }
    func testCompletedResultIsDiscardedIfStaleBeforeDelivery() {
        let delivery = DispatchQueue(label: "test.suspended"); delivery.suspend()
        let ended = DispatchSemaphore(value: 0), installed = Box<[Int]>([]), delivered = DispatchSemaphore(value:0)
        let renderer = LatestRenderer<Int, Int>(delivery: delivery, work: { value, _ in value },
            trace: { kind, _, _, _ in if kind == "worker_end" { ended.signal() } },
            install: { _, value in installed.change { $0.append(value) };delivered.signal() })
        renderer.request(1); XCTAssertEqual(ended.wait(timeout: .now() + 3), .success)
        renderer.request(2); XCTAssertEqual(ended.wait(timeout: .now() + 3), .success)
        delivery.resume(); XCTAssertEqual(delivered.wait(timeout:.now()+3),.success)
        XCTAssertEqual(installed.value, [2])
    }
    func testEveryRasterIdentityDimensionInvalidates() {
        let original = RasterKey()
        var keys = [RasterKey](); var k = original
        k.revision += 1; keys.append(k); k = original; k.x += 1; keys.append(k)
        k = original; k.y += 1; keys.append(k); k = original; k.zoom = 2; keys.append(k)
        k = original; k.scale = 1; keys.append(k); k = original; k.dark = true; keys.append(k)
        k = original; k.width += 1; keys.append(k); k = original; k.height += 1; keys.append(k)
        XCTAssertTrue(keys.allSatisfy { $0 != original })
    }
    func testRealFixtureAndSyncReproducerExposeInputBlocking() {
        let fixture = Geometry.fixture()
        XCTAssertEqual(fixture.strokes.count, 2000)
        XCTAssertEqual(fixture.strokes.reduce(0) { $0 + $1.count }, 800000)
        XCTAssertEqual(fixture.strokes[0][0], Geometry.fixture().strokes[0][0])
        let request = RasterRequest(key: RasterKey(), fixture: fixture, strokes: nil)
        // The measured span includes actual 800,000-point raster, not a sleep/mock.
        let workerStarted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let renderer = LatestRenderer<RasterRequest, RasterImage>(work: { req, stale in
            workerStarted.signal(); _ = release.wait(timeout: .now() + 5)
            return ViewportRaster.render(req, cancelled: stale)
        }, install: { _,_ in })
        let async = RasterController(mode: .asynchronous, renderer: renderer, install: { _,_ in })
        let sync = RasterController(mode: .synchronousReproducer, renderer: renderer, install: { _,_ in })
        let begin = labNow(); async.viewportInput(request); let asyncSpan = labNow() - begin
        XCTAssertEqual(workerStarted.wait(timeout: .now() + 3), .success)
        // Pan/zoom while busy still only replaces one pending handle.
        var zoomed = request.key; zoomed.zoom = 1.1; zoomed.x = 2
        let busy = labNow()
        async.viewportInput(RasterRequest(key: zoomed, fixture: fixture, strokes: nil))
        let busySpan = labNow() - busy
        // Queue a pointer callback immediately behind a real viewport handler.
        // This is in-process dispatch, never CGEvent posting or a window.
        func queuedDownLatency(_ controller: RasterController) -> Double {
            let input = DispatchQueue(label: "test.input")
            let handled = DispatchSemaphore(value: 0), latency = Box(0.0)
            let posted = labNow()
            input.async { controller.viewportInput(request) }
            input.async { latency.change { $0 = labNow()-posted }; handled.signal() }
            XCTAssertEqual(handled.wait(timeout: .now()+5), .success)
            return latency.value
        }
        let pointerSpan = queuedDownLatency(async)
        let syncBegin = labNow(); let syncSpan = queuedDownLatency(sync)
        XCTAssertGreaterThanOrEqual(labNow()-syncBegin, syncSpan)
        release.signal(); release.signal()
        print("STALL_PROOF async_ms=\(asyncSpan*1000) busy_ms=\(busySpan*1000) down_ms=\(pointerSpan*1000) sync_ms=\(syncSpan*1000)")
        XCTAssertGreaterThan(syncSpan, 0.005)
        XCTAssertLessThan(max(asyncSpan, busySpan, pointerSpan), syncSpan / 4)
    }
    func testEventClockRoundTripWithoutPosting() {
        let event = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left)!
        let before = labNow()
        event.timestamp = LabClock.eventTimestamp(seconds:before)
        let converted = NSEvent(cgEvent:event)!
        XCTAssertEqual(converted.timestamp, before, accuracy:0.000001)
        XCTAssertEqual(LabClock.seconds(eventTimestamp:event.timestamp),before,accuracy:0.000001)
    }
    func testPredictionIsBoundedAndDoesNotMutateInput() {
        let p = CGPoint(x: 30, y: 40)
        let predicted = Prediction.point(previous: .zero, latest: p, dt: 0.0001)
        XCTAssertLessThanOrEqual(hypot(predicted.x-p.x, predicted.y-p.y), 12.00001)
        XCTAssertEqual(Prediction.point(previous: .zero, latest: p, dt: 0), p)
    }
}
let suite = RendererTests.defaultTestSuite
suite.run()
guard let result = suite.testRun, result.executionCount == 6, result.hasSucceeded else { exit(1) }
