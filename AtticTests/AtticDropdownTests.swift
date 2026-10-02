import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The E1 dropdown family (owner, 2026-10-02): one shared card, row and
/// width rule; one highlight; the `/` list below the caret; the presenter
/// in the panel's overlay layer; and its cost against the components it
/// replaced.
@MainActor
final class AtticDropdownTests: XCTestCase {
    // MARK: The width rule

    func testTheWidthFitsItsContentNeverUnderTheMinimumNeverPastTheMargin() {
        let m = AtticDropdownMetrics.self
        let available: CGFloat = 320 - m.panelMargin * 2
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 90, available: available), 144, "never under 144 pt")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 165, available: available), 165, "fits its content")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 164.2, available: available), 165, "whole points")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: 400, available: available), 296, "never past the 12 pt margin")
    }

    func testTheSlashListIsAsWideAsItsLongestNameAndShrinksToTheMinimum() {
        let all = NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) }
        let full = AtticDropdownLayout.listWidth(titles: all.map(\.title))
        // p2-24 D measured 165 pt for the nine rows (Numbered List).
        XCTAssertEqual(full, 165, accuracy: 4, "the nine rows fit Numbered List")
        XCTAssertTrue(all.contains { $0.kind == .mono }, "Mono is in the list")
        let date = AtticDropdownLayout.listWidth(titles: ["Date"], match: "da")
        XCTAssertEqual(AtticDropdownLayout.width(ideal: date, available: 296), 144, "“/da” leaves Date at the minimum")
    }

    // MARK: Where it opens

    func testItOpensBelowTheCaretWhenThereIsRoomWithItsLeftEdgeOnTheSlash() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        let caret = CGRect(x: 28, y: 96, width: 8, height: 18)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 165, height: 308), anchor: caret, bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.side, .below)
        XCTAssertEqual(placed.frame.minX, 28, "the left edge on the “/”")
        XCTAssertEqual(placed.frame.minY, caret.maxY + AtticDropdownMetrics.anchorGap)
    }

    func testItOpensAboveWhenThereIsNoRoomBelowAndAStripPickerOpensAbove() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        let low = CGRect(x: 28, y: 420, width: 8, height: 18)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 165, height: 200), anchor: low, bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.side, .above)
        XCTAssertEqual(placed.frame.maxY, low.minY - AtticDropdownMetrics.anchorGap)
        let strip = CGRect(x: 100, y: 440, width: 60, height: 28)
        let picker = AtticDropdownLayout.frame(size: CGSize(width: 185, height: 200), anchor: strip, bounds: bounds, prefer: .above)
        XCTAssertEqual(picker.side, .above)
        XCTAssertEqual(picker.frame.minX, 100, "the left edge on the strip button")
    }

    func testItMovesLeftOnlyAsFarAsTheMarginNeeds() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        let anchor = CGRect(x: 250, y: 100, width: 40, height: 28)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 187, height: 136), anchor: anchor, bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.frame.maxX, 308, "the right edge on the 12 pt margin")
        XCTAssertGreaterThanOrEqual(placed.frame.minX, 12)
    }

    // MARK: One highlight

    func testOneHighlightIsSharedByThePointerAndTheKeyboard() {
        // A list that owns its highlight: hover alone never lights a row.
        XCTAssertFalse(AtticDropdownRow.isLit(highlighted: false, hovered: true, listOwnsHighlight: true))
        XCTAssertTrue(AtticDropdownRow.isLit(highlighted: true, hovered: false, listOwnsHighlight: true))
        // The pointer moves the list's one highlight.
        XCTAssertEqual(AtticListHighlight.hovered(3, inside: true, current: 1), 3)
        XCTAssertEqual(AtticListHighlight.hovered(3, inside: false, current: 3), nil)
        XCTAssertEqual(AtticListHighlight.hovered(2, inside: false, current: 3), 3, "leaving a neighbour keeps it")
    }

    // MARK: The look's values

    func testTheCardTakesE1sValuesInBothModes() {
        let light = AtticDesignContext(mode: .light).tokens
        let dark = AtticDesignContext(mode: .dark).tokens
        XCTAssertEqual(light.popoverFill, AtticRGBA(0xFEFEFE))
        XCTAssertEqual(dark.popoverFill, AtticRGBA(0x363637))
        XCTAssertEqual(light.dropdownHighlight, AtticRGBA(0xF1F1F1))
        XCTAssertEqual(dark.dropdownHighlight, AtticRGBA(0x444445))
        XCTAssertEqual(light.popoverOuterRim, .black(0.11))
        XCTAssertEqual(dark.popoverOuterRim, .black(0.55))
        XCTAssertEqual(light.dropdownShadow, .black(0.12))
        XCTAssertEqual(dark.dropdownShadow, .black(0.42))
        XCTAssertEqual(light.dropdownContactShadow, .black(0.05))
        XCTAssertEqual(dark.dropdownContactShadow, .black(0.24))
        let m = AtticDropdownMetrics.self
        XCTAssertEqual(m.cornerRadius - m.inset, m.highlightRadius, "the pill nests in the corner")
        XCTAssertEqual(m.rowHeight, 32)
        XCTAssertEqual(AtticTextStyle.dropdownRow.spec.size, 14)
        // Increase Contrast steps the edge up (the existing rule).
        let contrast = AtticDesignContext(mode: .light, increaseContrast: true).tokens
        XCTAssertGreaterThan(contrast.popoverOuterRim.alpha, light.popoverOuterRim.alpha)
    }

    // MARK: The capture seam

    func testTheCaptureSeamIsForPreviewIdentitiesOnly() {
        let environment = ["ATTIC_UI_TESTING": "1", "ATTIC_UI_TEST_POPOVER": "slash-da"]
        XCTAssertEqual(AtticDropdownCaptureSeam.resolve(environment: environment, bundleIdentifier: "com.taha.Attic.preview.notes"), .slashDa)
        XCTAssertNil(AtticDropdownCaptureSeam.resolve(environment: environment, bundleIdentifier: "com.taha.Attic"))
        XCTAssertNil(AtticDropdownCaptureSeam.resolve(environment: ["ATTIC_UI_TEST_POPOVER": "tag"],
                                                      bundleIdentifier: "com.taha.Attic.preview.notes"), "needs ATTIC_UI_TESTING")
        XCTAssertEqual(AtticDropdownCaptureSeam.tag.page, "tasks")
        XCTAssertEqual(AtticDropdownCaptureSeam.date.notesScene, "date-lead")
    }

    // MARK: The presenter

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        window.orderFrontRegardless()
        return window
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    final class Opener: ObservableObject {
        @Published var isOpen = false
        @Published var query = ""
    }

    final class Counter {
        var behind = 0
    }

    /// Stands for the note or the task list behind: counts its renders.
    struct Behind: View {
        let counter: Counter
        var body: some View {
            counter.behind += 1
            return Color.clear.frame(height: 300)
        }
    }

    /// The control that opens the dropdown: the only view that observes it.
    struct Opening: View {
        @ObservedObject var opener: Opener
        var body: some View {
            Color.clear.frame(width: 60, height: 28)
                .atticDropdown(isPresented: $opener.isOpen, label: "Tags") {
                    ForEach(["launch", "home", "work"].filter { opener.query.isEmpty || $0.contains(opener.query) }, id: \.self) { tag in
                        AtticDropdownRow(title: "#" + tag, check: .off) {}
                    }
                }
        }
    }

    func testOpeningFilteringAndClosingNeverReRenderThePageBehind() {
        let window = makeWindow()
        defer { window.close() }
        let opener = Opener()
        let counter = Counter()
        let root = VStack(alignment: .leading, spacing: 0) {
            Behind(counter: counter)
            Opening(opener: opener)
        }
        let host = NSHostingView(rootView: root.atticDesign(AtticDesignContext()))
        host.frame = window.contentView!.bounds
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin()
        let before = counter.behind
        opener.isOpen = true
        spin(0.2)
        XCTAssertTrue(AtticDropdownPresenter.isAnyOpen, "it opened")
        XCTAssertTrue(AtticTextInput.isPopoverOpen, "the page's keys stand aside")
        let card = window.contentView?.subviews.compactMap { $0 as? AtticOverlayHostingView }.first
        XCTAssertNotNil(card, "the card is in the overlay layer")
        XCTAssertEqual(card?.accessibilityRole(), .menu, "VoiceOver hears a menu")
        if let card {
            let content = card.contentRect
            XCTAssertGreaterThanOrEqual(content.width, AtticDropdownMetrics.minWidth)
            let inWindow = card.convert(content, to: nil)
            XCTAssertGreaterThanOrEqual(inWindow.minX, AtticDropdownMetrics.panelMargin - 0.5)
            XCTAssertLessThanOrEqual(inWindow.maxX, 320 - AtticDropdownMetrics.panelMargin + 0.5)
        }
        opener.query = "ho"
        spin(0.1)
        opener.isOpen = false
        spin(0.5)
        XCTAssertFalse(AtticDropdownPresenter.isAnyOpen, "it closed")
        XCTAssertEqual(counter.behind, before, "the page behind was never re-rendered")
        XCTAssertTrue(window.contentView?.subviews.compactMap { $0 as? AtticOverlayHostingView }.isEmpty ?? false,
                      "the card left the overlay after its leave motion")
    }

    func testEscClosesItAndGivesTheKeyboardBack() {
        let window = makeWindow()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 400, width: 200, height: 22))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let previous = window.firstResponder
        let anchor = NSView(frame: NSRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        var dismissed = false
        presenter.onDismiss = { dismissed = true }
        presenter.content = AnyView(TaskPriorityPickerView(current: nil, onPick: { _ in }))
        presenter.present(from: anchor)
        spin(0.1)
        XCTAssertTrue(presenter.isOpen)
        let host = try? XCTUnwrap(presenter.host)
        XCTAssertTrue((window.firstResponder as? NSView).map { $0 === host || $0.isDescendant(of: host!) } ?? false,
                      "the card has the keyboard")
        presenter.dismiss()
        XCTAssertTrue(dismissed)
        XCTAssertFalse(presenter.isOpen)
        XCTAssertTrue(window.firstResponder === previous || window.firstResponder === field.currentEditor(),
                      "the keyboard went back where it was")
    }

    // MARK: Timings (no regression against the components it replaced)

    private func ms(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    /// Before E1: the `/` list was `AtticPopover` with 28 pt `AtticPopoverRow`s
    /// and a hint column, 256 wide.
    struct LegacySlashList: View {
        @ObservedObject var model: NoteSlashListModel
        var body: some View {
            ZStack(alignment: .topLeading) {
                if model.shown, !model.items.isEmpty {
                    AtticPopover(width: 256) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            AtticPopoverRow(systemName: NoteCommandCatalog.slashSymbol(item.kind), title: item.title,
                                            detail: NoteCommandCatalog.slashHint(item.kind),
                                            isHighlighted: index == model.highlighted) {}
                        }
                    }
                }
            }
            .padding(12)
            .fixedSize()
        }
    }

    /// Before E1: the tag picker's field and 28 pt choice rows on the
    /// picker surface, in a native pop-over.
    struct LegacyTagPicker: View {
        let tags: [String]
        @State private var query = ""
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                TextField("", text: $query, prompt: Text("Find or add a tag"))
                    .textFieldStyle(.plain)
                    .font(AtticTextStyle.menuRow.font)
                    .frame(height: 28)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tags, id: \.self) { tag in
                            AtticChoiceRow(title: "#" + tag, check: .off, isHighlighted: false, onHover: { _ in }) {}
                        }
                    }
                }
                .frame(maxHeight: 196)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200)
            .atticPickerSurface()
        }
    }

    func testOpenAndFilterCostNoMoreThanBefore() {
        let window = makeWindow()
        defer { window.close() }
        let design = AtticDesignContext()
        let all = NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) }
        let filtered = all.filter { $0.title.lowercased().contains("li") }

        func slashTimings<V: View>(_ make: (NoteSlashListModel) -> V) -> (open: Double, filter: Double) {
            let model = NoteSlashListModel()
            let host = NSHostingView(rootView: make(model).atticDesign(design))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
            window.contentView?.addSubview(host)
            defer { host.removeFromSuperview() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            var open: [Double] = [], filter: [Double] = []
            for _ in 0..<15 {
                model.hide(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                open.append(ms { model.show(all); host.layoutSubtreeIfNeeded(); window.displayIfNeeded() })
                filter.append(ms { model.show(filtered); host.layoutSubtreeIfNeeded(); window.displayIfNeeded() })
                filter.append(ms { model.show(all); host.layoutSubtreeIfNeeded(); window.displayIfNeeded() })
            }
            return (median(open), median(filter))
        }

        // Warm both (first-use costs: fonts, symbols), then measure.
        _ = slashTimings { LegacySlashList(model: $0) }
        _ = slashTimings { NoteSlashListView(model: $0) }
        let legacySlash = slashTimings { LegacySlashList(model: $0) }
        let slash = slashTimings { NoteSlashListView(model: $0) }

        let tags = (0..<12).map { "tag\($0)" }
        let anchor = NSView(frame: NSRect(x: 40, y: 60, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        var legacyTag: [Double] = [], tag: [Double] = [], priority: [Double] = []
        for round in 0..<16 {
            // Before E1 the Tasks pickers were native pop-overs.
            let popover = NSPopover()
            popover.animates = false
            popover.contentViewController = NSHostingController(rootView: LegacyTagPicker(tags: tags).atticDesign(design))
            let legacy = ms {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
                popover.contentViewController?.view.window?.displayIfNeeded()
            }
            popover.close()
            if round > 0 { legacyTag.append(legacy) }
            let presenter = AtticDropdownPresenter()
            presenter.design = design
            presenter.prefer = .above
            presenter.content = AnyView(TaskTagPickerView(allTags: tags, state: { _ in .off }, onToggle: { _ in },
                                                          onCreate: { _, _ in true }, focusField: false))
            let opened = ms {
                presenter.present(from: anchor)
                presenter.host?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
            if round > 0 { tag.append(opened) }
            presenter.close(restoreFocus: false, immediately: true)
            let prio = AtticDropdownPresenter()
            prio.design = design
            prio.content = AnyView(TaskPriorityPickerView(current: nil, onPick: { _ in }))
            let prioOpened = ms {
                prio.present(from: anchor)
                prio.host?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
            if round > 0 { priority.append(prioOpened) }
            prio.close(restoreFocus: false, immediately: true)
        }
        let tagMedian = median(tag), legacyTagMedian = median(legacyTag), priorityMedian = median(priority)
        print("DROPDOWN_SLASH_OPEN_MS_MEDIAN=\(slash.open) LEGACY=\(legacySlash.open)")
        print("DROPDOWN_SLASH_FILTER_MS_MEDIAN=\(slash.filter) LEGACY=\(legacySlash.filter)")
        print("DROPDOWN_TAG_OPEN_MS_MEDIAN=\(tagMedian) LEGACY=\(legacyTagMedian)")
        print("DROPDOWN_PRIORITY_OPEN_MS_MEDIAN=\(priorityMedian)")
        // No regression: within half again of the replaced component, plus a
        // millisecond for timer noise on a busy CI machine.
        XCTAssertLessThanOrEqual(slash.open, legacySlash.open * 1.5 + 1, "the / list opens no slower")
        XCTAssertLessThanOrEqual(slash.filter, legacySlash.filter * 1.5 + 1, "a filter keystroke costs no more")
        XCTAssertLessThanOrEqual(tagMedian, legacyTagMedian * 1.5 + 1, "the tag picker opens no slower")
        XCTAssertLessThanOrEqual(priorityMedian, legacyTagMedian * 1.5 + 1, "the priority picker opens no slower")
    }
}
