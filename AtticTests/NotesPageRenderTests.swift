import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Notes page hosted as the panel hosts it, in a window that is never
/// shown: the title's accessories sit on the title's lines, the tag line
/// pushes the body down, the header title appears once the title scrolls
/// away. With `ATTIC_NOTES_RENDER_DIR` set (pass it to xcodebuild as
/// `TEST_RUNNER_ATTIC_NOTES_RENDER_DIR`), each state is also written as a
/// PNG for a visual check (drawn controls: an off-screen render cannot show
/// Liquid Glass).
@MainActor
final class NotesPageRenderTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticNotesRender-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private struct Harness {
        let window: NSWindow
        let host: NSView
        let store: NoteStore
        let noteDraft: NoteDraftController
        var controller: NotesPageController { noteDraft.pages }
    }

    private let gate = PersistenceGate()

    private func makeHarness(context: AtticDesignContext, seed: (NoteStore) throws -> Void) throws -> Harness {
        let gate = gate
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        try seed(store)
        let noteDraft = NoteDraftController(noteStore: store)
        let uiState = PanelUIState()
        let size = CGSize(width: 320, height: 520)
        let toasts = PanelToastCenter()
        let root = NotesRenderRoot(noteDraft: noteDraft, store: store, uiState: uiState, toasts: toasts, size: size)
            .atticDesign(context)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: context.mode == .dark ? .darkAqua : .aqua)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        spin()
        host.layoutSubtreeIfNeeded()
        spin()
        return Harness(window: window, host: host, store: store, noteDraft: noteDraft)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func write(_ view: NSView, name: String) {
        guard ProcessInfo.processInfo.environment["ATTIC_NOTES_RENDER_DIR"] != nil else { return }
        // The test host's own temporary folder (it may be sandboxed).
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("AtticNotesRender").path
        print("NOTES_RENDER_DIR=\(path)")
        view.layoutSubtreeIfNeeded()
        for case let textView as NSTextView in descendants(of: view) {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            textView.display()
        }
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: path).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func seedPricing(_ store: NoteStore) throws {
        let document = NoteDocument(blocks: [
            .text("Pricing page for the October launch"),
            .text("Lead with the free tier: most people only need the panel."),
            .text(""),
            .text("Before launch"),
            .checklist("Final copy from Sam", checked: true),
            .checklist("One screenshot per plan"),
            .checklist("Check the EU prices"),
            .text(""),
            .text("Open questions"),
            .text("Annual plan: two months free?"),
            .text("Student pricing")
        ] + (0..<30).map { .text("More thinking about pricing, line \($0).") })
        guard case .success = store.createDocumentNote(id: UUID(), document: document,
                                                       tags: ["launch-october", "pricing", "website-redesign"]) else {
            throw NSError(domain: "seed", code: 1)
        }
        guard case let .success((groceries, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [
            .text("Groceries"), .checklist("Oat milk", checked: true), .checklist("Lemons"), .checklist("Rice")
        ])) else { throw NSError(domain: "seed", code: 2) }
        store.setPinned(true, noteID: groceries)
    }

    func testTitleAccessoriesSitOnTheTitleAndTheTagsPushTheBodyDown() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        let pricing = try XCTUnwrap(harness.store.notes.first { $0.title.hasPrefix("Pricing") })
        XCTAssertTrue(harness.controller.open(noteID: pricing.id))
        spin(0.4)
        harness.host.layoutSubtreeIfNeeded()
        spin()
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        let rects = try XCTUnwrap(engine.titleLineRects())
        XCTAssertGreaterThan(rects.last.minY, rects.first.minY, "the long title wraps")
        let accessories = textView.accessoryViews
        XCTAssertEqual(accessories.count, 2)
        let tagLine = accessories[0], menu = accessories[1]
        XCTAssertFalse(menu.isHidden, "a saved note shows its ⋯")
        XCTAssertEqual(menu.frame.midY, rects.first.midY, accuracy: 6, "the ⋯ sits on the title's first line")
        let column = textView.bounds.width - textView.textContainerInset.width
        XCTAssertLessThanOrEqual(menu.frame.maxX, column + AtticNoteMetrics.menuButtonSize / 2)
        XCTAssertLessThanOrEqual(rects.first.maxX, column - AtticNoteMetrics.titleTrailingReserve + 1,
                                 "the title's lines keep clear of the ⋯")
        XCTAssertFalse(tagLine.isHidden)
        XCTAssertGreaterThanOrEqual(tagLine.frame.minY, rects.last.maxY, "tags sit under the title")
        let bodyStart = engine.titleParagraphRange.length + 1
        let bodyRect = try XCTUnwrap(engine.rect(for: NSRange(location: bodyStart, length: 1)))
        XCTAssertGreaterThanOrEqual(bodyRect.minY, tagLine.frame.maxY, "the body starts under the tags")
        XCTAssertEqual(engine.style.titleFont.fontDescriptor.symbolicTraits.contains(.bold), true)
        write(harness.host, name: "writing-light")

        // Scrolled: the header title takes the title's place.
        let scroll = try XCTUnwrap(engine.scrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 260))
        scroll.reflectScrolledClipView(scroll.contentView)
        spin()
        write(harness.host, name: "writing-scrolled-light")
    }

    func testTheLibraryShowsGroupsAndTheEmptyDraftShowsNoMenu() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.3)
        let draft = try XCTUnwrap(harness.controller.active)
        XCTAssertTrue(draft.isUntouchedDraft)
        let menu = try XCTUnwrap(draft.engine.textView?.accessoryViews.last)
        XCTAssertTrue(menu.isHidden, "an untouched draft shows no ⋯")
        write(harness.host, name: "new-draft-light")
        XCTAssertTrue(harness.controller.showLibrary())
        spin(0.5)
        write(harness.host, name: "library-light")
    }

    func testTheSlotShowsTheMostUrgentStateAndHowManyMore() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        let pricing = try XCTUnwrap(harness.store.notes.first { $0.title.hasPrefix("Pricing") })
        XCTAssertTrue(harness.controller.open(noteID: pricing.id))
        spin(0.3)
        let session = try XCTUnwrap(harness.controller.active)
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
                                   with: NSAttributedString(string: " more"), name: "Typing")
        gate.shouldFail = true
        _ = harness.controller.preserve(session)
        gate.shouldFail = false
        spin(0.3)
        let items = harness.controller.statusItems(for: session)
        // No recovery folder in this harness, so the text is only in memory.
        XCTAssertEqual(items.first?.label, "Only in memory")
        write(harness.host, name: "slot-not-saved-light")
        session.notice = "Restored unsaved text."
        spin(0.3)
        XCTAssertEqual(harness.controller.statusItems(for: session).count, 2)
        write(harness.host, name: "slot-two-states-light")
    }

    func testDarkWritingAndLibrary() throws {
        let harness = try makeHarness(context: AtticDesignContext(mode: .dark, controls: .craft)) { try Self.seedPricing($0) }
        let pricing = try XCTUnwrap(harness.store.notes.first { $0.title.hasPrefix("Pricing") })
        XCTAssertTrue(harness.controller.open(noteID: pricing.id))
        spin(0.4)
        write(harness.host, name: "writing-dark")
        XCTAssertTrue(harness.controller.showLibrary())
        spin(0.5)
        write(harness.host, name: "library-dark")
    }
}

/// The panel around the Notes page: its surface, the header and the notices.
private struct NotesRenderRoot: View {
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
