import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The combined Tasks + Notes app's fix round (CU reviews of 2026-10-03):
/// the Notes page hosted as the panel hosts it, in a window that is never
/// shown or made key.
@MainActor
final class CombinedFixRoundTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Harness {
        let window: NSWindow
        let host: NSView
        let store: NoteStore
        let noteDraft: NoteDraftController
        @MainActor var controller: NotesPageController { noteDraft.pages }
    }

    private let gate = PersistenceGate()

    private func makeHarness(context: AtticDesignContext = AtticDesignContext(controls: .craft),
                             seed: (NoteStore) throws -> Void = { _ in }) throws -> Harness {
        let gate = gate
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        try seed(store)
        let noteDraft = NoteDraftController(noteStore: store)
        let size = CGSize(width: 320, height: 520)
        let root = CombinedFixNotesRoot(noteDraft: noteDraft, store: store, uiState: PanelUIState(),
                                        toasts: PanelToastCenter(), size: size)
            .atticDesign(context)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        spin()
        host.layoutSubtreeIfNeeded()
        spin()
        return Harness(window: window, host: host, store: store, noteDraft: noteDraft)
    }

    private func type(_ text: String, into textView: NSTextView) {
        for character in text {
            if character == "\n" {
                textView.insertNewline(nil)
            } else {
                textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    private func fixtures() throws -> (image: URL, file: URL) {
        let directory = ownedTemporaryDirectory(prefix: "AtticCombinedFix")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("CU2-image-fixture.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 30).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let file = directory.appendingPathComponent("CU2-file-fixture.txt")
        try Data("A disposable file for the combined fix round.\n".utf8).write(to: file)
        return (image, file)
    }

    // MARK: P2-01: the title's placeholder is redrawn away

    /// TextKit 2 draws the text in its own fragment views, so typing never
    /// redraws the text view's own layer, where "Title" is drawn. The first
    /// character (typed or pasted) must invalidate the whole placeholder,
    /// not only the caret's old strip, or "Title" stays under the title;
    /// emptying the title draws it again.
    func testTheTitlePlaceholderIsRedrawnAwayWhenTheTitleGetsText() throws {
        let harness = try makeHarness()
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.4)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        harness.window.makeFirstResponder(textView)
        XCTAssertEqual(engine.textStorage.length, 0)
        let font = engine.style.titleFont
        let width = ("Title" as NSString).size(withAttributes: [.font: font]).width
        let origin = textView.textContainerOrigin
        // The placeholder's last letters, well clear of the caret's strip.
        let tail = NSRect(x: origin.x + width * 0.6, y: origin.y + 2, width: width * 0.4, height: font.capHeight)
        let recorder = DisplayInvalidationRecorder(textView)
        defer { recorder.stop() }
        func covered() -> Bool { recorder.rects.contains { $0.contains(tail) } }
        for entry in ["typed", "pasted"] {
            harness.host.layoutSubtreeIfNeeded()
            textView.display()
            recorder.rects.removeAll()
            if entry == "typed" {
                textView.insertText("C", replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                XCTAssertTrue(engine.pastePlainText("CU2 rendering probe", at: NSRange(location: 0, length: 0)))
            }
            harness.host.layoutSubtreeIfNeeded()
            XCTAssertTrue(covered(), "\(entry): the placeholder's whole line is redrawn: \(recorder.rects)")
            textView.display()
            recorder.rects.removeAll()
            textView.selectAll(nil)
            textView.deleteBackward(nil)
            harness.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(engine.textStorage.length, 0)
            XCTAssertTrue(covered(), "\(entry): emptied, the placeholder is drawn again in full: \(recorder.rects)")
        }
    }


    // MARK: P3-01: `/image` and `/file` are consumed

    /// SwiftUI clears the importer's presentation binding before it calls
    /// the completion: the request it was opened for must survive that.
    func testTheOpenPanelKeepsWhatItWasOpenedForUntilItsCompletion() {
        let chrome = NotesPageChrome()
        chrome.fileRequest = .slash
        chrome.fileRequest = nil // the binding, as the panel closes
        XCTAssertEqual(chrome.takeFileRequest(), .slash)
        XCTAssertNil(chrome.takeFileRequest(), "taken once")
        XCTAssertNil(chrome.fileRequest)
        chrome.fileRequest = .insert
        XCTAssertEqual(chrome.takeFileRequest(), .insert, "with the binding not yet cleared")
        XCTAssertNil(chrome.fileRequest)
        let id = UUID()
        chrome.fileRequest = .locate(id)
        chrome.fileRequest = nil
        XCTAssertEqual(chrome.takeFileRequest(), .locate(id))
    }

    /// The `/` Image or File… row replaces its typed command with the
    /// picture or the file card, at a line's start or after text, as the
    /// other `/` rows consume theirs.
    func testSlashImageAndSlashFileReplaceTheirCommand() throws {
        let harness = try makeHarness()
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.4)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        harness.window.makeFirstResponder(textView)
        let (image, file) = try fixtures()
        // The open panel is the page's; the test answers for it.
        engine.onSlashFileRequest = {}
        type("Attachments\nBefore the image ", into: textView)
        type("/image", into: textView)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        harness.controller.importSlashImage(image)
        for _ in 0..<60 where !engine.textStorage.string.contains(NoteDocument.objectCharacter) { spin(0.05) }
        XCTAssertEqual(engine.textStorage.string, "Attachments\nBefore the image \n\(NoteDocument.objectCharacter)\n")
        type("/file", into: textView)
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        harness.controller.importSlashImage(file)
        for _ in 0..<60 where engine.textStorage.string.filter({ $0 == NoteDocument.objectCharacter }).count < 2 { spin(0.05) }
        let text = engine.textStorage.string
        XCTAssertFalse(text.contains("/image") || text.contains("/file"), text.debugDescription)
        XCTAssertEqual(text, "Attachments\nBefore the image \n\(NoteDocument.objectCharacter)\n\(NoteDocument.objectCharacter)\n")
        let blocks = engine.document().blocks
        XCTAssertEqual(blocks.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(blocks.filter { $0.kind == .file }.count, 1)
        XCTAssertNil(harness.controller.active?.notice)
        // One Undo takes the file back out and leaves the typed `/file`.
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.textStorage.string.hasSuffix("/file"), engine.textStorage.string.debugDescription)
    }

    // MARK: P3-02: clean previews in All notes

    /// A row's preview is the note's text, not its Markdown: the CU review
    /// saw `## Section Alpha - Bullet one - Bullet two 1. N…`.
    @MainActor
    func testLibraryPreviewsShowCleanText() {
        var heading = NoteBlock.text("Section Alpha")
        heading.style = "heading"
        heading.level = 2
        func styled(_ text: String, _ style: String) -> NoteBlock {
            var block = NoteBlock.text(text)
            block.style = style
            return block
        }
        let document = NoteDocument(blocks: [
            .text("CU2 formats"), heading, styled("Bullet one", "bullet"), styled("Bullet two", "bullet"),
            styled("Number one", "number"), styled("A quote", "quote"), styled("let x = 1", "mono"),
            .checklist("Milk"), .text("Plain line")
        ])
        let summary = NoteRowSummary(document: document, filename: { _ in nil })
        XCTAssertEqual(summary.preview, "Section Alpha Bullet one, Bullet two, Number one A quote let x = 1 Milk Plain line")
        XCTAssertEqual(NoteRowSummary.previewText("### Deep heading").0, "Deep heading")
        XCTAssertEqual(NoteRowSummary.previewText("12) Twelfth").0, "Twelfth")
        XCTAssertEqual(NoteRowSummary.previewText("#launch is a tag").0, "#launch is a tag", "a hashtag is text")
        XCTAssertEqual(NoteRowSummary.plainInline("**Bold** and *it* and _under_ and `code` and ~~gone~~"),
                       "Bold and it and under and code and gone")
        XCTAssertEqual(NoteRowSummary.plainInline("2 * 3 = 6 and snake_case_name"), "2 * 3 = 6 and snake_case_name",
                       "lone marks stay")
    }

    // MARK: P3-03: the tag picker's create row is never cut short

    /// The card opens at its rows' width; typing "cu2" adds "New tag
    /// “#cu2”", wider than "#cu2shared": the card grows for it (CU pass 2,
    /// capture 51: "New tag “#c…" in a half-empty card).
    func testTheTagPickerGrowsForItsCreateRow() throws {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 340, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 560))
        window.orderFrontRegardless()
        windows.append(window)
        let anchor = NSView(frame: CGRect(x: 40, y: 400, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        let tags = ["cu2shared", "cuqa"]
        presenter.content = AnyView(TaskTagPickerView(allTags: tags, state: { _ in .off }, onToggle: { _ in },
                                                      onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.3)
        let opened = presenter.cardWidth
        let m = AtticDropdownMetrics.self
        XCTAssertGreaterThanOrEqual(opened + 0.5, AtticTagPicker.rowsWidth(tags: tags, create: nil) + m.inset * 2,
                                    "the rows fit as it opens")
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("cu2", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.3)
        let needed = AtticTagPicker.rowsWidth(tags: ["cu2shared"], create: "cu2") + m.inset * 2
        XCTAssertGreaterThan(needed, opened, "the create row is wider than the card it opened as")
        XCTAssertGreaterThanOrEqual(presenter.cardWidth + 0.5, needed, "the card grew for “New tag “#cu2””")
        let host = try XCTUnwrap(presenter.host)
        XCTAssertEqual(host.contentRect.width, presenter.cardWidth, accuracy: 1)
        // Filtering back to fewer, shorter rows never narrows it while open.
        editor.deleteBackward(nil)
        spin(0.3)
        XCTAssertGreaterThanOrEqual(presenter.cardWidth + 0.5, needed)
    }
}

/// Records the rectangles a view is asked to redraw (`setNeedsDisplay(_:)`,
/// however AppKit or the view itself calls it), by replacing the method on
/// that view's class for the test's duration.
@MainActor
final class DisplayInvalidationRecorder {
    var rects: [NSRect] = []
    private let cls: AnyClass
    private let selector = #selector(NSView.setNeedsDisplay(_:))
    private let original: IMP
    private static var active: DisplayInvalidationRecorder?
    private weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
        cls = Swift.type(of: view)
        let inherited = class_getInstanceMethod(cls, selector)!
        original = method_getImplementation(inherited)
        typealias Setter = @convention(c) (NSView, Selector, NSRect) -> Void
        let call = unsafeBitCast(original, to: Setter.self)
        let selector = selector
        let block: @convention(block) (NSView, NSRect) -> Void = { target, rect in
            MainActor.assumeIsolated {
                if let recorder = DisplayInvalidationRecorder.active, target === recorder.view { recorder.rects.append(rect) }
            }
            call(target, selector, rect)
        }
        Self.active = self
        let added = class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(inherited))
        if !added { method_setImplementation(class_getInstanceMethod(cls, selector)!, imp_implementationWithBlock(block)) }
    }

    func stop() {
        Self.active = nil
        if let method = class_getInstanceMethod(cls, selector) { method_setImplementation(method, original) }
    }
}

/// Ends the test process when the main thread is stuck (a layout or render
/// loop cannot be interrupted from the main thread itself).
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    init(seconds: TimeInterval, label: String) {
        let deadline = Date().addingTimeInterval(seconds)
        Thread.detachNewThread { [self] in
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                if self.isDone { return }
            }
            FileHandle.standardError.write(Data("WATCHDOG: the main thread did not finish \(label) in \(Int(seconds)) s\n".utf8))
            exit(70)
        }
    }

    private var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }

    func finish() { lock.lock(); done = true; lock.unlock() }
}

private struct CombinedFixNotesRoot: View {
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var store: NoteStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var toasts: PanelToastCenter
    let size: CGSize

    var body: some View {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        NotesEditorPage(controller: noteDraft.pages, noteStore: store, noteDraft: noteDraft, uiState: uiState, layout: layout)
            .environment(\.atticPanelToasts, toasts)
            .overlay(alignment: .top) {
                PanelHeader(isPinned: false, page: .notes, onTogglePin: {}, onSelectPage: { _ in })
                    .padding(.horizontal, layout.chromeInsets.leading)
                    .padding(.top, layout.chromeInsets.top)
            }
            .frame(width: size.width, height: size.height)
            .background(AtticPanelStageSurface(cornerSize: 0))
    }
}
