import Foundation

struct CanvasCoreSample: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    /// Monotonic device time in microseconds. Large deltas are escaped in v2.
    let time: UInt64
    let pressure: Double?
    var valid: Bool {
        x.isFinite && y.isFinite && (pressure.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }
}
struct CanvasCoreInk: Equatable, Sendable {
    var color: String
    var width: Double
    var samples: [CanvasCoreSample]
}
enum CanvasCoreInkCodec {
    // Provisional admission, NOT a schema freeze: interim Spike A's highest
    // measured delivery is 135/s. ceil(135 * 600) = 81,000. Revisit if final
    // physical-device/presentation evidence changes that peak or mechanism.
    static let maximumSamples = 81_000
    static let maximumBytes = 32 + maximumSamples * 20
    static let colors = ["ink", "blue", "red", "green", "orange"]
    static func encode(_ ink: CanvasCoreInk) throws -> Data {
        guard colors.contains(ink.color), ink.width.isFinite, ink.width > 0, ink.width <= 64,
              !ink.samples.isEmpty, ink.samples.count <= maximumSamples else { throw CanvasCoreError.admission }
        var bytes = Data([0x41, 0x54, 0x49, 0x4b])
        bytes.reserveCapacity(24 + ink.samples.count * 12)
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        put(UInt16(2)); put(UInt16(0)); put(UInt32(ink.samples.count)); put(UInt32(colors.firstIndex(of: ink.color)!))
        put(ink.width.bitPattern)
        var previous: UInt64 = 0
        for sample in ink.samples {
            let x = Float(sample.x), y = Float(sample.y)
            guard sample.valid, sample.time >= previous, x.isFinite, y.isFinite,
                  abs(Double(x) - sample.x) <= 1.0 / 1_024, abs(Double(y) - sample.y) <= 1.0 / 1_024 else { throw CanvasCoreError.invalidGeometry }
            put(x.bitPattern); put(y.bitPattern)
            put(sample.pressure.map(pressureBits) ?? UInt16(0x7e00))
            let delta = sample.time - previous
            if delta < UInt64(UInt16.max) { put(UInt16(delta)) }
            else { put(UInt16.max); put(sample.time) }
            previous = sample.time
        }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> CanvasCoreInk {
        guard bytes.count >= 24, bytes.count <= maximumBytes, Array(bytes.prefix(4)) == [0x41, 0x54, 0x49, 0x4b] else { throw CanvasCoreError.invalidPayload }
        var offset = 4
        func take<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            guard offset + MemoryLayout<T>.size <= bytes.count else { throw CanvasCoreError.invalidPayload }
            var value: T = 0
            for i in 0..<MemoryLayout<T>.size { value |= T(bytes[offset + i]) << (i * 8) }
            offset += MemoryLayout<T>.size; return value
        }
        guard try take(UInt16.self) == 2 else { throw CanvasCoreError.unsupportedVersion }
        guard try take(UInt16.self) == 0 else { throw CanvasCoreError.unsupportedVersion }
        let count = Int(try take(UInt32.self)), color = Int(try take(UInt32.self))
        let width = Double(bitPattern: try take(UInt64.self))
        guard (1...maximumSamples).contains(count), colors.indices.contains(color), width.isFinite, width > 0, width <= 64 else { throw CanvasCoreError.admission }
        var samples: [CanvasCoreSample] = []; samples.reserveCapacity(count)
        var previous: UInt64 = 0
        for _ in 0..<count {
            let x = Double(Float(bitPattern: try take(UInt32.self))), y = Double(Float(bitPattern: try take(UInt32.self)))
            let raw = try take(UInt16.self)
            let pressure = raw == 0x7e00 ? nil : Optional(pressureValue(raw))
            let delta = try take(UInt16.self)
            let time: UInt64
            if delta == UInt16.max { time = try take(UInt64.self) }
            else {
                let sum = previous.addingReportingOverflow(UInt64(delta))
                guard !sum.overflow else { throw CanvasCoreError.overflow }; time = sum.partialValue
            }
            let sample = CanvasCoreSample(x: x, y: y, time: time, pressure: pressure)
            guard sample.valid, time >= previous else { throw CanvasCoreError.invalidPayload }
            samples.append(sample); previous = time
        }
        guard offset == bytes.count else { throw CanvasCoreError.invalidPayload }
        return .init(color: colors[color], width: width, samples: samples)
    }
    // Swift Float16 is unavailable on Intel Macs. Encode the same IEEE binary16
    // normalized-pressure representation without imposing an architecture gate.
    private static func pressureBits(_ value: Double) -> UInt16 {
        let bits = Float(value).bitPattern
        let exponent = Int((bits >> 23) & 255) - 127 + 15
        let mantissa = bits & 0x7fffff
        if exponent <= 0 {
            if exponent < -10 { return 0 }
            let shift = 14 - exponent, significand = mantissa | 0x800000
            let base = significand >> shift, remainder = significand & ((1 << shift) - 1), half = UInt32(1 << (shift - 1))
            return UInt16(base + (remainder > half || (remainder == half && base & 1 != 0) ? 1 : 0))
        }
        let base = UInt32(exponent << 10) | (mantissa >> 13), remainder = mantissa & 0x1fff
        return UInt16(base + (remainder > 0x1000 || (remainder == 0x1000 && base & 1 != 0) ? 1 : 0))
    }
    private static func pressureValue(_ bits: UInt16) -> Double {
        let exponent = Int((bits >> 10) & 31), fraction = Double(bits & 1023)
        guard bits & 0x8000 == 0, exponent != 31 else { return .nan }
        return exponent == 0 ? fraction * pow(2, -24) : (1 + fraction / 1_024) * pow(2, Double(exponent - 15))
    }
    /// Independent v1 compatibility reader. Canonical JSON is never rewritten.
    static func decodeLegacy(_ bytes: Data) throws -> CanvasCoreInk {
        struct Point: Decodable { let x: Double; let y: Double }
        struct Archive: Decodable { let version: Int; let color: String; let width: Double; let points: [Point] }
        guard bytes.count <= 900 * 1_024 else { throw CanvasCoreError.admission }
        let value = try JSONDecoder().decode(Archive.self, from: bytes)
        guard value.version == 1 else { throw CanvasCoreError.unsupportedVersion }
        let ink = CanvasCoreInk(color: value.color, width: value.width,
            samples: value.points.map { .init(x: $0.x, y: $0.y, time: 0, pressure: nil) })
        guard colors.contains(ink.color), ink.width.isFinite, ink.width > 0, ink.width <= 64,
              (1...12_000).contains(ink.samples.count), ink.samples.allSatisfy(\.valid) else { throw CanvasCoreError.invalidPayload }
        return ink
    }
}

struct CanvasCoreInputReducer {
    enum Mode: Equatable { case idle, ink, erase, shape, marquee, transform, pointerPan, viewportGesture, nativeText }
    struct Identity: Hashable { let device: Int; let sequence: UInt64; let event: UInt64 }
    struct Viewport: Equatable { var x = 0.0; var y = 0.0; var scale = 1.0 }
    enum Event {
        case begin(Mode, UInt64, Viewport)
        case sample(Identity, CanvasCoreSample)
        case space
        case incidentalGesture(UInt64)
        case gestureEnd(UInt64)
        case end(UInt64)
        case interrupt
        case saveResolved(Bool)
        case retry
    }
    enum Effect: Equatable { case commit(UUID, [CanvasCoreSample]), capReached, restoreCoalescing, refuse }
    private(set) var mode: Mode = .idle
    private(set) var samples: [CanvasCoreSample] = []
    private(set) var frozenViewport = Viewport()
    private(set) var pendingID: UUID?
    private(set) var deferredPan = false
    private var sequence: UInt64?
    private var suppressed: Set<UInt64> = []
    private var seen: Set<Identity> = []
    mutating func reduce(_ event: Event) -> [Effect] {
        switch event {
        case let .begin(next, id, viewport):
            // Other gesture states are contract names for later native slices;
            // an unbuilt route must refuse, never accept an inert gesture.
            guard next == .ink, mode == .idle, pendingID == nil, !suppressed.contains(id), viewport.scale.isFinite, viewport.scale > 0 else { return [.refuse] }
            mode = next; sequence = id; frozenViewport = viewport
            samples = []; seen = []; deferredPan = false
            return []
        case let .sample(id, sample):
            guard mode == .ink, sequence == id.sequence, !suppressed.contains(id.sequence), sample.valid,
                  sample.time >= (samples.last?.time ?? 0), !seen.contains(id) else { return [] }
            seen.insert(id); samples.append(sample)
            if samples.count == CanvasCoreInkCodec.maximumSamples {
                suppressed.insert(id.sequence); return finish() + [.capReached]
            }
            return []
        case .space:
            if mode == .ink { deferredPan = true; return [] }
            return [.refuse]
        case let .incidentalGesture(id):
            if mode != .idle || pendingID != nil { suppressed.insert(id); return [.refuse] }
            return []
        case let .gestureEnd(id): suppressed.remove(id); return []
        case let .end(id):
            if suppressed.remove(id) != nil { return [] }
            guard sequence == id else { return [] }; return finish()
        case .interrupt:
            if let sequence { suppressed.insert(sequence) }; return finish()
        case let .saveResolved(committed):
            if committed { pendingID = nil; samples = []; seen = [] }
            return []
        case .retry:
            guard let id = pendingID else { return [] }; return [.commit(id, samples)]
        }
    }
    private mutating func finish() -> [Effect] {
        let previous = mode; mode = .idle; sequence = nil
        guard previous == .ink else { return [] }
        guard !samples.isEmpty else { return [.restoreCoalescing] }
        let id = pendingID ?? UUID(); pendingID = id
        return [.commit(id, samples), .restoreCoalescing]
    }
}
