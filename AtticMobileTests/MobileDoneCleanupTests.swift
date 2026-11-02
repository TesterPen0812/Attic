import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

#if ATTIC_LOCAL_ONLY && !ATTIC_CLOUD_SYNC
@MainActor
final class MobileDoneCleanupTests: XCTestCase {
    private let old = Date(timeIntervalSince1970: 86_400)
    private let now = Date(timeIntervalSince1970: 259_200)

    private func calendar(_ zone: String = "GMT") throws -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return value
    }

    private func instant(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    private func done(_ title: String, id: UUID = UUID(), parent: UUID? = nil) -> TaskItem {
        TaskItem(id: id, title: title, status: .done, createdAt: old, completedAt: old, parentID: parent)
    }

    private func seed(_ rows: [TaskItem]) throws -> ModelContainer {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let writer = ModelContext(container)
        for row in rows { writer.insert(row) }
        try writer.save()
        return container
    }

    func testLocalMidnightAcrossBothDSTTransitions() throws {
        let london = try calendar("Europe/London")
        // UTC instants for consecutive London midnights: a 23-hour day, then a 25-hour day.
        for (start, end) in [("2026-03-29T00:00:00Z", "2026-03-29T23:00:00Z"),
                             ("2026-10-24T23:00:00Z", "2026-10-26T00:00:00Z")] {
            let firstMidnight = try instant(start), nextMidnight = try instant(end)
            let lastSecond = nextMidnight.addingTimeInterval(-1)
            XCTAssertEqual(PhoneDoneCleanup.nextMidnight(after: firstMidnight, calendar: london), nextMidnight)
            let before = done("Before"), at = done("At"), after = done("After"), missing = done("No completion")
            before.completedAt = lastSecond; before.updatedAt = nextMidnight
            at.completedAt = nextMidnight; after.completedAt = nextMidnight.addingTimeInterval(1)
            missing.completedAt = nil
            let active = done("Reopened"); active.status = .todo
            let container = try seed([before, at, after, missing, active])
            let service = PhoneDoneCleanup(container: container)
            XCTAssertEqual(try service.perform(at: lastSecond, calendar: london), 0)
            XCTAssertEqual(try service.perform(at: nextMidnight, calendar: london), 1)
            XCTAssertEqual(try service.history().map(\.id), [before.id])
            XCTAssertEqual(Set(try PhoneLibrary(container: container).tasks().map(\.id)), [at.id, after.id, missing.id, active.id])
        }
    }

    func testZoneChangeAndMissedMidnightsDoNotLogTwice() throws {
        let london = try calendar("Europe/London"), newYork = try calendar("America/New_York")
        let late = done("Late"); late.completedAt = try instant("2026-07-08T22:30:00Z")
        let container = try seed([late]), service = PhoneDoneCleanup(container: container)
        let sameInstant = try instant("2026-07-08T23:15:00Z")
        XCTAssertEqual(try service.perform(at: sameInstant, calendar: newYork), 0)
        XCTAssertEqual(try service.perform(at: sameInstant, calendar: london), 1)
        let more = ModelContext(container)
        for i in 0..<3 {
            let task = done("Missed day \(i)")
            task.completedAt = sameInstant.addingTimeInterval(Double(i) * 86_400)
            more.insert(task)
        }
        try more.save()
        let later = try instant("2026-07-15T10:00:00Z")
        XCTAssertEqual(try service.perform(at: later, calendar: newYork), 3)
        XCTAssertEqual(try service.perform(at: later, calendar: newYork), 0)
        XCTAssertEqual(try service.perform(at: sameInstant, calendar: newYork), 0)
        let history = try service.history()
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.first { $0.id == late.id }?.loggedAt, sameInstant)
    }

    func testPhysicalDivergenceBlocksOnlyThatUUID() throws {
        // Each pair differs in exactly one of the Mac cleanup snapshot's fields.
        let variants: [(TaskItem) -> Void] = [
            { $0.title = "Cafe\u{301}" }, { $0.statusRaw = "todo" }, { $0.priorityRaw = "high" },
            { $0.createdAt += 1 }, { $0.updatedAt += 1 }, { $0.completedAt = nil }, { $0.manualOrder = 11 },
            { $0.parentID = UUID() }, { $0.imageReferencesData = Data([7]) }, { $0.deletedAt = self.old },
            { $0.deletionRootID = UUID() }, { $0.deletionMembersRaw = "other" },
            { $0.removedAttachmentsData = Data([1]) }, { $0.doneLoggedAt = self.old },
            { $0.tagsRaw = "work" }, { $0.dueDayRaw = "2026-01-01" }, { $0.dueTimeMinutesRaw = 0 },
            { $0.completedFromRaw = "inProgress" }, { $0.completedFromOrder = 1 }
        ]
        var rows: [TaskItem] = []
        for change in variants {
            let a = done("Café"), b = done("Café", id: a.id)
            change(b); rows += [a, b]
        }
        let agreed = done("Agreed"), twin = done("Agreed", id: agreed.id)
        let container = try seed(rows + [agreed, twin])
        let service = PhoneDoneCleanup(container: container)
        XCTAssertEqual(try service.perform(at: now, calendar: calendar()), 1)
        let reader = ModelContext(container)
        let stored = try reader.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(stored.count, 2 * (variants.count + 1))
        XCTAssertEqual(stored.filter { $0.doneLoggedAt == now }.map(\.id), [agreed.id, agreed.id])
        XCTAssertEqual(stored.filter { $0.doneLoggedAt == old }.count, 1)
    }

    func testLiveFamilyMovesTogetherAndDeletedChildStaysDeleted() throws {
        let root = done("Root"), first = done("Earlier child", parent: root.id)
        let last = done("Last child", parent: root.id); last.status = .inProgress; last.completedAt = nil
        let deleted = done("Independently deleted", parent: root.id); deleted.deletedAt = old
        let orphan = done("Missing parent", parent: UUID())
        let replica = done("Earlier child", id: first.id, parent: root.id)
        let container = try seed([root, first, replica, last, deleted, orphan])
        let service = PhoneDoneCleanup(container: container), utc = try calendar()
        XCTAssertEqual(try service.perform(at: now, calendar: utc), 0)
        let writer = ModelContext(container), id = last.id
        let current = try XCTUnwrap(writer.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
        current.status = .done; current.completedAt = now; try writer.save()
        XCTAssertEqual(try service.perform(at: now, calendar: utc), 0)
        let tomorrow = try XCTUnwrap(utc.date(byAdding: .day, value: 1, to: now))
        XCTAssertEqual(try service.perform(at: tomorrow, calendar: utc), 3)
        XCTAssertEqual(Set(try service.history().map(\.id)), [root.id, first.id, last.id])
        let reader = ModelContext(container), rows = try reader.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(rows.filter { $0.doneLoggedAt == tomorrow }.count, 4)
        XCTAssertEqual(rows.first { $0.id == deleted.id }?.deletedAt, old)
        XCTAssertNil(rows.first { $0.id == deleted.id }?.doneLoggedAt)
        XCTAssertNil(rows.first { $0.id == orphan.id }?.doneLoggedAt)
    }

    func testReparentedAndPartlyDeletedReplicasBlockTheirFamilies() throws {
        let a = done("A"), b = done("B"), c = done("C")
        let child = done("Child", parent: a.id), elsewhere = done("Child", id: child.id, parent: b.id)
        let sibling = done("Sibling", parent: b.id)
        let hidden = done("Other child", parent: c.id); hidden.deletedAt = old
        // A link-only fetch sees just the deleted copy below C. Its live counterpart
        // has no parent and isn't a Done candidate; it must still veto the move.
        let detached = done("Other child", id: hidden.id); detached.status = .todo
        let independent = done("Unrelated")
        let container = try seed([a, b, c, child, elsewhere, sibling, hidden, detached, independent])
        let service = PhoneDoneCleanup(container: container)
        XCTAssertEqual(try service.perform(at: now, calendar: calendar()), 1)
        XCTAssertEqual(try service.history().map(\.id), [independent.id])
    }

    func testHistoryResolvesReplicasBeforeFilteringAndOrdersByCompletion() throws {
        let aID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let bID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let a = done("A", id: aID), b = done("B", id: bID), twin = done("A", id: aID)
        let legacy = done("No completion date"); legacy.completedAt = nil; legacy.updatedAt = now
        let stale = done("Logged"), newer = done("Now live", id: stale.id); newer.updatedAt = now
        let staleDeleted = done("Before deletion"), deleted = done("Deleted", id: staleDeleted.id)
        deleted.updatedAt = now; deleted.deletedAt = now
        let tie = done("A logged"), winningLive = done("Z live", id: tie.id)
        for task in [b, legacy, a, twin, stale, staleDeleted, tie] { task.doneLoggedAt = old }
        let container = try seed([b, legacy, a, twin, stale, newer, staleDeleted, deleted, tie, winningLive])
        let service = PhoneDoneCleanup(container: container)
        XCTAssertEqual(try service.history().map(\.id), [legacy.id, aID, bID])
        XCTAssertEqual(Set(try PhoneLibrary(container: container).tasks().map(\.id)), [newer.id, winningLive.id])
    }

    func testLoggingPreservesCompletionOriginAttachmentsAndNoteHistory() throws {
        let root = done("Keep"), references = Data([0, 128, 255]), removed = Data([1, 2])
        root.completedFromRaw = TaskStatus.inProgress.rawValue; root.completedFromOrder = 42
        root.manualOrder = 77; root.tags = ["Work"]; root.priority = .high
        root.imageReferencesData = references; root.removedAttachmentsData = removed
        let container = try seed([root]), writer = ModelContext(container)
        let note = NoteItem(title: "Writing", body: "Preserve"); note.taskID = root.id
        let content = try XCTUnwrap(note.content), revision = UUID(); note.revisionID = revision
        let version = NoteVersion(noteID: note.id, createdAt: old, reason: .leave, content: content,
            contentFormat: note.contentFormat, title: note.title, body: note.body, attachmentIDs: [], sourceRevisionID: revision)
        writer.insert(note); writer.insert(version); try writer.save()
        let service = PhoneDoneCleanup(container: container)
        XCTAssertEqual(try service.perform(at: now, calendar: calendar()), 1)
        let reader = ModelContext(container), row = try XCTUnwrap(reader.fetch(FetchDescriptor<TaskItem>()).first)
        XCTAssertEqual(row.doneLoggedAt, now); XCTAssertEqual(row.completedAt, old); XCTAssertEqual(row.updatedAt, old)
        XCTAssertEqual(row.status, .done); XCTAssertEqual(row.completedFromRaw, "inProgress"); XCTAssertEqual(row.completedFromOrder, 42)
        XCTAssertEqual(row.manualOrder, 77); XCTAssertEqual(row.tags, ["work"]); XCTAssertEqual(row.priority, .high)
        XCTAssertEqual(row.imageReferencesData, references); XCTAssertEqual(row.removedAttachmentsData, removed)
        let storedNote = try XCTUnwrap(reader.fetch(FetchDescriptor<NoteItem>()).first)
        XCTAssertEqual(storedNote.taskID, root.id); XCTAssertEqual(storedNote.content, content); XCTAssertEqual(storedNote.revisionID, revision)
        let versions = try reader.fetch(FetchDescriptor<NoteVersion>())
        XCTAssertEqual(versions.map(\.id), [version.id]); XCTAssertEqual(versions.first?.content, content)
    }

    func testSaveFailureRollsBackWholePassAndRetryIsIdempotent() throws {
        enum Refusal: Error { case save }
        let root = done("Parent"), child = done("Child", parent: root.id), other = done("Independent")
        let container = try seed([root, child, other]), utc = try calendar()
        let unrelated = ModelContext(container); unrelated.autosaveEnabled = false
        unrelated.insert(TaskItem(title: "Draft"))
        var calls = 0, refusedContext: ModelContext?
        let service = PhoneDoneCleanup(container: container, save: { context in
            calls += 1
            if calls == 1 {
                refusedContext = context
                let rows = try context.fetch(FetchDescriptor<TaskItem>())
                XCTAssertEqual(rows.count, 3); XCTAssertTrue(rows.allSatisfy { $0.doneLoggedAt == self.now })
                throw Refusal.save
            }
            try context.save()
        })
        XCTAssertThrowsError(try service.perform(at: now, calendar: utc)) { XCTAssertTrue($0 is Refusal) }
        XCTAssertEqual(refusedContext?.hasChanges, false); XCTAssertTrue(unrelated.hasChanges)
        XCTAssertTrue(try service.history().isEmpty)
        XCTAssertEqual(try PhoneLibrary(container: container).tasks().count, 3)
        XCTAssertEqual(try service.perform(at: now, calendar: utc), 3)
        XCTAssertEqual(try service.perform(at: now, calendar: utc), 0)
        XCTAssertEqual(calls, 2); XCTAssertTrue(unrelated.hasChanges)
    }
}
#endif
