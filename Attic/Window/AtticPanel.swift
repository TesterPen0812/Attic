import AppKit
import CoreImage
import QuartzCore

final class AtticPanel: NSPanel {
    var opticalInteractionHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved:
            opticalInteractionHandler?()
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// A public Core Image warp that maps destination pixels back into the live
/// background sampled by `NSVisualEffectView`. The center and any point beyond
/// the edge band return their destination coordinate exactly, so there is no
/// center seam or whole-panel stretch.
final class AtticOpticalWarpFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    @objc dynamic var inputCornerRadius: NSNumber = 18
    @objc dynamic var inputBand: NSNumber = 0
    @objc dynamic var inputDisplacement: NSNumber = 0

    static var isAvailable: Bool { warpKernel != nil }

    private static let metalSource = #"""
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    static inline float attic_smoothstep(float value) {
        float t = clamp(value, 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    extern "C" {
        namespace coreimage {
            float2 attic_optical_warp(
                destination dest,
                float4 extent,
                float radius,
                float band,
                float displacement
            ) {
                float2 destinationCoordinate = dest.coord();
                if (band <= 0.0f || displacement <= 0.0f) {
                    return destinationCoordinate;
                }

                float2 size = max(extent.zw, float2(0.0001f));
                float2 local = destinationCoordinate - extent.xy;
                float2 halfSize = size * 0.5f;
                float clampedRadius = clamp(
                    radius,
                    0.0f,
                    min(halfSize.x, halfSize.y)
                );
                float2 centered = local - halfSize;
                float2 signs = select(
                    float2(-1.0f),
                    float2(1.0f),
                    centered >= float2(0.0f)
                );
                float2 q = abs(centered) - (halfSize - clampedRadius);
                float2 positive = max(q, float2(0.0f));

                constexpr float exponent = 5.0f;
                float sum = pow(positive.x, exponent)
                    + pow(positive.y, exponent);
                float roundedDistance = pow(max(sum, 0.0f), 1.0f / exponent);
                float interiorDistance = min(max(q.x, q.y), 0.0f);
                float signedDistance = roundedDistance
                    + interiorDistance
                    - clampedRadius;
                if (signedDistance > 0.0f) {
                    return destinationCoordinate;
                }

                float2 outwardGradient;
                if (positive.x > 0.0f || positive.y > 0.0f) {
                    float denominator = pow(
                        max(sum, 0.000001f),
                        (exponent - 1.0f) / exponent
                    );
                    outwardGradient = float2(
                        pow(positive.x, exponent - 1.0f),
                        pow(positive.y, exponent - 1.0f)
                    ) / denominator;
                    outwardGradient *= signs;
                } else if (q.x > q.y) {
                    outwardGradient = float2(signs.x, 0.0f);
                } else if (q.y > q.x) {
                    outwardGradient = float2(0.0f, signs.y);
                } else {
                    outwardGradient = normalize(signs);
                }

                float gradientLength = max(length(outwardGradient), 0.0001f);
                float distanceInside = max(0.0f, -signedDistance) / gradientLength;
                if (distanceInside >= band) {
                    return destinationCoordinate;
                }

                float influence = attic_smoothstep(1.0f - distanceInside / band);
                float2 inwardNormal = -outwardGradient / gradientLength;
                float bottomProximity = 1.0f - clamp(local.y / size.y, 0.0f, 1.0f);
                float bottomWeight = attic_smoothstep(
                    (bottomProximity - 0.58f) / 0.42f
                );
                float cornerWeight = min(
                    1.0f,
                    2.0f * abs(inwardNormal.x * inwardNormal.y)
                );
                float edgeMultiplier = min(
                    1.22f,
                    0.84f + 0.16f * bottomWeight + 0.22f * cornerWeight
                );

                return destinationCoordinate
                    + inwardNormal * displacement * edgeMultiplier * influence;
            }
        }
    }
    """#

    private static let warpKernel: CIWarpKernel? = {
        do {
            return try CIKernel.kernels(withMetalString: metalSource)
                .first { $0.name == "attic_optical_warp" } as? CIWarpKernel
        } catch {
            NSLog("Attic optical Metal kernel unavailable: %@", error.localizedDescription)
            return nil
        }
    }()

    override init() {
        super.init()
        name = "atticOpticalWarp"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        name = "atticOpticalWarp"
    }

    override var attributes: [String: Any] {
        [
            kCIAttributeFilterDisplayName: "Attic Optical Warp",
            kCIInputImageKey: [
                kCIAttributeClass: "CIImage",
                kCIAttributeType: kCIAttributeTypeImage
            ],
            "inputCornerRadius": [
                kCIAttributeClass: "NSNumber",
                kCIAttributeDefault: 18,
                kCIAttributeMin: 0,
                kCIAttributeType: kCIAttributeTypeDistance
            ],
            "inputBand": [
                kCIAttributeClass: "NSNumber",
                kCIAttributeDefault: 0,
                kCIAttributeMin: 0,
                kCIAttributeType: kCIAttributeTypeDistance
            ],
            "inputDisplacement": [
                kCIAttributeClass: "NSNumber",
                kCIAttributeDefault: 0,
                kCIAttributeIdentity: 0,
                kCIAttributeMin: 0,
                kCIAttributeType: kCIAttributeTypeDistance
            ]
        ]
    }

    override var outputImage: CIImage? {
        guard let inputImage else { return nil }
        let band = inputBand.doubleValue
        let displacement = inputDisplacement.doubleValue
        guard band > 0, displacement > 0, let warpKernel = Self.warpKernel else {
            return inputImage
        }

        let extent = inputImage.extent
        guard !extent.isEmpty, !extent.isInfinite else { return inputImage }
        let maximumOffset = CGFloat(
            displacement * PanelOpticalBoundary.maximumEdgeMultiplier
        )

        return warpKernel.apply(
            extent: extent,
            roiCallback: { _, destinationRect in
                destinationRect.insetBy(
                    dx: -maximumOffset,
                    dy: -maximumOffset
                )
            },
            image: inputImage,
            arguments: [
                CIVector(cgRect: extent),
                inputCornerRadius,
                inputBand,
                inputDisplacement
            ]
        )
    }
}

@MainActor
final class OpticalPanelBackdropView: NSView {
    private struct RenderKey: Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
        let cornerRadius: Double
        let backingScale: Double
        let profile: OpticalGlassProfile
        let reduceTransparency: Bool
    }

    private let effectView = NSVisualEffectView()
    private let overlayView = OpticalPassthroughView()
    private let panelMask = CAShapeLayer()
    private let effectMask = CAShapeLayer()
    private let overlayMask = CAShapeLayer()
    private let surfaceLayer = CALayer()
    private let tintLayer = CALayer()
    private let readabilityLayer = CAGradientLayer()
    private let edgeShineLayer = CAGradientLayer()
    private let edgeBandMask = CAShapeLayer()

    private var controls: OpticalGlassControls
    private var profile: OpticalGlassProfile
    private var cornerRadius: CGFloat
    private var lifecycle = OpticalBackdropLifecycle()
    private var lastRenderKey: RenderKey?
    private var restDisplacementPoints = 0.0
    private var lastInteractionTime: CFTimeInterval = 0
    private(set) var backend: OpticalBackdropBackend = .liveMaterial

    var samplingBlendingMode: NSVisualEffectView.BlendingMode {
        effectView.blendingMode
    }

    var samplingState: NSVisualEffectView.State {
        effectView.state
    }

    init(controls: OpticalGlassControls, cornerRadius: CGFloat) {
        self.controls = controls
        profile = OpticalGlassProfile.resolve(
            controls: controls,
            windowActivity: .key
        )
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        panelMask.fillColor = NSColor.black.cgColor
        layer?.mask = panelMask

        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layerUsesCoreImageFilters = true
        effectView.layer?.backgroundColor = NSColor.clear.cgColor
        effectView.layer?.masksToBounds = true
        effectMask.fillColor = NSColor.black.cgColor
        effectView.layer?.mask = effectMask
        addSubview(effectView)

        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.clear.cgColor
        overlayView.layer?.masksToBounds = true
        overlayMask.fillColor = NSColor.black.cgColor
        overlayView.layer?.mask = overlayMask
        addSubview(overlayView)

        readabilityLayer.type = .radial
        readabilityLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        readabilityLayer.endPoint = CGPoint(x: 1, y: 1)
        readabilityLayer.locations = [0, 0.58, 1]

        edgeShineLayer.startPoint = CGPoint(x: 0, y: 1)
        edgeShineLayer.endPoint = CGPoint(x: 1, y: 0)
        edgeShineLayer.locations = [0, 0.20, 0.72, 1]
        edgeBandMask.fillRule = .evenOdd
        edgeBandMask.fillColor = NSColor.black.cgColor
        edgeShineLayer.mask = edgeBandMask

        overlayView.layer?.addSublayer(surfaceLayer)
        overlayView.layer?.addSublayer(tintLayer)
        overlayView.layer?.addSublayer(readabilityLayer)
        overlayView.layer?.addSublayer(edgeShineLayer)

        lifecycle.install()
        updateSemanticColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        overlayView.frame = bounds
        updateMasksAndOverlayFrames()
        rebuildFiltersIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateRendering()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateRendering()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSemanticColors()
    }

    func update(controls: OpticalGlassControls, cornerRadius: CGFloat) {
        let newProfile = OpticalGlassProfile.resolve(
            controls: controls,
            windowActivity: .key
        )
        guard controls != self.controls
                || newProfile != profile
                || cornerRadius != self.cornerRadius else {
            return
        }

        self.controls = controls
        profile = newProfile
        self.cornerRadius = cornerRadius
        invalidateRendering()
    }

    func setVisible(_ isVisible: Bool) {
        if lifecycle.phase == .stopped {
            lifecycle.install()
            invalidateRendering()
        }
        if isVisible {
            lifecycle.show()
            rebuildFiltersIfNeeded()
            pulseInteraction()
        } else {
            lifecycle.hide()
            effectView.layer?.removeAnimation(forKey: "atticInteractionResponse")
        }
    }

    func respondToInteraction() {
        guard lifecycle.phase == .visible else { return }
        let now = CACurrentMediaTime()
        guard now - lastInteractionTime >= 0.08 else { return }
        lastInteractionTime = now
        pulseInteraction()
    }

    func stop() {
        lifecycle.stop()
        effectView.layer?.removeAllAnimations()
        effectView.contentFilters = []
        lastRenderKey = nil
        restDisplacementPoints = 0
    }

    private func invalidateRendering() {
        lastRenderKey = nil
        needsLayout = true
        if bounds.width > 0, bounds.height > 0 {
            layoutSubtreeIfNeeded()
        }
    }

    private func updateMasksAndOverlayFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let outerPath = SquircleGeometry.path(
            in: bounds,
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent,
            segmentsPerCorner: 64
        )
        for mask in [panelMask, effectMask, overlayMask] {
            mask.frame = bounds
            mask.path = outerPath
        }

        surfaceLayer.frame = bounds
        tintLayer.frame = bounds
        readabilityLayer.frame = bounds
        edgeShineLayer.frame = bounds
        edgeBandMask.frame = bounds

        let bandWidth = min(
            max(CGFloat(profile.refractionBandPixels / currentBackingScale) * 0.52, 8),
            18
        )
        let innerRect = bounds.insetBy(dx: bandWidth, dy: bandWidth)
        let combinedPath = CGMutablePath()
        combinedPath.addPath(outerPath)
        if innerRect.width > 0, innerRect.height > 0 {
            combinedPath.addPath(
                SquircleGeometry.path(
                    in: innerRect,
                    cornerRadius: max(0, cornerRadius - bandWidth),
                    exponent: AtticStyle.panelSquircleExponent,
                    segmentsPerCorner: 64
                )
            )
        }
        edgeBandMask.path = combinedPath

        CATransaction.commit()
    }

    private func rebuildFiltersIfNeeded() {
        guard lifecycle.phase != .stopped,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        let backingScale = currentBackingScale
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let key = RenderKey(
            pixelWidth: Int((bounds.width * backingScale).rounded()),
            pixelHeight: Int((bounds.height * backingScale).rounded()),
            cornerRadius: Double(cornerRadius),
            backingScale: backingScale,
            profile: profile,
            reduceTransparency: reduceTransparency
        )
        guard key != lastRenderKey else {
            updateOverlayOpacities(reduceTransparency: reduceTransparency)
            return
        }
        lastRenderKey = key

        let needsRefraction = profile.baseDisplacementPixels > 0.001
        let needsFrost = profile.frostRadius > 0.001
        let refractionAvailable = !needsRefraction || AtticOpticalWarpFilter.isAvailable
        let frostAvailable = !needsFrost || CIFilter(name: "CIGaussianBlur") != nil
        backend = OpticalBackdropBackend.resolve(
            backgroundFiltersAvailable: refractionAvailable && frostAvailable,
            reduceTransparency: reduceTransparency
        )

        effectView.state = .active
        effectView.layer?.removeAnimation(forKey: "atticInteractionResponse")
        restDisplacementPoints = 0

        switch backend {
        case .opaque:
            effectView.isHidden = true
            effectView.contentFilters = []
        case .liveMaterial:
            effectView.isHidden = false
            effectView.contentFilters = []
        case .liveFiltered:
            guard let filters = makeContentFilters(backingScale: backingScale) else {
                backend = .liveMaterial
                effectView.isHidden = false
                effectView.contentFilters = []
                updateOverlayOpacities(reduceTransparency: reduceTransparency)
                return
            }
            effectView.isHidden = false
            effectView.contentFilters = filters
        }

        updateOverlayOpacities(reduceTransparency: reduceTransparency)
    }

    private func makeContentFilters(backingScale: Double) -> [CIFilter]? {
        var filters: [CIFilter] = []

        if profile.baseDisplacementPixels > 0, profile.refractionBandPixels > 0 {
            let warp = AtticOpticalWarpFilter()
            guard AtticOpticalWarpFilter.isAvailable else { return nil }
            restDisplacementPoints = profile.displacementPixels(interactionProgress: 0)
                / backingScale
            warp.inputCornerRadius = NSNumber(value: Double(cornerRadius))
            warp.inputBand = NSNumber(value: profile.refractionBandPixels / backingScale)
            warp.inputDisplacement = NSNumber(value: restDisplacementPoints)
            filters.append(warp)
        }

        if profile.frostRadius > 0.001 {
            guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
            blur.name = "atticFrost"
            blur.setValue(profile.frostRadius / backingScale, forKey: kCIInputRadiusKey)
            filters.append(blur)
        }

        return filters
    }

    private func updateSemanticColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            surfaceLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            tintLayer.backgroundColor = NSColor.controlAccentColor.cgColor
            readabilityLayer.colors = [
                NSColor.windowBackgroundColor.cgColor,
                NSColor.windowBackgroundColor.withAlphaComponent(0.35).cgColor,
                NSColor.clear.cgColor
            ]
            edgeShineLayer.colors = [
                NSColor.white.cgColor,
                NSColor.white.withAlphaComponent(0.05).cgColor,
                NSColor.clear.cgColor,
                NSColor.white.withAlphaComponent(0.34).cgColor
            ]
        }
        updateOverlayOpacities(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    private func updateOverlayOpacities(reduceTransparency: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reduceTransparency || backend == .opaque {
            surfaceLayer.opacity = 1
            tintLayer.opacity = 0
            readabilityLayer.opacity = 0
            edgeShineLayer.opacity = 0
        } else {
            surfaceLayer.opacity = Float(profile.surfaceOpacity)
            tintLayer.opacity = Float(profile.tintOpacity)
            readabilityLayer.opacity = Float(profile.readabilityOpacity)
            edgeShineLayer.opacity = backend == .liveFiltered
                ? Float(profile.edgeShineOpacity)
                : 0
        }
        CATransaction.commit()
    }

    private func pulseInteraction() {
        guard lifecycle.phase == .visible,
              backend == .liveFiltered,
              restDisplacementPoints > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = effectView.layer else {
            return
        }

        let peakDisplacement = profile.displacementPixels(interactionProgress: 1)
            / currentBackingScale
        guard peakDisplacement > restDisplacementPoints + 0.001 else { return }

        let keyPath = "filters.atticOpticalWarp.inputDisplacement"
        layer.setValue(restDisplacementPoints, forKeyPath: keyPath)
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = [
            restDisplacementPoints,
            peakDisplacement,
            restDisplacementPoints
        ]
        animation.keyTimes = [0, 0.30, 1]
        animation.duration = 0.24
        animation.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1),
            CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.2)
        ]
        layer.add(animation, forKey: "atticInteractionResponse")
    }

    private var currentBackingScale: Double {
        Double(window?.backingScaleFactor ?? 2)
    }
}

private final class OpticalPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
