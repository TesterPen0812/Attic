import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Notes v2, round 1: text direction 5 ("Notion-like", owner 2026-10-08) in
/// the native editor. The values are the draft's own
/// (`redesign-notes-v2/drafts/v2-04-text-directions.html`, `notion`); the
/// laid-out lines are checked against the draft's CSS model, and the Mono
/// block's wraps, empty lines, Return, selection, Copy and spell checking.
@MainActor
final class NotesV2TypographyTests: XCTestCase {
    private typealias T = AtticNoteType
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    /// An editor in the draft's 264 pt column (a 320 pt panel, 28 in).
    private func makeEngine(_ blocks: [NoteBlock], height: CGFloat = 520) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        textView.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        window.makeFirstResponder(textView)
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        textView.layoutSubtreeIfNeeded()
        return (engine, textView)
    }

    private func styled(_ text: String, _ style: String, level: Int? = nil, indent: Int? = nil) -> NoteBlock {
        var block = NoteBlock.text(text)
        block.style = style
        block.level = level
        block.indent = indent
        return block
    }

    /// The owner's CIA note, as the drafts show it.
    private var cia: [NoteBlock] {
        [.text("CIA impact"),
         styled("Colonial Pipeline ransomware attack", "heading", level: 1),
         .text("The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication"),
         styled("Confidentiality", "heading", level: 3), .text(""),
         styled("Integrity", "heading", level: 3), styled("Availability", "heading", level: 3),
         .text("The clearest impact was the staff losing access to affected IT system, which led to a shutdown causing fuel transport to be interrupted"),
         styled("Sources:", "heading", level: 3),
         styled("@inproceedings{beerman2023review,", "mono"),
         styled("  title={A review of colonial pipeline ransomware attack},", "mono"),
         styled("  author={Beerman, Jack and Berent, David and Falter, Zach", "mono")]
    }

    private func fragments(_ engine: NoteEditorEngine) -> [NSTextLayoutFragment] {
        var result: [NSTextLayoutFragment] = []
        engine.layoutManager?.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location,
                                                           options: [.ensuresLayout]) { fragment in
            result.append(fragment)
            return true
        }
        return result
    }

    private func location(of text: String, in engine: NoteEditorEngine) -> Int {
        (engine.textStorage.string as NSString).range(of: text).location
    }

    private func paragraphStyle(_ text: String, _ engine: NoteEditorEngine) throws -> NSParagraphStyle {
        try XCTUnwrap(engine.textStorage.attribute(.paragraphStyle, at: location(of: text, in: engine), effectiveRange: nil)
            as? NSParagraphStyle)
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Tokens

    func testTypeScaleIsTheDraftsDirection5() {
        XCTAssertEqual(T.title, T.Role(size: 18.5, lineHeight: 22, weight: 700))
        // R14 (notes-r14-spec.md B.2–B.4): Codex's proportions scaled to the panel.
        XCTAssertEqual(T.titleStyle, T.Role(size: 16.5, lineHeight: 21, weight: 650))
        XCTAssertEqual(T.heading, T.Role(size: 15, lineHeight: 20, weight: 650))
        XCTAssertEqual(T.subheading, T.Role(size: 13.5, lineHeight: 18.5, weight: 650))
        XCTAssertEqual(T.smallHeading, T.Role(size: 12.5, lineHeight: 18.5, weight: 650))
        XCTAssertEqual(T.body, T.Role(size: 12.5, lineHeight: 18.5, weight: 400))
        XCTAssertEqual(T.quote, T.Role(size: 12.5, lineHeight: 18.5, weight: 400))
        XCTAssertEqual(T.mono, T.Role(size: 11, lineHeight: 16.5, weight: 400, monospaced: true))
        XCTAssertEqual(T.codeLabel, T.Role(size: 11, lineHeight: 14, weight: 400))
        XCTAssertEqual([T.paragraphGap, T.listItemGap, T.titleToText], [8, 3, 10])
        XCTAssertEqual([T.aboveTitleStyle, T.aboveHeading, T.aboveSubheading, T.aboveSmallHeading], [20, 16, 14, 12])
        XCTAssertEqual([T.belowTitleStyle, T.belowHeading, T.belowSubheading, T.belowSmallHeading, T.headingAfterHeading], [6, 6, 6, 6, 6])
        XCTAssertEqual([T.blockMargin, T.blockAfterHeading], [12, 6])
        XCTAssertEqual([T.monoPaddingV, T.monoPaddingH, T.monoRadius, T.monoHairline], [8, 12, 10, 0.5])
        XCTAssertEqual([T.monoLabelHeight, T.monoLabelGap], [14, 4])
        XCTAssertEqual([T.monoCopySize, T.monoCopyInset, T.monoCopyTop], [16, 7, 7])
        XCTAssertEqual([T.listTextInset, T.markerSlot, T.bulletDot, T.bulletRing, T.bulletSquare, T.numberGap], [20, 14, 4, 4.5, 3.5, 6])
        XCTAssertEqual([T.quoteBar, T.quoteTextInset], [3, 20])
        XCTAssertEqual([T.calloutPaddingV, T.calloutPaddingH, T.calloutRadius, T.calloutIconSize, T.calloutTextInset], [8, 12, 10, 15, 36])
        XCTAssertEqual([T.inlineCodeSize, T.inlineCodeChipHeight, T.inlineCodeChipRadius, T.inlineCodeChipPadding], [11, 14, 4, 4])

        let style = NoteTextStyle()
        XCTAssertEqual(style.titleFont.pointSize, 18.5)
        XCTAssertTrue(style.titleFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(style.titleStyleFont.pointSize, 16.5)
        XCTAssertEqual(style.headingFont.pointSize, 15)
        XCTAssertEqual(style.subheadingFont.pointSize, 13.5)
        XCTAssertEqual(style.smallHeadingFont.pointSize, 12.5)
        XCTAssertEqual(style.bodyFont.pointSize, 12.5)
        XCTAssertEqual(style.quoteFont.pointSize, 12.5)
        XCTAssertEqual(style.monoFont.pointSize, 11)
        XCTAssertTrue(style.monoFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        // 650 sits between semibold and bold: wider than semibold, narrower than bold.
        let sample = "Colonial Pipeline ransomware" as NSString
        func width(_ font: NSFont) -> CGFloat { sample.size(withAttributes: [.font: font]).width }
        XCTAssertGreaterThan(width(style.titleStyleFont), width(.systemFont(ofSize: 16.5, weight: .semibold)))
        XCTAssertLessThan(width(style.titleStyleFont), width(.systemFont(ofSize: 16.5, weight: .bold)))
        // One near-black ink for the text and its headings.
        XCTAssertEqual(style.bodyColor, style.titleColor)
        XCTAssertEqual(style.quoteColor, style.bodyColor)
    }

    /// The space between line boxes, by the lower block's kind; a heading
    /// binds to what follows it.
    /// A39 F10: the empty-line hint and a new note's "Title" are visibly
    /// quieter than typed text, on every surface and mode.
    func testTheHintIsQuieterThanTypedTextInLightAndDark() {
        for context in [AtticDesignContext.default, AtticDesignContext(mode: .dark),
                        AtticDesignContext(mode: .dark, increaseContrast: true), AtticDesignContext(increaseContrast: true)] {
            let tokens = AtticColorTokens.resolve(context)
            let hint = tokens.hintInk, text = tokens.ink(.heading)
            XCTAssertLessThan(hint.alpha, 1, "partial opacity: it follows the surface")
            XCTAssertEqual([hint.red, hint.green, hint.blue], [text.red, text.green, text.blue], "the text's own ink")
            XCTAssertEqual(NoteTextStyle(design: context).placeholderColor, hint.nsColor)
        }
        let plain = AtticColorTokens.resolve(AtticDesignContext.default).hintInk.alpha
        let high = AtticColorTokens.resolve(AtticDesignContext(increaseContrast: true)).hintInk.alpha
        XCTAssertGreaterThan(high, plain, "Increase Contrast steps it up")
    }

    func testGapsAreTheDrafts() {
        typealias K = NoteParagraphKind
        // R14 B.3: paragraphs 8, list items 3, boxes 12 around, headings
        // 20 / 16 / 14 / 12 above and 6 below, a heading 6 under a heading.
        let tip = K.callout(icon: "💡"), warning = K.callout(icon: "⚠️")
        let cases: [(K, K?, CGFloat)] = [
            (.body, nil, 0), (.titleStyle, .title, 10), (.body, .title, 10), (.mono, .title, 10),
            (.titleStyle, .body, 20), (.heading, .body, 16), (.subheading, .body, 14), (.smallHeading, .body, 12),
            (.subheading, .subheading, 6), (.heading, .titleStyle, 6), (.smallHeading, .subheading, 6), (.heading, .mono, 16),
            (.body, .titleStyle, 6), (.body, .heading, 6), (.body, .subheading, 6), (.body, .smallHeading, 6),
            (.mono, .subheading, 6), (.mono, .titleStyle, 6), (tip, .heading, 6), (.quote, .heading, 6), (.listItem, .heading, 6),
            (.body, .body, 8), (.listItem, .body, 8), (.body, .listItem, 8), (.listItem, .listItem, 3),
            (.quote, .quote, 8), (.quote, .body, 12), (.body, .quote, 12),
            (tip, tip, 8), (warning, tip, 12), (tip, .body, 12), (.body, tip, 12), (tip, .quote, 12),
            (.mono, .body, 12), (.body, .mono, 12), (.mono, .mono, 0), (.listItem, .mono, 12),
            (.blockObject, .body, 12), (.body, .blockObject, 12),
            // A divider's 12 is to its rule, mid-line in its 18.5 pt box.
            (.divider, .body, 3.25), (.body, .divider, 3.25), (.divider, .heading, 0)
        ]
        for (kind, previous, gap) in cases {
            XCTAssertEqual(NoteTextStyle.gap(above: kind, after: previous), gap, "\(kind) after \(String(describing: previous))")
        }
    }

    // MARK: Lines on the draft's baselines

    /// The CIA note laid out natively, line for line on the draft's CSS
    /// model: each block's line boxes follow the one above by the draft's
    /// gap, and every first line's baseline sits where CSS centres its glyphs
    /// in its line box (within half a point). Line counts are TextKit's own.
    func testTheOwnersNoteSitsOnTheDraftsBaselines() throws {
        let (engine, _) = makeEngine(cia)
        let frags = fragments(engine)
        XCTAssertEqual(frags.count, cia.count)
        var kinds: [NoteParagraphKind] = []
        var location = 0
        for _ in cia {
            kinds.append(engine.paragraphKind(at: location))
            location = NSMaxRange(engine.paragraphRange(at: location))
        }
        XCTAssertEqual(kinds, [.title, .titleStyle, .body, .subheading, .body, .subheading, .subheading, .body, .subheading,
                               .mono, .mono, .mono])
        var cssBottom: CGFloat = 0
        var previous: NoteParagraphKind?
        var inMono = false
        for (index, fragment) in frags.enumerated() {
            let kind = kinds[index]
            let role = kind.role
            let font = NoteTextStyle.font(for: role)
            var cssTop = cssBottom + NoteTextStyle.gap(above: kind, after: previous)
            if kind == .mono, !inMono { cssTop += NoteBlockLayoutFragment.monoTopInset }
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 || fragment.textLineFragments.count == 1 }
            let first = try XCTUnwrap(lines.first)
            let native = fragment.layoutFragmentFrame.minY + first.typographicBounds.minY + first.glyphOrigin.y
            let css = cssTop + (role.lineHeight - (font.ascender - font.descender + font.leading)) / 2 + font.ascender
            XCTAssertEqual(native, css, accuracy: 0.5, "paragraph \(index) (\(kind)): baseline")
            cssBottom = cssTop + CGFloat(lines.count) * role.lineHeight
            inMono = kind == .mono
            previous = kind == .mono ? .mono : kind
            // Every line of a paragraph is its role's line height apart.
            for (a, b) in zip(lines, lines.dropFirst()) {
                XCTAssertEqual(b.typographicBounds.minY - a.typographicBounds.minY, role.lineHeight, accuracy: 0.01)
            }
        }
    }

    func testTheEmptyParagraphIsOneBodyLineAndHeadingsStickToTheirText() throws {
        let (engine, _) = makeEngine(cia)
        let frags = fragments(engine)
        // Confidentiality, the empty line, Integrity.
        let empty = frags[4]
        XCTAssertEqual(empty.layoutFragmentFrame.minY, frags[3].layoutFragmentFrame.maxY, accuracy: 0.01)
        XCTAssertEqual(try paragraphStyle("Integrity", engine).paragraphSpacingBefore,
                       NoteTextStyle.spacingBefore(.subheading, after: .body), accuracy: 0.001)
        XCTAssertEqual(try paragraphStyle("The attackers", engine).paragraphSpacingBefore,
                       NoteTextStyle.spacingBefore(.body, after: .titleStyle), accuracy: 0.001)
        for text in ["Colonial", "The attackers", "Integrity", "@inproceedings"] {
            XCTAssertEqual(try paragraphStyle(text, engine).paragraphSpacing, 0, "\(text): no gap counted twice")
        }
    }

    // MARK: The Mono block

    private func monoFragments(_ engine: NoteEditorEngine) -> [NoteBlockLayoutFragment] {
        fragments(engine).compactMap { $0 as? NoteBlockLayoutFragment }.filter { $0.monoBlockRect != nil }
    }

    func testMonoIsOneBlockAcrossItsLinesWithTheDraftsPadding() throws {
        let (engine, view) = makeEngine(cia)
        let blocks = monoFragments(engine)
        XCTAssertEqual(blocks.count, 3)
        let column = try XCTUnwrap(view.textContainer?.size.width)
        XCTAssertEqual(column, 264)
        var rects: [CGRect] = []
        for fragment in blocks {
            let rect = try XCTUnwrap(fragment.monoBlockRect)
                .offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
            XCTAssertEqual(rect.minX, 0, accuracy: 0.01, "the column's full width")
            XCTAssertEqual(rect.width, column, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(fragment.renderingSurfaceBounds.width, column - 0.5)
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                XCTAssertGreaterThanOrEqual(fragment.layoutFragmentFrame.minX + line.typographicBounds.minX, T.monoPaddingH - 0.01)
                XCTAssertLessThanOrEqual(fragment.layoutFragmentFrame.minX + line.typographicBounds.maxX, column - T.monoPaddingH + 0.5)
            }
            rects.append(rect)
        }
        // The slices meet with no seam: one block.
        for (a, b) in zip(rects, rects.dropFirst()) { XCTAssertEqual(a.maxY, b.minY, accuracy: 0.01) }
        let block = rects.reduce(rects[0]) { $0.union($1) }
        let firstLine = try XCTUnwrap(blocks.first?.textLineFragments.first)
        let lastFragment = try XCTUnwrap(blocks.last)
        let lastLine = try XCTUnwrap(lastFragment.textLineFragments.last)
        // O18-03 (10-17): a line's box is the font's natural one, with its
        // line spacing above it; the R14 box starts that spacing higher.
        XCTAssertEqual(firstLine.typographicBounds.minY + blocks[0].layoutFragmentFrame.minY - block.minY,
                       NoteBlockLayoutFragment.monoTopInset - NoteTextStyle.baselineShift(T.mono) + NoteTextStyle.lineLeading(T.mono), accuracy: 0.01)
        XCTAssertEqual(block.maxY - (lastFragment.layoutFragmentFrame.minY + lastLine.typographicBounds.maxY),
                       T.monoPaddingV + NoteTextStyle.baselineShift(T.mono), accuracy: 0.01)
        // 6 above the block after "Sources:" (a heading binds to it).
        let sources = fragments(engine)[8]
        XCTAssertEqual(block.minY - sources.layoutFragmentFrame.maxY,
                       NoteTextStyle.gap(above: .mono, after: .subheading) + NoteTextStyle.boxShift(.subheading), accuracy: 0.01)
    }

    /// The draft's first citation line fits whole (33 characters; 14 pt sides
    /// once wrapped a lone "w,"). Soft wraps hang from the line's own leading
    /// spaces.
    func testMonoWrapsLikeTheDraftAndHangsFromItsLeadingSpaces() throws {
        let (engine, _) = makeEngine(cia)
        let blocks = monoFragments(engine)
        // The arithmetic: 33 SF Mono characters at 11 pt need 224.4 pt; the
        // 264 pt column less 2 × 12 leaves 240.
        let citation = "@inproceedings{beerman2023review,"
        let needed = (citation as NSString).size(withAttributes: [.font: NoteTextStyle().monoFont]).width
        XCTAssertLessThanOrEqual(needed, 264 - 2 * T.monoPaddingH)
        let first = blocks[0].textLineFragments.filter { $0.characterRange.length > 0 }
        XCTAssertEqual(first.count, 1, "the first citation line fits whole")
        let text = engine.textStorage.string as NSString
        let start = location(of: "@inproceedings", in: engine)
        XCTAssertEqual(text.substring(with: NSRange(location: start, length: first[0].characterRange.length))
            .trimmingCharacters(in: .newlines), citation)
        let indent = NoteTextStyle().monoHang(for: "  title")
        XCTAssertGreaterThan(indent, 12)
        for fragment in blocks.dropFirst() {
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            XCTAssertGreaterThan(lines.count, 1, "the long lines wrap")
            XCTAssertEqual(lines[0].typographicBounds.minX, 0, accuracy: 0.01)
            for line in lines.dropFirst() {
                XCTAssertEqual(line.typographicBounds.minX, indent, accuracy: 0.01, "the wrap hangs under the text after its spaces")
            }
        }
    }

    func testEmptyMonoLinesStayInTheBlock() throws {
        let (engine, _) = makeEngine([.text("Title"), styled("let a = 1", "mono"), styled("", "mono"),
                                      styled("let b = 2", "mono"), .text("After")])
        let blocks = monoFragments(engine)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map(\.decoration), [.mono(starts: true, ends: false, exitsAtEnd: false),
                                                  .mono(starts: false, ends: false, exitsAtEnd: false),
                                                  .mono(starts: false, ends: true, exitsAtEnd: false)])
        XCTAssertEqual(blocks[1].layoutFragmentFrame.height, T.mono.lineHeight, accuracy: 0.01, "an empty line is one code line")
        XCTAssertEqual(engine.document().blocks.count, 5, "layout never removes the empty code line")
        XCTAssertEqual(engine.monoBlockText(at: location(of: "let b", in: engine)), "let a = 1\n\nlet b = 2")
    }

    func testReturnContinuesCodeAndAnEmptyLastLineLeavesIt() throws {
        let (engine, view) = makeEngine([.text("Title"), styled("first", "mono"), .text("body")])
        let start = location(of: "first", in: engine)
        view.setSelectedRange(NSRange(location: start + 5, length: 0))
        view.insertNewline(nil)
        view.insertText("second", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .mono, "Return continues the block")
        view.insertNewline(nil)
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .mono)
        view.insertNewline(nil)
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .body, "Return on an empty code line leaves the block")
        XCTAssertEqual(engine.document().blocks.compactMap { $0.style == "mono" ? $0.text : nil }, ["first", "second"])
        XCTAssertEqual(monoFragments(engine).map(\.decoration).last, .mono(starts: false, ends: true, exitsAtEnd: false))
    }

    /// A block that ends the note: its bottom padding is drawn and the text
    /// view is tall enough for it; after leaving it with Return, the empty
    /// last line sits a block margin below it, outside the block.
    func testABlockAtTheNotesEndKeepsItsPaddingAndTheEmptyLineSitsBelowIt() throws {
        let (engine, view) = makeEngine([.text("Title"), .text("Body"), styled("let a = 1", "mono")])
        let block = try XCTUnwrap(monoFragments(engine).last)
        XCTAssertEqual(block.bottomMargin, T.monoPaddingV + NoteTextStyle.baselineShift(T.mono), accuracy: 0.01)
        view.sizeToFit()
        XCTAssertGreaterThanOrEqual(view.frame.height + 0.5, block.layoutFragmentFrame.maxY, "the padding is never cut off")

        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .mono)
        view.insertNewline(nil)
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .body)
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        let exits = try XCTUnwrap(monoFragments(engine).last)
        XCTAssertEqual(exits.decoration, .mono(starts: true, ends: true, exitsAtEnd: true))
        XCTAssertEqual(exits.bottomMargin, 0)
        let rect = try XCTUnwrap(exits.monoBlockRect)
        var extra: NSTextLineFragment?
        engine.layoutManager?.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location,
                                                           options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            if fragment === exits { extra = fragment.textLineFragments.last }
            return true
        }
        let emptyLine = try XCTUnwrap(extra)
        XCTAssertEqual(emptyLine.characterRange.length, 0)
        XCTAssertEqual(emptyLine.typographicBounds.minY - NoteTextStyle.lineLeading(T.body) - rect.maxY, NoteTextStyle.spacingBefore(.body, after: .mono), accuracy: 0.01,
                       "the empty line sits below the block as a paragraph after it would")
    }

    func testSelectionAcrossTheBlockIsItsTextAndCopyCopiesTheBlock() throws {
        let (engine, view) = makeEngine([.text("Title"), .text("Before"), styled("let a = 1", "mono"),
                                         styled("  let b = 2", "mono"), .text("After")])
        let block = try XCTUnwrap(engine.monoBlockRange(at: location(of: "let b", in: engine)))
        view.setSelectedRange(block)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "let a = 1\n  let b = 2")
        XCTAssertEqual(engine.formattingState(for: block).paragraph, .mono, "a selection inside the block reads as Mono")

        // The caret in the block shows Copy (keyboard, VoiceOver); out of it, not.
        spin()
        XCTAssertFalse(view.monoCopyButton.isHidden, "the caret is in the block")
        XCTAssertTrue(view.accessibilityChildren()?.contains { ($0 as AnyObject) === view.monoCopyButton } ?? false,
                      "VoiceOver reaches Copy")
        view.setSelectedRange(NSRange(location: location(of: "Before", in: engine), length: 0))
        spin()
        XCTAssertTrue(view.monoCopyButton.isHidden, "the caret left the block")
        XCTAssertFalse(view.accessibilityChildren()?.contains { ($0 as AnyObject) === view.monoCopyButton } ?? true)

        // The pointer: Copy shows only over the block, tucked into its corner.
        let rect = try XCTUnwrap(engine.monoBlockRect(for: block))
        let origin = view.textContainerOrigin
        view.updateMonoCopy(at: NSPoint(x: origin.x + 4, y: origin.y + 4))
        XCTAssertTrue(view.monoCopyButton.isHidden, "not over the title")
        view.updateMonoCopy(at: NSPoint(x: origin.x + rect.midX, y: origin.y + rect.midY))
        XCTAssertFalse(view.monoCopyButton.isHidden)
        let button = view.monoCopyButton.frame
        XCTAssertEqual(button.size, CGSize(width: 16, height: 16))
        XCTAssertEqual(button.maxX, origin.x + rect.maxX - T.monoCopyInset, accuracy: 0.01)
        XCTAssertEqual(button.minY, origin.y + rect.minY + T.monoCopyTop, accuracy: 0.01)
        // Inside the block (D-12): the chip never crosses its outline.
        XCTAssertTrue(rect.offsetBy(dx: origin.x, dy: origin.y).contains(button), "the chip sits inside the block")
        XCTAssertEqual(NoteMonoCopyButton.radius, T.monoCopySize / 3, accuracy: 0.001)
        // The pointer reaching the chip keeps it.
        view.updateMonoCopy(at: NSPoint(x: button.midX, y: button.minY + 1))
        XCTAssertFalse(view.monoCopyButton.isHidden, "the chip is still the block's Copy under the pointer")
        // An icon in a chip of the block's own fill, opaque; the text never moves.
        XCTAssertEqual(view.monoCopyButton.symbolName, "doc.on.doc")
        XCTAssertEqual(view.monoCopyButton.fill.alphaComponent, 1, accuracy: 0.001)
        let fragmentsBefore = monoFragments(engine).map(\.layoutFragmentFrame)
        XCTAssertEqual(monoFragments(engine).map(\.layoutFragmentFrame), fragmentsBefore)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotesV2TypographyTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.copyPasteboard = pasteboard
        XCTAssertTrue(view.monoCopyButton.accessibilityPerformPress())
        XCTAssertEqual(pasteboard.string(forType: .string), "let a = 1\n  let b = 2")
        XCTAssertEqual(view.monoCopyButton.symbolName, "checkmark", "a tick for a moment")
        view.updateMonoCopy(at: nil)
        XCTAssertTrue(view.monoCopyButton.isHidden)

        // A block that ends the note (the owner's citation) shows it too.
        let (endEngine, endView) = makeEngine(cia)
        let endBlock = try XCTUnwrap(endEngine.monoBlockRange(at: endEngine.textStorage.length - 1))
        let endRect = try XCTUnwrap(endEngine.monoBlockRect(for: endBlock))
        XCTAssertEqual(endRect.width, 264, accuracy: 0.01)
        XCTAssertGreaterThan(endRect.height, 6 * T.mono.lineHeight)
        endView.updateMonoCopy(at: NSPoint(x: endView.textContainerOrigin.x + endRect.midX, y: endView.textContainerOrigin.y + endRect.maxY - 2))
        XCTAssertFalse(endView.monoCopyButton.isHidden, "over the block's bottom padding")
    }

    func testCodeIsNeverSpellChecked() throws {
        var inline = NoteBlock.text("prose inlinecodetypo prose")
        inline.marks = [NoteMark(.code, offset: 6, length: 14)]
        let (engine, view) = makeEngine([.text("Title"), styled("codetypo", "mono"), inline])
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        let string = engine.textStorage.string as NSString
        let code = string.range(of: "codetypo"), prose = string.range(of: "prose"), inlineCode = string.range(of: "inlinecodetypo")
        let results = [code, prose, inlineCode].map { NSTextCheckingResult.spellCheckingResult(range: $0) }
        func checked() -> [NSRange] {
            engine.textView(view, didCheckTextIn: NSRange(location: 0, length: string.length),
                            types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:], results: results,
                            orthography: NSOrthography.defaultOrthography(forLanguage: "en"), wordCount: 3).map(\.range)
        }
        XCTAssertEqual(checked(), [prose])
        XCTAssertTrue(engine.containsCode(in: code))
        XCTAssertFalse(engine.containsCode(in: prose))
        view.setSelectedRange(code)
        XCTAssertTrue(engine.perform(.paragraph(.body), selection: code))
        XCTAssertEqual(checked(), [code, prose], "prose again once it is no longer code")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(checked(), [prose])
    }

    // MARK: Lists and the quote

    func testListsStartTheirTextAt22WithDrawnMarkers() throws {
        let long = "An item long enough to wrap onto a second line in the panel's column"
        let (engine, _) = makeEngine([.text("Title"), styled(long, "bullet"), styled("Nested", "bullet", indent: 1),
                                      styled("One", "number"), styled("Two", "number"), .text("Body")])
        let frags = fragments(engine)
        // The editor shows list paragraphs without TextKit's own marker.
        for fragment in frags {
            let text = (fragment.textElement as? NSTextParagraph)?.attributedString.string ?? ""
            XCTAssertFalse(text.hasPrefix("\t"), "no TextKit list marker: \(text.debugDescription)")
        }
        // Storage keeps the lists (rich-text copy and print).
        let stored = try paragraphStyle("One", engine)
        XCTAssertEqual(stored.textLists.first?.markerFormat, .decimal)

        let bullet = try XCTUnwrap(frags[1] as? NoteBlockLayoutFragment)
        XCTAssertEqual(bullet.decoration, .marker(.disc, x: 0))
        let lines = bullet.textLineFragments
        XCTAssertGreaterThan(lines.count, 1)
        func textX(_ line: NSTextLineFragment) -> CGFloat {
            line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.location).x
        }
        // A common indent moves the fragment; a hanging one moves the lines.
        for line in lines {
            XCTAssertEqual(bullet.layoutFragmentFrame.minX + textX(line), T.listTextInset, accuracy: 0.01, "text and wraps at 22")
        }
        let nested = try XCTUnwrap(frags[2] as? NoteBlockLayoutFragment)
        XCTAssertEqual(nested.decoration, .marker(.ring, x: T.listLevelStep))
        XCTAssertEqual(nested.layoutFragmentFrame.minX + textX(try XCTUnwrap(nested.textLineFragments.first)),
                       T.listLevelStep + T.listTextInset, accuracy: 0.01)
        XCTAssertEqual((frags[3] as? NoteBlockLayoutFragment)?.decoration, .marker(.number("1."), x: 0))
        XCTAssertEqual((frags[4] as? NoteBlockLayoutFragment)?.decoration, .marker(.number("2."), x: 0))
        XCTAssertFalse(frags[5] is NoteBlockLayoutFragment, "body text draws nothing beside it")
        XCTAssertEqual(try paragraphStyle("Two", engine).paragraphSpacingBefore,
                       NoteTextStyle.spacingBefore(.listItem, after: .listItem), accuracy: 0.001, "3 between items")
    }

    func testChecklistTextAndWrapsAt22() throws {
        let long = "A checklist line long enough to wrap onto a second line in the column"
        let (engine, _) = makeEngine([.text("Title"), .checklist(long)])
        let fragment = try XCTUnwrap(fragments(engine).last)
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines[0].typographicBounds.minX + lines[0].locationForCharacter(at: 1).x, T.listTextInset, accuracy: 0.5)
        for line in lines.dropFirst() { XCTAssertEqual(line.typographicBounds.minX, T.listTextInset, accuracy: 0.01) }
    }

    func testQuoteIsBodySizeWithA3PointBarJoiningItsLines() throws {
        let (engine, _) = makeEngine([.text("Title"), styled("First thought", "quote"), styled("Second thought", "quote"),
                                      .text("Body")])
        let frags = fragments(engine)
        XCTAssertEqual((engine.textStorage.attribute(.font, at: location(of: "First", in: engine), effectiveRange: nil) as? NSFont)?.pointSize, 12.5)
        let first = try XCTUnwrap(frags[1] as? NoteBlockLayoutFragment)
        let second = try XCTUnwrap(frags[2] as? NoteBlockLayoutFragment)
        XCTAssertEqual(first.decoration, .quote(x: 0, joinsAbove: false, joinsBelow: true))
        XCTAssertEqual(second.decoration, .quote(x: 0, joinsAbove: true, joinsBelow: false))
        let line = try XCTUnwrap(first.textLineFragments.first)
        XCTAssertEqual(first.layoutFragmentFrame.minX + line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.location).x,
                       T.quoteTextInset, accuracy: 0.01)
        XCTAssertEqual(try paragraphStyle("First", engine).paragraphSpacingBefore,
                       NoteTextStyle.spacingBefore(.quote, after: .title), accuracy: 0.001)
        XCTAssertEqual(try paragraphStyle("Second", engine).paragraphSpacingBefore,
                       NoteTextStyle.spacingBefore(.quote, after: .quote), accuracy: 0.001)
    }

    // MARK: R14 · the visible redesign

    func testR14LinksAreDottedAndInlineCodeIsAKernedChip() throws {
        let style = NoteTextStyle()
        let link = style.markedAttributes(marks: [.link: "https://example.com"], baseFont: style.bodyFont)
        XCTAssertEqual(link[.underlineStyle] as? Int, NSUnderlineStyle([.single, .patternDot]).rawValue, "Codex's dotted underline")
        XCTAssertEqual(link[.underlineColor] as? NSColor, style.linkUnderlineColor)
        let underlined = style.markedAttributes(marks: [.link: "https://example.com", .underline: true], baseFont: style.bodyFont)
        XCTAssertEqual(underlined[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue, "a chosen underline stays solid")
        let code = style.markedAttributes(marks: [.code: true], baseFont: style.headingFont)
        XCTAssertEqual((code[.font] as? NSFont)?.pointSize, T.inlineCodeSize, "11 pt in its chip at any run size")
        XCTAssertTrue((code[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertNil(code[.backgroundColor], "the chip is drawn, never a flat run")

        var marked = NoteBlock.text("Say launch now")
        marked.marks = [NoteMark(.code, offset: 4, length: 6)]
        let (engine, _) = makeEngine([.text("Title"), marked])
        let start = location(of: "launch", in: engine)
        func kern(_ at: Int) -> CGFloat? { engine.textStorage.attribute(.kern, at: at, effectiveRange: nil) as? CGFloat }
        XCTAssertEqual(kern(start - 1), T.inlineCodeChipPadding, "room before the chip")
        XCTAssertEqual(kern(start + 5), T.inlineCodeChipPadding, "room after it")
        XCTAssertNil(kern(start + 2))
        let fragment = try XCTUnwrap(fragments(engine).last as? NoteBlockLayoutFragment)
        XCTAssertEqual(fragment.decoration, .plain)
        XCTAssertNotNil(fragment.chipFill)
        // O18-03: the line's box is the body font's natural one (the caret's
        // height); the chip's 11 pt mono never changes it or the pitch.
        XCTAssertEqual(fragment.textLineFragments.first?.typographicBounds.height ?? 0,
                       T.body.lineHeight - NoteTextStyle.lineLeading(T.body), accuracy: 0.01,
                       "the chip never changes the line's height")
    }

    func testR14ReduceTransparencySeamIsOffUnlessALaunchAsksForIt() {
        XCTAssertFalse(AtticTransparencySeam.forced, "a normal launch follows the Mac")
        XCTAssertTrue(AtticTransparencySeam.resolve(true))
        XCTAssertFalse(AtticTransparencySeam.resolve(false))
    }

    func testR14AnInlineChipMovesToTheNextLineWhole() throws {
        let text = "both. Strikethrough text marks a superseded idea. Inline code such as launch_status = \"ready\" distinguishes code from prose."
        var block = NoteBlock.text(text)
        let code = (text as NSString).range(of: "launch_status = \"ready\"")
        block.marks = [NoteMark(.code, offset: code.location, length: code.length)]
        let (engine, _) = makeEngine([.text("Title"), block])
        let fragment = try XCTUnwrap(fragments(engine).last as? NoteBlockLayoutFragment)
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        let holding = lines.filter { NSIntersectionRange($0.characterRange, code).length > 0 }
        XCTAssertEqual(holding.count, 1, "the chip is never split at its spaces")
        XCTAssertEqual(engine.textStorage.string, "Title\n" + text, "the stored text keeps its spaces")
    }

    func testR14MarkersGoDiscRingSquareAndNumbersLetterThenRoman() throws {
        let (engine, _) = makeEngine([.text("Title"), styled("One", "bullet"), styled("Two", "bullet", indent: 1),
                                      styled("Three", "bullet", indent: 2), .text("Gap"),
                                      styled("First", "number"), styled("Sub", "number", indent: 1), styled("Sub two", "number", indent: 1),
                                      styled("Deep", "number", indent: 2)])
        let decorations = fragments(engine).compactMap { ($0 as? NoteBlockLayoutFragment)?.decoration }
        XCTAssertEqual(decorations, [.marker(.disc, x: 0), .marker(.ring, x: 20), .marker(.square, x: 40),
                                     .marker(.number("1."), x: 0), .marker(.letter("a."), x: 20), .marker(.letter("b."), x: 20),
                                     .marker(.roman("i."), x: 40)])
        let number = try XCTUnwrap(fragments(engine)[5] as? NoteBlockLayoutFragment)
        XCTAssertEqual(number.ink, NoteTextStyle().bodyColor, "numbers in the body ink")
        XCTAssertTrue(number.markerFont.fontDescriptor.fontAttributes.description.contains("FeatureSettings")
                      || number.markerFont == NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular), "tabular figures")
    }

    func testR14CalloutIsOneBoxPerIconWithItsTextAt36() throws {
        var idea = styled("Idea: test a shorter onboarding flow", "quote"); idea.callout = "💡"
        var more = styled("Start with a clear welcome", "quote"); more.callout = "💡"
        var warning = styled("Demo warning", "quote"); warning.callout = "⚠️"
        var plain = styled("A callout without an icon", "quote"); plain.callout = ""
        let (engine, _) = makeEngine([.text("Title"), idea, more, warning, plain, .text("After")])
        let frags = fragments(engine).compactMap { $0 as? NoteBlockLayoutFragment }
        XCTAssertEqual(frags.map(\.decoration), [.callout(icon: "💡", starts: true, ends: false), .callout(icon: "💡", starts: false, ends: true),
                                                .callout(icon: "⚠️", starts: true, ends: true), .callout(icon: "", starts: true, ends: true)])
        func textX(_ fragment: NoteBlockLayoutFragment) throws -> CGFloat {
            let line = try XCTUnwrap(fragment.textLineFragments.first)
            return fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + line.locationForCharacter(at: line.characterRange.location).x
        }
        XCTAssertEqual(try textX(frags[0]), T.calloutTextInset, accuracy: 0.01)
        XCTAssertEqual(try textX(frags[1]), T.calloutTextInset, accuracy: 0.01)
        XCTAssertEqual(try textX(frags[3]), T.calloutPaddingH, accuracy: 0.01, "plain: text at 12")
        let icon = try XCTUnwrap(frags[0].calloutIconRect).offsetBy(dx: frags[0].layoutFragmentFrame.minX, dy: 0)
        XCTAssertEqual([icon.minX, icon.width], [T.calloutPaddingH, T.calloutIconSlot])
        XCTAssertNil(frags[1].calloutIconRect, "one icon per box")
        // One box: its slices meet; the next box starts 12 below.
        func box(_ fragment: NoteBlockLayoutFragment) throws -> CGRect {
            try XCTUnwrap(fragment.calloutBoxRect).offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
        }
        XCTAssertEqual(try box(frags[0]).maxY, try box(frags[1]).minY, accuracy: 0.01)
        XCTAssertEqual(try box(frags[2]).minY - box(frags[1]).maxY, T.blockMargin, accuracy: 0.01)
        XCTAssertEqual(try box(frags[0]).width, 264, accuracy: 0.01, "the column's width")
        // Optical padding: first line box 8 under the box top, last 8 above its bottom.
        let first = try XCTUnwrap(frags[2].textLineFragments.first)
        let top = frags[2].layoutFragmentFrame.minY + first.typographicBounds.minY
        XCTAssertEqual(top - NoteTextStyle.lineLeading(T.body) + NoteTextStyle.baselineShift(T.body) - (try box(frags[2]).minY), T.calloutPaddingV, accuracy: 0.01)
        let bottom = frags[2].layoutFragmentFrame.minY + first.typographicBounds.maxY + NoteTextStyle.baselineShift(T.body)
        XCTAssertEqual((try box(frags[2]).maxY) - bottom, T.calloutPaddingV, accuracy: 0.01)
    }

    func testR14CodeBlockHasALabelRowAndItsCopyChipSitsInIt() throws {
        var code = styled("const a = 1", "mono"); code.language = "javascript"
        var continuation = styled("a()", "mono"); continuation.language = "javascript"
        let (engine, view) = makeEngine([.text("Title"), code, continuation, .text("After")])
        let blocks = monoFragments(engine)
        XCTAssertEqual(blocks.first?.codeLabel, "JavaScript")
        XCTAssertNil(blocks.last?.codeLabel)
        let label = try XCTUnwrap(blocks.first?.codeLabelRect)
        let rect = try XCTUnwrap(blocks.first?.monoBlockRect)
        XCTAssertEqual(label.minX - rect.minX, T.monoPaddingH, accuracy: 0.01)
        XCTAssertEqual(label.minY - rect.minY, T.monoPaddingV, accuracy: 0.01)
        XCTAssertEqual(label.height, T.monoLabelHeight)
        XCTAssertEqual(NoteCodeLanguageName.label(for: nil), "Plain text")
        XCTAssertEqual(NoteCodeLanguageName.menu.count, 13)
        // Copy: in the label row, never over the first code line.
        view.updateMonoCopy(at: NSPoint(x: 100, y: (engine.monoBlockRect(for: try XCTUnwrap(engine.monoBlockRange(at: location(of: "const", in: engine)))) ?? .zero).midY + view.textContainerOrigin.y))
        let chip = view.monoCopyButton.frame.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        let firstLine = try XCTUnwrap(blocks.first?.textLineFragments.first)
        let firstLineTop = try XCTUnwrap(blocks.first).layoutFragmentFrame.minY + firstLine.typographicBounds.minY
        XCTAssertFalse(view.monoCopyButton.isHidden)
        XCTAssertLessThanOrEqual(chip.maxY, firstLineTop + 0.5, "the chip sits above the code")
        let blockTop = rect.minY + (try XCTUnwrap(blocks.first)).layoutFragmentFrame.minY
        XCTAssertEqual(chip.midY - blockTop, T.monoPaddingV + T.monoLabelHeight / 2, accuracy: 0.01)
    }

    func testR14HardBreaksLayOutAsLinesOfOneParagraph() throws {
        let (engine, view) = makeEngine([.text("Title"), .text("")])
        let end = (engine.textStorage.string as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        XCTAssertTrue(engine.pasteMarkdown("An address:\\\nNorthstar Studio\\\n24 Example Lane\\\nLondon\n", at: view.selectedRange()))
        let start = location(of: "An address", in: engine)
        let line = engine.lineRange(at: start)
        let text = (engine.textStorage.string as NSString).substring(with: line)
        XCTAssertEqual(text, "An address:\u{2028}Northstar Studio\u{2028}24 Example Lane\u{2028}London")
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        let fragment = try XCTUnwrap(fragments(engine).first { ($0.textElement as? NSTextParagraph)?.attributedString.string.hasPrefix("An address") == true })
        XCTAssertEqual(fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count, 4, "one line each")
    }

    #if DEBUG
    func testR14TheCodexTestPagePastesEveryBlock() throws {
        let (engine, view) = makeEngine([.text("Formatting test page"), .text("")], height: 4000)
        view.setSelectedRange(NSRange(location: (engine.textStorage.string as NSString).length, length: 0))
        XCTAssertTrue(engine.pasteMarkdown(NoteFormatCaptureScene.codexTestPage, at: view.selectedRange()))
        let start = location(of: "An intentional", in: engine)
        let text = (engine.textStorage.string as NSString).substring(with: engine.lineRange(at: start))
        XCTAssertEqual(text.components(separatedBy: "\u{2028}").count, 4, text.debugDescription)
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        let fragment = try XCTUnwrap(fragments(engine).first { ($0.textElement as? NSTextParagraph)?.attributedString.string.hasPrefix("An intentional") == true })
        XCTAssertEqual(fragment.textLineFragments.filter { $0.characterRange.length > 0 }.count, 4, "one line each")
        let kinds = Set(fragments(engine).compactMap { ($0 as? NoteBlockLayoutFragment)?.decoration }.map { decoration -> String in
            switch decoration {
            case .mono: "code"
            case .callout: "callout"
            case .quote: "quote"
            case .marker: "marker"
            case .plain: "chips"
            case .history: "history"
            }
        })
        XCTAssertEqual(kinds, ["code", "callout", "quote", "marker", "chips"])
    }
    #endif

    func testR14TheBlockHandleSitsOnTheGripLineBesideTheBlocksFirstLine() throws {
        var tip = styled("Demo warning: a long callout line that wraps onto a second line here", "quote"); tip.callout = "⚠️"
        let (engine, view) = makeEngine([.text("Title"), .text("Body"), tip, styled("One", "bullet"), styled("Child", "bullet", indent: 1)])
        let start = location(of: "Demo", in: engine)
        // The pointer over the block's lines, or the margin beside them.
        let frame = try XCTUnwrap(fragments(engine).first { ($0.textElement as? NSTextParagraph)?.attributedString.string.hasPrefix("Demo") == true })
            .layoutFragmentFrame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        XCTAssertEqual(view.blockLocation(at: NSPoint(x: 10, y: frame.midY)), start)
        XCTAssertEqual(view.blockLocation(at: NSPoint(x: 120, y: frame.midY)), start)
        XCTAssertNil(view.blockLocation(at: NSPoint(x: 120, y: view.textContainerOrigin.y + 5)), "never the title")
        view.updateBlockHandle(at: NSPoint(x: 10, y: frame.midY))
        XCTAssertFalse(view.blockHandle.isHidden)
        XCTAssertEqual(view.blockHandle.frame.midX, view.textContainerOrigin.x - T.handleFromColumn, accuracy: 0.01, "the grips' line")
        XCTAssertEqual(view.blockHandle.frame.size, T.handleHitSize)
        XCTAssertEqual(view.handleBlockLocation, start)
        // A list item's handle moves the item with its children.
        let one = location(of: "One", in: engine)
        XCTAssertEqual(engine.blockRange(at: one), NSRange(location: one, length: (engine.textStorage.string as NSString).length - one))
        view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)))
        XCTAssertTrue(view.blockHandle.isHidden, "typing hides it")
    }

    // MARK: Persistence is untouched

    func testStylesRoundTripWithoutLayoutChangingTheDocument() throws {
        let blocks = cia + [styled("Item", "bullet"), styled("Step", "number"), styled("Said", "quote")]
        let (engine, _) = makeEngine(blocks)
        XCTAssertEqual(engine.document().blocks, blocks)
        let reopened = NoteEditorEngine(noteID: engine.noteID, document: engine.document())
        for text in ["Colonial", "The attackers", "Integrity", "@inproceedings", "  title", "Said"] {
            let a = try paragraphStyle(text, engine)
            let at = (reopened.textStorage.string as NSString).range(of: text).location
            let b = try XCTUnwrap(reopened.textStorage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(a.paragraphSpacingBefore, b.paragraphSpacingBefore, accuracy: 0.001, "\(text): the same on reopening")
            XCTAssertEqual(a.headIndent, b.headIndent, accuracy: 0.001, text)
            XCTAssertEqual(a.minimumLineHeight, b.minimumLineHeight, text)
        }
    }
}
