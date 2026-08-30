import AppKit
import SwiftUI

final class AtticPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PanelResizeEdges: OptionSet, Equatable {
    let rawValue: Int

    static let left = PanelResizeEdges(rawValue: 1 << 0)
    static let right = PanelResizeEdges(rawValue: 1 << 1)
    static let bottom = PanelResizeEdges(rawValue: 1 << 2)
    static let top = PanelResizeEdges(rawValue: 1 << 3)
}

enum AtticPanelCoordinateSpace {
    /// Resize and docking policy uses AppKit screen-style coordinates where
    /// y increases upward. NSHostingView is flipped, so convert exactly once
    /// at the hosting boundary before classifying an interaction.
    static func policyPoint(
        fromHostingPoint point: CGPoint,
        in bounds: CGRect,
        isFlipped: Bool
    ) -> CGPoint {
        guard isFlipped else { return point }
        return CGPoint(
            x: point.x,
            y: bounds.minY + bounds.maxY - point.y
        )
    }

    /// Cursor rectangles are defined in policy coordinates and registered in
    /// the hosting view's local coordinate space.
    static func hostingRect(
        fromPolicyRect rect: CGRect,
        in bounds: CGRect,
        isFlipped: Bool
    ) -> CGRect {
        guard isFlipped else { return rect }
        return CGRect(
            x: rect.minX,
            y: bounds.minY + bounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

enum AtticPanelInteractionPolicy {
    @MainActor
    static func configure(_ panel: NSPanel) {
        // The panel remains non-activating, but its first eligible click must
        // make it key so controls and glass do not need a second click.
        panel.becomesKeyOnlyIfNeeded = false
    }
}

enum AtticPanelResizePolicy {
    static let edgeGripThickness: CGFloat = 14
    static let cornerGripThickness: CGFloat = 28

    @MainActor
    static func configure(
        _ panel: NSPanel,
        maximumSize: CGSize? = nil
    ) {
        panel.styleMask.insert(.resizable)
        let minimumSize = PanelGeometry.minimumPanelSize

        // AppKit owns a thin native resize border outside the hosting view's
        // generous custom grips. A borderless panel therefore needs limits
        // on both its frame and content sizes: content-only limits do not
        // constrain a drag that begins in that native border.
        panel.minSize = minimumSize
        panel.contentMinSize = minimumSize
        if let maximumSize {
            panel.maxSize = maximumSize
            panel.contentMaxSize = maximumSize
        }
        panel.preservesContentDuringLiveResize = true
    }

    static func resizeEdges(
        at point: CGPoint,
        in bounds: CGRect,
        cornerRadius: CGFloat
    ) -> PanelResizeEdges? {
        guard Squircle.contains(
            point,
            in: bounds,
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        ) else { return nil }

        let nearLeftCorner = point.x - bounds.minX <= cornerGripThickness
        let nearRightCorner = bounds.maxX - point.x <= cornerGripThickness
        let nearBottomCorner = point.y - bounds.minY <= cornerGripThickness
        let nearTopCorner = bounds.maxY - point.y <= cornerGripThickness

        if nearLeftCorner && nearBottomCorner { return [.left, .bottom] }
        if nearLeftCorner && nearTopCorner { return [.left, .top] }
        if nearRightCorner && nearBottomCorner { return [.right, .bottom] }
        if nearRightCorner && nearTopCorner { return [.right, .top] }

        if point.x - bounds.minX <= edgeGripThickness { return .left }
        if bounds.maxX - point.x <= edgeGripThickness { return .right }
        if point.y - bounds.minY <= edgeGripThickness { return .bottom }
        if bounds.maxY - point.y <= edgeGripThickness { return .top }
        return nil
    }

    static func resizedFrame(
        from initialFrame: CGRect,
        mouseDelta: CGPoint,
        edges: PanelResizeEdges,
        minimumSize: CGSize,
        maximumSize: CGSize,
        visibleFrame: CGRect? = nil,
        screenInset: CGFloat = PanelGeometry.screenInset
    ) -> CGRect {
        var width = initialFrame.width
        var height = initialFrame.height

        if edges.contains(.left) { width -= mouseDelta.x }
        if edges.contains(.right) { width += mouseDelta.x }
        if edges.contains(.bottom) { height -= mouseDelta.y }
        if edges.contains(.top) { height += mouseDelta.y }

        var availableWidth = maximumSize.width
        var availableHeight = maximumSize.height
        if let visibleFrame {
            let safeFrame = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
            if edges.contains(.left) {
                availableWidth = min(availableWidth, initialFrame.maxX - safeFrame.minX)
            } else if edges.contains(.right) {
                availableWidth = min(availableWidth, safeFrame.maxX - initialFrame.minX)
            }
            if edges.contains(.bottom) {
                availableHeight = min(availableHeight, initialFrame.maxY - safeFrame.minY)
            } else if edges.contains(.top) {
                availableHeight = min(availableHeight, safeFrame.maxY - initialFrame.minY)
            }
        }

        width = min(max(width, minimumSize.width), max(minimumSize.width, availableWidth))
        height = min(max(height, minimumSize.height), max(minimumSize.height, availableHeight))

        var origin = initialFrame.origin
        if edges.contains(.left) { origin.x = initialFrame.maxX - width }
        if edges.contains(.bottom) { origin.y = initialFrame.maxY - height }
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}

enum AtticPanelDragPolicy {
    static let controlClearance: CGFloat = 10
    static let maximumFlickReleaseDelay: TimeInterval = 0.14

    static func topDragRegion(in bounds: CGRect, cornerRadius: CGFloat) -> CGRect {
        let insets = PanelGeometry.chromeInsets(
            cornerSize: cornerRadius,
            panelSize: bounds.size
        )
        let leading = bounds.minX
            + insets.leading
            + AtticStyle.controlHitSize
            + controlClearance
        let trailing = bounds.maxX
            - insets.trailing
            - (AtticStyle.controlHitSize * CGFloat(PanelSection.allCases.count))
            - controlClearance
        return CGRect(
            x: leading,
            y: bounds.maxY - insets.top - AtticStyle.controlHitSize,
            width: max(0, trailing - leading),
            height: AtticStyle.controlHitSize
        )
    }

    static func isTopDragPoint(
        _ point: CGPoint,
        in bounds: CGRect,
        cornerRadius: CGFloat
    ) -> Bool {
        guard Squircle.contains(
            point,
            in: bounds,
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        ), AtticPanelResizePolicy.resizeEdges(
            at: point,
            in: bounds,
            cornerRadius: cornerRadius
        ) == nil else { return false }

        return topDragRegion(in: bounds, cornerRadius: cornerRadius).contains(point)
    }
}

/// The window server still treats a transparent borderless panel as a
/// rectangle. Keep AppKit's responder hit test aligned with the visible
/// squircle so transparent corner pixels cannot obstruct the app behind it.
final class AtticPanelHostingView: NSHostingView<AtticPanelView> {
    private struct ResizeSession {
        let edges: PanelResizeEdges
        let initialFrame: CGRect
        let initialMouseLocation: CGPoint
    }

    private struct MoveSession {
        let initialFrame: CGRect
        let initialMouseLocation: CGPoint
        var lastMouseLocation: CGPoint
        var lastTimestamp: TimeInterval
        var velocity: CGPoint = .zero
    }

    var panelCornerRadius: CGFloat {
        didSet {
            if let window { window.invalidateCursorRects(for: self) }
        }
    }
    var onLiveResizeBegan: (() -> Void)?
    var onLiveResizeChanged: ((CGSize) -> Void)?
    var onLiveResizeEnded: ((CGSize) -> Void)?
    var onWindowDragBegan: (() -> Void)?
    var onWindowDragChanged: ((CGRect, CGPoint) -> Void)?
    var onWindowDragEnded: ((CGRect, CGPoint, CGPoint, CGPoint) -> Void)?
    private var resizeSession: ResizeSession?
    private var moveSession: MoveSession?

    init(rootView: AtticPanelView, panelCornerRadius: CGFloat) {
        self.panelCornerRadius = panelCornerRadius
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: AtticPanelView) {
        fatalError("Use init(rootView:panelCornerRadius:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let policyPoint = AtticPanelCoordinateSpace.policyPoint(
            fromHostingPoint: point,
            in: bounds,
            isFlipped: isFlipped
        )
        guard Squircle.contains(
            policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        ) else {
            return nil
        }
        if AtticPanelResizePolicy.resizeEdges(
            at: policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius
        ) != nil {
            return self
        }
        if AtticPanelDragPolicy.isTopDragPoint(
            policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius
        ) {
            return self
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let hostingPoint = convert(event.locationInWindow, from: nil)
        let policyPoint = AtticPanelCoordinateSpace.policyPoint(
            fromHostingPoint: hostingPoint,
            in: bounds,
            isFlipped: isFlipped
        )
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        if let edges = AtticPanelResizePolicy.resizeEdges(
                at: policyPoint,
                in: bounds,
                cornerRadius: panelCornerRadius
              ) {
            resizeSession = ResizeSession(
                edges: edges,
                initialFrame: window.frame,
                initialMouseLocation: NSEvent.mouseLocation
            )
            window.makeKey()
            onLiveResizeBegan?()
            return
        }
        guard AtticPanelDragPolicy.isTopDragPoint(
            policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius
        ) else {
            super.mouseDown(with: event)
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        moveSession = MoveSession(
            initialFrame: window.frame,
            initialMouseLocation: mouseLocation,
            lastMouseLocation: mouseLocation,
            lastTimestamp: event.timestamp
        )
        window.makeKey()
        NSCursor.closedHand.set()
        onWindowDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else {
            super.mouseDragged(with: event)
            return
        }
        if let session = resizeSession {
            let mouseLocation = NSEvent.mouseLocation
            let delta = CGPoint(
                x: mouseLocation.x - session.initialMouseLocation.x,
                y: mouseLocation.y - session.initialMouseLocation.y
            )
            let frame = AtticPanelResizePolicy.resizedFrame(
                from: session.initialFrame,
                mouseDelta: delta,
                edges: session.edges,
                minimumSize: window.contentMinSize,
                maximumSize: window.contentMaxSize,
                visibleFrame: window.screen?.visibleFrame
            )
            window.setFrame(frame, display: true)
            onLiveResizeChanged?(frame.size)
            return
        }
        guard var session = moveSession else {
            super.mouseDragged(with: event)
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let delta = CGPoint(
            x: mouseLocation.x - session.initialMouseLocation.x,
            y: mouseLocation.y - session.initialMouseLocation.y
        )
        let elapsed = event.timestamp - session.lastTimestamp
        if elapsed > 0 {
            session.velocity = CGPoint(
                x: (mouseLocation.x - session.lastMouseLocation.x) / elapsed,
                y: (mouseLocation.y - session.lastMouseLocation.y) / elapsed
            )
        }
        session.lastMouseLocation = mouseLocation
        session.lastTimestamp = event.timestamp
        moveSession = session

        var frame = session.initialFrame
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        window.setFrame(frame, display: true)
        onWindowDragChanged?(frame, mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else {
            super.mouseUp(with: event)
            return
        }
        if resizeSession != nil {
            resizeSession = nil
            onLiveResizeEnded?(window.frame.size)
            return
        }
        guard let session = moveSession else {
            super.mouseUp(with: event)
            return
        }
        moveSession = nil
        let mouseLocation = NSEvent.mouseLocation
        let translation = CGPoint(
            x: mouseLocation.x - session.initialMouseLocation.x,
            y: mouseLocation.y - session.initialMouseLocation.y
        )
        let releaseVelocity = event.timestamp - session.lastTimestamp <= AtticPanelDragPolicy.maximumFlickReleaseDelay
            ? session.velocity
            : .zero
        window.invalidateCursorRects(for: self)
        onWindowDragEnded?(window.frame, mouseLocation, releaseVelocity, translation)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let edge = AtticPanelResizePolicy.edgeGripThickness
        let corner = AtticPanelResizePolicy.cornerGripThickness
        let middleWidth = max(0, bounds.width - (corner * 2))
        let middleHeight = max(0, bounds.height - (corner * 2))

        addCursorRect(
            AtticPanelCoordinateSpace.hostingRect(
                fromPolicyRect: AtticPanelDragPolicy.topDragRegion(
                    in: bounds,
                    cornerRadius: panelCornerRadius
                ),
                in: bounds,
                isFlipped: isFlipped
            ),
            cursor: .openHand
        )

        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX, y: bounds.minY, width: corner, height: corner)
            ),
            cursor: resizeCursor(for: [.left, .bottom])
        )
        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.maxX - corner, y: bounds.minY, width: corner, height: corner)
            ),
            cursor: resizeCursor(for: [.right, .bottom])
        )
        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX, y: bounds.maxY - corner, width: corner, height: corner)
            ),
            cursor: resizeCursor(for: [.left, .top])
        )
        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.maxX - corner, y: bounds.maxY - corner, width: corner, height: corner)
            ),
            cursor: resizeCursor(for: [.right, .top])
        )
        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX, y: bounds.minY + corner, width: edge, height: middleHeight)
            ),
            cursor: resizeCursor(for: .left)
        )
        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.maxX - edge, y: bounds.minY + corner, width: edge, height: middleHeight)
            ),
            cursor: resizeCursor(for: .right)
        )
        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX + corner, y: bounds.minY, width: middleWidth, height: edge)
            ),
            cursor: resizeCursor(for: .bottom)
        )
        addCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX + corner, y: bounds.maxY - edge, width: middleWidth, height: edge)
            ),
            cursor: resizeCursor(for: .top)
        )
    }

    private func localCursorRect(_ policyRect: CGRect) -> CGRect {
        AtticPanelCoordinateSpace.hostingRect(
            fromPolicyRect: policyRect,
            in: bounds,
            isFlipped: isFlipped
        )
    }

    private func resizeCursor(for edges: PanelResizeEdges) -> NSCursor {
        guard #available(macOS 15.0, *) else {
            if edges == .left || edges == .right { return .resizeLeftRight }
            if edges == .top || edges == .bottom { return .resizeUpDown }
            return .crosshair
        }

        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.left, .bottom]: position = .bottomLeft
        case [.right, .bottom]: position = .bottomRight
        case [.left, .top]: position = .topLeft
        case [.right, .top]: position = .topRight
        case .left: position = .left
        case .right: position = .right
        case .bottom: position = .bottom
        default: position = .top
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }
}
