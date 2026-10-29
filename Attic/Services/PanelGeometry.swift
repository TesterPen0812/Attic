import CoreGraphics
import SwiftUI

struct PanelWorkAreaPlacement: Equatable {
    let frame: CGRect
    let preferredSize: CGSize

    var isTemporarilyClamped: Bool {
        abs(frame.width - preferredSize.width) >= 0.5
            || abs(frame.height - preferredSize.height) >= 0.5
    }
}

enum PanelGeometry {
    static let triggerSize: CGFloat = 16
    static let minimumHeight: CGFloat = 460
    static let preferredHeightCeiling: CGFloat = 700
    static let screenInset: CGFloat = 12

    /// Moves Canvas controls above the actual rendered error banner instead of
    /// assuming a fixed one- or two-line height at compact widths.
    static func canvasErrorBannerOffset(measuredHeight: CGFloat) -> CGFloat {
        guard measuredHeight.isFinite, measuredHeight > 0 else { return 0 }
        return measuredHeight + 4
    }

    static let minimumPanelSize = CGSize(
        width: PanelContentSize.min,
        height: minimumHeight
    )
    static let defaultPanelSize = CGSize(
        width: PanelContentSize.defaultValue,
        height: preferredWorkspaceHeight(contentWidth: PanelContentSize.defaultValue)
    )

    /// Superellipse exponent used for the squircle corners.
    static let squircleExponent: CGFloat = 5

    /// Minimum horizontal padding from the panel edge to content, ensuring
    /// content never intersects the corner curve. Derived from the maximum
    /// inward deviation of the corner superellipse plus a safety margin.
    static func contentInsets(cornerSize: CGFloat, panelSize: CGSize) -> EdgeInsets {
        let insetFactor = Squircle.cornerInsetFactor(exponent: squircleExponent)
        let effectiveRadius = max(
            0,
            min(cornerSize, panelSize.width / 2, panelSize.height / 2)
        )
        let cornerInset = effectiveRadius * insetFactor
        let horizontal = max(AtticStyle.horizontalPadding, cornerInset + 6)
        let top = max(8, cornerInset + 4)
        let bottom = max(10, cornerInset + 6)
        return EdgeInsets(top: top, leading: horizontal, bottom: bottom, trailing: horizontal)
    }

    /// Insets for controls attached to the panel shell rather than its
    /// section content. The corner curve's maximum inward deviation is the
    /// diagonal of the local superellipse, so adding a fixed optical clearance
    /// to that value keeps the outer corner of every hit region inside the
    /// visible squircle as the user changes radius or panel size.
    static func chromeInsets(cornerSize: CGFloat, panelSize: CGSize) -> EdgeInsets {
        let effectiveRadius = max(
            0,
            min(cornerSize, panelSize.width / 2, panelSize.height / 2)
        )
        let curveInset = effectiveRadius * Squircle.cornerInsetFactor(exponent: squircleExponent)
        let edgeInset = max(
            AtticStyle.chromeMinimumInset,
            curveInset + AtticStyle.chromeCornerClearance
        )
        return EdgeInsets(
            top: edgeInset,
            leading: edgeInset,
            bottom: edgeInset,
            trailing: edgeInset
        )
    }

    /// Positions the first task section relative to the bottom of the top
    /// controls. This keeps the perceived gap stable while the squircle's
    /// radius moves the permanent chrome inward.
    static func taskWorkspaceTopPadding(cornerSize: CGFloat, panelSize: CGSize) -> CGFloat {
        let content = contentInsets(cornerSize: cornerSize, panelSize: panelSize)
        let chrome = chromeInsets(cornerSize: cornerSize, panelSize: panelSize)
        return max(
            0,
            chrome.top
                + AtticStyle.controlHitSize
                + AtticStyle.chromeWorkspaceSpacing
                - content.top
                - AtticStyle.taskScrollTopPadding
        )
    }

    /// The effective panel width for a given content size setting.
    static func panelWidth(for contentSize: CGFloat) -> CGFloat {
        contentSize
    }

    /// Native live resize limits for a particular display. There is no
    /// product-defined maximum; the visible work area is the only upper bound.
    static func resizeMaximumSize(in visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: max(0, visibleFrame.width - (screenInset * 2)),
            height: max(0, visibleFrame.height - (screenInset * 2))
        )
    }

    static func clampedPanelSize(
        _ size: CGSize,
        in visibleFrame: CGRect? = nil
    ) -> CGSize {
        let width = size.width.isFinite ? size.width : defaultPanelSize.width
        let height = size.height.isFinite ? size.height : defaultPanelSize.height
        let minimumClamped = CGSize(
            width: max(width, minimumPanelSize.width),
            height: max(height, minimumPanelSize.height)
        )
        guard let visibleFrame else { return minimumClamped }
        let upperBound = resizeMaximumSize(in: visibleFrame)
        return CGSize(
            width: min(minimumClamped.width, upperBound.width),
            height: min(minimumClamped.height, upperBound.height)
        )
    }

    /// Resolves the currently displayable frame without mutating the user's
    /// preferred size. A temporary Dock, menu-bar, or destination-display
    /// clamp can therefore be reversed when a roomier work area returns.
    static func workAreaPlacement(
        preferredSize: CGSize,
        in visibleFrame: CGRect,
        corner: ScreenCorner
    ) -> PanelWorkAreaPlacement {
        let normalizedPreference = clampedPanelSize(preferredSize)
        let displayedSize = clampedPanelSize(
            normalizedPreference,
            in: visibleFrame
        )
        return PanelWorkAreaPlacement(
            frame: panelFrame(
                in: visibleFrame,
                size: displayedSize,
                corner: corner
            ),
            preferredSize: normalizedPreference
        )
    }

    /// Keeps an already-sized panel wholly inside the display's usable work
    /// area. This is intentionally separate from `clampedPanelSize`: moving a
    /// panel must not unexpectedly enlarge it, while resize and restore paths
    /// continue to own minimum-size enforcement.
    static func constrainedFrame(
        _ frame: CGRect,
        to visibleFrame: CGRect,
        inset: CGFloat = screenInset
    ) -> CGRect {
        let horizontalInset = min(max(0, inset), max(0, visibleFrame.width / 2))
        let verticalInset = min(max(0, inset), max(0, visibleFrame.height / 2))
        let safeFrame = visibleFrame.insetBy(dx: horizontalInset, dy: verticalInset)
        let size = CGSize(
            width: min(max(0, frame.width), max(0, safeFrame.width)),
            height: min(max(0, frame.height), max(0, safeFrame.height))
        )
        let maximumOriginX = max(safeFrame.minX, safeFrame.maxX - size.width)
        let maximumOriginY = max(safeFrame.minY, safeFrame.maxY - size.height)
        let origin = CGPoint(
            x: min(max(frame.minX, safeFrame.minX), maximumOriginX),
            y: min(max(frame.minY, safeFrame.minY), maximumOriginY)
        )
        return CGRect(origin: origin, size: size)
    }

    static func hotspot(in screenFrame: CGRect, corner: ScreenCorner, size: CGFloat = triggerSize) -> CGRect {
        let origin: CGPoint
        switch corner {
        case .topLeft:
            origin = CGPoint(x: screenFrame.minX, y: screenFrame.maxY - size)
        case .topRight:
            origin = CGPoint(x: screenFrame.maxX - size, y: screenFrame.maxY - size)
        case .bottomLeft:
            origin = CGPoint(x: screenFrame.minX, y: screenFrame.minY)
        case .bottomRight:
            origin = CGPoint(x: screenFrame.maxX - size, y: screenFrame.minY)
        }
        return CGRect(origin: origin, size: CGSize(width: size, height: size))
    }

    static func panelFrame(
        in visibleFrame: CGRect,
        size: CGSize,
        corner: ScreenCorner,
        inset: CGFloat = screenInset
    ) -> CGRect {
        let x: CGFloat
        let y: CGFloat

        switch corner {
        case .topLeft, .bottomLeft:
            x = visibleFrame.minX + inset
        case .topRight, .bottomRight:
            x = visibleFrame.maxX - size.width - inset
        }

        switch corner {
        case .topLeft, .topRight:
            y = visibleFrame.maxY - size.height - inset
        case .bottomLeft, .bottomRight:
            y = visibleFrame.minY + inset
        }

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A local, still-on-screen staging frame used while fading the panel.
    /// Moving inward keeps every intermediate window frame inside the usable
    /// display area; the panel's alpha supplies the hidden presentation.
    static func hiddenFrame(
        from panelFrame: CGRect,
        corner: ScreenCorner,
        in visibleFrame: CGRect,
        distance: CGFloat = 18
    ) -> CGRect {
        let xOffset: CGFloat
        let yOffset: CGFloat
        switch corner {
        case .topLeft:
            xOffset = distance
            yOffset = -distance
        case .topRight:
            xOffset = -distance
            yOffset = -distance
        case .bottomLeft:
            xOffset = distance
            yOffset = distance
        case .bottomRight:
            xOffset = -distance
            yOffset = distance
        }
        return constrainedFrame(
            panelFrame.offsetBy(dx: xOffset, dy: yOffset),
            to: visibleFrame
        )
    }

    static func preferredHeight(taskCount: Int, sectionCount: Int, isComposing: Bool) -> CGFloat {
        let header: CGFloat = 76
        let composer: CGFloat = isComposing ? 70 : 0
        let taskGaps = max(taskCount - sectionCount, 0)
        let content: CGFloat = taskCount == 0
            ? 90
            : CGFloat(taskCount) * AtticStyle.rowHeight
                + CGFloat(taskGaps) * AtticStyle.taskSpacing
                + CGFloat(sectionCount) * 24
                + 10
        return min(max(header + composer + content + 16, minimumHeight), preferredHeightCeiling)
    }


    static func preferredCanvasHeight() -> CGFloat {
        min(max(560, minimumHeight), preferredHeightCeiling)
    }

    /// The redesigned panel is a stable workspace rather than a card that
    /// repeatedly changes size as content comes and goes. Keeping one frame
    /// also preserves the user's spatial memory when switching sections.
    static func preferredWorkspaceHeight(contentWidth: CGFloat) -> CGFloat {
        min(max(contentWidth * 1.45, minimumHeight), preferredHeightCeiling)
    }

    /// Prefer the closest free position at an obstacle edge. The candidate
    /// count depends on the obstacles, never on screen pixels or a timer.
    static func avoidingOverlap(_ preferred: CGRect, occupied: [CGRect], within safe: CGRect, gap: CGFloat = 10) -> CGRect {
        let proposed = CGRect(x: min(max(safe.minX, preferred.minX), max(safe.minX, safe.maxX - preferred.width)),
                              y: min(max(safe.minY, preferred.minY), max(safe.minY, safe.maxY - preferred.height)),
                              width: preferred.width, height: preferred.height)
        let obstacles = occupied.filter { !$0.isEmpty && $0.intersects(safe) }
        guard obstacles.contains(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(proposed) }) else { return proposed }
        let xs = [proposed.minX, safe.minX, safe.maxX - proposed.width]
            + obstacles.flatMap { [$0.minX - gap - proposed.width, $0.maxX + gap] }
        let ys = [proposed.minY, safe.minY, safe.maxY - proposed.height]
            + obstacles.flatMap { [$0.minY - gap - proposed.height, $0.maxY + gap] }
        var best = proposed
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for x in xs {
            for y in ys {
                let candidate = CGRect(x: min(max(safe.minX, x), max(safe.minX, safe.maxX - proposed.width)),
                                       y: min(max(safe.minY, y), max(safe.minY, safe.maxY - proposed.height)),
                                       width: proposed.width, height: proposed.height)
                let overlap = obstacles.reduce(CGFloat.zero) { sum, obstacle in
                    let intersection = candidate.intersection(obstacle.insetBy(dx: -gap / 2, dy: -gap / 2))
                    return sum + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
                let distance = hypot(candidate.minX - proposed.minX, candidate.minY - proposed.minY)
                if overlap < bestOverlap || (overlap == bestOverlap && distance < bestDistance) {
                    best = candidate; bestOverlap = overlap; bestDistance = distance
                }
            }
        }
        return best
    }
}

enum PanelDockingPolicy {
    static let minimumFlickDistance: CGFloat = 36
    static let minimumFlickSpeed: CGFloat = 650
    static let minimumFlickAxisSpeed: CGFloat = 180

    static func nearestCorner(for panelFrame: CGRect, in visibleFrame: CGRect) -> ScreenCorner {
        corner(
            right: panelFrame.midX >= visibleFrame.midX,
            top: panelFrame.midY >= visibleFrame.midY
        )
    }

    static func flickCorner(
        velocity: CGPoint,
        translation: CGPoint,
        panelFrame: CGRect,
        in visibleFrame: CGRect
    ) -> ScreenCorner? {
        guard hypot(translation.x, translation.y) >= minimumFlickDistance,
              hypot(velocity.x, velocity.y) >= minimumFlickSpeed else {
            return nil
        }

        let right = abs(velocity.x) >= minimumFlickAxisSpeed
            ? velocity.x > 0
            : panelFrame.midX >= visibleFrame.midX
        let top = abs(velocity.y) >= minimumFlickAxisSpeed
            ? velocity.y > 0
            : panelFrame.midY >= visibleFrame.midY
        return corner(right: right, top: top)
    }

    enum ReleaseAction: Equatable {
        case hide
        case dock(ScreenCorner)
    }

    /// Header drags only reposition. Explicit dismissal belongs to the
    /// two-finger swipe route, so even a fast return to the same corner docks.
    static func releaseAction(
        velocity: CGPoint,
        translation: CGPoint,
        attachedCorner: ScreenCorner,
        panelFrame: CGRect,
        in visibleFrame: CGRect
    ) -> ReleaseAction {
        if let flick = flickCorner(
            velocity: velocity,
            translation: translation,
            panelFrame: panelFrame,
            in: visibleFrame
        ) {
            return .dock(flick)
        }
        return .dock(nearestCorner(for: panelFrame, in: visibleFrame))
    }

    private static func corner(right: Bool, top: Bool) -> ScreenCorner {
        switch (right, top) {
        case (false, true): .topLeft
        case (true, true): .topRight
        case (false, false): .bottomLeft
        case (true, false): .bottomRight
        }
    }
}

enum PanelTrackpadSwipePhase: Equatable {
    case began
    case changed
    case ended
    case cancelled
    case none
}

struct PanelTrackpadSwipeSample: Equatable {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let phase: PanelTrackpadSwipePhase
    let isPrecise: Bool
    let isDirectionInvertedFromDevice: Bool
    /// The event's timestamp (seconds), for the release's speed.
    var time: TimeInterval = 0
}

/// Accumulates only the undecided prefix of one precise, phase-owned gesture.
/// The first nonzero direction remains authoritative even when every sample
/// is smaller than the acquisition threshold.
struct PanelTrackpadSwipeIntent {
    private(set) var displacement = CGPoint.zero
    private(set) var initialDirection: CGPoint?

    mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat) {
        guard deltaX.isFinite, deltaY.isFinite else { return }
        if initialDirection == nil, deltaX != 0 || deltaY != 0 {
            initialDirection = CGPoint(x: deltaX, y: deltaY)
        }
        displacement.x += deltaX
        displacement.y += deltaY
    }

    var isReady: Bool {
        hypot(displacement.x, displacement.y) >= PanelTrackpadDismissTracker.minimumIntentDelta
    }

    var isHorizontal: Bool {
        guard let initialDirection else { return false }
        let dominance = PanelTrackpadDismissTracker.horizontalDominance
        return abs(initialDirection.x) > abs(initialDirection.y) * dominance
            && abs(displacement.x) > abs(displacement.y) * dominance
    }
}

enum PanelTrackpadDismissUpdate: Equatable {
    case passThrough
    case tracking
    case requestHide
}

/// Presentation geometry only: the native hosting bounds and saved panel size
/// never participate in the collapse. Translations are relative to the backing
/// layer's actual anchor so the selected visible corner remains stationary.
enum PanelCollapseGeometry {
    static let collapsedScale: CGFloat = 0.015

    static func progress(forSwipeDistance distance: CGFloat, panelWidth: CGFloat) -> CGFloat {
        guard distance.isFinite, panelWidth.isFinite else { return 0 }
        let travel = min(280, max(120, panelWidth * 0.65))
        return min(0.95, max(0, distance / travel))
    }

    /// The pull (owner, 2026-10-01): the panel follows the fingers with
    /// resistance, firm at first and giving less the further it goes
    /// (UIKit's rubber band, tending to the whole travel), so it never
    /// races ahead of the fingers.
    static func resistedProgress(forSwipeDistance distance: CGFloat, panelWidth: CGFloat) -> CGFloat {
        guard distance.isFinite, panelWidth.isFinite, distance > 0 else { return 0 }
        let travel = min(280, max(120, panelWidth * 0.65))
        let resisted = (1 - 1 / (distance * pullResistance / travel + 1)) * travel
        return progress(forSwipeDistance: resisted, panelWidth: panelWidth)
    }

    /// The rubber band's constant (UIKit's 0.55).
    static let pullResistance: CGFloat = 0.55

    /// A swipe that started with the panel at `start` (0 shown, 1 hidden):
    /// where `distance` (points toward the edge; negative is away from it)
    /// puts the panel. Toward the edge it is the pull above, over what is
    /// left of the travel; away from it (a re-swipe taking the panel back
    /// from a close) it opens evenly, fully after one travel. A fresh swipe
    /// (`start` 0, `distance` never negative) is exactly the pull.
    static func followProgress(from start: CGFloat, distance: CGFloat, panelWidth: CGFloat) -> CGFloat {
        let start = start.isFinite ? min(1, max(0, start)) : 0
        guard distance.isFinite, panelWidth.isFinite else { return start }
        if distance >= 0 {
            return start + (1 - start) * resistedProgress(forSwipeDistance: distance, panelWidth: panelWidth)
        }
        let travel = min(280, max(120, panelWidth * 0.65))
        return start * max(0, 1 + distance / travel)
    }

    /// How far back from the edge a re-swipe can take the panel: one travel
    /// opens it fully (`followProgress`).
    static func openingTravel(panelWidth: CGFloat) -> CGFloat {
        guard panelWidth.isFinite else { return 120 }
        return min(280, max(120, panelWidth * 0.65))
    }

    /// Under Reduced motion the pull fades the panel instead of moving it:
    /// its opacity at `progress` (never below `reducedMinimumOpacity` while
    /// the fingers are down).
    static func reducedOpacity(progress: CGFloat) -> CGFloat {
        let progress = progress.isFinite ? min(1, max(0, progress)) : 0
        return 1 - progress * (1 - reducedMinimumOpacity)
    }

    static let reducedMinimumOpacity: CGFloat = 0.35
    /// A swipe's close or spring-back under Reduced motion: a short fade.
    static let reducedFadeDuration: TimeInterval = 0.18

    static func transform(
        progress: CGFloat, visibleBounds: CGRect, layerBounds: CGRect,
        corner: ScreenCorner, reduceMotion: Bool = false, layerAnchor: CGPoint? = nil
    ) -> CGAffineTransform {
        guard !reduceMotion else { return .identity }
        let progress = progress.isFinite ? min(1, max(0, progress)) : 0
        let scale = 1 - progress * (1 - collapsedScale)
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        let anchor = CGPoint(x: right ? visibleBounds.maxX : visibleBounds.minX,
                             y: top ? visibleBounds.maxY : visibleBounds.minY)
        let pivot = layerAnchor ?? CGPoint(x: layerBounds.midX, y: layerBounds.midY)
        return CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: (anchor.x - pivot.x) * (1 - scale),
            ty: (anchor.y - pivot.y) * (1 - scale)
        )
    }
}

/// A new swipe that picks the panel up from a swipe's release motion (its
/// close or its spring-back) while that motion is still running (owner,
/// 2026-10-22). Timed hides and reveals (the pointer, Escape, the shortcut)
/// are never taken over.
struct PanelSwipeTakeover: Equatable {
    /// Where the motion had the panel (0 shown, 1 hidden) …
    var progress: CGFloat
    /// … and how fast it was going (progress per second, + toward hidden).
    var velocity: CGFloat
    /// The panel's width, which sets the swipe's travel.
    var panelWidth: CGFloat

    /// The motion's speed carries into the new swipe: on top of where the
    /// fingers put the panel, the release spring keeps running with its
    /// speed but now rests on the fingers, so the panel neither jumps nor
    /// stops dead and then follows the fingers alone. This is the swipe
    /// close spring (critically damped, `swipeCloseSpring`) released from
    /// zero displacement with the motion's velocity: v·t·e^(−ωt), which
    /// starts at that speed, peaks after 1/ω (about 38 ms) at v/(ωe) and has
    /// gone after about 0.2 s.
    static func carry(velocity: CGFloat, elapsed: TimeInterval) -> CGFloat {
        guard velocity.isFinite, elapsed.isFinite, elapsed > 0 else { return 0 }
        let omega = 2 * Double.pi / max(0.05, PanelHideMotionTuning.swipeCloseSpring.response)
        return velocity * CGFloat(elapsed * exp(-omega * elapsed))
    }

    /// The carry has died away (under a thousandth of the travel).
    static func carryHasEnded(velocity: CGFloat, elapsed: TimeInterval) -> Bool {
        let omega = 2 * Double.pi / max(0.05, PanelHideMotionTuning.swipeCloseSpring.response)
        return elapsed > 1 / omega && abs(carry(velocity: velocity, elapsed: elapsed)) < 0.001
    }
}

/// Recognizes a phase-aware, precise horizontal swipe toward the screen edge
/// that owns the panel. Mouse wheels and ordinary content scrolling remain on
/// their existing paths.
struct PanelTrackpadDismissTracker {
    /// The release closes the panel when its projected travel reaches this
    /// far toward the edge (see `projectedDistance`).
    static let minimumDistance: CGFloat = 48
    /// … and only once the swipe itself has moved this far toward the edge
    /// (a tiny twitch never closes, however fast), unless the panel is
    /// already past `minimumDistance` (a re-swipe that caught a close).
    static let minimumFlickDistance: CGFloat = 12
    /// The window of recent movement the release spring's speed is measured
    /// over (the controller's `captureSwipeRelease` uses the same).
    static let velocityWindow: TimeInterval = 0.1
    /// The release's projection reads the fingers' speed over the last
    /// 50 ms and over the last 0.1 s and takes the slower (`releaseVelocity`),
    /// so fingers that came to rest before lifting project nothing, and a
    /// flick must have kept its speed, not just ended in a burst.
    static let projectionVelocityWindow: TimeInterval = 0.05
    /// Only a flick coasts: below this speed (points per second, sustained
    /// as above) a release projects nothing and closes only past
    /// `minimumDistance` (owner, 10-23: a slow drag "slips, and hides
    /// quickly"). Slow drags run at 30–120 pt/s; the flicks the projection
    /// is for at 230 pt/s and up (g7: 36 pt at 234 pt/s closes).
    static let flickMinimumSpeed: CGFloat = 200
    /// The release's coast, as UIKit projects a scroll view's deceleration:
    /// v/1000 · r/(1 − r) points for v points per second. r is UIKit's
    /// `.fast` rate (0.99), a coast of about 0.1 s × v (owner, 2026-10-22:
    /// close on projected travel instead of a 450 pt/s flick threshold).
    /// `.normal` (0.998, about 0.5 s × v) would close a 12 pt nudge at
    /// 72 pt/s; `.fast` closes one at 364 pt/s, near the old 450 pt/s flick,
    /// and still closes every flick around the old threshold (35 pt at
    /// 430 pt/s projects to 78 pt) with no edge where it can go either way.
    static let decelerationRate: CGFloat = 0.99
    static let horizontalDominance: CGFloat = 1.25
    static let minimumIntentDelta: CGFloat = 0.5

    private enum State {
        case idle
        case undecided
        case tracking
        case rejected
    }

    private var state = State.idle
    private var intent = PanelTrackpadSwipeIntent()
    /// The swipe's distance toward the edge (points). A takeover's may go
    /// below zero, back from the edge, down to one opening travel.
    private(set) var progress: CGFloat = 0
    /// The release motion this swipe took over, if it did.
    private(set) var takeover: PanelSwipeTakeover?
    /// Recent movement toward the edge, for the release's speed.
    private var recent: [(time: TimeInterval, delta: CGFloat)] = []
    /// When the swipe began (its first event).
    private var began: TimeInterval?

    /// The coast a release at `velocity` (points per second toward the
    /// edge) adds to its distance.
    static func projectedCoast(velocity: CGFloat) -> CGFloat {
        guard velocity.isFinite else { return 0 }
        return velocity / 1000 * decelerationRate / (1 - decelerationRate)
    }

    /// Whether a release at `progress` with `velocity` toward the edge
    /// closes the panel: its projected travel reaches `minimumDistance`
    /// once it has moved `minimumFlickDistance`.
    static func closes(progress: CGFloat, velocity: CGFloat) -> Bool {
        progress >= minimumFlickDistance && progress + releaseCoast(velocity: velocity) >= minimumDistance
    }

    /// The coast a release adds: a flick's projection toward the edge, none
    /// for anything slower than `flickMinimumSpeed`; a fling back from the
    /// edge always counts against it.
    static func releaseCoast(velocity: CGFloat) -> CGFloat {
        guard velocity.isFinite, velocity < 0 || velocity >= flickMinimumSpeed else { return 0 }
        return projectedCoast(velocity: velocity)
    }

    /// A takeover's release: the same rule on the panel's position. The
    /// projected position must reach the one `minimumDistance` gives a
    /// fresh swipe, and the swipe must have moved `minimumFlickDistance`
    /// toward the edge unless the panel already is past that position.
    static func closes(progress: CGFloat, velocity: CGFloat, takeover: PanelSwipeTakeover?) -> Bool {
        guard let takeover else { return closes(progress: progress, velocity: velocity) }
        func position(_ distance: CGFloat) -> CGFloat {
            PanelCollapseGeometry.followProgress(from: takeover.progress, distance: distance, panelWidth: takeover.panelWidth)
        }
        let threshold = PanelCollapseGeometry.followProgress(from: 0, distance: minimumDistance, panelWidth: takeover.panelWidth)
        guard position(progress + releaseCoast(velocity: velocity)) >= threshold else { return false }
        return progress >= minimumFlickDistance || position(progress) >= threshold
    }

    /// The movement in the last `window` seconds over the time it covers
    /// (the whole window, or the swipe's own time if shorter). Before
    /// 10-23 this was the movement of the events in the window over the
    /// time since the first of them, at least 1/120 s: after a pause, a
    /// 3 pt nudge just before the lift read as 375 pt/s and closed a slow
    /// 33 pt drag.
    private func velocity(at time: TimeInterval, window: TimeInterval) -> CGFloat {
        guard time > 0 else { return 0 }
        let moved = recent.filter { time - $0.time < window - 1e-6 }.reduce(0) { $0 + $1.delta }
        let covered = min(window, began.map { time - $0 } ?? window)
        return moved / CGFloat(max(covered, 1 / 120))
    }

    /// The fingers' speed at the lift, as the projection uses it: the
    /// slower of the last 50 ms and the last 0.1 s (opposite signs read as
    /// no speed), so a burst as the fingers leave the glass is not a flick.
    func releaseVelocity(at time: TimeInterval) -> CGFloat {
        let recentSpeed = velocity(at: time, window: Self.projectionVelocityWindow)
        let sustained = velocity(at: time, window: Self.velocityWindow)
        guard recentSpeed.sign == sustained.sign else { return 0 }
        return abs(recentSpeed) < abs(sustained) ? recentSpeed : sustained
    }

    private mutating func record(_ delta: CGFloat, at time: TimeInterval) {
        guard time > 0 else { return }
        recent.append((time, delta))
        recent.removeAll { time - $0.time > Self.velocityWindow }
    }

    /// Where a swipe may take the panel back to: the edge for a fresh one,
    /// one opening travel back for a takeover.
    private var lowestProgress: CGFloat {
        guard let takeover, takeover.progress > 0 else { return 0 }
        return -PanelCollapseGeometry.openingTravel(panelWidth: takeover.panelWidth)
    }

    static func isTowardDockedSide(
        deltaX: CGFloat,
        deltaY: CGFloat,
        isDirectionInvertedFromDevice: Bool,
        dockedCorner: ScreenCorner
    ) -> Bool {
        let inversion: CGFloat = isDirectionInvertedFromDevice ? -1 : 1
        let physicalX = deltaX * inversion
        let physicalY = deltaY * inversion
        let edgeDirection = horizontalEdgeDirection(for: dockedCorner)
        return physicalX * edgeDirection > 0
            && abs(physicalX) > abs(physicalY) * horizontalDominance
    }

    /// `takeover`: a release motion is running that this swipe picks up if
    /// it turns out horizontal, in either direction (read when it decides).
    mutating func update(
        sample: PanelTrackpadSwipeSample,
        dockedCorner: ScreenCorner,
        towardDockedSide: Bool = true,
        takeover offered: PanelSwipeTakeover? = nil
    ) -> PanelTrackpadDismissUpdate {
        guard sample.isPrecise, sample.phase != .none else {
            reset()
            return .passThrough
        }

        if sample.phase == .began {
            reset()
            state = .undecided
            began = sample.time > 0 ? sample.time : nil
        }
        guard state != .idle else { return .passThrough }
        if sample.phase == .cancelled {
            let wasTracking = state == .tracking
            reset()
            return wasTracking ? .tracking : .passThrough
        }
        if sample.phase == .ended {
            let inversion: CGFloat = sample.isDirectionInvertedFromDevice ? -1 : 1
            let direction = Self.horizontalEdgeDirection(for: dockedCorner) * (towardDockedSide ? 1 : -1)
            let delta = sample.deltaX * inversion * direction
            progress = max(lowestProgress, progress + delta)
            record(delta, at: sample.time)
            let shouldHide = state == .tracking && Self.closes(
                progress: progress, velocity: releaseVelocity(at: sample.time),
                takeover: takeover
            )
            reset()
            return shouldHide ? .requestHide : .passThrough
        }

        let inversion: CGFloat = sample.isDirectionInvertedFromDevice ? -1 : 1
        let physicalX = sample.deltaX * inversion
        let physicalY = sample.deltaY * inversion
        let edgeDirection = Self.horizontalEdgeDirection(for: dockedCorner) * (towardDockedSide ? 1 : -1)
        let edgeProgress = physicalX * edgeDirection

        if state == .rejected {
            return .passThrough
        }
        if state == .undecided {
            intent.accumulate(deltaX: physicalX, deltaY: physicalY)
            guard intent.isReady else { return .passThrough }
            // A takeover goes either way; a fresh swipe only toward the edge.
            guard offered != nil || ((intent.initialDirection?.x ?? 0) * edgeDirection > 0
                                     && intent.displacement.x * edgeDirection > 0),
                  intent.isHorizontal else {
                state = .rejected
                return .passThrough
            }
            state = .tracking
            takeover = offered
            progress = max(lowestProgress, intent.displacement.x * edgeDirection)
            record(intent.displacement.x * edgeDirection, at: sample.time)
            return .tracking
        }

        progress = max(lowestProgress, progress + edgeProgress)
        record(edgeProgress, at: sample.time)
        return .tracking
    }

    mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        state = .idle
        intent = PanelTrackpadSwipeIntent()
        progress = 0
        takeover = nil
        recent = []
        began = nil
    }

    private static func horizontalEdgeDirection(for corner: ScreenCorner) -> CGFloat {
        switch corner {
        case .topLeft, .bottomLeft:
            1
        case .topRight, .bottomRight:
            -1
        }
    }
}

enum PanelModeDockLayout {
    static func width(isExpanded: Bool) -> CGFloat {
        let visibleSectionCount = isExpanded ? PanelPage.allCases.count : 1
        return AtticStyle.controlHitSize * CGFloat(visibleSectionCount)
    }

    static func isVisible(
        _ section: PanelSection,
        selectedSection: PanelSection,
        isExpanded: Bool
    ) -> Bool {
        isExpanded || section == selectedSection
    }
}

enum TaskEntryBarLayout {
    static func width(panelWidth: CGFloat, chromeInsets: EdgeInsets) -> CGFloat {
        max(0, panelWidth - chromeInsets.leading - chromeInsets.trailing)
    }

    static func textFieldWidth(panelWidth: CGFloat, chromeInsets: EdgeInsets) -> CGFloat {
        max(
            0,
            width(panelWidth: panelWidth, chromeInsets: chromeInsets)
                - (2 * AtticStyle.taskComposerControlSize)
                // One 8pt action gap and the field’s 12pt trailing inset.
                - 20
        )
    }
}

/// Fixed chrome retains a faint impression of the scrolling content beneath
/// it. The mask is one static gradient: no per-frame snapshots or blur pass.
/// Pointer shields remain separate so dimmed rows cannot receive clicks.
enum TaskScrollMaskLayout {
    /// How far past the chrome the fade runs before content is fully opaque.
    static let fadeLength: CGFloat = 26

    struct Stops: Equatable {
        /// Content is invisible from the top edge to here.
        let topClearEnd: CGFloat
        /// … and fully opaque from here on.
        let topFadeEnd: CGFloat
        /// Content starts fading here …
        let bottomFadeStart: CGFloat
        /// … and is invisible from here to the bottom edge.
        let bottomClearStart: CGFloat
    }

    /// `topObscuredHeight` and `bottomObscuredHeight` are the chrome bands
    /// measured from the scrolling area's own edges. Degenerate inputs
    /// (non-finite, negative, or bands that overlap) collapse safely.
    static func stops(
        height: CGFloat,
        topObscuredHeight: CGFloat,
        bottomObscuredHeight: CGFloat,
        fadeLength: CGFloat = fadeLength
    ) -> Stops {
        let height = height.isFinite ? max(height, 1) : 1
        func points(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
        let fade = points(fadeLength)
        let topClear = points(topObscuredHeight)
        let bottomClear = points(bottomObscuredHeight)
        // Keep at least a sliver of fully visible content between the bands.
        let available = max(0, height - topClear - bottomClear)
        let usableFade = min(fade, available / 2)
        let topClearEnd = min(1, topClear / height)
        let topFadeEnd = min(1, (topClear + usableFade) / height)
        let bottomClearStart = max(topFadeEnd, 1 - bottomClear / height)
        let bottomFadeStart = max(topFadeEnd, bottomClearStart - usableFade / height)
        return Stops(
            topClearEnd: topClearEnd,
            topFadeEnd: topFadeEnd,
            bottomFadeStart: bottomFadeStart,
            bottomClearStart: bottomClearStart
        )
    }

    static func underChromeOpacity(reduceTransparency: Bool, increasedContrast: Bool) -> Double {
        reduceTransparency || increasedContrast ? 0 : 0.16
    }

    /// Fully readable in the workspace, subdued behind chrome, clear at the
    /// outer edge. Accessibility contrast settings remove the underlay.
    static func gradientStops(_ stops: Stops, underChromeOpacity: Double = 0.16, headerUnderChromeOpacity: Double? = nil) -> [Gradient.Stop] {
        let header = Color.black.opacity(min(1, max(0, headerUnderChromeOpacity ?? underChromeOpacity)))
        let underlay = Color.black.opacity(min(1, max(0, underChromeOpacity)))
        return [
            .init(color: .clear, location: 0),
            .init(color: header, location: min(0.012, stops.topClearEnd)),
            .init(color: header, location: stops.topClearEnd),
            .init(color: .black, location: stops.topFadeEnd),
            .init(color: .black, location: stops.bottomFadeStart),
            .init(color: underlay, location: stops.bottomClearStart),
            .init(color: underlay, location: max(0.988, stops.bottomClearStart)),
            .init(color: .clear, location: 1)
        ]
    }
}

/// The saved-notes drawer overlays round glass buttons on its scrolling list.
/// Its chrome bands have to clear each button's whole footprint — otherwise a
/// row rests underneath one and its preview text is unreadable — and the list
/// fades under them the way the task list already does.
enum SavedNotesDrawerLayout {
    static let buttonDiameter: CGFloat = 36
    /// Distance from the drawer edge to the button's own frame.
    static let buttonEdgePadding: CGFloat = 14
    /// How far a button reaches into the list, measured from the same edge.
    static var buttonFootprint: CGFloat { buttonEdgePadding + buttonDiameter }

    /// Resting inset for rows, and the band the mask keeps subdued.
    static let chromeBandHeight: CGFloat = 64
    /// Shorter than the task list's fade: the drawer's bands are shorter too.
    static let fadeLength: CGFloat = 18

    static func stops(height: CGFloat) -> TaskScrollMaskLayout.Stops {
        TaskScrollMaskLayout.stops(
            height: height,
            topObscuredHeight: chromeBandHeight,
            bottomObscuredHeight: chromeBandHeight,
            fadeLength: fadeLength
        )
    }

    /// The band a pointer shield covers at each edge, the same rule the task
    /// list uses: the chrome band plus the fade, so nothing the mask has
    /// dimmed can be pressed or hovered.
    static var shieldHeight: CGFloat { chromeBandHeight + fadeLength }

    /// Where a row comes to rest. Past the shield, not merely past the band:
    /// the task list's first row overlaps its own shield by a few points, and
    /// at this drawer's row height that would leave a visible, fully opaque
    /// row with an inert top edge.
    static var rowRestingInset: CGFloat { shieldHeight }

    /// The drawer's empty state sits below the top fade so it is never
    /// rendered half-faded by the mask that exists for scrolling rows.
    static var emptyStateTopInset: CGFloat { shieldHeight }
}

/// Hover and keyboard focus feedback for the panel's quick-entry submit.
/// `atticGlassControl` supplies no hover variant on the material and opaque
/// treatments, and native glass interactivity answers the pointer only, so the
/// emphasis is drawn over whichever backing the system chose. Kept here so the
/// rules are testable without rendering the panel.
enum QuickSubmitEmphasis {
    /// Nothing is drawn at rest, and a disabled submit stays quiet: there is
    /// nothing to add yet.
    static func isEmphasized(canSubmit: Bool, isHovered: Bool, isFocused: Bool) -> Bool {
        canSubmit && (isHovered || isFocused)
    }

    /// Keyboard focus reads stronger than hover, as it does on the mode dock.
    static func strokeWidth(isFocused: Bool) -> CGFloat {
        isFocused ? 1.5 : 0.75
    }
}
