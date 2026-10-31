import AppKit
import SwiftUI

// Pull a page out, snap it back in (Planning.md, Accepted 2026-10-31
// "Tall island: switching pages"): a page dragged off the island becomes
// its own live panel; dropped on the island or near the docked panel's
// place, it docks again. This file holds the geometry and the state, both
// free of windows so they can be tested on their own.

extension PanelPage: Codable {}

// MARK: - Geometry

/// The pull-out's geometry (the design's px halved; `island-methods.js`).
enum PanelPullOutLayout {
    /// A press on an item becomes a pull after this much travel.
    static let pullThreshold: CGFloat = 6
    /// How near the pointer must come to the island, or the panel's
    /// top-left corner to the docked panel's, for a drop to dock it.
    static let snapDistance: CGFloat = 40
    /// A floating panel stays this far inside the work area.
    static let screenInset: CGFloat = 8
    /// Where the pointer holds a page pulled from the island, from the
    /// panel's top-left corner: the middle of its top row (the design's
    /// [320, 42]).
    static func grab(for size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: 21) }

    /// The out dot: 4 pt, 3 pt in from the item's top-right corner.
    static let outDot: CGFloat = 4
    static let outDotInset: CGFloat = 3
    /// The island's snap ring, outside its capsule.
    static let ringWidth: CGFloat = 2
    /// The landing outline's inset ring and its fill.
    static let outlineWidth: CGFloat = 2
    /// Attic blue, the design's rgb(0, 122, 255).
    static let blue = Color(.sRGB, red: 0, green: 122 / 255, blue: 1, opacity: 1)

    /// A panel of `size` held at `grab` (from its top-left) under `pointer`
    /// (screen points, y up).
    static func frame(under pointer: CGPoint, grab: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: pointer.x - grab.x, y: pointer.y + grab.y - size.height, width: size.width, height: size.height)
    }

    /// `frame` moved to stay `screenInset` inside `workArea`. A panel too
    /// big for it keeps its top-left corner in.
    static func clamp(_ frame: CGRect, to workArea: CGRect) -> CGRect {
        let area = workArea.insetBy(dx: screenInset, dy: screenInset)
        guard area.width > 0, area.height > 0 else { return frame }
        var result = frame
        result.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        let top = max(min(frame.maxY, area.maxY), min(area.maxY, area.minY + frame.height))
        result.origin.y = top - frame.height
        return result
    }

    enum Snap: Equatable { case island, home }

    /// Where a drop at `pointer` with the panel at `frame` docks it: the
    /// island (the pointer within `snapDistance` of it), the docked
    /// panel's place (the top-left corners within `snapDistance`), or nil.
    static func snap(pointer: CGPoint, frame: CGRect, island: CGRect?, home: CGRect?) -> Snap? {
        if let island, island.insetBy(dx: -snapDistance, dy: -snapDistance).contains(pointer) { return .island }
        if let home, hypot(frame.minX - home.minX, frame.maxY - home.maxY) < snapDistance { return .home }
        return nil
    }

    /// A saved frame on the screens there are now: on the work area it
    /// overlaps most (else the nearest), kept `screenInset` inside.
    static func restore(_ frame: CGRect, workAreas: [CGRect]) -> CGRect? {
        guard !workAreas.isEmpty, frame.width > 0, frame.height > 0 else { return nil }
        func overlap(_ area: CGRect) -> CGFloat {
            let common = area.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        func distance(_ area: CGRect) -> CGFloat {
            hypot(max(area.minX - frame.midX, 0, frame.midX - area.maxX), max(area.minY - frame.midY, 0, frame.midY - area.maxY))
        }
        let best = workAreas.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
            ?? workAreas.min { distance($0) < distance($1) }!
        var sized = frame
        sized.size.width = min(frame.width, max(best.width - 2 * screenInset, 0))
        sized.size.height = min(frame.height, max(best.height - 2 * screenInset, 0))
        sized.origin.y = frame.maxY - sized.height
        return clamp(sized, to: best)
    }
}

// MARK: - State

/// Which pages are out, where, and pinned or not; and which page the docked
/// panel showed before (it shows that one when its page leaves).
struct PanelPullOutState: Equatable {
    struct Floating: Codable, Equatable {
        var page: PanelPage
        var frame: CGRect
        var isPinned: Bool
    }

    /// The floating panels, back to front.
    private(set) var floating: [Floating] = []
    /// The docked panel's pages, as it showed them (latest last).
    private(set) var history: [PanelPage] = []

    var outPages: Set<PanelPage> { Set(floating.map(\.page)) }
    func isOut(_ page: PanelPage) -> Bool { floating.contains { $0.page == page } }
    func record(_ page: PanelPage) -> Floating? { floating.first { $0.page == page } }
    /// The front floating panel's page.
    var front: PanelPage? { floating.last?.page }

    /// The docked panel always keeps one page, so the last can't come out.
    func canPullOut(_ page: PanelPage) -> Bool {
        isOut(page) || PanelPage.allCases.contains { $0 != page && !isOut($0) }
    }

    /// The docked panel showed `page`.
    mutating func dockedShows(_ page: PanelPage) {
        history.removeAll { $0 == page }
        history.append(page)
        if history.count > PanelPage.allCases.count { history.removeFirst() }
    }

    /// The page the docked panel shows when `page` leaves it: the one it
    /// showed before, else the first that is still in.
    func fallback(for page: PanelPage) -> PanelPage? {
        history.reversed().first { $0 != page && !isOut($0) }
            ?? PanelPage.allCases.first { $0 != page && !isOut($0) }
    }

    /// `page` comes out at `frame`, in front. False when it can't.
    @discardableResult
    mutating func pullOut(_ page: PanelPage, at frame: CGRect, pinned: Bool = false) -> Bool {
        guard !isOut(page), canPullOut(page) else { return false }
        floating.append(Floating(page: page, frame: frame, isPinned: pinned))
        return true
    }

    mutating func move(_ page: PanelPage, to frame: CGRect) {
        guard let index = floating.firstIndex(where: { $0.page == page }) else { return }
        floating[index].frame = frame
    }

    mutating func setPinned(_ page: PanelPage, _ pinned: Bool) {
        guard let index = floating.firstIndex(where: { $0.page == page }) else { return }
        floating[index].isPinned = pinned
    }

    /// `page`'s panel comes in front of the other floating panels.
    mutating func raise(_ page: PanelPage) {
        guard let index = floating.firstIndex(where: { $0.page == page }), index != floating.count - 1 else { return }
        floating.append(floating.remove(at: index))
    }

    /// `page` docks again.
    mutating func dockIn(_ page: PanelPage) {
        floating.removeAll { $0.page == page }
    }

    /// What ⌘1–⌘4 (or a click on the island) does with `page`.
    enum Route: Equatable {
        /// The docked panel switches to it.
        case switchDocked
        /// Its own panel comes to the front and takes the keyboard.
        case raise
    }

    func route(for page: PanelPage) -> Route { isOut(page) ? .raise : .switchDocked }

    /// When the docked panel hides, a pinned floating panel stays on
    /// screen and an unpinned one hides; it comes back with the docked
    /// panel (the user, 31 Oct).
    func staysWhenDockedHides(_ page: PanelPage) -> Bool { record(page)?.isPinned ?? false }
    var hidingWithDocked: [PanelPage] { floating.filter { !$0.isPinned }.map(\.page) }

    /// The saved records on the screens there are now: one per page, never
    /// every page (the docked panel keeps one), each clamped to the work
    /// area it overlaps most.
    static func restored(_ records: [Floating], workAreas: [CGRect]) -> PanelPullOutState {
        var state = PanelPullOutState()
        for record in records {
            guard let frame = PanelPullOutLayout.restore(record.frame, workAreas: workAreas) else { continue }
            state.pullOut(record.page, at: frame, pinned: record.isPinned)
        }
        return state
    }

    // MARK: Saving

    static func decode(_ data: Data?) -> [Floating] {
        guard let data, let records = try? JSONDecoder().decode([Floating].self, from: data) else { return [] }
        return records
    }

    func encoded() -> Data? { try? JSONEncoder().encode(floating) }
}
