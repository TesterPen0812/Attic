import Foundation

struct OpticalAdaptiveInputs: Equatable, Sendable {
    let isPanelVisible: Bool
    let isLowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState
    let isOnBatteryPower: Bool
    let displayScale: Double
    let performance: OpticalPerformanceSnapshot?
}

struct OpticalAdaptiveQualityController: Equatable, Sendable {
    private(set) var effectivePreset: OpticalPerformancePreset
    private var consecutiveUnhealthyWindows = 0
    private var consecutiveHealthyWindows = 0
    private var lastDowngradeTime: TimeInterval?

    init(initialEffectivePreset: OpticalPerformancePreset = .balanced) {
        switch initialEffectivePreset {
        case .off, .adaptive:
            effectivePreset = .balanced
        case .low, .balanced, .maximum:
            effectivePreset = initialEffectivePreset
        }
    }

    mutating func evaluate(
        inputs: OpticalAdaptiveInputs,
        now: TimeInterval
    ) -> OpticalPerformancePreset {
        guard inputs.isPanelVisible else { return .off }

        let ceiling = environmentalCeiling(for: inputs)
        if rank(effectivePreset) > rank(ceiling) {
            markDowngrade(to: ceiling, now: now)
        }

        if ceiling == .low {
            if effectivePreset != .low {
                markDowngrade(to: .low, now: now)
            }
            resetPerformanceCounters()
            return .low
        }

        guard let performance = inputs.performance else {
            effectivePreset = ceiling
            resetPerformanceCounters()
            return effectivePreset
        }

        if Self.isUnhealthy(performance) {
            consecutiveUnhealthyWindows += 1
            consecutiveHealthyWindows = 0
            if consecutiveUnhealthyWindows >= 3 {
                let degraded = oneStepBelow(effectivePreset)
                let clamped = rank(degraded) > rank(ceiling) ? ceiling : degraded
                if rank(clamped) < rank(effectivePreset) {
                    markDowngrade(to: clamped, now: now)
                }
                consecutiveUnhealthyWindows = 0
            }
            return effectivePreset
        }

        consecutiveUnhealthyWindows = 0
        consecutiveHealthyWindows += 1
        guard rank(effectivePreset) < rank(ceiling),
              consecutiveHealthyWindows >= 6 else {
            return effectivePreset
        }

        if let lastDowngradeTime, now - lastDowngradeTime < 20 {
            return effectivePreset
        }

        effectivePreset = minPreset(oneStepAbove(effectivePreset), ceiling)
        consecutiveHealthyWindows = 0
        return effectivePreset
    }

    private mutating func markDowngrade(
        to preset: OpticalPerformancePreset,
        now: TimeInterval
    ) {
        effectivePreset = preset
        lastDowngradeTime = now
        resetPerformanceCounters()
    }

    private mutating func resetPerformanceCounters() {
        consecutiveUnhealthyWindows = 0
        consecutiveHealthyWindows = 0
    }

    private func environmentalCeiling(
        for inputs: OpticalAdaptiveInputs
    ) -> OpticalPerformancePreset {
        if inputs.isLowPowerModeEnabled
            || inputs.thermalState == .serious
            || inputs.thermalState == .critical
            || !inputs.displayScale.isFinite
            || inputs.displayScale > 3 {
            return .low
        }

        if inputs.isOnBatteryPower
            || inputs.thermalState == .fair
            || inputs.displayScale > 2 {
            return .balanced
        }

        return .maximum
    }

    private static func isUnhealthy(_ snapshot: OpticalPerformanceSnapshot) -> Bool {
        snapshot.droppedFrameRate >= 0.08
            || snapshot.p95FrameTimeMilliseconds >= 33
            || snapshot.meanCaptureLatencyMilliseconds >= 100
    }

    private func oneStepBelow(
        _ preset: OpticalPerformancePreset
    ) -> OpticalPerformancePreset {
        switch preset {
        case .maximum: return .balanced
        case .balanced, .adaptive: return .low
        case .low, .off: return .low
        }
    }

    private func oneStepAbove(
        _ preset: OpticalPerformancePreset
    ) -> OpticalPerformancePreset {
        switch preset {
        case .low, .off: return .balanced
        case .balanced, .adaptive: return .maximum
        case .maximum: return .maximum
        }
    }

    private func minPreset(
        _ lhs: OpticalPerformancePreset,
        _ rhs: OpticalPerformancePreset
    ) -> OpticalPerformancePreset {
        rank(lhs) <= rank(rhs) ? lhs : rhs
    }

    private func rank(_ preset: OpticalPerformancePreset) -> Int {
        switch preset {
        case .off: return 0
        case .low: return 1
        case .balanced, .adaptive: return 2
        case .maximum: return 3
        }
    }
}
