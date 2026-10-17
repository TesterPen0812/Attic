import AppKit

/// Typed and imported destinations share one explicit web-link policy.
enum NoteLinkPolicy {
    static func url(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }

    @MainActor
    @discardableResult
    static func open(_ value: String, using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard let url = url(value) else { return false }
        return opener(url)
    }
}

extension NSAttributedString.Key {
    /// A text paragraph's optional identity (`NoteBlock.id`), as a UUID.
    static let noteBlockID = NSAttributedString.Key("com.taha.attic.note.blockID")
    /// A paragraph's unknown fields (`NoteBlockExtras`), written back as read.
    static let noteBlockExtras = NSAttributedString.Key("com.taha.attic.note.blockExtras")
    /// A text paragraph's style name (`NoteBlock.style`).
    static let noteBlockStyle = NSAttributedString.Key("com.taha.attic.note.blockStyle")
    static let noteBlockLevel = NSAttributedString.Key("com.taha.attic.note.blockLevel")
    static let noteCodeLanguage = NSAttributedString.Key("com.taha.attic.note.codeLanguage")
    static let noteCalloutIcon = NSAttributedString.Key("com.taha.attic.note.calloutIcon")
    static let noteListStart = NSAttributedString.Key("com.taha.attic.note.listStart")
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
    case titleStyle, heading, subheading, smallHeading
    /// Body text.
    case body
    /// A bulleted or numbered item, or a checklist line (items sit 3 apart).
    case listItem
    case quote, mono
    /// A callout paragraph; consecutive ones with the same icon share a box.
    case callout(icon: String)
    /// An image, a file or a table on its own line.
    case blockObject
    /// A divider: a 1 pt rule centred in one body line, so its gaps are
    /// measured to the rule.
    case divider

    var isHeading: Bool { self == .titleStyle || self == .heading || self == .subheading || self == .smallHeading }
    var isCallout: Bool { if case .callout = self { true } else { false } }
    /// A box (code, a callout, a quote run) or a block object: 12 around it.
    var isBox: Bool { self == .mono || self == .blockObject || self == .divider || self == .quote || isCallout }

    var role: AtticNoteType.Role {
        switch self {
        case .title: AtticNoteType.title
        case .titleStyle: AtticNoteType.titleStyle
        case .heading: AtticNoteType.heading
        case .subheading: AtticNoteType.subheading
        case .smallHeading: AtticNoteType.smallHeading
        case .body, .listItem, .blockObject, .divider, .callout: AtticNoteType.body
        case .quote: AtticNoteType.quote
        case .mono: AtticNoteType.mono
        }
    }

    /// A paragraph's kind from its stored style name, heading level and
    /// callout icon; `isChecklist` for a line that starts with a checkbox.
    static func of(style name: String?, level: Int?, callout: String? = nil, isChecklist: Bool = false) -> NoteParagraphKind {
        switch name {
        case "heading": (level ?? 2) <= 1 ? .titleStyle : (level == 2 ? .heading : ((level ?? 2) <= 3 ? .subheading : .smallHeading))
        case "mono": .mono
        case "quote": callout.map { .callout(icon: $0) } ?? .quote
        case "bullet", "number": .listItem
        default: isChecklist ? .listItem : .body
        }
    }
}

/// The editor's look, from the design system only (fonts and spacing from
/// `AtticNoteType`, inks from the resolved tokens).
///
/// Notes v2, text direction 5 (owner, 2026-10-08): SF Pro throughout, one
/// near-black ink. Lines are exactly their role's line height apart: each
/// is the font's natural box with the rest of the pitch as line spacing
/// above it (`setLines`, O18-03), so AppKit's caret is the natural one; the
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
    var smallHeadingFont: NSFont { Self.font(for: T.smallHeading) }
    var codeLabelFont: NSFont { Self.font(for: T.codeLabel) }
    /// Inline code's face: SF Mono at 11 in its chip, whatever the run's size.
    var inlineCodeFont: NSFont { Self.font(for: T.Role(size: T.inlineCodeSize, lineHeight: T.body.lineHeight, weight: 400, monospaced: true)) }

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
    /// The plain yellow highlight (owner 2026-10-16); code keeps
    /// its monospaced font and its own, lighter accent-tinted chip.
    var highlightColor: NSColor { tokens.highlightMarker.nsColor }
    /// The caret: the system's insertion point colour (the accent), as in
    /// Apple's own text views, so it reads lighter than the near-black text
    /// beside it (F-03c: the body-ink caret read heavy).
    var caretColor: NSColor { .textInsertionPointColor }
    /// A highlight's wash in its colour (N-2): a stored key, or `true` for
    /// the unkeyed yellow one.
    func highlightColor(for value: Any?) -> NSColor {
        tokens.highlightMarker(NoteHighlightColour(storedKey: value as? String)).nsColor
    }
    var codeColor: NSColor { tokens.tagFill.nsColor }
    /// A quote's bar: the quiet grey, with rounded ends (F-02).
    var quoteBarColor: NSColor { tokens.quoteBar.nsColor }
    /// Links: blue, with their underline in the same blue at 55 %.
    var linkColor: NSColor { tokens.ink(.linkText).nsColor }
    /// A ticked checklist line's words (T-06 B): the secondary grey.
    var checkedChecklistColor: NSColor { tokens.ink(.helper).nsColor }
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

    /// The shift a paragraph's own line boxes carry. A code block, a
    /// callout and a block object place their contents inside their own
    /// box (its top and bottom padding take the shift), so the box itself
    /// is not raised.
    static func boxShift(_ kind: NoteParagraphKind) -> CGFloat {
        switch kind {
        case .mono, .blockObject, .divider, .callout: 0
        default: baselineShift(kind.role)
        }
    }

    /// The gap between the line boxes of `previous` and `kind` (B.3):
    /// paragraphs 8 apart, list items 3, boxes 12 around, headings 20 / 16
    /// / 14 / 12 above and 6 below, a heading 6 under a heading.
    static func gap(above kind: NoteParagraphKind, after previous: NoteParagraphKind?) -> CGFloat {
        guard let previous else { return 0 }
        if kind == .divider || previous == .divider {
            // 12 to the rule itself, which sits mid-line in its 18.5 pt box.
            let inset = (T.body.lineHeight - T.dividerThickness) / 2
            let plain = gap(above: kind == .divider ? .blockObject : kind, after: previous == .divider ? .blockObject : previous)
            return max(0, plain - inset)
        }
        if previous == .title { return T.titleToText }
        if kind.isHeading, previous.isHeading { return T.headingAfterHeading }
        switch kind {
        case .titleStyle: return T.aboveTitleStyle
        case .heading: return T.aboveHeading
        case .subheading: return T.aboveSubheading
        case .smallHeading: return T.aboveSmallHeading
        default: break
        }
        if previous.isHeading {
            let below = switch previous {
            case .titleStyle: T.belowTitleStyle
            case .heading: T.belowHeading
            case .subheading: T.belowSubheading
            default: T.belowSmallHeading
            }
            return kind.isBox ? max(below, T.blockAfterHeading) : below
        }
        if kind == .mono, previous == .mono { return 0 }
        if case let .callout(icon) = kind, case let .callout(above) = previous {
            return icon == above ? T.paragraphGap : T.blockMargin
        }
        if kind == .quote, previous == .quote { return T.paragraphGap }
        if kind.isBox || previous.isBox { return T.blockMargin }
        if kind == .listItem, previous == .listItem { return T.listItemGap }
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
                             isChecklist: Bool = false, isBlockObject: Bool = false, isDivider: Bool = false,
                             monoHang: CGFloat = 0, callout: String? = nil) -> [NSAttributedString.Key: Any] {
        let kind: NoteParagraphKind = isBlockObject ? (isDivider ? .divider : .blockObject)
            : NoteParagraphKind.of(style: name, level: level, callout: callout, isChecklist: isChecklist)
        var result = bodyAttributes
        result[.font] = font(for: kind)
        result[.foregroundColor] = kind == .quote ? quoteColor : bodyColor
        let paragraph = NSMutableParagraphStyle()
        if kind != .blockObject, kind != .divider {
            Self.setLines(of: paragraph, font: font(for: kind), pitch: kind.role.lineHeight)
        }
        paragraph.paragraphSpacingBefore = Self.spacingBefore(kind, after: previous)
        let depth = CGFloat(indent ?? 0) * T.listLevelStep
        switch kind {
        case .mono:
            // The box's sides: its text 12 in from each edge, as paragraph
            // indents (not the fragment's padding), so the note's empty last
            // line laid out in a final code block's fragment keeps its own
            // format's x (O18-04: the hint under a code block sat 12 pt in).
            paragraph.firstLineHeadIndent = T.monoPaddingH
            paragraph.headIndent = T.monoPaddingH + monoHang
            paragraph.tailIndent = -T.monoPaddingH
        case .quote:
            paragraph.firstLineHeadIndent = depth + T.quoteTextInset
            paragraph.headIndent = depth + T.quoteTextInset
        case let .callout(icon):
            // The box's sides: the text 36 in beside the emoji (12 in a
            // plain callout) and 12 from the box's right edge.
            let inset = icon.isEmpty ? T.calloutPaddingH : T.calloutTextInset
            paragraph.firstLineHeadIndent = inset
            paragraph.headIndent = inset
            paragraph.tailIndent = -T.calloutPaddingH
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
        let source = marks[.code] == nil ? baseFont : inlineCodeFont
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
        // Inline code draws as a chip behind its glyphs (`NoteBlockLayoutFragment`),
        // never as a flat background run.
        if let highlight = marks[.highlight] { result[.backgroundColor] = highlightColor(for: highlight) }
        if marks[.underline] != nil {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if marks[.link] != nil {
            // Codex's dotted underline, in the link's blue at 55 % (owner).
            result[.underlineStyle] = marks[.underline] != nil ? NSUnderlineStyle.single.rawValue
                : NSUnderlineStyle([.single, .patternDot]).rawValue
        }
        if marks[.strikethrough] != nil { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let url = marks[.link] as? String, let value = NoteLinkPolicy.url(url) {
            result[.link] = value
            result[.foregroundColor] = linkColor
            result[.underlineColor] = linkUnderlineColor
        }
        return result
    }

    /// Inline code's chip keeps 4 pt clear of its neighbours on each side
    /// (Codex's padding): the character before a code run and the run's
    /// last character carry 4 pt of kern. Presentation only; any kern in
    /// `range` is replaced, so a restyle always leaves exactly this.
    static func applyInlineCodeSpacing(to text: NSMutableAttributedString, in range: NSRange) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return }
        text.removeAttribute(.kern, range: range)
        let string = text.string as NSString
        text.enumerateAttribute(.noteMark(.code), in: range) { value, run, _ in
            guard value != nil, run.length > 0 else { return }
            let last = NSMaxRange(run) - 1
            if string.character(at: last) != 0x0A {
                text.addAttribute(.kern, value: T.inlineCodeChipPadding, range: NSRange(location: last, length: 1))
            }
            let before = run.location - 1
            if before >= range.location, string.character(at: before) != 0x0A,
               text.attribute(.noteMark(.code), at: before, effectiveRange: nil) == nil {
                text.addAttribute(.kern, value: T.inlineCodeChipPadding, range: NSRange(location: before, length: 1))
            }
        }
    }

    /// The room the title's paragraph keeps under its last line: the tag
    /// line with 4 above it and 8 below, less the 12 the first block keeps
    /// from the title itself (its own spacing before).
    var titleParagraphSpacing: CGFloat {
        tagLineHeight > 0 ? Self.titleToTags + tagLineHeight + Self.tagsToBody - Self.titleToBody : 0
    }

    var titleParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        Self.setLines(of: style, font: titleFont, pitch: Self.titleLineHeight)
        style.paragraphSpacing = titleParagraphSpacing
        style.tailIndent = -titleTrailingReserve
        return style
    }

    var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        Self.setLines(of: style, font: bodyFont, pitch: Self.bodyLineHeight)
        style.paragraphSpacingBefore = Self.spacingBefore(.body, after: .body)
        return style
    }

    // MARK: Native line boxes (O18-03, owner 2026-10-17)

    /// AppKit's own line box for `font`: the height TextKit 2 gives a line
    /// of it with no line-height settings, as TextEdit lays it out. Measured
    /// once per font (AppKit rounds the font's metrics its own way: 15 for
    /// the 12.5 pt body, whose ascender plus descender is 14.72, but 19 for
    /// the 16.5 pt heading at 19.43), never derived from a formula.
    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        if let cached = lineCache.value[font] { return cached }
        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        storage.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 10_000, height: 0))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        storage.textStorage?.setAttributedString(NSAttributedString(string: "Hxgj", attributes: [.font: font]))
        layout.ensureLayout(for: layout.documentRange)
        var height = (font.ascender - font.descender + font.leading).rounded()
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first { height = line.typographicBounds.height }
            return false
        }
        lineCache.value[font] = height
        return height
    }

    private final class LineCache: @unchecked Sendable { var value: [NSFont: CGFloat] = [:] }
    private static let lineCache = LineCache()

    /// A paragraph's lines at `pitch` apart, each in the font's own line box
    /// (`naturalLineHeight`) with the rest of the pitch as line spacing,
    /// which TextKit 2 puts above every line after the first. So AppKit's
    /// insertion point, which spans a line's box and never its spacing, is
    /// the font's natural height and sits on the text as TextEdit's does
    /// (O18-03, owner 2026-10-17), while the glyphs keep the baselines and
    /// pitch of the fixed boxes they had (R14). The box is fixed at the
    /// natural height, so an emoji, inline code or a bigger pasted run
    /// never changes a line's height (mixed content keeps the pitch).
    static func setLines(of paragraph: NSMutableParagraphStyle, font: NSFont, pitch: CGFloat) {
        let natural = min(naturalLineHeight(font), pitch)
        paragraph.minimumLineHeight = natural
        paragraph.maximumLineHeight = natural
        paragraph.lineSpacing = pitch - natural
    }

    /// A role's line spacing: the part of its pitch above each natural line
    /// box (`setLines`). 3.5 for the body, 2 for H1/H2, 0 for the title.
    static func lineLeading(_ role: T.Role) -> CGFloat {
        max(0, role.lineHeight - naturalLineHeight(font(for: role)))
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
        Self.setLines(of: paragraph, font: header ? tableHeaderFont : bodyFont, pitch: AtticNoteType.body.lineHeight)
        paragraph.alignment = switch alignment {
        case .left: .natural
        case .center: .center
        case .right: .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: header ? tableHeaderFont : bodyFont, .foregroundColor: bodyColor, .paragraphStyle: paragraph]
    }
}
