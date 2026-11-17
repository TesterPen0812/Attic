import Combine
import SwiftData
import XCTest
@testable import Attic

/// Build 2 of the write path (`ops/design/write-path.md`, "Build 2's scope", 17 Nov): the shared tag
/// inventory is kept current after each durable save, and no reader rebuilds it. Every reader of the
/// inventory a redraw can reach runs after every control: the page's chips, the add bar and the "+"
/// card while focused, the pickers, Notes' counts, and the colour refresh (main queue). Each control
/// is followed by a check that the kept inventory equals one built from scratch.
@MainActor
final class TagInventoryLifeTests: XCTestCase {
    private struct Rig {
        let container: ModelContainer
        let library: AtticLibrary
        let notes: NoteStore
        let page: TasksPageModel
        let composer: ComposerModel
    }

    private final class Switch { var on = false }

    private static let pool = ["motion", "design", "home", "errand", "reading", "focus", "later-maybe", "admin"]

    /// A small tracker-shaped store: nearly every open task tagged (two or three tags each), a tagged
    /// Done log, tagged notes, and one tag carried only by an archived task.
    /// - `failingNoteReloads`: while on, every fresh context the Notes store asks for fails, so its
    ///   presentation reloads fail.
    /// - `taskSaveLandsThenThrows`: while on, the task store's writes reach the store and then throw.
    private func makeRig(failingNoteReloads: Switch? = nil, taskSaveLandsThenThrows: Switch? = nil) throws -> Rig {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<24 {
            let status: TaskStatus = index < 3 ? .inProgress : index < 14 ? .todo : .backlog
            let task = TaskItem(title: "Open task \(index) with a title of everyday length", status: status,
                                createdAt: base.addingTimeInterval(Double(index) * 60), manualOrder: Int64(index) * 1_024)
            task.listOrderVersion = TaskItem.currentListOrderVersion
            if index != 5 {
                task.tags = (0..<(2 + index % 2)).map { Self.pool[(index + $0 * 3) % Self.pool.count] }
            }
            seed.insert(task)
        }
        for index in 0..<10 {
            let task = TaskItem(title: "Logged task \(index)", status: .done,
                                createdAt: base.addingTimeInterval(-Double(index + 1) * 3_600),
                                completedAt: base.addingTimeInterval(-Double(index) * 600 - 86_400 * 2))
            task.doneLoggedAt = task.completedAt
            task.tags = index == 0 ? ["archived-only"] : [Self.pool[index % Self.pool.count]]
            seed.insert(task)
        }
        for index in 0..<6 {
            let note = NoteItem(title: "Note \(index)", createdAt: base.addingTimeInterval(Double(index) * 30))
            note.tags = index == 0 ? ["note-only"] : [Self.pool[(index * 5) % Self.pool.count]]
            seed.insert(note)
        }
        try seed.save()
        let tasks = TaskStore(container: container, persist: { context in
            try context.save()
            if taskSaveLandsThenThrows?.on == true { throw WorkspaceFoundationError.unknown }
        })
        let freshNoteContext: (() throws -> ModelContext)? = failingNoteReloads.map { failing in {
            if failing.on { throw NSError(domain: "TagInventoryLifeTests", code: 2) }
            return ModelContext(container)
        } }
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container,
                                                               attachmentFileStore: makeTestAttachmentFileStore(),
                                                               makeFreshContext: freshNoteContext))
        let library = AtticLibrary(tasks: tasks, notes: notes)
        let page = TasksPageModel(library: library, services: TasksPageServices())
        let composer = ComposerModel(tasks: page, services: ComposerServices())
        return Rig(container: container, library: library, notes: notes, page: page, composer: composer)
    }

    /// What a redraw of every built page reads after a change, plus the colour refresh's turn.
    private func readAsRedraw(_ rig: Rig) {
        drainMainQueue()
        _ = rig.page.tagChips()
        // The focused add bar's body (`TasksAddBar.suggestion`, private) reads exactly this.
        let addBar = rig.page.addBarState
        _ = addBar.text.suggestion(parser: rig.page.parser, caret: addBar.caret, tags: rig.page.cachedTags)
        _ = rig.composer.suggestion(focused: true)
        _ = rig.page.tagChoices(for: rig.page.rows(for: .now).prefix(1).map(\.id))
        _ = rig.page.composerTagChoices
        _ = rig.notes.tagCounts
        drainMainQueue()
    }

    private func drainMainQueue() {
        for _ in 0..<2 {
            let drained = expectation(description: "main queue")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 5)
        }
    }

    /// The kept inventory equals one built from scratch on the same store: counts, ordered names and
    /// the colour order.
    private func assertMatchesFreshBuild(_ rig: Rig, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = TagService(container: rig.container)
        XCTAssertEqual(rig.library.tags.counts(), fresh.counts(), "\(step): counts", file: file, line: line)
        XCTAssertEqual(rig.library.tags.names, fresh.names, "\(step): names", file: file, line: line)
        XCTAssertEqual(rig.library.tags.namesOldestFirst, fresh.namesOldestFirst, "\(step): colour order", file: file, line: line)
    }

    private func openRow(_ rig: Rig, _ salt: Int) throws -> UUID {
        let open = rig.page.rows(for: .now).filter { $0.status == .todo }
        guard !open.isEmpty else { throw XCTSkip("no open rows") }
        return open[salt % open.count].id
    }

    private func createFromCard(_ rig: Rig, _ text: String, writing: String? = nil) {
        if !rig.composer.isOpen { rig.composer.open(on: .tasks(.now)) }
        rig.page.addBar = TaskAddBarText(text: text)
        rig.page.addBarCaret = nil
        if let writing { rig.composer.writing = writing }
        rig.composer.submit()
        _ = rig.page.settlePendingCompletionAcknowledgements()
        if rig.composer.isOpen { rig.composer.close() }
    }

    /// The red test: across every control of a round, with every reader a redraw reaches, the shared
    /// inventory is never built again (`TagService.inventoryBuildCount`), Notes' own fallback is never
    /// built (`NoteStore.tagInventoryBuildCount`), and the kept inventory stays equal to a fresh build.
    func testNoControlRebuildsTheInventoryAndItStaysExact() throws {
        let rig = try makeRig()
        readAsRedraw(rig)
        assertMatchesFreshBuild(rig, "launch")
        let builds = rig.library.tags.inventoryBuildCount, noteBuilds = rig.notes.tagInventoryBuildCount
        var counts: [String: Int] = [:]
        func step(_ name: String, _ body: () throws -> Void) rethrows {
            let before = rig.library.tags.inventoryBuildCount
            try body()
            readAsRedraw(rig)
            counts[name] = rig.library.tags.inventoryBuildCount - before
            assertMatchesFreshBuild(rig, name)
        }
        for round in 0..<2 {
            let a = try openRow(rig, round * 7)
            try step("tick") { rig.page.completeAcknowledged(a) { _ in }; _ = rig.page.settlePendingCompletionAcknowledgements() }
            try step("untick") { _ = rig.page.reopen(a) }
            let b = try openRow(rig, round * 7 + 3)
            try step("priority") {
                rig.page.setPriorityAcknowledged(.high, for: [b]) { _ in }
                _ = rig.page.settlePendingCompletionAcknowledgements()
            }
            let c = try openRow(rig, round * 7 + 5)
            try step("tag menu") { _ = rig.page.toggleTag("motion", for: [c]) }
            try step("card create") { createFromCard(rig, "Card task \(round)") }
            try step("card create, tagged") { createFromCard(rig, "Tagged card task \(round) #fresh-\(round)") }
            try step("card with writing") { createFromCard(rig, "Card with writing \(round)", writing: "A line of writing.") }
            try step("add bar create") {
                rig.page.addBar = TaskAddBarText(text: "Add bar task \(round)")
                rig.page.addBarCaret = nil
                _ = rig.page.submitAddBar()
            }
            let d = try openRow(rig, round * 7 + 4)
            try step("delete") { _ = rig.page.delete([d]) }
            try step("undo") { _ = rig.page.undo() }
        }
        let rebuilt = counts.filter { $0.value != 0 }.sorted { $0.key < $1.key }
        print("ATTIC_TAG_INVENTORY_BUILDS " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        XCTAssertTrue(rebuilt.isEmpty, "controls that rebuilt the inventory: \(rebuilt)")
        XCTAssertEqual(rig.library.tags.inventoryBuildCount, builds, "no reader or control rebuilds the shared inventory")
        XCTAssertEqual(rig.notes.tagInventoryBuildCount, noteBuilds, "Notes' own inventory is never built while wired")
    }

    /// Where the inventory does not change (an untagged creation or deletion, a tick, a priority), it
    /// publishes nothing, so neither the Tasks page nor the Notes store hears about it.
    func testUnchangedInventoryPublishesNothing() throws {
        let rig = try makeRig()
        readAsRedraw(rig)
        var published: [String: Int] = [:], noteNotices: [String: Int] = [:]
        var current = ""
        let inventory = rig.library.tags.inventoryChanges.sink { published[current, default: 0] += 1 }
        let notes = rig.notes.objectWillChange.sink { noteNotices[current, default: 0] += 1 }
        func step(_ name: String, _ body: () throws -> Void) rethrows {
            current = name
            published[name] = 0; noteNotices[name] = 0
            try body()
            readAsRedraw(rig)
            current = ""
        }
        let a = try openRow(rig, 1)
        try step("tick") { rig.page.completeAcknowledged(a) { _ in }; _ = rig.page.settlePendingCompletionAcknowledgements() }
        try step("untick") { _ = rig.page.reopen(a) }
        try step("priority") {
            rig.page.setPriorityAcknowledged(.high, for: [a]) { _ in }
            _ = rig.page.settlePendingCompletionAcknowledgements()
        }
        try step("card create") { createFromCard(rig, "Untagged card task") }
        try step("add bar create") {
            rig.page.addBar = TaskAddBarText(text: "Untagged add bar task")
            rig.page.addBarCaret = nil
            _ = rig.page.submitAddBar()
        }
        let untagged = try XCTUnwrap(rig.page.rows(for: .now).first { $0.model.title == "Untagged add bar task" }).id
        try step("delete, untagged") { _ = rig.page.delete([untagged]) }
        print("ATTIC_TAG_INVENTORY_NOTICES published=\(published.sorted { $0.key < $1.key }) notes=\(noteNotices.sorted { $0.key < $1.key })")
        for (name, count) in published { XCTAssertEqual(count, 0, "\(name) left the tags in use as they were, so nothing is published") }
        for name in ["tick", "untick", "priority", "card create", "add bar create"] {
            XCTAssertEqual(noteNotices[name], 0, "\(name): the Notes store hears nothing")
        }
        // A real change still publishes, once, after the durable save.
        published = [:]
        try step("tag menu") { _ = rig.page.toggleTag("brand-new", for: [a]) }
        XCTAssertEqual(published["tag menu"], 1)
        XCTAssertEqual(rig.library.tags.countsByName["brand-new"], 1)
        withExtendedLifetime((inventory, notes)) {}
    }

    /// Pro's case for build 2: in the first publication after deleting, restoring and re-tagging the
    /// last archived item that carries a tag, the chips, the counts and Done membership agree.
    func testFirstPublicationAgreesWithTheDoneIndex() throws {
        let rig = try makeRig()
        readAsRedraw(rig)
        let tasks = rig.library.tasks
        let archived = try XCTUnwrap(tasks.doneLog().first { $0.tags == ["archived-only"] })
        var seen: [(chips: Bool, counted: Bool, indexed: Bool)] = []
        let observation = rig.library.tags.inventoryChanges.sink {
            seen.append((rig.page.tagChips().contains("archived-only"),
                         rig.library.tags.countsByName["archived-only"] != nil,
                         tasks.indexedDoneLogTags().contains("archived-only")))
        }
        func expectFirst(_ step: String, present: Bool, _ body: () -> Void) {
            seen = []
            body()
            readAsRedraw(rig)
            guard let first = seen.first else { return XCTFail("\(step): nothing was published") }
            XCTAssertEqual(first.chips, present, "\(step): chips")
            XCTAssertEqual(first.counted, present, "\(step): counts")
            XCTAssertEqual(first.indexed, present, "\(step): Done index")
            assertMatchesFreshBuild(rig, step)
        }
        let id = archived.id
        // A Done-log item is re-tagged through the tag editor's rename (row edits reach live rows only).
        expectFirst("re-tag away", present: false) { XCTAssertTrue(rig.library.renameTag("archived-only", to: "re-tagged")) }
        expectFirst("re-tag back", present: true) { XCTAssertTrue(rig.library.renameTag("re-tagged", to: "archived-only")) }
        expectFirst("delete", present: false) { XCTAssertTrue(tasks.delete(taskIDs: [id], includingDoneLog: true)) }
        expectFirst("restore", present: true) { XCTAssertTrue(tasks.restoreDeleted(taskID: id)) }
        withExtendedLifetime(observation) {}
    }

    /// Changes the inventory cannot see as they are made still end exact, and are handled by the
    /// model where they happen, never by the first reader: a write in another context followed by a
    /// reload, a failed reload, a rename and a merge, a note-only change, and a save that fails.
    func testOtherPathsEndExactWithoutAReaderBuilding() throws {
        let rig = try makeRig()
        readAsRedraw(rig)
        func readersBuildNothing(_ step: String, _ body: () throws -> Void) rethrows {
            try body()
            let builds = rig.library.tags.inventoryBuildCount
            readAsRedraw(rig)
            XCTAssertEqual(rig.library.tags.inventoryBuildCount, builds, "\(step): a reader built the inventory")
            assertMatchesFreshBuild(rig, step)
        }
        try readersBuildNothing("write elsewhere, then reload") {
            let other = ModelContext(rig.container)
            let row = try XCTUnwrap(other.fetch(FetchDescriptor<TaskItem>()).first { !$0.tags.isEmpty && $0.deletedAt == nil })
            row.tags = ["written-elsewhere"]
            other.insert({ let note = NoteItem(title: "Elsewhere"); note.tags = ["elsewhere-note"]; return note }())
            try other.save()
            rig.library.refreshItemStores()
        }
        try readersBuildNothing("failed reload") {
            let other = ModelContext(rig.container)
            let row = try XCTUnwrap(other.fetch(FetchDescriptor<TaskItem>()).first { $0.tags.contains("errand") })
            row.tags = ["after-failed-reload"]
            try other.save()
            #if DEBUG
            rig.library.tasks.listRefreshFailures = 1
            #endif
            rig.library.tasks.refresh()
        }
        try readersBuildNothing("rename") { XCTAssertTrue(rig.library.renameTag("design", to: "craft")) }
        try readersBuildNothing("merge") { XCTAssertTrue(rig.library.mergeTags(["home", "admin"], into: "household")) }
        try readersBuildNothing("note-only change") {
            let note = try XCTUnwrap(rig.notes.notes.first { $0.tags == ["note-only"] })
            XCTAssertTrue(rig.notes.setTags(["note-only", "note-second"], for: note))
        }
        try readersBuildNothing("tagged document note, presented without a reload") {
            guard case .success = rig.notes.createDocumentNote(id: UUID(),
                document: NoteDocument(blocks: [.text("Document")]), tags: ["document-only"]) else { return XCTFail("not created") }
            XCTAssertEqual(rig.library.tags.countsByName["document-only"], 1)
        }
        try readersBuildNothing("replica that disagrees") {
            let other = ModelContext(rig.container)
            let row = try XCTUnwrap(other.fetch(FetchDescriptor<TaskItem>()).first { $0.tags.contains("focus") && $0.deletedAt == nil })
            let replica = TaskItem(id: row.id, title: row.title, status: row.status, createdAt: row.createdAt,
                                   updatedAt: row.updatedAt.addingTimeInterval(60))
            replica.tags = ["replica-wins"]
            other.insert(replica)
            try other.save()
            rig.library.refreshItemStores()
        }
    }

    /// Dot's R-1 (PR 21): a note written outside the Notes store (Merge into This Note stages the
    /// alternate's deletion in the coordinator's transaction), then item-store reloads where the
    /// task reload succeeds and the Notes reload fails. The model rebuilds the inventory from the
    /// store; the deleted note's tag is gone before any later Notes reload succeeds, and no reader
    /// builds it.
    func testFailedNotesReloadAfterAnOutsideNoteWriteLeavesNoStaleTag() throws {
        let failing = Switch()
        let rig = try makeRig(failingNoteReloads: failing)
        readAsRedraw(rig)
        XCTAssertEqual(rig.library.tags.countsByName["note-only"], 1)
        let other = ModelContext(rig.container)
        let note = try XCTUnwrap(other.fetch(FetchDescriptor<NoteItem>()).first { $0.tags == ["note-only"] })
        note.deletedAt = Date()
        try other.save()
        failing.on = true
        rig.library.refreshItemStores()
        let builds = rig.library.tags.inventoryBuildCount
        readAsRedraw(rig)
        XCTAssertEqual(rig.library.tags.inventoryBuildCount, builds, "a reader built the inventory")
        XCTAssertNil(rig.library.tags.countsByName["note-only"], "a deleted note's tag stays counted")
        XCTAssertNil(rig.notes.tagCounts["note-only"], "Notes' counts still offer a deleted note's tag")
        assertMatchesFreshBuild(rig, "failed Notes reload")
        failing.on = false
    }

    /// Astra's R-1 (PR 21): a task save whose outcome stays unresolved. Deleting a task deletes its
    /// writing in the same journaled commit; the write lands, then throws, and the coordinator cannot
    /// read back what happened (`WorkspaceFoundationError.unknown`, not `CommitHeld`). Nothing
    /// reloads the Notes store afterwards. The model rebuilds from the store: the deleted writing's
    /// tag is gone, and no reader builds it.
    func testUnresolvedSaveOutcomeLeavesNoStaleTag() throws {
        let landsThenThrows = Switch()
        let rig = try makeRig(taskSaveLandsThenThrows: landsThenThrows)
        createFromCard(rig, "Task with tagged writing", writing: "Its writing.")
        let id = try XCTUnwrap(rig.library.tasks.tasks.first { $0.title == "Task with tagged writing" }?.id)
        let other = ModelContext(rig.container)
        let writing = try XCTUnwrap(WorkspaceItemLifecycle.writing(taskIDs: [id], in: other).first)
        writing.tags = ["writing-only"]
        try other.save()
        rig.library.refreshItemStores()
        readAsRedraw(rig)
        XCTAssertEqual(rig.library.tags.countsByName["writing-only"], 1)
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: rig.container)
        landsThenThrows.on = true
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        XCTAssertFalse(rig.library.tasks.delete(taskIDs: [id]))
        landsThenThrows.on = false
        coordinator.beforeReconciliationRead = nil
        let stored = try ModelContext(rig.container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == writing.id }
        XCTAssertTrue(!stored.isEmpty && stored.allSatisfy { $0.deletedAt != nil }, "the writing's deletion reached the store")
        let builds = rig.library.tags.inventoryBuildCount
        readAsRedraw(rig)
        XCTAssertEqual(rig.library.tags.inventoryBuildCount, builds, "a reader built the inventory")
        XCTAssertNil(rig.library.tags.countsByName["writing-only"], "a deleted writing's tag stays counted")
        assertMatchesFreshBuild(rig, "unresolved save outcome")
        XCTAssertTrue(rig.library.tasks.setPriority(.high, for: try XCTUnwrap(rig.library.tasks.task(withID: try openRow(rig, 1)))))
        readAsRedraw(rig)
        XCTAssertNil(rig.library.tags.countsByName["writing-only"], "an unrelated save brings the stale tag back")
    }

    /// Opus's R-2 (PR 21): a publication that reloads only the task store after a commit that also
    /// changed a note (Remove from Tasks while a newer draft exists writes the task's tags to its
    /// note and retires the task; a Merge Notes Undo whose session moved flips the alternate note).
    /// A reload of one store after a commit made elsewhere reads the other kinds from the store, in
    /// the model.
    func testTasksOnlyReloadAfterACommitThatChangedANoteLeavesNoStaleTag() throws {
        let rig = try makeRig()
        readAsRedraw(rig)
        let other = ModelContext(rig.container)
        let task = try XCTUnwrap(other.fetch(FetchDescriptor<TaskItem>()).first { $0.tags.contains("reading") && $0.deletedAt == nil && $0.doneLoggedAt == nil })
        let note = try XCTUnwrap(other.fetch(FetchDescriptor<NoteItem>()).first { $0.tags == ["note-only"] })
        note.tags = ["note-only", "moved-from-task"]
        task.deletedAt = Date()
        try other.save()
        rig.library.tasks.refresh()
        let builds = rig.library.tags.inventoryBuildCount
        readAsRedraw(rig)
        XCTAssertEqual(rig.library.tags.inventoryBuildCount, builds, "a reader built the inventory")
        XCTAssertEqual(rig.library.tags.countsByName["moved-from-task"], 1, "the note's new tag is missing")
        assertMatchesFreshBuild(rig, "tasks-only reload after a commit that changed a note")
        // The Notes store's own reload alone, after a commit that also changed a task.
        let again = ModelContext(rig.container)
        let tagged = try XCTUnwrap(again.fetch(FetchDescriptor<TaskItem>()).first { $0.tags.contains("errand") && $0.deletedAt == nil })
        tagged.tags = ["errand", "from-notes-commit"]
        let sameNote = try XCTUnwrap(again.fetch(FetchDescriptor<NoteItem>()).first { $0.id == note.id })
        sameNote.tags = ["note-only"]
        try again.save()
        rig.notes.refresh()
        let builds2 = rig.library.tags.inventoryBuildCount
        readAsRedraw(rig)
        XCTAssertEqual(rig.library.tags.inventoryBuildCount, builds2, "a reader built the inventory")
        XCTAssertEqual(rig.library.tags.countsByName["from-notes-commit"], 1, "the task's new tag is missing")
        assertMatchesFreshBuild(rig, "Notes-only reload after a commit that changed a task")
    }

    /// Every way a save can fail leaves the inventory exact, and no reader builds it afterwards: a
    /// failed task edit, a failed creation, a failed note edit, and a held task edit whose write
    /// landed (`CommitHeld`). The build count is taken after each failure and before the first
    /// reader, so a reader's rebuild is told apart from the model's own rebuild.
    func testFailedSavesLeaveTheInventoryExact() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let task = TaskItem(title: "Tagged")
        task.tags = ["kept"]
        seed.insert(task)
        let note = NoteItem(title: "Tagged note")
        note.tags = ["note-kept"]
        seed.insert(note)
        try seed.save()
        enum Mode { case saves, throwsBefore, landsThenThrows }
        var mode = Mode.saves
        let persist: (ModelContext) throws -> Void = { context in
            if mode == .throwsBefore { throw NSError(domain: "TagInventoryLifeTests", code: 1) }
            try context.save()
            if mode == .landsThenThrows { throw NSError(domain: "TagInventoryLifeTests", code: 3) }
        }
        let tasks = TaskStore(container: container, persist: persist)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, persist: persist,
                                                               attachmentFileStore: makeTestAttachmentFileStore()))
        let library = AtticLibrary(tasks: tasks, notes: notes, persist: persist)
        XCTAssertEqual(library.tags.countsByName, ["kept": 1, "note-kept": 1])
        func readersBuildNothing(_ step: String, expected: [String: Int]? = nil, _ body: () throws -> Void) rethrows {
            try body()
            mode = .saves
            let afterFailure = library.tags.inventoryBuildCount
            _ = library.tags.countsByName
            _ = library.tags.counts()
            _ = library.tags.names
            _ = library.tags.namesOldestFirst
            _ = notes.tagCounts
            XCTAssertEqual(library.tags.inventoryBuildCount, afterFailure, "\(step): a reader built the inventory")
            let fresh = TagService(container: container)
            if let expected { XCTAssertEqual(library.tags.countsByName, expected, "\(step): counts") }
            XCTAssertEqual(library.tags.counts(), fresh.counts(), "\(step): counts against the store")
            XCTAssertEqual(library.tags.namesOldestFirst, fresh.namesOldestFirst, "\(step): colour order")
        }
        try readersBuildNothing("failed task tag edit", expected: ["kept": 1, "note-kept": 1]) {
            mode = .throwsBefore
            XCTAssertFalse(tasks.setTags(["lost"], for: try XCTUnwrap(tasks.tasks.first)))
        }
        readersBuildNothing("failed creation", expected: ["kept": 1, "note-kept": 1]) {
            mode = .throwsBefore
            XCTAssertNil(tasks.create(title: "Not saved"))
        }
        try readersBuildNothing("failed note tag edit", expected: ["kept": 1, "note-kept": 1]) {
            mode = .throwsBefore
            XCTAssertFalse(notes.setTags(["note-lost"], for: try XCTUnwrap(notes.notes.first)))
        }
        try readersBuildNothing("held task tag edit whose write landed") {
            let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
            coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
            defer { coordinator.beforeReconciliationRead = nil }
            mode = .landsThenThrows
            _ = tasks.setTags(["landed"], for: try XCTUnwrap(tasks.tasks.first))
        }
    }
}
