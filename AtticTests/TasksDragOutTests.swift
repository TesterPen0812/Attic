import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Part 2 B (owner-approved, 2026-10-01): tasks dragged out of the panel
/// drop into other apps as text, Markdown and RTF (a copy; nothing moves),
/// with the same serializer as Copy (⌘C).
@MainActor
final class TasksDragOutTests: XCTestCase {
    private let launch = TasksTextExport.Item(
        title: "Finalize launch checklist", due: "Today", tags: ["launch"], priority: "High priority",
        subtasks: [.init(title: "Freeze strings", isDone: true), .init(title: "Write release notes", isDone: false)]
    )

    func testTheSerializerWritesTitleDetailsAndSubtasks() throws {
        let export = TasksTextExport(items: [launch, .init(title: "Call the plumber")])
        XCTAssertEqual(export.plain, """
        Finalize launch checklist
        Today · #launch · High priority
        - [x] Freeze strings
        - [ ] Write release notes

        Call the plumber
        """)
        XCTAssertEqual(export.markdown, """
        - [ ] **Finalize launch checklist** · Today · #launch · High priority
          - [x] Freeze strings
          - [ ] Write release notes
        - [ ] **Call the plumber**
        """)
        XCTAssertEqual(export.titles, "Finalize launch checklist\nCall the plumber")
        let rtf = try XCTUnwrap(export.rtf)
        let read = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(read.string.contains("Finalize launch checklist\nToday · #launch · High priority\n☑ Freeze strings"))
    }

    func testTitlesOnlyStayOnePerLine() {
        let export = TasksTextExport(items: [.init(title: "A"), .init(title: "B *bold*")])
        XCTAssertEqual(export.plain, "A\nB *bold*")
        XCTAssertEqual(export.markdown, "- [ ] **A**\n- [ ] **B \\*bold\\***", "Markdown's own characters are escaped")
    }

    /// ⌘C uses the same serializer: its plain text stays the titles (the add
    /// bar's round trip), its Markdown and RTF carry the full text.
    func testCopyUsesTheSameSerializer() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Finalize launch checklist" })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AtticDragOutTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(model.copy([row.id], to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Finalize launch checklist")
        let markdown = try XCTUnwrap(pasteboard.string(forType: TasksTextExport.markdownType))
        XCTAssertTrue(markdown.hasPrefix("- [ ] **Finalize launch checklist** · "), markdown)
        XCTAssertTrue(markdown.contains("#launch") && markdown.contains("High priority") && markdown.contains("  - [x] Freeze strings"))
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        let export = try XCTUnwrap(model.export([row.id]))
        XCTAssertEqual(export.dragItem().string(forType: .string), export.plain, "a drag carries the full text")
    }

    /// A reorder that leaves the panel's window becomes a drag out: the
    /// reorder ends with nothing moved, and the dragged task (or the whole
    /// selection it belongs to) goes out as text.
    func testLeavingTheWindowSwitchesTheReorderToADragOut() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1)
        var exported: TasksTextExport?
        hosted.pointer.startDragOut = { export, _ in exported = export }
        let rows = hosted.model.rows(for: .now).filter { $0.status == .todo }
        let first = try XCTUnwrap(rows.first), second = try XCTUnwrap(rows.dropFirst().first)
        hosted.model.selectOnly(first.id)
        hosted.model.extendSelection(to: second.id, visible: hosted.model.rows(for: .now).map(\.id), from: first.id)
        hosted.spin(0.2)
        let before = hosted.model.rows(for: .now).map(\.id)
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: first.id)])
        let window = hosted.window
        func post(_ type: NSEvent.EventType, x: CGFloat = 200, y: CGFloat) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: hosted.height - y), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 4, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
        }
        post(.leftMouseDown, y: frame.midY)
        for step in [CGFloat(6), 20, 40] { post(.leftMouseDragged, y: frame.midY + step) }
        // Out past the window's right edge.
        for x in [CGFloat(330), 420, 520] { post(.leftMouseDragged, x: x, y: frame.midY + 40) }
        let release = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated { post(.leftMouseUp, x: 520, y: frame.midY + 40) }
        }
        RunLoop.main.add(release, forMode: .common)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, release.isValid || exported == nil {
            Hosted.pumpEvents(limit: 8)
            hosted.spin(0.05)
        }
        hosted.spin(0.5)
        let export = try XCTUnwrap(exported, "the drag went out")
        XCTAssertEqual(export.items.map(\.title), [first.model.title, second.model.title], "the whole selection")
        XCTAssertEqual(hosted.model.rows(for: .now).map(\.id), before, "nothing moved")
        XCTAssertNil(hosted.pointer.liftedCard.lift, "the lifted card is gone")
    }
}
