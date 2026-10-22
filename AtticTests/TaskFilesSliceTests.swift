import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Phase 3 slice 2, "files and migration" (UX plan § 2.4, § 5.6, § 13; S9,
/// S10, S11): rows, the task's page, block file cards, Merge into This Note
/// with files, and the asynchronous agent path, on in-memory stores.
@MainActor
final class TaskFilesSliceTests: XCTestCase {
    private var container: ModelContainer!
    private var tasks: TaskStore!
    private var library: AtticLibrary!
    private var notes: NotesPageController!
    private var coordinator: WorkspaceOperationCoordinator!
    private var filesRoot: URL!
    private var windows: [NSWindow] = []
    private var presenters: [TaskNotePresenter] = []

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
        filesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TaskFilesSlice-\(UUID().uuidString)")
        makeStores()
    }

    override func tearDown() async throws {
        AgentWorkspaceCall.beforePreparing = nil
        TaskAttachmentMigration.interruption = nil
        for presenter in presenters where presenter.lease != nil { _ = await presenter.close() }
        presenters.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        await notes?.waitForRecoveryWork()
        await notes?.store.waitForAttachmentReconciliation()
        notes = nil; library = nil; tasks = nil; coordinator = nil; container = nil
        // Materialized originals are read-only by design; make them
        // removable, then remove only this test's own folder.
        if let enumerator = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try? FileManager.default.removeItem(at: filesRoot)
    }

    private func makeStores() {
        tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: filesRoot))
        library = AtticLibrary(tasks: tasks)
        notes = NotesPageController(store: NoteStore(container: container,
                                                     attachmentFileStore: AttachmentFileStore(rootURL: filesRoot.appendingPathComponent("NoteFiles"))),
                                    journal: coordinator.journal, defaults: nil,
                                    saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
        notes.workspaceTaskStore = tasks
        tasks.fileMigration.onNotesChanged = { [weak notes] in notes?.store.refresh() }
    }

    private func legacyFiles(_ names: [String]) async throws -> [TaskImageReference] {
        let folder = filesRoot.appendingPathComponent("in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try names.map { name -> URL in
            let url = folder.appendingPathComponent(name)
            if name.hasSuffix(".png") { try AtticDemoData.demoImage().write(to: url) } else { try Data("\(name) \(UUID())".utf8).write(to: url) }
            return url
        }
        return try await tasks.taskImageFiles.importAttachments(urls, existing: [])
    }

    @discardableResult
    private func legacyTask(_ title: String, shown: [TaskImageReference], removed: [TaskImageReference] = []) throws -> UUID {
        let context = ModelContext(container)
        let row = TaskItem(title: title, manualOrder: Int64.random(in: 1...1_000_000))
        row.listOrderVersion = TaskItem.currentListOrderVersion
        row.imageReferencesData = try JSONEncoder().encode(shown)
        if !removed.isEmpty { row.removedAttachmentsData = try JSONEncoder().encode(removed.map { RemovedTaskAttachment(reference: $0, removedAt: Date()) }) }
        context.insert(row)
        try context.save()
        tasks.refresh()
        return row.id
    }

    private func open(_ taskID: UUID) throws -> TaskNotePresenter {
        let presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: notes,
                                              design: .default, columnInset: 28, defaults: nil)
        presenters.append(presenter)
        let host = presenter.host
        host.setContentInsets(top: 76, bottom: 60)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        window.contentView = host.scrollView
        windows.append(window)
        host.restack()
        host.textView.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date())
        return presenter
    }

    private func close(_ presenter: TaskNotePresenter) async {
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        presenters.removeAll { $0 === presenter }
    }

    private func document(_ noteID: UUID) throws -> NoteDocument {
        let row = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).first)
        return try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
    }

    private func ownNote(_ taskID: UUID) throws -> UUID? {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).first { $0.taskID == taskID && $0.deletedAt == nil }?.id
    }

    // MARK: Rows: the paperclip retires only for migrated families

    func testARowsPaperclipRetiresOnceItsFilesAreInItsNoteAndUnmigratedRowsLookAsOnMain() async throws {
        let refs = try await legacyFiles(["a.png", "b.txt"])
        let moved = try legacyTask("Moves", shown: refs)
        let many = try await legacyFiles((0..<11).map { "m\($0).txt" }) + legacyFiles((11..<21).map { "m\($0).txt" })
        let refused = try legacyTask("Refused", shown: many)
        let model = TasksPageModel(library: library)
        // Before the launch run: exactly as main (the legacy count).
        XCTAssertEqual(try XCTUnwrap(model.rows(for: .now).first { $0.id == moved }).model.attachments, 2)
        XCTAssertEqual(try XCTUnwrap(model.rows(for: .now).first { $0.id == refused }).model.attachments, 21)

        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { _ in false })
        notes.store.refresh()
        model.setNoteOwners(Set([try XCTUnwrap(ownNote(moved))].map { _ in moved }))
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == moved })
        XCTAssertEqual(row.model.attachments, 0, "the paperclip and count retire")
        XCTAssertTrue(row.model.hasPage, "the doc.text glyph stays")
        model.setFilesExpanded(moved, true)
        XCTAssertTrue(try XCTUnwrap(model.rows(for: .now).first { $0.id == moved }).files.isEmpty)
        // A refused family keeps the legacy paperclip, count and files list.
        let kept = try XCTUnwrap(model.rows(for: .now).first { $0.id == refused })
        XCTAssertEqual(kept.model.attachments, 21)
        XCTAssertEqual(tasks.fileMigration.status(of: refused).refusal, .tooManyFiles)
        XCTAssertEqual(tasks.fileMigration.status(of: refused).refusal?.reason, "the note would exceed 20 files")
    }

    // MARK: The task's page: files in the note, Earlier files

    func testAMigratedTasksPageShowsImagesInlineFilesAsBlockCardsAndNoEarlierFiles() async throws {
        let refs = try await legacyFiles(["shot.png", "Spec.pdf"])
        let id = try legacyTask("Spec review", shown: refs)
        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { _ in false })
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        let engine = session.engine
        XCTAssertEqual(Set(engine.objectIDs()).count, 2)
        var faces: [AtticNoteObjectFace?] = []
        let text = engine.textStorage.string as NSString
        for index in 0..<text.length where text.character(at: index) == NoteDocument.objectUnit {
            if let object = engine.object(at: index) { faces.append(engine.objectFace(for: object)) }
        }
        // D24: the image is a plain inline picture (no face); the other
        // file is a block card with its type in the header (D5).
        XCTAssertEqual(faces.compactMap { $0 }.count, 1)
        XCTAssertEqual(faces.compactMap { $0 }.first?.header, "PDF")
        XCTAssertTrue(presenter.model.earlierFiles.earlier.isEmpty)
        XCTAssertEqual(presenter.model.noticeCount, 0)
        // The block card's header actions sit where they are drawn.
        let size = CGSize(width: 264, height: AtticNoteObjectMetrics.blockCardHeight)
        let face = try XCTUnwrap(faces.compactMap { $0 }.first)
        let look = try XCTUnwrap(AtticNoteObjectLayout.headerActions(in: size).first { $0.0 == .quickLook }?.1)
        XCTAssertEqual(AtticNoteObjectLayout.headerAction(at: CGPoint(x: look.midX, y: look.midY), face: face, size: size), .quickLook)
        XCTAssertNil(AtticNoteObjectLayout.headerAction(at: CGPoint(x: 20, y: 50), face: face, size: size))
    }

    func testAnOrdinaryNoteKeepsTodaysFileCard() throws {
        let fileID = UUID()
        let document = NoteDocument(blocks: [.text("Ordinary"), .file(attachmentID: fileID, filename: "Spec.pdf",
                                                                       contentTypeIdentifier: "com.adobe.pdf", byteCount: 10)])
        let engine = NoteEditorEngine(noteID: UUID(), document: document)
        let text = engine.textStorage.string as NSString
        let index = (0..<text.length).first { text.character(at: $0) == NoteDocument.objectUnit }
        let object = try XCTUnwrap(index.flatMap { engine.object(at: $0) })
        XCTAssertNil(engine.objectFace(for: object)?.header, "ordinary Notes behave as on main")
    }

    func testARefusedOrReversedFamilyShowsEarlierFilesWithItsReasonAndMoveIntoNoteBringsThemIn() async throws {
        let refs = try await legacyFiles(["plan.txt", "photo.png"])
        let id = try legacyTask("Garden", shown: refs)
        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { _ in false })
        let reversed = await tasks.fileMigration.reverse(id, tasks: tasks)
        XCTAssertEqual(reversed, .reversed)
        let presenter = try open(id)
        XCTAssertEqual(presenter.model.earlierFiles.earlier.map(\.id), refs.map(\.id), "Earlier files are never hidden")
        XCTAssertEqual(presenter.model.earlierFiles.refusal, .reversed)
        XCTAssertTrue(presenter.model.deletedNote, "the reversal sent the note it made to Recently Deleted")
        XCTAssertEqual(presenter.model.noticeCount, 2, "Restore Note and Earlier files")
        await close(presenter)
        let moved = await tasks.fileMigration.moveIntoNote(id, tasks: tasks, notes: notes)
        guard case .migrated = moved else { return XCTFail("\(moved)") }
        let again = try open(id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        again.model.refreshEarlierFiles()
        XCTAssertTrue(again.model.earlierFiles.earlier.isEmpty)
        XCTAssertEqual(Set(try document(XCTUnwrap(ownNote(id))).attachmentIDs), Set(refs.map(\.id)))
    }

    func testTheLaunchRunWaitsForAFamilyWhoseNoteIsOpen() async throws {
        let refs = try await legacyFiles(["a.txt"])
        let id = try legacyTask("Open page", shown: refs)
        let presenter = try open(id)
        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { [notes, coordinator] root in
            TaskFilesState.noteIsOpen(root, notes: notes!, coordinator: coordinator!)
        })
        XCTAssertTrue(tasks.fileMigration.deferred.contains(id))
        XCTAssertEqual(presenter.model.earlierFiles.kind, .legacy)
        XCTAssertNil(try ownNote(id), "nothing written under the open page")
    }

    // MARK: Cut, copy, paste and Undo of a file card in a task's note

    func testCutCopyPasteAndUndoOfAFileCardInATasksNote() async throws {
        let refs = try await legacyFiles(["Spec.pdf"])
        let id = try legacyTask("Cards", shown: refs)
        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { _ in false })
        let presenter = try open(id)
        let textView = presenter.host.textView
        let engine = try XCTUnwrap(presenter.session?.engine)
        let text = engine.textStorage.string as NSString
        let index = try XCTUnwrap((0..<text.length).first { text.character(at: $0) == NoteDocument.objectUnit })
        let card = try XCTUnwrap(engine.object(at: index)?.objectID)
        let range = NSRange(location: index, length: 1)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-test-\(UUID().uuidString)"))
        XCTAssertTrue(engine.writeSelection(range, to: pasteboard, types: [NoteEditorEngine.fragmentType, .string]))
        let data = try XCTUnwrap(pasteboard.data(forType: NoteEditorEngine.fragmentType))
        // Copy, then paste: a second card for the same stored file.
        XCTAssertTrue(engine.paste(fragmentData: data, at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertEqual(engine.objectIDs().count, 2)
        XCTAssertEqual(engine.document().attachmentIDs, [refs[0].id, refs[0].id])
        XCTAssertTrue(presenter.page.history.undo(), "⌘Z undoes the paste")
        XCTAssertEqual(engine.objectIDs(), [card])
        // Cut (copy, then remove the card), then paste: the same card.
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.delete(nil)
        for _ in 0..<50 where !engine.objectIDs().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(engine.objectIDs().isEmpty, "the cut takes the card")
        XCTAssertTrue(engine.paste(fragmentData: data, at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertEqual(engine.objectIDs(), [card], "cut and paste keep the card")
        XCTAssertEqual(engine.document().attachmentIDs, [refs[0].id])
        XCTAssertTrue(presenter.page.history.undo())
        XCTAssertTrue(engine.objectIDs().isEmpty)
        XCTAssertTrue(presenter.page.history.undo(), "⌘Z puts the cut card back")
        XCTAssertEqual(engine.objectIDs(), [card])
    }

    // MARK: Merge into This Note with files (S10)

    private func alternate(to taskID: UUID, files: Int, title: String = "Spec review") throws -> (UUID, [UUID]) {
        let context = ModelContext(container)
        let id = UUID()
        let note = NoteItem(id: id, createdAt: Date().addingTimeInterval(3_600), updatedAt: Date().addingTimeInterval(3_600))
        note.taskID = taskID
        var blocks: [NoteBlock] = [.text(title), .text("From the other Mac")]
        var ids: [UUID] = []
        for index in 0..<files {
            let bytes = Data("other file \(index)".utf8)
            let row = NoteAttachment(noteID: id, originalFilename: "other\(index).txt", contentTypeIdentifier: "public.plain-text",
                                     byteCount: Int64(bytes.count), sortIndex: Int64(index), contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes)
            context.insert(row)
            ids.append(row.id)
            blocks.append(.file(attachmentID: row.id, filename: row.originalFilename, contentTypeIdentifier: row.contentTypeIdentifier, byteCount: row.byteCount))
        }
        let document = try NoteDocument(blocks: blocks).taskSnapshot(title: title)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(note)
        context.insert(TaskNoteAssociation(taskID: taskID, noteID: id))
        try context.save()
        return (id, ids)
    }

    private func taskWithOwnNote() async throws -> (UUID, UUID) {
        let refs = try await legacyFiles(["mine.txt"])
        let id = try legacyTask("Spec review", shown: refs)
        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { _ in false })
        return (id, try XCTUnwrap(ownNote(id)))
    }

    func testMergeIntoThisNoteMovesTheOtherNotesFilesAndUndoMovesThemBack() async throws {
        let (id, own) = try await taskWithOwnNote()
        let (other, moved) = try alternate(to: id, files: 2)
        notes.store.refresh()
        let presenter = try open(id)
        XCTAssertEqual(presenter.model.alternateNotes, [other])
        let engineBefore = presenter.session?.engine
        let result = await presenter.mergeAlternate(other, tasks: tasks, notes: notes)
        guard case let .made(entryID, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(presenter.session?.engine === engineBefore)
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertTrue(moved.allSatisfy { id in rows.filter { $0.id == id }.allSatisfy { $0.noteID == own && $0.deletedAt == nil } },
                      "the transfer path: the same rows change owner")
        XCTAssertEqual(rows.count, 3, "nothing copied or deleted")
        XCTAssertTrue(Set(try document(own).attachmentIDs).isSuperset(of: moved))
        // The cards' availability checks settle first (as on screen).
        for _ in 0..<50 where !(presenter.session?.engine.history.canPrepareWorkspaceCommand ?? false) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        let back = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertTrue(moved.allSatisfy { id in back.filter { $0.id == id }.allSatisfy { $0.noteID == other && $0.deletedAt == nil } })
        XCTAssertTrue(Set(try document(own).attachmentIDs).isDisjoint(with: moved))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == other }.allSatisfy { $0.deletedAt == nil })
    }

    func testMergeWithFilesRefusesBeyondTheLimitsAndAFailedSaveChangesNothing() async throws {
        let (id, own) = try await taskWithOwnNote()
        let (crowded, _) = try alternate(to: id, files: 20)
        notes.store.refresh()
        let presenter = try open(id)
        let refused = await presenter.mergeAlternate(crowded, tasks: tasks, notes: notes)
        XCTAssertEqual(refused, .refused("The merged note would exceed 20 files: keep it as a separate note"))
        // Failure injection: the save throws; every row stays where it was.
        let (small, moved) = try alternate(to: id, files: 1)
        notes.store.refresh()
        coordinator.save = { _ in throw CocoaError(.fileWriteNoPermission) }
        defer { coordinator.save = { try $0.save() } }
        let failed = await presenter.mergeAlternate(small, tasks: tasks, notes: notes)
        guard case .refused = failed else { return XCTFail("\(failed)") }
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).filter { moved.contains($0.id) }
        XCTAssertTrue(rows.allSatisfy { $0.noteID == small })
        XCTAssertFalse(Set(try document(own).attachmentIDs).contains(moved[0]))
    }

    // MARK: The asynchronous agent path (§ 5.9)

    private func agent() -> MCPRequestHandler {
        let tools = AgentTaskTools(store: tasks, noteStore: notes.store, library: library)
        tools.notesController = { [weak notes] in notes }
        return MCPRequestHandler(tools: tools)
    }

    private func call(_ handler: MCPRequestHandler, _ name: String, _ arguments: [String: Any]) async throws -> (String, Bool) {
        var arguments = arguments
        if AgentTaskTools.asyncToolNames.contains(name), arguments["base_workspace_token"] == nil,
           !arguments.keys.contains(where: { $0.hasPrefix("base_") }) {
            let tools = AgentTaskTools(store: tasks, noteStore: notes.store)
            if let intent = try? tools.workspaceIntent(name: name, arguments: arguments) {
                let snapshot = try AgentWorkspaceReadSet.capture(taskID: intent.taskID, noteID: intent.noteID, in: ModelContext(container))
                arguments["base_workspace_token"] = try WorkspaceModelFields.encode(snapshot).base64EncodedString()
            }
        }
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": name, "arguments": arguments]])
        let result = await handler.handleAsync(body: body, protocolVersion: "2025-06-18")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(result.body)) as? [String: Any])
        let payload = try XCTUnwrap(json["result"] as? [String: Any])
        let text = try XCTUnwrap((payload["content"] as? [[String: Any]])?.first?["text"] as? String)
        return (text, payload["isError"] as? Bool ?? false)
    }

    func testAgentsMakeSubtasksAndNoteCheckboxesThroughTheSameOperationAndRefusals() async throws {
        let id = try XCTUnwrap(tasks.create(title: "Launch")?.id)
        let handler = agent()
        // make_note_checkbox on a task with no note creates the note.
        let subtask = try XCTUnwrap(tasks.create(title: "Write the post", parentID: id)?.id)
        let (checkbox, checkboxError) = try await call(handler, "make_note_checkbox", ["subtask_id": subtask.uuidString])
        XCTAssertFalse(checkboxError, checkbox)
        let noteID = try XCTUnwrap(ownNote(id))
        XCTAssertTrue(try document(noteID).blocks.contains { $0.kind == .checklist && $0.text == "Write the post" })
        XCTAssertNil(tasks.task(withID: subtask), "the subtask is in Recently Deleted")
        // make_subtask from consecutive lines of the body.
        let presenter = try open(id)
        presenter.host.textView.window?.makeFirstResponder(presenter.host.textView)
        presenter.host.textView.setSelectedRange(NSRange(location: (presenter.host.textView.string as NSString).length, length: 0))
        presenter.host.textView.insertText("\nBook the room\nSend invites", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = notes.save(try XCTUnwrap(presenter.session))
        let (made, madeError) = try await call(handler, "make_subtask", ["task_id": id.uuidString, "lines": ["Book the room", "Send invites"]])
        XCTAssertFalse(madeError, made)
        XCTAssertTrue(made.contains("pending"), made)
        XCTAssertTrue(tasks.subtasks(of: id).isEmpty)
        let proposal = try XCTUnwrap(notes.workspaceProposals.first)
        let began = await notes.beginProposalReview(id: proposal.id)
        XCTAssertTrue(began)
        let accepted = await notes.acceptProposal()
        XCTAssertTrue(accepted)
        XCTAssertEqual(Set(tasks.subtasks(of: id).map(\.title)), ["Book the room", "Send invites"])
        XCTAssertFalse(presenter.host.textView.string.contains("Send invites"), "the lines left the writing in the same operation")
        XCTAssertNotNil(presenter.page.history.route.undoStepID(in: presenter.page.history.historyID), "it entered the workspace history")
        // Refusals as for people, after the editor leaves.
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        let (missing, missingError) = try await call(handler, "make_subtask", ["task_id": id.uuidString, "lines": ["Not in the note"]])
        XCTAssertTrue(missingError, missing)
        let (gone, goneError) = try await call(handler, "make_note_checkbox", ["subtask_id": UUID().uuidString])
        XCTAssertTrue(goneError, gone)
    }

    func testAgentsMakeTasksFromNotesRestoreNotesAndMoveFilesIntoNotes() async throws {
        let handler = agent()
        // make_task_from_note
        let ordinaryID = UUID()
        let context = ModelContext(container)
        let ordinary = NoteItem(id: ordinaryID)
        NoteStore.stageDocumentContent(try PreparedNoteDocument(NoteDocument(blocks: [.text("Trip plan"), .text("Pack light")])),
                                       format: 1, on: [ordinary], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(ordinary)
        try context.save()
        notes.store.refresh()
        let (made, madeError) = try await call(handler, "make_task_from_note", ["note_id": ordinaryID.uuidString])
        XCTAssertFalse(madeError, made)
        XCTAssertTrue(tasks.tasks.contains { $0.title == "Trip plan" })
        // move_files_into_note: a reversed family's files go back in.
        let refs = try await legacyFiles(["ticket.pdf"])
        let id = try legacyTask("Flights", shown: refs)
        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { _ in false })
        _ = await tasks.fileMigration.reverse(id, tasks: tasks)
        let (moved, movedError) = try await call(handler, "move_files_into_note", ["task_id": id.uuidString])
        XCTAssertFalse(movedError, moved)
        XCTAssertEqual(try document(XCTUnwrap(ownNote(id))).attachmentIDs, refs.map(\.id))
        // restore: a task's deleted note comes back as its own note.
        let noteID = try XCTUnwrap(ownNote(id))
        notes.store.refresh()
        XCTAssertTrue(notes.store.delete(try XCTUnwrap(notes.store.note(withID: noteID))))
        notes.store.refresh()
        let (restored, restoredError) = try await call(handler, "restore", ["id": noteID.uuidString])
        XCTAssertFalse(restoredError, restored)
        XCTAssertTrue(restored.contains("own_note"), restored)
        // Refused while the note is open.
        let presenter = try open(id)
        _ = presenter
        let (open, openError) = try await call(handler, "move_files_into_note", ["task_id": id.uuidString])
        XCTAssertFalse(openError, open)
        XCTAssertTrue(open.contains("pending"), open)
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2F10AgentOpenEditorRequiresProposal() async throws {
        let (id, _) = try await taskWithOwnNote()
        let presenter = try open(id)
        let text = presenter.host.textView
        text.insertText("\nFresh human line", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        let before = text.string
        let (result, error) = try await call(agent(), "make_subtask", ["task_id": id.uuidString, "lines": ["Fresh human line"],
            "base_workspace_token": try WorkspaceModelFields.encode(AgentWorkspaceReadSet.capture(taskID: id, noteID: nil, in: ModelContext(container))).base64EncodedString()])
        XCTAssertFalse(error, result)
        XCTAssertTrue(result.contains("pending"), "an agent must not consume a live human draft without review")
        XCTAssertEqual(notes.workspaceProposals.count, 1)
        XCTAssertEqual(text.string, before)
        XCTAssertTrue(tasks.subtasks(of: id).isEmpty)
    }

    func testP3S2F12ExplicitFileMoveEntersHistory() async throws {
        let refs = try await legacyFiles(["tool.txt"])
        let id = try legacyTask("Tool files", shown: refs)
        let history = notes.undoRoute.workspace(for: .taskWorkspace(id))
        XCTAssertNil(history.route.undoStepID(in: history.historyID))
        let (result, error) = try await call(agent(), "move_files_into_note", ["task_id": id.uuidString])
        XCTAssertFalse(error, result)
        XCTAssertNotNil(history.route.undoStepID(in: history.historyID), "agent file moves must enter workspace history")
    }

    func testP3S2F11FailedHeadlessCloseKeepsRecoverableLease() async throws {
        let id = try XCTUnwrap(tasks.create(title: "Lease")?.id)
        let child = try XCTUnwrap(tasks.create(title: "Do work", parentID: id)?.id)
        coordinator.save = { context in
            let changes = context.insertedModelsArray + context.changedModelsArray + context.deletedModelsArray
            if !changes.isEmpty && changes.allSatisfy({ $0 is OperationReceipt }) { throw CocoaError(.fileWriteNoPermission) }
            try context.save()
        }
        let (result, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": child.uuidString])
        coordinator.save = { try $0.save() }
        let page = try coordinator.sessions.session(for: .task(id), notes: notes)
        for _ in 0..<100 where page.history.hasPendingPublication { try await Task.sleep(for: .milliseconds(20)) }
        await coordinator.sessions.retryHeadlessClosures()
        XCTAssertNil(page.activeLease, "a retained engine-only lease must close after storage recovers")
        if let presenter = TaskNotePresenter.open(for: id) { _ = await presenter.close() }
        else if let lease = page.activeLease { _ = await page.close(lease) }
    }

    func testP3S2F1LaunchRechecksOpenPage() async throws {
        let refs = try await legacyFiles(["opening.txt"])
        let id = try legacyTask("Opening", shown: refs)
        var presenter: TaskNotePresenter?
        TaskAttachmentMigration.interruption = { [self] point in
            if point == "M2-bytes", presenter == nil { presenter = try open(id) }
        }
        await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { [notes, coordinator] root in
            TaskFilesState.noteIsOpen(root, notes: notes!, coordinator: coordinator!)
        })
        TaskAttachmentMigration.interruption = nil
        AgentWorkspaceCall.beforePreparing = nil
        XCTAssertNotNil(presenter)
        XCTAssertTrue(tasks.fileMigration.deferred.contains(id), "opening during file IO must defer migration")
        XCTAssertNil(try ownNote(id))
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2F3LaunchWaitsForRecoveryRepair() async throws {
        let (id, noteID) = try await taskWithOwnNote()
        let bytes = Data("note-owned bytes, outside the legacy manifest".utf8)
        let item = StagedNoteAttachment(id: UUID(), filename: "note-only.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        var old = try document(noteID)
        old.blocks.append(.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount))
        notes.store.refresh()
        let beforeRevision = try XCTUnwrap(notes.store.note(withID: noteID)?.revisionID)
        guard case let .success(revision) = notes.store.saveDocument(noteID: noteID, document: old,
            baseRevisionID: beforeRevision, staged: [item]) else { return XCTFail("fixture note-only file must save") }
        let entry = NoteDraftJournalEntry(noteID: noteID, isPersisted: true, baseRevisionID: revision,
            content: try NoteContentCodec.encode(old), selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                byteCount: item.byteCount, digest: item.digest)], savedAt: Date())
        _ = try await coordinator.journal.writeDurably(entry, staged: [item])
        let added = try await legacyFiles(["added-by-older-writer.txt"])
        let edit = ModelContext(container)
        for row in try edit.fetch(FetchDescriptor<NoteAttachment>()) where row.id == item.id { edit.delete(row) }
        for row in try edit.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
            row.imageReferencesData = try JSONEncoder().encode(row.attachments + added)
        }
        try edit.save()
        let noteStore = NoteStore(container: container, attachmentFileStore: AttachmentFileStore(rootURL: filesRoot.appendingPathComponent("recovery-files")))
        var began = false
        var resume: CheckedContinuation<Void, Never>?
        noteStore.attachmentReconciliationWillBegin = {
            guard !began else { return }
            began = true
            await withCheckedContinuation { resume = $0 }
        }
        let recovery = NotesPageController(store: noteStore, journal: coordinator.journal, defaults: nil)
        for _ in 0..<100 where !began { await Task.yield() }
        XCTAssertTrue(began)
        // The launch's offers callback starts this work but does not await
        // it. Let its startup task reach the attachment drain.
        for _ in 0..<20 { await Task.yield() }
        let release = Task { @MainActor in
            await Task.yield()
            resume?.resume(); resume = nil
        }
        var visited = false
        await tasks.fileMigration.runAtLaunch(tasks: tasks, recovering: recovery, isBusy: { root in
            visited = true
            XCTAssertTrue(recovery.launchRecoveryCompleted, "migration admission follows Notes recovery")
            let repaired = try? ModelContext(self.container).fetch(FetchDescriptor<NoteAttachment>()).first { $0.id == item.id }
            XCTAssertEqual(repaired?.payload, bytes, "the repair is committed before any family's migration admission")
            return TaskFilesState.noteIsOpen(root, notes: recovery, coordinator: self.coordinator)
        })
        await release.value
        await recovery.startAndWait()
        XCTAssertTrue(visited)
        let stored = await noteStore.verifiedAttachmentBytes(item.id)
        XCTAssertEqual(stored?.data, bytes, "launch must finish a matching missing-byte repair before migration advances its revision")
        let checkpoint = try await coordinator.journal.entriesDurably()
        XCTAssertTrue(stored?.data == bytes || checkpoint.flatMap { $0.1 }.contains { $0.id == item.id && $0.data == bytes })
        await noteStore.waitForAttachmentReconciliation()
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2MoveUndoRedoRebindsCreatedAndRevivedOpenNotes() async throws {
        for revived in [false, true] {
            let refs = try await legacyFiles(["history.txt"])
            let id = try legacyTask("History", shown: refs)
            if revived {
                await tasks.fileMigration.runAtLaunch(tasks: tasks, isBusy: { _ in false })
                let reversed = await tasks.fileMigration.reverse(id, tasks: tasks)
                XCTAssertEqual(reversed, .reversed)
            }
            let moved = await tasks.fileMigration.moveIntoNote(id, tasks: tasks, notes: notes)
            guard case let .migrated(noteID, _) = moved else { XCTFail("\(moved)"); continue }
            let presenter = try open(id)
            let history = presenter.page.history
            let undone = await history.replay(redo: false)
            XCTAssertEqual(undone, .applied)
            for _ in 0..<200 where history.hasPendingPublication {
                try await Task.sleep(for: .milliseconds(10))
                _ = await history.retryPublication(using: coordinator)
            }
            XCTAssertFalse(history.hasPendingPublication)
            XCTAssertNil(try ownNote(id))
            XCTAssertFalse(try XCTUnwrap(presenter.session).isPersisted)
            XCTAssertFalse(presenter.host.textView.string.contains("history.txt"))
            let redone = await history.replay(redo: true)
            XCTAssertEqual(redone, .applied)
            for _ in 0..<200 where history.hasPendingPublication {
                try await Task.sleep(for: .milliseconds(10))
                _ = await history.retryPublication(using: coordinator)
            }
            XCTAssertFalse(history.hasPendingPublication)
            XCTAssertEqual(try ownNote(id), noteID)
            XCTAssertTrue(try XCTUnwrap(presenter.session).isPersisted)
            let closed = await presenter.close()
            XCTAssertTrue(closed)
        }
    }

    func testP3S2AgentStaleWholeOperationAndAbsentNoteProposalSurviveReopen() async throws {
        let id = try XCTUnwrap(tasks.create(title: "Absent")?.id)
        let child = try XCTUnwrap(tasks.create(title: "Work", parentID: id)?.id)
        let snapshot = try AgentWorkspaceReadSet.capture(taskID: id, noteID: nil, in: ModelContext(container))
        XCTAssertTrue(tasks.rename(try XCTUnwrap(tasks.task(withID: id)), to: "Changed"))
        let (result, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": child.uuidString,
            "base_workspace_token": try WorkspaceModelFields.encode(snapshot).base64EncodedString()])
        XCTAssertFalse(error, result)
        XCTAssertTrue(result.contains("pending"))
        XCTAssertNil(try ownNote(id))
        XCTAssertNotNil(tasks.task(withID: child))
        let proposalID = try XCTUnwrap(notes.workspaceProposals.first?.id)
        await notes.waitForRecoveryWork()
        await notes.store.waitForAttachmentReconciliation()
        makeStores()
        XCTAssertEqual(notes.workspaceProposals.map(\.id), [proposalID], "whole operation survives controller replacement")
        let presenter = try open(id)
        XCTAssertNotNil(notes.proposalAgent(for: try XCTUnwrap(presenter.session)))
        let began = await notes.beginProposalReview(id: proposalID)
        XCTAssertTrue(began)
        let accepted = await notes.acceptProposal()
        XCTAssertTrue(accepted, notes.proposalReviewNotice ?? "")
        XCTAssertNotNil(try ownNote(id))
        XCTAssertNil(tasks.task(withID: child))
        XCTAssertTrue(notes.workspaceProposals.isEmpty)
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2AgentAssociationChangesStillBecomeWholeProposals() async throws {
        let source = try XCTUnwrap(tasks.create(title: "Source")?.id)
        let destination = try XCTUnwrap(tasks.create(title: "Destination")?.id)
        let child = try XCTUnwrap(tasks.create(title: "Child", parentID: source)?.id)
        let snapshot = try AgentWorkspaceReadSet.capture(taskID: source, noteID: nil, in: ModelContext(container))
        let edit = ModelContext(container)
        for row in try edit.fetch(FetchDescriptor<TaskItem>()) where row.id == child { row.parentID = destination }
        try edit.save(); tasks.refresh()
        let (result, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": child.uuidString,
            "base_workspace_token": try WorkspaceModelFields.encode(snapshot).base64EncodedString()])
        XCTAssertFalse(error, result)
        XCTAssertTrue(result.contains("pending"), result)
        XCTAssertNotNil(tasks.task(withID: child))
        XCTAssertNil(try ownNote(destination))
    }

    func testP3S2AgentLateOpenBecomesProposal() async throws {
        let id = try XCTUnwrap(tasks.create(title: "Late")?.id)
        let child = try XCTUnwrap(tasks.create(title: "Child", parentID: id)?.id)
        AgentWorkspaceCall.beforePreparing = { [self] in
            AgentWorkspaceCall.beforePreparing = nil
            _ = try? open(id)
        }
        let (result, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": child.uuidString])
        XCTAssertFalse(error, result)
        XCTAssertTrue(result.contains("pending"), result)
        XCTAssertNotNil(tasks.task(withID: child))
        XCTAssertNil(try ownNote(id))
    }

    func testP3S2ProposalSnapshotSizeRemainsBounded() async throws {
        let (id, _) = try await taskWithOwnNote()
        let child = try XCTUnwrap(tasks.create(title: "Child", parentID: id)?.id)
        var first = 0, last = 0
        for index in 0..<6 {
            let snapshot = try AgentWorkspaceReadSet.capture(taskID: id, noteID: nil, in: ModelContext(container))
            last = try WorkspaceModelFields.encode(snapshot).count
            if index == 0 { first = last }
            XCTAssertTrue(tasks.rename(try XCTUnwrap(tasks.task(withID: id)), to: "Size \(index)"))
            let (_, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": child.uuidString,
                "base_workspace_token": try WorkspaceModelFields.encode(snapshot).base64EncodedString()])
            XCTAssertFalse(error)
        }
        XCTAssertLessThan(last, first + 80_000, "proposal snapshots must fingerprint stored read sets instead of recursively embedding them")
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2AsyncRestoreWaitsForCollectionAdmission() async throws {
        let (rootID, noteID) = try await taskWithOwnNote()
        notes.store.refresh()
        XCTAssertTrue(notes.store.delete(try XCTUnwrap(notes.store.note(withID: noteID))))
        let collection = try XCTUnwrap(coordinator.ownership.tryAcquire([noteID], kind: .collection))
        let release = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            collection.release()
        }
        let (result, error) = try await call(agent(), "restore", ["id": noteID.uuidString])
        await release.value
        XCTAssertFalse(error, result)
        XCTAssertEqual(try ownNote(rootID), noteID)
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2ReviewedOperationSaveFailureKeepsProposalAndAllSources() async throws {
        let rootID = try XCTUnwrap(tasks.create(title: "Atomic")?.id)
        let childID = try XCTUnwrap(tasks.create(title: "Keep me", parentID: rootID)?.id)
        _ = try open(rootID)
        let (_, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": childID.uuidString])
        XCTAssertFalse(error)
        let proposalID = try XCTUnwrap(notes.workspaceProposals.first?.id)
        let began = await notes.beginProposalReview(id: proposalID); XCTAssertTrue(began)
        let save = coordinator.save
        coordinator.save = { _ in throw WorkspaceFoundationError.preparationFailed }
        let failed = await notes.acceptProposal(); XCTAssertFalse(failed)
        XCTAssertNotNil(tasks.task(withID: childID))
        XCTAssertNil(try ownNote(rootID))
        XCTAssertEqual(notes.workspaceProposals.map(\.id), [proposalID])
        coordinator.save = save
        let refreshed = await notes.beginProposalReview(id: proposalID); XCTAssertTrue(refreshed)
        let applied = await notes.acceptProposal(); XCTAssertTrue(applied, notes.proposalReviewNotice ?? "")
        XCTAssertNil(tasks.task(withID: childID))
        XCTAssertNotNil(try ownNote(rootID))
        XCTAssertTrue(notes.workspaceProposals.isEmpty)
    }

    func testP3S2ReviewedCheckboxCannotFollowSubtaskToAnotherWorkspace() async throws {
        let rootID = try XCTUnwrap(tasks.create(title: "Reviewed root")?.id)
        let otherID = try XCTUnwrap(tasks.create(title: "Other root")?.id)
        let childID = try XCTUnwrap(tasks.create(title: "Child", parentID: rootID)?.id)
        _ = try open(rootID)
        let (_, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": childID.uuidString])
        XCTAssertFalse(error)
        let proposalID = try XCTUnwrap(notes.workspaceProposals.first?.id)
        let began = await notes.beginProposalReview(id: proposalID); XCTAssertTrue(began)
        AgentWorkspaceCall.beforePreparing = { [self] in
            AgentWorkspaceCall.beforePreparing = nil
            let edit = ModelContext(container)
            for row in try! edit.fetch(FetchDescriptor<TaskItem>()) where row.id == childID { row.parentID = otherID }
            try! edit.save(); tasks.refresh()
        }
        let applied = await notes.acceptProposal(); XCTAssertFalse(applied)
        XCTAssertNotNil(tasks.task(withID: childID))
        XCTAssertNil(try ownNote(otherID))
        XCTAssertEqual(notes.workspaceProposals.map(\.id), [proposalID])
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2FileHistoryPublicationFinishesWithoutReplacingNewerTyping() async throws {
        let (rootID, noteID) = try await taskWithOwnNote()
        let presenter = try open(rootID)
        let session = try XCTUnwrap(presenter.session), history = presenter.page.history
        var blocked = true
        let result = await history.performCommand(using: coordinator) { [self] in
            let entryID = UUID(), owner = WorkspaceOwner(entity: .note, id: noteID)
            let effect = WorkspaceHistory.ForwardEffect(workspaceID: history.id, entryID: entryID)
            let envelope = try coordinator.newEnvelope(intent: "File publication fixture", reads: coordinator.capture([owner]), writes: [owner],
                historyEffect: WorkspaceModelFields.encode(effect))
            return .init(entryID: entryID, envelope: envelope, stage: { context in
                for row in try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) { row.externalEditedAt = Date() }
            }, record: { _, _ in }, publication: .init(steps: [{ [self] _ in
                if blocked { throw WorkspaceFoundationError.preparationFailed }
                try notes.installFileHistoryState(session, rootID: rootID, noteID: noteID, history: history)
            }]))
        }
        XCTAssertEqual(result, .publicationPending)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(history.isInputReserved)
        let text = presenter.host.textView
        text.insertText("\nNewer draft", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        let draft = text.string
        XCTAssertTrue(history.hasNewerPublicationDraft)
        blocked = false
        let completed = await history.retryPublication(using: coordinator)
        XCTAssertTrue(completed)
        XCTAssertFalse(history.hasPendingPublication)
        XCTAssertEqual(presenter.host.textView.string, draft)
    }

    func testP3S2MoveUndoAfterSavedTypingWasUndone() async throws {
        let refs = try await legacyFiles(["chronology.txt"])
        let rootID = try legacyTask("Chronology", shown: refs)
        guard case let .migrated(noteID, _) = await tasks.fileMigration.moveIntoNote(rootID, tasks: tasks, notes: notes) else { return XCTFail("move") }
        let presenter = try open(rootID)
        let session = try XCTUnwrap(presenter.session), history = presenter.page.history
        let text = presenter.host.textView
        text.insertText("\nLater typing", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        let saved = await notes.preserveDurably(session); XCTAssertTrue(saved)
        XCTAssertTrue(history.undo())
        let savedUndo = await notes.preserveDurably(session); XCTAssertTrue(savedUndo)
        let undone = await history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        for _ in 0..<200 where history.hasPendingPublication {
            try await Task.sleep(for: .milliseconds(10))
            _ = await history.retryPublication(using: coordinator)
        }
        XCTAssertFalse(history.hasPendingPublication)
        XCTAssertNil(try ownNote(rootID))
        XCTAssertFalse(try document(noteID).attachmentIDs.contains(refs[0].id))
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2WorkspaceProposalStatusCachesTypingAndInvalidatesOnDiscard() async throws {
        try await coordinator.finishLaunch()
        let rootID = try XCTUnwrap(tasks.create(title: "Cached proposal")?.id)
        let childID = try XCTUnwrap(tasks.create(title: "Child", parentID: rootID)?.id)
        let presenter = try open(rootID), session = try XCTUnwrap(presenter.session)
        let (_, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": childID.uuidString])
        XCTAssertFalse(error)
        let proposal = try XCTUnwrap(notes.workspaceProposals.first)
        XCTAssertEqual(notes.proposalAgent(for: session), "Agent")
        let fetches = notes.store.pendingEditFetchCount
        let text = presenter.host.textView
        for _ in 0..<20 {
            text.insertText("x", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
            XCTAssertEqual(notes.proposalAgent(for: session), "Agent")
        }
        XCTAssertEqual(notes.store.pendingEditFetchCount, fetches, "typing must use the workspace proposal status cache too")
        await notes.store.waitForAttachmentReconciliation()
        XCTAssertTrue(notes.store.discardProposal(proposal.id, noteID: proposal.noteID), notes.store.lastErrorMessage ?? "proposal family refused")
        XCTAssertNil(notes.proposalAgent(for: session), "a new store revision invalidates the cached proposal")
        let emptyFetches = notes.store.pendingEditFetchCount
        for _ in 0..<20 { XCTAssertNil(notes.proposalAgent(for: session)) }
        XCTAssertEqual(notes.store.pendingEditFetchCount, emptyFetches, "an absent-note negative lookup is cached too")
    }
}

@MainActor
extension TaskFilesSliceTests {
    func testP3S2DiscardWorkspaceProposalDeletesEveryAgreeingPhysicalReplica() async throws {
        try await coordinator.finishLaunch()
        let rootID = try XCTUnwrap(tasks.create(title: "Replica proposal")?.id)
        let childID = try XCTUnwrap(tasks.create(title: "Child", parentID: rootID)?.id)
        _ = try open(rootID)
        let (_, error) = try await call(agent(), "make_note_checkbox", ["subtask_id": childID.uuidString])
        XCTAssertFalse(error)
        let proposal = try XCTUnwrap(notes.workspaceProposals.first)
        let proposalID = proposal.id, anchor = proposal.noteID
        let duplicate = NotePendingEdit(id: proposalID, noteID: anchor, baseRevisionToken: proposal.baseRevisionToken,
            proposedContent: try XCTUnwrap(proposal.proposedContent), agentName: proposal.agentName, createdAt: proposal.createdAt)
        try WorkspaceModelFields.copy(Set(WorkspaceModelFields.read(proposal).keys), from: proposal, to: duplicate)
        let edit = ModelContext(container)
        edit.insert(duplicate); try edit.save()
        notes.store.refresh()
        await notes.store.waitForAttachmentReconciliation()
        XCTAssertEqual(try notes.store.pendingEditRows(proposalID).count, 2)
        XCTAssertTrue(notes.store.discardProposal(proposalID, noteID: anchor), notes.store.lastErrorMessage ?? "")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NotePendingEdit>()).filter { $0.id == proposalID }.isEmpty)
        XCTAssertNotNil(tasks.task(withID: childID))
        XCTAssertNil(try ownNote(rootID))
    }
}
