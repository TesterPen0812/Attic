import Foundation
import SwiftData
@testable import Attic

@MainActor
func makeTestStore(
    now: @escaping () -> Date = Date.init,
    persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
) throws -> TaskStore {
    let container = try PersistenceController.makeContainer(inMemory: true)
    return TaskStore(container: container, now: now, persist: persist)
}

@MainActor
func makeTestNoteStore(
    now: @escaping () -> Date = Date.init,
    persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
    attachmentFileStore: AttachmentFileStore = AttachmentFileStore()
) throws -> NoteStore {
    let container = try PersistenceController.makeContainer(inMemory: true)
    return NoteStore(
        container: container,
        now: now,
        persist: persist,
        attachmentFileStore: attachmentFileStore
    )
}

@MainActor
func makeTestCanvasStore(
    now: @escaping () -> Date = Date.init,
    persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
) throws -> CanvasStore {
    let container = try PersistenceController.makeContainer(inMemory: true)
    return CanvasStore(container: container, now: now, persist: persist)
}

final class MutableNow {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

@MainActor
final class PersistenceGate {
    struct Failure: Error {}

    var shouldFail = false
    private(set) var saveCount = 0

    func save(_ context: ModelContext) throws {
        if shouldFail { throw Failure() }
        try context.save()
        saveCount += 1
    }
}
