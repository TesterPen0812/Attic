import Foundation

/// The diagnostic is intentionally a preview-only compile-time feature. The
/// official release has no writer, filesystem access or event collection.
enum FirstTouchLogAvailability {
    #if ATTIC_FIRST_TOUCH_LOG && ATTIC_LOCAL_ONLY && arch(arm64)
    static let enabled = true
    #else
    static let enabled = false
    #endif
}

#if ATTIC_FIRST_TOUCH_LOG && ATTIC_LOCAL_ONLY && arch(arm64)
/// A fixed schema: only clocks, preselected stage names and system counters.
/// Records are encoded and written off main, after the input has been returned.
struct FirstTouchLogRecord: Codable, Sendable {
    let version: Int
    let id: Int
    let event: String
    let atNS: UInt64
    var run: String? = nil
    var originNS: UInt64? = nil
    var kind: String? = nil
    var stage: String? = nil
    var control: String? = nil
    var spanStartNS: UInt64? = nil
    var count: Int? = nil
    var dueNS: UInt64? = nil
    var revealDelayMS: Double? = nil
    var idleMS: Double? = nil
    var firstAfterIdle: Bool? = nil
    var hiddenMS: Double? = nil
    var page: String? = nil
    var released: Bool? = nil
    var snapshot: Bool? = nil
    var hideMode: String? = nil
    var napActivity: Bool? = nil
    var memory: FirstTouchMemory? = nil
    var sampledAfterMS: Double? = nil
    var wallEpochMS: Double? = nil

    init(id: Int, event: String, atNS: UInt64) {
        version = 1
        self.id = id
        self.event = event
        self.atNS = atNS
    }
}

struct FirstTouchMemory: Codable, Sendable {
    let valid: UInt64
    let footprintBytes: UInt64
    let residentBytes: UInt64
    let compressedBytes: UInt64
    let faults: UInt64
    let pageins: UInt64

    init(_ values: [UInt64]) {
        valid = values[0]
        footprintBytes = values[1]
        residentBytes = values[2]
        compressedBytes = values[3]
        faults = values[4]
        pageins = values[5]
    }
}

/// One rolling file, bounded to 512 KiB. Trimming retains whole JSON lines.
/// All calls occur on the writer's private queue (or directly in a test).
final class FirstTouchRollingFile {
    let url: URL
    let maximumBytes: Int
    private var handle: FileHandle?
    private var used = 0

    init(url: URL, maximumBytes: Int = 512 * 1024) {
        precondition(maximumBytes > 0)
        self.url = url
        self.maximumBytes = maximumBytes
    }

    func append(_ line: Data) throws {
        guard !line.isEmpty, line.count <= maximumBytes, line.last == 10 else { return }
        if handle == nil { try open() }
        if used + line.count > maximumBytes {
            let previous = try Data(contentsOf: url)
            // The incoming record may itself use over half the budget.
            // Reserve its entire length before selecting prior records.
            let keepBudget = min(maximumBytes / 2, maximumBytes - line.count)
            var retained = Data(previous.suffix(keepBudget))
            // If the suffix began mid-record, remove the incomplete first line.
            if retained.count < previous.count, let boundary = retained.firstIndex(of: 10) {
                retained.removeSubrange(retained.startIndex...boundary)
            } else if retained.count < previous.count {
                retained.removeAll()
            }
            try handle?.close()
            handle = nil
            try retained.write(to: url, options: .atomic)
            try open()
        }
        try handle?.write(contentsOf: line)
        used += line.count
    }

    private func open() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
        let file = try FileHandle(forWritingTo: url)
        used = Int(try file.seekToEnd())
        handle = file
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }
}

@_silgen_name("AtticFirstTouchReadMemory")
private func atticFirstTouchReadMemory(_ output: UnsafeMutablePointer<UInt64>)

/// Only enqueue is called by input handlers. Encoding, Mach task_info and all
/// disk IO occur on this utility queue. No background timer is installed.
final class FirstTouchLogWriter: @unchecked Sendable {
    static let shared = FirstTouchLogWriter()
    private let queue = DispatchQueue(label: "com.taha.Attic.FirstTouchLog", qos: .utility)
    // Fail closed if a Local build accidentally has the official release ID.
    // Only isolated preview / invisible unit-host identities may write.
    private let isIsolatedPreview = Bundle.main.bundleIdentifier?.hasPrefix("com.taha.Attic.") == true
    private var file: FirstTouchRollingFile?
    private let encoder = JSONEncoder()
    private let runID = UUID().uuidString

    private init() {}

    func submit(_ record: FirstTouchLogRecord) {
        guard isIsolatedPreview else { return }
        queue.async { [self] in
            if file == nil {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                file = FirstTouchRollingFile(url: support.appendingPathComponent("Attic/Diagnostics/first-touch.jsonl"))
            }
            write(record)
            // Attribute page-ins/faults to the approach, the render preflight
            // and the eventual reveal or click (not just input -> frame).
            let samplesStage = record.event == "stage" && [
                "hotspot_entered", "island_hover_entered", "island_hover_left",
                "warmup_begin", "warmup_end",
                "reveal_decision", "view_dispatch_done", "page_change_decision"
            ].contains(record.stage ?? "")
            if record.event == "input" || record.event == "frame_candidate" || samplesStage {
                var words = [UInt64](repeating: 0, count: 6)
                words.withUnsafeMutableBufferPointer { buffer in
                    atticFirstTouchReadMemory(buffer.baseAddress!)
                }
                let sampled = DispatchTime.now().uptimeNanoseconds
                var sample = FirstTouchLogRecord(id: record.id, event: "memory", atNS: sampled)
                sample.stage = record.stage ?? record.event
                sample.memory = FirstTouchMemory(words)
                sample.sampledAfterMS = Double(sampled >= record.atNS ? sampled - record.atNS : 0) / 1_000_000
                write(sample)
            }
        }
    }

    private func write(_ source: FirstTouchLogRecord) {
        var record = source
        record.run = runID
        let sampledNS = DispatchTime.now().uptimeNanoseconds
        record.wallEpochMS = Date().timeIntervalSince1970 * 1000
            - Double(sampledNS >= record.atNS ? sampledNS - record.atNS : 0) / 1_000_000
        guard var line = try? encoder.encode(record) else { return }
        line.append(10)
        try? file?.append(line)
    }
}
#endif
