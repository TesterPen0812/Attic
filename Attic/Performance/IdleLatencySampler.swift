import Foundation

/// The counters are monotonic during one action. Clamp a regressing or
/// unavailable counter rather than reporting a huge unsigned wraparound.
struct IdleLatencyCounters: Equatable {
    let userUS: UInt64
    let systemUS: UInt64
    let faults: UInt64
    let pageins: UInt64
    let cowFaults: UInt64
    let systemDecompressions: UInt64

    func delta(since other: Self) -> Self {
        func difference(_ end: UInt64, _ begin: UInt64) -> UInt64 { end >= begin ? end - begin : 0 }
        return Self(userUS: difference(userUS, other.userUS),
                    systemUS: difference(systemUS, other.systemUS),
                    faults: difference(faults, other.faults),
                    pageins: difference(pageins, other.pageins),
                    cowFaults: difference(cowFaults, other.cowFaults),
                    systemDecompressions: difference(systemDecompressions, other.systemDecompressions))
    }
}

enum IdleLatencySamplePolicy {
    static let minimumIdleSeconds: Double = 20
    static let maximumSamples = 40
    static let maximumFrames = 32
    static func mayCapture(sampleCount: Int) -> Bool { sampleCount >= 0 && sampleCount < maximumSamples }
    static func shouldSample(idleSeconds: Double?) -> Bool {
        guard let idleSeconds else { return false }
        return idleSeconds >= minimumIdleSeconds
    }
}

#if ATTIC_IDLE_SAMPLER && arch(arm64)
@_silgen_name("AtticIdleMainThread") private func atticIdleMainThread() -> UInt32
@_silgen_name("AtticIdleReleaseThread") private func atticIdleReleaseThread(_ port: UInt32)
@_silgen_name("AtticIdleReadMetrics") private func atticIdleReadMetrics(_ port: UInt32, _ output: UnsafeMutablePointer<UInt64>)
@_silgen_name("AtticIdleCapture") private func atticIdleCapture(_ port: UInt32, _ output: UnsafeMutablePointer<UInt64>)
@_silgen_name("AtticIdleDescribePC") private func atticIdleDescribePC(
    _ pc: UInt64, _ name: UnsafeMutablePointer<CChar>, _ uuid: UnsafeMutablePointer<CChar>,
    _ offset: UnsafeMutablePointer<UInt64>
) -> UInt32

struct IdleLatencySnapshot {
    let valid: UInt64
    let counters: IdleLatencyCounters
    let footprint: UInt64
    let resident: UInt64
    let compressed: UInt64

    init(_ values: [UInt64]) {
        valid = values[0]
        counters = IdleLatencyCounters(userUS: values[1], systemUS: values[2],
                                       faults: values[3], pageins: values[4],
                                       cowFaults: values[5], systemDecompressions: values[6])
        footprint = values[7]
        resident = values[8]
        compressed = values[9]
    }
}

enum AtticIdleMach {
    static func mainThread() -> UInt32 { atticIdleMainThread() }
    static func release(_ port: UInt32) { atticIdleReleaseThread(port) }

    static func snapshot(_ thread: UInt32) -> IdleLatencySnapshot {
        var words = [UInt64](repeating: 0, count: 10)
        words.withUnsafeMutableBufferPointer { buffer in
            atticIdleReadMetrics(thread, buffer.baseAddress!)
        }
        return IdleLatencySnapshot(words)
    }

    static func image(for pc: UInt64) -> (name: String, uuid: String, offset: UInt64)? {
        var name = [CChar](repeating: 0, count: 96)
        var uuid = [CChar](repeating: 0, count: 37)
        var offset: UInt64 = 0
        let result = name.withUnsafeMutableBufferPointer { nameBuffer in
            uuid.withUnsafeMutableBufferPointer { uuidBuffer in
                atticIdleDescribePC(pc, nameBuffer.baseAddress!, uuidBuffer.baseAddress!, &offset)
            }
        }
        guard result != 0 else { return nil }
        return (String(cString: name), String(cString: uuid), offset)
    }
}

struct IdleLatencyStackSample {
    let afterStartMS: Int
    let runState: UInt64
    let waiting: Bool
    let status: UInt64
    let frames: [UInt64]
    var frameCount: Int { frames.count }
}

/// A timer and 40 preallocated sample slots exist only during an eligible
/// traced action. The private utility queue serializes capture and stop;
/// finish drains any in-flight suspend before the thread port is released.
/// All symbol lookup and logging happen after finish, with the main resumed.
/// The mutable capture buffers/timer are owned by `queue`; the completion
/// crosses back to main only after that queue has drained.
final class IdleLatencyStackSampler: @unchecked Sendable {
    private static let slotWords = 36 // 4 metadata words + 32 frame PCs.
    @MainActor private(set) static var activeCountForTesting = 0
    private let queue = DispatchQueue(label: "com.taha.Attic.IdleLatencySampler", qos: .utility)
    private let slots = UnsafeMutablePointer<UInt64>.allocate(capacity: IdleLatencySamplePolicy.maximumSamples * slotWords)
    private let times = UnsafeMutablePointer<Int>.allocate(capacity: IdleLatencySamplePolicy.maximumSamples)
    private var count = 0 // Accessed only on the private queue.
    private var timer: DispatchSourceTimer?
    private let thread: UInt32
    private let began = ProcessInfo.processInfo.systemUptime
    @MainActor private var finished = false

    private init(thread: UInt32) {
        self.thread = thread
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        timer.setEventHandler { [self] in
            guard IdleLatencySamplePolicy.mayCapture(sampleCount: count) else { return }
            let index = count
            times[index] = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            // C performs only Mach traps and fixed-size buffer writes between
            // thread_suspend / thread_resume. Swift stays outside that region.
            atticIdleCapture(thread, slots.advanced(by: index * Self.slotWords))
            count += 1
            if count == IdleLatencySamplePolicy.maximumSamples {
                timer.cancel()
                self.timer = nil
            }
        }
        timer.resume()
    }

    @MainActor static func startIfEligible(idleSeconds: Double?, thread: UInt32) -> Self? {
        guard thread != 0, activeCountForTesting == 0,
              IdleLatencySamplePolicy.shouldSample(idleSeconds: idleSeconds) else { return nil }
        activeCountForTesting += 1
        return Self(thread: thread)
    }

    @MainActor func finish() async -> [IdleLatencyStackSample] {
        guard !finished else { return [] }
        finished = true
        let result: [IdleLatencyStackSample] = await withCheckedContinuation { continuation in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                let result = (0..<count).map { index in
                    let slot = slots.advanced(by: index * Self.slotWords)
                    let frameCount = min(Int(slot[2]), IdleLatencySamplePolicy.maximumFrames)
                    return IdleLatencyStackSample(afterStartMS: times[index],
                                                  runState: slot[0], waiting: slot[1] != 0,
                                                  status: slot[3],
                                                  frames: (0..<frameCount).map { slot[4 + $0] })
                }
                continuation.resume(returning: result)
            }
        }
        Self.activeCountForTesting -= 1
        return result
    }

    deinit {
        // finish() always drains the queue before releasing these buffers.
        slots.deallocate()
        times.deallocate()
    }
}
#else
/// The API exists for policy tests, but neither sampling nor Mach code is
/// linked in Debug/Release or on unsupported architectures.
enum AtticIdleMach {
    static func mainThread() -> UInt32 { 0 }
    static func release(_ port: UInt32) {}
}
final class IdleLatencyStackSampler {
    @MainActor static let activeCountForTesting = 0
    @MainActor static func startIfEligible(idleSeconds: Double?, thread: UInt32) -> Self? { nil }
}
#endif
