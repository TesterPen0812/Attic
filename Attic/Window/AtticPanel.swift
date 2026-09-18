import AppKit
import QuartzCore
import SwiftUI

@MainActor
protocol PanelNotesSwipeTarget: AnyObject {
    var swipeView: NSView { get }
    var isNotesLibraryPresented: Bool { get }
    func performNotesSwipe()
}

final class AtticPanel: NSPanel {
    var onAccessibilityResizeRequest: ((CGSize) -> Void)?
    var onAccessibilityMoveRequest: ((CGRect) -> Void)?
    var onTrackpadDismissRequest: (() -> Void)?
    var onTrackpadDismissProgress: ((CGFloat) -> Void)?
    var onTrackpadDismissCancelled: (() -> Void)?
    var onDirectContentInteraction: (() -> Void)?
    var trackpadDismissCorner: ScreenCorner = .topRight {
        didSet {
            if trackpadDismissCorner != oldValue { cancelTrackpadSwipe() }
        }
    }
    weak var notesSwipeTarget: (any PanelNotesSwipeTarget)? {
        didSet {
            if notesSwipeTarget !== oldValue { cancelTrackpadSwipe() }
        }
    }
    var canBeginTrackpadSwipe: ((NSEvent) -> Bool)?
    private var trackpadDismissTracker = PanelTrackpadDismissTracker()
    private enum SwipeRoute { case hide, notes, content }
    private var swipeRoute: SwipeRoute?
    private var swipeSequenceActive = false
    private var swipeIntent = PanelTrackpadSwipeIntent()
    private var hasInteractiveDismissal = false
    private var swipeStartedInNotes = false
    private var swipeStartedInLibrary = false
    private weak var swipeNotesTarget: (any PanelNotesSwipeTarget)?

    /// The invisible acquisition perimeter is part of the native window only.
    /// Content geometry and saved sizes always describe the visible surface.
    var resizePerimeter: CGFloat = 0
    var visibleContentFrame: CGRect {
        frame.insetBy(dx: resizePerimeter, dy: resizePerimeter)
    }

    func nativeFrame(forVisibleFrame frame: CGRect) -> CGRect {
        frame.insetBy(dx: -resizePerimeter, dy: -resizePerimeter)
    }

    func setVisibleContentFrame(_ frame: CGRect, display: Bool) {
        setFrame(nativeFrame(forVisibleFrame: frame), display: display)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        cancelTrackpadSwipe()
        super.resignKey()
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel else {
            if [.magnify, .beginGesture, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged].contains(event.type) {
                cancelTrackpadSwipe()
                // Finish a returning presentation before AppKit hit-testing
                // this new interaction at the untransformed content bounds.
                onDirectContentInteraction?()
            }
            super.sendEvent(event)
            return
        }
        guard (event.momentumPhase.isEmpty || event.phase.contains(.ended)),
              event.modifierFlags.intersection([
                .command,
                .control,
                .option,
                .shift
              ]).isEmpty else {
            cancelTrackpadSwipe()
            super.sendEvent(event)
            return
        }

        let phase = trackpadSwipePhase(for: event.phase)
        guard event.hasPreciseScrollingDeltas, phase != .none else {
            cancelTrackpadSwipe()
            super.sendEvent(event)
            return
        }
        if phase == .began {
            cancelTrackpadSwipe()
            swipeSequenceActive = event.hasPreciseScrollingDeltas
                && NSEvent.pressedMouseButtons == 0
                && (canBeginTrackpadSwipe?(event) ?? true)
                && !contentOwnsHorizontalScrolling(at: event.locationInWindow)
            swipeRoute = swipeSequenceActive ? nil : .content
            if let target = notesSwipeTarget {
                let point = target.swipeView.convert(event.locationInWindow, from: nil)
                swipeStartedInNotes = target.swipeView.window === self
                    && target.swipeView.bounds.contains(point)
                swipeStartedInLibrary = target.isNotesLibraryPresented
                swipeNotesTarget = swipeStartedInNotes ? target : nil
            }
        }
        guard swipeSequenceActive else {
            super.sendEvent(event)
            return
        }
        // Imports, modal presentation, or other interaction locks may start
        // after the initial sample. They must invalidate this sequence too.
        if NSEvent.pressedMouseButtons != 0 || !(canBeginTrackpadSwipe?(event) ?? true) {
            cancelTrackpadSwipe()
            super.sendEvent(event)
            return
        }
        if swipeStartedInNotes {
            guard let target = swipeNotesTarget,
                  target === notesSwipeTarget,
                  target.swipeView.window === self,
                  target.isNotesLibraryPresented == swipeStartedInLibrary else {
                cancelTrackpadSwipe()
                super.sendEvent(event)
                return
            }
        }

        var trackerPhase = phase
        var trackerDelta = CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        if swipeRoute == nil, phase == .began || phase == .changed {
            swipeIntent.accumulate(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        }
        if swipeRoute == nil, swipeIntent.isReady,
           let initialDirection = swipeIntent.initialDirection {
            let towardEdge = PanelTrackpadDismissTracker.isTowardDockedSide(
                deltaX: initialDirection.x,
                deltaY: initialDirection.y,
                isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice,
                dockedCorner: trackpadDismissCorner
            )
            if !swipeIntent.isHorizontal {
                swipeRoute = .content
            } else if swipeStartedInNotes && (towardEdge == swipeStartedInLibrary) {
                swipeRoute = .notes
            } else {
                swipeRoute = towardEdge ? .hide : .content
            }
            // AppKit commonly begins with a zero-delta event. Preserve that
            // sequence boundary when the first directional sample follows it.
            trackerPhase = phase == .changed ? .began : phase
            // The tracker did not receive undecided samples. Seed its first
            // sample with their total so slow movement is never discarded.
            trackerDelta = swipeIntent.displacement
        }
        guard let route = swipeRoute, route != .content else {
            if phase == .ended || phase == .cancelled { cancelTrackpadSwipe() }
            super.sendEvent(event)
            return
        }

        let update = trackpadDismissTracker.update(
            sample: PanelTrackpadSwipeSample(
                deltaX: trackerDelta.x,
                deltaY: trackerDelta.y,
                phase: trackerPhase,
                isPrecise: event.hasPreciseScrollingDeltas,
                isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
            ),
            dockedCorner: trackpadDismissCorner,
            towardDockedSide: route == .hide || swipeStartedInLibrary
        )
        let navigationTarget = swipeNotesTarget
        let beganInLibrary = swipeStartedInLibrary
        if phase == .ended || phase == .cancelled {
            resetTrackpadSwipe(notifyCancellation: update != .requestHide)
        }
        switch update {
        case .passThrough:
            super.sendEvent(event)
        case .tracking:
            if route == .hide, phase != .cancelled {
                hasInteractiveDismissal = true
                onTrackpadDismissProgress?(trackpadDismissTracker.progress)
            }
        case .requestHide:
            if route == .notes {
                guard let navigationTarget,
                      navigationTarget === notesSwipeTarget,
                      navigationTarget.isNotesLibraryPresented == beganInLibrary else { return }
                navigationTarget.performNotesSwipe()
            } else {
                onTrackpadDismissRequest?()
            }
        }
    }

    func cancelTrackpadSwipe() {
        resetTrackpadSwipe(notifyCancellation: true)
    }

    private func resetTrackpadSwipe(notifyCancellation: Bool) {
        let shouldNotify = hasInteractiveDismissal && notifyCancellation
        hasInteractiveDismissal = false
        trackpadDismissTracker.cancel()
        swipeRoute = nil
        swipeSequenceActive = false
        swipeIntent = PanelTrackpadSwipeIntent()
        swipeStartedInNotes = false
        swipeStartedInLibrary = false
        swipeNotesTarget = nil
        if shouldNotify { onTrackpadDismissCancelled?() }
    }

    private func contentOwnsHorizontalScrolling(at windowPoint: CGPoint) -> Bool {
        guard let contentView else { return false }
        var view = contentView.hitTest(contentView.convert(windowPoint, from: nil))
        while let candidate = view {
            if candidate is CanvasNSView || candidate is NSControl { return true }
            if let scroll = candidate as? NSScrollView,
               let document = scroll.documentView,
               document.bounds.width > scroll.contentView.bounds.width + 1 {
                return true
            }
            view = candidate.superview
        }
        return false
    }

    private func trackpadSwipePhase(for phase: NSEvent.Phase) -> PanelTrackpadSwipePhase {
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        return .none
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityFrame(_:)),
           onAccessibilityResizeRequest != nil || onAccessibilityMoveRequest != nil {
            return true
        }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func setAccessibilityFrame(_ accessibilityFrame: NSRect) {
        guard accessibilityFrame.size != visibleContentFrame.size else {
            if let onAccessibilityMoveRequest {
                onAccessibilityMoveRequest(accessibilityFrame)
                return
            }
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

    override func accessibilityFrame() -> NSRect {
        visibleContentFrame
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
    static let outsideGripThickness: CGFloat = 6
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
        let perimeter = (panel as? AtticPanel)?.resizePerimeter ?? 0
        let minimumSize = CGSize(
            width: min(PanelGeometry.minimumPanelSize.width, maximumSize?.width ?? .greatestFiniteMagnitude) + perimeter * 2,
            height: min(PanelGeometry.minimumPanelSize.height, maximumSize?.height ?? .greatestFiniteMagnitude) + perimeter * 2
        )

        // Retain explicit limits for accessibility and programmatic callers.
        // Custom live resizing clamps independently before setting the frame.
        panel.minSize = minimumSize
        panel.contentMinSize = minimumSize
        if let maximumSize {
            let nativeMaximum = CGSize(width: maximumSize.width + perimeter * 2, height: maximumSize.height + perimeter * 2)
            panel.maxSize = nativeMaximum
            panel.contentMaxSize = nativeMaximum
        }
        panel.preservesContentDuringLiveResize = true
    }

    static func resizeEdges(
        at point: CGPoint,
        in bounds: CGRect,
        cornerRadius: CGFloat,
        dockedAt corner: ScreenCorner? = nil,
        acquisitionInset: CGFloat = 0
    ) -> PanelResizeEdges? {
        // NSView's local bounds are half-open, but an event on the visual
        // right/top border can arrive exactly at maxX/maxY. Pull only those
        // boundary coordinates one representable point inward so the visible
        // edge belongs to the resize grip without expanding the window's hit
        // region or claiming a transparent corner outside the squircle.
        guard bounds.width > 0,
              bounds.height > 0,
              point.x >= bounds.minX - acquisitionInset,
              point.x <= bounds.maxX + acquisitionInset,
              point.y >= bounds.minY - acquisitionInset,
              point.y <= bounds.maxY + acquisitionInset else { return nil }
        if !bounds.contains(point) && acquisitionInset > 0 {
            let alongVerticalSide = point.y >= bounds.minY + cornerGripThickness
                && point.y <= bounds.maxY - cornerGripThickness
            let alongHorizontalSide = point.x >= bounds.minX + cornerGripThickness
                && point.x <= bounds.maxX - cornerGripThickness
            let candidate: PanelResizeEdges?
            if point.x < bounds.minX && alongVerticalSide { candidate = .left }
            else if point.x > bounds.maxX && alongVerticalSide { candidate = .right }
            else if point.y < bounds.minY && alongHorizontalSide { candidate = .bottom }
            else if point.y > bounds.maxY && alongHorizontalSide { candidate = .top }
            else { candidate = nil }
            if let candidate {
                var acquisitionPoint = point
                if candidate == .left { acquisitionPoint.x += acquisitionInset }
                if candidate == .right { acquisitionPoint.x -= acquisitionInset }
                if candidate == .bottom { acquisitionPoint.y += acquisitionInset }
                if candidate == .top { acquisitionPoint.y -= acquisitionInset }
                guard Squircle.contains(
                    acquisitionPoint, in: bounds, cornerRadius: cornerRadius,
                    exponent: AtticStyle.panelSquircleExponent
                ) else { return nil }
                return allowedResizeEdges(candidate, dockedAt: corner)
            }
        }
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
        let resizedFrame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        guard let visibleFrame else { return resizedFrame }
        return PanelGeometry.constrainedFrame(
            resizedFrame,
            to: visibleFrame,
            inset: screenInset
        )
    }
}

enum AtticPanelDragPolicy {
    static let controlClearance: CGFloat = 8

    static func topDragRegion(
        in bounds: CGRect,
        cornerRadius: CGFloat,
        modeDockWidth: CGFloat = PanelModeDockLayout.width(isExpanded: true),
        dockedAt corner: ScreenCorner? = nil
    ) -> CGRect {
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
            - max(AtticStyle.controlHitSize, modeDockWidth)
            - controlClearance
        let bottom = bounds.maxY - insets.top - AtticStyle.controlHitSize
        let topEdgeIsLocked = corner.map {
            AtticPanelResizePolicy.allowedResizeEdges(.top, dockedAt: $0) == nil
        } ?? false
        let top = bounds.maxY - (topEdgeIsLocked ? 0 : AtticPanelResizePolicy.edgeGripThickness)
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
        cornerRadius: CGFloat,
        modeDockWidth: CGFloat = PanelModeDockLayout.width(isExpanded: true),
        dockedAt corner: ScreenCorner? = nil
    ) -> Bool {
        guard bounds.width > 0,
              bounds.height > 0,
              point.x >= bounds.minX,
              point.x <= bounds.maxX,
              point.y >= bounds.minY,
              point.y <= bounds.maxY else { return false }
        let point = CGPoint(
            x: min(point.x, bounds.maxX.nextDown),
            y: min(point.y, bounds.maxY.nextDown)
        )
        guard Squircle.contains(
            point,
            in: bounds,
            cornerRadius: cornerRadius,
            exponent: AtticStyle.panelSquircleExponent
        ), AtticPanelResizePolicy.resizeEdges(
            at: point,
            in: bounds,
            cornerRadius: cornerRadius,
            dockedAt: corner
        ) == nil else { return false }

        let region = topDragRegion(
            in: bounds,
            cornerRadius: cornerRadius,
            modeDockWidth: modeDockWidth,
            dockedAt: corner
        )
        let inMiddleLane = point.x >= region.minX
            && point.x < region.maxX
            && point.y >= region.minY
            && point.y <= region.maxY
        return inMiddleLane || upperDragRegion(
            in: bounds,
            cornerRadius: cornerRadius,
            dockedAt: corner
        ).contains(point)
    }

    /// Blank chrome above the controls remains draggable across the panel.
    /// The four-point gap protects the actual control hit rectangles.
    static func upperDragRegion(
        in bounds: CGRect,
        cornerRadius: CGFloat,
        dockedAt corner: ScreenCorner?
    ) -> CGRect {
        let insets = PanelGeometry.chromeInsets(cornerSize: cornerRadius, panelSize: bounds.size)
        let topLocked = corner.map {
            AtticPanelResizePolicy.allowedResizeEdges(.top, dockedAt: $0) == nil
        } ?? false
        let top = bounds.maxY - (topLocked ? 0 : AtticPanelResizePolicy.edgeGripThickness)
        let bottom = bounds.maxY - insets.top + 4
        return CGRect(x: bounds.minX, y: bottom, width: bounds.width, height: max(0, top - bottom))
    }
}

struct PanelDragReleaseIntent: Equatable {
    let velocity: CGPoint
    let translation: CGPoint
}

enum PanelInteraction: Equatable {
    case windowMove
    case windowResize
}

enum PanelInteractionCancellationReason: CaseIterable, Equatable {
    case escape
    case applicationDeactivated
    case windowDeactivated
    case screenChanged
    case explicitHide
    case lostWindow
    case interruptedEventDelivery
}

struct PanelInteractionCancellation: Equatable {
    let interaction: PanelInteraction
    let reason: PanelInteractionCancellationReason
}

struct PanelInteractionLifecycle {
    private(set) var activeInteraction: PanelInteraction?

    mutating func begin(_ interaction: PanelInteraction) {
        activeInteraction = interaction
    }

    mutating func finish(_ interaction: PanelInteraction) -> Bool {
        guard activeInteraction == interaction else { return false }
        activeInteraction = nil
        return true
    }

    mutating func cancel(
        reason: PanelInteractionCancellationReason
    ) -> PanelInteractionCancellation? {
        guard let activeInteraction else { return nil }
        self.activeInteraction = nil
        return PanelInteractionCancellation(
            interaction: activeInteraction,
            reason: reason
        )
    }
}

enum PanelInteractionCaptureWatchdogPolicy {
    static let intervalMilliseconds = 200

    static func shouldRecover(
        hasActiveInteraction: Bool,
        pressedMouseButtons: Int
    ) -> Bool {
        hasActiveInteraction && (pressedMouseButtons & 1) == 0
    }
}

/// Retains deliberate mouse-throw intent across the stationary samples that
/// occur when the physical pointer reaches a screen edge. Direction comes from
/// the cumulative gesture, while speed is the strongest meaningful rolling
/// segment rather than the often-zero final event.
struct PanelDragIntentTracker {
    static let minimumMeaningfulSegmentDistance: CGFloat = 8
    static let maximumReleaseTail: TimeInterval = 0.4

    private let initialLocation: CGPoint
    private let initialTimestamp: TimeInterval
    private var velocityAnchorLocation: CGPoint
    private var velocityAnchorTimestamp: TimeInterval
    private var peakSpeed: CGFloat = 0
    private var lastMeaningfulTimestamp: TimeInterval?

    init(location: CGPoint, timestamp: TimeInterval) {
        initialLocation = location
        initialTimestamp = timestamp
        velocityAnchorLocation = location
        velocityAnchorTimestamp = timestamp
    }

    mutating func record(location: CGPoint, timestamp: TimeInterval) {
        let segment = CGPoint(
            x: location.x - velocityAnchorLocation.x,
            y: location.y - velocityAnchorLocation.y
        )
        let distance = hypot(segment.x, segment.y)
        let elapsed = timestamp - velocityAnchorTimestamp
        guard distance >= Self.minimumMeaningfulSegmentDistance,
              elapsed > 0 else { return }

        peakSpeed = max(peakSpeed, distance / elapsed)
        lastMeaningfulTimestamp = timestamp
        velocityAnchorLocation = location
        velocityAnchorTimestamp = timestamp
    }

    func release(
        location: CGPoint,
        timestamp: TimeInterval
    ) -> PanelDragReleaseIntent {
        let translation = CGPoint(
            x: location.x - initialLocation.x,
            y: location.y - initialLocation.y
        )
        let distance = hypot(translation.x, translation.y)
        guard distance > 0,
              let lastMeaningfulTimestamp,
              timestamp - lastMeaningfulTimestamp <= Self.maximumReleaseTail else {
            return PanelDragReleaseIntent(
                velocity: .zero,
                translation: translation
            )
        }

        let elapsed = max(timestamp - initialTimestamp, .leastNonzeroMagnitude)
        let displacementSpeed = distance / elapsed
        let intentSpeed = max(peakSpeed, displacementSpeed)
        return PanelDragReleaseIntent(
            velocity: CGPoint(
                x: translation.x / distance * intentSpeed,
                y: translation.y / distance * intentSpeed
            ),
            translation: translation
        )
    }
}

/// A narrow bridge between SwiftUI's transient section-dock expansion state
/// and AppKit's window hit testing. It is deliberately not observable: the
/// shell already redraws for hover/focus, and AppKit only needs the current
/// control footprint when classifying the next pointer event.
@MainActor
final class PanelChromeInteractionState {
    var onModeDockWidthChanged: (() -> Void)?
    var bottomControlsHeight: CGFloat = AtticStyle.controlHitSize
    var modeDockWidth = PanelModeDockLayout.width(isExpanded: false) {
        didSet {
            guard modeDockWidth != oldValue else { return }
            onModeDockWidthChanged?()
        }
    }
}

/// The window server still treats a transparent borderless panel as a
/// rectangle. Keep AppKit's responder hit test aligned with the visible
/// squircle so transparent corner pixels cannot obstruct the app behind it.
final class AtticPanelContentContainer: NSView {
    let hostingView: AtticPanelHostingView
    private let motionView = NSView()
    private static let collapseAnimationKey = "attic.panel.collapse"
    var allowsContentInteraction = true

    init(hostingView: AtticPanelHostingView, visibleSize: CGSize, perimeter: CGFloat) {
        self.hostingView = hostingView
        super.init(frame: CGRect(origin: .zero, size: CGSize(
            width: visibleSize.width + perimeter * 2,
            height: visibleSize.height + perimeter * 2
        )))
        motionView.frame = bounds
        motionView.autoresizingMask = [.width, .height]
        motionView.wantsLayer = true
        addSubview(motionView)
        hostingView.frame = bounds.insetBy(dx: perimeter, dy: perimeter)
        hostingView.autoresizingMask = [.width, .height]
        motionView.addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowsContentInteraction,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return hostingView.hitTest(convert(point, from: superview))
    }

    var presentationTransform: CATransform3D {
        guard let layer = motionView.layer else { return CATransform3DIdentity }
        // Finger-driven updates write the model immediately. The presentation
        // tree can still describe the previous display frame until the next
        // commit, so only consult it while a timed animation owns the motion.
        if layer.animation(forKey: Self.collapseAnimationKey) != nil {
            return layer.presentation()?.transform ?? layer.transform
        }
        return layer.transform
    }

    func stopCollapseMotion() {
        guard let layer = motionView.layer else { return }
        let current = presentationTransform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = current
        layer.removeAnimation(forKey: Self.collapseAnimationKey)
        CATransaction.commit()
    }

    func setCollapseProgress(
        _ progress: CGFloat, corner: ScreenCorner, reduceMotion: Bool,
        duration: TimeInterval = 0, completion: (() -> Void)? = nil
    ) {
        guard let layer = motionView.layer else { completion?(); return }
        let from = presentationTransform
        let target = CATransform3DMakeAffineTransform(PanelCollapseGeometry.transform(
            progress: progress, visibleBounds: hostingView.frame,
            layerBounds: motionView.bounds, corner: corner, reduceMotion: reduceMotion,
            layerAnchor: CGPoint(
                x: layer.bounds.minX + layer.anchorPoint.x * layer.bounds.width,
                y: layer.bounds.minY + layer.anchorPoint.y * layer.bounds.height
            )
        ))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.collapseAnimationKey)
        layer.transform = target
        if duration > 0, !reduceMotion, !CATransform3DEqualToTransform(from, target) {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: from)
            animation.toValue = NSValue(caTransform3D: target)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1)
            CATransaction.setCompletionBlock(completion)
            layer.add(animation, forKey: Self.collapseAnimationKey)
            CATransaction.commit()
        } else {
            CATransaction.commit()
            completion?()
        }
    }
}

final class AtticPanelHostingView: NSHostingView<AtticPanelView> {
    private struct ResizeSession {
        let edges: PanelResizeEdges
        let initialFrame: CGRect
        let initialMouseLocation: CGPoint
    }

    private struct MoveSession {
        let initialFrame: CGRect
        let initialMouseLocation: CGPoint
        var intent: PanelDragIntentTracker
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
    var onWindowDragChanged: ((CGRect, CGPoint) -> CGRect)?
    var onWindowDragEnded: ((CGRect, CGPoint, CGPoint, CGPoint) -> Void)?
    var onInteractionCancelled: ((PanelInteractionCancellation, CGRect?) -> Void)?
    private let chromeInteractionState: PanelChromeInteractionState
    private var resizeSession: ResizeSession?
    private var moveSession: MoveSession?
    private var interactionLifecycle = PanelInteractionLifecycle()
    private var escapeKeyMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var captureWatchdog: DispatchSourceTimer?

    init(
        rootView: AtticPanelView,
        panelCornerRadius: CGFloat,
        dockedCorner: ScreenCorner,
        chromeInteractionState: PanelChromeInteractionState
    ) {
        self.panelCornerRadius = panelCornerRadius
        self.dockedCorner = dockedCorner
        self.chromeInteractionState = chromeInteractionState
        super.init(rootView: rootView)
        chromeInteractionState.onModeDockWidthChanged = { [weak self] in
            guard let self, let window = self.window else { return }
            window.invalidateCursorRects(for: self)
        }
    }

    @available(*, unavailable)
    required init(rootView: AtticPanelView) {
        fatalError("Use init(rootView:panelCornerRadius:dockedCorner:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
        }
        captureWatchdog?.cancel()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelActiveInteraction(reason: .lostWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        let policyPoint = AtticPanelCoordinateSpace.policyPoint(
            fromHostingPoint: localPoint,
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
            dockedAt: dockedCorner,
            acquisitionInset: (window as? AtticPanel)?.resizePerimeter ?? 0
        )
        guard isInsideSquircle || resizeEdges != nil else { return nil }
        if resizeEdges != nil {
            return self
        }
        if AtticPanelDragPolicy.isTopDragPoint(
            policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius,
            modeDockWidth: chromeInteractionState.modeDockWidth,
            dockedAt: dockedCorner
        ) {
            return self
        }
        return super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func isChromeControlPoint(_ windowPoint: CGPoint) -> Bool {
        let point = AtticPanelCoordinateSpace.policyPoint(
            fromHostingPoint: convert(windowPoint, from: nil), in: bounds, isFlipped: isFlipped
        )
        let insets = PanelGeometry.chromeInsets(cornerSize: panelCornerRadius, panelSize: bounds.size)
        let topControlsY = bounds.maxY - insets.top - AtticStyle.controlHitSize
        let pinRect = CGRect(x: bounds.minX + insets.leading, y: topControlsY,
                             width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
        let modeRect = CGRect(x: bounds.maxX - insets.trailing - chromeInteractionState.modeDockWidth,
                              y: topControlsY, width: chromeInteractionState.modeDockWidth,
                              height: AtticStyle.controlHitSize)
        return pinRect.contains(point) || modeRect.contains(point)
            || point.y < bounds.minY + insets.bottom + chromeInteractionState.bottomControlsHeight
    }

    override func mouseDown(with event: NSEvent) {
        let hostingPoint = convert(event.locationInWindow, from: nil)
        let policyPoint = AtticPanelCoordinateSpace.policyPoint(
            fromHostingPoint: hostingPoint,
            in: bounds,
            isFlipped: isFlipped
        )
        guard let window else {
            cancelActiveInteraction(reason: .lostWindow)
            super.mouseDown(with: event)
            return
        }
        if interactionLifecycle.activeInteraction != nil {
            cancelActiveInteraction(reason: .interruptedEventDelivery)
        }
        // The delivered event owns this sample. Reading the live global
        // cursor instead can collapse queued or replayed movement to zero.
        if let edges = AtticPanelResizePolicy.resizeEdges(
                at: policyPoint,
                in: bounds,
                cornerRadius: panelCornerRadius,
                dockedAt: dockedCorner,
                acquisitionInset: (window as? AtticPanel)?.resizePerimeter ?? 0
              ) {
            resizeSession = ResizeSession(
                edges: edges,
                initialFrame: (window as? AtticPanel)?.visibleContentFrame ?? window.frame,
                initialMouseLocation: window.convertPoint(toScreen: event.locationInWindow)
            )
            interactionLifecycle.begin(.windowResize)
            startEscapeMonitoring()
            window.makeKey()
            onLiveResizeBegan?()
            return
        }
        guard AtticPanelDragPolicy.isTopDragPoint(
            policyPoint,
            in: bounds,
            cornerRadius: panelCornerRadius,
            modeDockWidth: chromeInteractionState.modeDockWidth,
            dockedAt: dockedCorner
        ) else {
            super.mouseDown(with: event)
            return
        }

        let mouseLocation = window.convertPoint(toScreen: event.locationInWindow)
        moveSession = MoveSession(
            initialFrame: (window as? AtticPanel)?.visibleContentFrame ?? window.frame,
            initialMouseLocation: mouseLocation,
            intent: PanelDragIntentTracker(
                location: mouseLocation,
                timestamp: event.timestamp
            )
        )
        interactionLifecycle.begin(.windowMove)
        startEscapeMonitoring()
        window.makeKey()
        NSCursor.closedHand.set()
        onWindowDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else {
            cancelActiveInteraction(reason: .lostWindow)
            super.mouseDragged(with: event)
            return
        }
        if let session = resizeSession {
            let mouseLocation = window.convertPoint(toScreen: event.locationInWindow)
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
            setContentFrame(frame, in: window)
            onLiveResizeChanged?(frame.size)
            return
        }
        guard var session = moveSession else {
            super.mouseDragged(with: event)
            return
        }

        let mouseLocation = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(
            x: mouseLocation.x - session.initialMouseLocation.x,
            y: mouseLocation.y - session.initialMouseLocation.y
        )
        session.intent.record(
            location: mouseLocation,
            timestamp: event.timestamp
        )
        moveSession = session

        var proposedFrame = session.initialFrame
        proposedFrame.origin.x += delta.x
        proposedFrame.origin.y += delta.y
        let frame = onWindowDragChanged?(proposedFrame, mouseLocation) ?? proposedFrame
        setContentFrame(frame, in: window)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else {
            cancelActiveInteraction(reason: .lostWindow)
            super.mouseUp(with: event)
            return
        }
        guard finishActiveInteraction(
            in: window,
            mouseLocation: window.convertPoint(toScreen: event.locationInWindow),
            timestamp: event.timestamp
        ) else {
            super.mouseUp(with: event)
            return
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard interactionLifecycle.activeInteraction != nil else {
            super.cancelOperation(sender)
            return
        }
        cancelActiveInteraction(reason: .escape)
    }

    func cancelActiveInteraction(
        reason: PanelInteractionCancellationReason
    ) {
        guard let cancellation = interactionLifecycle.cancel(reason: reason) else {
            return
        }
        resizeSession = nil
        moveSession = nil
        stopEscapeMonitoring()
        window?.ignoresMouseEvents = false
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
        onInteractionCancelled?(cancellation, (window as? AtticPanel)?.visibleContentFrame ?? window?.frame)
    }

    private func setContentFrame(_ frame: CGRect, in window: NSWindow) {
        if let panel = window as? AtticPanel {
            panel.setVisibleContentFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func startEscapeMonitoring() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                self?.cancelActiveInteraction(reason: .escape)
            }
            return nil
        }
        startCaptureCompletionMonitoring()
    }

    private func stopEscapeMonitoring() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
        stopCaptureCompletionMonitoring()
    }

    private func startCaptureCompletionMonitoring() {
        guard localMouseUpMonitor == nil,
              globalMouseUpMonitor == nil,
              captureWatchdog == nil else { return }
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.finishCapturedMouseUp(event)
            }
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.finishCapturedMouseUp(event)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(
                PanelInteractionCaptureWatchdogPolicy.intervalMilliseconds
            ),
            repeating: .milliseconds(
                PanelInteractionCaptureWatchdogPolicy.intervalMilliseconds
            ),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      PanelInteractionCaptureWatchdogPolicy.shouldRecover(
                        hasActiveInteraction: self.interactionLifecycle.activeInteraction != nil,
                        pressedMouseButtons: NSEvent.pressedMouseButtons
                      ) else { return }
                guard let window = self.window else {
                    self.cancelActiveInteraction(reason: .lostWindow)
                    return
                }
                _ = self.finishActiveInteraction(
                    in: window,
                    mouseLocation: NSEvent.mouseLocation,
                    timestamp: ProcessInfo.processInfo.systemUptime
                )
            }
        }
        captureWatchdog = timer
        timer.resume()
    }

    private func stopCaptureCompletionMonitoring() {
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        captureWatchdog?.cancel()
        captureWatchdog = nil
    }

    private func finishCapturedMouseUp(_ event: NSEvent) {
        guard let window else {
            cancelActiveInteraction(reason: .lostWindow)
            return
        }
        _ = finishActiveInteraction(
            in: window,
            // Own-window mouse-up is delivered before the responder path by
            // the local monitor. Preserve its event position too; events from
            // another window or the global monitor need the global fallback.
            mouseLocation: event.window === window
                ? window.convertPoint(toScreen: event.locationInWindow)
                : NSEvent.mouseLocation,
            timestamp: event.timestamp
        )
    }

    @discardableResult
    private func finishActiveInteraction(
        in window: NSWindow,
        mouseLocation: CGPoint,
        timestamp: TimeInterval
    ) -> Bool {
        if resizeSession != nil {
            resizeSession = nil
            guard interactionLifecycle.finish(.windowResize) else { return false }
            stopEscapeMonitoring()
            onLiveResizeEnded?(((window as? AtticPanel)?.visibleContentFrame ?? window.frame).size)
            return true
        }
        guard let session = moveSession,
              interactionLifecycle.finish(.windowMove) else { return false }
        moveSession = nil
        stopEscapeMonitoring()
        let release = session.intent.release(
            location: mouseLocation,
            timestamp: timestamp
        )
        window.invalidateCursorRects(for: self)
        onWindowDragEnded?(
            (window as? AtticPanel)?.visibleContentFrame ?? window.frame,
            mouseLocation,
            release.velocity,
            release.translation
        )
        return true
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
                    cornerRadius: panelCornerRadius,
                    modeDockWidth: chromeInteractionState.modeDockWidth,
                    dockedAt: dockedCorner
                ),
                in: bounds,
                isFlipped: isFlipped
            ),
            cursor: .openHand
        )
        addCursorRect(
            localCursorRect(AtticPanelDragPolicy.upperDragRegion(
                in: bounds, cornerRadius: panelCornerRadius, dockedAt: dockedCorner
            )),
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
