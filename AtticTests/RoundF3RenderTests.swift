import AppKit
import XCTest
@testable import Attic

/// Round F3 comparison renders (headless, never-shown windows): each case
/// as Attic draws it with AppKit's caret, and the same text in a stock
/// TextEdit-default text view. Built unchanged against b07795e4 for "before".
@MainActor
private final class F3RenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
final class F3CaretRenderTests: XCTestCase {
    var windows: [NSWindow] = []
    var keep: [AnyObject] = []
    override func tearDown() async throws {
        for w in windows { w.contentView = nil; w.close() }
        windows.removeAll(); keep.removeAll()
    }
    func host(_ scroll: NSScrollView, _ text: NSTextView, dark: Bool, height: CGFloat) {
        scroll.frame = CGRect(x: 0, y: 0, width: 300, height: height)
        let w = F3RenderWindow(contentRect: CGRect(x: -9000, y: -9000, width: 300, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = scroll; windows.append(w); w.makeFirstResponder(text)
    }
    func settle(_ text: NSTextView) {
        if let lm = text.textLayoutManager { lm.ensureLayout(for: lm.documentRange) }
        text.enclosingScrollView?.layoutSubtreeIfNeeded(); text.layoutSubtreeIfNeeded()
        text.textLayoutManager?.textViewportLayoutController.layoutViewport()
        text.updateInsertionPointStateAndRestartTimer(true)
        text.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
    func attach(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.png"); a.name = name + ".png"; a.lifetime = .keepAlways; add(a)
    }
    func callout(_ t: String) -> NoteBlock { var b = NoteBlock.text(t, style: "quote"); b.callout = "💡"; return b }
    func heading(_ l: Int) -> NoteBlock { var b = NoteBlock.text("Heading py", style: "heading"); b.level = l; return b }

    func testRenders() throws {
        try requireKeyWindowTests()
        var mono = NoteBlock.text("let x = 1", style: "mono"); mono.language = "swift"
        let cases: [(String, [NoteBlock], Int)] = [
            ("body", [.text("Title"), .text("Body text py")], 8), ("h1", [.text("Title"), heading(1)], 8),
            ("h2", [.text("Title"), heading(2)], 8), ("h3", [.text("Title"), heading(3)], 8),
            ("title", [.text("Title py"), .text("Body")], 2), ("callout", [.text("Title"), callout("Callout py")], 8),
            ("quote", [.text("Title"), .text("Quote text py", style: "quote")], 8),
            ("list", [.text("Title"), .text("List item py", style: "bullet")], 8), ("code", [.text("Title"), mono], 8),
            ("blank-interior", [.text("Title"), .text("Above py"), .text(""), .text("Below py")], 15),
            ("hint", [.text("Title"), .text("Body text py"), .text("")], -1),
            ("table", [.text("Title"), .table(NoteTable(texts: [["Head py", "B"], ["Cell py", "d"]])), .text("After")], -2)]
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for (name, blocks, offset) in cases {
                let e = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks), design: AtticDesignContext(mode: dark ? .dark : .light))
                keep.append(e)
                let (scroll, text) = e.makeView()
                text.textContainerInset = CGSize(width: 24, height: 0)
                host(scroll, text, dark: dark, height: name == "table" ? 140 : 90)
                settle(text)
                var stockFont: NSFont?
                var stockText = ""
                if offset == -2, let table = e.tableViews().first {
                    table.activate(NoteTable.Position(row: 1, column: 0), caret: .end); settle(table.editor)
                    stockFont = table.editor.typingAttributes[.font] as? NSFont; stockText = "Cell py"
                } else {
                    let location = offset == -1 ? e.textStorage.length : offset
                    text.setSelectedRange(NSRange(location: location, length: 0))
                    if offset == -1 {
                        let f = NoteFormatControls(engine: e, textView: text, scrollView: scroll, design: AtticDesignContext(mode: dark ? .dark : .light))
                        keep.append(f); f.refresh()
                    }
                    settle(text)
                    stockFont = text.typingAttributes[.font] as? NSFont
                    let string = e.textStorage.string as NSString
                    stockText = offset == -1 ? "" : string.substring(with: string.paragraphRange(for: NSRange(location: location, length: 0))).trimmingCharacters(in: .newlines)
                }
                settle(text)
                attach(scroll, "\(name)-attic-\(mode)")
                // TextEdit's default: the same font, a default paragraph style.
                let stock = NSTextView(usingTextLayoutManager: true)
                stock.isRichText = false
                stock.textContainerInset = CGSize(width: 24, height: 16)
                stock.textContainer?.lineFragmentPadding = 0
                let font = stockFont ?? NSFont.systemFont(ofSize: 12.5)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
                stock.textStorage?.setAttributedString(NSAttributedString(string: stockText, attributes: attributes))
                stock.typingAttributes = attributes
                stock.insertionPointColor = .textInsertionPointColor
                stock.drawsBackground = true; stock.backgroundColor = .textBackgroundColor
                let stockScroll = NSScrollView(frame: .zero); stockScroll.documentView = stock
                stock.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
                host(stockScroll, stock, dark: dark, height: 60)
                stock.setSelectedRange(NSRange(location: min(stockText.count, offset == -2 ? 7 : max(0, offset - 6)), length: 0))
                if name == "title" { stock.setSelectedRange(NSRange(location: 2, length: 0)) }
                settle(stock)
                attach(stockScroll, "\(name)-textedit-\(mode)")
            }
        }
    }
}
