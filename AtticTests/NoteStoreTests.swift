import SwiftData
import XCTest
@testable import Attic

final class NoteStoreTests: XCTestCase {
    @MainActor
    func testDataSafetyRejectedProposalReplacementKeepsRetainedNoteAndPendingEdit() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Owner", body: "Original")?.id)
        let original = NoteDocument(blocks: [.text("Owner"), .text("Original")])
        let token = try XCTUnwrap(store.note(withID: id)?.revisionToken)
        let proposed = NoteDocument(blocks: [.text("Owner"), .text("Changed")])
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                document: proposed, agentName: "Agent", disposition: .proposal) else {
            return XCTFail("proposal fixture")
        }
        let pending = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        let signature = NoteProposalSignature(pending)
        let retained = try XCTUnwrap(store.note(withID: id))
        let beforeContent = retained.content
        reject = true
        guard case .failure = store.replaceWithProposal(pending.id, noteID: id, expectedRevision: token,
                expectedSavedContent: beforeContent, expectedProposal: signature, preserving: original) else {
            return XCTFail("a rejected replacement must fail")
        }
        XCTAssertEqual(retained.body, "Original", "failed proposal replacement cannot change a retained note")
        XCTAssertEqual(retained.revisionToken, token)
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1, "failed replacement keeps the pending proposal")
        reject = false
        guard case .success = store.replaceWithProposal(pending.id, noteID: id, expectedRevision: token,
                expectedSavedContent: beforeContent, expectedProposal: signature, preserving: original) else {
            return XCTFail("a later valid replacement must succeed")
        }
        XCTAssertEqual(store.note(withID: id)?.body, "Changed")
    }

    @MainActor
    func testDataSafetyRejectedMarkForReviewRestoresRetainedPendingEdit() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Owner", body: "Original")?.id)
        let token = try XCTUnwrap(store.note(withID: id)?.revisionToken)
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                document: NoteDocument(blocks: [.text("Owner"), .text("Proposed")]),
                agentName: "Agent", disposition: .proposal) else {
            return XCTFail("proposal fixture")
        }
        let pending = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        // The owner makes a newer edit, so the pending proposal must be marked
        // for review. Refusing that metadata save must restore the live row.
        let edited = try XCTUnwrap(store.note(withID: id))
        XCTAssertTrue(store.update(edited, body: "Owner edited"))
        reject = true
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertFalse(pending.needsReview, "rejected review flag must not remain on a retained proposal")
        reject = false
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertTrue(try XCTUnwrap(store.pendingEdits(noteID: id).first).needsReview)
    }

    @MainActor
    func testDataSafetyRejectedDeletedNoteRestoreKeepsRetainedTombstone() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let note = try XCTUnwrap(store.create(title: "Deleted", body: "Keep"))
        XCTAssertTrue(store.delete(note))
        let retained = try XCTUnwrap(store.replicasIncludingDeleted(of: note.id).first)
        XCTAssertNotNil(retained.deletedAt)
        reject = true
        XCTAssertFalse(store.restoreDeleted(noteID: note.id))
        XCTAssertNotNil(retained.deletedAt, "failed restore must keep retained deletion date")
        reject = false
        XCTAssertTrue(store.restoreDeleted(noteID: note.id))
        XCTAssertNotNil(store.note(withID: note.id))
    }

    @MainActor
    func testDataSafetyRejectedDirectAgentDeleteKeepsRetainedAttribution() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Owner", body: "Retain")?.id)
        let retained = try XCTUnwrap(store.note(withID: id))
        let token = retained.revisionToken
        reject = true
        guard case .failure = store.agentDelete(noteID: id, baseRevisionToken: token,
                agentName: "Agent", disposition: .direct) else {
            return XCTFail("a rejected agent deletion must report failure")
        }
        XCTAssertNil(retained.externalEditorName, "failed agent delete cannot leave false attribution")
        XCTAssertNil(retained.deletedAt, "failed agent delete cannot hide a retained note")
        reject = false
        guard case .success(.applied) = store.agentDelete(noteID: id, baseRevisionToken: token,
                agentName: "Agent", disposition: .direct) else {
            return XCTFail("a later successful agent delete must work")
        }
        XCTAssertNil(store.note(withID: id))
    }

    @MainActor
    func testDataSafetyRejectedPendingAgentApplyRestoresRetainedNote() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Owner", body: "Original")?.id)
        let token = try XCTUnwrap(store.note(withID: id)?.revisionToken)
        let proposed = NoteDocument(blocks: [.text("Owner"), .text("Agent changed")])
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                document: proposed, agentName: "Agent", disposition: .proposal) else {
            return XCTFail("proposal fixture must be committed")
        }
        let retained = try XCTUnwrap(store.note(withID: id))
        reject = true
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertEqual(retained.body, "Original", "failed pending edit must keep retained text")
        XCTAssertNil(retained.externalEditorName)
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
        reject = false
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 1)
        XCTAssertEqual(store.note(withID: id)?.body, "Agent changed")
    }

    @MainActor
    func testDataSafetyFailedDirectAgentNoteWriteRestoresRetainedContentAndAttribution() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Owner", body: "Original")?.id)
        let retained = try XCTUnwrap(store.note(withID: id))
        let token = retained.revisionToken
        let updated = NoteDocument(blocks: [.text("Owner"), .text("Agent changed")])
        reject = true
        guard case .failure = store.agentWrite(noteID: id, baseRevisionToken: token,
                document: updated, agentName: "Agent", disposition: .direct) else {
            return XCTFail("a rejected agent note write must report failure")
        }
        XCTAssertEqual(retained.body, "Original", "rejected agent edit cannot alter a retained note")
        XCTAssertEqual(retained.revisionToken, token)
        XCTAssertNil(retained.externalEditorName, "rejected agent edit cannot leave ghost attribution")
        reject = false
        guard case .success(.applied) = store.agentWrite(noteID: id, baseRevisionToken: token,
                document: updated, agentName: "Agent", disposition: .direct) else {
            return XCTFail("the next valid agent edit must succeed")
        }
        XCTAssertEqual(store.note(withID: id)?.body, "Agent changed")
    }

    @MainActor
    func testDataSafetyFailedVersionRestoreRestoresRetainedDocumentAndNextSave() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Owner", body: "Current")?.id)
        let current = try XCTUnwrap(store.note(withID: id))
        let version = NoteVersion(noteID: id, createdAt: Date(), reason: .pause,
            content: try NoteContentCodec.encode(NoteDocument(blocks: [.text("Owner"), .text("Earlier")])),
            contentFormat: NoteDocument.currentFormat, title: "Owner", body: "Earlier",
            attachmentIDs: [], sourceRevisionID: current.revisionID)
        store.modelContext.insert(version)
        try store.modelContext.save()
        store.refresh()
        let retained = try XCTUnwrap(store.note(withID: id))
        let token = retained.revisionToken
        reject = true
        guard case .failure = store.restoreVersion(version.id, noteID: id) else {
            return XCTFail("a rejected version restore must report failure")
        }
        XCTAssertEqual(retained.body, "Current", "a failed restore must leave the live note intact")
        XCTAssertEqual(retained.revisionToken, token)
        reject = false
        guard case .success = store.restoreVersion(version.id, noteID: id) else {
            return XCTFail("a later restore must still be permitted")
        }
        XCTAssertEqual(store.note(withID: id)?.body, "Earlier")
    }

    @MainActor
    func testDataSafetyFailedPinAndAcknowledgementRestoreRetainedMetadata() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Pinned")?.id)
        XCTAssertTrue(store.setPinned(true, noteID: id))
        let retainedPin = try XCTUnwrap(store.note(withID: id))
        reject = true
        XCTAssertFalse(store.setPinned(false, noteID: id))
        XCTAssertTrue(retainedPin.isPinned, "failed unpin must not alter the retained note")

        let external = ModelContext(container)
        let row = try XCTUnwrap(external.fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
        row.externalEditorName = "Agent"
        row.externalEditedAt = Date(timeIntervalSince1970: 1_500_000_000)
        try external.save()
        store.refresh()
        let retainedAttribution = try XCTUnwrap(store.note(withID: id))
        XCTAssertFalse(store.acknowledgeExternalEdit(noteID: id))
        XCTAssertEqual(retainedAttribution.externalEditorName, "Agent",
                       "failed acknowledgement must retain outside-edit attribution")
    }

    @MainActor
    func testDataSafetyFailedLegacyAttachmentRemoveRestoresRetainedRows() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "Attachment owner")
        seed.insert(note)
        seed.insert(NoteAttachment(noteID: note.id, originalFilename: "proof.txt", byteCount: 1,
            sortIndex: 0, contentDigest: String(repeating: "a", count: 64), payload: Data([1])))
        try seed.save()
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let retainedNote = try XCTUnwrap(store.note(withID: note.id))
        let retainedAttachment = try XCTUnwrap(store.attachments(for: note.id).first)
        let beforeTimestamp = retainedNote.updatedAt
        reject = true
        XCTAssertFalse(store.removeAttachment(retainedAttachment))
        XCTAssertEqual(retainedNote.updatedAt, beforeTimestamp,
                       "failed removal must not change the retained note's timestamp")
        XCTAssertNil(retainedAttachment.deletedAt, "failed removal must restore the retained attachment")
        let durable = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<NoteAttachment>()).first)
        XCTAssertNil(durable.deletedAt)
    }

    @MainActor
    func testDataSafetyForeignContextImportRebindsBeforeNextNoteMutation() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "External import")?.id)
        let stale = try XCTUnwrap(store.note(withID: id))
        let external = ModelContext(container)
        let imported = try XCTUnwrap(external.fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
        imported.tagsRaw = AtticTag.encode(["foreign"])
        try external.save()
        store.refresh()
        XCTAssertEqual(store.note(withID: id)?.tags, ["foreign"])
        XCTAssertFalse(store.note(withID: id) === stale, "an import must rebind presentation to a fresh context")
        XCTAssertTrue(store.setTags(["owner"], for: stale))
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
        XCTAssertEqual(saved.tags, ["owner"], "a mutation with an older handle must apply to current replicas")
    }

    @MainActor
    func testDataSafetyFailedDocumentEditDoesNotChangeRetainedNote() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Safe", body: "Original")?.id)
        let retained = try XCTUnwrap(store.note(withID: id))
        let originalRevision = retained.revisionID
        reject = true
        XCTAssertFalse(store.update(retained, body: "Must be discarded"))
        XCTAssertEqual(retained.body, "Original", "a rejected document edit cannot change a retained row")
        XCTAssertEqual(retained.revisionID, originalRevision)
        reject = false
        XCTAssertNotNil(store.create(title: "Successful later edit"))
        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
        XCTAssertEqual(persisted.body, "Original")
        XCTAssertEqual(persisted.revisionID, originalRevision)
    }

    @MainActor
    func testDataSafetyFailedTagAndDeleteSaveDoNotMutateRetainedNote() throws {
        enum Rejected: Error { case save }
        var reject = false
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container,
            persist: { context in
                if reject { throw Rejected.save }
                try context.save()
            }, attachmentFileStore: makeTestAttachmentFileStore()))
        let id = try XCTUnwrap(store.create(title: "Retain me")?.id)
        let retained = try XCTUnwrap(store.note(withID: id))
        reject = true
        XCTAssertFalse(store.setTags(["injected"], for: retained))
        XCTAssertEqual(retained.tags, [], "failed tag save must restore the retained Notes row")
        XCTAssertFalse(store.delete(try XCTUnwrap(store.note(withID: id))))
        XCTAssertNil(retained.deletedAt, "failed deletion must restore retained deletion state")
        XCTAssertEqual(store.note(withID: id)?.tags, [])
        XCTAssertNotNil(store.note(withID: id))
        reject = false
        XCTAssertNotNil(store.create(title: "Later successful save"))
        let rows = try ModelContext(container).fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.first(where: { $0.id == id })?.tags, [])
        XCTAssertNil(rows.first(where: { $0.id == id })?.deletedAt)
    }

    @MainActor
    func testB04SupersededReconciliationLogsCancellationAndKeepsNewSignature() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        var messages: [String] = []
        store.attachmentReconciliationLog = { messages.append($0) }
        let seed = ModelContext(container)
        let note = NoteItem(title: "Fixture")
        seed.insert(note)
        seed.insert(NoteAttachment(noteID: note.id, originalFilename: "fixture.txt", byteCount: 1, sortIndex: 0,
                                   contentDigest: String(repeating: "a", count: 64)))
        try seed.save()
        // Both passes are queued on this actor; refreshing cancels the first
        // before its checkCancellation, without a timing-dependent sleep.
        store.refresh()
        await store.waitForAttachmentReconciliation()
        XCTAssertEqual(messages, ["Attic attachment reconciliation cancelled"])
        let passes = store.attachmentReconciliationPasses
        store.refresh()
        await store.waitForAttachmentReconciliation()
        XCTAssertEqual(store.attachmentReconciliationPasses, passes, "the obsolete pass cannot invalidate the newer signature")
    }

    func testB09LegacyRemovalDoesNotRebuildPreferredPayloadInReplicaScan() throws {
        // A deterministic cost guard: each comparison must read only the
        // candidate payload, never fault the preferred blob again per replica.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Attic/Services/NoteStore.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func removeAttachment("))
        let end = try XCTUnwrap(source.range(of: "func recentlyDeletedAttachments()", range: start.upperBound..<source.endIndex))
        let removal = String(source[start.lowerBound..<end.lowerBound])
        let scans = try NSRegularExpression(pattern: #"contains\(where:\s*\{([^}]*)\}"#)
        let matches = scans.matches(in: removal, range: NSRange(removal.startIndex..., in: removal))
        XCTAssertFalse(matches.isEmpty, "the guard must inspect the replica comparisons")
        for match in matches {
            let body = (removal as NSString).substring(with: match.range(at: 1))
            XCTAssertFalse(body.contains("NoteAttachmentReplicaSnapshot(preferred)"), "preferred payload must be snapshotted outside the replica scan")
        }
    }

    @MainActor
    func testB09LegacyAttachmentRemovalKeepsCanonicalNoteAndAttachment() async throws {
        for equivalent in [false, true] {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let seed = ModelContext(container)
            let id = UUID(), attachmentID = UUID()
            let older = NoteItem(id: id, title: equivalent ? "A visible" : "Z older", body: "older", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
            let winner = NoteItem(id: id, title: "A visible", body: equivalent ? "older" : "winner", createdAt: older.createdAt, updatedAt: Date(timeIntervalSince1970: 3))
            if equivalent { winner.content = older.content }
            let first = NoteAttachment(id: attachmentID, noteID: id, originalFilename: "old.txt", byteCount: 1, sortIndex: 0, contentDigest: String(repeating: "a", count: 64), createdAt: older.createdAt, updatedAt: older.updatedAt, payload: Data([1]))
            let second = NoteAttachment(id: attachmentID, noteID: id, originalFilename: equivalent ? "old.txt" : "visible.txt", byteCount: 1, sortIndex: 0, contentDigest: String(repeating: equivalent ? "a" : "b", count: 64), createdAt: first.createdAt, updatedAt: winner.updatedAt, payload: equivalent ? first.payload : Data([2]))
            for row in [older, winner] { seed.insert(row) }
            for row in [first, second] { seed.insert(row) }
            try seed.save()
            let store = trackAttachmentReconciliation(of: NoteStore(container: container, now: { Date(timeIntervalSince1970: 10) }, attachmentFileStore: makeTestAttachmentFileStore()))
            let visible = try XCTUnwrap(store.notes.first)
            let attachment = try XCTUnwrap(store.attachments(for: id).first)
            XCTAssertEqual(visible.title, "A visible")
            XCTAssertTrue(store.removeAttachment(attachment))
            store.refresh()
            XCTAssertEqual(store.notes.first?.title, "A visible")
            XCTAssertEqual(store.notes.first?.body, equivalent ? "older" : "winner")
            XCTAssertEqual(store.recentlyDeletedAttachments().first?.filename, equivalent ? "old.txt" : "visible.txt")
            let fresh = ModelContext(container)
            let notes = try fresh.fetch(FetchDescriptor<NoteItem>())
            let files = try fresh.fetch(FetchDescriptor<NoteAttachment>())
            XCTAssertEqual(Set(notes.map(\.title)), equivalent ? ["A visible"] : ["A visible", "Z older"])
            XCTAssertEqual(Set(files.map(\.contentDigest)).count, equivalent ? 1 : 2)
            XCTAssertEqual(Set(notes.compactMap(\.content)), Set([older.content, winner.content].compactMap { $0 }))
            XCTAssertEqual(Set(files.compactMap(\.payload)), equivalent ? [Data([1])] : [Data([1]), Data([2])])
            XCTAssertTrue(files.allSatisfy { $0.updatedAt <= $0.deletedAt! })
            XCTAssertTrue(files.allSatisfy { $0.deletedAt == Date(timeIntervalSince1970: 10) })
            if equivalent {
                XCTAssertEqual(Set(notes.map(\.updatedAt)).count, 1)
                XCTAssertEqual(Set(files.map(\.updatedAt)).count, 1)
            }
            XCTAssertTrue(store.delete(try XCTUnwrap(store.notes.first)))
            XCTAssertEqual(store.recentlyDeletedNotes().first?.title, "A visible")
            XCTAssertTrue(store.restoreDeleted(noteID: id))
            XCTAssertEqual(store.notes.first?.title, "A visible")
            await store.waitForAttachmentReconciliation()
        }
    }

    @MainActor
    func testB09FailedLegacyAttachmentRemovalRollsBackEveryReplica() async throws {
        struct SaveFailure: Error {}
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let note = NoteItem(title: "A visible", body: "keep")
        let older = NoteItem(id: note.id, title: "Z older", body: "variant", updatedAt: note.updatedAt.addingTimeInterval(-1))
        let file = NoteAttachment(noteID: note.id, originalFilename: "visible.txt", byteCount: 1, sortIndex: 0,
                                  contentDigest: String(repeating: "a", count: 64), payload: Data([1]))
        let oldFile = NoteAttachment(id: file.id, noteID: note.id, originalFilename: "older.txt", byteCount: 1, sortIndex: 0,
                                     contentDigest: String(repeating: "b", count: 64), updatedAt: file.updatedAt.addingTimeInterval(-1), payload: Data([2]))
        for row in [note, older] { seed.insert(row) }
        for row in [file, oldFile] { seed.insert(row) }
        try seed.save()
        var failSave = false
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, persist: {
            if failSave { throw SaveFailure() }; try $0.save()
        }, attachmentFileStore: makeTestAttachmentFileStore()))
        failSave = true
        XCTAssertFalse(store.removeAttachment(try XCTUnwrap(store.attachments(for: note.id).first)))
        XCTAssertEqual(store.notes.first?.title, "A visible")
        XCTAssertEqual(store.attachments(for: note.id).first?.originalFilename, "visible.txt")
        let fresh = ModelContext(container)
        let notes = try fresh.fetch(FetchDescriptor<NoteItem>())
        let files = try fresh.fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Set(notes.map(\.updatedAt)), Set([note.updatedAt, older.updatedAt]))
        XCTAssertEqual(Set(notes.compactMap(\.content)), Set([note.content, older.content].compactMap { $0 }))
        XCTAssertEqual(Set(files.map(\.updatedAt)), Set([file.updatedAt, oldFile.updatedAt]))
        XCTAssertEqual(Set(files.compactMap(\.payload)), [Data([1]), Data([2])])
        XCTAssertTrue(files.allSatisfy { $0.deletedAt == nil })
        await store.waitForAttachmentReconciliation()
    }

    @MainActor
    func testRepresentativeStoreDirectoryIsRemovedAfterXCTestTeardown() async throws {
        var directory: URL?
        // Registered first, this check runs last: after the helper's actual
        // teardown has drained reconciliation and removed its owned root.
        addTeardownBlock {
            let root = try XCTUnwrap(directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                           "The representative store's teardown must remove its root")
        }
        let files = makeTestAttachmentFileStore()
        let root = await files.rootURL
        directory = root
        let store = try makeTestNoteStore(attachmentFileStore: files)
        XCTAssertNotNil(store.create(body: "Cleanup guard"))
        await store.waitForAttachmentReconciliation()
        try Data("owned attachment fixture".utf8).write(to: root.appendingPathComponent("guard.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testTemporaryCleanupRefusesASymlinkAndPreservesTheOtherRoot() throws {
        let source = OwnedTestTemporaryDirectory(prefix: "AtticTempSymlinkGuard")
        addTeardownBlock { try source.remove() }
        let target = ownedTemporaryDirectory(prefix: "AtticTempSentinelGuard")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("must-survive.txt")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: source.url, withDestinationURL: target)
        XCTAssertThrowsError(try source.remove())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        // Unlink the symlink this test created; leave the target to its owner.
        try FileManager.default.removeItem(at: source.url)
    }

    #if ATTIC_LOCAL_ONLY
    @MainActor
    func testLocalOnlyNotesDoNotStartDeferredCloudActivity() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let initialStatus = store.cloudSyncStatus
        XCTAssertNotNil(store.create(body: "Local save"))
        let externalContext = ModelContext(container)
        let externalNote = try XCTUnwrap(externalContext.fetch(FetchDescriptor<NoteItem>()).first)
        externalNote.body = "External change"
        try externalContext.save()
        store.handleCloudSyncEvent(CloudSyncEventUpdate(
            id: UUID(), kind: .importData, endedAt: Date(), succeeded: true, errorMessage: nil
        ))
        XCTAssertEqual(store.cloudSyncStatus, initialStatus)
        XCTAssertNil(store.remoteChangeObservation)
        XCTAssertNil(store.cloudKitEventObservation)
        XCTAssertNil(store.cloudImportRefreshTask)
        XCTAssertNil(store.exportActivityToken)
        XCTAssertNil(store.importActivityToken)
        XCTAssertNil(store.exportActivityTimeoutTask)
        XCTAssertNil(store.importActivityTimeoutTask)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.notes.first?.body, "Local save", "Deferred events cannot reload Local Notes")
        store.refresh()
        XCTAssertEqual(store.notes.first?.body, "External change", "Explicit local refresh must still replace stale contexts")
    }
    #endif

    @MainActor
    func testEmptyStoreReconciliationLeavesSeparateDefaultLikeRootUntouched() async throws {
        let parent = ownedTemporaryDirectory(prefix: "AtticNoteStoreSentinel")

        let defaultLikeRoot = parent
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Attic", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: defaultLikeRoot,
            withIntermediateDirectories: true
        )
        let sentinelURL = defaultLikeRoot.appendingPathComponent("must-survive.txt")
        let sentinelData = Data("separate app attachment root".utf8)
        try sentinelData.write(to: sentinelURL)

        let testRoot = parent
            .appendingPathComponent("XCTest", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        let fileStore = makeTestAttachmentFileStore(rootURL: testRoot)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: fileStore))

        XCTAssertTrue(store.notes.isEmpty)
        let preparationDeadline = ContinuousClock.now + .seconds(2)
        let testStagingRoot = testRoot.appendingPathComponent(".staging", isDirectory: true)
        while !FileManager.default.fileExists(atPath: testStagingRoot.path),
              ContinuousClock.now < preparationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: testStagingRoot.path),
            "The injected test root must be the root reconciled during NoteStore creation"
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelData)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: defaultLikeRoot.appendingPathComponent(".staging").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: defaultLikeRoot.appendingPathComponent("Thumbnails").path
        ))
    }

    @MainActor
    func testCreateNormalizesTitleWithoutChangingMeaningfulBodyWhitespace() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )

        XCTAssertNil(store.create(title: "   ", body: "   \n  "))
        let note = try XCTUnwrap(store.create(title: "  Meeting   notes ", body: "  Discuss\nrelease  "))

        XCTAssertEqual(note.title, "Meeting notes")
        XCTAssertEqual(note.body, "  Discuss\nrelease  ")
        XCTAssertEqual(store.notes.count, 1)
    }

    @MainActor
    func testUpdatePreservesMeaningfulBodyWhitespace() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Original"))

        XCTAssertTrue(store.update(note, body: "  Indented\ntext  "))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "  Indented\ntext  ")
    }

    @MainActor
    func testCreateAcceptsBodyWithoutTitle() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Quick jot"))

        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.body, "Quick jot")
    }

    @MainActor
    func testCreateReportsPersistenceFailureAndRollsBack() throws {
        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = try makeTestNoteStore(
            persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()
        )

        XCTAssertNil(store.create(body: "Must not disappear"))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    @MainActor
    func testUpdateRejectsEmptyTitleAndBody() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(title: "Keep", body: "me"))

        XCTAssertFalse(store.update(note, title: "   ", body: "   "))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).title, "Keep")
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "me")
    }

    @MainActor
    func testFailedSaveRestoresNote() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(
            persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Keep me"))
        gate.shouldFail = true

        XCTAssertFalse(store.update(note, body: "Changed"))
        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "Keep me")

        XCTAssertFalse(store.delete(note))
        XCTAssertEqual(store.notes.map(\.body), ["Keep me"])
    }

    @MainActor
    func testDeleteRemovesNote() throws {
        let store = try makeTestNoteStore(
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let note = try XCTUnwrap(store.create(body: "Temporary"))

        store.delete(note)
        XCTAssertTrue(store.notes.isEmpty)
    }

    @MainActor
    func testOrderedNotesNewestFirst() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestNoteStore(
            now: { clock.value },
            attachmentFileStore: makeTestAttachmentFileStore()
        )
        let older = try XCTUnwrap(store.create(body: "Older"))
        clock.value = Date(timeIntervalSince1970: 2_000)
        let newer = try XCTUnwrap(store.create(body: "Newer"))

        XCTAssertEqual(store.orderedNotes().map(\.id), [newer.id, older.id])
    }

    @MainActor
    func testRefreshSeesChangesSavedByAnotherModelContext() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))
        let externalContext = ModelContext(container)
        let externalNote = NoteItem(title: "Created elsewhere", body: "hi")

        externalContext.insert(externalNote)
        try externalContext.save()
        store.refresh()

        let imported = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(imported.id, externalNote.id)
        XCTAssertEqual(imported.title, "Created elsewhere")

        externalNote.body = "Updated elsewhere"
        externalNote.updatedAt = Date(timeIntervalSince1970: 2_000)
        try externalContext.save()
        store.refresh()

        XCTAssertEqual(try XCTUnwrap(store.notes.first).body, "Updated elsewhere")
    }

    @MainActor
    func testRefreshHidesDuplicateApplicationIDsWithoutDeletingEitherRow() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        let older = NoteItem(id: sharedID, title: "Older", body: "a", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = NoteItem(id: sharedID, title: "Newer", body: "b", updatedAt: Date(timeIntervalSince1970: 2_000))
        context.insert(older)
        context.insert(newer)
        try context.save()

        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))

        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.title, "Newer")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteItem>()), 2)
    }

    @MainActor
    func testMutationsAndDeleteApplyToEveryPhysicalDuplicate() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        let sharedID = UUID()
        // This case isolates changed-field fan-out. Unchanged metadata
        // must already agree for the later destructive purge to be safe.
        let createdAt = Date()
        seedContext.insert(NoteItem(id: sharedID, title: "Older", body: "a", createdAt: createdAt))
        seedContext.insert(NoteItem(
            id: sharedID,
            title: "Visible",
            body: "b",
            createdAt: createdAt,
            updatedAt: Date().addingTimeInterval(1)
        ))
        try seedContext.save()
        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))
        let visible = try XCTUnwrap(store.notes.first)

        XCTAssertTrue(store.update(visible, title: "Unified", body: "z"))
        var verificationContext = ModelContext(container)
        var replicas = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy { $0.title == "Unified" && $0.body == "z" })

        // Phase 0: the delete is soft and marks every replica; the purge
        // after 30 days removes every replica.
        XCTAssertTrue(store.delete(try XCTUnwrap(store.notes.first)))
        verificationContext = ModelContext(container)
        replicas = try verificationContext.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(store.purgeDeleted(before: .distantFuture), [sharedID])
        replicas = try ModelContext(container).fetch(FetchDescriptor<NoteItem>())
        XCTAssertTrue(replicas.isEmpty)
    }

    #if !ATTIC_LOCAL_ONLY
    @MainActor
    func testSuccessfulCloudImportRefreshesChangesSavedOutsideStoreContext() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        seedContext.insert(NoteItem(title: "Before iPhone update", body: "v1"))
        try seedContext.save()

        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))
        XCTAssertEqual(store.notes.map(\.body), ["v1"])

        let externalContext = ModelContext(container)
        let importedNote = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<NoteItem>()).first
        )
        importedNote.body = "Updated from iPhone"
        importedNote.updatedAt = Date()
        try externalContext.save()
        XCTAssertEqual(store.notes.map(\.body), ["v1"])

        store.handleCloudSyncEvent(CloudSyncEventUpdate(
            id: UUID(),
            kind: .importData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(store.notes.map(\.body), ["Updated from iPhone"])
    }
    #endif

    @MainActor
    func testRemoteDeletionMakesCapturedNoteReferencesNoOps() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = trackAttachmentReconciliation(of: NoteStore(
            container: container,
            attachmentFileStore: makeTestAttachmentFileStore()
        ))
        let capturedNote = try XCTUnwrap(store.create(body: "Deleted elsewhere"))
        let externalContext = ModelContext(container)
        let externalNote = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<NoteItem>()).first
        )
        externalContext.delete(externalNote)
        try externalContext.save()
        store.refresh()

        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertFalse(store.update(capturedNote, body: "Resurrected"))
        XCTAssertFalse(store.delete(capturedNote))
    }
}
