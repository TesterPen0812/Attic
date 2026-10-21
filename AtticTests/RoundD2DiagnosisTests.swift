import AppKit
import XCTest
@testable import Attic

/// Diagnosis only. No window is ever ordered, activated, or made key.
/// Reporting key status locally lets stock AppKit create its own real insertion
/// indicator; it does not change the window server's key window or user focus.
@MainActor
private final class D2UnshownWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
final class RoundD2DiagnosisTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try requireKeyWindowTests()
    }
    private var windows: [NSWindow] = []
    private var engines: [NoteEditorEngine] = []
    private var controls: [NoteFormatControls] = []
    private var records: [[String: Any]] = []

    override func tearDown() async throws {
        if !records.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            a.name = "\(name)-measurements.json"; a.lifetime = .keepAlways; add(a)
            print("D2_MEASUREMENTS", String(decoding: data, as: UTF8.self))
        }
        controls.removeAll()
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll(); engines.removeAll()
    }

    private func callout(_ text: String) -> NoteBlock {
        var b = NoteBlock.text(text, style: "quote"); b.callout = "💡"; return b
    }
    private func heading(_ level: Int) -> NoteBlock {
        var b = NoteBlock.text("Khkj py", style: "heading"); b.level = level; return b
    }
    private func host(_ scroll: NSScrollView, text: NSTextView, height: CGFloat) {
        scroll.frame = CGRect(x: 0, y: 0, width: 340, height: height)
        let window = D2UnshownWindow(contentRect: CGRect(x: -9000, y: -9000, width: 340, height: height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = scroll; windows.append(window)
        window.makeFirstResponder(text)
        XCTAssertFalse(window.isVisible)
    }
    private func editor(_ blocks: [NoteBlock], height: CGFloat = 70) -> (NoteEditorEngine, NoteEditorTextView) {
        let e = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks),
                                 design: AtticDesignContext(mode: .dark))
        engines.append(e)
        let (scroll, text) = e.makeView()
        text.textContainerInset = CGSize(width: 24, height: 0) // actual NoteEditorHost
        text.drawsBackground = true; text.backgroundColor = NSColor(srgbRed: 0.24, green: 0.24, blue: 0.24, alpha: 1)
        host(scroll, text: text, height: height)
        settle(text)
        return (e, text)
    }
    private func settle(_ text: NSTextView) {
        text.textLayoutManager?.ensureLayout(for: text.textLayoutManager!.documentRange)
        text.enclosingScrollView?.layoutSubtreeIfNeeded()
        text.layoutSubtreeIfNeeded()
        text.textLayoutManager?.textViewportLayoutController.layoutViewport()
        text.updateInsertionPointStateAndRestartTimer(true)
        text.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    private func indicators(_ text: NSTextView) -> [NSTextInsertionIndicator] { descendants(text).compactMap { $0 as? NSTextInsertionIndicator } }
    private func rect(_ r: CGRect) -> [String: Double] {
        ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height), "bottom": Double(r.maxY)]
    }
    private func fragment(_ e: NoteEditorEngine, at offset: Int) throws -> NoteBlockLayoutFragment {
        let range = try XCTUnwrap(e.textRange(for: NSRange(location: offset, length: 0)))
        return try XCTUnwrap(e.layoutManager?.textLayoutFragment(for: range.location) as? NoteBlockLayoutFragment)
    }
    private func render(_ view: NSView, _ name: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        a.name = name + ".png"; a.lifetime = .keepAlways; add(a)
    }
    private func recordBox(_ e: NoteEditorEngine, _ text: NoteEditorTextView, _ label: String) throws -> (CGRect, NoteBlockLayoutFragment) {
        let first = try fragment(e, at: e.titleParagraphRange.length + 1)
        var f = first
        e.layoutManager?.enumerateTextLayoutFragments(from: e.contentStorage.documentRange.location, options: [.ensuresLayout]) { candidate in
            if let box = candidate as? NoteBlockLayoutFragment, box.calloutBoxRect != nil { f = box }
            return true
        }
        let local = try XCTUnwrap(f.calloutBoxRect ?? f.lastLineBoxRect)
        let box = local.offsetBy(dx: f.layoutFragmentFrame.minX + text.textContainerOrigin.x,
                                 dy: f.layoutFragmentFrame.minY + text.textContainerOrigin.y)
        let lines = f.textLineFragments.map { ["rect": rect($0.typographicBounds), "baseline": $0.glyphOrigin.y + $0.typographicBounds.minY,
                                             "range": NSStringFromRange($0.characterRange)] as [String: Any] }
        records.append(["case": label, "document": rect(text.bounds), "visible": rect(text.visibleRect),
                        "container": rect(CGRect(origin: .zero, size: text.textContainer!.size)), "box": rect(box),
                        "fragment": rect(f.layoutFragmentFrame), "surface": rect(f.renderingSurfaceBounds),
                        "icon": f.calloutIconRect.map(rect) as Any? ?? NSNull(), "decoration": String(describing: f.decoration),
                        "lastLine": String(describing: f.lastLine), "topMargin": f.topMargin, "bottomMargin": f.bottomMargin,
                        "lines": lines, "paragraphSpacing": (e.textStorage.attribute(.paragraphStyle, at: e.contentStorage.offset(from: e.contentStorage.documentRange.location, to: f.rangeInElement.location), effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? -1, "caret": e.caretRect(at: e.textStorage.length).map(rect) as Any? ?? NSNull()])
        try render(text.enclosingScrollView!, label + "-viewport")
        try render(text, label + "-document")
        // A fragment-only render preserves the full decoration, independently of
        // NSTextView's clipping. It is evidence, not a replacement product view.
        let canvas = D2FragmentCanvas(fragment: f)
        try render(canvas, label + "-full-fragment")
        return (box, f)
    }

    func testO1801FinalCalloutDecorationFitsDocumentBounds() throws {
        let (e, text) = editor([.text("Wet"), callout("Callout py")], height: 55)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0)); settle(text)
        let (box, _) = try recordBox(e, text, "o18-01-final-typed-callout")
        XCTAssertLessThanOrEqual(box.maxY, text.bounds.maxY + 0.5, "final callout bottom padding must fit in the document")
    }

    func testO1801EmptyPickedCalloutDecorationFitsDocumentBounds() throws {
        let (e, text) = editor([.text("Wet"), .text("")], height: 55)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        XCTAssertTrue(e.perform(.paragraph(.callout(icon: "💡"))))
        settle(text)
        // The title fragment owns the empty line when it is the only body line.
        let range = try XCTUnwrap(e.textRange(for: NSRange(location: 0, length: 0)))
        let f = try XCTUnwrap(e.layoutManager?.textLayoutFragment(for: range.location) as? NoteBlockLayoutFragment)
        let box = try XCTUnwrap(f.lastLineBoxRect).offsetBy(dx: f.layoutFragmentFrame.minX + text.textContainerOrigin.x,
                                                          dy: f.layoutFragmentFrame.minY + text.textContainerOrigin.y)
        records.append(["case": "o18-01-empty-picked", "box": rect(box), "document": rect(text.bounds), "surface": rect(f.renderingSurfaceBounds)])
        try render(text, "o18-01-empty-picked-document"); try render(D2FragmentCanvas(fragment: f), "o18-01-empty-picked-full-fragment")
        XCTAssertLessThanOrEqual(box.maxY, text.bounds.maxY + 0.5, "new empty callout keeps its bottom padding too")
    }

    func testO1802ReturnContinuationBoxContainsEmptyLineAndPadding() throws {
        let (e, text) = editor([.text("Wet"), callout("First py")], height: 80)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
        text.insertNewline(nil); settle(text)
        XCTAssertEqual(e.paragraphStyle(at: e.textStorage.length), .callout(icon: "💡"))
        let (box, f) = try recordBox(e, text, "o18-02-return-continuation")
        let line = try XCTUnwrap(f.textLineFragments.last)
        XCTAssertEqual(line.characterRange.length, 0)
        let lineBottom = f.layoutFragmentFrame.minY + line.typographicBounds.maxY + text.textContainerOrigin.y
        let required = lineBottom + AtticNoteType.calloutPaddingV + NoteTextStyle.baselineShift(AtticNoteType.body)
        XCTAssertGreaterThanOrEqual(box.maxY + 0.5, required, "Return's empty continuation needs the same bottom padding as typed text")
        XCTAssertLessThanOrEqual(box.maxY, text.bounds.maxY + 0.5, "continuation decoration must be scrollable")
    }

    func testO1804EmptyBodyAfterCalloutDoesNotJumpWhenTypingStarts() throws {
        for route in ["below-click", "double-return", "pick-body", "reopen"] {
            let blocks: [NoteBlock] = [.text("Wet"), callout("First py"), callout("Second py")]
                + (route == "reopen" ? [.text("")] : [])
            let (e, text) = editor(blocks, height: 240)
            text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
            switch route {
            case "below-click": XCTAssertTrue(e.startLineBelowFinalBlock())
            case "double-return": text.insertNewline(nil); text.insertNewline(nil)
            case "pick-body": text.insertNewline(nil); XCTAssertTrue(e.perform(.paragraph(.body)))
            default: break
            }
            settle(text)
            XCTAssertEqual(e.paragraphStyle(at: e.textStorage.length), .body)
            let end = e.textStorage.length
            let empty = try XCTUnwrap(e.caretRect(at: end))
            let format = NoteFormatControls(engine: e, textView: text, scrollView: text.enclosingScrollView!, design: AtticDesignContext(mode: .dark))
            controls.append(format); format.refresh(); settle(text)
            let (box, _) = try recordBox(e, text, "o18-04-\(route)-empty")
            let hint = descendants(text).filter { !$0.isHidden && String(describing: type(of: $0)).contains("OverlayHosting") }.map { rect($0.frame) }
            records.append(["case": "o18-04-\(route)-empty", "caret": rect(empty), "hintVisible": format.isHintVisible,
                            "overlays": hint, "gapFromBox": empty.minY - box.maxY,
                            "typingParagraph": String(describing: text.typingAttributes[.paragraphStyle])])
            text.insertText("x", replacementRange: NSRange(location: end, length: 0)); settle(text)
            let typed = try XCTUnwrap(e.caretRect(at: end))
            records.append(["case": "o18-04-\(route)-typed", "caret": rect(typed), "jump": typed.minY - empty.minY])
            _ = try recordBox(e, text, "o18-04-\(route)-typed-box")
            try render(text, "o18-04-\(route)-typed")
            XCTAssertEqual(empty.minY, typed.minY, accuracy: 0.5, "\(route): hint/empty line must occupy the same paragraph baseline as the first letter")
        }
    }

    /// Causal control: the existing contextual restyler alone restores the
    /// missing space, with no character edit and no placeholder offset.
    func testO1804ContextualRestyleRestoresLoadedExitPaddingWithoutTyping() throws {
        let blocks: [NoteBlock] = [.text("Wet"), callout("First py"), callout("Second py"), .text("")]
        let (e, text) = editor(blocks, height: 240)
        text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0)); settle(text)
        let before = try XCTUnwrap(e.caretRect(at: e.textStorage.length))
        let above = e.paragraphRange(at: e.textStorage.length - 1)
        e.restyle(above); e.invalidateLayout(above); settle(text)
        let after = try XCTUnwrap(e.caretRect(at: e.textStorage.length))
        let (reference, referenceText) = editor(Array(blocks.dropLast()) + [.text("x")], height: 240)
        settle(referenceText)
        let expected = try XCTUnwrap(reference.caretRect(at: reference.textStorage.length - 1))
        records.append(["case": "o18-04-restyle-control", "before": rect(before), "after": rect(after), "typedReference": rect(expected),
                        "restoredSpace": after.minY - before.minY])
        _ = try recordBox(e, text, "o18-04-restyled-without-typing")
        XCTAssertEqual(after.minY, expected.minY, accuracy: 0.5)
        // Round F3 (O18-04): the reopened line already has the exit padding
        // (the empty last line's own attributes carry it), so nothing is
        // left for a restyle to restore. Before F3 this was 9.53 pt.
        XCTAssertEqual(before.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(after.minY - before.minY, 0, accuracy: 0.5)
    }

    /// For these callout-only fixtures the pre-O3 content delegate returned
    /// nil. Disabling that delegate replays that exact display-attribute policy,
    /// without modifying product source or pretending to run an older binary.
    func testPreO3CalloutDisplayPolicyStillHasTheContinuationAndBodyGapDefects() throws {
        for route in ["return", "body", "reopen"] {
            let continuation = route == "return"
            let blocks: [NoteBlock] = [.text("Wet"), callout("First py")] + (route == "reopen" ? [.text("")] : [])
            let (e, text) = editor(blocks, height: 100)
            text.setSelectedRange(NSRange(location: e.textStorage.length, length: 0))
            if continuation { text.insertNewline(nil) } else if route == "body" { XCTAssertTrue(e.ensureBodyAfterFinalBlock()) }
            settle(text)
            let (currentBox, _) = try recordBox(e, text, "o3-current-\(route)")
            let currentCaret = try XCTUnwrap(e.caretRect(at: e.textStorage.length))
            e.invalidateLayout(NSRange(location: 0, length: e.textStorage.length)); settle(text)
            let freshCaret = try XCTUnwrap(e.caretRect(at: e.textStorage.length))
            e.contentStorage.delegate = nil
            e.invalidateLayout(NSRange(location: 0, length: e.textStorage.length)); settle(text)
            let (oldPolicyBox, _) = try recordBox(e, text, "pre-o3-policy-\(route)")
            let oldPolicyCaret = try XCTUnwrap(e.caretRect(at: e.textStorage.length))
            records.append(["case": "o3-attribution-\(route)", "currentBox": rect(currentBox),
                            "preO3PolicyBox": rect(oldPolicyBox), "currentCaret": rect(currentCaret), "freshCurrentCaret": rect(freshCaret), "preO3PolicyCaret": rect(oldPolicyCaret)])
            XCTAssertEqual(currentBox.maxY, oldPolicyBox.maxY, accuracy: 0.5)
            XCTAssertEqual(freshCaret.minY, oldPolicyCaret.minY, accuracy: 0.5, "compare freshly laid out policies, not a stale fragment")
        }
    }

    private func stock(from source: NSTextView) -> NSTextView {
        let text = NSTextView(usingTextLayoutManager: true)
        text.frame = CGRect(x: 0, y: 0, width: 340, height: 400)
        text.isRichText = false; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainerInset = source.textContainerInset
        text.textContainer?.lineFragmentPadding = source.textContainer?.lineFragmentPadding ?? 0
        text.textContainer?.widthTracksTextView = true
        let copy = NSMutableAttributedString(attributedString: source.textStorage!)
        copy.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if let p = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                p.textLists = [] // same display paragraph styles; Attic suppresses native markers
                if copy.attribute(.noteBlockStyle, at: range.location, effectiveRange: nil) as? String == "heading" { p.tailIndent = -24 }
                copy.addAttribute(.paragraphStyle, value: p, range: range)
            }
        }
        text.textStorage?.setAttributedString(copy)
        text.typingAttributes = source.typingAttributes
        text.insertionPointColor = source.insertionPointColor
        text.drawsBackground = source.drawsBackground; text.backgroundColor = source.backgroundColor
        let scroll = NSScrollView(frame: text.frame); scroll.documentView = text
        host(scroll, text: text, height: 400)
        return text
    }
    private func selectionRect(_ text: NSTextView, at offset: Int) throws -> CGRect {
        let layout = try XCTUnwrap(text.textLayoutManager), content = try XCTUnwrap(layout.textContentManager)
        let start = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
        var result: CGRect?
        layout.enumerateTextSegments(in: NSTextRange(location: start), type: .selection, options: [.rangeNotRequired]) { _, r, _, _ in result = r; return false }
        return try XCTUnwrap(result).offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
    }

    func testO1803GreyBarBelowHeadingIsQuoteDecorationWithOneIndicator() throws {
        for isQuote in [true, false] {
            let (e, text) = editor([.text("Title"), heading(1), .text("Bmibmibn py", style: isQuote ? "quote" : nil)], height: 220)
            text.setSelectedRange(NSRange(location: e.titleParagraphRange.length + 1, length: 0)); settle(text)
            let offset = (e.textStorage.string as NSString).range(of: "Bmibmibn").location
            let range = try XCTUnwrap(e.textRange(for: NSRange(location: offset, length: 0)))
            let f = try XCTUnwrap(e.layoutManager?.textLayoutFragment(for: range.location))
            let bar = (f as? NoteBlockLayoutFragment)?.quoteBar
            records.append(["case": isQuote ? "o18-03-heading-then-quote" : "o18-03-heading-then-body", "indicatorCount": indicators(text).count,
                            "indicatorFrames": indicators(text).map { rect(text.convert($0.frame, from: $0.superview)) },
                            "bar": bar.map { rect($0.offsetBy(dx: f.layoutFragmentFrame.minX + text.textContainerOrigin.x,
                                                               dy: f.layoutFragmentFrame.minY + text.textContainerOrigin.y)) } as Any? ?? NSNull(),
                            "textInset": (e.textStorage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? -1])
            try render(text, isQuote ? "o18-03-heading-then-quote" : "o18-03-heading-then-body")
            XCTAssertEqual(indicators(text).count, 1)
            XCTAssertEqual(bar != nil, isQuote)
            if let bar { XCTAssertEqual(bar.width, 3, accuracy: 0.01) }
        }
    }

    func testO1803RealNativeIndicatorsMatchStockRelativeToLineBaseline() throws {
        let cases: [(String, NoteBlock)] = [("body", .text("Bmibmibn py"))] + (1...6).map { ("h\($0)", heading($0)) }
            + [("callout", callout("Callout py")), ("list", .text("List py", style: "bullet")), ("quote", .text("Bmibmibn py", style: "quote")), ("empty-placeholder", .text(""))]
        for (name, block) in cases {
            let (e, ours) = editor([.text("Title"), block], height: 220)
            let offset = e.titleParagraphRange.length + 1
            ours.setSelectedRange(NSRange(location: offset, length: 0)); settle(ours)
            let native = stock(from: ours)
            native.setSelectedRange(NSRange(location: offset, length: 0)); native.typingAttributes = ours.typingAttributes; settle(native)
            let ourIndicator = try XCTUnwrap(indicators(ours).first, "AppKit must create ours; no synthetic indicator")
            let stockIndicator = try XCTUnwrap(indicators(native).first, "AppKit must create stock; no synthetic indicator")
            let ourFrame = ours.convert(ourIndicator.frame, from: ourIndicator.superview)
            let stockFrame = native.convert(stockIndicator.frame, from: stockIndicator.superview)
            let ourSegment = try selectionRect(ours, at: offset), stockSegment = try selectionRect(native, at: offset)
            let ourLine = try XCTUnwrap(NoteLineGeometry.line(at: ourSegment, in: ours))
            let stockLine = try XCTUnwrap(NoteLineGeometry.line(at: stockSegment, in: native))
            let font = try XCTUnwrap(ours.typingAttributes[.font] as? NSFont)
            let f = e.layoutManager?.textLayoutFragment(for: e.textRange(for: NSRange(location: offset, length: 0))!.location)
            let bar = (f as? NoteBlockLayoutFragment)?.quoteBar
            records.append(["case": name, "font": font.fontName, "fontSize": font.pointSize, "ascender": font.ascender, "descender": font.descender,
                            "ours": rect(ourFrame), "stock": rect(stockFrame), "ourSegment": rect(ourSegment), "stockSegment": rect(stockSegment),
                            "ourBaseline": ourLine.baseline, "stockBaseline": stockLine.baseline,
                            "oursTopFromBaseline": ourFrame.minY - ourLine.baseline, "stockTopFromBaseline": stockFrame.minY - stockLine.baseline,
                            "oursCount": indicators(ours).count, "stockCount": indicators(native).count,
                            "ourIndicatorClass": NSStringFromClass(type(of: ourIndicator)), "ourIndicatorMode": ourIndicator.displayMode.rawValue,
                            "ourIndicatorColor": ourIndicator.color.description, "quoteBar": bar.map(rect) as Any? ?? NSNull(),
                            "ourTree": descendants(ours).map { "\(type(of: $0)) \($0.frame) hidden=\($0.isHidden)" }])
            try render(ours, "o18-03-\(name)-ours"); try render(native, "o18-03-\(name)-stock")
            XCTAssertEqual(indicators(ours).count, 1, "\(name): exactly one genuine insertion indicator")
            XCTAssertEqual(ourFrame.height, stockFrame.height, accuracy: 0.5, "\(name): allow AppKit to size its caret")
            XCTAssertEqual(ourFrame.minY - ourLine.baseline, stockFrame.minY - stockLine.baseline, accuracy: 0.5, "\(name): allow AppKit to place its caret")
        }
    }
}

@MainActor
private final class D2FragmentCanvas: NSView {
    let fragment: NSTextLayoutFragment
    let drawOrigin: CGPoint
    init(fragment: NSTextLayoutFragment) {
        self.fragment = fragment
        let b = fragment.renderingSurfaceBounds.union(CGRect(origin: .zero, size: fragment.layoutFragmentFrame.size))
        drawOrigin = CGPoint(x: 8 - b.minX, y: 8 - b.minY)
        super.init(frame: CGRect(x: 0, y: 0, width: b.width + 16, height: b.height + 16))
        appearance = NSAppearance(named: .darkAqua)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.darkGray.setFill(); bounds.fill()
        if let c = NSGraphicsContext.current?.cgContext { fragment.draw(at: drawOrigin, in: c) }
    }
}
