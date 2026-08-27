import AppKit
import CoreVideo
import MetalKit
import QuartzCore

struct OpticalMetalRenderState: Equatable {
    let profile: OpticalGlassProfile
    let workload: OpticalWorkloadProfile
    let region: OpticalCaptureRegion
    let panelSizePoints: CGSize
    let cornerRadiusPoints: CGFloat
    let backingScale: Double
    let tintColor: SIMD4<Float>
    let surfaceColor: SIMD4<Float>
    let interactionMultiplier: Double
}

struct OpticalMetalUniforms: Equatable {
    var geometry0: SIMD4<Float>
    var geometry1: SIMD4<Float>
    var optics0: SIMD4<Float>
    var optics1: SIMD4<Float>
    var optics2: SIMD4<Float>
    var optics3: SIMD4<Float>
    var tintColor: SIMD4<Float>
    var surfaceColor: SIMD4<Float>

    static func make(
        textureWidth: Int,
        textureHeight: Int,
        state: OpticalMetalRenderState
    ) -> OpticalMetalUniforms {
        let sourceWidth = max(Double(state.region.sourceRect.width), 1)
        let sourceHeight = max(Double(state.region.sourceRect.height), 1)
        let panelRect = state.region.panelRectInCapturePoints
        let normalizedOrigin = SIMD2<Float>(
            Float(Double(panelRect.minX) / sourceWidth),
            Float(Double(panelRect.minY) / sourceHeight)
        )
        let normalizedSize = SIMD2<Float>(
            Float(Double(panelRect.width) / sourceWidth),
            Float(Double(panelRect.height) / sourceHeight)
        )
        let panelPhysicalSize = SIMD2<Float>(
            Float(Double(state.panelSizePoints.width) * state.backingScale),
            Float(Double(state.panelSizePoints.height) * state.backingScale)
        )

        return OpticalMetalUniforms(
            geometry0: SIMD4<Float>(
                Float(textureWidth),
                Float(textureHeight),
                normalizedOrigin.x,
                normalizedOrigin.y
            ),
            geometry1: SIMD4<Float>(
                normalizedSize.x,
                normalizedSize.y,
                panelPhysicalSize.x,
                panelPhysicalSize.y
            ),
            optics0: SIMD4<Float>(
                Float(Double(state.cornerRadiusPoints) * state.backingScale),
                Float(state.profile.refractionBandPixels),
                Float(state.profile.baseDisplacementPixels),
                Float(state.workload.captureScale)
            ),
            optics1: SIMD4<Float>(
                Float(state.profile.frostRadius),
                Float(state.profile.surfaceOpacity),
                Float(state.profile.edgeShineOpacity),
                Float(state.profile.tintOpacity)
            ),
            optics2: SIMD4<Float>(
                Float(state.profile.readabilityOpacity),
                Float(state.interactionMultiplier),
                Float(state.workload.blurSampleCount),
                Float(state.workload.edgeEvaluationCount)
            ),
            optics3: SIMD4<Float>(
                Float(state.workload.maximumDisplacementPixels),
                0,
                0,
                0
            ),
            tintColor: state.tintColor,
            surfaceColor: state.surfaceColor
        )
    }
}

@MainActor
final class OpticalMetalRenderer: NSObject, MTKViewDelegate {
    let view: MTKView

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let metrics: OpticalPerformanceMetrics
    private var textureCache: CVMetalTextureCache?
    private var latestFrame: OpticalCaptureFrame?
    private var latestState: OpticalMetalRenderState?
    private var lifecycle = OpticalRendererLifecycle()

    static var isSupported: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    init?(metrics: OpticalPerformanceMetrics) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        let library: MTLLibrary
        let pipelineState: MTLRenderPipelineState
        let samplerState: MTLSamplerState
        do {
            library = try device.makeLibrary(
                source: OpticalShaderLibrary.source,
                options: nil
            )
            guard let vertexFunction = library.makeFunction(
                name: "attic_optical_vertex"
            ), let fragmentFunction = library.makeFunction(
                name: "attic_optical_fragment"
            ) else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Attic Optical Glass"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.mipFilter = .notMipmapped
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            guard let createdSampler = device.makeSamplerState(
                descriptor: samplerDescriptor
            ) else {
                return nil
            }
            samplerState = createdSampler
        } catch {
            NSLog("Attic optical Metal pipeline unavailable: %@", error.localizedDescription)
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        ) == kCVReturnSuccess, let cache else {
            return nil
        }

        let view = MTKView(frame: .zero, device: device)
        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.samplerState = samplerState
        self.metrics = metrics
        textureCache = cache
        self.view = view
        super.init()

        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.autoResizeDrawable = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
    }

    func submit(
        frame: OpticalCaptureFrame,
        state: OpticalMetalRenderState
    ) {
        prepareResourcesIfNeeded()
        if latestFrame != nil {
            metrics.recordDroppedFrame()
        }
        latestFrame = frame
        latestState = state
        lifecycle.didReceiveFrame()
        metrics.updateMemoryEstimate(
            pixelWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
            pixelHeight: CVPixelBufferGetHeight(frame.pixelBuffer),
            bytesPerPixel: 4,
            queueDepth: state.workload.queueDepth,
            rendererTextureCount: 2
        )
        view.isPaused = false
        view.draw()
    }

    func releaseResources() {
        latestFrame = nil
        latestState = nil
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        textureCache = nil
        lifecycle.release()
        view.isPaused = true
    }

    func draw(in view: MTKView) {
        guard let frame = latestFrame,
              let state = latestState,
              let textureCache,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }
        latestFrame = nil

        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            frame.pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let backdropTexture = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                  descriptor: renderPassDescriptor
              ) else {
            metrics.recordDroppedFrame()
            return
        }

        var uniforms = OpticalMetalUniforms.make(
            textureWidth: width,
            textureHeight: height,
            state: state
        )
        encoder.label = "Attic Optical Glass"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(backdropTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<OpticalMetalUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        let retention = OpticalMetalFrameRetention(
            frame: frame,
            texture: cvTexture
        )
        let startedAt = CACurrentMediaTime()
        commandBuffer.addCompletedHandler { [metrics] _ in
            _ = retention
            metrics.recordRenderedFrame(
                durationMilliseconds: (CACurrentMediaTime() - startedAt) * 1_000
            )
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func prepareResourcesIfNeeded() {
        guard textureCache == nil else {
            if !lifecycle.isPrepared {
                lifecycle.prepare()
            }
            return
        }
        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        ) == kCVReturnSuccess {
            textureCache = cache
            lifecycle.prepare()
        }
    }
}

private final class OpticalMetalFrameRetention: @unchecked Sendable {
    let frame: OpticalCaptureFrame
    let texture: CVMetalTexture

    init(frame: OpticalCaptureFrame, texture: CVMetalTexture) {
        self.frame = frame
        self.texture = texture
    }
}

extension NSColor {
    func opticalSIMDColor() -> SIMD4<Float> {
        let color = usingColorSpace(NSColorSpace.sRGB) ?? self
        return SIMD4<Float>(
            Float(color.redComponent),
            Float(color.greenComponent),
            Float(color.blueComponent),
            Float(color.alphaComponent)
        )
    }
}
