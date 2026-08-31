import Foundation

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

    /// Commits the model transition only after the panel controller accepts
    /// the request (including a successful draft flush). Rejection leaves the
    /// panel visible and starts a fresh hide-delay window.
    mutating func resolveHideRequest(accepted: Bool) {
        guard isHidePending else { return }
        if accepted {
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
