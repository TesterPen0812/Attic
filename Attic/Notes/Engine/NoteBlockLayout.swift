import AppKit
import SwiftUI

/// What Notes v2 draws beside a paragraph's own text (text direction 5,
/// owner 2026-10-08): the Mono block's one rounded fill, a list's dot or
/// number, and a quote's bar. Layout stays TextKit's: only the Mono block
/// changes geometry, through its fragments' margins and padding, so every
/// line keeps viewport-driven layout and its own selection and caret.
///
/// Each Mono paragraph (one code line) is a slice of its block: the first
/// carries the block's top padding, the last its bottom padding, and every
/// slice draws the block's fill clipped to itself, so a block of any length
/// reads as one rounded rectangle with no seams.
final class NoteBlockLayoutFragment: NSTextLayoutFragment {
    enum Decoration: Equatable {
        /// `exitsAtEnd`: the block's last line ends the note, and the empty
        /// line after it (inside this fragment) is not code.
        case mono(starts: Bool, ends: Bool, exitsAtEnd: Bool = false)
        /// A dot centred at `x` in the column.
        case bullet(x: CGFloat)
        /// A list number ending at `trailing` in the column.
        case number(String, trailing: CGFloat)
        /// A bar from `x` in the column; it joins the quote line above or
        /// below across their gap.
        case quote(x: CGFloat, joinsAbove: Bool, joinsBelow: Bool)
    }

    var decoration: Decoration = .mono(starts: true, ends: true, exitsAtEnd: false)
    /// The paragraph's space before its first line (inside the fragment).
    var spacingBefore: CGFloat = 0
    /// How far the paragraph's line boxes sit above the draft's (see
    /// `NoteTextStyle.baselineShift`): the quote's bar follows the draft's.
    var boxShift: CGFloat = 0
    var ink: NSColor = .labelColor
    var fill: NSColor = .clear
    var border: NSColor?
    var markerFont: NSFont = NoteTextStyle.font(for: AtticNoteType.body)

    private typealias T = AtticNoteType
    private static var monoShift: CGFloat { NoteTextStyle.baselineShift(T.mono) }

    private var mono: (starts: Bool, ends: Bool, exitsAtEnd: Bool)? {
        if case let .mono(starts, ends, exitsAtEnd) = decoration { return (starts, ends, exitsAtEnd) }
        return nil
    }

    // The Mono block's padding: the text sits 12 × 14 inside the block, its
    // glyphs on the draft's baselines (the top padding gives up the line's
    // baseline shift, the bottom one takes it).
    override var leadingPadding: CGFloat { mono == nil ? super.leadingPadding : T.monoPaddingH }
    override var trailingPadding: CGFloat { mono == nil ? super.trailingPadding : T.monoPaddingH }
    override var topMargin: CGFloat {
        guard let mono else { return super.topMargin }
        return mono.starts ? T.monoPaddingV - Self.monoShift : 0
    }
    override var bottomMargin: CGFloat {
        guard let mono else { return super.bottomMargin }
        return mono.ends && !mono.exitsAtEnd ? T.monoPaddingV + Self.monoShift : 0
    }

    private var columnWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// The block's rectangle in this fragment's coordinates: the column's
    /// full width, from the block's top (first slice) to its bottom (last).
    var monoBlockRect: CGRect? {
        guard let mono else { return nil }
        let top = mono.starts ? spacingBefore : 0
        var bottom = layoutFragmentFrame.height
        if mono.exitsAtEnd, let last = textLineFragments.last(where: { $0.characterRange.length > 0 }) ?? textLineFragments.first {
            // Not the note's empty last line: it sits below the block.
            bottom = last.typographicBounds.maxY + T.monoPaddingV + Self.monoShift
        }
        return CGRect(x: -layoutFragmentFrame.minX, y: top, width: columnWidth, height: max(0, bottom - top))
    }

    private var firstBaseline: CGFloat? {
        guard let line = textLineFragments.first else { return nil }
        return line.typographicBounds.minY + line.glyphOrigin.y
    }

    private var decorationRect: CGRect {
        switch decoration {
        case .mono:
            return monoBlockRect ?? .zero
        case let .bullet(x):
            let baseline = firstBaseline ?? 0
            return CGRect(x: x - layoutFragmentFrame.minX - T.bulletDot, y: baseline - 12, width: T.bulletDot * 2, height: 14)
        case let .number(_, trailing):
            let baseline = firstBaseline ?? 0
            return CGRect(x: -layoutFragmentFrame.minX, y: baseline - markerFont.ascender - 1,
                          width: trailing + 1, height: markerFont.ascender - markerFont.descender + 2)
        case .quote:
            return quoteBar ?? .zero
        }
    }

    private var quoteBar: CGRect? {
        guard case let .quote(x, joinsAbove, joinsBelow) = decoration else { return nil }
        let top = joinsAbove ? 0 : spacingBefore + boxShift
        let bottom = layoutFragmentFrame.height + (joinsBelow ? 0 : boxShift)
        return CGRect(x: x - layoutFragmentFrame.minX, y: top, width: T.quoteBar, height: max(0, bottom - top))
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(decorationRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let block = monoBlockRect, let mono {
            drawBlock(block, starts: mono.starts, ends: mono.ends || mono.exitsAtEnd, at: point, in: context)
        }
        super.draw(at: point, in: context)
        switch decoration {
        case .mono:
            break
        case let .bullet(x):
            guard let baseline = firstBaseline else { return }
            let centreY = baseline - markerFont.xHeight / 2
            let dot = CGRect(x: point.x + x - layoutFragmentFrame.minX - T.bulletDot / 2,
                             y: point.y + centreY - T.bulletDot / 2, width: T.bulletDot, height: T.bulletDot)
            context.saveGState()
            context.setFillColor(ink.cgColor)
            context.fillEllipse(in: dot)
            context.restoreGState()
        case let .number(text, trailing):
            guard let baseline = firstBaseline else { return }
            let string = NSAttributedString(string: text, attributes: [.font: markerFont, .foregroundColor: ink])
            let width = string.size().width
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            string.draw(at: CGPoint(x: point.x + trailing - layoutFragmentFrame.minX - width,
                                    y: point.y + baseline - markerFont.ascender))
            NSGraphicsContext.restoreGraphicsState()
        case .quote:
            guard let bar = quoteBar else { return }
            context.saveGState()
            context.setFillColor(ink.cgColor)
            context.fill(bar.offsetBy(dx: point.x, dy: point.y))
            context.restoreGState()
        }
    }

    /// The block's continuous rounded rectangle, cut to this slice: a slice
    /// that does not start or end the block extends past its own edge, so
    /// its corners fall outside the clip.
    private func drawBlock(_ block: CGRect, starts: Bool, ends: Bool, at point: CGPoint, in context: CGContext) {
        let slice = block.offsetBy(dx: point.x, dy: point.y)
        let reach = T.monoRadius * 2
        let full = CGRect(x: slice.minX, y: slice.minY - (starts ? 0 : reach),
                          width: slice.width, height: slice.height + (starts ? 0 : reach) + (ends ? 0 : reach))
        let path = RoundedRectangle(cornerRadius: T.monoRadius, style: .continuous).path(in: full).cgPath
        context.saveGState()
        context.clip(to: slice)
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        if let border {
            // Increase Contrast: the block's edge, 1 pt inside it.
            let inset = RoundedRectangle(cornerRadius: T.monoRadius - 0.5, style: .continuous)
                .path(in: full.insetBy(dx: 0.5, dy: 0.5)).cgPath
            context.addPath(inset)
            context.setStrokeColor(border.cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
        context.restoreGState()
    }
}

// MARK: - The engine's layout hooks

extension NoteEditorEngine: NSTextLayoutManagerDelegate, NSTextContentStorageDelegate {
    /// List paragraphs keep their `NSTextList`s in storage (copy as rich
    /// text and print use them), but TextKit 2 would lay its own marker and
    /// fixed 36 pt indent into the line. The editor shows them without:
    /// the text at the list's own indent (22 pt), the marker drawn by
    /// `NoteBlockLayoutFragment`.
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length,
              let style = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              !style.textLists.isEmpty else { return nil }
        let text = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, part, _ in
            guard let style = value as? NSParagraphStyle, !style.textLists.isEmpty,
                  let plain = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            plain.textLists = []
            text.addAttribute(.paragraphStyle, value: plain, range: part)
        }
        return NSTextParagraph(attributedString: text)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: location)
        guard offset > 0, offset < textStorage.length,
              let decoration = decoration(forParagraphAt: offset) else {
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        let fragment = NoteBlockLayoutFragment(textElement: textElement, range: nil)
        let paragraph = textStorage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
        fragment.decoration = decoration
        fragment.spacingBefore = paragraph?.paragraphSpacingBefore ?? 0
        let kind = paragraphKind(at: offset)
        fragment.boxShift = NoteTextStyle.boxShift(kind)
        switch decoration {
        case .mono:
            fragment.fill = style.codeBlockColor
            fragment.border = style.codeBlockBorder
        case .number:
            fragment.ink = style.markerColor
            fragment.markerFont = NSFont.monospacedDigitSystemFont(ofSize: AtticNoteType.body.size, weight: .regular)
        case .bullet, .quote:
            fragment.ink = style.bodyColor
            fragment.markerFont = style.font(for: kind)
        }
        return fragment
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
        case "bullet":
            return .bullet(x: depth + AtticNoteType.bulletCentre)
        case "number":
            let ordinal = numberedOrdinal(at: line.location, indent: attributes[.noteBlockIndent] as? Int ?? 0)
            return .number("\(ordinal).", trailing: depth + AtticNoteType.listTextInset - AtticNoteType.numberGap)
        case "quote":
            return .quote(x: depth, joinsAbove: style(paragraphBefore: line) == "quote",
                          joinsBelow: style(paragraphAfter: line) == "quote")
        default:
            return nil
        }
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
        return pendingParagraphStyle?.location == next && pendingParagraphStyle?.state.style == .mono
    }

    /// The Mono block around `location` (its first paragraph's start to its
    /// last paragraph's end, without the final line break), or nil.
    func monoBlockRange(at location: Int) -> NSRange? {
        guard location < textStorage.length, paragraphStyle(at: location) == .mono else { return nil }
        var start = paragraphRange(at: location)
        while start.location > 0 {
            let previous = paragraphRange(at: start.location - 1)
            guard previous.location > 0, paragraphStyle(at: previous.location) == .mono else { break }
            start = previous
        }
        var end = paragraphRange(at: location)
        while NSMaxRange(end) < textStorage.length, paragraphStyle(at: NSMaxRange(end)) == .mono {
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
