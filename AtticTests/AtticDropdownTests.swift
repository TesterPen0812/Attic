import AppKit
import Combine
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

    func testTheTagListKeepsItsHeightWhileFiltering() {
        XCTAssertEqual(AtticTagPicker.visibleRows(tagCount: 0), 1, "room for No tags yet or New tag")
        XCTAssertEqual(AtticTagPicker.visibleRows(tagCount: 5), 5, "p2-24's five tags, no scrolling")
        XCTAssertEqual(AtticTagPicker.visibleRows(tagCount: 30), 7, "seven rows, then it scrolls")
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

    func testCrampedPlacementUsesTheRoomierSideAndNeverCrossesTheMargin() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 216)
        let caret = CGRect(x: 28, y: 140, width: 8, height: 18)
        let placed = AtticDropdownLayout.frame(size: CGSize(width: 165, height: 308), anchor: caret,
                                               bounds: bounds, prefer: .below)
        XCTAssertEqual(placed.side, .above)
        XCTAssertLessThan(placed.frame.height, 308)
        XCTAssertEqual(placed.frame.maxY, caret.minY - AtticDropdownMetrics.anchorGap)
        XCTAssertTrue(bounds.contains(placed.frame))
    }

    /// P3-B3: the one placement keeps an open card's side while it fits
    /// there, and flips only when that side can't hold it.
    func testAnOpenCardKeepsItsSideUntilThatSideCannotHoldIt() {
        let bounds = CGRect(x: 12, y: 12, width: 296, height: 496)
        // 336 pt above the anchor, 120 below.
        let anchor = CGRect(x: 28, y: 354, width: 60, height: 28)
        let opened = AtticDropdownLayout.place(idealWidth: 200, height: 252, anchor: anchor, bounds: bounds, prefer: .below)
        XCTAssertEqual(opened.side, .above, "the full list fits only above")
        XCTAssertNil(opened.heightLimit)
        XCTAssertEqual(AtticDropdownLayout.place(idealWidth: 200, height: 88, anchor: anchor, bounds: bounds, prefer: .below).side,
                       .below, "a fresh short card opens below")
        let filtered = AtticDropdownLayout.place(idealWidth: 200, height: 88, anchor: anchor, bounds: bounds, prefer: .below,
                                                 current: opened.side)
        XCTAssertEqual(filtered.side, .above, "a filtered card keeps its side")
        XCTAssertEqual(filtered.frame.maxY, anchor.minY - AtticDropdownMetrics.anchorGap, "still hanging from the anchor")
        let below = AtticDropdownLayout.place(idealWidth: 200, height: 88, anchor: anchor, bounds: bounds, prefer: .above,
                                              current: .below)
        XCTAssertEqual(below.side, .below, "a card below stays below while it fits there")
        let grown = AtticDropdownLayout.place(idealWidth: 200, height: 130, anchor: anchor, bounds: bounds, prefer: .below,
                                              current: .below)
        XCTAssertEqual(grown.side, .above, "it flips once its side can't hold it")
        let tooTall = AtticDropdownLayout.place(idealWidth: 200, height: 400, anchor: anchor, bounds: bounds, prefer: .below,
                                                current: .below)
        XCTAssertEqual(tooTall.side, .above, "the roomier side when neither holds it")
        XCTAssertEqual(tooTall.heightLimit, 336)
        // The width rule is the same one.
        XCTAssertEqual(AtticDropdownLayout.place(idealWidth: 90, height: 88, anchor: anchor, bounds: bounds, prefer: .below).width, 144)
        XCTAssertEqual(AtticDropdownLayout.place(idealWidth: 400, height: 88, anchor: anchor, bounds: bounds, prefer: .below).width, 296)
    }

    /// Inspect the actual accessibility representation, including its action.
    func testMenuItemRepresentationHasRoleSelectionPositionAndPress() {
        var pressed = 0
        let item = AtticDropdownMenuItem(label: "Mono", selected: true, position: 9, count: 9) { pressed += 1 }
        // NSViewRepresentable.Context cannot be constructed here; host the
        // representation so SwiftUI builds and updates the real AppKit view.
        let host = NSHostingView(rootView: item)
        host.frame = CGRect(x: 0, y: 0, width: 165, height: 32)
        host.layoutSubtreeIfNeeded()
        func find(_ root: NSView) -> AtticDropdownMenuItem.ItemView? {
            if let item = root as? AtticDropdownMenuItem.ItemView { return item }
            return root.subviews.compactMap { find($0) }.first
        }
        guard let represented = find(host) else { return XCTFail("the AppKit menu item exists") }
        XCTAssertEqual(represented.accessibilityRole(), .menuItem)
        XCTAssertTrue(represented.isAccessibilitySelected())
        XCTAssertEqual(represented.accessibilityValue() as? String, "9 of 9")
        XCTAssertTrue(represented.accessibilityPerformPress())
        XCTAssertEqual(pressed, 1)
        let disabled = NSHostingView(rootView: item.disabled(true))
        disabled.frame = host.frame
        disabled.layoutSubtreeIfNeeded()
        let disabledItem = try? XCTUnwrap(find(disabled))
        XCTAssertEqual(disabledItem?.isAccessibilityEnabled(), false)
        XCTAssertEqual(disabledItem?.accessibilityPerformPress(), false)
        XCTAssertEqual(pressed, 1, "a disabled menu item never runs its action")
        // A ticked row the highlight is not on: its mark, not "selected".
        let ticked = NSHostingView(rootView: AtticDropdownMenuItem(label: "High", selected: false, check: .on) {})
        ticked.frame = host.frame
        ticked.layoutSubtreeIfNeeded()
        let tickedItem = try? XCTUnwrap(find(ticked))
        XCTAssertEqual(tickedItem?.isAccessibilitySelected(), false, "a tick is not the highlight")
        XCTAssertEqual(tickedItem.map(Self.markChar), "✓")
        XCTAssertNil(Self.markChar(represented), "an unticked item has no mark")
    }

    /// What the accessibility server reads for a menu item's mark, by the
    /// same selectors (the NSAccessibility protocol has no accessor for it).
    private static func markChar(_ element: AnyObject) -> String? {
        guard let object = element as? NSObject,
              let names = object.perform(NSSelectorFromString("accessibilityAttributeNames"))?.takeUnretainedValue() as? [String],
              names.contains(AtticDropdownMenuItem.markCharAttribute.rawValue) else { return nil }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"),
                              with: AtticDropdownMenuItem.markCharAttribute.rawValue)?.takeUnretainedValue() as? String
    }

    /// The tag picker as Tasks shows it, with its rows' states and the
    /// list's one highlight given.
    struct TagList: View {
        let tags: [AtticTagPicker.Tag]
        let highlighted: Int?
        @FocusState private var focused: Bool
        var body: some View {
            AtticTagPicker(query: .constant(""), tags: tags, highlighted: highlighted, onToggle: { _ in }, onCreate: { _ in },
                           fieldFocused: $focused)
                .frame(width: 200)
        }
    }

    /// P2-B1: VoiceOver tells the ticked rows from the highlighted one. Only
    /// the highlight is "selected"; ticks are the menu items' marks.
    func testOnlyTheHighlightIsSelectedAndTicksAreMenuItemMarks() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        defer { window.close() }
        // The priority picker on a High task, ↓ moved to Medium; the tag
        // picker with two ticked tags, one part-ticked, the highlight on
        // an unticked one.
        let tags = [AtticTagPicker.Tag(name: "design", state: .on), AtticTagPicker.Tag(name: "home", state: .off),
                    AtticTagPicker.Tag(name: "launch", state: .on), AtticTagPicker.Tag(name: "travel", state: .mixed)]
        let priorities = VStack(spacing: 0) {
            ForEach(Array(TaskPriority.choices.enumerated()), id: \.element) { index, priority in
                AtticDropdownRow(title: priority.choiceTitle, check: priority == .high ? .on : .off, isHighlighted: priority == .medium,
                                 onHover: { _ in }, position: index + 1, itemCount: 4) {}
            }
        }
        let root = VStack(spacing: 0) { priorities.frame(width: 200); TagList(tags: tags, highlighted: 1) }
        let host = NSHostingView(rootView: root.atticDesign(AtticDesignContext(reduceMotion: true)))
        host.frame = CGRect(x: 0, y: 0, width: 220, height: 400)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        let items = accessibilityElements(host).compactMap { $0 as? AtticDropdownMenuItem.ItemView }
        func item(_ label: String) throws -> AtticDropdownMenuItem.ItemView {
            try XCTUnwrap(items.first { $0.accessibilityLabel() == label }, label)
        }
        XCTAssertEqual(items.filter { $0.isAccessibilitySelected() }.map { $0.accessibilityLabel() ?? "" }, ["Medium", "#home"],
                       "one selected item per list: its highlight")
        XCTAssertEqual(Self.markChar(try item("High")), "✓", "the checked priority is marked, not selected")
        XCTAssertNil(Self.markChar(try item("Medium")))
        XCTAssertEqual(Self.markChar(try item("#design")), "✓")
        XCTAssertEqual(Self.markChar(try item("#launch")), "✓")
        XCTAssertEqual(Self.markChar(try item("#travel")), "-", "a part-ticked tag")
        XCTAssertEqual(try item("#travel").accessibilityValue() as? String, "some selected tasks, 4 of 4")
        XCTAssertNil(Self.markChar(try item("#home")))
    }

    func testRenderedRowsExposeMenuItemsAndKeepTheirIdentifiers() throws {
        // SwiftUI builds its virtual AX tree only when accessibility is
        // requested. Enable that mode in this test host, then restore it.
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        defer { window.close() }
        let model = NoteSlashListModel()
        model.show(NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) })
        let host = NSHostingView(rootView: NoteSlashListView(model: model).atticDesign(AtticDesignContext(reduceMotion: true)))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 340)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        func items(_ element: AnyObject) -> [AtticDropdownMenuItem.ItemView] {
            if let item = element as? AtticDropdownMenuItem.ItemView { return [item] }
            // SwiftUI's virtual children expose the ObjC accessibility
            // methods without declaring protocol conformance.
            let children = (element.accessibilityChildren?() ?? nil) ?? []
            return children.flatMap { items($0 as AnyObject) }
        }
        let rows = items(host)
        XCTAssertEqual(rows.count, model.items.count, "the rendered accessibility tree contains menu items")
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(first.accessibilityRole(), .menuItem)
        XCTAssertTrue(first.isAccessibilitySelected())
        XCTAssertEqual(first.accessibilityValue() as? String, "1 of 9")
        XCTAssertEqual(first.accessibilityIdentifier(), "notes-slash-checklist")
        XCTAssertGreaterThan(first.accessibilityFrame().width, 0)
        XCTAssertEqual(first.accessibilityFrame().height, AtticDropdownMetrics.rowHeight, accuracy: 1)
        XCTAssertEqual(rows.last?.accessibilityValue() as? String, "9 of 9")
        XCTAssertEqual(rows.filter { $0.isAccessibilitySelected() }.count, 1, "only the highlight is selected")
    }

    func testCrampedSlashScrollKeepsTheKeyboardHighlightVisible() throws {
        let window = makeWindow()
        defer { window.close() }
        let model = NoteSlashListModel()
        model.viewportHeight = 116
        model.width = 165
        model.show(NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) })
        let host = NSHostingView(rootView: NoteSlashListView(model: model).atticDesign(AtticDesignContext(reduceMotion: true)))
        host.frame = CGRect(x: 10, y: 10, width: 189, height: 140)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
        }
        let scroll = try XCTUnwrap(scrolls(host).first)
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentView.bounds.height)
        let before = scroll.contentView.bounds.origin.y
        model.move(-1) // wraps from the first row to Mono
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, before, "the keyboard scrolls to Mono")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.bounds.maxY - 1,
                                    "the last row is wholly visible")
        model.move(1) // wraps back to the first row
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.minY, document.bounds.minY,
                                 "the first row starts within the viewport, allowing the native top inset")
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxY, document.bounds.minY + AtticDropdownMetrics.rowHeight,
                                    "the entire first row is visible")
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
        // The leave motion, then the card's host goes (polled: a busy
        // machine runs the cleanup late).
        let deadline = Date().addingTimeInterval(3)
        repeat { spin(0.1) } while Date() < deadline
            && !(window.contentView?.subviews.compactMap { $0 as? AtticOverlayHostingView }.isEmpty ?? true)
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

    func testTheTagPickerCardShowsEveryTagItHasRoomFor() {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 40, y: 60, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.prefer = .above
        presenter.content = AnyView(TaskTagPickerView(allTags: ["launch", "home", "work", "design", "travel"], state: { _ in .off },
                                                      onToggle: { _ in }, onCreate: { _, _ in true }, focusField: false))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        let m = AtticDropdownMetrics.self
        let card = try? XCTUnwrap(presenter.host?.contentRect)
        // The field, its gap and the five rows, 10 pt in.
        XCTAssertEqual(card?.height ?? 0, m.inset * 2 + m.fieldHeight + m.fieldGap + 5 * m.rowHeight, accuracy: 1)
        XCTAssertGreaterThanOrEqual(card?.width ?? 0, m.minWidth)
    }

    func testTypingSuggestionsKeepTheKeyboardAndResizeWhenRowsChange() throws {
        let window = makeWindow()
        defer { window.close() }
        let field = NSTextField(frame: CGRect(x: 28, y: 50, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let previous = window.firstResponder
        let anchor = NSView(frame: CGRect(x: 28, y: 90, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.takesKeyboard = false
        presenter.contentHasCard = true
        presenter.contentHeight = 52
        presenter.content = AnyView(AtticSuggestionList(items: [.init(id: "first", title: "First")], highlighted: 0) { _ in })
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.1)
        XCTAssertIdentical(window.firstResponder, previous, "typing stays in the draft")
        XCTAssertEqual(presenter.stage.side, .below)
        presenter.content = AnyView(AtticSuggestionList(items: (0..<9).map { .init(id: "\($0)", title: "Row \($0)") }, highlighted: 0) { _ in })
        presenter.contentHeight = 308
        presenter.update()
        spin(0.1)
        XCTAssertEqual(presenter.stage.side, .above, "the full grown list fits above")
        XCTAssertEqual(try XCTUnwrap(presenter.host).contentRect.height, 308, accuracy: 1)
        XCTAssertIdentical(window.firstResponder, previous)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: anchor.convert(CGPoint(x: 30, y: 14), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertIdentical(try XCTUnwrap(presenter.handleClick(click)), click, "an editor/strip click still acts")
        XCTAssertFalse(presenter.isOpen, "the automatic suggestions close on that click")
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testTagFieldEscPassesCompositionAndModifiersThenDismissesAndRestoresFocus() throws {
        let window = makeWindow()
        defer { window.close() }
        let original = NSTextField(frame: CGRect(x: 20, y: 400, width: 200, height: 24))
        window.contentView?.addSubview(original)
        window.makeFirstResponder(original)
        let anchor = NSView(frame: CGRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.content = AnyView(TaskTagPickerView(allTags: ["home"], state: { _ in .off }, onToggle: { _ in }, onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        XCTAssertTrue(field.isDescendant(of: try XCTUnwrap(presenter.host)), "the actual tag field is editing")
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let escape = key("\u{1b}", code: 53, in: window)
        XCTAssertIdentical(presenter.handleKey(escape), escape, "composition cancellation reaches the text input")
        XCTAssertTrue(presenter.isOpen)
        // AppKit's input client finishes cancellation; no candidate window
        // or system input-source switch is required in this headless test.
        editor.unmarkText()
        for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            let modified = key("\u{1b}", code: 53, flags: flags, in: window)
            XCTAssertIdentical(presenter.handleKey(modified), modified)
            XCTAssertTrue(presenter.isOpen)
        }
        XCTAssertNil(presenter.handleKey(escape))
        XCTAssertFalse(presenter.isOpen)
        XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original)
    }

    /// A view that counts the clicks that reach it.
    final class ClickRecorder: NSView {
        var clicks = 0
        override func mouseDown(with event: NSEvent) { clicks += 1 }
    }

    /// A key panel that never activates the app (no keyboard taken from
    /// whoever is at the Mac).
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// P3-T1: the tag picker from the keyboard with Full Keyboard Access on,
    /// through real events in the app's queue: Tab moves from the field to a
    /// row and Space presses it; ↓ moves the one highlight (VoiceOver's
    /// "selected"; ticks stay marks); Return toggles the highlighted tag;
    /// Esc closes the card and gives the keyboard back; a click outside
    /// closes it and goes through to what is under it.
    func testTheTagPickerWorksFromTheKeyboardWithFullKeyboardAccess() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_FULL_KEYBOARD_ACCESS_TESTS"] == "1" else {
            throw XCTSkip("CI enables Full Keyboard Access before launching the test host; local tests preserve the user's setting")
        }
        XCTAssertTrue(NSApp.isFullKeyboardAccessEnabled, "verify AppKit's actual mode, not just a preference value")
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = KeyPanel(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        window.orderFront(nil)
        window.makeKey()
        defer { window.close() }
        XCTAssertTrue(window.isKeyWindow)
        let original = NSTextField(frame: CGRect(x: 20, y: 470, width: 200, height: 24))
        window.contentView?.addSubview(original)
        let recorder = ClickRecorder(frame: CGRect(x: 240, y: 20, width: 60, height: 40))
        window.contentView?.addSubview(recorder)
        let anchor = NSView(frame: CGRect(x: 20, y: 400, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        var toggled: [String] = []
        var dismissals = 0
        func open() throws -> AtticDropdownPresenter {
            window.makeFirstResponder(original)
            let presenter = AtticDropdownPresenter()
            presenter.design = AtticDesignContext(reduceMotion: true)
            presenter.onDismiss = { dismissals += 1 }
            presenter.content = AnyView(TaskTagPickerView(allTags: ["design", "home", "launch"], state: { $0 == "home" ? .on : .off },
                                                          onToggle: { toggled.append($0) }, onCreate: { _, _ in true }))
            presenter.present(from: anchor)
            spin(0.3)
            XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true, "the tag field has the keyboard")
            return presenter
        }
        func deliver(_ events: [NSEvent]) {
            events.forEach { NSApp.postEvent($0, atStart: false) }
            var count = 0
            while count < 64, let next = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                count += 1
            }
            spin(0.2)
        }
        func press(_ characters: String, _ code: UInt16) {
            deliver([NSEvent.EventType.keyDown, .keyUp].map { type in
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            })
        }
        func items(_ host: NSView) -> [AtticDropdownMenuItem.ItemView] {
            accessibilityElements(host).compactMap { $0 as? AtticDropdownMenuItem.ItemView }
        }
        func selected(_ host: NSView) -> [String] {
            items(host).filter { $0.isAccessibilitySelected() }.compactMap { $0.accessibilityLabel() }
        }

        let presenter = try open()
        let host = try XCTUnwrap(presenter.host)
        press("\t", 48)
        let afterTab = window.firstResponder as? NSView
        XCTAssertFalse((afterTab as? NSTextView)?.isFieldEditor == true, "Tab left the field")
        XCTAssertTrue(afterTab?.isDescendant(of: host) == true, "the keyboard is still in the card")
        press(" ", 49)
        XCTAssertEqual(toggled.count, 1, "Tab reached a row and Space pressed it: \(toggled)")
        XCTAssertTrue(["design", "home", "launch"].contains(toggled.first ?? ""))
        XCTAssertTrue(presenter.isOpen, "toggling a tag keeps the card open")
        press("\u{F701}", 125)
        XCTAssertEqual(selected(host), ["#design"], "↓ highlights the first row, and only it is selected")
        press("\u{F701}", 125)
        XCTAssertEqual(selected(host), ["#home"], "↓ moves the one highlight")
        XCTAssertEqual(items(host).first { $0.accessibilityLabel() == "#home" }.flatMap(Self.markChar), "✓", "its tick is its mark")
        press("\r", 36)
        XCTAssertEqual(toggled.dropFirst().first, "home", "Return toggles the highlighted tag")
        press("\u{1b}", 53)
        XCTAssertFalse(presenter.isOpen, "Esc closes the card")
        XCTAssertEqual(dismissals, 1)
        XCTAssertIdentical(AtticDropdownPresenter.owner(of: window.firstResponder), original, "the keyboard goes back")
        presenter.close(restoreFocus: false, immediately: true)

        // A click outside, with a row focused from the keyboard.
        let second = try open()
        press("\t", 48)
        XCTAssertFalse((window.firstResponder as? NSTextView)?.isFieldEditor == true, "Tab left the field")
        let point = recorder.convert(CGPoint(x: recorder.bounds.midX, y: recorder.bounds.midY), to: nil)
        deliver([NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        })
        XCTAssertFalse(second.isOpen, "a click outside closes the card")
        XCTAssertEqual(dismissals, 2)
        XCTAssertEqual(recorder.clicks, 1, "the click goes through to what is under it")
        second.close(restoreFocus: false, immediately: true)
    }

    func testOutsideClickDismissesAnEditingTagFieldAndPassesThrough() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.content = AnyView(TaskTagPickerView(allTags: ["home"], state: { _ in .off }, onToggle: { _ in }, onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 310, y: 510),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertIdentical(presenter.handleClick(click), click)
        XCTAssertFalse(presenter.isOpen)
    }

    func testPriorityChordsInvokeTheOpenPickersAction() throws {
        let window = makeWindow()
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 20, y: 300, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        var picked: [TaskPriority] = []
        presenter.contentHeight = AtticDropdownMetrics.inset * 2 + AtticDropdownMetrics.rowHeight * 4
        presenter.content = AnyView(TaskPriorityPickerView(current: nil) { picked.append($0) })
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let host = try XCTUnwrap(presenter.host)
        for (index, code) in [UInt16(29), 18, 19, 20].enumerated() {
            NSApp.sendEvent(key("\(index)", code: code, flags: [.option, .command], in: window))
            spin()
        }
        XCTAssertEqual(picked, TaskPriority.choices)
        XCTAssertFalse(host.performKeyEquivalent(with: key("1", code: 18, flags: .command, in: window)))
        XCTAssertEqual(picked, TaskPriority.choices)
        presenter.close(restoreFocus: false, immediately: true)
        NSApp.sendEvent(key("0", code: 29, flags: [.option, .command], in: window))
        spin()
        XCTAssertEqual(picked, TaskPriority.choices, "closed pickers no longer own the chords")
    }

    final class RetryContent: ObservableObject {
        @Published var failed = false
    }

    struct RetryingTagPicker: View {
        @ObservedObject var model: RetryContent
        var body: some View {
            VStack(spacing: 0) {
                TaskTagPickerView(allTags: (0..<7).map { "tag\($0)" }, state: { _ in .off },
                                  onToggle: { _ in }, onCreate: { _, _ in false })
                if model.failed { Text("Save failed; Retry").frame(height: 80) }
            }
            // The real row picker clears its failure only when it leaves.
            .onDisappear { model.failed = false }
        }
    }

    func testAHeightChangePreservesTheEditingTagQueryAndRetryState() throws {
        let window = makeWindow()
        window.setContentSize(CGSize(width: 320, height: 420))
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 40, y: 40, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let model = RetryContent()
        let presenter = AtticDropdownPresenter()
        presenter.prefer = .above
        presenter.content = AnyView(RetryingTagPicker(model: model))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("tag0", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.1)
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        XCTAssertEqual(field.stringValue, "tag0")
        XCTAssertNil(presenter.stage.height, "the initial card fits")
        model.failed = true
        spin(0.3)
        XCTAssertTrue(model.failed, "constraining the card must not run its dismissal cleanup")
        XCTAssertNotNil(presenter.stage.height, "the error grows beyond the available room")
        let current = try XCTUnwrap((window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        XCTAssertEqual(current.stringValue, "tag0", "the typed query survives the scrolling threshold")
        model.failed = false
        spin(0.3)
        XCTAssertNil(presenter.stage.height, "clearing the error returns the card to its natural height")
        let restored = try XCTUnwrap((window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        XCTAssertEqual(restored.stringValue, "tag0", "shrinking must preserve editing state too")
    }

    /// P3-B2: a tag picker taller than both sides of its anchor settles its
    /// height in one step as it opens (it flickered `nil → 178 → nil …`).
    func testATagPickerTallerThanBothSidesSettlesItsHeightInOneStep() throws {
        let window = makeWindow()
        window.setContentSize(CGSize(width: 320, height: 420))
        defer { window.close() }
        // Mid-panel: 162 pt above the anchor, 194 below; the card is 280.
        let anchor = NSView(frame: CGRect(x: 40, y: 212, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.prefer = .above
        var heights: [CGFloat?] = []
        let watch = presenter.stage.$height.dropFirst().sink { heights.append($0) }
        defer { watch.cancel() }
        presenter.content = AnyView(TaskTagPickerView(allTags: (0..<7).map { "tag\($0)" }, state: { _ in .off },
                                                      onToggle: { _ in }, onCreate: { _, _ in true }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.6)
        let m = AtticDropdownMetrics.self
        let natural = m.inset * 2 + m.fieldHeight + m.fieldGap + 7 * m.rowHeight
        let limit = try XCTUnwrap(presenter.stage.height, "neither side holds the card")
        XCTAssertLessThan(limit, natural)
        XCTAssertEqual(presenter.stage.side, .below, "the roomier side")
        XCTAssertEqual(Array(heights.drop { $0 == nil }), [limit], "one step from nil to the limit, then it holds: \(heights)")
        XCTAssertEqual(try XCTUnwrap(presenter.host).contentRect.height, limit, accuracy: 1)
    }

    /// P3-B3: Move to Task… low in the panel opens above; typing a filter
    /// until the list would fit below leaves it above (it jumped across
    /// the row mid-typing).
    func testAFilteredCardKeepsItsSide() throws {
        let window = makeWindow()
        defer { window.close() }
        // 336 pt above the anchor, 120 below.
        let anchor = NSView(frame: CGRect(x: 40, y: 138, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"]
        presenter.content = AnyView(TaskMovePickerView(choices: names.map { .init(id: UUID(), title: $0, detail: "Now") }, onChoose: { _ in }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.3)
        let host = try XCTUnwrap(presenter.host)
        XCTAssertEqual(presenter.stage.side, .above, "the full list fits only above")
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("Alpha", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.3)
        let card = AtticDropdownLayout.topDown(host.convert(host.contentRect, to: window.contentView), in: window.contentView!)
        let anchorTop = 520 - anchor.frame.maxY
        XCTAssertLessThanOrEqual(card.height, 520 - 12 - (anchorTop + 28 + AtticDropdownMetrics.anchorGap),
                                 "the filtered card would fit below")
        XCTAssertEqual(presenter.stage.side, .above, "it keeps its side while filtering")
        XCTAssertEqual(card.maxY, anchorTop - AtticDropdownMetrics.anchorGap, accuracy: 1, "still hanging from the row")
    }

    private func accessibilityElements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { accessibilityElements($0 as AnyObject) }
    }

    func testCalendarHeightTracksFourFiveAndSixWeeksAndLastRowRemainsInteractive() throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        window.setContentSize(CGSize(width: 320, height: 420))
        defer { window.close() }
        let anchor = NSView(frame: CGRect(x: 40, y: 40, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let february = try XCTUnwrap(calendar.date(from: DateComponents(year: 2021, month: 2, day: 1)))
        let choices = TaskDateChoices(parser: TaskTextParser(calendar: calendar, locale: Locale(identifier: "en_GB"), now: { february }))
        var picked: DueDay?
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.prefer = .above
        presenter.content = AnyView(TaskDatePickerView(choices: choices, selected: nil, onPick: { picked = $0 }))
        presenter.present(from: anchor)
        defer { presenter.close(restoreFocus: false, immediately: true) }
        spin(0.2)
        let host = try XCTUnwrap(presenter.host)
        let four = host.contentRect.size
        XCTAssertNil(presenter.stage.height, "February 2021's four weeks fit")
        func nextMonth() throws {
            let next = try XCTUnwrap(accessibilityElements(host).first { ($0.accessibilityLabel?() ?? nil) == "Next month" })
            XCTAssertTrue(next.accessibilityPerformPress?() == true)
            spin(0.2)
        }
        try nextMonth() // March: five weeks
        XCTAssertEqual(host.contentRect.width, four.width, accuracy: 1)
        XCTAssertEqual(host.contentRect.height, four.height + AtticDropdownMetrics.monthCellHeight, accuracy: 1)
        try nextMonth() // April: five weeks
        try nextMonth() // May: six weeks, constrained at this anchor
        XCTAssertEqual(host.contentRect.width, four.width, accuracy: 1)
        XCTAssertNotNil(presenter.stage.height)
        XCTAssertGreaterThan(host.contentRect.height, four.height + AtticDropdownMetrics.monthCellHeight)
        let inWindow = host.convert(host.contentRect, to: nil)
        XCTAssertGreaterThanOrEqual(inWindow.minY, 12)
        XCTAssertLessThanOrEqual(inWindow.maxY, 408)
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
        }
        let scroll = try XCTUnwrap(scrolls(host).first)
        let document = try XCTUnwrap(scroll.documentView)
        document.scrollToVisible(CGRect(x: 0, y: document.bounds.maxY - 1, width: 1, height: 1))
        spin(0.2)
        let last = DueDay(rawValue: "2021-06-06")!
        let label = TaskRowPresentation.format(try XCTUnwrap(last.startDate(in: calendar)), template: "EEEEdMMMMy", calendar: calendar, locale: choices.parser.locale)
        let day = try XCTUnwrap(accessibilityElements(host).first { ($0.accessibilityLabel?() ?? nil) == label })
        let frame: NSRect = day.accessibilityFrame!()
        let local = host.convert(window.convertFromScreen(frame), from: nil)
        let center = CGPoint(x: local.midX, y: local.midY)
        XCTAssertTrue(host.contentRect.contains(center), "the last calendar row is inside the updated hit bounds after scrolling")
        XCTAssertNotNil(host.hitTest(host.convert(center, to: host.superview)))
        XCTAssertTrue(day.accessibilityPerformPress?() == true)
        XCTAssertEqual(picked, last, "the bottom day runs the real pick action")
        // Shrinking removes the viewport instead of retaining the old limit.
        let previousMonth = try XCTUnwrap(accessibilityElements(host).first { ($0.accessibilityLabel?() ?? nil) == "Previous month" })
        XCTAssertTrue(previousMonth.accessibilityPerformPress?() == true)
        spin(0.2)
        XCTAssertNil(presenter.stage.height)
        XCTAssertEqual(host.contentRect.height, four.height + AtticDropdownMetrics.monthCellHeight, accuracy: 1)
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

    /// One timing sample set: each interaction's samples, the dropdown's
    /// and the component it replaced.
    struct Samples {
        var slashOpen: [Double] = [], slashFilter: [Double] = []
        var legacySlashOpen: [Double] = [], legacySlashFilter: [Double] = []
        var tag: [Double] = [], legacyTag: [Double] = [], priority: [Double] = []
    }

    /// The upper and lower quartiles' distance: the samples' own spread.
    private func spread(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        return sorted[sorted.count * 3 / 4] - sorted[sorted.count / 4]
    }

    /// Opens, filters and closes the dropdowns and the components they
    /// replaced, the same way. With `readAccessibility`, each sample also
    /// reads the shown list's accessibility tree, as VoiceOver does when a
    /// menu opens or changes (that is when SwiftUI builds each row's
    /// accessibility element).
    private func measureDropdownCosts(in window: NSWindow, readAccessibility: Bool = false) -> Samples {
        let design = AtticDesignContext()
        let all = NoteSlashItem.Kind.allCases.map { NoteSlashItem(kind: $0) }
        let filtered = all.filter { $0.title.lowercased().contains("li") }
        var samples = Samples()

        func slashTimings<V: View>(_ make: (NoteSlashListModel) -> V) -> (open: [Double], filter: [Double]) {
            let model = NoteSlashListModel()
            let host = NSHostingView(rootView: make(model).atticDesign(design))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
            window.contentView?.addSubview(host)
            defer { host.removeFromSuperview() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            var open: [Double] = [], filter: [Double] = []
            func read() { if readAccessibility { _ = accessibilityElements(host) } }
            for _ in 0..<15 {
                model.hide(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read()
                open.append(ms { model.show(all); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read() })
                filter.append(ms { model.show(filtered); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read() })
                filter.append(ms { model.show(all); host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); read() })
            }
            return (open, filter)
        }

        // Warm both (first-use costs: fonts, symbols), then measure.
        _ = slashTimings { LegacySlashList(model: $0) }
        _ = slashTimings { NoteSlashListView(model: $0) }
        (samples.legacySlashOpen, samples.legacySlashFilter) = slashTimings { LegacySlashList(model: $0) }
        (samples.slashOpen, samples.slashFilter) = slashTimings { NoteSlashListView(model: $0) }

        let tags = (0..<12).map { "tag\($0)" }
        let anchor = NSView(frame: NSRect(x: 40, y: 60, width: 60, height: 28))
        window.contentView?.addSubview(anchor)
        defer { anchor.removeFromSuperview() }
        for round in 0..<16 {
            // Before E1 the Tasks pickers were native pop-overs.
            let popover = NSPopover()
            popover.animates = false
            popover.contentViewController = NSHostingController(rootView: LegacyTagPicker(tags: tags).atticDesign(design))
            let legacy = ms {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
                popover.contentViewController?.view.window?.displayIfNeeded()
                if readAccessibility, let view = popover.contentViewController?.view { _ = accessibilityElements(view) }
            }
            popover.close()
            if round > 0 { samples.legacyTag.append(legacy) }
            let presenter = AtticDropdownPresenter()
            presenter.design = design
            presenter.prefer = .above
            presenter.content = AnyView(TaskTagPickerView(allTags: tags, state: { $0 == "tag2" ? .on : .off }, onToggle: { _ in },
                                                          onCreate: { _, _ in true }, focusField: false))
            let opened = ms {
                presenter.present(from: anchor)
                presenter.host?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if readAccessibility, let host = presenter.host { _ = accessibilityElements(host) }
            }
            if round > 0 { samples.tag.append(opened) }
            presenter.close(restoreFocus: false, immediately: true)
            let prio = AtticDropdownPresenter()
            prio.design = design
            // The real composer strip supplies this fixed four-row height.
            prio.contentHeight = AtticDropdownMetrics.inset * 2 + AtticDropdownMetrics.rowHeight * 4
            prio.content = AnyView(TaskPriorityPickerView(current: .high, onPick: { _ in }))
            let prioOpened = ms {
                prio.present(from: anchor)
                prio.host?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                if readAccessibility, let host = prio.host { _ = accessibilityElements(host) }
            }
            if round > 0 { samples.priority.append(prioOpened) }
            prio.close(restoreFocus: false, immediately: true)
        }
        return samples
    }

    private func report(_ samples: Samples, label: String) {
        print("DROPDOWN\(label)_SLASH_OPEN_MS_MEDIAN=\(median(samples.slashOpen)) LEGACY=\(median(samples.legacySlashOpen))"
              + " SPREAD=\(spread(samples.slashOpen))/\(spread(samples.legacySlashOpen))")
        print("DROPDOWN\(label)_SLASH_FILTER_MS_MEDIAN=\(median(samples.slashFilter)) LEGACY=\(median(samples.legacySlashFilter))"
              + " SPREAD=\(spread(samples.slashFilter))/\(spread(samples.legacySlashFilter))")
        print("DROPDOWN\(label)_TAG_OPEN_MS_MEDIAN=\(median(samples.tag)) LEGACY=\(median(samples.legacyTag))"
              + " SPREAD=\(spread(samples.tag))/\(spread(samples.legacyTag))")
        print("DROPDOWN\(label)_PRIORITY_OPEN_MS_MEDIAN=\(median(samples.priority)) SPREAD=\(spread(samples.priority))")
    }

    func testOpenAndFilterCostNoMoreThanBefore() {
        let window = makeWindow()
        defer { window.close() }
        let samples = measureDropdownCosts(in: window)
        report(samples, label: "")
        let slashOpen = median(samples.slashOpen), slashFilter = median(samples.slashFilter)
        let legacySlashOpen = median(samples.legacySlashOpen), legacySlashFilter = median(samples.legacySlashFilter)
        let tagMedian = median(samples.tag), legacyTagMedian = median(samples.legacyTag), priorityMedian = median(samples.priority)
        // No regression: within half again of the replaced component, plus a
        // millisecond for timer noise on a busy CI machine.
        XCTAssertLessThanOrEqual(slashOpen, legacySlashOpen * 1.5 + 1, "the / list opens no slower")
        XCTAssertLessThanOrEqual(slashFilter, legacySlashFilter * 1.5 + 1, "a filter keystroke costs no more")
        XCTAssertLessThanOrEqual(tagMedian, legacyTagMedian * 1.5 + 1, "the tag picker opens no slower")
        XCTAssertLessThanOrEqual(priorityMedian, legacyTagMedian * 1.5 + 1, "the priority picker opens no slower")
    }

    /// The same gate with accessibility on and the tree read (as VoiceOver
    /// reads a menu), so each row's accessibility element is built and paid
    /// for. The replaced components build and read theirs too. No
    /// fixed tolerance: a dropdown's median may exceed the replaced
    /// component's only by the two sample sets' own spreads (their
    /// interquartile ranges, measured in this run).
    func testOpenAndFilterCostNoMoreThanBeforeWithAccessibilityOn() {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let window = makeWindow()
        defer { window.close() }
        let samples = measureDropdownCosts(in: window, readAccessibility: true)
        report(samples, label: "_AX")
        func noRegression(_ new: [Double], _ old: [Double], _ message: String) {
            XCTAssertLessThanOrEqual(median(new), median(old) + spread(new) + spread(old), message)
        }
        noRegression(samples.slashOpen, samples.legacySlashOpen, "the / list opens no slower with accessibility on")
        noRegression(samples.slashFilter, samples.legacySlashFilter, "a filter keystroke costs no more with accessibility on")
        noRegression(samples.tag, samples.legacyTag, "the tag picker opens no slower with accessibility on")
        noRegression(samples.priority, samples.legacyTag, "the priority picker opens no slower with accessibility on")
    }
}
