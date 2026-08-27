import Foundation

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

extension OpticalGlassProfile {
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

        return OpticalGlassProfile(
            surfaceOpacity: pow(1 - transparency, 1.35),
            frostRadius: frost * 8,
            refractionBandPixels: refractionEnabled
                ? workload.maximumBandPixels * sqrt(refraction)
                : 0,
            baseDisplacementPixels: refractionEnabled
                ? workload.maximumDisplacementPixels * pow(refraction, 1.15)
                : 0,
            edgeShineOpacity: edgeShine * 0.30,
            tintOpacity: tint * 0.16,
            readabilityOpacity: readability * 0.22,
            interactionBoost: 1 + interaction * 0.06
        )
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
