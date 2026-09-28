import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Control-audit items 13, 15 (library part) and 17 (Phase 2 audit): the
/// library's commands and keys, the library history, and the recovery copy.
@MainActor
final class NotesAuditTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticAudit-\(UUID().uuidString)")
        suiteName = "AtticAudit-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeController() -> NotesPageController {
        NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                            defaults: defaults, saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
    }

    private func create(_ blocks: [NoteBlock], tags: [String] = []) throws -> UUID {
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks),
                                                                   tags: tags.isEmpty ? nil : tags) else {
            throw NSError(domain: "create", code: 1)
        }
        return id
    }

    // MARK: 13. The library's commands and keys

    func testTheLibraryRowKeysAreExplicitAndTheEditorChordsStayTheirOwn() {
        func action(_ code: UInt16, _ modifiers: EventModifiers, field: Bool = false, composing: Bool = false) -> NotesLibraryView.KeyAction {
            NotesLibraryView.keyAction(keyCode: code, modifiers: modifiers, characters: nil, composing: composing, fieldFocused: field)
        }
        XCTAssertEqual(action(34, [.command, .shift]), .actions, "⇧⌘I opens the row's actions")
        XCTAssertEqual(action(2, .command), .duplicate, "⌘D duplicates the row")
        XCTAssertEqual(action(8, [.command, .option, .shift]), .copyMarkdown, "⌥⇧⌘C copies the row as Markdown")
        // They work with the search field focused: none of them is text editing.
        XCTAssertEqual(action(34, [.command, .shift], field: true), .actions)
        XCTAssertEqual(action(2, .command, field: true), .duplicate)
        // Other chords of the same keys stay somebody else's.
        XCTAssertEqual(action(34, .command), .passThrough)
        XCTAssertEqual(action(2, [.command, .shift]), .passThrough)
        XCTAssertEqual(action(8, .command), .passThrough)
        XCTAssertEqual(action(8, [.command, .shift]), .passThrough)
        // An input method that is composing keeps every key.
        XCTAssertEqual(action(2, .command, field: true, composing: true), .passThrough)
    }

    func testTheLibraryCommandTargetIsTheHighlightedRowElseTheSelectedOneAndNeverAHiddenRow() throws {
        let a = try create([.text("Alpha")])
        let b = try create([.text("Beta")])
        let library = NotesLibraryModel(search: { _ in [] })
        let all = library.groups(store: store, drafts: [])
        XCTAssertNil(library.commandTarget(in: all, selected: nil))
        XCTAssertEqual(library.commandTarget(in: all, selected: a), a, "the selected note, when nothing is highlighted")
        library.moveHighlight(by: 1, in: all, from: nil)
        let highlighted = try XCTUnwrap(library.highlightedID)
        XCTAssertEqual(library.commandTarget(in: all, selected: a), highlighted, "the keyboard's row wins")
        // The search field being focused does not matter (unlike ⌘⌫).
        XCTAssertEqual(library.deleteTarget(in: all, selected: a, inField: true), highlighted)
        library.highlightedID = nil
        XCTAssertNil(library.deleteTarget(in: all, selected: a, inField: true), "⌘⌫ edits text in the field")
        XCTAssertEqual(library.commandTarget(in: all, selected: b), b)
        // A row the list does not show is never a target.
        XCTAssertNil(library.commandTarget(in: [], selected: a))
        library.highlightedID = a
        XCTAssertNil(library.commandTarget(in: [], selected: a))
    }

    func testARunningCommandIsFoundByIdentifierAndADisabledOneIsSwallowed() {
        var ran: [String] = []
        let commands = [
            AtticMenuCommand("Copy as Markdown", identifier: "notes-row-copy-markdown") { ran.append("copy") },
            AtticMenuCommand("Duplicate", isDisabled: true, identifier: "notes-row-duplicate") { ran.append("duplicate") }
        ]
        XCTAssertTrue(NotesLibraryView.run("notes-row-copy-markdown", in: commands))
        XCTAssertTrue(NotesLibraryView.run("notes-row-duplicate", in: commands), "found, and swallowed")
        XCTAssertFalse(NotesLibraryView.run("notes-row-missing", in: commands))
        XCTAssertEqual(ran, ["copy"], "the disabled Duplicate never ran")
    }

    func testVoiceOverGetsTheEnabledNamedActionsWithoutOpenOrSubmenus() {
        let commands = [
            AtticMenuCommand("Open", identifier: "notes-row-open") {},
            AtticMenuCommand("Pin to Top", startsSection: true, identifier: "notes-row-pin") {},
            AtticMenuCommand("Copy as Markdown", identifier: "notes-row-copy-markdown") {},
            AtticMenuCommand("Duplicate", isDisabled: true, identifier: "notes-row-duplicate") {},
            AtticMenuCommand("More", submenu: [AtticMenuCommand("Inner") {}]),
            AtticMenuCommand("Delete Note", isDestructive: true, identifier: "notes-row-delete") {}
        ]
        XCTAssertEqual(AtticNoteRow.spokenActions(commands).map(\.title), ["Pin to Top", "Copy as Markdown", "Delete Note"])
    }

    func testTheNativeMenuForTheRowCarriesTheSameCommandsIdentifiersAndShortcuts() {
        let commands = [
            AtticMenuCommand("Open", identifier: "notes-row-open") {},
            AtticMenuCommand("Duplicate", shortcut: KeyboardShortcut("d", modifiers: .command), startsSection: true,
                             identifier: "notes-row-duplicate") {},
            AtticMenuCommand("Delete Note", shortcut: KeyboardShortcut(.delete, modifiers: .command), isDestructive: true,
                             startsSection: true, identifier: "notes-row-delete") {}
        ]
        let menu = AtticNativeMenu.make(commands)
        let ids = menu.items.compactMap { $0.identifier?.rawValue }
        XCTAssertEqual(ids, ["notes-row-open", "notes-row-duplicate", "notes-row-delete"])
        XCTAssertEqual(menu.items.first { $0.title == "Duplicate" }?.keyEquivalent, "d")
    }

    // MARK: 15. The library's history

    private func liveIDs() -> Set<UUID> { Set(store.notes.map(\.id)) }

    func testDeleteUndoAndRedoWorkWithNoToastAtAll() throws {
        let controller = makeController()
        let id = try create([.text("Alpha")])
        XCTAssertFalse(controller.canUndoLibrary)
        XCTAssertTrue(controller.deleteNote(noteID: id))
        XCTAssertNil(store.note(withID: id))
        XCTAssertEqual(controller.libraryUndoName, "Delete Note")
        // The toast is only a shortcut to this step: the history holds it.
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertNotNil(store.note(withID: id), "Undo brings the note back")
        XCTAssertNil(controller.libraryUndoName)
        XCTAssertEqual(controller.libraryRedoName, "Delete Note")
        XCTAssertTrue(controller.redoLibrary())
        XCTAssertNil(store.note(withID: id), "Redo deletes it again")
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertNotNil(store.note(withID: id))
    }

    func testEachActionIsOneStepInOrderAndUndoWalksBackThroughThem() throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        let b = try create([.text("Beta")])
        XCTAssertTrue(controller.setPinned(true, noteID: a))
        XCTAssertTrue(controller.duplicateNote(noteID: b))
        let copies = liveIDs().subtracting([a, b])
        XCTAssertEqual(copies.count, 1)
        XCTAssertTrue(controller.showLibrary())
        XCTAssertTrue(controller.deleteNote(noteID: b))
        XCTAssertEqual(controller.libraryUndoName, "Delete Note")

        XCTAssertTrue(controller.undoLibrary())
        XCTAssertNotNil(store.note(withID: b))
        XCTAssertEqual(controller.libraryUndoName, "Duplicate Note")
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertTrue(liveIDs().isDisjoint(with: copies), "the copy is gone")
        XCTAssertEqual(controller.libraryUndoName, "Pin Note")
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertEqual(store.note(withID: a)?.isPinned, false)
        XCTAssertFalse(controller.canUndoLibrary)

        XCTAssertTrue(controller.redoLibrary())
        XCTAssertEqual(store.note(withID: a)?.isPinned, true)
        XCTAssertTrue(controller.redoLibrary())
        XCTAssertEqual(liveIDs().subtracting([a, b]), copies, "Redo restores the same copy")
        XCTAssertTrue(controller.redoLibrary())
        XCTAssertNil(store.note(withID: b))
    }

    func testPinningWithoutAChangeAndANewActionAfterUndoShapeTheHistory() throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        XCTAssertTrue(controller.setPinned(false, noteID: a), "already unpinned")
        XCTAssertFalse(controller.canUndoLibrary, "a pin that changed nothing is not a step")
        controller.setPinned(true, noteID: a)
        XCTAssertEqual(controller.libraryUndoName, "Pin Note")
        controller.undoLibrary()
        XCTAssertEqual(controller.libraryRedoName, "Pin Note")
        controller.setPinned(true, noteID: a)
        XCTAssertFalse(controller.canRedoLibrary, "a new action clears Redo")
        controller.setPinned(false, noteID: a)
        XCTAssertEqual(controller.libraryUndoName, "Unpin Note")
    }

    func testUndoOfDeleteReopensTheNoteOnlyWhenItWasOnScreen() throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        let b = try create([.text("Beta")])
        XCTAssertTrue(controller.open(noteID: a))
        controller.isLibraryPresented = false
        XCTAssertTrue(controller.deleteNote(noteID: a))
        XCTAssertTrue(controller.isLibraryPresented, "deleting the open note shows All notes")
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertEqual(controller.active?.noteID, a)
        XCTAssertFalse(controller.isLibraryPresented, "the note on screen comes back on screen")
        // A note deleted from the library comes back into the library.
        XCTAssertTrue(controller.showLibrary())
        XCTAssertTrue(controller.deleteNote(noteID: b))
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertTrue(controller.isLibraryPresented)
        XCTAssertNotNil(store.note(withID: b))
    }

    func testAStepThatCanNeverApplyIsDroppedAndOneThatFailedIsKept() throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        XCTAssertTrue(controller.deleteNote(noteID: a))
        // Restored somewhere else (Settings' Recently Deleted): the step is stale.
        XCTAssertTrue(store.restoreDeleted(noteID: a))
        XCTAssertFalse(controller.undoLibrary(), "nothing to undo any more")
        XCTAssertFalse(controller.canUndoLibrary, "an obsolete step is dropped")

        let b = try create([.text("Beta")])
        XCTAssertTrue(controller.deleteNote(noteID: b))
        gate.shouldFail = true
        XCTAssertFalse(controller.undoLibrary(), "the store refused the restore")
        XCTAssertTrue(controller.canUndoLibrary, "a failed step stays, so a retry can work")
        XCTAssertNil(store.note(withID: b))
        gate.shouldFail = false
        XCTAssertTrue(controller.undoLibrary())
        XCTAssertNotNil(store.note(withID: b))
    }

    func testAPinStepFindsTheNoteGoneOrAlreadyInTheStateItWants() throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        controller.setPinned(true, noteID: a)
        store.setPinned(false, noteID: a)              // changed elsewhere
        XCTAssertTrue(controller.undoLibrary(), "already unpinned: applied, nothing to do")
        XCTAssertEqual(store.note(withID: a)?.isPinned, false)
        controller.setPinned(true, noteID: a)
        let note = try XCTUnwrap(store.note(withID: a))
        XCTAssertTrue(store.delete(note))
        XCTAssertFalse(controller.undoLibrary(), "the note is gone")
        XCTAssertFalse(controller.canUndoLibrary, "so the step is dropped")
    }

    func testTheHistoryFollowsTheAppRouteAndAnnouncesEveryChange() throws {
        let controller = makeController()
        let route = UndoRoute()
        controller.attachUndoRoute(route)
        let a = try create([.text("Alpha")])
        let before = controller.undoRevision
        controller.setPinned(true, noteID: a)
        XCTAssertGreaterThan(controller.undoRevision, before, "menus redraw when a step is recorded")
        XCTAssertTrue(route.canUndo(in: .notesLibrary))
        XCTAssertFalse(route.canUndo(in: .library), "apart from Recently Deleted and tag changes")
        let recorded = controller.undoRevision
        controller.undoLibrary()
        XCTAssertGreaterThan(controller.undoRevision, recorded)
    }

    func testTheUndoKeysBelongToTheLibraryUnlessTheSearchFieldHasTextToUndo() {
        func action(_ modifiers: EventModifiers, field: Bool = false, canUndo: Bool = false, canRedo: Bool = false) -> NotesLibraryView.KeyAction {
            NotesLibraryView.keyAction(keyCode: 6, modifiers: modifiers, characters: nil, composing: false, fieldFocused: field,
                                       fieldCanUndo: canUndo, fieldCanRedo: canRedo)
        }
        XCTAssertEqual(action(.command), .undo)
        XCTAssertEqual(action([.command, .shift]), .redo)
        XCTAssertEqual(action(.command, field: true), .undo, "an empty field has nothing of its own")
        XCTAssertEqual(action(.command, field: true, canUndo: true), .passThrough, "typed search text is undone first")
        XCTAssertEqual(action([.command, .shift], field: true, canRedo: true), .passThrough)
        XCTAssertEqual(action([.command, .option]), .passThrough)
        XCTAssertEqual(action(.control), .passThrough)
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 6, modifiers: .command, characters: nil, composing: true,
                                                  fieldFocused: true), .passThrough, "a composing input method keeps every key")
    }

    func testLibraryStepsLiveInTheirOwnHistoryApartFromNotesAndTasks() throws {
        let route = UndoRoute()
        let controller = makeController()
        controller.attachUndoRoute(route)
        let a = try create([.text("Alpha")])
        controller.setPinned(true, noteID: a)
        // The editor's typing history is the text view's own; the library's
        // steps sit in one named history and answer only where the library's
        // key handler asks for them.
        XCTAssertEqual(route.undoCount(in: .notesLibrary), 1)
        XCTAssertEqual(route.undoCount(in: .note(a)), 0)
        XCTAssertEqual(route.undoCount(in: .tasks), 0)
    }
}
