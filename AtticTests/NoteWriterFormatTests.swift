import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Each live writer is checked at its persisted boundary, independent of flags.
@MainActor final class NoteWriterFormatTests: XCTestCase {
    private func store() throws -> NoteStore {
        try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
    }
    private func assertFormat(_ store: NoteStore, _ id: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == id }
        XCTAssertFalse(rows.isEmpty, file: file, line: line)
        for row in rows {
            XCTAssertEqual(row.contentFormat, 1, file: file, line: line)
            XCTAssertTrue(NoteContentCodec.decode(try XCTUnwrap(row.content)).isEditable, file: file, line: line)
        }
    }
    private func page(_ store: NoteStore) async -> NotesPageController {
        let page = NotesPageController(store: store, journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "WriterDrafts")), saveDelay: .seconds(600))
        await page.startAndWait(); return page
    }
    private func type(_ page: NotesPageController, _ text: String) throws -> NoteSession {
        let session = try XCTUnwrap(page.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: text), name: "Type"))
        return session
    }
    func testNewNoteAndEditorAutosaveWriteDocumentFormat() async throws {
        let store = try store(), page = await page(store)
        XCTAssertTrue(page.requestNewNote())
        let session = try type(page, "Title\nBody")
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        try assertFormat(store, session.noteID)
        XCTAssertEqual(store.note(withID: session.noteID)?.body, "Body")
    }
    func testPlainTextUpdateUsesDocumentWriter() throws {
        let store = try store(), note = try XCTUnwrap(store.create(title: "Before", body: "body"))
        XCTAssertTrue(store.update(note, title: "After", body: "new body"))
        try assertFormat(store, note.id)
        XCTAssertEqual(store.loadDocument(noteID: note.id)?.content.document?.title, "After")
    }
    func testAgentAndMCPUpdateWriteDocumentFormat() throws {
        let notes = try store(), tasks = TaskStore(container: notes.container)
        let tools = AgentTaskTools(store: tasks, noteStore: notes)
        _ = try tools.call(name: "create_note", arguments: ["title": "Agent", "body": "body"])
        let note = try XCTUnwrap(notes.notes.first)
        _ = try tools.call(name: "update_note", arguments: ["id": note.id.uuidString, "title": "Agent edit", "base_revision": note.revisionToken])
        try assertFormat(notes, note.id)
        XCTAssertEqual(notes.note(withID: note.id)?.title, "Agent edit")
    }
    func testProposalsAndAcceptanceWriteDocumentFormat() throws {
        let store = try store(), note = try XCTUnwrap(store.create(title: "Current"))
        guard case .success(.pending) = store.agentWrite(noteID: note.id, baseRevisionToken: note.revisionToken,
            document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Agent", disposition: .proposal) else { return XCTFail() }
        XCTAssertTrue(try XCTUnwrap(store.pendingEdits(noteID: note.id).first?.proposedContent).count > 0)
        XCTAssertEqual(store.applyPendingEdits(noteID: note.id), 1)
        try assertFormat(store, note.id)
        XCTAssertEqual(store.note(withID: note.id)?.title, "Proposed")
    }
    func testImportWritesDocumentFormatWithAttachmentPlacementAndBytes() async throws {
        let store = try store(), page = await page(store)
        let root = ownedTemporaryDirectory(prefix: "NewFormatImport"), url = root.appendingPathComponent("Type specimen.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("Same attachment content".utf8); try bytes.write(to: url)
        page.importFiles([url]); await page.waitForImportWork()
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        let session = try XCTUnwrap(page.active)
        try assertFormat(store, session.noteID)
        let document = try XCTUnwrap(store.loadDocument(noteID: session.noteID)?.content.document)
        XCTAssertEqual(document.blocks.filter { $0.kind == .file }.map(\.filename), ["Type specimen.txt"])
        XCTAssertEqual(try store.attachmentRows(forNoteID: session.noteID).first?.payload, bytes)
    }
    func testPrivateFragmentPasteWritesDocumentFormat() async throws {
        let store = try store(), page = await page(store), session = try XCTUnwrap(page.active)
        let fragment = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Pasted")]), context: .fragment)
        XCTAssertTrue(session.engine.paste(fragmentData: fragment, at: NSRange(location: 0, length: 0)))
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        try assertFormat(store, session.noteID)
    }
    func testDuplicateWritesDocumentFormat() async throws {
        let store = try store(), source = try XCTUnwrap(store.create(title: "Source", body: "Body")), page = await page(store)
        XCTAssertTrue(page.open(noteID: source.id)); XCTAssertTrue(page.duplicateNote(noteID: source.id))
        let copy = try XCTUnwrap(page.active)
        XCTAssertNotEqual(copy.noteID, source.id); try assertFormat(store, copy.noteID)
        XCTAssertEqual(store.note(withID: copy.noteID)?.body, "Body")
    }
    func testSaveAsNewAfterDeletionWritesDocumentFormat() async throws {
        let store = try store(), source = try XCTUnwrap(store.create(title: "Source")), page = await page(store)
        XCTAssertTrue(page.open(noteID: source.id)); let session = try type(page, " unsaved")
        XCTAssertTrue(store.delete(source)); XCTAssertFalse(page.save(session))
        await XCTAssertTrueAsync(await page.keepAsNewNoteDurably())
        XCTAssertNotEqual(session.noteID, source.id); try assertFormat(store, session.noteID)
        XCTAssertEqual(store.note(withID: session.noteID)?.plainText, session.engine.plainText)
        XCTAssertTrue(session.engine.plainText.contains(" unsaved"))
    }
    func testVersionRestoreWritesDocumentFormatAndRefusesFormatZero() throws {
        let store = try store(), source = try XCTUnwrap(store.create(title: "Earlier"))
        XCTAssertTrue(store.recordVersion(noteID: source.id, reason: .pause))
        let version = try XCTUnwrap(store.versions(noteID: source.id).first)
        XCTAssertTrue(store.update(source, title: "Current"))
        _ = try store.restoreVersion(version.id, noteID: source.id).get(); try assertFormat(store, source.id)
        let old = NoteVersion(noteID: source.id, createdAt: Date(), reason: .pause, content: nil,
            contentFormat: 0, title: "Old", body: "", attachmentIDs: [], sourceRevisionID: nil)
        store.modelContext.insert(old); try store.modelContext.save()
        guard case .failure = store.restoreVersion(old.id, noteID: source.id) else { return XCTFail("Format-zero history can never become a note") }
        XCTAssertEqual(store.note(withID: source.id)?.title, "Earlier")
    }
    func testTasksCreateOnlyTasksAndSubtasks() throws {
        let notes = try store(), tasks = TaskStore(container: notes.container)
        let tools = AgentTaskTools(store: tasks, noteStore: notes)
        _ = try tools.call(name: "create_task", arguments: ["title": "Task"])
        let task = try XCTUnwrap(tasks.tasks.first)
        _ = try tools.call(name: "create_task", arguments: ["title": "Subtask", "parent_id": task.id.uuidString])
        XCTAssertEqual(tasks.tasks.count, 2)
        XCTAssertEqual(try ModelContext(notes.container).fetchCount(FetchDescriptor<NoteItem>()), 0,
            "Tasks has no separate note writer in the current product")
    }
    func testDemoFixturesKeepMoodboardTextAndBothAttachmentsInDocumentFormat() async throws {
        let notes = try store(), identity = "com.taha.Attic.preview.no-legacy-fixture"
        _ = try AtticDemoData.seed(into: notes.container, bundleIdentifier: identity)
        notes.refresh(); await AtticDemoData.attachFiles(to: notes, bundleIdentifier: identity)
        let id = AtticDemoData.attachmentsNoteID
        try assertFormat(notes, id)
        let document = try XCTUnwrap(notes.loadDocument(noteID: id)?.content.document)
        XCTAssertEqual(document.title, "Moodboard")
        XCTAssertEqual(document.blocks.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(document.blocks.filter { $0.kind == .file }.map(\.filename), ["Type specimen.txt"])
        XCTAssertEqual(Set(try notes.attachmentRows(forNoteID: id).map(\.originalFilename)), ["Palette.png", "Type specimen.txt"])
        XCTAssertTrue(try notes.attachmentRows(forNoteID: id).allSatisfy { $0.payload?.isEmpty == false })
    }
}
