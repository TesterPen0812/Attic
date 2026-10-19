import AppKit
import QuartzCore

#if DEBUG
/// Preview builds only (round DG1): with `ATTIC_FRAME_MONITOR=1`, a block
/// drag (⋮⋮) logs what an on-screen run needs to judge its feel, next to
/// the frame monitor's `ATTIC_FRAME` lines:
/// - `ATTIC_DRAG_EVENT <uptime> <ms>`: the main thread's time handling one
///   drag event (pointer to card moved, slot and line chosen);
/// - `ATTIC_DRAG_FRAME <uptime> <pointer y> <card top y> <line y>` once per
///   display frame, in window points (y up), with the card where it is on
///   screen (its presentation layer), so the pointer-to-card distance can
///   be followed frame by frame;
/// - `ATTIC_DRAG_BEGIN` / `ATTIC_DRAG_END <how>`.
/// Nothing runs without the variable.
@MainActor
final class NoteDragProbe: NSObject {
    static let isEnabled = ProcessInfo.processInfo.environment["ATTIC_FRAME_MONITOR"] == "1"

    /// The card's top edge on screen and the drop line's middle, in window
    /// coordinates (nil when not shown).
    private let sample: () -> (card: CGFloat?, line: CGFloat?)
    private weak var window: NSWindow?
    private var link: CADisplayLink?

    private init(window: NSWindow, sample: @escaping () -> (card: CGFloat?, line: CGFloat?)) {
        self.window = window
        self.sample = sample
    }

    static func begin(in view: NSView, sample: @escaping () -> (card: CGFloat?, line: CGFloat?)) -> NoteDragProbe? {
        guard isEnabled, let window = view.window else { return nil }
        setvbuf(stdout, nil, _IOLBF, 0)
        let probe = NoteDragProbe(window: window, sample: sample)
        let link = view.displayLink(target: probe, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        probe.link = link
        print(String(format: "ATTIC_DRAG_BEGIN %.4f", CACurrentMediaTime()))
        return probe
    }

    /// One drag event handled, from `start` until now.
    func eventHandled(since start: CFTimeInterval) {
        print(String(format: "ATTIC_DRAG_EVENT %.4f %.3f", start, (CACurrentMediaTime() - start) * 1_000))
    }

    func end(_ how: String) {
        link?.invalidate()
        link = nil
        print(String(format: "ATTIC_DRAG_END %.4f %@", CACurrentMediaTime(), how))
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let window else { return }
        let pointer = window.mouseLocationOutsideOfEventStream.y
        let (card, line) = sample()
        print(String(format: "ATTIC_DRAG_FRAME %.4f %.1f %.1f %.1f", link.timestamp, pointer, card ?? -1, line ?? -1))
    }

    /// The top edge of `view` in window coordinates, where its layer is on
    /// screen now (mid-animation included).
    static func screenTop(of view: NSView) -> CGFloat? {
        guard let superview = view.superview, view.window != nil, !view.isHidden else { return nil }
        var frame = view.frame
        if let layer = view.layer, let shown = layer.presentation() {
            // The layer's y runs the same way as the view's, or the other way.
            let sameWay = abs(layer.frame.minY - view.frame.minY) < 0.5
            let moved = shown.frame.minY - layer.frame.minY
            frame.origin.y += sameWay ? moved : -moved
        }
        return superview.convert(frame, to: nil).maxY
    }
}
#endif
