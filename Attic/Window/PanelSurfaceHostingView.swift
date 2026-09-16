import AppKit
import SwiftUI

/// A key-capable auxiliary surface. Lifetime and content belong to its
/// owner; every scroll event reaches the content untouched.
final class PanelSurfaceWindow: NSPanel {
    var onEscape: (() -> Void)?
    /// Test seam: receives the events the window would hand to AppKit.
    var eventForwardingForTesting: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(contentView: NSView, initialSize: CGSize) {
        self.init(contentRect: CGRect(origin: .zero, size: initialSize),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
        self.contentView = contentView
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

