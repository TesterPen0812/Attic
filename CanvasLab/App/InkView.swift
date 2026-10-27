import AppKit
import QuartzCore

struct PendingEvent: Sendable {
    let sequence: Int, driver: Int64, event: Double, handler: Double, overlay: Double
    let type: UInt32, point: CGPoint
}
/// A retained bitmap prefix plus at most 32 points in a shape tail.
/// Prefix raster happens in display(), outside input handlers.
final class RetainedStroke: CALayer {
    private let tail = CAShapeLayer()
    private let prefix = CALayer()
    private let bitmap: CGContext
    private var pending: [[CGPoint]] = []
    private var points: [CGPoint] = []
    let revision: Int
    let viewport: RasterKey
    init(size: CGSize, scale: Double, revision: Int, viewport: RasterKey) {
        self.revision = revision;self.viewport = viewport
        bitmap = CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,
            bytesPerRow:Int(size.width*scale)*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        super.init(); frame = CGRect(origin:.zero,size:size)
        bitmap.scaleBy(x:scale,y:scale); bitmap.setStrokeColor(CGColor(gray:0,alpha:1)); bitmap.setLineWidth(2)
        prefix.frame = bounds; prefix.contentsScale = scale; addSublayer(prefix)
        tail.frame = bounds; tail.strokeColor = CGColor(gray:0,alpha:1); tail.fillColor = nil; tail.lineWidth = 2
        addSublayer(tail)
    }
    override init(layer: Any) { fatalError("No animations") }
    required init?(coder: NSCoder) { fatalError("No archives") }
    func append(_ point: CGPoint, predicted: CGPoint?) {
        points.append(point)
        if points.count > 32 {
            pending.append(points); points = [points.last!]; setNeedsDisplay()
        }
        let path = CGMutablePath()
        if let first = points.first { path.move(to:first); for p in points.dropFirst() { path.addLine(to:p) } }
        if let predicted { path.addLine(to:predicted) }; tail.path = path
    }
    override func display() {
        for points in pending {
            bitmap.beginPath(); bitmap.move(to:points[0])
            for p in points.dropFirst() { bitmap.addLine(to:p) }; bitmap.strokePath()
        }
        pending.removeAll(keepingCapacity:true); prefix.contents = bitmap.makeImage()
    }
}

final class InkView: NSView {
    let mode: String, fixture: Geometry, events: CSVLog, workers: CSVLog, predictions: CSVLog
    let sync: Bool
    var key: RasterKey, installedKey: RasterKey
    var strokes: StrokeNode?
    var activePoints: [CGPoint] = [] // world coordinates, one current stroke only
    var overlays: [RetainedStroke] = []
    var activeOverlay: RetainedStroke?
    let committed = CALayer()
    var referenceBitmap: CGContext?
    var referenceSegments: [(CGPoint,CGPoint)] = []
    var referencePending: [PendingEvent] = []
    var sequence = 0, previousTime: Double = 0
    var lastPoint: CGPoint?, prediction: CGPoint?
    var metal: MetalInk?
    var ready: (() -> Void)?
    lazy var renderer = LatestRenderer<RasterRequest,RasterImage>(work: { request, stale in
        ViewportRaster.render(request,cancelled:stale)
    }, trace: { [workers] kind, token, time, depth in
        workers.row([kind,String(token),String(time),String(Thread.isMainThread),String(depth),""])
    }, install: { [weak self] request, image in MainActor.assumeIsolated { self?.install(request,image) } })
    lazy var controller = RasterController(mode: sync ? .synchronousReproducer : .asynchronous,
        renderer:renderer, synchronous: { [workers] request in
            workers.row(["sync_start","0",String(labNow()),String(Thread.isMainThread),"0",""])
            let result = ViewportRaster.render(request)
            workers.row(["sync_end","0",String(labNow()),String(Thread.isMainThread),"0",""])
            return result
        }, install: { [weak self] request, image in self?.install(request,image) })
    init(mode: String, sync: Bool, out: URL, scale: Double) throws {
        self.mode = mode; self.sync = sync
        fixture = mode == "reference" ? Geometry(strokes:[]) : Geometry.fixture()
        key = RasterKey();key.scale = scale;installedKey = key
        events = try CSVLog(url:out.appendingPathComponent("events.csv"),header:"sequence,driver_sequence,event_monotonic_s,handler_s,overlay_s,ca_commit_submit_s,type,x,y,submit_kind")
        workers = try CSVLog(url:out.appendingPathComponent("workers.csv"),header:"kind,generation,time_s,is_main,queue_depth,duration_s")
        predictions = try CSVLog(url:out.appendingPathComponent("prediction.csv"),header:"sequence,predicted_x,predicted_y,next_x,next_y,error_px,overshoot_px,turn_degrees")
        super.init(frame:CGRect(x:0,y:0,width:320,height:520));wantsLayer = true
        layer?.backgroundColor = CGColor(gray:1,alpha:1)
        if mode == "reference" {
            referenceBitmap = CGContext(data:nil,width:Int(320*scale),height:Int(520*scale),bitsPerComponent:8,
                bytesPerRow:Int(320*scale)*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            referenceBitmap!.scaleBy(x:scale,y:scale)
            referenceBitmap!.setFillColor(CGColor(gray:1,alpha:1));referenceBitmap!.fill(bounds)
            referenceBitmap!.setStrokeColor(CGColor(gray:0,alpha:1));referenceBitmap!.setLineWidth(2)
        } else if mode == "c2" {
            metal = try MetalInk();metal!.layer.frame = bounds;layer?.addSublayer(metal!.layer)
            metal!.resize(size:bounds.size,scale:scale)
            metal!.updateViewport(key,size:bounds.size)
        } else { committed.frame = bounds;committed.contentsScale = scale;layer?.addSublayer(committed) }
    }
    required init?(coder: NSCoder) { fatalError("No archives") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func start() { controller.viewportInput(RasterRequest(key:key,fixture:fixture,strokes:strokes)) }
    func signalReady() { ready?();ready = nil }
    func install(_ request: RasterRequest, _ result: RasterImage) {
        precondition(Thread.isMainThread)
        guard request.key == key else { return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        if let metal {
            metal.install(result.image,key:request.key,active:activePoints,size:bounds.size) { [weak self] in
                guard let view = self else { return }
                DispatchQueue.main.async { view.signalReady() }
            }
        } else if mode != "reference" { committed.contents = result.image;committed.setAffineTransform(.identity) }
        overlays.removeAll { overlay in
            if overlay.revision <= request.key.revision { overlay.removeFromSuperlayer();return true };return false
        }
        installedKey = request.key
        CATransaction.commit();CATransaction.flush()
        if metal == nil { signalReady() }
    }
    override func mouseDown(with event: NSEvent) {
        let entry = labNow()
        activePoints = [];lastPoint = nil;prediction = nil
        if mode != "reference" && mode != "c2" {
            let overlay = RetainedStroke(size:bounds.size,scale:key.scale,revision:key.revision+1,viewport:key)
            overlays.append(overlay);activeOverlay = overlay;layer?.addSublayer(overlay)
        }
        accept(event,handler:entry)
    }
    override func mouseDragged(with event: NSEvent) { accept(event,handler:labNow()) }
    override func mouseUp(with event: NSEvent) {
        accept(event,handler:labNow())
        if mode != "reference" {
            key.revision += 1
            // Immutable linked handle: no whole-board snapshot in input.
            strokes = StrokeNode(revision:key.revision,points:activePoints,previous:strokes)
            metal?.updateViewport(key,size:bounds.size)
            renderer.request(RasterRequest(key:key,fixture:fixture,strokes:strokes))
        }
        activeOverlay = nil;activePoints = [];lastPoint = nil;prediction = nil
    }
    func accept(_ event: NSEvent, handler: Double) {
        let point = convert(event.locationInWindow,from:nil)
        sequence += 1
        if let prediction, let from = lastPoint {
            let dx = Double(prediction.x-from.x),dy = Double(prediction.y-from.y),length = max(hypot(dx,dy),0.00001)
            let ax = Double(point.x-from.x),ay = Double(point.y-from.y)
            let cosine = max(-1,min(1,(dx*ax+dy*ay)/(length*max(hypot(ax,ay),0.00001))))
            let turn = acos(cosine)*180/Double.pi
            let overshoot = max(0,(Double(prediction.x-point.x)*dx+Double(prediction.y-point.y)*dy)/length)*key.scale
            let error = hypot(Double(point.x-prediction.x),Double(point.y-prediction.y))*key.scale
            predictions.row([String(sequence-1),String(Double(prediction.x)),String(Double(prediction.y)),
                String(Double(point.x)),String(Double(point.y)),String(error),String(overshoot),String(turn)])
        }
        let previous = lastPoint;lastPoint = point
        if mode != "reference" { activePoints.append(CGPoint(x:(point.x-key.x)/key.zoom,y:(point.y-key.y)/key.zoom)) }
        var predicted: CGPoint?
        if mode == "c3", let previous {
            predicted = Prediction.point(previous:previous,latest:point,dt:event.timestamp-previousTime)
        }
        prediction = predicted;previousTime = event.timestamp
        CATransaction.begin();CATransaction.setDisableActions(true)
        if mode == "reference" {
            let a = previous ?? CGPoint(x:point.x-0.1,y:point.y)
            referenceSegments.append((a,point))
            setNeedsDisplay(CGRect(x:min(a.x,point.x)-3,y:min(a.y,point.y)-3,width:abs(a.x-point.x)+6,height:abs(a.y-point.y)+6))
        } else { activeOverlay?.append(point,predicted:predicted) }
        let overlay = labNow();CATransaction.commit()
        let pending = PendingEvent(sequence:sequence,driver:event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
            event:event.timestamp,handler:handler,overlay:overlay,type:event.cgEvent?.type.rawValue ?? 0,point:point)
        if let metal {
            let logger = events
            let current = activePoints.last!
            let from = activePoints.count > 1 ? activePoints[activePoints.count-2] : CGPoint(x:current.x-0.1,y:current.y)
            metal.segment(from,current,size:bounds.size) { submit in
                Self.write(logger,pending,submit:submit,kind:"metal_present_enqueue")
            }
        } else if mode == "reference" { referencePending.append(pending) }
        else { CATransaction.flush();Self.write(events,pending,submit:labNow(),kind:"ca_flush") }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard mode == "reference", let bitmap = referenceBitmap, let context = NSGraphicsContext.current?.cgContext else { return }
        // Incremental straight segments; no growing path replay, smoothing,
        // model/storage work or glass in the reference.
        for (a,b) in referenceSegments { bitmap.beginPath();bitmap.move(to:a);bitmap.addLine(to:b);bitmap.strokePath() }
        referenceSegments.removeAll(keepingCapacity:true)
        if let image = bitmap.makeImage() { context.draw(image,in:bounds) }
        let time = labNow()
        for pending in referencePending { Self.write(events,pending,submit:time,kind:"appkit_draw") }
        referencePending.removeAll(keepingCapacity:true)
    }
    nonisolated static func write(_ logger: CSVLog, _ e: PendingEvent, submit: Double, kind: String) {
        logger.row([String(e.sequence),String(e.driver),String(e.event),String(e.handler),String(e.overlay),String(submit),
                    String(e.type),String(Double(e.point.x)),String(Double(e.point.y)),kind])
    }
    override func scrollWheel(with event: NSEvent) {
        let begin = labNow()
        if event.modifierFlags.contains(.command) { key.zoom = min(2,max(0.5,key.zoom+Double(event.scrollingDeltaY)*0.01)) }
        else { key.x += Double(event.scrollingDeltaX);key.y += Double(event.scrollingDeltaY) }
        CATransaction.begin();CATransaction.setDisableActions(true)
        let ratio = key.zoom/installedKey.zoom
        let transform = CGAffineTransform(a:ratio,b:0,c:0,d:ratio,tx:key.x-installedKey.x*ratio,ty:key.y-installedKey.y*ratio)
        committed.setAffineTransform(transform)
        for overlay in overlays {
            let r = key.zoom/overlay.viewport.zoom
            overlay.setAffineTransform(CGAffineTransform(a:r,b:0,c:0,d:r,
                tx:key.x-overlay.viewport.x*r,ty:key.y-overlay.viewport.y*r))
        }
        metal?.updateViewport(key,size:bounds.size)
        CATransaction.commit()
        controller.viewportInput(RasterRequest(key:key,fixture:fixture,strokes:strokes))
        workers.row(["viewport_handler",String(sequence),String(begin),"true","0",String(labNow()-begin)])
    }
}
