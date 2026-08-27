import Foundation

struct OpticalGlassControls: Equatable, Sendable {
    static let range = 0.0...100.0
    static let defaults = OpticalGlassControls(
        transparency: 88,
        frost: 14,
        refraction: 100,
        edgeShine: 18,
        tint: 10,
        readability: 22,
        interactionResponse: 28
    )

    var transparency: Double
    var frost: Double
    var refraction: Double
    var edgeShine: Double
    var tint: Double
    var readability: Double
    var interactionResponse: Double

    static func normalized(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback / 100 }
        return min(max(value, range.lowerBound), range.upperBound) / 100
    }
}

enum OpticalWindowActivity: Equatable, Sendable {
    case key
    case inactive
}

/// Constants shared by the deterministic CPU reference model and the Metal
/// source. At Maximum and Refraction 100, the resting field spans roughly
/// 15.5 px on ordinary sides, 18.7 px at the bottom, 19.7 px at top corners,
/// and 22.9 px at bottom corners. Interaction can use the remaining 1 px of
/// headroom without crossing the 24 px hard cap.
enum OpticalRefractionEnvelope {
    static let restingDisplacementFraction = 23.0 / 24.0
    static let sideMultiplier = 0.68
    static let bottomContribution = 0.14
    static let cornerContribution = 0.18
    static let bottomStart = 0.58
    static let bottomSpan = 0.42
    static let cornerProductScale = 2.0
    static let maximumEdgeMultiplier = 1.0

    static func edgeMultiplier(
        bottomProximity: Double,
        inwardX: Double,
        inwardY: Double
    ) -> Double {
        let bottomWeight = smoothstep((bottomProximity - bottomStart) / bottomSpan)
        let cornerWeight = min(
            1,
            cornerProductScale * abs(inwardX * inwardY)
        )
        return min(
            maximumEdgeMultiplier,
            sideMultiplier
                + bottomContribution * bottomWeight
                + cornerContribution * cornerWeight
        )
    }

    static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

/// A resolved rendering profile. Each user-facing axis maps to its own output
/// field so Transparency, Frost, and Refraction cannot silently drive one
/// another. Window activity is accepted for compatibility but deliberately
/// ignored, making the resting profile focus invariant.
struct OpticalGlassProfile: Equatable, Sendable {
    let surfaceOpacity: Double
    let frostRadius: Double
    let refractionBandPixels: Double
    let baseDisplacementPixels: Double
    let maximumDisplacementPixels: Double
    let edgeShineOpacity: Double
    let tintOpacity: Double
    let readabilityOpacity: Double
    let interactionBoost: Double

    static func resolve(
        controls: OpticalGlassControls,
        windowActivity: OpticalWindowActivity
    ) -> OpticalGlassProfile {
        resolve(
            controls: controls,
            workload: OpticalWorkloadProfile.workload(for: .maximum),
            windowActivity: windowActivity
        )
    }

    static func resolve(
        controls: OpticalGlassControls,
        workload: OpticalWorkloadProfile,
        windowActivity _: OpticalWindowActivity
    ) -> OpticalGlassProfile {
        let defaults = OpticalGlassControls.defaults
        let transparency = OpticalGlassControls.normalized(
            controls.transparency,
            fallback: defaults.transparency
        )
        let frost = OpticalGlassControls.normalized(
            controls.frost,
            fallback: defaults.frost
        )
        let refraction = OpticalGlassControls.normalized(
            controls.refraction,
            fallback: defaults.refraction
        )
        let edgeShine = OpticalGlassControls.normalized(
            controls.edgeShine,
            fallback: defaults.edgeShine
        )
        let tint = OpticalGlassControls.normalized(
            controls.tint,
            fallback: defaults.tint
        )
        let readability = OpticalGlassControls.normalized(
            controls.readability,
            fallback: defaults.readability
        )
        let interaction = OpticalGlassControls.normalized(
            controls.interactionResponse,
            fallback: defaults.interactionResponse
        )
        let refractionEnabled = workload.allowsLiveOptics && refraction > 0
        let restingMaximum = workload.maximumDisplacementPixels
            * OpticalRefractionEnvelope.restingDisplacementFraction

        return OpticalGlassProfile(
            surfaceOpacity: pow(1 - transparency, 1.35),
            frostRadius: frost * 8,
            refractionBandPixels: refractionEnabled
                ? workload.maximumBandPixels * sqrt(refraction)
                : 0,
            baseDisplacementPixels: refractionEnabled
                ? restingMaximum * pow(refraction, 1.15)
                : 0,
            maximumDisplacementPixels: workload.allowsLiveOptics
                ? workload.maximumDisplacementPixels
                : 0,
            edgeShineOpacity: edgeShine * 0.30,
            tintOpacity: tint * 0.16,
            readabilityOpacity: readability * 0.22,
            interactionBoost: 1 + interaction * 0.06
        )
    }

    func displacementPixels(interactionProgress: Double) -> Double {
        guard baseDisplacementPixels > 0, maximumDisplacementPixels > 0 else {
            return 0
        }
        let progress = min(max(interactionProgress, 0), 1)
        return min(
            maximumDisplacementPixels,
            baseDisplacementPixels * (1 + (interactionBoost - 1) * progress)
        )
    }
}

enum OpticalPerformancePreset: String, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case balanced
    case maximum
    case adaptive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .balanced: return "Balanced"
        case .maximum: return "Maximum"
        case .adaptive: return "Adaptive"
        }
    }

    var powerImpactDescription: String {
        switch self {
        case .off:
            return "Lowest power. Uses only the lightweight native material fallback."
        case .low:
            return "Low power. Reduces capture resolution, update rate, buffering, and shader work."
        case .balanced:
            return "Moderate power. Recommended for persistent visible refraction."
        case .maximum:
            return "Highest power. Uses full capture resolution and the strongest optical envelope."
        case .adaptive:
            return "Variable power. Responds to visibility, power, thermal pressure, display scale, and sustained frame performance."
        }
    }
}

struct OpticalWorkloadProfile: Equatable, Sendable {
    let captureScale: Double
    let maximumFramesPerSecond: Int
    let queueDepth: Int
    let blurSampleCount: Int
    let edgeEvaluationCount: Int
    let maximumBandPixels: Double
    let maximumDisplacementPixels: Double

    var allowsLiveOptics: Bool {
        captureScale > 0
            && maximumFramesPerSecond > 0
            && queueDepth > 0
            && blurSampleCount > 0
            && edgeEvaluationCount > 0
    }

    static func workload(for preset: OpticalPerformancePreset) -> OpticalWorkloadProfile {
        switch preset {
        case .off:
            return OpticalWorkloadProfile(
                captureScale: 0,
                maximumFramesPerSecond: 0,
                queueDepth: 0,
                blurSampleCount: 0,
                edgeEvaluationCount: 0,
                maximumBandPixels: 0,
                maximumDisplacementPixels: 0
            )
        case .low:
            return OpticalWorkloadProfile(
                captureScale: 0.50,
                maximumFramesPerSecond: 15,
                queueDepth: 3,
                blurSampleCount: 5,
                edgeEvaluationCount: 1,
                maximumBandPixels: 28,
                maximumDisplacementPixels: 12
            )
        case .balanced, .adaptive:
            return OpticalWorkloadProfile(
                captureScale: 0.75,
                maximumFramesPerSecond: 30,
                queueDepth: 4,
                blurSampleCount: 9,
                edgeEvaluationCount: 3,
                maximumBandPixels: 32,
                maximumDisplacementPixels: 19
            )
        case .maximum:
            return OpticalWorkloadProfile(
                captureScale: 1,
                maximumFramesPerSecond: 60,
                queueDepth: 5,
                blurSampleCount: 13,
                edgeEvaluationCount: 5,
                maximumBandPixels: 36,
                maximumDisplacementPixels: 24
            )
        }
    }
}

enum OpticalCapturePermissionState: Equatable, Sendable {
    case notRequested
    case authorized
    case denied
}

enum OpticalFallbackReason: Equatable, Sendable {
    case performanceOff
    case permissionNotRequested
    case permissionDenied
    case metalUnavailable
    case captureUnavailable
    case reduceTransparency
    case temporarilyNoFrame
}

enum OpticalBackdropMode: Equatable, Sendable {
    case live
    case material(reason: OpticalFallbackReason)
    case opaque(reason: OpticalFallbackReason)

    static func resolve(
        preset: OpticalPerformancePreset,
        permission: OpticalCapturePermissionState,
        metalAvailable: Bool,
        captureAvailable: Bool,
        reduceTransparency: Bool
    ) -> OpticalBackdropMode {
        if reduceTransparency {
            return .opaque(reason: .reduceTransparency)
        }
        if preset == .off {
            return .material(reason: .performanceOff)
        }
        switch permission {
        case .notRequested:
            return .material(reason: .permissionNotRequested)
        case .denied:
            return .material(reason: .permissionDenied)
        case .authorized:
            break
        }
        guard metalAvailable else {
            return .material(reason: .metalUnavailable)
        }
        guard captureAvailable else {
            return .material(reason: .captureUnavailable)
        }
        return .live
    }
}

enum OpticalCapturePhase: Equatable, Sendable {
    case stopped
    case running(generation: Int, configurationFingerprint: Int)
}

enum OpticalCaptureCommand: Equatable, Sendable {
    case none
    case start(generation: Int)
    case restart(previousGeneration: Int, generation: Int)
    case stop(generation: Int)
}

struct OpticalCaptureLifecycle: Equatable, Sendable {
    private(set) var phase: OpticalCapturePhase = .stopped
    private(set) var generation = 0
    private(set) var requiresResourceRelease = false

    mutating func reconcile(
        shouldRun: Bool,
        configurationFingerprint: Int
    ) -> OpticalCaptureCommand {
        guard shouldRun else {
            guard case let .running(activeGeneration, _) = phase else {
                return .none
            }
            phase = .stopped
            requiresResourceRelease = true
            return .stop(generation: activeGeneration)
        }

        switch phase {
        case .stopped:
            generation += 1
            phase = .running(
                generation: generation,
                configurationFingerprint: configurationFingerprint
            )
            requiresResourceRelease = false
            return .start(generation: generation)

        case let .running(activeGeneration, activeFingerprint):
            guard activeFingerprint != configurationFingerprint else {
                return .none
            }
            generation += 1
            phase = .running(
                generation: generation,
                configurationFingerprint: configurationFingerprint
            )
            requiresResourceRelease = true
            return .restart(
                previousGeneration: activeGeneration,
                generation: generation
            )
        }
    }

    func acceptsFrame(generation candidate: Int) -> Bool {
        guard case let .running(activeGeneration, _) = phase else { return false }
        return candidate == activeGeneration
    }

    func acceptsFailure(generation candidate: Int) -> Bool {
        acceptsFrame(generation: candidate)
    }
}

/// Guards actor-reentrant ScreenCaptureKit start/stop operations. A newer
/// operation invalidates all older async continuations before they can install,
/// tear down, or report against a replacement stream.
struct OpticalCaptureOperationGate: Equatable, Sendable {
    private(set) var generation = 0
    private(set) var activeOperation: Int?

    mutating func begin() -> Int {
        generation += 1
        activeOperation = generation
        return generation
    }

    mutating func stop() {
        generation += 1
        activeOperation = nil
    }

    func accepts(_ operation: Int) -> Bool {
        activeOperation == operation
    }
}

struct OpticalRendererLifecycle: Equatable, Sendable {
    private(set) var isPrepared = false
    private(set) var hasRetainedFrame = false
    private(set) var releaseGeneration = 0

    mutating func prepare() {
        isPrepared = true
    }

    mutating func didReceiveFrame() {
        guard isPrepared else { return }
        hasRetainedFrame = true
    }

    mutating func release() {
        isPrepared = false
        hasRetainedFrame = false
        releaseGeneration += 1
    }
}
