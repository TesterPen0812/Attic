import AppKit
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class DrawDataSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DrawDataSafety-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        return url
    }

    private func persistent(at root: URL? = nil) throws -> DrawPersistentStore {
        let config: ModelConfiguration = if let root {
            ModelConfiguration(url: root.appendingPathComponent("draw.store"), cloudKitDatabase: .none)
        } else { ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none) }
        return DrawPersistentStore(container: try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations: config))
    }

    private func actions(_ draw: DrawStore) throws -> AgentActions {
        let tasks = try makeTestStore()
        return AgentActions(tasks: AgentTaskTools(store: tasks, library: AtticLibrary(tasks: tasks)), draw: draw)
    }

    private func read(_ actions: AgentActions, canvas: UUID) throws -> [String: Any] {
        let text = try actions.drawAction("draw_read_canvas", ["canvas_id": canvas.uuidString], beforeMutation: {}).0
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap((response["objects"] as? [[String: Any]])?.first)
    }

    func testDS6PendingTypingFlushesBeforeAgentSnapshotAndValidation() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let canvas = try XCTUnwrap(page.canvasID)
        let object = DrawObject(content: .text("cat"))
        XCTAssertTrue(page.perform(.put([object])).isSaved)
        let agent = try actions(store)
        page.edit(object.id)
        page.typed("cats")
        XCTAssertThrowsError(try agent.drawAction("draw_edit_text", [
            "canvas_id": canvas.uuidString, "object_id": object.id.uuidString,
            "expected_text": "cat", "text": "dog"
        ], beforeMutation: {}), "An agent must validate against the live draft")
        XCTAssertEqual(try read(agent, canvas: canvas)["text"] as? String, "cats")
        _ = try agent.drawAction("draw_edit_text", ["canvas_id": canvas.uuidString,
            "object_id": object.id.uuidString, "expected_text": "cats", "text": "dog"], beforeMutation: {})
        page.endEditing()
        XCTAssertEqual(try store.open(canvas).objects.first?.text, "dog")
        XCTAssertTrue(store.undo(on: canvas).isSaved)
        XCTAssertEqual(try store.open(canvas).objects.first?.text, "cats")
        XCTAssertTrue(store.undo(on: canvas).isSaved)
        XCTAssertEqual(try store.open(canvas).objects.first?.text, "cat")
    }

    func testDS6QueuedTypingCannotResurrectDeletedObjectOrOverwriteStyleAndGeometry() throws {
        for name in ["draw_delete_object", "draw_restyle_object", "draw_resize_object", "draw_move_object"] {
            let store = try persistent()
            let page = DrawPageModel(store: store)
            page.start()
            let canvas = try XCTUnwrap(page.canvasID)
            let object = DrawObject(content: .text("cat"))
            XCTAssertTrue(page.perform(.put([object])).isSaved)
            let agent = try actions(store)
            let token = try XCTUnwrap(read(agent, canvas: canvas)["object_token"] as? String)
            page.edit(object.id)
            page.typed("cats")
            var args: [String: Any] = ["canvas_id": canvas.uuidString, "object_id": object.id.uuidString,
                "object_token": token, "colour": "red", "width": 400, "height": 200,
                "expected_x": object.frame.x, "expected_y": object.frame.y, "x": 100, "y": 200]
            do { _ = try agent.drawAction(name, args, beforeMutation: {}) }
            catch {
                args["object_token"] = try read(agent, canvas: canvas)["object_token"]
                _ = try agent.drawAction(name, args, beforeMutation: {})
            }
            let accepted = try store.open(canvas).objects
            page.endEditing()
            XCTAssertEqual(try store.open(canvas).objects, accepted, name)
            if name == "draw_delete_object" { XCTAssertTrue(accepted.isEmpty) }
            else { XCTAssertEqual(accepted.first?.text, "cats", name) }
        }
    }

    func testDS6SettlingEarlierGestureKeepsLaterEditorTextBeforeAgentRead() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let canvas = try XCTUnwrap(page.canvasID)
        let object = DrawObject(content: .text("cat"))
        XCTAssertTrue(page.perform(.put([object])).isSaved)
        var moved = object
        moved.frame.x = 100
        page.performAcknowledged(.put([moved]))
        page.edit(object.id)
        page.typed("cats")
        page.flushAcknowledgedDraw()
        XCTAssertEqual(page.editing?.text, "cats")
        let agent = try actions(store)
        XCTAssertEqual(try read(agent, canvas: canvas)["text"] as? String, "cats")
        page.typed(try XCTUnwrap(page.editing?.text) + "!")
        page.endEditing()
        XCTAssertEqual(try store.open(canvas).objects.first?.text, "cats!")
        XCTAssertEqual(try store.open(canvas).objects.first?.frame.x, 100)
    }

    func testDS6AgentUndoCannotConsumeBufferedOwnerTyping() async throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let canvas = try XCTUnwrap(page.canvasID)
        let object = DrawObject(content: .text("Original"))
        XCTAssertTrue(page.perform(.put([object])).isSaved)
        let agent = try actions(store)
        let request = agent.beginRequest(title: "Agent text")
        _ = try await agent.call(name: "draw_edit_text", arguments: ["canvas_id": canvas.uuidString,
            "object_id": object.id.uuidString, "expected_text": "Original", "text": "Agent"],
            watching: false, requestID: request)
        page.edit(object.id)
        page.typed("Newer owner draft")
        let result = await agent.undo(changeSet: request)
        XCTAssertEqual(result.undone, 0)
        XCTAssertEqual(result.failures.count, 1)
        page.endEditing()
        XCTAssertEqual(try store.open(canvas).objects.first?.text, "Newer owner draft")
        XCTAssertTrue(store.undo(on: canvas).isSaved)
        XCTAssertEqual(try store.open(canvas).objects.first?.text, "Agent")
    }

    func testSeededDrawOwnerAgentRoundTripsKeepEveryAcceptedEditAndUndo() throws {
        for seed: UInt64 in [16, 613, 20261113] {
            var random = seed
            func choose(_ count: UInt64) -> Int {
                random ^= random << 13; random ^= random >> 7; random ^= random << 17
                return Int(random % count)
            }
            let store = try persistent()
            let page = DrawPageModel(store: store)
            page.start()
            let canvas = try XCTUnwrap(page.canvasID)
            let initial = DrawObject(content: .text("Seed \(seed)"))
            XCTAssertTrue(page.perform(.put([initial])).isSaved)
            let agent = try actions(store)
            for step in 0..<240 {
                let before = try XCTUnwrap(store.open(canvas).objects.first)
                switch choose(4) {
                case 0:
                    page.edit(initial.id)
                    let draft = "Owner \(seed)-\(step) 👩🏽‍🚀"
                    page.typed(draft)
                    XCTAssertEqual(try read(agent, canvas: canvas)["text"] as? String, draft)
                    page.endEditing()
                case 1:
                    let row = try read(agent, canvas: canvas)
                    _ = try agent.drawAction("draw_edit_text", ["canvas_id": canvas.uuidString,
                        "object_id": initial.id.uuidString, "expected_text": try XCTUnwrap(row["text"]),
                        "text": "Agent \(seed)-\(step)"], beforeMutation: {})
                case 2:
                    _ = try agent.drawAction("draw_move_object", ["canvas_id": canvas.uuidString,
                        "object_id": initial.id.uuidString, "expected_x": before.frame.x,
                        "expected_y": before.frame.y, "x": Double(step + 1), "y": Double(step + 2)], beforeMutation: {})
                default:
                    let row = try read(agent, canvas: canvas)
                    _ = try agent.drawAction("draw_restyle_object", ["canvas_id": canvas.uuidString,
                        "object_id": initial.id.uuidString, "object_token": try XCTUnwrap(row["object_token"]),
                        "colour": before.style.colour == .red ? "blue" : "red"], beforeMutation: {})
                }
                let after = try store.open(canvas).objects
                XCTAssertTrue(store.undo(on: canvas).isSaved, "seed \(seed) step \(step)")
                XCTAssertEqual(try store.open(canvas).objects, [before])
                XCTAssertTrue(store.redo(on: canvas).isSaved)
                XCTAssertEqual(try store.open(canvas).objects, after)
                XCTAssertEqual(try DrawPersistentStore(container: store.container).open(canvas).objects, after)
                XCTAssertFalse(store.hasUnsettledEdits)
            }
            print("DRAW_DATA_SEED=\(seed) STEPS=240")
        }
    }

}
