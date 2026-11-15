import AppKit
import QuartzCore
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

    /// BG-31 round 2 (Opus R-11): an agent's explicit size is the size asked
    /// for. A 400 x 3 image asked for 400 x 6 scales proportionally to 800 x 6,
    /// and a thin non-image stroke asked for 50 x 1 is not lifted to the pointer's
    /// 4 pt minimum.
    /// BG-31 round 3 (Opus R-15, Dot R-13): a line or arrow keeps the signed
    /// difference of its endpoints, so its frame can have a negative width or
    /// height. The agent's size is the box the object covers: every endpoint
    /// direction gets exactly the asked size, with one Undo.
    func testR4AgentFlatLineResizeNeverClaimsAnInexactSuccess() throws {
        for kind in [DrawShape.line, .arrow] {
            for frame in [DrawFrame(x: 200, y: 200, width: 100, height: 0),
                          DrawFrame(x: 200, y: 200, width: 0, height: -100)] {
                let store = try persistent(at: directory()), agent = try actions(store)
                let c = store.create(name: "Flat")
                let line = DrawObject(frame: frame, content: .shape(kind))
                XCTAssertTrue(store.perform(.put([line]), on: c.id).isSaved)
                let token = try XCTUnwrap(read(agent, canvas: c.id)["object_token"] as? String)
                let reply = try agent.drawAction("draw_resize_object", ["canvas_id": c.id.uuidString,
                    "object_id": line.id.uuidString, "object_token": token, "width": 50, "height": 30], beforeMutation: {}).0
                let changed = try XCTUnwrap(store.open(c.id).objects.first)
                let box = DrawGeometry.frame(changed.frame)
                XCTAssertEqual(box.width, frame.width == 0 ? 0 : 50, accuracy: 0.001)
                XCTAssertEqual(box.height, frame.height == 0 ? 0 : 30, accuracy: 0.001)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
                let reported = try XCTUnwrap(json["frame"] as? [String: Any])
                XCTAssertEqual(reported["width"] as? Double, changed.frame.width)
                XCTAssertEqual(reported["height"] as? Double, changed.frame.height)
                XCTAssertTrue(store.undo(on: c.id).isSaved)
                XCTAssertEqual(try store.open(c.id).objects, [line])
                XCTAssertTrue(store.redo(on: c.id).isSaved)
                XCTAssertEqual(try DrawPersistentStore(container: store.container).open(c.id).objects, [changed])
            }
        }
    }

    func testR4NearFlatPointerResizeBoundsAmplificationAndRoundTrips() throws {
        for width in [0.0009, 0.001, 0.002] {
            for mirror in [false, true] {
                let store = try persistent(at: directory()), page = DrawPageModel(store: store)
                page.start()
                page.setBoard(size: CGSize(width: 320, height: 460), clearInsets: NSEdgeInsets(top: 48.5, left: 15.5, bottom: 48.5, right: 15.5))
                let frame = DrawFrame(x: 20, y: 80, width: mirror ? 3 : width, height: mirror ? width : 3)
                let stroke = DrawObject(frame: frame, content: .stroke([DrawPoint(x: frame.x, y: frame.y), DrawPoint(x: frame.x + frame.width, y: frame.y + frame.height)]))
                XCTAssertTrue(page.perform(.put([stroke])).isSaved)
                page.setTool(.select); page.select([stroke.id])
                page.setViewport(DrawViewport(zoom: DrawViewport.maxZoom), byUser: true)
                let spot = try XCTUnwrap(page.handleSpots.first { $0.handle == .bottomRight })
                let head = store.undoStepID(on: page.canvasID!)
                page.pointerDown(at: spot.point, shift: true)
                page.pointerDragged(to: CGPoint(x: spot.point.x + page.viewport.zoom, y: spot.point.y + page.viewport.zoom), shift: true)
                page.pointerUp(); page.flushAcknowledgedDraw()
                let changed = try XCTUnwrap(page.objects.first)
                let box = DrawGeometry.frame(changed.frame)
                XCTAssertLessThanOrEqual(max(box.width, box.height), 4.01, "1 pt travel cannot amplify a 3 pt object to thousands")
                XCTAssertNotEqual(changed, stroke, "the pointer fixture must actually resize")
                XCTAssertNotEqual(store.undoStepID(on: page.canvasID!), head)
                XCTAssertEqual(max(box.width, box.height), 4, accuracy: 0.01)
                page.undo(); XCTAssertEqual(page.objects, [stroke])
                page.redo(); XCTAssertEqual(page.objects, [changed])
                XCTAssertEqual(try DrawPersistentStore(container: store.container).open(page.canvasID!).objects, [changed])
            }
        }
    }

    func testBG31AgentResizeOfSignedLineAndArrowFramesIsExact() throws {
        for kind in [DrawShape.line, .arrow] {
            for (signX, signY) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] {
                let store = try persistent(at: directory())
                let canvas = store.create(name: "Signed \(kind)")
                let agent = try actions(store)
                let original = DrawObject(frame: DrawFrame(x: 200, y: 200, width: 100 * signX, height: 50 * signY),
                                          content: .shape(kind))
                XCTAssertTrue(store.perform(.put([original]), on: canvas.id).isSaved)
                let label = "\(kind) \(signX),\(signY)"
                func resize(_ width: Double, _ height: Double) throws {
                    let token = try XCTUnwrap(read(agent, canvas: canvas.id)["object_token"] as? String)
                    _ = try agent.drawAction("draw_resize_object", ["canvas_id": canvas.id.uuidString,
                        "object_id": original.id.uuidString, "object_token": token, "width": width, "height": height],
                        beforeMutation: {})
                }
                XCTAssertThrowsError(try resize(100, 50), "\(label): the current size is not a change")
                try resize(50, 25)
                let resized = try XCTUnwrap(store.open(canvas.id).objects.first)
                let box = DrawGeometry.frame(resized.frame)
                XCTAssertEqual(box.width, 50, accuracy: 0.001, label)
                XCTAssertEqual(box.height, 25, accuracy: 0.001, label)
                XCTAssertEqual(resized.frame.width.sign, original.frame.width.sign, "\(label): endpoint direction kept")
                XCTAssertEqual(resized.frame.height.sign, original.frame.height.sign, "\(label): endpoint direction kept")
                let origin = DrawGeometry.frame(original.frame)
                XCTAssertEqual(box.minX, origin.minX, accuracy: 0.001, "\(label): the top-left corner stays")
                XCTAssertEqual(box.minY, origin.minY, accuracy: 0.001, "\(label): the top-left corner stays")
                try resize(120, 80)
                XCTAssertEqual(store.undoStepID(on: canvas.id) == nil, false)
                XCTAssertTrue(store.undo(on: canvas.id).isSaved)
                XCTAssertEqual(try store.open(canvas.id).objects.first, resized, "\(label): one Undo takes back one resize")
                XCTAssertEqual(try DrawPersistentStore(container: store.container).open(canvas.id).objects.first, resized)
                XCTAssertTrue(store.undo(on: canvas.id).isSaved)
                XCTAssertEqual(try DrawPersistentStore(container: store.container).open(canvas.id).objects.first, original)
                XCTAssertTrue(store.redo(on: canvas.id).isSaved)
                XCTAssertEqual(try DrawPersistentStore(container: store.container).open(canvas.id).objects.first, resized)
            }
        }
    }

    func testBG31AgentResizeOfThinObjectsUsesNoPointerMinimum() throws {
        let store = try persistent()
        let canvas = store.create(name: "Thin")
        let agent = try actions(store)
        let image = DrawObject(frame: DrawFrame(x: 0, y: 0, width: 400, height: 3), content: .image(
            DrawImage(original: Draw3Images.encoded(width: 20, height: 10), pixelWidth: 20, pixelHeight: 10)))
        let points = [DrawPoint(x: 10, y: 20), DrawPoint(x: 60, y: 21), DrawPoint(x: 110, y: 22)]
        let stroke = DrawObject(frame: DrawGeometry.strokeFrame(points), content: .stroke(points))
        XCTAssertTrue(store.perform(.put([image, stroke]), on: canvas.id).isSaved)
        func token(of object: DrawObject) throws -> String {
            let text = try agent.drawAction("draw_read_canvas", ["canvas_id": canvas.id.uuidString], beforeMutation: {}).0
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let objects = try XCTUnwrap(response["objects"] as? [[String: Any]])
            let match = try XCTUnwrap(objects.first { ($0["id"] as? String) == object.id.uuidString || ($0["object_id"] as? String) == object.id.uuidString })
            return try XCTUnwrap(match["object_token"] as? String)
        }
        _ = try agent.drawAction("draw_resize_object", ["canvas_id": canvas.id.uuidString,
            "object_id": image.id.uuidString, "object_token": try token(of: image), "width": 400, "height": 6], beforeMutation: {})
        let scaled = try XCTUnwrap(store.open(canvas.id).objects.first { $0.id == image.id })
        XCTAssertEqual(scaled.frame.width, 800, accuracy: 0.001)
        XCTAssertEqual(scaled.frame.height, 6, accuracy: 0.001)
        _ = try agent.drawAction("draw_resize_object", ["canvas_id": canvas.id.uuidString,
            "object_id": stroke.id.uuidString, "object_token": try token(of: stroke), "width": 50, "height": 1], beforeMutation: {})
        let thin = try XCTUnwrap(store.open(canvas.id).objects.first { $0.id == stroke.id })
        XCTAssertEqual(thin.frame.height, stroke.frame.height / 2, accuracy: 0.01, "no 4 pt floor on an explicit size")
        XCTAssertEqual(thin.frame.width, stroke.frame.width / 2, accuracy: 0.01)
    }
}
extension DrawDataSafetyTests {
    private func r5CaptureFlatBoard(_ store: DrawStore, canvas: UUID, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["ATTIC_R5_RENDER_DIR"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrawR5-" + URL(fileURLWithPath: path).lastPathComponent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("R5_RENDER_ROOT=\(root.path)")
        let page = DrawPageModel(store: store)
        page.setBoard(size: CGSize(width: 320, height: 460), clearInsets: NSEdgeInsets(top: 48.5, left: 15.5, bottom: 48.5, right: 15.5))
        page.start(); page.open(canvas)
        let board = DrawBoardView(model: page)
        board.setFrameSize(CGSize(width: 320, height: 460))
        page.setViewport(DrawViewport(), byUser: true)
        page.setShown(true)
        defer { page.setShown(false) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3)); CATransaction.flush()
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 920, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 920))
        context.scaleBy(x: 2, y: 2); board.layer?.render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
    }

    func testR5FlatLineLengthResizeSucceedsAndReportsItsActualFrame() throws {
        for kind in [DrawShape.line, .arrow] {
            let root = try directory()
            var store: DrawPersistentStore! = try persistent(at: root)
            var agent: AgentActions! = try actions(store)
            let c = store.create(name: "Flat length")
            let line = DrawObject(frame: DrawFrame(x: 20, y: 80, width: 100, height: 0), content: .shape(kind))
            XCTAssertTrue(store.perform(.put([line]), on: c.id).isSaved)
            let label = kind == .line ? "line" : "arrow"
            try autoreleasepool { try r5CaptureFlatBoard(store, canvas: c.id, name: "flat-" + label + "-before") }
            let token = try XCTUnwrap(read(agent, canvas: c.id)["object_token"] as? String)
            let reply = try agent.drawAction("draw_resize_object", ["canvas_id": c.id.uuidString,
                "object_id": line.id.uuidString, "object_token": token, "width": 200, "height": 1], beforeMutation: {}).0
            let frame = try XCTUnwrap(store.open(c.id).objects.first).frame
            XCTAssertEqual(frame.width, 200, accuracy: 0.001)
            XCTAssertEqual(frame.height, 0, accuracy: 0.001)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let reported = try XCTUnwrap(json["frame"] as? [String: Any])
            XCTAssertEqual(reported["width"] as? Double, 200)
            XCTAssertEqual(reported["height"] as? Double, 0)
            try autoreleasepool { try r5CaptureFlatBoard(store, canvas: c.id, name: "flat-" + label + "-after") }
            XCTAssertTrue(store.undo(on: c.id).isSaved)
            XCTAssertEqual(try store.open(c.id).objects, [line])
            XCTAssertTrue(store.redo(on: c.id).isSaved)
            weak var abandoned = store
            agent = nil; store = nil // No clean close; reopen the file in a fresh container.
            XCTAssertNil(abandoned)
            XCTAssertEqual(try persistent(at: root).open(c.id).objects.first?.frame, frame)
        }
    }
}
