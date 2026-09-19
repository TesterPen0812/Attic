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
    static let panelWidth: CGFloat = 320
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

    static func preferredHeight(
        noteCount: Int,
        isComposing: Bool,
        hasConflict: Bool = false
    ) -> CGFloat {
        let header: CGFloat = 76
        let composer: CGFloat = isComposing ? (hasConflict ? 196 : 128) : 0
        let rowHeight: CGFloat = 52
        let content: CGFloat = noteCount == 0 ? 90 : CGFloat(noteCount) * rowHeight + 12
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

/// Recognizes a phase-aware, precise horizontal swipe toward the screen edge
/// that owns the panel. Mouse wheels and ordinary content scrolling remain on
/// their existing paths.
struct PanelTrackpadDismissTracker {
    static let minimumDistance: CGFloat = 48
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
    private(set) var progress: CGFloat = 0

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

    mutating func update(
        sample: PanelTrackpadSwipeSample,
        dockedCorner: ScreenCorner,
        towardDockedSide: Bool = true
    ) -> PanelTrackpadDismissUpdate {
        guard sample.isPrecise, sample.phase != .none else {
            reset()
            return .passThrough
        }

        if sample.phase == .began {
            reset()
            state = .undecided
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
            progress = max(0, progress + sample.deltaX * inversion * direction)
            let shouldHide = state == .tracking && progress >= Self.minimumDistance
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
            guard (intent.initialDirection?.x ?? 0) * edgeDirection > 0,
                  intent.displacement.x * edgeDirection > 0,
                  intent.isHorizontal else {
                state = .rejected
                return .passThrough
            }
            state = .tracking
            progress = intent.displacement.x * edgeDirection
            return .tracking
        }

        progress = max(0, progress + edgeProgress)
        return .tracking
    }

    mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        state = .idle
        intent = PanelTrackpadSwipeIntent()
        progress = 0
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
        let visibleSectionCount = isExpanded ? PanelSection.allCases.count : 1
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
