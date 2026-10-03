import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Attic

/// The header's corner buttons are the system's interactive Liquid Glass
/// (owner, 2026-10-02: "I want liquid glass, make it happen without losing
/// any performance"), replacing L3's flat surface: glass by default in one
/// shared container, L3's opaque surface wherever the controls are not glass,
/// a Flat switch only in preview identities, and a header that scrolling and
/// swiping never re-evaluate.
@MainActor
final class CornerGlassTests: XCTestCase {
    private final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
    private func host<Content: View>(_ content: Content, size: CGSize = CGSize(width: 340, height: 80)) -> (NSPanel, NSView) {
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        panel.contentView = view
        panel.orderFront(nil)
        panel.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        return (panel, view)
    }

    /// The glass the window server samples behind a view: AppKit's backdrop
    /// layers, with how many glass shapes each one draws.
    private func backdrops(in view: NSView) -> [(frame: CGRect, shapes: Int)] {
        func walk(_ layer: CALayer) -> [(CGRect, Int)] {
            var found: [(CGRect, Int)] = []
            if "\(type(of: layer))".contains("Backdrop") {
                func shapes(_ layer: CALayer) -> Int {
                    ("\(type(of: layer))".contains("SDFElement") ? 1 : 0) + (layer.sublayers ?? []).map(shapes).reduce(0, +)
                }
                found.append((layer.frame, shapes(layer)))
            }
            return found + (layer.sublayers ?? []).flatMap(walk)
        }
        return view.layer.map(walk) ?? []
    }

    private func header(_ design: AtticDesignContext, isPinned: Bool = false) -> some View {
        PanelHeader(isPinned: isPinned, page: .tasks, onTogglePin: {}, onSelectPage: { _ in })
            .atticDesign(design)
    }

    private func withCornerStyle(_ style: AtticCornerButtonStyle, _ body: () throws -> Void) rethrows {
        let lab = AtticCornerButtonsLab.shared
        let saved = lab.style
        lab.style = style
        defer { lab.style = saved }
        try body()
    }

    // MARK: - Glass by default

    func testTheCornerButtonsAreLiquidGlassByDefault() throws {
        XCTAssertEqual(AtticCornerButtonsLab.shared.style, .liquidGlass, "the product (and this test host) is glass")
        XCTAssertFalse(AtticCornerButtonStyle.liquidGlass.drawsFlat(in: .default))
        for mode in AtticDesignContext.Mode.allCases {
            for increaseContrast in [false, true] {
                let design = AtticDesignContext(mode: mode, increaseContrast: increaseContrast)
                for isPinned in [false, true] {
                    let (panel, view) = host(header(design, isPinned: isPinned))
                    defer { panel.orderOut(nil); panel.close() }
                    let glass = backdrops(in: view)
                    let name = "\(mode) contrast=\(increaseContrast) pinned=\(isPinned)"
                    // One shared container: one backdrop for both buttons,
                    // not one each.
                    XCTAssertEqual(glass.count, 1, "\(name): one shared glass container")
                    XCTAssertEqual(glass.first?.shapes, 2, "\(name): the pin and the page button are its two shapes")
                }
            }
        }
    }

    /// The A/B arm and every place the controls are not live glass draw L3's
    /// opaque surface: no glass at all.
    func testReduceTransparencyTheCraftStyleAndFlatGiveTheOpaqueSurface() throws {
        let opaque: [(String, AtticDesignContext, AtticCornerButtonStyle)] = [
            ("Reduce Transparency", AtticDesignContext(reduceTransparency: true), .liquidGlass),
            ("Reduce Transparency, Dark", AtticDesignContext(mode: .dark, reduceTransparency: true), .liquidGlass),
            ("Craft (a Solid panel that is not key)", AtticDesignContext(controls: .craft), .liquidGlass),
            ("Flat", AtticDesignContext(), .flat),
        ]
        for (name, design, style) in opaque {
            XCTAssertTrue(style.drawsFlat(in: design), name)
            try withCornerStyle(style) {
                let (panel, view) = host(header(design, isPinned: true))
                defer { panel.orderOut(nil); panel.close() }
                XCTAssertTrue(backdrops(in: view).isEmpty, "\(name): the opaque flat surface, no glass")
            }
        }
    }

    // MARK: - Clicks still reach the buttons

    /// Interactive glass only responds to a click: the pin's action and the
    /// page button's pages still take it, glass or flat.
    func testClicksReachTheButtonsThroughTheGlass() throws {
        final class Clicks { var pins = 0; var page = 0 }
        for flat in [false, true] {
            let clicks = Clicks()
            let pages: [AtticPageButton<Int>.Item] = [
                .init(page: 0, systemName: "checkmark.circle", title: "Tasks", shortcut: "⌘1"),
                .init(page: 1, systemName: "note.text", title: "Notes", shortcut: "⌘2"),
                .init(page: 2, systemName: "scribble.variable", title: "Canvas", shortcut: "⌘3"),
            ]
            let view = AtticControlGroup {
                HStack(spacing: 0) {
                    AtticRaisedButton(systemName: "pin", label: "Pin", flat: flat) { clicks.pins += 1 }
                    Spacer(minLength: 6)
                    AtticPageButton(items: pages, selection: Binding(get: { clicks.page }, set: { clicks.page = $0 }),
                                    pinnedOpen: true, flat: flat)
                }
            }
            .atticDesign(AtticDesignContext(mode: .light))
            let size = CGSize(width: 340, height: 80)
            let (panel, hosting) = host(view, size: size)
            defer { panel.orderOut(nil); panel.close() }
            XCTAssertEqual(backdrops(in: hosting).count, flat ? 0 : 1)
            func click(_ x: CGFloat) {
                // The controls are centred vertically; AppKit's window points are y-up.
                let point = CGPoint(x: x, y: size.height / 2)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    panel.sendEvent(event)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            click(18)
            XCTAssertEqual(clicks.pins, 1, "flat=\(flat): the pin takes the click")
            // Open, the pages are 28 pt segments 2 apart inside a 4 pt inset,
            // ending at the trailing edge: Notes is the middle one.
            let width = AtticPageButton<Int>.width(open: true, count: 3)
            click(size.width - width + AtticPageButtonMetrics.inset + AtticPageButtonMetrics.segment * 1.5 + AtticPageButtonMetrics.gap)
            XCTAssertEqual(clicks.page, 1, "flat=\(flat): a page takes the click")
        }
    }

    // MARK: - The switch is preview-only

    private func scratchDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "AtticCornerButtonsLabTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testOnlyAPreviewIdentityCanChooseFlat() throws {
        let identities: [String?] = [
            "com.taha.Attic", "com.taha.Attic.UnitTestHost", "com.taha.Attic.perf.ui",
            "com.taha.Attic.previewish", "com.taha.Attic.preview.", "com.taha.AtticUITests", "", nil,
        ]
        let flat = ["ATTIC_UI_TEST_CORNER_BUTTONS": "flat"]
        for identity in identities {
            let name = identity ?? "nil"
            let isPreview = AtticPreviewOverrides.isPreviewIdentity(identity)
            XCTAssertFalse(isPreview, name)
            let overrides = AtticPreviewOverrides.resolve(environment: flat, bundleIdentifier: identity)
            XCTAssertNil(overrides.cornerButtons, "\(name) ignores the environment")
            let (defaults, cleanup) = try scratchDefaults()
            defer { cleanup() }
            // Even handed the override, a non-preview lab stays glass.
            let lab = AtticCornerButtonsLab(defaults: defaults, overrides: AtticPreviewOverrides(cornerButtons: .flat), isPreview: isPreview)
            XCTAssertEqual(lab.style, .liquidGlass, "\(name): the environment cannot choose Flat")
            XCTAssertFalse(lab.offersChoice, "\(name): no switch")
            defaults.set(AtticCornerButtonStyle.flat.rawValue, forKey: AtticCornerButtonsLab.styleKey)
            XCTAssertEqual(AtticCornerButtonsLab(defaults: defaults, isPreview: isPreview).style, .liquidGlass,
                           "\(name): a stored Flat is ignored")
            defaults.removeObject(forKey: AtticCornerButtonsLab.styleKey)
            AtticCornerButtonsLab(defaults: defaults, isPreview: isPreview).style = .flat
            XCTAssertNil(defaults.string(forKey: AtticCornerButtonsLab.styleKey), "\(name): nothing is kept")
        }

        // A preview: glass by default, the environment forces either for the
        // launch (over a stored choice, without storing it), the developer
        // panel's choice is kept.
        let preview = "com.taha.Attic.preview.glass"
        XCTAssertEqual(AtticPreviewOverrides.resolve(environment: flat, bundleIdentifier: preview).cornerButtons, .flat)
        XCTAssertEqual(AtticPreviewOverrides.resolve(environment: ["ATTIC_UI_TEST_CORNER_BUTTONS": "glass"], bundleIdentifier: preview).cornerButtons, .glass)
        XCTAssertNil(AtticPreviewOverrides.resolve(environment: ["ATTIC_UI_TEST_CORNER_BUTTONS": "Flat"], bundleIdentifier: preview).cornerButtons,
                     "an unknown word is ignored")
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let lab = AtticCornerButtonsLab(defaults: defaults, isPreview: true)
        XCTAssertEqual(lab.style, .liquidGlass, "glass by default in a preview too")
        XCTAssertTrue(lab.offersChoice)
        XCTAssertEqual(AtticCornerButtonsLab(defaults: defaults, overrides: AtticPreviewOverrides(cornerButtons: .flat), isPreview: true).style, .flat)
        XCTAssertNil(defaults.string(forKey: AtticCornerButtonsLab.styleKey), "a forced launch stores nothing")
        lab.style = .flat
        XCTAssertEqual(AtticCornerButtonsLab(defaults: defaults, isPreview: true).style, .flat, "the developer panel's choice is kept")
        XCTAssertEqual(AtticCornerButtonsLab(defaults: defaults, overrides: AtticPreviewOverrides(cornerButtons: .glass), isPreview: true).style,
                       .liquidGlass, "the environment wins for its launch")
        XCTAssertEqual(AtticCornerButtonStyle.allCases.map(\.title), ["Liquid Glass", "Flat"])
    }

    // MARK: - Scrolling and swiping never reach the header

    func testScrollingAndSwipingNeverReEvaluateTheHeader() throws {
        let suite = "CornerGlassTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let tasksState = TasksPageState()
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(
                store: store, noteStore: notes,
                canvasSession: CanvasSession(store: CanvasStore(container: container)),
                noteDraft: NoteDraftController(noteStore: notes),
                chromeInteractionState: chrome, uiState: state, settings: settings,
                subtaskPanels: SubtaskPanelController(store: store, uiState: state, settings: settings),
                tasksPageState: tasksState
            ),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome
        )
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        panel.makeKey()
        // The key panel: the corner buttons are live glass.
        state.setPanelKey(true)
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func frame() {
            RunLoop.current.run(until: Date())
            host.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
        }
        spin(1.5)
        state.selectSection(.tasks)
        spin(1.5)
        let model = tasksState.model(for: store, toasts: nil)
        XCTAssertEqual(model.tab, .now)

        // The list on show: the tallest scroll view at the page's left edge.
        func lists(_ view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView { return [scroll] }
            return view.subviews.flatMap(lists)
        }
        let list = try XCTUnwrap(lists(host)
            .filter { $0.frame.height > host.bounds.height / 3 }
            .first { abs($0.convert($0.bounds, to: nil).minX) < host.bounds.width / 2 })
        PanelHeader.bodyEvaluations = 0
        AtticAddBar.bodyEvaluations = 0
        TasksPage.tabsEvaluations = 0
        // Scrolling: the list moves under the header 6 pt a frame, down and
        // back, as AppKit scrolls it (its clip view's bounds, which SwiftUI
        // follows).
        let clip = list.contentView
        let top = clip.bounds.origin.y
        for step in Array(1...60) + Array((0..<60).reversed()) {
            clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: top + CGFloat(step) * 6))
            list.reflectScrolledClipView(clip)
            frame()
            if step == 60 { XCTAssertEqual(clip.bounds.origin.y - top, 360, accuracy: 1, "the list scrolled under the header") }
        }
        spin(0.6)
        XCTAssertEqual(PanelHeader.bodyEvaluations, 0, "scrolling never re-evaluates the header")
        XCTAssertEqual(AtticAddBar.bodyEvaluations, 0, "scrolling never re-evaluates the composer")
        XCTAssertEqual(TasksPage.tabsEvaluations, 0, "scrolling never re-evaluates the tabs/Find controls")

        // Swiping: Now to Later and back, as the page's monitor feeds it.
        var time: TimeInterval = 1_000
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0) {
            time += 1.0 / 120
            _ = model.pagerScrolled(.init(phase: phase, dx: dx, time: time), allowed: true)
            frame()
        }
        for (dx, lands) in [(CGFloat(-9), TasksTab.backlog), (9, .now)] {
            send(.began)
            for _ in 0..<40 { send(.changed, dx: dx) }
            send(.ended)
            spin(1)
            XCTAssertEqual(model.tab, lands, "the swipe turned the page")
        }
        XCTAssertEqual(PanelHeader.bodyEvaluations, 0, "swiping never re-evaluates the header")

        // The seam counts: pinning does re-evaluate it.
        state.isPanelPinned = true
        spin(0.3)
        XCTAssertGreaterThan(PanelHeader.bodyEvaluations, 0, "the counter sees the header's own changes")
    }
}
