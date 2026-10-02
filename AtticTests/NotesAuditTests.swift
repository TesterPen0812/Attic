import AppKit
import CryptoKit
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
        directory = ownedTemporaryDirectory(prefix: "AtticAudit")
        suiteName = "AtticAudit-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {

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

    func testTheLibraryRowKeysAreExplicitAndTheEditorChordsStayTheirOwn() async {
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

    func testTheLibraryCommandTargetIsTheHighlightedRowElseTheSelectedOneAndNeverAHiddenRow() async throws {
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

    func testARunningCommandIsFoundByIdentifierAndADisabledOneIsSwallowed() async {
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

    func testVoiceOverGetsTheEnabledNamedActionsWithoutOpenOrSubmenus() async {
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

    func testTheNativeMenuForTheRowCarriesTheSameCommandsIdentifiersAndShortcuts() async {
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

    func testDeleteUndoAndRedoWorkWithNoToastAtAll() async throws {
        let controller = makeController()
        let id = try create([.text("Alpha")])
        XCTAssertFalse(controller.canUndoLibrary)
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
        XCTAssertNil(store.note(withID: id))
        XCTAssertEqual(controller.libraryUndoName, "Delete Note")
        // The toast is only a shortcut to this step: the history holds it.
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertNotNil(store.note(withID: id), "Undo brings the note back")
        XCTAssertNil(controller.libraryUndoName)
        XCTAssertEqual(controller.libraryRedoName, "Delete Note")
        await XCTAssertTrueAsync(await controller.redoLibraryDurably())
        XCTAssertNil(store.note(withID: id), "Redo deletes it again")
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertNotNil(store.note(withID: id))
    }

    func testEachActionIsOneStepInOrderAndUndoWalksBackThroughThem() async throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        let b = try create([.text("Beta")])
        XCTAssertTrue(controller.setPinned(true, noteID: a))
        XCTAssertTrue(controller.duplicateNote(noteID: b))
        let copies = liveIDs().subtracting([a, b])
        XCTAssertEqual(copies.count, 1)
        XCTAssertTrue(controller.showLibrary())
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: b))
        XCTAssertEqual(controller.libraryUndoName, "Delete Note")

        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertNotNil(store.note(withID: b))
        XCTAssertEqual(controller.libraryUndoName, "Duplicate Note")
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertTrue(liveIDs().isDisjoint(with: copies), "the copy is gone")
        XCTAssertEqual(controller.libraryUndoName, "Pin Note")
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertEqual(store.note(withID: a)?.isPinned, false)
        XCTAssertFalse(controller.canUndoLibrary)

        await XCTAssertTrueAsync(await controller.redoLibraryDurably())
        XCTAssertEqual(store.note(withID: a)?.isPinned, true)
        await XCTAssertTrueAsync(await controller.redoLibraryDurably())
        XCTAssertEqual(liveIDs().subtracting([a, b]), copies, "Redo restores the same copy")
        await XCTAssertTrueAsync(await controller.redoLibraryDurably())
        XCTAssertNil(store.note(withID: b))
    }

    func testPinningWithoutAChangeAndANewActionAfterUndoShapeTheHistory() async throws {
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

    /// B1: pinning is decided across the whole UUID family. The presentation
    /// representative agreeing with the request must not hide a replica that
    /// disagrees, in the initial pin or in Undo and Redo.
    func testPinHistoryFollowsEveryReplicaNotTheRepresentative() async throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        XCTAssertTrue(store.setPinned(true, noteID: a))
        // A second physical row of the same note, unpinned: the presented
        // representative is the pinned one.
        let other = NoteItem(id: a, title: "Alpha", body: "Alpha")
        store.modelContext.insert(other)
        try store.modelContext.save()
        func replicas() throws -> [NoteItem] { try store.liveReplicas(of: a) }
        XCTAssertEqual(try replicas().count, 2)
        XCTAssertEqual(store.note(withID: a)?.isPinned, true, "the representative is already pinned")
        XCTAssertEqual(try replicas().filter(\.isPinned).count, 1)

        // Initial pin: the representative already agrees, but a replica does not.
        XCTAssertTrue(controller.setPinned(true, noteID: a))
        XCTAssertEqual(try replicas().map(\.isPinned), [true, true], "every replica is pinned")
        XCTAssertEqual(controller.libraryUndoName, "Pin Note", "the mutation is a history step")

        // Undo with the replicas diverged the other way round.
        let representative = try XCTUnwrap(store.note(withID: a))
        let sibling = try XCTUnwrap(try replicas().first { $0 !== representative })
        representative.pinnedAt = nil
        try store.modelContext.save()
        XCTAssertFalse(representative.isPinned)
        XCTAssertTrue(sibling.isPinned)
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertEqual(try replicas().map(\.isPinned), [false, false], "Undo unpins every replica")

        // Redo with the representative agreeing and the sibling not.
        representative.pinnedAt = Date()
        try store.modelContext.save()
        XCTAssertTrue(representative.isPinned)
        XCTAssertFalse(sibling.isPinned)
        await XCTAssertTrueAsync(await controller.redoLibraryDurably())
        XCTAssertEqual(try replicas().map(\.isPinned), [true, true], "Redo pins every replica")

        // Every replica already agrees: nothing changes and no step is added.
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertEqual(try replicas().map(\.isPinned), [false, false])
        XCTAssertTrue(controller.setPinned(false, noteID: a), "all replicas already unpinned")
        XCTAssertNil(controller.libraryUndoName, "a no-op is not a step")
    }

    func testUndoOfDeleteReopensTheNoteOnlyWhenItWasOnScreen() async throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        let b = try create([.text("Beta")])
        await XCTAssertTrueAsync(await controller.openDurably(noteID: a))
        controller.isLibraryPresented = false
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: a))
        XCTAssertTrue(controller.isLibraryPresented, "deleting the open note shows All notes")
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertEqual(controller.active?.noteID, a)
        XCTAssertFalse(controller.isLibraryPresented, "the note on screen comes back on screen")
        // A note deleted from the library comes back into the library.
        XCTAssertTrue(controller.showLibrary())
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: b))
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertTrue(controller.isLibraryPresented)
        XCTAssertNotNil(store.note(withID: b))
    }

    func testAStepThatCanNeverApplyIsDroppedAndOneThatFailedIsKept() async throws {
        let controller = makeController()
        let a = try create([.text("Alpha")])
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: a))
        // Restored somewhere else (Settings' Recently Deleted): the step is stale.
        XCTAssertTrue(store.restoreDeleted(noteID: a))
        XCTAssertFalse(controller.undoLibrary(), "nothing to undo any more")
        XCTAssertFalse(controller.canUndoLibrary, "an obsolete step is dropped")

        let b = try create([.text("Beta")])
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: b))
        gate.shouldFail = true
        XCTAssertFalse(controller.undoLibrary(), "the store refused the restore")
        XCTAssertTrue(controller.canUndoLibrary, "a failed step stays, so a retry can work")
        XCTAssertNil(store.note(withID: b))
        gate.shouldFail = false
        await XCTAssertTrueAsync(await controller.undoLibraryDurably())
        XCTAssertNotNil(store.note(withID: b))
    }

    func testAPinStepFindsTheNoteGoneOrAlreadyInTheStateItWants() async throws {
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

    func testTheHistoryFollowsTheAppRouteAndAnnouncesEveryChange() async throws {
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

    func testTheUndoKeysBelongToTheLibraryUnlessTheSearchFieldHasTextToUndo() async {
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

    func testLibraryStepsLiveInTheirOwnHistoryApartFromNotesAndTasks() async throws {
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

    // MARK: 17. Save Recovery Copy…

    private final class DeadJournal: NoteDraftJournaling {
        struct Failure: Error {}
        func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
                   replacing claim: NoteRecoveryClaim?) throws -> NoteRecoveryClaim { throw Failure() }
        func retire(noteID: UUID, claim: NoteRecoveryClaim?, saved: () -> NoteRecoverySavedState?) throws {}
        func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { [] }
    }

    private func pixel(_ name: String = "pixel.png") throws -> StagedNoteAttachment {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return StagedNoteAttachment(id: UUID(), filename: name, contentTypeIdentifier: "public.png",
                                    byteCount: Int64(bytes.count), digest: digest, data: bytes)
    }

    /// A note that is only in memory: typed text and an image, the store
    /// refusing the save and the recovery journal dead.
    private func onlyInMemoryNote(image: StagedNoteAttachment? = nil) async throws -> (NotesPageController, NoteSession) {
        let controller = NotesPageController(store: store, journal: DeadJournal(), defaults: defaults,
                                             saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        let engine = session.engine
        engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Groceries"), name: "Typing")
        if let image { XCTAssertTrue(engine.insertImage(image, pixelSize: CGSize(width: 2, height: 2))) }
        gate.shouldFail = true
        await XCTAssertFalseAsync(await controller.newNoteDurably(), "both saves fail, so the note cannot be left")
        guard case .onlyInMemory = session.state else { throw NSError(domain: "state", code: 1) }
        return (controller, session)
    }

    private func scratchURL(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func testARecoveryCopyKeepsTheStructureTheTextAndTheImagesInAReopenableFolder() async throws {
        let image = try pixel()
        let (controller, session) = try await onlyInMemoryNote(image: image)
        let expected = session.engine.document()
        let target = try scratchURL("Groceries recovery copy")
        var suggested: String?
        controller.recoveryCopyDestination = { name in suggested = name; return target }

        let saved = await controller.saveRecoveryCopy()
        XCTAssertTrue(saved)
        XCTAssertEqual(suggested, "Groceries recovery copy")

        let files = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
        XCTAssertEqual(files, ["README.txt", "attachments", "manifest.json", "note.json", "note.md"])
        // The structure: decoding note.json gives back the very document.
        let noteJSON = try Data(contentsOf: target.appendingPathComponent("note.json"))
        guard case let .editable(decoded) = NoteContentCodec.decode(noteJSON) else { return XCTFail("note.json must decode") }
        XCTAssertEqual(decoded, expected)
        // The images: the original bytes, found through the manifest.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(NoteRecoveryCopy.Manifest.self,
                                          from: Data(contentsOf: target.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.noteID, session.noteID)
        XCTAssertEqual(manifest.format, NoteRecoveryCopy.formatName)
        XCTAssertEqual(manifest.images.map(\.id), [image.id])
        XCTAssertEqual(manifest.images.first?.digest, image.digest)
        XCTAssertEqual(manifest.unavailableImageIDs, [])
        let file = try XCTUnwrap(manifest.images.first?.file)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(file)), image.data)
        XCTAssertEqual(Set(decoded.attachmentIDs), Set(manifest.images.map(\.id)), "every image note.json shows is in the folder")
        // Readable anywhere.
        let markdown = try String(contentsOf: target.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Groceries"))
        XCTAssertTrue(markdown.contains("[image: pixel.png]"))
        let readme = try String(contentsOf: target.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("note.json"))
        // It is a copy: the note is exactly as it was, and says where the copy went.
        guard case .onlyInMemory = session.state else { return XCTFail("the copy does not change the note's state") }
        XCTAssertEqual(session.engine.document(), expected)
        XCTAssertEqual(session.notice, "Recovery copy saved to “Groceries recovery copy”.")
        XCTAssertTrue(store.notes.isEmpty, "nothing was saved to the library")
    }

    /// Phase 2 audit fix B3: while Writing Tools' session was refused, the
    /// note in memory can be rewritten in place, past the text-edit guards.
    /// The recovery copy is a checkpoint, so it must keep the starting note
    /// (its structure, its objects and its images), never that rewrite.
    func testARecoveryCopyDuringARefusedWritingToolsRewriteKeepsTheStartingNote() async throws {
        let image = try pixel()
        let (controller, session) = try await onlyInMemoryNote(image: image)
        let engine = session.engine
        _ = engine.makeView()
        let expected = engine.document()
        XCTAssertEqual(expected.attachmentIDs, [image.id], "the note starts with its image")
        let expectedMarkdown = try XCTUnwrap(controller.markdown(noteID: session.noteID))
        XCTAssertTrue(expectedMarkdown.contains("[image: pixel.png]"))

        // Both the store and the journal refuse, so Writing Tools is refused
        // and the note is frozen at this snapshot.
        engine.writingToolsWillBegin()
        XCTAssertEqual(engine.activity, .writingToolsRefused)
        // A rewrite that bypasses the guards: the text and the image are gone
        // from the live text storage.
        engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: engine.textStorage.length), with: "Rewritten")
        XCTAssertNotEqual(engine.document(), expected, "the live text was rewritten")
        XCTAssertEqual(engine.checkpointDocument(), expected)

        let target = try scratchURL("refused recovery copy")
        controller.recoveryCopyDestination = { _ in target }
        let saved = await controller.saveRecoveryCopy(of: session)
        XCTAssertTrue(saved)

        let noteJSON = try Data(contentsOf: target.appendingPathComponent("note.json"))
        guard case let .editable(decoded) = NoteContentCodec.decode(noteJSON) else { return XCTFail("note.json must decode") }
        XCTAssertEqual(decoded, expected, "the structure and objects of the starting note")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(NoteRecoveryCopy.Manifest.self,
                                          from: Data(contentsOf: target.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.images.map(\.id), [image.id], "the image of that same document")
        XCTAssertEqual(manifest.unavailableImageIDs, [])
        let file = try XCTUnwrap(manifest.images.first?.file)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(file)), image.data, "its original bytes")
        let markdown = try String(contentsOf: target.appendingPathComponent("note.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Groceries"))
        XCTAssertFalse(markdown.contains("Rewritten"))

        // Copy as Markdown reads the same checkpoint, not the transient text.
        XCTAssertEqual(controller.markdown(noteID: session.noteID), expectedMarkdown)
        engine.writingToolsDidEnd()
        XCTAssertEqual(engine.document(), expected, "and the note is restored when Writing Tools ends")
    }

    func testCancellingTheSavePanelWritesNothingAndSaysNothing() async throws {
        let (controller, session) = try await onlyInMemoryNote()
        let target = try scratchURL("never")
        var asked = 0
        controller.recoveryCopyDestination = { _ in asked += 1; return nil }
        let saved = await controller.saveRecoveryCopy()
        XCTAssertFalse(saved)
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(session.notice)
    }

    func testAFailedWriteIsSaidLeavesNothingBehindAndKeepsTheNote() async throws {
        let (controller, session) = try await onlyInMemoryNote(image: try pixel())
        // A folder cannot be made inside a file.
        let blocker = try scratchURL("blocker")
        try Data("x".utf8).write(to: blocker)
        let target = blocker.appendingPathComponent("copy")
        controller.recoveryCopyDestination = { _ in target }

        let saved = await controller.saveRecoveryCopy()
        XCTAssertFalse(saved)
        let notice = try XCTUnwrap(session.notice)
        XCTAssertTrue(notice.hasPrefix("The recovery copy couldn’t be saved"), notice)
        XCTAssertEqual(try Data(contentsOf: blocker), Data("x".utf8), "the file in the way is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["blocker"], "no partial folder")
        guard case .onlyInMemory = session.state else { return XCTFail("the note stays as it was") }
        XCTAssertTrue(session.engine.plainText.contains("Groceries"))
        // The person can simply try again somewhere else.
        let elsewhere = try scratchURL("second")
        controller.recoveryCopyDestination = { _ in elsewhere }
        let again = await controller.saveRecoveryCopy()
        XCTAssertTrue(again)
    }

    func testChoosingAnExistingFolderReplacesItWholeAfterTheNewOneIsComplete() async throws {
        let (controller, _) = try await onlyInMemoryNote()
        let target = try scratchURL("copy")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("stale.txt"))
        controller.recoveryCopyDestination = { _ in target }
        let saved = await controller.saveRecoveryCopy()
        XCTAssertTrue(saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted(),
                       ["README.txt", "manifest.json", "note.json", "note.md"])
    }

    // MARK: Recovery copy: where it is built and how it is published (Phase 2 audit fix B4)

    /// A file manager that can refuse to make a scratch folder, play a
    /// scratch folder on another volume, or refuse to publish.
    private final class FaultyFileManager: FileManager {
        var refuseReplacementDirectory = false
        /// A real folder handed out as the "replacement directory", standing
        /// for another volume's.
        var replacementDirectory: URL?
        var refuseSibling = false
        var refusePublishing = false
        private(set) var publishAttempts = 0

        override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                          appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
            if directory == .itemReplacementDirectory {
                if refuseReplacementDirectory { throw CocoaError(.fileWriteUnknown) }
                if let replacementDirectory {
                    let folder = replacementDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try createDirectory(at: folder, withIntermediateDirectories: true)
                    return folder
                }
            }
            return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
        }

        override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            if refuseSibling, url.lastPathComponent.hasPrefix(".AtticRecovery-") { throw CocoaError(.fileWriteNoPermission) }
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            publishAttempts += 1
            if refusePublishing { throw CocoaError(.fileWriteUnknown) }
            try super.moveItem(at: srcURL, to: dstURL)
        }

        override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
                                  options: FileManager.ItemReplacementOptions = [],
                                  resultingItemURL resultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            publishAttempts += 1
            if refusePublishing { throw CocoaError(.fileWriteUnknown) }
            try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName,
                                  options: options, resultingItemURL: resultingURL)
        }
    }

    private func recoverySnapshot(title: String = "T") throws -> NoteRecoverySnapshot {
        let image = try pixel()
        return NoteRecoverySnapshot(noteID: UUID(), title: title, content: Data("{}".utf8), markdown: "# \(title)", tags: [],
                                    reason: "why", savedAt: Date(), attachments: [image], unavailableAttachmentIDs: [])
    }

    /// A folder standing for another volume's scratch space, and a folder
    /// to put the destination in, both real.
    private func makeFolders() throws -> (elsewhere: URL, home: URL) {
        let root = try scratchURL("volumes")
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (elsewhere, home)
    }

    private func existingCopy(at target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("stale.txt"))
    }

    private func assertUntouched(_ target: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["stale.txt"],
                       "the folder that was there is exactly as it was", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("stale.txt")), Data("old".utf8), file: file, line: line)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func temporaryRecoveryFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("AtticRecovery-") })
    }

    func testARecoveryCopyThatCannotBeStagedOnTheDestinationVolumeFailsAndPublishesNothing() async throws {
        let (_, home) = try makeFolders()
        let target = home.appendingPathComponent("copy")
        try existingCopy(at: target)
        let general = temporaryRecoveryFolders()
        let files = FaultyFileManager()
        files.refuseReplacementDirectory = true
        files.refuseSibling = true

        XCTAssertThrowsError(try NoteRecoveryCopy.write(try recoverySnapshot(), to: target, fileManager: files)) { error in
            XCTAssertTrue(error is NoteRecoveryCopy.NoStagingError, "\(error)")
        }
        XCTAssertEqual(files.publishAttempts, 0, "nothing was published")
        try assertUntouched(target)
        XCTAssertEqual(try names(in: home), ["copy"], "nothing left beside it")
        XCTAssertEqual(temporaryRecoveryFolders(), general, "and never built in the general temporary folder")

        // With no folder there yet, nothing appears.
        let fresh = home.appendingPathComponent("fresh")
        XCTAssertThrowsError(try NoteRecoveryCopy.write(try recoverySnapshot(), to: fresh, fileManager: files))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testARecoveryCopyDestinedForAnotherVolumeIsNeverBuiltThereAndIsPublishedFromASibling() async throws {
        let (elsewhere, home) = try makeFolders()
        let target = home.appendingPathComponent("copy")
        try existingCopy(at: target)
        let files = FaultyFileManager()
        // The replacement directory is on another volume; the destination's
        // own folder is on the destination's volume.
        files.replacementDirectory = elsewhere
        let sameVolume: (URL, URL) -> Bool = { first, second in
            !first.path.hasPrefix(elsewhere.path) && !second.path.hasPrefix(elsewhere.path)
        }

        try NoteRecoveryCopy.write(try recoverySnapshot(), to: target, fileManager: files, onSameVolume: sameVolume)
        XCTAssertEqual(try names(in: target), ["README.txt", "attachments", "manifest.json", "note.json", "note.md"],
                       "the whole folder replaced the old one")
        XCTAssertEqual(try names(in: elsewhere), [], "the other volume's scratch folder was not used and is gone")
        XCTAssertEqual(try names(in: home), ["copy"], "the sibling scratch folder is gone too")
    }

    func testARecoveryCopyWhoseOnlyScratchSpaceIsAnotherVolumeFailsAndKeepsTheDestination() async throws {
        let (elsewhere, home) = try makeFolders()
        let target = home.appendingPathComponent("copy")
        try existingCopy(at: target)
        let general = temporaryRecoveryFolders()
        let files = FaultyFileManager()
        files.replacementDirectory = elsewhere
        files.refuseSibling = true
        let sameVolume: (URL, URL) -> Bool = { first, second in
            !first.path.hasPrefix(elsewhere.path) && !second.path.hasPrefix(elsewhere.path)
        }

        XCTAssertThrowsError(try NoteRecoveryCopy.write(try recoverySnapshot(), to: target, fileManager: files,
                                                        onSameVolume: sameVolume)) { error in
            XCTAssertTrue(error is NoteRecoveryCopy.NoStagingError, "\(error)")
        }
        XCTAssertEqual(files.publishAttempts, 0, "no cross-volume move was ever attempted")
        try assertUntouched(target)
        XCTAssertEqual(try names(in: elsewhere), [], "the other volume's folder was cleaned up")
        XCTAssertEqual(try names(in: home), ["copy"])
        XCTAssertEqual(temporaryRecoveryFolders(), general)

        // A scratch folder that is not on the volume even when it was the
        // sibling (a mount point, say) is refused the same way.
        try NoteRecoveryCopy.write(try recoverySnapshot(), to: target, fileManager: FaultyFileManager(),
                                   onSameVolume: { _, _ in true })
        XCTAssertEqual(try names(in: target), ["README.txt", "attachments", "manifest.json", "note.json", "note.md"])
        XCTAssertThrowsError(try NoteRecoveryCopy.write(try recoverySnapshot(), to: target, fileManager: FaultyFileManager(),
                                                        onSameVolume: { _, _ in false }))
        XCTAssertEqual(try names(in: target), ["README.txt", "attachments", "manifest.json", "note.json", "note.md"],
                       "and the copy that was there stays")
        XCTAssertEqual(try names(in: home), ["copy"])
    }

    func testAFailedPublicationKeepsTheExistingFolderAndLeavesNoScratchBehind() async throws {
        let (_, home) = try makeFolders()
        let target = home.appendingPathComponent("copy")
        try existingCopy(at: target)
        let files = FaultyFileManager()
        files.refusePublishing = true

        XCTAssertThrowsError(try NoteRecoveryCopy.write(try recoverySnapshot(), to: target, fileManager: files))
        XCTAssertEqual(files.publishAttempts, 1, "publication was attempted, and refused")
        try assertUntouched(target)
        XCTAssertEqual(try names(in: home), ["copy"], "no scratch folder left beside it")

        // A first copy that cannot be published leaves no folder at all.
        let fresh = home.appendingPathComponent("fresh")
        XCTAssertThrowsError(try NoteRecoveryCopy.write(try recoverySnapshot(), to: fresh, fileManager: files))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(try names(in: home), ["copy"])
    }

    func testARecoveryCopyIsOfferedOnlyWhileTheTextIsHeldOnlyHere() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        XCTAssertFalse(controller.canSaveRecoveryCopy(session), "an untouched draft")
        XCTAssertFalse(controller.canSaveRecoveryCopy(nil))
        session.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Hi"), name: "Typing")
        XCTAssertFalse(controller.canSaveRecoveryCopy(controller.active), "typed but the save is still pending")
        // The store refuses but the recovery journal works: Not saved.
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.newNoteDurably(), "the recovery journal holds it, so the person may leave")
        guard case .notSaved = session.state else { return XCTFail("expected Not saved, got \(session.state)") }
        XCTAssertTrue(controller.canSaveRecoveryCopy(session), "Not saved is offered too")
    }

    func testTheFolderNamesAreSafeAndUnique() async {
        XCTAssertEqual(NoteRecoveryCopy.suggestedName(title: ""), "Untitled note recovery copy")
        XCTAssertEqual(NoteRecoveryCopy.suggestedName(title: "a/b: c"), "a-b- c recovery copy")
        var used = Set<String>()
        XCTAssertEqual(NoteRecoveryCopy.uniqueName("photo.png", among: &used), "photo.png")
        XCTAssertEqual(NoteRecoveryCopy.uniqueName("Photo.png", among: &used), "Photo 2.png")
        XCTAssertEqual(NoteRecoveryCopy.uniqueName("../evil", among: &used), "-evil", "no path escapes the folder")
        XCTAssertEqual(NoteRecoveryCopy.uniqueName("", among: &used), "attachment")
    }

    func testImagesThatCouldNotBeReadAreListedNotSilentlyDropped() async throws {
        let target = try scratchURL("partial")
        let missing = UUID()
        let snapshot = NoteRecoverySnapshot(noteID: UUID(), title: "T", content: Data("{}".utf8), markdown: "# T", tags: ["a"],
                                            reason: "why", savedAt: Date(), attachments: [], unavailableAttachmentIDs: [missing])
        try NoteRecoveryCopy.write(snapshot, to: target)
        let readme = try String(contentsOf: target.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains(missing.uuidString))
        XCTAssertTrue(readme.contains("why"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("attachments").path))
    }
}
