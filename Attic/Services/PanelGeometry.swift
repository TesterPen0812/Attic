import CoreGraphics
import SwiftUI

enum PanelGeometry {
    static let triggerSize: CGFloat = 16
    static let panelWidth: CGFloat = 332
    static let minimumHeight: CGFloat = 380
    static let maximumHeight: CGFloat = 700
    static let screenInset: CGFloat = 12

    /// Superellipse exponent used for the squircle corners.
    static let squircleExponent: CGFloat = 5

    /// Minimum horizontal padding from the panel edge to content, ensuring
    /// content never intersects the corner curve. Derived from the maximum
    /// inward deviation of the corner superellipse plus a safety margin.
    static func contentInsets(cornerSize: CGFloat, panelSize: CGSize) -> EdgeInsets {
        let insetFactor = Squircle.cornerInsetFactor(exponent: squircleExponent)
        let cornerInset = cornerSize * insetFactor
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

    static func hiddenFrame(from visibleFrame: CGRect, corner: ScreenCorner, distance: CGFloat = 18) -> CGRect {
        let xOffset: CGFloat
        let yOffset: CGFloat
        switch corner {
        case .topLeft:
            xOffset = -distance
            yOffset = distance
        case .topRight:
            xOffset = distance
            yOffset = distance
        case .bottomLeft:
            xOffset = -distance
            yOffset = -distance
        case .bottomRight:
            xOffset = distance
            yOffset = -distance
        }
        return visibleFrame.offsetBy(dx: xOffset, dy: yOffset)
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
        return min(max(header + composer + content + 16, minimumHeight), maximumHeight)
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
        return min(max(header + composer + content + 16, minimumHeight), maximumHeight)
    }

    static func preferredCanvasHeight() -> CGFloat {
        min(max(560, minimumHeight), maximumHeight)
    }

    /// The redesigned panel is a stable workspace rather than a card that
    /// repeatedly changes size as content comes and goes. Keeping one frame
    /// also preserves the user's spatial memory when switching sections.
    static func preferredWorkspaceHeight(contentWidth: CGFloat) -> CGFloat {
        min(max(contentWidth * 1.45, 480), maximumHeight)
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
