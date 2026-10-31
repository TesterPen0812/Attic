import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The accepted panel design's chrome (Planning.md, Accepted 2026-10-29/30):
/// "Shapes: squircle surfaces, 1.4 controls", "Top row and bottom bar" and
/// the Calendar header. Sizes are points (the design's px ÷ 2).
@MainActor
final class PanelChromeTests: XCTestCase {
    // MARK: Tokens

    func testEveryTopRowAndBottomBarControlIs27() {
        XCTAssertEqual(AtticControlSize.headerControl, 27)
        XCTAssertEqual(AtticControlSize.addBarHeight, 27, "the bottom bar comes down from 30.5")
        XCTAssertEqual(NotesBarMetrics.control, 27)
        XCTAssertEqual(CalendarDesign.footerHeight, 27)
        XCTAssertEqual(AtticPageButtonMetrics.inset, 3)
        XCTAssertEqual(AtticPageButtonMetrics.segment, 21, "21 pt chips")
        XCTAssertEqual(AtticControlSize.raisedGlyph, 12.2, "12.2 pt icons")
        XCTAssertEqual(NotesBarMetrics.pillHeight, 21, "21 pt tags")
        XCTAssertEqual(NotesBarMetrics.tagBarPadding, 3)
        XCTAssertEqual(TasksTopTabsMetrics.cell.height, 21)
        XCTAssertEqual(TasksTopTabsMetrics.width, 134, "3 + 3 × 42 + 2 × 1 + 3")
        XCTAssertEqual(CalendarMonthArrows.width, 49, "3 + 21 + 1 + 21 + 3")
    }

    func testShapesRadiiAndCurves() {
        // Surfaces: CSS squircle (superellipse(2)); controls curve 1.4.
        XCTAssertEqual(AtticShape.surfaceExponent, 4)
        XCTAssertEqual(AtticShape.controlExponent, pow(2, 1.4), accuracy: 1e-9)
        XCTAssertEqual(AtticStyle.panelSquircleExponent, AtticShape.surfaceExponent, "the panel is a squircle")
        XCTAssertEqual(AtticControlShape.designExponent, AtticShape.controlExponent)
        // Controls: half their height (a capsule; a square is a whole superellipse).
        XCTAssertEqual(AtticRadius.control(height: 27), 13.5)
        XCTAssertEqual(AtticRadius.control(height: 21), 10.5)
        XCTAssertEqual(AtticRadius.header, 13.5)
        XCTAssertEqual(NotesBarMetrics.radius, 13.5)
        XCTAssertEqual(NotesBarMetrics.pillRadius, 10.5)
        // Surfaces (design px, half in points).
        XCTAssertEqual(AtticRadius.shell, 52)
        XCTAssertEqual(PanelCornerSize.defaultValue, 52, "104 px panel")
        XCTAssertEqual(AtticRadius.card, 18, "36 px cards")
        XCTAssertEqual(CalendarDesign.dayRadius, AtticRadius.card, "Calendar day cards use the card token")
        XCTAssertEqual(AtticRadius.row, 12)
        XCTAssertEqual(TasksRowDesign.radius, 12)
        XCTAssertEqual(NotesLibraryRowMetrics.radius, 12)
        XCTAssertEqual(AtticRadius.menu, 14)
        XCTAssertEqual(AtticRadius.popover, 14)
        XCTAssertEqual(AtticDropdownMetrics.cornerRadius, 14, "the solid pickers: 28 px")
        XCTAssertEqual(AtticDropdownMetrics.inset, 3, "6 px padding")
        XCTAssertEqual(AtticDropdownMetrics.highlightRadius, 11, "22 px rows")
        XCTAssertEqual(AtticRadius.noteBlock, 10)
        XCTAssertEqual(AtticNoteObjectMetrics.blockRadius, 10)
        XCTAssertEqual(AtticRadius.small, 6)
        XCTAssertEqual(NoteThumbnailMetrics.radius, 6)
        XCTAssertEqual(NoteThumbnailMetrics.cornerExponent, AtticShape.surfaceExponent)
        XCTAssertEqual(TasksDesignMetrics.tileRadius, 6)
        // Concentric nesting.
        XCTAssertEqual(AtticRadius.formatSheet, 19, "24 + 14 px")
        XCTAssertEqual(AtticRadius.reviewBar, 17, "20 + 14 px")
        XCTAssertEqual(AtticRadius.concentric(outer: AtticRadius.menu, padding: AtticRadius.menuPadding), AtticRadius.menuRow)
        // A day card's padding grows with its radius (10 px at 36 px).
        XCTAssertEqual(CalendarDesign.dayPadding, 5)
        XCTAssertEqual(CalendarDesign.dayPadding(radius: 32), 8.5, "64 px: 17 px")
        XCTAssertEqual(CalendarDesign.dayPadding(radius: 0), 3, "never under 6 px")
    }

    func testOneFlatGreySelectionMarker() {
        XCTAssertEqual(AtticSelectionMarker.fillAlpha, 0.06)
        XCTAssertEqual(NotesBarMetrics.selectedFill, AtticSelectionMarker.fillAlpha, "the tag bar's chosen tag")
        XCTAssertEqual(NotesBarMetrics.hoverFill, AtticSelectionMarker.hoverAlpha)
        // The page switch's current page: the glyph's own ink, no accent.
        let face = AtticPageButtonMetrics.glyphFace(isSelected: true, open: true, accent: false, solid: false)
        XCTAssertEqual(face.ink, .glyph)
    }

    func testTopRowPlaces() {
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 560))
        let chrome = layout.chromeInsets
        let search = PanelTopRowLayout.searchButtonFrame(layout)
        let more = PanelTopRowLayout.moreButtonFrame(layout)
        XCTAssertEqual(search.maxX, 340 - chrome.trailing, accuracy: 0.001, "Search at the far right")
        XCTAssertEqual(search.minX - more.maxX, 3, accuracy: 0.001, "••• one 6 px gap before it")
        let tabs = PanelTopRowLayout.switchFrame(layout, width: TasksTopTabsMetrics.width)
        XCTAssertEqual(more.minX - tabs.maxX, 3, accuracy: 0.001)
        let field = PanelTopRowLayout.fieldFrame(layout)
        XCTAssertEqual(field.minX, chrome.leading, accuracy: 0.001)
        XCTAssertEqual(340 - field.maxX, chrome.trailing, accuracy: 0.001)
        XCTAssertEqual(field.minX, 340 - field.maxX, accuracy: 0.001, "the open field: equal space on both sides")
    }

    // MARK: Review fixes (w1-fixes)

    /// The pin's glass folds with the switch and ••• while the search is
    /// open (a glass group ignores an opacity set on its members from
    /// outside), as its raised material receives it, and only for this
    /// page's search. Escape, through the field, is in the panel test.
    func testThePinsGlassFoldsWithTheSearchAndComesBack() throws {
        let state = PanelTopRowState()
        let header = PanelHeader(isPinned: false, page: .tasks, onTogglePin: {}, onSelectPage: { _ in })
            .environment(\.panelTopRowState, state)
            .atticDesign(.default)
            .frame(width: 340, height: 40)
        AtticMaterialProbe.reset()
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 340, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: header)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        spin(0.3)
        func pin() throws -> AtticMaterialProbe.State {
            try XCTUnwrap(AtticMaterialProbe.states["panel-pin"], "the pin's material is drawn")
        }
        XCTAssertEqual(try pin(), .init(away: false, gone: false))
        state.setSearching(true, on: .tasks)
        spin(0.05)
        XCTAssertTrue(try pin().away, "the pin's glass fades as the search opens")
        spin(0.6)
        XCTAssertEqual(try pin(), .init(away: true, gone: true), "and is gone once the fade is over")
        state.setSearching(false, on: .tasks)
        spin(0.6)
        XCTAssertEqual(try pin(), .init(away: false, gone: false), "closing the search brings it back")
        // Another page's search leaves this page's pin alone.
        state.setSearching(true, on: .notes)
        spin(0.6)
        XCTAssertEqual(try pin(), .init(away: false, gone: false))
    }

    /// Shut, the page switch still shows the current page on the grey chip
    /// ("with the current page on a grey chip").
    func testTheShutPageSwitchDrawsTheCurrentPageOnTheMarker() throws {
        for context in [AtticDesignContext(mode: .light), AtticDesignContext(mode: .dark)] {
            let button = AtticPageButton(items: AtticGallerySamples.pages, selection: .constant(0), pinnedOpen: false, flat: true)
                .atticDesign(context)
            let renderer = ImageRenderer(content: button)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            func level(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
                let c = try XCTUnwrap(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB))
                return (c.redComponent + c.greenComponent + c.blueComponent) / 3 * c.alphaComponent
            }
            // Above the glyph, inside the 21 pt chip (3 pt in) / beside it on the surface.
            let chip = try level(3 + 10.5, 6)
            let surface = try level(28.5, 6)
            XCTAssertGreaterThan(abs(chip - surface), 0.005, "\(context.caption): the current page sits on the marker while shut")
        }
    }

    /// The page switch's marker moves with the one selection motion: a
    /// per-cell crossfade in 160 ms ease-out, at once under Reduce Motion,
    /// whatever motion the page change itself carries (here the
    /// page-navigation spring, as the switch's own click sends it).
    func testThePageSwitchMarkerCrossfadesOnTheSelectionMotion() throws {
        let M = AtticPageButtonMetrics.self
        let points = (0 ..< 3).map { CGPoint(x: M.inset + CGFloat($0) * (M.segment + M.gap) + M.segment / 2, y: M.inset + 1.5) }
        for reduceMotion in [false, true] {
            let design = AtticDesignContext(mode: .light, reduceMotion: reduceMotion, controls: .craft)
            let frames = try SelectionMarkerMotionProbe.run(
                size: CGSize(width: AtticPageButton<Int>.width(open: true, count: 3), height: AtticControlSize.headerControl),
                points: points, from: 0, to: 2,
                change: { probe in
                    withAnimation(AtticMotionPreset.pageSwitch.animation(reduceMotion: reduceMotion)) { probe.index = 2 }
                }) { probe in
                    AtticPageButton(items: AtticGallerySamples.pages,
                                    selection: Binding(get: { probe.index }, set: { probe.index = $0 }),
                                    pinnedOpen: true, flat: true)
                        .atticDesign(design)
                }
            assertSelectionCrossfade(frames, from: 0, to: 2, reduceMotion: reduceMotion, "page switch, reduce \(reduceMotion)")
        }
    }

    /// Shapes on the solid pickers: the cards and their rows are surface
    /// squircles at the menu radius (14 pt, rows 11 pt), and the date
    /// picker's day marks whole superellipses on curve 1.4.
    func testPickerCardsRowsAndDayMarksFollowShapes() {
        let d = AtticDropdownMetrics.self
        let card = CGRect(x: 0, y: 0, width: 224, height: 260)
        XCTAssertEqual(AtticUnfoldShape(cornerRadius: d.cornerRadius).path(in: card),
                       Squircle(cornerRadius: 14, exponent: AtticShape.surfaceExponent).path(in: card),
                       "the card: a surface squircle at the menu radius")
        let row = CGRect(x: 3, y: 3, width: 218, height: 32)
        XCTAssertEqual(AtticDropdownRow.highlightShape.path(in: row),
                       Squircle(cornerRadius: 11, exponent: AtticShape.surfaceExponent).path(in: row), "a row: 11 pt squircle")
        XCTAssertEqual(d.clearRadius, d.highlightRadius, "Clear Date is a row")
        XCTAssertEqual(d.monthMarkRadius, d.monthMarkHeight / 2, "a day mark is rounded by half its height")
        let mark = CGRect(x: 0, y: 0, width: d.monthMarkWidth, height: d.monthMarkHeight)
        let curve = Squircle(cornerRadius: d.monthMarkRadius, exponent: AtticShape.controlExponent)
        XCTAssertEqual(AtticCalendarMark.outline(in: mark, radius: d.monthMarkRadius), curve.path(in: mark), "curve 1.4")
        XCTAssertEqual(AtticCalendarMark.outline(in: mark, radius: d.monthMarkRadius, inset: 0.5), curve.inset(by: 0.5).path(in: mark),
                       "today's ring follows the mark")
    }

    /// The "+" expansion (the switch and the tag bar folding as the field
    /// takes the row) moves on the bar's fold token: the design's ease at
    /// 260 ms, Reduce Motion a 150 ms fade, as the footer's tabs folded in
    /// pd-combined (unchanged motion).
    func testThePlusExpansionUsesTheBarsFoldToken() {
        for reduce in [false, true] {
            XCTAssertEqual(TasksBottomBar<EmptyView>.foldAnimation(reduceMotion: reduce), TasksDesignMetrics.fold(reduceMotion: reduce))
        }
        XCTAssertEqual(TasksDesignMetrics.fold(reduceMotion: false), TasksDesignMetrics.curve(0.26))
        XCTAssertEqual(TasksDesignMetrics.fold(reduceMotion: true), .easeOut(duration: 0.15))
    }

    // MARK: In the panel

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func withPanel(_ body: (_ host: AtticPanelHostingView, _ state: PanelUIState, _ tasks: TasksPageState,
                                    _ store: TaskStore, _ draft: NoteDraftController,
                                    _ chrome: PanelChromeInteractionState) throws -> Void) throws {
        let suite = "PanelChrome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        _ = store.commit([TaskDraft(title: "Write launch notes", tags: ["launch"]),
                          TaskDraft(title: "Return books", tags: ["books"])])
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Launch plan")]), tags: ["launch"]).get()
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let tasksState = TasksPageState()
        let draft = NoteDraftController(noteStore: notes)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: settings, tasksPageState: tasksState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
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
        try body(host, state, tasksState, store, draft, chrome)
    }

    /// An element's frame in the host's top-left space, or nil if absent.
    private func frame(of identifier: String, in host: AtticPanelHostingView) -> CGRect? {
        host.layoutSubtreeIfNeeded()
        return element(identifier, in: host).flatMap { frame(ofElement: $0, in: host) }
    }

    private func frame(ofElement element: AnyObject, in host: AtticPanelHostingView) -> CGRect? {
        guard let screen = element.accessibilityFrame?(), let window = host.window, screen.width > 0 else { return nil }
        let local = host.convert(window.convertFromScreen(screen), from: nil)
        return host.isFlipped ? local : CGRect(x: local.minX, y: host.bounds.height - local.maxY,
                                               width: local.width, height: local.height)
    }

    private func element(_ identifier: String, in host: AtticPanelHostingView) -> AnyObject? {
        elements(host).first { ($0.accessibilityIdentifier?() ?? "") == identifier }
    }

    private func assertRow(_ ids: [String], in host: AtticPanelHostingView, height: CGFloat = 27,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [CGRect] {
        let frames = try ids.map { try XCTUnwrap(frame(of: $0, in: host), "\($0) is drawn", file: file, line: line) }
        for (id, rect) in zip(ids, frames) {
            XCTAssertEqual(rect.height, height, accuracy: 0.5, "\(id) is \(height) pt tall", file: file, line: line)
        }
        for (a, b) in zip(zip(ids, frames), zip(ids, frames).dropFirst()) {
            XCTAssertLessThanOrEqual(a.1.maxX, b.1.minX + 0.5, "\(a.0) before \(b.0)", file: file, line: line)
            XCTAssertEqual(a.1.midY, b.1.midY, accuracy: 0.5, "\(a.0) and \(b.0) on one line", file: file, line: line)
        }
        return frames
    }

    func testTasksTopRowBottomBarSearchAndTagBar() throws {
        try withPanel { host, state, tasksState, store, _, chrome in
            state.selectSection(.tasks)
            spin(1.0)
            let layout = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size)
            let insets = layout.chromeInsets
            // Top row: Pin · · · Now Later Done, •••, Search.
            let top = try assertRow(["panel-pin-button", "tasks-page-tabs", "panel-settings-button", "tasks-find-button"], in: host)
            XCTAssertEqual(top[0].minX, insets.leading, accuracy: 0.5, "Pin alone on the left")
            XCTAssertEqual(top[3].maxX, host.bounds.width - insets.trailing, accuracy: 0.5, "Search at the far right")
            XCTAssertEqual(top[1].width, TasksTopTabsMetrics.width, accuracy: 0.5)
            XCTAssertGreaterThan(top[1].minX - top[0].maxX, 20, "the switch sits on the right, Pin alone on the left")
            XCTAssertNil(element("tasks-view-options", in: host), "no filter button")
            // AppKit's drag lane keeps clear of the right-hand controls.
            XCTAssertEqual(chrome.modeDockWidth, host.bounds.width - insets.trailing - top[1].minX, accuracy: 1)
            // Bottom bar: the page switch, the tag bar, "+".
            let bottom = try assertRow(["panel-section-picker", "tasks-tag-bar", "tasks-new-task"], in: host)
            XCTAssertEqual(bottom[0].minX, insets.leading, accuracy: 0.5, "the page switch on the left")
            XCTAssertEqual(bottom[2].maxX, host.bounds.width - insets.trailing, accuracy: 0.5, "\"+\" on the right")

            // The tag bar filters the list.
            let model = tasksState.model(for: store, toasts: nil)
            XCTAssertEqual(model.rows(for: .now).count, 2)
            let books = try XCTUnwrap(element("tasks-tag-bar-books", in: host), "the #books tag")
            XCTAssertTrue(books.accessibilityPerformPress?() ?? false)
            spin(0.3)
            XCTAssertEqual(model.tagFilter(on: .now), "books")
            XCTAssertEqual(model.rows(for: .now).map(\.model.title), ["Return books"])
            let all = try XCTUnwrap(element("tasks-tag-bar-all", in: host))
            XCTAssertTrue(all.accessibilityPerformPress?() ?? false)
            spin(0.3)
            XCTAssertNil(model.tagFilter(on: .now))

            // Search: Pin, the switch and ••• fold away; the field fills the row.
            let searchButton = try XCTUnwrap(element("tasks-find-button", in: host))
            XCTAssertTrue(searchButton.accessibilityPerformPress?() ?? false)
            spin(0.8)
            // The field's magnifier sits in the row's first 27 pt; its text runs to the right inset.
            let parts = elements(host).filter { ($0.accessibilityIdentifier?() ?? "") == "tasks-find" }
            let glyph = try XCTUnwrap(parts.first { $0.accessibilityRole?() == .image }.flatMap { frame(ofElement: $0, in: host) }, "the magnifier")
            let text = try XCTUnwrap(parts.first { $0.accessibilityRole?() == .textField }.flatMap { frame(ofElement: $0, in: host) }, "the text")
            XCTAssertEqual(glyph.midX, insets.leading + AtticControlSize.headerControl / 2, accuracy: 1, "from the left inset")
            XCTAssertGreaterThan(text.maxX, host.bounds.width - insets.trailing - 40, "the field fills the row to the right inset")
            XCTAssertLessThanOrEqual(text.maxX, host.bounds.width - insets.trailing + 0.5)
            XCTAssertNil(element("panel-pin-button", in: host), "Pin folds away")
            XCTAssertEqual(AtticMaterialProbe.states["panel-pin"], .init(away: true, gone: true), "and so does its glass")
            XCTAssertNil(element("tasks-page-tabs", in: host), "the switch folds away")
            XCTAssertNil(element("panel-settings-button", in: host), "••• folds away")
            XCTAssertEqual(chrome.modeDockWidth, host.bounds.width, "no drag lane under the open field")
        }
    }

    /// A real Escape in the open search field (the key-window route of
    /// `TasksRound12Tests`) closes the search and brings Pin back, its
    /// raised material told to draw its glass again.
    func testEscapeInTheSearchBringsThePinAndItsGlassBack() throws {
        try requireKeyWindowTests()
        try withPanel { host, state, tasksState, store, _, _ in
            state.selectSection(.tasks)
            spin(1.0)
            let window = try XCTUnwrap(host.window)
            window.makeKey()
            @MainActor func send(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                NSApp.postEvent(event, atStart: false)
                Hosted.pumpEvents()
            }
            let model = tasksState.model(for: store, toasts: nil)
            let searchButton = try XCTUnwrap(element("tasks-find-button", in: host))
            XCTAssertTrue(searchButton.accessibilityPerformPress?() ?? false)
            spin(0.8)
            XCTAssertNotNil(element("tasks-find", in: host), "the search is open")
            XCTAssertEqual(AtticMaterialProbe.states["panel-pin"], .init(away: true, gone: true), "the pin's glass is gone")
            let field = try XCTUnwrap(AtticTabsSearchField.searchField(in: host, placeholder: model.searchPlaceholder(for: .now)))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field has the keyboard")
            XCTAssertTrue(editor.delegate as? NSTextField === field, "the hosted search field's own editor")
            try send("\u{1b}", code: 53)
            spin(0.8)
            XCTAssertNil(element("tasks-find", in: host), "Escape closes the search")
            XCTAssertNotNil(element("panel-pin-button", in: host), "Pin is back")
            XCTAssertEqual(AtticMaterialProbe.states["panel-pin"], .init(away: false, gone: false), "and so is its glass")
        }
    }

    func testNotesAndCalendarRows() throws {
        try withPanel { host, state, _, _, draft, _ in
            state.selectSection(.notes)
            spin(1.5)
            XCTAssertTrue(draft.pages.showLibrary())
            spin(1.0)
            let layout = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size)
            let insets = layout.chromeInsets
            let notesTop = try assertRow(["panel-pin-button", "panel-settings-button", "notes-search-button"], in: host)
            XCTAssertEqual(notesTop[2].maxX, host.bounds.width - insets.trailing, accuracy: 0.5)
            let notesBottom = try assertRow(["panel-section-picker", "notes-tag-bar", "notes-new-note"], in: host)
            XCTAssertEqual(notesBottom[0].minX, insets.leading, accuracy: 0.5)
            let tag = try XCTUnwrap(frame(of: "notes-tag-bar-launch", in: host))
            XCTAssertEqual(tag.height, 21, accuracy: 0.5, "21 pt tags")

            state.selectSection(.calendar)
            spin(1.5)
            let calTop = try assertRow(["panel-pin-button", "calendar-month-pill", "panel-settings-button",
                                        "calendar-search-button"], in: host)
            XCTAssertEqual(calTop[1].minX - calTop[0].maxX, 8, accuracy: 1, "the month 16 px after the pin")
            // ‹ › in one capsule before •••: 21 pt cells in its 3 pt inset.
            // (Each cell answers a 28 pt target around its 21 pt face.)
            let previous = try XCTUnwrap(frame(of: "calendar-previous", in: host))
            let next = try XCTUnwrap(frame(of: "calendar-next", in: host))
            XCTAssertEqual(previous.midY, calTop[2].midY, accuracy: 0.5, "on the top row")
            XCTAssertEqual(next.midX - previous.midX, 21 + 1, accuracy: 0.5, "21 pt cells 1 pt apart")
            XCTAssertGreaterThan(previous.midX - 10.5, calTop[1].maxX)
            XCTAssertEqual(calTop[2].minX - (next.midX + 10.5), 3 + 3, accuracy: 0.5, "the capsule's inset, then a 6 px gap")
            // Today shows only while another day is selected (Accepted
            // "Calendar page", the Today button), so the row reads switch,
            // then "+".
            XCTAssertNil(element("calendar-today", in: host), "no Today button while today is selected")
            _ = try assertRow(["panel-section-picker", "calendar-new-task"], in: host)
            let today = DueDay(date: Date(), calendar: CalendarMonthMath.calendar())
            let other = try XCTUnwrap(DueDay(year: today.year, month: today.month, day: today.day == 1 ? 2 : today.day - 1))
            let otherCell = try XCTUnwrap(element("calendar-day-\(other.rawValue)", in: host))
            XCTAssertTrue(otherCell.accessibilityPerformPress?() ?? false)
            spin(1.0)
            _ = try assertRow(["panel-section-picker", "calendar-today", "calendar-new-task"], in: host)
        }
    }

    /// Notes board (Accepted 2026-10-30): board | list on the top row's
    /// page-switch slot, only on the notes list, 27 pt like the Tasks tabs,
    /// the current one on the selection marker; it folds with the search.
    /// The bottom bar ends with "+".
    /// No outline from a click (owner, 2026-10-31): one keyboard tracker at
    /// the panel's root, so the Notes and Calendar pages, the top row and the
    /// bottom bar show rings only while the keyboard drives, as Tasks did. A
    /// click on any page turns them off; Tab turns them on.
    func testOneFocusTrackerForTheWholePanelAClickHidesRings() throws {
        try withPanel { host, state, _, _, _, _ in
            for section in [PanelSection.notes, .calendar, .tasks] {
                state.selectSection(section)
                spin(1.0)
                XCTAssertTrue(state.keyboardFocus.isTracking, "\(section): the panel's tracker watches clicks and keys")
            }
            // What it does with them (TasksRound5Tests): Tab on, a click off.
            state.keyboardFocus.observe(.keyDown, keyCode: 48)
            XCTAssertTrue(state.keyboardFocus.isKeyboardDriving)
            state.keyboardFocus.observe(.leftMouseDown, keyCode: nil)
            XCTAssertFalse(state.keyboardFocus.isKeyboardDriving)
        }
    }

    /// Tag bar fades (owner, 2026-10-31): each edge fades only while tags
    /// are cut off there, over 14 pt (the HTML's 28 px), on every page's bar.
    func testTheTagBarFadesOnlyWhereTagsAreCutOff() {
        XCTAssertEqual(NotesBarMetrics.endFade, 14)
        XCTAssertEqual(NotesTagBarCutOff(offset: 0, visible: 200, content: 180), .init(), "all fit: no fade")
        XCTAssertEqual(NotesTagBarCutOff(offset: 0, visible: 200, content: 400), .init(trailing: true), "at the start: trailing only")
        XCTAssertEqual(NotesTagBarCutOff(offset: 80, visible: 200, content: 400), .init(leading: true, trailing: true), "midway: both")
        XCTAssertEqual(NotesTagBarCutOff(offset: 200, visible: 200, content: 400), .init(leading: true), "at the end: leading only")
    }

    func testNotesLayoutSwitchOnlyOnTheListAndFoldsWithSearch() throws {
        XCTAssertEqual(NotesBarMetrics.newNoteSymbol, "plus", "the bottom bar ends with +")
        XCTAssertEqual(NotesLayoutSwitchMetrics.width, 3 + 21 + 1 + 21 + 3)
        try withPanel { host, state, _, _, draft, _ in
            state.selectSection(.notes)
            spin(1.5)
            XCTAssertTrue(draft.pages.showLibrary())
            spin(1.0)
            let top = try assertRow(["panel-pin-button", "notes-layout-switch", "panel-settings-button", "notes-search-button"],
                                    in: host)
            XCTAssertEqual(top[1].width, NotesLayoutSwitchMetrics.width, accuracy: 0.5)
            XCTAssertEqual(top[2].minX - top[1].maxX, 3, accuracy: 0.5, "a 6 px gap before •••")
            _ = try assertRow(["panel-section-picker", "notes-tag-bar", "notes-new-note"], in: host)
            XCTAssertNotNil(element("notes-library-group-today", in: host), "the list, with its sections")

            // Board: the cards, no headings.
            let board = try XCTUnwrap(element("notes-layout-board", in: host))
            XCTAssertTrue(board.accessibilityPerformPress?() ?? false)
            spin(0.6)
            XCTAssertNotNil(element("notes-board-column-0", in: host), "the board")
            XCTAssertNil(element("notes-library-group-today", in: host), "no headings on the board")
            let list = try XCTUnwrap(element("notes-layout-list", in: host))
            XCTAssertTrue(list.accessibilityPerformPress?() ?? false)
            spin(0.6)
            XCTAssertNotNil(element("notes-library-group-today", in: host))

            // Search folds the switch with Pin and •••.
            let search = try XCTUnwrap(element("notes-search-button", in: host))
            XCTAssertTrue(search.accessibilityPerformPress?() ?? false)
            spin(0.8)
            XCTAssertNil(element("notes-layout-switch", in: host), "folds with the search")

            // An open note has no layout switch.
            draft.pages.dismissLibrary()
            spin(1.0)
            XCTAssertNil(element("notes-layout-switch", in: host), "only on the notes list")
            XCTAssertNotNil(element("notes-search-button", in: host))
        }
    }
}

// MARK: - One selection motion

/// What a switch's marker does over a change of choice, sampled live in an
/// off-screen window: each cell's darkening at its marker's top edge (above
/// the word or glyph) against its own unselected level, as a fraction of the
/// full marker, per frame. A crossfade lights the old and new cells at once
/// and never the cells between; a slide crosses the cells between.
@MainActor
final class SelectionMarkerMotionProbe: ObservableObject {
    @Published var index = 0

    struct Frame { let time: TimeInterval; let presence: [CGFloat] }

    /// `points` are the cells' sample points (pt, top-left); `from` and `to`
    /// index into them; `change` makes the change as the control's caller does.
    static func run<V: View>(size: CGSize, points: [CGPoint], from: Int, to: Int,
                             change: @escaping (SelectionMarkerMotionProbe) -> Void,
                             @ViewBuilder view: @escaping (SelectionMarkerMotionProbe) -> V) throws -> [Frame] {
        let probe = SelectionMarkerMotionProbe()
        probe.index = from
        let host = NSHostingView(rootView: SelectionMarkerMotionRoot(probe: probe, content: view))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func levels() throws -> [CGFloat] {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            return try points.map { p in
                let c = try XCTUnwrap(rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.usingColorSpace(.sRGB))
                return (c.redComponent + c.greenComponent + c.blueComponent) / 3
            }
        }
        spin(0.4)
        let before = try levels()
        let start = Date()
        change(probe)
        var raw: [(TimeInterval, [CGFloat])] = []
        while Date().timeIntervalSince(start) < 0.6 {
            spin(0.008)
            raw.append((Date().timeIntervalSince(start), try levels()))
        }
        let after = try XCTUnwrap(raw.last?.1)
        // Each cell's unselected level: the old cell's after, the others' before.
        let off = points.indices.map { $0 == from ? after[$0] : before[$0] }
        let full = max(off[to] - after[to], 0.001)
        XCTAssertGreaterThan(full, 0.02, "the marker is visible on its cell")
        return raw.map { time, level in
            Frame(time: time, presence: points.indices.map { (off[$0] - level[$0]) / full })
        }
    }
}

private struct SelectionMarkerMotionRoot<V: View>: View {
    @ObservedObject var probe: SelectionMarkerMotionProbe
    let content: (SelectionMarkerMotionProbe) -> V

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            content(probe)
        }
    }
}

/// The one selection motion: a crossfade between the cells (never through
/// the ones between), over by 0.22 s, and at once under Reduce Motion.
@MainActor
func assertSelectionCrossfade(_ frames: [SelectionMarkerMotionProbe.Frame], from: Int, to: Int, reduceMotion: Bool,
                              _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    let between = Array(min(from, to) + 1 ..< max(from, to))
    for frame in frames {
        for cell in between {
            XCTAssertLessThan(frame.presence[cell], 0.25,
                              "\(label): the marker never crosses cell \(cell) (t = \(Int(frame.time * 1000)) ms)", file: file, line: line)
        }
    }
    let settled = frames.filter { $0.time >= (reduceMotion ? 0.05 : 0.22) }
    XCTAssertFalse(settled.isEmpty, file: file, line: line)
    for frame in settled {
        XCTAssertGreaterThan(frame.presence[to], 0.85, "\(label): settled on the new cell by \(Int(frame.time * 1000)) ms",
                             file: file, line: line)
        XCTAssertLessThan(frame.presence[from], 0.15, "\(label): gone from the old cell by \(Int(frame.time * 1000)) ms",
                          file: file, line: line)
    }
    if !reduceMotion {
        XCTAssertTrue(frames.contains { $0.presence[from] > 0.15 && $0.presence[to] > 0.15 },
                      "\(label): old and new cells are lit together mid-change (a crossfade); presence old/new: "
                      + frames.prefix(20).map { String(format: "%.2f/%.2f", $0.presence[from], $0.presence[to]) }.joined(separator: " "),
                      file: file, line: line)
    }
}
