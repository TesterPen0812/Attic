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
