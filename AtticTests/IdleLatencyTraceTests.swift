import AppKit
import XCTest
@testable import Attic

@MainActor
final class IdleLatencyTraceTests: XCTestCase {
    func testCounterDeltasUseActionStartAndDoNotUnderflow() {
        let start = IdleLatencyCounters(userUS: 10, systemUS: 20, faults: 100,
                                        pageins: 4, cowFaults: 40, systemDecompressions: 50)
        let end = IdleLatencyCounters(userUS: 35, systemUS: 27, faults: 119,
                                      pageins: 6, cowFaults: 39, systemDecompressions: 53)
        let delta = end.delta(since: start)
        XCTAssertEqual(delta.userUS, 25)
        XCTAssertEqual(delta.systemUS, 7)
        XCTAssertEqual(delta.faults, 19)
        XCTAssertEqual(delta.pageins, 2)
        XCTAssertEqual(delta.cowFaults, 0)
        XCTAssertEqual(delta.systemDecompressions, 3)
    }

    func testIdleThresholdAndCapOnlyScheduleEligibleActions() {
        XCTAssertFalse(IdleLatencySamplePolicy.shouldSample(idleSeconds: nil))
        XCTAssertFalse(IdleLatencySamplePolicy.shouldSample(idleSeconds: 19.999))
        XCTAssertTrue(IdleLatencySamplePolicy.shouldSample(idleSeconds: 20))
        XCTAssertTrue(IdleLatencySamplePolicy.shouldSample(idleSeconds: 45))
        XCTAssertEqual(IdleLatencySamplePolicy.maximumSamples, 40)
        XCTAssertEqual(IdleLatencySamplePolicy.maximumFrames, 32)
        XCTAssertTrue(IdleLatencySamplePolicy.mayCapture(sampleCount: 0))
        XCTAssertTrue(IdleLatencySamplePolicy.mayCapture(sampleCount: 39))
        XCTAssertFalse(IdleLatencySamplePolicy.mayCapture(sampleCount: 40))
        XCTAssertFalse(IdleLatencySamplePolicy.mayCapture(sampleCount: 41))
        XCTAssertNil(IdleLatencyStackSampler.startIfEligible(idleSeconds: 0, thread: 0))
        XCTAssertEqual(IdleLatencyStackSampler.activeCountForTesting, 0)
    }

    #if ATTIC_IDLE_SAMPLER && arch(arm64)
    func testSuspendedMainThreadYieldsFramesAndAlwaysResumes() async {
        let thread = AtticIdleMach.mainThread()
        defer { AtticIdleMach.release(thread) }
        guard let sampler = IdleLatencyStackSampler.startIfEligible(idleSeconds: 20, thread: thread) else {
            return XCTFail("an eligible action must start its sampler")
        }
        // Deliberately keep main busy across several background 25 ms ticks.
        let until = ProcessInfo.processInfo.systemUptime + 0.22
        var work = 0
        while ProcessInfo.processInfo.systemUptime < until { work &+= 1 }
        XCTAssertGreaterThan(work, 0)
        let samples = await sampler.finish()
        XCTAssertTrue(samples.contains { $0.frameCount >= 2 }, "busy main frame-pointer chain must be readable")
        XCTAssertTrue(samples.allSatisfy { $0.frameCount <= IdleLatencySamplePolicy.maximumFrames })
        XCTAssertLessThanOrEqual(samples.count, IdleLatencySamplePolicy.maximumSamples)
        XCTAssertEqual(IdleLatencyStackSampler.activeCountForTesting, 0)
        // Reaching this assertion from the resumed main actor is the liveness check.
        XCTAssertTrue(Thread.isMainThread)
    }
    #endif
}
