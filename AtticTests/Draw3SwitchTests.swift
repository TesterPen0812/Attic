import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Draw job 3, the switch-over: Draw is the Canvas page by default, the
/// hidden `AtticDraw.enabled` off-switch brings the old page back, and while
/// Draw is on the old `Canvas*` rows are never read and never changed.
@MainActor
final class Draw3SwitchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        AtticDraw.enabledOverride = nil
        super.tearDown()
    }

    func testDrawIsOnByDefaultAndTheHiddenSwitchBringsBackTheOldPage() throws {
        let suite = "Draw3Switch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertTrue(AtticDraw.value(in: defaults), "Unset is on: Draw is the Canvas page")
        defaults.set(false, forKey: AtticDraw.enabledKey)
        XCTAssertFalse(AtticDraw.value(in: defaults), "defaults write … AtticDraw.enabled -bool false")
        defaults.set(true, forKey: AtticDraw.enabledKey)
        XCTAssertTrue(AtticDraw.value(in: defaults))

        AtticDraw.enabledOverride = true
        XCTAssertEqual(PanelPage.canvas.title, "Draw")
        XCTAssertEqual(PanelPage.switchItems.last?.title, "Draw")
        XCTAssertFalse(CanvasEditCommandAvailability.offersShadowingItems(section: .canvas),
                       "The old Canvas's Undo items stay out of the menu while Draw is on")
        AtticDraw.enabledOverride = false
        XCTAssertEqual(PanelPage.canvas.title, "Canvas")
        XCTAssertEqual(PanelPage.switchItems.last?.title, "Canvas")
        XCTAssertTrue(CanvasEditCommandAvailability.offersShadowingItems(section: .canvas))
    }

    // MARK: Old canvases stay untouched and unread

    private func runtime(_ root: URL) throws -> AppRuntimeEnvironment {
        let attachments = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let token = UUID().uuidString, suite = "Draw3Runtime." + UUID().uuidString
        try Data(token.utf8).write(to: attachments.appendingPathComponent(AppRuntimeEnvironment.testAttachmentRootOwnerMarkerName))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return AppRuntimeEnvironment(environment: ["ATTIC_TESTING": "1", "ATTIC_TEST_DEFAULTS_SUITE": suite,
            "ATTIC_TEST_ATTACHMENT_ROOT": attachments.path, "ATTIC_TEST_ATTACHMENT_ROOT_OWNER_TOKEN": token],
            arguments: [], applicationSupportURL: root)
    }

    /// Old boards (one tagged, one deleted 60 days ago) with a stroke, an
    /// image and a semantic object.
    private func seedOldCanvases(in container: ModelContainer) throws -> (live: UUID, deleted: UUID) {
        let context = ModelContext(container)
        let board = CanvasBoardItem(id: UUID(), name: "Old #untouched", sortIndex: 1)
        board.tagsRaw = "old-tag"
        let gone = CanvasBoardItem(id: UUID(), name: "Old deleted", sortIndex: 2)
        gone.tombstoned = true
        gone.deletedAt = Date().addingTimeInterval(-60 * 86_400)
        gone.recentlyDeletedAt = gone.deletedAt
        context.insert(board)
        context.insert(gone)
        context.insert(CanvasStrokeItem(canvasID: board.id, payload: Data([255, 0, 99])))
        context.insert(CanvasImageItem(canvasID: board.id, encodedData: Data([1, 0, 2]), pixelWidth: 3, pixelHeight: 1))
        let semantic = CanvasSemanticObjectItem(canvasID: board.id)
        semantic.payload = Data([5, 6])
        context.insert(semantic)
        try context.save()
        return (board.id, gone.id)
    }

    /// Every persisted attribute of every old row.
    private func oldRows(_ container: ModelContainer) throws -> Data {
        let context = ModelContext(container)
        func time(_ date: Date?) -> String { date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil" }
        let boards = try context.fetch(FetchDescriptor<CanvasBoardItem>()).map { row in
            [row.id.uuidString, row.name, String(row.sortIndex), String(row.formatVersion), String(row.clearGeneration),
             String(row.mutationVersion), String(row.tombstoned), time(row.createdAt), time(row.updatedAt), time(row.deletedAt),
             row.tagsRaw, time(row.purgedAt), time(row.recentlyDeletedAt), String(describing: row.deletedContentCount)]
        }
        let strokes = try context.fetch(FetchDescriptor<CanvasStrokeItem>()).map { row in
            [row.id.uuidString, row.canvasID.uuidString, String(row.payloadVersion), row.payload.base64EncodedString(),
             String(row.boardGeneration), String(row.mutationVersion), String(row.tombstoned), time(row.updatedAt), time(row.deletedAt)]
        }
        let images = try context.fetch(FetchDescriptor<CanvasImageItem>()).map { row in
            [row.id.uuidString, row.canvasID.uuidString, row.encodedData.base64EncodedString(), String(row.encodedByteCount),
             row.contentDigest, row.contentType, String(row.pixelWidth), String(row.pixelHeight), String(row.mutationVersion),
             String(row.tombstoned), time(row.updatedAt), time(row.deletedAt)]
        }
        let semantics = try context.fetch(FetchDescriptor<CanvasSemanticObjectItem>()).map { row in
            [row.id.uuidString, row.canvasID.uuidString, row.kind, row.payload.base64EncodedString(), String(row.mutationVersion),
             String(row.tombstoned), time(row.updatedAt), time(row.deletedAt)]
        }
        return try JSONSerialization.data(withJSONObject: [boards, strokes, images, semantics], options: [.sortedKeys])
    }

    func testWithDrawOnOldCanvasRowsAreNeverFetchedAndStayUnchanged() async throws {
        AtticDraw.enabledOverride = true
        let root = ownedTemporaryDirectory(prefix: "Draw3Legacy")
        let disk = root.appendingPathComponent("Store", isDirectory: true)
        let seeded = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: disk)
        let ids = try seedOldCanvases(in: seeded)
        let before = try oldRows(seeded)
        CanvasReplicaFetchCounter.reset()

        let coordinator = try AppCoordinator(runtime: runtime(root), openStore: {
            try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: disk)
        })
        let library = coordinator.library
        // Launch, shared Search, Recently Deleted, the tag inventory, the
        // daily cleanup, the reveal refresh, links and the quit route.
        XCTAssertTrue(coordinator.canvasStore.canvases.isEmpty)
        XCTAssertFalse(library.recentlyDeleted().contains { $0.ref.kind == .canvas })
        let recentlyDeleted = RecentlyDeletedModel(library: library, draw: { nil })
        recentlyDeleted.reload()
        XCTAssertFalse(recentlyDeleted.entries.contains { $0.kind == .canvas })
        XCTAssertFalse(TagService(container: coordinator.store.container).counts().contains { $0.name == "old-tag" })
        _ = library.purgeExpired(now: Date(), calendar: .current)
        coordinator.canvasStore.refresh()
        XCTAssertNil(library.title(of: AtticItemRef(.canvas, ids.live)))
        XCTAssertFalse(library.setTags(["new"], on: AtticItemRef(.canvas, ids.live)))
        XCTAssertFalse(library.restore(AtticItemRef(.canvas, ids.deleted)))
        let ready = await coordinator.prepareForTerminationDurably()
        XCTAssertTrue(ready)
        coordinator.stop()

        XCTAssertEqual(CanvasReplicaFetchCounter.fetches, 0, "No old Canvas row is fetched while Draw is on")
        XCTAssertEqual(CanvasReplicaFetchCounter.blocked, 0, "Nothing even tries")
        XCTAssertEqual(try oldRows(seeded), before, "The old rows are unchanged")
    }

    func testWithDrawOffTheOldCanvasLoadsAsBefore() throws {
        AtticDraw.enabledOverride = false
        let root = ownedTemporaryDirectory(prefix: "Draw3LegacyOff")
        let disk = root.appendingPathComponent("Store", isDirectory: true)
        let seeded = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: disk)
        let ids = try seedOldCanvases(in: seeded)
        let coordinator = try AppCoordinator(runtime: runtime(root), openStore: {
            try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: disk)
        })
        XCTAssertTrue(coordinator.canvasStore.canvases.contains { $0.id == ids.live })
        XCTAssertFalse(AtticLegacyCanvas.isDormant(coordinator.store.container))
    }

    // MARK: Quit

    func testTheAppsQuitRouteWaitsForDrawAndAHeldEditStopsIt() async throws {
        AtticDraw.enabledOverride = true
        let root = ownedTemporaryDirectory(prefix: "Draw3Quit")
        let coordinator = try AppCoordinator(runtime: runtime(root), openStore: {
            try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        })
        let repository = Draw3HeldRepository()
        let model = DrawPageModel(store: DrawStore(repository: repository))
        let previous = DrawPageModel.shared
        DrawPageModel.replaceShared(model)
        defer { DrawPageModel.replaceShared(previous) }
        model.setBoard(size: CGSize(width: 320, height: 460), clearInsets: NSEdgeInsets(top: 48.5, left: 15.5, bottom: 48.5, right: 15.5))
        model.start()
        model.setTool(.pen)
        model.pointerDown(at: CGPoint(x: 60, y: 100))
        model.pointerDragged(to: CGPoint(x: 120, y: 150))
        let blocked = await coordinator.prepareForTerminationDurably()
        XCTAssertFalse(blocked, "A held edit stops quit")
        XCTAssertNil(model.live, "The stroke in progress was finished first")
        repository.reconcileOutcome = .committed
        let ready = await coordinator.prepareForTerminationDurably()
        XCTAssertTrue(ready)
        coordinator.stop()
    }
}
