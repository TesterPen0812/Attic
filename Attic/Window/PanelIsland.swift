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

    /// Today's place (Accepted "Island position": "The default is today's place").
    static let defaultSpot: PanelIslandSpot = .screenSideCornerEnd

    enum Side: Equatable { case screen, open, across }
    enum Position: Equatable { case cornerEnd, middle, farEnd }

    var id: String { rawValue }

    var side: Side {
        switch self {
        case .screenSideCornerEnd, .screenSideMiddle, .screenSideFarEnd: .screen
        case .openSideCornerEnd, .openSideMiddle, .openSideFarEnd: .open
        case .acrossOpenEnd: .across
        }
    }

    /// Along the panel's side (the across spot is always centred).
    var position: Position {
        switch self {
        case .screenSideCornerEnd, .openSideCornerEnd: .cornerEnd
        case .screenSideMiddle, .openSideMiddle, .acrossOpenEnd: .middle
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
    /// From the work area's side edge (the Dock's edge when it sits there).
    static let edgeInset: CGFloat = 8
    /// Between the island and the panel.
    static let panelGap: CGFloat = 8
    /// How far the panel's side edge sits from the work area's side edge.
    static let panelSideInset: CGFloat = edgeInset + width + panelGap

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
    /// Transparent room around the island's capsule for its glass's edge
    /// and shadow (less than `panelGap`, so it never reaches the panel).
    static let windowMargin: CGFloat = 6

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

    /// Whether the island sits right of the panel (the right corners).
    static func isOnRight(_ corner: ScreenCorner) -> Bool {
        corner == .topRight || corner == .bottomRight
    }

    static func isTop(_ corner: ScreenCorner) -> Bool {
        corner == .topRight || corner == .topLeft
    }

    /// The part of a work area the panel itself may use: the island's strip
    /// comes off the docked corner's side, so a panel placed `screenInset`
    /// inside it sits `panelSideInset` from that edge.
    static func panelArea(in visibleFrame: CGRect, corner: ScreenCorner,
                          spot: PanelIslandSpot = .defaultSpot,
                          screenInset: CGFloat = PanelGeometry.screenInset) -> CGRect {
        let trim = min(max(0, panelSideInset - screenInset), max(0, visibleFrame.width))
        var area = visibleFrame
        area.size.width -= trim
        if !isOnRight(corner) { area.origin.x += trim }
        return area
    }

    /// The island's capsule in screen points, beside `panelFrame` (the
    /// panel's visible surface) on `corner`'s side.
    static func islandFrame(panelFrame: CGRect, corner: ScreenCorner,
                            spot: PanelIslandSpot = .defaultSpot) -> CGRect {
        let height = height()
        let x = isOnRight(corner) ? panelFrame.maxX + panelGap : panelFrame.minX - panelGap - width
        let y = isTop(corner) ? panelFrame.maxY - height : panelFrame.minY
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The gap between the panel and the island, at the island's height:
    /// crossing it from the panel to the island stays on the panel.
    static func gapFrame(panelFrame: CGRect, corner: ScreenCorner,
                         spot: PanelIslandSpot = .defaultSpot) -> CGRect {
        let island = islandFrame(panelFrame: panelFrame, corner: corner)
        let x = isOnRight(corner) ? panelFrame.maxX : island.maxX
        return CGRect(x: x, y: island.minY, width: panelGap, height: island.height)
    }

    /// An item's square in screen points (items run top to bottom).
    static func itemFrame(_ index: Int, in island: CGRect) -> CGRect {
        CGRect(x: island.minX + inset, y: island.maxY - inset - CGFloat(index + 1) * item - CGFloat(index) * gap,
               width: item, height: item)
    }

    /// The side of the island its label shows on: the panel's.
    static func labelSide(corner: ScreenCorner, spot: PanelIslandSpot = .defaultSpot) -> PanelIslandLabelSide {
        isOnRight(corner) ? .left : .right
    }

    /// The label window: the island's height, beside it on the panel's side.
    static func labelWindowFrame(island: CGRect, corner: ScreenCorner,
                                 spot: PanelIslandSpot = .defaultSpot) -> CGRect {
        let x = isOnRight(corner) ? island.minX - labelGap - labelRoom : island.maxX + labelGap
        return CGRect(x: x, y: island.minY, width: labelRoom, height: island.height)
    }

    /// How the island's stand-in keeps its place on the surface as the
    /// panel resizes (the motion layer is not flipped).
    static func standInResizing(corner: ScreenCorner, spot: PanelIslandSpot = .defaultSpot) -> NSView.AutoresizingMask {
        [isOnRight(corner) ? .minXMargin : .maxXMargin, isTop(corner) ? .minYMargin : .maxYMargin]
    }

    /// The point the panel and the island hide into and grow back out of:
    /// the corner of the two together nearest the screen corner (Accepted
    /// "Island position", "Hiding and showing as one shape still holds").
    static func collapseAnchor(panelFrame: CGRect, corner: ScreenCorner,
                               spot: PanelIslandSpot = .defaultSpot) -> CGPoint {
        PanelCollapseGeometry.cornerPoint(of: islandFrame(panelFrame: panelFrame, corner: corner), corner: corner)
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
    /// The item under the pointer: its name label shows. Never switches.
    @Published private(set) var pointed: PanelPage?
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

    func show(_ page: PanelPage) {
        if self.page != page { self.page = page }
    }

    func setOut(_ pages: Set<PanelPage>) {
        if outPages != pages { outPages = pages }
    }

    func setSnapTarget(_ target: Bool) {
        if isSnapTarget != target { isSnapTarget = target }
    }

    func setCorner(_ corner: ScreenCorner, spot: PanelIslandSpot = .defaultSpot) {
        let side = PanelIslandLayout.labelSide(corner: corner, spot: spot)
        if labelSide != side { labelSide = side }
        if isFlat != spot.isFlat { isFlat = spot.isFlat }
    }

    /// The pointer is over `page`'s item (nil: over none).
    func point(at page: PanelPage?) {
        if pointed == nil, page != nil { approaches.send() }
        if pointed != page { pointed = page }
    }

    /// The pointer left `page`'s item (another item may have it already).
    func leave(_ page: PanelPage) {
        if pointed == page { pointed = nil }
    }

    func click(_ page: PanelPage) {
        guard !suppressesClicks else { return }
        onClick?()
        requests.send(page)
    }
}

// MARK: - Views

/// The island: one glass capsule (the tag bar's and "+"'s control glass,
/// or their flat look) with an item per page, the current page on the grey
/// selection chip. VoiceOver reads "Pages" with a named button per page,
/// the current one selected.
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
    private typealias M = AtticPageButtonMetrics

    var body: some View {
        let radius = AtticRadius.header
        let chipRadius = AtticRadius.nested(outer: radius, gap: L.inset) ?? radius
        VStack(spacing: L.gap) {
            ForEach(L.pages) { page in
                if isStandIn {
                    face(page, chipRadius: chipRadius)
                } else {
                    item(page, chipRadius: chipRadius)
                }
            }
        }
        .padding(L.inset)
        .frame(width: L.width, height: L.height())
        // The surface sits behind the items rather than wrapping them, so
        // the glass does not tint the icons and chip (the owner's recording
        // of build 1: the island read faint), as the top-line tabs do.
        .background {
            Color.clear
                .modifier(PanelIslandSurface(flat: design.effectiveControls != .liquidGlass, cornerRadius: radius))
        }
        .overlay {
            // A floating panel dragged near: a solid blue ring (the
            // design's 4 px at 55 %, outside the capsule).
            AtticControlShape.shape(cornerRadius: radius + PanelPullOutLayout.ringWidth, exponent: cornerExponent)
                .strokeBorder(PanelPullOutLayout.blue.opacity(0.55), lineWidth: PanelPullOutLayout.ringWidth)
                .padding(-PanelPullOutLayout.ringWidth)
                .opacity(model.isSnapTarget ? 1 : 0)
                .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion,
                                                               showing: model.isSnapTarget), value: model.isSnapTarget)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(AtticControlShape.shape(cornerRadius: radius, exponent: cornerExponent))
        .padding(L.windowMargin)
        .accessibilityElement(children: isStandIn ? .ignore : .contain)
        .accessibilityLabel(String(localized: "Pages"))
        .accessibilityIdentifier(isStandIn ? "" : "panel-section-picker")
        .accessibilityHidden(isStandIn)
        .allowsHitTesting(!isStandIn)
    }

    /// An item as drawn: the chip or hover fill, the icon and the out dot.
    private func face(_ page: PanelPage, chipRadius: CGFloat) -> some View {
        let isSelected = page == model.page
        let shape = AtticControlShape.shape(cornerRadius: chipRadius, exponent: cornerExponent)
        return ZStack {
            if isSelected {
                AtticSelectionMarker(cornerRadius: chipRadius)
                    .transition(AtticSelectionMarker.transition)
            } else if model.pointed == page {
                shape.fill(AtticSelectionMarker.hoverFill(design.tokens).color)
            }
            let face = L.face(isSelected: isSelected, solid: design.effectiveSurface == .solid)
            AtticIcon(systemName: page.systemName, size: M.iconSize, weight: face.weight, ink: face.ink)
            // A page that's out: a 4 pt blue dot at the item's
            // top-right corner (the design's 8 px, 6 px in).
            Circle()
                .fill(PanelPullOutLayout.blue)
                .frame(width: PanelPullOutLayout.outDot, height: PanelPullOutLayout.outDot)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(PanelPullOutLayout.outDotInset)
                .opacity(model.outPages.contains(page) ? 1 : 0)
                .accessibilityHidden(true)
        }
        .animation(AtticSelectionMarker.animation(reduceMotion: design.reduceMotion), value: isSelected)
        .frame(width: L.item, height: L.item)
        .contentShape(Rectangle())
    }

    private func item(_ page: PanelPage, chipRadius: CGFloat) -> some View {
        let isSelected = page == model.page
        return Button { model.click(page) } label: {
            face(page, chipRadius: chipRadius)
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
        .accessibilityLabel(page.title)
        .accessibilityValue(model.outPages.contains(page) ? String(localized: "In its own panel") : "")
        .accessibilityIdentifier(page.accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct PanelIslandSurface: ViewModifier {
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

/// The name labels, one per item row, in a window that never takes the
/// pointer. Only the pointed item's shows; it slides 4 pt in from the
/// island on the popover motion (Reduce Motion: a fade).
struct PanelIslandLabels: View {
    @ObservedObject var model: PanelIslandModel

    @Environment(\.atticDesign) private var design
    @Environment(\.atticControlCornerExponent) private var cornerExponent

    private typealias L = PanelIslandLayout

    var body: some View {
        let alignment: Alignment = model.labelOnLeft ? .trailing : .leading
        let towardIsland: CGFloat = model.labelOnLeft ? L.labelSlide : -L.labelSlide
        VStack(spacing: L.gap) {
            ForEach(L.pages) { page in
                let shown = model.pointed == page
                Text(page.title)
                    .font(.system(size: L.labelFontSize, weight: .medium))
                    .foregroundStyle(design.tokens.ink(.heading).color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, L.labelPadding)
                    .frame(height: L.labelHeight)
                    .modifier(PanelIslandSurface(flat: design.effectiveControls != .liquidGlass,
                                                 cornerRadius: L.labelHeight / 2))
                    .opacity(shown ? 1 : 0)
                    .offset(x: shown ? 0 : towardIsland)
                    .animation(shown || L.labelFadesOut(pointed: model.pointed)
                               ? AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: shown) : nil,
                               value: shown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .frame(height: L.item)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, L.inset)
        .frame(width: L.labelRoom, height: L.height())
        .allowsHitTesting(false)
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

    override func sendEvent(_ event: NSEvent) {
        let point = convertPoint(toScreen: event.locationInWindow)
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
    override var canBecomeMain: Bool { false }
    /// Draws active exactly while its parent, the Attic panel, is key, so
    /// the island's glass looks like the panel's own controls (owner, 1 Nov:
    /// it drew inactive glass while Attic was focused). AppKit's glass asks
    /// the window it is in, and a child window that is never key always
    /// answers inactive; SwiftUI's `appearsActive`/`controlActiveState` and
    /// an `isKeyWindow` override do not reach it (measured on macOS 26.4).
    /// Only the look changes: the window still never becomes key or main,
    /// and the keyboard stays with the panel. AppKit asks again whenever
    /// the parent's key state changes and when the window is ordered in
    /// attached (`show(attachedTo:)` attaches before it orders in).
    @objc func _hasActiveAppearance() -> Bool { parent?.isKeyWindow ?? false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

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
/// controller places them from the panel's frame, shows and hides them with
/// it and fades them on its hide motion's own duration and curve.
@MainActor
final class PanelIslandWindows {
    let model: PanelIslandModel
    let island: PanelIslandWindow
    let label: PanelIslandWindow
    private(set) var corner: ScreenCorner = .topRight
    private(set) var spot: PanelIslandSpot = .defaultSpot
    /// The capsule in screen points (not the window's transparent margin).
    private(set) var islandFrame: CGRect = .zero
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
        if case .began = pull { model.suppressesClicks = true; model.point(at: nil) }
        onPull?(pull)
        if case .ended = pull {
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
        model.point(at: nil)
        island.parent?.removeChildWindow(island)
        label.parent?.removeChildWindow(label)
        island.orderOut(nil)
        label.orderOut(nil)
    }

    /// How shown the island is (1 shown, 0 hidden), animated over
    /// `duration` on `timing` (the panel motion's own), or at once. The
    /// windows stay opaque and their content fades on Core Animation, so
    /// the fade runs on the render server with the panel's own motion
    /// (a window's animated alpha did not: the owner's recording of build
    /// 1 showed the island staying until the panel vanished).
    func setPresentation(_ shown: CGFloat, duration: TimeInterval = 0,
                         timing: CAMediaTimingFunction? = nil) {
        let alpha = min(max(shown, 0), 1)
        for window in [island, label] {
            if window.alphaValue != 1 { window.alphaValue = 1 }
            guard let view = window.contentView else { continue }
            view.wantsLayer = true
            let layer = view.layer
            let from = layer?.presentation()?.opacity ?? Float(view.alphaValue)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.removeAnimation(forKey: Self.fadeKey)
            view.alphaValue = alpha
            layer?.opacity = Float(alpha)
            if duration > 0, abs(from - Float(alpha)) > 0.001, let layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from
                fade.toValue = Float(alpha)
                fade.duration = duration
                fade.timingFunction = timing
                layer.add(fade, forKey: Self.fadeKey)
            }
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
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let ignores = island.frame.contains(point) && !islandFrame.contains(point)
        guard island.ignoresMouseEvents != ignores else { return }
        island.ignoresMouseEvents = ignores
        if ignores { model.point(at: nil) }
    }

    /// The island takes the pointer everywhere again (monitoring stopped).
    func stopPassthrough() {
        if island.ignoresMouseEvents { island.ignoresMouseEvents = false }
    }

    private static let fadeKey = "attic.island.presentation"

    /// How shown the island is meant to be (the fade's end, or the motion's
    /// while the stand-in shows it).
    var shownAlpha: CGFloat { handedOffShown ?? island.contentView?.alphaValue ?? 0 }

    /// Whether `point` (screen) is on the island's capsule while it shows.
    func contains(_ point: CGPoint) -> Bool {
        island.isVisible && shownAlpha > 0.01 && islandFrame.contains(point)
    }
}
