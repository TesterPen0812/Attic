import AppKit
import SwiftUI

/// A key-capable auxiliary surface. Lifetime and content belong to its
/// owner; every scroll event reaches the content untouched.
///
/// Like `AtticPanel`, the native window is larger than the visible squircle:
/// `surfaceMargin` of transparent, click-through room on every side lets the
/// surface's exterior shadow fade out instead of being cut at the window
/// edge. Owners describe the window by its *visible* frame
/// (`visibleContentFrame`, `setVisibleContentFrame`), never the native one,
/// so placement, animation and saved positions are unchanged by the margin.
final class PanelSurfaceWindow: NSPanel {
    var onEscape: (() -> Void)?
    /// Test seam: receives the events the window would hand to AppKit.
    var eventForwardingForTesting: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Transparent room for the surface's exterior shadow, never a grip.
    private(set) var surfaceMargin: CGFloat = 0
    /// The content the owner supplied: the painted squircle's host.
    private(set) weak var surfaceContentView: NSView?

    var visibleContentFrame: CGRect {
        frame.insetBy(dx: surfaceMargin, dy: surfaceMargin)
    }

    func nativeFrame(forVisibleFrame frame: CGRect) -> CGRect {
        frame.insetBy(dx: -surfaceMargin, dy: -surfaceMargin)
    }

    func setVisibleContentFrame(_ frame: CGRect, display: Bool) {
        setFrame(nativeFrame(forVisibleFrame: frame), display: display)
    }

    /// Assistive technology and UI tests see the surface, not its margin.
    override func accessibilityFrame() -> NSRect {
        visibleContentFrame
    }

    /// Whether a screen point lies on the painted squircle. Everything else
    /// inside the native frame (the margin and the corner wedges) is
    /// click-through; the owner keeps `ignoresMouseEvents` in step with the
    /// pointer through `PanelSurfacePointerPolicy`.
    func surfaceContains(screenPoint point: CGPoint, cornerSize: CGFloat) -> Bool {
        PanelSurfacePointerPolicy.surfaceContains(
            point, visibleFrame: visibleContentFrame, cornerSize: cornerSize
        )
    }

    convenience init(contentView: NSView, initialSize: CGSize,
                     surfaceMargin: CGFloat = AtticStyle.panelElevationMargin) {
        let margin = max(0, surfaceMargin)
        self.init(contentRect: CGRect(origin: .zero, size: CGSize(
                      width: initialSize.width + margin * 2,
                      height: initialSize.height + margin * 2
                  )),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.surfaceMargin = margin
        animationBehavior = .none
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        AtticPanelInteractionPolicy.configure(self)
        surfaceContentView = contentView
        self.contentView = PanelSurfaceContentContainer(
            surfaceView: contentView, visibleSize: initialSize, margin: margin
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !(firstResponder is NSTextView) {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if let eventForwardingForTesting {
            eventForwardingForTesting(event)
        } else {
            super.sendEvent(event)
        }
    }
}

/// Insets the surface host by the window's margin, the way
/// `AtticPanelContentContainer` does for the main panel, and hands hit tests
/// straight to the host: the host answers `nil` outside its squircle, so
/// neither the margin nor the corner wedges ever own a press.
final class PanelSurfaceContentContainer: NSView {
    let surfaceView: NSView

    init(surfaceView: NSView, visibleSize: CGSize, margin: CGFloat) {
        self.surfaceView = surfaceView
        super.init(frame: CGRect(origin: .zero, size: CGSize(
            width: visibleSize.width + margin * 2,
            height: visibleSize.height + margin * 2
        )))
        surfaceView.frame = bounds.insetBy(dx: margin, dy: margin)
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard surfaceView.frame.contains(local) else { return nil }
        return surfaceView.hitTest(local)
    }
}

/// Pointer pass-through for the auxiliary surfaces, mirroring the main
/// panel's `updateMousePassthrough`: a borderless window swallows clicks on
/// its transparent pixels, so while the pointer is inside the native frame
/// but off the painted squircle the window must ignore mouse events. Pure
/// geometry, so the rule is unit-testable without a window.
enum PanelSurfacePointerPolicy {
    static func surfaceContains(_ point: CGPoint, visibleFrame: CGRect, cornerSize: CGFloat) -> Bool {
        SubtaskPanelLayout.surfaceContains(
            CGPoint(x: point.x - visibleFrame.minX, y: point.y - visibleFrame.minY),
            in: CGRect(origin: .zero, size: visibleFrame.size),
            cornerSize: cornerSize
        )
    }

    /// True when the window should ignore mouse events for this pointer.
    static func shouldIgnoreMouseEvents(
        at point: CGPoint, nativeFrame: CGRect, visibleFrame: CGRect, cornerSize: CGFloat
    ) -> Bool {
        nativeFrame.contains(point)
            && !surfaceContains(point, visibleFrame: visibleFrame, cornerSize: cornerSize)
    }
}

/// Owns every press inside the painted surface. Header routing happens before
/// SwiftUI's internal hit-test result, so labels, spacers and glass cannot
/// fragment the drag region. Measured controls retain their own events.
final class PanelSurfaceHostingView<Content: View>: NSHostingView<Content> {
    var surfaceCornerSize: CGFloat = AtticStyle.panelCornerRadius
    var dragGeometry = PanelSurfaceDragGeometry()
    var onBeginWindowDrag: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard Squircle.contains(local, in: bounds, cornerRadius: surfaceCornerSize,
                                exponent: AtticStyle.panelSquircleExponent) else { return nil }
        if dragGeometry.allowsWindowDrag(at: contentPoint(local), in: bounds) {
            return self
        }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let window, dragGeometry.allowsWindowDrag(at: contentPoint(local), in: bounds) {
            onBeginWindowDrag?()
            window.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    private func contentPoint(_ point: CGPoint) -> CGPoint {
        isFlipped ? point : CGPoint(x: point.x, y: bounds.maxY - point.y)
    }
}

/// Where a surface may be dragged from. The header is the drag
/// handle, but its position moves with the corner-aware padding and its
/// controls must keep their own presses — so the region is measured from the
/// live layout instead of assuming a fixed strip.
///
/// All rects are in the surface content's own top-left origin space, which is
/// the flipped hosting view's coordinate space.
struct PanelSurfaceDragGeometry: Equatable, Sendable {
    var headerFrame: CGRect = .null
    var controlFrames: [CGRect] = []

    func allowsWindowDrag(at point: CGPoint, in bounds: CGRect) -> Bool {
        // Until controls have been measured, leave the event with content.
        guard bounds.contains(point), !headerFrame.isNull,
              headerFrame.contains(point) else { return false }
        // Pin/unpin/close keep their own presses: a drag that starts on a
        // control is that control's press, never a window move.
        return !controlFrames.contains { $0.contains(point) }
    }

    func merging(_ other: PanelSurfaceDragGeometry) -> PanelSurfaceDragGeometry {
        PanelSurfaceDragGeometry(
            headerFrame: other.headerFrame.isNull ? headerFrame : other.headerFrame,
            controlFrames: controlFrames + other.controlFrames
        )
    }
}

/// Published by the surface content so the hosting view can own header drags
/// without hard-coding where the header ends.
struct PanelSurfaceDragGeometryPreferenceKey: PreferenceKey {
    static let defaultValue = PanelSurfaceDragGeometry()

    static func reduce(value: inout PanelSurfaceDragGeometry, nextValue: () -> PanelSurfaceDragGeometry) {
        value = value.merging(nextValue())
    }
}

