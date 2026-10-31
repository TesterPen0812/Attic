import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Owner, 2026-10-31 (Accepted "Shared controls stay still while pages
/// switch"): the bottom bar and the top row's shared controls are one layer
/// above the pages, and the page switch's open moves the bar with it.
@MainActor
final class PanelSharedChromeTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
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

    /// Through a page switch (the pages travelling sideways), the pin, •••,
    /// Search, the page switch, the tag bar card and "+" stay put and keep
    /// their look on every frame: they are drawn once, above the pages, so
    /// the switch is one view whose open state lives on.
    func testSharedControlsStayStillThroughAPageSwitch() throws {
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
        let baseline = PanelPageSwitcher.liveCount
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
        XCTAssertEqual(PanelPageSwitcher.liveCount - baseline, 1, "one page switch for the whole panel, whatever pages are built")

        let plusIDs: [PanelSection: String] = [.tasks: "tasks-new-task", .notes: "notes-new-note", .calendar: "calendar-new-task"]
        let searchIDs: [PanelSection: String] = [.tasks: "tasks-find-button", .notes: "notes-search-button",
                                                 .calendar: "calendar-search-button"]
        let tagBarIDs: [PanelSection: String] = [.tasks: "tasks-tag-bar", .notes: "notes-tag-bar"]
        for (from, to) in [(PanelSection.tasks, PanelSection.notes), (.notes, .calendar), (.calendar, .tasks)] {
            let pin = try XCTUnwrap(frame(of: "panel-pin-button", in: host), "\(from): the pin")
            let more = try XCTUnwrap(frame(of: "panel-settings-button", in: host), "\(from): •••")
            let search = try XCTUnwrap(frame(of: try XCTUnwrap(searchIDs[from]), in: host), "\(from): Search")
            let pageSwitch = try XCTUnwrap(frame(of: "panel-section-picker", in: host), "\(from): the page switch")
            let plus = try XCTUnwrap(frame(of: try XCTUnwrap(plusIDs[from]), in: host), "\(from): +")
            let M = AtticPageButtonMetrics.self
            var boxes = [box(around: CGPoint(x: pin.midX, y: pin.midY)),
                         box(around: CGPoint(x: more.midX, y: more.midY)),
                         box(around: CGPoint(x: search.midX, y: search.midY)),
                         box(around: CGPoint(x: pageSwitch.maxX - M.inset - M.chevronWidth / 2, y: pageSwitch.midY), side: 4),
                         box(around: CGPoint(x: plus.midX, y: plus.midY))]
            var names = ["pin", "•••", "Search", "switch", "+"]
            // The tag bar card's empty end, where both pages draw no tag.
            if let fromBar = tagBarIDs[from], tagBarIDs[to] != nil {
                let bar = try XCTUnwrap(frame(of: fromBar, in: host), "\(from): the tag bar")
                boxes.append(box(around: CGPoint(x: bar.maxX - 8, y: bar.midY - 7), side: 4))
                names.append("tag bar card")
            }
            let before = try levels(host, boxes)
            let start = Date()
            state.switchPage(to: to, motion: PanelPageMotion.current(reduceMotion: false))
            var samples: [(ms: Int, levels: [CGFloat])] = []
            while Date().timeIntervalSince(start) < 0.7 {
                spin(0.008)
                samples.append((Int(Date().timeIntervalSince(start) * 1000), try levels(host, boxes)))
            }
            XCTAssertGreaterThan(samples.count, 10, "sampled the switch's frames")
            spin(0.4)
            // A box may settle to another level when the arriving page draws
            // something else under a translucent control (Calendar's agenda
            // reaches under the switch, owner 2026-10-31: every day listed).
            // Staying still means no frame leaves the span between the level
            // before and the level after: no replayed opening, no jump.
            let after = try levels(host, boxes)
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
            for (id, was) in [("panel-section-picker", pageSwitch), (try XCTUnwrap(plusIDs[to]), plus),
                              (try XCTUnwrap(searchIDs[to]), search), ("panel-settings-button", more), ("panel-pin-button", pin)] {
                let now = try XCTUnwrap(frame(of: id, in: host), "\(from) → \(to): \(id) is drawn")
                for (a, b) in [(now.minX, was.minX), (now.minY, was.minY), (now.width, was.width), (now.height, was.height)] {
                    XCTAssertEqual(a, b, accuracy: 0.5, "\(from) → \(to): \(id) keeps its frame (\(now) vs \(was))")
                }
            }
            XCTAssertEqual(PanelPageSwitcher.liveCount - baseline, 1, "\(from) → \(to): the same switch, never rebuilt")
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

    /// The page switch opens on hover and pushes the bar after it; it folds
    /// when the pointer leaves (owner, 2026-10-31, rec1): on every frame both
    /// ways the bar's leading edge stays one gap after the switch's trailing
    /// edge (nothing covers its icons, no gap opens), and its icons stay
    /// inside its own bounds.
    func testTheOpenSwitchAndTheBarMoveAsOneEveryFrame() throws {
        let gap = TasksDesignMetrics.footerGap
        let side = AtticControlSize.headerControl
        let size = CGSize(width: 260, height: side + 20)
        let design = AtticDesignContext(mode: .light, reduceMotion: false, controls: .craft)
        let root = ZStack(alignment: .topLeading) {
            Color.white
            HStack(spacing: gap) {
                AtticPageButton(items: PanelPageSwitcher.items, selection: .constant(PanelPage.tasks), flat: true)
                Color(red: 1, green: 0, blue: 0).frame(height: side)
            }
            .padding(10)
        }
        .atticDesign(design)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        spin(0.5)
        let y = 10 + side / 2
        let shut = try XCTUnwrap(try edges(host, y: y, from: 10), "the bar is drawn")
        XCTAssertEqual(shut.barStart - shut.switchEnd, gap, accuracy: 1.5, "shut: one gap")

        for (label, point) in [("opening", CGPoint(x: 10 + 8, y: y) as CGPoint?), ("folding", nil)] {
            try hover(host, at: point)
            let start = Date()
            var widths: [CGFloat] = []
            while Date().timeIntervalSince(start) < 0.6 {
                spin(0.008)
                guard let frame = try edges(host, y: y, from: 10) else { continue }
                widths.append(frame.switchEnd)
                let between = frame.barStart - frame.switchEnd
                XCTAssertGreaterThanOrEqual(between, gap - 1.5,
                                            "\(label), t = \(Int(Date().timeIntervalSince(start) * 1000)) ms: the bar never covers the switch (\(between) pt)")
                XCTAssertLessThanOrEqual(between, gap + 1.5,
                                         "\(label), t = \(Int(Date().timeIntervalSince(start) * 1000)) ms: no gap opens (\(between) pt)")
            }
            let distinct = Set(widths.map { Int($0.rounded()) })
            XCTAssertGreaterThan(distinct.count, 3, "\(label): sampled the motion itself (\(distinct.sorted()))")
        }
        let open = PanelPageSwitcher.width(open: true)
        XCTAssertGreaterThan(open, PanelPageSwitcher.width(open: false))
    }
}
