import Foundation
import SwiftData
import Security
import XCTest
@testable import Attic

@MainActor
final class OperationCrashHarnessTests: XCTestCase {
    private func runChild(_ mode: String, root: URL, point: String? = nil, saveThenThrow: Bool = false) async throws -> Int32 {
        let child = Process()
        child.executableURL = try XCTUnwrap(Bundle.main.executableURL)
            .deletingLastPathComponent().appendingPathComponent("AtticOperationCrashHelper")
        child.arguments = [mode, root.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ATTIC_CRASH_POINT")
        environment.removeValue(forKey: "ATTIC_SAVE_THEN_THROW")
        if let point { environment["ATTIC_CRASH_POINT"] = point }
        if saveThenThrow { environment["ATTIC_SAVE_THEN_THROW"] = "1" }
        child.environment = environment
        let done = expectation(description: "\(mode) \(point ?? "complete") exits")
        child.terminationHandler = { _ in done.fulfill() }
        try child.run()
        await fulfillment(of: [done], timeout: 40)
        if child.isRunning { child.terminate(); throw WorkspaceFoundationError.unknown }
        XCTAssertEqual(child.terminationReason, .exit)
        return child.terminationStatus
    }

    /// Engineering rule 2026-10-23: process death cannot split a whole item.
    func testAWholeItemDeleteAndPurgeCrashMatricesReopenTwice() async throws {
        try await assertWholeItemCrashMatrices(modes: ["delete-item", "purge-item"])
    }

    func testARestoreWholeItemCrashMatrixReopensTwice() async throws {
        try await assertWholeItemCrashMatrices(modes: ["restore-item"])
    }

    private func assertWholeItemCrashMatrices(modes: [String]) async throws {
        let deletePoints = ["A-delete-tasks", "A-delete-writing", "K-pre-intent", "K-intent-synced", "K1", "K2", "K3-validation", "K4", "K5", "A-delete-published", "save-then-throw"]
        let purgePoints = ["K-pre-intent", "K-intent-synced", "K1", "K2", "K3-validation", "A-purge-staged", "K4", "K5", "K6-1", "K7", "K8-before-unlink", "save-then-throw"]
        let restorePoints = ["K-pre-intent", "K-intent-synced", "K1", "K2", "K3-validation", "K4", "K5", "save-then-throw"]
        for mode in modes {
            for point in mode == "delete-item" ? deletePoints : (mode == "purge-item" ? purgePoints : restorePoints) {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let seed = try await runChild("seed-item", root: root); XCTAssertEqual(seed, 73, point)
                if mode != "delete-item" {
                    let deleted = try await runChild("delete-item", root: root); XCTAssertEqual(deleted, 73, point)
                }
                let result = try await runChild(mode, root: root, point: point == "save-then-throw" ? nil : point,
                    saveThenThrow: point == "save-then-throw")
                XCTAssertEqual(result, point == "save-then-throw" ? 73 : 86, "\(mode) \(point)")
                let committed = ["K5", "K6-1", "K7", "K8-before-unlink", "A-delete-published", "save-then-throw"].contains(point)
                for reopen in 0..<2 {
                    let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                    let coordinator = try WorkspaceOperationCoordinator(container: container, journal: WorkspaceCrashFixture.journal(root))
                    try await coordinator.reconcileStartup()
                    let context = coordinator.freshContext()
                    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
                    let notes = try context.fetch(FetchDescriptor<NoteItem>())
                    let files = try context.fetch(FetchDescriptor<NoteAttachment>())
                    let purged = mode == "purge-item" && committed
                    XCTAssertEqual(tasks.count, purged ? 1 : 5)
                    XCTAssertEqual(tasks.filter { $0.id != WorkspaceCrashFixture.alternateID }.count, purged ? 0 : 4, "\(mode) \(point) #\(reopen)")
                    XCTAssertEqual(notes.count, purged ? 0 : 4)
                    XCTAssertEqual(files.count, purged ? 0 : 4)
                    if !purged {
                        for copies in Dictionary(grouping: tasks, by: \.id).values {
                            let first = try WorkspaceModelFields.read(copies[0])
                            for copy in copies.dropFirst() { XCTAssertEqual(try WorkspaceModelFields.read(copy), first) }
                        }
                        let deleted = mode == "restore-item" ? !committed : (mode == "purge-item" || committed)
                        XCTAssertTrue(tasks.filter { $0.id != WorkspaceCrashFixture.alternateID }.allSatisfy { ($0.deletedAt != nil) == deleted })
                        XCTAssertTrue(notes.allSatisfy { ($0.deletedAt != nil) == deleted })
                        let groups = Set(tasks.filter { $0.id != WorkspaceCrashFixture.alternateID }.compactMap(\.deletionGroupID) + notes.compactMap(\.deletionGroupID))
                        XCTAssertEqual(groups.count, deleted ? 1 : 0)
                        XCTAssertTrue(notes.allSatisfy { $0.content == (try? PreparedNoteDocument(WorkspaceCrashFixture.original).content) })
                        XCTAssertTrue(files.allSatisfy { $0.payload == WorkspaceCrashFixture.bytes })
                        XCTAssertEqual(files.filter { $0.id == WorkspaceCrashFixture.removedFileID && $0.deletedAt != nil }.count, 2)
                    }
                    XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), purged ? 0 : 1)
                    XCTAssertEqual(try context.fetchCount(FetchDescriptor<NotePendingEdit>()), purged ? 0 : 1)
                    if !purged {
                        let expected = try PreparedNoteDocument(WorkspaceCrashFixture.original).content
                        let version = try XCTUnwrap(context.fetch(FetchDescriptor<NoteVersion>()).first)
                        XCTAssertEqual(version.content, expected)
                        let proposal = try XCTUnwrap(context.fetch(FetchDescriptor<NotePendingEdit>()).first)
                        XCTAssertEqual(proposal.proposedContent, expected)
                        XCTAssertEqual(proposal.baseVersionID, version.id)
                        XCTAssertTrue(tasks.filter { $0.id == WorkspaceCrashFixture.taskID }.allSatisfy { $0.manualOrder == 42 })
                    }
                    let references = try WorkspaceCrashFixture.purgeFiles(root)
                    XCTAssertEqual(references.count, 2, "one exclusive and one shared original")
                    if references.count == 2 {
                        let taskFiles = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
                        // A kill before unlink may retain surplus bytes; shared bytes must always survive.
                        let shared = try await taskFiles.verifiedURL(for: references[1])
                        XCTAssertEqual(try shared.map { try Data(contentsOf: $0) }, WorkspaceCrashFixture.bytes)
                        if !purged {
                            let exclusive = try await taskFiles.verifiedURL(for: references[0])
                            XCTAssertEqual(try exclusive.map { try Data(contentsOf: $0) }, WorkspaceCrashFixture.bytes)
                        }
                        if purged, point == "save-then-throw" {
                            let exclusive = try await taskFiles.verifiedURL(for: references[0])
                            XCTAssertNil(exclusive, "committed completion collects the exclusive original")
                            let reasons = try JSONDecoder().decode([UUID: String].self,
                                from: Data(contentsOf: root.appendingPathComponent("retained-reasons.json")))
                            XCTAssertNotNil(reasons[references[1].id])
                        }
                        let outside = tasks.filter { $0.id == WorkspaceCrashFixture.alternateID }
                        XCTAssertEqual(outside.count, 1)
                        XCTAssertTrue(outside.allSatisfy { $0.deletedAt == nil })
                        if let row = outside.first { XCTAssertEqual(try WorkspacePurge.legacyReferences(row), [references[1]]) }
                    }
                    XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), (mode != "delete-item" ? 1 : 0) + (committed ? 1 : 0))
                }
            }
        }
    }

    /// Engineering rule 2026-10-23: both circle changes are atomic across
    /// replica rows, document projection, retirement/redirect and receipts.
    func testBAddAndRemoveTasksRealKillMatricesReopenTwice() async throws {
        try await assertCircleCrashMatrices(inWindow: false)
    }

    func testC2RetainedWindowProjectionCrashMatricesReopenTwice() async throws {
        try await assertCircleCrashMatrices(inWindow: true)
    }

    func testC2WindowFileHandoffRealKillsKeepTheWindowPagesDurableStore() async throws {
        for point in ["C2-window-migration-released", "C2-window-migration-rebound"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let seeded = try await runChild("seed-review-move", root: root)
            XCTAssertEqual(seeded, 73)
            let crashed = try await runChild("window-move-review-remove", root: root, point: point)
            XCTAssertEqual(crashed, 86, point)
            guard crashed == 86 else { continue }
            let expected = try Data(contentsOf: root.appendingPathComponent("review-before-content.json"))
            for reopen in 0..<2 {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let coordinator = try WorkspaceOperationCoordinator(container: container, journal: WorkspaceCrashFixture.journal(root))
                try await coordinator.reconcileStartup()
                let context = coordinator.freshContext(), message = "\(point) #\(reopen)"
                let notes = try context.fetch(FetchDescriptor<NoteItem>())
                XCTAssertEqual(notes.count, 2, message)
                XCTAssertTrue(notes.allSatisfy { $0.content == expected && $0.taskID == WorkspaceCrashFixture.taskID && $0.deletedAt == nil }, message)
                let tasks = try context.fetch(FetchDescriptor<TaskItem>())
                XCTAssertEqual(tasks.count, 6, message)
                XCTAssertTrue(tasks.filter { $0.id == WorkspaceCrashFixture.taskID }.allSatisfy { $0.deletedAt == nil && $0.priority == .high && $0.tags == ["kept"] }, message)
                let files = try context.fetch(FetchDescriptor<NoteAttachment>())
                XCTAssertEqual(files.count, 6, message)
                XCTAssertTrue(files.allSatisfy { $0.payload == WorkspaceCrashFixture.bytes }, message)
                let rebound = point == "C2-window-migration-rebound"
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), rebound ? 1 : 0, message)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), rebound ? 3 : 1, message)
                XCTAssertTrue(try context.fetch(FetchDescriptor<TaskNoteAssociation>()).allSatisfy { $0.detachedAt == nil }, message)
                for reference in try JSONDecoder().decode([TaskImageReference].self, from: Data(contentsOf: root.appendingPathComponent("review-files.json"))) {
                    let original = try await TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")).verifiedURL(for: reference)
                    XCTAssertEqual(try original.map { try Data(contentsOf: $0) }, WorkspaceCrashFixture.bytes, message)
                }
            }
            let finished = try await runChild("window-move-review-remove", root: root)
            XCTAssertEqual(finished, 73, "retry finishes the same durable migration/removal")
        }
    }

    private func assertCircleCrashMatrices(inWindow: Bool) async throws {
        for adding in [true, false] {
            let mode = (inWindow ? "window-" : "") + (adding ? "add-to-tasks" : "remove-from-tasks")
            let staged = adding ? "B-add-association" : "B-remove-tasks"
            let points = ["K-pre-intent", "K-intent-synced", "K1", "K2", "K3-validation", staged,
                          "K3-note", "K4", "K5", "K6-1", "save-then-throw"] + (adding ? ["K3-task", "B-add-published"] : ["B-remove-writing", "B-remove-published"]) + (inWindow ? ["C2-projection-rekeyed", "C2-projection-installed"] : [])
            for point in points {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let seeded = try await runChild(adding ? "seed-add-to-tasks" : "seed-remove-from-tasks", root: root)
                XCTAssertEqual(seeded, 73, mode)
                guard seeded == 73 else { break }
                let crashed = try await runChild(mode, root: root, point: point == "save-then-throw" ? nil : point,
                    saveThenThrow: point == "save-then-throw")
                XCTAssertEqual(crashed, point == "save-then-throw" ? 73 : 86, "\(mode) \(point)")
                let committed = ["K5", "K6-1", "B-add-published", "B-remove-published", "C2-projection-rekeyed", "C2-projection-installed", "save-then-throw"].contains(point)
                for reopen in 0..<2 {
                    let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                    let coordinator = try WorkspaceOperationCoordinator(container: container, journal: WorkspaceCrashFixture.journal(root))
                    try await coordinator.reconcileStartup()
                    let context = coordinator.freshContext(), message = "\(mode) \(point) #\(reopen)"
                    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
                    let notes = try context.fetch(FetchDescriptor<NoteItem>())
                    let files = try context.fetch(FetchDescriptor<NoteAttachment>())
                    XCTAssertEqual(tasks.count, adding ? (committed ? 1 : 0) : 4, message)
                    XCTAssertEqual(notes.count, 2, message); XCTAssertTrue(notes.allSatisfy { $0.deletedAt == nil }, message)
                    XCTAssertEqual(notes.filter(\.isPinned).count, 1, message)
                    XCTAssertEqual(files.count, 4, message); XCTAssertTrue(files.allSatisfy { $0.payload == WorkspaceCrashFixture.bytes }, message)
                    XCTAssertEqual(files.filter { $0.id == WorkspaceCrashFixture.removedFileID && $0.deletedAt != nil }.count, 2, message)
                    XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), committed ? 1 : 0, message)
                    XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), committed ? 2 : 0, message)
                    let links = try context.fetch(FetchDescriptor<TaskNoteAssociation>())
                    if adding {
                        XCTAssertEqual(links.count, committed ? 1 : 0, message)
                        XCTAssertTrue(notes.allSatisfy { ($0.taskID != nil) == committed }, message)
                        for note in notes {
                            let document = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document })
                            XCTAssertEqual(document.requires.contains("taskNote"), committed, message)
                            XCTAssertEqual(Array(document.blocks.dropFirst()), Array(try WorkspaceCrashFixture.original.ordinarySnapshot(title: "Parent").blocks.dropFirst()), message)
                        }
                        XCTAssertTrue(tasks.allSatisfy { $0.status == .todo && $0.priority == .none && $0.dueDay == nil && $0.parentID == nil }, message)
                    } else {
                        XCTAssertTrue(tasks.allSatisfy { ($0.deletedAt != nil) == committed }, message)
                        XCTAssertEqual(Set(tasks.compactMap(\.deletionGroupID)).count, committed ? 1 : 0, message)
                        XCTAssertTrue(links.allSatisfy { ($0.detachedAt != nil) == committed && ($0.detachedPreservationID != nil) == committed }, message)
                        for note in notes {
                            let document = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document })
                            XCTAssertEqual(document.requires.contains("taskNote"), !committed, message)
                            if committed {
                                XCTAssertEqual(document.blocks[1].kind, .checklist, message)
                                XCTAssertEqual(document.blocks[1].text, "Child", message)
                                XCTAssertEqual(Array(document.blocks.dropFirst(2)), Array(WorkspaceCrashFixture.original.blocks.dropFirst()), message)
                            } else { XCTAssertEqual(document, WorkspaceCrashFixture.original, message) }
                        }
                    }
                }
            }
        }
    }

    /// Engineering rule: inverse commits, collection and migration handoff
    /// have the same all-or-none receipt and byte contract as forward changes.
    func testBReviewInversePurgeAndMoveCrashMatricesReopenTwice() async throws {
        let common = ["K-pre-intent", "K-intent-synced", "K1", "K2", "K3-validation", "K3-note", "K4", "K5", "K6-1", "save-then-throw"]
        for mode in ["undo-review-add", "undo-review-remove", "purge-review-circle", "move-review-remove"] {
            let points: [String]
            switch mode {
            case "purge-review-circle": points = common.filter { $0 != "K3-note" } + ["B-purge-links", "A-purge-staged", "K7", "K8-before-unlink"]
            case "move-review-remove": points = common + ["B-move-before-remove", "B-remove-writing", "B-remove-tasks", "B-remove-published"]
            default: points = common
            }
            for point in points {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let adding = mode == "undo-review-add", moving = mode == "move-review-remove", purging = mode == "purge-review-circle"
                let seeded = try await runChild(adding ? "seed-review-add" : (moving ? "seed-review-move" : "seed-review-remove"), root: root)
                XCTAssertEqual(seeded, 73, mode)
                guard seeded == 73 else { break }
                let crashed = try await runChild(mode, root: root, point: point == "save-then-throw" ? nil : point,
                    saveThenThrow: point == "save-then-throw")
                XCTAssertEqual(crashed, point == "save-then-throw" ? 73 : 86, "\(mode) \(point)")
                let committed = ["K5", "K6-1", "K7", "K8-before-unlink", "B-remove-published", "save-then-throw"].contains(point)
                for reopen in 0..<2 {
                    let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                    let coordinator = try WorkspaceOperationCoordinator(container: container, journal: WorkspaceCrashFixture.journal(root))
                    try await coordinator.reconcileStartup()
                    let context = coordinator.freshContext(), message = "\(mode) \(point) #\(reopen)"
                    let tasks = try context.fetch(FetchDescriptor<TaskItem>()), notes = try context.fetch(FetchDescriptor<NoteItem>())
                    let files = try context.fetch(FetchDescriptor<NoteAttachment>()), links = try context.fetch(FetchDescriptor<ItemLink>())
                    let versions = try context.fetch(FetchDescriptor<NoteVersion>())
                    XCTAssertEqual(tasks.count, adding ? 1 : (purging && committed ? 0 : 6), message)
                    XCTAssertEqual(notes.count, 2, message); XCTAssertEqual(notes.filter(\.isPinned).count, 1, message)
                    XCTAssertTrue(notes.allSatisfy { $0.deletedAt == nil }, message)
                    XCTAssertEqual(files.count, moving ? 6 : 4, message)
                    XCTAssertTrue(files.allSatisfy { $0.payload == WorkspaceCrashFixture.bytes }, message)
                    XCTAssertEqual(files.filter { $0.id == WorkspaceCrashFixture.removedFileID && $0.deletedAt != nil }.count, 2, message)
                    XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), 1 + (committed ? 1 : 0), message)
                    XCTAssertEqual(versions.count, 3 + (committed && !purging ? 2 : 0), message)
                    XCTAssertEqual(versions.first { $0.id == WorkspaceCrashFixture.versionID }?.content,
                        try PreparedNoteDocument(adding ? WorkspaceCrashFixture.original.ordinarySnapshot(title: "Parent") : WorkspaceCrashFixture.original).content, message)
                    XCTAssertEqual(links.count, 1, message)
                    XCTAssertEqual(links.first?.target, .init(adding || (purging && committed) ? .note : .task,
                        adding || (purging && committed) ? WorkspaceCrashFixture.noteID : WorkspaceCrashFixture.taskID), message)
                    let taskForm = adding ? !committed : (mode == "undo-review-remove" ? committed : (moving ? !committed : false))
                    XCTAssertTrue(notes.allSatisfy { ($0.taskID != nil) == taskForm }, message)
                    let rawExpected = try Data(contentsOf: root.appendingPathComponent(committed && !purging
                        ? "review-after-content.json" : "review-before-content.json"))
                    let intended = try XCTUnwrap(NoteContentCodec.decode(rawExpected).document)
                    var expected = adding && taskForm
                        ? try WorkspaceCrashFixture.original.ordinarySnapshot(title: "Parent").taskSnapshot(title: "Parent")
                        : WorkspaceCrashFixture.original
                    if moving {
                        let references = try JSONDecoder().decode([TaskImageReference].self, from: Data(contentsOf: root.appendingPathComponent("review-files.json")))
                        let reference = try XCTUnwrap(references.last)
                        expected.blocks.append(.file(id: TaskAttachmentMigration.placementID(attachment: reference.id, note: WorkspaceCrashFixture.noteID), attachmentID: reference.id, filename: reference.filename,
                            contentTypeIdentifier: reference.contentTypeIdentifier, byteCount: reference.byteCount))
                    }
                    if !taskForm {
                        expected = try expected.ordinarySnapshot(title: "Parent")
                        if !adding {
                            let blockID = try XCTUnwrap(intended.blocks[1].id, "generated checkbox has a persisted identity")
                            var checkbox = NoteBlock.checklist("Child", checked: false); checkbox.id = blockID
                            expected.blocks.insert(checkbox, at: 1)
                        }
                    }
                    for note in notes {
                        XCTAssertEqual(note.content, rawExpected, "exact intended pre-save/baseline bytes: \(message)")
                        XCTAssertEqual(note.content.flatMap { NoteContentCodec.decode($0).document }, expected, message)
                    }
                    let associations = try context.fetch(FetchDescriptor<TaskNoteAssociation>())
                    let preservations = try context.fetch(FetchDescriptor<TaskDeletionPreservation>())
                    if adding {
                        let task = try XCTUnwrap(tasks.first)
                        XCTAssertEqual(task.deletedAt != nil, committed, message)
                        XCTAssertEqual(task.deletionGroupID != nil, committed, message)
                        XCTAssertEqual(associations.count, 1, message)
                        XCTAssertTrue(associations.allSatisfy { ($0.detachedAt != nil) == committed && ($0.detachedPreservationID != nil) == committed }, message)
                        XCTAssertEqual(preservations.filter { $0.provenance == "circle removed" && $0.retiredAt == nil }.count, committed ? 1 : 0, message)
                        XCTAssertEqual(task.priority, .none); XCTAssertNil(task.dueDay); XCTAssertEqual(task.status, .todo)
                    } else if mode == "undo-review-remove" {
                        XCTAssertEqual(associations.count, 1, message)
                        XCTAssertTrue(associations.allSatisfy { ($0.detachedAt == nil) == committed }, message)
                        XCTAssertEqual(preservations.filter { $0.retiredAt == nil }.count, committed ? 0 : 1, message)
                    }
                    if !adding, !(purging && committed) {
                        let earlier = tasks.filter { $0.title == "Earlier deleted child" }
                        XCTAssertEqual(earlier.count, 2, message)
                        XCTAssertTrue(earlier.allSatisfy { $0.deletedAt == Date(timeIntervalSince1970: 1_699_999_990) }, message)
                        let primary = tasks.filter { $0.title != "Earlier deleted child" }
                        let parents = primary.filter { $0.id == WorkspaceCrashFixture.taskID }
                        XCTAssertEqual(parents.count, 2, message)
                        XCTAssertTrue(parents.allSatisfy { $0.priority == .high && $0.dueDayRaw == "2026-10-23"
                            && $0.manualOrder == 42 && $0.tags == ["kept"] && $0.parentID == nil }, message)
                        let children = primary.filter { $0.id == WorkspaceCrashFixture.childID }
                        XCTAssertEqual(children.count, 2, message)
                        XCTAssertTrue(children.allSatisfy { $0.parentID == WorkspaceCrashFixture.taskID && $0.status == .todo }, message)
                        if mode == "undo-review-remove" && committed {
                            XCTAssertTrue(primary.allSatisfy { $0.deletionGroupID == nil && $0.deletionRootID == nil && $0.deletionMembersRaw.isEmpty }, message)
                        }

                        let retired = moving ? committed : (mode == "undo-review-remove" ? !committed : true)
                        XCTAssertTrue(primary.allSatisfy { ($0.deletedAt != nil) == retired }, message)
                        for copies in Dictionary(grouping: tasks, by: \.id).values {
                            let fields = try WorkspaceModelFields.read(copies[0])
                            for copy in copies { XCTAssertEqual(try WorkspaceModelFields.read(copy), fields, message) }
                        }
                    }
                    if !adding {
                        let references = try JSONDecoder().decode([TaskImageReference].self, from: Data(contentsOf: root.appendingPathComponent("review-files.json")))
                        let storage = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
                        for (index, reference) in references.enumerated() {
                            let url = try await storage.verifiedURL(for: reference)
                            if purging && committed && point == "save-then-throw" && index == 0 { XCTAssertNil(url, "exclusive earlier original unlinked after commit") }
                            else { XCTAssertEqual(try url.map { try Data(contentsOf: $0) }, WorkspaceCrashFixture.bytes, message) }
                        }
                    }
                }
            }
        }
    }

    func testC2SecondProcessWriterLeaseRefusesTheSameStoreAndReleasesOnDeath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var container: ModelContainer? = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        XCTAssertNotNil(container)
        let refused = try await runChild("writer-probe", root: root)
        XCTAssertEqual(refused, 76)
        container = nil
        let launched = try await runChild("launch-probe", root: root)
        XCTAssertEqual(launched, 73)
    }

    func testC4ConversionCrashMatrixReopensTwiceWithoutPartialRowsOrLostOriginals() async throws {
        let points = ["K0", "K1", "K2", "K3-validation", "K3-task", "K3-note", "K3-association", "K4",
                      "K5", "K6-1", "K6-2", "K6-3", "K6-4", "K6-5", "K7", "save-then-throw"]
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("AtticCrashSentinel-\(UUID())")
        let sentinelBytes = Data("outside fixture: preserve me".utf8)
        try sentinelBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        for (index, point) in points.enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let seeded = try await runChild("seed-conversion", root: root)
            XCTAssertEqual(seeded, 73, point)
            let crashed = try await runChild("convert", root: root, point: point == "save-then-throw" ? nil : point,
                                            saveThenThrow: point == "save-then-throw")
            XCTAssertEqual(crashed, point == "save-then-throw" ? 73 : 86, point)
            let committed = index >= 8
            for reopen in 0..<2 {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let journal = WorkspaceCrashFixture.journal(root)
                let coordinator = try WorkspaceOperationCoordinator(container: container, journal: journal)
                if point != "save-then-throw" && reopen == 0 {
                    do { _ = try await journal.readRecoveryEntries(); XCTFail("offering must await receipt reconciliation: \(point)") }
                    catch { }
                } else if reopen == 1 && !committed {
                    let independent = try await journal.readRecoveryEntries()
                    XCTAssertEqual(independent.count, 1, "released intent must leave an offerable ordinary checkpoint: \(point)")
                }
                try await coordinator.reconcileStartup()
                let context = coordinator.freshContext()
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), committed ? 2 : 1, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskNoteAssociation>()), committed ? 1 : 0, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteVersion>()), committed ? 1 : 0, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<NoteAttachment>()), committed ? 1 : 0, point)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), committed ? 1 : 0, point)
                let recovery = try await journal.readRecoveryEntries()
                if committed {
                    XCTAssertTrue(recovery.isEmpty, "committed pre-copy must not be offered: \(point)")
                    XCTAssertTrue(coordinator.preOperationRecoveryCopies.isEmpty)
                    XCTAssertEqual(try context.fetch(FetchDescriptor<NoteAttachment>()).first?.payload, WorkspaceCrashFixture.bytes)
                    let content = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first?.content)
                    XCTAssertEqual(NoteContentCodec.decode(content).document, WorkspaceCrashFixture.candidate)
                } else {
                    guard case let .valid(pre, staged, _) = recovery.first else { XCTFail("lost pre-copy: \(point)"); continue }
                    XCTAssertEqual(NoteContentCodec.decode(pre.content).document, WorkspaceCrashFixture.original)
                    XCTAssertEqual(staged.first?.data, WorkspaceCrashFixture.bytes)
                    XCTAssertEqual(coordinator.preOperationRecoveryCopies.count, reopen == 0 ? 1 : 0)
                    let envelopes = try await journal.operationEnvelopes()
                    XCTAssertTrue(envelopes.isEmpty, "proven absent receipt must release its intent: \(point)")
                }
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
            }
        }
    }
    /// Phase 3 slice 2 (§ 13): a real process death at every migration
    /// boundary leaves "not migrated" or "migrated", never a mix; launch
    /// recovery plus the launch run then finish it exactly once.
    func testM1MigrationCrashMatrixRecoversToOldOrNewAndFinishesOnce() async throws {
        let points = ["M0-inventory", "M1-validation", "M2-bytes", "K-pre-intent", "K-intent-synced", "K0", "K1", "K2", "K3-validation", "M3-note", "M4-record",
                      "K4", "K5", "K6-1", "M5-publication", "save-then-throw"]
        let committedPoints: Set<String> = ["K5", "K6-1", "M5-publication", "save-then-throw"]
        for point in points {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let seeded = try await runChild("seed-migration", root: root)
            XCTAssertEqual(seeded, 73, point)
            let crashed = try await runChild("migrate", root: root, point: point == "save-then-throw" ? nil : point,
                                            saveThenThrow: point == "save-then-throw")
            XCTAssertEqual(crashed, point == "save-then-throw" ? 73 : 86, point)
            let references = try WorkspaceCrashFixture.migrationFiles(root)
            let legacyRows = { (context: ModelContext) throws -> [Data?] in
                try context.fetch(FetchDescriptor<TaskItem>()).sorted { $0.title < $1.title }.flatMap { [$0.imageReferencesData, $0.removedAttachmentsData] }
            }
            var legacy: [Data?]?
            for reopen in 0..<2 {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let coordinator = try WorkspaceOperationCoordinator(container: container, journal: WorkspaceCrashFixture.journal(root))
                try await coordinator.reconcileStartup()
                let context = coordinator.freshContext()
                let records = try context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>())
                let notes = try context.fetch(FetchDescriptor<NoteItem>())
                let rows = try context.fetch(FetchDescriptor<NoteAttachment>())
                let committed = committedPoints.contains(point)
                XCTAssertEqual(records.count, committed ? 1 : 0, "\(point) #\(reopen)")
                XCTAssertEqual(notes.count, committed ? 1 : 0, "\(point) #\(reopen)")
                XCTAssertEqual(rows.count, committed ? 4 : 0, "\(point) #\(reopen)")
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskNoteAssociation>()), committed ? 1 : 0, "\(point) #\(reopen)")
                if legacy == nil { legacy = try legacyRows(context) } else { XCTAssertEqual(try legacyRows(context), legacy, point) }
                if reopen == 1 {
                    let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
                    let report = await TaskAttachmentMigration.runAll(coordinator: coordinator, files: files)
                    let done = coordinator.freshContext()
                    // K0–K2 release only after a durable, verified abort of
                    // the old intent. A new operation then finishes migration.
                    XCTAssertEqual(report.migrated, committed ? [] : [WorkspaceCrashFixture.taskID], point)
                    XCTAssertEqual(try done.fetchCount(FetchDescriptor<TaskAttachmentMigrationRecord>()), 1, point)
                    guard let note = try done.fetch(FetchDescriptor<NoteItem>()).first,
                          let doc = note.content.flatMap({ NoteContentCodec.decode($0).document }) else {
                        XCTFail("no migrated note: \(point)"); continue
                    }
                    XCTAssertEqual(doc.attachmentIDs, [references[0].id, references[1].id, references[2].id], point)
                    let attachments = try done.fetch(FetchDescriptor<NoteAttachment>())
                    XCTAssertEqual(Set(attachments.map(\.id)), Set(references.map(\.id)), point)
                    XCTAssertEqual(attachments.count, 4, point)
                    XCTAssertEqual(try legacyRows(done), legacy, "legacy lists stay untouched: \(point)")
                    for reference in references {
                        let exists = (try? await files.verifiedURL(for: reference)) != nil
                        XCTAssertTrue(exists, "original kept: \(point)")
                    }
                }
            }
        }
    }

    func testK8CoordinatedPurgeCrashesLeaveOnlyRecoverableExclusiveFileSurplus() async throws {
        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("AtticPurgeSentinel-\(UUID())")
        let sentinelBytes = Data("outside purge fixture".utf8); try sentinelBytes.write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        for point in ["K8-before-unlink", "K8-cache"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticOperationCrash-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let seed = try await runChild("seed-purge", root: root); XCTAssertEqual(seed, 73)
            let crash = try await runChild("purge", root: root, point: point); XCTAssertEqual(crash, 86)
            let references = try WorkspaceCrashFixture.purgeFiles(root)
            for _ in 0..<2 {
                let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
                let coordinator = try WorkspaceOperationCoordinator(container: container, journal: WorkspaceCrashFixture.journal(root))
                try await coordinator.reconcileStartup()
                let context = coordinator.freshContext()
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskItem>()), 0)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<TaskDeletionPreservation>()), 1)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<OperationReceipt>()), 1)
                let note = try XCTUnwrap(context.fetch(FetchDescriptor<NoteItem>()).first)
                XCTAssertNil(note.taskID); XCTAssertEqual(note.title, "Parent")
                let doc = try XCTUnwrap(note.content.flatMap { NoteContentCodec.decode($0).document })
                XCTAssertFalse(doc.requires.contains("taskNote"))
                // 2026-10-23: conversion drops task-only completion metadata.
                XCTAssertFalse(doc.blocks.contains { $0.text.hasPrefix("Was a task") })
                XCTAssertEqual(doc.blocks[1].kind, .checklist)
                XCTAssertEqual(doc.blocks[1].text, "Child")
                XCTAssertFalse(doc.blocks[1].checked)
                XCTAssertEqual(doc.blocks[2].text, "Retain body", "body follows the preserved child checkbox")
                let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles"))
                var remaining = 0
                for reference in references { if try await files.verifiedURL(for: reference) != nil { remaining += 1 } }
                XCTAssertEqual(remaining, point == "K8-before-unlink" ? 2 : 1)
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
            }
            let files = TaskImageFiles(rootURL: root.appendingPathComponent("TaskFiles")); await files.remove(references)
            for reference in references { let url = try await files.verifiedURL(for: reference); XCTAssertNil(url) }
        }
    }
    func testC4EmbeddedChildLaunchesAndReopensExactSchemaInsideHostSandbox() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticOperationCrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Bundle.main is the hosted executable, not the XCTest bundle. Resolve
        // relative to it so product/executable-name preview overrides work.
        let executable = try XCTUnwrap(Bundle.main.executableURL)
            .deletingLastPathComponent().appendingPathComponent("AtticOperationCrashHelper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        // Assert the signatures at launch time too; build evidence alone must
        // not mask any test-runner re-signing of the embedded executable.
        var hostCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &hostCode), errSecSuccess)
        var hostStatic: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(hostCode), [], &hostStatic), errSecSuccess)
        try assertSandboxAndRuntime(try XCTUnwrap(hostStatic), helper: false)
        var helperCode: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, [], &helperCode), errSecSuccess)
        try assertSandboxAndRuntime(try XCTUnwrap(helperCode), helper: true)
        let child = Process()
        child.executableURL = executable
        child.arguments = ["launch-probe", root.path]
        let done = expectation(description: "crash helper exits")
        child.terminationHandler = { _ in done.fulfill() }
        try child.run()
        await fulfillment(of: [done], timeout: 30)
        if child.isRunning { child.terminate(); XCTFail("helper did not exit"); return }
        XCTAssertEqual(child.terminationReason, .exit)
        XCTAssertEqual(child.terminationStatus, 73, "child must save then exit abruptly")
        let childSchema = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: root.appendingPathComponent("schema.json"))
        )
        for _ in 0..<2 {
            try autoreleasepool {
                let container = try PersistenceController.makeContainer(
                    cloudSyncEnabled: false, storeDirectory: root
                )
                XCTAssertEqual(childSchema, container.schema.entities.map(\.name).sorted())
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let tasks = try context.fetch(FetchDescriptor<TaskItem>())
                let notes = try context.fetch(FetchDescriptor<NoteItem>())
                XCTAssertEqual(tasks.count, 1)
                XCTAssertEqual(notes.count, 1)
                XCTAssertEqual(tasks.first?.title, "child task")
                XCTAssertEqual(notes.first?.body, "durable child bytes")
                XCTAssertEqual(notes.first?.taskID, tasks.first?.id)
            }
        }
    }
    private func assertSandboxAndRuntime(_ code: SecStaticCode, helper: Bool) throws {
        var information: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information), errSecSuccess)
        let info = try XCTUnwrap(information as? [String: Any])
        let flags = try XCTUnwrap(info[kSecCodeInfoFlags as String] as? NSNumber).uint32Value
        XCTAssertNotEqual(flags & 0x10000, 0, "hardened runtime must be active")
        let entitlements = try XCTUnwrap(info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        if helper {
            XCTAssertEqual(Set(entitlements.keys), ["com.apple.security.app-sandbox", "com.apple.security.inherit"])
            XCTAssertEqual(entitlements["com.apple.security.inherit"] as? Bool, true)
        }
    }
}
