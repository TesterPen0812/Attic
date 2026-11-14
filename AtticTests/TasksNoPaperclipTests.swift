import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Accepted 2026-11-01 "Task rows: no paperclip count": a row with files
/// draws no paperclip count (its tiles already show the files), and the
/// files list it opened is gone. The six-tile cap goes too: tiles that
/// overflow scroll sideways in a strip that starts at the row's text
/// column. Reduce Motion and Reduce Transparency are stated (CI turns both
/// on).
@MainActor
final class TasksNoPaperclipTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() async throws {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        try await super.tearDown()
    }

    private func files(_ count: Int) -> [TaskImageReference] {
        (0..<count).map { index in
            TaskImageReference(id: UUID(), filename: "File \(index).pdf", digest: UUID().uuidString,
                               contentTypeIdentifier: "com.adobe.pdf", byteCount: 2_048)
        }
    }

    /// The Tasks page with the demo tasks, off screen in the invisible host,
    /// with its drag session (the rows' control frames) in reach.
    @MainActor
    private final class Host {
        let store: TaskStore
        let model: TasksPageModel
        let pointer = TasksPointer()
        let session = TasksDragSession()
        let window: NSPanel

        init() throws {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            try TasksPagePreview.seedDemo(in: container, long: false)
            store = TaskStore(container: container)
            model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
            let size = CGSize(width: AtticLayout.panelSize.width, height: 560)
            let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                                 addBarFocused: .constant(false), pointer: pointer, dragSession: session)
            window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: page.atticDesign(AtticDesignContext(mode: .light))
                .frame(width: size.width, height: size.height))
            window.orderFront(nil)
            spin(1)
        }

        func close() { window.orderOut(nil); window.contentView = nil; window.close() }

        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

        /// Stores `references` on the task (references only: no file is read).
        func attach(_ references: [TaskImageReference], to id: UUID) throws {
            let context = ModelContext(store.container)
            let stored = try XCTUnwrap(try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first)
            stored.imageReferencesData = try TaskStore.encodedAttachments(references)
            try context.save()
            store.refresh()
            spin(0.5)
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    /// The row's tile strip: a sideways scroll view one tile high whose
    /// content is `count` file tiles side by side (so all of them are built).
    private func strip(of count: Int, in root: NSView) -> NSScrollView? {
        root.layoutSubtreeIfNeeded()
        let width = CGFloat(count) * TasksDesignMetrics.fileTileWidth + CGFloat(count - 1) * TasksDesignMetrics.tileGap
        return scrollViews(in: root).first {
            abs($0.frame.height - TasksRowDesign.tile) <= 0.5 && abs(($0.documentView?.frame.width ?? 0) - width) <= 0.5
        }
    }

    // MARK: No paperclip count

    func testARowWithFilesDrawsNoPaperclipCount() throws {
        let hosted = try Host()
        defer { hosted.close() }
        // A row with tags keeps its details line, with or without files.
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { !$0.model.tags.isEmpty && $0.model.attachments == 0 })
        let key = TasksRowID(tab: .now, id: row.id)
        let before = try XCTUnwrap(hosted.session.controlFrames[key], "the row reports its controls").count

        try hosted.attach(files(3), to: row.id)
        let withFiles = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == row.id })
        XCTAssertEqual(withFiles.model.attachments, 3)
        XCTAssertEqual(withFiles.model.tileFiles.count, 3, "its files show as tiles")
        // Every tile is itself a draggable target, so it reports a control
        // frame. A separate paperclip/count button would add one more.
        let controls = try XCTUnwrap(hosted.session.controlFrames[key])
        XCTAssertEqual(controls.count, before + withFiles.model.tileFiles.count,
                       "each draggable file tile adds one target, with no paperclip count")
        XCTAssertEqual(controls.filter {
            abs($0.width - TasksDesignMetrics.fileTileWidth) <= 0.5 &&
                abs($0.height - TasksDesignMetrics.tile) <= 0.5
        }.count, withFiles.model.tileFiles.count,
        "the added targets are file tiles, not a paperclip control")

        // A row whose only details were its files has no details line left.
        let plain = try XCTUnwrap(hosted.store.create(title: "Scan the receipts"))
        try hosted.attach(files(2), to: plain.id)
        let plainRow = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == plain.id })
        XCTAssertFalse(plainRow.model.hasDetails, "files alone draw no empty details line")
        let height = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: plain.id)]).height
        XCTAssertEqual(height, TasksRowDesign.height(twoLine: false, tiles: true), accuracy: 1,
                       "the title line, then the tiles")
    }

    // MARK: Tiles scroll, no cap

    func testSevenFilesAreAllTiles() throws {
        let hosted = try Host()
        defer { hosted.close() }
        let task = try XCTUnwrap(hosted.store.create(title: "Collect the tax papers"))
        try hosted.attach(files(7), to: task.id)
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == task.id })
        XCTAssertEqual(row.model.tileFiles.count, 7, "no six-tile cap")
        XCTAssertNotNil(strip(of: 7, in: try XCTUnwrap(hosted.window.contentView)),
                        "all seven tiles are built, in a sideways strip")
    }

    func testOverflowingTilesScrollSidewaysFromTheTextColumn() throws {
        let hosted = try Host()
        defer { hosted.close() }
        let task = try XCTUnwrap(hosted.store.create(title: "Sort the holiday photos"))
        let count = 14
        try hosted.attach(files(count), to: task.id)
        let row = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == task.id })
        XCTAssertEqual(row.model.tileFiles.count, count, "every file is a tile")

        let root = try XCTUnwrap(hosted.window.contentView)
        let tiles = try XCTUnwrap(strip(of: count, in: root), "all \(count) tiles are built, in a sideways strip")
        let content = try XCTUnwrap(tiles.documentView).frame.width
        let visible = tiles.contentView.bounds.width
        XCTAssertGreaterThan(content, visible, "more than fit: the strip scrolls")
        XCTAssertFalse(tiles.hasVerticalScroller && !(tiles.verticalScroller?.isHidden ?? true), "no vertical scroller")
        XCTAssertTrue(!tiles.hasHorizontalScroller || tiles.horizontalScroller?.isHidden ?? true
                          || tiles.scrollerStyle == .overlay, "no visible scroller bar")

        // The strip's visible part starts at the row's text column.
        let rowFrame = try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: task.id)])
        let inRoot = root.convert(tiles.bounds, from: tiles)
        let flippedY = root.isFlipped ? inRoot.minY : root.bounds.height - inRoot.maxY
        XCTAssertEqual(inRoot.minX, rowFrame.minX + TasksDesignMetrics.textX, accuracy: 0.5, "clipped at the text column")
        XCTAssertGreaterThanOrEqual(flippedY, rowFrame.minY - 0.5, "inside its row")
        XCTAssertLessThanOrEqual(flippedY + inRoot.height, rowFrame.maxY + 0.5)
    }

    func testBG4PagerLeavesAnOverflowingFileStripToNativeHorizontalScrolling() throws {
        let hosted = try Host()
        defer { hosted.close() }
        let task = try XCTUnwrap(hosted.store.create(title: "Attachments to browse"))
        try hosted.attach(files(14), to: task.id)
        let root = try XCTUnwrap(hosted.window.contentView)
        let tiles = try XCTUnwrap(strip(of: 14, in: root))
        let page = try XCTUnwrap(hosted.pointer.view)
        let inside = tiles.convert(CGPoint(x: tiles.bounds.midX, y: tiles.bounds.midY), to: nil)
        func event(_ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        let band = TasksPagerBand(top: 0, bottomInset: 0)
        XCTAssertGreaterThan(tiles.documentView!.bounds.width, tiles.contentView.bounds.width)
        XCTAssertTrue(band.contains(page.convert(inside, from: nil), height: page.bounds.height, stackHeight: 0))
        XCTAssertFalse(TasksPage.pagerTakes(try event(inside), pointer: hosted.pointer,
                         band: band, stackHeight: 0, pageShown: true),
            "BG-4: the pager must not steal a horizontal gesture begun over file tiles")
        let outside = CGPoint(x: max(3, inside.x - tiles.bounds.width / 2 - 20), y: inside.y)
        XCTAssertTrue(TasksPage.pagerTakes(try event(outside), pointer: hosted.pointer,
                        band: band, stackHeight: 0, pageShown: true),
            "normal row space still pages horizontally")
    }
}
