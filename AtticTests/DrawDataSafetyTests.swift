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

    func testCatchupR1EmptyAcknowledgementCannotCarryHistoryAcrossCanvasAndTyping() throws {
        for emptyAction in ["put", "redo", "undo"] {
            let store = try persistent()
            let page = DrawPageModel(store: store)
            page.start()
            let first = try XCTUnwrap(page.canvasID)
            let box = DrawObject(frame: DrawFrame(x: 40, y: 80, width: 100, height: 50), content: .shape(.rectangle))
            if emptyAction != "undo" {
                XCTAssertTrue(page.perform(.put([box])).isSaved)
                var moved = box
                moved.frame.x += 30
                page.performAcknowledged(.put([moved]))
                page.flushAcknowledgedDraw()
                if emptyAction == "put" { page.performAcknowledged(.put([moved])) }
                else { page.redoAcknowledged() }
            } else { page.undoAcknowledged() }
            let firstObjects = try store.open(first).objects
            XCTAssertTrue(page.newCanvas(name: "Second"))
            let second = try XCTUnwrap(page.canvasID)
            page.beginText(at: CGPoint(x: 150, y: 150))
            page.typed("Second canvas writing")
            page.endEditing()
            XCTAssertEqual(try store.open(second).objects.count, 1)
            page.undoAcknowledged()
            page.flushAcknowledgedDraw()
            XCTAssertTrue(page.objects.isEmpty, emptyAction)
            XCTAssertEqual(page.objects, try store.open(second).objects, emptyAction)
            XCTAssertEqual(try store.open(first).objects, firstObjects, emptyAction)
        }
    }

    func testCatchupR1NoOpProjectionRefreshesAfterExternalEdit() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let canvas = try XCTUnwrap(page.canvasID)
        let box = DrawObject(frame: DrawFrame(x: 40, y: 80, width: 100, height: 50), content: .shape(.rectangle))
        XCTAssertTrue(page.perform(.put([box])).isSaved)
        var moved = box
        moved.frame.x += 30
        page.performAcknowledged(.put([moved]))
        page.flushAcknowledgedDraw()
        page.performAcknowledged(.put([moved])) // No-op, followed by an external history change with no flush boundary.
        let text = DrawObject(content: .text("Agent addition"))
        XCTAssertTrue(store.perform(.put([text]), on: canvas).isSaved)
        page.undoAcknowledged()
        page.flushAcknowledgedDraw()
        XCTAssertEqual(page.objects, [moved])
        XCTAssertEqual(page.objects, try store.open(canvas).objects)
    }

    func testCatchupR3AgentReadsKeepInkAndMoveLiveUntilPointerUp() throws {
        for name in ["draw_read_canvas", "draw_list_canvases"] {
            for moving in [false, true] {
                let store = try persistent()
                let page = DrawPageModel(store: store)
                page.start()
                let canvas = try XCTUnwrap(page.canvasID)
                let box = DrawObject(frame: DrawFrame(x: 40, y: 80, width: 100, height: 50), content: .shape(.rectangle))
                if moving { XCTAssertTrue(page.perform(.put([box])).isSaved) }
                page.setTool(moving ? .select : .pen)
                let start = page.viewport.screen(CGPoint(x: 80, y: 100))
                let middle = page.viewport.screen(CGPoint(x: 100, y: 110))
                let end = page.viewport.screen(CGPoint(x: 180, y: 140))
                page.pointerDown(at: start)
                page.pointerDragged(to: middle)
                XCTAssertNotNil(page.live)
                let before = try store.open(canvas).objects
                let undoBefore = store.undoStepID(on: canvas)
                let agent = try actions(store)
                _ = try agent.drawAction(name, ["canvas_id": canvas.uuidString], beforeMutation: {})
                XCTAssertNotNil(page.live, name)
                XCTAssertEqual(try store.open(canvas).objects, before, name)
                XCTAssertEqual(store.undoStepID(on: canvas), undoBefore, name)
                page.pointerDragged(to: end)
                page.pointerUp()
                page.flushAcknowledgedDraw()
                XCTAssertNil(page.live)
                let after = try store.open(canvas).objects
                XCTAssertEqual(after.count, 1)
                XCTAssertEqual(page.objects, after)
                if moving {
                    XCTAssertEqual(after.first?.frame.x, box.frame.x + 100)
                    XCTAssertEqual(after.first?.frame.y, box.frame.y + 40)
                } else {
                    XCTAssertGreaterThan(try XCTUnwrap(after.first).frame.width, 80)
                }
                XCTAssertTrue(store.undo(on: canvas).isSaved)
                XCTAssertEqual(try store.open(canvas).objects, before)
            }
        }
    }

    func testCatchupR8AgentMutationsRefuseTheLiveGestureCanvasAndRetryAfterPointerUp() throws {
        for deleting in [false, true] {
            let store = try persistent()
            let page = DrawPageModel(store: store)
            page.start()
            let canvas = try XCTUnwrap(page.canvasID)
            let box = DrawObject(frame: DrawFrame(x: 40, y: 80, width: 100, height: 50), content: .shape(.rectangle))
            if !deleting { XCTAssertTrue(page.perform(.put([box])).isSaved) }
            let agent = try actions(store)
            page.setTool(deleting ? .pen : .select)
            page.pointerDown(at: page.viewport.screen(CGPoint(x: 80, y: 100)))
            page.pointerDragged(to: page.viewport.screen(CGPoint(x: 100, y: 110)))
            XCTAssertNotNil(page.live)
            let before = try store.open(canvas).objects
            let name = deleting ? "draw_delete_canvas" : "draw_move_object"
            var args: [String: Any] = ["canvas_id": canvas.uuidString, "object_id": box.id.uuidString,
                "expected_x": box.frame.x, "expected_y": box.frame.y, "x": 300, "y": 300]
            var mutations = 0
            XCTAssertThrowsError(try agent.drawAction(name, args, beforeMutation: { mutations += 1 })) { error in
                XCTAssertTrue(error.localizedDescription.lowercased().contains("owner is drawing"))
                XCTAssertTrue(error.localizedDescription.lowercased().contains("retry"))
            }
            XCTAssertEqual(mutations, 0)
            XCTAssertNotNil(page.live)
            XCTAssertNil(try store.open(canvas).canvas.deletedAt)
            XCTAssertEqual(try store.open(canvas).objects, before)
            page.pointerDragged(to: page.viewport.screen(CGPoint(x: 180, y: 140)))
            page.pointerUp()
            page.flushAcknowledgedDraw()
            let finished = try store.open(canvas)
            XCTAssertEqual(finished.objects.count, 1, "the owner's complete gesture is durable")
            if !deleting {
                XCTAssertEqual(finished.objects.first?.frame.x, 140)
                XCTAssertEqual(finished.objects.first?.frame.y, 120)
                args["expected_x"] = finished.objects.first?.frame.x
                args["expected_y"] = finished.objects.first?.frame.y
            }
            if finished.canvas.deletedAt != nil { continue }
            _ = try agent.drawAction(name, args, beforeMutation: {})
            if deleting {
                XCTAssertTrue(store.undo(on: canvas).isSaved)
                XCTAssertEqual(try store.open(canvas).objects, finished.objects, "restoring a deleted canvas keeps the stroke")
            } else {
                XCTAssertEqual(try store.open(canvas).objects.first?.frame.x, 300)
                XCTAssertEqual(try store.open(canvas).objects.first?.frame.y, 300)
            }
        }
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

    func testCatchupR8AgentUndoCannotChangeACanvasDuringTheOwnerGesture() async throws {
        for durable in [false, true] {
            let store: DrawStore = durable ? try persistent() : DrawInMemoryStore()
            let page = DrawPageModel(store: store)
            page.start()
            let canvas = try XCTUnwrap(page.canvasID)
            let box = DrawObject(frame: DrawFrame(x: 40, y: 80, width: 100, height: 50), content: .shape(.rectangle))
            XCTAssertTrue(page.perform(.put([box])).isSaved)
            let agent = try actions(store)
            let request = agent.beginRequest(title: "Agent move")
            _ = try await agent.call(name: "draw_move_object", arguments: ["canvas_id": canvas.uuidString,
                "object_id": box.id.uuidString, "expected_x": 40, "expected_y": 80, "x": 60, "y": 80],
                watching: false, requestID: request)
            page.syncExternalChanges()
            page.setTool(.select)
            page.pointerDown(at: page.viewport.screen(CGPoint(x: 80, y: 100)))
            page.pointerDragged(to: page.viewport.screen(CGPoint(x: 100, y: 110)))
            let before = try store.open(canvas).objects
            let result = await agent.undo(changeSet: request)
            XCTAssertEqual(result.undone, 0)
            XCTAssertEqual(result.failures.count, 1)
            XCTAssertNotNil(page.live)
            XCTAssertEqual(try store.open(canvas).objects, before)
            page.pointerUp()
            page.flushAcknowledgedDraw()
            XCTAssertEqual(try store.open(canvas).objects.first?.frame.x, 80)
        }
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

    func testClipboardOlderImageCopyCannotOverwriteLaterCopyCutOrExternalChange() async throws {
        for later in ["copy", "cut", "external", "beforeTaskStarts"] {
            let page = DrawPageModel(store: DrawInMemoryStore())
            page.start()
            let object = DrawObject(content: .shape(.rectangle))
            XCTAssertTrue(page.perform(.put([object])).isSaved)
            page.select([object.id])
            let pb = NSPasteboard(name: .init("DrawClipboard-\(UUID())"))
            page.pasteboard = pb
            let gate = Draw3Gate()
            page.images.copyRenderer = { _, _ in await gate.wait(); return Data([1, 2, 3]) }
            page.images.copyAsImage([object])
            let task = page.images.lastTask
            if later != "beforeTaskStarts" { await Task.yield() }
            switch later {
            case "copy": page.copySelection()
            case "cut": page.cutSelection()
            default:
                pb.clearContents()
                pb.setString("Newer external copy", forType: .string)
            }
            let expectedTypes = pb.types
            let expected = expectedTypes?.map { pb.data(forType: $0) }
            gate.open()
            await task?.value
            XCTAssertEqual(pb.types, expectedTypes, later)
            XCTAssertEqual(pb.types?.map { pb.data(forType: $0) }, expected, later)
            pb.releaseGlobally()
        }
    }

    func testClipboardOriginalImageCopyRespectsExternalChangeBeforeTaskStarts() async throws {
        let page = DrawPageModel(store: DrawInMemoryStore())
        let pb = NSPasteboard(name: .init("DrawOriginalClipboard-\(UUID())"))
        defer { pb.releaseGlobally() }
        page.pasteboard = pb
        let image = DrawImage(original: Draw3Images.encoded(width: 20, height: 10), pixelWidth: 20, pixelHeight: 10)
        page.images.copyAsImage([DrawObject(content: .image(image))])
        pb.clearContents()
        pb.setString("Later clipboard", forType: .string)
        await page.images.lastTask?.value
        XCTAssertEqual(pb.string(forType: .string), "Later clipboard")
        XCTAssertNil(pb.data(forType: .png))
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

    func testHunt17DeletingImmediatelyAfterStrokeKeepsStrokeInCanvasRestore() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let canvasID = try XCTUnwrap(page.canvasID)
        let original = DrawObject(content: .shape(.rectangle))
        XCTAssertTrue(page.perform(.put([original])).isSaved)

        page.setTool(.pen)
        page.pointerDown(at: CGPoint(x: 50, y: 140))
        page.pointerDragged(to: CGPoint(x: 90, y: 155))
        page.pointerUp(at: CGPoint(x: 120, y: 160))
        XCTAssertEqual(page.objects.count, 2, "A completed stroke appears before its queued disk write")

        let toasts = PanelToastCenter()
        page.library.toasts = toasts
        page.library.perform(.delete)
        XCTAssertTrue(page.library.undoDeletionIfOffered())
        XCTAssertEqual(try store.open(canvasID).objects.count, 2,
                       "Delete/Undo must restore a stroke completed immediately before opening the library")
    }

    func testHunt17RapidDuplicateThenCopyUsesTheVisibleSelection() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let original = DrawObject(content: .shape(.ellipse))
        XCTAssertTrue(page.perform(.put([original])).isSaved)
        let pasteboard = NSPasteboard(name: .init("DrawRapidCopy-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        page.pasteboard = pasteboard
        page.select([original.id])
        page.duplicateSelection()
        let copiedID = try XCTUnwrap(page.selection.first)
        XCTAssertNotEqual(copiedID, original.id)

        page.copySelection()
        let data = try XCTUnwrap(pasteboard.data(forType: .init(DrawStore.clipboardType)))
        let other = store.create(name: "Paste target")
        XCTAssertTrue(store.paste(data, into: other.id).isSaved)
        XCTAssertEqual(try store.open(other.id).objects.map(\.content), [original.content],
                       "Copy immediately after Duplicate must copy the visible new object")
    }

    func testHunt17RapidDuplicateThenCutRemovesOnlyTheDuplicate() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let id = try XCTUnwrap(page.canvasID)
        let original = DrawObject(content: .shape(.rectangle))
        XCTAssertTrue(page.perform(.put([original])).isSaved)
        let pasteboard = NSPasteboard(name: .init("DrawRapidCut-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        page.pasteboard = pasteboard
        page.select([original.id])
        page.duplicateSelection()
        let duplicatedID = try XCTUnwrap(page.selection.first)

        page.cutSelection()
        page.flushAcknowledgedDraw()
        XCTAssertEqual(try store.open(id).objects.map(\.id), [original.id],
                       "A rapid Cut must remove the just-duplicated object")
        XCTAssertTrue(store.undo(on: id).isSaved)
        XCTAssertEqual(Set(try store.open(id).objects.map(\.id)), Set([original.id, duplicatedID]),
                       "Undo after Cut restores the exact duplicate")
    }

    func testHunt17ResumingDeletedLastCanvasOpensAnEditableLiveCanvas() throws {
        let defaultsName = "DrawLastCanvas-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = DrawInMemoryStore()
        let deleted = store.create(name: "Deleted while away")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .shape(.rectangle))]), on: deleted.id).isSaved)
        let surviving = store.create(name: "Working canvas")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .shape(.ellipse))]), on: surviving.id).isSaved)
        defaults.set(deleted.id.uuidString, forKey: "AtticDraw.lastCanvas")
        XCTAssertTrue(store.perform(.deleteCanvas, on: deleted.id).isSaved)

        let relaunched = DrawPageModel(store: store, resumeDefaults: defaults)
        relaunched.start()
        XCTAssertEqual(relaunched.canvasID, surviving.id,
                       "A saved last-canvas pointer can outlive its deletion; startup must choose a live board")
        XCTAssertTrue(relaunched.perform(.put([DrawObject(content: .text("Can draw"))])).isSaved)
    }

    func testHunt17DuplicatingCanvasImmediatelyAfterInkIncludesTheLastStroke() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let source = try XCTUnwrap(page.canvasID)
        XCTAssertTrue(page.perform(.put([DrawObject(content: .shape(.rectangle))])).isSaved)
        page.setTool(.pen)
        page.pointerDown(at: CGPoint(x: 35, y: 80))
        page.pointerDragged(to: CGPoint(x: 110, y: 125))
        page.pointerUp()
        XCTAssertEqual(page.objects.count, 2)
        page.library.perform(.duplicate)

        let copyID = try XCTUnwrap(page.canvasID)
        XCTAssertNotEqual(copyID, source)
        XCTAssertEqual(try store.open(copyID).objects.map(\.content), try store.open(source).objects.map(\.content),
                       "A library duplicate must include the last visible but queued stroke")
    }

    func testHunt17TagImmediatelyAfterStrokeUndoesTheTagBeforeTheInk() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let id = try XCTUnwrap(page.canvasID)
        page.setTool(.shape)
        page.pointerDown(at: CGPoint(x: 25, y: 30))
        page.pointerDragged(to: CGPoint(x: 65, y: 80))
        page.pointerUp()
        XCTAssertEqual(page.objects.count, 1)
        page.library.setTag("important", on: true)
        XCTAssertEqual(try store.open(id).canvas.tags, ["important"])
        page.undo()
        XCTAssertEqual(try store.open(id).canvas.tags, [], "Undo should reverse the latest tag edit")
        XCTAssertEqual(try store.open(id).objects.count, 1, "Undo must not consume the older stroke")
        page.redo()
        XCTAssertEqual(try store.open(id).canvas.tags, ["important"])
        XCTAssertEqual(try store.open(id).objects.count, 1)
    }

    func testHunt17PasteAfterQueuedDuplicateUndoesPasteBeforeDuplicate() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let id = try XCTUnwrap(page.canvasID)
        let original = DrawObject(content: .shape(.rectangle))
        XCTAssertTrue(page.perform(.put([original])).isSaved)
        let pasteboard = NSPasteboard(name: .init("DrawHunt17Paste-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        page.pasteboard = pasteboard
        page.select([original.id])
        page.copySelection()
        page.duplicateSelection()
        let duplicateID = try XCTUnwrap(page.selection.first)
        page.paste()
        let pastedID = try XCTUnwrap(page.selection.first)
        XCTAssertNotEqual(pastedID, duplicateID)
        page.flushAcknowledgedDraw()
        let snapshot = try store.open(id)
        XCTAssertEqual(snapshot.objects.count, 3)
        XCTAssertEqual(snapshot.objects.last?.id, pastedID, "Pasted objects must be layered above earlier duplicates")
        page.undo()
        XCTAssertEqual(Set(try store.open(id).objects.map(\.id)), Set([original.id, duplicateID]),
                       "Undo after Duplicate, Paste must remove Paste, the latest user action")
        page.redo()
        XCTAssertEqual(Set(try store.open(id).objects.map(\.id)), Set([original.id, duplicateID, pastedID]))
    }

    func testHunt17MaximumAndMinimumLayersStayEditableAndUndoable() throws {
        let store = try persistent()
        let page = DrawPageModel(store: store)
        page.start()
        let id = try XCTUnwrap(page.canvasID)
        let highest = DrawObject(zIndex: .max, content: .shape(.ellipse))
        XCTAssertTrue(page.perform(.put([highest])).isSaved)
        page.setTool(.shape)
        page.pointerDown(at: CGPoint(x: 30, y: 35))
        page.pointerDragged(to: CGPoint(x: 85, y: 110))
        page.pointerUp()
        page.flushAcknowledgedDraw()
        XCTAssertEqual(try store.open(id).objects.count, 2)
        XCTAssertEqual(try store.open(id).objects.last?.content, .shape(.rectangle))
        page.undo()
        XCTAssertEqual(try store.open(id).objects, [highest], "Undo must restore the original Int64.max layer")

        page.beginText(at: CGPoint(x: 75, y: 90))
        page.typed("Highest layer text")
        page.endEditing()
        XCTAssertEqual(try store.open(id).objects.count, 2)
        page.undo()
        XCTAssertEqual(try store.open(id).objects, [highest], "Undo of text also restores the old layer")

        let clipboard = try store.copy([highest.id], from: id)
        XCTAssertTrue(store.paste(clipboard, into: id).isSaved)
        XCTAssertEqual(try store.open(id).objects.count, 2)
        XCTAssertTrue(store.undo(on: id).isSaved)
        page.syncExternalChanges()
        XCTAssertEqual(try store.open(id).objects, [highest])

        page.setTool(.select)
        page.select([highest.id])
        page.duplicateSelection()
        page.flushAcknowledgedDraw()
        XCTAssertEqual(try store.open(id).objects.count, 2)
        page.undo()
        XCTAssertEqual(try store.open(id).objects, [highest])

        let lowest = DrawObject(zIndex: .min, content: .shape(.rectangle))
        XCTAssertTrue(page.perform(.put([lowest])).isSaved)
        page.select([highest.id])
        page.arrange(toFront: false)
        page.flushAcknowledgedDraw()
        XCTAssertEqual(try store.open(id).objects.first?.id, highest.id)
        page.undo()
        XCTAssertEqual(try store.open(id).objects, [lowest, highest], "Undo restores both extreme layer values")

        let agent = try actions(store)
        _ = try agent.drawAction("draw_add_shape", ["canvas_id": id.uuidString, "shape": "ellipse", "x": 25, "y": 35], beforeMutation: {})
        XCTAssertEqual(try store.open(id).objects.count, 3)
        XCTAssertEqual(try DrawPersistentStore(container: store.container).open(id).objects,
                       try store.open(id).objects)
    }

    func testHunt17SeededToolsPaletteClipboardAndUndoSurviveReopen() throws {
        for seed: UInt64 in [0xD17A_0101, 0xD17A_0202] {
            var state = seed
            func choose(_ range: UInt64) -> Int {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                return Int(state % range)
            }
            let store = try persistent()
            let page = DrawPageModel(store: store)
            page.start()
            let canvasID = try XCTUnwrap(page.canvasID)
            let pasteboard = NSPasteboard(name: .init("DrawHunt17Seed-\(seed)"))
            defer { pasteboard.releaseGlobally() }
            page.pasteboard = pasteboard
            for step in 0..<210 {
                let before = try store.open(canvasID).objects
                let action = choose(8)
                let x = CGFloat(20 + choose(170))
                let y = CGFloat(30 + choose(140))
                if action < 2 || before.isEmpty {
                    page.setTool(.pen)
                    page.pointerDown(at: CGPoint(x: x, y: y))
                    page.pointerDragged(to: CGPoint(x: x + 20, y: y + 16))
                    page.pointerUp(at: CGPoint(x: x + 35, y: y + 21))
                } else if action < 4 {
                    page.setTool(.shape)
                    page.pickShape(DrawShape.allCases[choose(UInt64(DrawShape.allCases.count))])
                    page.pointerDown(at: CGPoint(x: x, y: y))
                    page.pointerDragged(to: CGPoint(x: x + 35, y: y + 25))
                    page.pointerUp()
                } else {
                    page.setTool(.select)
                    let picked = before[choose(UInt64(before.count))]
                    page.select([picked.id])
                    switch action {
                    case 4:
                        page.styleSelection(colour: [.red, .blue, .green, .orange][choose(4)])
                    case 5:
                        page.duplicateSelection()
                    case 6:
                        page.deleteSelection()
                    default:
                        page.copySelection()
                        page.paste()
                    }
                }
                page.flushAcknowledgedDraw()
                let after = try store.open(canvasID).objects
                XCTAssertEqual(page.objects, after, "seed \(seed), step \(step), action \(action)")
                if before != after {
                    page.undo()
                    XCTAssertEqual(try store.open(canvasID).objects, before,
                                   "Undo seed \(seed), step \(step), action \(action)")
                    page.redo()
                    XCTAssertEqual(try store.open(canvasID).objects, after,
                                   "Redo seed \(seed), step \(step), action \(action)")
                }
                if step.isMultiple(of: 30) {
                    let reopened = try DrawPersistentStore(container: store.container).open(canvasID)
                    XCTAssertEqual(reopened.objects, after, "Reopen seed \(seed), step \(step)")
                    XCTAssertFalse(store.hasUnsettledEdits)
                }
            }
            print("DRAW_HUNT17_SEED=\(seed) STEPS=210")
        }
    }

    func testHunt17QuitImmediatelyAfterStrokeRestoresTheSameCanvasFromDisk() async throws {
        let root = try directory()
        let defaultsName = "DrawHunt17Reopen-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var canvasID = UUID()
        var expected: [DrawObject] = []
        do {
            let store = try persistent(at: root)
            let page = DrawPageModel(store: store, resumeDefaults: defaults)
            page.start()
            canvasID = try XCTUnwrap(page.canvasID)
            page.setTool(.pen)
            page.pointerDown(at: CGPoint(x: 40, y: 55))
            page.pointerDragged(to: CGPoint(x: 120, y: 90))
            page.pointerUp()
            expected = page.objects
            XCTAssertEqual(expected.count, 1)
            let didQuit = await page.prepareToQuit()
            XCTAssertTrue(didQuit)
            XCTAssertEqual(try store.open(canvasID).objects, expected)
        }
        let reopenedStore = try persistent(at: root)
        let relaunched = DrawPageModel(store: reopenedStore, resumeDefaults: defaults)
        relaunched.start()
        XCTAssertEqual(relaunched.canvasID, canvasID)
        XCTAssertEqual(relaunched.objects, expected)
        XCTAssertEqual(try reopenedStore.open(canvasID).objects, expected)
    }
}
