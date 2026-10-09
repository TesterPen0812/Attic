import CryptoKit
import SwiftData
import XCTest
@testable import Attic

/// The note-format store: replica writes (requirement 8), versions and
/// transactional restore (critique finding 3), agent writes (requirement 5),
/// reference-aware attachment retention, and the migration gate
/// (requirement 2, on fixtures only).
@MainActor
final class NoteDocumentStoreTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
    }

    private func document(_ title: String, _ lines: [String] = []) -> NoteDocument {
        NoteDocument(blocks: [.text(title)] + lines.map { .text($0) })
    }

    private func create(_ document: NoteDocument, staged: [StagedNoteAttachment] = []) throws -> (UUID, UUID) {
        guard case let .success(result) = store.createDocumentNote(id: UUID(), document: document, staged: staged) else {
            XCTFail("Unexpected document creation failure: \(store.lastErrorMessage ?? "unknown")")
            throw NoteDocumentStoreError.saveFailed(store.lastErrorMessage ?? "unknown")
        }
        return (result.noteID, result.revisionID)
    }

    private func rows(_ id: UUID) throws -> [NoteItem] {
        try store.modelContext.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
    }

    private func versions(_ id: UUID) -> [NoteVersion] { store.versions(noteID: id) }

    // MARK: Saves and replicas

    func testS5ReviewedProposalNeverAppliesAutomatically() throws {
        let (id, token) = try create(document("Current"))
        guard case .success = store.agentWrite(noteID: id, baseRevisionToken: token.uuidString,
            document: document("Proposed"), agentName: "Claude", disposition: .proposal) else { return XCTFail() }
        let edit = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        edit.needsReview = true
        try store.modelContext.save()
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertEqual(store.note(withID: id)?.title, "Current")
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
    }

    func testS5DeletionRejectsStaleRevisionAndDivergentPhysicalReplica() throws {
        let (id, token) = try create(document("Keep me"))
        guard case .failure(.staleRevision) = store.agentDelete(noteID: id, baseRevisionToken: "stale",
            agentName: "Claude", disposition: .direct) else { return XCTFail() }
        let copy = NoteItem(id: id, title: "Different text")
        copy.contentFormat = 1; copy.content = try NoteContentCodec.encode(document("Different text"))
        copy.revisionID = token
        store.modelContext.insert(copy)
        try store.modelContext.save()
        guard case .failure(.saveFailed) = store.agentDelete(noteID: id, baseRevisionToken: token.uuidString,
            agentName: "Claude", disposition: .direct) else { return XCTFail() }
        XCTAssertTrue(try rows(id).allSatisfy { $0.deletedAt == nil })
    }

    func testS5DivergentDeletionProposalCannotResolveAnyPhysicalReplica() throws {
        let (id, token) = try create(document("Keep me"))
        guard case let .success(.pending(editID)) = store.agentDelete(noteID: id, baseRevisionToken: token.uuidString,
            agentName: "Claude", disposition: .proposal) else { return XCTFail() }
        let first = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        let divergent = NotePendingEdit(id: editID, noteID: id, baseRevisionToken: first.baseRevisionToken,
            proposedContent: try XCTUnwrap(first.proposedContent), agentName: first.agentName,
            createdAt: first.createdAt, baseVersionID: first.baseVersionID)
        divergent.needsReview = first.needsReview
        // Same bytes, different meaning. It must not delete either replica.
        store.modelContext.insert(divergent)
        try store.modelContext.save()
        XCTAssertFalse(store.discardProposal(editID, noteID: id))
        guard case .failure = store.replaceWithProposal(editID, noteID: id, expectedRevision: token.uuidString,
            expectedSavedContent: store.note(withID: id)?.content, expectedProposal: NoteProposalSignature(first),
            preserving: document("Keep me")) else { return XCTFail() }
        XCTAssertEqual(try store.pendingEditRows(editID).count, 2)
        XCTAssertNotNil(store.note(withID: id))
    }

    func testS5ChangedProposalMeaningRefusesReplacement() throws {
        let (id, token) = try create(document("Keep me"))
        guard case let .success(.pending(editID)) = store.agentWrite(noteID: id, baseRevisionToken: token.uuidString,
            document: document("Proposed"), agentName: "Claude", disposition: .proposal) else { return XCTFail() }
        let edit = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        let signature = NoteProposalSignature(edit)
        edit.isDeletion = true
        try store.modelContext.save()
        guard case .failure = store.replaceWithProposal(editID, noteID: id, expectedRevision: token.uuidString,
            expectedSavedContent: store.note(withID: id)?.content, expectedProposal: signature,
            preserving: document("Keep me")) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Keep me")
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
    }

    func testS5AttributionIsDurableAndAcknowledgementUpdatesEveryReplica() throws {
        let (id, token) = try create(document("Current"))
        guard case .success = store.agentWrite(noteID: id, baseRevisionToken: token.uuidString,
            document: document("Outside"), agentName: "Claude", disposition: .direct) else { return XCTFail() }
        let fresh = ModelContext(store.container)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(saved.externalEditorName, "Claude")
        XCTAssertNotNil(saved.externalEditedAt)
        let duplicate = NoteItem(id: id, title: saved.title)
        duplicate.externalEditorName = "Claude"; duplicate.externalEditedAt = saved.externalEditedAt
        store.modelContext.insert(duplicate)
        try store.modelContext.save()
        XCTAssertTrue(store.acknowledgeExternalEdit(noteID: id))
        XCTAssertTrue(try rows(id).allSatisfy { $0.externalEditorName == nil && $0.externalEditedAt == nil })
    }

    func testSaveWritesEveryFieldToEveryReplica() throws {
        let (id, revision) = try create(document("Plan", ["one"]))
        // A second physical row with the same id (a CloudKit duplicate).
        let duplicate = NoteItem(id: id, title: "stale", body: "stale")
        store.modelContext.insert(duplicate)
        try store.modelContext.save()

        guard case let .success(newRevision) = store.saveDocument(noteID: id, document: document("Plan", ["one", "two"]),
                                                                   baseRevisionID: revision) else { return XCTFail() }
        let all = try rows(id)
        XCTAssertEqual(all.count, 2)
        for row in all {
            XCTAssertEqual(row.contentFormat, 1)
            XCTAssertEqual(row.revisionID, newRevision)
            XCTAssertEqual(row.title, "Plan")
            XCTAssertEqual(row.body, "one\ntwo")
            XCTAssertEqual(row.plainText, "Plan\none\ntwo")
            XCTAssertEqual(row.content, all[0].content)
            XCTAssertEqual(row.revision, all[0].revision)
        }
        // The duplicate was not at the base revision: what it held is kept.
        XCTAssertTrue(versions(id).contains { $0.reason == .replacedByDraft && $0.title == "stale" })
    }

    func testDivergentLegacyReplicasSharingARevisionAreEachPreserved() throws {
        let (id, revision) = try create(document("Original"))
        for title in ["Legacy A", "Legacy B"] {
            let replica = NoteItem(id: id, title: title, body: "different")
            replica.revisionID = revision
            store.modelContext.insert(replica)
        }
        try store.modelContext.save()
        guard case .success = store.saveDocument(noteID: id, document: document("Edited"),
                                                  baseRevisionID: revision) else { return XCTFail() }
        let saved = Set(versions(id).map(\.title))
        XCTAssertTrue(saved.isSuperset(of: ["Original", "Legacy A", "Legacy B"]))
        XCTAssertEqual(Set(try rows(id).map(\.title)), ["Edited"])
    }

    func testDivergentDocumentReplicaDoesNotRejectCanonicalSaveAndIsVersioned() throws {
        let (id, base) = try create(document("Main"))
        let other = NoteItem(id: id, title: "Other", body: "")
        other.content = try NoteContentCodec.encode(document("Other"))
        other.contentFormat = 1
        other.revisionID = UUID()
        other.revision = -1
        store.modelContext.insert(other)
        try store.modelContext.save()
        guard case let .success(next) = store.saveDocument(noteID: id, document: document("Person"),
                                                           baseRevisionID: base) else { return XCTFail() }
        XCTAssertEqual(Set(try rows(id).map(\.revisionID)), [next])
        XCTAssertEqual(Set(try rows(id).map(\.title)), ["Person"])
        XCTAssertTrue(versions(id).contains { $0.title == "Other" && $0.reason == .replacedByDraft })
    }

    func testHundredDocumentAutosavesDoNotMakeHistoryRowsOrDecodeUnchangedReplicas() throws {
        let (id, first) = try create(document("Draft"))
        var revision = first
        let decodesBefore = store.documentReplicaDecodeCount
        for number in 0..<100 {
            guard case let .success(next) = store.saveDocument(noteID: id,
                document: document("Draft \(number)"), baseRevisionID: revision) else {
                return XCTFail("Autosave \(number) failed")
            }
            revision = next
        }
        XCTAssertTrue(versions(id).isEmpty, "only pause, leave and explicit safety boundaries make snapshots")
        XCTAssertEqual(store.documentReplicaDecodeCount, decodesBefore,
                       "known bytes must not be decoded again on each save")
    }

    func testBatchAttachmentAdmissionDecodesTheBaseOnlyOnce() throws {
        let base = NoteDocument(blocks: (0..<5_000).map { .text("Line \($0)") })
        let (id, _) = try create(base)
        try store.reloadPresentation() // A cold proof, as after import/reload.
        let before = store.documentReplicaDecodeCount
        var candidate = base
        var staged: [StagedNoteAttachment] = []
        var milliseconds: [Double] = []
        for _ in 0..<8 {
            let item = stagedImage()
            staged.append(item)
            candidate.blocks.append(.image(attachmentID: item.id))
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertNil(store.attachmentAdmissionFailure(noteID: id, document: candidate, staged: staged))
            milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(store.documentReplicaDecodeCount, before + 1,
                           "Admission reuses one exact-byte proof for the complete batch")
        }
        print("NOTE_ADMISSION_5000_LINES_COLD_MS=\(milliseconds[0]) WARM_BATCH_7_MS=\(milliseconds.dropFirst().reduce(0, +))")
    }

    func testAttachmentAdmissionProofInvalidatesForBytesRevisionAndReload() throws {
        let (id, _) = try create(document("Draft"))
        let missing = NoteBlock.file(attachmentID: UUID(), filename: "missing.pdf",
                                    contentTypeIdentifier: "com.adobe.pdf", byteCount: 4)
        let imported = NoteDocument(blocks: [.text("Draft"), missing])
        let row = try XCTUnwrap(store.note(withID: id))
        row.content = try NoteContentCodec.encode(imported) // Same revision, different bytes.
        let before = store.documentReplicaDecodeCount
        XCTAssertNil(store.attachmentAdmissionFailure(noteID: id, document: imported, staged: []),
                     "A missing original keeps its exact placement after invalidating the old proof")
        XCTAssertEqual(store.documentReplicaDecodeCount, before + 1)
        row.revisionID = UUID()
        XCTAssertNil(store.attachmentAdmissionFailure(noteID: id, document: imported, staged: []))
        XCTAssertEqual(store.documentReplicaDecodeCount, before + 2)
        try store.modelContext.save()
        try store.reloadPresentation()
        XCTAssertNil(store.attachmentAdmissionFailure(noteID: id, document: imported, staged: []))
        XCTAssertEqual(store.documentReplicaDecodeCount, before + 3)
        let current = try XCTUnwrap(store.note(withID: id))
        let corrupt = Data("not JSON".utf8)
        current.content = corrupt
        XCTAssertNotNil(store.attachmentAdmissionFailure(noteID: id, document: imported, staged: []))
        XCTAssertEqual(store.documentReplicaDecodeCount, before + 4)
        XCTAssertEqual(current.content, corrupt, "Admission never repairs or overwrites corrupt bytes")
    }

    func testAttachmentBaseProofInvalidatesWhenBytesChangeWithoutARevisionChange() throws {
        let (id, revision) = try create(document("Draft"))
        let missing = NoteBlock.file(attachmentID: UUID(), filename: "missing.pdf",
                                     contentTypeIdentifier: "com.adobe.pdf", byteCount: 4)
        let imported = NoteDocument(blocks: [.text("Draft"), missing])
        let importedBytes = try NoteContentCodec.encode(imported)
        let row = try XCTUnwrap(store.note(withID: id))
        row.content = importedBytes // A malformed external writer reused the token.
        try store.modelContext.save()
        let before = store.documentReplicaDecodeCount
        var edited = imported
        edited.blocks[0].text = "Edited"
        guard case let .success(next) = store.saveDocument(noteID: id, document: edited,
                                                           baseRevisionID: revision) else {
            return XCTFail("the unchanged missing original must remain savable")
        }
        XCTAssertEqual(store.documentReplicaDecodeCount, before + 1)
        XCTAssertTrue(try store.attachmentRows(forNoteID: id).isEmpty, "no bytes are invented")
        guard case .success = store.saveDocument(noteID: id, document: document("Removed"),
                                                 baseRevisionID: next) else { return XCTFail() }
        XCTAssertTrue(versions(id).contains { $0.content == (try? NoteContentCodec.encode(edited)) },
                      "removing the placement preserves the exact displaced document")
    }

    func testCachedEditableProofCannotOverwriteCorruptBytesAtTheSameRevision() throws {
        let (id, revision) = try create(document("Draft"))
        let row = try XCTUnwrap(store.note(withID: id))
        let corrupt = Data("not JSON".utf8)
        row.content = corrupt
        try store.modelContext.save()
        guard case .failure(.readOnly) = store.saveDocument(noteID: id, document: document("Overwrite"),
                                                           baseRevisionID: revision) else { return XCTFail() }
        XCTAssertEqual(row.content, corrupt)
        XCTAssertTrue(versions(id).isEmpty)
    }

    func testLegacyAutosavesDoNotMakeHistoryRows() throws {
        let note = try XCTUnwrap(store.create(title: "Draft"))
        for number in 0..<20 {
            XCTAssertTrue(store.update(note, body: "Body \(number)"))
        }
        XCTAssertTrue(versions(note.id).isEmpty)
    }

    func testRemovedLegacyAttachmentIsPurgeableAfterOrdinaryEdits() throws {
        let note = try XCTUnwrap(store.create(title: "Legacy"))
        let row = NoteAttachment(noteID: note.id, originalFilename: "old.bin", byteCount: 1,
                                 sortIndex: 0, contentDigest: String(repeating: "a", count: 64),
                                 payload: Data([1]))
        store.modelContext.insert(row)
        try store.modelContext.save()
        for number in 0..<3 { XCTAssertTrue(store.update(note, body: "Edit \(number)")) }
        XCTAssertTrue(store.removeAttachment(row))
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 1)
        XCTAssertTrue(try store.attachmentRows(forNoteID: note.id).isEmpty)
    }

    func testStaleDocumentBaseCannotOverwriteAnAgentEdit() throws {
        let (id, base) = try create(document("Current"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.applied) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: document("Agent"), agentName: "Claude", disposition: .direct) else { return XCTFail() }
        guard case .failure(.staleRevision) = store.saveDocument(noteID: id,
            document: document("Stale draft"), baseRevisionID: base) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Agent")
    }

    func testQueuedLossyAgentProposalCannotAutoApplyToRichNote() throws {
        var rich = NoteBlock.text("Bold", style: "heading")
        rich.level = 2
        rich.marks = [NoteMark(.bold, offset: 0, length: 4)]
        let base = NoteDocument(blocks: [.text("Title"), rich])
        let (id, _) = try create(base)
        let note = try XCTUnwrap(store.note(withID: id))
        var lossy = base
        lossy.blocks[1].text = "Changed"
        lossy.blocks[1].marks = []
        guard case let .failure(.saveFailed(directReason)) = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
                                                document: lossy, agentName: "Agent", disposition: .direct) else { return XCTFail("direct") }
        XCTAssertTrue(directReason.contains("paragraph structure"))
        guard case let .failure(.saveFailed(proposalReason)) = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
                                                document: lossy, agentName: "Agent", disposition: .proposal) else { return XCTFail("proposal") }
        XCTAssertTrue(proposalReason.contains("paragraph structure"))
        let queued = NotePendingEdit(noteID: id, baseRevisionToken: note.revisionToken,
                                     proposedContent: try NoteContentCodec.encode(lossy), agentName: "Older Agent",
                                     createdAt: Date(), baseVersionID: nil)
        store.modelContext.insert(queued)
        try store.modelContext.save()
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertTrue(try XCTUnwrap(store.pendingEdits(noteID: id).first).needsReview)
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.blocks, base.blocks)
        guard case .success(.applied) = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
                                                        document: base, agentName: "Agent", disposition: .direct) else {
            return XCTFail("unchanged rich content must remain writable")
        }
    }

    func testEveryWriterRefusesAFutureReplicaWithoutMutatingTheFamily() throws {
        let (id, revision) = try create(document("Readable"))
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let versionID = try XCTUnwrap(versions(id).first?.id)
        let originalToken = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: originalToken,
                                                         document: document("Waiting"), agentName: "Agent",
                                                         disposition: .proposal) else { return XCTFail("pending fixture") }
        let future = NoteItem(id: id, title: "Future", body: "")
        future.contentFormat = 99
        future.content = Data("future bytes".utf8)
        store.modelContext.insert(future)
        try store.modelContext.save()
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        let baseline = try rows(id).map { ($0.contentFormat, $0.content, $0.title) }

        guard case .failure(.readOnly) = store.saveDocument(noteID: id, document: document("Overwrite"),
                                                            baseRevisionID: revision) else { return XCTFail("document save") }
        guard case .failure(.readOnly) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                          document: document("Agent"), agentName: "Agent",
                                                          disposition: .direct) else { return XCTFail("agent write") }
        guard case .failure(.readOnly) = store.restoreVersion(versionID, noteID: id) else {
            return XCTFail("restore")
        }
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertFalse(store.update(try XCTUnwrap(store.note(withID: id)), title: "Old writer"))
        XCTAssertEqual(try rows(id).map(\.contentFormat), baseline.map(\.0))
        XCTAssertEqual(try rows(id).map(\.content), baseline.map(\.1))
        XCTAssertEqual(try rows(id).map(\.title), baseline.map(\.2))
    }

    func testLegacyUpdateRefusesNewFormatNotesAndBumpsRevisionOnLegacyNotes() throws {
        let (id, _) = try create(document("New"))
        let note = try XCTUnwrap(store.note(withID: id))
        XCTAssertFalse(store.update(note, title: "Clobber", body: "x"))
        XCTAssertEqual(store.note(withID: id)?.title, "New")

        let legacy = try XCTUnwrap(store.create(title: "Old", body: "text"))
        XCTAssertEqual(legacy.revisionToken, NoteItem.initialRevisionToken)
        XCTAssertTrue(store.update(legacy, body: "changed"))
        let updated = try XCTUnwrap(store.note(withID: legacy.id))
        XCTAssertNotNil(updated.revisionID)
        XCTAssertEqual(updated.revision, 1)
        XCTAssertEqual(updated.plainText, "Old\nchanged")
    }

    func testFailedSaveChangesNothing() throws {
        let (id, revision) = try create(document("Plan"))
        gate.shouldFail = true
        guard case .failure = store.saveDocument(noteID: id, document: document("Changed"), baseRevisionID: revision) else {
            return XCTFail("save should fail")
        }
        gate.shouldFail = false
        XCTAssertEqual(store.note(withID: id)?.title, "Plan")
        XCTAssertEqual(store.note(withID: id)?.revisionID, revision)
    }

    func testSaveToMissingNoteFails() {
        guard case .failure(.noteMissing) = store.saveDocument(noteID: UUID(), document: document("x"), baseRevisionID: nil) else {
            return XCTFail()
        }
    }

    func testReadOnlyContentIsNeverRewritten() throws {
        let (id, _) = try create(document("Plan"))
        let newer = Data(#"{"format":9,"blocks":[{"kind":"text","text":"From the future"}]}"#.utf8)
        for row in try rows(id) { row.content = newer; row.contentFormat = 9 }
        try store.modelContext.save()
        store.refresh()
        guard case .failure(.readOnly) = store.saveDocument(noteID: id, document: document("x"), baseRevisionID: nil) else {
            return XCTFail()
        }
        let note = try XCTUnwrap(store.note(withID: id))
        XCTAssertTrue(store.setTags(["launch"], for: note))
        XCTAssertEqual(try rows(id).first?.content, newer, "metadata changes keep the bytes")
        guard case .failure(.readOnly) = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
                                                          document: document("y"), agentName: "Claude", disposition: .direct) else {
            return XCTFail()
        }
        XCTAssertEqual(try rows(id).first?.content, newer)
    }

    // MARK: Versions

    func testRecordVersionSkipsAnUnchangedRevision() throws {
        let (id, _) = try create(document("Plan"))
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .leave))
        XCTAssertEqual(versions(id).count, 1)
    }

    func testVersionThinningKeepsHourlyAndDailySnapshotsAndProposalBase() throws {
        let (id, _) = try create(document("Current"))
        let now = Date()
        func oldVersion(days: Double, minutes: Double) -> NoteVersion {
            NoteVersion(noteID: id, createdAt: now.addingTimeInterval(-days * 86_400 + minutes * 60),
                        reason: .pause, content: nil, contentFormat: 0, title: "old", body: "",
                        attachmentIDs: [], sourceRevisionID: UUID())
        }
        let hourlyFirst = oldVersion(days: 2, minutes: 0)
        hourlyFirst.createdAt = Date(timeIntervalSince1970:
            floor(hourlyFirst.createdAt.timeIntervalSince1970 / 3_600) * 3_600 + 60)
        let hourlySecond = NoteVersion(noteID: id, createdAt: hourlyFirst.createdAt.addingTimeInterval(60),
            reason: .pause, content: nil, contentFormat: 0, title: "old", body: "",
            attachmentIDs: [], sourceRevisionID: UUID())
        let dailyFirst = oldVersion(days: 8, minutes: 0)
        dailyFirst.createdAt = Date(timeIntervalSince1970:
            floor(dailyFirst.createdAt.timeIntervalSince1970 / 86_400) * 86_400 + 60)
        let dailySecond = NoteVersion(noteID: id, createdAt: dailyFirst.createdAt.addingTimeInterval(60),
            reason: .pause, content: nil, contentFormat: 0, title: "old", body: "",
            attachmentIDs: [], sourceRevisionID: UUID())
        let expired = oldVersion(days: 31, minutes: 0)
        let protected = oldVersion(days: 31, minutes: 5)
        for version in [hourlyFirst, hourlySecond, dailyFirst, dailySecond, expired, protected] {
            store.modelContext.insert(version)
        }
        store.modelContext.insert(NotePendingEdit(noteID: id, baseRevisionToken: "old",
            proposedContent: Data(), agentName: "Agent", createdAt: now, baseVersionID: protected.id))
        try store.modelContext.save()
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let retained = Set(versions(id).map(\.id))
        XCTAssertEqual(retained.intersection([hourlyFirst.id, hourlySecond.id]).count, 1)
        XCTAssertEqual(retained.intersection([dailyFirst.id, dailySecond.id]).count, 1)
        XCTAssertFalse(retained.contains(expired.id))
        XCTAssertTrue(retained.contains(protected.id))
    }

    func testVersionThinningDeletesEveryPhysicalCopyOfRemovedVersion() throws {
        let (id, _) = try create(document("Current"))
        let old = NoteVersion(noteID: id, createdAt: Date().addingTimeInterval(-40 * 86_400),
                              reason: .pause, content: nil, contentFormat: 0, title: "old", body: "",
                              attachmentIDs: [], sourceRevisionID: UUID())
        let duplicate = NoteVersion(id: old.id, noteID: id, createdAt: old.createdAt,
                                    reason: .pause, content: nil, contentFormat: 0, title: "old", body: "",
                                    attachmentIDs: [], sourceRevisionID: old.sourceRevisionID)
        store.modelContext.insert(old)
        store.modelContext.insert(duplicate)
        try store.modelContext.save()
        store.thinVersions(noteID: id)
        let physical = try store.modelContext.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.noteID == id }))
        XCTAssertTrue(physical.isEmpty)
    }

    func testUnreadableRecoveryBaseStopsVersionThinning() throws {
        let (id, _) = try create(document("Current"))
        let old = NoteVersion(noteID: id, createdAt: Date().addingTimeInterval(-40 * 86_400),
                              reason: .pause, content: nil, contentFormat: 0, title: "old", body: "",
                              attachmentIDs: [], sourceRevisionID: UUID())
        store.modelContext.insert(old)
        try store.modelContext.save()
        store.recoveryProtectedRevisionIDs = { throw NoteDocumentStoreError.invalidDocument("damaged recovery") }
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        XCTAssertTrue(versions(id).contains { $0.id == old.id })
    }

    func testF5FailedProposalRetentionScanKeepsEveryVersion() throws {
        let (id, _) = try create(document("Current"))
        let expired = NoteVersion(noteID: id, createdAt: Date().addingTimeInterval(-40 * 86_400),
            reason: .pause, content: nil, contentFormat: 0, title: "old", body: "",
            attachmentIDs: [], sourceRevisionID: UUID())
        store.modelContext.insert(expired)
        try store.modelContext.save()
        store.pendingEditRetentionRowsOverride = { _ in throw NoteDocumentStoreError.invalidDocument("fetch failed") }
        store.thinVersions(noteID: id)
        XCTAssertTrue(versions(id).contains { $0.id == expired.id })
        store.pendingEditRetentionRowsOverride = nil
        store.thinVersions(noteID: id)
        XCTAssertFalse(versions(id).contains { $0.id == expired.id })
    }

    func testF5DivergentPhysicalProposalReplicasProtectBothBaseVersions() throws {
        let (id, _) = try create(document("Current"))
        let first = NoteVersion(noteID: id, createdAt: Date().addingTimeInterval(-40 * 86_400),
            reason: .pause, content: nil, contentFormat: 0, title: "first", body: "",
            attachmentIDs: [], sourceRevisionID: UUID())
        let second = NoteVersion(noteID: id, createdAt: Date().addingTimeInterval(-39 * 86_400),
            reason: .pause, content: nil, contentFormat: 0, title: "second", body: "",
            attachmentIDs: [], sourceRevisionID: UUID())
        let proposalID = UUID()
        for version in [first, second] { store.modelContext.insert(version) }
        for version in [first, second] {
            store.modelContext.insert(NotePendingEdit(id: proposalID, noteID: id,
                baseRevisionToken: "old", proposedContent: Data(), agentName: "Agent",
                createdAt: Date(), baseVersionID: version.id))
        }
        try store.modelContext.save()
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1, "presentation deduplicates the proposal UUID")
        store.thinVersions(noteID: id)
        XCTAssertTrue(Set(versions(id).map(\.id)).isSuperset(of: [first.id, second.id]))
    }

    func testStepBackRecoveryProtectedNonRepresentativeKeepsWholeVersionFamily() throws {
        let (id, revision) = try create(document("Current"))
        let sharedID = UUID()
        let protectedRevision = UUID()
        let selected = NoteVersion(id: sharedID, noteID: id,
            createdAt: Date().addingTimeInterval(-39 * 86_400), reason: .pause,
            content: nil, contentFormat: 0, title: "newer", body: "",
            attachmentIDs: [], sourceRevisionID: UUID())
        let protected = NoteVersion(id: sharedID, noteID: id,
            createdAt: Date().addingTimeInterval(-40 * 86_400), reason: .pause,
            content: nil, contentFormat: 0, title: "protected", body: "",
            attachmentIDs: [], sourceRevisionID: protectedRevision)
        store.modelContext.insert(selected)
        store.modelContext.insert(protected)
        try store.modelContext.save()
        store.recoveryProtectedRevisionIDs = { Set([protectedRevision]) }
        store.thinVersions(noteID: id)
        let physical = try store.modelContext.fetch(FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.id == sharedID }))
        XCTAssertEqual(Set(physical.map(\.title)), ["newer", "protected"])
        guard case .success = store.saveDocument(noteID: id, document: document("Edited"),
            baseRevisionID: revision) else { return XCTFail("retention must not block an ordinary save") }
    }

    func testStepBackVersionThinningKeepsCrossNotePhysicalFamily() throws {
        let (id, revision) = try create(document("Current"))
        let (otherID, _) = try create(document("Other"))
        let sharedID = UUID()
        for (noteID, title) in [(id, "target"), (otherID, "other")] {
            store.modelContext.insert(NoteVersion(id: sharedID, noteID: noteID,
                createdAt: Date().addingTimeInterval(-40 * 86_400), reason: .pause,
                content: nil, contentFormat: 0, title: title, body: "",
                attachmentIDs: [], sourceRevisionID: UUID()))
        }
        try store.modelContext.save()
        store.thinVersions(noteID: id)
        let physical = try store.modelContext.fetch(FetchDescriptor<NoteVersion>(
            predicate: #Predicate { $0.id == sharedID }))
        XCTAssertEqual(Set(physical.map(\.title)), ["target", "other"])
        guard case .success = store.saveDocument(noteID: id, document: document("Edited"),
            baseRevisionID: revision) else { return XCTFail("unknown family must not block an ordinary save") }
    }

    func testStepBackPhysicalFamilyInvariantKeepsProtectedAndUnknownReplicas() throws {
        let cases: [([NotePhysicalFamilyRetention.Decision], Bool)] = [
            ([], false), ([.eligible], true), ([.eligible, .eligible], true),
            ([.eligible, .protected], false), ([.eligible, .unknown], false),
            ([.unknown, .eligible], false)
        ]
        for (family, expected) in cases {
            XCTAssertEqual(NotePhysicalFamilyRetention.mayDelete(family, decision: { $0 }), expected)
        }
        let (id, revision) = try create(document("Current"))
        guard case .success = store.saveDocument(noteID: id, document: document("Still saveable"),
            baseRevisionID: revision) else { return XCTFail("unknown retention must not block text save") }
    }

    /// Family-retention invariant: every destructive store operation keeps a
    /// complete physical family when any member is protected, divergent or
    /// unreadable, deletes an agreeing unprotected family, and never blocks an
    /// ordinary save.
    func testPhysicalFamilyInvariantEveryDestructiveOperationKeepsProtectedOrUnknownFamilies() throws {
        func bytes(_ text: String) -> StagedNoteAttachment {
            let data = Data(text.utf8)
            return StagedNoteAttachment(id: UUID(), filename: "\(text).pdf", contentTypeIdentifier: "com.adobe.pdf",
                byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                data: data)
        }
        func fileBlock(_ item: StagedNoteAttachment) -> NoteBlock {
            .file(attachmentID: item.id, filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier,
                  byteCount: item.byteCount)
        }
        func physicalVersions(_ id: UUID) throws -> [NoteVersion] {
            try store.modelContext.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.id == id }))
        }
        func physicalAttachments(_ id: UUID) throws -> [NoteAttachment] {
            try store.modelContext.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == id }))
        }
        let removed = bytes("removed"), divergent = bytes("divergent")
        let (id, firstRevision) = try create(NoteDocument(blocks: [.text("Current"), fileBlock(removed),
                                                                   fileBlock(divergent)]), staged: [removed, divergent])
        var revision = firstRevision
        func ordinarySave(_ step: String) {
            guard case let .success(next) = store.saveDocument(noteID: id, document: document("Current", [step]),
                baseRevisionID: revision) else { return XCTFail("\(step): an ordinary save must succeed") }
            revision = next
        }

        // Version thinning: agreeing, protected, divergent and unreadable families.
        let old = Date().addingTimeInterval(-40 * 86_400)
        let protectedRevision = UUID()
        let agreeing = UUID(), protected = UUID(), split = UUID(), unread = UUID()
        // Distinct instants: same-instant families are kept together.
        for (offset, (family, sources, contents)) in [
            (agreeing, [UUID?.none, nil], [Data?.none, nil]),
            (protected, [protectedRevision, protectedRevision], [nil, nil]),
            (split, [nil, nil], [nil, Data("other".utf8)]),
        ].enumerated() {
            for index in 0..<2 {
                store.modelContext.insert(NoteVersion(id: family, noteID: id,
                    createdAt: old.addingTimeInterval(-Double(offset) * 60), reason: .pause,
                    content: contents[index], contentFormat: 0, title: "v", body: "", attachmentIDs: [],
                    sourceRevisionID: sources[index]))
            }
        }
        try store.modelContext.save()
        store.recoveryProtectedRevisionIDs = { [protectedRevision] }
        store.thinVersions(noteID: id)
        XCTAssertTrue(try physicalVersions(agreeing).isEmpty, "an agreeing unprotected family is thinned")
        XCTAssertEqual(try physicalVersions(protected).count, 2, "a protected family is kept whole")
        XCTAssertEqual(try physicalVersions(split).count, 2, "a divergent family is kept whole")
        for _ in 0..<2 {
            store.modelContext.insert(NoteVersion(id: unread, noteID: id, createdAt: old, reason: .pause,
                content: nil, contentFormat: 0, title: "v", body: "", attachmentIDs: [], sourceRevisionID: nil))
        }
        try store.modelContext.save()
        store.recoveryProtectedRevisionIDs = { throw CocoaError(.fileReadCorruptFile) }
        store.thinVersions(noteID: id)
        XCTAssertEqual(try physicalVersions(unread).count, 2, "unreadable recovery ownership keeps history")
        ordinarySave("after thinning, files removed")

        // Attachment expiry: a divergent removed file and an unreadable scan.
        let removedRow = try XCTUnwrap(physicalAttachments(divergent.id).first)
        store.modelContext.insert(NoteAttachment(id: divergent.id, noteID: id, originalFilename: divergent.filename,
            contentTypeIdentifier: divergent.contentTypeIdentifier, byteCount: 5, sortIndex: 9,
            contentDigest: "different", createdAt: removedRow.createdAt, updatedAt: removedRow.updatedAt,
            payload: Data("other".utf8)))
        try physicalAttachments(divergent.id).forEach { $0.deletedAt = removedRow.deletedAt }
        // The displaced version that still shows both files has expired.
        for version in try store.modelContext.fetch(FetchDescriptor<NoteVersion>())
        where !Set(version.attachmentIDs).isDisjoint(with: [removed.id, divergent.id]) {
            store.modelContext.delete(version)
        }
        try store.modelContext.save()
        store.recoveryReferencedAttachmentIDs = { throw CocoaError(.fileReadCorruptFile) }
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 0, "an unreadable scan purges nothing")
        store.recoveryReferencedAttachmentIDs = { [] }
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 0,
            "unknown historical document ownership keeps even an agreeing byte family")
        XCTAssertEqual(try physicalAttachments(removed.id).count, 1)
        // Simulate the owner resolving the malformed legacy content. The
        // original agreeing/divergent-family deletion assertions still apply
        // once the complete historical inventory is knowable.
        for version in try physicalVersions(split) { version.content = nil }
        try store.modelContext.save()
        XCTAssertEqual(store.purgeRemovedAttachments(before: .distantFuture), 1, "only the agreeing file is purged")
        XCTAssertTrue(try physicalAttachments(removed.id).isEmpty)
        XCTAssertEqual(try physicalAttachments(divergent.id).count, 2, "the divergent file family is kept whole")
        ordinarySave("after attachment expiry")

        // Recently Deleted expiry: an unreadable scan and a history family
        // shared with a live note (history removal decides whole families).
        let kept = bytes("kept")
        let (deletedID, _) = try create(NoteDocument(blocks: [.text("Doomed"), fileBlock(kept)]), staged: [kept])
        let shared = UUID()
        for noteID in [deletedID, id] {
            store.modelContext.insert(NoteVersion(id: shared, noteID: noteID, createdAt: old, reason: .pause,
                content: nil, contentFormat: 0, title: "shared", body: "", attachmentIDs: [], sourceRevisionID: nil))
        }
        try store.modelContext.save()
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: deletedID))))
        store.recoveryReferencedAttachmentIDs = { throw CocoaError(.fileReadCorruptFile) }
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty, "an unreadable scan purges nothing")
        store.recoveryReferencedAttachmentIDs = { [] }
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty, "a shared history family keeps the note")
        XCTAssertEqual(try physicalVersions(shared).count, 2)
        XCTAssertEqual(try physicalAttachments(kept.id).first?.payload, Data("kept".utf8))
        ordinarySave("after deleted-note expiry")

        // Proposal application: a divergent proposal family neither applies
        // nor loses a replica.
        let proposal = UUID()
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        for content in [try NoteContentCodec.encode(document("Agent A")), try NoteContentCodec.encode(document("Agent B"))] {
            store.modelContext.insert(NotePendingEdit(id: proposal, noteID: id, baseRevisionToken: token,
                proposedContent: content, agentName: "Agent", createdAt: Date()))
        }
        try store.modelContext.save()
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertEqual(try store.modelContext.fetch(FetchDescriptor<NotePendingEdit>(
            predicate: #Predicate { $0.id == proposal })).count, 2)
        ordinarySave("after proposals")
    }

    func testStepBackDeletedNotePurgeKeepsSharedPhysicalHistoryFamilyAndBytes() throws {
        let data = Data("retained bytes".utf8)
        let item = StagedNoteAttachment(id: UUID(), filename: "proof.pdf", contentTypeIdentifier: "com.adobe.pdf",
            byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            data: data)
        let withFile = NoteDocument(blocks: [.text("Delete"), .file(attachmentID: item.id,
            filename: item.filename, contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        let (deletedID, _) = try create(withFile, staged: [item])
        let (otherID, otherRevision) = try create(document("Other"))
        let familyID = UUID()
        for noteID in [deletedID, otherID] {
            store.modelContext.insert(NoteVersion(id: familyID, noteID: noteID,
                createdAt: Date().addingTimeInterval(-40 * 86_400), reason: .pause,
                content: nil, contentFormat: 0, title: "shared", body: "", attachmentIDs: [],
                sourceRevisionID: UUID()))
        }
        try store.modelContext.save()
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: deletedID))))
        XCTAssertTrue(store.purgeDeleted(before: .distantFuture).isEmpty,
            "a version UUID shared with a live note prevents partial history deletion")
        XCTAssertEqual(try store.attachmentRows(forNoteID: deletedID).first?.payload, data)
        XCTAssertEqual(try store.replicasIncludingDeleted(of: deletedID).count, 1)
        guard case .success = store.saveDocument(noteID: otherID, document: document("Other edited"),
            baseRevisionID: otherRevision) else { return XCTFail("retention must not block the live note save") }
    }

    func testStepBackDivergentProposalFamilyCannotPartiallyApply() throws {
        let (id, revision) = try create(document("Base"))
        let (otherID, _) = try create(document("Other"))
        let proposalID = UUID()
        let proposed = try NoteContentCodec.encode(document("Agent change"))
        for noteID in [id, otherID] {
            store.modelContext.insert(NotePendingEdit(id: proposalID, noteID: noteID,
                baseRevisionToken: try XCTUnwrap(store.note(withID: id)).revisionToken,
                proposedContent: proposed, agentName: "Agent", createdAt: Date()))
        }
        try store.modelContext.save()
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertEqual(try store.modelContext.fetch(FetchDescriptor<NotePendingEdit>(
            predicate: #Predicate { $0.id == proposalID })).count, 2)
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.title, "Base")
        guard case .success = store.saveDocument(noteID: id, document: document("Manual"),
            baseRevisionID: revision) else { return XCTFail("ordinary save remains available") }
    }

    func testRestoreIsTransactional() throws {
        let (id, first) = try create(document("First"))
        store.recordVersion(noteID: id, reason: .pause)
        let version = try XCTUnwrap(versions(id).first)
        guard case .success = store.saveDocument(noteID: id, document: document("Second"), baseRevisionID: first) else {
            return XCTFail()
        }
        // Failure injection: neither the preserving version nor the restore lands.
        gate.shouldFail = true
        guard case .failure = store.restoreVersion(version.id, noteID: id) else { return XCTFail() }
        gate.shouldFail = false
        XCTAssertEqual(store.note(withID: id)?.title, "Second")
        XCTAssertEqual(versions(id).count, 1)

        guard case .success = store.restoreVersion(version.id, noteID: id) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "First")
        XCTAssertTrue(versions(id).contains { $0.reason == .beforeRestore && $0.title == "Second" })
        guard case .failure(.versionMissing) = store.restoreVersion(UUID(), noteID: id) else { return XCTFail() }
    }

    func testAgentWritesAndProposalsPreserveTheOrderedPlainChecklistInventory() throws {
        var first = NoteBlock.checklist("Pay rent", checked: true)
        first.extras = ["owner": .string("person")]
        let second = NoteBlock.checklist("Call bank")
        let base = NoteDocument(blocks: [.text("Bills"), first, .text("Between"), second])
        let (id, _) = try create(base)
        let token = try XCTUnwrap(store.note(withID: id)?.revisionToken)
        var flattened = base; flattened.blocks[1] = .text("Pay rent")
        var duplicate = base; var extra = first; extra.id = UUID(); duplicate.blocks.append(extra)
        var reordered = base; reordered.blocks.swapAt(1, 3)
        var renamed = base; renamed.blocks[1].text = "Different"
        var changedMetadata = base; changedMetadata.blocks[1].extras = [:]
        for proposed in [flattened, duplicate, reordered, renamed, changedMetadata] {
            for disposition in [NoteAgentWriteDisposition.direct, .proposal] {
                guard case .failure = store.agentWrite(noteID: id, baseRevisionToken: token,
                    document: proposed, agentName: "Agent", disposition: disposition) else {
                    return XCTFail("lossy checklist accepted")
                }
                XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, base)
                XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
            }
        }
        for body in ["Pay rent\nBetween\n- [ ] Call bank",
                     "- [x] Pay rent\nBetween\n- [ ] Call bank\n- [x] Pay rent"] {
            XCTAssertThrowsError(try NoteAgentTextParser.document(title: "Bills", body: body, base: base))
        }
        var checked = base; checked.blocks[1].checked = false; checked.blocks[3].checked = true
        let parsed = try NoteAgentTextParser.document(title: "Bills", body: "- [ ] Pay rent\nBetween\n- [x] Call bank", base: base)
        XCTAssertEqual(parsed, checked)
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: parsed, agentName: "Agent", disposition: .proposal) else { return XCTFail("checked proposal") }
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 1)
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, checked)
        let currentToken = try XCTUnwrap(store.note(withID: id)?.revisionToken)
        guard case .success = store.agentWrite(noteID: id, baseRevisionToken: currentToken,
            document: base, agentName: "Agent", disposition: .direct) else { return XCTFail("checked direct") }
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, base)
    }

    func testAgentChecklistRemovalAndAdditionKeepRemainingItemsForDirectWritesAndProposals() throws {
        for disposition in [NoteAgentWriteDisposition.direct, .proposal] {
            for protectedRemoval in [false, true] {
                var first = NoteBlock.checklist("Remove me")
                if protectedRemoval { first.extras = ["owner": .string("person")] }
                var kept = NoteBlock.checklist("Keep me", checked: true)
                kept.marks = [NoteMark(.bold, offset: 0, length: 4)]
                var base = NoteDocument(blocks: [.text("Title"), first, kept])
                base.refreshRequiredCapabilities()
                let (id, _) = try create(base)
                var token = try XCTUnwrap(store.note(withID: id)?.revisionToken)
                let body = "- [x] Keep me\n- [ ] New item"
                if protectedRemoval {
                    XCTAssertThrowsError(try NoteAgentTextParser.document(title: "Title", body: body, base: base)) {
                        XCTAssertEqual($0 as? NoteAgentTextError, .unsafeChecklist)
                    }
                    XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, base)
                    XCTAssertEqual(store.note(withID: id)?.revisionToken, token)
                    XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
                    // Deleting the metadata-bearing item outright is still safe.
                    let removed = try NoteAgentTextParser.document(title: "Title", body: "- [x] Keep me", base: base)
                    var expected = base
                    expected.blocks.remove(at: 1)
                    expected.refreshRequiredCapabilities()
                    XCTAssertEqual(removed, expected)
                    guard case .success = store.agentWrite(noteID: id, baseRevisionToken: token,
                        document: removed, agentName: "Agent", disposition: disposition) else { return XCTFail("checklist deletion refused") }
                    if disposition == .proposal { XCTAssertEqual(store.applyPendingEdits(noteID: id), 1) }
                    XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, removed)
                    token = try XCTUnwrap(store.note(withID: id)?.revisionToken)
                    base = removed
                }
                let parsed = try NoteAgentTextParser.document(title: "Title", body: body, base: base)
                XCTAssertEqual(parsed.blocks[1], kept)
                guard case .success = store.agentWrite(noteID: id, baseRevisionToken: token,
                    document: parsed, agentName: "Agent", disposition: disposition) else { return XCTFail("safe checklist edit refused") }
                if disposition == .proposal { XCTAssertEqual(store.applyPendingEdits(noteID: id), 1) }
                XCTAssertEqual(store.loadDocument(noteID: id)?.content.document, parsed)
            }
        }
    }

    // MARK: Agent writes (requirement 5)

    func testAgentWriteNeedsAnExistingNoteAndItsCurrentRevision() throws {
        guard case .failure(.noteMissing) = store.agentWrite(noteID: UUID(), baseRevisionToken: NoteItem.initialRevisionToken,
                                                             document: document("x"), agentName: "Claude", disposition: .direct) else {
            return XCTFail("a write to no row must fail")
        }
        let (id, _) = try create(document("Plan"))
        guard case .failure(.staleRevision) = store.agentWrite(noteID: id, baseRevisionToken: "not-the-token",
                                                               document: document("x"), agentName: "Claude", disposition: .direct) else {
            return XCTFail()
        }
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case let .success(.applied(newToken)) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                                       document: document("Agent plan"), agentName: "Claude",
                                                                       disposition: .direct) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Agent plan")
        XCTAssertEqual(store.note(withID: id)?.revisionToken, newToken)
        XCTAssertTrue(versions(id).contains { $0.reason == .beforeAgentEdit && $0.title == "Plan" })
    }

    func testDirectAgentDocumentWriteCannotBypassLegacyMigrationGate() throws {
        let note = try XCTUnwrap(store.create(title: "Legacy"))
        guard case .failure(.invalidDocument) = store.agentWrite(noteID: note.id,
            baseRevisionToken: note.revisionToken, document: document("New format"),
            agentName: "Claude", disposition: .direct) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: note.id)?.contentFormat, 0)
    }

    func testAgentWriteToAnOpenNoteWaitsAndAppliesOnLeaveWhenUnchanged() throws {
        let (id, _) = try create(document("Plan"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token, document: document("Agent"),
                                                         agentName: "Claude", disposition: .proposal) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Plan", "an open note is not written")
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 1)
        XCTAssertEqual(store.note(withID: id)?.title, "Agent")
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
    }

    func testPendingEditWaitsForReviewWhenTheNoteChanged() throws {
        let (id, revision) = try create(document("Plan"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        _ = store.agentWrite(noteID: id, baseRevisionToken: token, document: document("Agent"), agentName: "Claude", disposition: .proposal)
        guard case .success = store.saveDocument(noteID: id, document: document("Mine"), baseRevisionID: revision) else { return XCTFail() }
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        XCTAssertEqual(store.note(withID: id)?.title, "Mine", "the user's text is never overwritten")
        XCTAssertEqual(store.pendingEdits(noteID: id).first?.needsReview, true)
    }

    func testFailedAgentWriteLeavesNoRow() throws {
        let (id, _) = try create(document("Plan"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        gate.shouldFail = true
        guard case .failure = store.agentWrite(noteID: id, baseRevisionToken: token, document: document("Agent"),
                                               agentName: "Claude", disposition: .proposal) else { return XCTFail() }
        guard case .failure = store.agentWrite(noteID: id, baseRevisionToken: token, document: document("Agent"),
                                               agentName: "Claude", disposition: .direct) else { return XCTFail() }
        gate.shouldFail = false
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
        XCTAssertTrue(versions(id).isEmpty)
        XCTAssertEqual(store.note(withID: id)?.title, "Plan")
    }

    // MARK: Staged images and retention

    private func stagedImage() -> StagedNoteAttachment {
        let data = Data([1, 2, 3, 4])
        return StagedNoteAttachment(id: UUID(), filename: "shot.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(data.count),
            digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data: data)
    }

    func testIncompleteImageReservationCannotBecomeAStoredAttachment() throws {
        let id = UUID()
        let reservation = StagedNoteAttachment(id: UUID(), filename: "loading.png",
            contentTypeIdentifier: "public.png", byteCount: 0, digest: "", data: Data())
        let result = store.createDocumentNote(id: id,
            document: NoteDocument(blocks: [.text("Image"), .image(attachmentID: reservation.id)]),
            staged: [reservation])
        guard case .failure(.invalidDocument) = result else { return XCTFail("incomplete image must be refused") }
        XCTAssertNil(store.note(withID: id))
        XCTAssertTrue(try store.attachmentRows(forNoteID: id).isEmpty)
    }

    func testCreateWithExistingLiveIDCannotInventRevisionToOverwrite() throws {
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: document("First")) else {
            return XCTFail()
        }
        let revision = store.note(withID: id)?.revisionID
        guard case .failure(.staleRevision) = store.createDocumentNote(id: id, document: document("Second")) else {
            return XCTFail("a first-save retry has no proven base revision")
        }
        XCTAssertEqual(store.note(withID: id)?.title, "First")
        XCTAssertEqual(store.note(withID: id)?.revisionID, revision)
    }

    func testReservedDraftIDCannotSilentlyRekeyOverDeletedReplica() throws {
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: document("First")) else {
            return XCTFail("initial note fixture")
        }
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))))
        guard case .failure(.noteMissing) = store.createDocumentNote(id: id,
            document: document("Draft")) else {
            return XCTFail("reserved ID must report the deleted collision")
        }
        XCTAssertNil(store.note(withID: id))
        XCTAssertTrue(store.notes.isEmpty)
    }

    func testStagedImageRowsCommitOnlyWithTheDocumentThatShowsThem() throws {
        let shown = stagedImage(), undone = stagedImage()
        let doc = NoteDocument(blocks: [.text("Pics"), .image(attachmentID: shown.id)])
        let (id, revision) = try create(doc, staged: [shown, undone])
        let rowIDs = Set(try store.attachmentRows(forNoteID: id).map(\.id))
        XCTAssertEqual(rowIDs, [shown.id], "an image the text no longer shows gets no row")

        // A failed save commits no row either.
        let later = stagedImage()
        gate.shouldFail = true
        _ = store.saveDocument(noteID: id, document: NoteDocument(blocks: doc.blocks + [.image(attachmentID: later.id)]),
                               baseRevisionID: revision, staged: [later])
        gate.shouldFail = false
        XCTAssertFalse(try store.attachmentRows(forNoteID: id).contains { $0.id == later.id })
    }

    func testPendingProposalCommitsItsBaseSnapshotAndFailureCommitsNeither() throws {
        let (id, _) = try create(document("Base"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        gate.shouldFail = true
        guard case .failure = store.agentWrite(noteID: id, baseRevisionToken: token,
                                               document: document("Proposal"), agentName: "Agent",
                                               disposition: .proposal) else { return XCTFail() }
        gate.shouldFail = false
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
        XCTAssertTrue(versions(id).isEmpty)
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                         document: document("Proposal"), agentName: "Agent",
                                                         disposition: .proposal) else { return XCTFail() }
        let edit = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        let base = try XCTUnwrap(versions(id).first { $0.id == edit.baseVersionID })
        XCTAssertEqual(base.title, "Base")
        XCTAssertEqual(base.sourceRevisionID, store.note(withID: id)?.revisionID)
    }

    func testPendingProposalAndBaseSurvivePersistentRestart() throws {
        let directory = ownedTemporaryDirectory(prefix: "AtticProposal")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstContainer = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                      storeDirectory: directory)
        let first = trackAttachmentReconciliation(of: NoteStore(container: firstContainer, attachmentFileStore: makeTestAttachmentFileStore()))
        guard case let .success((id, _)) = first.createDocumentNote(id: UUID(), document: document("Base")) else {
            return XCTFail()
        }
        let token = try XCTUnwrap(first.note(withID: id)).revisionToken
        guard case .success(.pending) = first.agentWrite(noteID: id, baseRevisionToken: token,
            document: document("Proposal"), agentName: "Agent", disposition: .proposal) else { return XCTFail() }
        let secondContainer = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false,
                                                                       storeDirectory: directory)
        let second = trackAttachmentReconciliation(of: NoteStore(container: secondContainer, attachmentFileStore: makeTestAttachmentFileStore()))
        let edit = try XCTUnwrap(second.pendingEdits(noteID: id).first)
        XCTAssertEqual(second.note(withID: id)?.title, "Base")
        XCTAssertEqual(second.versions(noteID: id).first(where: { $0.id == edit.baseVersionID })?.title, "Base")
        XCTAssertEqual(NoteContentCodec.decode(try XCTUnwrap(edit.proposedContent)).document?.title, "Proposal")
    }

    func testS5DeletionAndMultipleProposalsPersistAcrossRestart() throws {
        let directory = ownedTemporaryDirectory(prefix: "AtticS5Proposals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false, storeDirectory: directory)
        let first = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        guard case let .success((id, token)) = first.createDocumentNote(id: UUID(), document: document("Base")) else { return XCTFail() }
        for agent in ["Claude", "Other editor"] {
            guard case .success(.pending) = first.agentWrite(noteID: id, baseRevisionToken: token.uuidString,
                document: document(agent), agentName: agent, disposition: .proposal) else { return XCTFail() }
        }
        guard case .success(.pending) = first.agentDelete(noteID: id, baseRevisionToken: token.uuidString,
            agentName: "Claude", disposition: .proposal) else { return XCTFail() }
        let reopenedContainer = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false, storeDirectory: directory)
        let second = trackAttachmentReconciliation(of: NoteStore(container: reopenedContainer, attachmentFileStore: makeTestAttachmentFileStore()))
        let proposals = second.pendingEdits(noteID: id)
        XCTAssertEqual(proposals.count, 3)
        XCTAssertEqual(proposals.filter(\.isDeletion).count, 1)
        XCTAssertTrue(proposals.filter(\.isDeletion).allSatisfy(\.needsReview))
        XCTAssertEqual(Set(proposals.compactMap(\.baseVersionID)).count, 3)
        XCTAssertEqual(second.note(withID: id)?.title, "Base")
    }

    func testFailedProposalApplyRetainsPendingEditAndBaseUntilRetry() throws {
        let (id, _) = try create(document("Base"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
            document: document("Proposal"), agentName: "Agent", disposition: .proposal) else { return XCTFail() }
        let edit = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        gate.shouldFail = true
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 0)
        gate.shouldFail = false
        XCTAssertEqual(store.note(withID: id)?.title, "Base")
        XCTAssertEqual(store.pendingEdits(noteID: id).first?.id, edit.id)
        XCTAssertEqual(store.versions(noteID: id).first(where: { $0.id == edit.baseVersionID })?.title, "Base")
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 1)
        XCTAssertEqual(store.note(withID: id)?.title, "Proposal")
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
    }

    func testRowsShownByVersionsAreRetained() throws {
        let image = stagedImage()
        let (id, revision) = try create(NoteDocument(blocks: [.text("Pics"), .image(attachmentID: image.id)]), staged: [image])
        store.recordVersion(noteID: id, reason: .pause)
        guard case .success = store.saveDocument(noteID: id, document: document("Pics"), baseRevisionID: revision) else { return XCTFail() }
        XCTAssertTrue(try store.documentReferencedAttachmentIDs().contains(image.id))
        // Even a row marked removed long ago stays while a version shows it.
        for row in try store.attachmentRows(forNoteID: id) { row.deletedAt = Date(timeIntervalSinceNow: -90 * 86_400) }
        try store.modelContext.save()
        XCTAssertEqual(store.purgeRemovedAttachments(before: Date()), 0)
        XCTAssertFalse(try store.attachmentRows(forNoteID: id).isEmpty)
    }

    // MARK: Migration gate (requirement 2, fixtures only)

    private func legacy(_ body: String, title: String = "Note",
                        attachments: [LegacyNoteSnapshot.Attachment] = []) -> LegacyNoteSnapshot {
        LegacyNoteSnapshot(noteID: UUID(), title: title, body: body, attachments: attachments,
                           revisionToken: NoteItem.initialRevisionToken)
    }

    private func attachment(_ offset: Int?, sort: Int64 = 0, image: Bool = true, id: UUID = UUID()) -> LegacyNoteSnapshot.Attachment {
        .init(id: id, inlineOffset: offset, sortIndex: sort, createdAt: Date(timeIntervalSince1970: 0), isImage: image)
    }

    private func textKitRoundTrip(_ document: NoteDocument) -> NoteDocument {
        NoteTextKitRoundTrip.document(afterRoundTrip: document)
    }

    func testMigrationProjectsTodaysPlacementAndTray() throws {
        let top = attachment(0, sort: 0), middle = attachment(8, sort: 1), tray = attachment(nil, sort: 2)
        let end = attachment(99, sort: 3)
        let snapshot = legacy("First\r\nSecond line\u{2029}Third\n", attachments: [end, tray, middle, top])
        guard case let .success(plan) = LegacyNoteMigration.plan(snapshot) else { return XCTFail() }
        XCTAssertEqual(plan.normalizedBody, "First\nSecond line\nThird\n")
        XCTAssertEqual(plan.normalizedLineBreaks, 2)
        XCTAssertEqual(plan.snappedAnchors, 1, "offset 8 is inside 'Second line', shown at its start")
        let kinds = plan.document.blocks.map { $0.kind == .image ? "img:\($0.attachmentID == top.id ? "top" : $0.attachmentID == middle.id ? "mid" : $0.attachmentID == tray.id ? "tray" : "end")" : "t:\($0.text)" }
        XCTAssertEqual(kinds, ["t:Note", "img:top", "t:First", "img:mid", "t:Second line", "t:Third", "t:", "img:tray", "img:end"])
        guard case .success = LegacyNoteMigration.verify(plan, roundTrip: textKitRoundTrip) else { return XCTFail() }
    }

    func testMigrationRefusesWhatItCannotKeep() {
        let id = UUID()
        XCTAssertEqual(refusal(legacy("x", attachments: [attachment(0, id: id), attachment(0, id: id)])), .duplicateAttachmentIDs)
        XCTAssertEqual(refusal(legacy("x", title: "two\nlines")), .titleHasLineBreak)
        XCTAssertEqual(refusal(legacy("a\u{FFFC}b")), .bodyContainsObjectCharacter)
        let file = attachment(nil, image: false)
        XCTAssertEqual(refusal(legacy("x", attachments: [file])), .fileAttachment(file.id))
    }

    private func refusal(_ snapshot: LegacyNoteSnapshot) -> LegacyMigrationRefusal? {
        if case let .failure(reason) = LegacyNoteMigration.plan(snapshot) { return reason }
        return nil
    }

    func testMigrationEdgeCasesPassTheGate() {
        let cases: [LegacyNoteSnapshot] = [
            legacy(""),
            legacy("", title: ""),
            legacy("", attachments: [attachment(nil), attachment(0)]),       // attachment-only
            legacy("😀 emoji\n", attachments: [attachment(3)]),              // anchor inside a surrogate pair's paragraph
            legacy("a\n\nb", attachments: [attachment(2, sort: 1), attachment(2, sort: 0)]) // ties
        ]
        for snapshot in cases {
            guard case let .success(plan) = LegacyNoteMigration.plan(snapshot) else { return XCTFail("\(snapshot)") }
            guard case .success = LegacyNoteMigration.verify(plan, roundTrip: textKitRoundTrip) else { return XCTFail("\(snapshot)") }
        }
    }

    func testVerificationRejectsATamperedPlanOrABadRoundTrip() throws {
        guard case let .success(plan) = LegacyNoteMigration.plan(legacy("body")) else { return XCTFail() }
        guard case .failure(.roundTripMismatch) = LegacyNoteMigration.verify(plan, roundTrip: { _ in .blank }) else {
            return XCTFail("the round trip is checked, not assumed")
        }
    }

    func testMigrationCommitsThroughTheStoreAndKeepsTheRevertPath() throws {
        let note = try XCTUnwrap(store.create(title: "Old", body: "one\r\ntwo"))
        guard case let .success(snapshot) = store.legacySnapshot(noteID: note.id),
              case let .success(plan) = LegacyNoteMigration.plan(snapshot),
              case let .success(verified) = LegacyNoteMigration.verify(plan, roundTrip: textKitRoundTrip) else { return XCTFail() }

        // Interrupted migration: the save fails, nothing changes.
        gate.shouldFail = true
        guard case .failure(.saveFailed) = store.commitMigration(verified) else { return XCTFail() }
        gate.shouldFail = false
        XCTAssertEqual(store.note(withID: note.id)?.contentFormat, 0)
        XCTAssertTrue(versions(note.id).isEmpty)

        guard case .success = store.commitMigration(verified) else { return XCTFail() }
        let migrated = try XCTUnwrap(store.note(withID: note.id))
        XCTAssertEqual(migrated.contentFormat, 1)
        XCTAssertEqual(migrated.title, "Old", "title kept")
        XCTAssertEqual(migrated.body, "one\r\ntwo", "body kept exactly (revert path)")
        XCTAssertTrue(versions(note.id).contains { $0.reason == .beforeMigration && $0.body == "one\r\ntwo" })
        XCTAssertEqual(store.loadDocument(noteID: note.id)?.content.document?.blocks.map(\.text), ["Old", "one", "two"])
        guard case .failure(.alreadyMigrated) = store.legacySnapshot(noteID: note.id) else { return XCTFail() }
    }

    func testStaleMigrationIsRefused() throws {
        let note = try XCTUnwrap(store.create(title: "Old", body: "one"))
        guard case let .success(snapshot) = store.legacySnapshot(noteID: note.id),
              case let .success(plan) = LegacyNoteMigration.plan(snapshot),
              case let .success(verified) = LegacyNoteMigration.verify(plan, roundTrip: textKitRoundTrip) else { return XCTFail() }
        XCTAssertTrue(store.update(note, body: "edited meanwhile"))
        guard case .failure(.changedSincePlanned) = store.commitMigration(verified) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: note.id)?.contentFormat, 0)
    }

    func testMigrationRejectsAttachmentMovementReorderAndPayloadChange() throws {
        for change in 0..<3 {
            let note = try XCTUnwrap(store.create(title: "Old", body: "first\nsecond"))
            let first = NoteAttachment(id: UUID(), noteID: note.id, originalFilename: "one.png",
                                       contentTypeIdentifier: "public.png", byteCount: 1,
                                       sortIndex: 0, contentDigest: "a",
                                       payload: Data([1]))
            let second = NoteAttachment(id: UUID(), noteID: note.id, originalFilename: "two.png",
                                        contentTypeIdentifier: "public.png", byteCount: 1,
                                        sortIndex: 1, contentDigest: "b",
                                        payload: Data([2]))
            first.inlineOffset = 0
            second.inlineOffset = 6
            store.modelContext.insert(first)
            store.modelContext.insert(second)
            try store.modelContext.save()
            guard case let .success(snapshot) = store.legacySnapshot(noteID: note.id),
                  case let .success(plan) = LegacyNoteMigration.plan(snapshot),
                  case let .success(verified) = LegacyNoteMigration.verify(plan, roundTrip: textKitRoundTrip) else {
                return XCTFail("valid fixture")
            }
            switch change {
            case 0: first.inlineOffset = nil
            case 1: second.sortIndex = -1
            default: first.payload = Data([9])
            }
            try store.modelContext.save()
            guard case .failure(.changedSincePlanned) = store.commitMigration(verified) else {
                return XCTFail("stale attachment input was accepted: \(change)")
            }
            XCTAssertEqual(store.note(withID: note.id)?.contentFormat, 0)
        }
    }

    func testMigrationCommitRefusesAFutureReplicaAddedAfterVerification() throws {
        let note = try XCTUnwrap(store.create(title: "Legacy", body: "body"))
        guard case let .success(snapshot) = store.legacySnapshot(noteID: note.id),
              case let .success(plan) = LegacyNoteMigration.plan(snapshot),
              case let .success(verified) = LegacyNoteMigration.verify(plan, roundTrip: textKitRoundTrip) else {
            return XCTFail("verified fixture")
        }
        let future = NoteItem(id: note.id, title: "Legacy", body: "body")
        future.contentFormat = 7
        future.content = Data("future".utf8)
        store.modelContext.insert(future)
        try store.modelContext.save()
        guard case .failure(.changedSincePlanned) = store.commitMigration(verified) else {
            return XCTFail("future replica must block migration")
        }
        XCTAssertEqual(try rows(note.id).map(\.contentFormat).sorted(), [0, 7])
    }
}
