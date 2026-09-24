#if DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The automated appearance check (spec § Quality bar, Appearance and Craft).
///
/// It renders every gallery family in every combination (Light and Dark ×
/// Solid, Glass and Frosted × every palette × every Tint step, each also
/// with Increase Contrast, Reduce Transparency and both) and checks, by
/// code, on the rendered pixels and the reported layout:
///
/// - **contrast**: every text run and icon against the pixels actually
///   behind it (4.5 : 1 text, helper and inactive text included; 3 : 1
///   icons, circles, rings and priority colours). Glass and Frosted are
///   rendered over two flat desktops, drawn as their measured native renders
///   (see `AtticSurfaceModel`): a 50 % grey desktop, judged at the full
///   floors, and the desktop that fights the text, judged at the owner's
///   Glass 3 : 1 / Frosted 3.5 : 1 transparency floor.
/// - **nothing clipped**: interface text is never shorter than its natural
///   size (user content may truncate, and says so).
/// - **nothing overlapping**: no two text runs or icons in a specimen
///   intersect, and everything stays inside its specimen.
/// - **sizes and radii**: controls match the size tokens and the corner rules.
///
/// It also checks the colour model itself for every combination, and writes
/// one curated contact sheet per family for the owner.
@MainActor
enum AtticAppearanceCheck {
    struct Failure: Hashable {
        enum Kind: String { case contrast, clipped, overlap, outOfBounds, size, radius, model, render }
        let kind: Kind
        let family: String
        let specimen: String
        let detail: String
    }

    struct Report {
        var combinations = 0
        var renders = 0
        var probesChecked = 0
        var contrastPairsChecked = 0
        /// Unique failures, each with the combinations it happened in.
        var failures: [Failure: [String]] = [:]
        var clampedTints: [String] = []
        /// Foundation and Tint strength per palette, mode and surface, under
        /// both translucency policies: the numbers behind the look.
        var surfaceTable: [String] = []
        var worstContrast: [String: (ratio: Double, floor: Double, where: String)] = [:]

        mutating func fail(_ failure: Failure, in combination: String) {
            failures[failure, default: []].append(combination)
        }

        var headline: String {
            "\(combinations) combinations, \(renders) renders, \(probesChecked) probes, \(contrastPairsChecked) contrast checks, \(failures.count) distinct failures"
        }

        var summary: String {
            var lines = ["Attic appearance check", headline, ""]
            if failures.isEmpty {
                lines.append("No failures.")
            } else {
                for (failure, combinations) in failures.sorted(by: { "\($0.key.family)\($0.key.specimen)\($0.key.detail)" < "\($1.key.family)\($1.key.specimen)\($1.key.detail)" }) {
                    lines.append("FAIL [\(failure.kind.rawValue)] \(failure.family) › \(failure.specimen): \(failure.detail)")
                    lines.append("     in \(combinations.count) combination(s), e.g. \(combinations.prefix(3).joined(separator: " | "))")
                }
            }
            lines.append("")
            lines.append("Tints held back for readability (\(clampedTints.count)):")
            lines.append(contentsOf: clampedTints.map { "  " + $0 })
            lines.append("")
            lines.append("Surfaces: foundation over the desktop, and each Tint step's colour difference at the top edge (ΔE76; designed 3 / 7 / 12):")
            lines.append(contentsOf: surfaceTable.map { "  " + $0 })
            lines.append("")
            lines.append("Lowest contrast per role (ratio / floor):")
            for (role, value) in worstContrast.sorted(by: { $0.key < $1.key }) {
                lines.append(String(format: "  %@: %.2f / %.1f  (%@)", role, value.ratio, value.floor, value.where))
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: Combinations

    /// Every combination the quality bar names. Reduce Transparency forces
    /// Solid, so its Glass and Frosted rows collapse into Solid.
    nonisolated static func allContexts() -> [AtticDesignContext] {
        var contexts: [AtticDesignContext] = []
        var seen = Set<String>()
        for mode in AtticDesignContext.Mode.allCases {
            for palette in AtticPanelTheme.allCases {
                for surface in PanelSurfaceStyle.allCases {
                    for tint in PanelTintLevel.allCases {
                        for (ic, rt) in [(false, false), (true, false), (false, true), (true, true)] {
                            let context = AtticDesignContext(
                                mode: mode, palette: palette, surface: surface, tint: tint,
                                increaseContrast: ic, reduceTransparency: rt
                            )
                            if seen.insert(context.caption).inserted {
                                contexts.append(context)
                            }
                        }
                    }
                }
            }
        }
        return contexts
    }

    /// The owner's curated sheet: default Light and Dark plus the stress cases.
    nonisolated static func sheetContexts() -> [(title: String, context: AtticDesignContext)] {
        let lightest = AtticPanelTheme.allCases
            .filter { $0 != .original }
            .max { $0.palette(for: AtticPanelThemeAppearance.light).opaqueSurface.relativeLuminance < $1.palette(for: AtticPanelThemeAppearance.light).opaqueSurface.relativeLuminance } ?? .porcelainVapor
        return [
            ("Default · Light", AtticDesignContext(mode: .light)),
            ("Default · Dark", AtticDesignContext(mode: .dark)),
            ("Stress · Midnight Cobalt, Dark, Glass, Bold tint", AtticDesignContext(mode: .dark, palette: .midnightCobalt, surface: .glass, tint: .bold)),
            ("Stress · \(lightest.title) (lightest), Light, Frosted", AtticDesignContext(mode: .light, palette: lightest, surface: .frosted)),
            ("Stress · Increase Contrast + Reduce Transparency, Light", AtticDesignContext(mode: .light, increaseContrast: true, reduceTransparency: true)),
            ("Stress · Increase Contrast + Reduce Transparency, Dark", AtticDesignContext(mode: .dark, increaseContrast: true, reduceTransparency: true)),
            ("Compare · stress 1 on the PR #5 glass floor", {
                var context = AtticDesignContext(mode: .dark, palette: .midnightCobalt, surface: .glass, tint: .bold)
                context.translucencyPolicy = .transparencyFirst
                return context
            }())
        ]
    }

    // MARK: Running

    static func run(
        families: [AtticGalleryFamily] = AtticGalleryFamily.allCases,
        contexts: [AtticDesignContext] = allContexts(),
        scale: CGFloat = 1
    ) -> Report {
        var report = Report()
        report.combinations = contexts.count
        checkModel(contexts: contexts, report: &report)
        for context in contexts {
            let desktops: [AtticSurfaceModel.Desktop] = context.isTranslucent ? AtticSurfaceModel.Desktop.allCases : [.typical]
            for desktop in desktops {
                for family in families {
                    check(family: family, context: context, desktop: desktop, scale: scale, report: &report)
                }
            }
        }
        return report
    }

    /// The colour model on its own: every role on every background it is
    /// drawn on, for every combination (fast, no rendering).
    static func checkModel(contexts: [AtticDesignContext], report: inout Report) {
        var clamped = Set<String>()
        for context in contexts {
            let tokens = context.tokens
            if tokens.panel.isTintClamped {
                clamped.insert("\(context.mode.title) · \(context.palette.title) · \(PanelSurfaceStyle(tokens.panel.kind).title) · \(context.tint.title): tint held to \(Int((tokens.panel.tintScale * 100).rounded())) %")
            }
            let pairs = AtticSurfaceModel.readabilityPairs(
                inks: tokens.inks, hover: tokens.hover, selected: tokens.selected, pressed: tokens.pressed,
                controlFace: tokens.raised.face.over(tokens.controlBase), chipSelected: tokens.chipSelected, chipHover: tokens.chipHover,
                recessed: tokens.recessed, tagFill: tokens.tagFill, tagFillSelected: tokens.tagFillSelected
            )
            if tokens.panel.worstMargin(pairs) < 0.999 {
                report.fail(.init(kind: .model, family: "Model", specimen: "Panel surface", detail: String(format: "worst margin %.3f", tokens.panel.worstMargin(pairs))), in: context.caption)
            }
            // Cards are base style: their text is judged on the card itself.
            for (card, name) in [(tokens.contentCard, "content card"), (tokens.groupCard, "group card")] {
                for ink in [AtticInk.heading, .body, .label, .helper] {
                    let ratio = tokens.ink(ink).contrast(on: card)
                    if ratio < ink.floor.ratio {
                        report.fail(.init(kind: .model, family: "Model", specimen: name, detail: String(format: "%@ %.2f < %.1f", ink.rawValue, ratio, ink.floor.ratio)), in: context.caption)
                    }
                }
            }
        }
        report.clampedTints = clamped.sorted()
        report.surfaceTable = surfaceTable()
    }

    static func surfaceTable() -> [String] {
        var lines: [String] = []
        for policy in AtticSurfaceModel.Policy.allCases {
            lines.append("[\(policy.title)]")
            for mode in AtticDesignContext.Mode.allCases {
                for palette in AtticPanelTheme.allCases {
                    for surface in PanelSurfaceStyle.allCases where !(policy == .transparencyFirst && surface == .solid) {
                        var plainContext = AtticDesignContext(mode: mode, palette: palette, surface: surface)
                        plainContext.translucencyPolicy = policy
                        let plain = plainContext.tokens.panel
                        var line = "\(mode.title) · \(palette.title) · \(surface.title): foundation \(Int((plain.foundationOpacity * 100).rounded())) %, tint ΔE"
                        for tint in [PanelTintLevel.subtle, .vivid, .bold] {
                            var context = plainContext
                            context.tint = tint
                            let tinted = context.tokens.panel
                            let difference = ColorDifference.deltaE76(tinted.composite(.typical).themeColor, plain.composite(.typical).themeColor)
                            line += String(format: " %.1f", difference)
                        }
                        lines.append(line)
                    }
                }
            }
        }
        return lines
    }

    static func check(
        family: AtticGalleryFamily,
        context: AtticDesignContext,
        desktop: AtticSurfaceModel.Desktop,
        scale: CGFloat,
        report: inout Report
    ) {
        let combination = context.caption + (context.isTranslucent ? " · \(desktop.rawValue) desktop" : "")
        let collector = AtticProbeCollector()
        guard let bitmap = render(family: family, context: context, backdrop: .desktop(desktop), collector: collector, scale: scale) else {
            report.fail(.init(kind: .render, family: family.title, specimen: "", detail: "render failed"), in: combination)
            return
        }
        report.renders += 1
        let probes = collector.all
        let specimens = Dictionary(probes.compactMap { probe -> (String, CGRect)? in
            if case .specimen = probe.kind { return (probe.specimen, probe.frame) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        // The kind whose floors apply: the Settings chrome is a sidebar
        // (Frosted) material; everything else sits on the panel surface.
        let judgedKind: AtticPanelSurfaceTreatment.Kind = family.stage == .settingsWindow && context.isTranslucent ? .frosted : context.effectiveSurface

        var visual: [AtticProbe] = []
        for probe in probes {
            let specimenName = displayName(probe.specimen)
            func fail(_ kind: Failure.Kind, _ detail: String) {
                report.fail(.init(kind: kind, family: family.title, specimen: specimenName, detail: detail), in: combination)
            }
            switch probe.kind {
            case .specimen:
                continue
            case let .control(name, expectedSize, radius, expectedRadius):
                report.probesChecked += 1
                if let expectedSize {
                    if expectedSize.width > 0, abs(probe.frame.width - expectedSize.width) > 0.5 {
                        fail(.size, String(format: "%@ width %.1f, token %.1f", name, probe.frame.width, expectedSize.width))
                    }
                    if expectedSize.height > 0, abs(probe.frame.height - expectedSize.height) > 0.5 {
                        fail(.size, String(format: "%@ height %.1f, token %.1f", name, probe.frame.height, expectedSize.height))
                    }
                }
                if abs(radius - expectedRadius) > 0.01 {
                    fail(.radius, String(format: "%@ radius %.2f, token %.2f", name, radius, expectedRadius))
                }
                if controlRuleNames.contains(name) {
                    let rule = AtticRadius.control(height: probe.frame.height)
                    if abs(radius - rule) > 0.26 {
                        fail(.radius, String(format: "%@ radius %.2f on %.1f tall, rule %.2f", name, radius, probe.frame.height, rule))
                    }
                }
            case let .text(style, string):
                report.probesChecked += 1
                visual.append(probe)
                if let ideal = probe.idealSize, !probe.allowsTruncation {
                    if probe.frame.width + 0.75 < ideal.width {
                        fail(.clipped, String(format: "“%@” (%@) %.1f of %.1f pt wide", string, style.rawValue, probe.frame.width, ideal.width))
                    }
                    if probe.frame.height + 0.75 < ideal.height {
                        fail(.clipped, String(format: "“%@” (%@) %.1f of %.1f pt tall", string, style.rawValue, probe.frame.height, ideal.height))
                    }
                }
            case .icon:
                report.probesChecked += 1
                visual.append(probe)
            }
        }

        // Contrast against the rendered pixels.
        for probe in visual {
            guard let ink = probe.ink, ink.floor != .exempt, let foreground = probe.foreground,
                  !probe.frame.isNull, probe.frame.width > 1, probe.frame.height > 1 else { continue }
            let isIcon: Bool = if case .icon = probe.kind { true } else { false }
            guard let background = bitmap.background(around: probe.frame, outside: isIcon, foreground: foreground, scale: scale) else { continue }
            let ratio = foreground.contrast(on: background)
            let floor = AtticSurfaceModel.floor(for: ink.floor, kind: judgedKind, desktop: desktop)
            report.contrastPairsChecked += 1
            let role = "\(ink.rawValue) (\(ink.floor == .text ? "text" : "non-text"))"
            let slack = ratio / floor
            if let current = report.worstContrast[role] {
                if slack < current.ratio / current.floor {
                    report.worstContrast[role] = (ratio, floor, "\(family.title) › \(label(probe)) · \(combination)")
                }
            } else {
                report.worstContrast[role] = (ratio, floor, "\(family.title) › \(label(probe)) · \(combination)")
            }
            if ratio + 0.005 < floor {
                report.fail(.init(
                    kind: .contrast, family: family.title,
                    specimen: displayName(probe.specimen),
                    detail: "\(label(probe)) \(ink.rawValue) below \(floor == 4.5 ? "4.5" : String(format: "%.1f", floor)) : 1"
                ), in: combination + String(format: " (%.2f on %@)", ratio, background.hexString))
            }
        }

        // Overlap and bounds, within each specimen.
        let bySpecimen = Dictionary(grouping: visual, by: \.specimen)
        for (specimen, items) in bySpecimen {
            let specimenName = displayName(specimen)
            if let bounds = specimens[specimen] {
                for item in items where !item.frame.isNull {
                    let outside = item.frame.minX < bounds.minX - 0.5 || item.frame.maxX > bounds.maxX + 0.5
                        || item.frame.minY < bounds.minY - 0.5 || item.frame.maxY > bounds.maxY + 0.5
                    if outside, !item.allowsOverlap {
                        report.fail(.init(kind: .outOfBounds, family: family.title, specimen: specimenName, detail: "\(label(item)) leaves its specimen"), in: combination)
                    }
                }
            }
            for (index, first) in items.enumerated() where !first.allowsOverlap {
                for second in items[(index + 1)...] where !second.allowsOverlap {
                    let overlap = first.frame.intersection(second.frame)
                    if !overlap.isNull, overlap.width > 0.75, overlap.height > 0.75 {
                        report.fail(.init(kind: .overlap, family: family.title, specimen: specimenName, detail: "\(label(first)) overlaps \(label(second))"), in: combination)
                    }
                }
            }
        }
    }

    /// Controls whose radius must follow the 32 %-of-height rule.
    static let controlRuleNames: Set<String> = [
        "Single button", "Label button", "Page switch", "Add bar", "Small control",
        "Selection bar", "Toast", "Menu row", "Tag"
    ]

    /// "Family / Caption#id" → "Caption".
    static func displayName(_ specimen: String) -> String {
        let caption = specimen.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        return caption.components(separatedBy: "#").first ?? caption
    }

    private static func label(_ probe: AtticProbe) -> String {
        switch probe.kind {
        case let .text(_, string): "“\(string)”"
        case let .icon(name): name
        case let .control(name, _, _, _): name
        case .specimen: "specimen"
        }
    }

    // MARK: Rendering

    /// Renders one family's board on its stage, in capture mode.
    static func render(
        family: AtticGalleryFamily,
        context: AtticDesignContext,
        backdrop: AtticCaptureContext.Backdrop,
        collector: AtticProbeCollector?,
        scale: CGFloat
    ) -> AtticBitmap? {
        let view = AtticGalleryStage(family: family, demo: AtticGalleryDemo())
            .atticDesign(context)
            .environment(\.atticCapture, AtticCaptureContext(collector: collector, backdrop: backdrop))
            .coordinateSpace(.named(AtticCaptureContext.coordinateSpace))
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        return AtticBitmap(image: image)
    }

    // MARK: Contact sheets

    /// Writes one PNG per family: the default Light and Dark looks and the
    /// stress cases side by side, at 2×. Returns the files written.
    @discardableResult
    static func writeContactSheets(to directory: URL, families: [AtticGalleryFamily] = AtticGalleryFamily.allCases) -> [URL] {
        var written: [URL] = []
        for (index, family) in families.enumerated() {
            let sheet = AtticContactSheet(family: family, columns: sheetContexts())
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let url = directory.appendingPathComponent(String(format: "%02d-%@.png", index + 1, family.rawValue))
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { written.append(url) }
            }
        }
        return written
    }
}

/// One family in the curated combinations, on a neutral sheet.
struct AtticContactSheet: View {
    let family: AtticGalleryFamily
    let columns: [(title: String, context: AtticDesignContext)]

    var body: some View {
        let wide = family.width > 400
        let perRow = wide ? 3 : columns.count
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: family.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(.sRGB, red: 0.12, green: 0.12, blue: 0.12))
                Text(verbatim: "Attic design system · Phase 0 gallery · rendered by the appearance check")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(.sRGB, red: 0.40, green: 0.40, blue: 0.40))
            }
            ForEach(0..<Int((Double(columns.count) / Double(perRow)).rounded(.up)), id: \.self) { row in
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(columns.enumerated()).dropFirst(row * perRow).prefix(perRow), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: column.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(.sRGB, red: 0.20, green: 0.20, blue: 0.20))
                                .frame(width: family.width + 32, alignment: .leading)
                                .lineLimit(1)
                            AtticGalleryStage(family: family, demo: AtticGalleryDemo())
                                .atticDesign(column.context)
                                .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: .wallpaper))
                                .padding(16)
                                .background(
                                    AtticStandInWallpaper(dark: column.context.mode == .dark)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                )
                        }
                    }
                }
            }
        }
        .padding(32)
        .background(Color(.sRGB, red: 0.93, green: 0.93, blue: 0.94))
    }
}

/// An sRGB RGBA8 copy of a rendered image, for pixel sampling.
struct AtticBitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// The colour at a point in points (top-left origin), or nil when the
    /// pixel is transparent or outside the image.
    func colour(atX x: CGFloat, y: CGFloat, scale: CGFloat) -> AtticRGBA? {
        let px = Int((x * scale).rounded(.down))
        let py = Int((y * scale).rounded(.down))
        guard px >= 0, py >= 0, px < width, py < height else { return nil }
        let index = (py * width + px) * 4
        let alpha = Double(bytes[index + 3]) / 255
        guard alpha > 0.99 else { return nil }
        return AtticRGBA(red: Double(bytes[index]) / 255, green: Double(bytes[index + 1]) / 255, blue: Double(bytes[index + 2]) / 255)
    }

    /// What lies behind a text run or icon: its frame's four corners, inset
    /// by a pixel, taking the second most background-like sample (robust to
    /// one corner touching a glyph).
    /// Text is sampled just inside its frame's corners (above the cap height
    /// and beside the glyphs); icons, which can fill their frame (a
    /// checkbox), just outside.
    func background(around frame: CGRect, outside: Bool, foreground: AtticRGBA, scale: CGFloat) -> AtticRGBA? {
        let inset = outside ? -1.5 : 1 / scale + 0.25
        let points = [
            (frame.minX + inset, frame.minY + inset), (frame.maxX - inset, frame.minY + inset),
            (frame.minX + inset, frame.maxY - inset), (frame.maxX - inset, frame.maxY - inset)
        ]
        let samples = points.compactMap { colour(atX: $0.0, y: $0.1, scale: scale) }
        guard !samples.isEmpty else { return nil }
        let target = foreground.relativeLuminance
        let sorted = samples.sorted { abs($0.relativeLuminance - target) > abs($1.relativeLuminance - target) }
        return sorted.count >= 2 ? sorted[1] : sorted[0]
    }
}
#endif
