import Foundation
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class DrawStoreContractTests: XCTestCase {
    func testMemoryContract() throws { try contract(DrawInMemoryStore()) }

    // The persistent implementation runs this exact contract in the next slice.
    func contract(_ store: any DrawStoreProtocol) throws {
        XCTAssertTrue(try store.library().isEmpty)
        let first = store.create(name: "Ideas")
        XCTAssertTrue(try store.library().isEmpty, "An empty new canvas is only a draft")
        var text = DrawObject(content: .text("hello world"))
        XCTAssertTrue(store.perform(.put([text]), on: first.id).isSaved)
        XCTAssertEqual(try store.library().map(\.name), ["Ideas"])
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
        XCTAssertNotEqual(try store.open(copy.id).objects.first?.id, text.id)
        XCTAssertTrue(store.perform(.deleteCanvas, on: first.id).isSaved)
        XCTAssertFalse(try store.library().contains { $0.id == first.id })
        XCTAssertEqual(try store.library(deleted: true).map(\.id), [first.id])
        XCTAssertTrue(store.perform(.restoreCanvas, on: first.id).isSaved)
        XCTAssertTrue(try store.library().contains { $0.id == first.id })
    }

    func testClipboardCutPasteAndImageRoundTrip() throws {
        let store = DrawInMemoryStore()
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
        XCTAssertTrue(store.undo(on: board.id).isSaved)
        XCTAssertTrue(try store.open(board.id).objects.isEmpty)
    }

    func testImageDeletionIsRestorableAndTextTypingIsOneStepPerCommand() throws {
        let store = DrawInMemoryStore()
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
}
