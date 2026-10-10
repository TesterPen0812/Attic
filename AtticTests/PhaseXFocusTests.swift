import AppKit
import XCTest
@testable import Attic

/// Owner round 1 (2026-10-10): F-02 grey rounded quote bars and F-04 the quote
/// bar against its text (F-01 is in `PhaseXColourTokenTests`, F-03 in
/// `PhaseXCaretTests`). Windows are never shown; geometry is read from
/// TextKit and drawing from an offscreen bitmap.
@MainActor
final class PhaseXFocusTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func heading(_ text: String, level: Int) -> NoteBlock {
        var block = NoteBlock.text(text, style: "heading")
        block.level = level
        return block
    }

    private func makeEditor(_ blocks: [NoteBlock], width: CGFloat = 400,
                            design: AtticDesignContext = .default) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks), design: design)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = scrollView
        windows.append(host)
        host.makeFirstResponder(textView)
        textView.layoutSubtreeIfNeeded()
        return (engine, textView)
    }

    private func fragments(_ textView: NoteEditorTextView) -> [NoteBlockLayoutFragment] {
        guard let layout = textView.textLayoutManager else { return [] }
        var found: [NoteBlockLayoutFragment] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let block = fragment as? NoteBlockLayoutFragment { found.append(block) }
            return true
        }
        return found
    }

    // MARK: F-04, F-02 the quote bar

    private func quoteSlices(_ textView: NoteEditorTextView) -> [NoteBlockLayoutFragment] {
        fragments(textView).filter { if case .quote = $0.decoration { return true } else { return false } }
    }

    private func baseline(_ line: NSTextLineFragment) -> CGFloat { line.typographicBounds.minY + line.glyphOrigin.y }

    /// The bar spans exactly its text: first line's ascender to the last
    /// line's descender, centred on the glyphs, not longer; a quote of
    /// several paragraphs or wrapped lines is one bar without a gap.
    func testQuoteBarSpansItsTextLinesAndNoMore() throws {
        let long = String(repeating: "A quote that wraps across lines. ", count: 6)
        let (_, textView) = makeEditor([.text("Title"), .text("Before"),
                                       .text("Short", style: "quote"),
                                       .text("Between"),
                                       .text(long, style: "quote"), .text("Second paragraph of the same quote", style: "quote"),
                                       .text("After")], width: 260)
        let slices = quoteSlices(textView)
        XCTAssertEqual(slices.count, 3)
        let font = NoteTextStyle(design: AtticDesignContext(mode: .light)).quoteFont

        // A one-line quote.
        let single = try XCTUnwrap(slices.first)
        let bar = try XCTUnwrap(single.quoteBar)
        let line = try XCTUnwrap(single.textLineFragments.first)
        XCTAssertEqual(bar.minY, baseline(line) - font.ascender, accuracy: 0.01)
        XCTAssertEqual(bar.maxY, baseline(line) - font.descender, accuracy: 0.01)
        XCTAssertEqual(bar.height, font.ascender - font.descender, accuracy: 0.01)
        XCTAssertLessThan(bar.height, line.typographicBounds.height, "shorter than the line's box")
        XCTAssertEqual(bar.midY, baseline(line) - (font.ascender + font.descender) / 2, accuracy: 0.01, "centred on the glyphs")
        XCTAssertEqual(bar.width, AtticNoteType.quoteBar)

        // A wrapped quote of two paragraphs: one bar, first ascender to last descender.
        let top = try XCTUnwrap(slices[1]), bottom = try XCTUnwrap(slices[2])
        XCTAssertGreaterThan(top.textLineFragments.count, 2, "the quote wraps")
        let topBar = try XCTUnwrap(top.quoteBar), bottomBar = try XCTUnwrap(bottom.quoteBar)
        let firstLine = try XCTUnwrap(top.textLineFragments.first)
        let lastLine = try XCTUnwrap(bottom.textLineFragments.last)
        XCTAssertEqual(top.layoutFragmentFrame.minY + topBar.minY,
                       top.layoutFragmentFrame.minY + baseline(firstLine) - font.ascender, accuracy: 0.01)
        XCTAssertEqual(bottom.layoutFragmentFrame.minY + bottomBar.maxY,
                       bottom.layoutFragmentFrame.minY + baseline(lastLine) - font.descender, accuracy: 0.01)
        XCTAssertEqual(topBar.maxY + top.layoutFragmentFrame.minY, bottomBar.minY + bottom.layoutFragmentFrame.minY, accuracy: 0.01,
                       "the two slices meet without a gap")
        let spanned = (bottom.layoutFragmentFrame.minY + bottomBar.maxY) - (top.layoutFragmentFrame.minY + topBar.minY)
        let textSpan = (bottom.layoutFragmentFrame.minY + baseline(lastLine) - font.descender)
            - (top.layoutFragmentFrame.minY + baseline(firstLine) - font.ascender)
        XCTAssertEqual(spanned, textSpan, accuracy: 0.01, "not longer than the text")
    }

    private func render(_ fragment: NoteBlockLayoutFragment, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let size = CGSize(width: 40, height: ceil(fragment.layoutFragmentFrame.height) + 8)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)?.cgContext)
        context.scaleBy(x: scale, y: scale)
        // TextKit draws top-down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        // Room to the left of the column for the bar, whose x is the quote's depth.
        fragment.draw(at: CGPoint(x: fragment.layoutFragmentFrame.minX + 4, y: 4), in: context)
        return rep
    }

    /// F-02: the bar is the quiet grey (not the primary ink) with rounded
    /// ends: its corner pixels are clear, its middle is solid.
    func testQuoteBarIsGreyWithRoundedEnds() throws {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            let design = AtticDesignContext(mode: mode)
            let (_, textView) = makeEditor([.text("Title"), .text("A quote", style: "quote")], design: design)
            let slice = try XCTUnwrap(quoteSlices(textView).first)
            let style = NoteTextStyle(design: design)
            XCTAssertEqual(slice.ink, style.quoteBarColor)
            XCTAssertNotEqual(slice.ink, style.bodyColor)
            let tokens = design.tokens
            XCTAssertEqual(tokens.quoteBar.red, tokens.ink(.muted).red, accuracy: 0.001, "the quiet ink")
            XCTAssertLessThan(tokens.quoteBar.alpha, 0.5)

            let rep = try render(slice)
            let bar = try XCTUnwrap(slice.quoteBar)
            let scale: CGFloat = 2
            let originX = slice.layoutFragmentFrame.minX + 4
            let x = Int((originX + bar.midX) * scale)
            let topRow = Int((4 + bar.minY) * scale), bottomRow = Int((4 + bar.maxY) * scale) - 1
            let middleRow = Int((4 + bar.midY) * scale)
            func alpha(_ column: Int, _ row: Int) -> CGFloat { rep.colorAt(x: column, y: row)?.alphaComponent ?? -1 }
            let leftEdge = Int((originX + bar.minX) * scale), rightEdge = Int((originX + bar.maxX) * scale) - 1
            let expected = tokens.quoteBar.alpha
            XCTAssertEqual(alpha(x, middleRow), expected, accuracy: 0.03, "\(mode) the bar's middle is the grey wash")
            // The caps are round: the very corners of the end rows are clear, the middle of the end row is filled.
            XCTAssertLessThan(alpha(leftEdge, topRow), expected * 0.5, "\(mode) top-left corner is rounded")
            XCTAssertLessThan(alpha(rightEdge, topRow), expected * 0.5, "\(mode) top-right corner is rounded")
            XCTAssertLessThan(alpha(leftEdge, bottomRow), expected * 0.5, "\(mode) bottom-left corner is rounded")
            XCTAssertLessThan(alpha(rightEdge, bottomRow), expected * 0.5, "\(mode) bottom-right corner is rounded")
            XCTAssertGreaterThan(alpha(x, topRow + 1), expected * 0.5, "\(mode) the cap is filled in the middle")
            let colour = try XCTUnwrap(rep.colorAt(x: x, y: middleRow)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(colour.redComponent, 0.7, "the bar is a grey, not clear")
            XCTAssertEqual(colour.redComponent, colour.greenComponent, accuracy: 0.05, "neutral")
        }
    }

    /// The seam between a quote's slices is square: no cap in the middle of
    /// a quote of two paragraphs.
    func testJoinedQuoteSlicesHaveASquareSeam() throws {
        let (_, textView) = makeEditor([.text("Title"), .text("One", style: "quote"), .text("Two", style: "quote")])
        let slices = quoteSlices(textView)
        XCTAssertEqual(slices.count, 2)
        guard case let .quote(_, aboveFirst, belowFirst) = slices[0].decoration,
              case let .quote(_, aboveSecond, belowSecond) = slices[1].decoration else { return XCTFail("quote slices") }
        XCTAssertEqual([aboveFirst, belowFirst, aboveSecond, belowSecond], [false, true, true, false])
        let rep = try render(slices[0])
        let bar = try XCTUnwrap(slices[0].quoteBar)
        let originX = slices[0].layoutFragmentFrame.minX + 4
        let x = Int((originX + bar.midX) * 2)
        let last = Int((4 + bar.maxY) * 2) - 1
        let expected = AtticDesignContext(mode: .light).tokens.quoteBar.alpha
        let cornerX = Int((originX + bar.minX) * 2)
        XCTAssertEqual(rep.colorAt(x: cornerX, y: last)?.alphaComponent ?? 0, expected, accuracy: 0.05, "the seam's corner is filled")
        XCTAssertEqual(rep.colorAt(x: x, y: last)?.alphaComponent ?? 0, expected, accuracy: 0.05)
    }
}
