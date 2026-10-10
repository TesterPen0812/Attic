import AppKit

extension NSAttributedString.Key {
    /// A text paragraph's optional identity (`NoteBlock.id`), as a UUID.
    static let noteBlockID = NSAttributedString.Key("com.taha.attic.note.blockID")
    /// A paragraph's unknown fields (`NoteBlockExtras`), written back as read.
    static let noteBlockExtras = NSAttributedString.Key("com.taha.attic.note.blockExtras")
    /// A text paragraph's style name (`NoteBlock.style`).
    static let noteBlockStyle = NSAttributedString.Key("com.taha.attic.note.blockStyle")
    static let noteBlockLevel = NSAttributedString.Key("com.taha.attic.note.blockLevel")
    static let noteBlockIndent = NSAttributedString.Key("com.taha.attic.note.blockIndent")
    static func noteMark(_ kind: NoteMark.Kind) -> NSAttributedString.Key {
        NSAttributedString.Key("com.taha.attic.note.mark.\(kind.rawValue)")
    }

    /// Identity and unknown fields belong to their original paragraph. Style,
    /// heading level and indentation must carry into text typed in that paragraph.
    static let noteBookkeeping: Set<NSAttributedString.Key> = [.noteBlockID, .noteBlockExtras]
}

/// A reference box, so a paragraph split can tell that both halves carry the
/// same original fields (the second half then drops them).
final class NoteBlockExtras: NSObject {
    let fields: [String: NoteJSON]
    init(_ fields: [String: NoteJSON]) { self.fields = fields }
}

/// What a paragraph is, for its spacing and what is drawn beside it.
enum NoteParagraphKind: Equatable, Sendable {
    /// The note's first line.
    case title
    case titleStyle, heading, subheading
    /// Body text, and list and checklist items.
    case body
    case quote, mono
    /// An image, a file or a divider on its own line.
    case blockObject

    var isHeading: Bool { self == .titleStyle || self == .heading || self == .subheading }

    var role: AtticNoteType.Role {
        switch self {
        case .title: AtticNoteType.title
        case .titleStyle: AtticNoteType.titleStyle
        case .heading: AtticNoteType.heading
        case .subheading: AtticNoteType.subheading
        case .body, .blockObject: AtticNoteType.body
        case .quote: AtticNoteType.quote
        case .mono: AtticNoteType.mono
        }
    }

    /// A paragraph's kind from its stored style name and heading level.
    static func of(style name: String?, level: Int?) -> NoteParagraphKind {
        switch name {
        case "heading": (level ?? 2) <= 1 ? .titleStyle : (level == 2 ? .heading : .subheading)
        case "mono": .mono
        case "quote": .quote
        default: .body
        }
    }
}

/// The editor's look, from the design system only (fonts and spacing from
/// `AtticNoteType`, inks from the resolved tokens).
///
/// Notes v2, text direction 5 (owner, 2026-10-08): SF Pro throughout, one
/// near-black ink. Every line box is exactly its role's line height; the
/// space between two blocks is the lower paragraph's
/// `paragraphSpacingBefore` (`paragraphSpacing` stays 0, so nothing is
/// counted twice), from `gap(above:after:)`. TextKit sets a line's glyphs on
/// the line box's floor where the draft (CSS) centres them in it, so each
/// paragraph is raised by its role's `baselineShift`: its glyphs land on the
/// draft's baselines while the gaps between line boxes stay the draft's.
///
/// With tags, the title's paragraph reserves room under it for the tag line
/// (4 above it, 8 below); its lines keep clear of the ⋯ at the end of the
/// first line (`titleTrailingReserve`).
struct NoteTextStyle: Equatable {
    var design: AtticDesignContext = .default
    /// Height of the tag line drawn under the title (0: no tags).
    var tagLineHeight: CGFloat = 0
    /// Room kept at the end of the title's lines for the note menu button.
    var titleTrailingReserve: CGFloat = 0

    typealias T = AtticNoteType
    static let titleLineHeight: CGFloat = T.title.lineHeight
    static let bodyLineHeight: CGFloat = T.body.lineHeight
    static let bodyParagraphGap: CGFloat = T.paragraphGap
    static let titleToBody: CGFloat = T.titleToText
    static let titleToTags: CGFloat = 3
    static let tagsToBody: CGFloat = T.titleToText - titleToTags

    // MARK: Fonts

    /// SF Pro (or SF Mono) at a role's size and weight. The headings' 650
    /// sits between semibold and bold on SF Pro's weight axis, as drawn.
    static func font(for role: T.Role) -> NSFont {
        if let cached = fontCache.value[role] { return cached }
        let font: NSFont
        if role.monospaced {
            font = NSFont.monospacedSystemFont(ofSize: role.size, weight: role.weight >= 600 ? .semibold : .regular)
        } else if role.weight == 400 {
            font = NSFont.systemFont(ofSize: role.size, weight: .regular)
        } else if role.weight == 700 {
            font = NSFont.systemFont(ofSize: role.size, weight: .bold)
        } else {
            let base = NSFont.systemFont(ofSize: role.size, weight: .semibold)
            let axis = NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            let wght = 0x7767_6874 // 'wght'
            font = NSFont(descriptor: base.fontDescriptor.addingAttributes([axis: [wght: role.weight]]), size: role.size) ?? base
        }
        fontCache.value[role] = font
        return font
    }

    private final class FontCache: @unchecked Sendable { var value: [T.Role: NSFont] = [:] }
    private static let fontCache = FontCache()

    var titleFont: NSFont { Self.font(for: T.title) }
    var bodyFont: NSFont { Self.font(for: T.body) }
    var titleStyleFont: NSFont { Self.font(for: T.titleStyle) }
    var headingFont: NSFont { Self.font(for: T.heading) }
    var subheadingFont: NSFont { Self.font(for: T.subheading) }
    var quoteFont: NSFont { Self.font(for: T.quote) }
    var monoFont: NSFont { Self.font(for: T.mono) }

    func font(for kind: NoteParagraphKind) -> NSFont { Self.font(for: kind.role) }

    // MARK: Inks

    var tokens: AtticColorTokens { AtticColorTokens.resolve(design) }
    /// One near-black ink for the title, the headings, the body and quotes.
    var titleColor: NSColor { tokens.ink(.heading).nsColor }
    var bodyColor: NSColor { tokens.ink(.heading).nsColor }
    var quoteColor: NSColor { bodyColor }
    var secondaryColor: NSColor { tokens.ink(.helper).nsColor }
    /// List numbers are quieter than the text; bullets are in the text's ink.
    var markerColor: NSColor { secondaryColor }
    var placeholderColor: NSColor { tokens.hintInk.nsColor }
    /// A plain grey wash behind proportional text (owner 2026-10-10); code keeps
    /// its monospaced font and its own, lighter accent-tinted chip.
    var highlightColor: NSColor { tokens.highlightMarker.nsColor }
    var codeColor: NSColor { tokens.tagFill.nsColor }
    /// A quote's bar: the quiet grey, with rounded ends (F-02).
    var quoteBarColor: NSColor { tokens.quoteBar.nsColor }
    /// Links: blue, with their underline in the same blue at 55 %.
    var linkColor: NSColor { tokens.ink(.linkText).nsColor }
    var linkUnderlineColor: NSColor { tokens.linkUnderline.nsColor }
    /// The Mono block's fill (Light black 4.5 %, Dark white 5.5 %) and,
    /// under Increase Contrast, its edge.
    var codeBlockColor: NSColor { tokens.recessed.nsColor }
    var codeBlockBorder: NSColor? { tokens.recessedBorder?.nsColor }

    // MARK: Lines

    /// How far TextKit sets a role's baseline below where the draft (CSS)
    /// does in the same line box: TextKit puts the glyphs on the box's floor
    /// (the baseline its rounded descent above the bottom), CSS centres them.
    static func baselineShift(_ role: T.Role) -> CGFloat {
        let font = font(for: role)
        let natural = font.ascender - font.descender + font.leading
        let native = role.lineHeight - (-font.descender).rounded()
        let drawn = (role.lineHeight - natural) / 2 + font.ascender
        return native - drawn
    }

    /// The shift a paragraph's own line boxes carry. A Mono block and a
    /// block object place their contents inside their own box, so the box
    /// itself is not raised.
    static func boxShift(_ kind: NoteParagraphKind) -> CGFloat {
        switch kind {
        case .mono, .blockObject: 0
        default: baselineShift(kind.role)
        }
    }

    /// The draft's gap between the line boxes of `previous` and `kind`.
    static func gap(above kind: NoteParagraphKind, after previous: NoteParagraphKind?) -> CGFloat {
        guard let previous else { return 0 }
        if previous == .title { return T.titleToText }
        switch kind {
        case .titleStyle: return T.aboveTitleStyle
        case .heading: return T.aboveHeading
        case .subheading: return T.aboveSubheading
        default: break
        }
        if previous.isHeading {
            let below = previous == .titleStyle ? T.belowTitleStyle : (previous == .heading ? T.belowHeading : T.belowSubheading)
            return kind == .mono || kind == .blockObject ? max(below, T.blockAfterHeading) : below
        }
        if kind == .mono, previous == .mono { return 0 }
        if [.mono, .blockObject].contains(kind) || [.mono, .blockObject].contains(previous) { return T.blockMargin }
        return T.paragraphGap
    }

    /// The paragraph's `paragraphSpacingBefore`: the draft's gap, with each
    /// side's baseline shift taken into the space between them.
    static func spacingBefore(_ kind: NoteParagraphKind, after previous: NoteParagraphKind?) -> CGFloat {
        guard let previous else { return 0 }
        let gap = gap(above: kind, after: previous)
        return max(0, gap - boxShift(kind) + boxShift(previous))
    }

    /// The width of a Mono line's leading spaces and tabs: its soft wraps
    /// hang from there.
    func monoHang(for line: String) -> CGFloat {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        guard !leading.isEmpty else { return 0 }
        return ceil((String(leading) as NSString).size(withAttributes: [.font: monoFont]).width * 2) / 2
    }

    // MARK: Attributes

    var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: titleFont, .foregroundColor: titleColor, .paragraphStyle: titleParagraphStyle]
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: bodyParagraphStyle]
    }

    /// A paragraph's attributes. `previous` is the kind of the paragraph
    /// above it (nil: none, or not known; the engine restyles every edited
    /// paragraph and its neighbours with the real one).
    func paragraphAttributes(style name: String?, level: Int?, indent: Int?, previous: NoteParagraphKind? = .body,
                             isChecklist: Bool = false, isBlockObject: Bool = false,
                             monoHang: CGFloat = 0, monoExitsAtEnd: Bool = false) -> [NSAttributedString.Key: Any] {
        let kind: NoteParagraphKind = isBlockObject ? .blockObject : NoteParagraphKind.of(style: name, level: level)
        var result = bodyAttributes
        result[.font] = font(for: kind)
        result[.foregroundColor] = kind == .quote ? quoteColor : bodyColor
        let paragraph = NSMutableParagraphStyle()
        if kind != .blockObject {
            paragraph.minimumLineHeight = kind.role.lineHeight
            paragraph.maximumLineHeight = kind.role.lineHeight
        }
        paragraph.paragraphSpacingBefore = Self.spacingBefore(kind, after: previous)
        let depth = CGFloat(indent ?? 0) * T.listLevelStep
        switch kind {
        case .mono:
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = monoHang
            if monoExitsAtEnd {
                // The block's bottom padding goes before the note's empty
                // last line, which TextKit lays out in this paragraph
                // (`NoteBlockLayoutFragment` then adds no margin); that line
                // keeps its own space before, as any paragraph below a block.
                paragraph.paragraphSpacing = T.monoPaddingV + Self.baselineShift(T.mono)
            }
        case .quote:
            paragraph.firstLineHeadIndent = depth + T.quoteTextInset
            paragraph.headIndent = depth + T.quoteTextInset
        default:
            let list = name == "bullet" || name == "number"
            paragraph.firstLineHeadIndent = depth + (list ? T.listTextInset : 0)
            // A list item's or checklist line's wraps hang at its text.
            paragraph.headIndent = depth + (list || isChecklist ? T.listTextInset : 0)
        }
        if name == "bullet" {
            paragraph.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        } else if name == "number" {
            paragraph.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        }
        result[.paragraphStyle] = paragraph
        return result
    }

    /// Presentation always comes from the complete semantic mark set. In
    /// particular, code chooses the family before bold/italic add traits.
    func markedAttributes(marks: [NoteMark.Kind: Any], baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        let source = marks[.code] == nil ? baseFont : monoFont
        var desired = source.fontDescriptor.symbolicTraits
        if marks[.bold] != nil { desired.insert(.bold) }
        if marks[.italic] != nil { desired.insert(.italic) }
        var font = marks[.code] == nil && marks[.bold] == nil && marks[.italic] == nil
            ? baseFont
            : NSFont(descriptor: source.fontDescriptor.withSymbolicTraits(desired), size: source.pointSize) ?? source
        if desired.contains(.italic), !font.fontDescriptor.symbolicTraits.contains(.italic) {
            let fallback = marks[.code] == nil
                ? NSFont.systemFont(ofSize: source.pointSize, weight: desired.contains(.bold) ? .bold : .regular)
                : NSFont.monospacedSystemFont(ofSize: source.pointSize, weight: desired.contains(.bold) ? .bold : .regular)
            font = NSFont(descriptor: fallback.fontDescriptor.withSymbolicTraits(desired), size: source.pointSize)
                ?? NSFontManager.shared.convert(fallback, toHaveTrait: .italicFontMask)
        }
        var result: [NSAttributedString.Key: Any] = [.font: font]
        if marks[.code] != nil { result[.backgroundColor] = codeColor }
        if marks[.highlight] != nil { result[.backgroundColor] = highlightColor }
        if marks[.underline] != nil || marks[.link] != nil {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if marks[.strikethrough] != nil { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let url = marks[.link] as? String, let value = URL(string: url) {
            result[.link] = value
            result[.foregroundColor] = linkColor
            result[.underlineColor] = linkUnderlineColor
        }
        return result
    }

    /// The room the title's paragraph keeps under its last line: the tag
    /// line with 4 above it and 8 below, less the 12 the first block keeps
    /// from the title itself (its own spacing before).
    var titleParagraphSpacing: CGFloat {
        tagLineHeight > 0 ? Self.titleToTags + tagLineHeight + Self.tagsToBody - Self.titleToBody : 0
    }

    var titleParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = Self.titleLineHeight
        style.maximumLineHeight = Self.titleLineHeight
        style.paragraphSpacing = titleParagraphSpacing
        style.tailIndent = -titleTrailingReserve
        return style
    }

    var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = Self.bodyLineHeight
        style.maximumLineHeight = Self.bodyLineHeight
        style.paragraphSpacingBefore = Self.spacingBefore(.body, after: .body)
        return style
    }

    /// Extra space between lines that brings the font's own line to `lineHeight`.
    static func lineSpacing(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        let natural = font.ascender - font.descender + font.leading
        return max(0, lineHeight - natural)
    }

    // MARK: Table cells

    /// The header row's face: the body's size, semibold.
    var tableHeaderFont: NSFont { NSFont.systemFont(ofSize: AtticNoteType.body.size, weight: .semibold) }

    /// A cell's text: the body's 14 / 21 lines, no paragraph spacing, in
    /// its column's alignment; the header row is semibold.
    func tableCellAttributes(header: Bool, alignment: NoteTable.Alignment = .left) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = AtticNoteType.body.lineHeight
        paragraph.maximumLineHeight = AtticNoteType.body.lineHeight
        paragraph.alignment = switch alignment {
        case .left: .natural
        case .center: .center
        case .right: .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: header ? tableHeaderFont : bodyFont, .foregroundColor: bodyColor, .paragraphStyle: paragraph]
    }
}
