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

/// The editor's look, from the design system only (fonts from the note text
/// styles, inks from the resolved tokens).
///
/// The title is 22 bold on a 28 pt line; the body 14 regular on a 21 pt
/// line with paragraphs 7 apart (UX plan § 2), both SF Pro Rounded (owner
/// decision 4). With tags, the title's paragraph reserves room under it for
/// the tag line (4 above it, 8 below); its lines keep clear of the ⋯ at the
/// end of the first line (`titleTrailingReserve`).
struct NoteTextStyle: Equatable {
    var design: AtticDesignContext = .default
    /// Height of the tag line drawn under the title (0: no tags).
    var tagLineHeight: CGFloat = 0
    /// Room kept at the end of the title's lines for the note menu button.
    var titleTrailingReserve: CGFloat = 0

    static let titleLineHeight: CGFloat = 28
    static let codePadding: CGFloat = 12
    static let codeRadius: CGFloat = 10
    static let bodyLineHeight: CGFloat = 21
    static let bodyParagraphGap: CGFloat = 7
    static let titleToBody: CGFloat = 8
    static let titleToTags: CGFloat = 4
    static let tagsToBody: CGFloat = 8

    var titleFont: NSFont { AtticTextStyle.noteTitle.nsFont }
    var bodyFont: NSFont { AtticTextStyle.noteBody.nsFont }
    var headingFont: NSFont { roundedFont(size: 18, weight: .semibold) }
    var subheadingFont: NSFont { roundedFont(size: 15.5, weight: .semibold) }
    var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
    var quoteColor: NSColor { secondaryColor }
    var markerColor: NSColor { secondaryColor }
    var highlightColor: NSColor { tokens.tagFill.nsColor }
    var codeColor: NSColor { tokens.tagFill.nsColor }
    var codeBlockColor: NSColor { tokens.recessed.nsColor }

    private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: size) ?? font
    }

    var tokens: AtticColorTokens { AtticColorTokens.resolve(design) }
    var titleColor: NSColor { tokens.ink(.heading).nsColor }
    var bodyColor: NSColor { tokens.ink(.body).nsColor }
    var secondaryColor: NSColor { tokens.ink(.helper).nsColor }
    var placeholderColor: NSColor { tokens.ink(.placeholder).nsColor }

    var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: titleFont, .foregroundColor: titleColor, .paragraphStyle: titleParagraphStyle]
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: bodyColor, .paragraphStyle: bodyParagraphStyle]
    }

    func paragraphAttributes(style name: String?, level: Int?, indent: Int?) -> [NSAttributedString.Key: Any] {
        if (name == nil || name == "body") && indent == nil { return bodyAttributes }
        var result = bodyAttributes
        switch name {
        case "heading":
            result[.font] = (level ?? 2) <= 1 ? titleFont : (level == 2 ? headingFont : subheadingFont)
            result[.foregroundColor] = titleColor
        case "mono": result[.font] = monoFont
        case "quote": result[.foregroundColor] = quoteColor
        default: break
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.setParagraphStyle(bodyParagraphStyle)
        paragraph.firstLineHeadIndent = CGFloat(indent ?? 0) * 20 + ((name == "bullet" || name == "number") ? 19 : 0)
        paragraph.headIndent = paragraph.firstLineHeadIndent
        if name == "bullet" {
            paragraph.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        } else if name == "number" {
            paragraph.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        }
        if name == "quote" { paragraph.headIndent += 12; paragraph.firstLineHeadIndent += 12 }
        if name == "heading" {
            let font = result[.font] as? NSFont ?? headingFont
            let height: CGFloat = (level ?? 2) <= 1 ? Self.titleLineHeight : (level == 2 ? 23 : 20)
            paragraph.lineSpacing = Self.lineSpacing(for: font, lineHeight: height)
            paragraph.paragraphSpacingBefore = 18
            paragraph.paragraphSpacing = 6
        } else if name == "mono" {
            paragraph.lineSpacing = Self.lineSpacing(for: monoFont, lineHeight: 18)
            paragraph.paragraphSpacing = 0
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 12 // Hanging soft wraps inside the block padding.
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
            result[.foregroundColor] = bodyColor
        }
        return result
    }

    /// The gap from the title's last line to the body's first.
    var titleParagraphSpacing: CGFloat {
        tagLineHeight > 0 ? Self.titleToTags + tagLineHeight + Self.tagsToBody : Self.titleToBody
    }

    var titleParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Self.lineSpacing(for: titleFont, lineHeight: Self.titleLineHeight)
        style.paragraphSpacing = titleParagraphSpacing
        style.tailIndent = -titleTrailingReserve
        return style
    }

    var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Self.lineSpacing(for: bodyFont, lineHeight: Self.bodyLineHeight)
        style.paragraphSpacing = Self.bodyParagraphGap
        return style
    }

    /// Extra space between lines that brings the font's own line to `lineHeight`.
    static func lineSpacing(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        let natural = font.ascender - font.descender + font.leading
        return max(0, lineHeight - natural)
    }
}
