import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class DrawStoreContractTests: XCTestCase {
    func testMemoryContract() throws { try contract(DrawInMemoryStore()) }

    func testUndoHistoryHasABoundedCapacity() throws {
        let store = DrawInMemoryStore()
        let canvas = store.create(name: "History")
        for index in 0..<110 {
            XCTAssertTrue(store.perform(.rename("Version \(index)"), on: canvas.id).isSaved)
        }
        for _ in 0..<100 { XCTAssertTrue(store.undo(on: canvas.id).isSaved) }
        XCTAssertFalse(store.canUndo(on: canvas.id), "Oldest saved steps should leave the bounded history")
        XCTAssertTrue(store.canRedo(on: canvas.id))
    }

    func testCachedCanvasesKeepActiveSessionAndUnsavedDraft() throws {
        let store = DrawInMemoryStore()
        let active = store.create(name: "Active")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Keep"))]), on: active.id).isSaved)
        store.activate(active.id)
        let draft = store.create(name: "Unsaved draft")
        var firstInactive: UUID?
        for index in 0..<14 {
            let canvas = store.create(name: "Saved \(index)")
            if firstInactive == nil { firstInactive = canvas.id }
            XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Durable \(index)"))]), on: canvas.id).isSaved)
        }
        XCTAssertLessThanOrEqual(store.cachedCanvasIDs.count, DrawStore.maxCachedStates)
        XCTAssertTrue(store.cachedCanvasIDs.contains(active.id))
        XCTAssertTrue(store.cachedCanvasIDs.contains(draft.id))
        let evicted = try XCTUnwrap(firstInactive)
        XCTAssertFalse(store.cachedCanvasIDs.contains(evicted))
        XCTAssertEqual(try store.open(evicted).objects.first?.text, "Durable 0", "Eviction must reload the saved data")
    }

    func testCachedCanvasesNeverEvictUnsettledEdits() throws {
        final class Gate { var fail = false }
        let gate = Gate()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = DrawPersistentStore(container: container, save: { context in
            if gate.fail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let pending = store.create(name: "Pending")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Original"))]), on: pending.id).isSaved)
        gate.fail = true
        XCTAssertFalse(store.perform(.rename("Unsettled"), on: pending.id).isSaved)
        gate.fail = false
        for index in 0..<14 {
            let canvas = store.create(name: "Other \(index)")
            XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Saved"))]), on: canvas.id).isSaved)
        }
        XCTAssertTrue(store.cachedCanvasIDs.contains(pending.id))
        XCTAssertEqual(try store.open(pending.id).canvas.name, "Unsettled")
        XCTAssertTrue(store.retry(on: pending.id).isSaved)
        XCTAssertEqual(try DrawPersistentStore(container: container).open(pending.id).canvas.name, "Unsettled")
    }

    func testTagsUseAtticsSharedRules() throws {
        try tagContract(DrawInMemoryStore())
    }

    func tagContract(_ store: any DrawStoreProtocol) throws {
        let board = store.create()
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("tagged"))]), on: board.id).isSaved)
        XCTAssertTrue(store.perform(.tags(["##Work__PLAN !!!", "work plan", "???"]), on: board.id).isSaved)
        XCTAssertEqual(try store.library().first?.tags, ["work-plan"])
        XCTAssertEqual(try store.search("#WORK_PLAN").map(\.canvas.id), [board.id])
        XCTAssertTrue(try store.search("#???").isEmpty)
    }

    // The persistent implementation runs this exact contract in the next slice.
    func contract(_ store: any DrawStoreProtocol) throws {
        XCTAssertTrue(try store.library().isEmpty)
        let first = store.create(name: "Draft")
        XCTAssertTrue(store.perform(.rename("Ideas"), on: first.id).isSaved)
        XCTAssertTrue(store.perform(.thumbnail(Data([1, 2, 3])), on: first.id).isSaved)
        XCTAssertTrue(try store.library().isEmpty, "An empty new canvas is only a draft")
        var text = DrawObject(content: .text("hello world"))
        XCTAssertTrue(store.perform(.put([text]), on: first.id).isSaved)
        XCTAssertEqual(try store.library().map(\.name), ["Ideas"])
        XCTAssertEqual(try store.library().first?.thumbnail, Data([1, 2, 3]))
        XCTAssertTrue(store.perform(.tags(["Work"]), on: first.id).isSaved)
        XCTAssertEqual(try store.search("#work").map(\.canvas.id), [first.id])
        XCTAssertEqual(try store.search("hello").first?.matchingTextBoxIDs, [text.id])
        XCTAssertEqual(try store.search("Ideas").count, 1)
        let second = store.create(name: "Other")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .shape(.ellipse))]), on: second.id).isSaved)
        _ = try store.open(first.id)
        text.content = .text("hello changed")
        XCTAssertTrue(store.perform(.put([text]), on: first.id).isSaved)
        _ = try store.open(second.id)
        XCTAssertTrue(store.undo(on: first.id).isSaved)
        XCTAssertEqual(try store.open(first.id).objects.first?.content, .text("hello world"))
        XCTAssertTrue(store.redo(on: first.id).isSaved)
        XCTAssertEqual(try store.open(first.id).objects.first?.content, .text("hello changed"))
        let copy = try XCTUnwrap(store.duplicate(first.id, name: "Copy"))
        XCTAssertNotEqual(copy.id, first.id)
        XCTAssertEqual(copy.thumbnail, Data([1, 2, 3]))
        XCTAssertNotEqual(try store.open(copy.id).objects.first?.id, text.id)
        XCTAssertTrue(store.perform(.deleteCanvas, on: first.id).isSaved)
        XCTAssertFalse(try store.library().contains { $0.id == first.id })
        XCTAssertEqual(try store.library(deleted: true).map(\.id), [first.id])
        XCTAssertTrue(store.perform(.restoreCanvas, on: first.id).isSaved)
        XCTAssertTrue(try store.library().contains { $0.id == first.id })
    }

    func testClipboardCutPasteAndImageRoundTrip() throws {
        try clipboardContract(DrawInMemoryStore())
    }

    func clipboardContract(_ store: any DrawStoreProtocol) throws {
        let board = store.create()
        let image = DrawObject(content: .image(DrawImage(original: Data([0, 1, 255]), pixelWidth: 50, pixelHeight: 20)))
        let stroke = DrawObject(content: .stroke([DrawPoint(x: 1, y: 2), DrawPoint(x: 3, y: 4)]))
        XCTAssertTrue(store.perform(.put([image, stroke]), on: board.id).isSaved)
        let data = try store.copy([image.id, stroke.id], from: board.id)
        XCTAssertTrue(store.cut([image.id, stroke.id], from: board.id).isSaved)
        XCTAssertTrue(try store.open(board.id).objects.isEmpty)
        XCTAssertTrue(store.paste(data, into: board.id, offset: DrawPoint(x: 10, y: 20)).isSaved)
        let objects = try store.open(board.id).objects
        XCTAssertEqual(objects.count, 2)
        XCTAssertFalse(objects.contains { $0.id == image.id || $0.id == stroke.id })
        XCTAssertTrue(objects.contains { $0.content == image.content })
        XCTAssertTrue(objects.contains { $0.content == .stroke([DrawPoint(x: 11, y: 22), DrawPoint(x: 13, y: 24)]) })
        XCTAssertTrue(store.undo(on: board.id).isSaved)
        XCTAssertTrue(try store.open(board.id).objects.isEmpty)
    }

    func testImageDeletionIsRestorableAndTextTypingIsOneStepPerCommand() throws {
        try typingContract(DrawInMemoryStore())
    }

    func typingContract(_ store: any DrawStoreProtocol) throws {
        let board = store.create()
        var text = DrawObject(content: .text("a"))
        let image = DrawObject(content: .image(DrawImage(original: Data([9]), pixelWidth: 1, pixelHeight: 1)))
        XCTAssertTrue(store.perform(.put([text, image]), on: board.id).isSaved)
        text.content = .text("ab")
        XCTAssertTrue(store.perform(.put([text]), on: board.id).isSaved)
        XCTAssertTrue(store.undo(on: board.id).isSaved)
        XCTAssertTrue(try store.open(board.id).objects.contains { $0.content == .text("a") })
        XCTAssertTrue(store.perform(.remove([image.id]), on: board.id).isSaved)
        XCTAssertEqual(try store.deletedImages(in: board.id).map(\.id), [image.id])
        XCTAssertTrue(store.perform(.restoreObjects([image.id]), on: board.id).isSaved)
        XCTAssertTrue(try store.deletedImages(in: board.id).isEmpty)
    }

    func testDA4SavedAgentUndoMustKeepEarlierOwnerInkReachableInSessionHistory() throws {
        let store = DrawInMemoryStore()
        let canvas = store.create(name: "Interleaved history")
        let ink = DrawObject(content: .stroke([DrawPoint(x: 10, y: 10), DrawPoint(x: 50, y: 50)]))
        let agentShape = DrawObject(content: .shape(.rectangle))
        XCTAssertTrue(store.perform(.put([ink]), on: canvas.id).isSaved) // Owner's earlier command.
        XCTAssertTrue(store.perform(.put([agentShape]), on: canvas.id).isSaved) // Agent's next command.
        let agentStepID = try XCTUnwrap(store.undoStepID(on: canvas.id))
        let receipt = try XCTUnwrap(store.agentUndoProof(on: canvas.id, stepID: agentStepID))
        XCTAssertTrue(store.undoAgentStep(on: canvas.id, proof: receipt).isSaved)
        XCTAssertNotEqual(store.undoStepID(on: canvas.id), agentStepID,
                          "The agent reversal needs its own history identity")
        XCTAssertEqual(try store.open(canvas.id).objects.map(\.id), [ink.id])
        XCTAssertTrue(store.undo(on: canvas.id).isSaved, "Undoing the agent reversal itself is supported")
        XCTAssertEqual(Set(try store.open(canvas.id).objects.map(\.id)), Set([ink.id, agentShape.id]))
        XCTAssertTrue(store.canUndo(on: canvas.id),
                      "Earlier owner ink must still be reachable by Undo after the agent's saved Undo")
        XCTAssertTrue(store.undo(on: canvas.id).isSaved, "Undo the agent's original rectangle")
        XCTAssertEqual(try store.open(canvas.id).objects.map(\.id), [ink.id])
        XCTAssertTrue(store.undo(on: canvas.id).isSaved, "Undo the owner's earlier ink")
        XCTAssertTrue(try store.open(canvas.id).objects.isEmpty)
    }

    func testDA4SavedAgentUndoDropsStaleHistoryWhenCachedStateDiverges() throws {
        let repository = DrawMemoryRepository()
        let store = DrawStore(repository: repository)
        let canvas = store.create(name: "Stale session")
        let ink = DrawObject(content: .stroke([DrawPoint(x: 10, y: 10)]))
        let agentShape = DrawObject(content: .shape(.rectangle))
        XCTAssertTrue(store.perform(.put([ink]), on: canvas.id).isSaved)
        XCTAssertTrue(store.perform(.put([agentShape]), on: canvas.id).isSaved)
        let stepID = try XCTUnwrap(store.undoStepID(on: canvas.id))
        let proof = try XCTUnwrap(store.agentUndoProof(on: canvas.id, stepID: stepID))

        // A thumbnail update keeps the history head but changes cached state.
        XCTAssertTrue(store.perform(.thumbnail(Data([7])), on: canvas.id).isSaved)
        let updated = try XCTUnwrap(repository.load(canvas.id)).canvas
        var restored = updated
        restored.thumbnail = nil
        restored.thumbnailDark = nil
        guard case .committed = repository.write(DrawChange(
            canvasID: canvas.id, before: updated, after: restored,
            objectsBefore: [:], objectsAfter: [:]
        )) else { return XCTFail("Could not restore the persisted proof state") }
        XCTAssertEqual(try store.open(canvas.id).canvas.thumbnail, Data([7]))
        XCTAssertNil(try repository.load(canvas.id)?.canvas.thumbnail)

        XCTAssertTrue(store.undoAgentStep(on: canvas.id, proof: proof).isSaved)
        XCTAssertEqual(try store.open(canvas.id).objects.map(\.id), [ink.id])
        XCTAssertTrue(store.undo(on: canvas.id).isSaved, "The saved reversal is still undoable")
        XCTAssertEqual(Set(try store.open(canvas.id).objects.map(\.id)), Set([ink.id, agentShape.id]))
        XCTAssertFalse(store.canUndo(on: canvas.id), "Stale owner history must not survive the reload")
        XCTAssertEqual(store.undo(on: canvas.id), .unchanged, "Undo must not replay a stale step")
    }

}
