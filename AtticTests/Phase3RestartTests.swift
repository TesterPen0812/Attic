import AppKit
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class Phase3RestartTests: XCTestCase {
    func testP3_3HeldTaskAndNoteSavesLeaveUnrelatedEditsWritable() throws {
        for notesCase in [false, true] {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
            let seed = ModelContext(container)
            let first = TaskItem(title: "first"), second = TaskItem(title: "second")
            let firstNote = NoteItem(), secondNote = NoteItem()
            for (note, title) in [(firstNote, "first"), (secondNote, "second")] {
                NoteStore.stageDocumentContent(try PreparedNoteDocument(NoteDocument(blocks: [.text(title)])),
                    format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
                seed.insert(note)
            }
            seed.insert(first); seed.insert(second)
            try seed.save()
            coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
            var fail = true
            let persist: (ModelContext) throws -> Void = { context in
                if fail { throw WorkspaceFoundationError.unknown }
                try context.save()
            }
            if notesCase {
                let store = NoteStore(container: container, persist: persist)
                XCTAssertFalse(store.update(try XCTUnwrap(store.note(withID: firstNote.id)), title: "held"))
                XCTAssertFalse(store.modelContext.hasChanges)
                fail = false
                XCTAssertTrue(store.update(try XCTUnwrap(store.note(withID: secondNote.id)), title: "unrelated"))
                XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).first { $0.id == secondNote.id }?.title, "unrelated")
            } else {
                let store = TaskStore(container: container, persist: persist)
                XCTAssertFalse(store.update(try XCTUnwrap(store.task(withID: first.id)), title: "held"))
                XCTAssertFalse(try XCTUnwrap(store.task(withID: first.id)?.modelContext).hasChanges)
                fail = false
                XCTAssertTrue(store.update(try XCTUnwrap(store.task(withID: second.id)), title: "unrelated"))
                XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == second.id }?.title, "unrelated")
            }
        }
    }

    func testBodyOnlyMarkdownAndNativeSelectionReplayKeepTheLiveTitle() throws {
        let document = try NoteDocument(blocks: [.text("Task title"), .text("body")]).taskSnapshot(title: "Task title")
        let route = UndoRoute()
        let workspace = route.workspace(for: .taskWorkspace(UUID()))
        let engine = NoteEditorEngine(noteID: UUID(), document: document, workspace: workspace, bodyOnly: true)
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        let selection = NSRange(location: 1, length: 2)
        view.setSelectedRange(selection)
        view.insertText("X", replacementRange: selection)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Task title", "bXy"])
        XCTAssertTrue(workspace.undo())
        XCTAssertEqual(engine.document(), document)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(workspace.redo())
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Task title", "bXy"])
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testWorkspaceTableReplayPreservesGridAndDoesNotMutateDuringPreparation() throws {
        let table = NoteTable(texts: [["Heading"], ["before"]])
        var document = try NoteDocument(blocks: [.text("Task title"), .table(table)]).taskSnapshot(title: "Task title")
        document.refreshRequiredCapabilities()
        let route = UndoRoute()
        let workspace = route.workspace(for: .taskWorkspace(UUID()))
        let engine = NoteEditorEngine(noteID: UUID(), document: document, workspace: workspace, bodyOnly: true)
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        let attachment = try XCTUnwrap(engine.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? NoteTableAttachment)
        XCTAssertTrue(engine.addRow(to: attachment, at: 2, focusing: 0))
        let changed = engine.document()
        let prepared = try XCTUnwrap(engine.history.prepareReplay(engine.history.undoOps.reversed()))
        XCTAssertEqual(engine.document(), changed, "preflight must never edit the live table")
        XCTAssertEqual(prepared.document, document)
        XCTAssertTrue(workspace.undo())
        XCTAssertEqual(engine.document(), document)
        XCTAssertTrue(workspace.redo())
        XCTAssertEqual(engine.document(), changed)
        XCTAssertTrue(view.engine === engine)
    }

    func testBodyOnlyFirstBlockUsesCurrentMarkdownPasteAndInlineMarks() throws {
        let document = try NoteDocument(blocks: [.text("Task title"), .text("body")]).taskSnapshot(title: "Task title")
        let route = UndoRoute(), id = UUID()
        let workspace = route.workspace(for: .taskWorkspace(id))
        let engine = NoteEditorEngine(noteID: id, document: document, workspace: workspace, bodyOnly: true)
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(engine.validate(.mark(.bold)).enabled)
        XCTAssertTrue(engine.perform(.mark(.bold)))
        XCTAssertEqual(engine.document().blocks[1].marks, [.init(.bold, offset: 0, length: 4)])
        XCTAssertTrue(workspace.undo())
        XCTAssertEqual(engine.document(), document)
        view.setSelectedRange(NSRange(location: 0, length: 4))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("# Heading", forType: .string)
        XCTAssertTrue(engine.handlePaste(pasteboard))
        XCTAssertEqual(engine.document().blocks[0].text, "Task title")
        XCTAssertEqual(engine.document().blocks[1].text, "Heading")
        XCTAssertEqual(engine.document().blocks[1].style, "heading")
        XCTAssertTrue(workspace.undo())
        XCTAssertEqual(engine.document(), document)
    }

    func testMixedTagRenameCarriesColourInTheSameGuardedSave() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let task = TaskItem(title: "Task")
        task.tagsRaw = "source"
        context.insert(task)
        context.insert(TagColour(name: "source", hue: .green))
        context.insert(TagColour(name: "target", hue: .blue))
        try context.save()
        let library = AtticLibrary(tasks: TaskStore(container: container), notes: NoteStore(container: container))
        XCTAssertNotNil(library.tags.rename("source", to: "target"))
        let saved = ModelContext(container)
        XCTAssertEqual(try saved.fetch(FetchDescriptor<TaskItem>()).first?.tags, ["target"])
        XCTAssertEqual(try saved.fetch(FetchDescriptor<TagColour>()).first { $0.name == "target" }?.hue, .green)
    }

    func testExternalAttributionParticipatesInTheExactNoteGuard() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let note = NoteItem(title: "Title")
        context.insert(note)
        try context.save()
        let owner = WorkspaceOwner(entity: .note, id: note.id)
        let before = try WorkspaceModelToken.read(owner, in: context)
        note.externalEditorName = "Agent"
        note.externalEditedAt = Date()
        XCTAssertNotEqual(before, try WorkspaceModelToken.read(owner, in: context))
    }
}
