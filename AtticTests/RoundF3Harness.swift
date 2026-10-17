import AppKit
import XCTest
@testable import Attic

/// Round F3's harness: the real editor in a never-shown window that reports
/// key status, so AppKit creates its own real insertion indicator (D2's
/// technique). No window is ordered, activated or made key.
@MainActor
final class F3UnshownWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
class RoundF3TestCase: XCTestCase {
    var windows: [NSWindow] = []
    var engines: [NoteEditorEngine] = []
    var controls: [NoteFormatControls] = []

    override func tearDown() async throws {
        controls.removeAll()
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll(); engines.removeAll()
    }

    func callout(_ text: String, icon: String = "💡") -> NoteBlock {
        var b = NoteBlock.text(text, style: "quote"); b.callout = icon; return b
    }
    func heading(_ text: String, _ level: Int) -> NoteBlock {
        var b = NoteBlock.text(text, style: "heading"); b.level = level; return b
    }
    func code(_ text: String, language: String? = nil) -> NoteBlock {
        var b = NoteBlock.text(text, style: "mono"); b.language = language; return b
    }

    func host(_ scroll: NSScrollView, text: NSTextView, width: CGFloat = 340, height: CGFloat) {
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = F3UnshownWindow(contentRect: CGRect(x: -9000, y: -9000, width: width, height: height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = scroll; windows.append(window)
        window.makeFirstResponder(text)
        XCTAssertFalse(window.isVisible)
    }

    func editor(_ blocks: [NoteBlock], width: CGFloat = 340, height: CGFloat = 300) -> (NoteEditorEngine, NoteEditorTextView) {
        let e = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks), design: AtticDesignContext(mode: .dark))
        engines.append(e)
        let (scroll, text) = e.makeView()
        text.textContainerInset = CGSize(width: 24, height: 0) // as NoteEditorHost
        host(scroll, text: text, width: width, height: height)
        settle(text)
        return (e, text)
    }

    func settle(_ text: NSTextView) {
        if let layout = text.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        text.enclosingScrollView?.layoutSubtreeIfNeeded()
        text.layoutSubtreeIfNeeded()
        text.textLayoutManager?.textViewportLayoutController.layoutViewport()
        text.updateInsertionPointStateAndRestartTimer(true)
        text.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    /// AppKit's own insertion indicators in `text`, in its coordinates.
    func indicatorFrames(_ text: NSTextView) -> [CGRect] {
        descendants(text).compactMap { $0 as? NSTextInsertionIndicator }.map { text.convert($0.frame, from: $0.superview) }
    }

    /// The caret at the selection: AppKit's indicator (exactly one), and the
    /// baseline of the line TextKit laid it on.
    struct Caret { var frame: CGRect; var baseline: CGFloat }
    func caret(_ text: NSTextView, file: StaticString = #filePath, line: UInt = #line) throws -> Caret {
        settle(text)
        let frames = indicatorFrames(text)
        XCTAssertEqual(frames.count, 1, "exactly one native indicator", file: file, line: line)
        let frame = try XCTUnwrap(frames.first, file: file, line: line)
        let baseline = try XCTUnwrap(NoteLineGeometry.line(at: frame, in: text)?.baseline, file: file, line: line)
        return Caret(frame: frame, baseline: baseline)
    }

    func render(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        a.name = name + ".png"; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["F3_RENDER_DIR"] {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
}
