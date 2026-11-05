import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

/// The canvas menu, Search for canvases and Recently Deleted's Draw rows,
/// on the in-memory Draw store only.
@MainActor
final class DrawLibraryTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func tick() -> Date { date += 60; return date }
    }

    private var log: [String] = []
    private let clock = Clock()
    private let calendar = Calendar(identifier: .gregorian)

    override func setUp() async throws {
        try await super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
        log = []
    }

    override func tearDown() async throws {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        AtticDraw.enabledOverride = nil
        DrawLibraryHub.register(nil)
        try await super.tearDown()
    }

    func testAuditB7NewCanvasNamesAvoidBothDraftAndSavedNames() {
        let repository = DrawMemoryRepository()
        let store = DrawStore(repository: repository)
        let first = store.create()
        XCTAssertEqual(first.name, "Untitled")
        XCTAssertEqual(store.create().name, "Untitled 2", "drafts reserve their visible names")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Saved"))]), on: first.id).isSaved)
        let relaunched = DrawStore(repository: repository)
        XCTAssertEqual(relaunched.create().name, "Untitled 2", "persisted names also reserve their suffix")
        XCTAssertEqual(relaunched.create(name: "Chosen name").name, "Chosen name")
        XCTAssertEqual(relaunched.create(name: " ").name, "Untitled 3")
    }

    private func actions(export: Bool = false) -> DrawLibraryActions {
        var exporter: (@MainActor (UUID) -> Void)?
        if export { exporter = { [unowned self] (id: UUID) -> Void in self.record("export \(id)") } }
        return DrawLibraryActions(open: { [unowned self] in log.append("open \($0)") },
                           newCanvas: { [unowned self] in log.append("new \($0 ?? "-")") },
                           reveal: { [unowned self] in log.append("reveal \($0) \($1)") },
                           close: { [unowned self] in log.append("close") },
                           export: exporter)
    }

    private func record(_ line: String) { log.append(line) }

    private struct Seed {
        let store: DrawInMemoryStore
        let launch: UUID, kitchen: UUID, logo: UUID
        let rocketBox: UUID, fridgeBox: UUID
    }

    /// Three canvases, newest last: Launch plan (#work, "rocket timeline"),
    /// Kitchen layout (#home, "fridge"), Logo ideas (a shape).
    private func seed() -> Seed {
        let clock = clock
        let store = DrawInMemoryStore(now: { clock.tick() })
        func canvas(_ name: String, _ objects: [DrawObject], tags: [String]) -> UUID {
            let canvas = store.create(name: name)
            XCTAssertTrue(store.perform(.put(objects), on: canvas.id).isSaved)
            if !tags.isEmpty { XCTAssertTrue(store.perform(.tags(tags), on: canvas.id).isSaved) }
            return canvas.id
        }
        let rocket = DrawObject(content: .text("rocket timeline"))
        let fridge = DrawObject(frame: DrawFrame(x: 40), content: .text("fridge"))
        let launch = canvas("Launch plan", [rocket], tags: ["work"])
        let kitchen = canvas("Kitchen layout", [DrawObject(content: .shape(.rectangle)), fridge], tags: ["home"])
        let logo = canvas("Logo ideas", [DrawObject(content: .shape(.ellipse))], tags: [])
        return Seed(store: store, launch: launch, kitchen: kitchen, logo: logo, rocketBox: rocket.id, fridgeBox: fridge.id)
    }

    private func menu(_ seed: Seed, open: UUID? = nil, export: Bool = false) -> DrawLibraryMenuModel {
        let model = DrawLibraryMenuModel(store: seed.store, actions: actions(export: export),
                                         now: { [clock] in clock.date }, calendar: calendar)
        model.currentCanvasID = open
        return model
    }

    private func canvasTitles(_ model: DrawLibraryMenuModel) -> [String] {
        model.rows.compactMap { $0.canvas == nil ? nil : $0.title }
    }

    func testAuditA11MenuHighlightDoesNotRefetchUnchangedLibraryMetadata() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = DrawPersistentStore(container: container)
        let canvas = store.create(name: "Audit canvas")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Audit writing"))]), on: canvas.id).isSaved)
        let model = DrawLibraryMenuModel(store: store, actions: actions())
        model.currentCanvasID = canvas.id
        store.metrics.reset()
        let rows = model.rows
        for row in rows where row.isEnabled {
            model.hover(row, inside: true)
            XCTAssertEqual(model.rows.map(\.id), rows.map(\.id))
        }
        XCTAssertEqual(store.metrics.metadataRowsRead, 1, "hover and layout reuse the opening's library snapshot")
        XCTAssertTrue(store.perform(.rename("Revised canvas"), on: canvas.id).isSaved)
        XCTAssertTrue(model.rows.contains { $0.title == "Revised canvas" }, "a durable change invalidates the snapshot")
    }

    // MARK: The menu

    func testTheFilterMatchesNamesTagsAndText() {
        let seed = seed()
        let model = menu(seed)
        XCTAssertEqual(canvasTitles(model), ["Logo ideas", "Kitchen layout", "Launch plan"], "newest first")
        model.filter = "kitchen"
        XCTAssertEqual(canvasTitles(model), ["Kitchen layout"])
        model.filter = "#work"
        XCTAssertEqual(canvasTitles(model), ["Launch plan"])
        model.filter = "rocket"
        XCTAssertEqual(canvasTitles(model), ["Launch plan"])
        model.filter = "zebra"
        XCTAssertEqual(canvasTitles(model), [])
        XCTAssertEqual(model.rows.map(\.title), ["No canvases match “zebra”", "New canvas “zebra”"])
        XCTAssertFalse(model.rows[0].isEnabled)
    }

    func testReturnOpensTheFirstMatch() {
        let seed = seed()
        let model = menu(seed)
        model.filter = "a"
        model.openFirstMatch()
        XCTAssertEqual(log, ["close", "open \(seed.logo)"])
        XCTAssertEqual(model.filter, "", "the menu forgets its filter once it has chosen")
        log = []
        model.filter = "zebra"
        model.openFirstMatch()
        XCTAssertEqual(log, ["close", "new zebra"], "with no match, Return makes the typed canvas")
    }

    func testNewCanvasUsesTheTypedName() {
        let seed = seed()
        let model = menu(seed)
        XCTAssertEqual(model.rows.first { $0.id == "new-canvas" }?.title, "New canvas")
        model.filter = "  Garden plan "
        let row = try! XCTUnwrap(model.rows.first { $0.id == "new-canvas" })
        XCTAssertEqual(row.title, "New canvas “Garden plan”")
        model.choose(row)
        XCTAssertEqual(log, ["close", "new Garden plan"])
        log = []
        model.choose(try! XCTUnwrap(model.rows.first { $0.id == "new-canvas" }))
        XCTAssertEqual(log, ["close", "new -"], "with no filter, New canvas is unnamed")
    }

    func testArrowsMoveTheHighlightOverChoosableRows() {
        let seed = seed()
        let model = menu(seed, open: seed.kitchen)
        XCTAssertNil(model.litRowID(in: model.rows), "nothing is lit until a key or the pointer")
        model.moveHighlight(by: 1)
        XCTAssertEqual(model.highlightedID, "canvas-\(seed.logo.uuidString)")
        model.moveHighlight(by: 1)
        XCTAssertEqual(model.highlightedID, "canvas-\(seed.kitchen.uuidString)")
        model.moveHighlight(by: -9)
        XCTAssertEqual(model.highlightedID, "canvas-\(seed.logo.uuidString)", "stops at the top")
        model.moveHighlight(by: 99)
        XCTAssertEqual(model.highlightedID, "command-delete", "stops at the bottom")
        model.moveHighlight(by: -1)
        XCTAssertEqual(model.highlightedID, "command-duplicate", "greyed rows are skipped")
        model.moveHighlight(by: -1)
        XCTAssertEqual(model.highlightedID, "command-tags", "Linked from… is skipped")
        model.moveHighlight(by: -3)
        model.openFirstMatch()
        XCTAssertEqual(log, ["close", "open \(seed.launch)"], "Return chooses the highlighted row")

        model.filter = "l"
        XCTAssertNil(model.highlightedID, "typing resets the highlight")
        XCTAssertEqual(model.litRowID(in: model.rows), "canvas-\(seed.logo.uuidString)", "while filtering, Return's row is lit")
    }

    func testTheOpenCanvasIsCheckedAndUnbuiltCommandsAreGreyed() {
        let seed = seed()
        let model = menu(seed, open: seed.kitchen)
        let rows = model.rows
        XCTAssertEqual(rows.filter(\.isOpen).map(\.title), ["Kitchen layout"])
        let commands = rows.filter { if case .command = $0.kind { true } else { false } }
        XCTAssertEqual(commands.map(\.title), ["Rename", "Tags…", "Linked from…", "Duplicate", "Export…", "Copy as Image", "Delete"])
        XCTAssertEqual(commands.filter { !$0.isEnabled }.map(\.title), ["Linked from…", "Export…", "Copy as Image"])
        XCTAssertEqual(commands.filter(\.startsSection).map(\.title), ["Rename"])
        XCTAssertEqual(commands.filter(\.isDestructive).map(\.title), ["Delete"])
        XCTAssertTrue(menu(seed, open: seed.kitchen, export: true).rows.contains { $0.id == "command-export" && $0.isEnabled },
                      "Export… comes alive once job 3 supplies it")
        XCTAssertTrue(menu(seed).rows.allSatisfy { row in
            if case .command = row.kind { !row.isEnabled } else { true }
        }, "with no open canvas, its commands are greyed")
        model.filter = "k"
        XCTAssertFalse(model.rows.contains { if case .command = $0.kind { true } else { false } },
                       "filtering shows only canvases and New canvas")
    }

    func testAnOpenDraftKeepsItsCheck() {
        let seed = seed()
        let draft = seed.store.create(name: "Fresh")
        let model = menu(seed, open: draft.id)
        XCTAssertEqual(canvasTitles(model).first, "Fresh")
        XCTAssertEqual(model.rows.first?.isOpen, true)
    }

    func testRenameTagsDuplicateAndDeleteReachTheStore() throws {
        let seed = seed()
        let store = seed.store
        let model = menu(seed, open: seed.kitchen)

        model.perform(.rename)
        XCTAssertTrue(model.isRenaming)
        XCTAssertEqual(model.nameDraft, "Kitchen layout")
        XCTAssertEqual(log, ["close"])
        model.nameDraft = "  Kitchen v2 "
        model.commitRename()
        XCTAssertFalse(model.isRenaming)
        XCTAssertEqual(try store.open(seed.kitchen).canvas.name, "Kitchen v2")
        model.perform(.rename)
        model.nameDraft = "Thrown away"
        model.cancelRename()
        XCTAssertEqual(try store.open(seed.kitchen).canvas.name, "Kitchen v2")

        log = []
        model.perform(.tags)
        XCTAssertEqual(model.mode, .tags)
        XCTAssertEqual(model.tagCounts, ["home": 1, "work": 1])
        model.setTag("#Urgent", on: true)
        model.setTag("home", on: false)
        XCTAssertEqual(try store.open(seed.kitchen).canvas.tags, ["urgent"])
        model.closeTags()
        XCTAssertEqual(model.mode, .list)
        XCTAssertEqual(log, ["close"])

        log = []
        model.perform(.duplicate)
        let copy = try XCTUnwrap(try store.library().first { $0.name == "Kitchen v2 copy" })
        XCTAssertEqual(try store.open(copy.id).objects.count, 2)
        XCTAssertEqual(log, ["close", "open \(copy.id)"])

        log = []
        model.perform(.delete)
        XCTAssertEqual(try store.library(deleted: true).map(\.id), [seed.kitchen], "Delete sends it to Recently Deleted")
        XCTAssertFalse(try store.library().contains { $0.id == seed.kitchen })
        XCTAssertEqual(log, ["close", "open \(copy.id)"], "the board moves to the newest other canvas")
    }

    func testDeletingTheLastCanvasStartsANewOne() {
        let clock = clock
        let store = DrawInMemoryStore(now: { clock.tick() })
        let only = store.create(name: "Only")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("x"))]), on: only.id).isSaved)
        let model = DrawLibraryMenuModel(store: store, actions: actions())
        model.currentCanvasID = only.id
        model.perform(.delete)
        XCTAssertEqual(log, ["close", "new -"])
    }

    func testFailedDeletionKeepsCanvasOpenAndNeverOffersUndo() throws {
        final class SaveGate { var fail = false }
        let gate = SaveGate()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = DrawPersistentStore(container: container, save: { context in
            if gate.fail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let canvas = store.create(name: "Keep me")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Safe"))]), on: canvas.id).isSaved)
        let model = DrawLibraryMenuModel(store: store, actions: actions())
        let toasts = PanelToastCenter()
        model.toasts = toasts
        model.currentCanvasID = canvas.id
        gate.fail = true
        model.perform(.delete)
        XCTAssertTrue(log.isEmpty, "Unsettled deletion must not navigate or close the menu")
        XCTAssertEqual(model.currentCanvasID, canvas.id)
        XCTAssertFalse(toasts.current?.answersUndoKey ?? true)
        XCTAssertNotNil(store.pendingEdits[canvas.id])
        gate.fail = false
        XCTAssertTrue(store.retry(on: canvas.id).isSaved)
        XCTAssertEqual(try store.library(deleted: true).map(\.id), [canvas.id])
    }

    func testDuplicateCommandDisablesAsSoonAsSourceHasPendingEdits() throws {
        final class SaveGate { var fail = false }
        let gate = SaveGate()
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = DrawPersistentStore(container: container, save: { context in
            if gate.fail { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        let canvas = store.create(name: "Draft")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Saved"))]), on: canvas.id).isSaved)
        let model = DrawLibraryMenuModel(store: store, actions: actions())
        model.currentCanvasID = canvas.id
        func enabled() -> Bool { model.rows.first { $0.id == "command-duplicate" }?.isEnabled == true }
        XCTAssertTrue(enabled())
        gate.fail = true
        XCTAssertFalse(store.perform(.rename("Pending"), on: canvas.id).isSaved)
        XCTAssertFalse(enabled(), "A cached menu must reflect the pending write immediately")
        model.perform(.duplicate)
        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(try store.library().count, 1)
    }

    func testTheMenuIsTheMenusWideCardWithItsRows() {
        let seed = seed()
        let model = menu(seed, open: seed.kitchen)
        // 3 canvases + New canvas + 7 commands, one rule.
        let list = DrawLibraryMetrics.listHeight(model.rows)
        XCTAssertEqual(list, 11 * AtticDropdownMetrics.rowHeight + AtticDropdownMetrics.separatorHeight)
        func size(_ view: DrawLibraryMenu) -> CGSize {
            let host = NSHostingView(rootView: view.atticDesign(AtticDesignContext()))
            host.layout()
            return host.fittingSize
        }
        let roomy = size(DrawLibraryMenu(model: model, maxListHeight: 400))
        XCTAssertEqual(roomy.width, AtticMenuMetrics.wideWidth, accuracy: 0.5)
        XCTAssertEqual(roomy.height, list + AtticGlassMenuShape.inset * 2, accuracy: 0.5)
        let capped = size(DrawLibraryMenu(model: model))
        XCTAssertEqual(capped.height, DrawLibraryMetrics.maxListHeight + AtticGlassMenuShape.inset * 2, accuracy: 0.5,
                       "past its room the list scrolls")
    }

    // MARK: Search

    private final class SearchSpyStore: DrawStore {
        var searchCount = 0
        var failSearch = false
        var failOpen = false

        init() { super.init(repository: DrawMemoryRepository()) }

        override func search(_ query: String) throws -> [DrawSearchMatch] {
            searchCount += 1
            if failSearch { throw NSError(domain: "DrawSearchTests", code: 1) }
            return try super.search(query)
        }

        override func open(_ id: UUID) throws -> DrawSnapshot {
            if failOpen { throw NSError(domain: "DrawOpenTests", code: 2) }
            return try super.open(id)
        }
    }

    func testSearchCachesByQueryAndStoreRevisionWithoutHoverReads() throws {
        let store = SearchSpyStore()
        let canvas = store.create(name: "Workshop")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Workbench"))]), on: canvas.id).isSaved)
        let search = DrawSearchModel(store: store, actions: actions())

        search.query = "work"
        XCTAssertEqual(search.results.count, 1)
        XCTAssertEqual(store.searchCount, 1)
        for _ in 0..<4 {
            _ = search.results
            search.hover(try XCTUnwrap(search.results.first), inside: true)
            search.moveHighlight(by: 1)
        }
        XCTAssertEqual(store.searchCount, 1, "highlighting must not hit persistence")

        search.query = "bench"
        XCTAssertEqual(search.results.count, 1)
        XCTAssertEqual(store.searchCount, 2)
        XCTAssertTrue(store.perform(.rename("Bench"), on: canvas.id).isSaved)
        XCTAssertEqual(search.results.count, 1)
        XCTAssertEqual(store.searchCount, 3, "a durable revision refreshes search")
    }

    func testSearchAndRevealFailuresRemainVisibleAndRecoverable() throws {
        let store = SearchSpyStore()
        let canvas = store.create(name: "Workshop")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .text("Workbench"))]), on: canvas.id).isSaved)
        let search = DrawSearchModel(store: store, actions: actions())

        store.failSearch = true
        search.query = "work"
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertNotNil(search.searchError)
        XCTAssertEqual(store.searchCount, 1)
        _ = search.results
        XCTAssertEqual(store.searchCount, 1, "a failed query must also be cached")

        store.failSearch = false
        search.query = "bench"
        let result = try XCTUnwrap(search.results.first)
        XCTAssertNil(search.searchError)
        store.failOpen = true
        XCTAssertFalse(search.open(result))
        XCTAssertNotNil(search.openError)
        XCTAssertTrue(log.isEmpty, "a failed reveal must not silently open elsewhere")
        store.failOpen = false
        XCTAssertTrue(search.open(result))
        XCTAssertNil(search.openError)
        XCTAssertEqual(log, ["reveal \(canvas.id) \(result.textBoxIDs[0])"])
    }

    func testSearchFindsCanvasesAndATextMatchRevealsItsBox() throws {
        let seed = seed()
        let search = DrawSearchModel(store: seed.store, actions: actions())
        XCTAssertTrue(search.results.isEmpty, "nothing until a query")

        search.query = "fridge"
        let text = try XCTUnwrap(search.results.first)
        XCTAssertEqual(search.results.map(\.title), ["Kitchen layout"])
        XCTAssertEqual(text.detail, "“fridge”")
        search.open(text)
        XCTAssertEqual(log, ["reveal \(seed.kitchen) \(seed.fridgeBox)"])

        log = []
        search.query = "kitchen"
        let name = try XCTUnwrap(search.results.first)
        XCTAssertEqual(name.textBoxIDs, [])
        search.open(name)
        XCTAssertEqual(log, ["open \(seed.kitchen)"], "a name match just opens the canvas")

        search.query = "#home"
        XCTAssertEqual(search.results.map(\.detail), ["#home"])

        log = []
        search.query = "i"
        search.moveHighlight(by: 1)
        search.moveHighlight(by: 1)
        XCTAssertEqual(search.highlightedID, seed.kitchen)
        search.openHighlighted()
        XCTAssertEqual(log, ["open \(seed.kitchen)"])
    }

    // MARK: Recently Deleted

    func testRecentlyDeletedListsAndRestoresACanvasAndAnImage() throws {
        let seed = seed()
        let store = seed.store
        let image = DrawObject(content: .image(DrawImage(original: Data([1, 2, 3]), pixelWidth: 4, pixelHeight: 3)))
        XCTAssertTrue(store.perform(.put([image]), on: seed.launch).isSaved)
        XCTAssertTrue(store.perform(.remove([image.id]), on: seed.launch).isSaved)
        XCTAssertTrue(store.perform(.deleteCanvas, on: seed.logo).isSaved)

        let model = RecentlyDeletedModel(library: nil, now: { [clock] in clock.date }, calendar: calendar, draw: { store })
        model.reload()
        let canvas = try XCTUnwrap(model.entries.first { $0.kind == .canvas })
        XCTAssertEqual(canvas.title, "Logo ideas")
        XCTAssertEqual(canvas.detail, "Deleted today")
        let picture = try XCTUnwrap(model.entries.first { $0.kind == .attachment })
        XCTAssertEqual(picture.title, "Image")
        XCTAssertEqual(picture.detail, "From “Launch plan” · Deleted today")
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(canvas.canDeletePermanently, "Draw 3: the store removes Draw rows for good")
        XCTAssertTrue(picture.canDeletePermanently)
        XCTAssertEqual(model.sections.map(\.kind), [.canvas, .attachment])

        model.restore(canvas)
        XCTAssertNil(model.message)
        XCTAssertTrue(try store.library(deleted: true).isEmpty)
        XCTAssertTrue(try store.library().contains { $0.id == seed.logo })
        model.restore([picture, picture])
        XCTAssertTrue(try store.deletedImages(in: seed.launch).isEmpty)
        XCTAssertEqual(try store.open(seed.launch).objects.map(\.id).contains(image.id), true)
        XCTAssertTrue(model.entries.isEmpty)
    }

    // MARK: The setting

    func testNothingShowsWhileDrawIsOff() throws {
        let seed = seed()
        XCTAssertTrue(seed.store.perform(.deleteCanvas, on: seed.logo).isSaved)
        DrawLibraryHub.register(seed.store)
        let deleted = RecentlyDeletedModel(library: nil)
        let model = menu(seed, open: seed.kitchen)
        let search = DrawSearchModel(store: seed.store, actions: actions())
        search.query = "kitchen"

        AtticDraw.enabledOverride = false
        deleted.reload()
        XCTAssertTrue(deleted.entries.isEmpty)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertNil(DrawLibraryHub.activeStore)

        AtticDraw.enabledOverride = true
        deleted.reload()
        XCTAssertEqual(deleted.entries.map(\.title), ["Logo ideas"])
        XCTAssertFalse(model.rows.isEmpty)
        XCTAssertEqual(search.results.count, 1)
    }
}
