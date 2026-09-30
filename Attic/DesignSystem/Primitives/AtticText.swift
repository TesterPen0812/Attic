import SwiftUI

/// Every piece of design-system text goes through this view, so each run
/// has a role (`AtticInk`) and a style, never wraps (labels truncate; only
/// Settings helper text wraps, to at most three lines), and is measurable by
/// the appearance check.
struct AtticText: View {
    let string: String
    let style: AtticTextStyle
    let ink: AtticInk
    var strikethrough = false
    var allowsOverlap = false
    /// User content (a task title) may truncate with an ellipsis; interface
    /// copy never may, and the appearance check fails it if it does.
    var truncates = false
    /// Search matches in user content: the find highlight behind them,
    /// the letters in the primary ink (the Done search, owner item 17).
    var highlights: [Range<String.Index>] = []

    @Environment(\.atticDesign) private var design
    @Environment(\.atticCapture) private var capture
    @State private var probeID = UUID()

    /// Localised text (every string lives in the String Catalog).
    init(_ value: String.LocalizationValue, style: AtticTextStyle, ink: AtticInk, strikethrough: Bool = false) {
        self.string = String(localized: value)
        self.style = style
        self.ink = ink
        self.strikethrough = strikethrough
    }

    /// User content (task titles, tags) that must not be localised.
    init(verbatim string: String, style: AtticTextStyle, ink: AtticInk, strikethrough: Bool = false, truncates: Bool = false,
         allowsOverlap: Bool = false, highlights: [Range<String.Index>] = []) {
        self.string = string
        self.style = style
        self.ink = ink
        self.strikethrough = strikethrough
        self.truncates = truncates
        self.allowsOverlap = allowsOverlap
        self.highlights = highlights
    }

    private var text: Text {
        guard !highlights.isEmpty else { return Text(verbatim: string).font(style.font) }
        var attributed = AttributedString(string)
        let tokens = design.tokens
        for range in highlights {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = tokens.findHighlight.color
            attributed[lower..<upper].foregroundColor = tokens.ink(.heading).color
        }
        return Text(attributed).font(style.font)
    }

    var body: some View {
        let color = design.tokens.ink(ink)
        text
            .foregroundStyle(color.color)
            .strikethrough(strikethrough, color: color.color)
            .lineLimit(style.mayWrap ? 3 : 1)
            .truncationMode(.tail)
            .background {
                if let collector = capture?.collector, !style.mayWrap {
                    AtticIdealSizeReporter(id: probeID, text: text, collector: collector)
                }
            }
            .atticProbe { [probeID, string, style, ink, allowsOverlap, truncates] specimen in
                AtticProbe(
                    id: probeID,
                    kind: .text(style: style, string: string),
                    ink: ink,
                    foreground: color,
                    specimen: specimen,
                    allowsOverlap: allowsOverlap,
                    allowsTruncation: truncates
                )
            }
    }
}

/// An SF Symbol in an ink. Outline symbols only (filled ones only for
/// state), 13–14 pt, lighter than text unless inside a control.
struct AtticIcon: View {
    let systemName: String
    var size: CGFloat = AtticControlSize.glyph
    var weight: Font.Weight = .regular
    let ink: AtticInk

    @Environment(\.atticDesign) private var design
    @State private var probeID = UUID()

    var body: some View {
        let color = design.tokens.ink(ink)
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color.color)
            .accessibilityHidden(true)
            .atticProbe { [probeID, systemName, ink] specimen in
                AtticProbe(id: probeID, kind: .icon(name: systemName), ink: ink, foreground: color, specimen: specimen)
            }
    }
}
