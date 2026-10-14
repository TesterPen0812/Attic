import AppKit
import SwiftUI

/// What Notes draws beside a paragraph's own text (R14, Codex Pages scaled
/// to the panel, `notes-r14-spec.md` C): the code block's and the callout's
/// rounded boxes, a list's marker, a quote's bar and inline code's chips.
/// Layout stays TextKit's: only the boxes change geometry, through their
/// fragments' margins and padding, so every line keeps viewport-driven
/// layout and its own selection and caret.
///
/// Each paragraph of a box (one code line, one callout paragraph) is a
/// slice of it: the first carries the box's top padding, the last its
/// bottom padding, and every slice draws the box's fill clipped to itself,
/// so a box of any length reads as one rounded rectangle with no seams.
final class NoteBlockLayoutFragment: NSTextLayoutFragment {
    enum Decoration: Equatable {
        case history
        /// Nothing beside the text: the paragraph only has inline code chips.
        case plain
        /// `exitsAtEnd`: the block's last line ends the note, and the empty
        /// line after it (inside this fragment) is not code.
        case mono(starts: Bool, ends: Bool, exitsAtEnd: Bool = false)
        /// A list's marker in the 14 pt slot starting at `x` in the column.
        case marker(NoteListMarker, x: CGFloat)
        /// A bar from `x` in the column; it joins the quote line above or
        /// below across their gap.
        case quote(x: CGFloat, joinsAbove: Bool, joinsBelow: Bool)
        /// A callout's slice; its first paragraph draws the icon ("" none).
        case callout(icon: String, starts: Bool, ends: Bool, exitsAtEnd: Bool = false)
    }

    var decoration: Decoration = .mono(starts: true, ends: true, exitsAtEnd: false)
    var hasHistoryDifference = false
    /// The paragraph's space before its first line (inside the fragment).
    var spacingBefore: CGFloat = 0
    /// How far the paragraph's line boxes sit above the draft's (see
    /// `NoteTextStyle.baselineShift`): the quote's bar follows the draft's.
    var boxShift: CGFloat = 0
    var ink: NSColor = .labelColor
    var fill: NSColor = .clear
    var border: NSColor?
    var markerFont: NSFont = NoteTextStyle.font(for: AtticNoteType.body)
    /// A code block's language label, drawn in its first slice's label row.
    var codeLabel: String?
    var labelInk: NSColor = .secondaryLabelColor
    /// Inline code's chip fill (nil: the paragraph has no inline code).
    var chipFill: NSColor?

    private typealias T = AtticNoteType
    private static var monoShift: CGFloat { NoteTextStyle.baselineShift(T.mono) }
    private static var bodyShift: CGFloat { NoteTextStyle.baselineShift(T.body) }

    private var mono: (starts: Bool, ends: Bool, exitsAtEnd: Bool)? {
        if case let .mono(starts, ends, exitsAtEnd) = decoration { return (starts, ends, exitsAtEnd) }
        return nil
    }

    private var callout: (icon: String, starts: Bool, ends: Bool, exitsAtEnd: Bool)? {
        if case let .callout(icon, starts, ends, exitsAtEnd) = decoration { return (icon, starts, ends, exitsAtEnd) }
        return nil
    }

    /// From a code block's top edge to its first code line's box: the top
    /// padding, the label row and the gap under it.
    static var monoTopInset: CGFloat { T.monoPaddingV + T.monoLabelHeight + T.monoLabelGap }

    // The code block's padding: the text sits 12 in from the box's sides,
    // its glyphs on the draft's baselines (the top padding gives up the
    // line's baseline shift, the bottom one takes it). A callout's sides
    // are its paragraph's indents; its top and bottom padding work as code's.
    override var leadingPadding: CGFloat { mono == nil ? super.leadingPadding : T.monoPaddingH }
    override var trailingPadding: CGFloat { mono == nil ? super.trailingPadding : T.monoPaddingH }
    override var topMargin: CGFloat {
        if let mono { return mono.starts ? Self.monoTopInset - Self.monoShift : 0 }
        if let callout { return callout.starts ? T.calloutPaddingV - Self.bodyShift : 0 }
        return super.topMargin
    }
    override var bottomMargin: CGFloat {
        if let mono { return mono.ends && !mono.exitsAtEnd ? T.monoPaddingV + Self.monoShift : 0 }
        if let callout { return callout.ends && !callout.exitsAtEnd ? T.calloutPaddingV + Self.bodyShift : 0 }
        return super.bottomMargin
    }

    private var columnWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// A box's slice in this fragment's coordinates: the column's full
    /// width, from the box's top (first slice) to its bottom (last).
    private func boxSlice(starts: Bool, exitsAtEnd: Bool, bottomPadding: CGFloat) -> CGRect {
        let top = starts ? spacingBefore : 0
        var bottom = layoutFragmentFrame.height
        if exitsAtEnd, let last = textLineFragments.last(where: { $0.characterRange.length > 0 }) ?? textLineFragments.first {
            // Not the note's empty last line: it sits below the box.
            bottom = last.typographicBounds.maxY + bottomPadding
        }
        return CGRect(x: -layoutFragmentFrame.minX, y: top, width: columnWidth, height: max(0, bottom - top))
    }

    /// The code block's rectangle in this fragment's coordinates.
    var monoBlockRect: CGRect? {
        guard let mono else { return nil }
        return boxSlice(starts: mono.starts, exitsAtEnd: mono.exitsAtEnd, bottomPadding: T.monoPaddingV + Self.monoShift)
    }

    /// The callout's rectangle in this fragment's coordinates.
    var calloutBoxRect: CGRect? {
        guard let callout else { return nil }
        return boxSlice(starts: callout.starts, exitsAtEnd: callout.exitsAtEnd, bottomPadding: T.calloutPaddingV + Self.bodyShift)
    }

    /// A code block's label row (its first slice only), in this fragment's
    /// coordinates: 12 in from the box's left edge, 8 under its top.
    var codeLabelRect: CGRect? {
        guard let mono, mono.starts else { return nil }
        return CGRect(x: -layoutFragmentFrame.minX + T.monoPaddingH, y: spacingBefore + T.monoPaddingV,
                      width: max(0, columnWidth - 2 * T.monoPaddingH - T.monoCopySize - 4), height: T.monoLabelHeight)
    }

    /// The callout icon's slot (its first slice only): 16 wide at x 12,
    /// one body line tall on the first line's box.
    var calloutIconRect: CGRect? {
        guard let callout, callout.starts, !callout.icon.isEmpty, let line = textLineFragments.first else { return nil }
        let baseline = Self.baseline(of: line)
        let centreY = baseline - markerFont.capHeight / 2
        return CGRect(x: -layoutFragmentFrame.minX + T.calloutPaddingH, y: centreY - T.body.lineHeight / 2,
                      width: T.calloutIconSlot, height: T.body.lineHeight)
    }

    private var firstBaseline: CGFloat? {
        guard let line = textLineFragments.first else { return nil }
        return line.typographicBounds.minY + line.glyphOrigin.y
    }

    private var decorationRect: CGRect {
        switch decoration {
        case .history, .plain: return .zero
        case .mono:
            return monoBlockRect ?? .zero
        case .callout:
            return (calloutBoxRect ?? .zero).insetBy(dx: 0, dy: -Self.bodyShift - 1)
        case let .marker(_, x):
            let baseline = firstBaseline ?? 0
            // Numbers wider than the slot grow left into the margin.
            return CGRect(x: x - layoutFragmentFrame.minX - 40, y: baseline - markerFont.ascender - 1,
                          width: 40 + T.markerSlot + 1, height: markerFont.ascender - markerFont.descender + 2)
        case .quote:
            return quoteBar ?? .zero
        }
    }

    /// The quote's bar, in this fragment's coordinates (F-04): it spans its
    /// text, from the first line's ascender to the last line's descender,
    /// centred on the glyphs and never longer. Where the quote goes on in
    /// the paragraph above or below, the bar runs to this fragment's edge
    /// and meets the neighbour's across the gap.
    var quoteBar: CGRect? {
        guard case let .quote(x, joinsAbove, joinsBelow) = decoration else { return nil }
        let lines = textLineFragments
        let first = lines.first
        let last = lines.last(where: { $0.characterRange.length > 0 }) ?? first
        let top: CGFloat
        if joinsAbove {
            top = 0
        } else if let first {
            // F-04b: from what the eye reads as the text's top (the cap
            // height and a little over, the lowercase ascenders), not the
            // font's ascender, which stood 3 pt over the letters.
            top = Self.baseline(of: first) - Self.quoteBarAbove(markerFont)
        } else {
            top = spacingBefore
        }
        let bottom: CGFloat
        if joinsBelow {
            bottom = layoutFragmentFrame.height
        } else if let last {
            // Just under the last baseline, with or without descenders.
            bottom = Self.baseline(of: last) + Self.quoteBarBelow(markerFont)
        } else {
            bottom = layoutFragmentFrame.height
        }
        return CGRect(x: x - layoutFragmentFrame.minX, y: top, width: T.quoteBar, height: max(0, bottom - top))
    }

    /// The quote bar's reach above a baseline: the cap height and 7 % of
    /// the size (the lowercase ascenders' height in SF).
    static func quoteBarAbove(_ font: NSFont) -> CGFloat { font.capHeight + font.pointSize * 0.07 }
    /// Its reach below the last baseline: 11 % of the size, about a third
    /// of the descender, so it reads as ending with the text.
    static func quoteBarBelow(_ font: NSFont) -> CGFloat { font.pointSize * 0.11 }

    /// A line's baseline in the fragment's coordinates.
    private static func baseline(of line: NSTextLineFragment) -> CGFloat {
        line.typographicBounds.minY + line.glyphOrigin.y
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds.union(decorationRect)
        if chipFill != nil { bounds = bounds.insetBy(dx: -T.inlineCodeChipPadding, dy: -1) }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if hasHistoryDifference {
            context.saveGState()
            context.setFillColor(ink.withAlphaComponent(0.65).cgColor)
            context.fill(CGRect(x: point.x - layoutFragmentFrame.minX - 7, y: point.y + spacingBefore,
                                width: 2, height: max(3, layoutFragmentFrame.height - spacingBefore)))
            context.restoreGState()
        }
        if let block = monoBlockRect, let mono {
            let edge: (NSColor, CGFloat)? = border.map { ($0, 1) } ?? hairlineInk.map { ($0, T.monoHairline) }
            drawBox(block, starts: mono.starts, ends: mono.ends || mono.exitsAtEnd, radius: T.monoRadius,
                    edge: edge, at: point, in: context)
            if let label = codeLabel, let rect = codeLabelRect { drawLabel(label, in: rect.offsetBy(dx: point.x, dy: point.y), context: context) }
        }
        if let box = calloutBoxRect, let callout {
            drawBox(box, starts: callout.starts, ends: callout.ends || callout.exitsAtEnd, radius: T.calloutRadius,
                    edge: border.map { ($0, 1) }, at: point, in: context)
        }
        if chipFill != nil { drawInlineCodeChips(at: point, in: context) }
        super.draw(at: point, in: context)
        switch decoration {
        case .mono, .history, .plain:
            break
        case let .callout(icon, starts, _, _):
            guard starts, !icon.isEmpty, let slot = calloutIconRect else { return }
            drawIcon(icon, in: slot.offsetBy(dx: point.x, dy: point.y), context: context)
        case let .marker(marker, x):
            guard let baseline = firstBaseline else { return }
            drawMarker(marker, slotX: point.x + x - layoutFragmentFrame.minX, baseline: point.y + baseline, in: context)
        case .quote:
            guard let bar = quoteBar, case let .quote(_, joinsAbove, joinsBelow) = decoration else { return }
            drawQuoteBar(bar.offsetBy(dx: point.x, dy: point.y), joinsAbove: joinsAbove, joinsBelow: joinsBelow, in: context)
        }
    }

    // MARK: Markers

    /// Disc (4), ring (4.5, 1 pt stroke) and square (3.5) centred on x 7,
    /// raised 0.5 off the first line's x-height middle; numbers, letters and
    /// roman numerals in tabular figures ending at x 14, on the baseline.
    private func drawMarker(_ marker: NoteListMarker, slotX: CGFloat, baseline: CGFloat, in context: CGContext) {
        let centre = CGPoint(x: slotX + T.bulletCentre, y: baseline - markerFont.xHeight / 2 - T.bulletLift)
        context.saveGState()
        defer { context.restoreGState() }
        switch marker {
        case .disc:
            context.setFillColor(ink.cgColor)
            context.fillEllipse(in: CGRect(x: centre.x - T.bulletDot / 2, y: centre.y - T.bulletDot / 2, width: T.bulletDot, height: T.bulletDot))
        case .ring:
            let diameter = T.bulletRing - T.bulletRingStroke
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(T.bulletRingStroke)
            context.strokeEllipse(in: CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter))
        case .square:
            let side = T.bulletSquare
            context.addPath(CGPath(roundedRect: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side),
                                   cornerWidth: T.bulletSquareRadius, cornerHeight: T.bulletSquareRadius, transform: nil))
            context.setFillColor(ink.cgColor)
            context.fillPath()
        case let .number(text), let .letter(text), let .roman(text):
            let string = NSAttributedString(string: text, attributes: [.font: markerFont, .foregroundColor: ink])
            let width = string.size().width
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            string.draw(at: CGPoint(x: slotX + T.markerSlot - width, y: baseline - markerFont.ascender))
            NSGraphicsContext.restoreGraphicsState()
        case .checkbox:
            break
        }
    }

    // MARK: Box chrome

    /// The language name in the label row: 11 pt helper ink, centred on
    /// the row's 14 pt line box.
    private func drawLabel(_ label: String, in rect: CGRect, context: CGContext) {
        let font = NoteTextStyle.font(for: T.codeLabel)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: labelInk, .paragraphStyle: paragraph])
        let height = font.ascender - font.descender
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(with: CGRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2, width: rect.width, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The callout's emoji at 15 pt, centred in its slot (on the first
    /// line's cap height).
    private func drawIcon(_ icon: String, in slot: CGRect, context: CGContext) {
        let font = NSFont(name: "AppleColorEmoji", size: T.calloutIconSize) ?? .systemFont(ofSize: T.calloutIconSize)
        let string = NSAttributedString(string: icon, attributes: [.font: font])
        let size = string.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Apple Color Emoji's image sits 0.14 em below its typographic
        // box's centre (measured at 2×: 2.1 pt at 15 pt); lift it so the
        // picture itself centres on the first line's cap height.
        string.draw(at: CGPoint(x: slot.midX - size.width / 2,
                                y: slot.midY - (font.ascender - font.descender) / 2 - font.pointSize * 0.14))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Inline code's chips: 14 tall on the x-height middle, radius 4, 4 pt
    /// outside the run's glyphs on each side (the run's kern makes that
    /// room). A run that wraps draws one chip per line.
    private func drawInlineCodeChips(at point: CGPoint, in context: CGContext) {
        guard let chipFill, let paragraph = textElement as? NSTextParagraph else { return }
        let text = paragraph.attributedString
        var runs: [NSRange] = []
        text.enumerateAttribute(.noteMark(.code), in: NSRange(location: 0, length: text.length)) { value, run, _ in
            if value != nil { runs.append(run) }
        }
        guard !runs.isEmpty else { return }
        let padding = T.inlineCodeChipPadding
        context.saveGState()
        context.setFillColor(chipFill.cgColor)
        for line in textLineFragments where line.characterRange.length > 0 {
            let baseline = Self.baseline(of: line)
            let centreY = baseline - markerFont.xHeight / 2
            for run in runs {
                let part = NSIntersectionRange(run, line.characterRange)
                guard part.length > 0 else { continue }
                let startX = line.locationForCharacter(at: part.location).x
                var endX = line.locationForCharacter(at: NSMaxRange(part)).x
                // The run's last character carries the right-hand padding
                // as kern; a run cut by a wrap ends at its last glyph.
                if NSMaxRange(part) < NSMaxRange(run) { endX += padding }
                let origin = line.typographicBounds.origin
                let rect = CGRect(x: point.x + origin.x + startX - padding, y: point.y + centreY - T.inlineCodeChipHeight / 2,
                                  width: max(0, endX - startX + padding), height: T.inlineCodeChipHeight)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: T.inlineCodeChipRadius, cornerHeight: T.inlineCodeChipRadius, transform: nil))
            }
        }
        context.fillPath()
        context.restoreGState()
    }

    /// A pill: rounded at the top and the bottom of the whole quote. A slice
    /// that joins its neighbour extends past its own edge, so the cap falls
    /// outside the clip and the seam is square; the seam sits on a device
    /// pixel so the two slices never blend into a hairline.
    private func drawQuoteBar(_ bar: CGRect, joinsAbove: Bool, joinsBelow: Bool, in context: CGContext) {
        func snapped(_ y: CGFloat) -> CGFloat {
            let device = context.convertToDeviceSpace(CGPoint(x: bar.minX, y: y))
            return context.convertToUserSpace(CGPoint(x: device.x, y: device.y.rounded())).y
        }
        let top = joinsAbove ? snapped(bar.minY) : bar.minY
        let bottom = joinsBelow ? snapped(bar.maxY) : bar.maxY
        guard bottom > top else { return }
        let radius = bar.width / 2
        let slice = CGRect(x: bar.minX, y: top, width: bar.width, height: bottom - top)
        let full = CGRect(x: bar.minX, y: top - (joinsAbove ? radius * 2 : 0), width: bar.width,
                          height: slice.height + (joinsAbove ? radius * 2 : 0) + (joinsBelow ? radius * 2 : 0))
        context.saveGState()
        context.clip(to: slice)
        context.addPath(CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(ink.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    /// The box's continuous rounded rectangle, cut to this slice: a slice
    /// that does not start or end the box extends past its own edge, so its
    /// corners fall outside the clip. `edge`: its outline, inside it (the
    /// code block's 0.5 pt hairline, or 1 pt under Increase Contrast).
    private func drawBox(_ block: CGRect, starts: Bool, ends: Bool, radius: CGFloat, edge: (NSColor, CGFloat)?,
                         at point: CGPoint, in context: CGContext) {
        let slice = block.offsetBy(dx: point.x, dy: point.y)
        let reach = radius * 2
        let full = CGRect(x: slice.minX, y: slice.minY - (starts ? 0 : reach),
                          width: slice.width, height: slice.height + (starts ? 0 : reach) + (ends ? 0 : reach))
        let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: full).cgPath
        context.saveGState()
        context.clip(to: slice)
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        if let (ink, width) = edge {
            let inset = width / 2
            let outline = RoundedRectangle(cornerRadius: radius - inset, style: .continuous)
                .path(in: full.insetBy(dx: inset, dy: inset)).cgPath
            context.addPath(outline)
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The code block's hairline ink (`divider`); Increase Contrast's
    /// `border` replaces it at 1 pt.
    var hairlineInk: NSColor?
}

// MARK: - The engine's layout hooks

// AppKit calls this editor's content-storage delegate on its owning main
// actor. The bridge retains the runtime isolation check for the SDK's
// nonisolated protocol, rather than sending text elements across actors.
extension NoteEditorEngine: NSTextLayoutManagerDelegate, @preconcurrency NSTextContentStorageDelegate {
    func textContentManager(_ textContentManager: NSTextContentManager,
                            shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard !foldedHeadingIDs.isEmpty, let range = textElement.elementRange else { return true }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: range.location)
        return !headingSections.contains { section in
            section.id.map(foldedHeadingIDs.contains) == true && NSLocationInRange(offset, section.content)
        }
    }

    /// List paragraphs keep their `NSTextList`s in storage (copy as rich
    /// text and print use them), but TextKit 2 would lay its own marker and
    /// fixed 36 pt indent into the line. The editor shows them without:
    /// the text at the list's own indent (22 pt), the marker drawn by
    /// `NoteBlockLayoutFragment`.
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length,
              let style = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              !style.textLists.isEmpty || textStorage.attribute(.noteBlockStyle, at: range.location, effectiveRange: nil) as? String == "heading" else { return nil }
        let text = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, part, _ in
            guard let style = value as? NSParagraphStyle,
                  let plain = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            plain.textLists = []
            if textStorage.attribute(.noteBlockStyle, at: range.location, effectiveRange: nil) as? String == "heading" {
                plain.tailIndent = -24
            }
            text.addAttribute(.paragraphStyle, value: plain, range: part)
        }
        return NSTextParagraph(attributedString: text)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        let changed = historyDifferenceOffsets.contains(offset)
        let inStorage = offset > 0 && offset < textStorage.length
        let native = inStorage ? decoration(forParagraphAt: offset) : nil
        let chips = inStorage && containsInlineCode(paragraphAt: offset)
        guard offset >= 0, offset < textStorage.length,
              let decoration = native ?? (changed ? .history : (chips ? .plain : nil)) else {
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        let fragment = NoteBlockLayoutFragment(textElement: textElement, range: nil)
        let paragraph = textStorage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
        fragment.decoration = decoration
        fragment.hasHistoryDifference = changed
        fragment.spacingBefore = paragraph?.paragraphSpacingBefore ?? 0
        let kind = paragraphKind(at: offset)
        fragment.boxShift = NoteTextStyle.boxShift(kind)
        fragment.markerFont = style.font(for: kind)
        fragment.ink = style.bodyColor
        if chips { fragment.chipFill = style.codeColor }
        switch decoration {
        case let .mono(starts, _, _):
            fragment.fill = style.codeBlockColor
            fragment.border = style.codeBlockBorder
            fragment.hairlineInk = style.tokens.divider.nsColor
            fragment.labelInk = style.secondaryColor
            if starts { fragment.codeLabel = NoteCodeLanguageName.label(for: codeLanguage(at: offset)) }
        case .callout:
            fragment.fill = style.codeBlockColor
            fragment.border = style.codeBlockBorder
        case .marker(let marker, _):
            if case .number = marker { fragment.markerFont = Self.markerNumberFont }
            if case .letter = marker { fragment.markerFont = Self.markerNumberFont }
            if case .roman = marker { fragment.markerFont = Self.markerNumberFont }
        case .quote:
            fragment.ink = style.quoteBarColor
        case .history, .plain:
            break
        }
        return fragment
    }

    /// List numbers: the body's size in tabular figures, so "9." and "10."
    /// line up on their periods.
    static let markerNumberFont = NSFont.monospacedDigitSystemFont(ofSize: AtticNoteType.body.size, weight: .regular)

    /// Whether the paragraph at `location` has inline code (its chips are
    /// drawn by the paragraph's fragment). Bounded by the paragraph.
    func containsInlineCode(paragraphAt location: Int) -> Bool {
        let line = lineRange(at: location)
        guard line.length > 0 else { return false }
        var found = false
        textStorage.enumerateAttribute(.noteMark(.code), in: line, options: [.longestEffectiveRangeNotRequired]) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// What the paragraph at `location` draws beside its text, if anything.
    func decoration(forParagraphAt location: Int) -> NoteBlockLayoutFragment.Decoration? {
        let line = paragraphRange(at: location)
        guard line.location > 0, line.location < textStorage.length else { return nil }
        let attributes = textStorage.attributes(at: line.location, effectiveRange: nil)
        let name = attributes[.noteBlockStyle] as? String
        let depth = CGFloat(attributes[.noteBlockIndent] as? Int ?? 0) * AtticNoteType.listLevelStep
        switch name {
        case "mono":
            return .mono(starts: !isMono(paragraphBefore: line), ends: !isMono(paragraphAfter: line),
                         exitsAtEnd: monoExitsAtEnd(line))
        case "bullet", "number":
            guard let marker = listMarker(at: line.location) else { return nil }
            return .marker(marker, x: depth)
        case "quote":
            if let icon = attributes[.noteCalloutIcon] as? String {
                return .callout(icon: icon, starts: calloutIcon(paragraphBefore: line) != icon,
                                ends: !calloutContinues(after: line, icon: icon), exitsAtEnd: boxExitsAtEnd(line))
            }
            return .quote(x: depth, joinsAbove: isPlainQuote(paragraphBefore: line),
                          joinsBelow: isPlainQuote(paragraphAfter: line))
        default:
            return nil
        }
    }

    /// The callout icon of the paragraph above (nil: not a callout).
    private func calloutIcon(paragraphBefore line: NSRange) -> String? {
        guard line.location > 0 else { return nil }
        let previous = paragraphRange(at: line.location - 1)
        guard previous.location > 0 else { return nil }
        return textStorage.attribute(.noteCalloutIcon, at: previous.location, effectiveRange: nil) as? String
    }

    /// The callout box goes on below `line`: the next paragraph is a callout
    /// with the same icon, or the note's empty last line has that callout
    /// pending.
    private func calloutContinues(after line: NSRange, icon: String) -> Bool {
        let next = NSMaxRange(line)
        if next < textStorage.length {
            return textStorage.attribute(.noteCalloutIcon, at: next, effectiveRange: nil) as? String == icon
        }
        guard next == textStorage.length, next > 0,
              (textStorage.string as NSString).character(at: next - 1) == 0x0A else { return false }
        return pendingParagraphStyle?.location == next && pendingParagraphStyle?.state.style == .callout(icon: icon)
    }

    private func isPlainQuote(paragraphBefore line: NSRange) -> Bool {
        guard line.location > 0 else { return false }
        let previous = paragraphRange(at: line.location - 1)
        guard previous.location > 0 else { return false }
        return textStorage.attribute(.noteBlockStyle, at: previous.location, effectiveRange: nil) as? String == "quote"
            && textStorage.attribute(.noteCalloutIcon, at: previous.location, effectiveRange: nil) == nil
    }

    private func isPlainQuote(paragraphAfter line: NSRange) -> Bool {
        let next = NSMaxRange(line)
        guard next < textStorage.length else { return false }
        return textStorage.attribute(.noteBlockStyle, at: next, effectiveRange: nil) as? String == "quote"
            && textStorage.attribute(.noteCalloutIcon, at: next, effectiveRange: nil) == nil
    }

    /// A box (code or a callout) that ends the note keeps its bottom padding
    /// above the note's empty last line, unless that line continues the box
    /// (its style is pending).
    func boxExitsAtEnd(_ paragraph: NSRange) -> Bool {
        let string = textStorage.string as NSString
        guard paragraph.length > 0, NSMaxRange(paragraph) == string.length,
              string.character(at: NSMaxRange(paragraph) - 1) == 0x0A else { return false }
        guard let pending = pendingParagraphStyle, pending.location == string.length else { return true }
        let format = paragraphStyle(at: paragraph.location)
        if format?.isCode == true { return !pending.state.style.isCode }
        return pending.state.style != format
    }

    private func style(paragraphBefore line: NSRange) -> String? {
        guard line.location > 0 else { return nil }
        let previous = paragraphRange(at: line.location - 1)
        guard previous.location > 0 else { return nil }
        return textStorage.attribute(.noteBlockStyle, at: previous.location, effectiveRange: nil) as? String
    }

    private func style(paragraphAfter line: NSRange) -> String? {
        let next = NSMaxRange(line)
        guard next < textStorage.length else { return nil }
        return textStorage.attribute(.noteBlockStyle, at: next, effectiveRange: nil) as? String
    }

    private func isMono(paragraphBefore line: NSRange) -> Bool { style(paragraphBefore: line) == "mono" }

    /// The block goes on while the next paragraph is Mono too. The note's
    /// trailing empty line (after its final line break) belongs to the
    /// block only while a Mono style is pending for it.
    private func isMono(paragraphAfter line: NSRange) -> Bool {
        let next = NSMaxRange(line)
        if next < textStorage.length { return style(paragraphAfter: line) == "mono" }
        guard next == textStorage.length, next > 0,
              (textStorage.string as NSString).character(at: next - 1) == 0x0A else { return false }
        return pendingParagraphStyle?.location == next && pendingParagraphStyle?.state.style.isCode == true
    }

    /// The Mono block around `location` (its first paragraph's start to its
    /// last paragraph's end, without the final line break), or nil.
    func monoBlockRange(at location: Int) -> NSRange? {
        guard location < textStorage.length, paragraphStyle(at: location)?.isCode == true else { return nil }
        var start = paragraphRange(at: location)
        while start.location > 0 {
            let previous = paragraphRange(at: start.location - 1)
            guard previous.location > 0, paragraphStyle(at: previous.location)?.isCode == true else { break }
            start = previous
        }
        var end = paragraphRange(at: location)
        while NSMaxRange(end) < textStorage.length, paragraphStyle(at: NSMaxRange(end))?.isCode == true {
            end = paragraphRange(at: NSMaxRange(end))
        }
        var range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        if range.length > 0, (textStorage.string as NSString).character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        return range
    }

    /// The text a Mono block's Copy puts on the pasteboard: its lines as
    /// written, one per line.
    func monoBlockText(at location: Int) -> String? {
        monoBlockRange(at: location).map { (textStorage.string as NSString).substring(with: $0) }
    }

    /// After an edit in a numbered list, the items further down show new
    /// numbers: their fragments are made again (the edit restyled only the
    /// paragraphs beside it). Bounded by the list's own run.
    func renumberList(after range: NSRange) {
        guard let layoutManager, textStorage.length > 0 else { return }
        var location = min(NSMaxRange(range), textStorage.length - 1)
        location = NSMaxRange(paragraphRange(at: location))
        let start = location
        while location < textStorage.length {
            let line = paragraphRange(at: location)
            let name = textStorage.attribute(.noteBlockStyle, at: line.location, effectiveRange: nil) as? String
            guard name == "number" || name == "bullet" || (textStorage.attribute(.noteBlockIndent, at: line.location, effectiveRange: nil) as? Int ?? 0) > 0
            else { break }
            location = NSMaxRange(line)
        }
        guard location > start, let textRange = textRange(for: NSRange(location: start, length: location - start)) else { return }
        layoutManager.invalidateLayout(for: textRange)
    }

    // MARK: Spell checking stays out of code

    /// Filter results at delivery time too: asynchronous checks may have
    /// begun before a paragraph was switched from prose to Mono (Codex).
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange,
                  types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        results.filter { !containsCode(in: $0.range) }
    }

    func containsCode(in range: NSRange) -> Bool {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        guard clamped.length > 0 else { return false }
        var found = false
        textStorage.enumerateAttributes(in: clamped) { attributes, _, stop in
            if attributes[.noteBlockStyle] as? String == "mono" || attributes[.noteMark(.code)] != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}

// MARK: - Copy on a Mono block

/// Copy on a Mono block: an 18 pt `doc.on.doc` chip on the block's top-right
/// corner, rising above its top edge so it ends where the text begins and
/// covers nothing; opaque in the block's own fill. Shown while the
/// pointer is over the block, while the caret is in it, or for VoiceOver.
/// It copies the block's lines as plain text and shows a tick for a moment.
final class NoteMonoCopyButton: NSView {
    private typealias T = AtticNoteType
    var onCopy: (() -> Void)?
    var fill: NSColor = .controlBackgroundColor { didSet { needsDisplay = true } }
    var hoverFill: NSColor = .controlBackgroundColor { didSet { needsDisplay = true } }
    var ink: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    /// The glyph shown: `doc.on.doc`, or `checkmark` just after a copy.
    private(set) var symbolName = "doc.on.doc"
    private var hovered = false { didSet { needsDisplay = true } }
    private var resetWork: DispatchWorkItem?

    static var size: CGFloat { T.monoCopySize }
    static var radius: CGFloat { size / 3 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Copy Code"))
        setAccessibilityIdentifier("note-mono-copy")
        toolTip = String(localized: "Copy the code block")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { press() }
    override func accessibilityPerformPress() -> Bool { press(); return true }

    private func press() {
        onCopy?()
        symbolName = "checkmark"
        setAccessibilityValue(String(localized: "Copied"))
        needsDisplay = true
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.symbolName = "doc.on.doc"
            self.setAccessibilityValue(nil)
            self.needsDisplay = true
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius)
        (hovered ? hoverFill : fill).setFill()
        shape.fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: T.monoCopyGlyph, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }
}

extension NoteEditorEngine {
    /// The Mono block under a point in the text view: a location in it and
    /// its rectangle (the column's full width, padding included) in the
    /// text view's coordinates.
    func monoBlock(at point: NSPoint) -> (location: Int, rect: NSRect)? {
        guard let layoutManager, let textView else { return nil }
        let origin = textView.textContainerOrigin
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: containerPoint) as? NoteBlockLayoutFragment,
              fragment.monoBlockRect != nil else { return nil }
        let location = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
        guard let range = monoBlockRange(at: location), let rect = monoBlockRect(for: range) else { return nil }
        let inView = rect.offsetBy(dx: origin.x, dy: origin.y)
        guard inView.contains(point) else { return nil }
        return (location, inView)
    }

    /// The bottom of the note's last paragraph's fragment, in the text
    /// container, when that paragraph is Mono (its block's bottom padding
    /// counts); nil otherwise.
    func trailingMonoBlockBottom() -> CGFloat? {
        guard let layoutManager, textStorage.length > 0 else { return nil }
        let last = paragraphRange(at: textStorage.length - 1)
        guard last.location > 0, textStorage.attribute(.noteBlockStyle, at: last.location, effectiveRange: nil) as? String == "mono",
              let range = textRange(for: NSRange(location: last.location, length: 0)),
              let fragment = layoutManager.textLayoutFragment(for: range.location) as? NoteBlockLayoutFragment else { return nil }
        return fragment.layoutFragmentFrame.maxY
    }

    /// A Mono block's rectangle in the text container's coordinates.
    func monoBlockRect(for range: NSRange) -> NSRect? {
        guard let layoutManager,
              let first = textRange(for: NSRange(location: range.location, length: 0)).flatMap({
                  layoutManager.textLayoutFragment(for: $0.location) as? NoteBlockLayoutFragment }),
              let last = textRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0)).flatMap({
                  layoutManager.textLayoutFragment(for: $0.location) as? NoteBlockLayoutFragment }),
              let top = first.monoBlockRect, let bottom = last.monoBlockRect else { return nil }
        let topRect = top.offsetBy(dx: first.layoutFragmentFrame.minX, dy: first.layoutFragmentFrame.minY)
        let bottomRect = bottom.offsetBy(dx: last.layoutFragmentFrame.minX, dy: last.layoutFragmentFrame.minY)
        return topRect.union(bottomRect)
    }
}


/// A heading and the paragraphs it owns, in retained storage coordinates.
struct NoteHeadingSection {
    let heading: NSRange
    let content: NSRange
    let level: Int
    let id: UUID?
}

extension NoteEditorEngine {
    var headingSections: [NoteHeadingSection] {
        if let cached = headingSectionsCache { return cached }
        let string = textStorage.string as NSString
        var headings: [(NSRange, Int, UUID?)] = []
        var seen = Set<Int>()
        var usedIDs = Set<UUID>()
        textStorage.enumerateAttribute(.noteBlockStyle, in: NSRange(location: 0, length: string.length)) { value, run, _ in
            guard value as? String == "heading" else { return }
            var offset = run.location
            while offset < NSMaxRange(run) {
                let paragraph = string.paragraphRange(for: NSRange(location: offset, length: 0))
                if paragraph.location > 0, seen.insert(paragraph.location).inserted {
                    var id: UUID?
                    textStorage.enumerateAttribute(.noteBlockID, in: paragraph) { value, _, stop in
                        if let found = value as? UUID {
                            // A split can leave the same ID on both halves.
                            // Match the codec: only the first paragraph owns it.
                            id = usedIDs.insert(found).inserted ? found : nil
                            stop.pointee = true
                        }
                    }
                    headings.append((paragraph, textStorage.attribute(.noteBlockLevel, at: offset, effectiveRange: nil) as? Int ?? 2, id))
                }
                offset = NSMaxRange(paragraph)
            }
        }
        // Resolve section ends in one backwards pass (including nested levels).
        var stack: [Int] = []
        var ends = Array(repeating: string.length, count: headings.count)
        for i in headings.indices.reversed() {
            while let next = stack.last, headings[next].1 > headings[i].1 { stack.removeLast() }
            if let next = stack.last { ends[i] = headings[next].0.location }
            stack.append(i)
        }
        let sections = headings.indices.map { i in
            let start = NSMaxRange(headings[i].0)
            return NoteHeadingSection(heading: headings[i].0,
                content: NSRange(location: start, length: max(0, ends[i] - start)),
                level: headings[i].1, id: headings[i].2)
        }
        headingSectionsCache = sections
        return sections
    }

    func headingSection(at location: Int) -> NoteHeadingSection? {
        headingSections.first { NSLocationInRange(location, $0.heading) ||
            (location == textStorage.length && NSMaxRange($0.heading) == location && location > 0 &&
             (textStorage.string as NSString).character(at: location - 1) != 0x0A) }
    }

    @discardableResult
    func toggleHeadingFold(at location: Int) -> Bool {
        guard !isReadOnly, activity == .idle, let section = headingSection(at: location) else { return false }
        let id = section.id ?? UUID()
        if section.id == nil {
            // Assign paragraph identity once. Typed characters do not copy it;
            // surviving paragraph runs keep it through edits and undo.
            textStorage.addAttribute(.noteBlockID, value: id, range: section.heading)
            foldAssignedHeadingIDs.insert(id)
            headingSectionsCache = nil
        }
        let wasFolded = foldedHeadingIDs.contains(id)
        if !wasFolded, let selection = textView?.selectedRange(),
           headingContentContainsCaret(section, at: selection.location) {
            activeTableView?.deactivate()
            textView?.window?.makeFirstResponder(textView)
            textView?.setSelectedRange(NSRange(location: section.heading.location, length: 0))
        }
        setHeadingFold(id: id, folded: !wasFolded)
        return true
    }

    func setHeadingFold(id: UUID, folded: Bool) {
        foldMetadataWasEdited = true
        if folded, let section = headingSections.first(where: { $0.id == id }),
           let selection = textView?.selectedRange(), headingContentContainsCaret(section, at: selection.location) {
            textView?.setSelectedRange(NSRange(location: section.heading.location, length: 0))
        }
        if folded { foldedHeadingIDs.insert(id) } else { foldedHeadingIDs.remove(id) }
        invalidateDocumentCache()
        textView?.marquee?.textChanged()
        // A focused attachment must not be parked over its hidden paragraph.
        if folded, let section = headingSections.first(where: { $0.id == id }),
           let table = activeTableView?.attachment, let range = range(ofTable: table),
           NSLocationInRange(range.location, section.content) {
            activeTableView?.deactivate()
            textView?.window?.makeFirstResponder(textView)
            textView?.setSelectedRange(NSRange(location: section.heading.location, length: 0))
        }
        invalidateLayout(NSRange(location: 0, length: textStorage.length))
        textView?.needsLayout = true
        // Fold hints ride on the next content save; this view change never dirties a note.
        onCaretChange?()
    }

    func isRangeFolded(_ range: NSRange) -> Bool {
        guard !foldedHeadingIDs.isEmpty else { return false }
        return headingSections.contains { $0.id.map(foldedHeadingIDs.contains) == true && NSLocationInRange(range.location, $0.content) }
    }

    /// An insertion point at EOF belongs to the final body paragraph too.
    /// An empty body after a trailing newline is distinct from the end of
    /// a final heading with no following paragraph (typing there stays folded).
    private func headingContentContainsCaret(_ section: NoteHeadingSection, at location: Int) -> Bool {
        if NSLocationInRange(location, section.content) { return true }
        guard location == textStorage.length, NSMaxRange(section.content) == location else { return false }
        return section.content.length > 0 || (location > 0 &&
            (textStorage.string as NSString).character(at: location - 1) == 0x0A)
    }

    func unfoldHeadings(containing range: NSRange) {
        guard !foldedHeadingIDs.isEmpty else { return }
        let ids = headingSections.compactMap { section -> UUID? in
            guard let id = section.id, foldedHeadingIDs.contains(id),
                  headingContentContainsCaret(section, at: range.location) || NSIntersectionRange(range, section.content).length > 0 else { return nil }
            return id
        }
        for id in ids { setHeadingFold(id: id, folded: false) }
    }

    /// Viewport-only controls: their bounds follow the final glyph's line,
    /// including wrapped headings, without forcing offscreen layout.
    func updateHeadingControls() {
        guard !updatingHeadingControls, let textView, let layoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else { return }
        updatingHeadingControls = true
        defer { updatingHeadingControls = false }
        let start = contentStorage.offset(from: contentStorage.documentRange.location, to: viewport.location)
        let end = contentStorage.offset(from: contentStorage.documentRange.location, to: viewport.endLocation)
        var visible = Set<Int>()
        for section in headingSections where section.heading.location >= start && section.heading.location < end {
            guard foldedHeadingIDs.isEmpty || !headingSections.contains(where: { outer in
                outer.id.map(foldedHeadingIDs.contains) == true && NSLocationInRange(section.heading.location, outer.content)
            }) else { continue }
            let line = lineRange(at: section.heading.location)
            let glyphRange = line.length == 0 ? line : (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(line) - 1)
            guard let glyph = rect(for: glyphRange), glyph.intersects(textView.visibleRect) else { continue }
            let key = section.heading.location
            visible.insert(key)
            let button = headingControls[key] ?? NoteHeadingButton(frame: .zero)
            button.engine = self
            button.headingOffset = key
            button.folded = section.id.map(foldedHeadingIDs.contains) == true
            button.ink = style.markerColor
            button.isEnabled = !isReadOnly && activity == .idle
            // R14 B.4: 8 wide, 6 after the last glyph, centred on the
            // heading's x-height middle (TextKit sets the baseline its
            // rounded descent above the line box's floor).
            let font = textStorage.attribute(.font, at: glyphRange.location, effectiveRange: nil) as? NSFont ?? style.headingFont
            let xMiddle = glyph.maxY - (-font.descender).rounded() - font.xHeight / 2
            let centreX = glyph.maxX + AtticNoteType.foldChevronGap + AtticNoteType.foldChevronWidth / 2
            button.frame = CGRect(x: centreX - 10, y: (xMiddle - 10).rounded(), width: 20, height: 20)
            button.setAccessibilityLabel("\(button.folded ? "Unfold" : "Fold") \((textStorage.string as NSString).substring(with: line))")
            button.setAccessibilityIdentifier("note-heading-fold-\(key)")
            button.toolTip = button.folded ? "Unfold heading (⌃⌘H)" : "Fold heading (⌃⌘H)"
            AtticOverlayHierarchy.attach(button, to: textView)
            headingControls[key] = button
            button.needsDisplay = true
        }
        for key in Array(headingControls.keys) where !visible.contains(key) {
            if let button = headingControls.removeValue(forKey: key) { AtticOverlayHierarchy.remove(button) }
        }
    }
}

/// The owner's thin, round-ended chevron (o22), rotated from down to right.
final class NoteHeadingButton: NSButton {
    weak var engine: NoteEditorEngine?
    var headingOffset = 0
    var folded = false
    var ink = NSColor.secondaryLabelColor
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        target = self
        action = #selector(toggle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { _ = engine?.toggleHeadingFold(at: headingOffset) }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if folded { context.rotate(by: -.pi / 2) }
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let half = AtticNoteType.foldChevronWidth / 2
        context.move(to: CGPoint(x: -half, y: -2))
        context.addLine(to: CGPoint(x: 0, y: 2))
        context.addLine(to: CGPoint(x: half, y: -2))
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Code languages and callout icons, as the chrome names them

/// The code block's language menu (spec C: Plain Text and twelve languages)
/// and the label each stored id shows.
enum NoteCodeLanguageName {
    /// The menu's languages in order; nil is Plain Text.
    static let menu: [String?] = [nil, "javascript", "typescript", "json", "swift", "python", "shell",
                                  "html", "css", "sql", "yaml", "diff", "mermaid"]

    static func label(for language: String?) -> String {
        switch language {
        case nil: String(localized: "Plain text")
        case "javascript": "JavaScript"
        case "typescript": "TypeScript"
        case "json": "JSON"
        case "swift": "Swift"
        case "python": "Python"
        case "shell": String(localized: "Shell")
        case "html": "HTML"
        case "css": "CSS"
        case "sql": "SQL"
        case "yaml": "YAML"
        case "diff": String(localized: "Diff")
        case "mermaid": "Mermaid"
        case let other?: other
        }
    }

    /// The menu's row title (Plain Text in title case, as menus write it).
    static func menuTitle(for language: String?) -> String {
        language == nil ? String(localized: "Plain Text") : label(for: language)
    }
}

/// The callout's Icon menu (spec C): six emoji, the system palette and No Icon.
enum NoteCalloutIcons {
    static let menu = ["💡", "⚠️", "✅", "❗", "📌", "ℹ️"]
}

// MARK: - The block handle and the drop line (R14 D.2)

/// The handle beside the hovered block (Codex's six dots, B.4): 2 × 3 dots
/// of 2 pt, 4 apart both ways, in the table grips' quiet ink, in a 24 × 28
/// hit area. A click selects the block; a drag moves it. VoiceOver moves it
/// with Move Block Up and Move Block Down.
final class NoteBlockHandleView: NSView {
    private typealias T = AtticNoteType
    var ink: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }
    var onPress: ((NSEvent) -> Void)?
    var onMove: ((_ up: Bool) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Block Handle"))
        setAccessibilityHelp(String(localized: "Click to select the block; drag to move it"))
        setAccessibilityIdentifier("note-block-handle")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Move Block Up")) { [weak self] in self?.onMove?(true) ?? false },
            NSAccessibilityCustomAction(name: String(localized: "Move Block Down")) { [weak self] in self?.onMove?(false) ?? false }
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { onPress?(event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(ink.cgColor)
        let dot = T.handleDot, pitch = T.handlePitch
        for column in 0..<2 {
            for row in 0..<3 {
                let x = bounds.midX + (CGFloat(column) - 0.5) * pitch - dot / 2
                let y = bounds.midY + CGFloat(row - 1) * pitch - dot / 2
                context.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
            }
        }
    }
}

/// ProseMirror's drop cursor: a 2 pt line in the accent, radius 1, where
/// the dragged block will land (only ever between blocks).
final class NoteDropLineView: NSView {
    var ink: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ink.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: AtticNoteType.dropLineThickness / 2, yRadius: AtticNoteType.dropLineThickness / 2).fill()
    }
}
