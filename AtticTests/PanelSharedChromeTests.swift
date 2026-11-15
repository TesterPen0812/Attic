import AppKit
import ApplicationServices
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Owner, 2026-10-31 (Accepted "Shared controls stay still while pages
/// switch"): the bottom bar and the top row's shared controls are one layer
/// above the pages, and the page switch's open moves the bar with it.
@MainActor
final class PanelSharedChromeTests: XCTestCase {
    override func record(_ issue: XCTIssue) {
        if issue.type == .assertionFailure {
            for shell in RealShell.live.allObjects {
                shell.requestFinalDiagnostics()
                shell.recordSnapshot("on assertion failure")
                let attachment = XCTAttachment(string: shell.focusDiagnostics())
                attachment.name = "BG-67 native focus and Tab history"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        super.record(issue)
    }

    override func setUp() {
        super.setUp()
        resetStaticState()
    }

    override func tearDown() {
        resetStaticState()
        super.tearDown()
    }

    /// The statics the "+" card and the key-stop seams leave behind, so no
    /// test passes or fails on what an earlier one left (round 2 review N-1).
    private func resetStaticState() {
        ComposerOverlay.isPresented = false
        AtticDraw.enabledOverride = nil
        PanelKeyStopSeam.holdsHandoffs = false
        PanelKeyStopSeam.held = []
        PanelKeyStopSeam.plusFocusReports = [:]
        PanelKeyStopSeam.focusCallbacks = []
        PanelKeyStopSeam.monitorDecisions = []
        PanelKeyStopSeam.actions = []
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    func testBugs4TaskPageTakesTheSharedGlassAwayBeforeDrawingItsOwnControls() throws {
        let chrome = PanelSharedChrome()
        let state = PanelTopRowState()
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        let root = VStack {
            PanelSharedTopControls(page: .tasks).atticMaterialProbe("task-cover-top")
            PanelSharedBottomBar(chrome: chrome, page: .tasks, layout: layout).atticMaterialProbe("task-cover-bottom")
        }
        .environment(\.panelSharedChrome, chrome)
        .environment(\.panelTopRowState, state)
        .atticDesign(.default)
        AtticMaterialProbe.reset()
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 340, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        spin(0.3)
        XCTAssertEqual(AtticMaterialProbe.states["task-cover-top"], .init(away: false, gone: false))
        XCTAssertEqual(AtticMaterialProbe.states["task-cover-bottom"], .init(away: false, gone: false))
        chrome.setCovered(true, page: .tasks)
        host.layoutSubtreeIfNeeded()
        spin(0.02)
        XCTAssertEqual(AtticMaterialProbe.states["task-cover-top"], .init(away: true, gone: true), "the shared Settings glass must not fade over the task's inline menu")
        XCTAssertEqual(AtticMaterialProbe.states["task-cover-bottom"], .init(away: true, gone: true), "native glass ignores the bar's outer opacity and must give Back its row")
        chrome.setCovered(false, page: .tasks)
        spin(0.3)
        XCTAssertEqual(AtticMaterialProbe.states["task-cover-top"], .init(away: false, gone: false))
        XCTAssertEqual(AtticMaterialProbe.states["task-cover-bottom"], .init(away: false, gone: false))
    }

    /// The owner's crops, 2026-11-05: with a note open, Back and the note's
    /// "+" showed through the "+" card's corners. They are the page's own
    /// row, not the shared bar, and Back, "+" and Aa each set the fold's
    /// flags for the format row, so a fold around the row must still reach
    /// their glass.
    func testPageDrawnRowGivesItsGlassAwayUnderTheCard() throws {
        let chrome = PanelSharedChrome()
        let root = HStack {
            AtticRaisedButton(systemName: "chevron.left", label: "Back", action: {})
                .noteFormatRowLeaving(.allNotes)
                .atticMaterialProbe("row-back")
            AtticRaisedButton(systemName: NoteFormatRowSource.symbol, label: "Format", action: {})
                .noteFormatRowSource()
                .atticMaterialProbe("row-format")
            AtticRaisedButton(systemName: "plus", label: "New note", action: {})
                .noteFormatRowLeaving(.newNote)
                .atticMaterialProbe("row-plus")
            AtticRaisedButton(systemName: "checkmark", label: "Done", action: {})
                .atticMaterialProbe("row-plain")
        }
        .panelRowGivesWayToCard()
        .environment(\.panelSharedChrome, chrome)
        .atticDesign(.default)
        AtticMaterialProbe.reset()
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 340, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        spin(0.3)
        let ids = ["row-back", "row-format", "row-plus", "row-plain"]
        for id in ids { XCTAssertEqual(AtticMaterialProbe.states[id], .init(away: false, gone: false), id) }
        chrome.plusHandedOver = true
        spin(1)
        for id in ids {
            XCTAssertEqual(AtticMaterialProbe.states[id]?.gone, true, "\(id): native glass ignores the row's outer opacity")
        }
        chrome.plusHandedOver = false
        spin(1)
        for id in ids { XCTAssertEqual(AtticMaterialProbe.states[id], .init(away: false, gone: false), id) }
    }

    /// Outside the panel there is no card: a row keeps its glass.
    func testRowOutsideThePanelStaysAsItIs() throws {
        let root = AtticRaisedButton(systemName: "plus", label: "New note", action: {})
            .atticMaterialProbe("row-window")
            .panelRowGivesWayToCard()
            .atticDesign(.default)
        AtticMaterialProbe.reset()
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 120, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        spin(0.3)
        XCTAssertEqual(AtticMaterialProbe.states["row-window"], .init(away: false, gone: false))
    }

    /// An element's frame in the host's top-left space.
    private func frame(of identifier: String, in host: NSView) -> CGRect? {
        host.layoutSubtreeIfNeeded()
        guard let element = elements(host).first(where: { ($0.accessibilityIdentifier?() ?? "") == identifier }),
              let screen = element.accessibilityFrame?(), let window = host.window, screen.width > 0 else { return nil }
        let local = host.convert(window.convertFromScreen(screen), from: nil)
        return host.isFlipped ? local : CGRect(x: local.minX, y: host.bounds.height - local.maxY,
                                               width: local.width, height: local.height)
    }

    /// The mean level of each box (pt, top-left), as drawn now.
    private func levels(_ host: NSView, _ boxes: [CGRect]) throws -> [CGFloat] {
        // Reproduce CI's 140 ms bitmap capture without changing its assertions.
        if ProcessInfo.processInfo.environment["ATTIC_TEST_SLOW_CHROME_CAPTURE"] == "1" {
            Thread.sleep(forTimeInterval: 0.14)
        }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        return try boxes.map { box in
            var sum: CGFloat = 0, count: CGFloat = 0
            for y in Int(box.minY * scale) ..< Int(box.maxY * scale) {
                for x in Int(box.minX * scale) ..< Int(box.maxX * scale) {
                    let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    count += 1
                }
            }
            return sum / max(count, 1)
        }
    }

    private func box(around point: CGPoint, side: CGFloat = 5) -> CGRect {
        CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
    }

    /// `cacheDisplay` paints the model tree, which can already be at its
    /// destination even while an offscreen layer's presentation is travelling.
    /// Record stable model-layer identities and their stepped presentation X.
    private func presentationOriginX(in root: CALayer) -> [ObjectIdentifier: CGFloat] {
        var positions: [ObjectIdentifier: CGFloat] = [:]
        func visit(_ layer: CALayer) {
            if let presented = layer.presentation() {
                positions[ObjectIdentifier(layer)] = presented.frame.minX
            }
            for child in layer.sublayers ?? [] { visit(child) }
        }
        visit(root)
        return positions
    }

    /// Through a page switch (the pages travelling sideways), the pin, •••,
    /// Search, the page switch, the tag bar card and "+" stay put and keep
    /// their look on every frame: they are drawn once, above the pages, so
    /// the switch is one view whose open state lives on.
    func testSharedControlsStayStillThroughAPageSwitch() throws {
        // Terra 9 (batch 3): the switch's motion is stated, never the
        // system's (CI runners turn Reduce Motion on, which made the
        // switch instant and this test vacuous); solid glass is stated too.
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let suite = "PanelSharedChrome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        _ = store.commit([TaskDraft(title: "Write launch notes", tags: ["launch"])])
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Launch plan")]), tags: ["launch"]).get()
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        // Solid and not key: the controls draw the opaque Craft face, so a
        // page passing behind them never changes their pixels.
        settings.panelSurfaceStyle = .solid
        let draft = NoteDraftController(noteStore: notes)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state, settings: settings),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        spin(1.0)
        // Build every page once, with Notes on its list.
        for section in [PanelSection.notes, .calendar, .tasks] {
            state.switchPage(to: section, motion: .instant)
            spin(0.8)
            if section == .notes { XCTAssertTrue(draft.pages.showLibrary()); spin(0.8) }
        }
        // Accepted 2026-10-31 "Tall island": the page switch left the
        // bottom bar for the island beside the panel.
        XCTAssertNil(frame(of: "panel-section-picker", in: host), "no page switch in the bar")

        let plusIDs: [PanelSection: String] = [.tasks: "tasks-new-task", .notes: "notes-new-note", .calendar: "calendar-new-task"]
        let searchIDs: [PanelSection: String] = [.tasks: "tasks-find-button", .notes: "notes-search-button",
                                                 .calendar: "calendar-search-button"]
        let tagBarIDs: [PanelSection: String] = [.tasks: "tasks-tag-bar", .notes: "notes-tag-bar"]
        for (from, to) in [(PanelSection.tasks, PanelSection.notes), (.notes, .calendar), (.calendar, .tasks)] {
            let pin = try XCTUnwrap(frame(of: "panel-pin-button", in: host), "\(from): the pin")
            let more = try XCTUnwrap(frame(of: "panel-more-button", in: host), "\(from): •••")
            let search = try XCTUnwrap(frame(of: try XCTUnwrap(searchIDs[from]), in: host), "\(from): Search")
            let plus = try XCTUnwrap(frame(of: try XCTUnwrap(plusIDs[from]), in: host), "\(from): +")
            var boxes = [box(around: CGPoint(x: pin.midX, y: pin.midY)),
                         box(around: CGPoint(x: more.midX, y: more.midY)),
                         box(around: CGPoint(x: search.midX, y: search.midY)),
                         box(around: CGPoint(x: plus.midX, y: plus.midY))]
            var names = ["pin", "•••", "Search", "+"]
            // The tag bar card's empty end, where both pages draw no tag.
            if let fromBar = tagBarIDs[from], tagBarIDs[to] != nil {
                let bar = try XCTUnwrap(frame(of: fromBar, in: host), "\(from): the tag bar")
                boxes.append(box(around: CGPoint(x: bar.maxX - 8, y: bar.midY - 7), side: 4))
                names.append("tag bar card")
            }
            // The pages' own content under the top row: it must travel
            // (frames between the two pages), or the switch was instant.
            let content = CGRect(x: 20, y: 64, width: size.width - 40, height: 120)
            boxes.append(content)
            let before = try levels(host, boxes)
            var samples: [(ms: Int, levels: [CGFloat])] = []
            var presentationTracks: [ObjectIdentifier: [CGFloat]] = [:]
            do {
                // As in the island motion tests, pause presentation and step
                // its clock. Bitmap capture cost must never skip a frame:
                // the same 0.7 s window is sampled at 60 frames per second.
                let layer = try XCTUnwrap(host.layer)
                let start = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = start
                defer { layer.speed = 1; layer.timeOffset = 0 }
                host._renderForTest(interval: 0)
                state.switchPage(to: to, motion: PanelPageMotion.current(reduceMotion: false))
                for frame in 0...42 {
                    let elapsed = Double(frame) / 60
                    // The page switch publishes into SwiftUI on the next
                    // main-queue turn. Without that turn an offscreen CI
                    // host can sample only the unchanged backing layers,
                    // reporting zero travel for every direction.
                    RunLoop.main.run(until: Date())
                    host._renderForTest(interval: frame == 0 ? 0 : 1.0 / 60)
                    layer.timeOffset = start + elapsed
                    CATransaction.flush()
                    for (id, x) in presentationOriginX(in: layer) {
                        presentationTracks[id, default: []].append(x)
                    }
                    samples.append((Int(elapsed * 1000), try levels(host, boxes)))
                }
            }
            XCTAssertGreaterThan(samples.count, 10, "sampled the switch's frames")
            spin(0.4)
            // A box may settle to another level when the arriving page draws
            // something else under a translucent control (Calendar's agenda
            // reaches under the switch, owner 2026-10-31: every day listed).
            // Staying still means no frame leaves the span between the level
            // before and the level after: no replayed opening, no jump.
            let after = try levels(host, boxes)
            let travelled = presentationTracks.values.filter { $0.count > 10 }.map {
                ($0.max() ?? 0) - ($0.min() ?? 0)
            }.max() ?? 0
            XCTAssertGreaterThan(travelled, size.width / 5,
                                 "\(from) → \(to): a page layer travels during stepped presentation (max \(travelled) pt)")
            for (index, name) in names.enumerated() {
                // Known limit: Notes is never kept built, so it comes in by
                // the shell's insertion transition, which its top row cannot
                // counter; its board | list passes under the translucent •••
                // and Search for a frame. The controls themselves stay put
                // (their frames are checked below).
                if to == .notes, name == "•••" || name == "Search" { continue }
                let low = min(before[index], after[index]), high = max(before[index], after[index])
                var worst: CGFloat = 0
                var trace = ""
                for sample in samples {
                    let level = sample.levels[index]
                    let outside = max(0, low - level, level - high)
                    worst = max(worst, outside)
                    if outside >= 0.02 { trace += String(format: " %d:%.2f", sample.ms, level) }
                }
                XCTAssertLessThan(worst, 0.04, "\(from) → \(to): \(name) keeps its place and look on every frame "
                                  + "(worst \(worst) outside \(before[index])…\(after[index]);\(trace))")
            }
            for (id, was) in [(try XCTUnwrap(plusIDs[to]), plus),
                              (try XCTUnwrap(searchIDs[to]), search), ("panel-more-button", more), ("panel-pin-button", pin)] {
                let now = try XCTUnwrap(frame(of: id, in: host), "\(from) → \(to): \(id) is drawn")
                for (a, b) in [(now.minX, was.minX), (now.minY, was.minY), (now.width, was.width), (now.height, was.height)] {
                    XCTAssertEqual(a, b, accuracy: 0.5, "\(from) → \(to): \(id) keeps its frame (\(now) vs \(was))")
                }
            }
        }
    }

    // MARK: The switch's open and the bar

    /// Tracking areas the pointer is inside.
    private var insideAreas: Set<ObjectIdentifier> = []

    /// The pointer at a point of the host (top-left), or off it: each
    /// tracking area's owner hears it enter, move and leave, as AppKit tells
    /// them when the real pointer moves. No wait after.
    private func hover(_ host: NSView, at point: CGPoint?) throws {
        let window = try XCTUnwrap(host.window)
        host.layoutSubtreeIfNeeded()
        let location = point.map { CGPoint(x: $0.x, y: host.bounds.height - $0.y) } ?? CGPoint(x: -40, y: -40)
        let now = ProcessInfo.processInfo.systemUptime
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: now,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 0, pressure: 0))
        for view in views(host) {
            for area in view.trackingAreas {
                guard let owner = area.owner as? NSResponder else { continue }
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                let inside = rect.contains(view.convert(location, from: nil))
                let key = ObjectIdentifier(area)
                func edge(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: now,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil)
                }
                if inside, !insideAreas.contains(key), area.options.contains(.mouseEnteredAndExited), let event = edge(.mouseEntered) {
                    insideAreas.insert(key)
                    owner.mouseEntered(with: event)
                } else if !inside, insideAreas.contains(key), let event = edge(.mouseExited) {
                    insideAreas.remove(key)
                    owner.mouseExited(with: event)
                }
                if inside, area.options.contains(.mouseMoved) { owner.mouseMoved(with: moved) }
            }
        }
    }

    /// One frame's row at the bar's mid-height: the switch's right edge and
    /// the bar's left edge, in points.
    private struct Edges { let switchEnd: CGFloat; let barStart: CGFloat }

    private func edges(_ host: NSView, y: CGFloat, from x0: CGFloat) throws -> Edges? {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let row = Int(y * scale)
        func colour(_ x: Int) throws -> NSColor { try XCTUnwrap(rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB)) }
        func isBar(_ x: Int) throws -> Bool {
            let c = try colour(x)
            return c.redComponent > 0.85 && c.greenComponent < 0.2 && c.blueComponent < 0.2
        }
        // The bar's own soft edge (a partly covered pixel) is the bar's.
        func isBarEdge(_ x: Int) throws -> Bool {
            let c = try colour(x)
            return c.redComponent - (c.greenComponent + c.blueComponent) / 2 > 0.02
        }
        var bar: Int?
        var x = Int(x0 * scale)
        while x < rep.pixelsWide - 8 {
            if try (0 ..< 8).allSatisfy({ try isBar(x + $0) }) { bar = x; break }
            x += 1
        }
        guard let bar else { return nil }
        // The switch's edge: the last drawn pixel before the bar.
        var end = bar - 1
        while end > Int(x0 * scale), try isBarEdge(end) { end -= 1 }
        let barEdge = end + 1
        while end > Int(x0 * scale) {
            let c = try colour(end)
            if (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.985 { break }
            end -= 1
        }
        return Edges(switchEnd: CGFloat(end + 1) / scale, barStart: CGFloat(barEdge) / scale)
    }

    // The page switch that opened on hover and pushed the bar along is
    // gone: Accepted 2026-10-31 "Tall island" moves the switch out of the
    // bottom bar ("the hover-to-open switch is gone"), so its open-and-push
    // test went with it. `PanelIslandTests` covers the island.
}

// MARK: - The real shell's keyboard (BG-67 and what it must not break)

/// The production host: the real `AtticPanelView` in an `AtticPanelHostingView`
/// (AppKit's own key loop), in a key `AtticPanel`, with real Tab key events.
@MainActor
private final class RealShell {
    static let live = NSHashTable<RealShell>.weakObjects()
    enum Placement { case offscreen, onDisplay }
    private static let xcodeVersion: String = {
        let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        let plist = URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent("Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "unavailable"
    }()
    private var tabHistory: [String] = []
    private var inputTrace: [String] = []
    private var hasStartedTabbing = false
    private var finalDiagnosticsRequested = false
    // Keep diagnostic readers separate from native-test gate discovery.
    private var fullKeyboardAccessDescription: String { String(NSApp.isFullKeyboardAccessEnabled) }

    func requestFinalDiagnostics() { finalDiagnosticsRequested = true }

    func focusDiagnostics() -> String {
        "Recorded native input trace:\n\(inputTrace.joined(separator: "\n\n"))\n\n" +
        "on failure / final read:\n\(snapshot())\nTab stops actually visited:\n\(tabHistory.joined(separator: "\n"))"
    }

    func recordSnapshot(_ phase: String) {
        inputTrace.append("TRACE \(phase)\n\(snapshot())")
    }

    private func snapshot() -> String {
        let env = ProcessInfo.processInfo.environment
        let currentPage = PanelPage(state.selectedSection)
        let look = sharedChrome.bar(for: currentPage)
        let panelOnScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        let focusedAttribute = NSAccessibility.Attribute(rawValue: "AXFocused")
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let enhancedValue = NSApp.accessibilityAttributeValue(enhanced)
        let editor = panel.firstResponder as? NSTextView
        return """
        environment: commit=\(env["GITHUB_SHA"] ?? env["ATTIC_TEST_COMMIT"] ?? "unavailable") macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) Xcode=\(Self.xcodeVersion) XcodeDeveloperDir=\(env["DEVELOPER_DIR"] ?? "unavailable") keyOptIn=\(env["TEST_RUNNER_ATTIC_KEY_WINDOW_TESTS"] ?? env["ATTIC_KEY_WINDOW_TESTS"] ?? "unset") keyboardNavigationMode=\(String(describing: UserDefaults.standard.object(forKey: "AppleKeyboardUIMode"))) globalKeyboardNavigationMode=\(String(describing: UserDefaults(suiteName: "NSGlobalDomain")?.object(forKey: "AppleKeyboardUIMode"))) FKA=\(fullKeyboardAccessDescription) AXEnhancedUI=\(String(describing: enhancedValue)) AXEnhancedUISettable=\(NSApp.accessibilityIsAttributeSettable(enhanced))
        application: active=\(NSApp.isActive) keyWindow=\(String(describing: NSApp.keyWindow)) mainWindow=\(String(describing: NSApp.mainWindow)) panelKey=\(panel.isKeyWindow) panelMain=\(panel.isMainWindow)
        product: page=\(state.selectedSection) shown=\(look.shown) folded=\(look.folded) taken=\(sharedChrome.plusHandedOver) covered=\(sharedChrome.covered) reachable=\(look.plus != nil && look.shown && !look.folded && !sharedChrome.plusHandedOver && !sharedChrome.covered.contains(currentPage)) tagOpen=\(sharedChrome.tagBar.isOpen) tagCursor=\(String(describing: sharedChrome.tagBar.cursor)) hashOwns=\(sharedChrome.tagBar.keyFocused) summaryStop=\(String(describing: sharedChrome.tagBar.summaryFocus)) composer=\(ComposerOverlay.isPresented)
        window: panelFrame=\(panel.frame) visible=\(panel.isVisible) screenVisibleFrame=\(String(describing: panel.screen?.visibleFrame)) intersectsDisplay=\(panelOnScreen) hostAttached=\(host.window === panel) hostHidden=\(host.isHiddenOrHasHiddenAncestor) hostAlpha=\(host.alphaValue) panelAlpha=\(panel.alphaValue) hostAcceptsFirstResponder=\(host.acceptsFirstResponder)
        dispatch: firstResponder=\(String(describing: panel.firstResponder)) fieldEditor=\(String(describing: editor)) fieldEditorDelegate=\(String(describing: editor?.delegate)) monitorDecisions=\(PanelKeyStopSeam.monitorDecisions)
        focus callbacks: \(PanelKeyStopSeam.focusCallbacks)
        actions: \(PanelKeyStopSeam.actions)
        system AX focus: \(systemAXFocus()) NSAppFocused=\(focusedAXDescription())
        host AX tree:\n\(axTree(host, focus: focusedAttribute))
        window AX tree:\n\(axTree(panel, focus: focusedAttribute))
        native key loop:\n\(nativeKeyLoop())
        """
    }

    private func axTree(_ root: AnyObject, focus: NSAccessibility.Attribute) -> String {
        var lines: [String] = []
        var seen = Set<ObjectIdentifier>()
        let enabled = NSAccessibility.Attribute(rawValue: "AXEnabled")
        let hidden = NSAccessibility.Attribute(rawValue: "AXHidden")
        func visit(_ node: AnyObject, _ depth: Int) {
            if !seen.insert(ObjectIdentifier(node)).inserted {
                lines.append("\(String(repeating: "  ", count: depth))cycle to \(node)")
                return
            }
            let children = (node.accessibilityChildren?() ?? nil) ?? []
            let value = (node as? NSObject)?.accessibilityAttributeValue(focus)
            let focusValue = value.map { String(describing: $0) } ?? "MISSING (not false)"
            lines.append("\(String(repeating: "  ", count: depth))node=\(node) id=\(node.accessibilityIdentifier?() ?? nil ?? "MISSING") role=\(String(describing: node.accessibilityRole?())) frame=\(String(describing: node.accessibilityFrame?())) AXEnabled=\(String(describing: (node as? NSObject)?.accessibilityAttributeValue(enabled))) AXHidden=\(String(describing: (node as? NSObject)?.accessibilityAttributeValue(hidden))) AXFocused=\(focusValue) AXFocusedSettable=\(String(describing: (node as? NSObject)?.accessibilityIsAttributeSettable(focus))) children=\(children.count)")
            for child in children { visit(child as AnyObject, depth + 1) }
        }
        visit(root, 0)
        return lines.joined(separator: "\n")
    }

    private func systemAXFocus() -> String {
        let system = AXUIElementCreateSystemWide()
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func read(_ element: AXUIElement, _ attribute: String) -> String {
            var value: CFTypeRef?
            let name = CFStringCreateWithCString(nil, attribute, CFStringBuiltInEncodings.UTF8.rawValue)!
            let error = AXUIElementCopyAttributeValue(element, name, &value)
            return "\(attribute): status=\(error.rawValue) value=\(String(describing: value))"
        }
        return [read(system, kAXFocusedApplicationAttribute), read(system, kAXFocusedWindowAttribute),
                read(system, kAXFocusedUIElementAttribute), read(app, kAXFocusedWindowAttribute),
                read(app, kAXFocusedUIElementAttribute)].joined(separator: "; ")
    }

    private func focusedAXDescription() -> String {
        guard let focused = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXFocusedUIElement")) else { return "nil" }
        let node: AnyObject = focused as AnyObject
        return "\(focused) id=\(node.accessibilityIdentifier?() ?? nil ?? "nil") role=\(String(describing: node.accessibilityRole?())) frame=\(String(describing: node.accessibilityFrame?()))"
    }

    func writeFocusRenderIfRequested() throws {
        let env = ProcessInfo.processInfo.environment
        let path = env["ATTIC_R3_FOCUS_RENDER_DIR"] ?? env["TEST_RUNNER_ATTIC_R3_FOCUS_RENDER_DIR"] ?? "verification"
        // Native Liquid Glass cannot be rasterized offscreen. Use the
        // design system's capture backdrop for the same production bar.
        let size = CGSize(width: 340, height: 560)
        let view = PanelSharedBottomBar(chrome: sharedChrome, page: .notes,
                                       layout: PanelPageLayout(cornerSize: 52, panelSize: size))
            .frame(width: size.width, height: 88, alignment: .bottom)
            .background(Color(white: 0.95))
            .atticDesignCorners()
            .atticDesign(.default)
            .environment(\.atticKeyboardFocusVisible, true)
            .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: .desktop(.midGrey)))
        let captureWindow = NSWindow(contentRect: CGRect(x: -7000, y: -7000, width: size.width, height: 88),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        captureWindow.isReleasedWhenClosed = false
        let captureHost = NSHostingView(rootView: view)
        captureWindow.contentView = captureHost
        captureWindow.orderFront(nil)
        defer {
            captureWindow.orderOut(nil)
            captureWindow.contentView = nil
            captureWindow.close()
        }
        spin(0.2)
        captureHost.layoutSubtreeIfNeeded()
        let bounds = captureHost.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        captureHost.cacheDisplay(in: bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "picked-summary-\(URL(fileURLWithPath: path).lastPathComponent)"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Offscreen production summary at 2×") { $0.add(attachment) }
    }

    private func nativeKeyLoop() -> String {
        var current = panel.contentView
        var seen: Set<ObjectIdentifier> = []
        var lines: [String] = []
        while let view = current, seen.insert(ObjectIdentifier(view)).inserted, lines.count < 512 {
            lines.append("\(view) accepts=\(view.acceptsFirstResponder) canBecomeKey=\(view.canBecomeKeyView) hidden=\(view.isHiddenOrHasHiddenAncestor) next=\(String(describing: view.nextValidKeyView)) previous=\(String(describing: view.previousValidKeyView))")
            current = view.nextValidKeyView
        }
        return lines.joined(separator: "\n")
    }

    let panel: AtticPanel
    let host: AtticPanelHostingView
    let state: PanelUIState
    let notes: NoteStore
    let draft: NoteDraftController
    /// The shell's shared bars, handed in so a test reaches the keyboard
    /// state the real controls report.
    let sharedChrome = PanelSharedChrome()
    private let suite: String

    init(attachments: AttachmentFileStore, placement: Placement? = nil) throws {
        suite = "PanelSharedChromeKeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        _ = store.commit([TaskDraft(title: "Write launch notes", tags: ["launch"])])
        notes = NoteStore(container: container, attachmentFileStore: attachments)
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Launch plan")]), tags: ["launch"]).get()
        draft = NoteDraftController(noteStore: notes)
        // After every step that can throw, so a failed init leaves nothing on.
        AtticDraw.enabledOverride = true
        state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        settings.panelSurfaceStyle = .solid
        host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state, settings: settings,
                                     sharedChrome: sharedChrome),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        let origin: CGPoint
        // The macOS CI FKA trial runs the production shell in a display's
        // key window. A separate same-commit control deliberately retains
        // the original -6000 fixture so its AX exposure can be compared.
        let effectivePlacement = placement ?? (NSApp.isFullKeyboardAccessEnabled ? .onDisplay : .offscreen)
        switch effectivePlacement {
        case .offscreen:
            origin = CGPoint(x: -6_000, y: -6_000)
        case .onDisplay:
            let visible = try XCTUnwrap((NSScreen.main ?? NSScreen.screens.first)?.visibleFrame,
                                        "the on-display FKA control requires a display")
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        panel = AtticPanel(contentRect: CGRect(origin: origin, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        panel.makeKey()
        spin(0.8)
        Self.live.add(self)
        recordSnapshot("fixture mounted placement=\(effectivePlacement)")
    }

    func close() {
        if finalDiagnosticsRequested || NSApp.isFullKeyboardAccessEnabled {
            let attachment = XCTAttachment(string: focusDiagnostics())
            attachment.name = "BG-67 focus after native navigation"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Completed native Tab trace before closing") { $0.add(attachment) }
            finalDiagnosticsRequested = false
        }
        host.cancelActiveInteraction(reason: .lostWindow)
        state.releasePageContent()
        spin(0.3)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        AtticDraw.enabledOverride = nil
    }

    func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func go(to section: PanelSection) {
        state.switchPage(to: section, motion: .instant)
        spin(0.8)
        recordSnapshot("after page switch to \(section)")
    }

    func tab(shift: Bool = false) {
        if !hasStartedTabbing {
            hasStartedTabbing = true
            recordSnapshot("before first Tab")
        }
        let characters = shift ? "\u{19}" : "\t"
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: 48)!
            send(event)
        }
        spin(0.12)
        tabHistory.append("shift=\(shift) plusOwns=\(sharedChrome.plusHasKeyboard) hashOwns=\(sharedChrome.tagBar.keyFocused) summaryOwns=\(sharedChrome.tagBar.summaryHasKeyboard) summaryStop=\(String(describing: sharedChrome.tagBar.summaryFocus)) focused=\(focusedIdentifiers()) responder=\(responder) key=\(panel.isKeyWindow) AXFocus=\(focusedAXDescription())")
        recordSnapshot("after Tab settled shift=\(shift)")
    }

    func tabTo(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<32 {
            if focusedIdentifiers().contains(identifier) { break }
            tab()
        }
        XCTAssertTrue(focusedIdentifiers().contains(identifier), "Tab reaches \(identifier)", file: file, line: line)
    }

    func hideAndReveal() {
        panel.orderOut(nil)
        state.panelDidHide()
        spin(0.2)
        panel.orderFront(nil)
        panel.makeKey()
        state.panelDidReveal()
        spin(0.6)
        recordSnapshot("after hide/reveal")
        XCTAssertTrue(panel.isKeyWindow)
    }

    func press(_ characters: String, keyCode: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: keyCode)!
            send(event)
        }
        spin(0.15)
    }

    /// A key through `NSApp.sendEvent`, so the app's local monitors (the
    /// library's keys, the tag bar's) see it as they do a real key, then it
    /// goes on to the window.
    func appKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], settle: Bool = true) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: keyCode)!
            send(event)
        }
        if settle { spin(0.2) }
    }

    /// Runs the loop until `condition` holds, at most `seconds` (a release
    /// goes through a SwiftUI update and one queued turn, which a loaded
    /// machine delays).
    func wait(_ seconds: TimeInterval = 4, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { spin(0.05) }
    }

    /// A click at `point` (window coordinates, origin bottom left) through
    /// `NSApp.sendEvent`.
    func appClick(at point: CGPoint, settle: Bool = true) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            send(event)
        }
        if settle { spin(0.3) }
    }

    func elements(_ root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [root] }
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject, depth: depth + 1) }
    }

    private func send(_ event: NSEvent) {
        let isKey = event.type == .keyDown || event.type == .keyUp
        let eventName: String
        switch event.type {
        case .keyDown: eventName = "keyDown"
        case .keyUp: eventName = "keyUp"
        case .leftMouseDown: eventName = "leftMouseDown"
        case .leftMouseUp: eventName = "leftMouseUp"
        default: eventName = String(describing: event.type)
        }
        let key = isKey ? String(event.keyCode) : "mouse"
        inputTrace.append("input \(eventName) \(key) modifiers=\(event.modifierFlags.rawValue) chars=\(isKey ? String(describing: event.charactersIgnoringModifiers) : "n/a") dispatch=NSApp target=\(event.windowNumber) responderBefore=\(String(describing: panel.firstResponder)) fieldEditorBefore=\(String(describing: (panel.firstResponder as? NSTextView)?.delegate))")
        NSApp.sendEvent(event)
        recordSnapshot("after dispatch input \(eventName) \(key)")
    }

    func element(_ identifier: String) -> NSObject? {
        elements(host).first { $0.accessibilityIdentifier?() == identifier } as? NSObject
    }

    /// The accessibility identifiers of every element reporting keyboard focus.
    func focusedIdentifiers() -> [String] {
        let focused = NSAccessibility.Attribute(rawValue: "AXFocused")
        let systemFocused: AnyObject?
        if let value = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXFocusedUIElement")) {
            systemFocused = value as AnyObject
        } else { systemFocused = nil }
        return elements(host).compactMap { node -> String? in
            // SwiftUI can expose the actual focused node without implementing
            // the legacy per-node AXFocused attribute. Match that exact node.
            let reportsFocus = ((node as? NSObject)?.accessibilityAttributeValue(focused) as? Bool) == true
            guard node === systemFocused || reportsFocus else { return nil }
            let identifier: String? = node.accessibilityIdentifier?()
            return identifier ?? "(no id: \(type(of: node)))"
        }
    }

    var responder: String {
        guard let responder = panel.firstResponder else { return "nil" }
        return String(describing: responder)
    }
}

@MainActor
private final class SharedBarModel: ObservableObject {
    @Published var page: PanelPage
    @Published var revealCount: UInt64 = 0
    init(page: PanelPage) { self.page = page }
}

/// The shared bottom bar on its own, with the page and the reveal count the
/// shell would give it.
private struct SharedBarHarness: View {
    let chrome: PanelSharedChrome
    @ObservedObject var model: SharedBarModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            PanelSharedBottomBar(chrome: chrome, page: model.page,
                                 layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560)),
                                 revealCount: model.revealCount)
        }
        .frame(width: 340, height: 560)
        .atticDesign(.default)
    }
}

extension PanelSharedChromeTests {
    private func mountBar(_ chrome: PanelSharedChrome, _ model: SharedBarModel) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 340, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SharedBarHarness(chrome: chrome, model: model))
        window.orderFront(nil)
        spin(0.4)
        return window
    }

    private func mountKeyBar(_ chrome: PanelSharedChrome, _ model: SharedBarModel) throws -> AtticPanel {
        try requireKeyWindowTests()
        let panel = AtticPanel(contentRect: CGRect(x: -6000, y: -6000, width: 340, height: 560),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: SharedBarHarness(chrome: chrome, model: model))
        panel.orderFront(nil)
        panel.makeKey()
        spin(0.4)
        return panel
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func pressSpace(in window: NSWindow) throws {
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.sendEvent(space)
        spin(0.2)
    }

    /// BG-67's "reachable by keyboard when visible" and its limits (round 1
    /// review R-1, R-5): the shared "+" is a plain keyboard stop on a page
    /// AppKit's key loop walks, only while there is a "+" to press. Hidden
    /// by an open note, under the "+" card or under a task page it is no
    /// stop (opacity and hit testing never remove one), and Tasks' own Tab
    /// order owns its "+" before its bar registers and after it goes.
    func testTheSharedPlusIsAKeyboardStopOnlyWhileThereIsAPlusToPress() throws {
        for (page, plus) in [(PanelPage.calendar, PanelBottomBarLook.calendarPlus),
                             (PanelPage.notes, PanelBottomBarLook.notesPlus),
                             (PanelPage.canvas, PanelBottomBarLook.drawPlus)] {
            let chrome = PanelSharedChrome()
            let actions = PanelBottomBarActions(plus: {})
            chrome.setBar(PanelBottomBarLook(middle: .none, plus: plus), actions: actions, for: page)
            let window = mountBar(chrome, SharedBarModel(page: page))
            defer { close(window) }
            XCTAssertEqual(PanelKeyStopSeam.plus[page], true, "\(page): a visible shared plus is a plain keyboard stop")
            chrome.setBar(PanelBottomBarLook(middle: .none, plus: plus, shown: false), actions: actions, for: page)
            spin(0.3)
            XCTAssertEqual(PanelKeyStopSeam.plus[page], false, "\(page): the page draws its own plus (an open note)")
            chrome.setBar(PanelBottomBarLook(middle: .none, plus: plus), actions: actions, for: page)
            spin(0.3)
            XCTAssertEqual(PanelKeyStopSeam.plus[page], true, "\(page): back to a stop with the bar")
            chrome.plusHandedOver = true
            spin(0.3)
            XCTAssertEqual(PanelKeyStopSeam.plus[page], false, "\(page): the plus card has the bar's row")
            chrome.plusHandedOver = false
            spin(0.3)
            XCTAssertEqual(PanelKeyStopSeam.plus[page], true, "\(page): the card folded away")
            chrome.setCovered(true, page: page)
            spin(0.3)
            XCTAssertEqual(PanelKeyStopSeam.plus[page], false, "\(page): a task page covers the bar")
            chrome.setCovered(false, page: page)
            spin(0.3)
            XCTAssertEqual(PanelKeyStopSeam.plus[page], true, "\(page): the task page closed")
        }
        // Tasks orders Tab itself: no stop before its bar registers, none
        // once registered until its own Tab order asks, none after it goes.
        let chrome = PanelSharedChrome()
        let requests = AtticFocusRequests()
        let window = mountBar(chrome, SharedBarModel(page: .tasks))
        defer { close(window) }
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], false, "Tasks' plus is no stop before its bar registers")
        chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.tasksPlus),
                      actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], false, "Tasks' plus waits for its own Tab order")
        chrome.removeBar(for: .tasks)
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], false, "Tasks' plus is no stop after its bar goes")
    }

    /// Round 1 review R-6: BG-67's class (not focused on insertion, but
    /// reachable by navigation) holds for the "#" key too. On Notes it is a
    /// plain stop while the tag bar shows; hidden, it is none; on Tasks
    /// the page's own Tab order arms it.
    func testTheTagKeyIsAKeyboardStopOnNotesWhileTheBarShows() throws {
        func look(_ page: PanelPage, shown: Bool, prefix: String) -> PanelBottomBarLook {
            PanelBottomBarLook(middle: .tags(tags: ["launch"], picks: .none, idPrefix: prefix, shown: shown),
                               plus: page == .tasks ? PanelBottomBarLook.tasksPlus : PanelBottomBarLook.notesPlus, shown: shown)
        }
        let chrome = PanelSharedChrome()
        chrome.setBar(look(.notes, shown: true, prefix: "notes-tag-bar"), actions: PanelBottomBarActions(), for: .notes)
        let window = mountBar(chrome, SharedBarModel(page: .notes))
        defer { close(window) }
        XCTAssertEqual(PanelKeyStopSeam.tagKey["notes-tag-bar"], true, "Notes: the # key is a keyboard stop with the bar showing")
        chrome.setBar(look(.notes, shown: false, prefix: "notes-tag-bar"), actions: PanelBottomBarActions(), for: .notes)
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.tagKey["notes-tag-bar"], false, "Notes: no stop while an open note hides the bar")
        chrome.setBar(look(.notes, shown: true, prefix: "notes-tag-bar"), actions: PanelBottomBarActions(), for: .notes)
        chrome.plusHandedOver = true
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.tagKey["notes-tag-bar"], false, "Notes: no stop under the plus card")
        chrome.plusHandedOver = false
        let tasks = PanelSharedChrome()
        let requests = AtticFocusRequests()
        tasks.setBar(look(.tasks, shown: true, prefix: "tasks-tag-bar"), actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
        let tasksWindow = mountBar(tasks, SharedBarModel(page: .tasks))
        defer { close(tasksWindow) }
        XCTAssertEqual(PanelKeyStopSeam.tagKey["tasks-tag-bar"], false, "Tasks: the # key waits for the page's own Tab order")
    }

    /// Tasks arms its "+" through its own Tab order, then keeps it armed
    /// until the keyboard leaves it. The "+" is one view on every page, so
    /// the state must not outlive what armed it. (Without Full Keyboard
    /// Access a programmatic focus on this control cannot take, so the
    /// armed state itself, which the Tab order's request sets, is what
    /// these tests read.)
    private func armedTasksBar() -> (PanelSharedChrome, AtticFocusRequests, SharedBarModel, NSWindow) {
        let chrome = PanelSharedChrome()
        let requests = AtticFocusRequests()
        chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.tasksPlus),
                      actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
        chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.calendarPlus),
                      actions: PanelBottomBarActions(), for: .calendar)
        let model = SharedBarModel(page: .tasks)
        let window = mountBar(chrome, model)
        PanelKeyStopSeam.plus[.tasks] = nil
        requests.focus(PanelPlusFocusID())
        spin(0.3)
        return (chrome, requests, model, window)
    }

    /// Round 1 review R-2: a page switch drops the "+"'s arming, so back on
    /// Tasks it waits for the Tab order again, and on the other pages it is
    /// never carried over to press the new page's action.
    func testAPageSwitchDropsTheSharedPlusArming() throws {
        let (_, _, model, window) = armedTasksBar()
        defer { close(window) }
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], true, "Tasks' own Tab order armed its plus")
        model.page = .calendar
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.plus[.calendar], true, "Calendar's plus is a plain stop")
        model.page = .tasks
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], false, "back on Tasks the plus waits for its Tab order again")
    }

    /// Round 1 review R-2: a reveal never finds the "+" armed (never the
    /// initial key view).
    func testARevealDropsTheSharedPlusArming() throws {
        let (_, _, model, window) = armedTasksBar()
        defer { close(window) }
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], true, "Tasks' own Tab order armed its plus")
        model.revealCount += 1
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], false, "a reveal leaves the plus unarmed")
    }

    /// Round 1 review R-1: the "+" going out of reach (the "+" card has the
    /// row) drops its arming and takes no stop while it is gone.
    func testTheSharedPlusLosesItsArmingWhileTheCardHasTheRow() throws {
        let (chrome, _, _, window) = armedTasksBar()
        defer { close(window) }
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], true, "Tasks' own Tab order armed its plus")
        chrome.plusHandedOver = true
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], false, "no stop under the card")
        chrome.plusHandedOver = false
        spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.plus[.tasks], false, "the plus comes back unarmed")
    }

    /// Round 1 review R-2 with Full Keyboard Access (CI; the Air keeps the
    /// Mac's setting): the keyboard really on Tasks' "+", then a page
    /// switch. Space must not press Calendar's, and Tasks' Tab order must
    /// not still think it has the keyboard.
    func testAPageSwitchNeverLeavesTheKeyboardOnTheSharedPlusWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        let chrome = PanelSharedChrome()
        let requests = AtticFocusRequests()
        var taps: [PanelPage: Int] = [:]
        chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.tasksPlus),
                      actions: PanelBottomBarActions(plus: { taps[.tasks, default: 0] += 1 }, focusRequests: requests), for: .tasks)
        chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.calendarPlus),
                      actions: PanelBottomBarActions(plus: { taps[.calendar, default: 0] += 1 }), for: .calendar)
        let model = SharedBarModel(page: .tasks)
        let panel = try mountKeyBar(chrome, model)
        defer { close(panel) }
        XCTAssertTrue(panel.isKeyWindow, "the hosted shell must own keyboard input")
        requests.focus(PanelPlusFocusID())
        spin(0.4)
        XCTAssertEqual(requests.current, AnyHashable(PanelPlusFocusID()), "Tasks' own Tab order reached the plus")
        model.page = .calendar
        spin(0.4)
        XCTAssertNil(requests.current, "Tasks' page no longer has the keyboard on the plus")
        try pressSpace(in: panel)
        XCTAssertEqual(taps[.calendar] ?? 0, 0, "Space after the switch must not create an event")
        XCTAssertEqual(taps[.tasks] ?? 0, 0, "nor press Tasks' plus")
    }

    /// Round 1 review R-2 with Full Keyboard Access (CI): a reveal never
    /// leaves the keyboard on "+".
    func testARevealNeverLeavesTheKeyboardOnTheSharedPlusWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        let chrome = PanelSharedChrome()
        let requests = AtticFocusRequests()
        var taps = 0
        chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.tasksPlus),
                      actions: PanelBottomBarActions(plus: { taps += 1 }, focusRequests: requests), for: .tasks)
        let model = SharedBarModel(page: .tasks)
        let panel = try mountKeyBar(chrome, model)
        defer { close(panel) }
        XCTAssertTrue(panel.isKeyWindow, "the hosted shell must own keyboard input")
        requests.focus(PanelPlusFocusID())
        spin(0.4)
        XCTAssertEqual(requests.current, AnyHashable(PanelPlusFocusID()), "Tasks' own Tab order reached the plus")
        model.revealCount += 1
        spin(0.4)
        XCTAssertNil(requests.current, "a reveal leaves no keyboard on the plus")
        try pressSpace(in: panel)
        XCTAssertEqual(taps, 0, "Space after a reveal must not press the plus")
    }
}

extension PanelSharedChromeTests {
    /// BG-67 on the production host (round 1 review R-4): the real panel in
    /// an `AtticPanelHostingView` (AppKit's own key loop), the real Calendar,
    /// Notes and Draw pages, real Tab key events. Without Full Keyboard
    /// Access (the Air, which keeps the Mac's setting) the plus must be
    /// focusable (it was not on d3fcd6ed); with it (CI) Tab must reach the
    /// plus once, and Space must press it.
    func testBG67TheRealPanelsCalendarNotesAndDrawPlusAreKeyboardStops() throws {
        try requireKeyWindowTests()
        let focused = NSAccessibility.Attribute(rawValue: "AXFocused")
        let cases: [(PanelSection, PanelPage, PanelBottomBarLook.Plus)] = [
            (.calendar, .calendar, PanelBottomBarLook.calendarPlus), (.notes, .notes, PanelBottomBarLook.notesPlus),
            (.canvas, .canvas, PanelBottomBarLook.drawPlus)]
        for (section, page, plus) in cases {
            let shell = try RealShell(attachments: makeTestAttachmentFileStore())
            defer { shell.close() }
            shell.go(to: section)
            if page == .notes {
                XCTAssertTrue(shell.draft.pages.showLibrary())
                shell.spin(0.8)
            }
            XCTAssertTrue(shell.panel.isKeyWindow, "\(page): the hosted shell must own keyboard input")
            XCTAssertEqual(PanelKeyStopSeam.plus[page], true, "\(page): the shared plus is a keyboard stop")
            let node = shell.element(plus.identifier)
            // Keep the AX contract, while a failed lookup still lets the
            // native walk record the actual stops instead of aborting here.
            XCTAssertNotNil(node, "\(page): the shared plus must be an accessible control")
            if let node {
                XCTAssertTrue(node.accessibilityIsAttributeSettable(focused), "\(page): the shared plus must accept keyboard focus")
            }
            XCTAssertFalse(shell.focusedIdentifiers().contains(plus.identifier), "\(page): a reveal never lands on the plus")
            guard NSApp.isFullKeyboardAccessEnabled else { continue }
            // Full Keyboard Access (CI): AppKit's own Tab walk.
            let notesBefore = shell.notes.notes.count
            let canvasBefore = DrawPageModel.shared.canvasID
            var reached = false
            for _ in 0..<24 where !reached {
                shell.tab()
                reached = shell.focusedIdentifiers().contains(plus.identifier)
            }
            XCTAssertTrue(reached, "\(page): Tab reaches the shared plus")
            guard reached else { continue }
            shell.tab()
            XCTAssertFalse(shell.focusedIdentifiers().contains(plus.identifier), "\(page): the plus is one stop, not two")
            shell.tab(shift: true)
            XCTAssertTrue(shell.focusedIdentifiers().contains(plus.identifier), "\(page): Shift-Tab comes back to the plus")
            // The real shell gives pages the "+" card (`\.panelComposer`): on
            // Calendar and Notes the plus opens it instead of making the
            // thing itself.
            ComposerOverlay.isPresented = false
            shell.press(" ", keyCode: 49)
            switch page {
            case .calendar: XCTAssertTrue(ComposerOverlay.isPresented, "calendar: Space on the plus opens the new-event card")
            case .notes:
                XCTAssertTrue(ComposerOverlay.isPresented, "notes: Space on the plus opens the new-note card")
                XCTAssertEqual(shell.notes.notes.count, notesBefore, "notes: the card makes the note, not the key")
            case .canvas: XCTAssertNotEqual(DrawPageModel.shared.canvasID, canvasBefore, "draw: Space on the plus makes a canvas")
            case .tasks: break
            }
        }
    }
}

// MARK: - Round 2 N-2 (the plus releases its Tab order when its subtree is rebuilt)

extension PanelSharedChromeTests {
    /// Round 2 review N-2: `PanelFoldAccessibility` and the Draw page give
    /// the "+" a new subtree, so the old one goes without its `onChange`
    /// running. Tasks' Tab order, told the "+" had the keyboard, must hear
    /// that it no longer does. (Full Keyboard Access is off on the Air, so
    /// real focus cannot take: the Tab order's record is set the way the
    /// control sets it when it takes focus.)
    func testTheSharedPlusHandsTasksTabOrderBackWheneverItsSubtreeIsRebuilt() throws {
        for change in ["handover", "draw", "calendar"] {
            AtticDraw.enabledOverride = true
            let (chrome, requests, model, window) = armedTasksBar()
            defer { close(window) }
            requests.note(PanelPlusFocusID(), focused: true)
            PanelKeyStopSeam.plusFocusReports[.tasks]?(true)
            XCTAssertEqual(requests.current, AnyHashable(PanelPlusFocusID()), "\(change): Tasks' Tab order has the plus")
            switch change {
            case "handover": chrome.plusHandedOver = true
            case "draw": model.page = .canvas
            default: model.page = .calendar
            }
            spin(0.4)
            XCTAssertNil(requests.current, "\(change): the Tab order is told the plus no longer has the keyboard")
        }
    }

    /// The same with real focus (Full Keyboard Access, CI): the keyboard on
    /// Tasks' "+", then the card takes the row. Back on Tasks the Tab order
    /// must not still think it is on "+".
    func testTheCardTakingTheRowNeverLeavesTasksTabOrderOnThePlusWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        AtticDraw.enabledOverride = true
        defer { AtticDraw.enabledOverride = nil }
        for change in ["handover", "draw"] {
            let chrome = PanelSharedChrome()
            let requests = AtticFocusRequests()
            chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.tasksPlus),
                          actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
            let model = SharedBarModel(page: .tasks)
            let panel = try mountKeyBar(chrome, model)
            defer { close(panel) }
            requests.focus(PanelPlusFocusID())
            spin(0.4)
            XCTAssertEqual(requests.current, AnyHashable(PanelPlusFocusID()), "\(change): Tasks' own Tab order reached the plus")
            if change == "handover" { chrome.plusHandedOver = true } else { model.page = .canvas }
            spin(0.4)
            XCTAssertNil(requests.current, "\(change): the Tab order no longer has the plus")
        }
    }
}

// MARK: - Round 2 N-3 (the # key hands Tasks' Tab order back, as the plus does)

extension PanelSharedChromeTests {
    private func tagLook(_ page: PanelPage, picks: TagPicks = .none, shown: Bool = true) -> PanelBottomBarLook {
        let prefix = page == .tasks ? "tasks-tag-bar" : "notes-tag-bar"
        return PanelBottomBarLook(middle: .tags(tags: ["launch"], picks: picks, idPrefix: prefix, shown: shown),
                                  plus: page == .tasks ? PanelBottomBarLook.tasksPlus : PanelBottomBarLook.notesPlus, shown: shown)
    }

    /// Round 2 review N-3 (Dot R-3): Tasks' "#" has the keyboard, then the
    /// page switches to Notes. The shared "#" keeps its identity and its
    /// requests become nil, so the Tab order that was told "#" had the
    /// keyboard is the only one that can be told it left. (The record is set
    /// the way the control sets it when it takes focus; Full Keyboard Access
    /// is off on the Air.)
    func testTheTagKeyHandsTasksTabOrderBackWhenThePageSwitchesToNotes() throws {
        let chrome = PanelSharedChrome()
        let requests = AtticFocusRequests()
        chrome.setBar(tagLook(.tasks), actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
        chrome.setBar(tagLook(.notes), actions: PanelBottomBarActions(), for: .notes)
        let model = SharedBarModel(page: .tasks)
        let window = mountBar(chrome, model)
        defer { close(window) }
        requests.note(PanelTagKeyFocusID(), focused: true)
        chrome.tagBar.noteKeyFocus(true)
        XCTAssertEqual(requests.current, AnyHashable(PanelTagKeyFocusID()), "Tasks' Tab order has the # key")
        model.page = .notes
        spin(0.4)
        XCTAssertNil(requests.current, "the Tab order is told the # key left")
        XCTAssertFalse(chrome.tagBar.keyFocused, "and the bar no longer owns the keys")
    }

    /// The same with real focus (Full Keyboard Access, CI).
    func testTheTagKeyNeverLeavesTasksTabOrderOnItAfterThePageSwitchWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        let chrome = PanelSharedChrome()
        let requests = AtticFocusRequests()
        chrome.setBar(tagLook(.tasks), actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
        chrome.setBar(tagLook(.notes), actions: PanelBottomBarActions(), for: .notes)
        let model = SharedBarModel(page: .tasks)
        let panel = try mountKeyBar(chrome, model)
        defer { close(panel) }
        requests.focus(PanelTagKeyFocusID())
        spin(0.4)
        XCTAssertEqual(requests.current, AnyHashable(PanelTagKeyFocusID()), "Tasks' own Tab order reached the # key")
        model.page = .notes
        spin(0.4)
        XCTAssertNil(requests.current, "Tasks' Tab order no longer has the # key")
        XCTAssertFalse(chrome.tagBar.keyFocused, "the bar no longer owns the keys")
    }
}

// MARK: - Round 2 N-6 (Return on a focused plus creates through the plus)

extension PanelSharedChromeTests {
    private static let downArrow = "\u{F701}"

    private func notesLibraryShell(resolve: (@MainActor (RealShell) throws -> NotesLibraryModel)? = nil) throws -> (RealShell, NotesLibraryModel) {
        let shell = try RealShell(attachments: makeTestAttachmentFileStore())
        var handedOut = false
        defer { if !handedOut { shell.close() } }
        shell.go(to: .notes)
        XCTAssertTrue(shell.draft.pages.showLibrary())
        shell.spin(0.8)
        XCTAssertTrue(shell.panel.isKeyWindow, "the hosted shell must own keyboard input")
        let library: NotesLibraryModel
        if let resolve { library = try resolve(shell) }
        else {
            let live = shell.draft.pages.liveLibraryModel
            library = try XCTUnwrap(live, "All notes shows")
        }
        handedOut = true
        return (shell, library)
    }

    /// Round 2 review N-6 (Dot R-1): in All notes the library's local key
    /// monitor took Return before the focused "+" saw it and opened the
    /// highlighted (or first searched) note. The monitor now lets Return go
    /// while "+" holds the keyboard. The key is sent through
    /// `NSApp.sendEvent` so the monitor runs. (Full Keyboard Access is off on
    /// the Air, so "+" holds the keyboard the way its focus callback reports
    /// it; what the "+" then does is the CI test below.)
    func testReturnWhileThePlusHoldsTheKeyboardIsNotTheLibrarysOpen() throws {
        try requireKeyWindowTests()
        for searching in [false, true] {
            let (shell, library) = try notesLibraryShell()
            defer { shell.close() }
            if searching {
                library.query = "Launch"
                shell.wait { !library.groups(store: shell.notes, drafts: []).isEmpty }
                XCTAssertFalse(library.query.isEmpty)
                XCTAssertNil(library.highlightedID, "search supplies its first result without a highlight")
            } else {
                shell.appKey(Self.downArrow, keyCode: 125)
                XCTAssertNotNil(library.highlightedID, "a row is highlighted")
            }
            shell.sharedChrome.notePlusKeyboard(true)
            shell.appKey("\r", keyCode: 36)
            XCTAssertTrue(shell.draft.pages.isLibraryPresented, "Return on + never opens a highlighted or searched note")
            shell.sharedChrome.notePlusKeyboard(false)
            shell.appKey("\r", keyCode: 36)
            shell.wait { !shell.draft.pages.isLibraryPresented }
            XCTAssertFalse(shell.draft.pages.isLibraryPresented, "control: with the keyboard elsewhere Return opens it")
        }
    }

    /// Return and Space on the Notes "+" both open the new-note card, with a
    /// row highlighted and with a search (Full Keyboard Access, CI).
    func testReturnAndSpaceOnTheNotesPlusBothOpenTheCardWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        for searching in [false, true] {
            for key in [("\r", UInt16(36)), (" ", UInt16(49)), ("\u{3}", UInt16(76))] {
                let (shell, library) = try notesLibraryShell()
                defer { shell.close() }
                let notesBefore = shell.notes.notes.count
                if searching {
                    library.query = "Launch"
                    shell.wait { !library.groups(store: shell.notes, drafts: []).isEmpty }
                    XCTAssertFalse(library.query.isEmpty)
                    XCTAssertNil(library.highlightedID)
                } else {
                    shell.appKey(Self.downArrow, keyCode: 125)
                    XCTAssertNotNil(library.highlightedID, "a row is highlighted")
                }
                var reached = false
                for _ in 0..<24 where !reached {
                    shell.tab()
                    reached = shell.focusedIdentifiers().contains(PanelBottomBarLook.notesPlus.identifier)
                }
                XCTAssertTrue(reached, "Tab reaches the plus")
                guard reached else { continue }
                ComposerOverlay.isPresented = false
                shell.appKey(key.0, keyCode: key.1)
                XCTAssertTrue(ComposerOverlay.isPresented, "\(key.1): the plus opens the new-note card")
                XCTAssertEqual(shell.notes.notes.count, notesBefore, "\(key.1): the card makes the note, not the key")
                XCTAssertTrue(shell.draft.pages.isLibraryPresented, "\(key.1): the highlighted note stays closed")
            }
        }
    }
}

// MARK: - Round 2 R-2 (a reveal reaches the shared controls)

extension PanelSharedChromeTests {
    /// Dot R-2: the shell's selective observer never subscribed to
    /// `revealCount`, so on the production shell a retained panel that hid
    /// and came back without another observed change never told the "+"
    /// (nor closed the tag bar). Hidden and revealed with the page and size
    /// unchanged, the keyboard must be released. (The Air keeps Full
    /// Keyboard Access off, so the "+" holds the keyboard the way its focus
    /// callback reports it.)
    func testARevealOfTheRetainedPanelReleasesTheSharedPlusOnTheRealShell() throws {
        try requireKeyWindowTests()
        for page in [PanelSection.calendar, .notes] {
            let shell = try RealShell(attachments: makeTestAttachmentFileStore())
            defer { shell.close() }
            shell.go(to: page)
            if page == .notes {
                XCTAssertTrue(shell.draft.pages.showLibrary())
                shell.spin(0.8)
            }
            let plus = page == .notes ? PanelBottomBarLook.notesPlus : PanelBottomBarLook.calendarPlus
            if NSApp.isFullKeyboardAccessEnabled {
                shell.tabTo(plus.identifier)
                XCTAssertTrue(shell.sharedChrome.plusHasKeyboard)
            } else {
                let report = try XCTUnwrap(PanelKeyStopSeam.plusFocusReports[PanelPage(page)])
                report(true)
            }
            let size = shell.state.panelSize
            shell.hideAndReveal()
            XCTAssertEqual(shell.state.selectedSection, page)
            XCTAssertEqual(shell.state.panelSize, size)
            shell.wait { !shell.sharedChrome.plusHasKeyboard }
            XCTAssertFalse(shell.sharedChrome.plusHasKeyboard, "\(page): a reveal never leaves the keyboard on the plus")
            XCTAssertFalse(shell.focusedIdentifiers().contains(plus.identifier))
            ComposerOverlay.isPresented = false
            shell.appKey(" ", keyCode: 49)
            XCTAssertFalse(ComposerOverlay.isPresented, "Space after the reveal cannot press the old plus")
        }
    }
}

// MARK: - Round 2 N-4 (a # that holds the keyboard on Notes never leaves the library's keys dead)

extension PanelSharedChromeTests {
    /// Round 2 review N-4: the keyboard on "#" (Tab) stops the library's
    /// arrows, Return, ⌘F and type-to-search (`PanelTagBarState.ownsKeys`).
    /// Nothing but Tab gave it back. A click in the library (rows are no
    /// focus targets), the panel's reveal and `close()` now do. (Full
    /// Keyboard Access is off on the Air, so the keyboard reaches "#" the
    /// way its focus callback reports it.)
    func testAHashKeyHoldingTheKeyboardOnNotesNeverLeavesTheLibraryKeysDead() throws {
        try requireKeyWindowTests()
        for how in ["a click in the library", "a hide and a reveal", "the bar closing"] {
            let (shell, library) = try notesLibraryShell()
            defer { shell.close() }
            shell.sharedChrome.tagBar.noteKeyFocus(true)
            XCTAssertTrue(PanelTagBarState.ownsKeys, "\(how): # has the keyboard")
            shell.appKey(Self.downArrow, keyCode: 125)
            XCTAssertNil(library.highlightedID, "\(how): while # holds the keys, the arrows wait")
            switch how {
            case "a click in the library": shell.appClick(at: CGPoint(x: 170, y: 250))
            case "a hide and a reveal": shell.hideAndReveal()
            default:
                shell.sharedChrome.tagBar.close()
                shell.spin(0.4)
            }
            shell.wait { !shell.sharedChrome.tagBar.keyFocused }
            XCTAssertFalse(shell.sharedChrome.tagBar.keyFocused, "\(how): # gave the keyboard up")
            shell.appKey(Self.downArrow, keyCode: 125)
            shell.wait { library.highlightedID != nil }
            XCTAssertNotNil(library.highlightedID, "\(how): the arrows move the library highlight")
        }
    }

    /// The same with the real Tab walk (Full Keyboard Access, CI).
    func testTabbingToTheHashKeyThenClickingTheLibraryNeverLeavesItsKeysDeadWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        for how in ["a click in the library", "beside the collapsed bar", "a row click", "a hide and a reveal", "the bar closing"] {
            let (shell, library) = try notesLibraryShell()
            defer { shell.close() }
            shell.tabTo("notes-tag-bar-key")
            XCTAssertTrue(PanelTagBarState.ownsKeys, "\(how): # holds the keyboard")
            switch how {
            case "a click in the library": shell.appClick(at: CGPoint(x: 170, y: 250))
            case "beside the collapsed bar": try clickBesideTheCollapsedTagBar(shell)
            case "a row click":
                let row = try XCTUnwrap(shell.elements(shell.host).first { $0.accessibilityIdentifier?() == "notes-library-row" })
                let frame = try XCTUnwrap(row.accessibilityFrame?())
                XCTAssertGreaterThan(frame.width, 0)
                shell.appClick(at: shell.panel.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY)))
                // A row opens its note (Accepted). Return to All notes
                // before asking its arrows to move; do not change that action.
                shell.wait { !shell.draft.pages.isLibraryPresented }
                XCTAssertFalse(shell.draft.pages.isLibraryPresented, "the row click opened the note")
                XCTAssertTrue(shell.draft.pages.showLibrary())
                shell.spin(0.8)
            case "a hide and a reveal": shell.hideAndReveal()
            default: shell.sharedChrome.tagBar.close()
            }
            shell.wait { !shell.sharedChrome.tagBar.keyFocused }
            XCTAssertFalse(PanelTagBarState.ownsKeys, "\(how): # gave up the keys")
            let currentLibrary = try XCTUnwrap(shell.draft.pages.liveLibraryModel)
            let before = currentLibrary.highlightedID
            shell.appKey(Self.downArrow, keyCode: 125)
            shell.wait { currentLibrary.highlightedID != before }
            XCTAssertNotEqual(currentLibrary.highlightedID, before, "\(how): the arrows move the library highlight")
        }
    }
}

// MARK: - Round 2 N-7 (a queued handoff checks again when it runs)

extension PanelSharedChromeTests {
    /// Round 2 review N-7 (Dot R-4): the focus handoff is queued one turn
    /// after the request. A page switch or the card taking the row in
    /// between releases the "+", and the old closure must not give the
    /// control the keyboard again (on Calendar or Notes it is a plain stop,
    /// where Space would press the new page's action). The test holds the
    /// queued closures and drains them after the release.
    func testAQueuedPlusHandoffNeverOutlivesTheReleaseThatCameBetween() throws {
        for change in ["a page switch", "the card taking the row"] {
            let chrome = PanelSharedChrome()
            let requests = AtticFocusRequests()
            chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.tasksPlus),
                          actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
            chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.calendarPlus),
                          actions: PanelBottomBarActions(), for: .calendar)
            let model = SharedBarModel(page: .tasks)
            let window: NSWindow = NSApp.isFullKeyboardAccessEnabled ? try mountKeyBar(chrome, model) : mountBar(chrome, model)
            defer { close(window) }
            PanelKeyStopSeam.holdsHandoffs = true
            PanelKeyStopSeam.held = []
            PanelKeyStopSeam.plusAssignments = 0
            requests.focus(PanelPlusFocusID())
            XCTAssertEqual(PanelKeyStopSeam.held.count, 1, "\(change): the request queued its handoff")
            if change == "a page switch" { model.page = .calendar } else { chrome.plusHandedOver = true }
            spin(0.4)
            let held = PanelKeyStopSeam.held
            PanelKeyStopSeam.held = []
            for run in held { run() }
            spin(0.2)
            XCTAssertFalse(chrome.plusHasKeyboard)
            XCTAssertEqual(PanelKeyStopSeam.plusAssignments, 0, "\(change): the old handoff must not take the keyboard")
        }
    }

    /// The same for "#" (a release between the request and the handoff).
    func testAQueuedTagKeyHandoffNeverOutlivesTheReleaseThatCameBetween() throws {
        let chrome = PanelSharedChrome()
        let requests = AtticFocusRequests()
        chrome.setBar(tagLook(.tasks), actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
        chrome.setBar(tagLook(.notes), actions: PanelBottomBarActions(), for: .notes)
        let model = SharedBarModel(page: .tasks)
        let window: NSWindow = NSApp.isFullKeyboardAccessEnabled ? try mountKeyBar(chrome, model) : mountBar(chrome, model)
        defer { close(window) }
        PanelKeyStopSeam.holdsHandoffs = true
        PanelKeyStopSeam.held = []
        PanelKeyStopSeam.tagKeyAssignments = 0
        requests.focus(PanelTagKeyFocusID())
        XCTAssertEqual(PanelKeyStopSeam.held.count, 1, "the request queued its handoff")
        model.page = .notes
        spin(0.4)
        let held = PanelKeyStopSeam.held
        PanelKeyStopSeam.held = []
        for run in held { run() }
        spin(0.2)
        XCTAssertFalse(chrome.tagBar.keyFocused)
        XCTAssertEqual(PanelKeyStopSeam.tagKeyAssignments, 0, "the old handoff must not take the keyboard")
    }
}

// MARK: - Round 2 N-5 (the picked-tags summary is no extra stop)

extension PanelSharedChromeTests {
    /// Round 2 review N-5: with tags picked the collapsed bar shows a summary
    /// whose two native buttons are the stops. The summary's container wears
    /// the same key-stop modifier as "#", so on Notes it became a third stop
    /// around them. One stop per control: it is none, and "#" (no picks) is
    /// still one.
    func testThePickedTagsSummaryIsNoKeyboardStopAroundItsTwoButtonsOnNotes() throws {
        let chrome = PanelSharedChrome()
        chrome.setBar(tagLook(.notes, picks: TagPicks(["launch"])), actions: PanelBottomBarActions(), for: .notes)
        let window = mountBar(chrome, SharedBarModel(page: .notes))
        defer { close(window) }
        XCTAssertEqual(PanelKeyStopSeam.tagKey["notes-tag-bar"], false, "the summary's container is no stop; its two buttons are")
        chrome.setBar(tagLook(.notes), actions: PanelBottomBarActions(), for: .notes)
        spin(0.4)
        XCTAssertEqual(PanelKeyStopSeam.tagKey["notes-tag-bar"], true, "without picks # is the one stop")
    }

    /// The stops across the summary (Full Keyboard Access, CI): its two
    /// buttons, and nothing around them.
    func testTabbingAcrossThePickedTagsSummaryVisitsOnlyItsTwoButtonsWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        let (shell, library) = try notesLibraryShell()
        defer { shell.close() }
        library.tagPicks = TagPicks(["launch"])
        shell.spin(0.8)
        var visited: [[String]] = []
        for _ in 0..<24 {
            shell.tab()
            visited.append(shell.focusedIdentifiers())
            XCTAssertFalse(shell.sharedChrome.tagBar.keyFocused, "the summary container must never own a Tab stop, even without an AX identifier")
        }
        let flat = Set(visited.flatMap { $0 })
        XCTAssertTrue(flat.contains("notes-tag-bar-picked"), "Tab reaches the summary's picked button")
        XCTAssertTrue(flat.contains("notes-tag-bar-clear"), "and its clear button")
        XCTAssertFalse(flat.contains("notes-tag-bar"), "the summary's container is not a stop")
    }
}


extension PanelSharedChromeTests {
    /// Closing the bar must beat a request whose next-turn focus handoff
    /// has not run yet. No native FKA focus is needed to observe the stale
    /// assignment itself; CI additionally observes native focus below.
    func testClosingTheTagBarCancelsItsQueuedKeyboardHandoff() throws {
        let chrome = PanelSharedChrome()
        chrome.setBar(tagLook(.notes), actions: PanelBottomBarActions(), for: .notes)
        let model = SharedBarModel(page: .notes)
        let window: NSWindow = NSApp.isFullKeyboardAccessEnabled ? try mountKeyBar(chrome, model) : mountBar(chrome, model)
        defer { close(window) }
        PanelKeyStopSeam.holdsHandoffs = true
        PanelKeyStopSeam.tagKeyAssignments = 0
        chrome.tagBar.requestKeyFocus()
        spin(0.2)
        XCTAssertEqual(PanelKeyStopSeam.held.count, 1, "the request is queued before native focus takes")
        chrome.tagBar.close()
        spin(0.2)
        let held = PanelKeyStopSeam.held
        PanelKeyStopSeam.held = []
        held.forEach { $0() }
        spin(0.2)
        XCTAssertEqual(PanelKeyStopSeam.tagKeyAssignments, 0, "close wins over the queued request")
        XCTAssertFalse(chrome.tagBar.keyFocused)
    }
}


extension PanelSharedChromeTests {
    private func clickBesideTheCollapsedTagBar(_ shell: RealShell) throws {
        XCTAssertFalse(shell.sharedChrome.tagBar.isOpen, "the bar is collapsed to its # key")
        let key = try XCTUnwrap(shell.elements(shell.host).first { $0.accessibilityIdentifier?() == "notes-tag-bar-key" })
        let frame = try XCTUnwrap(key.accessibilityFrame?())
        XCTAssertGreaterThan(frame.width, 0)
        let point = CGPoint(x: frame.maxX + 20, y: frame.midY)
        XCTAssertFalse(frame.contains(point), "the click is outside the visible bar")
        let plus = try XCTUnwrap(shell.elements(shell.host).first { $0.accessibilityIdentifier?() == "notes-new-note" })
        let plusFrame = try XCTUnwrap(plus.accessibilityFrame?())
        XCTAssertLessThan(point.x, plusFrame.minX, "the gap click must not activate +")
        XCTAssertTrue(shell.panel.frame.contains(point), "the gap is inside the panel")
        shell.appClick(at: shell.panel.convertPoint(fromScreen: point))
    }

    /// The bar expands its outer frame to fill the row, but the empty gap
    /// beside its collapsed card is panel space. Its local click monitor
    /// must measure the card, or this click leaves the library keys dead.
    func testClickingTheSpaceBesideTheCollapsedTagBarReleasesTheLibraryKeyboard() throws {
        try requireKeyWindowTests()
        let (shell, library) = try notesLibraryShell()
        defer { shell.close() }
        shell.sharedChrome.tagBar.noteKeyFocus(true)
        shell.appKey(Self.downArrow, keyCode: 125)
        XCTAssertNil(library.highlightedID, "control: # owns the library keys")
        try clickBesideTheCollapsedTagBar(shell)
        shell.wait { !shell.sharedChrome.tagBar.keyFocused }
        XCTAssertFalse(shell.sharedChrome.tagBar.keyFocused, "a click beside the visible bar releases #")
        shell.appKey(Self.downArrow, keyCode: 125)
        XCTAssertNotNil(library.highlightedID, "the library's arrows work after clicking the empty gap")
    }
}


extension PanelSharedChromeTests {
    func testBG67TheAXObserverFindsTheRealControlsWithCIEnhancedUIOff() throws {
        try requireKeyWindowTests()
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(false, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let shell = try RealShell(attachments: makeTestAttachmentFileStore())
        defer { shell.close() }
        for (section, identifier) in [(PanelSection.calendar, "calendar-new-task"), (.notes, "notes-new-note"), (.canvas, "draw-new-canvas")] {
            shell.go(to: section)
            if section == .notes { XCTAssertTrue(shell.draft.pages.showLibrary()); shell.spin(0.8) }
            XCTAssertNotNil(shell.element(identifier), "\(section): the observer sees the visible real control")
        }
    }
}


extension PanelSharedChromeTests {
    func testR3TheTabDriverUsesTheApplicationsKeyboardPath() throws {
        try requireKeyWindowTests()
        // Tasks has its own tracker and can consume Tab before the shell's
        // tracker sees it. Its native focus still exercises the AX reader.
        do {
            let shell = try RealShell(attachments: makeTestAttachmentFileStore())
            defer { shell.close() }
            shell.requestFinalDiagnostics()
            shell.tab()
            let focusedValue = try XCTUnwrap(NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXFocusedUIElement")))
            let systemFocused = focusedValue as AnyObject
            XCTAssertTrue(elements(shell.host).contains { $0 === systemFocused }, "the system's focused element is inside the real shell")
            let identifier: String? = systemFocused.accessibilityIdentifier?()
            let expected = identifier ?? "(no id: \(type(of: systemFocused)))"
            XCTAssertTrue(shell.focusedIdentifiers().contains(expected), "the focus reader must report the system's actually focused native element")
        }

        let shell = try RealShell(attachments: makeTestAttachmentFileStore())
        defer { shell.close() }
        shell.go(to: .calendar)
        XCTAssertTrue(shell.state.keyboardFocus.isTracking)
        XCTAssertFalse(shell.state.keyboardFocus.isKeyboardDriving)
        shell.requestFinalDiagnostics()
        var applicationEvents: [NSEvent.EventType] = []
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.window === shell.panel, event.keyCode == 48 { applicationEvents.append(event.type) }
            return event
        })
        defer { NSEvent.removeMonitor(monitor) }
        // Negative control: direct window dispatch bypasses the application.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shell.panel.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            shell.panel.sendEvent(event)
        }
        XCTAssertTrue(applicationEvents.isEmpty, "the probe distinguishes direct window dispatch")
        shell.tab()
        XCTAssertEqual(applicationEvents, [.keyDown, .keyUp], "the driver sends both native events through the application")
        XCTAssertTrue(shell.state.keyboardFocus.isKeyboardDriving, "real Tab must traverse application monitors before the native key loop")
    }
}


extension PanelSharedChromeTests {
    func testR3AnUnfocusedPlusDisappearingNeverClearsTheNewPlusOwnership() throws {
        for oldHadFocus in [false, true] {
            let chrome = PanelSharedChrome()
            let requests = AtticFocusRequests()
            chrome.setBar(PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.tasksPlus),
                          actions: PanelBottomBarActions(focusRequests: requests), for: .tasks)
            let old = mountBar(chrome, SharedBarModel(page: .tasks))
            let oldReport = try XCTUnwrap(PanelKeyStopSeam.plusFocusReports[.tasks])
            if oldHadFocus { oldReport(true) }
            let new = mountBar(chrome, SharedBarModel(page: .tasks))
            defer { close(new) }
            let newReport = try XCTUnwrap(PanelKeyStopSeam.plusFocusReports[.tasks])
            newReport(true)
            XCTAssertTrue(chrome.plusHasKeyboard)
            XCTAssertEqual(requests.current, AnyHashable(PanelPlusFocusID()))
            // A late loss callback, or disappearance without ever having focus,
            // must not release the other physical control's acquired ownership.
            if oldHadFocus { oldReport(false) }
            close(old)
            XCTAssertTrue(chrome.plusHasKeyboard, "the old instance cannot release the new owner")
            XCTAssertEqual(requests.current, AnyHashable(PanelPlusFocusID()))
        }
    }
}


extension PanelSharedChromeTests {
    func testR3RevealAddsNoShellBodyPass() throws {
        try requireKeyWindowTests()
        let shell = try RealShell(attachments: makeTestAttachmentFileStore())
        defer { PanelInvalidationProbe.shell = nil; shell.close() }
        shell.go(to: .calendar)
        var passes = 0
        PanelInvalidationProbe.shell = { passes += 1 }
        shell.state.panelDidReveal()
        shell.spin(0.6)
        XCTAssertEqual(passes, 0, "an idle reveal releases controls without rebuilding the retained shell")
    }
}


extension PanelSharedChromeTests {
    func testR3ThePlusAcceptsKeypadEnterAsWellAsReturnAndSpace() throws {
        let chrome = PanelSharedChrome()
        let window = mountBar(chrome, SharedBarModel(page: .notes))
        defer { close(window) }
        XCTAssertTrue(PanelKeyStopSeam.plusActivationKeys.contains(KeyEquivalent(Character("\u{3}"))), "keypad Enter is an activation key")
        XCTAssertTrue(PanelKeyStopSeam.plusActivationKeys.contains(.return))
        XCTAssertTrue(PanelKeyStopSeam.plusActivationKeys.contains(.space))
    }
}


extension PanelSharedChromeTests {
    func testR3AThrowWhileResolvingTheLibraryClosesItsKeyShell() throws {
        try requireKeyWindowTests()
        enum Injected: Error { case failure }
        weak var panel: AtticPanel?
        var resolverEntered = false
        XCTAssertThrowsError(try notesLibraryShell { shell in
            resolverEntered = true
            panel = shell.panel
            throw Injected.failure
        }) { error in XCTAssertTrue(error is Injected) }
        XCTAssertTrue(resolverEntered, "the injected failure occurred after the key shell was created")
        // Diagnostic callback captures must not be the reason a window survives.
        PanelKeyStopSeam.plusFocusReports = [:]
        spin(0.4)
        XCTAssertFalse(panel?.isVisible == true, "throwing setup must close the panel before the caller can install a defer")
        XCTAssertFalse(panel?.isKeyWindow == true)
        panel?.orderOut(nil) // red-run cleanup only, after the oracle
        panel?.contentView = nil
        panel?.close()
    }
}


extension PanelSharedChromeTests {
    func testR3TheNewestTagKeyboardIntentWinsWhenSwiftUICoalescesChanges() throws {
        for releaseLast in [false, true] {
            let chrome = PanelSharedChrome()
            chrome.setBar(tagLook(.notes), actions: PanelBottomBarActions(), for: .notes)
            let window = mountBar(chrome, SharedBarModel(page: .notes))
            defer { close(window) }
            PanelKeyStopSeam.holdsHandoffs = true
            PanelKeyStopSeam.held = []
            PanelKeyStopSeam.tagKeyAssignments = 0
            if releaseLast {
                chrome.tagBar.requestKeyFocus()
                chrome.tagBar.releaseKeyFocus()
            } else {
                chrome.tagBar.releaseKeyFocus()
                chrome.tagBar.open(cursor: .tag("launch"))
                chrome.tagBar.requestKeyFocus()
            }
            spin(0.3)
            let held = PanelKeyStopSeam.held
            PanelKeyStopSeam.held = []
            held.forEach { $0() }
            spin(0.2)
            XCTAssertEqual(PanelKeyStopSeam.tagKeyAssignments, releaseLast ? 0 : 1, "the last source action wins")
            if !releaseLast { XCTAssertEqual(chrome.tagBar.cursor, .tag("launch")) }
        }
    }
}


extension PanelSharedChromeTests {
    func testR3AnOutsideClickCancelsAClosedHashKeysPendingHandoff() throws {
        try requireKeyWindowTests()
        let (shell, library) = try notesLibraryShell()
        defer { shell.close() }
        PanelKeyStopSeam.holdsHandoffs = true
        PanelKeyStopSeam.tagKeyAssignments = 0
        // Toggle twice without releasing the intended keyboard: the real shortcut route.
        shell.appKey("t", keyCode: 17, modifiers: [.option, .command])
        shell.appKey("t", keyCode: 17, modifiers: [.option, .command])
        XCTAssertFalse(shell.sharedChrome.tagBar.isOpen)
        XCTAssertFalse(shell.sharedChrome.tagBar.keyFocused)
        XCTAssertFalse(PanelKeyStopSeam.held.isEmpty)
        shell.appClick(at: CGPoint(x: 170, y: 250))
        let held = PanelKeyStopSeam.held
        PanelKeyStopSeam.held = []
        held.forEach { $0() }
        shell.spin(0.3)
        XCTAssertEqual(PanelKeyStopSeam.tagKeyAssignments, 0, "outside click cancels focus that has not landed")
        XCTAssertFalse(shell.sharedChrome.tagBar.hasKeyboard)
        shell.appKey(Self.downArrow, keyCode: 125)
        XCTAssertNotNil(library.highlightedID)
    }
}


extension PanelSharedChromeTests {
    func testR3PickedSummaryReturnNeverOpensTheHighlightedOrSearchedNote() throws {
        try requireKeyWindowTests()
        for searching in [false, true] {
            let (shell, library) = try notesLibraryShell()
            defer { shell.close() }
            library.tagPicks = TagPicks(["launch"])
            if searching {
                library.query = "Launch"
                shell.wait { !library.groups(store: shell.notes, drafts: []).isEmpty }
                XCTAssertNil(library.highlightedID)
            } else {
                shell.appKey(Self.downArrow, keyCode: 125)
                XCTAssertNotNil(library.highlightedID)
            }
            shell.spin(0.5)
            for id in ["notes-tag-bar-picked", "notes-tag-bar-clear"] {
                let node = try XCTUnwrap(shell.element(id))
                let object: AnyObject = node
                XCTAssertEqual(object.accessibilityRole?(), .button)
                if NSApp.isFullKeyboardAccessEnabled {
                    XCTAssertTrue(node.accessibilityIsAttributeSettable(NSAccessibility.Attribute(rawValue: "AXFocused")))
                }
            }
            // Report the native buttons' focus callback, as the plus seam does.
            shell.sharedChrome.tagBar.noteSummaryKeyboard(true)
            shell.state.keyboardFocus.noteKeyboardNavigation()
            shell.spin(0.3)
            if !searching { try shell.writeFocusRenderIfRequested() }
            XCTAssertEqual(PanelKeyStopSeam.summaryFocusRings["notes-tag-bar-picked"], true, "the picked button draws its focus ring")
            XCTAssertEqual(PanelKeyStopSeam.summaryFocusRings["notes-tag-bar-clear"], false, "only the focused button draws a ring")
            shell.appKey("\r", keyCode: 36)
            XCTAssertTrue(shell.draft.pages.isLibraryPresented, "Return belongs to the focused summary button")
            shell.sharedChrome.tagBar.noteSummaryKeyboard(false)
            shell.appKey("\r", keyCode: 36)
            shell.wait { !shell.draft.pages.isLibraryPresented }
            XCTAssertFalse(shell.draft.pages.isLibraryPresented, "control: the library still opens a note when summary focus is released")
        }
    }
}


extension PanelSharedChromeTests {
    func testR3ThePickedSummaryButtonsShowFocusAndOwnReturnAndSpaceWithFullKeyboardAccess() throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs Full Keyboard Access (CI)") }
        for identifier in ["notes-tag-bar-picked", "notes-tag-bar-clear"] {
            for key in [("\r", UInt16(36)), (" ", UInt16(49))] {
                for searching in [false, true] {
                    let (shell, library) = try notesLibraryShell()
                    defer { shell.close() }
                    library.tagPicks = TagPicks(["launch"])
                    if searching { library.query = "Launch" } else { shell.appKey(Self.downArrow, keyCode: 125) }
                    shell.spin(0.4)
                    shell.tabTo(identifier)
                    XCTAssertTrue(shell.sharedChrome.tagBar.summaryHasKeyboard, "the native summary button owns activation")
                    XCTAssertEqual(PanelKeyStopSeam.summaryFocusRings[identifier], true)
                    let other = identifier.hasSuffix("picked") ? "notes-tag-bar-clear" : "notes-tag-bar-picked"
                    XCTAssertEqual(PanelKeyStopSeam.summaryFocusRings[other], false)
                    shell.appKey(key.0, keyCode: key.1)
                    XCTAssertTrue(shell.draft.pages.isLibraryPresented, "the highlighted or searched note stays closed")
                    if identifier.hasSuffix("picked") { XCTAssertTrue(shell.sharedChrome.tagBar.isOpen) }
                    else { XCTAssertTrue(library.tagPicks.isEmpty) }
                }
            }
        }
    }
}


extension PanelSharedChromeTests {
    func testR3ClickingANotesRowReleasesThePlusAndReturnKeepsTheNoteOpen() throws {
        try requireKeyWindowTests()
        let (shell, library) = try notesLibraryShell()
        defer { shell.close() }
        _ = try shell.notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Another launch note")]), tags: ["launch"]).get()
        shell.spin(0.5)
        let rows = library.groups(store: shell.notes, drafts: []).flatMap(\.rows)
        XCTAssertEqual(rows.count, 2)
        let clickedID = try XCTUnwrap(rows.first?.id)
        shell.appKey(Self.downArrow, keyCode: 125)
        shell.appKey(Self.downArrow, keyCode: 125)
        XCTAssertNotEqual(library.highlightedID, clickedID, "the keyboard highlights a different note before the row click")
        XCTAssertNotNil(library.highlightedID)
        if NSApp.isFullKeyboardAccessEnabled { shell.tabTo("notes-new-note") }
        else {
            let report = try XCTUnwrap(PanelKeyStopSeam.plusFocusReports[.notes])
            report(true)
        }
        let row = try XCTUnwrap(shell.element("notes-library-row"))
        let object: AnyObject = row
        let frame = try XCTUnwrap(object.accessibilityFrame?())
        XCTAssertGreaterThan(frame.width, 0)
        let point = shell.panel.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(shell.panel.contentView!.bounds.contains(point))
        // No view-update turn between the actual click and Return: neither
        // a delayed registration nor a focus dump can hide stale ownership.
        shell.appClick(at: point, settle: false)
        let released = !shell.sharedChrome.plusHasKeyboard
        ComposerOverlay.isPresented = false
        shell.appKey("\r", keyCode: 36, settle: false)
        shell.wait { !shell.draft.pages.isLibraryPresented }
        XCTAssertFalse(shell.draft.pages.isLibraryPresented, "the click opened the chosen note")
        shell.spin(0.5)
        XCTAssertEqual(shell.draft.pages.active?.noteID, clickedID, "Return cannot replace the clicked note with the highlighted one while the first frame is pending")
        XCTAssertTrue(released, "the row click releases + before another key can act")
        XCTAssertFalse(ComposerOverlay.isPresented, "Return stays with the clicked note")
    }
}

// MARK: - Round 4: native focus evidence must survive failures

extension PanelSharedChromeTests {
    func testR4NativeFocusTraceRecordsBothSidesOfEveryInput() throws {
        try requireKeyWindowTests()
        let shell = try RealShell(attachments: makeTestAttachmentFileStore())
        defer { shell.close() }
        shell.tab()
        shell.appKey("\r", keyCode: 36)
        let trace = shell.focusDiagnostics()
        for required in ["before first Tab", "input keyDown 48", "input keyUp 48",
                         "input keyDown 36", "input keyUp 36", "after dispatch",
                         "environment:", "product:", "host AX tree:", "window AX tree:",
                         "system AX focus:", "native key loop:", "focus callbacks:"] {
            XCTAssertTrue(trace.contains(required), "native evidence missing: \(required)")
        }
    }

    /// Same product code and CI machine, changing only the fixture's screen
    /// placement. The offscreen result is evidence, not a prescribed pass;
    /// the on-display button is required to exist before sending any Tab.
    func testR4OffscreenAndOnDisplayExposeTheSameCalendarAXControl() throws {
        try requireKeyWindowTests()
        func capture(_ placement: RealShell.Placement) throws -> Bool {
            let shell = try RealShell(attachments: makeTestAttachmentFileStore(), placement: placement)
            defer { shell.close() }
            shell.go(to: .calendar)
            shell.recordSnapshot("same-commit FKA contrast before first Tab \(placement)")
            let id = PanelBottomBarLook.calendarPlus.identifier
            let found = shell.element(id) != nil
            let evidence = XCTAttachment(string: "fixture=\(placement) hasCalendarAX=\(found)\n\(shell.focusDiagnostics())")
            evidence.name = "Round 4 fixture AX comparison \(placement)"
            evidence.lifetime = .keepAlways
            add(evidence)
            if case .onDisplay = placement {
                XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(shell.panel.frame) })
            } else {
                XCTAssertFalse(NSScreen.screens.contains { $0.visibleFrame.intersects(shell.panel.frame) })
            }
            return found
        }
        let offscreen = try capture(.offscreen)
        let onDisplay = try capture(.onDisplay)
        let comparison = XCTAttachment(string: "FKA=\(NSApp.isFullKeyboardAccessEnabled) offscreen AX=\(offscreen) onDisplay AX=\(onDisplay)")
        comparison.name = "Round 4 placement outcome"
        comparison.lifetime = .keepAlways
        add(comparison)
        if NSApp.isFullKeyboardAccessEnabled {
            XCTAssertTrue(onDisplay, "the visible Calendar plus must exist before Tab on native FKA")
        }
    }

    private func assertR4PageReachesNativePlus(_ section: PanelSection, id: String) throws {
        try requireKeyWindowTests()
        guard NSApp.isFullKeyboardAccessEnabled else { throw XCTSkip("needs native FKA CI") }
        let shell = try RealShell(attachments: makeTestAttachmentFileStore(), placement: .onDisplay)
        defer { shell.close() }
        shell.go(to: section)
        if section == .notes {
            XCTAssertTrue(shell.draft.pages.showLibrary())
            shell.spin(0.8)
        }
        shell.recordSnapshot("real \(section) on-display before first Tab")
        XCTAssertNotNil(shell.element(id), "\(section): the actual control is exposed before Tab")
        shell.tabTo(id)
        XCTAssertTrue(shell.focusedIdentifiers().contains(id), "\(section): native Tab focuses the control")
    }

    func testR4CalendarPlusHasItsOwnNativeTabReach() throws {
        try assertR4PageReachesNativePlus(.calendar, id: PanelBottomBarLook.calendarPlus.identifier)
    }

    func testR4NotesPlusHasItsOwnNativeTabReach() throws {
        try assertR4PageReachesNativePlus(.notes, id: PanelBottomBarLook.notesPlus.identifier)
    }

    func testR4DrawPlusHasItsOwnNativeTabReach() throws {
        try assertR4PageReachesNativePlus(.canvas, id: PanelBottomBarLook.drawPlus.identifier)
    }
}
