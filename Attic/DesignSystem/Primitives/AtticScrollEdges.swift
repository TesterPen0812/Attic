import AppKit
import SwiftUI

/// Native clip bounds shared by the page keepers and keyboard/composer glides.
enum AtticPanelScrollGeometry {
    @MainActor
    static func clampedOriginY(_ y: CGFloat, in scroll: NSScrollView) -> CGFloat {
        let clip = scroll.contentView
        let insets = clip.contentInsets
        let content = scroll.documentView?.frame.height ?? 0
        let upper = max(-insets.top, content - clip.bounds.height + insets.bottom)
        return min(max(y, -insets.top), upper)
    }
}

/// An AppKit clip-view glide that yields as soon as an input event or another
/// scroll changes the origin. This avoids animated lazy-stack layout hangs.
@MainActor
final class AtticPanelScrollGlide: NSObject {
    private weak var scroll: NSScrollView?
    private var link: CADisplayLink?
    private var spring = Spring(duration: 0.4, bounce: 0)
    private var from: Double = 0
    private var to: Double = 0
    /// Where the glide last put the clip (after AppKit's own rounding).
    private var placed: CGFloat = 0
    private var began: CFTimeInterval?

    var isRunning: Bool { link != nil }

    /// Moves content by `delta` points, clamped to the scrollable region.
    func run(by delta: CGFloat, in scroll: NSScrollView, spring: Spring) {
        stop()
        scroll.layoutSubtreeIfNeeded()
        let origin = scroll.contentView.bounds.origin.y
        let goal = AtticPanelScrollGeometry.clampedOriginY(origin + delta, in: scroll)
        guard abs(goal - origin) > 0.5 else { return }
        self.scroll = scroll
        self.spring = spring
        from = Double(origin)
        to = Double(goal)
        placed = origin
        began = nil
        let link = scroll.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        scroll = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let time = now - (began ?? link.timestamp)
        if began == nil { began = link.timestamp }
        advance(to: time)
    }

    /// One deterministic animation step; tests drive it directly.
    func advance(to time: TimeInterval) {
        guard let scroll else { return stop() }
        let clip = scroll.contentView
        // A gesture or another reveal owns any movement we did not place.
        guard abs(clip.bounds.origin.y - placed) <= 0.5 else { return stop() }
        let done = time >= spring.settlingDuration
        let value = done ? to : spring.value(fromValue: from, toValue: to, initialVelocity: 0, time: time)
        var origin = clip.bounds.origin
        origin.y = AtticPanelScrollGeometry.clampedOriginY(CGFloat(value), in: scroll)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        placed = clip.bounds.origin.y
        if done { stop() }
    }
}

// MARK: - Scroll edges before controls (D1, 2026-10-02; Clean cut, 2026-10-03)

/// Tasks and Done use Clean cut.
/// The owner disabled the native soft edge everywhere (overnight A1,
/// 2026-10-04), including saved preview choices and environment overrides.
/// Former soft-edge choices also resolve to Clean cut. Notes editor,
/// All notes and E1 cards use clean edges too.
extension View {
    /// Native effects stay hidden, including legacy geometry test injection.
    func atticScrollEdgeEffect() -> some View {
        scrollEdgeEffectHidden(true, for: .all)
    }
}
