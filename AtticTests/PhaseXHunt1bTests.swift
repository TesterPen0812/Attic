import AppKit
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
        let canonical = try XCTUnwrap(store.note(withID: id))
        XCTAssertTrue(store.setPinned(true, noteID: id))
        let duplicate = NoteItem(id: id, title: canonical.title, body: canonical.body,
                                 createdAt: canonical.createdAt, updatedAt: canonical.updatedAt.addingTimeInterval(-60))
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
        XCTExpectFailure("H3-02") {
            XCTAssertTrue(physical.allSatisfy(\.isPinned), "Restore must preserve canonical metadata on every replica")
        }
    }

    func testH3_03MigrationPreservesAttachmentOnlyLegacyHistoryState() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try XCTUnwrap(store.create(title: "Legacy", body: "Same prose")).id
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .leave))
        let image = NoteAttachment(noteID: id, originalFilename: "added.png", contentTypeIdentifier: "public.png",
                                   byteCount: 3, sortIndex: 0, contentDigest: NotePayloadDigest.sha256(Data([1, 2, 3])), payload: Data([1, 2, 3]))
        image.inlineOffset = 0
        store.modelContext.insert(image); try store.modelContext.save()
        let snapshot = try store.legacySnapshot(noteID: id).get()
        let plan = try LegacyNoteMigration.plan(snapshot).get()
        let verified = try LegacyNoteMigration.verify(plan, roundTrip: { NoteTextKitRoundTrip.document(afterRoundTrip: $0) }).get()
        _ = try store.commitMigration(verified).get()
        let originals = store.versions(noteID: id).filter { $0.contentFormat == 0 && $0.attachmentIDs.contains(image.id) }
        XCTAssertFalse(originals.isEmpty, "Before migration must retain the current legacy attachment visibility")
    }

    func testH3_03VersionRecordingPreservesAttachmentVisibilityChanges() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = try XCTUnwrap(store.create(title: "Legacy", body: "Same prose")).id
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .leave))
        let image = NoteAttachment(noteID: id, originalFilename: "added.png", contentTypeIdentifier: "public.png",
                                   byteCount: 3, sortIndex: 0, contentDigest: NotePayloadDigest.sha256(Data([1, 2, 3])), payload: Data([1, 2, 3]))
        store.modelContext.insert(image); try store.modelContext.save()
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let withImage = try XCTUnwrap(store.versions(noteID: id).first)
        XCTAssertEqual(withImage.attachmentIDs, [image.id])
        let count = store.versions(noteID: id).count
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        XCTAssertEqual(store.versions(noteID: id).count, count, "An unchanged attachment set is already preserved")
        image.deletedAt = Date(); try store.modelContext.save()
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
