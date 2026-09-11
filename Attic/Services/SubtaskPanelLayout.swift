import CoreGraphics
import Foundation
import SwiftUI

/// Geometry and timing for the auxiliary subtask surfaces: the transient
/// hover panel and the pinned mini-window. Everything here is pure value
/// logic so placement, flip/clamp behaviour and the open/close state machine
/// stay unit-testable without AppKit.
enum SubtaskPanelLayout {
    /// Inside the handoff's 260–310 point range; wide enough for a checklist
    /// row and its actions, narrow enough to sit beside the main panel.
    static let panelWidth: CGFloat = 292
    /// The child list is the only scrolling region; the header and entry row
    /// stay fixed. Tall families bound the surface instead of growing it.
    static let maximumListHeight: CGFloat = 264
    static let minimumListHeight: CGFloat = AtticStyle.rowHeight
    /// Open only after a settled hover; brief row crossings stay closed.
    static let openDwell: TimeInterval = 0.35
    /// Grace for pointer travel across the row-to-panel gap before the
    /// transient surface dismisses.
    static let closeGrace: TimeInterval = 0.45
    /// Horizontal gap between the main panel and the auxiliary surface.
    static let sideGap: CGFloat = 10
    /// Matches the main panel's display-edge breathing room.
    static let screenInset: CGFloat = PanelGeometry.screenInset
    /// Lower bound for the surface height even when a family has no rows.
    static let minimumContentHeight: CGFloat = 112

    static func clampedListHeight(_ measured: CGFloat) -> CGFloat {
        guard measured.isFinite, measured > 0 else { return minimumListHeight }
        return min(max(measured, minimumListHeight), maximumListHeight)
    }

    /// The transient panel hangs off the side of the main panel toward the
    /// screen's interior and top-aligns with the hovered row. When the
    /// interior side cannot fit, it flips to the panel's outside edge; the
    /// result is always clamped into the display's safe work area.
    static func transientFrame(
        size: CGSize,
        anchorScreenRect: CGRect?,
        panelScreenFrame: CGRect,
        screenVisibleFrame: CGRect,
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
        return CGRect(origin: CGPoint(x: x, y: y), size: sizeClamped)
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

/// Tracks which family a transient hover surface may show and when pending
/// opens/closes mature. The AppKit controller owns timers and hit tests;
/// this value type owns the decisions so they stay deterministic in tests.
struct SubtaskPanelLifecycle: Equatable {
    enum TransientOrigin: Equatable {
        /// Hover-dwell open: pointer-leave rules close it.
        case hover
        /// Explicit open (count control, menu, VoiceOver, unpin): stays until
        /// an outside click, an explicit close, or a family change.
        case explicit
    }

    struct PendingOpen: Equatable {
        let familyID: UUID
        let deadline: TimeInterval
    }

    struct PendingClose: Equatable {
        let familyID: UUID
        let deadline: TimeInterval
    }

    private(set) var transientFamilyID: UUID?
    private(set) var transientOrigin: TransientOrigin = .hover
    private(set) var pinnedFamilyID: UUID?
    private(set) var pendingOpen: PendingOpen?
    private(set) var pendingClose: PendingClose?

    var isTransientLatched: Bool { transientOrigin == .explicit }
    var hasPendingTransient: Bool { transientFamilyID != nil || pendingOpen != nil }

    mutating func noteRowHover(familyID: UUID, isHovering: Bool, at now: TimeInterval) {
        if isHovering {
            if let close = pendingClose, close.familyID == familyID {
                pendingClose = nil
            }
            guard transientFamilyID != familyID,
                  pinnedFamilyID != familyID else { return }
            pendingOpen = PendingOpen(
                familyID: familyID,
                deadline: now + SubtaskPanelLayout.openDwell
            )
        } else {
            if pendingOpen?.familyID == familyID {
                pendingOpen = nil
            }
            if transientFamilyID == familyID, !isTransientLatched {
                pendingClose = PendingClose(
                    familyID: familyID,
                    deadline: now + SubtaskPanelLayout.closeGrace
                )
            }
        }
    }

    /// Pointer crossed into the transient surface itself: any close is
    /// cancelled and a pending open for a different family loses its claim.
    mutating func noteTransientPointer(inside: Bool, at now: TimeInterval) {
        if inside {
            pendingClose = nil
            if let pending = pendingOpen, pending.familyID != transientFamilyID {
                pendingOpen = nil
            }
        } else if let open = transientFamilyID, !isTransientLatched {
            pendingClose = PendingClose(
                familyID: open,
                deadline: now + SubtaskPanelLayout.closeGrace
            )
        }
    }

    /// A pending dwell matures into an open only when the same family is
    /// still the request and nothing newer superseded it.
    mutating func maturePendingOpen(for familyID: UUID, at now: TimeInterval) -> Bool {
        guard let pending = pendingOpen,
              pending.familyID == familyID,
              now >= pending.deadline else { return false }
        pendingOpen = nil
        transientFamilyID = familyID
        transientOrigin = .hover
        pendingClose = nil
        return true
    }

    mutating func maturePendingClose(for familyID: UUID, at now: TimeInterval) -> Bool {
        guard let pending = pendingClose,
              pending.familyID == familyID,
              now >= pending.deadline else { return false }
        pendingClose = nil
        if transientFamilyID == familyID {
            transientFamilyID = nil
        }
        return true
    }

    /// Explicit open (click/keyboard/VoiceOver/unpin) latches the surface so
    /// it is not bound to pointer presence. Returns false when the family is
    /// pinned — the pinned window is that family's only surface — or when the
    /// requested state is already active. Callers must honor the result: a
    /// rejected open presents nothing.
    @discardableResult
    mutating func openTransient(_ familyID: UUID, latched: Bool) -> Bool {
        guard mayOpenTransient(for: familyID) else { return false }
        pendingOpen = nil
        pendingClose = nil
        guard transientFamilyID != familyID || transientOrigin != (latched ? .explicit : .hover) else {
            return false
        }
        transientFamilyID = familyID
        transientOrigin = latched ? .explicit : .hover
        return true
    }

    /// Re-arms the pending dwell for another interval — the row stays hovered
    /// but the current surface is mid-interaction; a leave event still cancels.
    mutating func rearmPendingOpen(at now: TimeInterval) {
        guard let pending = pendingOpen else { return }
        pendingOpen = PendingOpen(
            familyID: pending.familyID,
            deadline: now + SubtaskPanelLayout.openDwell
        )
    }

    mutating func closeTransient() {
        transientFamilyID = nil
        pendingOpen = nil
        pendingClose = nil
    }

    /// Pinning is an explicit action: any other pinned window resolves to the
    /// newly pinned family and a same-family transient is promoted, never
    /// duplicated.
    mutating func pin(_ familyID: UUID) {
        pinnedFamilyID = familyID
        if transientFamilyID == familyID {
            transientFamilyID = nil
        }
        pendingOpen = nil
        pendingClose = nil
    }

    mutating func unpin() -> UUID? {
        let released = pinnedFamilyID
        pinnedFamilyID = nil
        return released
    }

    /// Idle hovers may coexist with the pinned window but never open a second
    /// surface for the already-pinned family.
    func mayOpenTransient(for familyID: UUID) -> Bool {
        pinnedFamilyID != familyID
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
