import CoreGraphics
import SwiftUI

enum PanelGeometry {
    static let triggerSize: CGFloat = 16
    static let panelWidth: CGFloat = 332
    static let minimumHeight: CGFloat = 480
    static let preferredHeightCeiling: CGFloat = 700
    static let screenInset: CGFloat = 12

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
            width: max(minimumPanelSize.width, visibleFrame.width - (screenInset * 2)),
            height: max(minimumPanelSize.height, visibleFrame.height - (screenInset * 2))
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

    /// A deliberate flick back toward the already attached corner dismisses
    /// the panel. Other flicks retain their existing role of moving it to a
    /// different corner, while an ordinary release docks to the nearest one.
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
            return flick == attachedCorner ? .hide : .dock(flick)
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
                - (2 * AtticStyle.controlHitSize)
                - 4
        )
    }
}

enum TaskScrollMaskLayout {
    /// Preserve short, optical fades as the panel grows rather than scaling
    /// them into large translucent bands at taller user-selected sizes.
    static func stops(panelHeight: CGFloat) -> (topFadeEnd: CGFloat, bottomFadeStart: CGFloat) {
        let height = max(panelHeight, 1)
        let topFadeEnd = min(0.12, 18 / height)
        let bottomFadeStart = max(topFadeEnd + 0.25, 1 - (76 / height))
        return (topFadeEnd, min(bottomFadeStart, 0.96))
    }
}
