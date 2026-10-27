import Foundation
import CoreGraphics
import QuartzCore


/// Constructed once, outside input handlers. Immutable handles cross the worker boundary.
final class Geometry: @unchecked Sendable {
    let strokes: [[CGPoint]]
    init(strokes: [[CGPoint]]) { self.strokes = strokes }
    static func fixture() -> Geometry {
        // Fixed integer PRNG; never Swift's randomized Hasher/random APIs.
        var seed: UInt64 = 0x4154544943
        func unit() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 32) / Double(UInt32.max)
        }
        return Geometry(strokes: (0..<2000).map { _ in
            let x = 20 + unit() * 270, y = 100 + unit() * 270
            return (0..<400).map { i in
                CGPoint(x: x + sin(Double(i) * 0.07) * 12,
                        y: y + Double(i) * 0.08)
            }
        })
    }
}

final class StrokeNode: @unchecked Sendable {
    let revision: Int
    let points: [CGPoint]
    let previous: StrokeNode?
    init(revision: Int, points: [CGPoint], previous: StrokeNode?) {
        self.revision = revision; self.points = points; self.previous = previous
    }
}

struct RasterKey: Equatable, Sendable {
    var revision = 0
    var x: Double = 0
    var y: Double = 0
    var zoom: Double = 1
    var scale: Double = 2
    var width = 320
    var height = 520
    var dark = false
}
struct RasterRequest: Sendable {
    let key: RasterKey
    let fixture: Geometry
    let strokes: StrokeNode?
}
struct RasterImage: @unchecked Sendable { let image: CGImage }

/// One worker, one replaceable pending request. Delivery checks generation AGAIN
/// on the presentation queue: a completed-but-not-delivered image can be stale too.
final class LatestRenderer<Request: Sendable, Output: Sendable>: @unchecked Sendable {
    typealias Work = @Sendable (Request, @escaping @Sendable () -> Bool) -> Output?
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "canvas.lab.raster", qos: .userInitiated)
    private let delivery: DispatchQueue
    private var generation = 0
    private var pending: (Int, Request)?
    private var running = false
    private let work: Work
    private let install: @Sendable (Request, Output) -> Void
    private let trace: @Sendable (String, Int, Double, Int) -> Void
    init(delivery: DispatchQueue = .main, work: @escaping Work,
         trace: @escaping @Sendable (String, Int, Double, Int) -> Void = { _,_,_,_ in },
         install: @escaping @Sendable (Request, Output) -> Void) {
        self.delivery = delivery; self.work = work; self.install = install; self.trace = trace
    }
    func request(_ request: Request) {
        lock.lock(); generation += 1
        pending = (generation, request)
        let start = !running; running = true
        let token = generation
        lock.unlock()
        trace("queued", token, labNow(), 1)
        if start { worker.async { self.drain() } }
    }
    private func current(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == token
    }
    private func pendingDepth() -> Int {
        lock.lock(); defer { lock.unlock() }; return pending == nil ? 0 : 1
    }
    private func drain() {
        while true {
            lock.lock()
            guard let (token, request) = pending else { running = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            trace("worker_start", token, labNow(), 0)
            let output = work(request, { !self.current(token) })
            trace(output == nil ? "cancelled" : "worker_end", token, labNow(), pendingDepth())
            if let output {
                delivery.async {
                    // Requests and installations are serialized on this queue by callers.
                    guard self.current(token) else { self.trace("stale", token, labNow(), self.pendingDepth()); return }
                    self.install(request, output)
                    self.trace("installed", token, labNow(), self.pendingDepth())
                }
            }
        }
    }
}

enum ViewportRaster {
    static func render(_ request: RasterRequest, cancelled: () -> Bool = { false }) -> RasterImage? {
        let k = request.key, w = Int(Double(k.width) * k.scale), h = Int(Double(k.height) * k.scale)
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.scaleBy(x: k.scale, y: k.scale)
        c.setFillColor(CGColor(gray: k.dark ? 0.12 : 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: k.width, height: k.height))
        c.translateBy(x: k.x, y: k.y); c.scaleBy(x: k.zoom, y: k.zoom)
        c.setStrokeColor(CGColor(gray: k.dark ? 0.85 : 0.2, alpha: 1)); c.setLineWidth(1)
        func stroke(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            c.beginPath(); c.move(to: first)
            for p in points.dropFirst() { c.addLine(to: p) }; c.strokePath()
        }
        for (i, points) in request.fixture.strokes.enumerated() {
            if i % 16 == 0 && cancelled() { return nil }
            stroke(points)
        }
        c.setStrokeColor(CGColor(gray: k.dark ? 1 : 0, alpha: 1)); c.setLineWidth(2)
        var node = request.strokes
        while let n = node {
            if cancelled() { return nil }; stroke(n.points); node = n.previous
        }
        guard !cancelled(), let image = c.makeImage() else { return nil }
        return RasterImage(image: image)
    }
}

/// Shared by the real view and in-process tests. The sync branch deliberately
/// does the forbidden work, so the same transition test must detect it.
final class RasterController: @unchecked Sendable {
    enum Mode { case synchronousReproducer, asynchronous }
    let mode: Mode
    let renderer: LatestRenderer<RasterRequest, RasterImage>
    let synchronous: (RasterRequest) -> RasterImage?
    let install: (RasterRequest, RasterImage) -> Void
    init(mode: Mode, renderer: LatestRenderer<RasterRequest, RasterImage>,
         synchronous: @escaping (RasterRequest) -> RasterImage? = { ViewportRaster.render($0) },
         install: @escaping (RasterRequest, RasterImage) -> Void) {
        self.mode = mode; self.renderer = renderer; self.synchronous = synchronous; self.install = install
    }
    func viewportInput(_ request: RasterRequest) {
        switch mode {
        case .asynchronous: renderer.request(request)
        case .synchronousReproducer:
            if let image = synchronous(request) { install(request, image) }
        }
    }
}

final class CSVLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    init(url: URL, header: String) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data((header + "\n").utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
    }
    func row(_ values: [String]) {
        lock.lock(); defer { lock.unlock() }
        handle.write(Data((values.joined(separator: ",") + "\n").utf8))
    }
    deinit { try? handle.close() }
}
