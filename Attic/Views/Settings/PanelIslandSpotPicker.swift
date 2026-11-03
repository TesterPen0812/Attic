import SwiftUI

/// Settings › Panel: where the island sits (Planning.md, Accepted 2026-11-01
/// "Island position: seven spots around the panel"). A small diagram draws
/// the panel in its current corner of the screen with the seven spots
/// around it; a click on a spot chooses it, and the island moves there
/// straight away. The spots are one keyboard stop: the arrow keys move the
/// choice to the nearest spot that way.
enum PanelIslandSpotDiagram {
    /// The diagram: the screen, with the panel in its corner.
    static let size = CGSize(width: 152, height: 96)
    /// A spot's capsule: 6 pt thick, 18 pt long (lying flat across).
    static let thickness: CGFloat = 6
    static let length: CGFloat = 18
    /// Between a spot and the panel, and a screen-side spot and the edge.
    static let gap: CGFloat = 5
    static let edge: CGFloat = 5
    static let panelSize = CGSize(width: 46, height: 62)
    /// The panel's top or bottom from the screen's edge; in a bottom corner
    /// it leaves room for the spot on the screen's bottom edge.
    static let panelEnd: CGFloat = 8
    static let bottomEdgeRoom: CGFloat = 15

    private static func panelEnd(_ corner: ScreenCorner) -> CGFloat {
        PanelIslandLayout.isTop(corner) ? panelEnd : bottomEdgeRoom
    }

    /// The panel drawn for the top-right corner, before mirroring.
    private static func unmirroredPanel(_ corner: ScreenCorner) -> CGRect {
        CGRect(x: size.width - edge - thickness - gap - panelSize.width, y: panelEnd(corner),
               width: panelSize.width, height: panelSize.height)
    }
    /// How far past its capsule a spot takes a click.
    static let hitSlop = CGSize(width: 4, height: 2)
    static let screenRadius: CGFloat = 10
    static let panelRadius: CGFloat = 9

    /// The panel, in the diagram's points (top-left origin), in `corner`.
    static func panelFrame(corner: ScreenCorner) -> CGRect {
        mirrored(unmirroredPanel(corner), corner: corner)
    }

    /// A spot's capsule, in the diagram's points, with the panel in `corner`.
    static func spotFrame(_ spot: PanelIslandSpot, corner: ScreenCorner) -> CGRect {
        let spot = spot.shown(in: corner)
        // Drawn for the top-right corner, then mirrored.
        let panel = unmirroredPanel(corner)
        let frame: CGRect
        switch spot.side {
        case .across where spot == .bottomEdge:
            // The screen's bottom edge (a bottom corner only): drawn here at
            // the top, between the screen's edge and the panel, and mirrored.
            frame = CGRect(x: panel.midX - length / 2, y: max(1, panel.minY - gap - thickness), width: length, height: thickness)
        case .across:
            frame = CGRect(x: panel.midX - length / 2, y: panel.maxY + gap, width: length, height: thickness)
        case .screen, .open:
            let x = spot.side == .screen ? panel.maxX + gap : panel.minX - gap - thickness
            let y: CGFloat = switch spot.position {
            case .cornerEnd: panel.minY
            case .middle: panel.midY - length / 2
            case .farEnd: panel.maxY - length
            }
            frame = CGRect(x: x, y: y, width: thickness, height: length)
        }
        return mirrored(frame, corner: corner)
    }

    /// The part of the diagram a spot takes clicks in.
    static func hitFrame(_ spot: PanelIslandSpot, corner: ScreenCorner) -> CGRect {
        let frame = spotFrame(spot, corner: corner)
        return spot.isFlat ? frame.insetBy(dx: -hitSlop.height, dy: -hitSlop.width)
            : frame.insetBy(dx: -hitSlop.width, dy: -hitSlop.height)
    }

    private static func mirrored(_ rect: CGRect, corner: ScreenCorner) -> CGRect {
        var rect = rect
        if !PanelIslandLayout.isOnRight(corner) { rect.origin.x = size.width - rect.maxX }
        if !PanelIslandLayout.isTop(corner) { rect.origin.y = size.height - rect.maxY }
        return rect
    }

    enum Direction: Equatable { case up, down, left, right }

    /// The spot an arrow key moves to from `spot`: the nearest one that
    /// way, favouring the one most in line (nil: none that way).
    static func spot(from spot: PanelIslandSpot, toward direction: Direction, corner: ScreenCorner) -> PanelIslandSpot? {
        let start = spotFrame(spot.shown(in: corner), corner: corner)
        let origin = CGPoint(x: start.midX, y: start.midY)
        var best: (spot: PanelIslandSpot, score: CGFloat)?
        for candidate in PanelIslandSpot.spots(in: corner) where candidate != spot.shown(in: corner) {
            let frame = spotFrame(candidate, corner: corner)
            let dx = frame.midX - origin.x, dy = frame.midY - origin.y
            let (along, across): (CGFloat, CGFloat) = switch direction {
            case .up: (-dy, abs(dx))
            case .down: (dy, abs(dx))
            case .left: (-dx, abs(dy))
            case .right: (dx, abs(dy))
            }
            guard along > 1 else { continue }
            let score = along + 2 * across
            if best.map({ score < $0.score }) ?? true { best = (candidate, score) }
        }
        return best?.spot
    }
}

/// The Island group's row: "Position" over the chosen spot's name, and the
/// diagram.
struct PanelIslandSpotRow: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let m = AtticSettingsMetrics.self
        HStack(spacing: m.rowTrailingMinGap) {
            VStack(alignment: .leading, spacing: m.labelValueGap) {
                AtticText(verbatim: String(localized: "Position"), style: .groupLabel, ink: .label)
                AtticText(verbatim: settings.islandSpot.title(in: settings.corner), style: .groupValue, ink: .body)
            }
            .accessibilityHidden(true)
            Spacer(minLength: m.rowTrailingMinGap)
            PanelIslandSpotPicker(selection: $settings.islandSpot, corner: settings.corner)
        }
        .padding(.leading, AtticLayout.groupedRowTextInset)
        .padding(.trailing, AtticLayout.groupedRowTextInset)
        .padding(.vertical, PanelIslandSpotPicker.verticalPadding)
    }
}

/// The diagram itself: the screen, the panel in `corner`, and a button per
/// spot (VoiceOver: "Island position", each spot named, the chosen one selected).
struct PanelIslandSpotPicker: View {
    @Binding var selection: PanelIslandSpot
    let corner: ScreenCorner

    static let verticalPadding: CGFloat = 10

    @Environment(\.atticDesign) private var design
    @StateObject private var keyboard = AtticKeyboardFocusTracker()
    @FocusState private var focused: Bool
    @State private var hovered: PanelIslandSpot?

    private typealias D = PanelIslandSpotDiagram

    var body: some View {
        let tokens = design.tokens
        let dark = tokens.context.mode == .dark
        ZStack(alignment: .topLeading) {
            Squircle(cornerRadius: D.screenRadius, exponent: AtticShape.surfaceExponent)
                .strokeBorder(tokens.ink(.heading).withAlpha(dark ? 0.24 : 0.18).color, lineWidth: 1)
                .frame(width: D.size.width, height: D.size.height)
                .accessibilityHidden(true)
            let panel = D.panelFrame(corner: corner)
            Squircle(cornerRadius: D.panelRadius, exponent: AtticShape.surfaceExponent)
                .fill(tokens.ink(.heading).withAlpha(dark ? 0.16 : 0.10).color)
                .frame(width: panel.width, height: panel.height)
                .offset(x: panel.minX, y: panel.minY)
                .accessibilityHidden(true)
            ForEach(PanelIslandSpot.spots(in: corner)) { spot in
                spotButton(spot)
            }
        }
        .frame(width: D.size.width, height: D.size.height, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(.up) }
        .onKeyPress(.downArrow) { move(.down) }
        .onKeyPress(.leftArrow) { move(.left) }
        .onKeyPress(.rightArrow) { move(.right) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Island position"))
        .atticIdentifier("setting-island-spot")
    }

    private func spotButton(_ spot: PanelIslandSpot) -> some View {
        let tokens = design.tokens
        let frame = D.spotFrame(spot, corner: corner)
        let hit = D.hitFrame(spot, corner: corner)
        let isSelected = spot == selection.shown(in: corner)
        let ink = isSelected ? tokens.ink(.accent)
            : tokens.ink(.heading).withAlpha(hovered == spot ? 0.42 : 0.24)
        // Controls are on curve 1.4 (Accepted "Shapes"): a capsule.
        let radius = AtticShape.controlRadius(height: D.thickness)
        return Button { selection = spot } label: {
            AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent)
                .fill(ink.color)
                .frame(width: frame.width, height: frame.height)
                .atticFocusRing(isSelected && focused && keyboard.isKeyboardDriving, cornerRadius: radius)
                .frame(width: hit.width, height: hit.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            if inside { hovered = spot } else if hovered == spot { hovered = nil }
        }
        .offset(x: hit.minX, y: hit.minY)
        .accessibilityLabel(spot.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .atticIdentifier("setting-island-spot-\(spot.rawValue)")
    }

    private func move(_ direction: D.Direction) -> KeyPress.Result {
        guard let next = D.spot(from: selection, toward: direction, corner: corner) else { return .ignored }
        selection = next
        return .handled
    }
}
