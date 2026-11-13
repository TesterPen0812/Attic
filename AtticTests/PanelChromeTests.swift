import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The accepted panel design's chrome (Planning.md, Accepted 2026-10-29/30):
/// "Shapes: squircle surfaces, 1.4 controls", "Top row and bottom bar" and
/// the Calendar header. Sizes are points (the design's px ÷ 2).
@MainActor
final class PanelChromeTests: XCTestCase {
    func testContinuousDiagnosticsRetainOnlyRecentSamples() {
        AtticMaterialProbe.resetCorners()
        PanelSwipeTrace.events = []
        ComposerOverlay.surfaces = []
        ComposerOverlay.corners = []
        CalendarScrollMask.renders = []
        defer {
            AtticMaterialProbe.resetCorners()
            PanelSwipeTrace.events = []
            ComposerOverlay.surfaces = []
            ComposerOverlay.corners = []
            CalendarScrollMask.renders = []
        }
        for index in 0..<10_000 {
            AtticMaterialProbe.recordCorner(CGFloat(index))
            AtticMaterialProbe.recordRevealed(.init(cornerRadius: CGFloat(index), leading: 0, trailing: 0, exponent: 1.4))
            PanelSwipeTrace.events.append([Double(index)])
            ComposerOverlay.surfaces.append(ComposerGrow.geometry(progress: 1, card: CGSize(width: CGFloat(index), height: 130)))
            ComposerOverlay.corners.append(CGPoint(x: index, y: 0))
            CalendarScrollMask.renders.append(index.isMultiple(of: 2))
        }
        for count in [AtticMaterialProbe.corners.count, AtticMaterialProbe.revealed.count,
                      PanelSwipeTrace.events.count, ComposerOverlay.surfaces.count,
                      ComposerOverlay.corners.count, CalendarScrollMask.renders.count] {
            XCTAssertLessThanOrEqual(count, 4096, "continuous diagnostics must have bounded storage")
        }
        XCTAssertEqual(AtticMaterialProbe.corners.last!, 9_999)
        XCTAssertEqual(PanelSwipeTrace.events.last, [9_999])
        XCTAssertEqual(ComposerOverlay.corners.last?.x, 9_999)
        XCTAssertEqual(CalendarScrollMask.renders.last, false)
    }
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
        XCTAssertEqual(TasksTopTabsMetrics.cell.width, 21, "an unselected tab: the icon's square")
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
        XCTAssertEqual(AtticRadius.card, 24, "48 px cards (owner, 2026-10-31)")
        XCTAssertEqual(CalendarDesign.dayRadius, AtticRadius.card, "Calendar day cards use the card token")
        // Corners (Accepted 2026-11-13): rows 16 on the continuous curve,
        // never rounder than half their height.
        XCTAssertEqual(AtticRadius.row, 16)
        XCTAssertEqual(AtticRadius.row(height: 28), 14)
        XCTAssertEqual(TasksRowDesign.radius, 16)
        XCTAssertEqual(NotesLibraryRowMetrics.radius, 16)
        XCTAssertEqual(NotesLibraryRowMetrics.thumbnailInset, 6)
        XCTAssertEqual(CalendarDesign.eventRadius, 17.5, "24 − 6.5")
        XCTAssertEqual(AtticRadius.menu, 16, "32 px menus (owner, 2026-10-31)")
        XCTAssertEqual(AtticRadius.popover, 16)
        XCTAssertEqual(AtticDropdownMetrics.cornerRadius, 18, "the picker cards: the glass menu's 18 pt (Accepted 2026-11-10)")
        XCTAssertEqual(AtticDropdownMetrics.inset, 3, "6 px padding")
        XCTAssertEqual(AtticDropdownMetrics.highlightRadius, 13, "concentric rows: 16 − 3")
        XCTAssertEqual(AtticDropdownMetrics.clearRadius, 13, "Clear Date as a row")
        XCTAssertEqual(AtticDropdownMetrics.fieldRadius, 11, "the field, 5 pt in: 16 − 5")
        XCTAssertEqual(AtticRadius.noteBlock, 10)
        XCTAssertEqual(AtticNoteObjectMetrics.blockRadius, 10)
        XCTAssertEqual(AtticRadius.small, 6)
        XCTAssertEqual(NoteThumbnailMetrics.radius, 10, "concentric in its row: 16 − 6")
        XCTAssertNil(NoteThumbnailMetrics.cornerExponent, "Apple's continuous curve")
        XCTAssertEqual(TasksDesignMetrics.tileRadius, 6)
        // Concentric nesting.
        XCTAssertEqual(AtticRadius.formatSheet, 19, "24 + 14 px")
        XCTAssertEqual(AtticRadius.concentric(outer: AtticRadius.menu, padding: AtticRadius.menuPadding), AtticRadius.menuRow)
        // A day card's padding grows with its radius (10 px at 36 px).
        XCTAssertEqual(CalendarDesign.dayPadding, 6.5, "48 px radius: 13 px padding")
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
        XCTAssertEqual(search.minX - more.maxX, 5, accuracy: 0.001, "••• one gap before it")
        let tabs = PanelTopRowLayout.switchFrame(layout, width: TasksTopTabsMetrics.width(selection: .now))
        XCTAssertEqual(more.minX - tabs.maxX, 10, accuracy: 0.001)
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

    /// Shapes on the pickers: the cards have the glass menu's continuous 18 pt
    /// corners (Accepted 2026-11-10; owner, 11 Nov), their rows 13 pt, and the date
    /// picker's day marks whole superellipses on curve 1.4.
    func testPickerCardsRowsAndDayMarksFollowShapes() {
        let d = AtticDropdownMetrics.self
        let card = CGRect(x: 0, y: 0, width: 224, height: 260)
        XCTAssertEqual(AtticUnfoldShape(cornerRadius: d.cornerRadius).path(in: card),
                       Path(roundedRect: card, cornerRadius: 18, style: .continuous),
                       "the card: the glass menu's continuous 18 pt corners")
        let row = CGRect(x: 3, y: 3, width: 218, height: 32)
        XCTAssertEqual(AtticDropdownRow.highlightShape.path(in: row),
                       RoundedRectangle(cornerRadius: 13, style: .continuous).path(in: row), "a row: 13 pt continuous")
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

    private func withPanel(composerState: PanelComposerState? = nil,
                           _ body: (_ host: AtticPanelHostingView, _ state: PanelUIState, _ tasks: TasksPageState,
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
        XCTAssertTrue(draft.pages.requestNewNote()) // Chrome fixtures exercise the writing/Back scene.
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: settings, tasksPageState: tasksState, composerState: composerState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        // The hosted window is ordered front: report its reveal just as the
        // real controller does, so Calendar navigation is not treated as hidden.
        state.panelDidReveal()
        panel.orderFront(nil)
        defer {
            state.panelDidHide()
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

    /// XCUITest's hit point: the accessibility hit test at a control's
    /// centre must find the control. On CI the top row's controls and the
    /// page switch hit an unnamed node spanning their bar instead, so every
    /// one of them was "Not hittable".
    func testTheBarsControlsAreWhatTheAccessibilityHitTestFinds() throws {
        try withPanel { host, _, _, _, _, _ in
            var report: [String] = []
            for id in ["panel-pin-button", "tasks-page-now", "tasks-find-button", "tasks-new-task"] {
                let control = try XCTUnwrap(element(id, in: host), "\(id) is there")
                let frame = try XCTUnwrap(control.accessibilityFrame?())
                let hit = host.accessibilityHitTest(NSPoint(x: frame.midX, y: frame.midY)) as AnyObject?
                var found = false
                var node = hit
                for _ in 0..<4 {
                    if node === control { found = true }
                    node = node?.accessibilityParent?() as AnyObject?
                }
                if !found {
                    let children = ((hit?.accessibilityChildren?() ?? nil) ?? []).map { child -> String in
                        let c = child as AnyObject
                        return "\((c.accessibilityRole?() ?? nil)?.rawValue ?? "") \((c.accessibilityIdentifier?() ?? nil) ?? "") \(c.accessibilityFrame?() ?? .zero)"
                    }
                    report.append("\(id) \(frame) hit \(hit.map { String(describing: type(of: $0)) } ?? "nil") \((hit?.accessibilityRole?() ?? nil)?.rawValue ?? "") \(hit?.accessibilityFrame?() ?? .zero) children: \(children)")
                }
                XCTAssertTrue(found, "\(id): the hit test finds it")
            }
            if !report.isEmpty { print("HITTEST\n" + report.joined(separator: "\n")) }
        }
    }

    func testTasksTopRowBottomBarSearchAndTagBar() throws {
        // Glass controls, stated: GitHub's runners also turn Reduce
        // Transparency on, which draws every control flat (no raised
        // material, so no probe; w4 run 41198876185).
        AtticTransparencySeam.systemOverride = false
        defer { AtticTransparencySeam.systemOverride = nil }
        // The motion path, stated (GitHub's runners turn Reduce Motion on).
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        try withPanel { host, state, tasksState, store, _, chrome in
            state.selectSection(.tasks)
            spin(1.0)
            let layout = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size)
            let insets = layout.chromeInsets
            // Top row: Pin · · · Now Later Done, •••, Search.
            let top = try assertRow(["panel-pin-button", "tasks-page-tabs", "panel-more-button", "tasks-find-button"], in: host)
            XCTAssertEqual(top[0].minX, insets.leading, accuracy: 0.5, "Pin alone on the left")
            XCTAssertEqual(top[3].maxX, host.bounds.width - insets.trailing, accuracy: 0.5, "Search at the far right")
            XCTAssertEqual(top[1].width, TasksTopTabsMetrics.width(selection: .now), accuracy: 0.5)
            XCTAssertGreaterThan(top[1].minX - top[0].maxX, 20, "the switch sits on the right, Pin alone on the left")
            XCTAssertNil(element("tasks-view-options", in: host), "no filter button")
            // AppKit's drag lane keeps clear of the right-hand controls.
            let slot = top[1].maxX - TasksTopTabsMetrics.slotWidth
            XCTAssertEqual(chrome.modeDockWidth, host.bounds.width - insets.trailing - slot, accuracy: 1)
            // Bottom bar: the tag bar on the left, then "+" (Accepted
            // 2026-10-31 "Tall island": the page switch left the bar).
            XCTAssertNil(element("panel-section-picker", in: host), "no page switch in the bar")
            let bottom = try assertRow(["tasks-tag-bar", "tasks-new-task"], in: host)
            XCTAssertEqual(bottom[0].minX, insets.leading, accuracy: 0.5, "the tag bar on the left")
            XCTAssertEqual(bottom[1].maxX, host.bounds.width - insets.trailing, accuracy: 0.5, "\"+\" on the right")

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
            XCTAssertNil(element("panel-more-button", in: host), "••• folds away")
            XCTAssertEqual(chrome.modeDockWidth, host.bounds.width, "no drag lane under the open field")
        }
    }

    /// A real Escape in the open search field (the key-window route of
    /// `TasksRound12Tests`) closes the search and brings Pin back, its
    /// raised material told to draw its glass again.
    /// Under Reduce Motion the pin and its glass still fold away while the
    /// search is open (no glass or hit target left behind) and come back
    /// when it closes, at once rather than in the search's motion.
    func testUnderReduceMotionThePinsGlassFoldsWithTheSearchAndComesBack() throws {
        // Glass controls, stated: GitHub's runners also turn Reduce
        // Transparency on, which draws every control flat (no raised
        // material, so no probe; w4 run 41198876185).
        AtticTransparencySeam.systemOverride = false
        defer { AtticTransparencySeam.systemOverride = nil }
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        try withPanel { host, state, _, _, _, _ in
            state.selectSection(.tasks)
            spin(1.0)
            let searchButton = try XCTUnwrap(element("tasks-find-button", in: host))
            XCTAssertTrue(searchButton.accessibilityPerformPress?() ?? false)
            spin(0.8)
            XCTAssertNotNil(element("tasks-find", in: host), "the search is open")
            XCTAssertNil(element("panel-pin-button", in: host), "Pin folds away")
            XCTAssertEqual(AtticMaterialProbe.states["panel-pin"], .init(away: true, gone: true), "and so does its glass")
            let close = try XCTUnwrap(elements(host).first { ($0.accessibilityLabel?() ?? "") == "End search" })
            XCTAssertTrue(close.accessibilityPerformPress?() ?? false)
            spin(0.8)
            XCTAssertNotNil(element("panel-pin-button", in: host), "Pin is back")
            XCTAssertEqual(AtticMaterialProbe.states["panel-pin"], .init(away: false, gone: false), "and so is its glass")
        }
    }

    func testEscapeInTheSearchBringsThePinAndItsGlassBack() throws {
        // Glass controls, stated: GitHub's runners also turn Reduce
        // Transparency on, which draws every control flat (no raised
        // material, so no probe; w4 run 41198876185).
        AtticTransparencySeam.systemOverride = false
        defer { AtticTransparencySeam.systemOverride = nil }
        // The motion path, stated (GitHub's runners turn Reduce Motion on).
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
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
            let notesTop = try assertRow(["panel-pin-button", "panel-more-button", "notes-search-button"], in: host)
            XCTAssertEqual(notesTop[2].maxX, host.bounds.width - insets.trailing, accuracy: 0.5)
            let notesBottom = try assertRow(["notes-tag-bar", "notes-new-note"], in: host)
            XCTAssertEqual(notesBottom[0].minX, insets.leading, accuracy: 0.5)
            let tag = try XCTUnwrap(frame(of: "notes-tag-bar-launch", in: host))
            XCTAssertEqual(tag.height, 21, accuracy: 0.5, "21 pt tags")

            state.selectSection(.calendar)
            spin(1.5)
            let calTop = try assertRow(["panel-pin-button", "calendar-month-pill", "panel-more-button",
                                        "calendar-search-button"], in: host)
            XCTAssertEqual(calTop[1].minX - calTop[0].maxX, 8, accuracy: 1, "the month 16 px after the pin")
            // ‹ › in one capsule before •••: 21 pt cells in its 3 pt inset.
            // (Each cell answers a 28 pt target around its 21 pt face.)
            let previous = try XCTUnwrap(frame(of: "calendar-previous", in: host))
            let next = try XCTUnwrap(frame(of: "calendar-next", in: host))
            XCTAssertEqual(previous.midY, calTop[2].midY, accuracy: 0.5, "on the top row")
            XCTAssertEqual(next.midX - previous.midX, 21 + 1, accuracy: 0.5, "21 pt cells 1 pt apart")
            XCTAssertGreaterThan(previous.midX - 10.5, calTop[1].maxX)
            XCTAssertEqual(calTop[2].minX - (next.midX + 10.5), 3 + 10, accuracy: 0.5, "the capsule's inset, then the switch's gap")
            // Today shows only while another day is selected (Accepted
            // "Calendar page", the Today button), so the row is "+" alone
            // (Accepted 2026-10-31 "Tall island": no switch in the bar).
            XCTAssertNil(element("calendar-today", in: host), "no Today button while today is selected")
            XCTAssertNil(element("panel-section-picker", in: host), "no page switch in the bar")
            _ = try assertRow(["calendar-new-task"], in: host)
            let today = DueDay(date: Date(), calendar: CalendarMonthMath.calendar())
            let other = try XCTUnwrap(DueDay(year: today.year, month: today.month, day: today.day == 1 ? 2 : today.day - 1))
            let otherCell = try XCTUnwrap(element("calendar-day-\(other.rawValue)", in: host))
            XCTAssertTrue(otherCell.accessibilityPerformPress?() ?? false)
            spin(1.0)
            // Accepted 2026-11-01 Adaptive picks C3 moves Today between
            // the arrows; the bottom bar keeps only the add control.
            let navigation = try ["calendar-previous", "calendar-today", "calendar-next"].map {
                try XCTUnwrap(frame(of: $0, in: host))
            }
            // These are the capsule's cells (21 pt faces; the arrows have
            // 28 pt hit halos), not separate 27 pt raised controls.
            for cell in navigation { XCTAssertEqual(cell.midY, calTop[2].midY, accuracy: 0.5) }
            XCTAssertEqual(navigation[1].height, 21, accuracy: 0.5)
            XCTAssertEqual(navigation[1].width, 44, accuracy: 0.5)
            XCTAssertEqual(navigation[1].midX - navigation[0].midX, 33.5, accuracy: 0.5)
            XCTAssertEqual(navigation[2].midX - navigation[1].midX, 33.5, accuracy: 0.5)
            let calBottom = try assertRow(["calendar-new-task"], in: host)
            XCTAssertGreaterThan(calBottom[0].minY, navigation[1].maxY)
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

    /// Expanded things close with one click (owner, 2026-10-31): an open
    /// search has an × at its end that ends it like Escape, and a click on
    /// the page's empty space ends it too, on Tasks, Notes and Calendar.
    func testTheSearchClosesFromItsCrossAndFromAClickOnEmptySpace() throws {
        try withPanel { host, state, tasksState, store, draft, _ in
            let window = try XCTUnwrap(host.window)
            @MainActor func click(_ point: CGPoint) throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0)))
                }
                spin(0.6)
            }
            let pages: [(PanelSection, String, String)] = [(.tasks, "tasks-find-button", "tasks-find"),
                                                           (.notes, "notes-search-button", "notes-search"),
                                                           (.calendar, "calendar-search-button", "calendar-search")]
            for (section, button, field) in pages {
                state.selectSection(section)
                spin(1.0)
                if section == .notes { XCTAssertTrue(draft.pages.showLibrary()); spin(0.8) }
                @MainActor func open() throws {
                    XCTAssertTrue(try XCTUnwrap(element(button, in: host), "\(section): the search button").accessibilityPerformPress?() ?? false)
                    spin(0.8)
                    XCTAssertNotNil(element(field, in: host), "\(section): the search is open")
                }
                try open()
                let cross = try XCTUnwrap(elements(host).first { ($0.accessibilityLabel?() ?? "") == "End search" },
                                          "\(section): an × at the field's end")
                let crossFrame = try XCTUnwrap(frame(ofElement: cross, in: host))
                let insets = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size).chromeInsets
                XCTAssertEqual(crossFrame.maxX, host.bounds.width - insets.trailing, accuracy: 0.5, "\(section): at the trailing end")
                window.makeKey()
                try click(CGPoint(x: crossFrame.midX, y: host.bounds.height - crossFrame.midY))
                XCTAssertNil(element(field, in: host), "\(section): the × ends the search")
                XCTAssertNotNil(element(button, in: host), "\(section): and the button is back")

                try open()
                window.makeKey()
                if section == .tasks {
                    // A row takes its own click: a search with words in it
                    // stays (an empty one may end as its field loses focus).
                    tasksState.model(for: store, toasts: nil).setSearchQuery("books", for: .now)
                    spin(0.5)
                    let row = try XCTUnwrap(elements(host).first { ($0.accessibilityLabel?() ?? "").hasPrefix("Return books") }
                        .flatMap { frame(ofElement: $0, in: host) }, "a row")
                    try click(CGPoint(x: row.midX, y: host.bounds.height - row.midY))
                    XCTAssertNotNil(element(field, in: host), "a click on a row keeps the search")
                }
                // Empty page space, low in the list, above the bottom bar
                // (window coordinates, from the bottom).
                try click(CGPoint(x: host.bounds.midX, y: 150))
                XCTAssertNil(element(field, in: host), "\(section): a click on empty space ends the search")
            }
        }
    }

    /// Square controls are not circles (owner, 2026-10-31; Accepted
    /// "Shapes"): every raised control on the panel, on every page and bar,
    /// the composer, "+" and the note and task pages' bottom buttons
    /// included, draws on curve 1.4, never Apple's continuous corner.
    func testEveryRaisedControlOnThePanelIsOnCurveOnePointFour() throws {
        // Glass controls, stated: GitHub's runners also turn Reduce
        // Transparency on, which draws every control flat (no raised
        // material, so no probe; w4 run 41198876185).
        AtticTransparencySeam.systemOverride = false
        defer { AtticTransparencySeam.systemOverride = nil }
        AtticMaterialProbe.resetCorners()
        try withPanel { host, state, tasks, store, _, _ in
            for section in [PanelSection.notes, .calendar, .tasks] {
                state.selectSection(section)
                spin(1.0)
            }
            // A task's page (its ‹ and Aa).
            let model = tasks.model(for: store, toasts: nil)
            model.openPage(try XCTUnwrap(model.rows(for: .now).first?.id))
            spin(1.0)
            host.display()
        }
        XCTAssertGreaterThan(AtticMaterialProbe.corners.count, 10, "controls drawn")
        XCTAssertEqual(AtticMaterialProbe.corners.filter { $0 == nil }.count, 0, "no control on the continuous (circle) corner")
    }

    /// The notes bar's Back (‹) slides out under the bar's edge on a
    /// revealed shape; at rest it must be the curve-1.4 superellipse the
    /// other square controls draw (Accepted "Shapes": a square control is a
    /// whole superellipse), not Apple's continuous corner, which draws a
    /// 27 pt square with a 13.5 pt radius as a circle (owner's notes, 1 Nov).
    func testTheNotesBackButtonIsASuperellipseNotACircle() throws {
        AtticTransparencySeam.systemOverride = false
        defer { AtticTransparencySeam.systemOverride = nil }
        AtticMaterialProbe.resetCorners()
        try withPanel { host, state, _, _, _, _ in
            state.selectSection(.notes)
            spin(1.5)
            XCTAssertNotNil(frame(of: "notes-all-notes", in: host), "Back shows")
            host.display()
        }
        let side = NotesBarMetrics.control
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let atRest = AtticMaterialProbe.revealed.filter { $0.leading == 0 && $0.trailing == 0 }
        XCTAssertFalse(atRest.isEmpty, "Back drew its revealed glass")
        // Containment on a 0.25 pt grid: the two paths cover the same points.
        func differences(_ a: Path, _ b: Path) -> Int {
            var count = 0
            for i in 0..<Int(side * 4) {
                for j in 0..<Int(side * 4) {
                    let point = CGPoint(x: (CGFloat(i) + 0.5) / 4, y: (CGFloat(j) + 0.5) / 4)
                    if a.contains(point) != b.contains(point) { count += 1 }
                }
            }
            return count
        }
        let superellipse = AtticControlShape.shape(cornerRadius: NotesBarMetrics.radius, exponent: AtticShape.controlExponent)
            .path(in: rect)
        XCTAssertGreaterThan(differences(superellipse, Circle().path(in: rect)), 20, "the two curves differ at this size")
        for shape in atRest {
            XCTAssertEqual(shape.exponent, AtticShape.controlExponent, "the inherited curve")
            XCTAssertEqual(differences(shape.path(in: rect), superellipse), 0, "at rest: the superellipse")
        }
        // Sliding out, the part still inside keeps the same curve.
        for shape in atRest.prefix(1) {
            var sliding = shape
            sliding.leading = 6
            let part = CGRect(x: 6, y: 0, width: side - 6, height: side)
            let expected = AtticControlShape.shape(cornerRadius: min(NotesBarMetrics.radius, part.width / 2),
                                                   exponent: AtticShape.controlExponent).path(in: part)
            XCTAssertEqual(differences(sliding.path(in: rect), expected), 0, "sliding: the same curve")
        }
    }

    // MARK: Shapes: the surfaces still left (Accepted "Shapes", still to build 31 Oct)

    /// Containment on a 0.25 pt grid over each corner's box (the sides
    /// between the corners are straight in every one of these shapes).
    private func cornerDifferences(_ a: Path, _ b: Path, in rect: CGRect, box: CGFloat) -> Int {
        let steps = Int(box * 4)
        var count = 0
        for (x0, y0) in [(rect.minX, rect.minY), (rect.maxX - box, rect.minY),
                         (rect.minX, rect.maxY - box), (rect.maxX - box, rect.maxY - box)] {
            for i in 0..<steps {
                for j in 0..<steps {
                    let point = CGPoint(x: x0 + (CGFloat(i) + 0.5) / 4, y: y0 + (CGFloat(j) + 0.5) / 4)
                    if a.contains(point) != b.contains(point) { count += 1 }
                }
            }
        }
        return count
    }

    /// The drawn outline is the expected squircle or curve-1.4 shape, and
    /// visibly not the old continuous rounded rectangle of the same radius.
    private func assertOutline(_ shape: AtticControlOutline, in size: CGSize, radius: CGFloat, exponent: CGFloat,
                               _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let rect = CGRect(origin: .zero, size: size)
        let box = min(radius + 2, size.width / 2, size.height / 2)
        let expected = Squircle(cornerRadius: radius, exponent: exponent).path(in: rect)
        let old = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        XCTAssertGreaterThan(cornerDifferences(expected, old, in: rect, box: box), 4, "\(name): the grid tells the two apart",
                             file: file, line: line)
        XCTAssertEqual(shape.cornerRadius, radius, "\(name): radius", file: file, line: line)
        XCTAssertEqual(cornerDifferences(shape.path(in: rect), expected, in: rect, box: box), 0, "\(name): the shape",
                       file: file, line: line)
    }

    /// Apple's continuous rounded rectangle (Corners, Accepted 2026-11-13),
    /// told apart from the surface squircle at the same radius.
    private func assertContinuousOutline(_ shape: AtticControlOutline, in size: CGSize, radius: CGFloat,
                                         _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let rect = CGRect(origin: .zero, size: size)
        let box = min(radius + 2, size.width / 2, size.height / 2)
        let expected = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        let squircle = Squircle(cornerRadius: radius, exponent: AtticShape.surfaceExponent).path(in: rect)
        XCTAssertGreaterThan(cornerDifferences(expected, squircle, in: rect, box: box), 4, "\(name): the grid tells the two apart",
                             file: file, line: line)
        XCTAssertNil(shape.exponent, "\(name): continuous", file: file, line: line)
        XCTAssertEqual(shape.cornerRadius, radius, "\(name): radius", file: file, line: line)
        XCTAssertEqual(cornerDifferences(shape.path(in: rect), expected, in: rect, box: box), 0, "\(name): the shape",
                       file: file, line: line)
    }

    private func withSystemLooksStated(_ body: () throws -> Void) rethrows {
        // GitHub's runners turn both on; these shapes must not depend on them.
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try body()
    }

    func testNoteObjectCardsAreSquircles() {
        withSystemLooksStated {
            let m = AtticNoteObjectMetrics.self
            let surface = AtticShape.surfaceExponent
            assertOutline(m.cardShape, in: CGSize(width: 300, height: m.cardHeight), radius: AtticRadius.noteBlock,
                          exponent: surface, "file card")
            assertOutline(m.blockShape, in: CGSize(width: 300, height: m.blockCardHeight), radius: AtticRadius.noteBlock,
                          exponent: surface, "block file card")
            // The selected object's ring hugs the card on its own curve,
            // its stroke wholly inside the edge.
            let rect = CGRect(x: 0, y: 0, width: 300, height: m.cardHeight)
            let ring = NoteObjectSelectionView.ringPath(objectRect: rect, shape: m.cardShape)
            let expected = Squircle(cornerRadius: AtticRadius.noteBlock, exponent: surface).inset(by: m.ringWidth / 2).path(in: rect)
            var differ = 0
            for i in 0..<48 {
                for j in 0..<48 {
                    let point = CGPoint(x: (CGFloat(i) + 0.5) / 4, y: (CGFloat(j) + 0.5) / 4)
                    if ring.contains(point) != expected.contains(point) { differ += 1 }
                }
            }
            XCTAssertEqual(differ, 0, "the ring follows the card's squircle")
        }
    }

    func testTheToastIsACapsuleOnCurve14() {
        withSystemLooksStated {
            let height = AtticControlSize.toastHeight
            let control = AtticShape.controlExponent
            assertOutline(AtticUndoToast.shape, in: CGSize(width: 220, height: height),
                          radius: AtticRadius.control(height: height), exponent: control, "toast")
            let inner = AtticRadius.control(height: height) - AtticControlSize.capsuleInset
            assertOutline(AtticUndoToast.buttonShape(), in: CGSize(width: 56, height: AtticControlSize.smallHeight),
                          radius: inner, exponent: control, "Undo, concentric")
        }
    }

    func testTheDragTilesAreTheRowsContinuousShape() {
        withSystemLooksStated {
            let surface = AtticShape.surfaceExponent
            assertContinuousOutline(AtticReorderLiftModifier.shape, in: CGSize(width: 288, height: 36), radius: AtticRadius.row,
                                    "the lifted task")
            assertContinuousOutline(AtticCarryPreview.cardShape, in: CGSize(width: 200, height: 36), radius: AtticRadius.row,
                                    "the carry card")
            assertContinuousOutline(TasksDragOut.labelShape, in: CGSize(width: 140, height: 28), radius: AtticRadius.row,
                                    "the drag label")
            assertContinuousOutline(NoteThumbnailMetrics.shape, in: NoteThumbnailMetrics.size, radius: NoteThumbnailMetrics.radius,
                                    "the note thumbnail")
            // A file dragged over a note carries the file card's look.
            assertOutline(AtticNoteObjectMetrics.cardShape,
                          in: CGSize(width: AtticNoteObjectMetrics.carryWidth, height: AtticNoteObjectMetrics.carryHeight),
                          radius: AtticRadius.noteBlock, exponent: surface, "the note carry card")
        }
    }

    func testThePickerFieldIsAConcentricSquircle() {
        withSystemLooksStated {
            let d = AtticDropdownMetrics.self
            let surface = AtticShape.surfaceExponent
            assertOutline(d.fieldShape, in: CGSize(width: 220, height: d.fieldHeight),
                          // The card's shell took the glass menu's 18 pt; its contents stay as they were.
                          radius: AtticRadius.concentric(outer: AtticRadius.menu, padding: d.inset + d.fieldInset),
                          exponent: surface, "the field")
            // The composer's short lists light their rows like the menus.
            let fill = AtticControlSize.smallHeight - AtticPickerMetrics.highlightGap
            assertOutline(AtticChoiceRow.highlightShape(radius: AtticRadius.control(height: fill)),
                          in: CGSize(width: 140, height: fill), radius: d.highlightRadius, exponent: surface, "a lit row")
        }
    }

    func testTheSettingsCardsAreSquircles() {
        withSystemLooksStated {
            let surface = AtticShape.surfaceExponent
            assertOutline(AtticGroupCardShape.shape, in: CGSize(width: 420, height: 160), radius: AtticRadius.card,
                          exponent: surface, "a group card")
            assertOutline(AtticContentCard<EmptyView>.shape, in: CGSize(width: 480, height: 400), radius: AtticRadius.contentCard,
                          exponent: surface, "the page's card")
        }
    }

    // MARK: Shapes: what the views draw (wave 2 review 3)

    /// A render's alpha at 4 px a point: one pixel per cell of the 0.25 pt
    /// grid the outline tests use.
    private struct AlphaGrid {
        static let scale: CGFloat = 4
        let width: Int, height: Int, bytes: [UInt8]
        init(_ image: CGImage) {
            width = image.width; height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            buffer.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            bytes = buffer
        }
        /// Row 0 is the image's top.
        func alpha(_ x: Int, _ y: Int) -> CGFloat { CGFloat(bytes[((height - 1 - y) * width + x) * 4 + 3]) / 255 }
    }

    /// How far the drawn coverage is from each candidate outline over the
    /// corner boxes (summed |alpha - inside|), and how many grid cells the
    /// two candidates disagree on. Antialiasing costs both alike, so a
    /// render of `expected` is nearer it by about the cells they differ on.
    private func cornerDistances(_ grid: AlphaGrid, normal: CGFloat, rect: CGRect, box: CGFloat,
                                 expected: (CGPoint) -> Bool, old: (CGPoint) -> Bool)
        -> (expected: CGFloat, old: CGFloat, cells: Int) {
        let s = AlphaGrid.scale, steps = Int(box * s)
        var toExpected: CGFloat = 0, toOld: CGFloat = 0, cells = 0
        for (x0, y0) in [(rect.minX, rect.minY), (rect.maxX - box, rect.minY),
                         (rect.minX, rect.maxY - box), (rect.maxX - box, rect.maxY - box)] {
            for i in 0..<steps {
                for j in 0..<steps {
                    let point = CGPoint(x: x0 + (CGFloat(i) + 0.5) / s, y: y0 + (CGFloat(j) + 0.5) / s)
                    let px = Int(point.x * s), py = Int(point.y * s)
                    guard px >= 0, py >= 0, px < grid.width, py < grid.height else { continue }
                    let a = min(1, grid.alpha(px, py) / normal)
                    let e = expected(point), o = old(point)
                    toExpected += abs(a - (e ? 1 : 0))
                    toOld += abs(a - (o ? 1 : 0))
                    if e != o { cells += 1 }
                }
            }
        }
        return (toExpected, toOld, cells)
    }

    private func assertDrawsExpected(_ d: (expected: CGFloat, old: CGFloat, cells: Int), _ name: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        print("ATTIC_SHAPE_RENDER \(name) to_expected=\(d.expected) to_old=\(d.old) cells=\(d.cells)")
        XCTAssertGreaterThan(d.cells, 4, "\(name): the grid tells the two apart", file: file, line: line)
        XCTAssertGreaterThan(d.old - d.expected, CGFloat(d.cells) / 2,
                             "\(name): the view draws the squircle, not the old rounded rectangle", file: file, line: line)
    }

    private func renderSwiftUI<V: View>(_ view: V) throws -> (AlphaGrid, CGSize) {
        let renderer = ImageRenderer(content: view.atticDesign(AtticDesignContext(mode: .light)))
        renderer.scale = AlphaGrid.scale
        let image = try XCTUnwrap(renderer.cgImage)
        return (AlphaGrid(image), CGSize(width: CGFloat(image.width) / AlphaGrid.scale,
                                         height: CGFloat(image.height) / AlphaGrid.scale))
    }

    private func assertFillDrawn<V: View>(_ view: V, radius: CGFloat, exponent: CGFloat, _ name: String,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let (grid, size) = try renderSwiftUI(view)
        let rect = CGRect(origin: .zero, size: size)
        let normal = grid.alpha(grid.width / 2, grid.height / 2)
        XCTAssertGreaterThan(normal, 0.05, "\(name): the fill is drawn", file: file, line: line)
        let expected = Squircle(cornerRadius: radius, exponent: exponent).path(in: rect)
        let old = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        assertDrawsExpected(cornerDistances(grid, normal: normal, rect: rect,
                                            box: min(radius + 2, size.width / 2, size.height / 2),
                                            expected: { expected.contains($0) }, old: { old.contains($0) }),
                            name, file: file, line: line)
    }

    func testTheGroupCardDrawsItsSquircleEvenClampedOnASingleRow() throws {
        try withSystemLooksStated {
            for height: CGFloat in [160, 40] {
                try assertFillDrawn(AtticGroupCard { Color.clear.frame(width: 300, height: height) },
                                    radius: AtticRadius.groupCard, exponent: AtticShape.surfaceExponent,
                                    "group card \(Int(height)) pt")
            }
        }
    }

    func testTheToastDrawsItsCurve14Capsule() throws {
        try withSystemLooksStated {
            let height = AtticControlSize.toastHeight
            try assertFillDrawn(AtticUndoToast(message: "Moved to Done", onUndo: {}),
                                radius: AtticRadius.control(height: height), exponent: AtticShape.controlExponent, "toast")
        }
    }

    func testASelectedFileCardsRingIsDrawnOnTheCardsSquircle() throws {
        try withSystemLooksStated {
            let file = NoteBlock.file(attachmentID: UUID(), filename: "Ring.txt", contentTypeIdentifier: "public.plain-text",
                                      byteCount: 12)
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Ring"), file, .text("after")]))
            let (scrollView, textView) = engine.makeView()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scrollView.frame = try XCTUnwrap(window.contentView).bounds
            window.contentView?.addSubview(scrollView)
            textView.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
            textView.layoutSubtreeIfNeeded()
            let controls = NoteObjectControls(engine: engine, textView: textView)
            engine.refreshObjectFaces()
            defer { controls.invalidate(); window.close() }
            let range = try XCTUnwrap(engine.objectPlacement(try XCTUnwrap(file.id))?.1)
            textView.setSelectedRange(range)
            controls.updateSelection()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            func rings(in view: NSView) -> [NoteObjectSelectionView] {
                view.subviews.flatMap { ($0 as? NoteObjectSelectionView).map { [$0] } ?? [] + rings(in: $0) }
            }
            let ring = try XCTUnwrap(rings(in: try XCTUnwrap(window.contentView)).first, "the ring is shown")
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                     pixelsWide: Int(ring.bounds.width * AlphaGrid.scale),
                                                     pixelsHigh: Int(ring.bounds.height * AlphaGrid.scale),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = ring.bounds.size
            ring.cacheDisplay(in: ring.bounds, to: rep)
            let grid = AlphaGrid(try XCTUnwrap(rep.cgImage))
            let m = AtticNoteObjectMetrics.self
            let card = ring.bounds.insetBy(dx: m.resizeHitTarget / 2, dy: m.resizeHitTarget / 2)
            let width = m.ringWidth, radius = AtticRadius.noteBlock
            let expected = Squircle(cornerRadius: radius, exponent: AtticShape.surfaceExponent).inset(by: width / 2)
                .path(in: card).cgPath.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
            let old = RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: width / 2)
                .path(in: card).cgPath.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
            var peak: CGFloat = 0
            for x in 0..<grid.width { for y in 0..<grid.height { peak = max(peak, grid.alpha(x, y)) } }
            XCTAssertGreaterThan(peak, 0.5, "the ring is drawn")
            assertDrawsExpected(cornerDistances(grid, normal: peak, rect: card, box: radius + 2,
                                                expected: { expected.contains($0) }, old: { old.contains($0) }),
                                "file card ring")
        }
    }

    // MARK: The "+" card (Phase B)

    /// 4 Nov #16: an outside press may already be folding the card when a
    /// task page opens. Its Back row must be reachable in the first frame;
    /// the pending fold cannot continue over the task page.
    func testOpeningTaskPageInterruptsAnAlreadyFoldingComposer() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        let composerState = PanelComposerState()
        try withPanel(composerState: composerState) { host, state, _, store, _, _ in
            let add = try XCTUnwrap(element("tasks-new-task", in: host))
            XCTAssertTrue(add.accessibilityPerformPress?() ?? false)
            spin(0.45)
            let model = try XCTUnwrap(composerState.model)
            XCTAssertTrue(model.isOpen)
            XCTAssertTrue(ComposerOverlay.isPresented)
            model.close() // outside press begins the ordinary fold
            spin(0.02)
            XCTAssertFalse(model.isOpen)
            XCTAssertTrue(ComposerOverlay.isPresented, "the ordinary close is still folding")

            let taskID = try XCTUnwrap(store.tasks.first?.id)
            state.openTaskNote(taskID, from: .tasks, row: taskID)
            spin(0.04)
            XCTAssertFalse(ComposerOverlay.isPresented, "the route must interrupt the in-flight fold at once")
            spin(0.8)
            XCTAssertNotNil(element("task-note-back", in: host), "Back is reachable")
            XCTAssertNil(element("panel-more-button", in: host), "the list's menu gives way to the task page")
        }
    }

    private func barFrames(_ ids: [String], in host: AtticPanelHostingView) throws -> [CGRect] {
        try ids.map { try XCTUnwrap(frame(of: $0, in: host), "\($0) is drawn") }
    }

    private func assertSameFrames(_ a: [CGRect], _ b: [CGRect], _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.minX, y.minX, accuracy: 0.5, message, file: file, line: line)
            XCTAssertEqual(x.minY, y.minY, accuracy: 0.5, message, file: file, line: line)
            XCTAssertEqual(x.width, y.width, accuracy: 0.5, message, file: file, line: line)
        }
    }

    func testTheTasksPlusGrowsIntoTheCardOnItsCornerAndTheBarStaysStill() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        try withPanel { host, state, _, _, _, _ in
            state.selectSection(.tasks)
            spin(1.0)
            let ids = ["tasks-tag-bar", "tasks-new-task"]
            let before = try barFrames(ids, in: host)
            XCTAssertNil(element("composer-card", in: host), "no card before \"+\"")
            let plus = try XCTUnwrap(element("tasks-new-task", in: host))
            XCTAssertTrue(plus.accessibilityPerformPress?() ?? false)
            spin(1.0)
            let card = try XCTUnwrap(frame(of: "composer-card", in: host), "\"+\" opens the card")
            // The AX frame includes the card's padding; the outer surface
            // shares the bottom-trailing corner of the "+" (P4).
            XCTAssertEqual(card.width, ComposerMetrics.width, accuracy: 0.5, "grown to the full card")
            XCTAssertEqual(card.maxX, before[1].maxX, accuracy: 0.5, "the card grows from the \"+\"'s corner")
            XCTAssertEqual(card.maxY, before[1].maxY, accuracy: 0.5, "the card grows from the \"+\"'s corner")
            XCTAssertEqual(element("composer-card", in: host)?.accessibilityLabel?(), "New Task")
            // P4: the card has the bar's row; its pills and "+" are under it.
            XCTAssertNil(frame(of: "tasks-tag-bar", in: host))
            XCTAssertNil(frame(of: "tasks-new-task", in: host))
            // A page switch closes it; the bar comes back where it was.
            state.selectSection(.calendar)
            spin(1.0)
            XCTAssertNil(element("composer-card", in: host), "the card shrinks back into the \"+\"")
            state.selectSection(.tasks)
            spin(1.0)
            assertSameFrames(before, try barFrames(ids, in: host), "the bar is back where it was")
        }
    }

    /// Review B-3/B-5: sampled through the grow, the shrink and a page
    /// switch, one "+" surface is drawn at a time, its corner never moves,
    /// and the bottom bar and top row stay still.
    func testTheGrowAndShrinkDrawOneSurfaceOnAFixedCornerWithTheBarsStill() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try withPanel { host, state, _, _, _, _ in
            state.selectSection(.tasks)
            spin(1.0)
            let still = ["panel-pin-button"]
            let before = try barFrames(still, in: host)
            let plusFrame = try XCTUnwrap(frame(of: "tasks-new-task", in: host))
            ComposerOverlay.surfaces = []
            ComposerOverlay.corners = []
            var doubled = 0
            var samples = 0
            // P4: folding, the bar's "+" fades back as the card fades out.
            var counting = true
            // Terra 9 (batch 3): the motion is stepped, never sampled in
            // real time. As the page switch's test does, the presentation
            // is paused and its clock stepped 60 frames a second through
            // 0.8 s, so a slow host can neither skip frames nor fit fewer.
            @MainActor func sample(frames: Int = 48, plus: String, _ start: () throws -> Void) throws {
                let layer = try XCTUnwrap(host.layer)
                let begin = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = begin
                defer { layer.speed = 1; layer.timeOffset = 0 }
                host._renderForTest(interval: 0)
                try start()
                for step in 0...frames {
                    // The grow starts one turn after the "+" is handed over.
                    RunLoop.main.run(until: Date())
                    host._renderForTest(interval: step == 0 ? 0 : 1.0 / 60)
                    layer.timeOffset = begin + Double(step) / 60
                    CATransaction.flush()
                    samples += 1
                    if counting, ComposerOverlay.isPresented && PanelSharedBottomBar.drawsPlus { doubled += 1 }
                    assertSameFrames(before, try barFrames(still, in: host), "the bars stay still (frame \(step))")
                    // While the card has the row, "+" is under it (P4).
                    if let now = frame(of: plus, in: host) {
                        XCTAssertEqual(now.maxX, plusFrame.maxX, accuracy: 0.5)
                        XCTAssertEqual(now.maxY, plusFrame.maxY, accuracy: 0.5)
                    }
                }
            }
            let plus = try XCTUnwrap(element("tasks-new-task", in: host))
            try sample(plus: "tasks-new-task") { XCTAssertTrue(plus.accessibilityPerformPress?() ?? false) }
            let opening = ComposerOverlay.surfaces
            XCTAssertTrue(opening.contains { $0.size.width > 30 && $0.size.width < 285 },
                          "an in-between frame on the way open: \(opening.map(\.size.width))")
            XCTAssertEqual(opening.last?.size.width ?? 0, 289, accuracy: 0.5)
            ComposerOverlay.surfaces = []
            counting = false
            // Closing by a press outside the card (Accepted 2026-11-04). A
            // page switch closes it at once instead (ComposerTests).
            @MainActor func watcher(in view: NSView?) -> ComposerOutsideClick.Watcher? {
                guard let view else { return nil }
                if let found = view as? ComposerOutsideClick.Watcher { return found }
                for child in view.subviews { if let found = watcher(in: child) { return found } }
                return nil
            }
            let outside = try XCTUnwrap(watcher(in: host.window?.contentView ?? host), "the card watches for a press outside it")
            try sample(plus: "tasks-new-task") { outside.close() }
            spin(0.3)
            let closing = ComposerOverlay.surfaces
            XCTAssertTrue(closing.contains { $0.size.width > 30 && $0.size.width < 285 },
                          "an in-between frame on the way back: \(closing.map(\.size.width))")
            XCTAssertEqual(doubled, 0, "never two \"+\"s while the card opens: the bar's own fades out under it")
            XCTAssertFalse(ComposerOverlay.isPresented)
            XCTAssertTrue(PanelSharedBottomBar.drawsPlus, "the bar's \"+\" is back once the shrink ends")
            // The card is kept built (A11), so its corner reports only if it
            // moves: any report must still be the "+"'s corner.
            for corner in ComposerOverlay.corners {
                XCTAssertEqual(corner.x, plusFrame.maxX, accuracy: 1, "the corner stays on the \"+\"")
                XCTAssertEqual(corner.y, plusFrame.maxY, accuracy: 1, "the corner stays on the \"+\"")
            }
        }
    }

    /// Accepted 2026-11-03 (P4): the card opens onto the bar's own row (its
    /// bottom-trailing corner on the "+"'s), the tag pills and "+" go under
    /// it, nothing dims, the list keeps the card's height clear, and folding
    /// gives the row back.
    func testTheCardTakesTheBarsRowAndTheListMakesRoom() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        try withPanel { host, state, _, _, _, _ in
            state.selectSection(.tasks)
            spin(1.0)
            let plusFrame = try XCTUnwrap(frame(of: "tasks-new-task", in: host))
            XCTAssertNotNil(element("tasks-tag-bar-books", in: host))
            ComposerOverlay.corners = []
            PanelComposerRoom.lastSet = nil
            XCTAssertTrue(try XCTUnwrap(element("tasks-new-task", in: host)).accessibilityPerformPress?() ?? false)
            spin(0.3)
            // The card AX frame is the complete 90 pt surface, padding included.
            let card = try XCTUnwrap(frame(of: "composer-card", in: host))
            XCTAssertEqual(card.width, ComposerMetrics.width, accuracy: 0.5)
            XCTAssertEqual(card.maxX, plusFrame.maxX, accuracy: 0.5, "it grows from the \"+\" corner")
            XCTAssertEqual(card.maxY, plusFrame.maxY, accuracy: 0.5, "its bottom edge is the bar's bottom edge")
            XCTAssertEqual(card.height, ComposerMetrics.height, accuracy: 1)
            XCTAssertNil(element("tasks-tag-bar-books", in: host), "the tag pills go under the card")
            XCTAssertNil(element("tasks-new-task", in: host), "and so does \"+\"")
            let room = try XCTUnwrap(PanelComposerRoom.lastSet)
            XCTAssertTrue(room.open)
            XCTAssertEqual(room.height, ComposerMetrics.height, accuracy: 1, "the list keeps the card's height clear")
            XCTAssertEqual(TasksViewport.composerExtra(room: room.height, stackHeight: TasksViewport.reservedStack),
                           max(0, room.height - max(TasksViewport.reservedStack, AtticControlSize.addBarHeight)))
            state.selectSection(.calendar)
            spin(0.3)
            state.selectSection(.tasks)
            spin(0.5)
            XCTAssertNil(element("composer-card", in: host))
            XCTAssertNotNil(element("tasks-tag-bar-books", in: host), "folding gives the row back")
            XCTAssertNotNil(element("tasks-new-task", in: host))
            XCTAssertEqual(PanelComposerRoom.lastSet?.height, 0)
            XCTAssertEqual(PanelComposerRoom.lastSet?.open, false)
        }
    }

    func testFollowupNotesPlusOpensTheNoteCardFromWritingAndLibrary() throws {
        for library in [true, false] {
            try withPanel { host, state, _, _, draft, _ in
                state.selectSection(.notes)
                spin(1.5)
                XCTAssertTrue(draft.pages.showLibrary())
                spin(0.5)
                if !library {
                    let note = try XCTUnwrap(draft.noteStore.notes.first { $0.title == "Launch plan" })
                    XCTAssertTrue(draft.pages.open(noteID: note.id))
                    draft.pages.dismissLibrary()
                    spin(0.5)
                }
                let beforeNote = draft.pages.active?.noteID
                let beforeDocument = draft.pages.active?.engine.document()
                XCTAssertEqual(draft.pages.isLibraryPresented, library)
                let plus = try XCTUnwrap(element("notes-new-note", in: host))
                XCTAssertTrue(plus.accessibilityPerformPress?() ?? false)
                spin(0.7)
                XCTAssertEqual(element("composer-card", in: host)?.accessibilityLabel?(), "New Note",
                               "Notes + opens the shared card on its own kind")
                XCTAssertEqual(draft.pages.isLibraryPresented, library, "the card leaves its underlying page in place")
                XCTAssertEqual(draft.pages.active?.noteID, beforeNote, "the card does not replace the current note")
                XCTAssertEqual(draft.pages.active?.engine.document(), beforeDocument, "the current writing is retained")
                XCTAssertEqual(state.selectedSection, .notes)
            }
        }
    }

    func testTheCalendarPlusOpensTheCardOnEventAndReduceMotionIsInstant() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        try withPanel { host, state, _, _, _, _ in
            state.selectSection(.calendar)
            spin(1.0)
            let plusFrame = try XCTUnwrap(frame(of: "calendar-new-task", in: host))
            let plus = try XCTUnwrap(element("calendar-new-task", in: host))
            XCTAssertTrue(plus.accessibilityPerformPress?() ?? false)
            spin(0.02)
            let card = try XCTUnwrap(frame(of: "composer-card", in: host), "Reduce Motion: the card is there at once")
            XCTAssertEqual(card.width, ComposerMetrics.width, accuracy: 0.5, "Reduce Motion: full card at once")
            XCTAssertEqual(card.maxX, plusFrame.maxX, accuracy: 0.5)
            XCTAssertEqual(element("composer-card", in: host)?.accessibilityLabel?(), "New Event")
            XCTAssertEqual(state.selectedSection, .calendar, "the Calendar \"+\" stays on the Calendar")
            state.selectSection(.tasks)
            spin(0.02)
            XCTAssertNil(element("composer-card", in: host), "Reduce Motion: it goes at once")
        }
    }

    func testNotesLayoutSwitchOnlyOnTheListAndFoldsWithSearch() throws {
        XCTAssertEqual(NotesBarMetrics.newNoteSymbol, "plus", "the bottom bar ends with +")
        XCTAssertEqual(NotesLayoutSwitchMetrics.width, 3 + 21 + 1 + 21 + 3)
        try withPanel { host, state, _, _, draft, _ in
            state.selectSection(.notes)
            spin(1.5)
            XCTAssertTrue(draft.pages.showLibrary())
            spin(1.0)
            let top = try assertRow(["panel-pin-button", "notes-layout-switch", "panel-more-button", "notes-search-button"],
                                    in: host)
            XCTAssertEqual(top[1].width, NotesLayoutSwitchMetrics.width, accuracy: 0.5)
            XCTAssertEqual(top[2].minX - top[1].maxX, 10, accuracy: 0.5, "the switch's gap before •••")
            _ = try assertRow(["notes-tag-bar", "notes-new-note"], in: host)
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
