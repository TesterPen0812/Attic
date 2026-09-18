import CoreGraphics
import Foundation
import SwiftUI

/// Geometry and timing for the auxiliary subtask surfaces: the transient
/// hover panel and the pinned mini-window. Everything here is pure value
/// logic so placement, flip/clamp behaviour and the open/close state machine
/// stay unit-testable without AppKit.
enum SubtaskPanelLayout {
    /// Inside the handoff's 260–310 point range, at its narrow end: the
    /// surface is a glance-sized companion to the row, not a second panel.
    /// The trade-off is title width — see `surfaceInsets`, which keeps a
    /// readable title column even at the largest configured corner.
    static let panelWidth: CGFloat = 272
    /// The child list is the only scrolling region; the header and entry row
    /// stay fixed. Tall families bound the surface instead of growing it.
    /// Short families still size to their content (`clampedListHeight`), so
    /// this is a ceiling, never a forced aspect ratio.
    static let maximumListHeight: CGFloat = 240
    static let minimumListHeight: CGFloat = AtticStyle.rowHeight
    /// A pin/unpin press resigns the entry's field editor on mouse-down —
    /// before the button's action runs — so a resign inside this window
    /// still counts as "the entry was engaged" for the host swap.
    static let entryResignReuseWindow: TimeInterval = 0.5
    /// Horizontal gap between the main panel and the auxiliary surface.
    static let sideGap: CGFloat = 10
    /// Matches the main panel's display-edge breathing room.
    static let screenInset: CGFloat = PanelGeometry.screenInset
    /// Lower bound for the surface height even when a family has no rows.
    static let minimumContentHeight: CGFloat = 112

    /// Corner-aware content padding for the auxiliary surfaces. The squircle
    /// curve moves inward by `cornerInsetFactor` of its radius, so padding
    /// must clear that or content corners clip; each value keeps its original
    /// compact spacing as a floor. Clamping the radius to half the panel
    /// WIDTH (never its height) can only over-pad a very short surface — it
    /// can never under-pad into the curve.
    static func surfaceInsets(cornerSize: CGFloat) -> SurfaceInsets {
        let clearance = min(max(0, cornerSize), panelWidth / 2)
            * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
        return SurfaceInsets(
            cornerClearance: clearance,
            horizontal: max(14, clearance + 6),
            top: max(11, clearance + 4),
            bottom: max(8, clearance + 6),
            row: max(4, clearance + 2)
        )
    }

    /// Room around the source row and the surface inside which a hand
    /// travelling between them still reads as transit.
    static let corridorVerticalPadding: CGFloat = AtticStyle.rowHeight

    /// Where a screen point sits relative to an open transient surface.
    /// `.surface` is the drawn squircle itself; `.transit` is the corridor
    /// from the source row to wherever the surface was actually placed. The
    /// main panel's auto-hide treats both as "inside" so a hand moving
    /// between the row and its open panel never hides the panel underneath;
    /// outside-click dismissal counts only the narrow gap beside the surface.
    enum PointerCoverage: Equatable {
        case outside
        case transit
        case surface
    }

    /// Classifies a screen point. The corridor is the convex hull of the
    /// padded source row and the padded surface, so it follows the surface
    /// wherever placement put it — beside the panel, or moved clear of a
    /// pinned window. Only its source-facing half counts: past the surface's
    /// centre, away from the row, the pointer is leaving, not arriving. A
    /// pinned Attic panel lying across that route is transit too, so crossing
    /// it does not dismiss. Without a main panel (a detached surface) there is
    /// no route; without a live row the panel's facing edge stands in for it.
    static func pointerCoverage(
        _ point: CGPoint,
        surfaceFrame: CGRect,
        cornerSize: CGFloat,
        mainPanelFrame: CGRect?,
        anchorRect: CGRect?,
        crossingFrames: [CGRect] = []
    ) -> PointerCoverage {
        let local = CGPoint(
            x: point.x - surfaceFrame.minX,
            y: point.y - surfaceFrame.minY
        )
        if surfaceContains(
            local,
            in: CGRect(origin: .zero, size: surfaceFrame.size),
            cornerSize: cornerSize
        ) {
            return .surface
        }
        guard let main = mainPanelFrame else { return .outside }
        let source: CGRect
        if let anchorRect, !anchorRect.isNull, !anchorRect.isEmpty {
            source = anchorRect
        } else {
            let edgeX = surfaceFrame.midX >= main.midX ? main.maxX : main.minX
            source = CGRect(x: edgeX, y: surfaceFrame.minY, width: 0, height: surfaceFrame.height)
        }
        let toSource = CGPoint(x: source.midX - surfaceFrame.midX, y: source.midY - surfaceFrame.midY)
        let fromSurface = CGPoint(x: point.x - surfaceFrame.midX, y: point.y - surfaceFrame.midY)
        guard fromSurface.x * toSource.x + fromSurface.y * toSource.y > 0 else { return .outside }
        let hull = corridorHull(source: source, surface: surfaceFrame)
        if convexPolygon(hull, contains: point) { return .transit }
        let crossesRoute = crossingFrames.contains { frame in
            !frame.isEmpty && frame.contains(point) && convexPolygons(hull, intersect: corners(of: frame))
        }
        return crossesRoute ? .transit : .outside
    }

    /// Counter-clockwise hull of the padded source and surface rectangles.
    static func corridorHull(source: CGRect, surface: CGRect) -> [CGPoint] {
        let padding = corridorVerticalPadding
        return convexHull(
            corners(of: source.insetBy(dx: -padding, dy: -padding))
                + corners(of: surface.insetBy(dx: -padding, dy: -padding))
        )
    }

    /// Distance from a point to the nearest point of a rectangle; zero inside.
    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    /// Monotone chain; eight points at most, so no allocation concerns.
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func convexPolygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            if cross(polygon[index], next, point) < 0 { return false }
        }
        return true
    }

    /// Separating-axis test for two convex polygons.
    private static func convexPolygons(_ a: [CGPoint], intersect b: [CGPoint]) -> Bool {
        for polygon in [a, b] {
            for index in polygon.indices {
                let next = polygon[(index + 1) % polygon.count]
                let axis = CGPoint(x: polygon[index].y - next.y, y: next.x - polygon[index].x)
                func project(_ points: [CGPoint]) -> ClosedRange<CGFloat> {
                    let values = points.map { $0.x * axis.x + $0.y * axis.y }
                    return (values.min() ?? 0)...(values.max() ?? 0)
                }
                if !project(a).overlaps(project(b)) { return false }
            }
        }
        return true
    }

    /// One geometry definition for the surfaces' visible shape, shared by the
    /// AppKit hit test, the auto-hide coverage predicate and outside-click
    /// dismissal so all three agree with what is actually drawn.
    static func surfaceContains(
        _ point: CGPoint,
        in bounds: CGRect,
        cornerSize: CGFloat
    ) -> Bool {
        Squircle.contains(
            point,
            in: bounds,
            cornerRadius: cornerSize,
            exponent: PanelGeometry.squircleExponent
        )
    }

    static func clampedListHeight(_ measured: CGFloat) -> CGFloat {
        guard measured.isFinite, measured > 0 else { return minimumListHeight }
        return min(max(measured, minimumListHeight), maximumListHeight)
    }

    // MARK: Attachments gallery

    /// Two compact columns: one image takes half the width and a short card,
    /// so it can never dominate the panel.
    static let galleryColumns = 2
    static let galleryCardHeight: CGFloat = 100
    static let galleryPreviewHeight: CGFloat = 56
    static let gallerySpacing: CGFloat = 8
    static let galleryVerticalPadding: CGFloat = 4
    static let galleryEmptyHeight: CGFloat = 40

    /// The gallery's natural height is pure arithmetic over a fixed card
    /// size, so switching views knows its target before anything renders.
    static func galleryContentHeight(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return galleryEmptyHeight }
        let rows = CGFloat((itemCount + galleryColumns - 1) / galleryColumns)
        return rows * galleryCardHeight + (rows - 1) * gallerySpacing + 2 * galleryVerticalPadding
    }

    /// Both views share one sizing rule: their natural height, bounded by the
    /// existing subtask list maximum, after which the content scrolls.
    static func contentHeight(for view: FamilyPanelView, childCount: Int,
                              measuredListHeight: CGFloat?, attachmentCount: Int) -> CGFloat {
        switch view {
        case .subtasks:
            guard childCount > 0 else { return 0 }
            return clampedListHeight(measuredListHeight
                ?? CGFloat(childCount) * AtticStyle.controlHitSize + 8)
        case .attachments:
            return min(galleryContentHeight(itemCount: attachmentCount), maximumListHeight)
        }
    }

    /// Short and anchored: content slides a few points and crossfades while
    /// the surface's top edge stays put and its height follows the content.
    static let viewSwitchDuration: TimeInterval = 0.22
    static let viewSwitchSlide: CGFloat = 18

    /// Horizontal offset of a view's own side: Subtasks left, Attachments
    /// right. A view enters from and leaves toward this offset, so on a switch
    /// the outgoing and incoming views move in the same direction.
    static func viewSwitchOffset(for view: FamilyPanelView) -> CGFloat {
        view == .attachments ? viewSwitchSlide : -viewSwitchSlide
    }
    /// Newly imported cards enter just after the view switch settles, a few
    /// hundredths apart; their fresh mark is dropped once that has played.
    static let freshAttachmentEntranceDelay: TimeInterval = 0.12
    static let freshAttachmentStagger: TimeInterval = 0.035
    static let freshAttachmentLifetime: TimeInterval = 1.2

    /// Composer capsule minimum height and the view switch's diameter.
    static let footerControlSize: CGFloat = 32

    /// The transient panel hangs off the side of the main panel toward the
    /// screen's interior and top-aligns with the hovered row. When the
    /// interior side cannot fit, it flips to the panel's outside edge; the
    /// result is always clamped into the display's safe work area.
    static func transientFrame(
        size: CGSize,
        anchorScreenRect: CGRect?,
        panelScreenFrame: CGRect,
        screenVisibleFrame: CGRect,
        occupiedFrames: [CGRect] = [],
        gap: CGFloat = sideGap,
        inset: CGFloat = screenInset
    ) -> CGRect {
        let safe = screenVisibleFrame.insetBy(dx: inset, dy: inset)
        let width = min(max(0, size.width), max(0, safe.width))
        let height = min(max(0, size.height), max(0, safe.height))
        let sizeClamped = CGSize(width: width, height: height)

        let panelOnRight = panelScreenFrame.midX >= screenVisibleFrame.midX
        let interiorX = panelOnRight
            ? panelScreenFrame.minX - gap - width
            : panelScreenFrame.maxX + gap
        let exteriorX = panelOnRight
            ? panelScreenFrame.maxX + gap
            : panelScreenFrame.minX - gap - width
        var x = interiorX
        if panelOnRight, x < safe.minX, exteriorX + width <= safe.maxX {
            x = exteriorX
        } else if !panelOnRight, x + width > safe.maxX, exteriorX >= safe.minX {
            x = exteriorX
        }
        x = min(max(x, safe.minX), max(safe.minX, safe.maxX - width))

        let desiredTop = anchorScreenRect?.maxY
            ?? (panelScreenFrame.maxY - min(60, panelScreenFrame.height))
        let y = min(
            max(desiredTop - height, safe.minY),
            max(safe.minY, safe.maxY - height)
        )
        let proposed = CGRect(origin: CGPoint(x: x, y: y), size: sizeClamped)
        return avoidingOverlap(proposed, occupied: occupiedFrames + [panelScreenFrame], within: safe, gap: gap)
    }

    /// Prefer the closest free position at an obstacle edge. The candidate
    /// count depends on open windows, never on screen pixels or a timer.
    static func avoidingOverlap(_ preferred: CGRect, occupied: [CGRect], within safe: CGRect, gap: CGFloat = sideGap) -> CGRect {
        let proposed = CGRect(x: min(max(safe.minX, preferred.minX), max(safe.minX, safe.maxX - preferred.width)),
                              y: min(max(safe.minY, preferred.minY), max(safe.minY, safe.maxY - preferred.height)),
                              width: preferred.width, height: preferred.height)
        let obstacles = occupied.filter { !$0.isEmpty && $0.intersects(safe) }
        guard obstacles.contains(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(proposed) }) else { return proposed }
        let xs = [proposed.minX, safe.minX, safe.maxX - proposed.width]
            + obstacles.flatMap { [$0.minX - gap - proposed.width, $0.maxX + gap] }
        let ys = [proposed.minY, safe.minY, safe.maxY - proposed.height]
            + obstacles.flatMap { [$0.minY - gap - proposed.height, $0.maxY + gap] }
        var best = proposed
        var bestOverlap = CGFloat.greatestFiniteMagnitude
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for x in xs {
            for y in ys {
                let candidate = CGRect(x: min(max(safe.minX, x), max(safe.minX, safe.maxX - proposed.width)),
                                       y: min(max(safe.minY, y), max(safe.minY, safe.maxY - proposed.height)),
                                       width: proposed.width, height: proposed.height)
                let overlap = obstacles.reduce(CGFloat.zero) { sum, obstacle in
                    let intersection = candidate.intersection(obstacle.insetBy(dx: -gap / 2, dy: -gap / 2))
                    return sum + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
                let distance = hypot(candidate.minX - proposed.minX, candidate.minY - proposed.minY)
                if overlap < bestOverlap || (overlap == bestOverlap && distance < bestDistance) {
                    best = candidate; bestOverlap = overlap; bestDistance = distance
                }
            }
        }
        return best
    }

    /// Keeps the surface's top edge stationary while its height follows
    /// content. Returns nil when the change is sub-pixel.
    static func framePreservingTop(_ frame: CGRect, height: CGFloat) -> CGRect? {
        guard height.isFinite, height > 0,
              abs(frame.height - height) >= 0.5 else { return nil }
        return CGRect(
            x: frame.minX,
            y: frame.maxY - height,
            width: frame.width,
            height: height
        )
    }

    /// Resolves a pinned-window frame: a remembered position survives only
    /// when its centre still lands inside a current display's work area;
    /// otherwise the window falls back to the given rect (a promotion frame
    /// or the row anchor), or centres on the first screen as a last resort.
    static func restoredPinnedFrame(
        saved: CGRect?,
        size: CGSize,
        screenVisibleFrames: [CGRect],
        fallback: CGRect? = nil
    ) -> CGRect {
        if let saved, saved.width >= 1, saved.height >= 1 {
            if let frame = frameWithOrigin(saved.origin, size: size, insideScreenContaining: CGPoint(x: saved.midX, y: saved.midY), screenVisibleFrames: screenVisibleFrames) {
                return frame
            }
        }
        if let fallback, fallback.width >= 1, fallback.height >= 1 {
            // Whether the fallback is a promoted transient frame or a row
            // anchor, it expresses "the surface's current location": keep its
            // horizontal position and top-align the window on its top edge.
            let desiredOrigin = CGPoint(
                x: fallback.minX,
                y: fallback.maxY - size.height
            )
            if let frame = frameWithOrigin(desiredOrigin, size: size, insideScreenContaining: CGPoint(x: fallback.midX, y: fallback.midY), screenVisibleFrames: screenVisibleFrames) {
                return frame
            }
        }
        guard let host = screenVisibleFrames.first else {
            return CGRect(origin: .zero, size: size)
        }
        let safe = host.insetBy(dx: screenInset, dy: screenInset)
        let width = min(size.width, max(0, safe.width))
        let height = min(size.height, max(0, safe.height))
        return CGRect(
            x: safe.midX - width / 2,
            y: safe.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// Resizes a pinned surface while holding its top edge, then clamps the
    /// result into the visible area of the screen hosting it. Growth near the
    /// bottom of a display can no longer push controls offscreen — the frame
    /// shifts up (and shrinks if it exceeds the safe area) instead.
    static func pinnedResizedFrame(
        _ frame: CGRect,
        newHeight: CGFloat,
        screenVisibleFrames: [CGRect]
    ) -> CGRect? {
        guard var resized = framePreservingTop(frame, height: newHeight) else {
            return nil
        }
        let center = CGPoint(x: resized.midX, y: resized.midY)
        let host = screenVisibleFrames.first(where: { $0.contains(center) })
            ?? screenVisibleFrames.first(where: { $0.intersects(resized) })
            ?? screenVisibleFrames.first
        if let host {
            resized = PanelGeometry.constrainedFrame(resized, to: host)
        }
        return resized
    }

    private static func frameWithOrigin(
        _ origin: CGPoint,
        size: CGSize,
        insideScreenContaining point: CGPoint,
        screenVisibleFrames: [CGRect]
    ) -> CGRect? {
        guard let host = screenVisibleFrames.first(where: { $0.contains(point) }) else {
            return nil
        }
        let safe = host.insetBy(dx: screenInset, dy: screenInset)
        let width = min(size.width, max(0, safe.width))
        let height = min(size.height, max(0, safe.height))
        let x = min(max(origin.x, safe.minX), max(safe.minX, safe.maxX - width))
        let y = min(max(origin.y, safe.minY), max(safe.minY, safe.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The two views of a family panel. Each family's panel opens on Subtasks;
/// the user switches deliberately with the control beside the composer.
enum FamilyPanelView: Equatable, Sendable {
    case subtasks
    case attachments

    var destination: FamilyPanelView { self == .subtasks ? .attachments : .subtasks }

    /// The switch shows where it goes, not where the user is.
    var switchSymbol: String { destination == .attachments ? "photo.on.rectangle" : "checklist" }
    var switchLabel: String { destination == .attachments ? "Show attachments" : "Show subtasks" }
}

/// Corner-aware spacing for one auxiliary surface. Pure geometry so the
/// relationship between the user's corner setting and the padding that keeps
/// content clear of the curve is unit-testable without a view.
struct SurfaceInsets: Equatable {
    /// Deepest inward deviation of the corner curve at this radius.
    let cornerClearance: CGFloat
    let horizontal: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    let row: CGFloat

    /// Width left for the header's title column beside its control cluster.
    func titleWidth(panelWidth: CGFloat, controlWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        panelWidth - 2 * horizontal - controlWidth - spacing
    }
}

/// Tracks which family the transient surface shows and which families own
/// pinned windows. Every transient is opened deliberately (row click,
/// keyboard, VoiceOver, menu command, unpin) and stays until an outside
/// click, an explicit close, or a family change — pointer position never
/// opens or closes a surface. The AppKit controller owns windows and hit
/// tests; this value type owns the decisions so they stay deterministic.
struct SubtaskPanelLifecycle: Equatable {
    private(set) var transientFamilyID: UUID?
    private(set) var pinnedFamilyIDs: Set<UUID> = []
    /// Dragged away from its row: it stays where it was put and only follows
    /// its content height.
    private(set) var isTransientDetached = false

    /// Deliberate open. Returns false when the family is pinned — the pinned
    /// window is that family's only surface — or when it is already the
    /// transient. Callers must honor the result: a rejected open presents
    /// nothing new.
    @discardableResult
    mutating func openTransient(_ familyID: UUID) -> Bool {
        guard mayOpenTransient(for: familyID), transientFamilyID != familyID else { return false }
        transientFamilyID = familyID
        isTransientDetached = false
        return true
    }

    mutating func closeTransient() {
        transientFamilyID = nil
        isTransientDetached = false
    }

    /// Dragging detaches the transient from its row. Pinning remains a
    /// separate choice to survive main-panel hide.
    mutating func detachTransient() {
        guard transientFamilyID != nil else { return }
        isTransientDetached = true
    }

    mutating func pin(_ familyID: UUID) {
        pinnedFamilyIDs.insert(familyID)
        if transientFamilyID == familyID { closeTransient() }
    }

    @discardableResult
    mutating func unpin(_ familyID: UUID) -> UUID? {
        pinnedFamilyIDs.remove(familyID)
    }

    /// A pinned family never gets a second surface.
    func mayOpenTransient(for familyID: UUID) -> Bool {
        !pinnedFamilyIDs.contains(familyID)
    }
}

/// Each task row publishes its frame in the panel's root coordinate space so
/// the auxiliary controller can anchor the transient surface to it.
struct TaskRowAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The inline count control's own frame in the workspace space, published per
/// family. Outside-click dismissal uses it to recognize the toggle's paired
/// mousedown — only a press landing on this control suppresses the paired
/// reopen, so deliberate clicks elsewhere followed by the control still work.
struct TaskSubtaskControlFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The task list's scroll viewport in the same coordinate space; a row frame
/// outside it means the anchor is scrolled out and any anchored surface must
/// dismiss rather than dangle.
struct TaskListViewportPreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}

enum AtticPanelCoordinateSpaceName {
    static let taskWorkspace = "attic.taskWorkspace"
}

/// Measured height of the auxiliary panel's child list; cached per family so
/// the surface never reflows on reopen.
struct SubtaskListHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
