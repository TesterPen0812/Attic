#if ATTIC_CLOUD_SYNC && !ATTIC_LOCAL_ONLY
import Foundation
import XCTest
@testable import AtticMobile

final class PhoneFakeSyncEngineTests: XCTestCase {
    private let alice = PhoneFakeSyncScope(environment: .development, account: "synthetic-A")
    private let bob = PhoneFakeSyncScope(environment: .development, account: "synthetic-B")

    private func session(_ server: PhoneFakeSyncServer, scope: PhoneFakeSyncScope? = nil,
                         repository: PhoneFakeSyncRepository = .init()) -> PhoneFakeSyncSession {
        PhoneFakeSyncSession(repository: repository, transport: server, scope: scope ?? alice)
    }

    private func task(_ id: UUID = UUID(), parents: [UUID] = [], title: String = "Task",
                      status: PhoneFakeSyncTask.Status = .now, parentID: UUID? = nil,
                      completedAt: Date? = nil) -> PhoneFakeSyncTask {
        .init(id: id, parents: parents, title: title, status: status,
              parentID: parentID, completedAt: completedAt)
    }

    func testCrashReplayRollsBackAtomicIntentAndDoesNotDuplicateCloudOperations() throws {
        let server = PhoneFakeSyncServer(), store = PhoneFakeSyncRepository()
        let first = session(server, repository: store), original = task()
        try first.saveTask(original)
        store.failNextCommit = true
        XCTAssertThrowsError(try first.saveTask(task(title: "Should roll back"))) { error in
            XCTAssertEqual(error as? PhoneFakeSyncFailure, .interruptedCommit)
        }
        XCTAssertEqual(try first.state().outgoing.count, 1)
        XCTAssertEqual(try first.state().tasks.count, 1)

        server.withholdNextReceipt = true // accepted in cloud; acknowledgment lost in crash
        try first.sendPending()
        XCTAssertEqual(server.ledger(alice).count, 1)
        let restored = try PhoneFakeSyncRepository(encoded: store.encoded())
        let restarted = session(server, repository: restored)
        XCTAssertEqual(try restarted.state().outgoing.count, 1)
        try restarted.sendPending()
        XCTAssertEqual(server.ledger(alice).count, 1)
        XCTAssertTrue(try restarted.state().outgoing.isEmpty)

        let other = session(server)
        try other.fetch()
        XCTAssertEqual(try other.state().physicalTasks[original.id], [original])
        XCTAssertEqual(try other.state().checkpoint, 1)
        XCTAssertTrue(try other.state().outgoing.isEmpty) // import cannot echo
    }

    func testReorderedDuplicatedImportsAndGapsNeverSkipCheckpoint() throws {
        let server = PhoneFakeSyncServer(), source = session(server), target = session(server)
        let initial = task(), updated = task(initial.id, parents: [initial.operationID], title: "Updated")
        try source.saveTask(initial)
        try source.saveTask(updated)
        try source.sendPending()
        let events = server.ledger(alice)
        XCTAssertEqual(events.count, 2)

        try target.receive(.init(scope: alice, changes: [events[1], events[1]], upperBound: 2, finished: true))
        XCTAssertEqual(try target.state().checkpoint, 0)
        XCTAssertFalse(target.hasCompletedFetch())
        XCTAssertTrue(try target.state().tasks.isEmpty)

        try target.receive(.init(scope: alice, changes: [events[0], events[0]], upperBound: 2, finished: true))
        XCTAssertEqual(try target.state().checkpoint, 2)
        XCTAssertEqual(try target.state().physicalTasks[initial.id], [updated])
        XCTAssertEqual(try target.state().tasks[initial.id]?.count, 2)
        XCTAssertTrue(target.hasCompletedFetch())
        XCTAssertTrue(try target.state().outgoing.isEmpty)

        // Duplicate fetches must not add physical replicas or replay writes.
        server.reverseFetchOrder = true
        server.duplicateOnFetch = true
        try target.receive(.init(scope: alice, changes: events + events, upperBound: 2, finished: true))
        XCTAssertEqual(try target.state().physicalTasks[initial.id]?.count, 1)
    }

    func testImportRollbackRetainsCheckpointAndReplaysUncommittedBatch() throws {
        let server = PhoneFakeSyncServer(), source = session(server)
        try source.saveTask(task())
        try source.sendPending()
        let targetStore = PhoneFakeSyncRepository(), target = session(server, repository: targetStore)
        targetStore.failNextCommit = true
        XCTAssertThrowsError(try target.fetch())
        XCTAssertEqual(try target.state().checkpoint, 0)
        XCTAssertTrue(try target.state().physicalTasks.isEmpty)
        try target.fetch()
        XCTAssertEqual(try target.state().checkpoint, 1)
    }

    func testStaleAcknowledgementCannotClearNewerEditOrWrongGeneration() throws {
        let server = PhoneFakeSyncServer(), writer = session(server)
        let old = task(), newer = task(old.id, parents: [old.operationID], title: "Second")
        try writer.saveTask(old)
        let first = try XCTUnwrap(writer.state().outgoing.first)
        try writer.saveTask(newer)

        try writer.acknowledge(.init(scope: alice, id: first.id, recordName: first.key.recordName, generation: first.generation))
        XCTAssertEqual(try writer.state().outgoing.map(\.id), [newer.operationID])
        try writer.acknowledge(.init(scope: alice, id: newer.operationID, recordName: first.key.recordName,
                                    generation: first.generation))
        XCTAssertEqual(try writer.state().outgoing.count, 1)
        try writer.acknowledge(.init(scope: alice, id: first.id, recordName: first.key.recordName, generation: first.generation))
        XCTAssertEqual(try writer.state().outgoing.count, 1)
        try writer.sendPending()
        XCTAssertEqual(server.ledger(alice).count, 1) // first ack simulated acceptance; not re-sent
        XCTAssertEqual(try writer.state().outgoing.count, 0)
    }

    func testOfflineDocumentForksAndResolutionRetainEveryImmutableRevision() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        let noteID = UUID(), rootID = UUID(), macID = UUID(), phoneID = UUID(), resolvedID = UUID()
        let root = PhoneFakeSyncRevision(noteID: noteID, id: rootID, parentIDs: [],
                                         contentFormat: 1, bytes: Data("R".utf8), attachmentIDs: [])
        try mac.saveNote(root)
        try mac.sendPending()
        try phone.fetch()
        let branchM = PhoneFakeSyncRevision(noteID: noteID, id: macID, parentIDs: [rootID],
                                            contentFormat: 1, bytes: Data("Mac".utf8), attachmentIDs: [])
        let branchP = PhoneFakeSyncRevision(noteID: noteID, id: phoneID, parentIDs: [rootID],
                                            contentFormat: 1, bytes: Data("Phone".utf8), attachmentIDs: [])
        // Both devices independently edit the same base while disconnected.
        try mac.saveNote(branchM)
        try phone.saveNote(branchP)
        try phone.sendPending()
        try mac.sendPending()
        try phone.fetch()
        try mac.fetch()
        XCTAssertEqual(Set(try mac.state().noteBranches(noteID).map(\.id)), [macID, phoneID])
        XCTAssertEqual(Set(try phone.state().noteBranches(noteID).map(\.id)), [macID, phoneID])
        XCTAssertEqual(try mac.state().revisions.count, 3)

        let resolution = PhoneFakeSyncRevision(noteID: noteID, id: resolvedID,
                                               parentIDs: [phoneID, macID], contentFormat: 1,
                                               bytes: Data("Reviewed".utf8), attachmentIDs: [])
        try phone.saveNote(resolution)
        try phone.sendPending()
        try mac.fetch()
        XCTAssertEqual(try mac.state().noteBranches(noteID).map(\.id), [resolvedID])
        XCTAssertEqual(try mac.state().revisions.count, 4) // preserve both for history/review
        XCTAssertEqual(try phone.state().revisions[macID]?.bytes, Data("Mac".utf8))
    }

    func testConcurrentTaskEditsKeepBothBranchesAndBlockPrematureCleanup() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        let yesterday = Date(timeIntervalSince1970: 86_400)
        let original = task(status: .done, completedAt: yesterday)
        try mac.saveTask(original); try mac.sendPending(); try phone.fetch()
        let editedOnMac = task(original.id, parents: [original.operationID], title: "Still done",
                               status: .done, completedAt: yesterday)
        let reopenedOnPhone = task(original.id, parents: [original.operationID], title: "Reopened")
        try mac.saveTask(editedOnMac)
        try phone.saveTask(reopenedOnPhone)
        try mac.sendPending(); try phone.sendPending()
        try mac.fetch(); try phone.fetch()
        XCTAssertEqual(try mac.state().taskHeads[original.id],
                       Set([editedOnMac.operationID, reopenedOnPhone.operationID]))
        XCTAssertNil(try mac.state().taskHead(original.id))
        XCTAssertNil(try phone.state().taskHead(original.id))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertTrue(try mac.cleanDone(at: yesterday.addingTimeInterval(172_800), calendar: utc).isEmpty)

        let resolved = task(original.id, parents: [editedOnMac.operationID, reopenedOnPhone.operationID],
                            title: "Reviewed reopen")
        try phone.saveTask(resolved); try phone.sendPending(); try mac.fetch()
        XCTAssertEqual(try mac.state().taskHead(original.id), resolved)
        XCTAssertEqual(try mac.state().tasks[original.id]?.count, 4)
    }

    func testDeleteTombstonePreventsLateOfflineResurrectionAndRestoreIsExplicit() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        let old = task(), target = PhoneFakeSyncKey(kind: .task, id: old.id)
        try mac.saveTask(old); try mac.sendPending(); try phone.fetch()
        try mac.delete(target); try mac.sendPending()
        let deletedID = try XCTUnwrap(mac.state().tombstones[target.recordName]?.keys.first)
        let staleOfflineEdit = task(old.id, parents: [old.operationID], title: "Offline edit")
        try phone.saveTask(staleOfflineEdit)
        try phone.sendPending()
        try mac.fetch(); try phone.fetch()
        XCTAssertTrue(try mac.state().deleted(target))
        XCTAssertNil(try mac.state().taskHead(old.id))
        XCTAssertEqual(try mac.state().tasks[old.id]?.count, 2) // recoverable offline work
        XCTAssertTrue(try phone.state().deleted(target))

        try mac.restore(target, tombstoneID: deletedID)
        try mac.sendPending(); try phone.fetch()
        XCTAssertFalse(try phone.state().deleted(target))
        XCTAssertEqual(try phone.state().taskHead(old.id)?.title, "Offline edit")
    }

    func testTwoOfflineTaskNotesRemainSeparateUntilOwnershipReview() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        let taskID = UUID(), firstNote = UUID(), secondNote = UUID()
        try mac.associateTaskNote(taskID: taskID, noteID: firstNote)
        try phone.associateTaskNote(taskID: taskID, noteID: secondNote)
        try phone.sendPending(); try mac.sendPending()
        try phone.fetch(); try mac.fetch()
        XCTAssertEqual(try XCTUnwrap(mac.state().taskNoteCandidates[taskID]), Set([firstNote, secondNote]))
        XCTAssertEqual(try XCTUnwrap(phone.state().taskNoteCandidates[taskID]), Set([firstNote, secondNote]))
        XCTAssertEqual(try mac.state().taskNoteLinks[taskID]?.count, 2)
        XCTAssertEqual(Set(server.ledger(alice).map(\.change.key.recordName)), [
            PhoneFakeSyncKey(kind: .taskNoteLink, id: firstNote).recordName,
            PhoneFakeSyncKey(kind: .taskNoteLink, id: secondNote).recordName
        ])
        XCTAssertTrue(try mac.state().outgoing.isEmpty)
    }

    func testInterruptedAssetCannotPublishHeadAndMissingBytesAreNotDeletion() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        let id = UUID(), bytes = Data("full original attachment bytes".utf8)
        let manifest = PhoneFakeSyncAsset(id: id, bytes: bytes), noteID = UUID()
        let revision = PhoneFakeSyncRevision(noteID: noteID, id: UUID(), parentIDs: [],
                                             contentFormat: 1, bytes: Data("note".utf8), attachmentIDs: [id])
        try mac.saveNote(revision, attachments: [(manifest, bytes)])
        server.interruptNextAsset = true
        XCTAssertThrowsError(try mac.sendPending()) { error in
            XCTAssertEqual(error as? PhoneFakeSyncFailure, .interruptedAsset)
        }
        XCTAssertEqual(server.ledger(alice).count, 1) // only manifest accepted
        XCTAssertEqual(try mac.state().outgoing.count, 3)
        try phone.fetch()
        XCTAssertNotNil(try phone.state().manifests[id])
        XCTAssertFalse(try phone.state().assetIsAvailable(id))
        XCTAssertTrue(try phone.state().noteBranches(noteID).isEmpty)

        try mac.sendPending()
        XCTAssertEqual(server.ledger(alice).count, 4) // bytes, revision, then head
        server.excludeAssetBytesFromFetch = true
        try phone.fetch()
        XCTAssertEqual(try phone.state().checkpoint, 1)
        XCTAssertFalse(phone.hasCompletedFetch())
        XCTAssertFalse(try phone.state().assetIsAvailable(id))
        server.excludeAssetBytesFromFetch = false
        try phone.fetch()
        XCTAssertEqual(try phone.state().checkpoint, 4)
        XCTAssertTrue(try phone.state().assetIsAvailable(id))
        XCTAssertEqual(try phone.state().noteBranches(noteID).map(\.id), [revision.id])
    }

    func testCorruptAssetIsRejectedWithoutAdvancingCheckpointOrReplacingBytes() throws {
        let server = PhoneFakeSyncServer(), reader = session(server)
        let id = UUID(), bytes = Data("right".utf8), metadata = PhoneFakeSyncAsset(id: id, bytes: bytes)
        let first = PhoneFakeSyncChange(id: UUID(), key: .init(kind: .assetManifest, id: id),
                                        generation: 1, after: [], body: .assetManifest(metadata))
        let damaged = PhoneFakeSyncChange(id: UUID(), key: .init(kind: .assetBytes, id: id),
                                          generation: 2, after: [first.id],
                                          body: .assetBytes(id: id, data: Data("wrong".utf8)))
        XCTAssertThrowsError(try reader.receive(.init(scope: alice, changes: [
            .init(sequence: 1, change: first), .init(sequence: 2, change: damaged)
        ], upperBound: 2, finished: true))) { error in
            XCTAssertEqual(error as? PhoneFakeSyncFailure, .invalidPayload)
        }
        XCTAssertEqual(try reader.state().checkpoint, 0)
        XCTAssertNil(try reader.state().manifests[id])
        XCTAssertNil(try reader.state().assets[id])
    }

    func testAccountsAndEnvironmentsIsolateQueuesCheckpointsAndSerializedEngineState() throws {
        let server = PhoneFakeSyncServer(), repo = PhoneFakeSyncRepository()
        let device = session(server, repository: repo), pendingInA = task(title: "A pending")
        try device.saveTask(pendingInA)
        try device.recordEngineState(Data([1, 2, 3]), recordFields: ["task": Data([7])])
        device.changeAccount(to: bob)
        let onlyInB = task(title: "B")
        try device.saveTask(onlyInB)
        try device.sendPending(); try device.fetch()
        XCTAssertEqual(server.ledger(bob).count, 1)
        XCTAssertEqual(server.ledger(alice).count, 0)
        XCTAssertEqual(try device.state().checkpoint, 1)

        // A delayed callback from the previous account must never be imported
        // into the newly active account, even if it arrives after sign-in.
        let fromB = try server.fetch(scope: bob, after: 0)
        device.changeAccount(to: alice)
        XCTAssertThrowsError(try device.receive(fromB)) { error in
            XCTAssertEqual(error as? PhoneFakeSyncFailure, .accountMismatch)
        }
        device.changeAccount(to: bob)

        let production = PhoneFakeSyncScope(environment: .production, account: bob.account)
        device.changeAccount(to: production)
        XCTAssertEqual(try device.state().checkpoint, 0)
        XCTAssertTrue(try device.state().outgoing.isEmpty)
        device.changeAccount(to: alice)
        XCTAssertEqual(try device.state().outgoing.count, 1)
        XCTAssertEqual(try device.state().engineState, Data([1, 2, 3]))
        XCTAssertEqual(try device.state().recordSystemFields["task"], Data([7]))
        try device.sendPending()
        XCTAssertEqual(server.ledger(alice).count, 1)

        device.changeAccount(to: nil)
        XCTAssertThrowsError(try device.sendPending()) { error in
            XCTAssertEqual(error as? PhoneFakeSyncFailure, .accountUnavailable)
        }
        let restarted = try PhoneFakeSyncRepository(encoded: repo.encoded())
        let freshSession = session(server, repository: restarted)
        XCTAssertFalse(freshSession.hasCompletedFetch())
        XCTAssertEqual(try freshSession.state().engineState, Data([1, 2, 3]))
        XCTAssertEqual(try freshSession.state().checkpoint, 0) // never fetched under A
    }

    func testUUIDRecordNamesAndPhysicalCopiesStayDistinctWhenReplicasDiverge() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        let original = task(), key = PhoneFakeSyncKey(kind: .task, id: original.id)
        try mac.saveTask(original); try mac.sendPending(); try phone.fetch()
        try phone.addPhysicalTaskCopy(original)
        let new = task(original.id, parents: [original.operationID], title: "Both updated")
        try mac.saveTask(new); try mac.sendPending(); try phone.fetch()
        XCTAssertEqual(try phone.state().physicalTasks[original.id], [new, new])
        XCTAssertEqual(server.ledger(alice).map(\.change.key.recordName), [key.recordName, key.recordName])

        var split = new
        split.title = "Divergent local physical row"
        try phone.addPhysicalTaskCopy(split)
        XCTAssertTrue(try phone.state().physicalDivergence(original.id))
        XCTAssertThrowsError(try phone.saveTask(task(original.id, parents: [new.operationID], title: "Unsafe"))) {
            XCTAssertEqual($0 as? PhoneFakeSyncFailure, .divergentReplicas)
        }
        let latest = task(original.id, parents: [new.operationID], title: "Remote newer")
        try mac.saveTask(latest); try mac.sendPending(); try phone.fetch()
        XCTAssertEqual(try phone.state().physicalTasks[original.id]?.count, 3)
        XCTAssertTrue(try phone.state().physicalDivergence(original.id))
        XCTAssertEqual(try phone.state().tasks[original.id]?[latest.operationID], latest)
        XCTAssertTrue(try phone.state().outgoing.isEmpty)
    }

    func testCrossDeviceReopenAndOfflineGateBlockDoneCleanup() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        let instant = Date(timeIntervalSince1970: 1_000_000)
        let old = task(status: .done, completedAt: instant)
        let now = instant.addingTimeInterval(3 * 86_400)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        try mac.saveTask(old); try mac.sendPending(); try phone.fetch()
        server.connected = false
        XCTAssertThrowsError(try mac.cleanDone(at: now, calendar: utc)) {
            XCTAssertEqual($0 as? PhoneFakeSyncFailure, .offline)
        }
        XCTAssertNil(try mac.state().taskHead(old.id)?.doneLoggedAt)
        server.connected = true
        let reopened = task(old.id, parents: [old.operationID], title: "Reopened", status: .now)
        try phone.saveTask(reopened); try phone.sendPending()
        XCTAssertTrue(try mac.cleanDone(at: now, calendar: utc).isEmpty) // fresh fetch sees reopen
        XCTAssertEqual(try mac.state().taskHead(old.id), reopened)
        XCTAssertFalse(try mac.state().deleted(.init(kind: .taskPlacement, id: old.id)))
    }

    func testDoneCleanupArchivesWholeEligibleFamilyWithPlacementTombstones() throws {
        let server = PhoneFakeSyncServer(), mac = session(server), phone = session(server)
        var london = Calendar(identifier: .gregorian)
        london.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let old = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-28T20:00:00Z"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-29T02:00:00Z"))
        let root = task(title: "Parent", status: .done, completedAt: old)
        let child = task(title: "Child", status: .done, parentID: root.id, completedAt: old)
        let open = task(title: "Open parent")
        let blocked = task(title: "Done child", status: .done, parentID: open.id, completedAt: old)
        for value in [root, child, open, blocked] { try mac.saveTask(value) }
        try mac.sendPending(); try phone.fetch()

        XCTAssertEqual(try mac.cleanDone(at: now, calendar: london), [root.id, child.id])
        XCTAssertEqual(try mac.state().taskHead(root.id)?.doneLoggedAt, now)
        XCTAssertEqual(try mac.state().taskHead(child.id)?.doneLoggedAt, now)
        XCTAssertNil(try mac.state().taskHead(blocked.id)?.doneLoggedAt)
        try mac.sendPending(); try phone.fetch()
        for id in [root.id, child.id] {
            XCTAssertTrue(try phone.state().deleted(.init(kind: .taskPlacement, id: id)))
            XCTAssertEqual(try phone.state().taskHead(id)?.doneLoggedAt, now)
            XCTAssertEqual(try phone.state().physicalTasks[id]?.count, 1)
        }
        XCTAssertTrue(try mac.cleanDone(at: now, calendar: london).isEmpty)
    }

    func testDivergentFamilyMemberBlocksCleanupForAllPhysicalCopies() throws {
        let server = PhoneFakeSyncServer(), device = session(server)
        let yesterday = Date(timeIntervalSince1970: 86_400), today = yesterday.addingTimeInterval(172_800)
        let root = task(status: .done, completedAt: yesterday)
        let child = task(status: .done, parentID: root.id, completedAt: yesterday)
        let unrelated = task(status: .done, completedAt: yesterday)
        for item in [root, child, unrelated] { try device.saveTask(item) }
        var divergent = child
        divergent.status = .now
        try device.addPhysicalTaskCopy(divergent)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(try device.cleanDone(at: today, calendar: cal), [unrelated.id])
        XCTAssertNil(try device.state().taskHead(root.id)?.doneLoggedAt)
        XCTAssertNil(try device.state().taskHead(child.id)) // visibly unresolved divergence
        XCTAssertEqual(try device.state().physicalTasks[child.id]?.count, 2)
    }
}
#endif
