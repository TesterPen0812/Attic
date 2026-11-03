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

    func testAuditA10CalendarPlusNamesTheEventItCreates() {
        XCTAssertEqual(PanelBottomBarLook.calendarPlus.label, "New event")
    }
}
