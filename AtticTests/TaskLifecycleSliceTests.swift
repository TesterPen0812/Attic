import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Phase 3 slice 1, "the association and its lifecycle" (UX plan § 2.3.3,
/// § 2.6, § 2.7, § 2.10, § 5.9; S1, S10, S11): the producers, the delete
/// matrices and the restore rules, headless on in-memory stores.
@MainActor
final class TaskLifecycleSliceTests: XCTestCase {
    private var container: ModelContainer!
    private var tasks: TaskStore!
    private var library: AtticLibrary!
    private var notes: NotesPageController!
    private var coordinator: WorkspaceOperationCoordinator!
    private var windows: [NSWindow] = []
    private var presenters: [TaskNotePresenter] = []
    private let panel = NSSize(width: 320, height: 520)

    override func setUp() async throws {
        container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        coordinator = try WorkspaceLegacyBridge.coordinator(for: container)
    }

    override func tearDown() async throws {
        for presenter in presenters where presenter.lease != nil { _ = await presenter.close() }
        presenters.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        notes = nil; library = nil; tasks = nil; coordinator = nil; container = nil
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testOpusR1OrdinaryNoteRestoreAndSecondRestoreDoNotRematerialize() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), tags: ["task-tag"]))
        XCTAssertTrue(try legacyDeleteTask(id))
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        let mine = NoteDocument(blocks: [.text("My ordinary title"), .text("My ordinary body")])
        _ = try notes.store.saveDocument(noteID: noteID, document: mine,
            baseRevisionID: notes.store.note(withID: noteID)?.revisionID, tags: ["mine"]).get()
        XCTAssertTrue(notes.store.recordVersion(noteID: noteID, reason: .pause))
        let version = try XCTUnwrap(notes.store.versions(noteID: noteID).first { $0.content.flatMap { NoteContentCodec.decode($0).document } == mine })
        for _ in 0..<2 {
            XCTAssertTrue(notes.store.delete(try XCTUnwrap(notes.store.note(withID: noteID))))
            XCTAssertTrue(notes.store.restoreDeleted(noteID: noteID))
            XCTAssertEqual(try storedDocument(noteID), mine)
            XCTAssertEqual(notes.store.note(withID: noteID)?.tags, ["mine"])
        }
        _ = try notes.store.restoreVersion(version.id, noteID: noteID).get()
        XCTAssertEqual(try storedDocument(noteID), mine)
        XCTAssertEqual(notes.store.note(withID: noteID)?.tags, ["mine"])
    }

    func testOpusR5OrdinaryProposalListFollowsTheReviewWithATaskPageOpen() async throws {
        let id = try seed(.boundary)
        let taskPage = try open(id)
        notes.taskNotePresenter = taskPage
        await notes.startAndWait()
        let ordinary = UUID()
        _ = try notes.store.createDocumentNote(id: ordinary, document: NoteDocument(blocks: [.text("Ordinary"), .text("Body")])).get()
        XCTAssertTrue(notes.open(noteID: ordinary))
        let revision = try XCTUnwrap(notes.store.note(withID: ordinary)?.revisionToken)
        var ids: Set<UUID> = []
        for text in ["Proposal one", "Proposal two"] {
            guard case let .success(.pending(edit)) = notes.store.agentWrite(noteID: ordinary,
                baseRevisionToken: revision, document: NoteDocument(blocks: [.text("Ordinary"), .text(text)]),
                agentName: "Agent", disposition: .proposal) else { return XCTFail() }
            ids.insert(edit)
        }
        let began = await notes.beginProposalReview(id: try XCTUnwrap(ids.first))
        XCTAssertTrue(began)
        XCTAssertEqual(Set(notes.reviewProposals.map(\.id)), ids)
        XCTAssertTrue(notes.reviewProposals.allSatisfy { $0.noteID == ordinary })
    }

    func testOpusR6CommittedReloadProtectsUnreadableContentAndCancelsPendingSaves() async throws {
        for bytes in [Data("not a document".utf8), Data("{\"format\":1,\"requires\":[\"future\"],\"blocks\":[{\"kind\":\"text\",\"text\":\"Future\"}]}".utf8)] {
            let id = try seed(.boundary)
            await notes.startAndWait()
            let presenter = try open(id), session = try XCTUnwrap(presenter.session)
            type(" pending", into: presenter.host.textView)
            let job = try XCTUnwrap(Mirror(reflecting: session).children.first { $0.label == "saveTask" }?.value as? Task<Void, Never>)
            let context = ModelContext(container), noteID = session.noteID
            let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })).first)
            row.content = bytes; try context.save()
            notes.installCommittedTaskNote(noteID)
            XCTAssertTrue(session.isReadOnly)
            XCTAssertTrue(session.engine.isReadOnly)
            XCTAssertEqual(session.state, .readOnly)
            XCTAssertTrue(job.isCancelled, "failed and read-only loads cannot leave old autosaves scheduled")
            XCTAssertEqual(notes.store.note(withID: noteID)?.content, bytes)
        }
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testOpusR8SeparateRestoreKeepsTheNotesOwnTags() async throws {
        let id = try seed(.boundary)
        let oldID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(notes.store.setTags(["mine"], for: try XCTUnwrap(notes.store.note(withID: oldID))))
        XCTAssertTrue(try legacyDeleteNote(oldID))
        let presenter = try open(id)
        type("New own note", into: presenter.host.textView)
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)))
        await close(presenter)
        XCTAssertTrue(notes.store.restoreDeleted(noteID: oldID))
        XCTAssertEqual(notes.store.note(withID: oldID)?.tags, ["mine"])
    }

    func testOpusR8PreservationSummaryUsesSentenceCaseAndFullOlderDates() throws {
        let id = try seed(.boundary), context = ModelContext(container)
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        task.status = .done
        for date in [Date(), Date().addingTimeInterval(-30 * 86_400)] {
            task.completedAt = date; try context.save()
            let snapshot = try WorkspaceTaskNoteMaterializer.preservation(taskID: id, in: context)
            let document = try WorkspaceTaskNoteMaterializer.materialize(
                NoteDocument(blocks: [.text("Task"), .text("Body")], requires: ["taskNote"]),
                taskID: id, preservation: snapshot).document
            let dateText = Calendar.autoupdatingCurrent.isDate(date, equalTo: Date(), toGranularity: .weekOfYear)
                ? date.formatted(.dateTime.weekday(.abbreviated))
                : date.formatted(.dateTime.day().month(.wide).year())
            XCTAssertFalse(document.blocks.contains { $0.text.contains("Was a task") || $0.text.contains(dateText) }, "2026-10-23: conversion drops completion details")
            XCTAssertEqual(document.blocks[1].kind, .checklist)
        }
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testOpusR10PurgeToastIsObsoleteAfterItsControllerLeaves() async throws {
        let id = try seed(.boundary)
        XCTAssertTrue(try legacyDeleteTask(id))
        var captured: (WorkspaceMaterializationPatch, UUID)?
        notes.taskNoteMaterialized = { captured = ($0, $1) }
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        let patch = try XCTUnwrap(captured), toasts = PanelToastCenter()
        await TaskNotePurgePresentation.finish(patch.0, operationID: patch.1, tasks: tasks, notes: notes,
            uiState: PanelUIState(), toasts: toasts, showNotes: {})
        await notes.waitForRecoveryWork()
        await notes.store.waitForAttachmentReconciliation()
        weak var owner = notes
        notes = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(owner)
        let outcome = await toasts.performActionAsync()
        XCTAssertEqual(outcome, .obsolete)
    }

    func testOpusR7TaskMetadataIsReadOnceForRepeatedRowsAndTags() throws {
        let id = try seed(.boundary)
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, controller: notes, taskStore: tasks)
        for _ in 0..<8 {
            _ = model.groups(store: notes.store, drafts: [])
            _ = model.recentTags(store: notes.store)
        }
        XCTAssertEqual(model.taskMetadataFetchCount, 1)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "Fresh head"))
        XCTAssertTrue(model.groups(store: notes.store, drafts: []).flatMap(\.rows).contains { $0.title == "Fresh head" })
        _ = model.recentTags(store: notes.store)
        XCTAssertEqual(model.taskMetadataFetchCount, 2)
    }

    func testOpusR7TaskNoteSearchKeepsSearchIndexMatches() async throws {
        let id = try seed(.boundary), noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        // The index can match a filename or date chip absent from title/body.
        let model = NotesLibraryModel(search: { _ in [noteID] }, store: notes.store, controller: notes, taskStore: tasks)
        model.query = "attachment-index-match"
        await model.waitForSearch()
        XCTAssertEqual(model.groups(store: notes.store, drafts: []).flatMap(\.rows).map(\.id), [noteID])
        let context = ModelContext(container)
        context.insert(NoteAttachment(noteID: noteID, originalFilename: "attachment-index-match.pdf",
            byteCount: 1, sortIndex: 0, contentDigest: ""))
        try context.save()
        let staleTitle = try XCTUnwrap(tasks.task(withID: id)?.title)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "New live head", tags: ["fresh-tag"]))
        for query in ["attachment-index-match", "New live head", "#fresh-tag"] {
            let found = try await notes.store.searchNoteIDs(matching: query)
            XCTAssertTrue(found.contains(noteID), query)
        }
        let stale = try await notes.store.searchNoteIDs(matching: staleTitle)
        XCTAssertFalse(stale.contains(noteID), "the compatibility title cannot match after a rename")
    }

    func testOpusR7OrdinaryNotesDoNotPublishForUnrelatedTaskChanges() throws {
        makeStores()
        _ = try notes.store.createDocumentNote(id: UUID(), document: .blank).get()
        let task = try XCTUnwrap(tasks.create(title: "Unrelated"))
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, taskStore: tasks)
        _ = model.groups(store: notes.store, drafts: [])
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        XCTAssertTrue(tasks.update(task, title: "Changed"))
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(model.taskMetadataFetchCount, 0)
        withExtendedLifetime(subscription) {}
    }

    func testOpusR4QueuedTypingUsesThePostOperationCaretAndOneUndoGroup() async throws {
        let (_, presenter, session) = try makeSubtaskFixture()
        let view = presenter.host.textView
        view.setSelectedRange(NSRange(location: 60, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        coordinator.afterPreparation = {
            view.insertText(" queued", replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertNewline(nil)
            view.insertText("tail", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        guard case .made = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes) else { return XCTFail() }
        coordinator.afterPreparation = nil
        XCTAssertEqual(view.string, "Everything that has to be true before 1.0 goes out. queued\ntail")
        XCTAssertEqual(session.state, .dirty)
        view.insertText(" continued", replacementRange: NSRange(location: NSNotFound, length: 0))
        let undone = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertEqual(view.string, "Everything that has to be true before 1.0 goes out.")
        XCTAssertEqual(presenter.page.history.undoName, "Make Subtask")
    }

    func testOpusR4ReservationAllowsNavigationAndAnnouncesRefusedMutations() throws {
        let (_, presenter, session) = try makeSubtaskFixture(), view = presenter.host.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        var announcements: [String] = [], escaped = false
        session.engine.announceWorkspaceInputRefusal = { announcements.append($0) }
        view.escapeFallback = { escaped = true }
        XCTAssertTrue(presenter.page.history.reserveInput())
        defer { presenter.page.history.releaseInput() }
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
        view.doCommand(by: #selector(NSResponder.selectWord(_:)))
        XCTAssertGreaterThan(view.selectedRange().length, 0)
        XCTAssertTrue(announcements.isEmpty, "Selection commands are non-mutating navigation")
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(escaped)
        let before = view.string
        view.deleteBackward(nil)
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, before)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertFalse(announcements.isEmpty, "VoiceOver must hear the visible refusal")
    }

    func testOpusR4QueuedTypingSurvivesEditorReplacement() throws {
        let (_, presenter, session) = try makeSubtaskFixture(), oldView = presenter.host.textView
        let oldEngine = session.engine
        let before = oldView.string
        XCTAssertTrue(presenter.page.history.reserveInput())
        oldView.insertText(" queued", replacementRange: NSRange(location: NSNotFound, length: 0))
        notes.installCommittedTaskNote(session.noteID)
        presenter.host.replaceEngine(session.engine)
        let replacement = presenter.host.textView
        XCTAssertFalse(replacement === oldView)
        replacement.setSelectedRange(NSRange(location: replacement.string.utf16.count, length: 0))
        presenter.page.history.releaseInput()
        XCTAssertEqual(replacement.string, before + " queued")
        XCTAssertEqual(oldEngine.textStorage.string, before)
        XCTAssertFalse(oldView.isEditable)
    }

    func testOpusR4ReleasedTypingWaitsForTheReplacementHostsSelection() throws {
        let (_, presenter, session) = try makeSubtaskFixture(), oldView = presenter.host.textView
        let before = oldView.string
        XCTAssertTrue(presenter.page.history.reserveInput())
        oldView.insertText("queued", replacementRange: NSRange(location: NSNotFound, length: 0))
        notes.installCommittedTaskNote(session.noteID)
        session.engine.detachView()
        XCTAssertNil(session.engine.textView)
        presenter.page.history.releaseInput()
        let (scroll, view) = session.engine.makeView()
        defer { withExtendedLifetime(scroll) {} }
        XCTAssertEqual(view.string, before, "creation precedes the host restoring its selection")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        presenter.page.history.inputClientDidAttach()
        let expected = (before as NSString).replacingCharacters(in: NSRange(location: 5, length: 0), with: "queued")
        XCTAssertEqual(view.string, expected)
    }

    func testOpusR3DelayedCommitKeepsNewerTypingAsAConflictAndAllowsDurableClose() async throws {
        let (_, presenter, session) = try makeSubtaskFixture(), view = presenter.host.textView
        view.setSelectedRange(NSRange(location: 60, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        _ = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        XCTAssertNotNil(presenter.page.history.pendingCommandID)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(presenter.page.history.isInputReserved)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText(" newer unsaved writing", replacementRange: NSRange(location: NSNotFound, length: 0))
        let newer = view.string
        XCTAssertTrue(notes.statusItems(for: session).contains { $0.label == "Couldn't finish saving" })
        coordinator.save = { try $0.save() }; coordinator.beforeReconciliationRead = nil
        notes.retry(session)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(presenter.page.history.pendingCommandID)
        XCTAssertEqual(view.string, newer)
        XCTAssertEqual(session.state, .conflict(.changed))
        XCTAssertFalse(try storedDocument(session.noteID).blocks.dropFirst().map(\.text).joined(separator: "\n").contains("newer unsaved writing"))
        let closed = await presenter.close()
        XCTAssertTrue(closed, "the existing unsaved-checkpoint path can close the page")
        XCTAssertTrue(notes.workspaceIsDurable(session))
    }

    func testOpusR3RefusedInputRetriesPublicationBeforeTheTimer() async throws {
        let (_, presenter, _) = try makeSubtaskFixture(), view = presenter.host.textView
        view.setSelectedRange(NSRange(location: 60, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        _ = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        XCTAssertNotNil(presenter.page.history.pendingCommandID)
        coordinator.beforeReconciliationRead = nil
        view.deleteBackward(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(presenter.page.history.pendingCommandID)
        XCTAssertFalse(presenter.page.history.isInputReserved)
    }

    func testOpusR3PendingCloseUsesTheFailedSavePathAndKeepsTheNewestDraft() async throws {
        let (_, presenter, session) = try makeSubtaskFixture(), view = presenter.host.textView
        view.setSelectedRange(NSRange(location: 60, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        _ = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        try await Task.sleep(for: .milliseconds(800))
        await notes.waitForRecoveryWork()
        let directory = coordinator.journal.directory
        XCTAssertTrue(directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path) }
        view.insertText(" newest draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let newest = session.engine.document()
        let refused = await presenter.close()
        XCTAssertFalse(refused)
        guard case .onlyInMemory = session.state else { return XCTFail("failed checkpoint must stay visible") }
        XCTAssertEqual(session.engine.document(), newest)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)
        notes.retry(session)
        await notes.waitForRecoveryWork()
        XCTAssertTrue(notes.workspaceIsDurable(session), "Retry also checkpoints the unsaved draft while publication remains unknown")
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        XCTAssertTrue(notes.workspaceIsDurable(session))
        let entries = try await coordinator.journal.inventoryCheckpoints()
        XCTAssertTrue(entries.contains {
            if case let .valid(entry, _, _) = $0 { return NoteContentCodec.decode(entry.content).document == newest }
            return false
        })
        XCTAssertNotNil(presenter.page.history.pendingCommandID, "closing retains the unresolved operation")
    }

    func testOpusR3InstalledPublicationKeepsTagOnlyDraftDirtyUntilSaved() async throws {
        let (_, presenter, session) = try makeSubtaskFixture(), view = presenter.host.textView
        view.setSelectedRange(NSRange(location: 60, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        var broken = true
        coordinator.save = { context in
            if broken, try context.fetch(FetchDescriptor<OperationReceipt>()).contains(where: \.publicationComplete) {
                throw WorkspaceFoundationError.preparationFailed
            }
            try context.save()
        }
        _ = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        try await Task.sleep(for: .milliseconds(800))
        session.engine.setTagsFromPicker(["unsaved-tag"])
        XCTAssertEqual(session.engine.tags, ["unsaved-tag"])
        broken = false
        notes.retry(session)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(presenter.page.history.pendingCommandID)
        XCTAssertNotEqual(session.state, .clean, "matching body bytes do not prove a tag-only draft saved")
        XCTAssertTrue(notes.save(session))
        XCTAssertEqual(notes.store.note(withID: session.noteID)?.tags, ["unsaved-tag"])
    }

    func testOpusR3ConversionAutomaticallyPublishesAnUnknownCommit() async throws {
        makeStores()
        let id = UUID()
        _ = try notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Convert"), .text("Body")])).get()
        XCTAssertTrue(notes.open(noteID: id))
        let session = try XCTUnwrap(notes.active)
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        _ = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks)
        let history = try XCTUnwrap(session.engine.history.workspace)
        XCTAssertTrue(history.hasPendingPublication)
        coordinator.save = { try $0.save() }; coordinator.beforeReconciliationRead = nil
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(history.hasPendingPublication)
        tasks.refresh(); notes.store.refresh()
        let taskID = try XCTUnwrap(notes.store.note(withID: id)?.taskID)
        XCTAssertNotNil(tasks.task(withID: taskID))
        // Owner decision 2026-10-23: the command is Add to Tasks.
        XCTAssertEqual(history.undoName, "Add to Tasks")
    }

    func testOpusR4UndeliveredTypingCannotPassTheQuitDurabilityBoundary() async throws {
        let (_, presenter, session) = try makeSubtaskFixture(), view = presenter.host.textView
        XCTAssertTrue(presenter.page.history.reserveInput())
        view.insertText("queued", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.engine.detachView()
        presenter.page.history.releaseInput()
        let durable = await notes.preserveAllDurably()
        XCTAssertFalse(durable, "accepted typing must reach a draft before quit is durable")
        presenter.host.replaceEngine(session.engine)
        presenter.page.history.inputClientDidAttach()
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testOpusR3UnknownPurgeRecoversEveryOpenFamilyNoteOnce() async throws {
        let id = try seed(.boundary)
        let child = try XCTUnwrap(tasks.subtasks(of: id).first)
        let childNote = UUID()
        _ = try notes.store.createDocumentNote(id: childNote,
            document: try NoteDocument(blocks: [.text("Child"), .text("Child body")]).taskSnapshot(title: child.title),
            taskOwner: child.id).get()
        let parentPage = try open(id), childPage = try open(child.id)
        XCTAssertTrue(try legacyDeleteTask(id))
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        var installed: Set<UUID> = []
        notes.taskNoteMaterialized = { patch, _ in installed.insert(patch.noteID) }
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(parentPage.page.history.hasPendingPublication)
        XCTAssertTrue(childPage.page.history.hasPendingPublication)
        coordinator.save = { try $0.save() }; coordinator.beforeReconciliationRead = nil
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(parentPage.page.history.hasPendingPublication)
        XCTAssertFalse(childPage.page.history.hasPendingPublication)
        XCTAssertEqual(installed, [parentPage.session!.noteID, childNote])
        XCTAssertFalse(parentPage.session!.engine.isBodyOnly)
        XCTAssertFalse(childPage.session!.engine.isBodyOnly)
    }

    func testOpusR4TypingQueuedDuringConversionSurvivesOpeningTheTaskPage() async throws {
        makeStores()
        let id = UUID(), document = NoteDocument(blocks: [.text("Convert queue"), .text("Body")])
        _ = try notes.store.createDocumentNote(id: id, document: document).get()
        XCTAssertTrue(notes.open(noteID: id))
        let session = try XCTUnwrap(notes.active), view = session.engine.makeView()
        defer { withExtendedLifetime(view.0) {} }
        view.1.setSelectedRange(NSRange(location: view.1.string.utf16.count, length: 0))
        coordinator.afterPreparation = {
            view.1.insertText(" queued", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        coordinator.afterPreparation = nil
        let presenter = try open(taskID)
        presenter.restoreViewStateOnMount()
        XCTAssertTrue(presenter.host.textView.string.contains("queued"))
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)))
        await close(presenter)
        let reopened = try open(taskID)
        XCTAssertTrue(reopened.host.textView.string.contains("queued"))
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testOpusR3PurgeReusesTheCachedNotesHistoryWithoutATaskPresenter() async throws {
        let id = try seed(.boundary), noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(notes.open(noteID: noteID))
        let session = try XCTUnwrap(notes.active), view = session.engine.makeView()
        defer { withExtendedLifetime(view.0) {} }
        XCTAssertNil(session.engine.history.workspace)
        XCTAssertTrue(try legacyDeleteTask(id))
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        let history = try XCTUnwrap(session.engine.history.workspace)
        XCTAssertFalse(history.hasPendingPublication)
        XCTAssertEqual(history.historyID, .note(noteID))
        XCTAssertTrue(notes.undoRoute.workspace(for: .taskWorkspace(id)) === history)
        XCTAssertEqual(history.undoName, "Task removed permanently")
    }

    func testOpusR3PendingConversionUndoRetainsItsReceiptThroughLaunchPruning() async throws {
        makeStores(); await notes.startAndWait()
        let noteID = UUID()
        _ = try notes.store.createDocumentNote(id: noteID, document: NoteDocument(blocks: [.text("Convert receipt"), .text("Body")])).get()
        XCTAssertTrue(notes.open(noteID: noteID))
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks) else { return XCTFail() }
        let presenter = try open(taskID), history = presenter.page.history
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        _ = await history.replay(redo: false)
        let pending = try XCTUnwrap(history.pendingReplayID)
        coordinator.save = { try $0.save() }; coordinator.beforeReconciliationRead = nil
        try await coordinator.reconcileStartup()
        _ = try coordinator.prunePublishedReceipts()
        let retained = try coordinator.freshContext().fetch(FetchDescriptor<OperationReceipt>()).map(\.id)
        XCTAssertTrue(retained.contains(pending), "a pending replay owns its inverse receipt until the editor consumes publication")
        let completed = await history.retryPublication(using: coordinator)
        XCTAssertTrue(completed)
        XCTAssertNil(presenter.lease, "the committed conversion Undo must finish its ordinary-note presentation")
        XCTAssertTrue(notes.open(noteID: noteID))
        XCTAssertFalse(try XCTUnwrap(notes.active).engine.isBodyOnly)
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testOpusR3CachedPurgeKeepsNewerDraftDuringAnUnknownReceipt() async throws {
        let id = try seed(.boundary), noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(notes.open(noteID: noteID))
        let session = try XCTUnwrap(notes.active), view = session.engine.makeView()
        defer { withExtendedLifetime(view.0) {} }
        XCTAssertTrue(try legacyDeleteTask(id))
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        try await Task.sleep(for: .milliseconds(800))
        view.1.insertText(" newest cached draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let draft = session.engine.document()
        coordinator.save = { try $0.save() }; coordinator.beforeReconciliationRead = nil
        notes.retry(session)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(session.engine.document(), draft)
        XCTAssertEqual(session.state, .conflict(.changed))
        XCTAssertFalse(try XCTUnwrap(session.engine.history.workspace).hasPendingPublication)
        XCTAssertFalse(try storedDocument(noteID).requires.contains("taskNote"))
        let kept = await notes.preserveAllDurably()
        XCTAssertTrue(kept)
    }

    // MARK: Fixtures

    // Mutations other than the owner's newly approved plain-typing queue
    // still refuse visibly before storage changes. R4 covers queued typing.
    private func checkReservedInput(_ session: NoteSession, file: StaticString = #filePath, line: UInt = #line) {
        let view = session.engine.textView!
        let before = view.string
        var notices = 0
        let oldNotice = session.engine.onNotice
        session.engine.onNotice = { _ in notices += 1 }
        defer { session.engine.onNotice = oldNotice }
        guard !view.shouldChangeText(in: view.selectedRange(), replacementString: "x") else {
            return XCTFail("Native input admitted during awaited workspace operation", file: file, line: line)
        }
        guard !session.engine.validate(.mark(.bold)).enabled else {
            return XCTFail("Formatting admitted during workspace reservation", file: file, line: line)
        }
        XCTAssertFalse(session.engine.perform(.mark(.bold)), file: file, line: line)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("pasted", forType: .string)
        XCTAssertFalse(view.readSelection(from: board, type: .string), file: file, line: line)
        let drag = ReservedDrag(board: board)
        XCTAssertFalse(view.prepareForDragOperation(drag), file: file, line: line)
        XCTAssertFalse(view.performDragOperation(drag), file: file, line: line)
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText(), "IME is refused before composition begins", file: file, line: line)
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, before, file: file, line: line)
        XCTAssertGreaterThan(notices, 0, "The refusal is visible", file: file, line: line)
    }

    func testP3F1NativeInputIncludingIMEIsRefusedDuringMakeSubtaskAndReplay() async throws {
        let (_, presenter, session) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        coordinator.afterPreparation = { [self] in checkReservedInput(session) }
        defer { coordinator.afterPreparation = nil }
        guard case .made = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes) else { return XCTFail() }
        let undone = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
    }

    func testP3F12WorkspaceReadReturnsReplicaAndExpectedAbsenceTokens() throws {
        let id = try seed(.boundary)
        let tools = AgentTaskTools(store: tasks, noteStore: notes.store, library: library)
        let payload = try json(tools.call(name: "get_task_workspace", arguments: ["id": id.uuidString]))
        XCTAssertNotNil(payload["note_token"] as? String)
        XCTAssertNotNil(payload["association_token"] as? String)
        let empty = try XCTUnwrap(tasks.create(title: "No note"))
        let absent = try json(tools.call(name: "get_task_workspace", arguments: ["id": empty.id.uuidString]))
        XCTAssertNotNil(absent["note_token"] as? String, "expected absence is a token too")
        XCTAssertNotNil(absent["association_token"] as? String)
    }

    func testP3F12SecondaryReplicaAndAssociationChangesMakeTheWholeWriteAReviewedProposal() throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let agentNotes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: agentNotes, library: library)
        for associationChange in [false, true] {
            let expected = try workspaceTokens(id, tools: tools)
            let context = ModelContext(container)
            if associationChange {
                let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskNoteAssociation>()).first { $0.noteID == noteID })
                let other = TaskNoteAssociation(id: row.id, taskID: id, noteID: noteID)
                other.noteGeneration = row.noteGeneration + 1
                context.insert(other)
            } else {
                let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first { $0.id == noteID })
                let other = NoteItem(id: noteID)
                try WorkspaceModelFields.apply(WorkspaceModelFields.read(row), to: other)
                other.pinnedAt = Date()
                context.insert(other)
            }
            try context.save()
            agentNotes.refresh()
            let before = try storedDocument(noteID)
            let revision = try XCTUnwrap(agentNotes.note(withID: noteID)?.revisionToken)
            let reply = try json(tools.call(name: "update_note", arguments: expected.merging([
                "id": noteID.uuidString, "body": "Stale request", "base_revision": revision
            ]) { _, new in new }))
            XCTAssertEqual(reply["status"] as? String, "pending")
            XCTAssertEqual(try storedDocument(noteID), before)
            XCTAssertTrue(agentNotes.pendingEdits(noteID: noteID).allSatisfy(\.needsReview))
            XCTAssertEqual(agentNotes.applyPendingEdits(noteID: noteID), 0)
        }
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F8HistoricalDetachedAssociationDoesNotBlockPurge() async throws {
        let id = try XCTUnwrap(TaskNoteLifecyclePreviewSeed.seed(in: container)[.alternateNote])
        makeStores()
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(notes.store.keepAsSeparateNote(noteID: noteID))
        XCTAssertTrue(try legacyDeleteTask(id))
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id))
        XCTAssertNotNil(notes.store.note(withID: noteID), "separate note survives")
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F14PurgeMaterializesTagsAndReadablePreservedSubtasks() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), tags: ["launch"]))
        XCTAssertTrue(try legacyDeleteTask(id))
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id))
        let document = try storedDocument(noteID)
        XCTAssertFalse(document.blocks.contains { $0.text.hasPrefix("Was a task") }, "2026-10-23: completion details are dropped")
        XCTAssertEqual(document.blocks.filter { $0.kind == .checklist }.map(\.text), ["Write release notes", "Freeze strings"])
        XCTAssertEqual(try rows(noteID).first?.tags, ["launch"])
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F14DeletedNoteRestoredAfterTaskPurgeGetsPreservedTagsAndSummary() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), tags: ["launch"]))
        let deleted = try legacyDeleteNote(noteID)
        XCTAssertTrue(deleted)
        XCTAssertTrue(try legacyDeleteTask(id))
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(notes.store.restoreDeleted(noteID: noteID))
        XCTAssertEqual(try rows(noteID).first?.tags, ["launch"])
        XCTAssertFalse(try storedDocument(noteID).blocks.contains { $0.text.hasPrefix("Was a task") }, "2026-10-23: completion details are dropped")
    }

    func testP3F7AgentWriteToLeasedTaskEditorIsAProposal() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        await notes.recoverAtLaunchAndWait()
        let tools = AgentTaskTools(store: tasks, noteStore: notes.store, library: library)
        let before = try storedDocument(session.noteID)
        let revision = try XCTUnwrap(notes.store.note(withID: session.noteID)?.revisionToken)
        _ = try tools.call(name: "update_note", arguments: workspaceTokens(id, tools: tools).merging(["id": session.noteID.uuidString, "body": "External", "base_revision": revision]) { _, new in new })
        XCTAssertEqual(try storedDocument(session.noteID), before)
        XCTAssertEqual(notes.store.pendingEdits(noteID: session.noteID).count, 1)
        XCTAssertEqual(session.engine.document(), before)
        let edit = try XCTUnwrap(notes.store.pendingEdits(noteID: session.noteID).first)
        let reviewed = await notes.beginProposalReview(id: edit.id)
        XCTAssertTrue(reviewed)
        let accepted = await notes.acceptProposal()
        XCTAssertTrue(accepted)
        XCTAssertEqual(session.engine.document().blocks.last?.text, "External")
        XCTAssertTrue(session.engine.history.workspace === presenter.page.history)
        XCTAssertEqual(presenter.page.history.undoName, "Edited by Agent: can't undo past this")
    }

    func testP3F9MakeSubtaskUndoRefusesAChangedSecondaryReplica() async throws {
        let (id, presenter, _) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        guard case .made = await presenter.makeSubtasks(try XCTUnwrap(presenter.subtaskSelection()), tasks: tasks, notes: notes) else { return XCTFail() }
        let made = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title.hasPrefix("Everything") })
        let context = ModelContext(container)
        let other = TaskItem(id: made.id, title: made.title, status: .done, createdAt: made.createdAt,
                             completedAt: Date(), manualOrder: made.manualOrder, parentID: id)
        other.tags = ["later work"]
        context.insert(other)
        try context.save()
        let undone = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(undone, .failed)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == made.id }.allSatisfy { $0.deletedAt == nil })
    }

    func testP3F9SameWorkspaceEditUndoThenMakeSubtaskUndoStaysChronological() async throws {
        let (id, presenter, _) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        guard case .made = await presenter.makeSubtasks(try XCTUnwrap(presenter.subtaskSelection()), tasks: tasks, notes: notes) else { return XCTFail() }
        let made = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title.hasPrefix("Everything") })
        presenter.model.beginRename(made.id)
        // Use the same workspace route as a committed field edit.
        XCTAssertTrue(library.updateTask(made.id, title: "Temporarily renamed", in: presenter.page.history.historyID).isApplied)
        XCTAssertTrue(presenter.page.history.undo())
        let undone = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertNil(tasks.task(withID: made.id))
    }

    func testP3F17CloseClearsEveryRetainedMenuRelay() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        var owner: NSObject? = NSObject()
        weak var probe = owner
        presenter.menus.noteMenu = { [owner] in _ = owner }
        presenter.menus.taskMenu = { [owner] in _ = owner; return [] }
        presenter.menus.restoreNote = { [owner] in _ = owner }
        presenter.menus.subtaskMenu = { [owner] _ in _ = owner; return [] }
        presenter.menus.reviewAlternate = { [owner] in _ = owner; return [] }
        owner = nil
        await close(presenter)
        XCTAssertNil(probe)
    }

    func testP3F13DoneLogTaskPageCanRenameAndDelete() async throws {
        let id = try seed(.boundary)
        await notes.startAndWait()
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        XCTAssertEqual(tasks.moveCompletedToDoneLog(before: Date().addingTimeInterval(60)), 3)
        presenter.model.refresh()
        presenter.model.beginEditingTitle()
        XCTAssertTrue(presenter.model.isEditingTitle)
        presenter.model.titleEdited(NSRange(location: 0, length: presenter.model.head.title.utf16.count), replacement: "Renamed in log")
        presenter.model.titleEdit.text = "Renamed in log" // the field binding follows its edit callback
        XCTAssertTrue(presenter.model.commitTitle())
        XCTAssertEqual(tasks.listedTask(withID: id)?.title, "Renamed in log")
        XCTAssertTrue(presenter.model.deleteTask())
        XCTAssertNotNil(tasks.deletedFamily(rootID: id))
    }

    func testP3F15AllNotesResolvesLiveTaskTitleAndTagsWithoutRewritingTheNote() throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let before = try rows(noteID).first?.content
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, controller: notes, taskStore: tasks)
        _ = model.groups(store: notes.store, drafts: [])
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "Live task name", tags: ["live-tag"]))
        let row = try XCTUnwrap(model.groups(store: notes.store, drafts: []).flatMap(\.rows).first { $0.id == noteID })
        XCTAssertEqual(row.title, "Live task name")
        XCTAssertTrue(row.spoken.contains("Live task name"))
        XCTAssertFalse(row.spoken.contains("Finalize launch checklist"), "VoiceOver must not read the stale title snapshot")
        model.tagFilter = "live-tag"
        XCTAssertTrue(model.groups(store: notes.store, drafts: []).flatMap(\.rows).contains { $0.id == noteID })
        XCTAssertEqual(try rows(noteID).first?.content, before)
    }

    func testP3F3ConversionReservesNativeInputIncludingIME() async throws {
        makeStores()
        let id = UUID()
        guard case .success = notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Convert"), .text("Keep body")])) else { return XCTFail() }
        XCTAssertTrue(notes.open(noteID: id))
        let session = try XCTUnwrap(notes.active)
        let viewport = session.engine.makeView()
        defer { withExtendedLifetime(viewport) {} }
        coordinator.afterPreparation = { [self] in checkReservedInput(session) }
        defer { coordinator.afterPreparation = nil }
        guard case .made = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        XCTAssertEqual(try storedDocument(id).blocks.last?.text, "Keep body")
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F5PurgeReservesNativeInputThroughRetirement() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(try legacyDeleteTask(id))
        coordinator.afterPreparation = { [self] in checkReservedInput(session) }
        defer { coordinator.afterPreparation = nil }
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id))
        XCTAssertEqual(session.state, .clean)
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F5TypingBeforePurgePresentationClosesKeepsMaterializedContext() async throws {
        let id = try seed(.boundary)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), tags: ["launch"]))
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(try legacyDeleteTask(id))
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertFalse(session.engine.isBodyOnly)
        let view = presenter.host.textView
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type(" Late writing", into: view)
        XCTAssertTrue(notes.save(session))
        let stored = try storedDocument(session.noteID)
        XCTAssertFalse(stored.blocks.contains { $0.text.hasPrefix("Was a task") }, "2026-10-23: no completion summary")
        XCTAssertEqual(stored.blocks.filter { $0.kind == .checklist }.count, 2)
        XCTAssertTrue(stored.blocks.last?.text.hasSuffix(" Late writing") == true)
        XCTAssertEqual(try rows(session.noteID).first?.tags, ["launch"])
        XCTAssertNotEqual(presenter.page.history.undoName, "Task removed permanently", "later typing is after purge in the chronology")
        let undone = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertFalse(session.engine.document().blocks.last?.text.hasSuffix(" Late writing") == true)
        XCTAssertEqual(presenter.page.history.undoName, "Task removed permanently")
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F2PurgeUsesTheControllersRetainedWorkspaceHistory() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let history = presenter.page.history
        let noteID = try XCTUnwrap(presenter.session?.noteID)
        XCTAssertTrue(try legacyDeleteTask(id))
        var captured: (WorkspaceMaterializationPatch, UUID)?
        notes.taskNoteMaterialized = { captured = ($0, $1) }
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        let patch = try XCTUnwrap(captured)
        await TaskNotePurgePresentation.finish(patch.0, operationID: patch.1, tasks: tasks, notes: notes,
                                               uiState: PanelUIState(), toasts: nil, showNotes: {})
        XCTAssertTrue(notes.undoRoute.workspace(for: .note(noteID)) === history)
        XCTAssertEqual(history.undoName, "Task removed permanently")
        XCTAssertTrue(notes.open(noteID: noteID))
        let reopened = try XCTUnwrap(notes.active)
        XCTAssertTrue(reopened.engine.history.workspace === history)
        XCTAssertTrue(reopened.engine.undoCommand(), "native editor Undo uses the retained workspace")
        for _ in 0..<200 where history.undoName == "Task removed permanently" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(history.undoName, "Task removed permanently")
        XCTAssertEqual(try storedDocument(noteID), reopened.engine.document())
        XCTAssertFalse(reopened.engine.document().blocks.contains { $0.text.hasPrefix("Was a task") })
    }

    func testP3F4ConversionUndoRefusesLaterSavedWriting() async throws {
        makeStores()
        let id = UUID()
        guard case .success = notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Convert"), .text("Before")])) else { return XCTFail() }
        XCTAssertTrue(notes.open(noteID: id))
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        let document = try NoteDocument(blocks: [.text("Convert"), .text("Later writing")]).taskSnapshot(title: "Convert")
        guard case .success = notes.store.saveDocument(noteID: id, document: document,
            baseRevisionID: notes.store.note(withID: id)?.revisionID) else { return XCTFail() }
        let workspace = notes.undoRoute.workspace(for: .taskWorkspace(taskID))
        // Exercise the old library route too on the unfixed build.
        let outcome = await notes.undoRoute.replay(in: workspace.canUndo ? workspace.historyID : .notesLibrary, redo: false)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(try storedDocument(id), document)
        XCTAssertNotNil(tasks.task(withID: taskID))
    }

    func testP3F4ConversionUndoInstallsTheOrdinaryEditorWhileItsTaskPageIsOpen() async throws {
        makeStores()
        let id = UUID(), original = NoteDocument(blocks: [.text("Convert mounted"), .text("Body")])
        _ = try notes.store.createDocumentNote(id: id, document: original).get()
        XCTAssertTrue(notes.open(noteID: id))
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        let presenter = try open(taskID)
        let history = presenter.page.history
        let undone = await history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertNil(presenter.lease)
        XCTAssertTrue(notes.open(noteID: id))
        let current = try XCTUnwrap(notes.active)
        XCTAssertFalse(current.engine.isBodyOnly)
        XCTAssertEqual(current.engine.document(), original)
        XCTAssertTrue(current.engine.history.workspace === history)
        let view = current.engine.makeView()
        defer { withExtendedLifetime(view) {} }
        type("More", into: view.1)
        XCTAssertTrue(notes.save(current))
    }

    func testP3F10ConversionKeepsEarlierTitleHistoryAndAllowsUndoAfterAFieldUndo() async throws {
        makeStores()
        let id = UUID()
        _ = try notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Original"), .text("Body")])).get()
        XCTAssertTrue(notes.open(noteID: id))
        let view = try XCTUnwrap(notes.active).engine.makeView()
        view.1.setSelectedRange(NSRange(location: 0, length: 8))
        type("Retitled", into: view.1)
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        let presenter = try open(taskID), history = presenter.page.history
        XCTAssertTrue(library.updateTask(taskID, title: "Temporary", in: history.historyID).isApplied)
        XCTAssertTrue(history.undo())
        let replayed = await history.replay(redo: false)
        XCTAssertEqual(replayed, .applied)
        let current = try XCTUnwrap(notes.active)
        XCTAssertEqual(current.engine.document().title, "Retitled")
        XCTAssertTrue(current.engine.history.workspace === history)
        let earlier = await history.replay(redo: false)
        XCTAssertEqual(earlier, .applied)
        XCTAssertEqual(current.engine.document().title, "Original")
        withExtendedLifetime(view) {}
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F2PurgeToastRefusesInsteadOfUndoingLaterTyping() async throws {
        let id = try seed(.boundary), presenter = try open(id)
        let noteID = try XCTUnwrap(presenter.session?.noteID)
        XCTAssertTrue(try legacyDeleteTask(id))
        var captured: (WorkspaceMaterializationPatch, UUID)?
        notes.taskNoteMaterialized = { captured = ($0, $1) }
        _ = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        let patch = try XCTUnwrap(captured), ui = PanelUIState(), toasts = PanelToastCenter()
        ui.openTaskNote(id, from: .tasks)
        await TaskNotePurgePresentation.finish(patch.0, operationID: patch.1, tasks: tasks, notes: notes,
                                               uiState: ui, toasts: toasts, showNotes: {})
        XCTAssertTrue(notes.open(noteID: noteID))
        let session = try XCTUnwrap(notes.active), view = session.engine.makeView()
        view.1.setSelectedRange(NSRange(location: view.1.string.utf16.count, length: 0))
        type(" Later", into: view.1)
        let before = session.engine.document()
        let outcome = await toasts.performActionAsync()
        if case .failed = outcome {} else { XCTFail("a stale toast must refuse") }
        XCTAssertEqual(session.engine.document(), before)
        toasts.dismiss()
        withExtendedLifetime(view) {}
    }

    func testP3F17MixedReplayRebindsAfterTheOriginalSessionIsEvicted() async throws {
        let id = try seed(.boundary)
        do {
            let presenter = try open(id)
            presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
            guard case .made = await presenter.makeSubtasks(try XCTUnwrap(presenter.subtaskSelection()), tasks: tasks, notes: notes) else { return XCTFail() }
            await close(presenter)
        }
        for i in 0..<12 {
            let noteID = UUID()
            _ = try notes.store.createDocumentNote(id: noteID, document: NoteDocument(blocks: [.text("Other \(i)")])).get()
            XCTAssertTrue(notes.open(noteID: noteID))
        }
        let reopened = try open(id)
        let undone = await reopened.page.history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertTrue(reopened.host.textView.string.hasPrefix("Everything that has"))
    }

    func testP3F10RestoreNoteIsInTheReopenedWorkspaceHistory() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = await notes.deleteNoteDurably(noteID: noteID)
        XCTAssertTrue(deleted)
        XCTAssertNotNil(notes.restoreTaskNote(noteID: noteID))
        let presenter = try open(id)
        XCTAssertEqual(presenter.page.history.undoName, "Restore Note")
        let outcome = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(outcome, .applied)
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.deletedAt != nil })
    }

    func testP3F10VersionRestoreIsUndoableInTheSameChronology() async throws {
        let (_, presenter, session) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        guard case .made = await presenter.makeSubtasks(try XCTUnwrap(presenter.subtaskSelection()), tasks: tasks, notes: notes) else { return XCTFail() }
        let before = session.engine.document()
        let opened = await notes.openHistoryDurably(workspace: session)
        XCTAssertTrue(opened)
        let browser = try XCTUnwrap(notes.historyBrowser)
        notes.selectHistoryVersion(try XCTUnwrap(browser.entries.firstIndex { $0.document.blocks.contains { $0.text.hasPrefix("Everything that has") } }))
        let restored = await notes.restoreHistoryVersionDurably()
        XCTAssertTrue(restored)
        XCTAssertEqual(presenter.page.history.undoName, "Restore Version")
        let undone = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertEqual(session.engine.document(), before)
        XCTAssertEqual(try storedDocument(session.noteID), before)
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testP3F2FamilyPurgeKeepsEachOwningTasksHistoryAndPresentation() async throws {
        let id = try seed(.boundary)
        let parent = try open(id)
        let childID = try XCTUnwrap(tasks.subtasks(of: id).first?.id)
        let child = try open(childID)
        let childSession = try XCTUnwrap(child.session)
        type("Child's own writing", into: child.host.textView)
        XCTAssertTrue(notes.save(childSession))
        let parentNote = try XCTUnwrap(parent.session?.noteID), childNote = childSession.noteID
        let parentHistory = parent.page.history, childHistory = child.page.history
        var patches: [(WorkspaceMaterializationPatch, UUID)] = []
        notes.taskNoteMaterialized = { patches.append(($0, $1)) }
        XCTAssertTrue(try legacyDeleteTask(id))
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.materializedNoteIDs.isSuperset(of: [parentNote, childNote]))
        XCTAssertTrue(notes.undoRoute.workspace(for: .note(parentNote)) === parentHistory)
        XCTAssertTrue(notes.undoRoute.workspace(for: .note(childNote)) === childHistory)
        XCTAssertEqual(parentHistory.undoName, "Task removed permanently")
        XCTAssertEqual(childHistory.undoName, "Task removed permanently")
        let patch = try XCTUnwrap(patches.first { $0.0.noteID == childNote })
        let uiState = PanelUIState()
        uiState.openTaskNote(childID, from: .tasks, backTitle: "Back")
        await TaskNotePurgePresentation.finish(patch.0, operationID: patch.1, tasks: tasks, notes: notes,
                                               uiState: uiState, toasts: nil, showNotes: {})
        XCTAssertNil(child.lease, "close the owner of this note, not the deletion root")
        XCTAssertNotNil(parent.lease)
        let childUndo = await childHistory.replay(redo: false)
        XCTAssertEqual(childUndo, .applied)
        XCTAssertFalse(try storedDocument(childNote).blocks.contains { $0.text.hasPrefix("Was a task") })
        XCTAssertEqual(try storedDocument(parentNote).blocks.filter { $0.kind == .checklist }.count, 2, "the other owner remains materialized")
        let parentUndo = await parentHistory.replay(redo: false)
        XCTAssertEqual(parentUndo, .applied)
        XCTAssertFalse(try storedDocument(parentNote).blocks.contains { $0.text.hasPrefix("Was a task") })
    }

    @discardableResult
    private func seed(_ scenario: TaskNotePreviewSeed.Scenario) throws -> UUID {
        let id = try TaskNotePreviewSeed.seed(scenario, in: container)
        makeStores()
        return id
    }

    private func makeStores() {
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("TaskLifecycle-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: files) }
        tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: files))
        library = AtticLibrary(tasks: tasks)
        notes = NotesPageController(store: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()),
                                    journal: coordinator.journal, defaults: nil,
                                    saveDelay: .seconds(600), durabilityDelay: .seconds(600))
        notes.attachUndoRoute(library.undo)
    }

    private func open(_ taskID: UUID) throws -> TaskNotePresenter {
        let presenter = try TaskNotePresenter(taskID: taskID, tasks: tasks, library: library, notes: notes,
                                              design: .default, columnInset: 28, defaults: nil)
        presenters.append(presenter)
        let host = presenter.host
        host.setContentInsets(top: 76, bottom: 60)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.scrollView.frame = NSRect(origin: .zero, size: panel)
        window.contentView = host.scrollView
        windows.append(window)
        host.restack()
        settle(host.textView)
        return presenter
    }

    private func close(_ presenter: TaskNotePresenter) async {
        let closed = await presenter.close()
        XCTAssertTrue(closed)
        presenters.removeAll { $0 === presenter }
    }

    private func settle(_ textView: NSTextView) {
        textView.window?.contentView?.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        textView.window?.displayIfNeeded()
        RunLoop.main.run(until: Date())
    }

    private func type(_ text: String, into textView: NSTextView) {
        textView.window?.makeFirstResponder(textView)
        for character in text {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(textView)
        }
    }

    private func rows(_ id: UUID) throws -> [NoteItem] {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
    }

    private func ownNotes(_ taskID: UUID) throws -> [NoteItem] {
        try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).filter { $0.taskID == taskID }
    }

    private func associations(note noteID: UUID) throws -> [TaskNoteAssociation] {
        try ModelContext(container).fetch(FetchDescriptor<TaskNoteAssociation>()).filter { $0.noteID == noteID }
    }

    /// Fixtures of pre-2026-10-23 independent deletions; new user commands
    /// are covered by OneItemLifecycleTests and never call these helpers.
    private func legacyDeleteTask(_ id: UUID) throws -> Bool {
        let context = WorkspaceLegacyBridge.context(for: container)
        try TaskStore.stageSoftDeletion(in: context, taskID: id, preservationID: UUID(), timestamp: Date())
        try context.save()
        tasks.refresh(); notes.store.refresh()
        TaskNotePresenter.open(for: id)?.model.refresh()
        return true
    }
    private func legacyDeleteNote(_ id: UUID) throws -> Bool {
        let context = ModelContext(container)
        let files = try context.fetch(FetchDescriptor<NoteAttachment>()).filter { $0.noteID == id }
        for row in try context.fetch(FetchDescriptor<NoteItem>()) where row.id == id {
            row.deletedAt = Date(); row.deletionGroupID = nil
            row.deletedAttachmentIDsRaw = Set(files.map(\.id)).map(\.uuidString).sorted().joined(separator: " ")
        }
        try context.save(); notes.store.refresh()
        return true
    }

    private func storedDocument(_ id: UUID) throws -> NoteDocument {
        let row = try XCTUnwrap(rows(id).first)
        return try XCTUnwrap(row.content.flatMap { NoteContentCodec.decode($0).document })
    }

    // MARK: The row's note glyph (p3-06, D11) and "note kept" (§ 2.7.1)

    func testARowShowsTheNoteGlyphOnlyWhileItsTaskHasALiveOwnNote() throws {
        let id = try seed(.boundary)
        let model = TasksPageModel(library: library)
        XCTAssertFalse(try XCTUnwrap(model.rows(for: .now).first { $0.id == id }).model.hasPage, "no owners known yet")
        model.setNoteOwners([id])
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == id })
        XCTAssertTrue(row.model.hasPage, "the doc.text glyph after the subtask count")
        XCTAssertTrue(row.model.hasDetails)
        XCTAssertTrue(row.model.accessibilityDescription.hasSuffix("has a note"))
        model.setNoteOwners([])
        XCTAssertFalse(try XCTUnwrap(model.rows(for: .now).first { $0.id == id }).model.hasPage, "the note left: so does the glyph")
    }

    func testDeletingATaskRowIsInstantAndItsToastNamesTheWholeItem() throws {
        let id = try seed(.boundary)
        let other = try XCTUnwrap(tasks.create(title: "No note here"))
        let model = TasksPageModel(library: library)
        model.setNoteOwners([id])
        XCTAssertTrue(model.delete([id]).isApplied, "⌫ on a row never asks (P5)")
        XCTAssertEqual(model.toasts.current?.message, "“Finalize launch checklist” deleted")
        XCTAssertNil(tasks.task(withID: id))
        XCTAssertFalse(try ownNotes(id).isEmpty, "the note stays")
        // Orchestrator build rule 2026-10-23: deletion takes the writing too.
        XCTAssertTrue(try ownNotes(id).allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(model.delete([other.id]).isApplied)
        XCTAssertEqual(model.toasts.current?.message, "“No note here” deleted", "a task without a note reads as before")
    }

    // MARK: A deleted task's note from All notes (§ 2.7.2 row 1)

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testADeletedTasksPageOpensInTheQuietDeletedStateWithItsSubtasksAsTheyWere() async throws {
        let id = try seed(.boundary)
        XCTAssertTrue(try legacyDeleteTask(id))
        let presenter = try open(id)
        let model = presenter.model
        XCTAssertFalse(model.head.exists, "the head reads Task deleted · Restore")
        XCTAssertEqual(model.head.title, "Finalize launch checklist", "the title as it was")
        XCTAssertEqual(model.rows.map(\.title), ["Write release notes", "Freeze strings"], "open, then done, read only")
        XCTAssertEqual(model.head.subtasks.done, 1)
        XCTAssertFalse(presenter.host.engine.isReadOnly, "the writing stays editable")
        XCTAssertTrue(model.restoreTask())
        XCTAssertTrue(model.head.exists, "Restore brings the live head back")
        XCTAssertNotNil(tasks.task(withID: id))
    }

    // MARK: "Write a new note" and Restore Note (§ 2.7.2)

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testWritingWhileTheNoteIsInRecentlyDeletedStartsANewSeparateOwnNote() async throws {
        let id = try seed(.boundary)
        let oldID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = try legacyDeleteNote(oldID)
        XCTAssertTrue(deleted)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.deletedNote)
        XCTAssertEqual(presenter.host.engine.bodyPlaceholder, "Write a new note")
        XCTAssertFalse(presenter.host.engine.isReadOnly)
        type("A fresh start", into: presenter.host.textView)
        let session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(notes.save(session), "the first save creates the new own note")
        XCTAssertNotEqual(session.noteID, oldID)
        let live = try ownNotes(id).filter { $0.deletedAt == nil }
        XCTAssertEqual(Set(live.map(\.id)), [session.noteID], "exactly one live own note")
        XCTAssertTrue(try rows(oldID).allSatisfy { $0.deletedAt != nil }, "the old note stays in Recently Deleted")
        XCTAssertFalse(presenter.model.deletedNote, "the Restore Note line goes once the new note exists")
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testRestoreNoteWhileTheTaskHasANewerNoteReturnsItAsAnOrdinaryNote() async throws {
        let id = try seed(.boundary)
        let oldID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = try legacyDeleteNote(oldID)
        XCTAssertTrue(deleted)
        let presenter = try open(id)
        type("Newer", into: presenter.host.textView)
        let newID = try XCTUnwrap(presenter.session?.noteID)
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)))
        await close(presenter)
        let restored = try XCTUnwrap(notes.restoreTaskNote(noteID: oldID))
        XCTAssertTrue(restored.separate, "toast: Note restored as a separate note")
        let old = try rows(oldID)
        XCTAssertTrue(old.allSatisfy { $0.deletedAt == nil && $0.taskID == nil }, "an ordinary note now")
        let document = try storedDocument(oldID)
        XCTAssertFalse(document.requires.contains("taskNote"), "materialized (§ 2.12)")
        XCTAssertEqual(document.title, "Finalize launch checklist", "block 0 carries the task's title")
        XCTAssertEqual(old.first?.tags, ["launch"], "the task's tags are copied")
        XCTAssertTrue(try associations(note: oldID).allSatisfy { $0.detachedAt != nil }, "its association is cleared")
        let reopened = try open(id)
        XCTAssertEqual(reopened.session?.noteID, newID, "the newer note stays the task's own note")
        XCTAssertFalse(reopened.model.deletedNote)
    }

    func testRestoreNoteIsItsOwnUndoStep() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let deleted = await notes.deleteNoteDurably(noteID: noteID)
        XCTAssertTrue(deleted)
        let restored = try XCTUnwrap(notes.restoreTaskNote(noteID: noteID))
        XCTAssertFalse(restored.separate, "the slot was free: it returns as the own note")
        XCTAssertEqual(restored.stepID, notes.undoRoute.undoStepID(in: .taskWorkspace(id)))
        XCTAssertEqual(notes.undoRoute.undoName(in: .taskWorkspace(id)), "Restore Note")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.deletedAt == nil && $0.taskID == id })
        XCTAssertTrue(notes.undoRoute.undo(in: .taskWorkspace(id)), "Undo sends it back to Recently Deleted")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(notes.undoRoute.redo(in: .taskWorkspace(id)))
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.deletedAt == nil && $0.taskID == id })
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testARestoredSeparateNoteCanBeDeletedAndRestoredAgain() async throws {
        let id = try seed(.boundary)
        let oldID = try XCTUnwrap(try ownNotes(id).first?.id)
        _ = try legacyDeleteNote(oldID)
        let presenter = try open(id)
        type("Newer", into: presenter.host.textView)
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)))
        await close(presenter)
        XCTAssertEqual(notes.restoreTaskNote(noteID: oldID)?.separate, true)
        let again = try legacyDeleteNote(oldID)
        XCTAssertTrue(again)
        XCTAssertTrue(notes.store.restoreDeleted(noteID: oldID), "an ordinary note restores as one")
        XCTAssertTrue(try rows(oldID).allSatisfy { $0.deletedAt == nil && $0.taskID == nil })
    }

    // MARK: Make Subtask ⌥⌘S (§ 2.3.3)

    private func attributed(_ paragraphs: [String]) -> NSMutableAttributedString {
        NSMutableAttributedString(string: paragraphs.joined(separator: "\n"))
    }

    func testTheSelectionTableForMakeSubtask() {
        let text = attributed(["Alpha line", "", "Bravo line", "Charlie line"])
        // A caret: the caret's whole paragraph.
        var analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Alpha line"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "\nBravo line\nCharlie line")
        XCTAssertEqual(analysis.candidate(from: text).caret, 0, "the caret stays where the text was")
        // Part of one paragraph: the selected text only; the rest stays.
        analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 6, length: 4))
        XCTAssertEqual(analysis.pieces.map(\.title), ["line"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Alpha \n\nBravo line\nCharlie line")
        // Several paragraphs: partial ends give their part; an empty
        // paragraph wholly selected goes; one subtask per paragraph, in order.
        analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 6, length: 22))
        XCTAssertEqual(analysis.pieces.map(\.title), ["line", "Bravo line", "Charl"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Alpha \nie line")
        // The last paragraph takes the break before it: no empty line left.
        analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: text.length - 2, length: 0))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Charlie line"])
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Alpha line\n\nBravo line")
        // A caret on an empty paragraph makes nothing.
        XCTAssertTrue(TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 11, length: 0)).isEmpty)
    }

    func testANoteCheckboxGivesItsTextAndACheckedBoxACompletedSubtask() {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(attachment: NoteChecklistAttachment(isChecked: true)))
        text.append(NSAttributedString(string: "Shipped it\n"))
        text.append(NSAttributedString(attachment: NoteChecklistAttachment(isChecked: false)))
        text.append(NSAttributedString(string: "Still to do"))
        let analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Shipped it", "Still to do"])
        XCTAssertEqual(analysis.pieces.map(\.isDone), [true, false])
        XCTAssertEqual(analysis.candidate(from: text).text.length, 0, "both lines leave the writing")
    }

    func testLinesWithLinksOrStylesAreAskedAboutAndKeptWhenMade() {
        let text = attributed(["Plain line", "Styled line"])
        text.addAttribute(.noteMark(.bold), value: true, range: NSRange(location: 11, length: 6))
        let analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: 0, length: text.length))
        XCTAssertEqual(analysis.pieces.map(\.title), ["Plain line", "Styled line"])
        XCTAssertEqual(analysis.richCount, 1, "the pop-over counts 1 line")
        XCTAssertEqual(analysis.candidate(from: text).text.string, "Styled line", "Keep Original: the styled line stays unchanged")
        let linked = attributed(["See the doc"])
        linked.addAttribute(.noteMark(.link), value: "https://example.com", range: NSRange(location: 4, length: 3))
        XCTAssertEqual(TaskNoteSubtaskSelection.analyse(linked, selection: NSRange(location: 0, length: 0)).richCount, 1)
    }

    private func makeSubtaskFixture() throws -> (UUID, TaskNotePresenter, NoteSession) {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        return (id, presenter, session)
    }

    func testMakeSubtaskMovesTheCaretsParagraphIntoTheBlockInOneCommitAndUndoRestoresTheExactSource() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let textView = presenter.host.textView
        let before = NSAttributedString(attributedString: textView.textStorage!)
        XCTAssertEqual(before.string, "Everything that has to be true before 1.0 goes out.\nSam owns the pricing page; I take the checklist.")
        textView.setSelectedRange(NSRange(location: 60, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        guard case let .made(entryID, count, kept) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(count, 1); XCTAssertEqual(kept, 0)
        let subtasks = tasks.subtasks(of: id)
        XCTAssertEqual(subtasks.map(\.title), ["Write release notes", "Sam owns the pricing page; I take the checklist.", "Freeze strings"],
                       "a new open subtask joins the end of the open group")
        XCTAssertEqual(textView.string, "Everything that has to be true before 1.0 goes out.")
        XCTAssertEqual(textView.selectedRange().location, textView.string.utf16.count, "the caret stays where the text was")
        let stored = try storedDocument(session.noteID)
        XCTAssertEqual(stored.blocks.dropFirst().map(\.text), ["Everything that has to be true before 1.0 goes out."],
                       "the writing changed in the same commit")
        XCTAssertEqual(stored.blocks.first?.text, "Finalize launch checklist", "block 0 stays the compatibility title")
        XCTAssertEqual(session.state, .clean, "the session took the commit's revision as its base")
        XCTAssertEqual(presenter.page.history.undoName, "Make Subtask")
        XCTAssertEqual(presenter.model.rows.count, 3)
        // Undo: the exact attributed source, in place, with its selection.
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        XCTAssertTrue(textView.textStorage!.isEqual(to: before), "the exact attributed source returns")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 60, length: 0))
        XCTAssertEqual(tasks.subtasks(of: id).count, 2, "the subtask leaves (to Recently Deleted)")
        XCTAssertEqual(try storedDocument(session.noteID).blocks.dropFirst().count, 2)
        XCTAssertEqual(session.state, .clean)
        // Redo makes it again, the same record.
        let redone = await presenter.page.history.replay(redo: true)
        XCTAssertEqual(redone, .applied)
        XCTAssertEqual(tasks.subtasks(of: id).count, 3)
        XCTAssertEqual(textView.string, "Everything that has to be true before 1.0 goes out.")
    }

    func testMakeSubtaskOfACheckedBoxMakesACompletedSubtask() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let textView = presenter.host.textView
        // A checked note checkbox at the end of the writing.
        let storage = try XCTUnwrap(textView.textStorage)
        let box = NSMutableAttributedString(string: "\n", attributes: storage.attributes(at: 0, effectiveRange: nil))
        box.append(NSAttributedString(attachment: NoteChecklistAttachment(isChecked: true)))
        box.append(NSAttributedString(string: "Book the venue", attributes: storage.attributes(at: 0, effectiveRange: nil)))
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.insertText(box, replacementRange: NSRange(location: storage.length, length: 0))
        XCTAssertTrue(notes.save(session))
        textView.setSelectedRange(NSRange(location: storage.length - 2, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        XCTAssertEqual(analysis.pieces.map(\.isDone), [true])
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        guard case .made = result else { return XCTFail("\(result)") }
        let made = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title == "Book the venue" })
        XCTAssertEqual(made.status, .done, "a checked box gives a completed subtask")
        XCTAssertFalse(textView.string.contains("Book the venue"))
    }

    func testMakeSubtaskRefusesInADeletedTaskAndOutsideATasksNote() async throws {
        let (id, presenter, _) = try makeSubtaskFixture()
        await notes.startAndWait()
        XCTAssertNil(presenter.makeSubtaskUnavailableReason(tasks: tasks))
        XCTAssertTrue(library.deleteTasks([id]).isApplied)
        XCTAssertEqual(presenter.makeSubtaskUnavailableReason(tasks: tasks), "The task is deleted")
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        XCTAssertEqual(result, .refused("The task is deleted"))
        XCTAssertEqual(presenter.host.textView.string.components(separatedBy: "\n").count, 2, "nothing moved")
    }

    /// Failure injection (S1): a refused save leaves the writing, the
    /// subtasks, the stored note and the history untouched.
    func testAFailedMakeSubtaskSaveChangesNothing() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let textView = presenter.host.textView
        let before = NSAttributedString(attributedString: textView.textStorage!)
        let storedBefore = try storedDocument(session.noteID)
        let historyBefore = presenter.page.history.undoName
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        let result = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        coordinator.save = { try $0.save() }
        XCTAssertEqual(result, .refused("Couldn't make the subtask"))
        XCTAssertTrue(textView.textStorage!.isEqual(to: before), "the writing is untouched")
        XCTAssertEqual(tasks.subtasks(of: id).count, 2, "no subtask was made")
        XCTAssertEqual(try storedDocument(session.noteID), storedBefore, "the stored note is untouched")
        XCTAssertEqual(presenter.page.history.undoName, historyBefore, "no history entry")
        XCTAssertEqual(session.state, .clean)
        // The same command then works.
        let retried = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes)
        guard case .made = retried else { return XCTFail("\(retried)") }
    }

    func testUndoOfMakeSubtaskRefusesOnceTheSubtaskWasRenamed() async throws {
        let (id, presenter, _) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        guard case let .made(entryID, _, _) = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes) else { return XCTFail() }
        let made = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title.hasPrefix("Everything") })
        // Renamed elsewhere (not through this page's history).
        XCTAssertTrue(tasks.rename(made, to: "Renamed"))
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .failed, "Can't undo: the subtask changed since")
        XCTAssertEqual(tasks.subtasks(of: id).first { $0.id == made.id }?.title, "Renamed", "nothing changed")
        XCTAssertFalse(presenter.host.textView.string.hasPrefix("Everything"))
    }

    // MARK: Make Note Checkbox (§ 2.3.3)

    func testMakeNoteCheckboxPutsTheTitleAtTheTopAndKeepsTheWholeRecordForUndo() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        let subtask = try XCTUnwrap(tasks.subtasks(of: id).first { $0.title == "Write release notes" })
        XCTAssertTrue(tasks.update(subtask, tags: ["copy"], dueDay: .some(DueDay(date: Date().addingTimeInterval(86_400 * 3), calendar: .current))))
        let subtaskID = subtask.id
        let before = NSAttributedString(attributedString: presenter.host.textView.textStorage!)
        let result = await presenter.makeNoteCheckbox(subtaskID: subtaskID, tasks: tasks, notes: notes)
        guard case let .madeCheckbox(entryID, recovery) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(recovery, "its date and 1 tag are in Recently Deleted")
        XCTAssertNil(tasks.task(withID: subtaskID), "the subtask went to Recently Deleted in the same commit")
        let stored = try storedDocument(session.noteID)
        XCTAssertEqual(stored.blocks[1].kind, .checklist, "a note checkbox at the top of the writing")
        XCTAssertEqual(stored.blocks[1].text, "Write release notes")
        XCTAssertEqual(stored.blocks[1].checked, false)
        let records = try ModelContext(container).fetch(FetchDescriptor<TaskDeletionPreservation>()).filter { $0.rootID == subtaskID }
        XCTAssertEqual(records.count, 1, "the complete record is in the operation's recovery record")
        XCTAssertEqual(session.state, .clean)
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        let back = try XCTUnwrap(tasks.task(withID: subtaskID), "Undo brings the same record back")
        XCTAssertEqual(back.title, "Write release notes")
        XCTAssertEqual(back.tags, ["copy"])
        XCTAssertNotNil(back.dueDay)
        XCTAssertTrue(presenter.host.textView.textStorage!.isEqual(to: before))
        let redone = await presenter.page.history.replay(redo: true)
        XCTAssertEqual(redone, .applied)
        XCTAssertNil(tasks.task(withID: subtaskID))
    }

    func testMakeNoteCheckboxCreatesTheNoteWhenTheTaskHasNone() async throws {
        let id = try seed(.nonote)
        let subtask = try XCTUnwrap(tasks.create(title: "Call the venue", parentID: id))
        let presenter = try open(id)
        XCTAssertTrue(try ownNotes(id).isEmpty)
        let session = try XCTUnwrap(presenter.session)
        let result = await presenter.makeNoteCheckbox(subtaskID: subtask.id, tasks: tasks, notes: notes)
        guard case .madeCheckbox = result else { return XCTFail("\(result)") }
        let own = try ownNotes(id)
        XCTAssertEqual(own.map(\.id), [session.noteID], "the page's draft became the task's own note, in the commit")
        XCTAssertTrue(session.isPersisted)
        XCTAssertEqual(try associations(note: session.noteID).filter { $0.detachedAt == nil }.map(\.taskID), [id])
        XCTAssertEqual(try storedDocument(session.noteID).blocks.dropFirst().first?.text, "Call the venue")
        XCTAssertNil(tasks.task(withID: subtask.id))
        XCTAssertEqual(session.state, .clean)
    }

    func testAFailedMakeNoteCheckboxSaveChangesNothing() async throws {
        let id = try seed(.nonote)
        let subtask = try XCTUnwrap(tasks.create(title: "Call the venue", parentID: id))
        let presenter = try open(id)
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        let result = await presenter.makeNoteCheckbox(subtaskID: subtask.id, tasks: tasks, notes: notes)
        coordinator.save = { try $0.save() }
        XCTAssertEqual(result, .refused("Couldn't make the note checkbox"))
        XCTAssertNotNil(tasks.task(withID: subtask.id), "the subtask stays")
        XCTAssertTrue(try ownNotes(id).isEmpty, "no note was created")
        XCTAssertEqual(presenter.session?.isPersisted, false)
        XCTAssertEqual(presenter.host.textView.string, "", "the writing is untouched")
    }

    // MARK: S10: two notes claim one task

    /// A second live note claiming the task (as a replica merge could
    /// leave), made after the seeded one.
    private func addAlternate(to taskID: UUID, body: String = "Notes from the other Mac") throws -> UUID {
        let context = ModelContext(container)
        let id = UUID()
        let note = NoteItem(id: id, createdAt: Date().addingTimeInterval(3_600), updatedAt: Date().addingTimeInterval(3_600))
        note.taskID = taskID
        let document = try NoteDocument(blocks: [.text("Finalize launch checklist"), .text(body)]).taskSnapshot(title: "Finalize launch checklist")
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [note], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(note)
        context.insert(TaskNoteAssociation(taskID: taskID, noteID: id))
        try context.save()
        return id
    }

    func testTwoNotesClaimingOneTaskOpenTheOlderAndOfferTheOtherForReview() async throws {
        let id = try seed(.boundary)
        let own = try XCTUnwrap(try ownNotes(id).first?.id)
        let alternate = try addAlternate(to: id)
        makeStores()
        let presenter = try open(id)
        XCTAssertEqual(presenter.session?.noteID, own, "(createdAt, UUID): the older note is the task's note")
        XCTAssertEqual(presenter.model.alternateNotes, [alternate], "Another note for this task · Review")
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt == nil && $0.taskID == id }, "nothing merges by itself")
    }

    func testKeepAsSeparateNoteMakesTheAlternateAnOrdinaryNote() async throws {
        let id = try seed(.boundary)
        let alternate = try addAlternate(to: id)
        makeStores()
        XCTAssertTrue(notes.store.keepAsSeparateNote(noteID: alternate))
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt == nil && $0.taskID == nil })
        XCTAssertFalse(try storedDocument(alternate).requires.contains("taskNote"))
        XCTAssertEqual(try storedDocument(alternate).blocks.last?.text, "Notes from the other Mac", "its writing is kept")
        XCTAssertTrue(try associations(note: alternate).allSatisfy { $0.detachedAt != nil })
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.alternateNotes.isEmpty)
        XCTAssertFalse(notes.store.keepAsSeparateNote(noteID: try XCTUnwrap(presenter.session?.noteID)),
                       "the task's only note is never separated")
    }

    func testMergeIntoThisNoteJoinsTheWritingInOneStepAndUndoSplitsThemAgain() async throws {
        let id = try seed(.boundary)
        let alternate = try addAlternate(to: id)
        makeStores()
        let presenter = try open(id)
        let before = NSAttributedString(attributedString: presenter.host.textView.textStorage!)
        let result = await presenter.mergeAlternate(alternate, tasks: tasks, notes: notes)
        guard case let .made(entryID, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(presenter.host.textView.string.hasSuffix("\nNotes from the other Mac"))
        XCTAssertEqual(try storedDocument(try XCTUnwrap(presenter.session?.noteID)).blocks.last?.text, "Notes from the other Mac")
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt != nil }, "the other note goes to Recently Deleted")
        XCTAssertTrue(presenter.model.alternateNotes.isEmpty)
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        XCTAssertTrue(presenter.host.textView.textStorage!.isEqual(to: before))
        XCTAssertTrue(try rows(alternate).allSatisfy { $0.deletedAt == nil && $0.taskID == id })
    }

    // MARK: Purge through an open session (§ 2.7.2)

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testPurgingADeletedTaskMakesItsClosedNoteOrdinaryInOneTransaction() async throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        XCTAssertTrue(try legacyDeleteTask(id))
        XCTAssertTrue(tasks.purgeDeleted(before: .distantFuture).isEmpty, "the legacy collector leaves a family with a note")
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id))
        XCTAssertEqual(report.materializedNoteIDs, [noteID])
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })), 0)
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == nil && $0.deletedAt == nil })
        let document = try storedDocument(noteID)
        XCTAssertFalse(document.requires.contains("taskNote"))
        XCTAssertEqual(document.title, "Finalize launch checklist")
        XCTAssertEqual(document.blocks[3].text, "Everything that has to be true before 1.0 goes out.", "2026-10-23: body follows the two subtasks")
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testPurgeWhileTheTasksPageIsOpenMergesItsUnsavedWritingAndTheNoteBecomesOrdinary() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        let session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(try legacyDeleteTask(id))
        presenter.host.textView.setSelectedRange(NSRange(location: presenter.host.textView.string.utf16.count, length: 0))
        type(" Still writing.", into: presenter.host.textView)
        XCTAssertNotEqual(session.state, .clean, "unsaved writing")
        var materialized: [UUID] = []
        notes.taskNoteMaterialized = { patch, _ in materialized.append(patch.noteID) }
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id))
        XCTAssertEqual(materialized, [session.noteID], "the page is told to leave")
        let document = try storedDocument(session.noteID)
        XCTAssertTrue(document.blocks.map(\.text).contains("Sam owns the pricing page; I take the checklist. Still writing."),
                      "the draft is merged, never replaced by stored content")
        XCTAssertFalse(document.requires.contains("taskNote"))
        XCTAssertTrue(try rows(session.noteID).allSatisfy { $0.taskID == nil })
        XCTAssertEqual(session.state, .clean, "what the editor shows is what the purge saved")
        await close(presenter)
        XCTAssertTrue(try rows(session.noteID).allSatisfy { $0.taskID == nil }, "leaving never writes the task note back")
        XCTAssertFalse(try storedDocument(session.noteID).requires.contains("taskNote"))
    }

    // 2026-10-23: legacy independent deletions retain compatibility coverage.
    func testPurgeWaitsWhileTheOpenNoteIsComposing() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(try legacyDeleteTask(id))
        let textView = presenter.host.textView
        textView.window?.makeFirstResponder(textView)
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertEqual(report.deferredRootIDs, [id], "IME composition: the purge waits for a later cleanup")
        XCTAssertTrue(report.removedTaskIDs.isEmpty)
        XCTAssertTrue(try ownNotes(id).allSatisfy { $0.taskID == id }, "nothing was written")
        textView.unmarkText()
    }

    // MARK: The family contract (§ 2.6)

    func testCompletingTheTaskOnItsPageCompletesItsOpenSubtasksAndKeepsThePage() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        XCTAssertEqual(tasks.task(withID: id)?.status, .done)
        XCTAssertTrue(tasks.subtasks(of: id).allSatisfy { $0.status == .done }, "one family operation")
        presenter.model.refresh()
        XCTAssertEqual(presenter.model.head.state, .done)
        XCTAssertTrue(presenter.model.head.exists)
        XCTAssertNotNil(presenter.lease, "completing never navigates away")
        XCTAssertFalse(presenter.host.engine.isReadOnly, "the writing stays editable")
        XCTAssertEqual(TaskNotePage.completionMessage(subtasks: 1), "Task and 1 subtask completed")
    }

    func testDoneCleanupWithTheTaskPageOpenKeepsItsHeadSubtasksAndWriting() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        let cutoff = Date().addingTimeInterval(60)
        XCTAssertEqual(tasks.moveCompletedToDoneLog(before: cutoff), 3, "next-day cleanup moves the family to the Done log")
        presenter.model.refresh()
        XCTAssertTrue(presenter.model.head.exists, "a Done-log task still has its page")
        XCTAssertEqual(presenter.model.head.state, .done)
        XCTAssertEqual(presenter.model.rows.count, 2, "its subtasks stay on the page")
        XCTAssertFalse(try ownNotes(id).isEmpty)
        type(" More.", into: presenter.host.textView)
        XCTAssertTrue(notes.save(try XCTUnwrap(presenter.session)), "the note stays editable")
    }

    func testADivergentDuplicateBlocksDoneCleanupWhileThePageIsOpen() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        // A second physical replica of the task that disagrees.
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        let replica = TaskItem(id: id, title: row.title + " (other Mac)", status: .done, createdAt: row.createdAt,
                               completedAt: row.completedAt, manualOrder: row.manualOrder)
        context.insert(replica)
        try context.save()
        tasks.refresh()
        XCTAssertEqual(tasks.moveCompletedToDoneLog(before: Date().addingTimeInterval(60)), 0, "replicas must agree first")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).allSatisfy { $0.doneLoggedAt == nil })
        presenter.model.refresh()
        XCTAssertTrue(presenter.model.head.exists)
    }

    func testReopenTaskAndContinueUnticksASubtaskOfADoneTask() async throws {
        let id = try seed(.boundary)
        let presenter = try open(id)
        XCTAssertTrue(presenter.model.toggleTask())
        let sub = try XCTUnwrap(tasks.subtasks(of: id).first)
        XCTAssertTrue(presenter.model.needsReopen(toggling: sub.id), "unticking under a Done task asks first")
        XCTAssertTrue(presenter.model.reopenTask())
        XCTAssertNotEqual(tasks.task(withID: id)?.status, .done)
        XCTAssertTrue(presenter.model.toggle(sub.id))
        XCTAssertEqual(tasks.task(withID: sub.id)?.status, .todo)
        XCTAssertFalse(presenter.model.needsReopen(toggling: sub.id))
    }

    // Build rules 2026-10-23: the same writing survives circle removal.
    // Owner answer: only children become checkboxes; task details are dropped.
    // Orchestrator decision: Undo is the sole return to the old task.
    func testBRemoveKeepsWritingDropsDetailsAndRestoresExactFamilyThroughUndoRedo() async throws {
        let id = try seed(.boundary), presenter = try open(id)
        let session = try XCTUnwrap(presenter.session), noteID = session.noteID
        let original = try storedDocument(noteID)
        let context = ModelContext(container)
        let family = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id || $0.parentID == id }
        let before = try Dictionary(uniqueKeysWithValues: family.map { ($0.persistentModelID, try WorkspaceModelFields.read($0)) })
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(result, .removed(noteID: noteID))
        guard case .removed = result else { return }
        XCTAssertNil(tasks.task(withID: id))
        XCTAssertTrue(tasks.recentlyDeletedTasks().isEmpty, "circle removed is hidden from trash")
        let ordinary = try storedDocument(noteID)
        XCTAssertFalse(ordinary.requires.contains("taskNote"))
        XCTAssertEqual(ordinary.blocks.dropFirst().prefix(2).map(\.text), ["Write release notes", "Freeze strings"])
        XCTAssertEqual(ordinary.blocks.dropFirst().prefix(2).map(\.checked), [false, true])
        XCTAssertEqual(Array(ordinary.blocks.dropFirst(3)), Array(original.blocks.dropFirst()))
        XCTAssertFalse(ordinary.blocks.contains { $0.text.contains("Was a task") || $0.text.contains("Due:") })
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == nil && $0.deletedAt == nil })
        XCTAssertTrue(try associations(note: noteID).allSatisfy { $0.detachedAt != nil && $0.detachedPreservationID != nil })
        let history = presenter.page.history
        await close(presenter)
        XCTAssertEqual(history.undoName, "Remove from Tasks")
        var opened: UUID?
        notes.openTaskPage = { opened = $0; return true }
        let undone = await history.replay(redo: false); XCTAssertEqual(undone, .applied)
        XCTAssertEqual(opened, id, "native workspace Undo returns to the task page")
        XCTAssertEqual(try storedDocument(noteID), original)
        for row in try ModelContext(container).fetch(FetchDescriptor<TaskItem>()) where before[row.persistentModelID] != nil {
            XCTAssertEqual(try WorkspaceModelFields.read(row), before[row.persistentModelID])
        }
        let redone = await history.replay(redo: true); XCTAssertEqual(redone, .applied)
        XCTAssertEqual(try storedDocument(noteID), ordinary)
    }

    func testBRemoveFailureRollsBackEveryRowAndReceipt() async throws {
        let id = try seed(.boundary), presenter = try open(id)
        let session = try XCTUnwrap(presenter.session), original = try storedDocument(session.noteID)
        let receipts = try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>())
        var attempted = false
        coordinator.save = { _ in attempted = true; throw WorkspaceFoundationError.unknown }
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        coordinator.save = { try $0.save() }
        guard case .refused = result else { return XCTFail("failed save succeeded") }
        XCTAssertTrue(attempted, "exercise the staged conversion, not a preflight refusal")
        XCTAssertNotNil(tasks.task(withID: id)); XCTAssertEqual(try storedDocument(session.noteID), original)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>()), receipts)
        XCTAssertTrue(try associations(note: session.noteID).allSatisfy { $0.detachedAt == nil })
    }

    func testBRemoveRefusesAlternateWritingAndDivergentFamily() async throws {
        let id = try seed(.boundary), presenter = try open(id)
        let session = try XCTUnwrap(presenter.session), original = try storedDocument(session.noteID)
        let context = ModelContext(container)
        let alternate = NoteItem(title: "Other writing", body: "Keep me"); alternate.taskID = id
        context.insert(alternate); try context.save()
        var result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        guard case .refused = result else { return XCTFail("S10 must resolve first") }
        context.delete(alternate); try context.save()
        let replica = TaskItem(id: id, title: "Different head"); context.insert(replica); try context.save()
        result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        guard case .refused = result else { return XCTFail("divergence must refuse") }
        XCTAssertEqual(try storedDocument(session.noteID), original)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.deletedAt == nil })
    }

    func testBAddCommitsBlankTitleInNowWithoutParsingOrPromotingCheckboxes() async throws {
        makeStores()
        let id = UUID(), original = NoteDocument(blocks: [.text(""), .checklist("Tomorrow !high", checked: true)])
        _ = try notes.store.createDocumentNote(id: id, document: original, tags: ["mine"]).get()
        XCTAssertTrue(notes.open(noteID: id))
        let result = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks)
        guard case let .made(taskID) = result else { return XCTFail("blank title must commit: \(result)") }
        let task = try XCTUnwrap(tasks.task(withID: taskID))
        XCTAssertEqual(task.title, ""); XCTAssertEqual(task.status, .todo)
        XCTAssertNil(task.dueDay); XCTAssertEqual(task.priority, .none)
        XCTAssertTrue(tasks.subtasks(of: taskID).isEmpty)
        XCTAssertEqual(Array(try storedDocument(id).blocks.dropFirst()), Array(original.blocks.dropFirst()))
    }

    func testBRemoveThenAddAlwaysMakesFreshTaskAndUndoCanReturnTheRetiredOne() async throws {
        let id = try seed(.boundary), presenter = try open(id)
        let session = try XCTUnwrap(presenter.session), noteID = session.noteID, history = presenter.page.history
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: noteID))
        await close(presenter)
        XCTAssertTrue(notes.open(noteID: noteID))
        guard case let .made(fresh) = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks) else { return XCTFail() }
        XCTAssertNotEqual(fresh, id); XCTAssertNil(tasks.task(withID: id)); XCTAssertTrue(tasks.subtasks(of: fresh).isEmpty)
        let undoAdd = await history.replay(redo: false); XCTAssertEqual(undoAdd, .applied)
        let undoRemove = await history.replay(redo: false); XCTAssertEqual(undoRemove, .applied)
        XCTAssertNotNil(tasks.task(withID: id)); XCTAssertNil(tasks.task(withID: fresh))
        let redoRemove = await history.replay(redo: true); XCTAssertEqual(redoRemove, .applied)
        let redoAdd = await history.replay(redo: true); XCTAssertEqual(redoAdd, .applied)
        XCTAssertNotNil(tasks.task(withID: fresh)); XCTAssertNil(tasks.task(withID: id))
    }

    func testBRemoveExcludesPreviouslyDeletedChildrenAndKeepsEveryReplica() async throws {
        let id = try seed(.boundary)
        let context = ModelContext(container)
        for task in try context.fetch(FetchDescriptor<TaskItem>()) {
            let copy = TaskItem(title: ""); try WorkspaceModelFields.apply(WorkspaceModelFields.read(task), to: copy); context.insert(copy)
        }
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        for note in try rows(noteID) {
            let copy = NoteItem(); try WorkspaceModelFields.apply(WorkspaceModelFields.read(note), to: copy)
            copy.pinnedAt = note.isPinned ? nil : Date(); context.insert(copy)
        }
        let earlier = TaskItem(title: "Earlier deleted child", parentID: id)
        earlier.deletedAt = Date(timeIntervalSince1970: 1); earlier.deletionRootID = earlier.id
        earlier.deletionMembersRaw = earlier.id.uuidString; context.insert(earlier); try context.save()
        tasks.refresh(); notes.store.refresh()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(result, .removed(noteID: noteID))
        XCTAssertFalse(try storedDocument(noteID).blocks.contains { $0.text == "Earlier deleted child" })
        let copies = try rows(noteID)
        XCTAssertEqual(copies.count, 2); XCTAssertEqual(copies.filter(\.isPinned).count, 1)
        XCTAssertTrue(copies.allSatisfy { $0.taskID == nil })
        let family = try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id || $0.parentID == id }
        XCTAssertTrue(family.allSatisfy { $0.deletedAt != nil })
        XCTAssertEqual(family.first { $0.id == earlier.id }?.deletedAt, earlier.deletedAt)
    }

    func testBRemoveReservesInputAndGuardsLaterWriting() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let view = presenter.host.textView, history = presenter.page.history
        var reserved = false
        coordinator.afterPreparation = {
            reserved = history.isInputReserved
            view.insertText("queued", replacementRange: NSRange(location: NSNotFound, length: 0))
            view.setMarkedText("composition", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(view.hasMarkedText())
        }
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        coordinator.afterPreparation = nil
        XCTAssertEqual(result, .removed(noteID: session.noteID)); XCTAssertTrue(reserved)
        XCTAssertTrue(history.hasQueuedTyping || session.engine.textStorage.string.contains("queued"))
        await close(presenter)
        XCTAssertTrue(notes.open(noteID: session.noteID))
        let active = try XCTUnwrap(notes.active)
        if let textView = active.engine.textView { textView.insertText("later", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        // Queued typing is its own later step. Undo it before testing the
        // guarded conversion inverse against independently saved writing.
        if history.undoName != "Remove from Tasks" { _ = await history.replay(redo: false) }
        // An independent saved edit must refuse the conversion inverse.
        var changed = try storedDocument(session.noteID); changed.blocks.append(.text("Outside edit"))
        _ = try notes.store.saveDocument(noteID: session.noteID, document: changed,
            baseRevisionID: notes.store.note(withID: session.noteID)?.revisionID).get()
        let undo = await history.replay(redo: false); XCTAssertEqual(undo, .failed)
        XCTAssertEqual(try storedDocument(session.noteID), changed)
    }

    func testBRemoveRejectsUnprovenEarlierFilesThenSucceedsAfterMove() async throws {
        let id = try seed(.boundary)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("AtticB-\(UUID()).txt")
        try Data("legacy bytes".utf8).write(to: input); defer { try? FileManager.default.removeItem(at: input) }
        let references = try await tasks.taskImageFiles.importAttachments([input], existing: [])
        let context = ModelContext(container)
        for task in try context.fetch(FetchDescriptor<TaskItem>()) where task.id == id {
            task.imageReferencesData = try JSONEncoder().encode(references)
        }
        try context.save(); tasks.refresh()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let refused = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(refused, .refused(TaskNoteConversion.earlierFilesReason))
        await close(presenter)
        let moved = await tasks.fileMigration.moveIntoNote(id, tasks: tasks, notes: notes)
        guard case .migrated = moved else { return XCTFail("\(moved)") }
        let reopened = try open(id), writing = try XCTUnwrap(reopened.session)
        let beforeRace = try storedDocument(writing.noteID)
        coordinator.afterPreparation = {
            let outside = ModelContext(self.container)
            for record in (try? outside.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>())) ?? [] where record.id == id {
                record.stateRaw = "reversed"
            }
            try? outside.save()
        }
        let raced = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: writing)
        coordinator.afterPreparation = nil
        guard case .refused = raced else { return XCTFail("changed migration proof must refuse") }
        XCTAssertEqual(try storedDocument(writing.noteID), beforeRace)
        let reset = ModelContext(container)
        for record in try reset.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>()) where record.id == id { record.stateRaw = "migrated" }
        try reset.save()
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: writing)
        XCTAssertEqual(result, .removed(noteID: writing.noteID))
        XCTAssertEqual(try storedDocument(writing.noteID).attachmentIDs, references.map(\.id))
        let attachments = try ModelContext(container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(attachments.first?.payload, Data("legacy bytes".utf8))
    }

    func testBCircleRemovedFamilyPurgesAfterHistoryExpiresAndKeepsEditedWritingAndRedirect() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(result, .removed(noteID: session.noteID))
        await close(presenter)
        XCTAssertFalse(tasks.restoreDeleted(taskID: id), "only Undo can return a retired circle")
        presenter.page.history.clear()
        var changed = try storedDocument(session.noteID); changed.blocks.append(.text("New ordinary writing"))
        _ = try notes.store.saveDocument(noteID: session.noteID, document: changed,
            baseRevisionID: notes.store.note(withID: session.noteID)?.revisionID).get()
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id), "\(report)")
        XCTAssertEqual(try storedDocument(session.noteID), changed)
        XCTAssertFalse(try associations(note: session.noteID).isEmpty)
    }

    func testBRetiredFamilyPurgeRedirectsBothLinkEndsAndPreservesReplicas() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let context = WorkspaceLegacyBridge.context(for: container), outside = UUID(), linkID = UUID()
        for _ in 0..<2 {
            context.insert(ItemLink(id: linkID, source: .init(.note, outside), target: .init(.task, id), kind: .card,
                createdAt: Date(timeIntervalSince1970: 1)))
        }
        let reverse = ItemLink(source: .init(.task, id), target: .init(.note, outside), kind: .reference)
        reverse.deletedAt = Date(timeIntervalSince1970: 2); context.insert(reverse)
        try context.save()
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        await close(presenter); presenter.page.history.clear()
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id), "\(report)")
        let links = try ModelContext(container).fetch(FetchDescriptor<ItemLink>())
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links.filter { $0.id == linkID && $0.target == .init(.note, session.noteID) && $0.kind == .card }.count, 2)
        XCTAssertEqual(links.first { $0.id == reverse.id }?.source, .init(.note, session.noteID))
        XCTAssertEqual(links.first { $0.id == reverse.id }?.deletedAt, reverse.deletedAt)
    }

    func testBPurgingReaddedNoteTakesOlderRetiredFamilyInSameCommit() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let history = presenter.page.history, noteID = session.noteID
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: noteID)); await close(presenter)
        XCTAssertTrue(notes.open(noteID: noteID))
        guard case let .made(fresh) = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks) else { return XCTFail() }
        XCTAssertTrue(library.deleteListedTasks([fresh]).isApplied)
        await notes.waitForRecoveryWork(); history.clear()
        let freshRow = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == fresh })
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture,
            confirmed: [fresh: try XCTUnwrap(freshRow.deletedAt)])
        XCTAssertTrue(report.removedTaskIDs.contains(fresh), "\(report)")
        XCTAssertTrue(report.removedTaskIDs.contains(id), "old hidden family belongs to the same purge commit")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).isEmpty)
        let later = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(later.deferredRootIDs.isEmpty, "no invisible orphan remains: \(later)")
    }

    func testBTagRenameDoesNotStrandCircleRemovedFamily() async throws {
        let id = try seed(.boundary)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), tags: ["before"]))
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID)); await close(presenter)
        presenter.page.history.clear()
        XCTAssertTrue(library.renameTag("before", to: "after"))
        let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(report.removedTaskIDs.contains(id), "\(report)")
        XCTAssertEqual(notes.store.note(withID: session.noteID)?.tags, ["after"])
    }

    func testBEarlierDeletedChildIsHiddenOnlyWithAtomicFamilyPurge() async throws {
        let id = try seed(.boundary), context = WorkspaceLegacyBridge.context(for: container)
        let earlier = TaskItem(title: "Earlier deleted child", parentID: id)
        earlier.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(earlier); try context.save(); tasks.refresh()
        XCTAssertTrue(tasks.delete(taskIDs: [earlier.id]))
        let old = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == earlier.id })
        let originalFields = try WorkspaceModelFields.read(old)
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        XCTAssertFalse(tasks.recentlyDeletedTasks().contains { $0.ref.id == earlier.id }, "never advertise an unrestorable child")
        let undone = await presenter.page.history.replay(redo: false); XCTAssertEqual(undone, .applied)
        XCTAssertTrue(tasks.recentlyDeletedTasks().contains { $0.ref.id == earlier.id })
        XCTAssertEqual(try WorkspaceModelFields.read(try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == earlier.id })), originalFields)
        let redone = await presenter.page.history.replay(redo: true); XCTAssertEqual(redone, .applied)
        await close(presenter); presenter.page.history.clear()
        let result = await WorkspacePurge.purge(rootID: id, before: .distantFuture,
            coordinator: coordinator, files: tasks.taskImageFiles,
            inventory: { self.notes.taskNotePurgeInventory(ownNotes: []) })
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertTrue(result.removedIDs.contains(id))
        XCTAssertTrue(result.removedIDs.contains(earlier.id), "one family commit must collect the hidden earlier deletion")
        XCTAssertFalse(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).contains { $0.id == earlier.id })
    }

    func testBLegacyCollectorCannotSplitCapturedEarlierChildFromCirclePurge() async throws {
        let id = try seed(.boundary), context = WorkspaceLegacyBridge.context(for: container)
        let child = TaskItem(title: "Earlier", parentID: id)
        child.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(child); try context.save(); tasks.refresh()
        XCTAssertTrue(tasks.delete(taskIDs: [child.id]))
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID)); await close(presenter); presenter.page.history.clear()
        XCTAssertFalse(tasks.purgeDeleted(before: .distantFuture).contains(child.id), "daily cleanup's first collector must keep captured members")
        let result = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(result.removedTaskIDs.isSuperset(of: [id, child.id]), "\(result)")
    }

    // Fix check 2026-10-24: restorable writing must keep its entire restore window.
    func testBRemoveRefusesEarlierDeletedChildWritingAndKeepsItRestorable() async throws {
        let id = try seed(.boundary), context = WorkspaceLegacyBridge.context(for: container)
        let child = TaskItem(title: "Earlier", parentID: id), childNote = NoteItem(title: "Earlier")
        child.listOrderVersion = TaskItem.currentListOrderVersion; childNote.taskID = child.id
        let document = try NoteDocument(blocks: [.text("Earlier"), .text("Earlier writing")]).taskSnapshot(title: "Earlier")
        NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [childNote], timestamp: Date(), revision: 0, revisionID: UUID())
        context.insert(child); context.insert(childNote); try context.save(); tasks.refresh(); notes.store.refresh()
        library = AtticLibrary(tasks: tasks, notes: notes.store, undo: library.undo)
        XCTAssertTrue(tasks.delete(taskIDs: [child.id]))
        let before = try WorkspaceModelFields.read(try XCTUnwrap(rows(childNote.id).first))
        let childBefore = try WorkspaceModelFields.read(try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == child.id }))
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let parentBefore = try storedDocument(session.noteID)
        let receipts = try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>())
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .refused("Restore or empty the deleted subtask's writing before removing from Tasks"))
        XCTAssertNotNil(tasks.task(withID: id))
        XCTAssertTrue(library.recentlyDeleted().contains { $0.ref.id == child.id || $0.ref.id == childNote.id })
        XCTAssertEqual(try WorkspaceModelFields.read(try XCTUnwrap(rows(childNote.id).first)), before)
        XCTAssertEqual(try WorkspaceModelFields.read(try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == child.id })), childBefore)
        XCTAssertEqual(try storedDocument(session.noteID), parentBefore)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>()), receipts)
        XCTAssertTrue(notes.store.restoreDeleted(noteID: childNote.id))
        XCTAssertEqual(try storedDocument(childNote.id).blocks.map(\.text), ["Earlier", "Earlier writing"])
        XCTAssertTrue(try storedDocument(childNote.id).requires.contains("taskNote"), "Restore still returns the original paired child")
        XCTAssertNotNil(tasks.task(withID: child.id))
    }

    func testBRemoveRefusesWritingJoiningEarlierDeletionGroupDuringPreparation() async throws {
        let id = try seed(.boundary), context = WorkspaceLegacyBridge.context(for: container)
        let child = TaskItem(title: "Earlier", parentID: id)
        child.listOrderVersion = TaskItem.currentListOrderVersion; context.insert(child); try context.save(); tasks.refresh()
        XCTAssertTrue(tasks.delete(taskIDs: [child.id]))
        let deleted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.id == child.id })
        let group = try XCTUnwrap(deleted.deletionGroupID), date = try XCTUnwrap(deleted.deletedAt)
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let before = try storedDocument(session.noteID)
        let receipts = try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>())
        let writingID = UUID()
        var injected = false
        coordinator.afterPreparation = {
            self.coordinator.afterPreparation = nil
            let external = ModelContext(self.container)
            let writing = NoteItem(id: writingID, title: "Still restorable", body: "Keep my writing")
            writing.deletedAt = date; writing.deletionGroupID = group
            external.insert(writing); try! external.save()
            injected = true
        }
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        coordinator.afterPreparation = nil
        XCTAssertTrue(injected, "exercise the journal-time membership race")
        XCTAssertEqual(removed, .refused("Restore or empty the deleted subtask's writing before removing from Tasks"))
        XCTAssertNotNil(tasks.task(withID: id))
        XCTAssertEqual(try storedDocument(session.noteID), before)
        XCTAssertEqual(try rows(writingID).first?.body, "Keep my writing")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<OperationReceipt>()), receipts)
        XCTAssertTrue(library.recentlyDeleted().contains { $0.ref.id == child.id || $0.ref.id == writingID })
    }

    func testBRetiredFamilyPurgeDropsSelfLinksWithoutChangingWriting() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let context = WorkspaceLegacyBridge.context(for: container)
        for reverse in [false, true] {
            let linkID = UUID(), date = Date(timeIntervalSince1970: 1)
            for _ in 0..<2 {
                context.insert(ItemLink(id: linkID,
                    source: .init(reverse ? .task : .note, reverse ? id : session.noteID),
                    target: .init(reverse ? .note : .task, reverse ? session.noteID : id), kind: .card, createdAt: date))
            }
        }
        try context.save()
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        let writing = try storedDocument(session.noteID)
        await close(presenter); presenter.page.history.clear()
        let result = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(result.removedTaskIDs.contains(id), "\(result)")
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ItemLink>()).isEmpty, "never produce note → same note")
        XCTAssertEqual(try storedDocument(session.noteID), writing, "link cleanup must not remove any writing or card blocks")
    }

    func testBLegacyPurgeRedirectsLinksWhenMaterializingSurvivingWriting() async throws {
        let id = try seed(.boundary), noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let context = WorkspaceLegacyBridge.context(for: container), outside = UUID(), linkID = UUID()
        for _ in 0..<2 {
            context.insert(ItemLink(id: linkID, source: .init(.note, outside), target: .init(.task, id), kind: .card,
                createdAt: Date(timeIntervalSince1970: 1)))
        }
        let reverse = ItemLink(source: .init(.task, id), target: .init(.note, outside), kind: .reference)
        reverse.deletedAt = Date(timeIntervalSince1970: 2); context.insert(reverse)
        context.insert(ItemLink(source: .init(.note, noteID), target: .init(.task, id), kind: .card))
        try context.save()
        XCTAssertTrue(try legacyDeleteTask(id))
        let result = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(result.removedTaskIDs.contains(id), "\(result)")
        let links = try ModelContext(container).fetch(FetchDescriptor<ItemLink>())
        XCTAssertEqual(links.count, 3, "redirect external links and drop only the self-link")
        XCTAssertEqual(links.filter { $0.id == linkID && $0.target == .init(.note, noteID) && $0.kind == .card && $0.createdAt == Date(timeIntervalSince1970: 1) }.count, 2)
        XCTAssertEqual(links.first { $0.id == reverse.id }?.source, .init(.note, noteID))
        XCTAssertEqual(links.first { $0.id == reverse.id }?.deletedAt, reverse.deletedAt)
        XCTAssertTrue(try associations(note: noteID).contains { $0.taskID == id && $0.detachedAt != nil })
        XCTAssertFalse(try storedDocument(noteID).requires.contains("taskNote"))
    }

    func testBOrdinaryRedirectNotePurgeCollectsCircleAndLinksTogether() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let context = WorkspaceLegacyBridge.context(for: container)
        context.insert(ItemLink(source: .init(.note, UUID()), target: .init(.task, id), kind: .reference)); try context.save()
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID)); await close(presenter); presenter.page.history.clear()
        XCTAssertTrue(notes.store.delete(try XCTUnwrap(notes.store.note(withID: session.noteID))))
        XCTAssertFalse(notes.store.purgeDeleted(before: .distantFuture).contains(session.noteID), "redirect note waits for the combined commit")
        let result = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(result.removedTaskIDs.contains(id), "\(result)")
        XCTAssertTrue(try rows(session.noteID).isEmpty)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<ItemLink>()).isEmpty)
        XCTAssertTrue(try associations(note: session.noteID).isEmpty)
    }

    func testBMaterializerReadsCapturesFromBeforeDeletionGroupField() throws {
        let id = try seed(.boundary), context = ModelContext(container)
        let family = try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.id == id || $0.parentID == id }
        let snapshot = try WorkspacePurge.Preservation(rootID: id, title: "Parent", members: family.map {
            var fields = try WorkspaceModelFields.read($0); fields.removeValue(forKey: "deletionGroupID")
            return .init(id: $0.id, fields: fields)
        }, originals: [])
        let value = try WorkspaceTaskNoteMaterializer.materialize(try storedDocument(try XCTUnwrap(ownNotes(id).first?.id)), taskID: id, preservation: snapshot)
        XCTAssertEqual(value.document.blocks.filter { $0.kind == .checklist }.count, family.count - 1)
    }

    func testBSettingsEmptyOrdinaryRedirectNoteDispatchesAndInvalidatesPurgedWriting() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let noteID = session.noteID
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: noteID)); await close(presenter); presenter.page.history.clear()
        library = AtticLibrary(tasks: tasks, notes: notes.store, undo: library.undo)
        XCTAssertTrue(notes.store.delete(try XCTUnwrap(notes.store.note(withID: noteID))))
        library.undo.perform(in: .note(noteID)) {
            UndoStep(name: "Writing", items: { [.init(.note, noteID)] }, undo: { true }, redo: { true })
        }
        let dispatched = expectation(description: "note-only Settings selection reaches coordinated purge")
        library.taskNotePurge = { [self] cutoff, confirmed, confirmedNotes in
            let report = await TaskNotePurge.run(tasks: tasks, notes: notes, before: cutoff, confirmed: confirmed, confirmedNotes: confirmedNotes)
            dispatched.fulfill(); return report.removedTaskIDs
        }
        let model = RecentlyDeletedModel(library: library)
        model.reload(); XCTAssertEqual(model.entries.count, 1)
        model.requestEmpty(); model.confirmEmpty()
        await fulfillment(of: [dispatched], timeout: 2)
        XCTAssertTrue(try rows(noteID).isEmpty)
        XCTAssertFalse(library.undo.canUndo(in: .note(noteID)))
    }

    func testBCommittedRemoveStillShowsUndoWhenCloseRefuses() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let uiState = PanelUIState(), toasts = PanelToastCenter()
        uiState.openTaskNote(id, from: .tasks, backTitle: "Back")
        notes.taskNotePresenter = presenter
        coordinator.save = { context in
            let removing = context.changedModelsArray.contains { ($0 as? NoteItem)?.id == session.noteID && ($0 as? NoteItem)?.taskID == nil }
            try context.save()
            if removing { presenter.model.newSubtaskText = "Late child draft" }
        }
        defer { coordinator.save = { try $0.save() }; presenter.model.newSubtaskText = "" }
        await AtticPanelView.removeFromTasks(id, pages: notes, tasks: tasks, uiState: uiState, toasts: toasts)
        XCTAssertNil(tasks.task(withID: id), "conversion committed")
        XCTAssertNotNil(presenter.lease, "the busy close must refuse")
        XCTAssertEqual(toasts.current?.message, "Removed from Tasks")
        XCTAssertEqual(toasts.current?.actionTitle, "Undo")
        presenter.model.newSubtaskText = ""
        coordinator.save = { try $0.save() }
        await notes.waitForRecoveryWork()
        _ = await presenter.page.history.retryPublication(using: coordinator)
    }

    func testBCommandTableNamesAndHidesBothCommandsForSubtasksAndBareTasks() {
        func names(_ id: UUID?, writing: Bool, child: Bool) -> [String] {
            TaskNoteConversion.commands(taskID: id, hasWriting: writing, isSubtask: child, add: {}, remove: {}).map(\.title)
        }
        XCTAssertEqual(names(nil, writing: true, child: false), ["Add to Tasks"])
        XCTAssertEqual(names(UUID(), writing: true, child: false), ["Remove from Tasks"])
        XCTAssertEqual(names(UUID(), writing: false, child: false), [])
        XCTAssertEqual(names(UUID(), writing: true, child: true), [])
        XCTAssertEqual(names(nil, writing: true, child: true), [])
    }

    func testBBlankTitleAddFocusesTitleOnFirstMount() async throws {
        makeStores(); let id = UUID()
        _ = try notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text(""), .text("Writing")])).get()
        XCTAssertTrue(notes.open(noteID: id))
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        let presenter = try open(taskID); presenter.restoreViewStateOnMount()
        XCTAssertEqual(presenter.model.focusRequest, .title)
    }

    func testBWritingVersionRestoreAfterRemovalNeverReactivatesTaskOrDuplicatesChildren() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(notes.store.recordVersion(noteID: session.noteID, reason: .pause))
        let version = try XCTUnwrap(notes.store.versions(noteID: session.noteID).first)
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        await close(presenter)
        _ = try notes.store.restoreVersion(version.id, noteID: session.noteID).get()
        let document = try storedDocument(session.noteID)
        XCTAssertFalse(document.requires.contains("taskNote")); XCTAssertNil(notes.store.note(withID: session.noteID)?.taskID)
        XCTAssertNil(tasks.task(withID: id))
        XCTAssertFalse(document.blocks.contains { $0.text == "Write release notes" }, "restoring writing never rematerializes the task's children")
    }

    func testBRemoveChildRestoreAliasCannotReturnTheRetiredFamily() async throws {
        let id = try seed(.boundary), child = try XCTUnwrap(tasks.subtasks(of: id).first?.id)
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        await close(presenter)
        XCTAssertFalse(tasks.restoreDeleted(taskID: child))
        XCTAssertNil(tasks.task(withID: id)); XCTAssertNil(tasks.task(withID: child))
    }

    func testBRemoveUsesHeldPageOrderInsteadOfResortingChildren() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let done = try XCTUnwrap(tasks.subtasks(of: id).first { $0.status == .done }?.id)
        presenter.model.setPointerInside(true)
        let owner = WorkspaceOwner(entity: .task, id: done)
        let envelope = try coordinator.newEnvelope(intent: "Fixture reorder", reads: coordinator.capture([owner]), writes: [owner])
        let reordered = await coordinator.execute(envelope, stage: { commit in
            for row in try commit.fetch(FetchDescriptor<TaskItem>()) where row.id == done {
                row.status = .todo; row.completedAt = nil; row.manualOrder = 2_000_000
            }
        })
        XCTAssertEqual(reordered, .committed)
        tasks.refresh(); presenter.model.refresh()
        let shown = presenter.model.rows.map(\.title)
        XCTAssertNotEqual(tasks.subtasks(of: id).map(\.title), shown, "fixture must hold a different order")
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        XCTAssertEqual(Array(try storedDocument(session.noteID).blocks.dropFirst().prefix(shown.count).map(\.text)), shown)
    }

    func testBAddAfterRetiredFamilyPurgeKeepsFreshTaskWritable() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(result, .removed(noteID: session.noteID)); await close(presenter)
        presenter.page.history.clear()
        let purged = await TaskNotePurge.run(tasks: tasks, notes: notes, before: .distantFuture)
        XCTAssertTrue(purged.removedTaskIDs.contains(id), "\(purged)")
        XCTAssertTrue(notes.open(noteID: session.noteID))
        let added = await TaskNoteConversion.makeTask(fromNote: session.noteID, notes: notes, tasks: tasks)
        guard case let .made(freshID) = added else { return XCTFail("fresh task after purge: \(added)") }
        XCTAssertNotEqual(freshID, id)
        let removedFresh = await TaskNoteConversion.removeTask(freshID, notes: notes, tasks: tasks)
        XCTAssertEqual(removedFresh, .removed(noteID: session.noteID))
        let freshHistory = notes.undoRoute.workspace(for: .taskWorkspace(freshID))
        let undoneFresh = await freshHistory.replay(redo: false); XCTAssertEqual(undoneFresh, .applied)
        XCTAssertEqual(notes.store.note(withID: session.noteID)?.taskID, freshID)
        var changed = try storedDocument(session.noteID); changed.blocks.append(.text("Fresh task writing"))
        _ = try notes.store.saveDocument(noteID: session.noteID, document: changed,
            baseRevisionID: notes.store.note(withID: session.noteID)?.revisionID).get()
        XCTAssertEqual(try storedDocument(session.noteID), changed)
    }

    // C2 replaces B's temporary close-and-handoff with an in-place projection.
    func testC2WindowConversionKeepsWindowLeaseAndHistoryInPlace() async throws {
        let id = try seed(.boundary); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let ui = PanelUIState(), beforeActive = notes.active
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store,
            design: .default, uiState: ui)
        let window = try XCTUnwrap(TaskNoteWindows.shared.window(for: id)), frame = window.frame
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        let lease = presenter.lease, history = presenter.page.history
        let before = try storedDocument(session.noteID)
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        await AtticPanelView.removeFromTasks(id, pages: notes, tasks: tasks, uiState: ui, toasts: nil)
        coordinator.save = { try $0.save() }
        XCTAssertTrue(TaskNoteWindows.shared.window(for: id) === window)
        XCTAssertEqual(presenter.lease, lease)
        XCTAssertEqual(try storedDocument(session.noteID), before)
        await AtticPanelView.removeFromTasks(id, pages: notes, tasks: tasks, uiState: ui, toasts: nil)
        XCTAssertTrue(TaskNoteWindows.shared.window(for: id) === window)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(presenter.lease, lease)
        XCTAssertTrue(session.usesWorkspaceBinding)
        XCTAssertFalse(session.engine.isBodyOnly)
        XCTAssertTrue(notes.active === beforeActive)
        XCTAssertTrue(session.engine.history.workspace === history)
        let undone = await history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertTrue(TaskNoteWindows.shared.window(for: id) === window)
        XCTAssertEqual(presenter.lease, lease)
        XCTAssertTrue(session.engine.isBodyOnly)
        let redone = await history.replay(redo: true)
        XCTAssertEqual(redone, .applied)
        guard case let .made(newTask) = await TaskNoteConversion.makeTask(fromNote: session.noteID, notes: notes, tasks: tasks, workspaceSession: session) else { return XCTFail("Add must use the window's leased ordinary session") }
        XCTAssertNotEqual(newTask, id)
        XCTAssertTrue(TaskNoteWindows.shared.window(for: newTask) === window)
        XCTAssertTrue(session.engine.history.workspace === history)
        XCTAssertEqual(presenter.lease, lease)
        XCTAssertEqual(presenter.taskID, newTask)
        XCTAssertTrue(session.engine.isBodyOnly)
        XCTAssertFalse(notes.open(noteID: session.noteID), "the panel cannot steal the window's editor")
        let resolved = try coordinator.sessions.session(for: .task(newTask), notes: notes)
        XCTAssertTrue(resolved === presenter.page)
    }

    func testC2RetainedRetirementKeepsQueuedAndNewerWriting() async throws {
        let id = try seed(.boundary); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store, design: .default, uiState: PanelUIState())
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        coordinator.afterPreparation = { presenter.host.textView.insertText(" queued", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let outcome = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        coordinator.afterPreparation = nil
        XCTAssertEqual(outcome, .removed(noteID: session.noteID))
        XCTAssertTrue(session.engine.textStorage.string.contains(" queued"))
        presenter.host.textView.insertText(" newest draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let expected = session.engine.document()
        await notes.retireConvertedNote(session.noteID)
        XCTAssertEqual(session.engine.document(), expected, "agent/Undo retirement cannot reload over released queued typing")
        XCTAssertTrue(session.engine.textStorage.string.contains(" queued"))
        XCTAssertTrue(session.engine.textStorage.string.contains(" newest draft"))
    }

    func testC2UndoResumesTaskObservationsAndOrdinaryAppearanceKeepsItsRegions() async throws {
        let id = try seed(.boundary); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        notes.makeTaskFromNote = { _ in }
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store, design: .default, uiState: PanelUIState())
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        let outcome = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(outcome, .removed(noteID: session.noteID))
        presenter.host.restack()
        let ordinaryTop = presenter.host.textView.frame.minY
        var dark = AtticDesignContext.default; dark.mode = .dark
        presenter.update(design: dark); presenter.host.restack()
        XCTAssertEqual(presenter.host.textView.frame.minY, ordinaryTop, "appearance preserves the ordinary Add/title projection")
        let undone = await presenter.page.history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        let updated = expectation(description: "the resumed model observes the live head")
        let subscription = presenter.model.$head.dropFirst().filter { $0.title == "C2 observed rename" }.prefix(1).sink { _ in updated.fulfill() }
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "C2 observed rename"))
        await fulfillment(of: [updated], timeout: 1)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(presenter.model.head.title, "C2 observed rename")
        XCTAssertEqual(session.engine.document().title, "C2 observed rename")
    }

    func testC2OrdinaryMoveToPanelLeavesTheLibraryAndKeepsHistory() async throws {
        let id = try seed(.boundary); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session), ui = PanelUIState()
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store, design: .default, uiState: ui)
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        let history = presenter.page.history
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        notes.showLibrary()
        XCTAssertTrue(notes.isLibraryPresented)
        let moved = await TaskNoteWindows.shared.moveToPanel(taskID: id)
        XCTAssertTrue(moved)
        XCTAssertNil(presenter.lease)
        XCTAssertNil(TaskNoteWindows.shared.window(for: id))
        XCTAssertEqual(notes.active?.noteID, session.noteID)
        XCTAssertFalse(notes.isLibraryPresented)
        XCTAssertTrue(notes.active?.engine.history.workspace === history)
    }

    func testC2RefusedOrdinaryMoveToPanelKeepsTheSourceWindowAndBusyDestination() async throws {
        let id = try seed(.boundary); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session), ui = PanelUIState()
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store, design: .default, uiState: ui)
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        let other = UUID()
        _ = try notes.store.createDocumentNote(id: other, document: NoteDocument(blocks: [.text("Other"), .text("Busy writing")])).get()
        XCTAssertTrue(notes.open(noteID: other))
        let destination = try XCTUnwrap(notes.active), view = destination.engine.makeView().1
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        defer { view.unmarkText() }
        let window = TaskNoteWindows.shared.window(for: id), lease = presenter.lease
        let moved = await TaskNoteWindows.shared.moveToPanel(taskID: id)
        XCTAssertFalse(moved)
        XCTAssertTrue(TaskNoteWindows.shared.window(for: id) === window)
        XCTAssertEqual(presenter.lease, lease)
        XCTAssertTrue(notes.active === destination)
    }

    func testC2LateTaskFieldDraftIsNeverHiddenOrDiscardedByConversion() async throws {
        let id = try seed(.boundary); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store, design: .default, uiState: PanelUIState())
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        coordinator.save = { context in
            let converting = context.changedModelsArray.contains { ($0 as? NoteItem)?.id == session.noteID && ($0 as? NoteItem)?.taskID == nil }
            try context.save()
            if converting { presenter.model.newSubtaskText = "Late native field draft" }
        }
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        coordinator.save = { try $0.save() }
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        XCTAssertEqual(presenter.model.newSubtaskText, "Late native field draft")
        XCTAssertFalse(presenter.isOrdinary, "a field draft must stay visible until explicitly resolved")
        XCTAssertTrue(presenter.model.showsAddRow, "retirement cannot hide the native draft before publication")
        XCTAssertTrue(presenter.page.history.hasPendingPublication)
        let added = await TaskNoteConversion.makeTask(fromNote: session.noteID, notes: notes, tasks: tasks, workspaceSession: session)
        guard case .refused = added else { return XCTFail("Add must not discard a prior field draft") }
        XCTAssertEqual(presenter.model.newSubtaskText, "Late native field draft")
        presenter.model.newSubtaskText = ""
        _ = await presenter.page.history.retryPublication(using: coordinator)
        XCTAssertTrue(presenter.isOrdinary)
    }

    func testC2NativeFieldRefusesBeforeChangingItsTextOrDraftHistory() throws {
        var edited = false
        let actions = AtticTokenFieldActions(submit: { _ in }, dismissChip: { _ in }, multilinePaste: { _ in false },
            escape: { true }, edited: { _, _ in edited = true }, caretMoved: { _ in }, admitEdit: { false })
        let field = AtticTokenField(text: .constant("kept"), chips: [], isFocused: .constant(false), accessibilityLabel: "Title", actions: actions)
        let delegate = field.makeCoordinator(), text = NSTextView()
        text.string = "kept"
        XCTAssertFalse(delegate.textView(text, shouldChangeTextIn: NSRange(location: 4, length: 0), replacementString: " refused"))
        XCTAssertFalse(edited)
        XCTAssertEqual(text.string, "kept")
        let add = AtticSubtaskFieldEditor()
        var editing = AtticTitleEditing(text: .constant("kept"), commit: { false }, cancel: {})
        editing.admitEdit = { false }
        add.editing = editing; add.string = "kept"
        XCTAssertFalse(add.shouldChangeText(in: NSRange(location: 4, length: 0), replacementString: " refused"))
        add.insertText(" refused", replacementRange: NSRange(location: 4, length: 0))
        XCTAssertEqual(add.string, "kept", "the Add field refuses before its native text changes too")
    }

    func testC2AddFieldEndEditingDoesNotClearTheNewTabDestination() throws {
        let id = try seed(.boundary), presenter = try open(id)
        var destination: TaskNotePageModel.Region? = .add
        let binding = Binding(get: { destination == .add }, set: { destination = $0 ? .add : nil })
        let field = TaskNoteAddField(model: presenter.model, focused: binding, color: .labelColor, submit: {}, tab: { _ in })
        let delegate = field.makeCoordinator()
        for next: TaskNotePageModel.Region in [.more, .list, .title, .writing] {
            destination = next
            delegate.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
            XCTAssertEqual(destination, next)
        }
    }

    func testC2LateFieldKeepsWritingReservedUntilCancellationThenReplaysOnNewProjection() async throws {
        let id = try seed(.boundary); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store, design: .default, uiState: PanelUIState())
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        let lease = presenter.lease, history = presenter.page.history
        coordinator.save = { context in
            let converting = context.changedModelsArray.contains { ($0 as? NoteItem)?.id == session.noteID && ($0 as? NoteItem)?.taskID == nil }
            try context.save()
            if converting { presenter.model.newSubtaskText = "Keep this field" }
        }
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        coordinator.save = { try $0.save() }
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(history.permitsUnsavedDraft, "native drafts retain the reservation until explicitly cancelled")
        XCTAssertTrue(history.isInputReserved)
        let writing = session.engine.textStorage.string
        presenter.host.textView.setSelectedRange(NSRange(location: writing.utf16.count, length: 0))
        presenter.host.textView.insertText(" fallback writing", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(history.hasQueuedTyping)
        XCTAssertEqual(session.engine.textStorage.string, writing)
        let refused = await history.retryPublication(using: coordinator)
        XCTAssertFalse(refused)
        XCTAssertEqual(presenter.model.newSubtaskText, "Keep this field")
        presenter.model.newSubtaskText = ""
        let retried = await history.retryPublication(using: coordinator)
        XCTAssertTrue(retried)
        XCTAssertFalse(history.hasPendingPublication)
        XCTAssertTrue(presenter.isOrdinary)
        XCTAssertFalse(session.engine.isBodyOnly)
        XCTAssertEqual(presenter.lease, lease)
        XCTAssertEqual(presenter.page.key.workspace, .note(session.noteID))
        XCTAssertTrue(session.engine.textStorage.string.hasSuffix(writing + " fallback writing"))
        XCTAssertFalse(history.hasQueuedTyping)
        XCTAssertFalse(try storedDocument(session.noteID).blocks.contains { $0.text.contains("fallback writing") })
        let undone = await history.replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertTrue(session.engine.textStorage.string.hasSuffix(writing))
        XCTAssertFalse(session.engine.textStorage.string.contains("fallback writing"))
    }

    func testC2MoveFilesFirstKeepsTheExistingWindowOnRefusalAndSuccess() async throws {
        let id = try seed(.boundary)
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("AtticC2-\(UUID()).txt")
        try Data("C2 legacy bytes".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let references = try await tasks.taskImageFiles.importAttachments([input], existing: [])
        let context = ModelContext(container)
        for row in try context.fetch(FetchDescriptor<TaskItem>()) where row.id == id {
            row.imageReferencesData = try JSONEncoder().encode(references)
        }
        try context.save(); tasks.refresh(); await notes.startAndWait()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session), ui = PanelUIState()
        TaskNoteWindows.shared.open(taskID: id, tasks: tasks, controller: notes, noteStore: notes.store, design: .default, uiState: ui)
        defer { TaskNoteWindows.shared.finishHandoff(id) }
        let window = try XCTUnwrap(TaskNoteWindows.shared.window(for: id)), frame = window.frame
        let history = presenter.page.history
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        await AtticPanelView.removeFromTasks(id, pages: notes, tasks: tasks, uiState: ui, toasts: nil, moveFilesFirst: true)
        coordinator.save = { try $0.save() }
        XCTAssertTrue(TaskNoteWindows.shared.window(for: id) === window, "migration refusal retains the original host")
        XCTAssertNotNil(tasks.task(withID: id))
        let originalChanged = tasks.fileMigration.onNotesChanged
        var blocker: (WorkspacePageSession, WorkspacePageSession.Lease)?
        tasks.fileMigration.onNotesChanged = { [self] in
            originalChanged?()
            guard blocker == nil, let page = try? coordinator.sessions.session(for: .task(id), notes: notes),
                  let lease = try? page.acquire(surfaceID: UUID()) else { return }
            blocker = (page, lease)
        }
        await AtticPanelView.removeFromTasks(id, pages: notes, tasks: tasks, uiState: ui, toasts: nil, moveFilesFirst: true)
        tasks.fileMigration.onNotesChanged = originalChanged
        XCTAssertTrue(TaskNoteWindows.shared.window(for: id) === window, "a refused remount keeps its Retry surface")
        XCTAssertNotNil(tasks.task(withID: id), "conversion must wait for the window to remount")
        XCTAssertEqual(try storedDocument(session.noteID).attachmentIDs, references.map(\.id), "migration remains durable after remount refuses")
        if let blocker { _ = await blocker.0.close(blocker.1) }
        await AtticPanelView.removeFromTasks(id, pages: notes, tasks: tasks, uiState: ui, toasts: nil, moveFilesFirst: true)
        XCTAssertTrue(TaskNoteWindows.shared.window(for: id) === window)
        XCTAssertEqual(window.frame, frame)
        XCTAssertNil(tasks.task(withID: id))
        let retained = try XCTUnwrap(TaskNoteWindows.shared.session(noteID: session.noteID, controller: notes))
        XCTAssertTrue(retained.engine.history.workspace === history)
        XCTAssertFalse(retained.engine.isBodyOnly)
        XCTAssertEqual(try storedDocument(session.noteID).attachmentIDs, references.map(\.id))
    }

    func testBAddPreservesLiteralTitleAndFailureRollsBack() async throws {
        makeStores(); let id = UUID(), title = "Plan  tomorrow !high #literal"
        let original = NoteDocument(blocks: [.text(title), .text("Writing")])
        _ = try notes.store.createDocumentNote(id: id, document: original).get(); XCTAssertTrue(notes.open(noteID: id))
        let count = tasks.tasks.count
        coordinator.save = { _ in throw WorkspaceFoundationError.unknown }
        let failed = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks)
        coordinator.save = { try $0.save() }
        guard case .refused = failed else { return XCTFail() }
        XCTAssertEqual(try storedDocument(id), original); XCTAssertEqual(tasks.tasks.count, count)
        let result = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks)
        guard case let .made(taskID) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(tasks.task(withID: taskID)?.title, title)
        XCTAssertNil(tasks.task(withID: taskID)?.dueDay); XCTAssertEqual(tasks.task(withID: taskID)?.priority, TaskPriority.none)
    }

    func testBRemoveRefusesChildReplicaWithForeignParentAndPreservesBoth() async throws {
        let id = try seed(.boundary), child = try XCTUnwrap(tasks.subtasks(of: id).first)
        let context = ModelContext(container), other = TaskItem(title: "Other parent")
        context.insert(other)
        let replica = TaskItem(title: ""); try WorkspaceModelFields.apply(WorkspaceModelFields.read(child), to: replica)
        replica.parentID = other.id; context.insert(replica); try context.save()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session), before = try storedDocument(session.noteID)
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        guard case .refused = result else { return XCTFail("foreign child replica must refuse") }
        XCTAssertEqual(try storedDocument(session.noteID), before)
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.deletedAt == nil })
    }

    func testBRemovePreservesSelectionWithTheWritingAcrossProjection() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let text = session.engine.textStorage.string, before = NSRange(location: 4, length: 7)
        presenter.host.textView.setSelectedRange(before)
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(result, .removed(noteID: session.noteID))
        let shift = session.engine.textStorage.length - (text as NSString).length
        XCTAssertEqual(presenter.host.textView.selectedRange(), NSRange(location: before.location + shift, length: before.length))
    }

    func testBRemoveUnknownSavePublishesAndKeepsQueuedTyping() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let history = presenter.page.history
        coordinator.save = { context in try context.save(); throw WorkspaceFoundationError.unknown }
        coordinator.beforeReconciliationRead = { throw WorkspaceFoundationError.unknown }
        _ = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertTrue(history.hasPendingPublication)
        presenter.host.textView.insertText(" queued", replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.save = { try $0.save() }; coordinator.beforeReconciliationRead = nil
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(history.hasPendingPublication)
        XCTAssertNil(tasks.task(withID: id))
        XCTAssertFalse(try storedDocument(session.noteID).requires.contains("taskNote"))
        XCTAssertTrue(history.hasQueuedTyping || session.engine.textStorage.string.contains(" queued"))
    }

    func testBAddRefusesAnOrdinaryNoteStillClaimedByAnActiveAssociation() async throws {
        makeStores(); let id = UUID()
        _ = try notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Ordinary"), .text("Writing")])).get()
        let context = ModelContext(container), owner = TaskItem(title: "Existing owner")
        context.insert(owner); context.insert(TaskNoteAssociation(taskID: owner.id, noteID: id)); try context.save()
        tasks.refresh(); XCTAssertTrue(notes.open(noteID: id))
        let before = try storedDocument(id)
        let result = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks)
        guard case .refused = result else { return XCTFail("active ownership must be resolved first") }
        XCTAssertNil(notes.store.note(withID: id)?.taskID); XCTAssertEqual(try storedDocument(id), before)
    }

    func testBRemoveRefusesAssociationReplicaOwnedByAnotherTask() async throws {
        let id = try seed(.boundary), noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let association = try XCTUnwrap(try associations(note: noteID).first)
        let context = ModelContext(container), other = TaskItem(title: "Foreign owner")
        context.insert(other)
        let foreign = NoteItem(title: "Foreign note", body: "Keep this writing"); foreign.taskID = other.id
        context.insert(foreign)
        let copy = TaskNoteAssociation(id: association.id, taskID: other.id, noteID: foreign.id)
        context.insert(copy); try context.save()
        let presenter = try open(id), session = try XCTUnwrap(presenter.session)
        let result = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        guard case .refused = result else { return XCTFail("association UUID must mutate as a complete family") }
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskNoteAssociation>()).filter { $0.id == association.id }.allSatisfy { $0.detachedAt == nil })
        XCTAssertNotNil(tasks.task(withID: id))
    }

    func testBAddRemoveHistoryUnwindsAndReplaysInBothDirections() async throws {
        makeStores(); let id = UUID(), original = NoteDocument(blocks: [.text("History"), .text("Writing")])
        _ = try notes.store.createDocumentNote(id: id, document: original).get(); XCTAssertTrue(notes.open(noteID: id))
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        let history = notes.undoRoute.workspace(for: .taskWorkspace(taskID))
        let removed = await TaskNoteConversion.removeTask(taskID, notes: notes, tasks: tasks)
        XCTAssertEqual(removed, .removed(noteID: id))
        for _ in 0..<2 { let undo = await history.replay(redo: false); XCTAssertEqual(undo, .applied) }
        XCTAssertEqual(try storedDocument(id), original)
        for _ in 0..<2 { let redo = await history.replay(redo: true); XCTAssertEqual(redo, .applied) }
        XCTAssertNil(tasks.task(withID: taskID)); XCTAssertNil(notes.store.note(withID: id)?.taskID)
    }

    func testBRemoveSettlesThePagesTitleDraftBeforeCopyingTheTitle() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        presenter.model.beginEditingTitle()
        presenter.model.titleEdit = TaskAddBarText(text: "The edited title")
        let removed = await TaskNoteConversion.removeTask(id, notes: notes, tasks: tasks, workspaceSession: session)
        XCTAssertEqual(removed, .removed(noteID: session.noteID))
        XCTAssertEqual(try storedDocument(session.noteID).title, "The edited title")
        presenter.model.cancelTitle()
    }

    // MARK: Make Task from Note (§ 2.1)

    func testMakeTaskFromNoteMakesTheSameDocumentTheTasksOwnNoteAndUndoReturnsItAsItWas() async throws {
        makeStores()
        let noteID = UUID()
        let original = NoteDocument(blocks: [.text("Plan the offsite"), .text("Venue ideas"), .checklist("Ask Sam", checked: true)])
        guard case .success = notes.store.createDocumentNote(id: noteID, document: original, tags: ["team"]) else { return XCTFail() }
        XCTAssertTrue(notes.open(noteID: noteID))
        let outcome = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: tasks)
        guard case let .made(taskID) = outcome else { return XCTFail("\(outcome)") }
        let task = try XCTUnwrap(tasks.task(withID: taskID))
        XCTAssertEqual(task.title, "Plan the offsite")
        XCTAssertEqual(task.tags, ["team"], "the task takes the note's title and tags")
        // Engineering rule, one-item-plan Titles and tags: hidden legacy tags remain recoverable.
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == taskID && $0.tags == ["team"] }, "same identity and recoverable note tags; live tags belong to TaskItem")
        let stored = try storedDocument(noteID)
        XCTAssertTrue(stored.requires.contains("taskNote"))
        XCTAssertEqual(stored.blocks.dropFirst().map(\.kind), [.text, .checklist], "body checkboxes stay note checkboxes")
        XCTAssertEqual(try associations(note: noteID).filter { $0.detachedAt == nil }.map(\.taskID), [taskID])
        let presenter = try open(taskID)
        XCTAssertEqual(presenter.session?.noteID, noteID, "the same document is the task's page")
        await close(presenter)
        let undone = await notes.undoRoute.replay(in: .taskWorkspace(taskID), redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertNil(tasks.task(withID: taskID), "Undo: the task goes to Recently Deleted")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == nil && $0.tags == ["team"] })
        XCTAssertEqual(try storedDocument(noteID), original, "the note returns exactly as it was")
        let redone = await notes.undoRoute.replay(in: .taskWorkspace(taskID), redo: true)
        XCTAssertEqual(redone, .applied)
        XCTAssertNotNil(tasks.task(withID: taskID), "Redo brings the same task back")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == taskID })
    }

    func testAddToTasksRefusesATasksNoteAndAcceptsAnUntitledNote() async throws {
        let id = try seed(.boundary)
        let own = try XCTUnwrap(try ownNotes(id).first?.id)
        let refused = await TaskNoteConversion.makeTask(fromNote: own, notes: notes, tasks: tasks)
        XCTAssertNotEqual(refused, .made(taskID: id), "a task's note never becomes a second task")
        XCTAssertTrue(try rows(own).allSatisfy { $0.taskID == id })
        let untitled = UUID()
        guard case .success = notes.store.createDocumentNote(id: untitled, document: NoteDocument(blocks: [.text(""), .text("body")])) else { return XCTFail() }
        XCTAssertTrue(notes.open(noteID: untitled))
        let outcome = await TaskNoteConversion.makeTask(fromNote: untitled, notes: notes, tasks: tasks)
        // Orchestrator decision 2026-10-23: a blank title commits immediately.
        guard case let .made(taskID) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(try rows(untitled).allSatisfy { $0.taskID == taskID })
        XCTAssertEqual(tasks.task(withID: taskID)?.title, "")
    }

    // Engineering contract: C2 surface parity, one-item-plan Surface table.
    func testC2SearchGroupsAlternateWritingButKeepsReferencingNotesSeparate() async throws {
        let ids = try TaskNoteLifecyclePreviewSeed.seed(in: container)
        makeStores()
        let taskID = try XCTUnwrap(ids[.alternateNote])
        let own = try ownNotes(taskID).sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        XCTAssertEqual(own.count, 2)
        let canonical = try XCTUnwrap(own.first?.id)
        let reference = UUID()
        _ = try notes.store.createDocumentNote(id: reference, document: NoteDocument(blocks: [.text("Venue shortlist reference"), .text("Venue shortlist")])).get()
        let links = ModelContext(container)
        links.insert(ItemLink(source: AtticItemRef(.note, reference), target: AtticItemRef(.task, taskID), kind: .reference))
        try links.save()
        let model = NotesLibraryModel(search: { [notes] in try await notes!.store.searchNoteIDs(matching: $0) }, store: notes.store, taskStore: tasks)
        XCTAssertEqual(model.groups(store: notes.store, drafts: []).flatMap(\.rows).filter { own.map(\.id).contains($0.id) }.map(\.id), [canonical])
        for query in ["Venue shortlist", "library hall"] {
            let matches = try await notes.store.searchNoteIDs(matching: query)
            XCTAssertTrue(matches.contains(canonical), query)
            XCTAssertFalse(matches.contains(own[1].id), "alternate writing is Review on the same result")
            if query == "Venue shortlist" { XCTAssertTrue(matches.contains(reference)) }
        }
    }

    func testC2SearchIncludesCompletedSubtasksAndLegacyFilenames() async throws {
        let ids = try TaskNoteLifecyclePreviewSeed.seed(in: container)
        makeStores()
        let taskID = try XCTUnwrap(ids[.doneToday])
        let noteID = try XCTUnwrap(try ownNotes(taskID).first?.id)
        let child = try XCTUnwrap(tasks.subtasks(of: taskID).first)
        let childMatch = try await notes.store.searchNoteIDs(matching: child.title)
        XCTAssertEqual(childMatch, [noteID])
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<TaskItem>()).first { $0.id == taskID })
        row.imageReferencesData = try JSONEncoder().encode([TaskImageReference(id: UUID(), filename: "C2-evidence.pdf", digest: "digest", contentTypeIdentifier: "com.adobe.pdf", byteCount: 7)])
        try context.save()
        let fileMatch = try await notes.store.searchNoteIDs(matching: "C2-evidence")
        XCTAssertEqual(fileMatch, [noteID])
        let logged = try XCTUnwrap(ids[.doneLogged]), loggedNote = try XCTUnwrap(try ownNotes(logged).first?.id)
        let loggedMatch = try await notes.store.searchNoteIDs(matching: "Order the banner")
        XCTAssertEqual(loggedMatch, [loggedNote])
    }

    func testC2AlternateSearchAndLibraryUseTheRegistrysReplicaCreationOrder() async throws {
        let ids = try TaskNoteLifecyclePreviewSeed.seed(in: container)
        makeStores()
        let taskID = try XCTUnwrap(ids[.alternateNote]), context = ModelContext(container)
        let own = try ownNotes(taskID).sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let oldest = try XCTUnwrap(own.first), alternate = own[1]
        let replica = NoteItem(title: "")
        try WorkspaceModelFields.apply(WorkspaceModelFields.read(oldest), to: replica)
        replica.createdAt = alternate.createdAt.addingTimeInterval(60)
        replica.updatedAt = oldest.updatedAt.addingTimeInterval(60)
        context.insert(replica); try context.save(); notes.store.refresh()
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, taskStore: tasks)
        XCTAssertEqual(model.groups(store: notes.store, drafts: []).flatMap(\.rows).filter { [oldest.id, alternate.id].contains($0.id) }.map(\.id), [oldest.id])
        let matches = try await notes.store.searchNoteIDs(matching: "library hall")
        XCTAssertEqual(matches, [oldest.id])
        XCTAssertEqual(try coordinator.sessions.resolve(.task(taskID)).1, oldest.id)
    }

    func testC2AddKeepsLegacyNoteTagsRecoverableWhileTaskTagsAreEffective() async throws {
        makeStores(); await notes.startAndWait()
        let id = UUID(), document = NoteDocument(blocks: [.text("Tags"), .text("Writing")])
        _ = try notes.store.createDocumentNote(id: id, document: document, tags: ["legacy"]).get()
        XCTAssertTrue(notes.open(noteID: id))
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        XCTAssertEqual(notes.store.note(withID: id)?.tags, ["legacy"], "hidden compatibility tags remain recoverable after restart")
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: taskID)), title: "Live title", tags: ["effective"]))
        let model = NotesLibraryModel(search: { _ in [] }, store: notes.store, taskStore: tasks)
        XCTAssertEqual(model.recentTags(store: notes.store), ["effective"])
        model.tagFilter = "legacy"
        XCTAssertTrue(model.groups(store: notes.store, drafts: []).isEmpty)
        model.tagFilter = "effective"
        XCTAssertEqual(model.groups(store: notes.store, drafts: []).flatMap(\.rows).map(\.id), [id])
        XCTAssertEqual(try storedDocument(id).title, "Tags", "rename does not rewrite compatibility bytes")
        XCTAssertEqual(library.title(of: AtticItemRef(.note, id)), "Live title", "references through the writing alias resolve the live item title")
    }

    func testC2AddAndItsUndoKeepTheExactLegacyNoteTagSnapshot() async throws {
        makeStores(); let id = UUID(), raw = "legacy  team "
        _ = try notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Tags"), .text("Writing")])).get()
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
        row.tagsRaw = raw; try context.save(); notes.store.refresh()
        XCTAssertTrue(notes.open(noteID: id))
        guard case let .made(taskID) = await TaskNoteConversion.makeTask(fromNote: id, notes: notes, tasks: tasks) else { return XCTFail() }
        XCTAssertEqual(notes.store.note(withID: id)?.tagsRaw, raw)
        XCTAssertEqual(tasks.task(withID: taskID)?.tags, ["legacy", "team"])
        let undone = await notes.undoRoute.workspace(for: .taskWorkspace(taskID)).replay(redo: false)
        XCTAssertEqual(undone, .applied)
        XCTAssertEqual(notes.store.note(withID: id)?.tagsRaw, raw)
    }

    func testC2SearchOpensWritingAtParagraphAndRevealsHiddenChild() throws {
        let id = try seed(.boundary)
        notes.libraryQueryAcrossTaskPage = "Sam owns"
        let presenter = try open(id)
        presenter.restoreViewStateOnMount()
        XCTAssertEqual(presenter.host.textView.selectedRange().location, "Everything that has to be true before 1.0 goes out.".utf16.count + 1)
        presenter.host.textView.setSelectedRange(NSRange(location: 0, length: 0))
        presenter.revealSearchResult("Sam owns")
        XCTAssertEqual(presenter.host.textView.selectedRange().location, "Everything that has to be true before 1.0 goes out.".utf16.count + 1, "selecting the same result again reveals it again")
        notes.libraryQueryAcrossTaskPage = "C2 hidden match"
        for index in 0..<5 { _ = tasks.create(title: index == 4 ? "C2 hidden match" : "C2 child \(index)", parentID: id) }
        presenter.model.refresh()
        presenter.model.setExpanded(false)
        let match = try XCTUnwrap(presenter.model.rows.first { $0.title == "C2 hidden match" })
        // A fresh opening consumes the search request and reveals the match.
        presenter.restoreViewStateOnMount()
        XCTAssertTrue(presenter.model.isVisible(match.id))
        XCTAssertEqual(presenter.model.focusedRowID, match.id)
        XCTAssertTrue(presenter.model.isRevealedForTheMoment)
    }

    func testC2InPageFindSearchesOnlyWritingAndNeverStructuredFields() throws {
        let id = try seed(.boundary), presenter = try open(id)
        let engine = try XCTUnwrap(presenter.session?.engine)
        engine.find.show()
        for query in [presenter.model.head.title, presenter.model.rows[0].title, "#launch"] {
            engine.find.query = query
            XCTAssertTrue(engine.find.matches.isEmpty, query)
        }
        engine.find.query = "Sam owns"
        XCTAssertEqual(engine.find.matches.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(engine.find.matches.first?.noteRange.location), 0)
    }

    func testC2OrdinaryFindExcludesTitleAndLibrarySearchOpensAtWriting() async throws {
        makeStores(); await notes.startAndWait()
        let id = UUID(), body = "First writing paragraph"
        _ = try notes.store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Title-only needle"), .text(body), .text("Second writing target")])).get()
        let opened = await notes.openFromLibrary(noteID: id, searchQuery: "Second writing target")
        XCTAssertTrue(opened)
        let session = try XCTUnwrap(notes.active)
        XCTAssertEqual(session.selection.location, "Title-only needle".utf16.count + body.utf16.count + 2)
        let view = session.engine.makeView().1
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; windows.append(window)
        window.contentView = session.engine.scrollView
        session.engine.find.show()
        session.engine.find.query = "Title-only needle"
        XCTAssertTrue(session.engine.find.matches.isEmpty)
        session.engine.find.query = "writing"
        XCTAssertEqual(session.engine.find.matches.count, 2)
        _ = view
    }

    func testC2TasksSearchesWritingChildrenFilenamesAndDoneLogAsOneItem() async throws {
        let ids = try TaskNoteLifecyclePreviewSeed.seed(in: container); makeStores()
        library = AtticLibrary(tasks: tasks, notes: notes.store, undo: library.undo)
        let model = TasksPageModel(library: library)
        let active = try XCTUnwrap(ids[.makeSubtask])
        for query in ["Things to turn", "Book the meeting room"] {
            model.setSearchQuery(query, for: .now)
            XCTAssertEqual(model.rows(for: .now).map(\.id), [active], query)
        }
        model.select(tab: .done)
        model.doneSearch = "Printed by Print Co."
        model.loadDoneLogIfNeeded()
        XCTAssertEqual(model.doneDays().flatMap(\.rows).map(\.id), [try XCTUnwrap(ids[.doneLogged])])
        let noteID = try XCTUnwrap(try ownNotes(active).first?.id)
        let context = ModelContext(container)
        context.insert(NoteAttachment(noteID: noteID, originalFilename: "C2-window-evidence.pdf", byteCount: 1, sortIndex: 0, contentDigest: ""))
        try context.save(); notes.store.refresh()
        model.setSearchQuery("C2-window-evidence", for: .now)
        XCTAssertEqual(model.rows(for: .now).map(\.id), [active])
    }

    func testC2DoneSearchInvalidatesCachedChildAndWritingTerms() async throws {
        let ids = try TaskNoteLifecyclePreviewSeed.seed(in: container); makeStores()
        library = AtticLibrary(tasks: tasks, notes: notes.store, undo: library.undo)
        let id = try XCTUnwrap(ids[.doneLogged])
        let context = ModelContext(container), seeded = TaskItem(title: "Searchable logged child", status: .done, parentID: id)
        seeded.doneLoggedAt = .now
        context.insert(seeded); try context.save(); tasks.refresh()
        let child = try XCTUnwrap(tasks.doneLogSubtasks(of: id).first)
        XCTAssertEqual(tasks.indexedDoneLogCount(matching: "C2 changed child"), 0)
        XCTAssertTrue(tasks.updateListed([child.id], title: "C2 changed child"))
        XCTAssertEqual(tasks.indexedDoneLogCount(matching: "C2 changed child"), 1)
        XCTAssertTrue(tasks.updateListed([child.id], title: "No longer matches"))
        XCTAssertEqual(tasks.indexedDoneLogCount(matching: "C2 changed child"), 0)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        var writing = try storedDocument(noteID)
        XCTAssertEqual(tasks.indexedDoneLogCount(matching: "C2 changed writing"), 0)
        writing.blocks.append(.text("C2 changed writing"))
        _ = try notes.store.saveDocument(noteID: noteID, document: writing, baseRevisionID: notes.store.note(withID: noteID)?.revisionID).get()
        XCTAssertEqual(tasks.indexedDoneLogCount(matching: "C2 changed writing"), 1)
    }

    func testC2MarkdownAndPrintUseLiveHeadDetailsSubtasksThenWriting() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "C2 export title", priority: .high, tags: ["export"]))
        presenter.model.refresh()
        let storedBefore = try storedDocument(session.noteID)
        let markdown = try XCTUnwrap(notes.markdown(noteID: session.noteID))
        XCTAssertTrue(markdown.hasPrefix("# C2 export title"))
        XCTAssertTrue(markdown.contains("High priority"))
        for row in presenter.model.rows { XCTAssertTrue(markdown.contains(row.title), row.title) }
        XCTAssertLessThan(try XCTUnwrap(markdown.range(of: presenter.model.rows[0].title)?.lowerBound), try XCTUnwrap(markdown.range(of: "Everything that has")?.lowerBound))
        let printed = await session.engine.preparedPrintView()
        XCTAssertTrue(printed.string.hasPrefix("C2 export title"))
        XCTAssertTrue(printed.string.contains("High priority"))
        XCTAssertTrue(printed.string.contains(presenter.model.rows[0].title))
        XCTAssertEqual(try storedDocument(session.noteID), storedBefore, "export is a read-only projection")
    }

    func testC2ExportOfANeverWrittenTaskIncludesItsHeadWithoutCreatingWriting() async throws {
        let id = try seed(.nonote), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), priority: .high, tags: ["bare-export"]))
        presenter.model.refresh()
        XCTAssertTrue(try ownNotes(id).isEmpty)
        let markdown = try XCTUnwrap(notes.markdown(noteID: session.noteID))
        XCTAssertTrue(markdown.contains("High priority"))
        let roundTrip = try NoteMarkdownImport.document(markdown)
        XCTAssertTrue(roundTrip.blocks.contains { $0.text == "#bare-export" }, "escaped Markdown retains the literal tag")
        let printView = await session.engine.preparedPrintView()
        XCTAssertTrue(printView.string.contains("High priority"))
        XCTAssertTrue(printView.string.contains("#bare-export"))
        XCTAssertTrue(try ownNotes(id).isEmpty, "read-only export cannot materialize a task draft")
        XCTAssertFalse(session.isPersisted)
    }

    func testC2HistoryPreviewsHistoricalDetailsButRestoreKeepsCurrentTaskFamily() async throws {
        let id = try seed(.boundary), presenter = try open(id), session = try XCTUnwrap(presenter.session)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), priority: .high, tags: ["historical"]))
        XCTAssertTrue(notes.store.recordVersion(noteID: session.noteID, reason: .pause))
        let version = try XCTUnwrap(notes.store.versions(noteID: session.noteID).first)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "C2 current head", priority: .low, tags: ["current"]))
        let taskBefore = try WorkspaceModelToken.read(.init(entity: .task, id: id), in: ModelContext(container))
        let associationBefore = try WorkspaceScopeToken.read(.taskAssociations(id), in: ModelContext(container))
        let historyOpened = await notes.openHistoryDurably(workspace: session)
        XCTAssertTrue(historyOpened)
        let browser = try XCTUnwrap(notes.historyBrowser)
        notes.selectHistoryVersion(try XCTUnwrap(browser.entries.firstIndex { $0.id == version.id }))
        let preview = try XCTUnwrap(notes.historyBrowser?.preview?.engine.textStorage.string)
        XCTAssertTrue(preview.contains("High priority"))
        XCTAssertTrue(preview.contains("#historical"))
        XCTAssertFalse(preview.components(separatedBy: "\n").contains("Low priority"), "live details may appear only as labelled comparison context")
        XCTAssertTrue(preview.contains("Not in this version: “Low priority”"))
        let historyRestored = await notes.restoreHistoryVersionDurably()
        XCTAssertTrue(historyRestored)
        XCTAssertEqual(try WorkspaceModelToken.read(.init(entity: .task, id: id), in: ModelContext(container)), taskBefore)
        XCTAssertEqual(try WorkspaceScopeToken.read(.taskAssociations(id), in: ModelContext(container)), associationBefore)
    }

    // MARK: Version History of a task's note (S4, § 2.10)

    func testVersionHistoryRestoresTheNoteOnlyNeverTheTaskOrItsSubtasks() async throws {
        let (id, presenter, session) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        guard case .made = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes) else { return XCTFail() }
        XCTAssertEqual(tasks.subtasks(of: id).count, 3)
        XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: id)), title: "Renamed launch checklist"))
        let opened = await notes.openHistoryDurably(workspace: session)
        XCTAssertTrue(opened)
        let browser = try XCTUnwrap(notes.historyBrowser)
        XCTAssertEqual(browser.noteID, session.noteID)
        let index = try XCTUnwrap(browser.entries.firstIndex { $0.document.blocks.contains { $0.text.hasPrefix("Everything that has") } })
        notes.selectHistoryVersion(index)
        XCTAssertEqual(notes.historyBrowser?.preview?.engine.isBodyOnly, true, "the preview shows the body, never block 0")
        let restored = await notes.restoreHistoryVersionDurably()
        XCTAssertTrue(restored)
        XCTAssertNil(notes.historyBrowser)
        let stored = try storedDocument(session.noteID)
        XCTAssertEqual(stored.blocks.dropFirst().first?.text, "Everything that has to be true before 1.0 goes out.", "the body returns")
        XCTAssertEqual(stored.title, "Renamed launch checklist", "block 0 is today's title, never the old snapshot")
        XCTAssertTrue(stored.requires.contains("taskNote"))
        XCTAssertEqual(tasks.subtasks(of: id).count, 3, "the subtasks are never rewound")
        XCTAssertEqual(tasks.task(withID: id)?.title, "Renamed launch checklist", "the task is never rewound")
        XCTAssertTrue(try rows(session.noteID).allSatisfy { $0.taskID == id }, "the association stays")
        XCTAssertTrue(presenter.host.textView.string.hasPrefix("Everything that has"), "the page shows the restored text")
    }

    // MARK: Agents (§ 5.9): the workspace read and body-only note writes

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func workspaceTokens(_ id: UUID, tools: AgentTaskTools) throws -> [String: Any] {
        let payload = try json(tools.call(name: "get_task_workspace", arguments: ["id": id.uuidString]))
        return ["base_note_token": try XCTUnwrap(payload["note_token"] as? String),
                "base_association_token": try XCTUnwrap(payload["association_token"] as? String)]
    }

    func testGetTaskWorkspaceReadsTheTaskItsSubtasksAndItsBodyWithoutTheTitleInOneSnapshot() throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        let tools = AgentTaskTools(store: tasks, noteStore: notes.store, library: library)
        XCTAssertTrue(tools.definitions.contains { ($0["name"] as? String) == "get_task_workspace" })
        let payload = try json(tools.call(name: "get_task_workspace", arguments: ["id": id.uuidString]))
        XCTAssertEqual((payload["task"] as? [String: Any])?["title"] as? String, "Finalize launch checklist")
        let subtasks = try XCTUnwrap(payload["subtasks"] as? [String: Any])
        XCTAssertEqual((subtasks["open"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["Write release notes"])
        XCTAssertEqual((subtasks["done"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["Freeze strings"])
        XCTAssertEqual(payload["own_note_id"] as? String, noteID.uuidString)
        let body = try XCTUnwrap(payload["body"] as? String)
        XCTAssertTrue(body.hasPrefix("Everything that has"), "the body without block 0")
        XCTAssertFalse(body.contains("Finalize launch checklist"))
        XCTAssertNotNil(payload["task_token"] as? String)
        XCTAssertNotNil(payload["note_revision"] as? String)
        // The token covers the family: a subtask change makes it stale.
        let first = payload["task_token"] as? String
        XCTAssertTrue(library.updateTask(try XCTUnwrap(tasks.subtasks(of: id).first).id, status: .done).isApplied)
        let again = try json(tools.call(name: "get_task_workspace", arguments: ["id": id.uuidString]))
        XCTAssertNotEqual(again["task_token"] as? String, first)
    }

    func testAnAgentWritesATasksNoteBodyOnlyAndNeverItsTitle() throws {
        let id = try seed(.boundary)
        let noteID = try XCTUnwrap(try ownNotes(id).first?.id)
        // The agent server's own note store (no editor on screen here).
        let agentNotes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let tools = AgentTaskTools(store: tasks, noteStore: agentNotes, library: library)
        let revision = try XCTUnwrap(agentNotes.note(withID: noteID)?.revisionToken)
        XCTAssertThrowsError(try tools.call(name: "update_note", arguments: ["id": noteID.uuidString, "title": "Hijack",
                                                                             "base_revision": revision]),
                             "a task's note has no title of its own")
        _ = try tools.call(name: "update_note", arguments: workspaceTokens(id, tools: tools).merging(["id": noteID.uuidString, "body": "Agent wrote this.",
                                                            "base_revision": revision]) { _, new in new })
        let stored = try storedDocument(noteID)
        XCTAssertEqual(stored.title, "Finalize launch checklist", "block 0 stays the live title snapshot")
        XCTAssertTrue(stored.requires.contains("taskNote"))
        XCTAssertEqual(stored.blocks.dropFirst().map(\.text), ["Agent wrote this."])
        XCTAssertEqual(tasks.subtasks(of: id).count, 2, "a body write never touches subtasks")
        XCTAssertTrue(try rows(noteID).allSatisfy { $0.taskID == id }, "nor the association")
    }

    // MARK: The "Attic Task Life" preview seed

    func testTheTaskLifePreviewSeedsEveryNewState() async throws {
        let ids = try TaskNoteLifecyclePreviewSeed.seed(in: container)
        makeStores()
        let deletedNote = try open(try XCTUnwrap(ids[.deletedNote]))
        XCTAssertTrue(deletedNote.model.deletedNote, "Write a new note · Restore Note")
        let deletedTask = try open(try XCTUnwrap(ids[.deletedTask]))
        XCTAssertFalse(deletedTask.model.head.exists, "Task deleted · Restore")
        XCTAssertEqual(deletedTask.model.rows.count, 1)
        let alternate = try open(try XCTUnwrap(ids[.alternateNote]))
        XCTAssertEqual(alternate.model.alternateNotes.count, 1, "Another note for this task · Review")
        let history = try XCTUnwrap(ids[.history])
        let noteID = try XCTUnwrap(try ownNotes(history).first?.id)
        XCTAssertEqual(notes.store.versions(noteID: noteID).count, 2)
        let logged = try open(try XCTUnwrap(ids[.doneLogged]))
        XCTAssertTrue(logged.model.head.exists)
        XCTAssertEqual(logged.model.head.state, .done)
        let demo = try open(try XCTUnwrap(ids[.makeSubtask]))
        XCTAssertTrue(demo.host.textView.string.contains("Record a backup video"))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TaskDeletionPreservation>())
            .contains { $0.rootID == ids[.deletedTask] }, "the deleted task has its preservation record")
    }

    /// The panel's Tasks page learns which tasks have notes from the note
    /// store, as the app wires it (the row glyph on screen).
    func testTheTasksPageHostFeedsTheNoteOwnersToItsRows() throws {
        let id = try seed(.boundary)
        let suite = "TaskLife.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = TasksPageState()
        let services = TaskNoteEntryServices(open: { _, _ in }, addFiles: { _, _ in },
            noteOwners: notes.store.$notes.map { Set($0.compactMap(\.taskID)) }.removeDuplicates().eraseToAnyPublisher())
        let host = TasksPageHost(store: tasks, uiState: PanelUIState(), settings: AppSettings(defaults: defaults), state: state,
            layout: PanelPageLayout(cornerSize: 24, panelSize: panel), chromeInteractionState: PanelChromeInteractionState(),
            primaryInputFocusRequest: 0, taskNotes: services)
        let hosting = NSHostingView(rootView: host)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: panel), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        windows.append(window)
        for _ in 0..<20 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let model = state.model(for: tasks, toasts: nil)
        XCTAssertTrue(model.noteOwners.contains(id))
        XCTAssertEqual(model.rows(for: .now).first { $0.id == id }?.model.hasPage, true)
        // A list skips rows that compare equal: the glyph must count.
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == id })
        var without = row.model
        without.hasPage = false
        XCTAssertNotEqual(row, TasksListRow(id: row.id, model: without, status: row.status, subtasks: row.subtasks, files: row.files))
    }

    /// The page leaves after Make Subtask and after its Undo (Back worked
    /// before; nothing may stay pending on the page's history).
    func testThePageLeavesAfterMakeSubtaskAndItsUndo() async throws {
        let (_, presenter, _) = try makeSubtaskFixture()
        presenter.host.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let analysis = try XCTUnwrap(presenter.subtaskSelection())
        guard case let .made(entryID, _, _) = await presenter.makeSubtasks(analysis, tasks: tasks, notes: notes) else { return XCTFail() }
        XCTAssertNil(presenter.page.history.pendingCommandID)
        let undone = await presenter.page.history.undoLatest(stepID: entryID)
        XCTAssertEqual(undone, .applied)
        XCTAssertNil(presenter.page.history.pendingReplayID)
        await close(presenter)
    }
}

@MainActor
private final class ReservedDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
