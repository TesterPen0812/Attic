import AppKit
import SwiftData
import SwiftUI
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

/// O14-11 (owner, 2026-10-14): the drag out of the panel is one motion (the
/// lifted card itself is the drag image, handed off without a gap), and a
/// cancelled drop springs back to its row instead of sliding and fading.
@MainActor
final class TasksDragOutCardTests: XCTestCase {
    private func exerciseG09Drag(_ hosted: Hosted, out: Bool) throws {
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.status == .todo })
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row.id)])
        var exported = false, lifted = false
        hosted.pointer.startDragOut = { _, _ in exported = true }
        func post(_ type: NSEvent.EventType, x: CGFloat = 200, y: CGFloat) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: hosted.height - y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                context: nil, eventNumber: 4, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApp.postEvent(event, atStart: false)
        }
        post(.leftMouseDown, y: frame.midY)
        for step in [CGFloat(6), 20, 40] { post(.leftMouseDragged, y: frame.midY + step) }
        let action = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                lifted = hosted.pointer.liftedCard.lift != nil
                if out {
                    for x in [CGFloat(330), 420, 520] { post(.leftMouseDragged, x: x, y: frame.midY + 40) }
                } else {
                    hosted.model.pageDidHide() // the panel's real cancellation route
                }
            }
        }
        let release = Timer(timeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated { post(.leftMouseUp, x: out ? 520 : 200, y: frame.midY + 40) }
        }
        RunLoop.main.add(action, forMode: .common)
        RunLoop.main.add(release, forMode: .common)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, release.isValid || action.isValid {
            Hosted.pumpEvents(limit: 8)
            hosted.spin(0.05)
        }
        hosted.spin(0.2)
        XCTAssertTrue(lifted, "the native row gesture really lifted a card")
        XCTAssertEqual(exported, out)
        XCTAssertNil(hosted.pointer.liftedCard.lift)
        hosted.pointer.startDragOut = nil
    }

    func testG09RemovedHostReleasesPointerLiftAndPageModelInEveryDragState() throws {
        for mode in ["none", "out", "cancelled"] {
            weak var pointer: TasksPointer?
            weak var lift: TasksLiftedCard?
            weak var model: TasksPageModel?
            weak var hostView: NSView?
            weak var hostWindow: NSWindow?
            try autoreleasepool {
                let hosted = try Hosted(height: 520)
                pointer = hosted.pointer; lift = hosted.pointer.liftedCard; model = hosted.model
                hostView = hosted.window.contentView; hostWindow = hosted.window
                XCTAssertNotNil(hosted.pointer.liftedCard.snapshot, "the layer installed its renderer")
                if mode != "none" { try exerciseG09Drag(hosted, out: mode == "out") }
                hosted.window.contentView = nil
                hosted.close()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            print("G09_RELEASE mode=\(mode) snapshot=\(lift?.snapshot != nil) view=\(hostView != nil) window=\(hostWindow != nil)")
            XCTAssertNil(pointer, mode)
            XCTAssertNil(lift, mode)
            XCTAssertNil(model, mode)
        }
    }

    func testG09ReattachedLivePageCanStillSnapshotAndDragOut() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.window.contentView = nil; hosted.close() }
        hosted.window.contentView = nil
        hosted.spin(0.1)
        XCTAssertNil(hosted.pointer.liftedCard.snapshot, "a detached layer releases its renderer")
        hosted.window.contentView = NSHostingView(rootView: hosted.page
            .atticDesign(AtticDesignContext(mode: .light)).frame(width: AtticLayout.panelSize.width, height: hosted.height))
        hosted.spin(0.5)
        let snapshot = try XCTUnwrap(hosted.pointer.liftedCard.snapshot)
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.status == .todo })
        let origin = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: row.id)])
        XCTAssertNotNil(snapshot(.init(id: row.id, tab: .now, origin: origin, y: origin.minY), 2))
        try exerciseG09Drag(hosted, out: true)
    }

    func testThePanelsCardStaysUntilTheSystemsImageIsUp() {
        let card = TasksLiftedCard()
        card.begin(id: UUID(), tab: .now, origin: CGRect(x: 8, y: 100, width: 300, height: 34))
        card.holdForHandOff()
        card.end()
        XCTAssertNotNil(card.lift, "held over the hand-off")
        card.releaseHandOff()
        XCTAssertNil(card.lift, "gone once the system's image is up")
        card.begin(id: UUID(), tab: .now, origin: .zero)
        card.end()
        XCTAssertNil(card.lift, "an ordinary end is immediate")
    }

    func testTheCardIsDrawnWithAndWithoutItsShadowAtItsOwnSize() throws {
        let images = try XCTUnwrap(TasksDragOut.Card.Images(card: Text("Call the plumber").frame(height: 34), width: 300,
                                                             environment: EnvironmentValues(), scale: 2))
        let room = TasksDragOut.Card.Images.room
        XCTAssertEqual(images.shadowed.size.width, 300 + room * 2, accuracy: 0.5)
        XCTAssertEqual(images.shadowed.size.height, 34 + room * 2, accuracy: 0.5)
        XCTAssertEqual(images.plain.size, images.shadowed.size)
    }

    func testACancelledDropSpringsHomeAndEndsOnce() {
        var settled = 0, ended = 0, handedOff = 0
        let images = TasksDragOut.Card.Images(card: Color.gray.frame(height: 34), width: 300, environment: EnvironmentValues(), scale: 2)!
        let home = CGRect(x: -5_000, y: -5_000, width: 340, height: 74)
        var card = TasksDragOut.Card(images: images, frame: CGRect(x: 0, y: 0, width: 340, height: 74), home: { home },
                                     reduceMotion: false, handOff: { handedOff += 1 })
        card.settled = { settled += 1 }
        let source = TasksDragOut.Source(ended: { ended += 1 })
        source.card = card
        source.imageSize = home.size
        TasksDragOut.Source.current = source
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        source.ended(at: CGPoint(x: -5_400, y: -5_300), operation: [])
        XCTAssertEqual(handedOff, 1)
        XCTAssertEqual(ended, 0, "still on its way home")
        XCTAssertTrue(NSApp.windows.contains { !windows.contains(ObjectIdentifier($0)) && $0.isVisible }, "the card is drawn over the screen")
        let deadline = Date().addingTimeInterval(3)
        while ended == 0, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(settled, 1, "it settles on its row")
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(NSApp.windows.contains { !windows.contains(ObjectIdentifier($0)) && $0.isVisible }, "and its window goes")
    }

    /// The item never vanishes for a frame at a cancelled drop: wherever the
    /// pointer rests, the same picture already lies under the system's
    /// image; a move withdraws it, and a successful drop takes it away.
    func testThePictureRestsUnderTheSystemsImageAndGoesOnAMoveOrADrop() {
        let images = TasksDragOut.Card.Images(card: Color.gray.frame(height: 34), width: 300, environment: EnvironmentValues(), scale: 2)!
        let drawn = CGRect(x: -5_200, y: -5_200, width: 200, height: 44)
        let dragReturn = AtticDragReturn(shadowed: images.shadowed, plain: images.plain, home: { CGRect(x: -5_000, y: -5_000, width: 340, height: 74) },
                                         level: .floating, reduceMotion: false)
        XCTAssertTrue(dragReturn.windowForTesting.isVisible, "ready, and clear, before the drop")
        dragReturn.moved(drawn: drawn)
        XCTAssertFalse(dragReturn.isResting, "not while the pointer moves")
        RunLoop.current.run(until: Date().addingTimeInterval(AtticDragReturn.restDelay + 0.05))
        XCTAssertTrue(dragReturn.isResting, "under the system's image once the pointer rests")
        dragReturn.moved(drawn: drawn.offsetBy(dx: 30, dy: 0))
        XCTAssertFalse(dragReturn.isResting, "withdrawn the moment it moves again")
        var done = 0
        dragReturn.ended(operation: .copy, drawn: drawn) { done += 1 }
        XCTAssertEqual(done, 1)
        XCTAssertFalse(dragReturn.windowForTesting.isVisible, "a drop takes the picture away at once")
    }
}

