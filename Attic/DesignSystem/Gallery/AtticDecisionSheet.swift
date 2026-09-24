#if DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The glass-and-tint decision sheet: the owner's choice between keeping
/// full text contrast and keeping PR #5's glass transparency and tint
/// strengths. Rendered from the real components with the contact-sheet
/// pipeline; every contrast printed under a panel is measured on that
/// panel's own pixels (the minimum over every body, label and helper text
/// run, against the pixels behind it).
///
/// Run with `--attic-gallery --decision-sheet <dir>`, or by
/// `AtticDesignSystemTests.testDecisionSheet`.
@MainActor
enum AtticDecisionSheet {
    struct Option {
        let code: String
        let title: String
        let detail: String
        let apply: (inout AtticDesignContext) -> Void
    }

    struct Cell: Identifiable {
        let id = UUID()
        let group: String
        let caption: String
        let context: AtticDesignContext
        let backdrop: AtticCaptureContext.Backdrop
    }

    struct Measured {
        var body: Double?
        var label: Double?
        var helper: Double?
        var tintDifference: Double?
    }

    // MARK: Options

    static let glassOptions: [Option] = [
        Option(code: "A1", title: "Current rule", detail: "Coverage that keeps 4.5 : 1 for all text over a mid-grey desktop") { _ in },
        Option(code: "A2", title: "PR #5 glass floor", detail: "3 : 1 Glass, 3.5 : 1 Frosted over the worst desktop; text ladder unchanged") {
            $0.translucencyPolicy = .transparencyFirst
        },
        Option(code: "A3", title: "PR #5 floor, stronger text", detail: "Same coverage as A2; on translucent surfaces helper uses the label colour, labels use body") {
            $0.translucencyPolicy = .transparencyFirst
            $0.variant.strongerTextOnTranslucentOrTint = true
        }
    ]

    static let tintOptions: [Option] = [
        Option(code: "B1", title: "Held back", detail: "The strongest tint that keeps every text role at 4.5 : 1") { _ in },
        Option(code: "B2", title: "PR #5 strengths", detail: "Designed strengths (ΔE 3 / 7 / 12, Original's shade as drawn); text ladder unchanged") {
            $0.variant.designedTintStrength = true
        },
        Option(code: "B3", title: "PR #5 strengths, stronger text", detail: "Designed strengths; on tinted panels helper uses the label colour, labels use body") {
            $0.variant.designedTintStrength = true
            $0.variant.strongerTextOnTranslucentOrTint = true
        }
    ]

    static let backdrops: [(title: String, backdrop: AtticCaptureContext.Backdrop)] = [
        ("Light wallpaper", .wallpaper(.light)),
        ("Dark wallpaper", .wallpaper(.dark)),
        ("Mid-grey desktop", .desktop(.typical))
    ]

    static func glassCells(_ option: Option, surface: PanelSurfaceStyle) -> [Cell] {
        var cells: [Cell] = []
        for mode in AtticDesignContext.Mode.allCases {
            for palette in [AtticPanelTheme.original, .amethyst] {
                for backdrop in backdrops {
                    var context = AtticDesignContext(mode: mode, palette: palette, surface: surface)
                    option.apply(&context)
                    cells.append(Cell(group: "\(mode.title) · \(palette.title)", caption: backdrop.title, context: context, backdrop: backdrop.backdrop))
                }
            }
        }
        return cells
    }

    static func tintCells(_ option: Option) -> [Cell] {
        var cells: [Cell] = []
        for palette in [AtticPanelTheme.original, .amethyst] {
            for tint in [PanelTintLevel.subtle, .bold] {
                var context = AtticDesignContext(mode: .light, palette: palette, surface: .solid, tint: tint)
                option.apply(&context)
                cells.append(Cell(group: "Light · \(palette.title) · Solid", caption: "\(tint.title) tint", context: context, backdrop: .wallpaper(.light)))
            }
        }
        return cells
    }

    // MARK: Measuring

    /// Renders a cell's panel with probes and measures its text.
    static func measure(_ cell: Cell) -> Measured {
        let collector = AtticProbeCollector()
        let view = panel(for: cell)
            .environment(\.atticCapture, AtticCaptureContext(collector: collector, backdrop: cell.backdrop))
            .coordinateSpace(.named(AtticCaptureContext.coordinateSpace))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        var measured = Measured()
        if let image = renderer.cgImage, let bitmap = AtticBitmap(image: image) {
            for probe in collector.all {
                guard case .text = probe.kind, let ink = probe.ink, let foreground = probe.foreground,
                      [.body, .label, .helper].contains(ink),
                      let background = bitmap.background(around: probe.frame, outside: false, foreground: foreground, scale: 2)
                else { continue }
                let ratio = foreground.contrast(on: background)
                switch ink {
                case .body: measured.body = min(measured.body ?? .infinity, ratio)
                case .label: measured.label = min(measured.label ?? .infinity, ratio)
                default: measured.helper = min(measured.helper ?? .infinity, ratio)
                }
            }
        }
        if cell.context.tint != .off {
            var plain = cell.context
            plain.tint = .off
            measured.tintDifference = ColorDifference.deltaE76(
                cell.context.tokens.panel.composite(.typical).themeColor,
                plain.tokens.panel.composite(.typical).themeColor
            )
        }
        return measured
    }

    /// The real Tasks panel, with an expanded quick look so labels appear.
    static func panel(for cell: Cell) -> some View {
        AtticGalleryPanelComposition(demo: AtticGalleryDemo(), showsQuickLook: true)
            .atticDesign(cell.context)
    }

    // MARK: Writing

    @discardableResult
    static func write(to directory: URL) -> (url: URL?, measurements: [String: Measured]) {
        var rows: [(option: Option, part: String, cells: [(Cell, Measured)])] = []
        var measurements: [String: Measured] = [:]
        for surface in [PanelSurfaceStyle.glass, .frosted] {
            for option in glassOptions {
                let cells = glassCells(option, surface: surface).map { ($0, measure($0)) }
                rows.append((option, surface.title, cells))
                for (cell, measured) in cells {
                    measurements["\(option.code) \(surface.title) \(cell.group) \(cell.caption)"] = measured
                }
            }
        }
        for option in tintOptions {
            let cells = tintCells(option).map { ($0, measure($0)) }
            rows.append((option, "Tint", cells))
            for (cell, measured) in cells {
                measurements["\(option.code) \(cell.group) \(cell.caption)"] = measured
            }
        }
        let sheet = AtticDecisionSheetView(rows: rows.map { .init(option: $0.option, part: $0.part, cells: $0.cells) })
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return (nil, measurements) }
        let url = directory.appendingPathComponent("decisions-glass-and-tint.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return (nil, measurements)
        }
        CGImageDestinationAddImage(destination, image, nil)
        return (CGImageDestinationFinalize(destination) ? url : nil, measurements)
    }
}

/// The sheet: one row per option, big labels, measurements under each panel.
private struct AtticDecisionSheetView: View {
    struct Row: Identifiable {
        let id = UUID()
        let option: AtticDecisionSheet.Option
        let part: String
        let cells: [(AtticDecisionSheet.Cell, AtticDecisionSheet.Measured)]
    }

    let rows: [Row]

    private let ink = Color(.sRGB, red: 0.11, green: 0.11, blue: 0.12)
    private let quiet = Color(.sRGB, red: 0.38, green: 0.38, blue: 0.40)

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Glass and tint: which trade-off?")
                    .font(.system(size: 44, weight: .bold))
                Text(verbatim: "Real components, rendered by the appearance-check pipeline. Numbers are the lowest measured contrast of each text role in that panel (floor 4.5 : 1; red = below it). Glass and Frosted are drawn from the measured PR #5 renders of a black and a white desktop.")
                    .font(.system(size: 20))
                    .foregroundStyle(quiet)
                    .frame(maxWidth: 2200, alignment: .leading)
            }
            .foregroundStyle(ink)

            partHeading("Part A · Glass and Frosted, no tint")
            ForEach(rows.filter { $0.part != "Tint" }) { row in rowView(row) }
            partHeading("Part B · Light tints, Solid")
            ForEach(rows.filter { $0.part == "Tint" }) { row in rowView(row) }
        }
        .padding(48)
        .background(Color(.sRGB, red: 0.94, green: 0.94, blue: 0.95))
    }

    private func partHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(ink)
            .padding(.top, 12)
    }

    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(verbatim: row.option.code)
                    .font(.system(size: 34, weight: .heavy))
                Text(verbatim: row.part == "Tint" ? row.option.title : "\(row.option.title) · \(row.part)")
                    .font(.system(size: 30, weight: .semibold))
                Text(verbatim: row.option.detail)
                    .font(.system(size: 20))
                    .foregroundStyle(quiet)
            }
            .foregroundStyle(ink)
            let groups = Dictionary(grouping: row.cells.indices, by: { row.cells[$0].0.group })
            let order = row.cells.map(\.0.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            HStack(alignment: .top, spacing: 28) {
                ForEach(order, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: group)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(ink)
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(groups[group] ?? [], id: \.self) { index in
                                cellView(row.cells[index].0, row.cells[index].1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cellView(_ cell: AtticDecisionSheet.Cell, _ measured: AtticDecisionSheet.Measured) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: cell.caption)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(quiet)
            AtticDecisionSheet.panel(for: cell)
                .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: cell.backdrop))
                .padding(14)
                .background(backdropView(cell))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 12) {
                number("body", measured.body)
                number("label", measured.label)
                number("helper", measured.helper)
            }
            if let difference = measured.tintDifference {
                Text(verbatim: String(format: "tint ΔE %.1f", difference))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ink)
            }
        }
        .frame(width: AtticLayout.panelSize.width + 28, alignment: .leading)
    }

    @ViewBuilder
    private func backdropView(_ cell: AtticDecisionSheet.Cell) -> some View {
        switch cell.backdrop {
        case .wallpaper(let tone):
            AtticStandInWallpaper(tone: tone, dark: cell.context.mode == .dark)
        case .desktop:
            Color(.sRGB, white: 0.5)
        }
    }

    private func number(_ name: String, _ value: Double?) -> some View {
        let text = value.map { String(format: "%@ %.1f", name, $0) } ?? "\(name) –"
        let failing = (value ?? 99) < 4.5
        return Text(verbatim: text)
            .font(.system(size: 17, weight: failing ? .bold : .regular).monospacedDigit())
            .foregroundStyle(failing ? Color(.sRGB, red: 0.78, green: 0.12, blue: 0.10) : ink)
    }
}
#endif
