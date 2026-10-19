import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
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
        // Posting a mouse event is not its delivery. A remounted host can
        // return from native tracking after both timers have fired, leaving
        // their outside motion and release queued for the next event turn.
        while Date() < deadline, release.isValid || action.isValid
                || hosted.pointer.liftedCard.lift != nil || (out && !exported) {
            autoreleasepool {
                // Let the drag timer observe each delivered position before
                // the next queued event (especially mouse-up) is dispatched.
                Hosted.pumpEvents(limit: 1)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        Hosted.pumpEvents(limit: 8)
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
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, pointer != nil || lift != nil || model != nil || hostView != nil || hostWindow != nil {
                autoreleasepool {
                    Hosted.pumpEvents(limit: 8)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
            }
            print("G09_RELEASE mode=\(mode) snapshot=\(lift?.snapshot != nil) view=\(hostView != nil) window=\(hostWindow != nil)")
            XCTAssertNil(pointer, mode)
            XCTAssertNil(lift, mode)
            XCTAssertNil(model, mode)
        }
    }

    func testG09ReattachedLivePageCanStillSnapshotAndDragOut() throws {
        weak var originalView: NSView?
        let hosted = try autoreleasepool {
            let hosted = try Hosted(height: 520)
            originalView = hosted.window.contentView
            hosted.window.contentView = nil
            return hosted
        }
        defer { autoreleasepool { hosted.window.contentView = nil; hosted.close() } }
        let deadline = Date().addingTimeInterval(3)
        while originalView != nil, Date() < deadline {
            autoreleasepool {
                Hosted.pumpEvents(limit: 8)
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
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
        source.grip = AtticDragGrip(offset: .zero, size: home.size)
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

    /// V-09: the picture is the drag's only one. It shows at once where it
    /// is drawn, follows every move without a gap (so it never vanishes for
    /// a frame at a cancelled drop), and a successful drop takes it away.
    func testThePictureFollowsThePointerAndGoesOnADrop() throws {
        let images = TasksDragOut.Card.Images(card: Color.gray.frame(height: 34), width: 300, environment: EnvironmentValues(), scale: 2)!
        let drawn = CGRect(x: -5_200, y: -5_200, width: 200, height: 44)
        let dragReturn = AtticDragReturn(shadowed: images.shadowed, plain: images.plain, home: { CGRect(x: -5_000, y: -5_000, width: 340, height: 74) },
                                         level: .floating, reduceMotion: false)
        XCTAssertTrue(dragReturn.windowForTesting.isVisible, "ready, and clear, before the drop")
        XCTAssertFalse(dragReturn.isShown)
        dragReturn.moved(drawn: drawn)
        XCTAssertTrue(dragReturn.isShown, "shown at once, where it is drawn")
        let layer = try XCTUnwrap(dragReturn.windowForTesting.contentView?.layer?.sublayers?.last)
        let origin = dragReturn.windowForTesting.frame.origin
        XCTAssertEqual(layer.position, CGPoint(x: drawn.minX - origin.x, y: drawn.minY - origin.y))
        dragReturn.moved(drawn: drawn.offsetBy(dx: 30, dy: 0))
        XCTAssertTrue(dragReturn.isShown, "still shown as it moves")
        XCTAssertEqual(layer.position.x, drawn.minX + 30 - origin.x, "it follows the pointer")
        XCTAssertTrue((layer.animationKeys() ?? []).isEmpty, "with no animation of its own")
        var done = 0
        dragReturn.ended(operation: .copy, drawn: drawn) { done += 1 }
        XCTAssertEqual(done, 1)
        XCTAssertFalse(dragReturn.windowForTesting.isVisible, "a drop takes the picture away at once")
    }
}


/// Round O2 (owner feedback 2026-10-17, O17-12/13/15/16): a cancelled card
/// starts home from exactly where it was let go, a dropped file lands in
/// its task, a dragged task takes its files along, and a file leaves on
/// its own.
@MainActor
final class TasksDragO2Tests: XCTestCase {
    private func images() -> TasksDragOut.Card.Images {
        TasksDragOut.Card.Images(card: Color.gray.frame(height: 34), width: 300, environment: EnvironmentValues(), scale: 2)!
    }

    // MARK: O17-12, the cancelled drag's start

    func testTheGripPlacesThePictureWhereItWasLetGoOnScreen() {
        let image = CGRect(x: 1_210, y: 640, width: 340, height: 74)
        let grip = AtticDragGrip(image: image, pointer: CGPoint(x: 1_300, y: 690))
        XCTAssertEqual(grip.frame(at: CGPoint(x: 1_300, y: 690)), image, "at the press, the picture is where it lay")
        let release = CGPoint(x: 220, y: 1_040)
        let start = grip.frame(at: release)
        XCTAssertEqual(start.size, image.size)
        XCTAssertEqual(start.minX - release.x, image.minX - 1_300)
        XCTAssertEqual(start.minY - release.y, image.minY - 690)
    }

    /// The card's frame is in the page's flipped view; the pointer arrives
    /// in the window's space and on screen. Whichever space the release is
    /// read in, the start is the card moved by exactly the pointer's travel.
    func testTheStartFollowsThePointerInEverySpace() throws {
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -3_000, width: 400, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let page = Flipped(frame: CGRect(x: 12, y: 30, width: 380, height: 460))
        window.contentView?.addSubview(page)
        let card = CGRect(x: -20, y: 100, width: 340, height: 74)
        let pressInPage = CGPoint(x: 150, y: 137)
        let imageOnScreen = window.convertToScreen(page.convert(card, to: nil))
        let pressOnScreen = window.convertPoint(toScreen: page.convert(pressInPage, to: nil))
        let grip = AtticDragGrip(image: imageOnScreen, pointer: pressOnScreen)
        // Released 60 pt right and 200 pt down the page.
        let releaseInPage = CGPoint(x: pressInPage.x + 60, y: pressInPage.y + 200)
        let releaseOnScreen = window.convertPoint(toScreen: page.convert(releaseInPage, to: nil))
        let start = grip.frame(at: releaseOnScreen)
        let expected = window.convertToScreen(page.convert(card.offsetBy(dx: 60, dy: 200), to: nil))
        XCTAssertEqual(start.minX, expected.minX, accuracy: 0.001)
        XCTAssertEqual(start.minY, expected.minY, accuracy: 0.001)
        XCTAssertEqual(start.size, expected.size)
        // Back in the page, the start is the card where the pointer let go.
        let back = page.convert(window.convertFromScreen(start), from: nil)
        XCTAssertEqual(back.minX, card.minX + 60, accuracy: 0.001)
        XCTAssertEqual(back.minY, card.minY + 200, accuracy: 0.001)
    }

    /// The corner jump (O17-12): the session's own frame for its image at
    /// the end is not where it was drawn. A cancelled card starts home from
    /// the release point and its grip, whatever the session reports, and
    /// the picture that springs lies exactly there on screen.
    func testACancelledCardStartsHomeFromTheReleasePointNotTheSessionsFrame() {
        let home = CGRect(x: -5_000, y: -5_000, width: 340, height: 74)
        var settled = 0
        let card = TasksDragOut.Card(images: images(), frame: CGRect(x: 0, y: 0, width: 340, height: 74), home: { home },
                                     reduceMotion: false, handOff: {}, settled: { settled += 1 })
        let source = TasksDragOut.Source(ended: {})
        source.card = card
        source.grip = AtticDragGrip(image: home, pointer: CGPoint(x: home.minX + 150, y: home.minY + 37))
        TasksDragOut.Source.current = source
        defer { TasksDragOut.Source.current = nil }
        let release = CGPoint(x: -5_600, y: -5_420)
        let corner = CGRect(x: 0, y: 0, width: 340, height: 74)
        source.ended(at: release, operation: [], reported: corner)
        let expected = CGRect(x: release.x - 150, y: release.y - 37, width: 340, height: 74)
        XCTAssertEqual(TasksDragOut.Probe.shared.lastStart, expected, "from where it was let go")
        XCTAssertEqual(TasksDragOut.Probe.shared.lastReported, corner, "the session's frame is kept as evidence only")
        XCTAssertEqual(source.dragReturnForTesting?.startOnScreen, expected, "the springing picture lies there on screen")
        XCTAssertEqual(settled, 0, "the row's place stays empty until the card lands")
        let deadline = Date().addingTimeInterval(3)
        while settled == 0, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(settled, 1, "then the row takes its place, once")
    }

    // MARK: O17-13, a dropped file lands

    func testADroppedPictureSettlesIntoTheSlotKeepingItsShape() {
        let slot = CGRect(x: 100, y: 50, width: 14, height: 14)
        XCTAssertEqual(AtticDropLanding.frame(for: CGSize(width: 140, height: 70), in: slot),
                       CGRect(x: 100, y: 53.5, width: 14, height: 7))
        XCTAssertEqual(AtticDropLanding.frame(for: CGSize(width: 64, height: 64), in: slot), slot)
        XCTAssertEqual(AtticDropLanding.frame(for: .zero, in: slot), slot)
    }

    func testTheSlotIsTheFilesListsIconColumn() {
        let row = CGRect(x: 8, y: 200, width: 360, height: 34)
        let closed = TasksPage.dropLandingSlot(rowFrame: row, filesExpanded: false)
        XCTAssertEqual(closed.minX, 8 + AtticLayout.textX)
        XCTAssertEqual(closed.size, CGSize(width: AtticQuietActionMetrics.iconSlot, height: AtticQuietActionMetrics.iconSlot))
        XCTAssertTrue(row.contains(closed), "closed, it lands in the row itself")
        // Open: two files, then "Attach file…", where the new file goes.
        let open = CGRect(x: 8, y: 200, width: 360, height: 34 + 3 * AtticLayout.subtaskPitch + AtticQuickLookMetrics.bottomPadding)
        let slot = TasksPage.dropLandingSlot(rowFrame: open, filesExpanded: true)
        let attachLine = open.maxY - AtticQuickLookMetrics.bottomPadding - AtticLayout.subtaskPitch
        XCTAssertEqual(slot.midY, attachLine + AtticLayout.subtaskPitch / 2, accuracy: 0.001)
    }

    func testTheHostAsksTheShownSourceInItsWindowAndConvertsTheSlot() {
        final class Source: AtticDropLandingSource {
            weak var landingView: NSView?
            var asked: CGPoint?
            func landingSlot(at point: CGPoint) -> CGRect? {
                asked = point
                return CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            }
        }
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -3_000, width: 400, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        window.contentView = host
        let page = Flipped(frame: CGRect(x: 10, y: 20, width: 380, height: 460))
        host.addSubview(page)
        let source = Source()
        source.landingView = page
        AtticDropLanding.register(source)
        let windowPoint = CGPoint(x: 110, y: 300)
        let slot = AtticDropLanding.slot(at: windowPoint, in: host)
        XCTAssertEqual(source.asked, page.convert(windowPoint, from: nil))
        XCTAssertEqual(slot?.midX ?? 0, windowPoint.x, accuracy: 0.001)
        XCTAssertEqual(slot?.midY ?? 0, windowPoint.y, accuracy: 0.001)
        page.isHidden = true
        XCTAssertNil(AtticDropLanding.slot(at: windowPoint, in: host), "a hidden page takes nothing")
        page.isHidden = false
        let other = NSView()
        XCTAssertNil(AtticDropLanding.slot(at: windowPoint, in: other), "another window asks nobody here")
    }

    /// The panel's host: a drop SwiftUI takes over a place that knows where
    /// it lands animates there; one it refuses is left to the system.
    func testTheHostLandsAnAcceptedDropAndLeavesARefusedOne() throws {
        AtticHostDragHooks.install()
        for name in ["prepareForDragOperation:", "performDragOperation:"] {
            let selector = NSSelectorFromString(name)
            XCTAssertNotNil(class_getInstanceMethod(AtticPanelHostingView.self, selector))
            XCTAssertNotEqual(class_getMethodImplementation(AtticPanelHostingView.self, selector),
                              class_getMethodImplementation(class_getSuperclass(AtticPanelHostingView.self), selector),
                              "\(name) runs after SwiftUI's own")
        }
        final class Source: AtticDropLandingSource {
            weak var landingView: NSView?
            func landingSlot(at point: CGPoint) -> CGRect? { CGRect(x: 40, y: 60, width: 14, height: 14) }
        }
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -3_000, width: 400, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        window.contentView = host
        let page = NSView(frame: host.bounds)
        host.addSubview(page)
        let source = Source()
        source.landingView = page
        AtticDropLanding.register(source)
        let info = FakeDraggingInfo(window: window, location: CGPoint(x: 100, y: 100),
                                    items: [CGRect(x: 80, y: 80, width: 128, height: 64)])
        let slot = AtticDropLanding.prepare(info, accepted: true, in: host)
        XCTAssertTrue(info.animatesToDestination)
        AtticDropLanding.perform(info, accepted: true, slot: slot, in: host)
        let landed = host.convert(page.convert(CGRect(x: 40, y: 60, width: 14, height: 14), to: nil), from: nil)
        XCTAssertEqual(info.items[0].draggingFrame, AtticDropLanding.frame(for: CGSize(width: 128, height: 64), in: landed))

        let refused = FakeDraggingInfo(window: window, location: CGPoint(x: 100, y: 100),
                                       items: [CGRect(x: 80, y: 80, width: 128, height: 64)])
        let none = AtticDropLanding.prepare(refused, accepted: false, in: host)
        XCTAssertNil(none)
        AtticDropLanding.perform(refused, accepted: false, slot: none, in: host)
        XCTAssertFalse(refused.animatesToDestination)
        XCTAssertEqual(refused.items[0].draggingFrame, CGRect(x: 80, y: 80, width: 128, height: 64))
    }

    // MARK: O17-15, a task's files go with it

    private func pngFile(in root: URL, named name: String = "Receipt.png") throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testADraggedTaskCarriesItsFilesAsPromisesBesideItsText() async throws {
        let root = ownedTemporaryDirectory(prefix: "TasksDragO2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container, taskImageFiles: files)
        let task = try XCTUnwrap(store.create(title: "Expense the trip"))
        let notes = root.appendingPathComponent("Notes.txt")
        try Data("Hotel and train".utf8).write(to: notes)
        let attached = await store.attachFiles([try pngFile(in: root), notes], to: task.id)
        XCTAssertTrue(attached)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let export = try XCTUnwrap(model.export([task.id]))
        XCTAssertEqual(export.items.first?.files.map(\.filename), ["Receipt.png", "Notes.txt"])
        XCTAssertFalse(export.plain.contains("Receipt"), "the text itself does not name them")

        let frame = CGRect(x: 0, y: 0, width: 340, height: 74)
        let items = TasksDragOut.attachmentItems(for: export, files: files, frame: frame)
        XCTAssertEqual(items.count, 2)
        let promises = items.compactMap { $0.item as? TaskAttachmentFilePromise }
        XCTAssertEqual(promises.map(\.fileType), [UTType.png.identifier, UTType.plainText.identifier])
        XCTAssertTrue(promises.allSatisfy { $0.delegate === $0 }, "each keeps its own delegate for the drag's life")
        XCTAssertTrue(items.allSatisfy { ($0.imageComponents ?? []).allSatisfy { $0.contents == nil } }, "the card alone is drawn")
        XCTAssertEqual(promises[0].filePromiseProvider(promises[0], fileNameForType: UTType.png.identifier), "Receipt.png")

        // On a pasteboard they are promised files under their own types.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AtticDragO2-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([export.dragItem()] + promises))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 3)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), export.plain)
        let promised = (pasteboard.pasteboardItems ?? []).dropFirst().map { $0.types.map(\.rawValue) }
        XCTAssertTrue(promised.allSatisfy { $0.contains("com.apple.NSFilePromiseItemMetaData") }, "\(promised)")

        // A receiver gets its own copy, byte for byte.
        let destination = root.appendingPathComponent("Dropped", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for promise in promises {
            let url = destination.appendingPathComponent(promise.reference.filename)
            try await TaskAttachmentFilePromise.write(promise.reference, from: files, to: url)
            let original = try await XCTUnwrapAsync(try await files.verifiedURL(for: promise.reference))
            XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: original))
            XCTAssertNotEqual(url.standardizedFileURL, original.standardizedFileURL, "never the private copy in place")
        }
    }

    /// The complete native payload, including the task text, is receivable as files.
    func testFinderCanReceiveEveryTaskDragItemAsAFile() throws {
        let references = [("Receipt.png", UTType.png), ("Notes.txt", UTType.plainText)].map { name, type in
            TaskImageReference(id: UUID(), filename: name, digest: "unused", contentTypeIdentifier: type.identifier, byteCount: 1)
        }
        let export = TasksTextExport(items: [.init(title: "Expense the trip", files: references)])
        let attachments = TasksDragOut.attachmentItems(for: export, files: .shared, frame: CGRect(x: 0, y: 0, width: 340, height: 74))
        let writers: [NSPasteboardWriting] = [export.dragWriter()] + attachments.compactMap { $0.item as? NSPasteboardWriting }
        let pasteboard = NSPasteboard(name: .init("AtticDragF2-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(writers))
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.string(forType: .string), export.plain)
        XCTAssertEqual(items.first?.string(forType: TasksTextExport.markdownType), export.markdown)
        XCTAssertNotNil(items.first?.data(forType: .rtf))
        XCTAssertTrue(items.allSatisfy { $0.types.contains(.init("com.apple.NSFilePromiseItemMetaData")) },
                      "Finder must be able to receive the task text as a file alongside every attachment")
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        XCTAssertEqual(receivers.flatMap(\.fileTypes), [UTType.utf8PlainText.identifier, UTType.png.identifier, UTType.plainText.identifier])
        XCTAssertEqual(writers.compactMap { $0 as? NSFilePromiseProvider }.count, 3)
    }

    func testFinderGetsTaskTextAndTwoAttachmentsThroughThePromiseDelegates() async {
        do {
            let root = ownedTemporaryDirectory(prefix: "TasksDragF2")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
            let notes = root.appendingPathComponent("Notes.txt")
            try Data("Hotel and train".utf8).write(to: notes)
            let references = try await files.importAttachments([try pngFile(in: root), notes], existing: [])
            let export = TasksTextExport(items: [.init(title: "Expense the trip", due: "Today",
                subtasks: [.init(title: "Submit receipts", isDone: false)], files: references)])
            let attachments = TasksDragOut.attachmentItems(for: export, files: files, frame: CGRect(x: 0, y: 0, width: 340, height: 74))
            let writers: [NSPasteboardWriting] = [export.dragWriter()] + attachments.compactMap { $0.item as? NSPasteboardWriting }
            let promises = writers.compactMap { $0 as? NSFilePromiseProvider }
            XCTAssertEqual(promises.count, 3)
            guard promises.count == 3 else { return }
            let destination = root.appendingPathComponent("Dropped", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var delivered: [URL] = []
            for promise in promises {
                let delegate = try XCTUnwrap(promise.delegate)
                let name = delegate.filePromiseProvider(promise, fileNameForType: promise.fileType)
                let url = destination.appendingPathComponent(name)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.filePromiseProvider(promise, writePromiseTo: url) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                delivered.append(url)
            }
            XCTAssertEqual(delivered.map(\.lastPathComponent), ["Expense the trip.txt", "Receipt.png", "Notes.txt"])
            XCTAssertEqual(try String(contentsOf: delivered[0], encoding: .utf8), export.plain)
            for (reference, url) in zip(references, delivered.dropFirst()) {
                let original = try await XCTUnwrapAsync(try await files.verifiedURL(for: reference))
                XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: original))
                XCTAssertNotEqual(url.standardizedFileURL, original.standardizedFileURL)
            }
        } catch {
            XCTFail("Promise delivery failed: \(error)")
        }
    }

    func testPromisedTaskTextWritesLongTitlesWithoutTruncatingTheirContents() async {
        do {
            let root = ownedTemporaryDirectory(prefix: "TasksDragF2Names")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for title in [String(repeating: "A", count: 600), String(repeating: "🗂️", count: 300),
                          "e" + String(repeating: "\u{0301}", count: 200)] {
                let export = TasksTextExport(items: [.init(title: title)])
                let promise = try XCTUnwrap(export.dragWriter() as? NSFilePromiseProvider)
                let delegate = try XCTUnwrap(promise.delegate)
                let name = delegate.filePromiseProvider(promise, fileNameForType: promise.fileType)
                XCTAssertLessThanOrEqual(name.utf8.count, 255, "A task title is not bounded like an existing filesystem filename")
                XCTAssertFalse(name.hasPrefix("."), "An oversized grapheme must not leave only a hidden .txt filename")
                let url = root.appendingPathComponent(name)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    delegate.filePromiseProvider(promise, writePromiseTo: url) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), export.plain)
            }
        } catch {
            XCTFail("Long-title promise could not be written: \(error)")
        }
    }

    /// Within Attic a task is moved, not copied: its files stay its own.
    func testMovingATaskKeepsItsFiles() async throws {
        let root = ownedTemporaryDirectory(prefix: "TasksDragO2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = TaskImageFiles(rootURL: root.appendingPathComponent("storage"))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container, taskImageFiles: files)
        let first = try XCTUnwrap(store.create(title: "First"))
        _ = try XCTUnwrap(store.create(title: "Second"))
        let attached = await store.attachFiles([try pngFile(in: root)], to: first.id)
        XCTAssertTrue(attached)
        let before = try XCTUnwrap(store.listedTask(withID: first.id)).attachments
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let group = model.rows(for: .now).map(\.id)
        let index = try XCTUnwrap(group.firstIndex(of: first.id))
        XCTAssertTrue(model.move(first.id, toGroupIndex: index == 0 ? 1 : 0).isApplied)
        XCTAssertNotEqual(model.rows(for: .now).map(\.id), group, "it moved")
        XCTAssertEqual(store.listedTask(withID: first.id)?.attachments, before)
        let verified = try await files.verifiedURL(for: before[0])
        XCTAssertNotNil(verified)
    }

    // MARK: O17-16, a file leaves on its own

    func testAFileLeavesAsItselfWithItsOwnPicture() throws {
        let reference = TaskImageReference(id: UUID(), filename: "Floor plan.pdf", digest: "d1",
                                           contentTypeIdentifier: UTType.pdf.identifier, byteCount: 2_048)
        let provider = TaskAttachmentDragItem(reference: reference, files: TaskImageFiles(rootURL: ownedTemporaryDirectory(prefix: "TasksDragO2")))
            .itemProvider()
        XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.pdf.identifier, TaskDropContent.attachmentCardType.identifier])
        XCTAssertEqual(provider.suggestedName, "Floor plan")
        // Its picture: the kind's icon and the name, nothing of the row.
        let renderer = ImageRenderer(content: TaskFileDragPreview(file: reference))
        renderer.scale = 2
        let picture = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(picture.size.height, TaskFileDragPreview.iconSide + 10, accuracy: 0.5)
        XCTAssertLessThanOrEqual(picture.size.width, 6 + TaskFileDragPreview.iconSide + 8 + 220 + 12 + 0.5)

        // An image shows the thumbnail its row already drew.
        let image = TaskImageReference(id: UUID(), filename: "Sketch.png", digest: "d2-\(UUID().uuidString)",
                                       contentTypeIdentifier: UTType.png.identifier, byteCount: 512)
        let thumbnail = NSImage(size: CGSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        TaskThumbnailMemory.remember(thumbnail, for: image.digest)
        XCTAssertTrue(TaskThumbnailMemory.image(for: image.digest) === thumbnail)
        XCTAssertNotNil(ImageRenderer(content: TaskFileDragPreview(file: image)).nsImage)

        // Evidence renders for the round's report, on request only.
        if let directory = ProcessInfo.processInfo.environment["ATTIC_O2_RENDERS"] {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                for (kind, file) in [("pdf", reference), ("image", image)] {
                    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
                    var data: Data?
                    appearance.performAsCurrentDrawingAppearance {
                        let renderer = ImageRenderer(content: TaskFileDragPreview(file: file).padding(12)
                            .background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme))
                        renderer.scale = 2
                        data = renderer.cgImage.map { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) } ?? nil
                    }
                    try XCTUnwrap(data).write(to: folder.appendingPathComponent("file-drag-\(kind)-\(name).png"))
                }
            }
        }
    }
}

/// A drop as AppKit hands it to a destination, for the host's landing.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let window: NSWindow
    let location: CGPoint
    let items: [NSDraggingItem]
    var animatesToDestination = false
    var draggingFormation: NSDraggingFormation = .none
    var numberOfValidItemsForDrop = 1

    init(window: NSWindow, location: CGPoint, items frames: [CGRect]) {
        self.window = window
        self.location = location
        items = frames.map { frame in
            let item = NSDraggingItem(pasteboardWriter: NSPasteboardItem())
            item.setDraggingFrame(frame, contents: NSImage(size: frame.size))
            return item
        }
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for (index, item) in items.enumerated() {
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }
}

// D1 diagnosis: native source completion and Core Animation, no screen input.
@MainActor
final class RoundD1DragTests: XCTestCase {
    /// The production return helper orders a transparent, display-spanning
    /// panel. Redirect only this test's ordering to a position off every screen
    /// so Core Animation makes a real presentation tree without visible UI.
    private func withReturnWindowsOffscreen(_ body: () throws -> Void) throws {
        let selector = #selector(NSWindow.orderFrontRegardless)
        let method = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, selector))
        let original = method_getImplementation(method)
        typealias Order = @convention(c) (NSWindow, Selector) -> Void
        let invoke = unsafeBitCast(original, to: Order.self)
        let redirect: @convention(block) (NSWindow) -> Void = { window in
            window.setFrameOrigin(CGPoint(x: -100000, y: -100000))
            precondition(NSScreen.screens.allSatisfy { !window.frame.intersects($0.frame) })
            invoke(window, selector)
        }
        let replacement = imp_implementationWithBlock(redirect)
        method_setImplementation(method, replacement)
        defer { method_setImplementation(method, original); imp_removeBlock(replacement) }
        try body()
    }

    private func source() throws -> TasksDragOut.Source {
        let images = try XCTUnwrap(TasksDragOut.Card.Images(card: Color.gray.frame(height: 34),
            width: 300, environment: EnvironmentValues(), scale: 2))
        let source = TasksDragOut.Source(ended: {})
        source.card = TasksDragOut.Card(images: images,
            frame: CGRect(x: 0, y: 0, width: 340, height: 74),
            home: { CGRect(x: 1200, y: 700, width: 340, height: 74) },
            reduceMotion: false, handOff: {}, settled: {})
        source.grip = AtticDragGrip(offset: CGPoint(x: -20, y: -37), size: CGSize(width: 340, height: 74))
        TasksDragOut.Source.current = source
        source.handOffOnce()
        return source
    }

    func testCancelledReturnDoesNotAddAnImplicitPositionAnimationFromTheScreenEdge() throws {
        try withReturnWindowsOffscreen {
            let source = try source()
            defer {
                source.dragReturnForTesting?.windowForTesting.orderOut(nil)
                TasksDragOut.Source.current = nil
            }
            let returning = try XCTUnwrap(source.dragReturnForTesting)
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let layers = try XCTUnwrap(returning.windowForTesting.contentView?.layer?.sublayers)
            // V-09: the picture shows at hand-off (the drag's only one),
            // placed without any animation of its own.
            XCTAssertTrue(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty },
                          "Shown at the hand-off with no implicit travel")
            let release = CGPoint(x: 900, y: 600)
            source.ended(at: release, operation: []) // no destination or a refused/cancelled drop
            let expected = source.grip.frame(at: release)
            XCTAssertEqual(returning.startOnScreen, expected, "O2's model-frame assertion still passes")
            for layer in layers {
                let position = layer.animation(forKey: "position") as? CABasicAnimation
                let x = layer.animation(forKey: "position.x") as? CASpringAnimation
                let y = layer.animation(forKey: "position.y") as? CASpringAnimation
                print("D1 return keys=\(layer.animationKeys() ?? []) implicitFrom=\(String(describing: position?.fromValue)) explicitXFrom=\(String(describing: x?.fromValue)) overlayOrigin=\(returning.windowForTesting.frame.origin)")
                XCTAssertNotNil(x)
                XCTAssertNotNil(y)
                XCTAssertNil(position, "O18-06: implicit position starts at the overlay origin and competes with release-point springs")
                XCTAssertNil(layer.animation(forKey: "bounds"), "Size must use only the explicit bounds.size spring")
            }
            XCTAssertTrue(NSScreen.screens.allSatisfy { !returning.windowForTesting.frame.intersects($0.frame) })
        }
    }

    func testEveryCompletedSourceOperationUsesTheSuppliedGlobalPointWithoutClamping() throws {
        try withReturnWindowsOffscreen {
            // x=0 and negative coordinates are valid on real multi-display
            // desktops. Do not introduce a blanket zero/negative-point fallback.
            for release in [CGPoint.zero, CGPoint(x: -1800, y: 400), CGPoint(x: 900, y: -600)] {
                for operation: NSDragOperation in [[], .copy, .delete] {
                    let source = try source()
                    let returning = try XCTUnwrap(source.dragReturnForTesting)
                    source.ended(at: release, operation: operation)
                    XCTAssertEqual(returning.startOnScreen,
                        operation.isEmpty ? source.grip.frame(at: release) : nil)
                    returning.windowForTesting.orderOut(nil)
                    TasksDragOut.Source.current = nil
                }
            }
        }
    }

    func testFileReturnUsesOnlyExplicitSpringsWhenItsSizeChanges() throws {
        try withReturnWindowsOffscreen {
            let image = NSImage(size: CGSize(width: 240, height: 40))
            let home = CGRect(x: 1200, y: 700, width: 240, height: 40)
            let returning = AtticDragReturn(shadowed: nil, plain: image, home: { home }, level: .floating, reduceMotion: false)
            defer { returning.windowForTesting.orderOut(nil) }
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let start = CGRect(x: -900, y: 300, width: 180, height: 30)
            returning.moved(drawn: start)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let layers = try XCTUnwrap(returning.windowForTesting.contentView?.layer?.sublayers)
            XCTAssertTrue(layers.allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "Resting placement has no implicit travel or fade")
            returning.ended(operation: [], drawn: start, done: {})
            for layer in layers {
                XCTAssertEqual(Set(layer.animationKeys() ?? []), ["position.x", "position.y", "bounds.size"])
                XCTAssertEqual((layer.animation(forKey: "bounds.size") as? CASpringAnimation)?.fromValue as? NSValue, NSValue(size: start.size))
            }
        }
    }
}


/// T7: cancellation owns the whole press, including its Escape and later release.
@MainActor
final class TasksDragCancellationTests: XCTestCase {
    private enum Interruption { case escape, keyLoss, orderOut, panelHide, pageSwitch, tabSwitch, none }

    func testT7EscapeCancelsSubtaskDragWithoutCollapsingOrUndo() throws { try exercise(.escape) }
    func testT7KeyLossCancelsSubtaskDrag() throws { try exercise(.keyLoss) }
    func testT7HiddenWindowCancelsSubtaskDrag() throws { try exercise(.orderOut) }
    func testT7PanelHideCancelsSubtaskDrag() throws { try exercise(.panelHide) }
    func testT7PageSwitchCancelsSubtaskDrag() throws { try exercise(.pageSwitch) }
    func testT7TabSwitchCancelsSubtaskDrag() throws { try exercise(.tabSwitch) }
    func testT7EscapeCancelsInListTaskReorderAndConsumesTheKey() throws { try exercise(.escape, subtask: false) }
    func testT7UninterruptedSubtaskDragStillReordersWithOneUndo() throws { try exercise(.none) }
    /// O5-03: an expanded task's cancelled drag returns as a drop home does.
    /// Its card settles into its own place while the rows below give it
    /// back, so the row and its open subtasks are drawn again only once
    /// nothing is left over them: they never show at once while the
    /// following rows are still on their way down.
    func testO5_03AnExpandedTaskReturnsHomeBeforeItsSubtasksShowAgain() throws {
        try exercise(.escape, subtask: false, checksReturn: true)
    }

    private func exercise(_ interruption: Interruption, subtask: Bool = true, checksReturn: Bool = false) throws {
        try requireKeyWindowTests()
        let hosted = try Hosted(height: 700)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.title == (subtask ? "Finalize launch checklist" : "Ship appearance PR") })
        hosted.model.setExpanded(parent.id, true)
        hosted.model.selectOnly(parent.id)
        hosted.spin(0.3)
        let children = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent.id }).subtasks
        let before = hosted.store.subtasks(of: parent.id).map(\.id)
        let rowsBefore = hosted.model.rows(for: .now).map(\.id)
        let undoBefore = hosted.model.library.undo.undoStepID(in: .tasks)
        let frame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: parent.id)])
        // The first open child is the first quick-look line. The last line is Add subtask.
        let startY = subtask
            ? frame.maxY - AtticQuickLookMetrics.bottomPadding - CGFloat(children.count + 1) * AtticLayout.subtaskPitch + AtticLayout.subtaskPitch / 2
            : frame.minY + 15
        let distance: CGFloat = subtask ? AtticLayout.subtaskPitch + 7 : frame.height + 24
        func post(_ type: NSEvent.EventType, _ offset: CGFloat) {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: 170, y: hosted.height - startY - offset),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                context: nil, eventNumber: 7, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!, atStart: false)
        }
        func escape() {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber, context: nil,
                    characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!, atStart: false)
            }
        }
        var timers: [Timer] = []
        func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        defer { timers.forEach { $0.invalidate() } }
        var lifted = false
        var returning: TasksLiftedCard.Lift?
        after(0.15) { post(.leftMouseDragged, 7) }
        after(0.25) { post(.leftMouseDragged, distance) }
        after(0.45) {
            if !subtask { lifted = hosted.pointer.liftedCard.lift != nil }
            switch interruption {
            case .escape: escape()
            case .keyLoss: hosted.window.resignKey()
            case .orderOut: hosted.window.orderOut(nil)
            case .panelHide: hosted.model.pageDidHide()
            case .pageSwitch: hosted.model.isPageShown = false
            case .tabSwitch: hosted.model.select(tab: .backlog)
            case .none: break
            }
        }
        // Just after Escape, the cancelled task is still on its way home.
        after(0.5) { returning = hosted.pointer.liftedCard.lift }
        // Restore the surface *before* moving/releasing: cancellation must be latched.
        after(0.7) {
            if interruption == .orderOut { hosted.window.orderFront(nil) }
            if interruption == .keyLoss || interruption == .orderOut { hosted.window.makeKey() }
            if interruption == .pageSwitch { hosted.model.isPageShown = true }
            if interruption == .tabSwitch { hosted.model.select(tab: .now) }
            post(.leftMouseDragged, distance + 3)
        }
        after(0.9) { post(.leftMouseUp, distance + 3) }
        post(.leftMouseDown, 0)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            Hosted.pumpEvents(limit: 1)
            hosted.spin(0.01)
        }
        Hosted.pumpEvents()
        hosted.spin(0.3)
        if !subtask { XCTAssertTrue(lifted, "the separate in-list row gesture lifted its card") }
        if checksReturn {
            let card = try XCTUnwrap(returning, "the card returns home: its row is not drawn again over the rows still moving")
            XCTAssertEqual(card.id, parent.id)
            XCTAssertEqual(card.y, card.origin.minY, accuracy: 0.5, "it settles into its own place")
        }
        XCTAssertTrue(hosted.model.expanded.contains(parent.id), "Escape belongs only to the drag; the task stays expanded")
        XCTAssertNil(hosted.pointer.liftedCard.lift)
        if interruption == .none {
            XCTAssertNotEqual(hosted.store.subtasks(of: parent.id).map(\.id), before, "positive control: the real gesture reorders")
            XCTAssertNotEqual(hosted.model.library.undo.undoStepID(in: .tasks), undoBefore)
            XCTAssertTrue(hosted.model.undo().isApplied)
            XCTAssertEqual(hosted.store.subtasks(of: parent.id).map(\.id), before)
            XCTAssertEqual(hosted.model.library.undo.undoStepID(in: .tasks), undoBefore, "exactly one Undo step")
        } else {
            XCTAssertEqual(hosted.store.subtasks(of: parent.id).map(\.id), before, "cancelled subtasks keep their order")
            XCTAssertEqual(hosted.model.rows(for: .now).map(\.id), rowsBefore, "cancelled task rows keep their order")
            XCTAssertEqual(hosted.model.library.undo.undoStepID(in: .tasks), undoBefore, "cancellation adds no Undo step")
        }
    }
}
