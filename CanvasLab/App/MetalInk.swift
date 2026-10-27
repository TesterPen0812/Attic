import AppKit
import Metal
import QuartzCore

/// All drawable acquisition/encoding runs on a dedicated queue, never in input
/// handlers. Pixel retention and command-queue presentation bypass CA commits.
final class MetalInk: @unchecked Sendable {
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let gpu = DispatchQueue(label:"canvas.lab.direct-gpu",qos:.userInteractive)
    private let pipeline: MTLRenderPipelineState
    private var retained: MTLTexture!
    private var initialized = false
    private var width = 0, height = 0
    private let stateLock = NSLock()
    private var targetKey = RasterKey()
    private var baseKey = RasterKey() // GPU queue only
    private func target() -> RasterKey { stateLock.lock();defer { stateLock.unlock() };return targetKey }
    func updateViewport(_ key: RasterKey, size: CGSize) {
        stateLock.lock();targetKey = key;stateLock.unlock()
        gpu.async { if self.initialized { self.applyTransform();self.render([],size:size,submitted:{ _ in },completed:{}) } }
    }
    private func applyTransform() {
        let key = target(), ratio = key.zoom/baseKey.zoom
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(a:ratio,b:0,c:0,d:ratio,
            tx:key.x-baseKey.x*ratio,ty:key.y-baseKey.y*ratio))
        CATransaction.commit();CATransaction.flush()
    }
    private func screen(_ point: CGPoint) -> CGPoint { CGPoint(x:point.x*baseKey.zoom+baseKey.x,y:point.y*baseKey.zoom+baseKey.y) }
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain:"CanvasLab.Metal",code:1)
        }
        self.device = device; self.queue = queue
        layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.framebufferOnly = false
        layer.presentsWithTransaction = false; layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = true // vsync still exists; this is not photon time.
        let library = try device.makeLibrary(source:"""
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 v(const device float2 *p [[buffer(0)]], uint i [[vertex_id]]) { return float4(p[i],0,1); }
        fragment float4 f() { return float4(0,0,0,1); }
        """,options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"v"); descriptor.fragmentFunction = library.makeFunction(name:"f")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
    }
    func resize(size: CGSize, scale: Double) {
        // Initialization only, before accepting any input.
        width = Int(size.width*scale); height = Int(size.height*scale)
        layer.drawableSize = CGSize(width:width,height:height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        d.usage = [.renderTarget,.shaderRead];d.storageMode = .private;retained = device.makeTexture(descriptor:d)
    }
    func install(_ image: CGImage, key: RasterKey, active: [CGPoint], size: CGSize, ready: @escaping @Sendable () -> Void) {
        gpu.async {
            guard self.target() == key else { return } // recheck at GPU execution, not just main delivery
            guard let context = CGContext(data:nil,width:self.width,height:self.height,bitsPerComponent:8,bytesPerRow:self.width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                let bytes = context.data else { fatalError("Metal staging allocation") }
            context.draw(image,in:CGRect(x:0,y:0,width:self.width,height:self.height))
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:self.width,height:self.height,mipmapped:false)
            d.storageMode = .shared
            guard let source = self.device.makeTexture(descriptor:d), let command = self.queue.makeCommandBuffer(),
                  let blit = command.makeBlitCommandEncoder() else { fatalError("Metal staging command") }
            source.replace(region:MTLRegionMake2D(0,0,self.width,self.height),mipmapLevel:0,withBytes:bytes,bytesPerRow:self.width*4)
            blit.copy(from:source,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),
                sourceSize:.init(width:self.width,height:self.height,depth:1),to:self.retained,destinationSlice:0,destinationLevel:0,destinationOrigin:.init(x:0,y:0,z:0))
            blit.endEncoding()
            guard self.target() == key else { return } // stale staging never enters the command queue
            command.commit();self.initialized = true;self.baseKey = key;self.applyTransform()
            // ONE command/present for the entire active overlay, never a drawable per old point.
            let points = active.map { self.screen($0) }
            let pairs = Array(zip(points,points.dropFirst()))
            self.render(pairs,size:size,submitted:{ _ in },completed:ready)
        }
    }
    func segment(_ from: CGPoint, _ to: CGPoint, size: CGSize, submitted: @escaping @Sendable (Double) -> Void) {
        gpu.async { self.applyTransform();self.render([(self.screen(from),self.screen(to))],size:size,submitted:submitted,completed:{}) }
    }
    private func render(_ segments: [(CGPoint,CGPoint)], size: CGSize,
                        submitted: @escaping @Sendable (Double) -> Void, completed: @escaping @Sendable () -> Void) {
        guard let retained, let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else { fatalError("Metal drawable/command unavailable") }
        var vertices = [SIMD2<Float>]();vertices.reserveCapacity(segments.count*6)
        for (a,b) in segments {
            let length = max(hypot(b.x-a.x,b.y-a.y),0.001)
            let radius = baseKey.zoom/target().zoom
            let n = CGPoint(x:-(b.y-a.y)/length*radius,y:(b.x-a.x)/length*radius)
            let points = [CGPoint(x:a.x+n.x,y:a.y+n.y),CGPoint(x:a.x-n.x,y:a.y-n.y),CGPoint(x:b.x+n.x,y:b.y+n.y),
                          CGPoint(x:b.x+n.x,y:b.y+n.y),CGPoint(x:a.x-n.x,y:a.y-n.y),CGPoint(x:b.x-n.x,y:b.y-n.y)]
            vertices.append(contentsOf:points.map { SIMD2<Float>(Float($0.x/size.width*2-1),Float($0.y/size.height*2-1)) })
        }
        if !vertices.isEmpty {
            let pass = MTLRenderPassDescriptor();pass.colorAttachments[0].texture = retained
            pass.colorAttachments[0].loadAction = .load;pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor:pass),
                  let buffer = device.makeBuffer(bytes:vertices,length:vertices.count*MemoryLayout<SIMD2<Float>>.stride,options:.storageModeShared) else { fatalError("Metal encode allocation") }
            encoder.setRenderPipelineState(pipeline);encoder.setVertexBuffer(buffer,offset:0,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count);encoder.endEncoding()
        }
        guard let blit = command.makeBlitCommandEncoder() else { fatalError("Metal drawable blit") }
        blit.copy(from:retained,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:width,height:height,depth:1),
            to:drawable.texture,destinationSlice:0,destinationLevel:0,destinationOrigin:.init(x:0,y:0,z:0))
        blit.endEncoding();command.present(drawable)
        command.addCompletedHandler { buffer in
            guard buffer.status == .completed else { fatalError("Metal command failed") };completed()
        }
        command.commit();submitted(labNow())
    }
}
