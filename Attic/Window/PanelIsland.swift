import AppKit
import Combine
import SwiftUI

// MARK: - Spot

/// Where the island sits around the docked panel (Planning.md, Accepted
/// 2026-11-01 "Island position: seven spots around the panel"), named by
/// the screen corner rather than by left and right, so a spot keeps its
/// meaning when the panel moves to another corner (the spots mirror).
/// - Screen side: between the panel and the screen's side edge.
/// - Open side: the panel's other side.
/// - Across the open end: lying flat, centred on the panel's edge away from
///   the screen's top or bottom edge.
/// Along a side, the corner end is the end nearest the screen corner, the
/// far end the other one.
enum PanelIslandSpot: String, CaseIterable, Codable, Identifiable {
    case screenSideCornerEnd
    case screenSideMiddle
    case screenSideFarEnd
    case openSideCornerEnd
    case openSideMiddle
    case openSideFarEnd
    case acrossOpenEnd
    /// The eighth spot (Accepted 2026-11-03, "The island, improved", the
    /// bottom default, reading (a)): flat under the panel in every corner.
    /// In a bottom corner it lies across the screen's bottom edge, and the
    /// panel moves up to make room; in a top corner it is "across the open
    /// end".
    case bottomEdge

    /// The island starts under the panel (the bottom default, reading (a)).
    static let defaultSpot: PanelIslandSpot = .bottomEdge

    /// The spots offered with the panel in `corner`: in a top corner the
    /// screen's bottom edge is the open end, so it is not a spot of its own.
    static func spots(in corner: ScreenCorner) -> [PanelIslandSpot] {
        PanelIslandLayout.isTop(corner) ? allCases.filter { $0 != .bottomEdge } : allCases
    }

    /// The spot this is with the panel in `corner` (the bottom edge is the
    /// open end in a top corner).
    func shown(in corner: ScreenCorner) -> PanelIslandSpot {
        self == .bottomEdge && PanelIslandLayout.isTop(corner) ? .acrossOpenEnd : self
    }

    func title(in corner: ScreenCorner) -> String { shown(in: corner).title }

    enum Side: Equatable { case screen, open, across }
    enum Position: Equatable { case cornerEnd, middle, farEnd }

    var id: String { rawValue }

    var side: Side {
        switch self {
        case .screenSideCornerEnd, .screenSideMiddle, .screenSideFarEnd: .screen
        case .openSideCornerEnd, .openSideMiddle, .openSideFarEnd: .open
        case .acrossOpenEnd, .bottomEdge: .across
        }
    }

    /// Along the panel's side (the across spot is always centred).
    var position: Position {
        switch self {
        case .screenSideCornerEnd, .openSideCornerEnd: .cornerEnd
        case .screenSideMiddle, .openSideMiddle, .acrossOpenEnd, .bottomEdge: .middle
        case .screenSideFarEnd, .openSideFarEnd: .farEnd
        }
    }

    /// The island lies flat (its items in a row).
    var isFlat: Bool { side == .across }

    /// What VoiceOver and the Settings row call it, e.g. "Open side, middle".
    var title: String {
        switch self {
        case .screenSideCornerEnd: String(localized: "Screen side, corner end")
        case .screenSideMiddle: String(localized: "Screen side, middle")
        case .screenSideFarEnd: String(localized: "Screen side, far end")
        case .openSideCornerEnd: String(localized: "Open side, corner end")
        case .openSideMiddle: String(localized: "Open side, middle")
        case .openSideFarEnd: String(localized: "Open side, far end")
        case .acrossOpenEnd: String(localized: "Across the open end")
        case .bottomEdge: String(localized: "Across the screen's bottom edge")
        }
    }
}

/// Which side of the island its name label shows on: always the panel's.
enum PanelIslandLabelSide: Equatable { case left, right, above, below }

// MARK: - Geometry

/// The Tall island's geometry (Planning.md, Accepted 2026-10-31 "Tall
/// island: switching pages"; the design's px halved): a 27 pt capsule
/// holding a 21 pt square item per page, 3 pt inset and 3 pt apart, 8 pt
/// from the screen's side edge and 8 pt from the panel, which docks that
/// much further in. It lines up with the panel's top in the top corners and
/// with its bottom in the bottom corners.
enum PanelIslandLayout {
    static let width: CGFloat = AtticControlSize.headerControl
    static let inset: CGFloat = AtticPageButtonMetrics.inset
    static let item: CGFloat = AtticPageButtonMetrics.segment
    static let gap: CGFloat = AtticPageButtonMetrics.gap
    /// From the work area's edge (the Dock's edge when it sits there):
    /// 10 pt (L2, was 8).
    static let edgeInset: CGFloat = 10
    /// Between the island and the panel: 6 pt (L2, was 8).
    static let panelGap: CGFloat = 6
    /// How far the panel's side edge sits from the work area's side edge
    /// (still 43 pt).
    static let panelSideInset: CGFloat = edgeInset + width + panelGap
    /// L3: standing at an end, the island sits 15.5 pt in from the panel's
    /// top (or bottom), so its first item's centre is level with Pin, •••
    /// and Search, 29 pt below the panel's top (mirrored at the bottom).
    /// Placed on whole points toward the panel's end (15 pt, 28.5 pt
    /// centres), so the window lands exactly where it is placed.
    static let endInset: CGFloat = 15.5
    /// L12: lying flat, the items are 25 × 21 (the capsule 115 × 27).
    static let flatItemWidth: CGFloat = 25

    // D4, dots at rest: a 13 × 43 capsule, a dot per page 10 pt apart, the
    // current page's 6 pt at full ink, the others 5 pt at 32 %.
    static let restThickness: CGFloat = 13
    static let restLength: CGFloat = 43
    static let restDot: CGFloat = 5
    static let restCurrentDot: CGFloat = 6
    static let restDotStep: CGFloat = 10
    static let restDotInk: Double = 0.32
    /// It wakes when the pointer comes within 16 pt.
    static let wakeDistance: CGFloat = 16
    /// It settles 800 ms after the pointer leaves.
    static let settleDelay: TimeInterval = 0.8
    /// L8: the first name waits 400 ms; another within 500 ms shows at once.
    static let labelDelay: TimeInterval = 0.4
    static let labelFollow: TimeInterval = 0.5
    /// The pop spring (200 ms, bounce 0.12): the chip's travel (L5) and the
    /// dots growing into their icons (D4).
    static let pop = AtticMotionSpring(response: 0.2, bounce: 0.12)

    @MainActor
    static func popAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? AtticMotionScale.reducedFade : .spring(duration: pop.response, bounce: pop.bounce)
    }

    /// L5: the chip slides on the pop spring; Reduce Motion fades it.
    static func chipTravels(reduceMotion: Bool) -> Bool { !reduceMotion }
    @MainActor
    static func chipAnimation(reduceMotion: Bool) -> Animation? { popAnimation(reduceMotion: reduceMotion) }

    /// An item's icon: 12.2 pt, Draw's `pencil.and.scribble` 11.5 (I6).
    static func iconSize(for page: PanelPage) -> CGFloat {
        page == .canvas ? 11.5 : AtticPageButtonMetrics.iconSize
    }

    /// L4, a contact shadow: a 0.5 pt edge at 10 %, 0 1 2 pt at 16 % and
    /// 0 6 16 pt at 16 % (Dark: 60 / 50 / 50 %).
    struct ContactShadow: Equatable {
        struct Layer: Equatable { var y: CGFloat; var blur: CGFloat; var opacity: Double }
        var edgeWidth: CGFloat
        var edgeOpacity: Double
        var layers: [Layer]
    }

    static func contactShadow(dark: Bool) -> ContactShadow {
        ContactShadow(edgeWidth: 0.5, edgeOpacity: dark ? 0.60 : 0.10,
                      layers: [.init(y: 1, blur: 2, opacity: dark ? 0.50 : 0.16),
                               .init(y: 6, blur: 16, opacity: dark ? 0.50 : 0.16)])
    }

    /// The name label beside an item: a 20 pt capsule of 11 pt medium text,
    /// 8 pt padding, 6 pt from the island on the panel's side, sliding in
    /// 4 pt from the island (the design's `labelR`, `labelT`).
    static let labelHeight: CGFloat = 20
    static let labelPadding: CGFloat = 8
    static let labelFontSize: CGFloat = 11
    static let labelGap: CGFloat = 6
    static let labelSlide: CGFloat = 4
    /// The label window's room for the longest page name.
    static let labelRoom: CGFloat = 120
    /// Transparent room around the island's capsule for its edge and its
    /// contact shadow (L4's deepest layer, 6 + 16 pt). It reaches over the
    /// panel; the margin passes the pointer through (`updatePassthrough`).
    static let windowMargin: CGFloat = 22

    static var pages: [PanelPage] { PanelPage.allCases }

    /// An item's icon face: every item in full ink (the design's `isl.ink`),
    /// the chip alone marking the current page (the owner's recording of
    /// build 1: the outline icons read faint).
    static func face(isSelected _: Bool, solid: Bool) -> (weight: Font.Weight, ink: AtticInk) {
        AtticPageButtonMetrics.glyphFace(isSelected: true, open: true, accent: false, solid: solid)
    }

    /// Whether a label fades as it goes (else it goes at once), with
    /// `pointed` the item under the pointer now.
    /// Pointing at another item takes the old label away at once, so only
    /// one name is ever on screen (the owner's recording of build 1).
    static func labelFadesOut(pointed: PanelPage?) -> Bool { pointed == nil }

    static func height(count: Int = PanelPage.allCases.count) -> CGFloat {
        2 * inset + CGFloat(count) * item + CGFloat(max(count - 1, 0)) * gap
    }

    /// Lying flat: 2 × 3 + 4 × 25 + 3 × 3 = 115 pt (L12).
    static func flatLength(count: Int = PanelPage.allCases.count) -> CGFloat {
        2 * inset + CGFloat(count) * flatItemWidth + CGFloat(max(count - 1, 0)) * gap
    }

    /// Whether a flat island lies under the panel (a top corner's open end,
    /// or the screen's bottom edge), not above it.
    static func liesBelowPanel(corner: ScreenCorner, spot: PanelIslandSpot) -> Bool {
        spot.isFlat && (isTop(corner) || spot == .bottomEdge)
    }

    /// Whether the island sits right of the panel (the right corners).
    static func isOnRight(_ corner: ScreenCorner) -> Bool {
        corner == .topRight || corner == .bottomRight
    }

    static func isTop(_ corner: ScreenCorner) -> Bool {
        corner == .topRight || corner == .topLeft
    }

    /// Whether the island sits right of the panel at `spot`.
    static func isRightOfPanel(corner: ScreenCorner, spot: PanelIslandSpot) -> Bool {
        spot.side == .open ? !isOnRight(corner) : isOnRight(corner)
    }

    /// The part of a work area the panel itself may use, so the island
    /// always fits beside it on screen, 8 pt from the edge at the least.
    /// - Screen side: the island's strip comes off the docked corner's side,
    ///   so a panel placed `screenInset` inside it sits `panelSideInset`
    ///   (43 pt) from that edge (Accepted "Tall island", "Placement").
    /// - Anywhere else the panel's side edge is the usual 12 pt in
    ///   (Accepted "Island position", "Spacing"), and the strip comes off
    ///   the far side or the open end instead, which only limits how large
    ///   the panel may grow.
    static func panelArea(in visibleFrame: CGRect, corner: ScreenCorner,
                          spot: PanelIslandSpot = .defaultSpot,
                          screenInset: CGFloat = PanelGeometry.screenInset) -> CGRect {
        let strip = max(0, panelSideInset - screenInset)
        var area = visibleFrame
        switch spot.side {
        case .screen, .open:
            let trim = min(strip, max(0, visibleFrame.width))
            area.size.width -= trim
            // The strip's side: the corner's for the screen side, else the other.
            if isOnRight(corner) != (spot.side == .screen) { area.origin.x += trim }
        case .across:
            let trim = min(strip, max(0, visibleFrame.height))
            area.size.height -= trim
            // Under the panel (a top corner's open end, the screen's bottom
            // edge): the strip comes off the bottom; above it, off the top.
            if liesBelowPanel(corner: corner, spot: spot) { area.origin.y += trim }
        }
        return area
    }

    /// The capsule's size: 27 × 99 standing, 115 × 27 lying flat.
    static func size(spot: PanelIslandSpot) -> CGSize {
        spot.isFlat ? CGSize(width: flatLength(), height: width) : CGSize(width: width, height: height())
    }

    /// The island's capsule in screen points at `spot` around `panelFrame`
    /// (the panel's visible surface) docked in `corner`: 8 pt from the
    /// panel; along a side at its corner end, middle or far end, or flat
    /// and centred across its open end.
    static func islandFrame(panelFrame: CGRect, corner: ScreenCorner,
                            spot: PanelIslandSpot = .defaultSpot) -> CGRect {
        let size = size(spot: spot)
        let top = isTop(corner)
        if spot.isFlat {
            let y = liesBelowPanel(corner: corner, spot: spot) ? panelFrame.minY - panelGap - size.height : panelFrame.maxY + panelGap
            let x = wholePoint(panelFrame.midX - size.width / 2, towardMax: isOnRight(corner))
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        let x = isRightOfPanel(corner: corner, spot: spot) ? panelFrame.maxX + panelGap : panelFrame.minX - panelGap - size.width
        let atTop = wholePoint(panelFrame.maxY - endInset - size.height, towardMax: true)
        let atBottom = wholePoint(panelFrame.minY + endInset, towardMax: false)
        let y: CGFloat = switch spot.position {
        case .cornerEnd: top ? atTop : atBottom
        case .middle: wholePoint(panelFrame.midY - size.height / 2, towardMax: top)
        case .farEnd: top ? atBottom : atTop
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// A centred spot on whole points, so its window lands exactly where it
    /// is placed, rounded toward the screen corner so the spots still mirror
    /// exactly from corner to corner.
    private static func wholePoint(_ value: CGFloat, towardMax: Bool) -> CGFloat {
        value.rounded(towardMax ? .up : .down)
    }

    /// The gap between the panel and the island, as long as the island:
    /// crossing it from the panel to the island stays on the panel.
    static func gapFrame(panelFrame: CGRect, corner: ScreenCorner,
                         spot: PanelIslandSpot = .defaultSpot) -> CGRect {
        let island = islandFrame(panelFrame: panelFrame, corner: corner, spot: spot)
        if spot.isFlat {
            let y = liesBelowPanel(corner: corner, spot: spot) ? island.maxY : panelFrame.maxY
            return CGRect(x: island.minX, y: y, width: island.width, height: panelGap)
        }
        let x = isRightOfPanel(corner: corner, spot: spot) ? panelFrame.maxX : island.maxX
        return CGRect(x: x, y: island.minY, width: panelGap, height: island.height)
    }

    /// An item's square in screen points: top to bottom, or left to right
    /// in a flat island (wider than tall), in the pages' order.
    static func itemFrame(_ index: Int, in island: CGRect) -> CGRect {
        if island.width > island.height {
            let step = CGFloat(index) * (flatItemWidth + gap)
            return CGRect(x: island.minX + inset + step, y: island.minY + inset, width: flatItemWidth, height: item)
        }
        let step = CGFloat(index) * (item + gap)
        return CGRect(x: island.minX + inset, y: island.maxY - inset - item - step, width: item, height: item)
    }

    /// The side of the island its label shows on: the panel's (Accepted
    /// "Island position": "The name label shows on the panel's side").
    static func labelSide(corner: ScreenCorner, spot: PanelIslandSpot = .defaultSpot) -> PanelIslandLabelSide {
        if spot.isFlat { return liesBelowPanel(corner: corner, spot: spot) ? .above : .below }
        return isRightOfPanel(corner: corner, spot: spot) ? .left : .right
    }

    /// D4: the capsule at rest, 13 × 43 (43 × 13 lying flat), on the
    /// panel's side of the island and at the end the island lines up with
    /// (centred in the middle and lying flat).
    static func restFrame(island: CGRect, corner: ScreenCorner, spot: PanelIslandSpot) -> CGRect {
        if spot.isFlat {
            let y = liesBelowPanel(corner: corner, spot: spot) ? island.maxY - restThickness : island.minY
            return CGRect(x: island.midX - restLength / 2, y: y, width: restLength, height: restThickness)
        }
        let x = isRightOfPanel(corner: corner, spot: spot) ? island.minX : island.maxX - restThickness
        let top = isTop(corner)
        let y: CGFloat = switch spot.position {
        case .cornerEnd: top ? island.maxY - restLength : island.minY
        case .middle: island.midY - restLength / 2
        case .farEnd: top ? island.minY : island.maxY - restLength
        }
        return CGRect(x: x, y: y, width: restThickness, height: restLength)
    }

    /// A page's dot at rest: its size, its ink and its centre along the
    /// rest capsule from its start (the top, or the left lying flat).
    struct RestDot: Equatable {
        var diameter: CGFloat
        var ink: Double
        var along: CGFloat
    }

    static func restDots(current: Int, count: Int = PanelPage.allCases.count) -> [RestDot] {
        (0..<count).map { index in
            RestDot(diameter: index == current ? restCurrentDot : restDot, ink: index == current ? 1 : restDotInk,
                    along: restThickness / 2 + CGFloat(index) * restDotStep)
        }
    }

    /// The label window, on the panel's side: beside a standing island and
    /// as tall as it, or over the panel above or below a flat one, wide
    /// enough for a name centred on either end item.
    static func labelWindowFrame(island: CGRect, corner: ScreenCorner,
                                 spot: PanelIslandSpot = .defaultSpot) -> CGRect {
        switch labelSide(corner: corner, spot: spot) {
        case .left: return CGRect(x: island.minX - labelGap - labelRoom, y: island.minY, width: labelRoom, height: island.height)
        case .right: return CGRect(x: island.maxX + labelGap, y: island.minY, width: labelRoom, height: island.height)
        case .above, .below:
            let width = island.width + labelRoom
            let y = labelSide(corner: corner, spot: spot) == .above ? island.maxY + labelGap : island.minY - labelGap - labelHeight
            return CGRect(x: island.midX - width / 2, y: y, width: width, height: labelHeight)
        }
    }

    /// How the island's stand-in keeps its place on the surface as the
    /// panel resizes (the motion layer is not flipped).
    static func standInResizing(corner: ScreenCorner, spot: PanelIslandSpot = .defaultSpot) -> NSView.AutoresizingMask {
        let top = isTop(corner)
        if spot.isFlat { return [.minXMargin, .maxXMargin, liesBelowPanel(corner: corner, spot: spot) ? .maxYMargin : .minYMargin] }
        let x: NSView.AutoresizingMask = isRightOfPanel(corner: corner, spot: spot) ? .minXMargin : .maxXMargin
        switch spot.position {
        case .middle: return [x, .minYMargin, .maxYMargin]
        case .cornerEnd: return [x, top ? .minYMargin : .maxYMargin]
        case .farEnd: return [x, top ? .maxYMargin : .minYMargin]
        }
    }

    /// The point the panel and the island hide into and grow back out of:
    /// the corner of the two together nearest the screen corner (Accepted
    /// "Island position", "Hiding and showing as one shape still holds").
    static func collapseAnchor(panelFrame: CGRect, corner: ScreenCorner,
                               spot: PanelIslandSpot = .defaultSpot) -> CGPoint {
        let union = panelFrame.union(islandFrame(panelFrame: panelFrame, corner: corner, spot: spot))
        return PanelCollapseGeometry.cornerPoint(of: union, corner: corner)
    }
}

// MARK: - Model

/// What the island shows and what it asks of the panel. The panel's page
/// switch path (`AtticPanelView.selectPage`) answers `requests`, so a click
/// on the island goes through the same signposts, Notes' `present()` and
/// the composer's kept drafts as every other switch.
@MainActor
final class PanelIslandModel: ObservableObject {
    @Published private(set) var page: PanelPage = .tasks
    /// The item under the pointer. Never switches.
    @Published private(set) var pointed: PanelPage?
    /// The item whose name label shows (L8): the first after 400 ms, the
    /// next at once while one shows or went less than 500 ms ago.
    @Published private(set) var labelPage: PanelPage?
    /// D4: awake, the island draws its items; at rest, a dot per page.
    @Published private(set) var isAwake = false
    /// Where the island sits, for the rest capsule's place.
    @Published private(set) var corner: ScreenCorner = .topRight
    @Published private(set) var spot: PanelIslandSpot = .defaultSpot
    /// Which side of the island faces the panel (the label goes there).
    @Published private(set) var labelSide: PanelIslandLabelSide = .left
    /// The island lies flat, its items in a row (the across spot).
    @Published private(set) var isFlat = false
    var labelOnLeft: Bool { labelSide == .left }
    /// The pages pulled out into their own panels: their items carry the
    /// out dot (Accepted "Tall island", "Pull a page out, snap it back in").
    @Published private(set) var outPages: Set<PanelPage> = []
    /// A floating panel dragged near: the island shows its blue ring.
    @Published private(set) var isSnapTarget = false
    /// A drag pulled a page off the island: the press's release is not a
    /// click.
    var suppressesClicks = false

    /// A click asked for this page.
    let requests = PassthroughSubject<PanelPage, Never>()
    /// The pointer came onto the island: the panel can build its pages early.
    let approaches = PassthroughSubject<Void, Never>()
    /// Before a click's request: the panel becomes active (one click).
    var onClick: (() -> Void)?

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Bumped to cancel a scheduled label or settle.
    private var labelTurn = 0
    private var settleTurn = 0
    private var labelHiddenAt: Date?
    /// Whether the pointer was within the wake zone at its last move.
    private var pointerNear = false
    /// A pull off the island is under way: it stays awake.
    var isPulling = false {
        didSet { if isPulling { wake() } else if oldValue { settleIfAway() } }
    }

    init(now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, run in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run() }
         }) {
        self.now = now
        self.schedule = schedule
    }

    var onOpenInOwnPanel: ((PanelPage) -> Void)?
    var onPutBack: ((PanelPage) -> Void)?

    /// The menu and VoiceOver run these same commands. A page already out
    /// is raised; the last docked page cannot leave.
    func commands(for page: PanelPage) -> [AtticMenuCommand] {
        let out = outPages.contains(page)
        var commands = [AtticMenuCommand("Open in Own Panel",
            isDisabled: !out && outPages.count >= PanelPage.allCases.count - 1) { [weak self] in
                self?.onOpenInOwnPanel?(page)
            }]
        if out {
            commands.append(AtticMenuCommand("Put Back") { [weak self] in self?.onPutBack?(page) })
        }
        return commands
    }

    func show(_ page: PanelPage) {
        if self.page != page { self.page = page }
    }

    func setOut(_ pages: Set<PanelPage>) {
        if outPages != pages { outPages = pages }
    }

    /// A page dragged out or back near the island: its ring shows, and the
    /// island stays awake while it does.
    func setSnapTarget(_ target: Bool) {
        if isSnapTarget != target { isSnapTarget = target }
        if target { wake() } else { settleIfAway() }
    }

    func setCorner(_ corner: ScreenCorner, spot: PanelIslandSpot = .defaultSpot) {
        let side = PanelIslandLayout.labelSide(corner: corner, spot: spot)
        if labelSide != side { labelSide = side }
        if isFlat != spot.isFlat { isFlat = spot.isFlat }
        if self.corner != corner { self.corner = corner }
        if self.spot != spot { self.spot = spot }
    }

    /// The pointer is over `page`'s item (nil: over none).
    func point(at page: PanelPage?) {
        if pointed == nil, page != nil { approaches.send() }
        if pointed != page { pointed = page }
        labelTurn &+= 1
        guard let page else {
            if labelPage != nil {
                labelPage = nil
                labelHiddenAt = now()
            }
            return
        }
        wake()
        let recently = labelHiddenAt.map { now().timeIntervalSince($0) < PanelIslandLayout.labelFollow } ?? false
        if labelPage != nil || recently {
            if labelPage != page { labelPage = page }
            return
        }
        let turn = labelTurn
        schedule(PanelIslandLayout.labelDelay) { [weak self] in
            guard let self, self.labelTurn == turn, self.pointed == page else { return }
            self.labelPage = page
        }
    }

    /// The pointer left `page`'s item (another item may have it already).
    func leave(_ page: PanelPage) {
        if pointed == page { point(at: nil) }
    }

    func click(_ page: PanelPage) {
        wake()
        guard !suppressesClicks else { return }
        onClick?()
        requests.send(page)
    }

    // MARK: Resting and waking (D4)

    func wake() {
        settleTurn &+= 1
        if !isAwake { isAwake = true }
    }

    /// The pointer moved: within 16 pt of the capsule as it is now, the
    /// island wakes; away from it, it settles 800 ms later.
    func track(pointer: CGPoint, rest: CGRect, awake: CGRect) {
        let zone = (isAwake ? awake : rest).insetBy(dx: -PanelIslandLayout.wakeDistance, dy: -PanelIslandLayout.wakeDistance)
        let near = zone.contains(pointer)
        let wasNear = pointerNear
        pointerNear = near
        if near {
            wake()
        } else if wasNear || isAwake {
            settleIfAway()
        }
    }

    /// Settles in 800 ms unless something holds it awake by then.
    private func settleIfAway() {
        guard isAwake, !pointerNear, !isSnapTarget, !isPulling else { return }
        settleTurn &+= 1
        let turn = settleTurn
        schedule(PanelIslandLayout.settleDelay) { [weak self] in
            guard let self, self.settleTurn == turn, !self.pointerNear, !self.isSnapTarget, !self.isPulling else { return }
            self.settle()
        }
    }

    /// At rest now (the panel hid, or the settle delay ran out).
    func settle() {
        settleTurn &+= 1
        pointerNear = false
        if pointed != nil { point(at: nil) }
        if isAwake { isAwake = false }
    }
}

// MARK: - Views

/// The island (Accepted 2026-10-31 "Tall island", improved 2026-11-03): a
/// capsule in the panel's own surface with an item per page, the current
/// page on the grey selection chip, which travels to a new page on the pop
/// spring (L5). Not in use and not pointed at, it rests as dots, one per
/// page, in a narrow capsule on the panel's side (D4); waking, each dot
/// travels to its item's place and grows into its icon. VoiceOver reads
/// "Pages" with a named button per page, the current one selected.
struct PanelIslandView: View {
    @ObservedObject var model: PanelIslandModel
    @ObservedObject var focusTracker: AtticKeyboardFocusTracker
    /// The stand-in that flies with the panel's hide and reveal: the same
    /// drawing, but nothing to press, point at, focus or hear.
    var isStandIn = false

    @Environment(\.atticDesign) private var design
    @Environment(\.atticControlCornerExponent) private var cornerExponent
    @FocusState private var focused: PanelPage?

    private typealias L = PanelIslandLayout

    private var size: CGSize {
        model.isFlat ? CGSize(width: L.flatLength(), height: L.width) : CGSize(width: L.width, height: L.height())
    }

    /// A screen-point rect in the capsule's own top-left coordinates.
    private func local(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: size) }

    private func itemRect(_ index: Int) -> CGRect { local(L.itemFrame(index, in: bounds)) }

    private var restRect: CGRect { local(L.restFrame(island: bounds, corner: model.corner, spot: model.spot)) }

    /// A page's dot at rest, in the capsule's coordinates.
    private func dotCentre(_ index: Int, dots: [L.RestDot]) -> CGPoint {
        let rest = restRect
        return model.isFlat ? CGPoint(x: rest.minX + dots[index].along, y: rest.midY)
            : CGPoint(x: rest.midX, y: rest.minY + dots[index].along)
    }

    var body: some View {
        let reduceMotion = design.reduceMotion
        Group {
            if reduceMotion {
                // Reduce Motion: it fades between the two; the one showing
                // takes the pointer and VoiceOver (at rest too, as without
                // Reduce Motion).
                ZStack(alignment: .topLeading) {
                    drawing(awake: false, interactive: !isStandIn && !model.isAwake)
                        .opacity(model.isAwake ? 0 : 1)
                        .accessibilityHidden(model.isAwake)
                    drawing(awake: true, interactive: !isStandIn && model.isAwake)
                        .opacity(model.isAwake ? 1 : 0)
                        .accessibilityHidden(!model.isAwake)
                }
                .animation(AtticMotionScale.reducedFade, value: model.isAwake)
            } else {
                drawing(awake: model.isAwake, interactive: !isStandIn)
                    .animation(L.popAnimation(reduceMotion: false), value: model.isAwake)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay {
            // A floating panel dragged near: a solid blue ring (the
            // design's 4 px at 55 %, outside the capsule).
            AtticControlShape.shape(cornerRadius: AtticRadius.header + PanelPullOutLayout.ringWidth, exponent: cornerExponent)
                .strokeBorder(PanelPullOutLayout.blue.opacity(0.55), lineWidth: PanelPullOutLayout.ringWidth)
                .padding(-PanelPullOutLayout.ringWidth)
                .opacity(model.isSnapTarget ? 1 : 0)
                .animation(AtticMotionPreset.popover.animation(reduceMotion: reduceMotion,
                                                               showing: model.isSnapTarget), value: model.isSnapTarget)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(L.windowMargin)
        .onChange(of: focused) { _, now in if now != nil { model.wake() } }
        .accessibilityElement(children: isStandIn ? .ignore : .contain)
        .accessibilityLabel(String(localized: "Pages"))
        .accessibilityIdentifier(isStandIn ? "" : "panel-section-picker")
        .accessibilityHidden(isStandIn)
        .allowsHitTesting(!isStandIn)
    }

    /// The island awake (its items) or at rest (its dots).
    private func drawing(awake: Bool, interactive: Bool) -> some View {
        let radius = AtticRadius.header
        let chipRadius = AtticRadius.nested(outer: radius, gap: L.inset) ?? radius
        let current = L.pages.firstIndex(of: model.page) ?? 0
        let dots = L.restDots(current: current)
        let capsule = awake ? bounds : restRect
        let travels = L.chipTravels(reduceMotion: design.reduceMotion)
        return ZStack(alignment: .topLeading) {
            PanelIslandSurface(cornerRadius: min(radius, min(capsule.width, capsule.height) / 2))
                .frame(width: capsule.width, height: capsule.height)
                .offset(x: capsule.minX, y: capsule.minY)
            // L5: one chip, travelling from the old item to the new one.
            if travels {
                let chip = itemRect(current)
                AtticSelectionMarker(cornerRadius: chipRadius)
                    .frame(width: chip.width, height: chip.height)
                    .offset(x: chip.minX, y: chip.minY)
                    .opacity(awake ? 1 : 0)
                    .animation(L.chipAnimation(reduceMotion: false), value: model.page)
                    .allowsHitTesting(false)
            }
            ForEach(Array(L.pages.enumerated()), id: \.element) { index, page in
                let rect = itemRect(index)
                Group {
                    if interactive {
                        item(page, index: index, awake: awake, dots: dots, chipRadius: chipRadius, chips: !travels)
                    } else {
                        face(page, index: index, awake: awake, dots: dots, chipRadius: chipRadius, chips: !travels)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// An item as drawn: the hover fill (and under Reduce Motion its own
    /// chip), and its mark: a dot at rest that travels to the item's place
    /// and grows into the icon awake (D4), with the out dot.
    private func face(_ page: PanelPage, index: Int, awake: Bool, dots: [L.RestDot], chipRadius: CGFloat,
                      chips: Bool) -> some View {
        let isSelected = page == model.page
        let shape = AtticControlShape.shape(cornerRadius: chipRadius, exponent: cornerExponent)
        let rect = itemRect(index)
        let dot = dots[index]
        let centre = dotCentre(index, dots: dots)
        let offset = awake ? CGSize.zero : CGSize(width: centre.x - rect.midX, height: centre.y - rect.midY)
        let iconSize = L.iconSize(for: page)
        let faceStyle = L.face(isSelected: isSelected, solid: design.effectiveSurface == .solid)
        let out = model.outPages.contains(page)
        let ink = design.tokens.ink(faceStyle.ink).color
        return ZStack {
            if awake, chips, isSelected {
                AtticSelectionMarker(cornerRadius: chipRadius)
                    .transition(AtticSelectionMarker.transition)
            } else if awake, model.pointed == page, !isSelected {
                shape.fill(AtticSelectionMarker.hoverFill(design.tokens).color)
            }
            ZStack {
                Circle()
                    .fill(out ? PanelPullOutLayout.blue : ink)
                    .frame(width: dot.diameter, height: dot.diameter)
                    .scaleEffect(awake ? iconSize / dot.diameter : 1)
                    .opacity(awake ? 0 : (out ? 1 : dot.ink))
                AtticIcon(systemName: page.systemName, size: iconSize, weight: faceStyle.weight, ink: faceStyle.ink)
                    .scaleEffect(awake ? 1 : dot.diameter / iconSize)
                    .opacity(awake ? 1 : 0)
            }
            .offset(offset)
            // A page that's out: a 4 pt blue dot at the item's top-right
            // corner (the design's 8 px, 6 px in); at rest its dot is blue.
            Circle()
                .fill(PanelPullOutLayout.blue)
                .frame(width: PanelPullOutLayout.outDot, height: PanelPullOutLayout.outDot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(PanelPullOutLayout.outDotInset)
                .opacity(awake && out ? 1 : 0)
                .accessibilityHidden(true)
        }
        .animation(AtticSelectionMarker.animation(reduceMotion: design.reduceMotion), value: isSelected)
        .animation(L.popAnimation(reduceMotion: design.reduceMotion), value: model.page)
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
    }

    private func item(_ page: PanelPage, index: Int, awake: Bool, dots: [L.RestDot], chipRadius: CGFloat,
                      chips: Bool) -> some View {
        let isSelected = page == model.page
        return Button { model.click(page) } label: {
            face(page, index: index, awake: awake, dots: dots, chipRadius: chipRadius, chips: chips)
        }
        .buttonStyle(.plain)
        .focused($focused, equals: page)
        .focusEffectDisabled()
        // Outlines are for keyboard focus only (Owner notes on
        // Attic Wave 2, "No outline from a click").
        .atticFocusRing(focused == page && focusTracker.isKeyboardDriving, cornerRadius: chipRadius)
        .onHover { inside in
            if inside { model.point(at: page) } else { model.leave(page) }
        }
        // At rest the dots take no pointer: coming near wakes the island.
        .allowsHitTesting(awake)
        .atticContextMenu { model.commands(for: page) }
        .accessibilityActions {
            // SwiftUI prepends custom actions to AppKit's rotor list.
            ForEach(Array(model.commands(for: page).filter { !$0.isDisabled }.reversed())) { command in
                Button(command.title, action: command.action)
            }
        }
        .accessibilityLabel(page.title)
        .accessibilityValue(model.outPages.contains(page) ? String(localized: "In its own panel") : "")
        .accessibilityIdentifier(page.accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The island wears the panel's own surface (Accepted 2026-11-03, "The
/// panel's appearance"): Palette, Surface, Tint and Tint length from
/// Settings › Appearance, with the panel's rim, in the island's curve 1.4
/// shape, over L4's contact shadow.
private struct PanelIslandSurface: View {
    let cornerRadius: CGFloat

    @Environment(\.atticDesign) private var design

    var body: some View {
        let shape = Squircle(cornerRadius: cornerRadius, exponent: AtticShape.controlExponent)
        let shadow = PanelIslandLayout.contactShadow(dark: design.mode == .dark)
        AtticSurfaceBackground(model: design.tokens.panel, shape: shape)
            .overlay { AtticPanelRim(cornerSize: cornerRadius, exponent: AtticShape.controlExponent) }
            .background {
                // L4: the layers fall outside the capsule only, so a
                // see-through surface never darkens.
                ZStack {
                    ForEach(Array(shadow.layers.enumerated()), id: \.offset) { _, layer in
                        shape.fill(Color.black)
                            .shadow(color: .black.opacity(layer.opacity), radius: layer.blur / 2, x: 0, y: layer.y)
                    }
                    shape.inset(by: -shadow.edgeWidth / 2)
                        .stroke(Color.black.opacity(shadow.edgeOpacity), lineWidth: shadow.edgeWidth)
                }
                .mask {
                    Rectangle()
                        .padding(-PanelIslandLayout.windowMargin)
                        .overlay { shape.blendMode(.destinationOut) }
                        .compositingGroup()
                }
                .allowsHitTesting(false)
            }
            .contentShape(shape)
            .accessibilityHidden(true)
    }
}

/// The name labels, one per item row, in a window that never takes the
/// pointer. Only the pointed item's shows; it slides 4 pt in from the
/// island on the popover motion (Reduce Motion: a fade).
struct PanelIslandLabels: View {
    @ObservedObject var model: PanelIslandModel

    @Environment(\.atticDesign) private var design
    @Environment(\.atticControlCornerExponent) private var cornerExponent

    private typealias L = PanelIslandLayout

    var body: some View {
        Group {
            if model.isFlat {
                // Over the panel, each name centred over its item.
                HStack(spacing: L.gap) {
                    ForEach(L.pages) { page in
                        label(page).frame(width: L.flatItemWidth, height: L.labelHeight)
                    }
                }
                .frame(width: L.flatLength() + L.labelRoom, height: L.labelHeight)
            } else {
                let alignment: Alignment = model.labelSide == .left ? .trailing : .leading
                VStack(spacing: L.gap) {
                    ForEach(L.pages) { page in
                        label(page)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                            .frame(height: L.item)
                    }
                }
                .padding(.vertical, L.inset)
                .frame(width: L.labelRoom, height: L.height())
            }
        }
        .allowsHitTesting(false)
    }

    /// A page's name: it slides in 4 pt from the island's side.
    private func label(_ page: PanelPage) -> some View {
        // L8: the first name waits; awake only (D4).
        let shown = model.labelPage == page && model.isAwake
        let towardIsland: CGSize = switch model.labelSide {
        case .left: CGSize(width: L.labelSlide, height: 0)
        case .right: CGSize(width: -L.labelSlide, height: 0)
        case .above: CGSize(width: 0, height: L.labelSlide)
        case .below: CGSize(width: 0, height: -L.labelSlide)
        }
        return Text(page.title)
            .font(.system(size: L.labelFontSize, weight: .medium))
            .foregroundStyle(design.tokens.ink(.heading).color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, L.labelPadding)
            .frame(height: L.labelHeight)
            .modifier(PanelIslandLabelSurface(flat: design.effectiveControls != .liquidGlass,
                                              cornerRadius: L.labelHeight / 2))
            .opacity(shown ? 1 : 0)
            .offset(shown ? .zero : towardIsland)
            .animation(shown || L.labelFadesOut(pointed: model.labelPage)
                       ? AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: shown) : nil,
                       value: shown)
            .accessibilityHidden(true)
    }
}

/// The name label's own surface: the controls' glass (or their flat look).
private struct PanelIslandLabelSurface: ViewModifier {
    let flat: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if flat {
            content.atticFlatSurface(cornerRadius: cornerRadius)
        } else {
            content.atticRaisedMaterial(cornerRadius: cornerRadius, interactive: true)
        }
    }
}

/// The island's own environment: the panel's design system, theme and
/// corners, read from the same settings and key state as the panel.
private struct PanelIslandRoot<Content: View>: View {
    @ObservedObject var settings: AppSettings
    let isPanelKey: Bool
    let content: Content

    var body: some View {
        content
            .atticDesignCorners()
            .environment(\.controlActiveState, .key)
            .atticDesignFromSystem(
                palette: settings.panelTheme,
                surface: settings.panelSurfaceStyle,
                tint: settings.panelTint,
                tintLength: settings.panelTintLength,
                hapticsEnabled: settings.panelHapticsEnabled,
                animations: settings.animations,
                controls: PanelKeyTreatment.controls(isPanelKey: isPanelKey, surface: settings.panelSurfaceStyle),
                motion: settings.motionTuning
            )
            .atticWindowAppearance(settings.appearance.designMode)
    }
}

/// Feeds the root the panel's key state without observing all of
/// `PanelUIState` (whose other changes must not redraw the island).
private struct PanelIslandKeyed<Content: View>: View {
    let settings: AppSettings
    let model: PanelIslandModel
    let uiState: PanelUIState
    let content: Content
    @State private var isPanelKey = false

    var body: some View {
        PanelIslandRoot(settings: settings, isPanelKey: isPanelKey, content: content)
            .onReceive(uiState.$isPanelKey.removeDuplicates()) { if isPanelKey != $0 { isPanelKey = $0 } }
    }
}

// MARK: - Windows

/// The island's windows: a borderless, non-activating panel like the
/// Attic panel, at its level and on all its Spaces.
final class PanelIslandWindow: NSPanel {
    /// The island can take the keyboard (Full Keyboard Access, VoiceOver);
    /// the label window never can.
    var allowsKey = false
    /// The left button's presses, drags and releases, in screen points,
    /// before SwiftUI sees them (pulling a page off the island).
    var onPointer: ((PanelIslandPointer) -> Void)?

    private var pressing = false
    private var trackedRelease = false

    override func nextEvent(matching mask: NSEvent.EventTypeMask) -> NSEvent? {
        let event = super.nextEvent(matching: mask)
        recordRelease(event)
        return event
    }
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode,
                            dequeue deqFlag: Bool) -> NSEvent? {
        let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: deqFlag)
        if deqFlag { recordRelease(event) }
        return event
    }
    private func recordRelease(_ event: NSEvent?) {
        if let event, [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) { trackedRelease = true }
    }

    override func sendEvent(_ event: NSEvent) {
        if AtticPanel.takesFirstPress(event.type) {
            pressing = true; trackedRelease = false
            (parent as? AtticPanel)?.beginFirstPress()
        }
        defer {
            if pressing, NSEvent.pressedMouseButtons == 0,
               (AtticPanel.takesFirstPress(event.type) && trackedRelease)
                || [.leftMouseUp, .rightMouseUp, .otherMouseUp, .mouseMoved, .keyDown].contains(event.type) {
                pressing = false; trackedRelease = false
                (parent as? AtticPanel)?.finishFirstPress()
                PanelActivation.shared.released(in: self)
            }
        }
        let point = convertPoint(toScreen: event.locationInWindow)
        // Whatever view a press hits takes it (one click always registers).
        if AtticPanel.takesFirstPress(event.type) { AtticFirstPress.prepare(event, in: self) }
        switch event.type {
        case .leftMouseDown: onPointer?(.down(point))
        case .leftMouseDragged: onPointer?(.dragged(point))
        case .leftMouseUp:
            super.sendEvent(event)
            onPointer?(.up(point))
            return
        default: break
        }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { allowsKey && !TestPresentationPolicy.isInvisible }
    override var canBecomeMain: Bool { !TestPresentationPolicy.isInvisible && PanelActivation.shared.isActivationWindow(self) }
    /// Draws with the parent's native appearance, so the island's glass
    /// matches the panel without taking its keyboard. The docked panel
    /// keeps glass active even before a click (owner, 3 Nov). AppKit asks
    /// the window it is in, and a child window that is never key always
    /// answers inactive; SwiftUI's `appearsActive`/`controlActiveState` and
    /// an `isKeyWindow` override do not reach it (measured on macOS 26.4).
    /// Only the look changes: the window still never becomes key or main,
    /// and the keyboard stays with the panel. AppKit asks again whenever
    /// the parent's key state changes and when the window is ordered in
    /// attached (`show(attachedTo:)` attaches before it orders in).
    @objc func _hasActiveAppearance() -> Bool {
        (parent as? AtticPanel)?._hasActiveAppearance() ?? (parent?.isKeyWindow ?? false)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Clicks are routed by the island's own passthrough, never by its
    // drawn alpha: its content is see-through while the panel's motion
    // draws the island (`AtticMousePolicy`).
    private var mousePolicy = AtticMousePolicy()

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place == .out { mousePolicy.orderedOut() }
        super.order(place, relativeTo: otherWin)
        if place != .out { mousePolicy.orderedIn(self) }
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        mousePolicy.orderedIn(self)
    }

    override func orderOut(_ sender: Any?) {
        mousePolicy.orderedOut()
        super.orderOut(sender)
    }
}

extension PanelIslandWindow: AtticFirstPressWindow {}

enum PanelIslandPointer: Equatable {
    case down(CGPoint), dragged(CGPoint), up(CGPoint)
}

/// A pull off the island, as the pull-out sees it.
enum PanelIslandPull: Equatable {
    case began(PanelPage, CGPoint), moved(CGPoint), ended(CGPoint)
}

/// Turns presses on the island's items into pulls: a press on an item that
/// travels more than `PanelPullOutLayout.pullThreshold` pulls that page.
struct PanelIslandPullTracker {
    private var pressed: (page: PanelPage, start: CGPoint)?
    private(set) var pulling = false

    /// What `pointer` does, given the island's capsule (screen points).
    mutating func handle(_ pointer: PanelIslandPointer, island: CGRect) -> PanelIslandPull? {
        switch pointer {
        case let .down(point):
            pulling = false
            pressed = Self.page(at: point, in: island).map { ($0, point) }
            return nil
        case let .dragged(point):
            if pulling { return .moved(point) }
            guard let pressed, hypot(point.x - pressed.start.x, point.y - pressed.start.y)
                    > PanelPullOutLayout.pullThreshold else { return nil }
            pulling = true
            return .began(pressed.page, point)
        case let .up(point):
            defer { pressed = nil; pulling = false }
            return pulling ? .ended(point) : nil
        }
    }

    static func page(at point: CGPoint, in island: CGRect) -> PanelPage? {
        PanelIslandLayout.pages.indices.first { PanelIslandLayout.itemFrame($0, in: island).contains(point) }
            .map { PanelIslandLayout.pages[$0] }
    }
}

/// A click on the island works on its first press, whichever app is active.
private final class PanelIslandHostingView<Root: View>: NSHostingView<Root> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The island's stand-in in the panel's motion layer: never hit, never an
/// accessibility element, so at rest the island windows stay the live
/// island.
private final class PanelIslandStandInHostingView<Root: View>: NSHostingView<Root> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
}

/// The island and its label, child windows of the Attic panel (Accepted
/// "Tall island": "it shows, hides and moves with the panel"). The panel's
/// controller places them from the panel's frame and shows and hides them
/// with it; while the panel moves, its motion layer draws the island (the
/// stand-in) and the windows' content steps aside at once.
@MainActor
final class PanelIslandWindows {
    let model: PanelIslandModel
    let island: PanelIslandWindow
    let label: PanelIslandWindow
    private(set) var corner: ScreenCorner = .topRight
    private(set) var spot: PanelIslandSpot = .defaultSpot
    /// The capsule awake, in screen points (not the window's margin).
    private(set) var islandFrame: CGRect = .zero
    /// The capsule at rest (D4).
    private(set) var restFrame: CGRect = .zero
    /// The capsule as it is now: awake, or at rest.
    var capsuleFrame: CGRect { model.isAwake ? islandFrame : restFrame }
    /// Pulls off the island (the pull-out answers them).
    var onPull: ((PanelIslandPull) -> Void)?
    private var pullTracker = PanelIslandPullTracker()
    /// The island drawn in the panel's motion layer, so it hides and shows
    /// as one shape with the panel (Accepted "Tall island", "Hiding and
    /// showing as one shape"). The panel's content container places it
    /// over the island window and shows it only while the panel moves.
    let standIn: NSView
    /// While the stand-in shows the island: how shown the island is meant
    /// to be (the motion's end), in place of the windows' own content.
    private(set) var handedOffShown: CGFloat?

    init(model: PanelIslandModel, uiState: PanelUIState, settings: AppSettings) {
        self.model = model
        func window(interactive: Bool) -> PanelIslandWindow {
            let window = PanelIslandWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: true)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isMovable = false
            window.isReleasedWhenClosed = false
            window.becomesKeyOnlyIfNeeded = true
            window.ignoresMouseEvents = !interactive
            window.allowsKey = interactive
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return window
        }
        island = window(interactive: true)
        label = window(interactive: false)
        island.setAccessibilityLabel(String(localized: "Pages"))
        island.contentView = PanelIslandHostingView(rootView: PanelIslandKeyed(
            settings: settings, model: model, uiState: uiState,
            content: PanelIslandView(model: model, focusTracker: uiState.keyboardFocus)))
        label.contentView = PanelIslandHostingView(rootView: PanelIslandKeyed(
            settings: settings, model: model, uiState: uiState, content: PanelIslandLabels(model: model)))
        label.setAccessibilityElement(false)
        let standIn = PanelIslandStandInHostingView(rootView: PanelIslandKeyed(
            settings: settings, model: model, uiState: uiState,
            content: PanelIslandView(model: model, focusTracker: uiState.keyboardFocus, isStandIn: true)))
        standIn.setAccessibilityElement(false)
        self.standIn = standIn
        island.onPointer = { [weak self] pointer in self?.handlePointer(pointer) }
    }

    /// The panel starts to move: the stand-in in its motion layer takes
    /// over (the caller shows it in the same transaction) and the windows'
    /// content goes. `shown` is where the motion takes the island.
    func handOff(shown: CGFloat) {
        let already = handedOffShown != nil
        handedOffShown = min(max(shown, 0), 1)
        // A swipe calls this on every event: the windows' content goes once.
        if !already { setPresentation(0) }
    }

    /// The motion has ended with the panel shown: the windows are the live
    /// island again (the caller hides the stand-in in the same transaction).
    func takeBack() {
        handedOffShown = nil
        setPresentation(1)
    }

    /// A press on an item may pull its page out; while it does, the press's
    /// release is not a click.
    func handlePointer(_ pointer: PanelIslandPointer) {
        guard let pull = pullTracker.handle(pointer, island: islandFrame) else { return }
        if case .began = pull { model.suppressesClicks = true; model.point(at: nil); model.isPulling = true }
        onPull?(pull)
        if case .ended = pull {
            model.isPulling = false
            // The release reaches SwiftUI first; clicks count again after.
            DispatchQueue.main.async { [weak model] in model?.suppressesClicks = false }
        }
    }

    /// Places both windows at `spot` around `panelFrame`, docked in `corner`.
    func layout(panelFrame: CGRect, corner: ScreenCorner, spot: PanelIslandSpot = .defaultSpot) {
        self.corner = corner
        self.spot = spot
        model.setCorner(corner, spot: spot)
        let capsule = PanelIslandLayout.islandFrame(panelFrame: panelFrame, corner: corner, spot: spot)
        islandFrame = capsule
        restFrame = PanelIslandLayout.restFrame(island: capsule, corner: corner, spot: spot)
        let islandWindowFrame = capsule.insetBy(dx: -PanelIslandLayout.windowMargin, dy: -PanelIslandLayout.windowMargin)
        if island.frame != islandWindowFrame { island.setFrame(islandWindowFrame, display: island.isVisible) }
        let labelFrame = PanelIslandLayout.labelWindowFrame(island: capsule, corner: corner, spot: spot)
        if label.frame != labelFrame { label.setFrame(labelFrame, display: label.isVisible) }
    }

    var isVisible: Bool { island.isVisible }

    /// How shown the island is on screen now (its window and its content,
    /// mid-animation included).
    var presentedOpacity: CGFloat {
        let layer = island.contentView?.layer
        let content = CGFloat(layer?.presentation()?.opacity ?? layer?.opacity ?? 1)
        return island.alphaValue * content
    }

    /// Orders both in above `parent`, attached so they keep its ordering.
    func show(attachedTo parent: NSWindow) {
        if island.parent !== parent { parent.addChildWindow(island, ordered: .above) }
        if label.parent !== parent { parent.addChildWindow(label, ordered: .above) }
        island.orderFrontRegardless()
        label.orderFrontRegardless()
    }

    func hide() {
        model.settle()
        island.parent?.removeChildWindow(island)
        label.parent?.removeChildWindow(label)
        island.orderOut(nil)
        label.orderOut(nil)
    }

    /// How shown the island is (1 shown, 0 hidden), at once. The windows
    /// stay opaque and their content's opacity changes, in the caller's
    /// transaction (the swaps with the stand-in).
    func setPresentation(_ shown: CGFloat) {
        let alpha = min(max(shown, 0), 1)
        for window in [island, label] {
            if window.alphaValue != 1 { window.alphaValue = 1 }
            guard let view = window.contentView else { continue }
            view.wantsLayer = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.alphaValue = alpha
            view.layer?.opacity = Float(alpha)
            CATransaction.commit()
        }
    }

    /// Only the capsule takes the pointer. The window's clear margin (room
    /// for the focus ring) passes clicks and hit-testing to the window under
    /// it, as the panel's clear corners do. Elsewhere the window keeps taking
    /// the pointer, so the capsule stays hittable. Moving onto the margin
    /// also clears the pointed item, since the island then hears no exit.
    /// Left alone while a button is held, so a pull off the island keeps
    /// its drag and release.
    func updatePassthrough(at point: CGPoint) {
        if island.isVisible { model.track(pointer: point, rest: restFrame, awake: islandFrame) }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let ignores = island.frame.contains(point) && !capsuleFrame.contains(point)
        guard island.ignoresMouseEvents != ignores else { return }
        island.ignoresMouseEvents = ignores
        if ignores { model.point(at: nil) }
    }

    /// The island takes the pointer everywhere again (monitoring stopped).
    func stopPassthrough() {
        if island.ignoresMouseEvents { island.ignoresMouseEvents = false }
    }

    /// How shown the island is meant to be (its windows' content, or the
    /// motion's while the stand-in shows it).
    var shownAlpha: CGFloat { handedOffShown ?? island.contentView?.alphaValue ?? 0 }

    /// Whether `point` (screen) is on the island while it shows: its
    /// capsule awake, or at rest the zone where the pointer wakes it.
    func contains(_ point: CGPoint) -> Bool {
        let zone = model.isAwake
            ? islandFrame
            : restFrame.insetBy(dx: -PanelIslandLayout.wakeDistance, dy: -PanelIslandLayout.wakeDistance)
        return island.isVisible && shownAlpha > 0.01 && zone.contains(point)
    }
}
