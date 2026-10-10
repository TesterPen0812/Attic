import AppKit
import Combine
import SwiftData
import XCTest
@testable import Attic

/// Phase X parts 4/7: no ordered windows, screen access or owner stores.
@MainActor
final class PhaseXHunt1bTests: XCTestCase {
    private func create(_ store: NoteStore, title: String = "Current", body: String = "Body",
                        tags: [String] = []) throws -> UUID {
        try store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text(title), .text(body)]),
                                     tags: tags).get().noteID
    }
    private func controller(_ store: NoteStore, journal: NoteDraftJournaling? = nil) async -> NotesPageController {
        let result = NotesPageController(store: store,
            journal: journal ?? NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "Hunt1b")),
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await result.startAndWait()
        return result
    }
    private func rows(_ library: NotesLibraryModel, _ store: NoteStore) -> [AtticNoteRowModel] {
        library.groups(store: store, drafts: []).flatMap(\.rows)
    }

    func testH3_01LibraryRefreshInvalidatesBodyCacheForSameRevisionReplicaChange() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store, body: "Old preview")
        let library = NotesLibraryModel(search: { try await store.searchNoteIDs(matching: $0) }, store: store)
        XCTAssertEqual(try XCTUnwrap(rows(library, store).first).preview, "Old preview")
        let imported = ModelContext(store.container)
        let row = try XCTUnwrap(imported.fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
        // Same-token divergent replicas are explicitly supported by the store.
        let changed = NoteDocument(blocks: [.text("Renamed"), .text("New preview")])
        row.content = try NoteContentCodec.encode(changed)
        row.title = "Renamed"; row.body = "New preview"; row.plainText = "Renamed\nNew preview"
        try imported.save()
        store.refresh()
        library.query = "New preview"
        await library.waitForSearch()
        let shown = try XCTUnwrap(rows(library, store).first)
        XCTAssertEqual(shown.id, id)
        XCTAssertEqual(shown.title, "Renamed")
        XCTAssertEqual(shown.preview, "New preview", "A fresh context must replace the old cached body")
    }

    func testR2_01AcceptPreservesTagsChangedAfterReview() async throws {
        for deletion in [false, true] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = try create(store, tags: ["saved"])
            let page = await controller(store)
            XCTAssertTrue(page.open(noteID: id))
            let session = try XCTUnwrap(page.active)
            let revision = try XCTUnwrap(store.note(withID: id)).revisionToken
            let result = deletion
                ? store.agentDelete(noteID: id, baseRevisionToken: revision, agentName: "Agent", disposition: .proposal)
                : store.agentWrite(noteID: id, baseRevisionToken: revision,
                    document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Agent", disposition: .proposal)
            guard case let .success(.pending(proposal)) = result else { return XCTFail("proposal fixture") }
            await XCTAssertTrueAsync(await page.beginProposalReview(id: proposal))
            session.engine.setTagsFromPicker(["unsaved"])
            await XCTAssertFalseAsync(await page.acceptProposal(), "Changed session state needs preservation and review first")
            XCTAssertTrue(page.active === session)
            XCTAssertEqual(session.engine.tags, ["unsaved"])
            // The refreshed review can safely replace only after all pending work is saved.
            await XCTAssertTrueAsync(await page.acceptProposal())
            let physical = try ModelContext(store.container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == id }
            XCTAssertEqual(physical.count, 1)
            XCTAssertEqual(physical.first?.tags, ["unsaved"], "Saved or trashed note must keep the edited tags")
            if !deletion {
                await XCTAssertTrueAsync(await page.preserveAllDurably())
                XCTAssertEqual(store.note(withID: id)?.tags, ["unsaved"])
                XCTAssertEqual(page.active?.state, .clean)
            }
        }
    }

    func testR2_01AcceptSavesStagedFilesBeforeReplacingReviewedDraft() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        let session = try XCTUnwrap(page.active)
        guard case let .success(.pending(proposal)) = store.agentWrite(noteID: id,
            baseRevisionToken: try XCTUnwrap(store.note(withID: id)).revisionToken,
            document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Agent", disposition: .proposal) else {
            return XCTFail("proposal fixture")
        }
        await XCTAssertTrueAsync(await page.beginProposalReview(id: proposal))
        let bytes = Data("unsaved file".utf8)
        let file = StagedNoteAttachment(id: UUID(), filename: "draft.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        session.engine.beginImageImport(at: NSRange(location: session.engine.textStorage.length, length: 0))
        XCTAssertTrue(session.engine.insertImportedObjects([NoteImportedObject(staged: file, pixelSize: nil)]))
        let draft = session.engine.document()
        await XCTAssertFalseAsync(await page.acceptProposal())
        await XCTAssertTrueAsync(await page.acceptProposal())
        XCTAssertTrue(store.versions(noteID: id).contains { $0.content.flatMap { NoteContentCodec.decode($0).document } == draft })
        XCTAssertEqual(store.attachmentFamily(file.id).first?.payload, bytes)
    }

    func testR2_01SaveAsNewKeepsLiveTagsAndOriginalPendingWork() async throws {
        for deletion in [false, true] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = try create(store, tags: ["saved"])
            let page = await controller(store)
            XCTAssertTrue(page.open(noteID: id))
            let session = try XCTUnwrap(page.active)
            let revision = try XCTUnwrap(store.note(withID: id)).revisionToken
            let result = deletion
                ? store.agentDelete(noteID: id, baseRevisionToken: revision, agentName: "Agent", disposition: .proposal)
                : store.agentWrite(noteID: id, baseRevisionToken: revision,
                    document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Agent", disposition: .proposal)
            guard case let .success(.pending(proposal)) = result else { return XCTFail("proposal fixture") }
            await XCTAssertTrueAsync(await page.beginProposalReview(id: proposal))
            session.engine.setTagsFromPicker(["live"])
            await XCTAssertTrueAsync(await page.saveReviewedProposalAsNew())
            XCTAssertTrue(page.active === session)
            XCTAssertEqual(session.state, .dirty)
            let copy = try XCTUnwrap(store.notes.first { $0.id != id })
            XCTAssertEqual(copy.tags, ["live"])
            await XCTAssertTrueAsync(await page.preserveAllDurably())
            XCTAssertEqual(store.note(withID: id)?.tags, ["live"])
        }
    }

    func testR2_03UndoReschedulesBothAutosaveAndDurabilityDeadline() async throws {
        for deadline in [false, true] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = try create(store, title: "Earlier")
            XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
            _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Current")]),
                baseRevisionID: store.note(withID: id)?.revisionID).get()
            let page = NotesPageController(store: store,
                journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "R2UndoTimers")),
                saveDelay: deadline ? .seconds(600) : .milliseconds(20),
                durabilityDelay: deadline ? .milliseconds(20) : .seconds(600), pauseVersionDelay: .seconds(600))
            await page.startAndWait()
            XCTAssertTrue(page.open(noteID: id))
            let displaced = try XCTUnwrap(page.active)
            await XCTAssertTrueAsync(await page.openHistoryDurably())
            await XCTAssertTrueAsync(await page.restoreHistoryVersionDurably())
            XCTAssertTrue(displaced.engine.performEdit(NSRange(location: displaced.engine.textStorage.length, length: 0),
                with: NSAttributedString(string: " late"), name: "Late callback"))
            let late = displaced.engine.document()
            // Let the original timer fail against the restored revision and expire.
            try await Task.sleep(for: .milliseconds(200))
            await page.waitForRecoveryWork()
            XCTAssertTrue(displaced.isConflict)
            await XCTAssertTrueAsync(await page.undoVersionRestoreDurably(expectedID: page.versionRestoreUndoID))
            XCTAssertEqual(displaced.state, .dirty)
            for _ in 0..<100 {
                if displaced.state == .clean { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(displaced.state, .clean, "Undo must restart the \(deadline ? "deadline" : "autosave")")
            XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, late)
        }
    }

    private func restoreDuringRecoveryWait(
        _ mutate: (NoteSession, NoteHistoryBrowser) -> Void
    ) async throws -> (Bool, NotesPageController, NoteSession, NoteHistoryBrowser) {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store, title: "Earlier")
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Middle")]),
            baseRevisionID: store.note(withID: id)?.revisionID).get()
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Current")]),
            baseRevisionID: store.note(withID: id)?.revisionID).get()
        let journal = H3BlockingJournal(directory: ownedTemporaryDirectory(prefix: "R2RestoreWait"))
        let page = await controller(store, journal: journal)
        await XCTAssertTrueAsync(await page.newNoteDurably())
        let hidden = try XCTUnwrap(page.active)
        XCTAssertTrue(hidden.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Hidden"), name: "Type"))
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        XCTAssertTrue(page.open(noteID: id))
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        let session = try XCTUnwrap(page.active), browser = try XCTUnwrap(page.historyBrowser)
        let waiting = expectation(description: "Recovery suspended")
        var resume: CheckedContinuation<Void, Never>?
        journal.beforeWrite = {
            journal.beforeWrite = nil
            await withCheckedContinuation { resume = $0; waiting.fulfill() }
        }
        XCTAssertTrue(hidden.engine.performEdit(NSRange(location: hidden.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: " pending"), name: "Type"))
        gate.shouldFail = true
        XCTAssertTrue(page.preserve(hidden, allowQueued: true))
        await fulfillment(of: [waiting], timeout: 5)
        gate.shouldFail = false
        let restore = Task { await page.restoreHistoryVersionDurably() }
        for _ in 0..<100 {
            if browser.isRestoring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(browser.isRestoring)
        mutate(session, browser)
        resume?.resume()
        let result = await restore.value
        await page.waitForRecoveryWork()
        return (result, page, session, browser)
    }

    func testR2_02RestoreRefreshesCompositionBeforeCheckingLateEdits() async throws {
        var heldView: NoteEditorTextView?
        let (restored, page, session, browser) = try await restoreDuringRecoveryWait { session, _ in
            let (_, view) = session.engine.makeView()
            heldView = view
            view.setSelectedRange(NSRange(location: session.engine.textStorage.length, length: 0))
            view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            session.engine.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertEqual(session.engine.activity, .composing)
            view.delegate = nil
            view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            view.unmarkText()
            view.delegate = session.engine
            XCTAssertEqual(session.engine.activity, .composing)
        }
        XCTAssertFalse(restored)
        XCTAssertTrue(page.active === session)
        XCTAssertTrue(page.historyBrowser === browser)
        XCTAssertEqual(session.engine.activity, .idle, "Cancelled composition must self-heal even when the edit generation changed")
        _ = heldView
    }

    func testR2_04RestoreRechecksSelectedVersionAfterRecoveryWait() async throws {
        let (restored, page, session, browser) = try await restoreDuringRecoveryWait { _, browser in
            XCTAssertGreaterThan(browser.entries.count, 1)
            browser.selectedIndex = 1
            browser.updateComparison()
        }
        XCTAssertFalse(restored, "A selection changed during the await requires a fresh Restore action")
        XCTAssertTrue(page.active === session)
        XCTAssertTrue(page.historyBrowser === browser)
        XCTAssertEqual(page.active?.engine.document().title, "Current")
    }

    func testR2_05RestoreKeepsNewerUnpinnedReplicaCanonical() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let older = try XCTUnwrap(store.note(withID: id))
        older.pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = NoteItem(id: id, title: older.title, body: older.body,
            createdAt: older.createdAt, updatedAt: older.updatedAt.addingTimeInterval(60))
        newer.content = older.content; newer.contentFormat = older.contentFormat
        newer.revision = older.revision; newer.revisionID = older.revisionID
        newer.pinnedAt = nil
        store.modelContext.insert(newer); try store.modelContext.save()
        store.refresh()
        XCTAssertFalse(try XCTUnwrap(store.note(withID: id)).isPinned)
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        await XCTAssertTrueAsync(await page.restoreHistoryVersionDurably())
        let physical = try ModelContext(store.container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == id }
        XCTAssertEqual(physical.count, 2)
        XCTAssertTrue(physical.allSatisfy { $0.pinnedAt == nil }, "Restore must converge on the newer replica's explicit unpin")
    }

    func testH3_01CleanCachedSessionFollowsSameTokenContentRefresh() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store, body: "Old body")
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        let original = try XCTUnwrap(page.active)
        let imported = ModelContext(store.container)
        let row = try XCTUnwrap(imported.fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
        let changed = NoteDocument(blocks: [.text("Renamed"), .text("New body")])
        row.content = try NoteContentCodec.encode(changed)
        row.title = "Renamed"; row.body = "New body"; row.plainText = "Renamed\nNew body"
        try imported.save()
        store.refresh(); page.present()
        XCTAssertEqual(page.active?.engine.document(), changed)
        let refreshed = try XCTUnwrap(page.active)
        XCTAssertFalse(refreshed === original)
        XCTAssertTrue(refreshed.engine.performEdit(NSRange(location: refreshed.engine.textStorage.length, length: 0),
                                                   with: NSAttributedString(string: " mine"), name: "Type"))
        row.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Outside")]))
        try imported.save()
        store.refresh(); page.present()
        XCTAssertTrue(page.active === refreshed, "A dirty editor retains its own text after refresh")
        XCTAssertEqual(page.active?.engine.document().blocks.last?.text, "New body mine")
    }

    func testH3_02BrowserRestoreConvergesPinnedMetadataAcrossPhysicalReplicas() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        XCTAssertTrue(store.setPinned(true, noteID: id))
        let canonical = try XCTUnwrap(store.note(withID: id))
        canonical.tags = ["canonical"]
        canonical.taskID = UUID()
        canonical.externalEditorName = "Agent"
        canonical.externalEditedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.modelContext.save()
        let duplicate = NoteItem(id: id, title: canonical.title, body: canonical.body,
                                 createdAt: canonical.createdAt.addingTimeInterval(-100), updatedAt: canonical.updatedAt.addingTimeInterval(-60))
        duplicate.content = canonical.content; duplicate.contentFormat = canonical.contentFormat
        duplicate.revision = canonical.revision; duplicate.revisionID = canonical.revisionID
        duplicate.pinnedAt = nil
        store.modelContext.insert(duplicate); try store.modelContext.save()
        store.refresh()
        XCTAssertTrue(try XCTUnwrap(store.note(withID: id)).isPinned)
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        await XCTAssertTrueAsync(await page.restoreHistoryVersionDurably())
        let physical = try ModelContext(store.container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == id }
        XCTAssertEqual(physical.count, 2)
        XCTAssertTrue(physical.allSatisfy(\.isPinned), "Restore must preserve canonical metadata on every replica")
        for replica in physical {
            XCTAssertEqual(replica.pinnedAt, canonical.pinnedAt)
            XCTAssertEqual(replica.createdAt, canonical.createdAt)
            XCTAssertEqual(replica.tags, canonical.tags)
            XCTAssertEqual(replica.taskID, canonical.taskID)
            XCTAssertEqual(replica.externalEditorName, canonical.externalEditorName)
            XCTAssertEqual(replica.externalEditedAt, canonical.externalEditedAt)
        }
    }

    func testH3_03VersionRecordingPreservesAttachmentVisibilityChanges() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try XCTUnwrap(store.create(title: "Text", body: "Same prose")).id
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .leave))
        let bytes = Data([1, 2, 3])
        let image = StagedNoteAttachment(id: UUID(), filename: "added.png", contentTypeIdentifier: "public.png",
            byteCount: 3, digest: NotePayloadDigest.sha256(bytes), data: bytes)
        var document = try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
        document.blocks.append(.image(attachmentID: image.id))
        guard case .success = store.saveDocument(noteID: id, document: document,
            baseRevisionID: store.note(withID: id)?.revisionID, staged: [image]) else { return XCTFail() }
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let withImage = try XCTUnwrap(store.versions(noteID: id).first)
        XCTAssertEqual(withImage.attachmentIDs, [image.id])
        let count = store.versions(noteID: id).count
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        XCTAssertEqual(store.versions(noteID: id).count, count, "An unchanged attachment set is already preserved")
        XCTAssertTrue(store.removeAttachment(try XCTUnwrap(store.attachments(for: id).first)))
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        XCTAssertTrue(try XCTUnwrap(store.versions(noteID: id).first).attachmentIDs.isEmpty)
        XCTAssertEqual(store.versions(noteID: id).count, count + 1)
        _ = try store.restoreVersion(withImage.id, noteID: id).get()
        XCTAssertTrue(store.attachments(for: id).contains { $0.id == image.id })
    }

    func testH3_04RestorePreservesEditsArrivingDuringRecoveryWait() async throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store, title: "Earlier", body: "Original")
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Current"), .text("Saved")]),
                                   baseRevisionID: store.note(withID: id)?.revisionID).get()
        let journal = H3BlockingJournal(directory: ownedTemporaryDirectory(prefix: "H3RecoveryWait"))
        let page = await controller(store, journal: journal)
        await XCTAssertTrueAsync(await page.newNoteDurably())
        let hidden = try XCTUnwrap(page.active)
        XCTAssertTrue(hidden.engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "Other note"), name: "Type"))
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        XCTAssertTrue(page.open(noteID: id))
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        let current = try XCTUnwrap(page.active), browser = try XCTUnwrap(page.historyBrowser)
        let waiting = expectation(description: "Other session recovery is suspended")
        var resume: CheckedContinuation<Void, Never>?
        journal.beforeWrite = {
            journal.beforeWrite = nil
            await withCheckedContinuation { continuation in resume = continuation; waiting.fulfill() }
        }
        XCTAssertTrue(hidden.engine.performEdit(NSRange(location: hidden.engine.textStorage.length, length: 0),
                                                with: NSAttributedString(string: " queued"), name: "Type"))
        gate.shouldFail = true
        XCTAssertTrue(page.preserve(hidden, allowQueued: true))
        await fulfillment(of: [waiting], timeout: 5)
        gate.shouldFail = false
        let restore = Task { await page.restoreHistoryVersionDurably() }
        for _ in 0..<100 {
            if browser.isRestoring { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(browser.isRestoring)
        // A late editor callback edits the owned session while Restore waits.
        XCTAssertTrue(current.engine.performEdit(NSRange(location: current.engine.textStorage.length, length: 0),
                                                 with: NSAttributedString(string: " LATE"), name: "Late callback"))
        let changed = current.engine.document()
        resume?.resume()
        let restored = await restore.value
        await page.waitForRecoveryWork()
        let safePreservation: Bool
        let cleanMatchesStore: Bool
        if restored {
            safePreservation = store.versions(noteID: id).contains {
                $0.content.flatMap { NoteContentCodec.decode($0).document } == changed
            }
            await XCTAssertTrueAsync(await page.undoVersionRestoreDurably(expectedID: page.versionRestoreUndoID))
            let saved = try XCTUnwrap(store.note(withID: id)?.content)
            cleanMatchesStore = page.active?.state != .clean
                || NoteContentCodec.decode(saved).document == page.active?.engine.document()
        } else {
            safePreservation = page.historyBrowser === browser && page.active === current
                && page.active?.engine.document() == changed
            cleanMatchesStore = true
        }
        XCTAssertTrue(safePreservation, "Late work must stay owned by the current editor or be saved before Restore")
        XCTAssertTrue(cleanMatchesStore, "A clean returned editor must agree with persisted content")
    }

    func testH3_04UndoKeepsLateWorkInTheDisplacedSessionDirty() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store, title: "Earlier")
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Current")]),
                                   baseRevisionID: store.note(withID: id)?.revisionID).get()
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        let original = try XCTUnwrap(page.active)
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        await XCTAssertTrueAsync(await page.restoreHistoryVersionDurably())
        XCTAssertTrue(original.engine.performEdit(NSRange(location: original.engine.textStorage.length, length: 0),
                                                  with: NSAttributedString(string: " LATE"), name: "Late callback"))
        original.engine.setTagsFromPicker(["late"])
        let late = original.engine.document()
        await XCTAssertTrueAsync(await page.undoVersionRestoreDurably(expectedID: page.versionRestoreUndoID))
        XCTAssertTrue(page.active === original)
        XCTAssertEqual(original.engine.document(), late)
        XCTAssertEqual(original.engine.tags, ["late"])
        XCTAssertEqual(original.state, .dirty)
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, late)
        XCTAssertEqual(store.note(withID: id)?.tags, ["late"])
        XCTAssertEqual(original.state, .clean)
    }

    func testSearchTracksTagsRenamesMovesAndDeletesAndNoMatchCreation() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store, title: "Old title", body: "First\nSecond", tags: ["work"])
        let other = try create(store, title: "Other", body: "Second", tags: ["home"])
        let library = NotesLibraryModel(search: { try await store.searchNoteIDs(matching: $0) }, store: store)
        library.tagFilter = "work"; library.query = "#work"
        await library.waitForSearch(); XCTAssertEqual(rows(library, store).map(\.id), [id])
        let current = try XCTUnwrap(store.note(withID: id))
        _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Renamed"), .text("Second"), .text("First")]),
                                   baseRevisionID: current.revisionID, tags: ["home"]).get()
        await library.waitForSearch(); XCTAssertTrue(rows(library, store).isEmpty)
        library.tagFilter = nil; library.query = "Renamed"
        await library.waitForSearch(); XCTAssertEqual(rows(library, store).map(\.id), [id])
        XCTAssertEqual(try XCTUnwrap(rows(library, store).first).preview, "Second First")
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        await library.waitForSearch(); XCTAssertTrue(rows(library, store).isEmpty)
        XCTAssertEqual(library.queryForNewNote(in: library.groups(store: store, drafts: [])), "Renamed")
        let page = await controller(store)
        XCTAssertTrue(page.showLibrary()); XCTAssertTrue(page.requestNewNote(title: "Renamed", tags: ["work"]))
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        let newID = try XCTUnwrap(page.active?.noteID)
        XCTAssertNotEqual(newID, id); XCTAssertEqual(store.note(withID: newID)?.tags, ["work"])
        XCTAssertNotNil(store.note(withID: other))
    }

    func testHistoryRetryRestoreUndoRedoAndCopyKeepStructuredContent() async throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store, title: "Earlier", body: "Original")
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let revision = try XCTUnwrap(store.note(withID: id)?.revisionID)
        var bold = NoteBlock.text("Changed"); bold.marks = [NoteMark(.bold, offset: 0, length: 7)]
        var current = NoteDocument(blocks: [.text("Current"), bold, .table(NoteTable(texts: [["Header"], ["Cell"]]))])
        current.refreshRequiredCapabilities()
        _ = try store.saveDocument(noteID: id, document: current, baseRevisionID: revision).get()
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        let browser = try XCTUnwrap(page.historyBrowser), originalSession = try XCTUnwrap(page.active)
        let entry = try XCTUnwrap(browser.selected)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let copy = NoteEditorEngine(noteID: id, document: entry.document, readOnly: true)
        XCTAssertTrue(copy.writeSelection(NSRange(location: 0, length: copy.textStorage.length), to: clipboard,
                                         types: [.string, NoteEditorEngine.fragmentType]))
        XCTAssertEqual(clipboard.string(forType: .string), "Earlier\nOriginal")
        XCTAssertFalse(try XCTUnwrap(clipboard.string(forType: .string)).contains("Not in"))
        let fragment = try XCTUnwrap(clipboard.data(forType: NoteEditorEngine.fragmentType))
        XCTAssertEqual(NoteContentCodec.decode(fragment, context: .fragment).document?.blocks.map(\.text), entry.document.blocks.map(\.text))
        let count = store.versions(noteID: id).count
        gate.shouldFail = true
        await XCTAssertFalseAsync(await page.restoreHistoryVersionDurably())
        XCTAssertTrue(page.historyBrowser === browser); XCTAssertNotNil(browser.failure)
        XCTAssertEqual(store.versions(noteID: id).count, count)
        gate.shouldFail = false
        await XCTAssertTrueAsync(await page.restoreHistoryVersionDurably())
        XCTAssertEqual(page.active?.engine.document(), entry.document)
        await XCTAssertTrueAsync(await page.undoVersionRestoreDurably(expectedID: page.versionRestoreUndoID))
        XCTAssertTrue(page.active === originalSession); XCTAssertEqual(page.active?.engine.document(), current)
        await XCTAssertTrueAsync(await page.redoVersionRestoreDurably())
        XCTAssertEqual(page.active?.engine.document(), entry.document)
        XCTAssertEqual(store.note(withID: id)?.title, "Earlier")
    }

    func testProposalBaseAndRichHistoryRemainProtectedAcrossRestoreAndThinning() async throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeTestNoteStore(now: { clock }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = try store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [
            .text("Current"), .table(NoteTable(texts: [["Header"], ["Protected cell"]]))])).get().noteID
        let revision = try XCTUnwrap(store.note(withID: id)?.revisionToken)
        _ = try store.agentWrite(noteID: id, baseRevisionToken: revision,
                                document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Test", disposition: .proposal).get()
        let proposal = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        let base = try XCTUnwrap(proposal.baseVersionID)
        clock += 60 * 86_400
        store.thinVersions(noteID: id)
        XCTAssertTrue(store.versions(noteID: id).contains { $0.id == base })
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        await XCTAssertTrueAsync(await page.restoreHistoryVersionDurably())
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0, "An old proposal cannot silently replace a restored revision")
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
        store.thinVersions(noteID: id)
        XCTAssertTrue(store.versions(noteID: id).contains { $0.id == base })
        XCTAssertFalse(store.historyRetainedVersionIDs.isEmpty)
    }
    func testSeededOrganizeSequencesMatchAnIndependentLibraryReference() async throws {
        struct Expected { var title: String; var body: String; var tags: [String]; var deleted = false }
        var seed: UInt64 = 0x48554E543142
        func next(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(count))
        }
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let library = NotesLibraryModel(search: { try await store.searchNoteIDs(matching: $0) }, store: store)
        var expected: [UUID: Expected] = [:], order: [UUID] = []
        for index in 0..<12 {
            let value = Expected(title: "Note \(index)", body: "needle \(index)", tags: [index % 2 == 0 ? "alpha" : "beta"])
            let id = try create(store, title: value.title, body: value.body, tags: value.tags)
            order.append(id); expected[id] = value
        }
        for step in 0..<240 {
            let id = order[next(order.count)]
            var value = try XCTUnwrap(expected[id])
            switch next(4) {
            case 0 where !value.deleted:
                value.title = "Renamed \(step)"
                value.body = step % 2 == 0 ? "moved needle" : "other body"
                _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text(value.title), .text(value.body)]),
                                           baseRevisionID: store.note(withID: id)?.revisionID).get()
            case 1 where !value.deleted:
                value.tags = [next(2) == 0 ? "alpha" : "beta"]
                XCTAssertTrue(store.setTags(value.tags, for: try XCTUnwrap(store.note(withID: id))))
            case 2 where !value.deleted:
                XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id)))); value.deleted = true
            case 3 where value.deleted:
                XCTAssertTrue(store.restoreDeleted(noteID: id)); value.deleted = false
            default: break
            }
            expected[id] = value
            let filter: String? = [nil, "alpha", "beta"][next(3)]
            let query = ["", "needle", "Renamed", "alpha", "no-match"][next(5)]
            library.tagFilter = filter; library.query = query
            if !query.isEmpty { library.retry() }
            await library.waitForSearch()
            let wanted = Set(expected.compactMap { id, row -> UUID? in
                guard !row.deleted, filter.map(row.tags.contains) ?? true else { return nil }
                let searchable = row.title + " " + row.body + " " + row.tags.joined(separator: " ")
                return query.isEmpty || searchable.lowercased().contains(query.lowercased()) ? id : nil
            })
            let shown = rows(library, store)
            XCTAssertEqual(Set(shown.map(\.id)), wanted, "seeded step \(step)")
            XCTAssertEqual(shown.count, wanted.count, "never duplicate a logical note")
            for row in shown {
                let wanted = try XCTUnwrap(expected[row.id])
                XCTAssertEqual(row.title, wanted.title)
                XCTAssertEqual(row.preview, wanted.body)
            }
        }
        print("ATTIC-H1B-ORGANIZE reference steps=240 seed=0x48554E543142")
    }

    func testRetentionDeletesAllIdenticalReplicasButKeepsDivergentAndRichFamilies() throws {
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeTestNoteStore(now: { clock }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        let old = clock.addingTimeInterval(-60 * 86_400)
        let identicalID = UUID(), divergentID = UUID(), richID = UUID()
        let richTable = NoteTable(texts: [["Keep"], ["Cell"]])
        for versionID in [identicalID, divergentID, richID] {
            for index in 0..<2 {
                let rich = versionID == richID
                let title = versionID == divergentID ? "Divergent \(index)" : "Version"
                let document = NoteDocument(blocks: rich ? [.text(title), .table(richTable)] : [.text(title)])
                store.modelContext.insert(NoteVersion(id: versionID, noteID: id, createdAt: old.addingTimeInterval(versionID == identicalID ? 0 : (versionID == divergentID ? -1 : -2)), reason: .pause,
                    content: try NoteContentCodec.encode(document), contentFormat: 1, title: title, body: "",
                    attachmentIDs: [], sourceRevisionID: nil))
            }
        }
        try store.modelContext.save()
        store.thinVersions(noteID: id)
        let physical = try ModelContext(store.container).fetch(FetchDescriptor<NoteVersion>())
        XCTAssertEqual(physical.filter { $0.id == identicalID }.count, 0)
        XCTAssertEqual(physical.filter { $0.id == divergentID }.count, 2)
        XCTAssertEqual(physical.filter { $0.id == richID }.count, 2)
    }

    func testHunt2GeneratedTagsUndoRedoAndAcceptPreserveWholeDraft() async throws {
        for seed in 0..<24 {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = try create(store, tags: ["saved"]), page = await controller(store)
            XCTAssertTrue(page.open(noteID: id))
            let session = try XCTUnwrap(page.active)
            let deletion = seed % 3 == 0
            let revision = try XCTUnwrap(store.note(withID: id)).revisionToken
            let outcome = deletion
                ? store.agentDelete(noteID: id, baseRevisionToken: revision, agentName: "Agent", disposition: .proposal)
                : store.agentWrite(noteID: id, baseRevisionToken: revision,
                    document: NoteDocument(blocks: [.text("Proposed \(seed)")]), agentName: "Agent", disposition: .proposal)
            guard case let .success(.pending(proposal)) = outcome else { return XCTFail("seed=\(seed)") }
            await XCTAssertTrueAsync(await page.beginProposalReview(id: proposal))
            for step in 0..<(1 + seed % 5) {
                let previous = session.engine.tags
                let tags = ["tag\(seed)", "step\(step)"]
                session.engine.setTagsFromPicker(tags)
                let expected = session.engine.tags
                XCTAssertTrue(session.engine.history.undo())
                XCTAssertEqual(session.engine.tags, previous)
                XCTAssertTrue(session.engine.history.redo())
                XCTAssertEqual(session.engine.tags, expected)
            }
            let tags = session.engine.tags
            await XCTAssertFalseAsync(await page.acceptProposal(), "seed=\(seed): pending work needs renewed review")
            XCTAssertEqual(session.engine.tags, tags)
            await XCTAssertTrueAsync(await page.acceptProposal(), "seed=\(seed)")
            let physical = try ModelContext(store.container).fetch(FetchDescriptor<NoteItem>()).filter { $0.id == id }
            XCTAssertEqual(physical.first?.tags, tags, "seed=\(seed)")
            XCTAssertEqual(physical.first?.deletedAt != nil, deletion)
            if !deletion {
                await XCTAssertTrueAsync(await page.preserveAllDurably())
                XCTAssertEqual(page.active?.engine.tags, tags)
                XCTAssertEqual(page.active?.engine.document().title, "Proposed \(seed)")
            }
        }
    }

    func testHunt2GeneratedRestoreRevalidatesMutationsDuringWait() async throws {
        for seed in 0..<12 {
            let kind = seed % 6
            let (restored, page, session, _) = try await restoreDuringRecoveryWait { session, browser in
                switch kind {
                case 0: _ = session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0), with: NSAttributedString(string: " late\(seed)"), name: "Type")
                case 1: session.engine.setTagsFromPicker(["late\(seed)"])
                case 2: browser.selectedIndex = 1; browser.updateComparison()
                case 3: browser.showsCurrent = true
                case 4:
                    session.engine.history.beginGroup()
                    _ = session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0), with: NSAttributedString(string: " grouped"), name: "Type")
                    session.engine.setTagsFromPicker(["grouped"])
                    session.engine.history.endGroup()
                default: break // A wait alone must not reject a legitimate restore.
                }
            }
            XCTAssertEqual(restored, kind == 5, "seed=\(seed)")
            if kind != 5 { XCTAssertTrue(page.active === session, "seed=\(seed)") }
            if kind == 1 { XCTAssertEqual(session.engine.tags, ["late\(seed)"]) }
            if kind == 0 { XCTAssertTrue(session.engine.plainText.contains(" late\(seed)")) }
            await XCTAssertTrueAsync(await page.preserveAllDurably())
        }
    }


    func testH6_01StartupRetainsFailureAndRetriesTheSameLoaderWithoutFallback() throws {
        let root = ownedTemporaryDirectory(prefix: "Hunt4Startup")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("store-sentinel")
        let bytes = Data("existing store must remain".utf8)
        try bytes.write(to: file)
        var attempts = 0
        let startup = AppStartup<ModelContainer> {
            attempts += 1
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            if attempts == 1 { throw NSError(domain: "Store cannot be opened", code: 1) }
            return try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(startup.value)
        do {
            XCTAssertEqual(startup.failureMessage, "Attic could not open its local data. Try again. Your existing data is kept.")
        }
        startup.retry()
        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(startup.value)
        XCTAssertNil(startup.failureMessage)
        startup.retry()
        XCTAssertEqual(attempts, 2, "A successful startup is not opened twice")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testH6_01ActualCoordinatorRetryReopensOwnedDiskStoreWithFreshContexts() async throws {
        let root = ownedTemporaryDirectory(prefix: "Hunt4DiskStartup")
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let token = UUID().uuidString
        try Data(token.utf8).write(to: attachments.appendingPathComponent(AppRuntimeEnvironment.testAttachmentRootOwnerMarkerName))
        let suite = "H6Startup." + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let runtime = AppRuntimeEnvironment(environment: ["ATTIC_TESTING": "1", "ATTIC_TEST_DEFAULTS_SUITE": suite,
            "ATTIC_TEST_ATTACHMENT_ROOT": attachments.path, "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN": token],
            arguments: [], applicationSupportURL: root)
        let diskRoot = root.appendingPathComponent("Store", isDirectory: true)
        let initial = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: diskRoot)
        let id = UUID()
        let context = ModelContext(initial)
        context.insert(TaskItem(id: id, title: "Keep this disk task"))
        try context.save()
        var attempts = 0
        let startup = AppStartup<AppCoordinator> {
            try AppCoordinator(runtime: runtime, openStore: {
                attempts += 1
                if attempts == 1 { throw NSError(domain: "Owned store denied", code: 1) }
                return try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: diskRoot)
            })
        }
        XCTAssertNil(startup.value)
        XCTAssertNotNil(startup.failureMessage)
        XCTAssertEqual(try ModelContext(initial).fetch(FetchDescriptor<TaskItem>()).map(\.id), [id])
        startup.retry()
        let coordinator = try XCTUnwrap(startup.value)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(coordinator.store.task(withID: id)?.title, "Keep this disk task")
        XCTAssertEqual(coordinator.store.container.configurations.first?.url, initial.configurations.first?.url)
        XCTAssertFalse(coordinator.store.container === initial)
        XCTAssertFalse(coordinator.store.container.mainContext === initial.mainContext)
        XCTAssertEqual(coordinator.globalShortcutRegistration, .notRegistered)
        coordinator.start()
        XCTAssertEqual(coordinator.globalShortcutRegistration, .notRegistered, "Unit runtime must not start interactive services")
        await coordinator.noteStore.waitForAttachmentReconciliation()
        startup.retry()
        XCTAssertEqual(attempts, 2)
    }

    func testH6_02DisplayRemovalReclampsPinnedFrameEvenWhenHeightIsUnchanged() throws {
        let frame = CGRect(x: 2200, y: 100, width: 272, height: 300)
        let remaining = CGRect(x: -1000, y: 28, width: 1000, height: 720)
        let result = SubtaskPanelLayout.pinnedResizedFrame(frame, newHeight: frame.height,
            screenVisibleFrames: [remaining])
        do {
            XCTAssertNotNil(result, "Display reconciliation is independent of height changes")
        }
        if let result {
            XCTAssertTrue(remaining.insetBy(dx: 12, dy: 12).contains(result))
            XCTAssertEqual(result.size, frame.size)
            XCTAssertNil(SubtaskPanelLayout.pinnedResizedFrame(result, newHeight: result.height,
                screenVisibleFrames: [remaining]), "Reconciliation is idempotent")
        }
    }

    func testH6_03SettingsSizeFitsAWorkAreaSmallerThanItsPreferredMinimum() {
        let screen = CGRect(x: -600, y: 32, width: 600, height: 420)
        let size = SettingsWindowLayout.fittedContentSize(to: screen)
        do {
            XCTAssertLessThanOrEqual(size.width, screen.width - 48)
            XCTAssertLessThanOrEqual(size.height, screen.height - 48)
        }
    }

    func testH6_05SettingsScreenChangeRefreshesNativeLimitsWithoutMovingWindow() throws {
        let store = try makeTestStore()
        var workArea = CGRect(x: 0, y: 0, width: 600, height: 420)
        let defaults = UserDefaults(suiteName: "H6Settings." + UUID().uuidString)!
        let server = AgentServer(port: 0, bearerToken: String(repeating: "a", count: 43),
            handler: MCPRequestHandler(tools: AgentTaskTools(store: store)))
        let controller = SettingsWindowController(settings: AppSettings(defaults: defaults),
            loginItemService: LoginItemService(), agentServer: server,
            globalHotKey: GlobalHotKey(combination: .newTask), library: nil, workArea: { _ in workArea })
        let window = try XCTUnwrap(controller.window as? SettingsWindow)
        controller.fitToCurrentWorkArea(window, reposition: false)
        let compactMaximum = window.contentMaxSize
        let frame = window.frame
        workArea = CGRect(x: 600, y: 0, width: 1600, height: 1000)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        do {
            XCTAssertGreaterThan(window.contentMaxSize.width, compactMaximum.width)
            XCTAssertGreaterThan(window.contentMaxSize.height, compactMaximum.height)
        }
        XCTAssertEqual(window.frame, frame, "Dragging between displays must preserve the user's position")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testH6_04StoppedCleanupDiscardsQueuedObserverAndPreviousGeneration() async throws {
        let notifications = [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
            NSApplication.didBecomeActiveNotification, NSWorkspace.didWakeNotification]
        for name in notifications {
            for restart in [false, true] {
                let store = try makeTestStore()
                var purges = 0
                let service = DailyCleanupService(store: store, purgeRecentlyDeleted: { _, _ in purges += 1 })
                service.start()
                XCTAssertEqual(purges, 1)
                let center = name == NSWorkspace.didWakeNotification
                    ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
                center.post(name: name, object: nil)
                let queued = try XCTUnwrap(service.queuedCleanupTask)
                service.stop()
                if restart { service.start() }
                // Await the actual queued callback, rather than relying on actor scheduling/yields.
                await queued.value
                XCTAssertEqual(purges, restart ? 2 : 1, "Stopped and superseded generations do no work: \(name)")
                service.stop()
            }
        }
    }

    func testR3_09FailedProposalReadsDoNotRepeatAtTheSameRevision() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        _ = try create(store)
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        var attempts = 0
        store.auxiliaryFetchWillRead = { type in
            if type == NotePendingEdit.self {
                attempts += 1
                throw NSError(domain: "R3-read", code: 9)
            }
        }
        _ = rows(library, store)
        await Task.yield()
        XCTAssertNotNil(store.lastErrorMessage)
        store.dismissError()
        for _ in 0..<8 { _ = rows(library, store) }
        await Task.yield()
        do {
            XCTAssertEqual(attempts, 1)
            XCTAssertNil(store.lastErrorMessage, "A dismissed notice stays dismissed at this revision")
        }
        let previousAttempts = attempts
        store.refresh()
        _ = rows(library, store)
        XCTAssertEqual(attempts, previousAttempts + 1, "A new store revision retries the read")
    }

    func testR3_10HistoryReadFailureUsesOneReadableNotice() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        store.auxiliaryFetchWillRead = { type in
            if type == NoteVersion.self { throw NSError(domain: "Opaque database details", code: 10) }
        }
        await XCTAssertFalseAsync(await page.openHistoryDurably())
        do {
            XCTAssertEqual(page.active?.notice, "Version history could not be read. Try again. Your note is kept.")
            XCTAssertNil(store.lastErrorMessage, "The session notice is the single history error surface")
        }
    }

    func testH5_01FailedHistoryFetchRefusesEmptyBrowserAndRetries() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let saved = store.versions(noteID: id).map(\.id)
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        store.auxiliaryFetchWillRead = { type in
            if type == NoteVersion.self { throw NSError(domain: "H5-fetch", code: 1) }
        }
        let opened = await page.openHistoryDurably()
        do {
            XCTAssertFalse(opened, "A failed read must not be presented as empty history")
            XCTAssertNil(page.historyBrowser)
            XCTAssertNotNil(page.active?.notice)
        }
        page.closeHistory()
        store.auxiliaryFetchWillRead = nil
        await XCTAssertTrueAsync(await page.openHistoryDurably())
        XCTAssertTrue(Set(try XCTUnwrap(page.historyBrowser).entries.map(\.id)).isSuperset(of: saved))
        page.closeHistory()
    }


    func testH5_01AttachmentRestoreCannotGuessPlacementAfterFailedHistoryRead() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let bytes = Data("saved file".utf8), fileID = UUID(), noteID = UUID()
        let staged = StagedNoteAttachment(id: fileID, filename: "file.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let original = NoteDocument(blocks: [.text("Title"), .file(attachmentID: fileID, filename: "file.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count)), .text("After file")])
        _ = try store.createDocumentNote(id: noteID, document: original, staged: [staged]).get()
        let attachment = try XCTUnwrap(store.attachmentFamily(fileID).first)
        XCTAssertTrue(store.removeDocumentAttachment(fileID, noteID: noteID))
        let before = try XCTUnwrap(store.loadDocument(noteID: noteID)).content.document
        store.auxiliaryFetchWillRead = { type in
            if type == NoteVersion.self { throw NSError(domain: "H5-fetch", code: 1) }
        }
        let restored = store.restoreDocumentAttachment(attachment)
        do {
            XCTAssertFalse(restored, "An unavailable history must not be treated as absent placement")
            XCTAssertEqual(store.loadDocument(noteID: noteID)?.content.document, before)
        }
        store.auxiliaryFetchWillRead = nil
        // Retry is covered by the history repro and the area's restore tests.
    }


    func testH5_02FailOnceDuringMultipleRowsDoesNotCachePartialBadges() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let ids = try [create(store, title: "One"), create(store, title: "Two")]
        for id in ids {
            _ = try store.agentWrite(noteID: id, baseRevisionToken: try XCTUnwrap(store.note(withID: id)).revisionToken,
                document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Agent", disposition: .proposal).get()
        }
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        var attempts = 0
        store.auxiliaryFetchWillRead = { type in
            if type == NotePendingEdit.self {
                attempts += 1
                if attempts == 1 { throw NSError(domain: "H5-fetch", code: 2) }
            }
        }
        _ = rows(library, store)
        let revision = store.revision
        library.retry() // R3-09: retry explicitly; renders at a failed revision are suppressed.
        let retried = rows(library, store)
        XCTAssertEqual(store.revision, revision)
        do {
            XCTAssertEqual(retried.filter(\.hasProposal).count, 2, "A partial failed render must not be cached")
        }
    }

    func testH5_02ProposalStatusDoesNotCacheAFailedFetchAsNoProposal() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        let page = await controller(store)
        XCTAssertTrue(page.open(noteID: id))
        _ = try store.agentWrite(noteID: id, baseRevisionToken: try XCTUnwrap(store.note(withID: id)).revisionToken,
            document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Hunt agent", disposition: .proposal).get()
        let session = try XCTUnwrap(page.active)
        let revision = store.revision
        store.auxiliaryFetchWillRead = { type in
            if type == NotePendingEdit.self { throw NSError(domain: "H5-fetch", code: 2) }
        }
        _ = page.proposalAgent(for: session)
        store.auxiliaryFetchWillRead = nil
        let retried = page.proposalAgent(for: session)
        await Task.yield()
        XCTAssertEqual(store.revision, revision, "Read recovery must not require a write")
        do {
            XCTAssertEqual(retried, "Hunt agent")
            XCTAssertNotNil(store.lastErrorMessage, "The failed fetch must be reported")
        }
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
    }

    func testH5_02LibraryBadgeDoesNotCacheAFailedFetchAsNoProposal() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try create(store)
        _ = try store.agentWrite(noteID: id, baseRevisionToken: try XCTUnwrap(store.note(withID: id)).revisionToken,
            document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Hunt agent", disposition: .proposal).get()
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        let revision = store.revision
        store.auxiliaryFetchWillRead = { type in
            if type == NotePendingEdit.self { throw NSError(domain: "H5-fetch", code: 2) }
        }
        _ = rows(library, store)
        store.auxiliaryFetchWillRead = nil
        library.retry() // R3-09: a recovery read must be requested explicitly.
        let retried = try XCTUnwrap(rows(library, store).first { $0.id == id })
        await Task.yield()
        XCTAssertEqual(store.revision, revision)
        do {
            XCTAssertTrue(retried.hasProposal)
            XCTAssertNotNil(store.lastErrorMessage)
        }
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
    }

    func testHunt3FailedAttachmentMetadataReadKeepsDecodedOwnershipAndOpaqueVersionsProtected() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID(), fileID = UUID(), bytes = Data("retained bytes".utf8)
        let document = NoteDocument(blocks: [.text("Title"), .file(attachmentID: fileID, filename: "file.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count))])
        let staged = StagedNoteAttachment(id: fileID, filename: "file.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        _ = try store.createDocumentNote(id: id, document: document, staged: [staged]).get()
        let originalBytes = try XCTUnwrap(store.note(withID: id)?.content)
        store.auxiliaryFetchWillRead = { type in
            if type == NoteAttachment.self { throw NSError(domain: "Hunt3-fetch", code: 3) }
        }
        _ = try store.agentWrite(noteID: id, baseRevisionToken: try XCTUnwrap(store.note(withID: id)).revisionToken,
            document: document, agentName: "Agent", disposition: .proposal).get()
        let version = try XCTUnwrap(store.versions(noteID: id).first { $0.reason == .beforeAgentEdit })
        XCTAssertEqual(version.attachmentIDs, [], "Exercise the silent metadata fallback")
        XCTAssertEqual(version.content, originalBytes, "The exact encoded base survives the metadata failure")
        let versionOnly = NoteDocumentRetentionSnapshot(notes: [], versions: [
            .init(format: version.contentFormat, content: version.content, attachmentIDsRaw: version.attachmentIDsRaw)
        ], proposals: [])
        XCTAssertEqual(try versionOnly.attachmentIDs(), [fileID], "Version bytes alone preserve ownership")
        XCTAssertTrue(try NoteDocumentRetentionSnapshot.read(in: ModelContext(store.container)).attachmentIDs().contains(fileID))

        let opaque = NoteItem(id: id, title: "Newer writer")
        opaque.contentFormat = 2; opaque.content = Data("unsupported bytes".utf8)
        let opaqueID = UUID()
        store.stageVersion(of: opaque, reason: .beforeAgentEdit, timestamp: Date(), context: store.modelContext, id: opaqueID)
        try store.modelContext.save()
        let retained = try XCTUnwrap(store.versions(noteID: id).first { $0.id == opaqueID })
        XCTAssertEqual(retained.attachmentIDs, [])
        XCTAssertEqual(retained.content, opaque.content)
        XCTAssertFalse(NotePhysicalFamilyRetention.versionEligible([retained], noteIDs: [id], proposalBases: [], recoveryBases: []))
        XCTAssertThrowsError(try NoteDocumentRetentionSnapshot.read(in: ModelContext(store.container)).attachmentIDs())
        store.auxiliaryFetchWillRead = nil
        store.thinVersions(noteID: id)
        XCTAssertTrue(store.versions(noteID: id).contains { $0.id == opaqueID })
        XCTAssertEqual(try XCTUnwrap(store.attachmentFamily(fileID).first).payload, bytes)
    }

}

@MainActor
private final class H3BlockingJournal: NoteDraftJournaling {
    let base: NoteDraftJournal
    init(directory: URL) { base = NoteDraftJournal(directory: directory) }
    var beforeWrite: (() async -> Void)?
    var requiresAsyncIO: Bool { true }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
                      replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        await beforeWrite?()
        return try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws {
        try await base.discardOwnedDurably(noteID: noteID, claim: claim)
    }
}

/// No test here presents, orders, activates or keys a window.
@MainActor
final class PhaseXHunt5Tests: XCTestCase {
    private final class WeakProbe<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    private func field<T>(_ name: String, in owner: Any, as type: T.Type = T.self) throws -> T {
        try XCTUnwrap(Mirror(reflecting: owner).children.first { $0.label == name }?.value as? T)
    }

    func testH7_01ReleasedStoreDoesNotPermanentlyVetoSharedFileCollector() async throws {
        let files = makeTestAttachmentFileStore()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var former: NoteStore? = NoteStore(container: container, attachmentFileStore: files)
        await former?.waitForAttachmentReconciliation()
        let released = WeakProbe(former)
        former = nil
        XCTAssertNil(released.value)

        // A replacement must still protect live and unreadable ownership.
        let current = NoteStore(container: container, attachmentFileStore: files)
        await current.waitForAttachmentReconciliation()
        let bytes = Data("owned bytes".utf8)
        let id = UUID()
        let reference = AttachmentFileReference(id: id, digest: NotePayloadDigest.sha256(bytes),
            filename: "kept.txt", payload: bytes)
        let url = try await XCTUnwrapAsync(try await files.ensureMaterialized(reference))
        current.recoveryReferencedAttachmentIDs = { [id] }
        try await files.removeMaterializations([reference])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        current.recoveryReferencedAttachmentIDs = { throw PersistenceGate.Failure() }
        try await files.removeMaterializations([reference])
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Unknown live ownership remains conservative")
        current.recoveryReferencedAttachmentIDs = { [] }
        try await files.removeMaterializations([reference])
        do {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                "A dead store is not an unknown live byte owner")
        }
    }

    func testH7_01ReleasedDurableSourcesKeepDocumentsVersionsProposalsAndOpaqueDataSafe() async throws {
        let files = makeTestAttachmentFileStore()
        let formerContainer = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var former: NoteStore? = NoteStore(container: formerContainer, attachmentFileStore: files)
        await former?.waitForAttachmentReconciliation()
        let seed = ModelContext(formerContainer)
        let note = NoteItem(title: "Owner")
        let bytes = Data("durable owner".utf8)
        let id = UUID()
        let document = NoteDocument(blocks: [.text("Owner"), .file(attachmentID: id, filename: "owned.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count))])
        note.content = try NoteContentCodec.encode(document)
        seed.insert(note)
        let version = NoteVersion(noteID: note.id, createdAt: Date(), reason: .leave,
            content: note.content, contentFormat: 1, title: "Owner", body: "", attachmentIDs: [], sourceRevisionID: nil)
        let proposal = NotePendingEdit(noteID: note.id, baseRevisionToken: "base", proposedContent: try XCTUnwrap(note.content),
            agentName: "Agent", createdAt: Date())
        seed.insert(version); seed.insert(proposal)
        try seed.save()
        let released = WeakProbe(former)
        former = nil
        XCTAssertNil(released.value)
        let current = NoteStore(container: try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false),
            attachmentFileStore: files)
        await current.waitForAttachmentReconciliation()
        let reference = AttachmentFileReference(id: id, digest: NotePayloadDigest.sha256(bytes), filename: "owned.txt", payload: bytes)
        let url = try await XCTUnwrapAsync(try await files.ensureMaterialized(reference))
        for owner in 0..<3 {
            try await files.removeMaterializations([reference])
            XCTAssertEqual(try Data(contentsOf: url), bytes, "remaining durable source \(owner)")
            if owner == 0 { seed.delete(note) }
            if owner == 1 { seed.delete(version) }
            try seed.save()
        }
        proposal.proposedContent = Data("opaque future content".utf8)
        try seed.save()
        try await files.removeMaterializations([reference])
        XCTAssertEqual(try Data(contentsOf: url), bytes, "An opaque released source remains unknown")
        seed.delete(proposal); try seed.save()
        try await files.removeMaterializations([reference])
        do { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testH7_01ReleasedControllerKeepsItsDurableJournalByteAuthority() async throws {
        let files = makeTestAttachmentFileStore()
        let store = try makeTestNoteStore(attachmentFileStore: files)
        await store.waitForAttachmentReconciliation()
        let bytes = Data("recovery bytes".utf8), id = UUID()
        let staged = StagedNoteAttachment(id: id, filename: "recovery.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let document = NoteDocument(blocks: [.text("Recovery"), .file(attachmentID: id, filename: staged.filename,
            contentTypeIdentifier: staged.contentTypeIdentifier, byteCount: staged.byteCount)])
        let journal = NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H7Journal"))
        _ = try await journal.writeDurably(NoteDraftJournalEntry(noteID: UUID(), isPersisted: false, baseRevisionID: nil,
            content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: id, filename: staged.filename, contentTypeIdentifier: staged.contentTypeIdentifier,
                byteCount: staged.byteCount, digest: staged.digest)], savedAt: Date()), staged: [staged])
        var page: NotesPageController? = NotesPageController(store: store, journal: journal)
        let released = WeakProbe(page)
        page = nil
        XCTAssertNil(released.value)
        let reference = AttachmentFileReference(id: id, digest: staged.digest, filename: staged.filename, payload: bytes)
        let url = try await XCTUnwrapAsync(try await files.ensureMaterialized(reference))
        try await files.removeMaterializations([reference])
        do { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        // The red repro still has recovery bytes; no actual user data loss is claimed.
        XCTAssertEqual(try journal.entries().first?.1.first?.data, bytes)
    }

    func testH7_04ReleasedSourceReadsFreshJournalWithoutCollectingForeignStaging() async throws {
        let files = makeTestAttachmentFileStore()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var store: NoteStore? = NoteStore(container: container, attachmentFileStore: files)
        await store?.waitForAttachmentReconciliation()
        let root = ownedTemporaryDirectory(prefix: "H7FreshJournal")
        let formerJournal = NoteDraftJournal(directory: root)
        _ = try await formerJournal.readRecoveryEntries()
        var page: NotesPageController? = NotesPageController(store: try XCTUnwrap(store), journal: formerJournal)
        await page?.waitForRecoveryWork()
        let releasedPage = WeakProbe(page), releasedStore = WeakProbe(store)
        page = nil; store = nil
        XCTAssertNil(releasedPage.value); XCTAssertNil(releasedStore.value)
        let bytes = Data("new recovery owner".utf8), id = UUID()
        let staged = StagedNoteAttachment(id: id, filename: "fresh.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let document = NoteDocument(blocks: [.text("Fresh recovery"), .file(attachmentID: id, filename: staged.filename,
            contentTypeIdentifier: staged.contentTypeIdentifier, byteCount: staged.byteCount)])
        let currentJournal = NoteDraftJournal(directory: root)
        _ = try await currentJournal.writeDurably(NoteDraftJournalEntry(noteID: UUID(), isPersisted: false,
            baseRevisionID: nil, content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: id, filename: staged.filename, contentTypeIdentifier: staged.contentTypeIdentifier,
                byteCount: staged.byteCount, digest: staged.digest)], savedAt: Date()), staged: [staged])
        // Bytes admitted by another owner but not yet checkpointed must not
        // be collected as a side effect of refreshing the old authority.
        let pending = root.appendingPathComponent("staged").appendingPathComponent(UUID().uuidString)
        try bytes.write(to: pending)
        let reference = AttachmentFileReference(id: id, digest: staged.digest, filename: staged.filename, payload: bytes)
        let url = try await XCTUnwrapAsync(try await files.ensureMaterialized(reference))
        try await files.removeMaterializations([reference])
        do { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(try Data(contentsOf: pending), bytes, "A retention read must not collect another owner's staging")
        let damaged = root.appendingPathComponent(UUID().uuidString + ".json")
        try Data("damaged checkpoint".utf8).write(to: damaged)
        let extraID = UUID()
        let extra = AttachmentFileReference(id: extraID, digest: staged.digest, filename: staged.filename, payload: bytes)
        let extraURL = try await XCTUnwrapAsync(try await files.ensureMaterialized(extra))
        try await files.removeMaterializations([extra])
        do { XCTAssertTrue(FileManager.default.fileExists(atPath: extraURL.path)) }
        XCTAssertEqual(try Data(contentsOf: damaged), Data("damaged checkpoint".utf8))
        XCTAssertEqual(try Data(contentsOf: pending), bytes)
    }

    func testH7_04LiveStoreReadsFreshJournalAfterOnlyItsControllerReleases() async throws {
        let files = makeTestAttachmentFileStore()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        var store: NoteStore? = NoteStore(container: container, attachmentFileStore: files)
        await store?.waitForAttachmentReconciliation()
        let root = ownedTemporaryDirectory(prefix: "H7FreshJournal")
        let formerJournal = NoteDraftJournal(directory: root)
        _ = try await formerJournal.readRecoveryEntries()
        var page: NotesPageController? = NotesPageController(store: try XCTUnwrap(store), journal: formerJournal)
        await page?.waitForRecoveryWork()
        let releasedPage = WeakProbe(page), releasedStore = WeakProbe(store)
        page = nil
        XCTAssertNil(releasedPage.value); XCTAssertNotNil(releasedStore.value)
        let bytes = Data("new recovery owner".utf8), id = UUID()
        let staged = StagedNoteAttachment(id: id, filename: "fresh.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let document = NoteDocument(blocks: [.text("Fresh recovery"), .file(attachmentID: id, filename: staged.filename,
            contentTypeIdentifier: staged.contentTypeIdentifier, byteCount: staged.byteCount)])
        let currentJournal = NoteDraftJournal(directory: root)
        _ = try await currentJournal.writeDurably(NoteDraftJournalEntry(noteID: UUID(), isPersisted: false,
            baseRevisionID: nil, content: try NoteContentCodec.encode(document), selectionLocation: 0, selectionLength: 0,
            staged: [.init(id: id, filename: staged.filename, contentTypeIdentifier: staged.contentTypeIdentifier,
                byteCount: staged.byteCount, digest: staged.digest)], savedAt: Date()), staged: [staged])
        // Bytes admitted by another owner but not yet checkpointed must not
        // be collected as a side effect of refreshing the old authority.
        let pending = root.appendingPathComponent("staged").appendingPathComponent(UUID().uuidString)
        try bytes.write(to: pending)
        let reference = AttachmentFileReference(id: id, digest: staged.digest, filename: staged.filename, payload: bytes)
        let url = try await XCTUnwrapAsync(try await files.ensureMaterialized(reference))
        try await files.removeMaterializations([reference])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: pending), bytes, "A retention read must not collect another owner's staging")
        let damaged = root.appendingPathComponent(UUID().uuidString + ".json")
        try Data("damaged checkpoint".utf8).write(to: damaged)
        let extraID = UUID()
        let extra = AttachmentFileReference(id: extraID, digest: staged.digest, filename: staged.filename, payload: bytes)
        let extraURL = try await XCTUnwrapAsync(try await files.ensureMaterialized(extra))
        try await files.removeMaterializations([extra])
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraURL.path))
        XCTAssertEqual(try Data(contentsOf: damaged), Data("damaged checkpoint".utf8))
        XCTAssertEqual(try Data(contentsOf: pending), bytes)
        await store?.waitForAttachmentReconciliation()
        XCTAssertNotNil(store)
    }

    func testH7_02ReleasingCleanupInvalidatesItsMidnightTimer() throws {
        let store = try makeTestStore()
        for _ in 0..<12 {
            var service: DailyCleanupService? = DailyCleanupService(store: store)
            service?.start()
            let timer: Timer = try field("timer", in: XCTUnwrap(service))
            XCTAssertTrue(timer.isValid)
            let released = WeakProbe(service)
            service = nil
            XCTAssertNil(released.value)
            // Clean even the red repro's run-loop residue before leaving.
            defer { timer.invalidate() }
            do { XCTAssertFalse(timer.isValid) }
        }
    }

    func testH7_03ReleasedNotesControllerCancelsItsSaveDeadlines() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        _ = try store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Draft")])).get()
        var page: NotesPageController? = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H7Deadlines")),
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await page?.startAndWait()
        XCTAssertTrue(try XCTUnwrap(page).open(noteID: id))
        let session = try XCTUnwrap(page?.active)
        XCTAssertTrue(session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: " unsaved"), name: "Type"))
        let save: Task<Void, Never> = try field("saveTask", in: session)
        let deadline: Task<Void, Never> = try field("durabilityTask", in: session)
        await page?.waitForRecoveryWork()
        let released = WeakProbe(page)
        page = nil
        XCTAssertNil(released.value)
        defer { save.cancel(); deadline.cancel() }
        // Retain the session as a displaced editor might: its old controller
        // must not leave deadlines runnable just because that editor survives.
        do {
            XCTAssertTrue(save.isCancelled)
            XCTAssertTrue(deadline.isCancelled)
        }
        session.engine.detachView()
    }

    func testH7_03ReleasedCanvasSessionCancelsItsViewStateDeadline() throws {
        let store = try makeTestCanvasStore()
        var session: CanvasSession? = CanvasSession(store: store)
        session?.pan(byViewTranslation: CGSize(width: 12, height: -7))
        let deadline: Task<Void, Never> = try field("viewStateSaveTask", in: XCTUnwrap(session))
        let released = WeakProbe(session)
        session = nil
        XCTAssertNil(released.value)
        defer { deadline.cancel() }
        do { XCTAssertTrue(deadline.isCancelled) }
    }
}

@MainActor
extension PhaseXHunt5Tests {
    private func isolatedRuntime(_ root: URL) throws -> AppRuntimeEnvironment {
        let attachments = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let token = UUID().uuidString, suite = "H7Runtime." + UUID().uuidString
        try Data(token.utf8).write(to: attachments.appendingPathComponent(AppRuntimeEnvironment.testAttachmentRootOwnerMarkerName))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return AppRuntimeEnvironment(environment: ["ATTIC_TESTING": "1", "ATTIC_TEST_DEFAULTS_SUITE": suite,
            "ATTIC_TEST_ATTACHMENT_ROOT": attachments.path, "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN": token],
            arguments: [], applicationSupportURL: root)
    }

    func testRepeatedFailedCoordinatorOpensThenSameDiskSuccessNeverConstructEmptyFallback() async throws {
        for failures in [1, 3, 7] {
            let root = ownedTemporaryDirectory(prefix: "H7Startup"), disk = root.appendingPathComponent("Store")
            let runtime = try isolatedRuntime(root), id = UUID()
            let url = try autoreleasepool {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: disk)
                let context = ModelContext(container)
                context.insert(TaskItem(id: id, title: "Durable before startup"))
                try context.save()
                return try XCTUnwrap(container.configurations.first?.url)
            }
            let bytes = try Data(contentsOf: url)
            var attempts = 0
            let startup = AppStartup<AppCoordinator> {
                try AppCoordinator(runtime: runtime, openStore: {
                    attempts += 1
                    if attempts <= failures { throw PersistenceGate.Failure() }
                    return try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: disk)
                })
            }
            for attempt in 1...failures {
                XCTAssertEqual(attempts, attempt)
                XCTAssertNil(startup.value, "No coordinator/stores/interactive services before success")
                XCTAssertEqual(startup.failureMessage, "Attic could not open its local data. Try again. Your existing data is kept.")
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                startup.retry()
            }
            let coordinator = try XCTUnwrap(startup.value)
            XCTAssertEqual(attempts, failures + 1)
            XCTAssertNil(startup.failureMessage)
            XCTAssertEqual(coordinator.store.container.configurations.first?.url, url)
            XCTAssertEqual(coordinator.store.task(withID: id)?.title, "Durable before startup")
            coordinator.start(); coordinator.start()
            XCTAssertEqual(coordinator.globalShortcutRegistration, .notRegistered)
            let cleanup: DailyCleanupService = try field("cleanupService", in: coordinator)
            XCTAssertNil(Mirror(reflecting: cleanup).children.first { $0.label == "timer" }?.value as? Timer)
            await coordinator.noteStore.waitForAttachmentReconciliation()
            await coordinator.noteDraft.pages.waitForRecoveryWork()
            coordinator.stop()
            startup.retry()
            XCTAssertEqual(attempts, failures + 1)
        }
        var attempts = 0
        var failed: AppStartup<Int>? = AppStartup { attempts += 1; throw PersistenceGate.Failure() }
        let released = WeakProbe(failed)
        failed = nil
        XCTAssertNil(released.value, "Quitting a failed loader does not retry or retain it")
        XCTAssertEqual(attempts, 1)
        // AppDelegate's failed-startup terminateNow branch is source audited;
        // real menu/Quit delivery belongs to CI, not this headless seam.
    }

    func testRepeatedUnshownCoordinatorsReleasePanelsSettingsSessionsAndEngines() async throws {
        for _ in 0..<12 {
            let probes = try await releasedShellProbes()
            try await Task.sleep(for: .milliseconds(50))
            for (index, probe) in probes.enumerated() {
                XCTAssertNil(probe.value, "owner index=\(index)")
            }
        }
    }

    private func releasedShellProbes() async throws -> [WeakProbe<AnyObject>] {
        let root = ownedTemporaryDirectory(prefix: "H7ShellRelease")
        let coordinator = try autoreleasepool {
            try AppCoordinator(runtime: isolatedRuntime(root), openStore: {
                try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            })
        }
        XCTAssertTrue(coordinator.noteDraft.pages.newNote())
        let panel: AtticPanelController = try field("panelController", in: coordinator)
        let settings: SettingsWindowController = try field("settingsWindowController", in: coordinator)
        let probes = [WeakProbe<AnyObject>(coordinator), WeakProbe<AnyObject>(panel), WeakProbe<AnyObject>(settings),
            WeakProbe<AnyObject>(coordinator.noteDraft), WeakProbe<AnyObject>(coordinator.noteDraft.pages),
            WeakProbe<AnyObject>(coordinator.noteDraft.pages.active), WeakProbe<AnyObject>(coordinator.noteDraft.pages.active?.engine),
            WeakProbe<AnyObject>(coordinator.canvasSession), WeakProbe<AnyObject>(coordinator.subtaskPanels),
            WeakProbe<AnyObject>(coordinator.canvasEditFocus)]
        await coordinator.noteStore.waitForAttachmentReconciliation()
        await coordinator.noteDraft.pages.waitForRecoveryWork()
        coordinator.stop()
        settings.close()
        panel.panelForTesting.close()
        panel.panelForTesting.contentView = nil
        return probes
    }

    private func diskRows(_ container: ModelContainer) throws -> [String: [String]] {
        let context = ModelContext(container)
        func data(_ value: Data?) -> String { value?.base64EncodedString() ?? "nil" }
        func date(_ value: Date?) -> String { value.map { String($0.timeIntervalSince1970.bitPattern) } ?? "nil" }
        return [
            "tasks": try context.fetch(FetchDescriptor<TaskItem>()).map { "\($0.id)|\($0.title)|\($0.parentID?.uuidString ?? "nil")|\($0.statusRaw)|\($0.priorityRaw)|\(date($0.deletedAt))|\($0.tagsRaw)|\($0.deletionMembersRaw)" }.sorted(),
            "notes": try context.fetch(FetchDescriptor<NoteItem>()).map { "\($0.id)|\(data($0.content))|\($0.revisionID?.uuidString ?? "nil")|\($0.revision)|\(date($0.deletedAt))|\($0.tagsRaw)" }.sorted(),
            "attachments": try context.fetch(FetchDescriptor<NoteAttachment>()).map { "\($0.id)|\($0.noteID)|\(data($0.payload))|\($0.contentDigest)|\(date($0.deletedAt))" }.sorted(),
            "versions": try context.fetch(FetchDescriptor<NoteVersion>()).map { "\($0.id)|\($0.noteID)|\(data($0.content))|\($0.attachmentIDsRaw)" }.sorted(),
            "proposals": try context.fetch(FetchDescriptor<NotePendingEdit>()).map { "\($0.id)|\($0.noteID)|\(data($0.proposedContent))|\($0.baseRevisionToken)" }.sorted(),
            "links": try context.fetch(FetchDescriptor<ItemLink>()).map { "\($0.id)|\($0.sourceKindRaw)|\($0.sourceID)|\($0.targetKindRaw)|\($0.targetID)|\(date($0.deletedAt))" }.sorted(),
            "boards": try context.fetch(FetchDescriptor<CanvasBoardItem>()).map { "\($0.id)|\($0.name)|\($0.tombstoned)|\($0.clearGeneration)|\($0.mutationVersion)|\(date($0.deletedAt))" }.sorted(),
            "objects": try context.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).map { "\($0.id)|\($0.canvasID)|\(data($0.payload))|\($0.tombstoned)|\($0.centerX)|\($0.centerY)|\($0.mutationVersion)" }.sorted()
        ]
    }

    private func mixedDiskSequence(_ root: URL, seed: UInt64) async throws -> [String: [String]] {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root.appendingPathComponent("Store"))
        let taskGate = PersistenceGate(), noteGate = PersistenceGate(), canvasGate = PersistenceGate()
        let tasks = TaskStore(container: container, persist: taskGate.save)
        let notes = NoteStore(container: container, persist: noteGate.save, attachmentFileStore: makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
        let canvases = CanvasStore(container: container, persist: canvasGate.save)
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let task = try XCTUnwrap(tasks.create(title: "Root")), child = try XCTUnwrap(tasks.create(title: "Child", parentID: task.id))
        let noteID = UUID(), bytes = Data("file-\(seed)".utf8)
        let file = StagedNoteAttachment(id: UUID(), filename: "roundtrip.txt", contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let initial = NoteDocument(blocks: [.text("Initial"), .file(attachmentID: file.id, filename: file.filename, contentTypeIdentifier: file.contentTypeIdentifier, byteCount: file.byteCount)])
        _ = try notes.createDocumentNote(id: noteID, document: initial, staged: [file]).get()
        XCTAssertTrue(notes.recordVersion(noteID: noteID, reason: .leave))
        let originalVersion = try XCTUnwrap(notes.versions(noteID: noteID).first)
        let versionID = originalVersion.id
        let board = try XCTUnwrap(canvases.createCanvas(name: "Board"))
        _ = try XCTUnwrap(canvases.createCanvas(name: "Spare"))
        XCTAssertTrue(canvases.selectCanvas(board.id))
        let object = try XCTUnwrap(canvases.addSemanticObject(content: CanvasSemanticContent(text: "Text", color: .ink, strokeWidth: 3), transform: CanvasImageTransform(center: .zero, width: 160, height: 48, zIndex: 0)))
        let link = try XCTUnwrap(library.links.link(AtticItemRef(.task, task.id), to: AtticItemRef(.note, noteID), kind: .reference))
        let replicaContext = ModelContext(container)
        let taskReplica = TaskItem(id: task.id, title: task.title, createdAt: task.createdAt, updatedAt: task.updatedAt)
        taskReplica.listOrderVersion = task.listOrderVersion; taskReplica.manualOrder = task.manualOrder
        replicaContext.insert(taskReplica)
        let originalNote = try XCTUnwrap(notes.note(withID: noteID))
        let noteReplica = NoteItem(id: noteID, title: originalNote.title, body: originalNote.body, createdAt: originalNote.createdAt, updatedAt: originalNote.updatedAt)
        noteReplica.content = originalNote.content; noteReplica.revisionID = originalNote.revisionID; noteReplica.revision = originalNote.revision
        noteReplica.plainText = originalNote.plainText; noteReplica.fileCount = originalNote.fileCount; noteReplica.firstFileName = originalNote.firstFileName
        replicaContext.insert(noteReplica)
        let attachment = try XCTUnwrap(notes.attachmentFamily(file.id).first)
        replicaContext.insert(NoteAttachment(id: file.id, noteID: noteID, originalFilename: attachment.originalFilename, contentTypeIdentifier: attachment.contentTypeIdentifier, byteCount: attachment.byteCount, sortIndex: attachment.sortIndex, contentDigest: attachment.contentDigest, createdAt: attachment.createdAt, updatedAt: attachment.updatedAt, payload: attachment.payload))
        replicaContext.insert(CanvasBoardItem(id: board.id, name: board.name, sortIndex: board.sortIndex, clearGeneration: board.clearGeneration, mutationVersion: board.mutationVersion, createdAt: board.createdAt, updatedAt: board.updatedAt))
        let objectReplica = CanvasSemanticObjectItem(id: object.id, canvasID: board.id)
        objectReplica.payload = object.payload; objectReplica.width = object.transform.width; objectReplica.height = object.transform.height
        replicaContext.insert(objectReplica)
        replicaContext.insert(ItemLink(id: link.id, source: link.source, target: link.target, kind: link.kind, createdAt: link.createdAt))
        replicaContext.insert(NoteVersion(id: versionID, noteID: noteID, createdAt: originalVersion.createdAt,
            reason: try XCTUnwrap(originalVersion.reason), content: originalVersion.content,
            contentFormat: originalVersion.contentFormat, title: originalVersion.title, body: originalVersion.body,
            attachmentIDs: Array(originalVersion.attachmentIDs), sourceRevisionID: originalVersion.sourceRevisionID))
        try replicaContext.save()
        tasks.refresh(); notes.refresh(); canvases.refresh()
        var taskTitle = "Root", noteTitle = "Initial", boardName = "Board"
        var taskDeleted = false, noteDeleted = false, boardDeleted = false, linkDeleted = false
        var random = seed
        for cycle in 0..<2 {
            var operations = Array(0..<12)
            for index in stride(from: 11, through: 1, by: -1) {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                operations.swapAt(index, Int((random >> 32) % UInt64(index + 1)))
            }
            for operation in operations {
                let label = "seed=\(seed) cycle=\(cycle) operation=\(operation)"
                if [0, 6, 7, 8].contains(operation), taskDeleted { XCTAssertTrue(tasks.restoreDeleted(taskID: task.id), label); taskDeleted = false }
                if [1, 9, 10].contains(operation), noteDeleted { XCTAssertTrue(notes.restoreDeleted(noteID: noteID), label); noteDeleted = false }
                if [2, 8].contains(operation), boardDeleted { XCTAssertTrue(canvases.restoreCanvas(board.id), label); boardDeleted = false }
                switch operation {
                case 0, 6:
                    if operation == 6 { taskGate.shouldFail = true; XCTAssertNil(tasks.create(title: "Rolled-back task"), label); taskGate.shouldFail = false }
                    taskTitle = "Task-\(seed)-\(cycle)-\(operation)"
                    XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: task.id)), title: taskTitle), label)
                case 1:
                    noteTitle = "Note-\(seed)-\(cycle)"
                    let changed = NoteDocument(blocks: [.text(noteTitle), initial.blocks[1]])
                    _ = try notes.saveDocument(noteID: noteID, document: changed, baseRevisionID: notes.note(withID: noteID)?.revisionID).get()
                case 2:
                    boardName = "Board-\(seed)-\(cycle)"
                    XCTAssertTrue(canvases.renameCanvas(board.id, to: boardName), label)
                case 3:
                    XCTAssertTrue(taskDeleted ? tasks.restoreDeleted(taskID: task.id) : tasks.delete(taskIDs: [task.id]), label)
                    taskDeleted.toggle()
                case 4:
                    XCTAssertTrue(noteDeleted ? notes.restoreDeleted(noteID: noteID) : notes.delete(try XCTUnwrap(notes.note(withID: noteID))), label)
                    noteDeleted.toggle()
                case 5:
                    XCTAssertTrue(boardDeleted ? canvases.restoreCanvas(board.id) : canvases.deleteCanvas(board.id), label)
                    boardDeleted.toggle()
                case 7:
                    noteGate.shouldFail = true
                    if case .success = notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Rolled-back note")])) { XCTFail(label) }
                    noteGate.shouldFail = false
                    taskTitle = "After-note-rollback-\(seed)-\(cycle)"
                    XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: task.id)), title: taskTitle), label)
                case 8:
                    canvasGate.shouldFail = true
                    XCTAssertNil(canvases.createCanvas(name: "Rolled-back board"), label)
                    canvasGate.shouldFail = false
                    taskTitle = "After-board-rollback-\(seed)-\(cycle)"
                    XCTAssertTrue(tasks.update(try XCTUnwrap(tasks.task(withID: task.id)), title: taskTitle), label)
                case 9:
                    _ = try notes.restoreVersion(versionID, noteID: noteID).get(); noteTitle = "Initial"
                case 10:
                    guard case let .success(.pending(proposal)) = notes.agentWrite(noteID: noteID, baseRevisionToken: try XCTUnwrap(notes.note(withID: noteID)).revisionToken, document: NoteDocument(blocks: [.text("Proposal"), initial.blocks[1]]), agentName: "Generated", disposition: .proposal) else { XCTFail(label); throw PersistenceGate.Failure() }
                    let proposalContext = ModelContext(container)
                    let proposalID = proposal
                    let original = try XCTUnwrap(proposalContext.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.id == proposalID })).first)
                    let duplicate = NotePendingEdit(id: original.id, noteID: original.noteID,
                        baseRevisionToken: original.baseRevisionToken, proposedContent: try XCTUnwrap(original.proposedContent),
                        agentName: original.agentName, createdAt: original.createdAt, baseVersionID: original.baseVersionID)
                    duplicate.needsReview = original.needsReview; duplicate.isDeletion = original.isDeletion
                    proposalContext.insert(duplicate); try proposalContext.save()
                    if cycle == 0 {
                        XCTAssertTrue(notes.discardProposal(proposal, noteID: noteID), label)
                        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<NotePendingEdit>()), 0, label)
                    }
                default:
                    XCTAssertTrue(linkDeleted ? library.links.restoreLink(link.id) : library.links.unlink(link.id), label)
                    linkDeleted.toggle()
                }
                let check = ModelContext(container)
                let taskRows = try check.fetch(FetchDescriptor<TaskItem>())
                XCTAssertEqual(taskRows.count, 3, label)
                XCTAssertTrue(taskRows.filter { $0.id == task.id }.allSatisfy { $0.title == taskTitle && ($0.deletedAt != nil) == taskDeleted }, label)
                XCTAssertTrue(taskRows.filter { $0.id == child.id }.allSatisfy { $0.parentID == task.id && ($0.deletedAt != nil) == taskDeleted }, label)
                let noteRows = try check.fetch(FetchDescriptor<NoteItem>())
                XCTAssertEqual(noteRows.count, 2, label)
                XCTAssertTrue(noteRows.allSatisfy { $0.title == noteTitle && ($0.deletedAt != nil) == noteDeleted }, label)
                let boardRows = try check.fetch(FetchDescriptor<CanvasBoardItem>()).filter { $0.id == board.id }
                XCTAssertEqual(boardRows.count, 2, label)
                XCTAssertTrue(boardRows.allSatisfy { $0.name == boardName && $0.tombstoned == boardDeleted }, label)
                XCTAssertEqual(try check.fetchCount(FetchDescriptor<NoteAttachment>()), 2, label)
                XCTAssertEqual(try check.fetchCount(FetchDescriptor<CanvasSemanticObjectItem>()), 2, label)
                XCTAssertTrue(try check.fetch(FetchDescriptor<ItemLink>()).allSatisfy { ($0.deletedAt != nil) == linkDeleted && $0.sourceID == task.id && $0.targetID == noteID }, label)
                XCTAssertTrue(try check.fetch(FetchDescriptor<NoteVersion>()).allSatisfy { $0.noteID == noteID }, label)
                let versionIDs = Set(try check.fetch(FetchDescriptor<NoteVersion>()).map(\.id))
                XCTAssertTrue(try check.fetch(FetchDescriptor<NotePendingEdit>()).allSatisfy {
                    $0.noteID == noteID && $0.baseVersionID.map { versionIDs.contains($0) } == true
                }, label)
                XCTAssertEqual(Set(tasks.tasks.map(\.id)).count, tasks.tasks.count, label)
                XCTAssertEqual(Set(notes.notes.map(\.id)).count, notes.notes.count, label)
                XCTAssertEqual(Set(canvases.canvases.map(\.id)).count, canvases.canvases.count, label)
            }
        }
        await notes.waitForAttachmentReconciliation()
        return try diskRows(container)
    }

    func testGeneratedTasksNotesCanvasSequencesSurviveClosingAllContextsAndRelaunch() async throws {
        for seed in 1...8 {
            let root = ownedTemporaryDirectory(prefix: "H7MixedRelaunch")
            // The helper returns only value snapshots. Every context, store,
            // library, container and attachment service is out of local scope.
            let expected = try await mixedDiskSequence(root, seed: UInt64(seed))
            let reopened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root.appendingPathComponent("Store"))
            XCTAssertEqual(try diskRows(reopened), expected, "seed=\(seed)")
        }
    }
}

@MainActor
extension PhaseXHunt5Tests {
    func testH7_05EngineReleasedAfterItsPageAndSessionClose() async throws {
        let probes = try await releasedNoteProbes()
        XCTAssertNil(probes[0].value)
        XCTAssertNil(probes[1].value)
        XCTAssertNil(probes[2].value)
    }

    private func releasedNoteProbes() async throws -> [WeakProbe<AnyObject>] {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let page = NotesPageController(store: store, journal: nil)
        XCTAssertTrue(page.newNote())
        let probes = [WeakProbe<AnyObject>(page), WeakProbe<AnyObject>(page.active), WeakProbe<AnyObject>(page.active?.engine)]
        await store.waitForAttachmentReconciliation()
        await page.waitForRecoveryWork()
        return probes
    }
}

@MainActor
extension PhaseXHunt5Tests {
    func testOtherAreaRollbackAndRevisionPublishingKeepUnsavedNoteDraft() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let taskGate = PersistenceGate(), canvasGate = PersistenceGate()
        let tasks = TaskStore(container: container, persist: taskGate.save)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, persist: canvasGate.save)
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let uiState = PanelUIState()
        let note = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Saved")])).get()
        let page = NotesPageController(store: notes, journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H7Cross")),
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await XCTAssertTrueAsync(await page.openDurably(noteID: note.noteID))
        let session = try XCTUnwrap(page.active)
        session.engine.performEdit(NSRange(location: session.engine.textStorage.length, length: 0),
            with: NSAttributedString(string: " unsaved"), name: "Typing")
        let draft = session.engine.document()
        var taskRevisions = 0, noteRevisions = 0, canvasRevisions = 0
        let observations = [tasks.$revision.dropFirst().sink { _ in taskRevisions += 1 },
            notes.$revision.dropFirst().sink { _ in noteRevisions += 1 },
            canvases.$revision.dropFirst().sink { _ in canvasRevisions += 1 }]
        for index in 0..<12 {
            taskGate.shouldFail = true; XCTAssertNil(tasks.create(title: "Rollback task")); taskGate.shouldFail = false
            canvasGate.shouldFail = true; XCTAssertNil(canvases.createCanvas(name: "Rollback canvas")); canvasGate.shouldFail = false
            _ = try XCTUnwrap(tasks.create(title: "Saved task \(index)"))
            _ = try XCTUnwrap(canvases.createCanvas(name: "Saved board \(index)"))
            uiState.selectSection(index % 2 == 0 ? .tasks : .canvas)
            XCTAssertEqual(library.state(of: AtticItemRef(.note, note.noteID)), .live)
            XCTAssertEqual(session.engine.document(), draft)
            XCTAssertTrue(page.active === session)
            XCTAssertEqual(notes.note(withID: note.noteID)?.title, "Saved", "Other contexts cannot commit the editor draft")
        }
        XCTAssertGreaterThan(taskRevisions, 0); XCTAssertGreaterThan(canvasRevisions, 0)
        XCTAssertEqual(noteRevisions, 0, "Unrelated writes do not publish a Notes save")
        await XCTAssertTrueAsync(await page.preserveAllDurably())
        XCTAssertEqual(notes.note(withID: note.noteID)?.title, "Saved unsaved")
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()), 12)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CanvasBoardItem>()), 12)
        XCTAssertEqual(observations.count, 3)
        await notes.waitForAttachmentReconciliation()
    }

    func testGeneratedCleanupRestartsTimeZoneAndWakeKeepOneTimerAndOneMove() async throws {
        let notifications = [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
            NSWorkspace.didWakeNotification, NSApplication.didBecomeActiveNotification]
        for identifier in ["Europe/London", "America/New_York", "Pacific/Auckland", "Asia/Kathmandu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
            var now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 23, minute: 30)))
            let store = try makeTestStore(now: { now })
            let task = try XCTUnwrap(store.create(title: "Done")); XCTAssertTrue(store.markDone(task))
            let service = DailyCleanupService(store: store, now: { now }, calendar: { calendar })
            service.start()
            for step in 0..<24 {
                let oldTimer: Timer = try field("timer", in: service)
                let name = notifications[step % notifications.count]
                let center = name == NSWorkspace.didWakeNotification ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
                center.post(name: name, object: nil)
                let callback = try XCTUnwrap(service.queuedCleanupTask)
                if step % 3 == 0 {
                    service.stop(); XCTAssertFalse(oldTimer.isValid)
                    service.start()
                }
                now = now.addingTimeInterval(3_600)
                if step % 4 == 0 { calendar.timeZone = try XCTUnwrap(TimeZone(identifier: step % 8 == 0 ? "Pacific/Auckland" : identifier)) }
                await callback.value
                center.post(name: name, object: nil)
                await service.queuedCleanupTask?.value
                XCTAssertFalse(oldTimer.isValid)
                let current: Timer = try field("timer", in: service)
                let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
                XCTAssertEqual(current.fireDate, next)
                XCTAssertLessThanOrEqual(store.doneLog().count, 1)
            }
            XCTAssertEqual(store.doneLog().map(\.id), [task.id])
            let last: Timer = try field("timer", in: service)
            service.stop(); XCTAssertFalse(last.isValid)
            XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<TaskItem>()), 1)
        }
    }

    func testSerializedGeometryReplaysGeneratedDisplayRemovalAndRelaunch() throws {
        var random: UInt64 = 5489
        var frame = CGRect(x: 2200, y: -150, width: 272, height: 300)
        for step in 0..<192 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let screen = CGRect(x: Double(Int(random % 4000) - 2000), y: Double(Int((random >> 8) % 1500) - 750),
                width: Double(360 + (random >> 16) % 1800), height: Double(400 + (random >> 32) % 1000))
            // Persist and deserialize value geometry as a new process would;
            // the expected bounds come from the generated work area, not the helper.
            let persisted = try JSONEncoder().encode(frame)
            let restored = try JSONDecoder().decode(CGRect.self, from: persisted)
            frame = SubtaskPanelLayout.pinnedResizedFrame(restored, newHeight: 280 + CGFloat(step % 4) * 20,
                screenVisibleFrames: [screen]) ?? restored
            XCTAssertTrue(screen.insetBy(dx: 12, dy: 12).contains(frame), "step=\(step)")
            XCTAssertNil(SubtaskPanelLayout.pinnedResizedFrame(frame, newHeight: frame.height, screenVisibleFrames: [screen]))
            let size = SettingsWindowLayout.fittedContentSize(to: screen)
            let settings = SettingsWindowLayout.constrainedFrame(CGRect(origin: restored.origin, size: size), to: screen)
            XCTAssertTrue(screen.insetBy(dx: 24, dy: 24).contains(settings))
            let next = try JSONDecoder().decode(CGRect.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(SettingsWindowLayout.constrainedFrame(next, to: screen), settings)
        }
    }

    func testDeepAndMalformedUserJSONReturnsReadablePreservedErrorWithoutTrapping() {
        for depth in [32, 256, 1024, 4096] {
            let data = Data((String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)).utf8)
            guard case let .readOnly(original, reason, _) = NoteContentCodec.decode(data) else { return XCTFail("Invalid document accepted") }
            XCTAssertEqual(original, data); XCTAssertFalse(reason.message.isEmpty)
        }
        for text in ["{", String(repeating: "&", count: 4096), "{\"format\":-1,\"blocks\":[]}"] {
            let data = Data(text.utf8)
            guard case let .readOnly(original, reason, _) = NoteContentCodec.decode(data) else { return XCTFail("Malformed document accepted") }
            XCTAssertEqual(original, data); XCTAssertTrue(reason.message.contains("kept"))
        }
    }
}

@MainActor
extension PhaseXHunt5Tests {
    func testH7_04LiveCollectorRevalidatesStoreAndRecoveryRegistrationAfterSuspension() async throws {
        for replaceHook in [false, true] {
            let files = makeTestAttachmentFileStore()
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let store = NoteStore(container: container, attachmentFileStore: files)
            await store.waitForAttachmentReconciliation()
            let id = UUID(), bytes = Data("late owner".utf8)
            let reference = AttachmentFileReference(id: id, digest: NotePayloadDigest.sha256(bytes), filename: "late.txt", payload: bytes)
            let url = try await XCTUnwrapAsync(try await files.ensureMaterialized(reference))
            var changed = false
            store.recoveryReferencedAttachmentIDsDurably = { [weak store] in
                guard !changed, let store else { return [] }
                changed = true
                await Task.yield()
                if replaceHook {
                    // A newly attached controller/authority can replace the
                    // hook without changing the database revision.
                    store.recoveryReferencedAttachmentIDs = { [id] }
                } else {
                    // Imported durable ownership arrives after the worker's
                    // snapshot. Refresh replaces the stale store context.
                    let context = ModelContext(container), noteID = UUID()
                    let document = NoteDocument(blocks: [.text("Late durable owner"), .file(attachmentID: id,
                        filename: reference.filename, contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count))])
                    let note = NoteItem(id: noteID, title: "Late durable owner")
                    note.content = try NoteContentCodec.encode(document)
                    context.insert(note)
                    context.insert(NoteAttachment(id: id, noteID: noteID, originalFilename: reference.filename,
                        contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count), sortIndex: 0,
                        contentDigest: reference.digest, payload: nil))
                    try context.save()
                    store.refresh()
                }
                return []
            }
            try await files.removeMaterializations([reference])
            XCTAssertTrue(changed, "Durable recovery authority must participate")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "replaceHook=\(replaceHook)")
            await store.waitForAttachmentReconciliation()
        }
    }
}
