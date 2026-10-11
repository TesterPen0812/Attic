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
        case history
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
        case .history: return .zero
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
            top = Self.baseline(of: first) - markerFont.ascender
        } else {
            top = spacingBefore
        }
        let bottom: CGFloat
        if joinsBelow {
            bottom = layoutFragmentFrame.height
        } else if let last {
            bottom = Self.baseline(of: last) - markerFont.descender
        } else {
            bottom = layoutFragmentFrame.height
        }
        return CGRect(x: x - layoutFragmentFrame.minX, y: top, width: T.quoteBar, height: max(0, bottom - top))
    }

    /// A line's baseline in the fragment's coordinates.
    private static func baseline(of line: NSTextLineFragment) -> CGFloat {
        line.typographicBounds.minY + line.glyphOrigin.y
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(decorationRect)
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
            drawBlock(block, starts: mono.starts, ends: mono.ends || mono.exitsAtEnd, at: point, in: context)
        }
        super.draw(at: point, in: context)
        switch decoration {
        case .mono, .history:
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
            guard let bar = quoteBar, case let .quote(_, joinsAbove, joinsBelow) = decoration else { return }
            drawQuoteBar(bar.offsetBy(dx: point.x, dy: point.y), joinsAbove: joinsAbove, joinsBelow: joinsBelow, in: context)
        }
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
        let native = offset > 0 && offset < textStorage.length ? decoration(forParagraphAt: offset) : nil
        guard offset >= 0, offset < textStorage.length,
              let decoration = native ?? (changed ? .history : nil) else {
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        let fragment = NoteBlockLayoutFragment(textElement: textElement, range: nil)
        let paragraph = textStorage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
        fragment.decoration = decoration
        fragment.hasHistoryDifference = changed
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
        case .quote:
            fragment.ink = style.quoteBarColor
            fragment.markerFont = style.font(for: kind)
        case .bullet, .history:
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
        textStorage.enumerateAttribute(.noteBlockStyle, in: NSRange(location: 0, length: string.length)) { value, run, _ in
            guard value as? String == "heading" else { return }
            var offset = run.location
            while offset < NSMaxRange(run) {
                let paragraph = string.paragraphRange(for: NSRange(location: offset, length: 0))
                if paragraph.location > 0, seen.insert(paragraph.location).inserted {
                    var id: UUID?
                    textStorage.enumerateAttribute(.noteBlockID, in: paragraph) { value, _, stop in
                        if let found = value as? UUID { id = found; stop.pointee = true }
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
        history.recordExternalChange(name: wasFolded ? "Unfold Heading" : "Fold Heading",
            undo: { [weak self] in self?.setHeadingFold(id: id, folded: wasFolded); return self != nil },
            redo: { [weak self] in self?.setHeadingFold(id: id, folded: !wasFolded); return self != nil })
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
        onTextChange?()
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
            button.frame = CGRect(x: glyph.maxX + 3, y: glyph.midY - 10, width: 20, height: 20)
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
        context.move(to: CGPoint(x: -4.5, y: -2))
        context.addLine(to: CGPoint(x: 0, y: 2))
        context.addLine(to: CGPoint(x: 4.5, y: -2))
        context.strokePath()
        context.restoreGState()
    }
}
