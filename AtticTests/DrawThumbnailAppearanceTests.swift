import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Thumbnails follow the appearance (batch 3 on-screen finding): a
/// thumbnail records the appearance it was rendered for, and one that is
/// about to show (the canvas menu, Search) or belongs to the open canvas is
/// re-rendered, quietly, when the appearance no longer matches.
@MainActor
final class DrawThumbnailAppearanceTests: XCTestCase {
    private var store: DrawPersistentStore!
    private var container: ModelContainer!
    private var model: DrawPageModel!
    private var renders: DrawRenderLog!

    private static let darkBoard = [28, 28, 30, 255]
    private static let lightBoard = [255, 255, 255, 255]

    override func setUp() async throws {
        try await super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
        DrawImageActions.darkOverride = true
        container = try ModelContainer(for: Schema(PersistenceController.appModelTypes),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        store = DrawPersistentStore(container: container)
        renders = DrawRenderLog()
        model = DrawPageModel(store: store)
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw-thumb-\(UUID().uuidString)"))
        model.setBoard(size: CGSize(width: 320, height: 460),
                       clearInsets: NSEdgeInsets(top: 48.5, left: 15.5, bottom: 48.5, right: 15.5))
        model.thumbnailSettleDelay = 600
        let log = renders!
        model.thumbnailRenderer = { objects, dark in
            await log.render(objects, dark: dark)
        }
        model.start()
    }

    override func tearDown() async throws {
        model?.pasteboard.releaseGlobally()
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        AtticDraw.enabledOverride = nil
        DrawImageActions.darkOverride = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    /// A canvas named `name` with one rectangle, its thumbnail rendered in
    /// the current appearance; the page moves on to a new canvas.
    @discardableResult
    private func drawnCanvas(_ name: String) throws -> (id: UUID, object: UUID) {
        let object = DrawObject(frame: DrawFrame(x: 20, y: 30, width: 100, height: 50), content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([object])).isSaved)
        let id = try XCTUnwrap(model.canvasID)
        XCTAssertTrue(store.perform(.rename(name), on: id).isSaved)
        model.flushThumbnail()
        XCTAssertTrue(wait { self.thumbnail(id) != nil }, "\(name)'s thumbnail renders")
        model.newCanvas()
        return (id, object.id)
    }

    private func canvas(_ id: UUID) -> DrawCanvas? { try? store.library().first { $0.id == id } }
    private func thumbnail(_ id: UUID) -> Data? { canvas(id)?.thumbnail }

    /// The stored thumbnail's corner: the board colour it was rendered on.
    private func board(_ id: UUID) -> [Int]? {
        guard let data = thumbnail(id), let image = Draw3Images.cgImage(data) else { return nil }
        return Draw3Images.pixel(image, x: 0, y: 0)
    }

    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Cases

    func testADarkThumbnailShownInTheMenuAfterSwitchingToLightRerendersOnceQuietly() throws {
        let alpha = try drawnCanvas("Alpha")
        XCTAssertEqual(board(alpha.id), Self.darkBoard)
        let order = try store.library().map(\.id)
        let date = try XCTUnwrap(canvas(alpha.id)?.updatedAt)
        let couldUndo = store.canUndo(on: alpha.id)
        let before = renders.count(of: alpha.object)

        DrawImageActions.darkOverride = false
        model.library.showThumbnails()
        XCTAssertTrue(wait { self.board(alpha.id) == Self.lightBoard }, "The stored thumbnail ends on the light board")
        spin()
        XCTAssertEqual(renders.count(of: alpha.object) - before, 1, "One re-render")
        XCTAssertEqual(renders.last(of: alpha.object)?.dark, false)
        XCTAssertEqual(canvas(alpha.id)?.thumbnailDark, false, "The thumbnail records its appearance")
        XCTAssertEqual(canvas(alpha.id)?.updatedAt, date, "No date change")
        XCTAssertEqual(try store.library().map(\.id), order, "No change in menu order")
        XCTAssertEqual(store.canUndo(on: alpha.id), couldUndo, "No Undo step")
        let light = thumbnail(alpha.id)
        if couldUndo {
            XCTAssertTrue(store.undo(on: alpha.id).isSaved)
            XCTAssertEqual(thumbnail(alpha.id), light, "Undo never brings back the dark thumbnail")
            XCTAssertEqual(canvas(alpha.id)?.thumbnailDark, false)
        }
    }

    func testACanvasThatIsNeverShownIsNotRerendered() throws {
        let alpha = try drawnCanvas("Alpha")
        let beta = try drawnCanvas("Beta")
        let betaRenders = renders.count(of: beta.object)
        let betaBytes = thumbnail(beta.id)

        DrawImageActions.darkOverride = false
        model.library.filter = "Alpha"
        model.library.showThumbnails()
        XCTAssertTrue(wait { self.board(alpha.id) == Self.lightBoard })
        spin()
        XCTAssertEqual(renders.count(of: beta.object), betaRenders, "Beta never showed, so it isn't re-rendered")
        XCTAssertEqual(thumbnail(beta.id), betaBytes)
        XCTAssertEqual(board(beta.id), Self.darkBoard)
    }

    func testRepeatedShowsCoalesceToOneRender() throws {
        let alpha = try drawnCanvas("Alpha")
        let before = renders.count(of: alpha.object)
        let gate = Draw3Gate()
        renders.gate = gate

        DrawImageActions.darkOverride = false
        for _ in 0..<4 {
            model.library.showThumbnails()
            spin(0.05)
        }
        model.search.query = "Alpha"
        model.search.showThumbnails()
        spin(0.1)
        gate.open()
        XCTAssertTrue(wait { self.board(alpha.id) == Self.lightBoard })
        spin()
        XCTAssertEqual(renders.count(of: alpha.object) - before, 1, "Repeated shows coalesce to one render")

        model.library.showThumbnails()
        spin()
        XCTAssertEqual(renders.count(of: alpha.object) - before, 1, "A matching thumbnail isn't rendered again")
    }

    func testTheOldImageStaysUntilTheNewOneLands() throws {
        let alpha = try drawnCanvas("Alpha")
        let dark = try XCTUnwrap(thumbnail(alpha.id))
        let before = renders.count(of: alpha.object)
        let gate = Draw3Gate()
        renders.gate = gate

        DrawImageActions.darkOverride = false
        model.library.showThumbnails()
        XCTAssertTrue(wait { self.renders.started(of: alpha.object) > before }, "The re-render starts")
        spin()
        XCTAssertEqual(thumbnail(alpha.id), dark, "The old thumbnail shows (never the empty card) while it renders")
        gate.open()
        XCTAssertTrue(wait { self.board(alpha.id) == Self.lightBoard }, "Then the card updates in place")
    }

    func testSearchResultsUseTheSamePath() throws {
        let alpha = try drawnCanvas("Alpha")
        let beta = try drawnCanvas("Beta")
        let betaRenders = renders.count(of: beta.object)

        DrawImageActions.darkOverride = false
        model.search.query = "Alpha"
        model.search.showThumbnails()
        XCTAssertTrue(wait { self.board(alpha.id) == Self.lightBoard }, "A Search result re-renders like a menu row")
        spin()
        XCTAssertEqual(renders.count(of: beta.object), betaRenders)
    }

    func testShowingTheSearchResultsViewQueuesTheRerender() throws {
        let alpha = try drawnCanvas("Alpha")
        DrawImageActions.darkOverride = false
        model.search.query = "Alpha"
        let host = NSHostingView(rootView: DrawSearchResults(model: model.search)
            .frame(width: 320, height: 200)
            .atticDesign(AtticDesignContext()))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layout()
        XCTAssertTrue(wait { self.board(alpha.id) == Self.lightBoard }, "The shown result's thumbnail re-renders")
        window.contentView = nil
    }

    func testTheOpenCanvasRerendersAfterAnAppearanceChangeThroughTheSettlePath() throws {
        let object = DrawObject(frame: DrawFrame(x: 20, y: 30, width: 100, height: 50), content: .shape(.rectangle))
        XCTAssertTrue(model.perform(.put([object])).isSaved)
        let id = try XCTUnwrap(model.canvasID)
        model.flushThumbnail()
        XCTAssertTrue(wait { self.board(id) == Self.darkBoard })
        let date = try XCTUnwrap(canvas(id)?.updatedAt)
        let couldUndo = store.canUndo(on: id)
        let before = renders.count(of: object.id)

        model.thumbnailSettleDelay = 0.05
        DrawImageActions.darkOverride = false
        model.appearanceChanged()
        model.appearanceChanged()
        XCTAssertTrue(wait { self.board(id) == Self.lightBoard }, "The open canvas re-renders once settled")
        spin()
        XCTAssertEqual(renders.count(of: object.id) - before, 1)
        XCTAssertEqual(canvas(id)?.updatedAt, date)
        XCTAssertEqual(store.canUndo(on: id), couldUndo)
        XCTAssertEqual(model.objects.map(\.id), [object.id])
    }

    func testAnEmptyCanvasKeepsTheEmptyCard() throws {
        let alpha = try drawnCanvas("Alpha")
        let empty = try XCTUnwrap(model.canvasID)
        DrawImageActions.darkOverride = false
        model.library.showThumbnails()
        XCTAssertTrue(wait { self.board(alpha.id) == Self.lightBoard })
        XCTAssertNil(thumbnail(empty), "Nothing drawn: still the empty card")
        XCTAssertEqual(renders.total, renders.total(dark: true) + 1, "Only Alpha re-rendered")
    }

    // MARK: Store

    func testTheThumbnailsAppearanceIsStoredAndASameBytesWriteOfTheOtherIsSaved() throws {
        let canvas = store.create(name: "Stored")
        XCTAssertTrue(store.perform(.put([DrawObject(content: .shape(.ellipse))]), on: canvas.id).isSaved)
        let date = try XCTUnwrap(self.canvas(canvas.id)?.updatedAt)
        XCTAssertTrue(store.perform(.thumbnail(Data([1, 2, 3]), dark: true), on: canvas.id).isSaved)
        XCTAssertEqual(try DrawPersistentStore(container: container).library().first { $0.id == canvas.id }?.thumbnailDark, true,
                       "A fresh read keeps the appearance")
        XCTAssertTrue(store.perform(.thumbnail(Data([1, 2, 3]), dark: false), on: canvas.id).isSaved,
                      "The same bytes for the other appearance still record it")
        XCTAssertEqual(try DrawPersistentStore(container: container).library().first { $0.id == canvas.id }?.thumbnailDark, false)
        XCTAssertTrue(store.perform(.thumbnail(nil, dark: false), on: canvas.id).isSaved)
        XCTAssertNil(try DrawPersistentStore(container: container).library().first { $0.id == canvas.id }?.thumbnailDark,
                     "No thumbnail, no appearance")
        XCTAssertEqual(self.canvas(canvas.id)?.updatedAt, date)
    }

    func testR21UnfinishedThumbnailRegeneratesAfterRelaunch() throws {
        let suite = "attic.draw.thumbnail.r21.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalStore = DrawPersistentStore(container: container)
        let canvas = originalStore.create(name: "Awaiting thumbnail")
        let id = canvas.id
        let object = DrawObject(frame: DrawFrame(x: 20, y: 30, width: 100, height: 50), content: .shape(.rectangle))
        XCTAssertTrue(originalStore.perform(.put([object]), on: id).isSaved)
        XCTAssertTrue(originalStore.perform(.thumbnail(Data([10]), dark: true), on: id).isSaved)
        defaults.set(id.uuidString, forKey: "AtticDraw.lastCanvas")
        var original: DrawPageModel? = DrawPageModel(store: originalStore, resumeDefaults: defaults)
        original?.thumbnailSettleDelay = 600
        original?.start()
        XCTAssertEqual(original?.canvasID, id)
        var changed = object
        changed.frame.x = 120
        XCTAssertTrue(try XCTUnwrap(original).perform(.put([changed])).isSaved)
        XCTAssertTrue(defaults.stringArray(forKey: "AtticDraw.unrenderedThumbnails")?.contains(id.uuidString) == true,
                      "The edit persisted its dirty marker before any asynchronous render")
        XCTAssertEqual(try originalStore.open(id).canvas.thumbnail, Data([10]), "Quit left the old thumbnail")
        original = nil // A new model must recover using persisted state alone.

        let relaunchedStore = DrawPersistentStore(container: container)
        let relaunched = DrawPageModel(store: relaunchedStore, resumeDefaults: defaults)
        relaunched.thumbnailRenderer = { _, _ in Data([30]) }
        relaunched.start()
        XCTAssertTrue(wait { (try? relaunchedStore.open(id).canvas.thumbnail) == Data([30]) },
                      "Opening a stale canvas regenerates its thumbnail after relaunch")
        XCTAssertTrue(defaults.stringArray(forKey: "AtticDraw.unrenderedThumbnails")?.isEmpty == true)
    }
}

/// Counts thumbnail renders by the first object drawn (one per canvas in
/// these tests), optionally held back by a gate.
final class DrawRenderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished: [(object: UUID?, dark: Bool)] = []
    private var begun: [UUID?] = []
    private var heldBy: Draw3Gate?

    var gate: Draw3Gate? {
        get { lock.lock(); defer { lock.unlock() }; return heldBy }
        set { lock.lock(); heldBy = newValue; lock.unlock() }
    }

    func render(_ objects: [DrawObject], dark: Bool) async -> Data? {
        let gate = begin(objects.first?.id)
        await gate?.wait()
        let data = await Task.detached(priority: .utility) { DrawThumbnail.render(objects, dark: dark) }.value
        finish(objects.first?.id, dark: dark)
        return data
    }

    private func begin(_ object: UUID?) -> Draw3Gate? {
        lock.withLock { begun.append(object); return heldBy }
    }

    private func finish(_ object: UUID?, dark: Bool) {
        lock.withLock { finished.append((object, dark)) }
    }

    func started(of object: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return begun.filter { $0 == object }.count }
    func count(of object: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return finished.filter { $0.object == object }.count }
    func last(of object: UUID) -> (object: UUID?, dark: Bool)? {
        lock.lock(); defer { lock.unlock() }; return finished.last { $0.object == object }
    }
    var total: Int { lock.lock(); defer { lock.unlock() }; return finished.count }
    func total(dark: Bool) -> Int { lock.lock(); defer { lock.unlock() }; return finished.filter { $0.dark == dark }.count }
}
