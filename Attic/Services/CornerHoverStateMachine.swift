import Foundation

enum CornerHoverSamplingCadence: Equatable {
    case idle
    case responsive

    var intervalMilliseconds: Int {
        switch self {
        case .idle: 1_000
        case .responsive: 50
        }
    }

    var leewayMilliseconds: Int {
        switch self {
        case .idle: 250
        case .responsive: 15
        }
    }

    var holdsResponsivenessActivity: Bool { self == .responsive }

    var nominalSamplesPerMinute: Int {
        60_000 / intervalMilliseconds
    }
}

struct CornerHoverSamplingDecision: Equatable {
    let cadence: CornerHoverSamplingCadence
    let shouldSampleImmediately: Bool
}

struct CornerHoverSamplingState {
    static let activationDistance: CGFloat = 96
    static let deactivationDistance: CGFloat = 144

    private(set) var cadence: CornerHoverSamplingCadence = .idle

    mutating func update(
        pointer: CGPoint,
        screenFrames: [CGRect],
        corner: ScreenCorner,
        isPanelVisible: Bool
    ) -> CornerHoverSamplingDecision {
        let previousCadence = cadence
        let proximityDistance = previousCadence == .responsive
            ? Self.deactivationDistance
            : Self.activationDistance
        let isNearConfiguredCorner = screenFrames.contains {
            Self.isNearCorner(
                pointer,
                screenFrame: $0,
                corner: corner,
                distance: proximityDistance
            )
        }
        cadence = isPanelVisible || isNearConfiguredCorner ? .responsive : .idle
        return CornerHoverSamplingDecision(
            cadence: cadence,
            shouldSampleImmediately: cadence != previousCadence
        )
    }

    private static func isNearCorner(
        _ point: CGPoint,
        screenFrame: CGRect,
        corner: ScreenCorner,
        distance: CGFloat
    ) -> Bool {
        let cornerPoint: CGPoint
        switch corner {
        case .topLeft:
            cornerPoint = CGPoint(x: screenFrame.minX, y: screenFrame.maxY)
        case .topRight:
            cornerPoint = CGPoint(x: screenFrame.maxX, y: screenFrame.maxY)
        case .bottomLeft:
            cornerPoint = CGPoint(x: screenFrame.minX, y: screenFrame.minY)
        case .bottomRight:
            cornerPoint = CGPoint(x: screenFrame.maxX, y: screenFrame.minY)
        }
        return abs(point.x - cornerPoint.x) <= distance
            && abs(point.y - cornerPoint.y) <= distance
    }
}

struct CornerHoverStateMachine {
    enum Transition: Equatable {
        case none
        case reveal
        case requestHide
    }

    private(set) var isVisible = false
    private(set) var isHidePending = false
    private var hotspotEnteredAt: TimeInterval?
    private var revealedAt: TimeInterval?
    private var revealGrace: TimeInterval = 0.8
    private var panelHasBeenEntered = false
    private var leaveBeganAt: TimeInterval?
    private var requiresHotspotExitBeforeReveal = false

    mutating func update(
        at timestamp: TimeInterval,
        isInHotspot: Bool,
        isInPanel: Bool,
        isInteractionLocked: Bool,
        isPinned: Bool = false,
        revealDelay: TimeInterval,
        hideDelay: TimeInterval = 0.3
    ) -> Transition {
        if !isVisible {
            if requiresHotspotExitBeforeReveal {
                guard !isInHotspot else {
                    hotspotEnteredAt = nil
                    return .none
                }
                requiresHotspotExitBeforeReveal = false
            }
            guard isInHotspot else {
                hotspotEnteredAt = nil
                return .none
            }

            if hotspotEnteredAt == nil { hotspotEnteredAt = timestamp }
            guard timestamp - (hotspotEnteredAt ?? timestamp) >= revealDelay else { return .none }

            isVisible = true
            revealedAt = timestamp
            revealGrace = 0.8
            panelHasBeenEntered = false
            leaveBeganAt = nil
            hotspotEnteredAt = nil
            return .reveal
        }

        if isHidePending {
            return .none
        }

        if isPinned || isInteractionLocked || isInHotspot {
            leaveBeganAt = nil
            return .none
        }

        if isInPanel {
            panelHasBeenEntered = true
            leaveBeganAt = nil
            return .none
        }

        if !panelHasBeenEntered,
           let revealedAt,
           timestamp - revealedAt < revealGrace {
            return .none
        }

        if leaveBeganAt == nil {
            leaveBeganAt = timestamp
            return .none
        }

        guard timestamp - (leaveBeganAt ?? timestamp) >= max(0, hideDelay) else { return .none }
        isHidePending = true
        return .requestHide
    }

    /// Commits the model transition only after the native panel has actually
    /// ordered out. Rejection or a superseding reveal leaves the model visible
    /// and starts a fresh hide-delay window.
    mutating func resolveHideCompletion(didOrderOut: Bool) {
        guard isHidePending else { return }
        if didOrderOut {
            reset()
        } else {
            isHidePending = false
            leaveBeganAt = nil
        }
    }

    mutating func forceVisible(at timestamp: TimeInterval, grace: TimeInterval = 3) {
        isVisible = true
        revealedAt = timestamp
        revealGrace = grace
        panelHasBeenEntered = false
        leaveBeganAt = nil
        hotspotEnteredAt = nil
        requiresHotspotExitBeforeReveal = false
        isHidePending = false
    }

    mutating func forceHidden(untilHotspotExit: Bool = false) {
        reset()
        requiresHotspotExitBeforeReveal = untilHotspotExit
    }

    private mutating func reset() {
        isVisible = false
        hotspotEnteredAt = nil
        revealedAt = nil
        panelHasBeenEntered = false
        leaveBeganAt = nil
        requiresHotspotExitBeforeReveal = false
        isHidePending = false
    }
}
