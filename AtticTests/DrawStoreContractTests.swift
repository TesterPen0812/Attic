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

    /// BG-27 review (Opus R-6, Dot R-4): evicting a canvas's body must not
    /// leave every visited canvas's Undo payloads (image bytes) resident for
    /// the whole session. The retained history is bounded.
    func testEvictedCanvasesDoNotKeepUnboundedUndoPayloads() throws {
        let store = DrawInMemoryStore()
        var ids: [UUID] = []
        for index in 0..<30 {
            let canvas = store.create(name: "Image \(index)")
            // Every canvas holds its own 4 MB, so the test measures resident size.
            let bytes = Data(repeating: UInt8(index + 1), count: 4_000_000)
            let image = DrawObject(content: .image(DrawImage(original: bytes, pixelWidth: 1_000, pixelHeight: 1_000)))
            XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
            ids.append(canvas.id)
        }
        let undoable = ids.filter { store.canUndo(on: $0) }
        XCTAssertLessThanOrEqual(undoable.count, 20,
                                 "30 canvases x 4 MB of images must not all stay undoable (\(undoable.count) did)")
        XCTAssertTrue(store.canUndo(on: ids[29]), "The canvas just edited keeps its Undo")
        XCTAssertFalse(store.canUndo(on: ids[0]), "The oldest evicted canvas gives up its payload first")
    }

    /// Dropping retained history frees the heaviest payloads, not the light
    /// restore steps a grouped Restore Selected offered to Undo (BG-27).
    func testHistoryBudgetKeepsLightRestoreStepsWhileDroppingImagePayloads() throws {
        let store = DrawInMemoryStore()
        var restored: [UUID] = []
        for index in 0..<10 {
            let canvas = store.create(name: "Restored \(index)")
            XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Saved \(index)"))]), on: canvas.id).isSaved)
            XCTAssertTrue(store.perform(.deleteCanvas, on: canvas.id).isSaved)
            XCTAssertTrue(store.perform(.restoreCanvas, on: canvas.id).isSaved)
            restored.append(canvas.id)
        }
        for index in 0..<30 {
            let canvas = store.create(name: "Heavy \(index)")
            let bytes = Data(repeating: UInt8(index + 1), count: 4_000_000)
            let image = DrawObject(content: .image(DrawImage(original: bytes, pixelWidth: 1_000, pixelHeight: 1_000)))
            XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
        }
        for id in restored { XCTAssertTrue(store.canUndo(on: id), "A light restore step must survive the budget") }
    }

    /// BG-27 round 2 (Dot R-1, Opus R-8): a grouped Restore Selected offers
    /// one Undo bound to the newest step of each restored canvas. Under
    /// budget pressure the oldest steps go, never those heads, even when the
    /// restored canvas also holds heavy image history.
    func testGroupedRestoreOfAHeavyHistoryStillUndoesUnderBudgetPressure() throws {
        let store = DrawInMemoryStore()
        let heavy = store.create(name: "Heavy history")
        for index in 0..<2 {
            let bytes = Data(repeating: UInt8(100 + index), count: 6_000_000)
            let image = DrawObject(content: .image(DrawImage(original: bytes, pixelWidth: 1_000, pixelHeight: 1_000)))
            XCTAssertTrue(store.perform(.put([image]), on: heavy.id).isSaved)
        }
        XCTAssertTrue(store.perform(.deleteCanvas, on: heavy.id).isSaved)
        let light = store.create(name: "Light")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Light"))]), on: light.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: light.id).isSaved)
        let report = DrawRecentlyDeleted.restoreTracked(
            [DrawDeletedItem(canvasID: heavy.id, objectID: nil), DrawDeletedItem(canvasID: light.id, objectID: nil)],
            store: store)
        XCTAssertEqual(report.actions.count, 2)
        let group = try XCTUnwrap(RecentlyDeletedRestoreUndo.make(
            drawStore: store, actions: report.actions, librarySteps: [], restored: 2))
        // Enough other heavy canvases to evict both restored ones and break the budget.
        for index in 0..<14 {
            let canvas = store.create(name: "Other \(index)")
            let bytes = Data(repeating: UInt8(index + 1), count: 6_000_000)
            let image = DrawObject(content: .image(DrawImage(original: bytes, pixelWidth: 1_000, pixelHeight: 1_000)))
            XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
        }
        XCTAssertFalse(store.cachedCanvasIDs.contains(heavy.id), "the restored canvas was evicted")
        XCTAssertEqual(group.undo(), .applied, "the offered Undo must still find both restore steps")
        XCTAssertNotNil(try store.open(heavy.id).canvas.deletedAt)
        XCTAssertNotNil(try store.open(light.id).canvas.deletedAt)
    }

    /// BG-27 round 2 (Opus R-9): a buffer shared by many steps (an image
    /// moved a hundred times, a thumbnail stamped onto each) is one buffer in
    /// memory, so it counts once toward the budget.
    func testHistoryBudgetCountsASharedBufferOnce() throws {
        let store = DrawInMemoryStore()
        var ids: [UUID] = []
        for index in 0..<3 {
            let canvas = store.create(name: "Moved \(index)")
            var image = DrawObject(content: .image(DrawImage(
                original: Data(repeating: UInt8(index + 1), count: 1_000_000), pixelWidth: 1_000, pixelHeight: 1_000)))
            XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
            for step in 1...99 {
                image.frame.x = Double(step)
                XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
            }
            ids.append(canvas.id)
        }
        for index in 0..<12 {
            let canvas = store.create(name: "Light \(index)")
            XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Light"))]), on: canvas.id).isSaved)
        }
        for id in ids {
            XCTAssertFalse(store.cachedCanvasIDs.contains(id), "evicted, so its history is under the budget")
            var undone = 0
            while store.canUndo(on: id), store.undo(on: id).isSaved { undone += 1 }
            XCTAssertEqual(undone, 100, "3 MB of real image bytes must keep all 100 steps undoable")
        }
    }

    // MARK: BG-27 round 3 (Dot R-8, R-9; Opus R-16, R-20)

    private func round3PersistentStore() throws -> DrawPersistentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrawBudget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        return DrawPersistentStore(container: try ModelContainer(for: Schema(PersistenceController.appModelTypes),
            configurations: ModelConfiguration(url: root.appendingPathComponent("draw.store"), cloudKitDatabase: .none)))
    }

    private func heavyImage(fill: UInt8, bytes: Int) -> DrawObject {
        // A renderable PNG with deterministic retained byte size, independent
        // of the encoder's compression ratio. ImageIO accepts trailing data.
        var data = Draw3Images.encoded(width: 1_000, height: 1_000)
        data.append(Data(repeating: fill, count: max(0, bytes - data.count)))
        XCTAssertNotNil(Draw3Images.cgImage(data), "the fixture must remain a real image")
        return DrawObject(content: .image(DrawImage(original: data, pixelWidth: 1_000, pixelHeight: 1_000)))
    }

    /// Enough saved, light canvases to push every earlier one out of the body cache.
    private func evictEveryEarlierCanvas(_ store: DrawStore, count: Int = 12) {
        for index in 0..<count {
            let canvas = store.create(name: "Filler \(index)")
            XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Filler"))]), on: canvas.id).isSaved)
        }
    }

    /// Dot R-9: a canvas whose text index is about 9 MB holds that one string
    /// in every copy of the canvas a step keeps (before, after, change). It
    /// is one buffer, so a two-item restore group over it must still Undo
    /// once the canvas is out of the cache.
    func testGroupedRestoreOfACanvasWithAHugeTextIndexStillUndoesAfterEviction() throws {
        let store = try round3PersistentStore()
        let big = store.create(name: "Big text")
        let text = String(repeating: "lorem ipsum dolor ", count: 500_000) // 9,000,000 bytes
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text(text))]), on: big.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: big.id).isSaved)
        let light = store.create(name: "Light")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Light"))]), on: light.id).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: light.id).isSaved)
        let report = DrawRecentlyDeleted.restoreTracked(
            [DrawDeletedItem(canvasID: big.id, objectID: nil), DrawDeletedItem(canvasID: light.id, objectID: nil)],
            store: store)
        XCTAssertEqual(report.actions.count, 2)
        let group = try XCTUnwrap(RecentlyDeletedRestoreUndo.make(
            drawStore: store, actions: report.actions, librarySteps: [], restored: 2))
        evictEveryEarlierCanvas(store)
        XCTAssertFalse(store.cachedCanvasIDs.contains(big.id), "the restored canvas was forced out of the cache")
        XCTAssertEqual(group.undo(), .applied, "the offered group Undo must still work")
        XCTAssertNotNil(try store.open(big.id).canvas.deletedAt)
        XCTAssertNotNil(try store.open(light.id).canvas.deletedAt)
    }

    func testSharedTextCopiesKeepUnpinnedHistoryUnderBudget() throws {
        let store = try round3PersistentStore()
        let canvas = store.create(name: "Text")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text(String(repeating: "x", count: 9_000_000)))]), on: canvas.id).isSaved)
        for step in 1..<4 {
            XCTAssertTrue(store.perform(.rename("Name \(step)"), on: canvas.id).isSaved)
        }
        evictEveryEarlierCanvas(store)
        XCTAssertFalse(store.cachedCanvasIDs.contains(canvas.id))
        var undone = 0
        while store.canUndo(on: canvas.id), store.undo(on: canvas.id).isSaved { undone += 1 }
        XCTAssertEqual(undone, 4, "the same text in before/after/change and the object is one buffer")
    }

    /// Dot R-8: when the heads an offered Undo is bound to are over the budget
    /// by themselves, the offer either keeps its head or is gone; it is never
    /// offered and then refused. Two restored images of 20 MB each are 40 MB.
    func testAGroupRestoreWhoseHeadsAreOverBudgetKeepsItsOfferedUndo() throws {
        let store = try round3PersistentStore()
        var items: [DrawDeletedItem] = []
        var ids: [UUID] = []
        for index in 0..<2 {
            let canvas = store.create(name: "Photo \(index)")
            let image = heavyImage(fill: UInt8(60 + index), bytes: 20_000_000)
            XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
            XCTAssertTrue(store.perform(.remove([image.id]), on: canvas.id).isSaved)
            items.append(DrawDeletedItem(canvasID: canvas.id, objectID: image.id))
            ids.append(canvas.id)
        }
        let report = DrawRecentlyDeleted.restoreTracked(items, store: store)
        XCTAssertEqual(report.actions.count, 2)
        let group = try XCTUnwrap(RecentlyDeletedRestoreUndo.make(
            drawStore: store, actions: report.actions, librarySteps: [], restored: 2))
        evictEveryEarlierCanvas(store)
        XCTAssertFalse(store.cachedCanvasIDs.contains(ids[0]))
        XCTAssertEqual(group.undo(), .applied, "offered, so it must not fail")
        for id in ids { XCTAssertTrue(try store.open(id).objects.isEmpty, "both images are deleted again") }
    }

    func testRestorePinsEachMemberBeforeRestoringTheNextMember() throws {
        let store = try round3PersistentStore()
        var items: [DrawDeletedItem] = []
        for index in 0..<2 {
            let canvas = store.create(name: "Photo \(index)")
            let image = heavyImage(fill: UInt8(90 + index), bytes: 34_000_000)
            XCTAssertTrue(store.perform(.put([image]), on: canvas.id).isSaved)
            XCTAssertTrue(store.perform(.remove([image.id]), on: canvas.id).isSaved)
            items.append(DrawDeletedItem(canvasID: canvas.id, objectID: image.id))
        }
        // These real unsaved drafts keep cache pressure high while the group
        // is still being assembled, before `make` can acquire any pins.
        for index in 0..<8 { _ = store.create(name: "Draft \(index)") }
        let report = DrawRecentlyDeleted.restoreTracked(items, store: store)
        XCTAssertEqual(report.actions.count, 2)
        for action in report.actions {
            XCTAssertEqual(store.undoStepID(on: action.canvasID), action.historyStepID,
                           "the first member cannot lose its token while the second restores")
        }
        let group = try XCTUnwrap(RecentlyDeletedRestoreUndo.make(drawStore: store, actions: report.actions, librarySteps: [], restored: 2))
        XCTAssertEqual(group.undo(), .applied)
        for item in items { XCTAssertTrue(try store.open(item.canvasID).objects.isEmpty) }
    }

    /// The pin an offer holds exempts its history from the whole-history
    /// fallback while the offer lives; an unpinned heavy head still goes, and
    /// a released pin protects nothing.
    func testAPinnedHeadSurvivesTheBudgetAndAReleasedOrMissingPinDoesNot() throws {
        let store = try round3PersistentStore()
        func heavyCanvas(_ name: String, fill: UInt8) throws -> (id: UUID, head: UUID) {
            let canvas = store.create(name: name)
            XCTAssertTrue(store.perform(.put([heavyImage(fill: fill, bytes: 20_000_000), heavyImage(fill: fill + 1, bytes: 20_000_000)]),
                                        on: canvas.id).isSaved)
            return (canvas.id, try XCTUnwrap(store.undoStepID(on: canvas.id)))
        }
        let pinned = try heavyCanvas("Pinned", fill: 10)
        let loose = try heavyCanvas("Loose", fill: 30)
        let released = try heavyCanvas("Released", fill: 50)
        var offer = store.pinHistoryStep(pinned.head)
        var gone = store.pinHistoryStep(released.head)
        gone = nil
        evictEveryEarlierCanvas(store)
        XCTAssertEqual(store.undoStepID(on: pinned.id), pinned.head, "the pinned head is still there")
        XCTAssertNil(store.undoStepID(on: loose.id), "no offer, over budget: the history goes")
        XCTAssertNil(store.undoStepID(on: released.id), "a released pin protects nothing")
        XCTAssertTrue(store.undo(on: pinned.id).isSaved)
        offer = nil
        _ = gone; _ = offer
    }

    func testReleasingTheLastOfferLetsTheBudgetReclaimItsHistory() throws {
        let store = try round3PersistentStore()
        let canvas = store.create(name: "Offered")
        XCTAssertTrue(store.perform(.put([heavyImage(fill: 7, bytes: 34_000_000)]), on: canvas.id).isSaved)
        let head = try XCTUnwrap(store.undoStepID(on: canvas.id))
        var offer = store.pinHistoryStep(head)
        for index in 0..<8 { _ = store.create(name: "Draft \(index)") }
        XCTAssertFalse(store.cachedCanvasIDs.contains(canvas.id))
        withExtendedLifetime(offer) { XCTAssertEqual(store.undoStepID(on: canvas.id), head) }
        offer = nil
        _ = store.create(name: "Another draft") // no new saved history to invalidate the budget cache
        XCTAssertNil(store.undoStepID(on: canvas.id), "a withdrawn offer must no longer exempt its history")
    }

    /// Opus R-16: one image moved 100 times is one buffer. Trimming its steps
    /// frees almost nothing, so it must not be cut while another canvas holds
    /// the bytes that are actually over budget.
    func testTrimmingFreesRealBytesInsteadOfCuttingASharedBufferHistory() async throws {
        func nextEvent() async {
            await withCheckedContinuation { ready in DispatchQueue.main.async { ready.resume() } }
        }
        let store = try round3PersistentStore()
        let moved = store.create(name: "Moved")
        var image = heavyImage(fill: 9, bytes: 5_000_000)
        XCTAssertTrue(store.perform(.put([image]), on: moved.id).isSaved)
        for step in 1...100 {
            image.frame.x = Double(step)
            // Separate pointer commits normally drain AppKit's autoreleases.
            XCTAssertTrue(autoreleasepool { store.perform(.put([image]), on: moved.id).isSaved })
            await nextEvent()
        }
        let pasted = store.create(name: "Pasted")
        for index in 0..<10 {
            XCTAssertTrue(autoreleasepool {
                store.perform(.put([heavyImage(fill: UInt8(20 + index), bytes: 4_000_000)]), on: pasted.id).isSaved
            })
            await nextEvent()
        }
        evictEveryEarlierCanvas(store)
        XCTAssertFalse(store.cachedCanvasIDs.contains(moved.id))
        var undone = 0
        while store.canUndo(on: moved.id), autoreleasepool(invoking: { store.undo(on: moved.id).isSaved }) {
            undone += 1
            await nextEvent()
        }
        XCTAssertEqual(undone, 100, "its steps hold one 5 MB buffer; cutting them frees nothing")
        let restored = try DrawPersistentStore(container: store.container).open(moved.id).objects
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.frame.x, 0, "all 100 moves are undone durably")
    }

    func testTrimmingRanksWhatIsFreedAfterAnotherHistorySharesTheBuffer() throws {
        let store = try round3PersistentStore()
        let original = store.create(name: "Original")
        XCTAssertTrue(store.perform(.put([heavyImage(fill: 3, bytes: 20_000_000)]), on: original.id).isSaved)
        XCTAssertTrue(store.perform(.put([heavyImage(fill: 4, bytes: 5_000_000)]), on: original.id).isSaved)
        let duplicate = try XCTUnwrap(store.duplicate(original.id))
        evictEveryEarlierCanvas(store, count: 7)
        XCTAssertFalse(store.cachedCanvasIDs.contains(original.id))
        XCTAssertTrue(store.cachedCanvasIDs.contains(duplicate.id), "original measured before its duplicate enters the ledger")
        evictEveryEarlierCanvas(store, count: 1)
        XCTAssertFalse(store.cachedCanvasIDs.contains(duplicate.id))

        let distinct = store.create(name: "Distinct")
        XCTAssertTrue(store.perform(.put([heavyImage(fill: 5, bytes: 10_000_000)]), on: distinct.id).isSaved)
        XCTAssertTrue(store.perform(.put([heavyImage(fill: 6, bytes: 1_000_000)]), on: distinct.id).isSaved)
        evictEveryEarlierCanvas(store)
        XCTAssertEqual(store.historyChanges(on: original.id)?.undo.count, 2,
                       "the duplicate now holds the 20 MB; only Distinct's old step frees its image")
        XCTAssertTrue(store.undo(on: original.id).isSaved)
        XCTAssertTrue(store.undo(on: original.id).isSaved)
        XCTAssertTrue(try store.open(original.id).objects.isEmpty)
    }

    /// Opus R-20: accounting belongs to each committed step. Eviction adds
    /// those footprints without walking any of the newcomer's objects.
    func testEvictionCountsOnlyTheNewlyEvictedHistory() throws {
        let store = try round3PersistentStore()
        for index in 0..<21 {
            let canvas = store.create(name: "Busy \(index)")
            var objects = (0..<5).map { DrawObject(frame: DrawFrame(x: Double($0), y: 0, width: 10, height: 10), content: .shape(.rectangle)) }
            XCTAssertTrue(store.perform(.put(objects), on: canvas.id).isSaved)
            for step in 1..<50 {
                for slot in objects.indices { objects[slot].frame.x += Double(step) }
                XCTAssertTrue(autoreleasepool { store.perform(.put(objects), on: canvas.id).isSaved })
            }
        }
        // 13 canvases are evicted by now; one more is evicted by creating this one.
        HistoryLedgerProbe.reset()
        _ = store.create(name: "One more")
        let visits = HistoryLedgerProbe.stepVisits
        XCTAssertEqual(visits, 0, "eviction must use the committed steps' footprints (\(visits) steps remeasured)")
    }

    /// Opus R-20: the cost, measured. 20 evicted histories of 100 steps x 500
    /// objects, then more evictions. Printed; the guard above is the count.
    func testReportEvictionCostForTwentyBigEvictedHistories() throws {
        XCTAssertTrue(Thread.isMainThread)
        let store = DrawInMemoryStore()
        var offers: [AnyObject] = []
        for index in 0..<28 {
            let canvas = store.create(name: "Big \(index)")
            var objects = (0..<500).map { DrawObject(frame: DrawFrame(x: Double($0), y: 0, width: 10, height: 10), content: .shape(.rectangle)) }
            for step in 0..<100 {
                if step > 0 { for slot in objects.indices { objects[slot].frame.x += Double(step % 3) + 1 } }
                XCTAssertTrue(store.perform(.put(objects), on: canvas.id).isSaved)
                offers.append(try XCTUnwrap(store.pinHistoryStep(try XCTUnwrap(store.undoStepID(on: canvas.id)))))
            }
        }
        func timed(_ action: () -> Void) -> Double {
            let start = ContinuousClock.now
            action()
            let duration = start.duration(to: .now)
            return Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
        }
        withExtendedLifetime(offers) {
            var full: [Double] = [], incremental: [Double] = [], eviction: [Double] = []
            // A/B interleaved in one process, same 20 histories, all 2,000
            // steps really retained. Persistence is excluded from this ledger
            // microbenchmark; the behavioral tests use file-backed stores.
            for _ in 0..<5 {
                var rebuilt = (histories: 0, steps: 0, bytes: 0)
                full.append(timed {
                    rebuilt = store.historyLedgerWorkForTesting(rebuild: true)
                })
                XCTAssertEqual(rebuilt.histories, 20)
                XCTAssertEqual(rebuilt.steps, 2_000)
                HistoryLedgerProbe.reset()
                var maintained = (histories: 0, steps: 0, bytes: 0)
                incremental.append(timed { maintained = store.historyLedgerWorkForTesting(rebuild: false) })
                XCTAssertEqual(maintained.bytes, rebuilt.bytes, "incremental accounting agrees with a full rebuild")
                XCTAssertEqual(HistoryLedgerProbe.stepVisits, 0, "already accounted histories are never remeasured")
            }
            for index in 0..<5 {
                HistoryLedgerProbe.reset()
                eviction.append(timed { _ = store.create(name: "Newcomer \(index)") })
                XCTAssertEqual(HistoryLedgerProbe.stepVisits, 0, "even a newcomer uses its already measured steps")
            }
            func formatted(_ values: [Double]) -> String { values.map { String(format: "%.3f", $0) }.joined(separator: ",") }
            print("BG27_R20_MS histories=20 steps=2000 objectsPerStep=500 rebuild=[\(formatted(full))] incremental=[\(formatted(incremental))] newcomerEviction=[\(formatted(eviction))]")
        }
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
