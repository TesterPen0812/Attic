import AppKit
import SwiftUI

final class AtticPanel: NSPanel {
    var onAccessibilityResizeRequest: ((CGSize) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func accessibilityIsAttributeSettable(
        _ attribute: NSAccessibility.Attribute
    ) -> Bool {
        if attribute == .size, onAccessibilityResizeRequest != nil { return true }
        return super.accessibilityIsAttributeSettable(attribute)
    }

    override func setAccessibilityFrame(_ accessibilityFrame: NSRect) {
        guard accessibilityFrame.size != frame.size else {
            // Preserve AppKit's standard accessible movement when this is an
            // origin-only request. Dock anchoring applies only to size changes.
            super.setAccessibilityFrame(accessibilityFrame)
            return
        }
        guard let onAccessibilityResizeRequest else {
            super.setAccessibilityFrame(accessibilityFrame)
            return
        }
        // AX clients commonly send an origin together with the new size. The
        // selected dock corner, not that untrusted origin, owns panel position.
        onAccessibilityResizeRequest(accessibilityFrame.size)
    }
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
    /// The transparent corner remains click-through except for a thin band
    /// immediately outside the visible superellipse. Expressing that band as
    /// a power-sum limit keeps it proportional as the corner radius changes
    /// and, unlike a rectangular halo, never claims the far corner pixel.
    static let cornerAcquisitionPowerLimit: CGFloat = 1.35

    @MainActor
    static func configure(
        _ panel: NSPanel,
        maximumSize: CGSize? = nil
    ) {
        // A borderless NSPanel still exposes a window-server resize border
        // when `.resizable` is present. That path wins before the hosting view
        // sees the mouse event and, for this SwiftUI-hosted panel, has proven
        // capable of ignoring AppKit's min/max properties and delegate clamp.
        // Keep one resize authority: the generous custom grips below.
        panel.styleMask.remove(.resizable)
        let minimumSize = PanelGeometry.minimumPanelSize

        // Retain explicit limits for accessibility and programmatic callers.
        // Custom live resizing clamps independently before setting the frame.
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
        cornerRadius: CGFloat,
        dockedAt corner: ScreenCorner? = nil
    ) -> PanelResizeEdges? {
        // NSView's local bounds are half-open, but an event on the visual
        // right/top border can arrive exactly at maxX/maxY. Pull only those
        // boundary coordinates one representable point inward so the visible
        // edge belongs to the resize grip without expanding the window's hit
        // region or claiming a transparent corner outside the squircle.
        guard bounds.width > 0,
              bounds.height > 0,
              point.x >= bounds.minX,
              point.x <= bounds.maxX,
              point.y >= bounds.minY,
              point.y <= bounds.maxY else { return nil }
        let point = CGPoint(
            x: min(point.x, bounds.maxX.nextDown),
            y: min(point.y, bounds.maxY.nextDown)
        )
        let isInsideSquircle = Squircle.contains(
            point,
            in: bounds,
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        )
        if !isInsideSquircle {
            return allowedResizeEdges(
                cornerAcquisitionEdges(
                    at: point,
                    in: bounds,
                    cornerRadius: cornerRadius
                ),
                dockedAt: corner
            )
        }

        let nearLeftCorner = point.x - bounds.minX <= cornerGripThickness
        let nearRightCorner = bounds.maxX - point.x <= cornerGripThickness
        let nearBottomCorner = point.y - bounds.minY <= cornerGripThickness
        let nearTopCorner = bounds.maxY - point.y <= cornerGripThickness

        let candidate: PanelResizeEdges?
        if nearLeftCorner && nearBottomCorner { candidate = [.left, .bottom] }
        else if nearLeftCorner && nearTopCorner { candidate = [.left, .top] }
        else if nearRightCorner && nearBottomCorner { candidate = [.right, .bottom] }
        else if nearRightCorner && nearTopCorner { candidate = [.right, .top] }
        else if point.x - bounds.minX <= edgeGripThickness { candidate = .left }
        else if bounds.maxX - point.x <= edgeGripThickness { candidate = .right }
        else if point.y - bounds.minY <= edgeGripThickness { candidate = .bottom }
        else if bounds.maxY - point.y <= edgeGripThickness { candidate = .top }
        else { candidate = nil }
        return allowedResizeEdges(candidate, dockedAt: corner)
    }

    static func allowedResizeEdges(
        _ candidate: PanelResizeEdges?,
        dockedAt corner: ScreenCorner?
    ) -> PanelResizeEdges? {
        guard let candidate, let corner else { return candidate }
        let lockedEdges: PanelResizeEdges
        switch corner {
        case .topLeft: lockedEdges = [.top, .left]
        case .topRight: lockedEdges = [.top, .right]
        case .bottomLeft: lockedEdges = [.bottom, .left]
        case .bottomRight: lockedEdges = [.bottom, .right]
        }
        return candidate.isDisjoint(with: lockedEdges) ? candidate : nil
    }

    static func cornerAcquisitionEdges(
        at point: CGPoint,
        in bounds: CGRect,
        cornerRadius: CGFloat
    ) -> PanelResizeEdges? {
        guard bounds.contains(point), !Squircle.contains(
            point,
            in: bounds,
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        ) else { return nil }

        let nearLeft = point.x - bounds.minX <= cornerGripThickness
        let nearRight = bounds.maxX - point.x <= cornerGripThickness
        let nearBottom = point.y - bounds.minY <= cornerGripThickness
        let nearTop = bounds.maxY - point.y <= cornerGripThickness
        guard (nearLeft || nearRight), (nearBottom || nearTop) else { return nil }

        let radius = min(cornerRadius, bounds.width / 2, bounds.height / 2)
        guard radius > 0 else { return nil }
        let centerX = nearLeft ? bounds.minX + radius : bounds.maxX - radius
        let centerY = nearBottom ? bounds.minY + radius : bounds.maxY - radius
        let normalizedX = abs(point.x - centerX) / radius
        let normalizedY = abs(point.y - centerY) / radius
        let exponent = max(1, AtticStyle.panelSquircleExponent)
        let powerSum = pow(normalizedX, exponent) + pow(normalizedY, exponent)
        guard powerSum <= cornerAcquisitionPowerLimit else { return nil }

        switch (nearLeft, nearBottom) {
        case (true, true): return [.left, .bottom]
        case (true, false): return [.left, .top]
        case (false, true): return [.right, .bottom]
        case (false, false): return [.right, .top]
        }
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
        let bottom = bounds.maxY - insets.top - AtticStyle.controlHitSize
        let top = bounds.maxY - AtticPanelResizePolicy.edgeGripThickness
        return CGRect(
            x: leading,
            y: bottom,
            width: max(0, trailing - leading),
            height: max(0, top - bottom)
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
    var dockedCorner: ScreenCorner {
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

    init(rootView: AtticPanelView, panelCornerRadius: CGFloat, dockedCorner: ScreenCorner) {
        self.panelCornerRadius = panelCornerRadius
        self.dockedCorner = dockedCorner
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: AtticPanelView) {
        fatalError("Use init(rootView:panelCornerRadius:dockedCorner:)")
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
        let isInsideSquircle = Squircle.contains(
            policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        )
        let resizeEdges = AtticPanelResizePolicy.resizeEdges(
            at: policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius,
            dockedAt: dockedCorner
        )
        guard isInsideSquircle || resizeEdges != nil else { return nil }
        if resizeEdges != nil {
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
                cornerRadius: panelCornerRadius,
                dockedAt: dockedCorner
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
            let visibleFrame = window.screen?.visibleFrame
            let maximumSize = visibleFrame.map(PanelGeometry.resizeMaximumSize)
                ?? window.contentMaxSize
            let frame = AtticPanelResizePolicy.resizedFrame(
                from: session.initialFrame,
                mouseDelta: delta,
                edges: session.edges,
                minimumSize: PanelGeometry.minimumPanelSize,
                maximumSize: maximumSize,
                visibleFrame: visibleFrame
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

        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX, y: bounds.minY, width: corner, height: corner)
            ),
            edges: [.left, .bottom]
        )
        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.maxX - corner, y: bounds.minY, width: corner, height: corner)
            ),
            edges: [.right, .bottom]
        )
        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX, y: bounds.maxY - corner, width: corner, height: corner)
            ),
            edges: [.left, .top]
        )
        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.maxX - corner, y: bounds.maxY - corner, width: corner, height: corner)
            ),
            edges: [.right, .top]
        )
        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX, y: bounds.minY + corner, width: edge, height: middleHeight)
            ),
            edges: .left
        )
        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.maxX - edge, y: bounds.minY + corner, width: edge, height: middleHeight)
            ),
            edges: .right
        )
        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX + corner, y: bounds.minY, width: middleWidth, height: edge)
            ),
            edges: .bottom
        )
        addResizeCursorRect(
            localCursorRect(
                CGRect(x: bounds.minX + corner, y: bounds.maxY - edge, width: middleWidth, height: edge)
            ),
            edges: .top
        )
    }

    private func addResizeCursorRect(_ rect: CGRect, edges: PanelResizeEdges) {
        guard AtticPanelResizePolicy.allowedResizeEdges(edges, dockedAt: dockedCorner) != nil else {
            return
        }
        addCursorRect(rect, cursor: resizeCursor(for: edges))
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

    func displayResizeCursor(for edges: PanelResizeEdges) {
        resizeCursor(for: edges).set()
    }
}
