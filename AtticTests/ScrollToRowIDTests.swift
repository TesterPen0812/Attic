import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// `ScrollViewReader.scrollTo` finds a row by one id. On macOS 27 a String
/// `.id` on a row inside a `ForEach` keyed by a different String is not
/// found: the scroll is issued and the list stays (PF-43 R-3, 26 Nov). The
/// dropdown lists whose rows fell back to their title as `.id` while their
/// `ForEach` keyed on the item's id never brought the keyboard's highlight
/// into view there. Each row now carries one id.
@MainActor
final class ScrollToRowIDTests: XCTestCase {
    private static let visibleRows: CGFloat = 6
    private static var listHeight: CGFloat { visibleRows * AtticDropdownMetrics.rowHeight + 2 * AtticDropdownMetrics.inset }

    // MARK: Notes tag suggestions

    private struct TagSuggestions: View {
        let highlighted: Int
        var body: some View {
            AtticTagSuggestionList(suggestions: ScrollToRowIDTests.tagSuggestions, highlighted: highlighted, onPick: { _ in })
                .environment(\.atticDropdownHeight, ScrollToRowIDTests.listHeight)
                .environment(\.atticDropdownContentHeightChanged, { _ in })
                .atticDesign(AtticDesignContext(reduceMotion: true))
        }
    }

    /// 29 existing tags, then the "New Tag “#fresh”" row.
    private static let tagSuggestions = (0..<29).map { AtticTagSuggestion(name: String(format: "tag-%02d", $0), count: 1, isNew: false) }
        + [AtticTagSuggestion(name: "fresh", count: 0, isNew: true)]

    /// ↓ onto a tag row that is out of view, then onto the "Create" row at
    /// the end: each is brought into view.
    func testTagSuggestionsBringTheKeyboardsHighlightIntoView() throws {
        let (host, list, window) = try show(TagSuggestions(highlighted: 0))
        defer { window.close() }
        XCTAssertEqual(offset(list), 0, accuracy: 0.5, "the list opens at its top")

        restoreNeutralCurrentEvent()
        host.rootView = TagSuggestions(highlighted: 12)
        waitUntil(host) { self.offset(list) > 1 }
        XCTAssertTrue(shows(row: 12, in: list), "the highlighted tag row is scrolled into view (offset \(offset(list)))")

        let before = offset(list)
        restoreNeutralCurrentEvent()
        host.rootView = TagSuggestions(highlighted: 29)
        waitUntil(host) { self.offset(list) > before + 1 }
        XCTAssertTrue(shows(row: 29, in: list), "the Create row is scrolled into view (offset \(offset(list)))")
    }

    // MARK: Suggestions (Tasks title, composer: # tags and dates)

    private struct Suggestions: View {
        let items: [AtticSuggestionList.Item]
        let highlighted: Int
        var onHover: ((Int) -> Void)? = nil
        var body: some View {
            AtticSuggestionList(items: items, highlighted: highlighted, onHover: onHover, onChoose: { _ in })
                .environment(\.atticDropdownHeight, ScrollToRowIDTests.listHeight)
                .environment(\.atticDropdownContentHeightChanged, { _ in })
                .atticDesign(AtticDesignContext(reduceMotion: true))
        }
    }

    /// The Tasks title's and composer's "#" list: each tag ("#work", id
    /// "work"), then "Create #new" (id "create-new").
    private static let suggestionItems = (0..<29).map { AtticSuggestionList.Item(id: String(format: "tag-%02d", $0), title: String(format: "#tag-%02d", $0)) }
        + [AtticSuggestionList.Item(id: "create-new", title: "Create #new", systemName: "plus")]

    func testSuggestionListBringsTheKeyboardsHighlightIntoView() throws {
        let (host, list, window) = try show(Suggestions(items: Self.suggestionItems, highlighted: 0))
        defer { window.close() }
        XCTAssertEqual(offset(list), 0, accuracy: 0.5, "the list opens at its top")

        restoreNeutralCurrentEvent()
        host.rootView = Suggestions(items: Self.suggestionItems, highlighted: 12)
        waitUntil(host) { self.offset(list) > 1 }
        XCTAssertTrue(shows(row: 12, in: list), "the highlighted row is scrolled into view (offset \(offset(list)))")

        let before = offset(list)
        restoreNeutralCurrentEvent()
        host.rootView = Suggestions(items: Self.suggestionItems, highlighted: 29)
        waitUntil(host) { self.offset(list) > before + 1 }
        XCTAssertTrue(shows(row: 29, in: list), "the Create row is scrolled into view (offset \(offset(list)))")
    }

    /// The pointer still moves the list's one highlight: a row it enters
    /// reports its own index.
    func testSuggestionListPointerStillReportsTheRowItEnters() throws {
        var reported: Int?
        let (host, list, window) = try show(Suggestions(items: Self.suggestionItems, highlighted: 0, onHover: { reported = $0 }))
        defer { window.close() }
        leaveAMouseMoveAsTheCurrentEvent(in: window)
        defer { restoreNeutralCurrentEvent() }
        // The middle of the third row (index 2), from the list's top.
        let y = 2.5 * AtticDropdownMetrics.rowHeight
        let point = list.convert(NSPoint(x: list.bounds.midX, y: list.isFlipped ? y : list.bounds.maxY - y), to: nil)
        try Pointer().move(in: host, toWindowPoint: point)
        waitUntil(host) { reported != nil }
        XCTAssertEqual(reported, 2, "the row under the pointer reports its index")
        XCTAssertEqual(offset(list), 0, accuracy: 0.5, "a hover does not scroll")
    }

    // MARK: Accessibility identity

    /// Each row reads as it did (its title, and a tag's count), with no
    /// identifier from its scroll id, and the lists keep their names.
    func testRowsKeepTheirAccessibilityLabelsAndIdentifiers() throws {
        // SwiftUI builds its accessibility tree for an assistive client.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        for (name, view, titles) in [
            ("Tag suggestions", AnyView(TagSuggestions(highlighted: 0)), ["#tag-00, 1", "#tag-01, 1", AtticTagPicker.createTitle("fresh")]),
            ("Suggestions", AnyView(Suggestions(items: Self.suggestionItems, highlighted: 0)), ["#tag-00", "#tag-01", "Create #new"]),
        ] {
            let (host, _, window) = try show(view)
            defer { window.close() }
            // The accessibility tree of a new host fills in over a turn or two.
            func labelled() -> [AnyObject] { accessibilityElements(host).filter { ($0.accessibilityLabel?() ?? nil) != nil } }
            waitUntil(host) { labelled().contains { ($0.accessibilityLabel?() ?? nil) == titles[0] } }
            let elements = accessibilityElements(host)
            let labels = elements.compactMap { ($0.accessibilityLabel?() ?? nil) }
            XCTAssertTrue(labels.contains(name), "the list is named \(name) (\(labels.prefix(8)))")
            for title in titles {
                let rows = elements.filter { ($0.accessibilityLabel?() ?? nil) == title }
                XCTAssertFalse(rows.isEmpty, "a row reads \(title) (\(name); \(labels.prefix(6)))")
                for row in rows {
                    let identifier = (row.accessibilityIdentifier?() ?? nil) ?? ""
                    XCTAssertEqual(identifier, "", "\(title) has no identifier from its id (\(name))")
                }
            }
        }
    }

    // MARK: Rebuilds

    #if DEBUG
    /// Moving the highlight rebuilds no row, and a row whose title changes
    /// under the same id is rebuilt at most once. Counted by each row's
    /// shortcut hint appearing (`AtticDropdownDiagnostics.hintRetains`).
    func testSuggestionRowsAreNotRebuiltByHighlightMoves() throws {
        func items(_ third: String) -> [AtticSuggestionList.Item] {
            (0..<5).map { AtticSuggestionList.Item(id: "day-\($0)", title: $0 == 2 ? third : "Day \($0)", detail: "⌘\($0 + 1)") }
        }
        let start = AtticDropdownDiagnostics.hintRetains
        AtticDropdownDiagnostics.enabled = true
        defer { AtticDropdownDiagnostics.enabled = false }
        let (host, _, window) = try show(Suggestions(items: items("Tomorrow"), highlighted: 0))
        defer { window.close() }
        waitUntil(host) { AtticDropdownDiagnostics.hintRetains - start >= 5 }
        turns()
        let shown = AtticDropdownDiagnostics.hintRetains - start
        for index in 1..<5 {
            host.rootView = Suggestions(items: items("Tomorrow"), highlighted: index)
            host.layoutSubtreeIfNeeded()
            turns()
        }
        let moved = AtticDropdownDiagnostics.hintRetains - start
        host.rootView = Suggestions(items: items("Tomorrow, Friday"), highlighted: 4)
        host.layoutSubtreeIfNeeded()
        turns()
        let retitled = AtticDropdownDiagnostics.hintRetains - start
        NSLog("SCROLLID rebuilds shown=%d moved=%d retitled=%d", shown, moved, retitled)
        XCTAssertEqual(shown, 5, "each row appears once")
        XCTAssertEqual(moved, shown, "moving the highlight rebuilds no row")
        XCTAssertLessThanOrEqual(retitled, moved + 1, "a new title rebuilds at most its own row")
    }
    #endif

    // MARK: Tag bar "All" (checked: an `.id` beside a String-keyed ForEach)

    /// The keyboard's stop on "All" scrolls back to it after a stop on the
    /// last tag scrolled away: "All" has its `.id` beside the tags'
    /// String-keyed `ForEach`, not inside it.
    func testTagBarKeyboardStopOnAllScrollsBackToIt() throws {
        let state = PanelTagBarState()
        state.open()
        let tags = (0..<30).map { String(format: "tag-%02d", $0) }
        let host = NSHostingView(rootView: NotesTagBar(tags: tags, picks: .none, state: state, onSelect: { _ in })
            .atticDesign(AtticDesignContext(mode: .light, reduceMotion: true)).frame(width: 240, height: 60))
        let window = makeWindow()
        defer { window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 60)
        window.contentView?.addSubview(host)
        waitUntil(host) { !self.scrollViews(in: host).isEmpty }
        let bar = try XCTUnwrap(scrollViews(in: host).first, "the tag bar scrolls")
        func x() -> CGFloat { bar.contentView.bounds.origin.x }
        XCTAssertEqual(x(), 0, accuracy: 0.5, "the bar opens at its start")

        state.open(cursor: .tag("tag-29"))
        waitUntil(host) { x() > 1 }
        XCTAssertGreaterThan(x(), 1, "a stop on the last tag scrolls to it")

        state.open(cursor: .all)
        waitUntil(host) { x() < 0.5 }
        XCTAssertEqual(x(), 0, accuracy: 0.5, "a stop on All scrolls back to it")
    }

    // MARK: Helpers

    private func show<V: View>(_ view: V) throws -> (NSHostingView<V>, NSScrollView, NSWindow) {
        let window = makeWindow()
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 320)
        window.contentView?.addSubview(host)
        waitUntil(host) { !self.scrollViews(in: host).isEmpty }
        turns()
        let list = try XCTUnwrap(scrollViews(in: host).first, "the list scrolls")
        return (host, list, window)
    }

    private func offset(_ list: NSScrollView) -> CGFloat { list.contentView.bounds.origin.y }

    /// Row `index` lies wholly inside the shown part of the list (rows
    /// start at the top of the scrolled content; the card's inset is outside it).
    private func shows(row index: Int, in list: NSScrollView) -> Bool {
        let top = CGFloat(index) * AtticDropdownMetrics.rowHeight
        let shown = list.contentView.bounds
        return top >= shown.minY - 0.5 && top + AtticDropdownMetrics.rowHeight <= shown.maxY + 0.5
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        window.orderFrontRegardless()
        return window
    }

    /// Waits, laying `host` out, until `condition` holds (or fails the test after 3 s).
    private func waitUntil(_ host: NSView, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        waitForTestOperation("the list's state", file: file, line: line) {
            host.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    /// `count` turns of the main queue, for callbacks SwiftUI posts after an update.
    private func turns(_ count: Int = 2) {
        for _ in 0..<count {
            let turned = expectation(description: "a main-queue turn")
            DispatchQueue.main.async { turned.fulfill() }
            wait(for: [turned], timeout: 1)
        }
    }

    /// The scroll views under `view`, outermost first.
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] + view.subviews.flatMap(scrollViews(in:)) } ?? view.subviews.flatMap(scrollViews(in:))
    }

    private func accessibilityElements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { accessibilityElements($0 as AnyObject) }
    }

    /// The app's current event is a neutral one, so the list does not read
    /// a stale pointer event as the pointer's highlight.
    private func restoreNeutralCurrentEvent() {
        guard let neutral = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                               context: nil, subtype: 0, data1: 0, data2: 0) else { return }
        NSApp.postEvent(neutral, atStart: true)
        if let next = NSApp.nextEvent(matching: .applicationDefined, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
    }

    /// The app's current event is a pointer move, as when the real pointer moved.
    private func leaveAMouseMoveAsTheCurrentEvent(in window: NSWindow) {
        guard let moved = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            return XCTFail("could not make a mouse-moved event")
        }
        NSApp.postEvent(moved, atStart: true)
        if let next = NSApp.nextEvent(matching: .mouseMoved, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
    }

    /// The pointer on a window point: each tracking area's owner hears it
    /// enter and move, as AppKit tells them when the real pointer moves (no
    /// real pointer is touched).
    private final class Pointer {
        func move(in host: NSView, toWindowPoint location: CGPoint) throws {
            let window = try XCTUnwrap(host.window)
            host.layoutSubtreeIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: now,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 0, pressure: 0))
            for view in views(host) {
                for area in view.trackingAreas {
                    guard let owner = area.owner as? NSResponder else { continue }
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                    guard rect.contains(view.convert(location, from: nil)) else { continue }
                    if area.options.contains(.mouseEnteredAndExited),
                       let event = NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [], timestamp: now,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                          trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil) {
                        owner.mouseEntered(with: event)
                    }
                    if area.options.contains(.mouseMoved) { owner.mouseMoved(with: moved) }
                }
            }
        }
    }
}
