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

/// How the corner monitor samples the pointer. No cadence runs a repeating
/// timer: every sample comes from a pointer event, a lock change, a screen
/// change or a one-shot deadline (the reveal delay while hidden, the hide
/// delay while visible), so a hidden panel does no periodic work.
///
/// - `idle`: hidden and far from the corner. Pointer events only update
///   this cheap cadence state; a full sample runs on a boundary crossing.
/// - `responsive`: hidden and near the corner. Every pointer event samples
///   (coalesced), and entering the hotspot schedules one follow-up at the
///   reveal deadline, because a pointer resting in the corner sends no
///   further events. The only time an App Nap exemption is held.
/// - `eventDriven`: the panel is visible. Pointer events, lock changes and a
///   one-shot follow-up for the hide delay drive every sample.
enum CornerHoverSamplingCadence: Equatable {
    case idle
    case responsive
    case eventDriven

    /// Whether every pointer event runs a (coalesced) full sample.
    var samplesEveryEvent: Bool { self != .idle }

    var holdsResponsivenessActivity: Bool { self == .responsive }
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
        // Near the corner or visible, every pointer event samples (the
        // monitor coalesces bursts); far and hidden, only a boundary
        // crossing does.
        return CornerHoverSamplingDecision(
            cadence: cadence,
            shouldSampleImmediately: cadence != previousCadence || cadence.samplesEveryEvent
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
    /// A pointer resting in the hotspot (the corner wedge outside the
    /// rounded panel) keeps the panel open for as long as it stays, so only
    /// its moving out can change anything: no deadline, before or after the
    /// reveal grace.
    func nextTimedDecision(
        at timestamp: TimeInterval,
        isInHotspot: Bool,
        isInPanel: Bool,
        isInteractionLocked: Bool,
        isPinned: Bool,
        hideDelay: TimeInterval
    ) -> TimeInterval? {
        guard isVisible, !isHidePending, !isPinned, !isInteractionLocked, !isInPanel, !isInHotspot else { return nil }
        if !panelHasBeenEntered, let revealedAt, timestamp - revealedAt < revealGrace {
            return revealedAt + revealGrace
        }
        // Away from the panel the sample that ran just before this call has
        // started the leave; without one, the next pointer event starts it.
        guard let leaveBeganAt else { return nil }
        return leaveBeganAt + max(0, hideDelay)
    }

    /// While hidden, the moment the pointer resting in the hotspot will have
    /// stayed long enough to reveal the panel. A resting pointer sends no
    /// events, so the monitor schedules one sample for then. nil when no
    /// reveal is pending.
    func nextRevealDeadline(revealDelay: TimeInterval) -> TimeInterval? {
        guard !isVisible, !requiresHotspotExitBeforeReveal,
              let hotspotEnteredAt else { return nil }
        return hotspotEnteredAt + max(0, revealDelay)
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
