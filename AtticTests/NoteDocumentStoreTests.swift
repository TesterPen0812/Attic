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
            document: document("Agent"), agentName: "Claude", noteIsOpen: false) else { return XCTFail() }
        guard case .failure(.staleRevision) = store.saveDocument(noteID: id,
            document: document("Stale draft"), baseRevisionID: base) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Agent")
    }

    func testEveryWriterRefusesAFutureReplicaWithoutMutatingTheFamily() throws {
        let (id, revision) = try create(document("Readable"))
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .pause))
        let versionID = try XCTUnwrap(versions(id).first?.id)
        let originalToken = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: originalToken,
                                                         document: document("Waiting"), agentName: "Agent",
                                                         noteIsOpen: true) else { return XCTFail("pending fixture") }
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
                                                          noteIsOpen: false) else { return XCTFail("agent write") }
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
                                                          document: document("y"), agentName: "Claude", noteIsOpen: false) else {
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

    // MARK: Agent writes (requirement 5)

    func testAgentWriteNeedsAnExistingNoteAndItsCurrentRevision() throws {
        guard case .failure(.noteMissing) = store.agentWrite(noteID: UUID(), baseRevisionToken: NoteItem.initialRevisionToken,
                                                             document: document("x"), agentName: "Claude", noteIsOpen: false) else {
            return XCTFail("a write to no row must fail")
        }
        let (id, _) = try create(document("Plan"))
        guard case .failure(.staleRevision) = store.agentWrite(noteID: id, baseRevisionToken: "not-the-token",
                                                               document: document("x"), agentName: "Claude", noteIsOpen: false) else {
            return XCTFail()
        }
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case let .success(.applied(newToken)) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                                       document: document("Agent plan"), agentName: "Claude",
                                                                       noteIsOpen: false) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Agent plan")
        XCTAssertEqual(store.note(withID: id)?.revisionToken, newToken)
        XCTAssertTrue(versions(id).contains { $0.reason == .beforeAgentEdit && $0.title == "Plan" })
    }

    func testDirectAgentDocumentWriteCannotBypassLegacyMigrationGate() throws {
        let note = try XCTUnwrap(store.create(title: "Legacy"))
        guard case .failure(.invalidDocument) = store.agentWrite(noteID: note.id,
            baseRevisionToken: note.revisionToken, document: document("New format"),
            agentName: "Claude", noteIsOpen: false) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: note.id)?.contentFormat, 0)
    }

    func testAgentWriteToAnOpenNoteWaitsAndAppliesOnLeaveWhenUnchanged() throws {
        let (id, _) = try create(document("Plan"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token, document: document("Agent"),
                                                         agentName: "Claude", noteIsOpen: true) else { return XCTFail() }
        XCTAssertEqual(store.note(withID: id)?.title, "Plan", "an open note is not written")
        XCTAssertEqual(store.pendingEdits(noteID: id).count, 1)
        XCTAssertEqual(store.applyPendingEdits(noteID: id), 1)
        XCTAssertEqual(store.note(withID: id)?.title, "Agent")
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
    }

    func testPendingEditWaitsForReviewWhenTheNoteChanged() throws {
        let (id, revision) = try create(document("Plan"))
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        _ = store.agentWrite(noteID: id, baseRevisionToken: token, document: document("Agent"), agentName: "Claude", noteIsOpen: true)
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
                                               agentName: "Claude", noteIsOpen: true) else { return XCTFail() }
        guard case .failure = store.agentWrite(noteID: id, baseRevisionToken: token, document: document("Agent"),
                                               agentName: "Claude", noteIsOpen: false) else { return XCTFail() }
        gate.shouldFail = false
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
        XCTAssertTrue(versions(id).isEmpty)
        XCTAssertEqual(store.note(withID: id)?.title, "Plan")
    }

    // MARK: Staged images and retention

    private func stagedImage() -> StagedNoteAttachment {
        StagedNoteAttachment(id: UUID(), filename: "shot.png", contentTypeIdentifier: "public.png", byteCount: 4,
                             digest: String(repeating: "a", count: 64), data: Data([1, 2, 3, 4]))
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
                                               noteIsOpen: true) else { return XCTFail() }
        gate.shouldFail = false
        XCTAssertTrue(store.pendingEdits(noteID: id).isEmpty)
        XCTAssertTrue(versions(id).isEmpty)
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                         document: document("Proposal"), agentName: "Agent",
                                                         noteIsOpen: true) else { return XCTFail() }
        let edit = try XCTUnwrap(store.pendingEdits(noteID: id).first)
        let base = try XCTUnwrap(versions(id).first { $0.id == edit.baseVersionID })
        XCTAssertEqual(base.title, "Base")
        XCTAssertEqual(base.sourceRevisionID, store.note(withID: id)?.revisionID)
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
