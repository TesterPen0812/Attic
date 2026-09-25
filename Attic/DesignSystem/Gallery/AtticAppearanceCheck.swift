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
///   behind it, to the rule in `AtticSurfaceModel`: all text 4.5 : 1 on
///   Solid (tinted or not) and under Increase Contrast or Reduce
///   Transparency; on Glass and Frosted body text and labels 4.5 : 1 and
///   helper text at least 3 : 1; icons, circles, rings and priority colours
///   3 : 1 everywhere. Glass and Frosted are rendered over a black, a
///   mid-grey and a white desktop, each drawn as its measured native render.
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
        enum Kind: String { case contrast, glyphContrast, unmeasured, clipped, overlap, outOfBounds, size, radius, geometry, model, render, native }
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
        /// Glyphs whose contrast was read from their own pixels.
        var glyphsMeasured = 0
        /// Text runs and icons with an ink and a real frame: each must be
        /// measured, or it fails as unmeasured.
        var eligibleProbes = 0
        /// Eligible probes in 2× renders, whose glyph pixels must be read.
        var eligibleGlyphs = 0
        /// Controls whose corner radius and size were fitted from pixels.
        var geometryMeasured = 0
        /// Unique failures, each with the combinations it happened in.
        var failures: [Failure: [String]] = [:]
        /// Foundation and Tint strength per palette, mode and surface, under
        /// both translucency policies: the numbers behind the look.
        var surfaceTable: [String] = []
        var worstContrast: [String: (ratio: Double, floor: Double, where: String)] = [:]
        /// The lowest glyph contrast read from pixels, per role.
        var worstGlyph: [String: (ratio: Double, floor: Double, where: String)] = [:]
        /// Measured corner radii and sizes (control, measured, token).
        var geometryTable: [String] = []

        mutating func fail(_ failure: Failure, in combination: String) {
            failures[failure, default: []].append(combination)
        }

        /// Passed: no failures, and every eligible probe measured, its
        /// background and (at 2×) its glyph pixels. A 1× run, which reads no
        /// glyph pixels, never passes.
        var passed: Bool {
            failures.isEmpty && eligibleProbes > 0
                && contrastPairsChecked == eligibleProbes
                && eligibleGlyphs == eligibleProbes && glyphsMeasured == eligibleGlyphs
        }

        var headline: String {
            "\(combinations) combinations, \(renders) renders, \(probesChecked) probes, \(contrastPairsChecked) contrast checks, \(glyphsMeasured) of \(eligibleGlyphs) glyphs measured from pixels, \(geometryMeasured) corners and sizes fitted from pixels, \(failures.count) distinct failures"
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
            lines.append("Surfaces: coverage over the desktop, and each Tint step's colour difference at the top edge (ΔE76; designed 3 / 7 / 12):")
            lines.append(contentsOf: surfaceTable.map { "  " + $0 })
            lines.append("")
            lines.append("Lowest contrast per role, declared ink on the sampled background (ratio / floor):")
            for (role, value) in worstContrast.sorted(by: { $0.key < $1.key }) {
                lines.append(String(format: "  %@: %.2f / %.1f  (%@)", role, value.ratio, value.floor, value.where))
            }
            if !worstGlyph.isEmpty {
                lines.append("")
                lines.append("Lowest contrast per role, read from the glyph's own pixels (ratio / floor):")
                for (role, value) in worstGlyph.sorted(by: { $0.key < $1.key }) {
                    lines.append(String(format: "  %@: %.2f / %.1f  (%@)", role, value.ratio, value.floor, value.where))
                }
            }
            if !geometryTable.isEmpty {
                lines.append("")
                lines.append("Corners and sizes fitted from pixels (measured / token):")
                lines.append(contentsOf: geometryTable.map { "  " + $0 })
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
            ("Stress · Increase Contrast + Reduce Transparency, Dark", AtticDesignContext(mode: .dark, increaseContrast: true, reduceTransparency: true))
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
        checkGeometry(report: &report)
        for context in contexts {
            let desktops: [AtticSurfaceModel.Desktop] = context.isTranslucent ? AtticSurfaceModel.Desktop.allCases : [.midGrey]
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
        for context in contexts {
            let tokens = context.tokens
            let pairs = AtticSurfaceModel.readabilityPairs(
                inks: tokens.inks, hover: tokens.hover, selected: tokens.selected, pressed: tokens.pressed,
                controlFace: tokens.controlFace, glassFace: tokens.glassFace, glassDisabled: tokens.glassDisabled, glassPressed: tokens.glassPressed, chipSelected: tokens.chipSelected, chipHover: tokens.chipHover,
                recessed: tokens.recessed, tagFill: tokens.tagFill, tagFillSelected: tokens.tagFillSelected
            )
            if tokens.panel.worstMargin(pairs) < 0.999 {
                report.fail(.init(kind: .model, family: "Model", specimen: "Panel surface", detail: String(format: "worst margin %.3f", tokens.panel.worstMargin(pairs))), in: context.caption)
            }
            // Cards and menus are base style: their text is judged on the
            // card itself. Disabled text and icons included (nothing is exempt).
            for (card, name) in [(tokens.contentCard, "content card"), (tokens.groupCard, "group card"), (tokens.popoverFill, "menu")] {
                for ink in [AtticInk.heading, .body, .label, .helper, .disabledText, .disabledIcon] {
                    let ratio = tokens.ink(ink).contrast(on: card)
                    let floor = AtticSurfaceModel.floor(for: ink, kind: context.effectiveSurface, increaseContrast: context.increaseContrast)
                    if ratio < floor {
                        report.fail(.init(kind: .model, family: "Model", specimen: name, detail: String(format: "%@ %.2f < %.1f", ink.rawValue, ratio, floor)), in: context.caption)
                    }
                }
            }
        }
        report.surfaceTable = surfaceTable()
    }

    /// Corner radii and sizes fitted from the pixels of a representative
    /// set of controls (`AtticGeometryCheck`).
    static func checkGeometry(report: inout Report) {
        for result in AtticGeometryCheck.run() {
            report.geometryMeasured += 1
            report.geometryTable.append(result.line)
            for problem in result.problems {
                report.fail(.init(kind: .geometry, family: "Geometry", specimen: result.specimen, detail: problem), in: "Light · Original · Solid")
            }
        }
    }

    static func surfaceTable() -> [String] {
        var lines: [String] = []
        for mode in AtticDesignContext.Mode.allCases {
            for palette in AtticPanelTheme.allCases {
                for surface in PanelSurfaceStyle.allCases {
                    let plain = AtticDesignContext(mode: mode, palette: palette, surface: surface).tokens.panel
                    var line = "\(mode.title) · \(palette.title) · \(surface.title): coverage \(Int((plain.foundationOpacity * 100).rounded())) %, tint ΔE"
                    for tint in [PanelTintLevel.subtle, .vivid, .bold] {
                        let tinted = AtticDesignContext(mode: mode, palette: palette, surface: surface, tint: tint).tokens.panel
                        let difference = ColorDifference.deltaE76(tinted.composite(.midGrey).themeColor, plain.composite(.midGrey).themeColor)
                        line += String(format: " %.1f", difference)
                    }
                    lines.append(line)
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
        // The rule (see `AtticSurfaceModel`): all text 4.5 : 1 on Solid and
        // under Increase Contrast; on Glass and Frosted helper text keeps
        // 3 : 1 and everything else 4.5 : 1; icons 3 : 1 everywhere.

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
        checkContrast(visual, bitmap: bitmap, scale: scale, context: context, family: family.title, combination: combination, report: &report)

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

    /// Every eligible text run and icon (one with an ink and a real frame)
    /// is judged against the rendered pixels. Nothing is skipped silently:
    /// a probe whose background cannot be sampled fails, and at 2× (where a
    /// glyph's core resolves) so does a probe whose glyph drew no pixels —
    /// a missing or invisible glyph is a failure, not a pass.
    static func checkContrast(
        _ visual: [AtticProbe],
        bitmap: AtticBitmap,
        scale: CGFloat,
        context: AtticDesignContext,
        family: String,
        combination: String,
        report: inout Report
    ) {
        let measuresGlyphs = scale >= 2
        for probe in visual {
            guard let ink = probe.ink, let foreground = probe.foreground,
                  !probe.frame.isNull, probe.frame.width > 1, probe.frame.height > 1 else { continue }
            report.eligibleProbes += 1
            let isIcon: Bool = if case .icon = probe.kind { true } else { false }
            let specimen = displayName(probe.specimen)
            let floor = AtticSurfaceModel.floor(for: ink, kind: context.effectiveSurface, increaseContrast: context.increaseContrast)
            let floorText = floor == 4.5 ? "4.5" : String(format: "%.1f", floor)
            let sampled: AtticRGBA? = if let points = probe.backgroundSamples {
                bitmap.background(at: points, in: probe.frame, scale: scale)
            } else {
                bitmap.background(around: probe.frame, outside: isIcon, foreground: foreground, scale: scale)
            }
            guard let background = sampled else {
                report.fail(.init(kind: .unmeasured, family: family, specimen: specimen,
                                  detail: "\(label(probe)) \(ink.rawValue): no background pixels to measure against"), in: combination)
                continue
            }
            let ratio = foreground.contrast(on: background)
            report.contrastPairsChecked += 1
            let role = "\(ink.rawValue) (\(ink.floor == .text ? "text" : "non-text"))"
            let place = "\(family) › \(label(probe)) · \(combination)"
            if let current = report.worstContrast[role] {
                if ratio / floor < current.ratio / current.floor { report.worstContrast[role] = (ratio, floor, place) }
            } else {
                report.worstContrast[role] = (ratio, floor, place)
            }
            if ratio + 0.005 < floor {
                report.fail(.init(
                    kind: .contrast, family: family, specimen: specimen,
                    detail: "\(label(probe)) \(ink.rawValue) below \(floorText) : 1"
                ), in: combination + String(format: " (%.2f on %@)", ratio, background.hexString))
            }
            // Independently, the glyph's own pixels (needs 2× to resolve a
            // glyph's core from its antialiased edge).
            guard measuresGlyphs else { continue }
            report.eligibleGlyphs += 1
            guard let glyph = bitmap.glyphContrast(in: probe.frame, background: background, scale: scale) else {
                report.fail(.init(kind: .unmeasured, family: family, specimen: specimen,
                                  detail: "\(label(probe)) \(ink.rawValue): no glyph pixels were drawn"), in: combination)
                continue
            }
            report.glyphsMeasured += 1
            if let current = report.worstGlyph[role] {
                if glyph.ratio / floor < current.ratio / current.floor { report.worstGlyph[role] = (glyph.ratio, floor, place) }
            } else {
                report.worstGlyph[role] = (glyph.ratio, floor, place)
            }
            if glyph.ratio + glyphTolerance < floor {
                report.fail(.init(
                    kind: .glyphContrast, family: family, specimen: specimen,
                    detail: "\(label(probe)) \(ink.rawValue) glyph pixels below \(floorText) : 1"
                ), in: combination + String(format: " (%.2f: %@ on %@)", glyph.ratio, glyph.ink.hexString, background.hexString))
            }
        }
    }

    /// Rendering (8-bit, antialiased, the core percentile) can read a glyph
    /// a touch lighter than its ink; a glyph fails only below this slack.
    static let glyphTolerance = 0.12

    /// Controls whose radius must follow the 42 %-of-height rule.
    static let controlRuleNames: Set<String> = [
        "Single button", "Label button", "Page switch", "Add bar", "Small control",
        "Selection bar", "Toast", "Pop-over row", "Title menu", "Tag"
    ]

    /// "Family / Caption#id" → "Caption".
    static func displayName(_ specimen: String) -> String {
        let caption = specimen.components(separatedBy: " / ").dropFirst().joined(separator: " / ")
        return caption.components(separatedBy: "#").first ?? caption
    }

    static func label(_ probe: AtticProbe) -> String {
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

extension AtticAppearanceCheck {
    /// The composed panel alone, default Light and Dark, 320 × 520 at 2×:
    /// `panel-render-light.png` and `panel-render-dark.png`.
    static func writePanelRenders(to directory: URL) {
        for mode in AtticDesignContext.Mode.allCases {
            let view = AtticGalleryPanelComposition(demo: AtticGalleryDemo())
                .environment(AtticGalleryDemo())
                .atticDesign(AtticDesignContext(mode: mode))
                .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: .wallpaper(.matchingMode)))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            renderer.isOpaque = false
            guard let image = renderer.cgImage else { continue }
            let url = directory.appendingPathComponent("panel-render-\(mode.rawValue).png")
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
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
                                .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: .wallpaper(.matchingMode)))
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

    /// What lies behind a glyph drawn on a fill (a check on its circle):
    /// the median of the given points (unit coordinates of the frame) that
    /// the glyph never touches.
    func background(at points: [CGPoint], in frame: CGRect, scale: CGFloat) -> AtticRGBA? {
        let samples = points.compactMap { colour(atX: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height, scale: scale) }
        guard !samples.isEmpty else { return nil }
        return samples.sorted { $0.relativeLuminance < $1.relativeLuminance }[samples.count / 2]
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
