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
    let panel: AtticPanel
    let host: AtticPanelHostingView
    let state: PanelUIState
    let notes: NoteStore
    let draft: NoteDraftController
    private let suite: String

    init(attachments: AttachmentFileStore) throws {
        AtticDraw.enabledOverride = true
        suite = "PanelSharedChromeKeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        _ = store.commit([TaskDraft(title: "Write launch notes", tags: ["launch"])])
        notes = NoteStore(container: container, attachmentFileStore: attachments)
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Launch plan")]), tags: ["launch"]).get()
        draft = NoteDraftController(noteStore: notes)
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
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state, settings: settings),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -6_000, y: -6_000), size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        panel.makeKey()
        spin(0.8)
    }

    func close() {
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
    }

    func tab(shift: Bool = false) {
        let characters = shift ? "\u{19}" : "\t"
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: 48)!
            panel.sendEvent(event)
        }
        spin(0.12)
    }

    func press(_ characters: String, keyCode: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: keyCode)!
            panel.sendEvent(event)
        }
        spin(0.15)
    }

    func elements(_ root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [root] }
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject, depth: depth + 1) }
    }

    func element(_ identifier: String) -> NSObject? {
        elements(host).first { $0.accessibilityIdentifier?() == identifier } as? NSObject
    }

    /// The accessibility identifiers of every element reporting keyboard focus.
    func focusedIdentifiers() -> [String] {
        let focused = NSAccessibility.Attribute(rawValue: "AXFocused")
        return elements(host).compactMap { node -> String? in
            guard let object = node as? NSObject,
                  (object.accessibilityAttributeValue(focused) as? Bool) == true else { return nil }
            let identifier: String? = node.accessibilityIdentifier?()
            return identifier ?? "(no id: \(type(of: object)))"
        }
    }

    var responder: String {
        guard let responder = panel.firstResponder else { return "nil" }
        return "\(type(of: responder))"
    }
}

@MainActor
private final class SharedBarModel: ObservableObject {
    @Published var page: PanelPage
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
                                 layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560)))
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

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
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
            let node = try XCTUnwrap(shell.element(plus.identifier), "\(page): the shared plus must be an accessible control")
            XCTAssertTrue(node.accessibilityIsAttributeSettable(focused), "\(page): the shared plus must accept keyboard focus")
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
            shell.press(" ", keyCode: 49)
            switch page {
            case .calendar: XCTAssertTrue(ComposerOverlay.isPresented, "calendar: Space on the plus opens the new-event card")
            case .notes: XCTAssertEqual(shell.notes.notes.count, notesBefore + 1, "notes: Space on the plus makes a note")
            case .canvas: XCTAssertNotEqual(DrawPageModel.shared.canvasID, canvasBefore, "draw: Space on the plus makes a canvas")
            case .tasks: break
            }
        }
    }
}
