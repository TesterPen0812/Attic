import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneNoteHistoryTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_700_000_000)
    private let raw = Data(#"{ "format":1, "blocks":[{"kind":"text","text":"Now"}], "extra":0.123456789012345678901 }"#.utf8)

    private func database() throws -> ModelContainer {
        let schema = Schema([NoteItem.self, NoteVersion.self, NotePendingEdit.self, NoteAttachment.self,
                             TaskItem.self, TaskNoteAssociation.self, TaskDeletionPreservation.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @discardableResult private func note(_ c: ModelContext, id: UUID, revisionID: UUID?, tag: String = "a") -> NoteItem {
        let n = NoteItem(id: id, title: "Now", createdAt: t)
        n.content = raw; n.contentFingerprint = nil; n.revision = 3; n.revisionID = revisionID
        n.tagsRaw = tag; n.pinnedAt = t; n.externalEditorName = "Existing"; n.externalEditedAt = t
        c.insert(n); return n
    }

    @discardableResult private func version(_ c: ModelContext, noteID: UUID, id: UUID = UUID(), bytes: Data? = nil,
                                            date: Date? = nil, assets: [UUID] = []) -> NoteVersion {
        let v = NoteVersion(id: id, noteID: noteID, createdAt: date ?? t, reason: .leave,
            content: bytes ?? raw, contentFormat: 1, title: "Historical cache", body: "Do not reconstruct",
            attachmentIDs: assets, sourceRevisionID: nil)
        c.insert(v); return v
    }

    func testCheckpointCoalescesOnlyMatchingWritingAndPreservesExactProjectionSpellings() throws {
        let db = try database(), c = ModelContext(db), id = UUID(), rev = UUID()
        note(c, id: id, revisionID: rev).body = "é"
        note(c, id: id, revisionID: rev).body = "e\u{301}"
        note(c, id: id, revisionID: rev).body = "é"
        try c.save()
        var saves = 0
        let history = PhoneNoteHistory(container: db, now: { self.t }, save: { saves += 1; try $0.save() })
        let first = try history.load(noteID: id)
        XCTAssertEqual(try history.checkpoint(first.head, reason: .pause), 2)
        XCTAssertEqual(try history.checkpoint(first.head, reason: .leave), 0)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(first.versions.isEmpty)
        let fresh = try history.load(noteID: id)
        XCTAssertEqual(fresh.versions.count, 2)
        XCTAssertEqual(Set(fresh.versions.map { Data($0.body.utf8) }), Set([Data("é".utf8), Data("e\u{301}".utf8)]))
        XCTAssertTrue(fresh.versions.allSatisfy { $0.content == raw && $0.sourceRevisionID == rev && $0.reason == .pause })
        XCTAssertTrue(try ModelContext(db).fetch(FetchDescriptor<NoteItem>()).allSatisfy { $0.revision == 3 && $0.contentFingerprint == nil })
    }

    func testRestorePreservesOriginalAndAllReplicasMetadataAndOnlyReconcilesAttachmentVisibility() throws {
        let db = try database(), c = ModelContext(db), id = UUID(), rev = UUID(), target = UUID()
        note(c, id: id, revisionID: rev, tag: "a"); note(c, id: id, revisionID: rev, tag: "b")
        let fileID = UUID(), removedID = UUID(), missingID = UUID()
        let doc = NoteDocument(blocks: [.text("  Old   head "), .file(attachmentID: fileID, filename: "kit.txt", contentTypeIdentifier: "public.text", byteCount: 2), .image(attachmentID: missingID)])
        var wire = try NoteContentCodec.encode(doc); wire.append(10)
        for _ in 0..<2 { version(c, noteID: id, id: target, bytes: wire, assets: [fileID, missingID]) }
        for assetID in [fileID, removedID] {
            let a = NoteAttachment(id: assetID, noteID: id, originalFilename: "keep", byteCount: 2, sortIndex: 0,
                                   contentDigest: "as stored", payload: Data([0, 255]))
            a.deletedAt = assetID == fileID ? t : nil; c.insert(a)
        }
        try c.save()
        let history = PhoneNoteHistory(container: db, now: { self.t.addingTimeInterval(9) })
        let opened = try history.load(noteID: id), chosen = try XCTUnwrap(opened.versions.first)
        XCTAssertEqual(opened.versions.count, 1)
        let next = try history.restore(chosen, against: opened.head)
        XCTAssertEqual(next.revision, 4); XCTAssertNotNil(next.revisionID); XCTAssertNotEqual(next.revisionID, rev)
        let reader = ModelContext(db), notes = try reader.fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(notes.count, 2); XCTAssertEqual(Set(notes.map(\.tagsRaw)), ["a", "b"])
        XCTAssertTrue(notes.allSatisfy { $0.content == wire && $0.revisionID == next.revisionID && $0.revision == 4 &&
            $0.title == "Old head" && $0.plainText == NoteTextExport.plainText(doc) && $0.body == NoteTextExport.plainBody(doc) &&
            $0.imageCount == 1 && $0.fileCount == 1 && $0.firstFileName == "kit.txt" && $0.contentFingerprint == NoteItem.fingerprint(wire) &&
            $0.pinnedAt == t && $0.externalEditedAt == t && $0.externalEditorName == "Existing" && $0.createdAt == t })
        let versions = try reader.fetch(FetchDescriptor<NoteVersion>())
        XCTAssertEqual(versions.filter { $0.id == target && $0.content == wire }.count, 2)
        XCTAssertEqual(versions.filter { $0.reason == .beforeRestore && $0.content == raw && $0.sourceRevisionID == rev }.count, 1)
        let assets = try reader.fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Set(assets.map(\.id)), [fileID, removedID]); XCTAssertTrue(assets.allSatisfy { $0.payload == Data([0, 255]) })
        XCTAssertNil(try XCTUnwrap(assets.first { $0.id == fileID }).deletedAt)
        XCTAssertNotNil(try XCTUnwrap(assets.first { $0.id == removedID }).deletedAt)
        XCTAssertThrowsError(try history.restore(chosen, against: opened.head))
        // Restoring even identical target bytes is a new content revision; never rewrite the selected version.
        let again = try history.load(noteID: id)
        XCTAssertEqual(try history.restore(chosen, against: again.head).revision, 5)
    }

    func testAnyStaleDeletedOrMixedOwnerCopyRefusesBeforeCheckpointOrRestore() throws {
        for change in ["bytes", "revision", "token", "deleted", "task", "generation", "link", "overflow"] {
            let db = try database(), c = ModelContext(db), id = UUID(), rev = UUID()
            let n = note(c, id: id, revisionID: rev); let sibling = note(c, id: id, revisionID: rev)
            if change == "overflow" { n.revision = .max; sibling.revision = .max }
            version(c, noteID: id); try c.save()
            let history = PhoneNoteHistory(container: db), opened = try history.load(noteID: id)
            switch change {
            case "bytes": sibling.content = raw + Data([32]); sibling.contentFingerprint = nil
            case "revision": sibling.revision += 1
            case "token": sibling.revisionID = UUID()
            case "deleted": sibling.deletedAt = t
            case "task": sibling.taskID = UUID()
            case "generation": sibling.associationGeneration += 1
            case "link": c.insert(TaskNoteAssociation(taskID: UUID(), noteID: id))
            default: break
            }
            try c.save()
            if change != "overflow" { XCTAssertThrowsError(try history.checkpoint(opened.head, reason: .leave), change) }
            XCTAssertThrowsError(try history.restore(XCTUnwrap(opened.versions.first), against: opened.head), change)
            XCTAssertEqual(try history.versions(noteID: id).count, 1, "Stored history stays readable during a live conflict")
            let reader = ModelContext(db)
            XCTAssertEqual(try reader.fetchCount(FetchDescriptor<NoteVersion>()), 1, change)
            XCTAssertEqual(try reader.fetch(FetchDescriptor<NoteItem>()).filter { $0.content == raw }.count, change == "bytes" ? 1 : 2)
        }
    }

    func testOpaqueTargetsAndChangedOrCrossOwnerVersionFamiliesCannotBeRestored() throws {
        for change in ["future", "unknown", "ambiguous", "malformed", "reason", "manifest", "taskSnapshot", "conflictingCopy", "crossOwner", "changedTicket"] {
            let db = try database(), c = ModelContext(db), id = UUID(), vid = UUID()
            note(c, id: id, revisionID: nil); let v = version(c, noteID: id, id: vid)
            switch change {
            case "future": v.contentFormat = 9
            case "unknown": v.content = Data(#"{"format":1,"blocks":[{"kind":"future","data":42}]}"#.utf8)
            case "ambiguous": v.content = Data(#"{"format":1,"blocks":[{"kind":"text","text":"one","text":"two"}]}"#.utf8)
            case "malformed": v.content = Data([0xff])
            case "reason": v.reasonRaw = "unknown"
            case "manifest": v.attachmentIDsRaw = "bad-id"
            case "taskSnapshot": v.taskSnapshotData = Data(#"{"format":7}"#.utf8)
            case "conflictingCopy": version(c, noteID: id, id: vid).body = "Different"
            case "crossOwner": version(c, noteID: UUID(), id: vid)
            default: break
            }
            try c.save()
            let history = PhoneNoteHistory(container: db), opened = try history.load(noteID: id), selected = try XCTUnwrap(opened.versions.first)
            if change == "changedTicket" { v.content = raw + Data([32]); try c.save() }
            let prior = v.content
            XCTAssertThrowsError(try history.restore(selected, against: opened.head), change)
            let reader = ModelContext(db)
            XCTAssertEqual(try reader.fetch(FetchDescriptor<NoteItem>()).first?.content, raw, change)
            XCTAssertTrue(try reader.fetch(FetchDescriptor<NoteVersion>()).contains { $0.id == vid && $0.content == prior }, change)
        }
    }

    func testOpaqueLiveContentIsNeverRebuiltFromPreviewOrOverwritten() throws {
        let db = try database(), c = ModelContext(db), id = UUID()
        let n = note(c, id: id, revisionID: nil); let damaged = Data([0xff, 0x00]); n.content = damaged
        version(c, noteID: id); try c.save()
        let history = PhoneNoteHistory(container: db), opened = try history.load(noteID: id)
        XCTAssertThrowsError(try history.checkpoint(opened.head, reason: .pause))
        XCTAssertThrowsError(try history.restore(XCTUnwrap(opened.versions.first), against: opened.head))
        XCTAssertEqual(try ModelContext(db).fetch(FetchDescriptor<NoteItem>()).first?.content, damaged)
    }

    func testSaveFailureRollsBackPreservationAttachmentVisibilityAndEveryPhysicalHead() throws {
        let db = try database(), c = ModelContext(db), id = UUID(), rev = UUID()
        note(c, id: id, revisionID: rev); note(c, id: id, revisionID: rev)
        let asset = NoteAttachment(noteID: id, originalFilename: "keep", byteCount: 1, sortIndex: 0, contentDigest: "x", payload: Data([7]))
        c.insert(asset); version(c, noteID: id, bytes: try NoteContentCodec.encode(.init(blocks: [.text("Earlier")])))
        try c.save(); var attempts = 0
        let history = PhoneNoteHistory(container: db, save: { writer in
            attempts += 1; XCTAssertTrue(writer.hasChanges); throw CocoaError(.fileWriteOutOfSpace)
        })
        let opened = try history.load(noteID: id)
        XCTAssertThrowsError(try history.checkpoint(opened.head, reason: .pause))
        XCTAssertThrowsError(try history.restore(XCTUnwrap(opened.versions.first), against: opened.head))
        XCTAssertEqual(attempts, 2)
        let reader = ModelContext(db)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<NoteVersion>()), 1)
        XCTAssertTrue(try reader.fetch(FetchDescriptor<NoteItem>()).allSatisfy { $0.content == raw && $0.revisionID == rev && $0.revision == 3 })
        XCTAssertNil(try XCTUnwrap(reader.fetch(FetchDescriptor<NoteAttachment>()).first).deletedAt)
    }

    func testListingsAreFreshOrderedValueSnapshotsAndProposalsRemainReadOnly() throws {
        let db = try database(), c = ModelContext(db), id = UUID(), a = UUID(), b = UUID()
        note(c, id: id, revisionID: nil); version(c, noteID: id, id: a)
        let pid = UUID()
        for _ in 0..<2 { c.insert(NotePendingEdit(id: pid, noteID: id, baseRevisionToken: "initial", proposedContent: raw, agentName: "First", createdAt: t)) }
        try c.save()
        let history = PhoneNoteHistory(container: db), old = try history.load(noteID: id)
        version(c, noteID: id, id: b, date: t.addingTimeInterval(1))
        let p = NotePendingEdit(noteID: id, baseRevisionToken: "initial", proposedContent: Data([42]), agentName: "Second", createdAt: t.addingTimeInterval(1))
        p.needsReview = true; p.isDeletion = true; c.insert(p); try c.save()
        let fresh = try history.load(noteID: id)
        XCTAssertEqual(old.versions.map(\.id), [a]); XCTAssertEqual(fresh.versions.map(\.id), [b, a])
        XCTAssertEqual(old.proposals.map(\.id), [pid]); XCTAssertEqual(fresh.proposals.map(\.agentName), ["First", "Second"])
        XCTAssertEqual(fresh.proposals.last?.proposedContent, Data([42])); XCTAssertEqual(fresh.proposals.last?.needsReview, true)
        XCTAssertEqual(fresh.proposals.last?.isDeletion, true)
        try history.restore(XCTUnwrap(fresh.versions.first), against: fresh.head)
        let reader = ModelContext(db)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<NotePendingEdit>()), 3)
        XCTAssertTrue(try reader.fetch(FetchDescriptor<NotePendingEdit>()).contains { $0.id == p.id && $0.needsReview && $0.isDeletion && $0.proposedContent == Data([42]) })
    }

    func testTaskRestoreUsesLiveHeadNotHistoricalTaskMetadata() throws {
        let db = try database(), c = ModelContext(db), id = UUID(), ownerID = UUID()
        let owner = TaskItem(id: ownerID, title: "Current task", priority: .high)
        let child = TaskItem(title: "Keep child", parentID: ownerID); c.insert(owner); c.insert(child)
        c.insert(TaskNoteAssociation(taskID: ownerID, noteID: id))
        let n = note(c, id: id, revisionID: UUID()); n.taskID = ownerID
        n.content = try NoteContentCodec.encode(.init(blocks: [.text("Current task"), .text("Current writing")], requires: ["taskNote"]))
        let past = NoteDocument(blocks: [.text("Previous task"), .text("Old writing")], requires: ["taskNote"])
        let source = try NoteContentCodec.encode(past); version(c, noteID: id, bytes: source)
        let p = NotePendingEdit(noteID: UUID(), baseRevisionToken: "initial", proposedContent: raw, agentName: "Task proposal", createdAt: t)
        p.workspaceTaskID = ownerID; c.insert(p); try c.save()
        let history = PhoneNoteHistory(container: db, now: { self.t.addingTimeInterval(9) }), opened = try history.load(noteID: id)
        XCTAssertEqual(opened.proposals.map(\.id), [p.id])
        _ = try history.restore(XCTUnwrap(opened.versions.first), against: opened.head)
        let reader = ModelContext(db), restored = try XCTUnwrap(reader.fetch(FetchDescriptor<NoteItem>()).first)
        let doc = try XCTUnwrap(restored.content.flatMap { NoteContentCodec.decode($0).document })
        XCTAssertEqual(doc.blocks.map(\.text), ["Current task", "Old writing"]); XCTAssertEqual(restored.taskID, ownerID)
        let stored = try reader.fetch(FetchDescriptor<NoteVersion>())
        XCTAssertTrue(stored.contains { $0.reason == .leave && $0.content == source })
        let head = try XCTUnwrap(stored.first { $0.reason == .beforeRestore }?.taskSnapshotData)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: head) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Current task"); XCTAssertEqual((json["children"] as? [[String: Any]])?.first?["title"] as? String, "Keep child")
        let tasks = try reader.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(tasks.first { $0.id == ownerID }?.priority, .high); XCTAssertEqual(tasks.first { $0.id == child.id }?.parentID, ownerID)
    }
    func testDetachedHistoryUsesPreservationButCircleRemovalNeverReplaysChildren() throws {
        for circle in [false, true] {
            let db = try database(), c = ModelContext(db), id = UUID(), retired = UUID(), child = UUID()
            note(c, id: id, revisionID: nil)
            let encoder = JSONEncoder()
            func member(_ key: UUID, _ parent: UUID?, _ title: String) throws -> [String: Any] {
                let fields: [String: Data] = try ["title": encoder.encode(title), "parentID": encoder.encode(parent),
                    "statusRaw": encoder.encode("todo"), "manualOrder": encoder.encode(Int64(1)), "createdAt": encoder.encode(t),
                    "tagsRaw": encoder.encode("archived"), "deletedAt": encoder.encode(t)]
                return ["id": key.uuidString, "fields": fields.mapValues { $0.base64EncodedString() }]
            }
            let payload = try JSONSerialization.data(withJSONObject: ["rootID": retired.uuidString, "title": "Preserved",
                "members": [try member(retired, nil, "Preserved"), try member(child, retired, "Child")], "originals": []])
            let recovery = TaskDeletionPreservation(rootID: retired, deletedAt: t, capturedAt: t,
                provenance: circle ? "circle removed" : "soft-deletion", snapshot: payload)
            recovery.purgedAt = t; c.insert(recovery)
            let link = TaskNoteAssociation(taskID: retired, noteID: id)
            link.detachedAt = t; link.detachedPreservationID = recovery.id; c.insert(link)
            let old = try NoteContentCodec.encode(.init(blocks: [.text("Old task"), .text("Earlier")], requires: ["taskNote"]))
            version(c, noteID: id, bytes: old); try c.save()
            let history = PhoneNoteHistory(container: db), opened = try history.load(noteID: id)
            let saved = try history.restore(XCTUnwrap(opened.versions.first), against: opened.head)
            let doc = try XCTUnwrap(saved.content.flatMap { NoteContentCodec.decode($0).document })
            XCTAssertFalse(doc.requires.contains("taskNote")); XCTAssertNil(saved.taskID)
            XCTAssertEqual(doc.blocks.map(\.text), circle ? ["Now", "Earlier"] : ["Preserved", "Child", "Earlier"])
            let reader = ModelContext(db)
            XCTAssertEqual(try reader.fetchCount(FetchDescriptor<TaskItem>()), 0)
            XCTAssertEqual(try reader.fetch(FetchDescriptor<NoteItem>()).first?.tagsRaw, "a")
            XCTAssertTrue(try reader.fetch(FetchDescriptor<NoteVersion>()).contains { $0.content == old })
        }
    }

    func testTaskNormalizationCannotRoundUnknownExtrasOrTrustAnOutdatedOwnerLink() throws {
        for stale in [false, true] {
            let db = try database(), c = ModelContext(db), id = UUID(), owner = UUID()
            let task = TaskItem(id: owner, title: "Live title"); c.insert(task)
            let link = TaskNoteAssociation(taskID: owner, noteID: id); c.insert(link)
            let n = note(c, id: id, revisionID: nil); n.taskID = owner
            n.content = try NoteContentCodec.encode(.init(blocks: [.text("Live title")], requires: ["taskNote"]))
            let unsafe = Data(#"{ "format":1,"blocks":[{"kind":"text","text":"Historical"}],"counter":0.123456789012345678901 }"#.utf8)
            version(c, noteID: id, bytes: stale ? try NoteContentCodec.encode(.init(blocks: [.text("Old")])) : unsafe); try c.save()
            let h = PhoneNoteHistory(container: db), opened = try h.load(noteID: id)
            if stale { task.associationGeneration += 1; try c.save() }
            XCTAssertThrowsError(try h.restore(XCTUnwrap(opened.versions.first), against: opened.head))
            let reader = ModelContext(db)
            XCTAssertEqual(try reader.fetchCount(FetchDescriptor<NoteVersion>()), 1); XCTAssertEqual(try reader.fetch(FetchDescriptor<NoteItem>()).first?.revision, 3)
            XCTAssertEqual(try reader.fetch(FetchDescriptor<NoteVersion>()).first?.content, opened.versions.first?.content)
        }
    }

}
