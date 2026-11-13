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

    func testDS7CheckpointFailureBeforeWriteRetriesAndRecoversAcrossRelaunch() async throws {
        for relaunch in [false, true] {
            let root = try directory()
            let store = try persistent(at: root)
            let page = DrawPageModel(store: store)
            page.start()
            let canvas = try XCTUnwrap(page.canvasID)
            let checkpoint = root.appendingPathComponent("DrawRecovery-v1.json")
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
            let object = DrawObject(content: .text("Exact unsaved draft"))
            XCTAssertFalse(page.perform(.put([object])).isSaved)
            XCTAssertEqual(store.metrics.saveAttempts, 0)
            XCTAssertTrue(store.hasUnsettledEdits)
            try FileManager.default.trashItem(at: checkpoint, resultingItemURL: nil)
            if relaunch {
                // Republish while the model writer still has no submitted attempt.
                _ = store.reconcile(on: canvas)
                let reopened = try persistent(at: root)
                let recovery = DrawPageModel(store: reopened)
                recovery.open(canvas)
                recovery.retrySave()
                XCTAssertFalse(reopened.hasUnsettledEdits)
                XCTAssertEqual(try reopened.open(canvas).objects, [object])
                let quit = await recovery.prepareToQuit()
                XCTAssertTrue(quit)
            } else {
                page.retrySave()
                XCTAssertFalse(store.hasUnsettledEdits)
                XCTAssertEqual(store.metrics.saveAttempts, 1)
                XCTAssertEqual(try persistent(at: root).open(canvas).objects, [object])
                XCTAssertTrue(store.undo(on: canvas).isSaved)
                XCTAssertTrue(try store.open(canvas).objects.isEmpty)
                let quit = await page.prepareToQuit()
                XCTAssertTrue(quit)
            }
        }
    }

    func testDS7UnsubmittedCheckpointMarkerSurvivesRelaunchBeforeRetry() async throws {
        for typing in [false, true] {
            struct Failure: Error {}
            let root = try directory()
            let container = try persistent(at: root).container
            let url = root.appendingPathComponent("DrawRecovery-v1.json")
            var checkpoints = 0
            let journal = DrawRecoveryJournal(fileURL: url, writeData: { data, url in
                checkpoints += 1
                if checkpoints == 1 { throw Failure() }
                try data.write(to: url, options: .atomic)
            })
            let metrics = DrawSaveMetrics()
            let store = DrawStore(repository: DrawSwiftDataRepository(container: container, metrics: metrics,
                save: { try $0.save() }, recovery: journal), recovery: journal)
            let canvas = store.create(name: "Checkpoint retry")
            let object = DrawObject(content: .text("Preserved exact draft"))
            let result = typing ? store.performTypingBurst([.put([object])], on: canvas.id)
                : store.perform(.put([object]), on: canvas.id)
            XCTAssertFalse(result.isSaved)
            XCTAssertEqual(metrics.saveAttempts, 0)
            XCTAssertEqual(journal.records[canvas.id]?.unattempted, true)
            let recoveredJournal = DrawRecoveryJournal(fileURL: url)
            let recoveredMetrics = DrawSaveMetrics()
            let recovered = DrawStore(repository: DrawSwiftDataRepository(container: container, metrics: recoveredMetrics,
                save: { try $0.save() }, recovery: recoveredJournal), recovery: recoveredJournal)
            XCTAssertTrue(recovered.retry(on: canvas.id).isSaved)
            XCTAssertEqual(recoveredMetrics.saveAttempts, 1)
            XCTAssertEqual(try recovered.open(canvas.id).objects, [object])
            XCTAssertFalse(recovered.hasUnsettledEdits)
            XCTAssertTrue(recoveredJournal.records.isEmpty)
            let page = DrawPageModel(store: recovered)
            page.open(canvas.id)
            let quit = await page.prepareToQuit()
            XCTAssertTrue(quit)
        }
    }

    func testDS9ImportNamesEveryFailedFileAndKeepsSuccessfulPeersOnOriginalCanvas() async throws {
        for validPeer in [false, true] {
            let root = try directory()
            let valid = root.appendingPathComponent("kept.png")
            let broken = root.appendingPathComponent("broken.png")
            let missing = root.appendingPathComponent("missing.png")
            try Draw3Images.encoded(width: 20, height: 10).write(to: valid)
            try Data("corrupt".utf8).write(to: broken)
            let page = DrawPageModel(store: try persistent())
            page.start()
            let original = try XCTUnwrap(page.canvasID)
            let gate = Draw3Gate()
            DrawPageModel.importLoadHook = { _ in await gate.wait() }
            defer { DrawPageModel.importLoadHook = nil }
            let pb = NSPasteboard(name: .init("DrawImport-\(UUID())"))
            pb.writeObjects((validPeer ? [valid, broken, missing] : [broken, missing]).map { $0 as NSURL })
            let task = try XCTUnwrap(page.importImages(from: pb, at: .zero))
            page.newCanvas(name: "Other")
            gate.open()
            await task.value
            XCTAssertEqual(try page.store.open(original).objects.count, validPeer ? 1 : 0)
            XCTAssertTrue(page.objects.isEmpty)
            let notice = try XCTUnwrap(page.saveNotice)
            XCTAssertTrue(notice.message.contains("broken.png"))
            XCTAssertTrue(notice.message.contains("missing.png"))
            if validPeer { XCTAssertFalse(notice.message.contains("kept.png")) }
            pb.releaseGlobally()
        }
    }

    func testDS9FailedModelSaveNeverPlaysImportSuccess() async throws {
        struct Failure: Error {}
        let container = try ModelContainer(for: Schema(PersistenceController.appModelTypes), configurations:
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let page = DrawPageModel(store: DrawPersistentStore(container: container, save: { _ in throw Failure() }))
        page.start()
        let pb = NSPasteboard(name: .init("DrawFailedImport-\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.setData(Draw3Images.encoded(width: 20, height: 10), forType: .png)
        var cues: [AtticSounds.Cue] = []
        let sounds = AtticSounds.shared
        sounds.lastPlayed = -.infinity
        sounds.settingEnabled = { true }; sounds.systemAllows = { true }
        sounds.clock = { 20_000 + Double(cues.count) }; sounds.output = { cues.append($0) }
        defer {
            sounds.settingEnabled = nil; sounds.output = nil; sounds.systemAllows = { true }
            sounds.clock = { ProcessInfo.processInfo.systemUptime }; sounds.lastPlayed = -.infinity
        }
        await page.importImages(from: pb, at: .zero)?.value
        XCTAssertFalse(cues.contains(.attached))
        XCTAssertNotNil(page.saveNotice)
        XCTAssertTrue(page.store.hasUnsettledEdits)
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

    func testDS11HugeFiniteImageExtentRendersAndReopensWithoutChangingStoredGeometry() throws {
        let store = try persistent()
        let canvas = store.create(name: "Huge image")
        let agent = try actions(store)
        var object = DrawObject(frame: DrawFrame(x: 0, y: 0, width: 20, height: 10), content: .image(
            DrawImage(original: Draw3Images.encoded(width: 20, height: 10), pixelWidth: 20, pixelHeight: 10)))
        XCTAssertTrue(store.perform(.put([object]), on: canvas.id).isSaved)
        for extent in [1e20, Double(Int64.max / 2) + 4096] {
            let token = try XCTUnwrap(read(agent, canvas: canvas.id)["object_token"] as? String)
            _ = try agent.drawAction("draw_resize_object", ["canvas_id": canvas.id.uuidString,
                "object_id": object.id.uuidString, "object_token": token, "width": extent, "height": extent / 2], beforeMutation: {})
            object = try XCTUnwrap(store.open(canvas.id).objects.first)
            let reopened = try DrawPersistentStore(container: store.container).open(canvas.id)
            XCTAssertEqual(reopened.objects, [object])
            let key = DrawRasterKey(size: CGSize(width: 32, height: 32), scale: 2)
            XCTAssertNotNil(DrawRaster.render(DrawRasterRequest(key: key, objects: reopened.objects)))
            XCTAssertEqual(try store.open(canvas.id).objects, [object], "Rendering must never rewrite stored geometry")
        }
    }
}
