import AppKit
import QuartzCore
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 11 (performance): what each interaction costs the main thread,
/// headless, on the spec's seeded sizes (500 open tasks, 500 in Later,
/// 5,000 in the Done log, with dates, tags and priorities mixed in). Each
/// "frame" is the change, then the run loop turn, layout, display and the
/// Core Animation commit that put it on screen, timed together. It prints
/// what it measures (`ATTIC_FRAME_COST`) and sets no budget of its own: a
/// 120 Hz frame is 8.3 ms, the spec's page switch budget is 50 ms, and the
/// judgement is made on an optimized build (`Scripts/run_optimized_tests.zsh`)
/// and the owner's Mac, not here. Only coarse sanity bounds are asserted,
/// far above any budget, so a slow CI runner never fails it.
@MainActor
final class TasksFrameCostTests: XCTestCase {
    private var hosted: FrameCostHost?

    override func tearDown() async throws {
        hosted?.close()
        hosted = nil
        try await super.tearDown()
    }

    func testMeasuresWhatEachInteractionCostsTheMainThread() throws {
        let host = try FrameCostHost()
        hosted = host
        // The Motion Lab: the feel measured (ATTIC_MOTION_FEEL, else the default).
        let feel = MotionFeelUnderTest.apply()
        defer { MotionFeelUnderTest.restore() }
        var report: [String] = ["feel=\(feel)", "edges=\(EdgesUnderTest.style.rawValue)"]
        // Profiling seam: one scenario, repeated (ATTIC_FRAME_COST_LOOP).
        if let loop = ProcessInfo.processInfo.environment["ATTIC_FRAME_COST_LOOP"] {
            let ids = host.model.rows(for: .now).prefix(6).map(\.id)
            let until = Date().addingTimeInterval(20)
            while Date() < until {
                switch loop {
                case "select": for id in ids { _ = host.frame { host.model.selectOnly(id) } }
                case "click": for tab in [TasksTab.backlog, .now] { _ = host.click(tab) }
                default: _ = host.swipe(from: .now, steps: 40, dx: -9); host.place(.now)
                }
            }
            return
        }

        // A tab click, as `AtticPageTabs` makes it, to each page and back;
        // the first frame (the model's change, the page's build, the
        // slide's first step) and the whole slide's frames.
        var clickFirst: [TasksTab: [Double]] = [:]
        var clickFrames: [Double] = []
        for _ in 0..<3 {
            for tab in [TasksTab.backlog, .done, .now] {
                let result = host.click(tab)
                clickFirst[tab, default: []].append(result.first)
                clickFrames += result.frames
            }
        }
        report.append("click-first " + Self.byTab(clickFirst))
        report.append("click-slide-frames " + Self.stats(clickFrames))
        // Where a click's first frame goes (to Later, cold or not).
        let phases = host.framePhases {
            withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { host.model.select(tab: .backlog) }
        }
        report.append("click-first-parts " + phases.map { String(format: "%.1f", $0) }.joined(separator: "/"))
        host.place(.now)

        // The same clicks with every page already built (what keeping the
        // pages built would give), and what a selection change costs with
        // one page built and with three.
        var warmFirst: [TasksTab: [Double]] = [:]
        var selectOne: [Double] = []
        var selectThree: [Double] = []
        let ids = host.model.rows(for: .now).prefix(6).map(\.id)
        for _ in 0..<3 {
            for _ in 0..<3 { for id in ids { selectOne.append(host.frame { host.model.selectOnly(id) }) } }
            for tab in [TasksTab.backlog, .done, .now] {
                _ = host.frame { host.model.pagerSwipe.span.pages = 0...2 }
                host.spin(0.1)
                if tab == .now { for id in ids { selectThree.append(host.frame { host.model.selectOnly(id) }) } }
                warmFirst[tab, default: []].append(host.frame {
                    withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { host.model.select(tab: tab) }
                })
                host.spin(0.8)
            }
        }
        report.append("warm-click-first " + Self.byTab(warmFirst))
        report.append("select-1-page " + Self.stats(selectOne))
        report.append("select-3-pages " + Self.stats(selectThree))

        // A swipe from Now to Later: the first sideways movement (it
        // draws Later), the frames that follow the fingers, then the
        // release's settle.
        var swipeFirst: [Double] = []
        var swipeFrames: [Double] = []
        var settleFrames: [Double] = []
        for _ in 0..<3 {
            let result = host.swipe(from: .now, steps: 40, dx: -9)
            swipeFirst.append(result.first)
            swipeFrames += result.follow
            settleFrames += result.settle
            host.place(.now)
        }
        report.append("swipe-first " + Self.stats(swipeFirst))
        report.append("swipe-follow-frames " + Self.stats(swipeFrames))
        report.append("swipe-settle-frames " + Self.stats(settleFrames))

        // Scrolling Now's list (the Motion Lab's "Edges": rows pass under
        // the tabs and the add bar), 8 pt a frame down and back.
        host.place(.now)
        let scrolled = host.scroll(steps: 60, dy: 8)
        report.append("scroll-frames " + Self.stats(scrolled.frames) + String(format: " travelled=%.0fpt", scrolled.travelled))

        // Typing in the add bar on Now (500 rows behind it).
        host.place(.now)
        let keys = host.type("Call the plumber tomorrow #home")
        report.append("keystroke " + Self.stats(keys) + " typed=\(host.model.addBar.text.count)")

        // Typing in a row's title editor, then in Done's search.
        host.place(.now)
        if let id = host.model.rows(for: .now).dropFirst(2).first?.id {
            host.model.selectOnly(id)
            host.model.beginEditingTitle(id)
            host.spin(0.5)
            let frames = host.type(" and more", focusAddBar: false)
            report.append("title-keystroke " + Self.stats(frames) + " typed=\(host.model.titleEdit.text.count)")
            host.model.cancelEditing()
            host.spin(0.3)
        }
        host.place(.done)
        host.model.beginSearch()
        host.spin(0.6)
        let searchFrames = host.type("task 12", focusAddBar: false)
        report.append("search-keystroke " + Self.stats(searchFrames) + " typed=\(host.model.doneSearch.count)")
        host.model.doneSearch = ""
        host.place(.now)

        print("ATTIC_FRAME_COST " + report.joined(separator: " | "))
        // Sanity only (see the type's comment).
        XCTAssertLessThan(Self.median(keys), 500)
        XCTAssertEqual(host.model.tab, .now)
    }

    // MARK: Reporting

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    static func stats(_ values: [Double]) -> String {
        String(format: "n=%d median=%.1fms p90=%.1fms max=%.1fms over8.3=%d", values.count, median(values),
               percentile(values, 0.9), values.max() ?? 0, values.filter { $0 > 1000.0 / 120 }.count)
    }

    static func byTab(_ samples: [TasksTab: [Double]]) -> String {
        [TasksTab.now, .backlog, .done].map { tab in
            "\(tab.identifier)=" + String(format: "%.1fms", median(samples[tab] ?? []))
        }.joined(separator: " ")
    }
}

/// The Tasks page on the spec's seeded sizes, in a window off screen, as
/// the panel hosts it; each step is timed as one frame.
@MainActor
final class FrameCostHost {
    let store: TaskStore
    let model: TasksPageModel
    let window: NSPanel
    let focus = Hosted.Focus()
    private var time: TimeInterval = 1_000

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    init() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        if ProcessInfo.processInfo.environment["ATTIC_EXP_SEED"] == "demo" {
            try TasksPagePreview.seedDemo(in: container)
        } else {
            try TasksPagePreview.seedScale(in: container)
        }
        store = TaskStore(container: container)
        model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        // Comparison seam: ATTIC_FRAME_COST_WARM=0 keeps no page built beside the one shown.
        model.pagerSwipe.motion.warms = ProcessInfo.processInfo.environment["ATTIC_FRAME_COST_WARM"] != "0"
        let size = CGSize(width: AtticLayout.panelSize.width, height: 560)
        let focus = focus
        let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: Binding(get: { focus.addBar }, set: { focus.addBar = $0 }))
        window = Panel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.atticDesign(EdgesUnderTest.context(AtticDesignContext(mode: .light)))
            .frame(width: size.width, height: size.height))
        window.orderFront(nil)
        window.makeKey()
        spin(1)
    }

    func close() { window.close() }

    func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// One frame: the change, a run loop turn, layout, display and the
    /// commit, in milliseconds.
    func frame(_ change: () -> Void = {}) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        change()
        RunLoop.current.run(until: Date())
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// One frame split into its parts (change, run loop, layout, display,
    /// commit), in milliseconds.
    func framePhases(_ change: () -> Void) -> [Double] {
        var marks = [DispatchTime.now().uptimeNanoseconds]
        change()
        marks.append(DispatchTime.now().uptimeNanoseconds)
        RunLoop.current.run(until: Date())
        marks.append(DispatchTime.now().uptimeNanoseconds)
        window.contentView?.layoutSubtreeIfNeeded()
        marks.append(DispatchTime.now().uptimeNanoseconds)
        window.displayIfNeeded()
        marks.append(DispatchTime.now().uptimeNanoseconds)
        CATransaction.flush()
        marks.append(DispatchTime.now().uptimeNanoseconds)
        return zip(marks.dropFirst(), marks).map { Double($0 - $1) / 1_000_000 }
    }

    /// The pager's position changes over its settle, one frame each,
    /// until it rests (at most two seconds).
    private func settleFrames() -> [Double] {
        var frames: [Double] = []
        let motion = model.pagerSwipe.motion
        let deadline = Date().addingTimeInterval(2)
        var last = motion.position
        while motion.isSettling, Date() < deadline {
            // Wait for the driver's next step, then time the frame it asks for.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.0 / 240))
            guard motion.position != last else { continue }
            last = motion.position
            frames.append(frame())
        }
        return frames
    }

    /// Scrolls the shown list `steps` frames down by `dy` points, then back
    /// up, as a trackpad does (the clip view moves; SwiftUI follows), one
    /// frame each. Empty when no list's scroll view is found.
    func scroll(steps: Int, dy: CGFloat) -> (frames: [Double], travelled: CGFloat) {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        guard let root = window.contentView,
              let list = scrollViews(in: root).filter({ !$0.isHiddenOrHasHiddenAncestor })
                .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return ([], 0) }
        var frames: [Double] = []
        let start = list.contentView.bounds.origin.y
        var furthest: CGFloat = 0
        for direction in [CGFloat(1), -1] {
            for _ in 0..<steps {
                frames.append(frame {
                    let clip = list.contentView
                    clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + dy * direction))
                    list.reflectScrolledClipView(clip)
                })
                furthest = max(furthest, abs(list.contentView.bounds.origin.y - start))
            }
        }
        return (frames, furthest)
    }

    /// Places the page on `tab` at once and lets it rest.
    func place(_ tab: TasksTab) {
        model.select(tab: tab)
        model.showPagerPage(animated: false)
        spin(0.6)
    }

    /// A tab click (as the tabs make it): its first frame, then the frames
    /// of its slide.
    func click(_ tab: TasksTab) -> (first: Double, frames: [Double]) {
        let first = frame {
            withAnimation(AtticMotionPreset.slide.animation(reduceMotion: false)) { model.select(tab: tab) }
        }
        let frames = settleFrames()
        spin(0.6)
        return (first, frames)
    }

    /// A swipe of `steps` sideways movements of `dx` from `tab`, released.
    func swipe(from tab: TasksTab, steps: Int, dx: CGFloat) -> (first: Double, follow: [Double], settle: [Double]) {
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0) {
            time += 1.0 / 120
            _ = model.pagerScrolled(.init(phase: phase, dx: dx, time: time), allowed: true)
        }
        _ = frame { send(.began) }
        let first = frame { send(.changed, dx: dx) }
        var follow: [Double] = []
        for _ in 1..<steps { follow.append(frame { send(.changed, dx: dx) }) }
        var settle = [frame { send(.ended) }]
        settle += settleFrames()
        spin(0.6)
        return (first, follow, settle)
    }

    /// Types `text` into the add bar, one key a frame.
    func type(_ text: String, focusAddBar: Bool = true) -> [Double] {
        if focusAddBar {
            focus.addBar = true
            // The binding is not observed: the page reads it on its next redraw.
            model.objectWillChange.send()
            spin(0.3)
        }
        var frames: [Double] = []
        for character in text {
            let characters = String(character)
            frames.append(frame {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: 0)!
                    NSApp.postEvent(event, atStart: false)
                }
                Hosted.pumpEvents()
            })
        }
        spin(0.3)
        return frames
    }
}
