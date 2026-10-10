import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Siblings of H10's environment capture and orphan presentation state.
/// Hosts are detached or mounted in never-shown, never-key windows.
@MainActor
final class PhaseXHunt9Tests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.contentView = nil; $0.close() }
        windows.removeAll()
    }

    private func spin(_ duration: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private func window(_ size: CGSize = CGSize(width: 340, height: 560)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func pixels<V: View>(_ view: V) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func assertSameRaster(_ actual: Data, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        // ImageRenderer/ColorSync can round a channel by one byte between
        // identical renders. Compare every channel, including alpha; the
        // light/dark ink difference is orders of magnitude larger.
        let error = zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(error, 1, "maximum raster channel error", file: file, line: line)
    }

    func testH11_01HoveredLinkAddressFollowsAppearanceWithoutRehover() throws {
        let light = AtticDesignContext(mode: .light), dark = AtticDesignContext(mode: .dark)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Note"), .text("example")]), design: light)
        let (scroll, text) = engine.makeView()
        let window = window()
        scroll.frame = window.contentView!.bounds
        window.contentView = scroll
        let controls = NoteFormatControls(engine: engine, textView: text, scrollView: scroll, design: light,
                                          noteID: engine.noteID, isNewDraft: false)
        defer { controls.invalidate(); engine.detachView() }
        let range = (text.string as NSString).range(of: "example")
        XCTAssertTrue(engine.perform(.link("https://example.com"), selection: range))
        scroll.layoutSubtreeIfNeeded()
        let rect = try XCTUnwrap(engine.rect(for: NSRange(location: range.location + 2, length: 1)))
        let point = text.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        controls.mouseMoved(with: event)
        spin(0.65)
        let address = try XCTUnwrap(descendants(scroll).compactMap { $0 as? AtticOverlayHostingView }.first { !$0.isHidden })
        let expectedLight = try pixels(AnyView(NoteLinkAddressView(address: "example.com").atticDesign(light)))
        let expectedDark = try pixels(AnyView(NoteLinkAddressView(address: "example.com").atticDesign(dark)))
        XCTAssertNotEqual(expectedLight, expectedDark, "independent rendered consumer changes ink")
        assertSameRaster(try pixels(address.rootView), expectedLight)
        controls.update(design: dark)
        spin()
        assertSameRaster(try pixels(address.rootView), expectedDark)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testH11_02ExternalSubtaskDeletionReleasesRenameState() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        let model = TasksPageModel(library: library, services: TasksPageServices())
        model.setExpanded(parent.id, true)
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "Draft"
        model.subtaskRenameFailed = true
        XCTAssertEqual(model.renamingSubtaskID, child.id)
        XCTAssertTrue(library.delete(AtticItemRef(.task, child.id)))
        spin()
        XCTAssertNotNil(store.task(withID: parent.id), "picker/field anchor survives")
        XCTAssertNil(store.task(withID: child.id))
        XCTAssertNil(model.renamingSubtaskID, "the missing field cannot keep page keys locked")
        XCTAssertFalse(model.hasUnsavedEdit, "the missing field's failed-save hold is released")
    }

    private func action(named name: String, label: String, in root: AnyObject) -> NSAccessibilityCustomAction? {
        var seen = Set<ObjectIdentifier>()
        func search(_ object: AnyObject) -> NSAccessibilityCustomAction? {
            guard seen.insert(ObjectIdentifier(object)).inserted, let element = object as? NSObject else { return nil }
            func value(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
            }
            if value("accessibilityLabel") as? String == label,
               let actions = value("accessibilityCustomActions") as? [NSAccessibilityCustomAction],
               let found = actions.first(where: { $0.name == name }) { return found }
            let children = value("accessibilityChildren") as? [Any] ?? []
            for child in children { if let found = search(child as AnyObject) { return found } }
            return nil
        }
        return search(root)
    }

    func testH11_03MovePickerClosesWhenItsChildGoesAwayButParentRemains() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        _ = try XCTUnwrap(store.create(title: "Destination"))
        let model = TasksPageModel(library: library, services: TasksPageServices())
        model.setExpanded(parent.id, true)
        final class Locks { var last = false }
        let locks = Locks()
        let size = CGSize(width: 340, height: 560)
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
            addBarFocused: .constant(false), chrome: TasksPageChrome(editLock: { locks.last = $0 }))
        let window = window(size)
        window.contentView = NSHostingView(rootView: page.atticDesign(.default).frame(width: size.width, height: size.height))
        spin(0.35)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let move = try XCTUnwrap(action(named: "Move to Task…", label: child.title, in: window))
        XCTAssertTrue(try XCTUnwrap(move.handler)())
        spin(0.35)
        XCTAssertTrue(locks.last, "mounted row's real shared command opened Move")
        XCTAssertTrue(library.delete(AtticItemRef(.task, child.id)))
        spin(0.35)
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == parent.id })
        XCTAssertFalse(locks.last, "missing target closes the card and releases the page")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testH11_04ExternalDoneDeletionPrunesSelectionAndTitleEditor() throws {
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Done"))
        XCTAssertTrue(library.updateTask(task.id, status: .done).isApplied)
        let model = TasksPageModel(library: library, services: TasksPageServices())
        model.select(tab: .done)
        model.selectOnly(task.id)
        model.beginEditingTitle(task.id)
        XCTAssertEqual(model.editingTitleID, task.id)
        XCTAssertTrue(library.delete(AtticItemRef(.task, task.id)))
        spin()
        XCTAssertFalse(model.doneDays().flatMap(\.rows).contains { $0.id == task.id })
        XCTAssertFalse(model.selection.contains(task.id))
        XCTAssertNil(model.editingTitleID, "absent Done rows are not immortal")
    }

    func testH11_05DateCachesFollowTimezoneWithinTheSameLocalDay() throws {
        let savedZone = NSTimeZone.default
        defer { NSTimeZone.default = savedZone }
        NSTimeZone.default = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let itemTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-09T23:30:00Z"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        let store = try makeTestStore(now: { itemTime }), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Finished near midnight"))
        XCTAssertTrue(library.updateTask(task.id, status: .done).isApplied)
        let model = TasksPageModel(library: library, services: TasksPageServices(now: { now }))
        model.select(tab: .done)
        let first = model.doneDays()
        let token = model.pageToken(.done)
        let notes = try makeTestNoteStore(now: { itemTime }, attachmentFileStore: makeTestAttachmentFileStore())
        guard case let .success((id, _)) = notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Midnight")])) else {
            return XCTFail("fixture note")
        }
        let list = NotesLibraryModel(search: { _ in [] }, store: notes, now: { now })
        XCTAssertTrue(list.groups(store: notes, drafts: []).contains { $0.id == "week" && $0.rows.contains { $0.id == id } })
        NSTimeZone.default = try XCTUnwrap(TimeZone(secondsFromGMT: 3_600))
        XCTAssertEqual(DueDay(date: now, calendar: .current), DueDay(rawValue: "2026-10-10"))
        XCTAssertNotEqual(first.first?.id, Calendar.current.startOfDay(for: itemTime), "independent grouping oracle changed")
        XCTExpectFailure("H11-05") {
            XCTAssertEqual(model.doneDays().first?.id, Calendar.current.startOfDay(for: itemTime))
            XCTAssertNotEqual(model.pageToken(.done), token, "hidden Done page invalidates for changed date environment")
            XCTAssertTrue(list.groups(store: notes, drafts: []).contains { $0.id == "today" && $0.rows.contains { $0.id == id } })
        }
    }

    func testH11_09ReopenedNoteDatePickerFollowsCurrentTimezone() throws {
        let savedZone = NSTimeZone.default
        defer { NSTimeZone.default = savedZone }
        NSTimeZone.default = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let card = NoteFormatCardModel()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        card.openDate(fromSlash: false, today: now)
        NSTimeZone.default = try XCTUnwrap(TimeZone(secondsFromGMT: 43_200))
        card.openDate(fromSlash: false, today: now)
        XCTExpectFailure("H11-09") {
            XCTAssertEqual(card.candidateDate, Calendar.current.startOfDay(for: now), "Today must use the current local day")
        }
    }

    private final class ClearBox: ObservableObject { @Published var presented = false }
    private struct CanvasRoot: View {
        let session: CanvasSession
        @ObservedObject var box: ClearBox
        var body: some View {
            CanvasPanelContent(session: session, horizontalInset: 16, isClearConfirmationPresented: $box.presented)
                .frame(width: 400, height: 560)
        }
    }

    func testH11_06DeletedCanvasClosesItsPendingClearConfirmation() throws {
        let store = try makeTestCanvasStore(), session = CanvasSession(store: store)
        let first = try XCTUnwrap(session.createCanvas(name: "First"))
        let second = try XCTUnwrap(session.createCanvas(name: "Second"))
        XCTAssertTrue(session.selectCanvas(first.id))
        let library = AtticLibrary(tasks: try makeTestStore(), canvases: store)
        let box = ClearBox()
        let host = NSHostingView(rootView: CanvasRoot(session: session, box: box))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
        host.layoutSubtreeIfNeeded()
        spin()
        XCTAssertNil(host.window, "detached host: native alert cannot be shown")
        box.presented = true
        spin()
        XCTAssertTrue(box.presented, "a pending confirmation was captured for First")
        XCTAssertTrue(library.delete(AtticItemRef(.canvas, first.id)))
        spin(0.35)
        XCTAssertEqual(session.selectedCanvasID, second.id)
        XCTAssertFalse(box.presented, "First's confirmation cannot survive to clear Second")
        box.presented = false
        host.rootView = CanvasRoot(session: session, box: box)
        spin()
    }

    func testH11_07OpenNoteDateChipsRefreshOnDayChange() async throws {
        let now = MutableNow(Date())
        let store = try makeTestNoteStore(now: { now.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: nil, now: { now.value })
        await controller.startAndWait()
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Dates"), .text("Body")])) else {
            return XCTFail("fixture note")
        }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        controller.present()
        let engine = try XCTUnwrap(controller.active?.engine)
        let today = NoteDay(date: now.value)
        XCTAssertTrue(engine.insertDate(today, at: NSRange(location: engine.textStorage.length, length: 0)))
        let date = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteDateAttachment }.first)
        let opened = try XCTUnwrap(date.renderedImage)
        now.value = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now.value))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        spin()
        XCTExpectFailure("H11-07") {
            XCTAssertEqual(engine.today, NoteDay(date: now.value))
            XCTAssertFalse(date.renderedImage === opened, "Today redraws as Yesterday without reopening")
        }
    }

    func testH11_08DeletedSubtaskParentReleasesFailedCreationHold() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save), library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let model = TasksPageModel(library: library, services: TasksPageServices())
        model.beginAddingSubtask(to: parent.id)
        model.newSubtaskTitle = "Unsaved child"
        gate.shouldFail = true
        XCTAssertFalse(model.commitNewSubtask())
        gate.shouldFail = false
        XCTAssertTrue(model.hasUnsavedEdit)
        XCTAssertTrue(library.delete(AtticItemRef(.task, parent.id)))
        spin()
        XCTAssertNil(model.newSubtaskParentID)
        XCTAssertFalse(model.hasUnsavedEdit, "missing editor cannot hold every subsequent agent reveal")
        XCTAssertNil(model.failedSave, "or offer a retry against its deleted parent")
    }

    func testCoverageRenameSurvivesRollbackThenClosesForMoveAndUndoDoesNotReopenIt() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save), library = AtticLibrary(tasks: store)
        let first = try XCTUnwrap(store.create(title: "First"))
        let second = try XCTUnwrap(store.create(title: "Second"))
        let child = try XCTUnwrap(store.create(title: "Child", parentID: first.id))
        let model = TasksPageModel(library: library, services: TasksPageServices())
        model.setExpanded(first.id, true)
        model.beginRenamingSubtask(child.id)
        model.subtaskRename = "Retained draft"
        gate.shouldFail = true
        XCTAssertFalse(library.delete(AtticItemRef(.task, child.id)))
        gate.shouldFail = false
        spin()
        XCTAssertEqual(model.renamingSubtaskID, child.id, "failed delete did not remove the owner")
        XCTAssertEqual(model.subtaskRename, "Retained draft")
        XCTAssertTrue(library.moveSubtask(child.id, toTask: second.id).isApplied)
        spin()
        XCTAssertNil(model.renamingSubtaskID, "moving to another quick look ends the original editor")
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        spin()
        XCTAssertEqual(store.task(withID: child.id)?.parentID, first.id)
        XCTAssertNil(model.renamingSubtaskID, "Undo restores the object, not its expired editor")
        XCTAssertTrue(library.redo(in: .tasks).isApplied)
        spin()
        XCTAssertNil(model.renamingSubtaskID)
    }

    func testCoverageDoneLogEditorSurvivesAnUnrelatedChangeAndFailedDelete() throws {
        let gate = PersistenceGate()
        let now = Date()
        let store = try makeTestStore(now: { now }, persist: gate.save), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Archived"))
        XCTAssertTrue(library.updateTask(task.id, status: .done).isApplied)
        XCTAssertEqual(store.moveCompletedToDoneLog(before: now.addingTimeInterval(1)), 1)
        XCTAssertNil(store.task(withID: task.id))
        XCTAssertNotNil(store.listedTask(withID: task.id))
        let model = TasksPageModel(library: library, services: TasksPageServices())
        model.select(tab: .done)
        model.selectOnly(task.id)
        model.beginEditingTitle(task.id)
        model.editingTitle = "Kept draft"
        _ = try XCTUnwrap(store.create(title: "Neighbour"))
        spin()
        XCTAssertEqual(model.editingTitleID, task.id, "archive membership remains live")
        gate.shouldFail = true
        XCTAssertFalse(library.delete(AtticItemRef(.task, task.id)))
        gate.shouldFail = false
        spin()
        XCTAssertEqual(model.editingTitleID, task.id)
        XCTAssertEqual(model.editingTitle, "Kept draft")
        XCTAssertTrue(model.selection.contains(task.id))
    }

    func testCoverageFailedSubtaskDraftStaysUntilItsParentActuallyLeaves() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save), library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let model = TasksPageModel(library: library, services: TasksPageServices())
        model.beginAddingSubtask(to: parent.id)
        model.newSubtaskTitle = "Kept child"
        gate.shouldFail = true
        XCTAssertFalse(model.commitNewSubtask())
        gate.shouldFail = false
        _ = try XCTUnwrap(store.create(title: "Neighbour"))
        spin()
        XCTAssertEqual(model.newSubtaskParentID, parent.id)
        XCTAssertTrue(model.hasUnsavedEdit)
        XCTAssertEqual(model.newSubtaskTitle, "Kept child")
        XCTAssertTrue(library.updateTask(parent.id, status: .backlog).isApplied)
        spin()
        XCTAssertNil(model.newSubtaskParentID)
        XCTAssertFalse(model.hasUnsavedEdit)
    }

    func testCoverageRowPickerSurvivesTitleReflowAndUndoDoesNotReopenIt() throws {
        setenv("ATTIC_UI_TEST_META", "tags@0.1", 1)
        defer { unsetenv("ATTIC_UI_TEST_META") }
        let store = try makeTestStore(), library = AtticLibrary(tasks: store)
        let task = try XCTUnwrap(store.create(title: "Short"))
        XCTAssertTrue(library.updateTask(task.id, tags: ["work"]).isApplied)
        let model = TasksPageModel(library: library, services: TasksPageServices())
        final class Locks { var last = false }
        let locks = Locks()
        let size = CGSize(width: 340, height: 560)
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
            addBarFocused: .constant(false), chrome: TasksPageChrome(editLock: { locks.last = $0 }))
        let window = window(size)
        window.contentView = NSHostingView(rootView: page.atticDesign(.default).frame(width: size.width, height: size.height))
        spin(0.5)
        XCTAssertTrue(locks.last)
        XCTAssertTrue(library.updateTask(task.id, title: String(repeating: "Long title ", count: 12)).isApplied)
        spin(0.3)
        XCTAssertTrue(locks.last, "reflow preserves logical row membership")
        XCTAssertTrue(library.delete(AtticItemRef(.task, task.id)))
        spin(0.3)
        XCTAssertFalse(locks.last)
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        spin(0.3)
        XCTAssertNotNil(store.task(withID: task.id))
        XCTAssertFalse(locks.last, "the restored row does not resurrect the old picker")
    }
}
