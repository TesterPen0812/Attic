import CoreGraphics
import Foundation

/// One explicit owner of every floating-panel window transition. Reveal,
/// hide, and dock are not independent animations: they are points on a
/// single presentation coordinate that the window always moves along.
///
/// The coordinate is geometry-derived rather than a stored frame: the
/// panel emerges from and returns to its attached screen corner by
/// construction, so every corner gets the correct physical direction
/// without mirroring a hard-coded vector. Interruptions retarget from the
/// live window state (the window server reports animated frames
/// continuously), which makes rapid hover-in/out reversal continue from
/// the current presentation instead of restarting or teleporting.
enum PanelMotion {
    /// Reveal: fast attack, gentle settle. Short enough to feel immediate
    /// while remaining legible as motion.
    static let revealDuration: CFTimeInterval = 0.22
    /// Hide: same family, slightly quicker release.
    static let hideDuration: CFTimeInterval = 0.18
    /// Dock: one restrained glide shared with the reveal family so a
    /// corner change reads as the panel sliding along the screen edges.
    static let dockDuration: CFTimeInterval = 0.24

    /// Reduce Motion keeps the state model and ownership intact but
    /// collapses geometry movement to a short crossfade: reveal fades the
    /// already-positioned panel in, hide fades it out in place, so nothing
    /// snaps to full visibility and no direction is misread.
    static let reduceMotionDuration: CFTimeInterval = 0.12

    /// The single presentation coordinate. `visibleFrame` is the fully
    /// revealed frame; `hiddenFrame` is the corner-directed emergence
    /// frame. All motion is interpolation between these two fixed
    /// geometries, so window frame, hit testing, and visual presentation
    /// agree on every frame by construction.
    struct Geometry {
        let visibleFrame: CGRect
        let hiddenFrame: CGRect

        /// The frame presented at a given progress (0 = hidden, 1 = fully
        /// revealed). Both staged frames share one size, so interpolating
        /// the origin is exact; easing is applied to progress, not frames.
        func frame(at progress: CGFloat) -> CGRect {
            let progress = PanelMotion.clampedProgress(progress)
            return CGRect(
                x: hiddenFrame.minX + (visibleFrame.minX - hiddenFrame.minX) * progress,
                y: hiddenFrame.minY + (visibleFrame.minY - hiddenFrame.minY) * progress,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        }
    }

    enum Phase: Equatable {
        case hidden
        case revealing
        case visible
        case hiding
        /// Docking shares the reveal family: the panel stays fully
        /// presented while it glides between corner anchors.
        case docking

        var isVisible: Bool {
            switch self {
            case .hidden: false
            case .revealing, .visible, .hiding, .docking: true
            }
        }

        var isTransitioning: Bool {
            switch self {
            case .hidden, .visible: false
            case .revealing, .hiding, .docking: true
            }
        }
    }

    /// Interruptible, reversible transition state. The controller owns
    /// window commands; this owns the presentation bookkeeping that must
    /// survive interruption: the phase, the active geometry, the intent
    /// sequence, and the progress the window is currently presenting.
    ///
    /// AppKit fires an interrupted animation's completion handler when a
    /// new `animator().setFrame` retargets the window. The intent sequence
    /// discriminates the still-current animation from those superseded
    /// mid-flight: only the newest intent may complete presentation state.
    struct Transition {
        private(set) var intentSequence: UInt64 = 0
        var phase: Phase = .hidden
        var geometry: Geometry?

        /// The currently presented progress, updated from live window
        /// state. Used to continue mid-flight motion without restarts.
        var presentedProgress: CGFloat = 0

        var isVisible: Bool { phase.isVisible }
        var isTransitioning: Bool { phase.isTransitioning }

        mutating func beginReveal() {
            intentSequence &+= 1
            phase = .revealing
        }

        mutating func beginHide() {
            intentSequence &+= 1
            phase = .hiding
        }

        mutating func beginDock() {
            intentSequence &+= 1
            phase = .docking
        }

        /// A transition the window server interrupted by retargeting. The
        /// frame stays wherever the live window is; presentation continues
        /// under the new intent.
        mutating func beginUserTakeover() {
            intentSequence &+= 1
            phase = .visible
            presentedProgress = 1
        }

        /// True when `candidate` is the newest intent, i.e. its animation
        /// still owns presentation completion.
        func ownsCompletion(_ candidate: UInt64) -> Bool {
            candidate == intentSequence
        }

        mutating func finishPresentation(at progress: CGFloat) {
            phase = progress > 0.5 ? .visible : .hidden
            presentedProgress = clampedProgress(progress)
        }

        /// Reveal (reversal) during an in-flight hide: continue from the
        /// current presentation state.
        mutating func reverseToReveal() {
            intentSequence &+= 1
            phase = .revealing
        }

        /// Hide (reversal) during an in-flight reveal: continue from the
        /// current presentation state.
        mutating func reverseToHide() {
            intentSequence &+= 1
            phase = .hiding
        }
    }

    static func clampedProgress(_ progress: CGFloat) -> CGFloat {
        guard progress.isFinite else { return 0 }
        return min(1, max(0, progress))
    }

    /// Derives presented progress from the live window frame. Both staged
    /// frames differ only along their joining line, so the fractional
    /// distance along that line is exact and monotonic.
    static func progress(of frame: CGRect, in geometry: Geometry) -> CGFloat {
        let deltaX = geometry.visibleFrame.minX - geometry.hiddenFrame.minX
        let deltaY = geometry.visibleFrame.minY - geometry.hiddenFrame.minY
        // Matching staged frames present the panel fully revealed; the
        // reveal then carries alpha only.
        guard deltaX != 0 || deltaY != 0 else { return 1 }
        let travelledX = frame.minX - geometry.hiddenFrame.minX
        let travelledY = frame.minY - geometry.hiddenFrame.minY
        let progress = (travelledX * deltaX + travelledY * deltaY)
            / (deltaX * deltaX + deltaY * deltaY)
        return clampedProgress(progress)
    }

    /// The single timing family for the unified timeline. AppKit owns
    /// window-frame motion; these curves are the shared timing source
    /// handed to NSAnimationContext.
    static func timingFunction(for phase: Phase) -> CAMediaTimingFunctionWrapper? {
        switch phase {
        case .revealing, .docking:
            // Fast, native-feeling attack with a soft settle.
            .reveal
        case .hiding:
            // Gentle pickup, quick departure.
            .hide
        case .hidden, .visible:
            nil
        }
    }

    static func duration(
        for phase: Phase,
        reduceMotion: Bool
    ) -> CFTimeInterval {
        guard !reduceMotion else { return reduceMotionDuration }
        switch phase {
        case .revealing: return revealDuration
        case .hiding: return hideDuration
        case .docking: return dockDuration
        case .hidden, .visible: return 0
        }
    }
}

/// Value description of the timing curve handed to NSAnimationContext.
/// Kept as plain control points so the motion family stays unit-testable
/// without importing QuartzCore into the model.
struct CAMediaTimingFunctionWrapper: Equatable {
    let point1: CGFloat
    let point2: CGFloat
    let point3: CGFloat
    let point4: CGFloat

    var controlPoints: (CGFloat, CGFloat, CGFloat, CGFloat) {
        (point1, point2, point3, point4)
    }

    static let reveal = CAMediaTimingFunctionWrapper(controlPoints: (0.16, 1, 0.3, 1))
    static let hide = CAMediaTimingFunctionWrapper(controlPoints: (0.4, 0, 1, 1))
    static let dock = CAMediaTimingFunctionWrapper(controlPoints: (0.16, 1, 0.3, 1))

    init(controlPoints: (CGFloat, CGFloat, CGFloat, CGFloat)) {
        self.point1 = controlPoints.0
        self.point2 = controlPoints.1
        self.point3 = controlPoints.2
        self.point4 = controlPoints.3
    }
}

/// Two-finger swipe/flick dismissal: a deliberate trackpad gesture toward
/// the panel's attached screen edge. The hosting view only observes
/// scroll events over non-scrollable chrome (scrollable content consumes
/// them deeper in the responder chain first), so accumulating toward the
/// attached corner cannot fight list scrolling or canvas panning.
///
/// Direction accounting: under natural scrolling the delivered delta is
/// inverted from the physical finger direction; with classic scrolling it
/// follows the finger. `isDirectionInvertedFromDevice` reports the user's
/// mode, so the policy resolves the physical direction for both.
enum PanelSwipeDismissalPolicy {
    static let triggerDistance: CGFloat = 48

    /// Accumulates phase-aware swipe samples and reports when the gesture
    /// has moved deliberately toward the attached corner's edges. Only
    /// components pointing at the attached corner accumulate, so
    /// perpendicular jitter cannot cancel a real swipe.
    struct Accumulator {
        private var accumulatedX: CGFloat = 0
        private var accumulatedY: CGFloat = 0
        private var hasTriggered = false

        mutating func reset() {
            accumulatedX = 0
            accumulatedY = 0
            hasTriggered = false
        }

        mutating func record(
            scrollingDeltaX: CGFloat,
            scrollingDeltaY: CGFloat,
            corner: ScreenCorner,
            isDeviceDirectionInverted: Bool
        ) -> Bool {
            guard !hasTriggered else { return false }
            guard scrollingDeltaX.isFinite, scrollingDeltaY.isFinite else {
                return false
            }

            // Natural scrolling inverts the content delta from the finger's
            // physical direction; classic scrolling keeps it aligned.
            let sign: CGFloat = isDeviceDirectionInverted ? -1 : 1
            let physicalX = sign * scrollingDeltaX
            let physicalY = sign * scrollingDeltaY

            // Only accumulate the components pointing toward the attached
            // corner; perpendicular jitter must not cancel a real swipe.
            switch corner {
            case .topLeft:
                if physicalX < 0 { accumulatedX += physicalX }
                if physicalY > 0 { accumulatedY += physicalY }
            case .topRight:
                if physicalX > 0 { accumulatedX += physicalX }
                if physicalY > 0 { accumulatedY += physicalY }
            case .bottomLeft:
                if physicalX < 0 { accumulatedX += physicalX }
                if physicalY < 0 { accumulatedY += physicalY }
            case .bottomRight:
                if physicalX > 0 { accumulatedX += physicalX }
                if physicalY < 0 { accumulatedY += physicalY }
            }

            let towardDistance = hypot(accumulatedX, accumulatedY)
            guard towardDistance >= PanelSwipeDismissalPolicy.triggerDistance else {
                return false
            }
            hasTriggered = true
            return true
        }
    }
}