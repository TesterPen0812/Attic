import XCTest
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
@testable import Attic

final class TaskStoreTests: XCTestCase {
    func testTaskPriorityIndicatorColoursKeepEstablishedMapping() {
        assertSameSRGBColor(TaskPriority.none.color, Color.secondary.opacity(0.5))
        assertSameSRGBColor(TaskPriority.low.color, .blue)
        assertSameSRGBColor(TaskPriority.medium.color, .orange)
        assertSameSRGBColor(TaskPriority.high.color, .red)
    }

    @MainActor
    func testAgentAccessRequiresExplicitOptInOnlyOnce() {
        let suiteName = "AtticTests.AgentAccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialSettings = AppSettings(defaults: defaults)
        XCTAssertFalse(initialSettings.isAgentAccessEnabled)

        initialSettings.isAgentAccessEnabled = true
        let reloadedSettings = AppSettings(defaults: defaults)
        XCTAssertTrue(reloadedSettings.isAgentAccessEnabled)
    }

    func testTaskDragPayloadExportsInternalDataAndPlainText() {
        let declaredTypes = Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        XCTAssertTrue(declaredTypes?.contains(where: {
            $0["UTTypeIdentifier"] as? String == TaskDragPayload.internalTaskType.identifier
        }) == true, "The real test host must export the same task drag type as Attic")
        let taskID = UUID()
        let payload = TaskDragPayload(taskID: taskID, title: "Paste me")
        let provider = payload.itemProvider()

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(
            TaskDragPayload.internalTaskType.identifier
        ))

        let internalIDLoaded = expectation(description: "Internal task identity loads")
        XCTAssertTrue(TaskDragPayload.loadTaskID(from: [provider]) { loadedID in
            XCTAssertEqual(loadedID, taskID)
            internalIDLoaded.fulfill()
        })

        let plainTextLoaded = expectation(description: "Plain-text drag representation loads")
        provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(data, Data("Paste me".utf8))
            plainTextLoaded.fulfill()
        }
        wait(for: [internalIDLoaded, plainTextLoaded], timeout: 1)

    }

    @MainActor
    func testCreateNormalizesTitleAndRejectsEmptyInput() throws {
        let store = try makeTestStore()

        XCTAssertNil(store.create(title: "   \n  "))
        let task = store.create(title: "  Write   release\nnotes  ")

        XCTAssertEqual(task?.title, "Write release notes")
        XCTAssertEqual(task?.status, .todo)
        XCTAssertEqual(task?.priority, TaskPriority.none)
        XCTAssertEqual(store.tasks.count, 1)
    }

    @MainActor
    func testCreateReportsPersistenceFailureAndRollsBack() throws {
        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = try makeTestStore(persist: gate.save)

        XCTAssertNil(store.create(title: "Must not disappear"))
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    /// Every message carries the surface that owns it. While the owner was a
    /// second property that only cleared when the message became nil, a general
    /// failure after a family-scoped one inherited that family: the main banner
    /// suppressed it (`lastErrorOwnerID != nil`) and a closed family panel could
    /// not show it either, so the user saw nothing at all.
    @MainActor
    func testLaterErrorsNeverInheritAnEarlierOperationsOwner() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let familyA = try XCTUnwrap(store.create(title: "Family A"))
        let familyB = try XCTUnwrap(store.create(title: "Family B"))

        // A family-scoped failure: creating a subtask of family A.
        gate.shouldFail = true
        XCTAssertNil(store.create(title: "Step", parentID: familyA.id))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.lastErrorOwnerID, familyA.id)

        // A general failure follows. It belongs to the main panel, not to the
        // family that happened to fail first.
        XCTAssertFalse(store.rename(familyB, to: "Renamed"))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertNil(store.lastErrorOwnerID,
                     "a general save failure must not stay attached to family A")

        // A different family's failure takes ownership from the general one.
        XCTAssertNil(store.create(title: "Step", parentID: familyB.id))
        XCTAssertEqual(store.lastErrorOwnerID, familyB.id)

        // A general delete failure releases the family again.
        XCTAssertFalse(store.delete(familyA))
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertNil(store.lastErrorOwnerID)

        // Success clears message and owner together, as does dismissal.
        gate.shouldFail = false
        XCTAssertTrue(store.rename(familyB, to: "Renamed"))
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertNil(store.lastErrorOwnerID)

        gate.shouldFail = true
        XCTAssertNil(store.create(title: "Step", parentID: familyB.id))
        XCTAssertEqual(store.lastErrorOwnerID, familyB.id)
        store.dismissError()
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertNil(store.lastErrorOwnerID)
    }

    /// The refusals that are not persistence failures follow the same rule: a
    /// stale family owner must not hide them from the main banner.
    @MainActor
    func testStatusAndDeletionRefusalsAreOwnedByTheMainPanel() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        _ = try XCTUnwrap(store.create(title: "Step", parentID: parent.id))

        // Take ownership with a family-scoped failure first.
        gate.shouldFail = true
        XCTAssertNil(store.create(title: "Another step", parentID: parent.id))
        XCTAssertEqual(store.lastErrorOwnerID, parent.id)
        gate.shouldFail = false

        XCTAssertFalse(store.setStatus(.done, for: parent))
        XCTAssertEqual(store.lastErrorMessage, "Finish the subtasks before completing this task.")
        XCTAssertNil(store.lastErrorOwnerID, "the main banner must show the refusal")
    }

    /// Every mutation a family panel can start had to learn its owner, not
    /// just subtask creation. A child's rename, priority, status, reorder,
    /// attachment removal and deletion all failed with `owner` nil, so the
    /// message went to the main banner while the user was looking at the
    /// family panel that had just refused them — and `SubtaskPanelContent`
    /// shows a message only when it owns it.
    @MainActor
    func testChildMutationFailuresAreOwnedByTheFamilyPanelThatShowsThem() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let childID = try XCTUnwrap(store.create(title: "Step", parentID: parent.id)).id
        let siblingID = try XCTUnwrap(store.create(title: "Other step", parentID: parent.id)).id

        // Attached through a successful save, because every refused save below
        // rolls back and reloads: a row edited in place would not survive.
        let reference = TaskImageReference(
            id: UUID(), filename: "a.png", digest: "digest",
            contentTypeIdentifier: UTType.png.identifier, byteCount: 1
        )
        try XCTUnwrap(store.task(withID: childID)).imageReferencesData =
            try JSONEncoder().encode([reference])
        // A different title, so the edit really is written: an update that
        // changes nothing returns true without saving, and the reference would
        // then only exist on the in-memory row.
        XCTAssertTrue(store.rename(try XCTUnwrap(store.task(withID: childID)),
                                   to: "Step with an attachment"))
        XCTAssertEqual(gate.saveCount, 4, "the attachment reached the store")
        store.refresh()
        XCTAssertEqual(try XCTUnwrap(store.task(withID: childID)).attachments, [reference])

        // Each operation is attempted from a cleared notice and against the
        // freshly reloaded row, so a passing owner can only have come from
        // that operation.
        func assertOwnedByFamily(
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ operation: (TaskItem) -> Bool
        ) throws {
            store.dismissError()
            let child = try XCTUnwrap(store.task(withID: childID), file: file, line: line)
            gate.shouldFail = true
            XCTAssertFalse(operation(child), "\(label) must fail while saving is refused",
                           file: file, line: line)
            gate.shouldFail = false
            XCTAssertNotNil(store.lastErrorMessage, "\(label) reported nothing", file: file, line: line)
            XCTAssertEqual(store.lastErrorOwnerID, parent.id,
                           "\(label) belongs to the family panel it happened in",
                           file: file, line: line)
        }

        try assertOwnedByFamily("rename") { store.rename($0, to: "Renamed step") }
        try assertOwnedByFamily("priority") { store.setPriority(.high, for: $0) }
        try assertOwnedByFamily("status") { store.setStatus(.done, for: $0) }
        try assertOwnedByFamily("attachment removal") {
            store.removeAttachment(reference.id, from: $0.id)
        }
        try assertOwnedByFamily("reorder") {
            store.reorder(taskID: $0.id, relativeTo: siblingID)
        }
        try assertOwnedByFamily("delete") { store.delete($0) }
    }

    /// The refusals a family panel raises are not save failures, and they were
    /// the other half of the same problem: a child that cannot be reopened, or
    /// cannot be deleted safely, said so on the main banner.
    @MainActor
    func testChildRefusalsAreOwnedByTheFamilyPanelThatRaisedThem() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Step", parentID: parent.id))

        // Completing the family completes its child too, then reopening the
        // child alone is refused — a refusal the family panel must show.
        XCTAssertTrue(store.setStatus(.done, for: child))
        XCTAssertTrue(store.setStatus(.done, for: parent))
        store.dismissError()
        XCTAssertFalse(store.setStatus(.todo, for: child))
        XCTAssertEqual(store.lastErrorMessage, "Reopen the main task before reopening a subtask.")
        XCTAssertEqual(store.lastErrorOwnerID, parent.id)

        // And a subtask of a finished family is refused in that family too.
        store.dismissError()
        XCTAssertNil(store.create(title: "Another step", parentID: parent.id))
        XCTAssertEqual(store.lastErrorMessage,
                       "Subtasks need an unfinished main task. Reopen the main task first.")
        XCTAssertEqual(store.lastErrorOwnerID, parent.id)
    }

    /// Ownership follows what the user can see, which is what `parent(of:)`
    /// and the family index already decide: an orphaned, self-linked or
    /// nested link is presented as a root, and its failures therefore belong
    /// to the main banner. Naming a family with no panel would hide the
    /// message from every surface — the bug this ownership exists to prevent.
    @MainActor
    func testFailuresOnRootsAndOrphanedLinksStayWithTheMainPanel() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        // Links no live top-level parent validates — exactly what a malformed
        // import can produce, and what the store keeps visible as roots rather
        // than hiding. Seeded through their own context so the store reads
        // them as stored data.
        let seed = ModelContext(container)
        let rootID = UUID(), orphanID = UUID(), selfLinkedID = UUID(), childID = UUID()
        let parentID = UUID()
        seed.insert(TaskItem(id: rootID, title: "Root"))
        seed.insert(TaskItem(id: orphanID, title: "Orphan", parentID: UUID()))
        seed.insert(TaskItem(id: selfLinkedID, title: "Self linked", parentID: selfLinkedID))
        // A valid family, as the contrast: its child is the one row that is
        // only reachable inside a family panel.
        seed.insert(TaskItem(id: parentID, title: "Parent"))
        seed.insert(TaskItem(id: childID, title: "Step", parentID: parentID))
        try seed.save()

        let gate = PersistenceGate()
        let store = TaskStore(container: container, persist: gate.save)
        XCTAssertEqual(store.tasks.count, 5, "no row is hidden by an invalid link")

        for (id, label) in [(rootID, "a root"), (orphanID, "an orphaned link"),
                            (selfLinkedID, "a self link")] {
            let visible = try XCTUnwrap(store.tasks.first { $0.id == id })
            store.dismissError()
            gate.shouldFail = true
            XCTAssertFalse(store.rename(visible, to: "Renamed \(label)"))
            gate.shouldFail = false
            XCTAssertNotNil(store.lastErrorMessage)
            XCTAssertNil(store.lastErrorOwnerID,
                         "\(label) is presented as a root, so the main panel owns its failure")

            store.dismissError()
            gate.shouldFail = true
            XCTAssertFalse(store.delete(visible))
            gate.shouldFail = false
            XCTAssertNotNil(store.lastErrorMessage)
            XCTAssertNil(store.lastErrorOwnerID)
        }

        // The validated child is the case that does name a family, so the
        // assertions above are about the link rule and not about nil always
        // being the answer.
        let child = try XCTUnwrap(store.tasks.first { $0.id == childID })
        store.dismissError()
        gate.shouldFail = true
        XCTAssertFalse(store.rename(child, to: "Renamed step"))
        gate.shouldFail = false
        XCTAssertEqual(store.lastErrorOwnerID, parentID)

        // The global done-task sweep is nobody's family.
        store.dismissError()
        gate.shouldFail = true
        XCTAssertTrue(store.setStatus(.done, for: try XCTUnwrap(store.tasks.first { $0.id == rootID })) == false)
        gate.shouldFail = false
        XCTAssertNil(store.lastErrorOwnerID)
    }

    /// A parent's row exists in the main panel as well as in its own family
    /// panel, and a failed import does not open that panel, so an attachment
    /// failure aimed at a parent belongs to the main banner. A child's belongs
    /// to the family panel its row lives in. The files still go to the parent
    /// either way — that owner is a storage decision, not a presentation one.
    @MainActor
    func testAttachmentFailureOwnerFollowsTheRowTheUserActedOn() async throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let child = try XCTUnwrap(store.create(title: "Step", parentID: parent.id))
        XCTAssertEqual(store.attachmentOwnerID(for: child.id), parent.id,
                       "the files themselves still belong to the parent")

        struct Refused: Error {}
        store.dismissError()
        let fromParent = await store.attachStagedFiles(to: parent.id) { throw Refused() }
        XCTAssertNil(fromParent)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertNil(store.lastErrorOwnerID, "the main panel owns a parent row's failure")

        store.dismissError()
        let fromChild = await store.attachStagedFiles(to: child.id) { throw Refused() }
        XCTAssertNil(fromChild)
        XCTAssertNotNil(store.lastErrorMessage)
        XCTAssertEqual(store.lastErrorOwnerID, parent.id,
                       "a child row is only reachable inside its family panel")
    }

    @MainActor
    func testRefreshSeesChangesSavedByAnotherModelContext() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let externalContext = ModelContext(container)
        let externalTask = TaskItem(title: "Created elsewhere", priority: .low)

        externalContext.insert(externalTask)
        try externalContext.save()
        store.refresh()

        let imported = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(imported.id, externalTask.id)
        XCTAssertEqual(imported.title, "Created elsewhere")

        externalTask.title = "Updated elsewhere"
        externalTask.updatedAt = Date(timeIntervalSince1970: 2_000)
        try externalContext.save()
        store.refresh()

        XCTAssertEqual(try XCTUnwrap(store.tasks.first).title, "Updated elsewhere")
    }

    #if ATTIC_LOCAL_ONLY
    /// The deferred CloudKit machinery must stay dormant in local-only
    /// builds, exactly like NoteStore and CanvasStore: no observers, no
    /// event handling, no App Nap assertions after a local save.
    @MainActor
    func testLocalOnlyTasksDoNotStartDeferredCloudActivity() async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let initialStatus = store.cloudSyncStatus
        XCTAssertNotNil(store.create(title: "Local save"))
        let externalContext = ModelContext(container)
        let externalTask = try XCTUnwrap(externalContext.fetch(FetchDescriptor<TaskItem>()).first)
        externalTask.title = "External change"
        externalTask.updatedAt = Date().addingTimeInterval(1)
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
        XCTAssertEqual(store.tasks.first?.title, "Local save", "Deferred events cannot reload local-only tasks")
        store.refresh()
        XCTAssertEqual(store.tasks.first?.title, "External change", "Explicit refresh still replaces stale contexts")
    }
    #endif

    /// The per-revision family index must answer exactly like a full scan
    /// after every mutation path, including ones that change sort order
    /// in place and ones that fail and roll back.
    @MainActor
    func testFamilyIndexStaysCoherentAcrossEveryMutationPath() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let other = try XCTUnwrap(store.create(title: "Other"))
        let first = try XCTUnwrap(store.create(title: "First", parentID: parent.id))
        let second = try XCTUnwrap(store.create(title: "Second", parentID: parent.id))
        func scanned(_ id: UUID) -> [UUID] {
            store.tasks.filter { $0.parentID == id }.sorted {
                if ($0.status == .done) != ($1.status == .done) { return $0.status != .done }
                if $0.manualOrder != $1.manualOrder { return ($0.manualOrder ?? 0) > ($1.manualOrder ?? 0) }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }.map(\.id)
        }
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), scanned(parent.id))
        XCTAssertTrue(store.hasSubtasks(parent.id))
        XCTAssertFalse(store.hasSubtasks(other.id))
        XCTAssertEqual(store.task(withID: first.id)?.id, first.id)
        XCTAssertEqual(store.parent(of: first)?.id, parent.id)

        // A status change re-sorts children in place.
        XCTAssertTrue(store.setStatus(.done, for: first))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [second.id, first.id])
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), scanned(parent.id))

        // A failed save rolls back and the index follows the reload.
        gate.shouldFail = true
        XCTAssertFalse(store.setStatus(.done, for: second))
        gate.shouldFail = false
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), scanned(parent.id))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.status), [.todo, .done])

        // Deletion and external refresh both invalidate it.
        XCTAssertTrue(store.delete(store.task(withID: second.id)!))
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [first.id])
        XCTAssertNil(store.task(withID: second.id))
        store.refresh()
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [first.id])
        XCTAssertTrue(store.delete(store.task(withID: parent.id)!))
        XCTAssertFalse(store.hasSubtasks(parent.id))
        XCTAssertTrue(store.subtasks(of: parent.id).isEmpty)
        XCTAssertEqual(store.tasks.map(\.id), [other.id])
    }

    /// Orphaned or self-referencing links never count as children; they stay
    /// visible as roots, the same as the scan-based rule they replace.
    @MainActor
    func testFamilyIndexIgnoresOrphanedAndNestedLinks() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let parentID = UUID(), childID = UUID(), grandchildID = UUID()
        seed.insert(TaskItem(id: parentID, title: "Parent"))
        seed.insert(TaskItem(id: childID, title: "Child", parentID: parentID))
        seed.insert(TaskItem(id: grandchildID, title: "Grandchild", parentID: childID))
        seed.insert(TaskItem(title: "Orphan", parentID: UUID()))
        let selfID = UUID()
        seed.insert(TaskItem(id: selfID, title: "Self", parentID: selfID))
        try seed.save()
        let store = TaskStore(container: container)
        XCTAssertEqual(store.subtasks(of: parentID).map(\.id), [childID])
        XCTAssertTrue(store.subtasks(of: childID).isEmpty, "a child is not a valid root, so its link is orphaned")
        XCTAssertNil(store.parent(of: store.task(withID: grandchildID)!))
        XCTAssertNil(store.parent(of: store.task(withID: selfID)!))
        let roots = store.snapshot(for: .tasks).sections.flatMap { $0.tasks.map(\.title) }
        XCTAssertEqual(Set(roots), ["Parent", "Grandchild", "Orphan", "Self"])
    }

    /// Status validation reads only the rows it concerns and still applies
    /// to replicas the visible list hides.
    @MainActor
    func testCompletionAndReopenRulesStillSeeHiddenReplicas() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let parentID = UUID(), childID = UUID()
        seed.insert(TaskItem(id: parentID, title: "Parent"))
        seed.insert(TaskItem(id: childID, title: "Child", updatedAt: Date(timeIntervalSince1970: 10), parentID: parentID))
        // A hidden replica of the child is still unfinished.
        seed.insert(TaskItem(id: childID, title: "Child", status: .done,
                             updatedAt: Date(timeIntervalSince1970: 20), parentID: parentID))
        try seed.save()
        let store = TaskStore(container: container)
        XCTAssertEqual(store.task(withID: childID)?.status, .done, "the newer replica is the visible one")
        XCTAssertFalse(store.setStatus(.done, for: store.task(withID: parentID)!),
                       "an unfinished hidden replica still blocks completion")
        XCTAssertEqual(store.lastErrorMessage, "Finish the subtasks before completing this task.")
        XCTAssertTrue(store.setStatus(.done, for: store.task(withID: parentID)!, allowingUnfinishedSubtasks: true))
        XCTAssertFalse(store.setStatus(.todo, for: store.task(withID: childID)!),
                       "a done parent refuses reopening a child")
        XCTAssertTrue(store.rename(store.task(withID: childID)!, to: "Child renamed"),
                      "edits that change no status never consult the status rules")
    }

    @MainActor
    func testDeleteRefusesNestedLinksWithoutReadingUnrelatedRows() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let parentID = UUID(), childID = UUID()
        seed.insert(TaskItem(id: parentID, title: "Parent"))
        seed.insert(TaskItem(id: childID, title: "Child", parentID: parentID))
        seed.insert(TaskItem(title: "Grandchild", parentID: childID))
        seed.insert(TaskItem(title: "Unrelated"))
        try seed.save()
        let store = TaskStore(container: container)
        XCTAssertFalse(store.delete(store.task(withID: parentID)!))
        XCTAssertEqual(store.lastErrorMessage, "An unsupported nested or cyclic subtask link prevents safe deletion.")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count, 4)
    }

    @MainActor
    func testSuccessfulCloudImportRefreshesChangesSavedOutsideStoreContext() async throws {
        #if ATTIC_LOCAL_ONLY
        throw XCTSkip("Deferred CloudKit import handling is dormant in local-only builds.")
        #endif
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        seedContext.insert(TaskItem(title: "Before iPhone update", priority: .high))
        try seedContext.save()

        let store = TaskStore(container: container)
        XCTAssertEqual(store.tasks.map(\.title), ["Before iPhone update"])

        let externalContext = ModelContext(container)
        let importedTask = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<TaskItem>()).first
        )
        importedTask.title = "Updated from iPhone"
        importedTask.updatedAt = Date()
        try externalContext.save()
        XCTAssertEqual(store.tasks.map(\.title), ["Before iPhone update"])

        store.handleCloudSyncEvent(CloudSyncEventUpdate(
            id: UUID(),
            kind: .importData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(store.tasks.map(\.title), ["Updated from iPhone"])
    }

    @MainActor
    func testRefreshHidesDuplicateApplicationIDsWithoutDeletingEitherRow() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        let older = TaskItem(
            id: sharedID,
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = TaskItem(
            id: sharedID,
            title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        context.insert(older)
        context.insert(newer)
        try context.save()

        let store = TaskStore(container: container)

        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertEqual(store.tasks.first?.title, "Newer")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 2)
    }

    @MainActor
    func testEqualTimestampDuplicatesAreHiddenWithoutCrossDeviceDeletion() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        let timestamp = Date(timeIntervalSince1970: 2_000)
        context.insert(TaskItem(id: sharedID, title: "Alpha", updatedAt: timestamp))
        context.insert(TaskItem(id: sharedID, title: "Beta", updatedAt: timestamp))
        try context.save()

        let store = TaskStore(container: container)

        XCTAssertEqual(store.tasks.map(\.title), ["Beta"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 2)
        store.refresh()
        XCTAssertEqual(store.tasks.map(\.title), ["Beta"])
    }

    @MainActor
    func testMutationsAndDeleteApplyToEveryPhysicalDuplicate() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        let sharedID = UUID()
        seedContext.insert(TaskItem(id: sharedID, title: "Older", priority: .low))
        seedContext.insert(TaskItem(
            id: sharedID,
            title: "Visible",
            priority: .medium,
            updatedAt: Date().addingTimeInterval(1)
        ))
        try seedContext.save()
        let store = TaskStore(container: container)
        let visible = try XCTUnwrap(store.tasks.first)

        XCTAssertTrue(store.update(visible, title: "Unified", priority: .high, status: .done))
        var verificationContext = ModelContext(container)
        var replicas = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(replicas.count, 2)
        XCTAssertTrue(replicas.allSatisfy {
            $0.title == "Unified"
                && $0.priority == .high
                && $0.status == .done
                && $0.completedAt != nil
        })

        XCTAssertTrue(store.delete(try XCTUnwrap(store.tasks.first)))
        verificationContext = ModelContext(container)
        replicas = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(replicas.isEmpty)
    }

    @MainActor
    func testExactDuplicateSelectionStaysStableAcrossRefreshes() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seedContext = ModelContext(container)
        let sharedID = UUID()
        let timestamp = Date(timeIntervalSince1970: 2_000)
        seedContext.insert(TaskItem(id: sharedID, title: "Same", updatedAt: timestamp))
        seedContext.insert(TaskItem(id: sharedID, title: "Same", updatedAt: timestamp))
        try seedContext.save()
        let store = TaskStore(container: container)
        let selectedID = try XCTUnwrap(store.tasks.first?.persistentModelID)

        for _ in 0..<5 {
            store.refresh()
            XCTAssertEqual(store.tasks.first?.persistentModelID, selectedID)
        }
    }

    @MainActor
    func testRemoteDeletionMakesCapturedTaskReferencesNoOps() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let capturedTask = try XCTUnwrap(store.create(title: "Deleted elsewhere"))
        let externalContext = ModelContext(container)
        let externalTask = try XCTUnwrap(
            try externalContext.fetch(FetchDescriptor<TaskItem>()).first
        )
        externalContext.delete(externalTask)
        try externalContext.save()
        store.refresh()

        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertFalse(store.update(capturedTask, title: "Resurrected"))
        XCTAssertFalse(store.delete(capturedTask))
        XCTAssertFalse(store.performPrimaryAction(capturedTask))
    }

    @MainActor
    func testRefreshNeverPersistsDuplicateCleanup() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let sharedID = UUID()
        context.insert(TaskItem(id: sharedID, title: "Older"))
        context.insert(TaskItem(id: sharedID, title: "Newer", updatedAt: Date().addingTimeInterval(1)))
        try context.save()

        let gate = PersistenceGate()
        gate.shouldFail = true
        let store = TaskStore(container: container, persist: gate.save)

        XCTAssertEqual(store.tasks.map(\.title), ["Newer"])
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 2)
    }

    func testCloudConfigurationsUseSeparateEnvironmentStores() {
        let legacy = ModelConfiguration(isStoredInMemoryOnly: false)
        let production = PersistenceController.makeConfiguration(environment: .production)
        let development = PersistenceController.makeConfiguration(environment: .development)
        let inMemory = PersistenceController.makeConfiguration(inMemory: true)

        XCTAssertEqual(production.url, legacy.url)
        XCTAssertNotEqual(development.url, production.url)
        XCTAssertEqual(development.url.lastPathComponent, "development.store")
        XCTAssertEqual(
            production.cloudKitContainerIdentifier,
            PersistenceController.cloudKitContainerIdentifier
        )
        XCTAssertEqual(
            development.cloudKitContainerIdentifier,
            PersistenceController.cloudKitContainerIdentifier
        )
        XCTAssertNil(inMemory.cloudKitContainerIdentifier)
    }

    func testDevelopmentFallbackWithoutCloudKitKeepsDevelopmentStore() {
        let production = PersistenceController.makeConfiguration(
            cloudSyncEnabled: false,
            environment: .production
        )
        let development = PersistenceController.makeConfiguration(
            cloudSyncEnabled: false,
            environment: .development
        )

        XCTAssertEqual(production.url.lastPathComponent, "default.store")
        XCTAssertEqual(development.url.lastPathComponent, "development.store")
        XCTAssertNil(production.cloudKitContainerIdentifier)
        XCTAssertNil(development.cloudKitContainerIdentifier)
    }

    @MainActor
    func testFailedEditsRestorePersistedValues() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let task = try XCTUnwrap(store.create(title: "Original", priority: .low))
        gate.shouldFail = true

        XCTAssertFalse(store.rename(task, to: "Changed"))
        XCTAssertEqual(try XCTUnwrap(store.tasks.first).title, "Original")

        let afterRename = try XCTUnwrap(store.tasks.first)
        XCTAssertFalse(store.setPriority(.high, for: afterRename))
        XCTAssertEqual(try XCTUnwrap(store.tasks.first).priority, .low)

        let afterPriority = try XCTUnwrap(store.tasks.first)
        XCTAssertFalse(store.setStatus(.done, for: afterPriority))
        let restored = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(restored.status, .todo)
        XCTAssertNil(restored.completedAt)
    }

    @MainActor
    func testAtomicUpdateRollsBackEveryFieldOnPersistenceFailure() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let task = try XCTUnwrap(store.create(title: "Original", priority: .low))
        gate.shouldFail = true

        XCTAssertFalse(store.update(task, title: "Changed", priority: .high, status: .done))

        let restored = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(restored.title, "Original")
        XCTAssertEqual(restored.priority, .low)
        XCTAssertEqual(restored.status, .todo)
        XCTAssertNil(restored.completedAt)
    }

    @MainActor
    func testFailedDeleteRestoresTask() throws {
        let gate = PersistenceGate()
        let store = try makeTestStore(persist: gate.save)
        let task = try XCTUnwrap(store.create(title: "Keep me"))
        gate.shouldFail = true

        XCTAssertFalse(store.delete(task))
        XCTAssertEqual(store.tasks.map(\.title), ["Keep me"])
    }

    @MainActor
    func testFailedReorderRestoresOriginalOrder() throws {
        let gate = PersistenceGate()
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value }, persist: gate.save)
        let first = try XCTUnwrap(store.create(title: "First", priority: .medium))
        clock.value = Date(timeIntervalSince1970: 1_100)
        let second = try XCTUnwrap(store.create(title: "Second", priority: .medium))
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [second.id, first.id])
        gate.shouldFail = true

        XCTAssertFalse(store.reorder(taskID: second.id, relativeTo: first.id))
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.title), ["Second", "First"])
    }

    @MainActor
    func testTaskTransitionsAndRestoreMaintainCompletionDate() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value })
        let task = try XCTUnwrap(store.create(title: "Build panel", priority: .high))

        clock.value = Date(timeIntervalSince1970: 1_100)
        store.advanceToInProgress(task)
        XCTAssertEqual(task.status, .inProgress)
        XCTAssertNil(task.completedAt)

        clock.value = Date(timeIntervalSince1970: 1_200)
        store.markDone(task)
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.completedAt, clock.value)

        clock.value = Date(timeIntervalSince1970: 1_300)
        store.setStatus(.todo, for: task)
        XCTAssertEqual(task.status, .todo)
        XCTAssertNil(task.completedAt)
    }

    @MainActor
    func testCreatingDoneTaskSetsCompletionDate() throws {
        let timestamp = Date(timeIntervalSince1970: 1_500)
        let store = try makeTestStore(now: { timestamp })

        let task = try XCTUnwrap(store.create(title: "Already finished", status: .done))

        XCTAssertEqual(task.completedAt, timestamp)
    }

    @MainActor
    func testPartialEditFromStaleReferencePreservesImportedFields() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let capturedTask = try XCTUnwrap(store.create(title: "Original", priority: .low))

        let externalContext = ModelContext(container)
        let importedTask = try XCTUnwrap(
            externalContext.fetch(FetchDescriptor<TaskItem>()).first
        )
        importedTask.priority = .high
        importedTask.status = .done
        importedTask.completedAt = Date(timeIntervalSince1970: 2_000)
        importedTask.updatedAt = Date(timeIntervalSince1970: 2_000)
        try externalContext.save()
        store.refresh()

        XCTAssertTrue(store.update(capturedTask, title: "Renamed locally"))
        let saved = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(saved.title, "Renamed locally")
        XCTAssertEqual(saved.priority, .high)
        XCTAssertEqual(saved.status, .done)
        XCTAssertEqual(saved.completedAt, Date(timeIntervalSince1970: 2_000))
    }

    @MainActor
    func testOrderingUsesPriorityThenMostRecentUpdate() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value })
        let low = try XCTUnwrap(store.create(title: "Low", priority: .low))
        clock.value = Date(timeIntervalSince1970: 1_100)
        let highOlder = try XCTUnwrap(store.create(title: "High older", priority: .high))
        clock.value = Date(timeIntervalSince1970: 1_200)
        let highNewer = try XCTUnwrap(store.create(title: "High newer", priority: .high))

        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [highNewer.id, highOlder.id, low.id])

        clock.value = Date(timeIntervalSince1970: 1_300)
        store.rename(highOlder, to: "High most recent")
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [highOlder.id, highNewer.id, low.id])
    }

    @MainActor
    func testNonePrioritySortsAfterLow() throws {
        let store = try makeTestStore()
        let none = try XCTUnwrap(store.create(title: "None", priority: .none))
        let low = try XCTUnwrap(store.create(title: "Low", priority: .low))

        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [low.id, none.id])
    }

    @MainActor
    func testDeleteRemovesTask() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Temporary"))
        store.delete(task)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    @MainActor
    func testPrimaryActionReturnsDoneTaskToTodo() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Toggle me"))

        store.performPrimaryAction(task)
        XCTAssertEqual(task.status, .done)
        XCTAssertNotNil(task.completedAt)

        store.performPrimaryAction(task)
        XCTAssertEqual(task.status, .todo)
        XCTAssertNil(task.completedAt)
    }

    @MainActor
    func testDoubleClickActionMovesBetweenTodoAndInProgress() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Toggle progress"))

        store.performDoubleClickAction(task)
        XCTAssertEqual(task.status, .inProgress)

        store.performDoubleClickAction(task)
        XCTAssertEqual(task.status, .todo)

        store.markDone(task)
        store.performDoubleClickAction(task)
        XCTAssertEqual(task.status, .done)
    }

    @MainActor
    func testBacklogReusesTaskRulesAndPromotesToTodo() throws {
        let store = try makeTestStore()
        let idea = try XCTUnwrap(store.create(
            title: "Explore CloudKit",
            priority: .high,
            status: .backlog
        ))

        XCTAssertEqual(idea.status, .backlog)
        XCTAssertEqual(idea.priority, .high)
        XCTAssertEqual(store.orderedTasks(for: .backlog).map(\.id), [idea.id])

        store.performPrimaryAction(idea)
        XCTAssertEqual(idea.status, .todo)
        XCTAssertNil(idea.completedAt)

        store.setStatus(.backlog, for: idea)
        store.performDoubleClickAction(idea)
        XCTAssertEqual(idea.status, .todo)
    }

    @MainActor
    func testScopeSnapshotIsTheSingleSourceForSectionsAndCounts() throws {
        let store = try makeTestStore()
        _ = store.create(title: "Todo")
        _ = store.create(title: "Progress")
        _ = store.create(title: "Done")
        _ = store.create(title: "Idea", status: .backlog)
        let progress = try XCTUnwrap(store.tasks.first { $0.title == "Progress" })
        let done = try XCTUnwrap(store.tasks.first { $0.title == "Done" })
        store.setStatus(.inProgress, for: progress)
        store.setStatus(.done, for: done)

        let taskSnapshot = store.snapshot(for: .tasks)
        XCTAssertEqual(taskSnapshot.visibleCount, 3)
        XCTAssertEqual(taskSnapshot.activeCount, 2)
        XCTAssertEqual(taskSnapshot.sections.map(\.status), [.inProgress, .todo, .done])

        let backlogSnapshot = store.snapshot(for: .backlog)
        XCTAssertEqual(backlogSnapshot.visibleCount, 1)
        XCTAssertEqual(backlogSnapshot.activeCount, 1)
        XCTAssertEqual(backlogSnapshot.sections.map(\.status), [.backlog])
    }

    @MainActor
    func testSnapshotMemoizationStaysCoherentAcrossMutations() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Cached"))

        XCTAssertEqual(store.snapshot(for: .tasks).visibleCount, 1)
        // Second call between edits must serve the same content (cache hit).
        XCTAssertEqual(store.snapshot(for: .tasks).sections.map(\.status), [.todo])

        store.setStatus(.inProgress, for: task)
        XCTAssertEqual(store.snapshot(for: .tasks).sections.map(\.status), [.inProgress])

        store.setStatus(.backlog, for: task)
        XCTAssertEqual(store.snapshot(for: .tasks).visibleCount, 0)
        XCTAssertEqual(store.snapshot(for: .backlog).visibleCount, 1)

        store.delete(task)
        XCTAssertEqual(store.snapshot(for: .backlog).visibleCount, 0)

        store.refresh()
        XCTAssertEqual(store.snapshot(for: .backlog).visibleCount, 0)
    }

    @MainActor
    func testExternalDragStartsPendingTasksWithoutReopeningDoneTasks() throws {
        let store = try makeTestStore()
        let todo = try XCTUnwrap(store.create(title: "Todo"))
        let backlog = try XCTUnwrap(store.create(title: "Idea", status: .backlog))
        let inProgress = try XCTUnwrap(store.create(title: "Working", status: .inProgress))
        let done = try XCTUnwrap(store.create(title: "Finished", status: .done))

        XCTAssertTrue(store.startAfterExternalDrag(taskID: todo.id))
        XCTAssertEqual(todo.status, .inProgress)

        XCTAssertTrue(store.startAfterExternalDrag(taskID: backlog.id))
        XCTAssertEqual(backlog.status, .inProgress)

        XCTAssertTrue(store.startAfterExternalDrag(taskID: inProgress.id))
        XCTAssertEqual(inProgress.status, .inProgress)

        XCTAssertFalse(store.startAfterExternalDrag(taskID: done.id))
        XCTAssertEqual(done.status, .done)
        XCTAssertFalse(store.startAfterExternalDrag(taskID: UUID()))
    }

    @MainActor
    func testReorderWithinSameStatusAndPriorityPersists() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value })
        let first = try XCTUnwrap(store.create(title: "First", priority: .medium))
        clock.value = Date(timeIntervalSince1970: 1_100)
        let second = try XCTUnwrap(store.create(title: "Second", priority: .medium))
        clock.value = Date(timeIntervalSince1970: 1_200)
        let third = try XCTUnwrap(store.create(title: "Third", priority: .medium))

        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [third.id, second.id, first.id])
        XCTAssertTrue(store.reorder(taskID: third.id, relativeTo: first.id))
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [second.id, first.id, third.id])

        let firstOrder = first.manualOrder
        let secondOrder = second.manualOrder
        XCTAssertTrue(store.reorder(taskID: third.id, relativeTo: second.id))
        XCTAssertEqual(first.manualOrder, firstOrder)
        XCTAssertEqual(second.manualOrder, secondOrder)
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [third.id, second.id, first.id])

        XCTAssertTrue(store.reorder(taskID: third.id, relativeTo: first.id))
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [second.id, first.id, third.id])

        clock.value = Date(timeIntervalSince1970: 1_300)
        store.rename(third, to: "Third renamed")
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [second.id, first.id, third.id])

        clock.value = Date(timeIntervalSince1970: 1_400)
        let newest = try XCTUnwrap(store.create(title: "Newest", priority: .medium))
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [newest.id, second.id, first.id, third.id])

        store.refresh()
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [newest.id, second.id, first.id, third.id])
    }

    @MainActor
    func testDropOntoRowReordersWithinSectionAndRestatusesAcrossSections() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let store = try makeTestStore(now: { clock.value })
        let first = try XCTUnwrap(store.create(title: "First"))
        clock.value = Date(timeIntervalSince1970: 1_100)
        let second = try XCTUnwrap(store.create(title: "Second"))
        clock.value = Date(timeIntervalSince1970: 1_200)
        let finished = try XCTUnwrap(store.create(title: "Finished", status: .done))

        // Same section behaves like a plain reorder.
        XCTAssertTrue(store.drop(taskID: second.id, onto: first.id))
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [first.id, second.id])

        // Another section's row: the task adopts that section's status and
        // lands next to the target row.
        clock.value = Date(timeIntervalSince1970: 1_300)
        XCTAssertTrue(store.drop(taskID: first.id, onto: finished.id))
        XCTAssertEqual(first.status, .done)
        XCTAssertNotNil(first.completedAt)
        XCTAssertEqual(store.orderedTasks(for: .done).map(\.id), [finished.id, first.id])
        XCTAssertEqual(store.orderedTasks(for: .todo).map(\.id), [second.id])

        // A cross-section drop keeps the dragged task's own priority.
        clock.value = Date(timeIntervalSince1970: 1_400)
        let urgent = try XCTUnwrap(store.create(title: "Urgent", priority: .high))
        XCTAssertTrue(store.drop(taskID: urgent.id, onto: finished.id))
        XCTAssertEqual(urgent.status, .done)
        XCTAssertEqual(urgent.priority, .high)

        XCTAssertFalse(store.drop(taskID: second.id, onto: second.id))
        XCTAssertFalse(store.drop(taskID: UUID(), onto: second.id))
        XCTAssertFalse(store.drop(taskID: second.id, onto: UUID()))
    }

    @MainActor
    func testDropIntoSectionChangesStatusOnlyAcrossSections() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Task"))

        XCTAssertTrue(store.drop(taskID: task.id, into: .inProgress))
        XCTAssertEqual(task.status, .inProgress)

        XCTAssertTrue(store.drop(taskID: task.id, into: .done))
        XCTAssertEqual(task.status, .done)
        XCTAssertNotNil(task.completedAt)

        // Dropping back into the section it already lives in is a no-op.
        XCTAssertFalse(store.drop(taskID: task.id, into: .done))
        XCTAssertFalse(store.drop(taskID: UUID(), into: .todo))
    }

    @MainActor
    func testReorderRejectsIncompatibleAndDegenerateDrops() throws {
        let store = try makeTestStore()
        let medium = try XCTUnwrap(store.create(title: "Medium", priority: .medium))
        let high = try XCTUnwrap(store.create(title: "High", priority: .high))
        let anotherMedium = try XCTUnwrap(store.create(title: "Another", priority: .medium))
        store.setStatus(.inProgress, for: anotherMedium)

        XCTAssertFalse(store.reorder(taskID: medium.id, relativeTo: medium.id))
        XCTAssertFalse(store.reorder(taskID: medium.id, relativeTo: high.id))
        XCTAssertFalse(store.reorder(taskID: medium.id, relativeTo: anotherMedium.id))
        XCTAssertFalse(store.reorder(taskID: UUID(), relativeTo: medium.id))
    }

    @MainActor
    func testRebalanceUpdatesManualOrderOnEveryPhysicalReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let firstTimestamp = Date(timeIntervalSince1970: 1_000)
        let secondTimestamp = Date(timeIntervalSince1970: 2_000)
        let thirdTimestamp = Date(timeIntervalSince1970: 3_000)

        context.insert(TaskItem(
            id: firstID,
            title: "First",
            priority: .medium,
            createdAt: firstTimestamp,
            updatedAt: firstTimestamp,
            manualOrder: 1
        ))
        context.insert(TaskItem(
            id: firstID,
            title: "First",
            priority: .medium,
            createdAt: firstTimestamp,
            updatedAt: firstTimestamp,
            manualOrder: 1
        ))
        context.insert(TaskItem(
            id: secondID,
            title: "Second",
            priority: .medium,
            createdAt: secondTimestamp,
            updatedAt: secondTimestamp,
            manualOrder: 1
        ))
        context.insert(TaskItem(
            id: thirdID,
            title: "Third",
            priority: .medium,
            createdAt: thirdTimestamp,
            updatedAt: thirdTimestamp,
            manualOrder: 1
        ))
        try context.save()
        let store = TaskStore(container: container)

        XCTAssertTrue(store.reorder(taskID: firstID, relativeTo: secondID))

        let verificationContext = ModelContext(container)
        let replicas = try verificationContext.fetch(FetchDescriptor<TaskItem>())
        let firstOrders = Set(replicas.filter { $0.id == firstID }.map(\.manualOrder))
        XCTAssertEqual(firstOrders.count, 1)
        XCTAssertEqual(Set(replicas.compactMap(\.manualOrder)).count, 3)
    }

    func testCloudSyncStatusTracksActivitySuccessAndFailure() {
        let importID = UUID()
        let exportID = UUID()
        let importEnd = Date(timeIntervalSince1970: 1_000)
        let exportEnd = Date(timeIntervalSince1970: 2_000)
        var status = CloudSyncStatus()

        status.apply(CloudSyncEventUpdate(
            id: importID,
            kind: .importData,
            endedAt: nil,
            succeeded: false,
            errorMessage: nil
        ))
        XCTAssertTrue(status.isSyncing)
        XCTAssertEqual(status.title, "Syncing…")

        status.apply(CloudSyncEventUpdate(
            id: importID,
            kind: .importData,
            endedAt: importEnd,
            succeeded: true,
            errorMessage: nil
        ))
        XCTAssertFalse(status.isSyncing)
        XCTAssertEqual(status.lastSuccessfulImportAt, importEnd)
        XCTAssertEqual(status.title, "Synced")

        status.apply(CloudSyncEventUpdate(
            id: exportID,
            kind: .exportData,
            endedAt: exportEnd,
            succeeded: false,
            errorMessage: "Quota exceeded"
        ))
        XCTAssertEqual(status.lastErrorMessage, "Quota exceeded")
        XCTAssertEqual(status.title, "Sync issue")

        status.apply(CloudSyncEventUpdate(
            id: UUID(),
            kind: .importData,
            endedAt: exportEnd.addingTimeInterval(1),
            succeeded: true,
            errorMessage: nil
        ))
        XCTAssertEqual(status.lastErrorMessage, "Quota exceeded")

        status.apply(CloudSyncEventUpdate(
            id: exportID,
            kind: .exportData,
            endedAt: exportEnd.addingTimeInterval(2),
            succeeded: true,
            errorMessage: nil
        ))
        XCTAssertNil(status.lastErrorMessage)
        XCTAssertEqual(status.title, "Synced")
    }

    func testCloudSyncProtectionKeepsNewerSaveProtectedFromOlderExport() {
        let firstExportID = UUID()
        let secondExportID = UUID()
        var protection = CloudSyncProtectionState()

        protection.noteLocalSave()
        protection.apply(CloudSyncEventUpdate(
            id: firstExportID,
            kind: .exportData,
            endedAt: nil,
            succeeded: false,
            errorMessage: nil
        ))
        protection.noteLocalSave()
        protection.apply(CloudSyncEventUpdate(
            id: secondExportID,
            kind: .exportData,
            endedAt: nil,
            succeeded: false,
            errorMessage: nil
        ))
        protection.apply(CloudSyncEventUpdate(
            id: firstExportID,
            kind: .exportData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))

        XCTAssertTrue(protection.protectsExport)

        protection.apply(CloudSyncEventUpdate(
            id: secondExportID,
            kind: .exportData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        XCTAssertFalse(protection.protectsExport)
    }

    func testCloudSyncProtectionDoesNotMarkFailedExportAsCovered() {
        let failedExportID = UUID()
        let retryExportID = UUID()
        var protection = CloudSyncProtectionState()

        protection.noteLocalSave()
        protection.apply(CloudSyncEventUpdate(
            id: failedExportID,
            kind: .exportData,
            endedAt: nil,
            succeeded: false,
            errorMessage: nil
        ))
        protection.apply(CloudSyncEventUpdate(
            id: failedExportID,
            kind: .exportData,
            endedAt: Date(),
            succeeded: false,
            errorMessage: "Network unavailable"
        ))

        XCTAssertTrue(
            protection.protectsExport,
            "A failed CloudKit export must leave the local save protected until a later successful export covers it."
        )

        protection.apply(CloudSyncEventUpdate(
            id: retryExportID,
            kind: .exportData,
            endedAt: nil,
            succeeded: false,
            errorMessage: nil
        ))
        protection.apply(CloudSyncEventUpdate(
            id: retryExportID,
            kind: .exportData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))

        XCTAssertFalse(protection.protectsExport)
    }

    func testCloudSyncProtectionKeepsOverlappingImportsProtectedUntilRefresh() {
        let firstImportID = UUID()
        let secondImportID = UUID()
        var protection = CloudSyncProtectionState()

        for id in [firstImportID, secondImportID] {
            protection.apply(CloudSyncEventUpdate(
                id: id,
                kind: .importData,
                endedAt: nil,
                succeeded: false,
                errorMessage: nil
            ))
        }
        protection.apply(CloudSyncEventUpdate(
            id: firstImportID,
            kind: .importData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        protection.completeImportRefresh()
        XCTAssertTrue(protection.protectsImport)

        protection.apply(CloudSyncEventUpdate(
            id: secondImportID,
            kind: .importData,
            endedAt: Date(),
            succeeded: true,
            errorMessage: nil
        ))
        XCTAssertTrue(protection.protectsImport)
        protection.completeImportRefresh()
        XCTAssertFalse(protection.protectsImport)
    }
}

private func assertSameSRGBColor(
    _ actual: Color,
    _ expected: Color,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let actual = NSColor(actual).usingColorSpace(.sRGB),
          let expected = NSColor(expected).usingColorSpace(.sRGB) else {
        XCTFail("Expected colours to resolve in sRGB", file: file, line: line)
        return
    }

    XCTAssertEqual(
        actual.redComponent, expected.redComponent,
        accuracy: 0.001, file: file, line: line
    )
    XCTAssertEqual(
        actual.greenComponent, expected.greenComponent,
        accuracy: 0.001, file: file, line: line
    )
    XCTAssertEqual(
        actual.blueComponent, expected.blueComponent,
        accuracy: 0.001, file: file, line: line
    )
    XCTAssertEqual(
        actual.alphaComponent, expected.alphaComponent,
        accuracy: 0.001, file: file, line: line
    )
}
