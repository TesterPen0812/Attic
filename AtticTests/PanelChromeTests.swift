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
            XCTAssertNil(element("tasks-page-tabs", in: host), "the switch folds away")
            XCTAssertNil(element("panel-settings-button", in: host), "••• folds away")
            XCTAssertEqual(chrome.modeDockWidth, host.bounds.width, "no drag lane under the open field")
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
            _ = try assertRow(["panel-section-picker", "calendar-today", "calendar-new-task"], in: host)
        }
    }
}
