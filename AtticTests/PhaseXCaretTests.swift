import AppKit
import XCTest
@testable import Attic

/// F-03 (owner 2026-10-10): the text caret is centred on the text's line and
/// no taller than the text (the font's ascender to its descender). Windows are
/// never shown; the system's indicator is stood in for by an
/// `NSTextInsertionIndicator` framed to the line's box, as TextKit frames it.
@MainActor
final class PhaseXCaretTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    func testSmoothRetiredCaretObserversAreUnregistered() {
        let notifications = CountingCaretNotifications()
        let view = NSTextView(usingTextLayoutManager: true)
        var fitter: NoteCaretFitter? = NoteCaretFitter(textView: view, notifications: notifications)
        for _ in 0..<50 {
            weak var released: NSView?
            autoreleasepool {
                let indicator = NSTextInsertionIndicator(frame: .zero)
                released = indicator
                view.addSubview(indicator)
                fitter?.refresh()
                indicator.removeFromSuperview()
            }
            XCTAssertNil(released, "the fixture must retire the indicator")
            fitter?.refresh()
        }
        XCTAssertEqual(notifications.added, 50)
        XCTAssertEqual(notifications.removed, 50, "dead indicators must not leave block observers behind")
        fitter = nil
        XCTAssertEqual(notifications.removed, notifications.added, "teardown must balance every registration")
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

    private func paragraphStarts(_ engine: NoteEditorEngine) -> [(text: String, location: Int)] {
        let ns = engine.textStorage.string as NSString
        var result: [(String, Int)] = []
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            result.append((ns.substring(with: range).trimmingCharacters(in: .newlines), range.location))
            location = NSMaxRange(range)
        }
        return result
    }

    private var everyStyle: [NoteBlock] {
        [.text("The title"), .text("Body line one"), .text("Body line two"),
         heading("Heading", level: 2), heading("Subheading", level: 3), heading("Title style", level: 1),
         .text("Quote one", style: "quote"), .text("Bullet", style: "bullet"), .text("Number", style: "number"),
         .checklist("Check"), .text("code line", style: "mono"), .text("after")]
    }

    /// For every block style the fitted caret is the glyph box: its height is
    /// the font's ascender to descender, centred on the glyphs, inside the
    /// line's box and never taller than it.
    func testCaretIsTheGlyphBoxOnEveryBlockStyle() throws {
        let (engine, textView) = makeEditor(everyStyle)
        let selectionHost = try XCTUnwrap(textView.subviews.first)
        var rows = ""
        for (text, location) in paragraphStarts(engine) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            let before = try XCTUnwrap(engine.caretRect(at: location), text)
            let font = try XCTUnwrap(engine.textStorage.attribute(.font, at: location, effectiveRange: nil) as? NSFont, text)
            // The system's caret is the line's box; give the fitter one to fit.
            let indicator = NSTextInsertionIndicator(frame: before)
            selectionHost.addSubview(indicator)
            XCTAssertEqual(NoteCaretFitter.font(of: textView)?.pointSize, font.pointSize, "\(text): the caret takes the line's font")
            textView.caretFitter.refresh()
            let after = textView.convert(indicator.frame, from: selectionHost)
            let line = try XCTUnwrap(NoteCaretFitter.line(at: before, in: textView), text)
            let glyphHeight = font.ascender - font.descender

            XCTAssertEqual(after.height, glyphHeight, accuracy: 0.01, "\(text): ascender to descender")
            XCTAssertEqual(after.maxY - line.baseline, -font.descender, accuracy: 0.01, "\(text): the descender ends the caret")
            XCTAssertEqual(line.baseline - after.minY, font.ascender, accuracy: 0.01, "\(text): the ascender starts it")
            XCTAssertLessThanOrEqual(after.height, before.height + 0.01, "\(text): never taller than the line")
            // The font's descender can pass the box's floor by a fraction of a point (TextKit rounds the box).
            XCTAssertGreaterThanOrEqual(after.minY, before.minY - 0.5, "\(text): inside the line's box")
            XCTAssertLessThanOrEqual(after.maxY, before.maxY + 0.5, "\(text): inside the line's box")
            XCTAssertEqual(after.minX, before.minX, accuracy: 0.01, "\(text): x stays the system's")
            XCTAssertEqual(after.width, before.width, accuracy: 0.01)
            // Centred on the glyph box: equal room above the ascender and
            // below the descender, around the baseline.
            XCTAssertEqual((line.baseline - after.minY) - font.ascender, after.maxY - line.baseline + font.descender, accuracy: 0.01)
            rows += String(format: "%@ | box %.2f at %.2f | glyph box %.2f at %.2f\n", text, before.height, before.minY, after.height, after.minY)
            indicator.removeFromSuperview()
        }
        rows.split(separator: "\n").forEach { print("CARET", $0) }
    }

    /// Refitting is stable: the system reframing the indicator (a move, a
    /// blink restart) is fitted again, and an unchanged frame is left alone.
    func testRefitIsIdempotentAndFollowsTheSystemsFrame() throws {
        let (engine, textView) = makeEditor(everyStyle)
        let host = try XCTUnwrap(textView.subviews.first)
        let location = (engine.textStorage.string as NSString).range(of: "Body line two").location
        textView.setSelectedRange(NSRange(location: location, length: 0))
        let box = try XCTUnwrap(engine.caretRect(at: location))
        let indicator = NSTextInsertionIndicator(frame: box)
        host.addSubview(indicator)
        textView.caretFitter.refresh()
        let fitted = indicator.frame
        XCTAssertNotEqual(fitted, box)
        XCTAssertFalse(textView.caretFitter.fit(indicator), "already fitted")
        indicator.frame = box
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(indicator.frame, fitted, "the system's own reframe is fitted again")
    }

    /// A line of its own (an image) keeps the system's full-height caret.
    func testLineOfAnObjectKeepsTheSystemCaret() throws {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)
        let (engine, textView) = makeEditor([.text("Title"), image, .text("After")])
        let host = try XCTUnwrap(textView.subviews.first)
        let location = (engine.textStorage.string as NSString).range(of: "After").location - 1
        textView.setSelectedRange(NSRange(location: location, length: 0))
        let box = try XCTUnwrap(engine.caretRect(at: location))
        let indicator = NSTextInsertionIndicator(frame: box)
        host.addSubview(indicator)
        textView.caretFitter.refresh()
        XCTAssertEqual(indicator.frame, box)
    }

    /// A table cell's editor (its own text view, body type on 17.5 lines) is
    /// fitted the same way.
    func testTableCellCaretIsTheGlyphBox() throws {
        let rows = [["Pillar", "What happened"], ["Integrity", "Systems encrypted"]]
        let (engine, textView) = makeEditor([.text("Title"), .table(NoteTable(texts: rows)), .text("After")])
        textView.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(engine.tableViews().first)
        table.activate(NoteTable.Position(row: 1, column: 0), caret: .end)
        let editor = table.editor
        let host = try XCTUnwrap(editor.subviews.first)
        let layout = try XCTUnwrap(editor.textLayoutManager)
        var box: NSRect?
        layout.enumerateTextSegments(in: NSTextRange(location: layout.documentRange.endLocation), type: .selection,
                                     options: [.rangeNotRequired]) { _, frame, _, _ in box = frame; return false }
        let before = try XCTUnwrap(box).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        let indicator = NSTextInsertionIndicator(frame: before)
        host.addSubview(indicator)
        editor.caretFitter.refresh()
        let after = editor.convert(indicator.frame, from: host)
        let font = try XCTUnwrap(NoteCaretFitter.font(of: editor))
        let line = try XCTUnwrap(NoteCaretFitter.line(at: before, in: editor))
        XCTAssertEqual(font.pointSize, NoteTextStyle(design: .default).bodyFont.pointSize)
        XCTAssertEqual(before.height, AtticNoteType.body.lineHeight, accuracy: 0.01, "the system's caret is the 17.5 line")
        XCTAssertEqual(after.height, font.ascender - font.descender, accuracy: 0.01)
        XCTAssertEqual(line.baseline - after.minY, font.ascender, accuracy: 0.01)
        XCTAssertLessThan(after.height, before.height)
        print("CARET", String(format: "table cell | box %.2f at %.2f | glyph box %.2f at %.2f", before.height, before.minY, after.height, after.minY))
    }
}


/// Independent registration counts: a weak indicator alone cannot prove
/// NotificationCenter released its block observer.
private final class CountingCaretNotifications: NotificationCenter, @unchecked Sendable {
    private let countLock = NSLock()
    private var counts = (added: 0, removed: 0)
    var added: Int { countLock.withLock { counts.added } }
    var removed: Int { countLock.withLock { counts.removed } }

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        countLock.withLock { counts.added += 1 }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
    override func removeObserver(_ observer: Any) {
        countLock.withLock { counts.removed += 1 }
        super.removeObserver(observer)
    }
}
