import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Off-screen renders of the panel at 320 × 460 pt, 2×, with data like the
/// owner's design's `SEED`, for comparing with the drawing. Writes PNGs
/// only when `TEST_RUNNER_ATTIC_PANEL_DESIGN_RENDER=1` (into the host's
/// temporary folder, printed);
/// otherwise it only checks that the panel lays out.
@MainActor
final class TasksPanelDesignRenderTests: XCTestCase {
    private func seed(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        func day(_ offset: Int) -> DueDay? {
            calendar.date(byAdding: .day, value: offset, to: now).map { DueDay(date: $0, calendar: calendar) }
        }
        var order: Int64 = 100 * 1_024
        @discardableResult
        func task(_ title: String, _ status: TaskStatus = .todo, _ priority: TaskPriority = .none, due: DueDay? = nil,
                  tags: [String] = [], parent: UUID? = nil, completed: Date? = nil, logged: Bool = false) -> TaskItem {
            order -= 1_024
            let item = TaskItem(title: title, status: status, priority: priority, createdAt: now.addingTimeInterval(-86_400 * 9),
                                completedAt: completed, manualOrder: order, parentID: parent)
            item.dueDay = due
            item.tags = tags
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if logged { item.doneLoggedAt = now }
            context.insert(item)
            return item
        }
        // The design's SEED, its dates relative to today as in the owner's
        // screenshot (all overdue).
        task("New Reminder", .todo, .high, due: day(-8))
        task("Renew the parking permit", .todo, .high, due: day(-5), tags: ["car"])
        task("Reply to the landlord about the boiler", .todo, .high, due: day(-4), tags: ["house", "admin"])
        let boiler = task("Book the boiler service", .todo, .high, due: day(-3), tags: ["house"])
        task("Get three quotes", parent: boiler.id)
        task("Confirm the date", parent: boiler.id)
        task("Pay the electricity bill", .todo, .high, due: day(-3), tags: ["bills"])
        task("New Reminder", due: day(-2))
        task("Call the dentist", due: day(-2))
        task("Send the invoice to Mira", .todo, .medium, due: day(-2), tags: ["work", "bills"])
        task("Stand-up notes", due: day(-2), tags: ["work"])
        task("Venue shortlist", due: day(1), tags: ["team"])
        task("1:1 with Priya — career goals", tags: ["work", "team"])
        task("Plan the team offsite", .backlog, due: day(3), tags: ["team"])
        task("Renew car insurance", .backlog, due: day(9), tags: ["car", "bills"])
        for (offset, title) in [(4, "Prepare the launch demo"), (5, "Send the beta invites"), (6, "Water the plants")] {
            task(title, .done, completed: calendar.date(byAdding: .day, value: -offset, to: now), logged: true)
        }
        try context.save()
    }

    /// The design gives every control `corner-shape: superellipse(1.4)`
    /// (fix round 2, "why are the controls round now?"): the 27 pt pin with
    /// its 15 pt radius clamps to half the side and is a rounded square. Its
    /// edge crosses the corner's diagonal 3.12 pt in (2^1.4 superellipse);
    /// a circle's crosses 3.95 pt in. Drawn opaque (the flat surface; an
    /// off-screen render cannot draw glass), 8×, on a clear background.
    func testTheHeadersControlsAreRoundedSquaresNotCircles() throws {
        let side = AtticControlSize.headerControl
        let view = PanelHeader(isPinned: false, page: .tasks, onTogglePin: {}, onSelectPage: { _ in })
            .frame(width: 300)
            .atticDesign(AtticDesignContext(controls: .craft))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 8
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int((x * scale).rounded(.down)), y: Int((y * scale).rounded(.down)))?.alphaComponent ?? 0
        }
        // The pin's edges: its left on its middle row, its top on its middle column.
        let step = 1 / scale
        let left = try XCTUnwrap(stride(from: 0, to: 40, by: step).first { alpha($0, side / 2) > 0.02 })
        let top = try XCTUnwrap(stride(from: 0, to: 40, by: step).first { alpha(left + side / 2, $0) > 0.02 })
        // Where the surface starts along the top-left corner's diagonal.
        let reference = alpha(left + side / 2, top + 1.5)
        XCTAssertGreaterThan(reference, 0.02, "the pin's surface is drawn")
        let corner = try XCTUnwrap(stride(from: 0, to: side / 2, by: step).first {
            alpha(left + $0, top + $0) >= reference * 0.5
        })
        let squircle = side / 2 * (1 - pow(0.5, 1 / AtticControlShape.designExponent))
        let circle = side / 2 * (1 - pow(0.5, 0.5))
        XCTAssertLessThan(corner, (squircle + circle) / 2,
                          "the pin is a rounded square (edge \(corner) pt in; superellipse \(squircle), circle \(circle))")
        XCTAssertEqual(corner, squircle, accuracy: 0.3, "the design's superellipse(1.4) corner")
    }

    func testTheDesignsCornerIsCSSSuperellipseOnePointFour() {
        // CSS superellipse(K) is |x|^(2^K) + |y|^(2^K) = 1: K = 1 the round corner.
        XCTAssertEqual(AtticControlShape.designExponent, 2.639, accuracy: 0.001)
        let rect = CGRect(x: 0, y: 0, width: 27, height: 27)
        let path = AtticControlShape.shape(cornerRadius: 15, exponent: AtticControlShape.designExponent).path(in: rect)
        // Clamped to half the side, as CSS does: inside at (3.5, 3.5), which
        // a 13.5 pt circle leaves out.
        XCTAssertTrue(path.contains(CGPoint(x: 3.5, y: 3.5)))
        XCTAssertFalse(Path(ellipseIn: rect).contains(CGPoint(x: 3.5, y: 3.5)))
        XCTAssertFalse(path.contains(CGPoint(x: 2.5, y: 2.5)))
    }

    func testRenderTheTopTabsAlone() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_PANEL_DESIGN_RENDER"] == "1" else { return }
        let view = TasksTopTabs(selection: .constant(.now)).padding(10).background(Color(white: 0.95)).atticDesign(.default)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelDesignRenders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("top-tabs-alone.png"))
    }

    func testRenderThePanelLikeTheDesign() throws {
        // The test host is sandboxed: the PNGs go to its temporary folder
        // (printed), and the caller copies them out.
        let out: String? = ProcessInfo.processInfo.environment["ATTIC_PANEL_DESIGN_RENDER"] == "1" ? {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PanelDesignRenders", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            print("PANEL_DESIGN_RENDERS \(dir.path)")
            return dir.path
        }() : nil
        for (name, appearance, surface) in [("panel-light-solid", AppearancePreference.light, PanelSurfaceStyle.solid),
                                            ("panel-dark-solid", .dark, .solid),
                                            ("panel-light-glass", .light, .glass)] {
            let suite = "PanelDesignRender.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            try seed(in: container)
            let store = TaskStore(container: container)
            let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
            let state = PanelUIState()
            let size = CGSize(width: 320, height: 460)
            state.updatePanelSize(size)
            state.loadPageContent()
            let chrome = PanelChromeInteractionState()
            let settings = AppSettings(defaults: defaults)
            settings.appearance = appearance
            settings.panelSurfaceStyle = surface
            let host = AtticPanelHostingView(
                rootView: AtticPanelView(store: store, noteStore: notes,
                                         canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                         noteDraft: NoteDraftController(noteStore: notes),
                                         chromeInteractionState: chrome, uiState: state, settings: settings,
                                         tasksPageState: TasksPageState()),
                panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
            let content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
            let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            panel.contentView = content
            panel.orderFront(nil)
            defer { host.cancelActiveInteraction(reason: .lostWindow); state.releasePageContent(); panel.close() }
            state.selectSection(.tasks)
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            content.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(content.bounds.width, 0)
            guard let out else { continue }
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width * 2),
                                                     pixelsHigh: Int(content.bounds.height * 2), bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = content.bounds.size
            content.cacheDisplay(in: content.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
        }
    }
}
