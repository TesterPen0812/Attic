import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Notes page hosted as the panel hosts it, in a window that is never
/// shown: the title's accessories sit on the title's lines, the tag line
/// pushes the body down, the header title appears once the title scrolls
/// away. With `ATTIC_NOTES_RENDER_DIR` set (pass it to xcodebuild as
/// `TEST_RUNNER_ATTIC_NOTES_RENDER_DIR`), each state is retained in xcresult
/// as a PNG for a visual check (drawn controls: an off-screen render cannot show
/// Liquid Glass).
@MainActor
final class NotesPageRenderTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var directory: URL!

    override func setUp() async throws {
        directory = ownedTemporaryDirectory(prefix: "AtticNotesRender")
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()

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
        let path = directory.path
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
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
        ]), tags: ["print-shop", "priorities"]) else { throw NSError(domain: "seed", code: 2) }
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
        XCTAssertEqual(accessories.count, 3, "the tag line, the ⋯ and the tag suggestions")
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

    func testAR04TitleUsesOpaqueNativeFragmentsThroughFastReversalsAndWraps() throws {
        for width: CGFloat in [320, 420] {
            let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { store in
                _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks:
                    [.text("A long wrapped title with descenders gyp across several lines for fast reverse scrolling")] +
                    (0..<80).map { .text("Body line \($0)") }))
            }
            harness.window.setContentSize(NSSize(width: width, height: 520))
            harness.host.frame.size.width = width
            XCTAssertTrue(harness.controller.open(noteID: try XCTUnwrap(harness.store.notes.first).id))
            spin(0.3)
            let engine = try XCTUnwrap(harness.controller.active?.engine)
            let scroll = try XCTUnwrap(engine.scrollView)
            let rest = -scroll.contentInsets.top
            for _ in 0..<8 {
                for y: CGFloat in [0, 60, 700, 130, 30, 500, 0] {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: rest + y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    harness.host.layoutSubtreeIfNeeded()
                    let fragment = try XCTUnwrap(engine.layoutManager?.textLayoutFragment(for: engine.contentStorage.documentRange.location))
                    XCTAssertTrue(type(of: fragment) == NSTextLayoutFragment.self,
                                  "scrolling must use the opaque native fragment, without an alpha/invalidation path")
                }
            }
        }
    }

    func testAR04HeaderAppearsOnlyAfterTheLastTitleLineLeavesTheVisibleTop() {
        for bottom: CGFloat in [90, 70, 50, 40] {
            XCTAssertEqual(NoteTitleAccessories.headerProgress(titleBottom: bottom, visibleTop: 40), 0)
        }
        XCTAssertGreaterThan(NoteTitleAccessories.headerProgress(titleBottom: 30, visibleTop: 40), 0)
        XCTAssertEqual(NoteTitleAccessories.headerProgress(titleBottom: 0, visibleTop: 40), 1)
    }

    func testH13ScrollingTextCannotEnterTheBottomControlsBand() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        let note = try XCTUnwrap(harness.store.notes.first)
        XCTAssertTrue(harness.controller.open(noteID: note.id))
        spin(0.3)
        let scroll = try XCTUnwrap(harness.controller.active?.engine.scrollView)
        let frame = scroll.convert(scroll.bounds, to: harness.host)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: harness.host.bounds.size)
        let bottomBand = layout.chromeInsets.bottom + AtticControlSize.panelButton.height
        let clearance = harness.host.isFlipped ? harness.host.bounds.maxY - frame.maxY : frame.minY - harness.host.bounds.minY
        XCTAssertGreaterThanOrEqual(clearance, bottomBand - 0.5,
                                   "scrolling content must stay out from under All notes, Aa and New note")
    }

    func testH13LibraryAndHistoryAlsoKeepTextOutOfTheFooter() async throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        let note = try XCTUnwrap(harness.store.notes.first)
        XCTAssertTrue(harness.controller.open(noteID: note.id))
        XCTAssertTrue(harness.controller.showLibrary())
        spin(0.4)
        func check(_ scroll: NSScrollView) {
            let frame = scroll.convert(scroll.bounds, to: harness.host)
            let layout = PanelPageLayout(cornerSize: 52, panelSize: harness.host.bounds.size)
            let clearance = harness.host.isFlipped ? harness.host.bounds.maxY - frame.maxY : frame.minY - harness.host.bounds.minY
            XCTAssertGreaterThanOrEqual(clearance, layout.chromeInsets.bottom + AtticControlSize.panelButton.height - 0.5)
        }
        let library = try XCTUnwrap(descendants(of: harness.host).compactMap { $0 as? NSScrollView }.first { $0.bounds.height > 200 })
        check(library)
        XCTAssertTrue(harness.controller.open(noteID: note.id))
        XCTAssertTrue(harness.store.recordVersion(noteID: note.id, reason: .pause))
        let opened = await harness.controller.openHistoryDurably()
        XCTAssertTrue(opened)
        spin(0.4)
        let history = try XCTUnwrap(harness.controller.historyBrowser?.preview?.engine.scrollView)
        check(history)
    }

    func testH13FastScrollBackRestoresEveryTitleLine() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { store in
            _ = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks:
                [.text("H13 fast scrolling title across several lines")] + (0..<80).map { .text("Body line \($0)") }))
        }
        let note = try XCTUnwrap(harness.store.notes.first)
        XCTAssertTrue(harness.controller.open(noteID: note.id))
        spin(0.3)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let text = try XCTUnwrap(engine.textView)
        let scroll = try XCTUnwrap(engine.scrollView)
        text.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        let rest = -scroll.contentInsets.top
        func top() {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: rest))
            scroll.reflectScrolledClipView(scroll.contentView)
            harness.host.layoutSubtreeIfNeeded()
            spin(0.1)
        }
        top()
        let before = try XCTUnwrap(engine.titleLineRects())
        for _ in 0..<12 {
            for y: CGFloat in [800, 160, 30, 500, 70, 0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: rest + y))
                scroll.reflectScrolledClipView(scroll.contentView)
                harness.host.layoutSubtreeIfNeeded()
            }
            top()
            let after = try XCTUnwrap(engine.titleLineRects())
            XCTAssertEqual(after.first, before.first, "the title's geometry survives viewport recycling")
            XCTAssertEqual(after.last, before.last)
            let layout = try XCTUnwrap(engine.layoutManager)
            let fragment = try XCTUnwrap(layout.textLayoutFragment(for: engine.contentStorage.documentRange.location) )
            XCTAssertTrue(type(of: fragment) == NSTextLayoutFragment.self)
        }
    }

    /// Notes v2 tables, sheet 3's sample in the real page, off screen (drawn
    /// controls; no Liquid Glass): at rest, editing a cell (ring, grips,
    /// chips), and a wide table scrolled sideways; Light and Dark.
    func testTablesRenderAtRestEditingAndScrolled() throws {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for wide in [false, true] {
                let rows: [[String]] = wide
                    ? [["Pillar", "What happened", "Control that failed", "Source"],
                       ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"],
                       ["Integrity", "Systems encrypted by ransomware", "No MFA on the VPN account", "beerman2023review"],
                       ["Availability", "Pipeline shut down", "No IT/OT separation", "beerman2023review"]]
                    : [["Pillar", "What happened"], ["Confidentiality", "Data taken from the IT network"],
                       ["Integrity", "Systems encrypted by ransomware"], ["Availability", "Pipeline shut down"]]
                var heading = NoteBlock.text("Colonial Pipeline ransomware attack")
                heading.style = "heading"
                heading.level = 1
                var sources = NoteBlock.text("Sources:")
                sources.style = "heading"
                sources.level = 3
                var mono = [NoteBlock]()
                for line in ["@inproceedings{beerman2023review,", "  title={A review of colonial pipeline ransomware attack},",
                             "  author={Beerman, Jack and Berent, David and Falter, Zach"] {
                    var block = NoteBlock.text(line)
                    block.style = "mono"
                    mono.append(block)
                }
                let blocks: [NoteBlock] = [.text("CIA impact"), heading,
                    .text("The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication"),
                    .table(NoteTable(texts: rows)), sources] + mono
                let harness = try makeHarness(context: AtticDesignContext(mode: mode, controls: .craft)) { store in
                    guard case .success = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks)) else {
                        throw NSError(domain: "seed", code: 1)
                    }
                }
                let note = try XCTUnwrap(harness.store.notes.first)
                XCTAssertTrue(harness.controller.open(noteID: note.id))
                spin(0.4)
                harness.host.layoutSubtreeIfNeeded()
                spin()
                let engine = try XCTUnwrap(harness.controller.active?.engine)
                let scroll = try XCTUnwrap(engine.scrollView)
                // Notes v2 must keep the owner's overlay-scroller contract,
                // even if AppKit tries to restore the legacy system style.
                scroll.scrollerStyle = .legacy
                harness.host.layoutSubtreeIfNeeded()
                spin()
                XCTAssertEqual(scroll.scrollerStyle, .overlay)
                let table = try XCTUnwrap(engine.tableViews().first, "the table is hosted in the page")
                XCTAssertEqual(table.frame.width, 264, accuracy: 0.5)
                let suffix = mode == .dark ? "dark" : "light"
                if wide {
                    table.setScrollOffset(table.grid.columnX(1) + 60)
                    spin()
                    XCTAssertTrue(table.grid.scrolls)
                    write(harness.host, name: "tables-wide-\(suffix)")
                } else {
                    write(harness.host, name: "tables-rest-\(suffix)")
                    table.activate(NoteTable.Position(row: 2, column: 1), caret: .end)
                    spin(0.3)
                    harness.host.layoutSubtreeIfNeeded()
                    write(harness.host, name: "tables-editing-\(suffix)")
                }
                harness.window.close()
            }
        }
    }

    /// An idle note does no layout work, and typing costs one pass per key:
    /// the title's accessories never feed a layout loop.
    func testAnIdleNoteDoesNotLayOutAgainAndAgain() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        let pricing = try XCTUnwrap(harness.store.notes.first { $0.title.hasPrefix("Pricing") })
        XCTAssertTrue(harness.controller.open(noteID: pricing.id))
        spin(0.5)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        var passes = 0
        let original = textView.onLayout
        textView.onLayout = { passes += 1; original?() }
        spin(1.0)
        print("NOTES_IDLE_LAYOUT_PASSES=\(passes)")
        XCTAssertLessThanOrEqual(passes, 2, "an idle note settles")
        harness.window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        passes = 0
        let started = Date()
        for character in "typing into the body" {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            harness.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let elapsed = Date().timeIntervalSince(started)
        spin(0.5)
        print("NOTES_TYPING_20_KEYS_MS=\(Int(elapsed * 1000)) LAYOUT_PASSES=\(passes)")
        XCTAssertLessThan(passes, 80, "about one or two passes per key")
    }

    func testTheLibraryShowsGroupsAndTheEmptyDraftShowsNoMenu() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        XCTAssertTrue(harness.controller.requestNewNote())
        spin(0.3)
        let draft = try XCTUnwrap(harness.controller.active)
        XCTAssertTrue(draft.isUntouchedDraft)
        let menu = try XCTUnwrap(draft.engine.textView?.accessoryViews[1])
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

    func testTagSuggestionsFollowAHashtagInTheTitle() throws {
        let harness = try makeHarness(context: AtticDesignContext(controls: .craft)) { try Self.seedPricing($0) }
        let pricing = try XCTUnwrap(harness.store.notes.first { $0.title.hasPrefix("Pricing") })
        XCTAssertTrue(harness.controller.open(noteID: pricing.id))
        spin(0.4)
        let engine = try XCTUnwrap(harness.controller.active?.engine)
        let textView = try XCTUnwrap(engine.textView)
        harness.window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: engine.titleParagraphRange.length, length: 0))
        for character in " #pri" {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        spin(0.3)
        let list = textView.accessoryViews[2]
        // The suggestions follow the note's keyboard focus: without it this
        // test proves nothing, so it fails rather than passing silently.
        XCTAssertIdentical(harness.window.firstResponder, textView, "the note has the keyboard")
        guard harness.window.firstResponder === textView else { return }
        XCTAssertFalse(list.isHidden, "suggestions show under the hashtag")
        write(harness.host, name: "suggestions-light")
        // ↓ picks the first suggestion; Return takes it (no line break).
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(engine.tags.contains("print-shop"), "\(engine.tags)")
        XCTAssertEqual(engine.document().blocks.first?.text, "Pricing page for the October launch ")
        XCTAssertTrue(list.isHidden)
        // Typed without picking, Return takes the typed word and moves into
        // the body, as it does with no list showing.
        for character in "#pri" {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        spin(0.3)
        XCTAssertFalse(list.isHidden, "the list shows again for #pri")
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(engine.tags.contains("pri"), "\(engine.tags)")
        XCTAssertGreaterThan(textView.selectedRange().location, engine.titleParagraphRange.length,
                             "the caret is in the body")
        for character in "Body" {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertFalse(engine.lineText(at: 0).contains("Body"), "typing after Return never lands in the title")
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
