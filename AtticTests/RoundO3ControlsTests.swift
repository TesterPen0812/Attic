import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Round O3, the owner's 10-17 decision (O17-01): content scrolls all the
/// way under every floating control and stays visible through the blur,
/// with no fade hiding it, on every surface. Off screen the variable blur
/// does not draw (it is a window-server backdrop), so these pages show
/// the content under the controls sharp: what matters here is that nothing
/// hides it. With `ATTIC_O3_RENDER=1` (`TEST_RUNNER_ATTIC_O3_RENDER=1` to
/// xcodebuild) each state is also written as a PNG for a visual check.
@MainActor
final class RoundO3ControlsTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let gate = PersistenceGate()

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static let size = CGSize(width: 340, height: 520)

    static var designs: [(String, AtticDesignContext)] {
        var result: [(String, AtticDesignContext)] = []
        for surface in [PanelSurfaceStyle.glass, .frosted, .solid] {
            for mode in [AtticDesignContext.Mode.light, .dark] {
                result.append(("\(surface.rawValue)-\(mode.rawValue)", AtticDesignContext(mode: mode, surface: surface)))
            }
        }
        result.append(("reduce-transparency-light", AtticDesignContext(mode: .light, surface: .glass, reduceTransparency: true)))
        result.append(("reduce-transparency-dark", AtticDesignContext(mode: .dark, surface: .glass, reduceTransparency: true)))
        result.append(("increase-contrast-light", AtticDesignContext(mode: .light, surface: .glass, increaseContrast: true)))
        result.append(("increase-contrast-dark", AtticDesignContext(mode: .dark, surface: .glass, increaseContrast: true)))
        return result
    }

    private func host<V: View>(_ view: V, design: AtticDesignContext) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.atticDesign(design)))
        host.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: design.mode == .dark ? .darkAqua : .aqua)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        spin()
        return host
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        for case let text as NSTextView in descendants(of: view) {
            text.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    static var renderDirectory: URL? {
        guard ProcessInfo.processInfo.environment["ATTIC_O3_RENDER"] == "1" else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AtticO3Render")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) {
        guard let directory = Self.renderDirectory, let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
        print("O3_RENDER \(directory.path)/\(name).png")
    }

    /// Pixels in `rect` (points) that differ clearly from the band's most
    /// common colour: the content's ink.
    private func ink(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
        let scale = CGFloat(rep.pixelsWide) / Self.size.width
        var colours: [[CGFloat]] = []
        for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 1) {
            for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colours.append([c.redComponent, c.greenComponent, c.blueComponent])
            }
        }
        var counts: [String: Int] = [:]
        for c in colours { counts[c.map { String(Int($0 * 20)) }.joined(separator: ","), default: 0] += 1 }
        guard let mode = counts.max(by: { $0.value < $1.value })?.key.split(separator: ",").compactMap({ Double($0) }) else { return 0 }
        let base = mode.map { CGFloat($0) / 20 }
        return colours.filter { c in zip(c, base).map { abs($0 - $1) }.reduce(0, +) > 0.45 }.count
    }

    // MARK: Notes

    private func notesPage(_ design: AtticDesignContext, document: NoteDocument) throws -> (NSHostingView<AnyView>, NotesPageController) {
        let gate = gate
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        guard case .success = store.createDocumentNote(id: UUID(), document: document, tags: []) else {
            throw NSError(domain: "seed", code: 1)
        }
        let noteDraft = NoteDraftController(noteStore: store)
        let root = O3NotesRoot(noteDraft: noteDraft, store: store, uiState: PanelUIState(), toasts: PanelToastCenter(), size: Self.size)
        let view = host(root, design: design)
        let note = try XCTUnwrap(store.notes.first)
        XCTAssertTrue(noteDraft.pages.open(noteID: note.id))
        spin(0.3)
        view.layoutSubtreeIfNeeded()
        return (view, noteDraft.pages)
    }

    static let longNote = NoteDocument(blocks: [.text("Pricing page for the October launch")]
        + (0..<40).map { .text("More thinking about pricing, line \($0).") })

    /// The note's text stays visible under the header and the bottom row,
    /// between their buttons, on every surface; with Reduce Transparency
    /// the solid surface stands in for the blur (U-02).
    func testTheNoteStaysVisibleUnderTheHeaderAndTheBottomRow() throws {
        for (name, design) in Self.designs {
            let (view, controller) = try notesPage(design, document: Self.longNote)
            let scroll = try XCTUnwrap(controller.active?.engine.scrollView)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 160))
            scroll.reflectScrolledClipView(scroll.contentView)
            spin(0.2)
            let rep = try bitmap(view)
            write(rep, "o17-01-notes-\(name)")
            let layout = PanelPageLayout(cornerSize: 52, panelSize: Self.size)
            let bottom = layout.chromeInsets.bottom + AtticControlSize.panelButton.height
            // Between the corner buttons, clear of the header's title.
            let under = CGRect(x: 70, y: Self.size.height - bottom + 2, width: 150, height: bottom - 6)
            let behindHeader = CGRect(x: 70, y: 2, width: 40, height: layout.headerBottom - 4)
            if design.reduceTransparency {
                XCTAssertLessThan(ink(rep, in: under), 40, "\(name): the solid surface under the bottom row")
            } else {
                XCTAssertGreaterThan(ink(rep, in: under), 150, "\(name): text under the bottom row")
                XCTAssertGreaterThan(ink(rep, in: behindHeader), 30, "\(name): text under the header")
            }
        }
    }

    /// Renders for O17-07 and O17-08 (explicit render runs only).
    func testRenderTheNotesFormatItems() throws {
        guard Self.renderDirectory != nil else { throw XCTSkip("explicit render run only") }
        for mode in [AtticDesignContext.Mode.light, .dark] {
            let design = AtticDesignContext(mode: mode, surface: .glass)
            let formats: [(String, NoteParagraphStyle)] = [("quote", .quote), ("bullet", .bullet), ("number", .number),
                                                          ("callout", .callout(icon: "💡")), ("code", .mono), ("heading", .heading(2))]
            for (name, style) in formats {
                let (view, controller) = try notesPage(design, document: NoteDocument(blocks: [.text("Formats"), .text("A line of body text."), .text("")]))
                let engine = try XCTUnwrap(controller.active?.engine)
                let text = try XCTUnwrap(engine.textView)
                text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
                XCTAssertTrue(engine.perform(.paragraph(style)))
                spin(0.1)
                write(try bitmap(view), "o17-07-\(name)-picked-\(mode.rawValue)")
                text.insertText("Typed", replacementRange: text.selectedRange())
                spin(0.1)
                write(try bitmap(view), "o17-07-\(name)-typed-\(mode.rawValue)")
            }
            let (view, controller) = try notesPage(design, document: NoteDocument(blocks: [.text("Click below"), .text("A quoted line", style: "quote")]))
            let engine = try XCTUnwrap(controller.active?.engine)
            write(try bitmap(view), "o17-08-before-\(mode.rawValue)")
            XCTAssertTrue(engine.startLineBelowFinalBlock())
            engine.textView?.insertText("New body line", replacementRange: engine.textView?.selectedRange() ?? NSRange())
            spin(0.1)
            write(try bitmap(view), "o17-08-after-\(mode.rawValue)")
        }
    }

    // MARK: Tasks

    private func tasksPage(_ design: AtticDesignContext) throws -> NSHostingView<AnyView> {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: Self.size),
                             addBarFocused: .constant(false))
            .background(AtticPanelStageSurface(cornerSize: 0))
        let view = host(page, design: design)
        spin(1.2)
        return view
    }

    private func visibleList(in view: NSView) throws -> NSScrollView {
        return try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSScrollView }.first { scroll in
            let frame = scroll.convert(scroll.bounds, to: view)
            return !scroll.isHiddenOrHasHiddenAncestor && frame.minX >= 0 && frame.minX < 40 && frame.height > 300
        })
    }

    /// Rows scrolled up stay visible under the tabs line and the header's
    /// band (no longer gone 3 pt below the tabs), and under the add bar.
    func testTasksRowsStayVisibleUnderTheTabsAndTheAddBar() throws {
        for (name, design) in Self.designs {
            let view = try tasksPage(design)
            let layout = PanelPageLayout(cornerSize: 52, panelSize: Self.size)
            let band = CGRect(x: 40, y: 4, width: 200, height: layout.headerBottom - 8)
            let rest = ink(try bitmap(view), in: band)
            let list = try visibleList(in: view)
            list.contentView.scroll(to: CGPoint(x: 0, y: list.contentView.bounds.minY + 120))
            list.reflectScrolledClipView(list.contentView)
            spin(0.2)
            let rep = try bitmap(view)
            write(rep, "o17-01-tasks-\(name)")
            if design.reduceTransparency {
                XCTAssertLessThanOrEqual(ink(rep, in: band), rest + 40, "\(name): the solid surface under the header")
            } else {
                XCTAssertGreaterThan(ink(rep, in: band), rest + 100, "\(name): rows under the header's band")
            }
        }
    }
}

/// The panel around the Notes page, as `NotesPageRenderTests` hosts it.
private struct O3NotesRoot: View {
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
