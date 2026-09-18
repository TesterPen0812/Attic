import Foundation

enum MainPanelAutoHidePolicy {
    private static let focusExpirationDelay: TimeInterval = 1.5
    private static let temporaryFocusReasons: Set<PanelInteractionLockReason> = [
        .quickEntryFocus,
        .notesEditorFocus,
    ]

    static func isInteractionLocked(
        reasons: Set<PanelInteractionLockReason>, pointerInside: Bool,
        secondsSinceKeyboardInput: TimeInterval
    ) -> Bool {
        var effective = reasons
        if !pointerInside, secondsSinceKeyboardInput >= focusExpirationDelay {
            // A clean, idle main editor retaining first responder is not a
            // permanent pin. Drafts, menus, selections and auxiliary editors
            // retain their independent protection.
            effective.subtract(temporaryFocusReasons)
        }
        return !effective.isEmpty
    }

    /// The one moment a temporary focus lock can expire without another UI
    /// event. Persistent locks need no timer because elapsed time cannot make
    /// them eligible for auto-hide.
    static func focusExpirationDeadline(
        reasons: Set<PanelInteractionLockReason>,
        pointerInside: Bool,
        lastKeyboardInputAt: TimeInterval,
        timestamp: TimeInterval
    ) -> TimeInterval? {
        guard !pointerInside,
              !reasons.isDisjoint(with: temporaryFocusReasons),
              reasons.isSubset(of: temporaryFocusReasons) else { return nil }
        let deadline = lastKeyboardInputAt + focusExpirationDelay
        return deadline > timestamp ? deadline : nil
    }
}

struct CornerHoverPointerMonitorDomains: OptionSet, Equatable {
    let rawValue: Int

    static let local = Self(rawValue: 1 << 0)
    static let global = Self(rawValue: 1 << 1)
    static let required: Self = [.local, .global]
}

/// How the corner monitor samples the pointer.
///
/// - `idle`: hidden and far from the corner — a slow safety-net timer.
/// - `responsive`: hidden and near the corner — the reveal decision window,
///   the only time a fast timer and an App Nap exemption are justified.
/// - `eventDriven`: the panel is visible — no timer at all. Pointer events,
///   lock changes and a one-shot follow-up for the hide delay drive every
///   sample, so an idle visible panel does no periodic work.
enum CornerHoverSamplingCadence: Equatable {
    case idle
    case responsive
    case eventDriven

    /// nil means no repeating timer.
    var intervalMilliseconds: Int? {
        switch self {
        case .idle: 1_000
        case .responsive: 50
        case .eventDriven: nil
        }
    }

    var leewayMilliseconds: Int {
        switch self {
        case .idle: 250
        case .responsive: 15
        case .eventDriven: 0
        }
    }

    var holdsResponsivenessActivity: Bool { self == .responsive }

    var nominalSamplesPerMinute: Int {
        guard let intervalMilliseconds else { return 0 }
        return 60_000 / intervalMilliseconds
    }
}

struct CornerHoverSamplingDecision: Equatable {
    let cadence: CornerHoverSamplingCadence
    let shouldSampleImmediately: Bool
}

struct CornerHoverTimerEpoch {
    private(set) var current: UInt64 = 0

    mutating func beginTimer() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func permits(_ candidate: UInt64, whileRunning: Bool) -> Bool {
        whileRunning && candidate == current
    }
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
        let activeScreenFrame = Self.activeScreenFrame(
            containing: pointer,
            screenFrames: screenFrames
        )
        let isNearConfiguredCorner = activeScreenFrame.map {
            Self.isNearCorner(
                pointer,
                screenFrame: $0,
                corner: corner,
                distance: proximityDistance
            )
        } ?? false
        if isPanelVisible {
            cadence = .eventDriven
        } else {
            cadence = isNearConfiguredCorner ? .responsive : .idle
        }
        // A visible panel samples on every pointer event (the monitor
        // coalesces bursts); hidden cadences sample only on a boundary
        // crossing and otherwise leave the work to their timer.
        return CornerHoverSamplingDecision(
            cadence: cadence,
            shouldSampleImmediately: cadence != previousCadence || cadence == .eventDriven
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

    private static func activeScreenFrame(
        containing point: CGPoint,
        screenFrames: [CGRect]
    ) -> CGRect? {
        // Half-open ownership makes a shared seam belong to exactly one
        // display: the display whose minimum edge starts at that coordinate.
        // This mirrors AppKit's edge behavior without letting an adjacent
        // display's corner promote the sampling cadence.
        if let owned = screenFrames.first(where: {
            point.x >= $0.minX && point.x < $0.maxX
                && point.y >= $0.minY && point.y < $0.maxY
        }) {
            return owned
        }
        // Physical outer edges can report a coordinate exactly one point
        // outside CGRect's half-open maximum. Choose the closest expanded
        // frame deterministically, not every matching display.
        return screenFrames
            .filter { $0.insetBy(dx: -1, dy: -1).contains(point) }
            .min { lhs, rhs in
                let lhsDistance = hypot(point.x - lhs.midX, point.y - lhs.midY)
                let rhsDistance = hypot(point.x - rhs.midX, point.y - rhs.midY)
                return lhsDistance < rhsDistance
            }
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

    /// While visible without a timer, the next moment a sample could change
    /// the outcome: when the hide delay (or the reveal grace) elapses for a
    /// pointer already away from the panel. nil when the next change can
    /// only come from an event — the pointer moving, a lock lifting, a pin.
    func nextTimedDecision(
        at timestamp: TimeInterval,
        isInPanel: Bool,
        isInteractionLocked: Bool,
        isPinned: Bool,
        hideDelay: TimeInterval
    ) -> TimeInterval? {
        guard isVisible, !isHidePending, !isPinned, !isInteractionLocked, !isInPanel else { return nil }
        if !panelHasBeenEntered, let revealedAt, timestamp - revealedAt < revealGrace {
            return revealedAt + revealGrace
        }
        guard let leaveBeganAt else { return timestamp }
        return leaveBeganAt + max(0, hideDelay)
    }

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
