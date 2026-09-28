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
}
