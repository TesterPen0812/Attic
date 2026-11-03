import AppKit
import SwiftUI
import XCTest
@testable import Attic

@MainActor
final class UXAuditFixTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        super.tearDown()
    }

    private func find(_ id: String, in element: AnyObject, depth: Int = 0) -> AnyObject? {
        guard depth < 50 else { return nil }
        if (element.accessibilityIdentifier?() ?? nil) == id { return element }
        for child in (element.accessibilityChildren?() ?? nil) ?? [] {
            if let found = find(id, in: child as AnyObject, depth: depth + 1) { return found }
        }
        return nil
    }

    func testAuditA8HistoryRestoreClearsTheSharedPlusAt320Points() async throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previousAX, forAttribute: enhanced) }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "AuditHistory")))
        await controller.startAndWait()
        let engine = try XCTUnwrap(controller.active?.engine)
        engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Title\nWriting"), name: "Typing")
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        let browser = try XCTUnwrap(controller.historyBrowser)
        let size = CGSize(width: 320, height: 460)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let host = NSHostingView(rootView: NoteHistoryPage(controller: controller, browser: browser, layout: layout)
            .atticDesign(AtticDesignContext(mode: .light)).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { controller.closeHistory(); window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let restore = try XCTUnwrap(find("notes-history-restore", in: host))
        let frame = restore.accessibilityFrame?() ?? .zero
        let plusLeft = window.convertToScreen(CGRect(x: size.width - PanelSharedBottomBar.plusInsets(layout: layout).trailing
            - AtticControlSize.panelButton.height, y: 0, width: 0, height: 0)).minX
        XCTAssertLessThanOrEqual(frame.maxX + 6, plusLeft, "Restore and the shared + have separate space")
    }

    func testAuditA3FailureNoticeFitsTheWholeMessage() {
        let message = "This item changed elsewhere. Your edit was not saved. Check the latest version before trying again."
        let host = NSHostingView(rootView: AtticNotice(message: message, actionTitle: "Retry", onAction: {}, onDismiss: {})
            .atticDesign(AtticDesignContext(mode: .light)).frame(width: 260))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 60, "a narrow failure notice has room for the complete sentence")
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func testAuditA5SearchAndTagsTakeTheKeyboardFromTheBoard() throws {
        try requireKeyWindowTests()
        AtticDraw.enabledOverride = true
        defer { AtticDraw.enabledOverride = nil }
        let store = DrawInMemoryStore()
        let model = DrawPageModel(store: store)
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 460)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
        let window = KeyPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: DrawPageHost(model: model, uiState: state, layout: layout)
            .atticDesign(AtticDesignContext(mode: .light)).frame(width: size.width, height: size.height))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        model.openSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let searchEditor = window.firstResponder as? NSTextView
        XCTAssertNotNil(searchEditor, "opening Search gives its field the keyboard")
        if let searchEditor {
            searchEditor.insertText("plan", replacementRange: searchEditor.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(model.search.query, "plan")
            searchEditor.cancelOperation(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertFalse(model.isSearching)
        }
        model.closeSearch()
        model.openFilter()
        model.library.perform(.tags)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let tagEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let field = try XCTUnwrap(tagEditor.delegate as? NSTextField)
        XCTAssertNotEqual(field.accessibilityIdentifier(), "draw-library-search", "Tags takes over from the canvas filter")
        XCTAssertTrue(field.placeholderString?.localizedCaseInsensitiveContains("tag") == true)
    }

    private func withHost<Content: View>(_ content: Content, size: CGSize = CGSize(width: 320, height: 460),
                                         check: (NSView) throws -> Void) rethrows {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let host = NSHostingView(rootView: content.atticDesign(AtticDesignContext(mode: .light))
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try check(host)
    }

    func testAuditA10NotesGroupCountsNotes() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        _ = try store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Audit note")])).get()
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "AuditAXNotes")))
        let model = NotesLibraryModel(search: { _ in [] }, store: store)
        model.layout = .list
        let view = NotesLibraryView(model: model, controller: controller, store: store,
            layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 320, height: 460)), bottomClearance: 0,
            searchFocused: .constant(false), searchOpen: .constant(false), rowCommands: { _ in [] }, libraryCommands: { [] },
            onOpen: { _ in }, onDelete: { _ in }, onBack: {})
        try withHost(view) { host in
            let group = try XCTUnwrap(find("notes-library-group-today", in: host))
            let value = (group as? NSAccessibilityElement)?.accessibilityValue() as? String
                ?? (group as? NSView)?.accessibilityValue() as? String
            XCTAssertEqual(value, "1 note")
        }
    }

    func testAuditA10TableButtonsKeepTheirIndividualNames() throws {
        let model = NoteFormatModel()
        var snapshot = NoteFormatSnapshot()
        snapshot.table = NoteTableToolsState(headerRow: true, rows: 3, columns: 2)
        model.setSnapshot(snapshot)
        try withHost(NoteFormatRowView(model: model, onClose: {}), size: CGSize(width: 320, height: 40)) { host in
            for tool in NoteTableTool.allCases {
                let button = try XCTUnwrap(find("notes-format-row-table-\(tool)", in: host))
                XCTAssertEqual(button.accessibilityLabel?() ?? nil, tool.title)
            }
            let close = try XCTUnwrap(find("notes-format-row-close", in: host))
            XCTAssertEqual(close.accessibilityLabel?() ?? nil, "Close Format")
        }
    }

    func testAuditA10CalendarPlusNamesTheEventItCreates() {
        XCTAssertEqual(PanelBottomBarLook.calendarPlus.label, "New event")
    }
}
