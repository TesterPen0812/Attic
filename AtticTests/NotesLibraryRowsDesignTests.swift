import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The owner's panel design for All notes (2026-10-27/28, Notes rows
/// option 4a): rows with a page thumbnail, time · first #tag · snippet,
/// no task status; foldable sections; the "•••" menu; thumbnails drawn
/// once per note revision.
@MainActor
final class NotesLibraryRowsDesignTests: XCTestCase {
    private var store: NoteStore!

    override func setUp() async throws {
        store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
    }

    @discardableResult
    private func create(_ title: String, _ body: String = "", tags: [String] = []) throws -> UUID {
        let blocks: [NoteBlock] = body.isEmpty ? [.text(title)] : [.text(title), .text(body)]
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks),
                                                                   tags: tags.isEmpty ? nil : tags) else {
            throw NSError(domain: "create", code: 1)
        }
        return id
    }

    private func library() -> NotesLibraryModel { NotesLibraryModel(search: { _ in [] }, store: store) }

    func testPF14LibraryRemountReusesTaskWritingClassification() throws {
        let context = ModelContext(store.container)
        var owners: [TaskItem] = []
        for i in 0..<24 {
            let task = TaskItem(title: "Task note \(i)")
            context.insert(task)
            owners.append(task)
        }
        try context.save()
        for (i, task) in owners.enumerated() {
            let blocks: [NoteBlock] = i.isMultiple(of: 5)
                ? [.text(task.title)]
                : [.text(task.title), .text(String(repeating: "text", count: 1_000))]
            _ = try store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks),
                                             taskOwner: task.id).get()
        }
        let controller = controller()
        let first = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        let firstIDs = Set(first.groups(store: store, drafts: [], prepareSummaries: false).flatMap(\.rows).map(\.id))
        print("PF14 first_mount=\(first.writingDecodeCount) task_writing_decodes")
        XCTAssertEqual(first.writingDecodeCount, 24)
        XCTAssertEqual(firstIDs.count, 19, "title-only task notes are excluded")
        let remounted = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        let remountIDs = Set(remounted.groups(store: store, drafts: [], prepareSummaries: false).flatMap(\.rows).map(\.id))
        print("PF14 remount=\(remounted.writingDecodeCount) task_writing_decodes")
        XCTAssertEqual(remounted.writingDecodeCount, 0,
                       "reopening All notes must not decode unchanged task documents again")
        XCTAssertEqual(firstIDs, remountIDs)

        let changed = try XCTUnwrap(store.notes.first { $0.taskID == owners[0].id })
        let revision = changed.revisionID
        let document = NoteDocument(blocks: [.text(changed.title), .text("New writing after the first mount")])
        guard case .success = store.saveDocument(noteID: changed.id, document: document,
                                                 baseRevisionID: revision) else {
            XCTFail("the revised writing must be saved before measuring invalidation")
            return
        }
        let updatedIDs = Set(remounted.groups(store: store, drafts: [], prepareSummaries: false)
            .flatMap(\.rows).map(\.id))
        XCTAssertEqual(remounted.writingDecodeCount, 1,
                       "a changed document must invalidate only its own classification")
        XCTAssertTrue(updatedIDs.contains(changed.id), "the newly written task note becomes visible")
        XCTAssertEqual(updatedIDs.count, firstIDs.count + 1)

        // An imported fresh-context row can carry different content under
        // the same revision token. The digest must invalidate the shared
        // classification even when that token is unchanged.
        let revised = try XCTUnwrap(store.note(withID: changed.id))
        let sameRevision = revised.revisionID
        revised.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text(revised.title)]))
        XCTAssertEqual(revised.revisionID, sameRevision)
        let imported = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        let importedIDs = Set(imported.groups(store: store, drafts: [], prepareSummaries: false)
            .flatMap(\.rows).map(\.id))
        XCTAssertEqual(imported.writingDecodeCount, 1,
                       "new bytes under an unchanged revision must reclassify exactly one note")
        XCTAssertFalse(importedIDs.contains(changed.id), "title-only writing must leave the library")
    }

    func testPF14ColdTagFilterDoesNotDecodeUnrelatedTaskNotes() throws {
        let context = ModelContext(store.container)
        var owners: [TaskItem] = []
        for i in 0..<48 {
            let task = TaskItem(title: "Task note \(i)")
            task.tags = i.isMultiple(of: 24) ? ["focus"] : ["unrelated"]
            context.insert(task)
            owners.append(task)
        }
        try context.save()
        var selectedIDs = Set<UUID>()
        var otherIDs = Set<UUID>()
        for (i, task) in owners.enumerated() {
            if i.isMultiple(of: 24) {
                let id = UUID()
                selectedIDs.insert(id)
                _ = try store.createDocumentNote(id: id, document: NoteDocument(blocks: [
                    .text(task.title), .text("Writing")
                ]), taskOwner: task.id).get()
            } else {
                let id = UUID()
                otherIDs.insert(id)
                _ = try store.createDocumentNote(id: id, document: NoteDocument(blocks: [
                    .text(task.title), .text(String(repeating: "x", count: 4_000))
                ]), taskOwner: task.id).get()
            }
        }
        let model = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller())
        model.toggleTag("focus")
        let visible = Set(model.groups(store: store, drafts: [], prepareSummaries: false)
            .flatMap(\.rows).map(\.id))
        print("PF14 cold_filtered=\(model.writingDecodeCount) task_writing_decodes / 48 task notes")
        XCTAssertEqual(model.writingDecodeCount, 2)
        XCTAssertEqual(visible, selectedIDs)
        // Fixed stress sequence (seed 0x14F1): 256 successive filter
        // changes must keep exact membership without decoding unchanged
        // content for a second time.
        for step in 0..<256 {
            let showOther = step.isMultiple(of: 2)
            model.toggleTag(showOther ? "focus" : "unrelated")
            model.toggleTag(showOther ? "unrelated" : "focus")
            let rows = Set(model.groups(store: store, drafts: [], prepareSummaries: false)
                .flatMap(\.rows).map(\.id))
            XCTAssertEqual(rows, showOther ? otherIDs : selectedIDs, "filter flip \(step)")
        }
        print("PF14 filter_flips=256 total_writing_decodes=\(model.writingDecodeCount)")
        XCTAssertEqual(model.writingDecodeCount, 48,
                       "every task is classified once across 256 filter changes")
    }

    func testSW04ArrowNavigationReusesOrderedIDsUntilRowsChange() throws {
        let first = try create("first")
        _ = try create("second")
        let model = library()
        var groups = model.unfolded(model.groups(store: store, drafts: [], prepareSummaries: false))
        for _ in 0..<20 { model.moveHighlight(by: 1, in: groups, from: nil) }
        XCTAssertEqual(model.navigationBuildCount, 1)
        _ = try create("third")
        groups = model.unfolded(model.groups(store: store, drafts: [], prepareSummaries: false))
        model.moveHighlight(by: -1, in: groups, from: first)
        XCTAssertEqual(model.navigationBuildCount, 2, "a changed inventory must rebuild the navigation index")
    }

    // MARK: Line two

    func testTheRowShowsTheFirstTagSkippingTheFilteredOne() throws {
        XCTAssertEqual(NotesLibraryModel.firstTag(["launch", "work"], filter: .none), "launch")
        XCTAssertEqual(NotesLibraryModel.firstTag(["launch", "work"], filter: TagPicks(["launch"])), "work")
        XCTAssertNil(NotesLibraryModel.firstTag(["launch"], filter: TagPicks(["launch"])))
        XCTAssertNil(NotesLibraryModel.firstTag([], filter: .none))

        let id = try create("Launch plan", "Kyoto offsite agenda", tags: ["launch", "work"])
        let model = library()
        let row = try XCTUnwrap(model.groups(store: store, drafts: []).flatMap(\.rows).first { $0.id == id })
        var details = model.libraryRow(row, store: store)
        XCTAssertEqual(details.tag, "launch")
        XCTAssertEqual(details.row.preview, "Kyoto offsite agenda")
        XCTAssertEqual(details.thumbnail, NoteThumbnailContent(title: "Launch plan", text: "Kyoto offsite agenda", hasImages: false))
        model.tagPicks = TagPicks(["launch"])
        details = model.libraryRow(row, store: store)
        XCTAssertEqual(details.tag, "work")
    }

    // MARK: Sections

    func testAFoldedSectionKeepsItsHeaderAndLeavesTheKeyboardsList() throws {
        let pinned = try create("Pinned note")
        let today = try create("Today note")
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let model = library()
        let groups = model.groups(store: store, drafts: [])
        XCTAssertEqual(groups.map(\.id), ["pinned", "today"])
        XCTAssertEqual(model.unfolded(groups).map(\.id), ["pinned", "today"])

        model.highlightedID = pinned
        model.toggleGroup("pinned", in: groups)
        XCTAssertEqual(model.foldedGroups, ["pinned"])
        XCTAssertNil(model.highlightedID, "a folded row can't keep the keyboard")
        XCTAssertEqual(model.unfolded(groups).map(\.id), ["today"])
        // The header still counts its rows.
        XCTAssertEqual(model.groups(store: store, drafts: []).map(\.id), ["pinned", "today"])

        model.moveHighlight(by: 1, in: model.unfolded(groups), from: nil)
        XCTAssertEqual(model.highlightedID, today)
        model.moveHighlight(by: -1, in: model.unfolded(groups), from: nil)
        XCTAssertEqual(model.highlightedID, today, "↑ never reaches a folded row")

        model.toggleGroup("pinned", in: groups)
        XCTAssertTrue(model.foldedGroups.isEmpty)
        XCTAssertEqual(model.highlightedID, today)
        XCTAssertEqual(model.orderedIDs(model.unfolded(groups)), [pinned, today])
    }

    // MARK: The "•••" menu

    private func controller() -> NotesPageController {
        NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "OneItemLibrary")), defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
    }

    private func rowCommands(_ id: UUID, controller: NotesPageController, tasks: TaskStore? = nil,
                             delete: @escaping (UUID) -> Void) -> [AtticMenuCommand] {
        NotesEditorPage.libraryRowCommands(id, noteStore: store, controller: controller, taskStore: tasks,
            picked: .none, hue: { _ in nil }, filter: { _ in }, open: { _ in }, delete: delete)
    }

    func testOrdinaryNoteHoverMenuUsesRealLibraryCommands() async throws {
        let id = try create("Groceries", "Milk and eggs"), controller = self.controller()
        var added: [UUID] = [], deleted: [UUID] = []
        controller.makeTaskFromNote = { added.append($0) }
        let commands = rowCommands(id, controller: controller, delete: { deleted.append($0) })
        let menu = NotesLibraryView.hoverMenu(commands, pinned: false)
        XCTAssertEqual(menu.map(\.title), ["Pin", "Add to Tasks", "Delete"])
        XCTAssertEqual(menu.map(\.identifier), ["notes-row-pin", "one-item-add-to-tasks", "notes-row-delete"])
        XCTAssertEqual(menu.map(\.isDestructive), [false, false, true])
        XCTAssertTrue(menu[2].startsSection)
        XCTAssertEqual(menu[2].shortcut, commands.last?.shortcut)
        menu[1].action()
        for _ in 0..<100 where added.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(added, [id], "runs the real library producer's Add to Tasks")
        menu[2].action()
        XCTAssertEqual(deleted, [id])
    }

    func testTaskWritingHoverMenuUsesRealLibraryCommands() throws {
        let context = ModelContext(store.container)
        let task = TaskItem(title: "Plan the offsite")
        context.insert(task)
        try context.save()
        let id = UUID()
        _ = try store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text(task.title), .text("Book the boathouse")]),
                                         taskOwner: task.id).get()
        XCTAssertTrue(store.setPinned(true, noteID: id))
        let controller = self.controller(), tasks = TaskStore(container: store.container)
        var removed: [UUID] = [], deleted: [UUID] = []
        controller.removeFromTasks = { removed.append($0) }
        let menu = NotesLibraryView.hoverMenu(rowCommands(id, controller: controller, tasks: tasks,
            delete: { deleted.append($0) }), pinned: true)
        XCTAssertEqual(menu.map(\.title), ["Unpin", "Remove from Tasks", "Delete"])
        XCTAssertFalse(menu[1].isDestructive)
        menu[1].action(); menu[2].action()
        XCTAssertEqual(removed, [task.id])
        XCTAssertEqual(deleted, [id])
    }

    func testCommandReturnUsesTheNotesKeyHandlerButPlainReturnKeepsItsBaseScope() throws {
        let id = try create("Selected note", "Writing")
        let controller = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "OneItemKeys")), defaults: nil,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        XCTAssertTrue(controller.open(noteID: id))
        XCTAssertTrue(controller.showLibrary())
        let model = library(), keys = NotesLibraryKeys()
        var opened: [UUID] = []
        let view = NotesLibraryView(model: model, controller: controller, store: store,
            layout: PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 320, height: 460)),
            bottomClearance: 0, searchFocused: .constant(false), searchOpen: .constant(false),
            rowCommands: { _ in [] }, libraryCommands: { [] }, onOpen: { opened.append($0) },
            onDelete: { _ in }, onBack: {}, keys: keys)
        let host = NSHostingView(rootView: view.frame(width: 320, height: 460))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 320, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let handler = try XCTUnwrap(keys.handler, "the mounted library's real key handler")
        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
        }
        XCTAssertNil(model.highlightedID)
        XCTAssertEqual(controller.librarySelectionID, id)
        XCTAssertFalse(handler(try key([])), "plain Return outside search passes through without a keyboard highlight")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(handler(try key(.command)))
        XCTAssertEqual(opened, [id], "⌘Return opens the selected item")
        model.highlightedID = id
        XCTAssertTrue(handler(try key([])), "a keyboard-highlighted row still opens on Return")
        XCTAssertEqual(opened, [id, id])
    }

    // MARK: Thumbnails

    func testAThumbnailIsDrawnOncePerRevisionAndAppearance() throws {
        let cache = NoteThumbnailCache()
        let id = UUID()
        let content = NoteThumbnailContent(title: "Launch plan", text: "Kyoto offsite agenda and more", hasImages: true)
        let key = NoteThumbnailCache.Key(content: content, dark: false, scale: 2)
        XCTAssertNil(cache.cached(id, key: key), "a body only looks up")
        let image = try XCTUnwrap(cache.image(id, key: key))
        let m = NoteThumbnailMetrics.self
        XCTAssertEqual(image.width, Int((m.size.width + 2 * m.margin) * 2))
        XCTAssertEqual(image.height, Int((m.size.height + 2 * m.margin) * 2))
        XCTAssertEqual(cache.renderCount, 1)
        cache.image(id, key: key)
        XCTAssertNotNil(cache.cached(id, key: key))
        XCTAssertEqual(cache.renderCount, 1, "the same revision is never drawn again")

        let edited = NoteThumbnailCache.Key(content: NoteThumbnailContent(title: "Launch plan", text: "Changed", hasImages: true),
                                            dark: false, scale: 2)
        XCTAssertNil(cache.cached(id, key: edited))
        cache.image(id, key: edited)
        cache.image(id, key: NoteThumbnailCache.Key(content: edited.content, dark: true, scale: 2))
        XCTAssertEqual(cache.renderCount, 3)

        cache.keep(only: [])
        XCTAssertNil(cache.cached(id, key: edited), "a gone note's thumbnail goes")
    }

    func testSW01EvictingOneThumbnailKeepsTheRestOfTheCache() throws {
        let cache = NoteThumbnailCache()
        let key = NoteThumbnailCache.Key(content: NoteThumbnailContent(title: "A", text: "B", hasImages: false), dark: false, scale: 1)
        let ids = (0...NoteThumbnailCache.limit).map { _ in UUID() }
        for id in ids { XCTAssertNotNil(cache.image(id, key: key)) }
        XCTAssertNil(cache.cached(ids[0], key: key), "The oldest entry may be evicted")
        XCTAssertNotNil(cache.cached(ids[1], key: key), "Inserting one entry must not evict every cached image")
        XCTAssertNotNil(cache.cached(ids[NoteThumbnailCache.limit], key: key))
    }

    // MARK: Geometry

    func testARowIsTheDesignsHeightWithItsThumbnailAndTwoLines() throws {
        let id = try create("Launch plan", "Kyoto offsite agenda", tags: ["launch"])
        let model = library()
        let row = try XCTUnwrap(model.groups(store: store, drafts: []).flatMap(\.rows).first { $0.id == id })
        let view = NotesLibraryRow(details: model.libraryRow(row, store: store), thumbnails: model.thumbnails,
                                   commands: { [] }, anchors: AtticNoteRowAnchors(), onShowActions: {}, onOpen: {})
            .frame(width: 300)
            .atticDesign(.default)
        let hosting = NSHostingView(rootView: view)
        // 12 px padding, the 60 px thumbnail, 12 px: 84 px.
        XCTAssertEqual(NotesLibraryRowMetrics.height, 42)
        XCTAssertEqual(hosting.fittingSize.height, 42, accuracy: 0.5)
    }
}
