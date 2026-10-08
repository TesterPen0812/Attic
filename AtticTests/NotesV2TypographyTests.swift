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

    // MARK: Tokens

    func testTypeScaleIsTheDraftsDirection5() {
        XCTAssertEqual(T.title, T.Role(size: 22, lineHeight: 27, weight: 700))
        XCTAssertEqual(T.titleStyle, T.Role(size: 18, lineHeight: 24, weight: 650))
        XCTAssertEqual(T.heading, T.Role(size: 16.5, lineHeight: 22, weight: 650))
        XCTAssertEqual(T.subheading, T.Role(size: 15, lineHeight: 21, weight: 650))
        XCTAssertEqual(T.body, T.Role(size: 14, lineHeight: 21, weight: 400))
        XCTAssertEqual(T.quote, T.Role(size: 15, lineHeight: 22, weight: 400))
        XCTAssertEqual(T.mono, T.Role(size: 12, lineHeight: 18, weight: 400, monospaced: true))
        XCTAssertEqual([T.paragraphGap, T.titleToText], [3, 12])
        XCTAssertEqual([T.aboveTitleStyle, T.aboveHeading, T.aboveSubheading], [16, 14, 12])
        XCTAssertEqual([T.belowTitleStyle, T.belowHeading, T.belowSubheading], [2, 1, 1])
        XCTAssertEqual([T.monoPaddingV, T.monoPaddingH, T.monoRadius], [12, 14, 10])
        XCTAssertEqual([T.listTextInset, T.bulletDot, T.quoteBar, T.quoteTextInset], [22, 5, 3, 14])

        let style = NoteTextStyle()
        XCTAssertEqual(style.titleFont.pointSize, 22)
        XCTAssertTrue(style.titleFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(style.titleStyleFont.pointSize, 18)
        XCTAssertEqual(style.headingFont.pointSize, 16.5)
        XCTAssertEqual(style.subheadingFont.pointSize, 15)
        XCTAssertEqual(style.bodyFont.pointSize, 14)
        XCTAssertEqual(style.quoteFont.pointSize, 15)
        XCTAssertEqual(style.monoFont.pointSize, 12)
        XCTAssertTrue(style.monoFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        // 650 sits between semibold and bold: wider than semibold, narrower than bold.
        let sample = "Colonial Pipeline ransomware" as NSString
        func width(_ font: NSFont) -> CGFloat { sample.size(withAttributes: [.font: font]).width }
        XCTAssertGreaterThan(width(style.titleStyleFont), width(.systemFont(ofSize: 18, weight: .semibold)))
        XCTAssertLessThan(width(style.titleStyleFont), width(.systemFont(ofSize: 18, weight: .bold)))
        // One near-black ink for the text and its headings.
        XCTAssertEqual(style.bodyColor, style.titleColor)
        XCTAssertEqual(style.quoteColor, style.bodyColor)
    }

    /// The space between line boxes, by the lower block's kind; a heading
    /// binds to what follows it.
    func testGapsAreTheDrafts() {
        typealias K = NoteParagraphKind
        let cases: [(K, K?, CGFloat)] = [
            (.body, nil, 0), (.titleStyle, .title, 12), (.body, .title, 12), (.mono, .title, 12),
            (.titleStyle, .body, 16), (.heading, .body, 14), (.subheading, .body, 12),
            (.subheading, .subheading, 12), (.heading, .mono, 14),
            (.body, .titleStyle, 2), (.body, .heading, 1), (.body, .subheading, 1),
            (.mono, .subheading, 4), (.mono, .titleStyle, 4),
            (.body, .body, 3), (.quote, .quote, 3), (.quote, .body, 3),
            (.mono, .body, 8), (.body, .mono, 8), (.mono, .mono, 0),
            (.blockObject, .body, 8), (.body, .blockObject, 8)
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
            if kind == .mono, !inMono { cssTop += T.monoPaddingV }
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
        XCTAssertEqual(firstLine.typographicBounds.minY + blocks[0].layoutFragmentFrame.minY - block.minY,
                       T.monoPaddingV - NoteTextStyle.baselineShift(T.mono), accuracy: 0.01)
        XCTAssertEqual(block.maxY - (lastFragment.layoutFragmentFrame.minY + lastLine.typographicBounds.maxY),
                       T.monoPaddingV + NoteTextStyle.baselineShift(T.mono), accuracy: 0.01)
        // 4 above the block after "Sources:" (a heading binds to it).
        let sources = fragments(engine)[8]
        XCTAssertEqual(block.minY - sources.layoutFragmentFrame.maxY,
                       NoteTextStyle.gap(above: .mono, after: .subheading) + NoteTextStyle.boxShift(.subheading), accuracy: 0.01)
    }

    /// The draft's first citation line: 31 characters fit the block's 236 pt,
    /// so "w," wraps alone, as drawn. Soft wraps hang from the line's own
    /// leading spaces.
    func testMonoWrapsLikeTheDraftAndHangsFromItsLeadingSpaces() throws {
        let (engine, _) = makeEngine(cia)
        let blocks = monoFragments(engine)
        let first = blocks[0].textLineFragments.filter { $0.characterRange.length > 0 }
        XCTAssertEqual(first.count, 2)
        let text = engine.textStorage.string as NSString
        let start = location(of: "@inproceedings", in: engine)
        XCTAssertEqual(text.substring(with: NSRange(location: start, length: first[0].characterRange.length)),
                       "@inproceedings{beerman2023revie")
        let indent = NoteTextStyle().monoHang(for: "  title")
        XCTAssertGreaterThan(indent, 14)
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
        XCTAssertEqual(emptyLine.typographicBounds.minY - rect.maxY, NoteTextStyle.spacingBefore(.body, after: .mono), accuracy: 0.01,
                       "the empty line sits below the block as a paragraph after it would")
    }

    func testSelectionAcrossTheBlockIsItsTextAndCopyCopiesTheBlock() throws {
        let (engine, view) = makeEngine([.text("Title"), .text("Before"), styled("let a = 1", "mono"),
                                         styled("  let b = 2", "mono"), .text("After")])
        let block = try XCTUnwrap(engine.monoBlockRange(at: location(of: "let b", in: engine)))
        view.setSelectedRange(block)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "let a = 1\n  let b = 2")
        XCTAssertEqual(engine.formattingState(for: block).paragraph, .mono, "a selection inside the block reads as Mono")

        // Copy shows only over the block, on its top-right corner.
        let rect = try XCTUnwrap(engine.monoBlockRect(for: block))
        let origin = view.textContainerOrigin
        view.updateMonoCopy(at: NSPoint(x: origin.x + 4, y: origin.y + 4))
        XCTAssertTrue(view.monoCopyButton.isHidden, "not over the title")
        view.updateMonoCopy(at: NSPoint(x: origin.x + rect.midX, y: origin.y + rect.midY))
        XCTAssertFalse(view.monoCopyButton.isHidden)
        let button = view.monoCopyButton.frame
        XCTAssertEqual(button.maxX, origin.x + rect.maxX - T.monoCopyInset, accuracy: 0.5)
        XCTAssertEqual(button.minY, origin.y + rect.minY + T.monoCopyInset, accuracy: 0.5)
        XCTAssertLessThanOrEqual(button.minY + button.height, origin.y + rect.minY + T.monoPaddingV + T.mono.lineHeight)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotesV2TypographyTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.copyPasteboard = pasteboard
        XCTAssertTrue(view.monoCopyButton.accessibilityPerformPress())
        XCTAssertEqual(pasteboard.string(forType: .string), "let a = 1\n  let b = 2")
        XCTAssertEqual(view.monoCopyButton.title, String(localized: "Copied"))
        view.updateMonoCopy(at: nil)
        XCTAssertTrue(view.monoCopyButton.isHidden)
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
        XCTAssertEqual(bullet.decoration, .bullet(x: T.bulletCentre))
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
        XCTAssertEqual(nested.decoration, .bullet(x: T.listLevelStep + T.bulletCentre))
        XCTAssertEqual(nested.layoutFragmentFrame.minX + textX(try XCTUnwrap(nested.textLineFragments.first)),
                       T.listLevelStep + T.listTextInset, accuracy: 0.01)
        XCTAssertEqual((frags[3] as? NoteBlockLayoutFragment)?.decoration, .number("1.", trailing: T.listTextInset - T.numberGap))
        XCTAssertEqual((frags[4] as? NoteBlockLayoutFragment)?.decoration, .number("2.", trailing: T.listTextInset - T.numberGap))
        XCTAssertFalse(frags[5] is NoteBlockLayoutFragment, "body text draws nothing beside it")
        XCTAssertEqual(try paragraphStyle("Two", engine).paragraphSpacingBefore,
                       NoteTextStyle.spacingBefore(.body, after: .body), accuracy: 0.001, "3 between items")
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

    func testQuoteIs15WithA3PointBarJoiningItsLines() throws {
        let (engine, _) = makeEngine([.text("Title"), styled("First thought", "quote"), styled("Second thought", "quote"),
                                      .text("Body")])
        let frags = fragments(engine)
        XCTAssertEqual((engine.textStorage.attribute(.font, at: location(of: "First", in: engine), effectiveRange: nil) as? NSFont)?.pointSize, 15)
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
