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
        let searchEditor = try XCTUnwrap(window.firstResponder as? NSTextView, "opening Search gives its field the keyboard")
        searchEditor.insertText("plan", replacementRange: searchEditor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(model.search.query, "plan")
        searchEditor.cancelOperation(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(model.isSearching)
        model.openFilter()
        model.library.perform(.tags)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let tagEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let field = try XCTUnwrap(tagEditor.delegate as? NSTextField)
        XCTAssertNotEqual(field.accessibilityIdentifier(), "draw-library-search", "Tags takes over from the canvas filter")
        XCTAssertTrue(field.placeholderString?.localizedCaseInsensitiveContains("tag") == true)
    }

    func testAuditA10CalendarPlusNamesTheEventItCreates() {
        XCTAssertEqual(PanelBottomBarLook.calendarPlus.label, "New event")
    }
}
