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

    /// Attributes that belong to the characters they were read with and are
    /// never carried into newly typed text.
    static let noteBookkeeping: Set<NSAttributedString.Key> = [.noteBlockID, .noteBlockExtras, .noteBlockStyle, .noteBlockLevel, .noteBlockIndent]
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
/// The title is 17 bold on a 22 pt line; the body 14 regular on a 21 pt
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

    static let titleLineHeight: CGFloat = 22
    static let bodyLineHeight: CGFloat = 21
    static let bodyParagraphGap: CGFloat = 7
    static let titleToBody: CGFloat = 8
    static let titleToTags: CGFloat = 4
    static let tagsToBody: CGFloat = 8

    var titleFont: NSFont { AtticTextStyle.noteTitle.nsFont }
    var bodyFont: NSFont { AtticTextStyle.noteBody.nsFont }
    var headingFont: NSFont { NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask).withSize(16) }
    var subheadingFont: NSFont { NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask) }
    var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) }
    var quoteColor: NSColor { secondaryColor }
    var markerColor: NSColor { secondaryColor }
    var highlightColor: NSColor { tokens.tagFill.nsColor }
    var codeColor: NSColor { tokens.tagFill.nsColor }

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
        result[.paragraphStyle] = paragraph
        return result
    }

    func markedAttributes(kind: NoteMark.Kind, baseFont: NSFont, url: String? = nil) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .bold: return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)]
        case .italic: return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
        case .underline: return [.underlineStyle: NSUnderlineStyle.single.rawValue]
        case .strikethrough: return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code: return [.font: monoFont, .backgroundColor: codeColor]
        case .highlight: return [.backgroundColor: highlightColor]
        case .link:
            var result: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue,
                                                          .foregroundColor: bodyColor]
            if let url, let value = URL(string: url) { result[.link] = value }
            return result
        }
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
