import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// The notes board (Accepted 2026-10-30, "Notes board"): the board | list
/// layout, persisted per user (the design's default, list); one flowing
/// two-column board with no headings, pinned first with a small grey pin,
/// each card in the shorter column by a height estimated from its content
/// (never measured, so layout can't feed back into itself); cards on the
/// 18 pt surface squircle; long links wrap; the list keeps its sections.
@MainActor
final class NotesBoardTests: XCTestCase {
    private var store: NoteStore!

    override func setUp() async throws {
        store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
    }

    @discardableResult
    private func create(_ title: String, _ body: String = "", tags: [String] = []) throws -> UUID {
        let blocks: [NoteBlock] = body.isEmpty ? [.text(title)] : [.text(title), .text(body)]
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks),
                                                                   tags: tags.isEmpty ? nil : tags) else {
            throw NSError(domain: "create", code: 1)
        }
        return id
    }

    private func controller(defaults: UserDefaults? = nil) -> NotesPageController {
        NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "NotesBoard")), defaults: defaults,
            saveDelay: .seconds(600), durabilityDelay: .seconds(600))
    }

    // MARK: Layout state

    func testTheLayoutStartsAsTheDesignsListAndIsKeptPerUser() throws {
        let suite = "NotesBoard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NotesLibraryLayout.default, .list, "the design's default")

        let first = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller(defaults: defaults))
        XCTAssertEqual(first.layout, .list)
        first.layout = .board
        XCTAssertEqual(defaults.string(forKey: NotesLibraryLayout.defaultsKey), "board")

        let second = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller(defaults: defaults))
        XCTAssertEqual(second.layout, .board, "the choice survives a new page (and a relaunch)")
        second.layout = .list
        let third = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller(defaults: defaults))
        XCTAssertEqual(third.layout, .list)

        // No defaults (tests, previews): the default, and nothing stored.
        let loose = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller())
        XCTAssertEqual(loose.layout, .list)
        loose.layout = .board
        XCTAssertEqual(loose.layout, .board)
    }

    // MARK: Columns

    func testColumnsGoToTheShorterColumnDeterministically() {
        // The design's estimate, halved: 33.5 base, 14 per title line (up
        // to 3, 17 characters each), 3 + 13 per snippet line (up to 6, 22
        // each), images 56 (75 from three).
        XCTAssertEqual(NotesBoardLayout.estimatedHeight(titleLength: 10, snippetLength: 0, images: 0), 47.5)
        XCTAssertEqual(NotesBoardLayout.estimatedHeight(titleLength: 40, snippetLength: 0, images: 0), 33.5 + 14 * 3)
        XCTAssertEqual(NotesBoardLayout.estimatedHeight(titleLength: 200, snippetLength: 0, images: 0), 33.5 + 14 * 3)
        XCTAssertEqual(NotesBoardLayout.estimatedHeight(titleLength: 5, snippetLength: 23, images: 0), 33.5 + 14 + 3 + 13 * 2)
        XCTAssertEqual(NotesBoardLayout.estimatedHeight(titleLength: 5, snippetLength: 500, images: 0), 33.5 + 14 + 3 + 13 * 6)
        XCTAssertEqual(NotesBoardLayout.estimatedHeight(titleLength: 5, snippetLength: 0, images: 1), 56 + 47.5)
        XCTAssertEqual(NotesBoardLayout.estimatedHeight(titleLength: 5, snippetLength: 0, images: 3), 75 + 47.5)

        // Ties go left; then each card to the shorter column (with the 6 pt gap).
        XCTAssertEqual(NotesBoardLayout.columns(heights: [100, 50, 50, 50]), [0, 1, 1, 0])
        XCTAssertEqual(NotesBoardLayout.columns(heights: []), [])

        var generator = SplitMix(seed: 7)
        let heights = (0..<200).map { _ in CGFloat(40 + generator.next() % 160) }
        let assignment = NotesBoardLayout.columns(heights: heights)
        XCTAssertEqual(assignment, NotesBoardLayout.columns(heights: heights), "the same notes, the same board")
        var totals: [CGFloat] = [0, 0]
        for (height, column) in zip(heights, assignment) { totals[column] += height + NotesBoardMetrics.cardGap }
        XCTAssertLessThanOrEqual(abs(totals[0] - totals[1]), (heights.max() ?? 0) + NotesBoardMetrics.cardGap, "balanced")
    }

    func testTheBoardFlowsPinnedFirstWithoutSections() throws {
        let old = try create("Old note", "Kyoto offsite agenda")
        let today = try create("Today note", String(repeating: "A long paragraph of writing. ", count: 8))
        let pinned = try create("Pinned note")
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let model = NotesLibraryModel(search: { _ in [] }, store: store)
        let groups = model.groups(store: store, drafts: [], prepareSummaries: false)
        let columns = model.boardColumns(groups, store: store)
        XCTAssertEqual(columns.count, 2, "two columns")
        XCTAssertEqual(columns[0].first?.id, pinned, "pinned first")
        XCTAssertEqual(Set(columns.flatMap { $0.map(\.id) }), [old, today, pinned], "every note once")
        XCTAssertEqual(model.boardColumns(groups, store: store).map { $0.map(\.id) }, columns.map { $0.map(\.id) })

        // A folded list section folds nothing on the board: no headings there.
        model.toggleGroup("pinned", in: groups)
        XCTAssertEqual(model.navigable(groups, layout: .board).flatMap { $0.rows.map(\.id) }.first, pinned)
        XCTAssertFalse(model.navigable(groups, layout: .list).flatMap { $0.rows.map(\.id) }.contains(pinned))
    }

    // MARK: Hosted

    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 320, height: 460))
        -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).atticDesign(.default)))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (host, window)
    }

    private func library(_ model: NotesLibraryModel, _ controller: NotesPageController)
        -> NotesLibraryView {
        NotesLibraryView(model: model, controller: controller, store: store,
            layout: PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 320, height: 460)),
            bottomClearance: 0, searchFocused: .constant(false), searchOpen: .constant(false),
            rowCommands: { _ in [] }, libraryCommands: { [] }, onOpen: { _ in },
            onDelete: { _ in }, onBack: {}, keys: NotesLibraryKeys())
    }

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func identifiers(in host: NSView) -> [String] {
        elements(host).compactMap { $0.accessibilityIdentifier?() }.filter { !$0.isEmpty }
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func withAccessibility(_ body: () throws -> Void) rethrows {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        try body()
    }

    func testTheBoardHasTwoColumnsNoHeadingsAndAGreyPinOnPinnedCards() throws {
        try create("Old note", "Kyoto offsite agenda")
        try create("Today note")
        let pinned = try create("Pinned note")
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let controller = controller()
        XCTAssertTrue(controller.showLibrary())
        let model = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        model.layout = .board
        try withAccessibility {
            let (host, window) = host(library(model, controller))
            defer { window.contentView = nil; window.close() }
            spin(0.3)
            host.layoutSubtreeIfNeeded()
            let ids = identifiers(in: host)
            XCTAssertTrue(ids.contains("notes-board-column-0"))
            XCTAssertTrue(ids.contains("notes-board-column-1"))
            XCTAssertFalse(ids.contains { $0.hasPrefix("notes-library-group-") }, "no section headings: \(ids)")
            let cards = elements(host).filter { ($0.accessibilityIdentifier?() ?? "") == "notes-board-card" }
            XCTAssertEqual(cards.count, 3)
            let labels = cards.compactMap { $0.accessibilityLabel?() }
            XCTAssertEqual(labels.filter { $0.hasPrefix("Pinned") }.count, 1, "only the pinned card has the pin: \(labels)")
        }
    }

    func testTheListKeepsItsSections() throws {
        try create("Today note")
        let pinned = try create("Pinned note")
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let controller = controller()
        XCTAssertTrue(controller.showLibrary())
        let model = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        XCTAssertEqual(model.layout, .list)
        try withAccessibility {
            let (host, window) = host(library(model, controller))
            defer { window.contentView = nil; window.close() }
            spin(0.3)
            host.layoutSubtreeIfNeeded()
            let ids = identifiers(in: host)
            XCTAssertTrue(ids.contains("notes-library-group-pinned"))
            XCTAssertTrue(ids.contains("notes-library-group-today"))
            XCTAssertTrue(ids.contains("notes-library-row"))
            XCTAssertFalse(ids.contains { $0.hasPrefix("notes-board-") })
        }
    }

    // MARK: Cards

    func testCardsAreEighteenPointSurfaceSquircles() {
        XCTAssertEqual(NotesBoardMetrics.radius, AtticRadius.card)
        XCTAssertEqual(NotesBoardMetrics.radius, 18, "36 px")
        XCTAssertEqual(NotesBoardMetrics.cornerExponent, AtticShape.surfaceExponent, "a surface: a squircle")
        XCTAssertEqual(NotesBoardMetrics.columnGap, 6)
        XCTAssertEqual(NotesBoardMetrics.cardGap, 6)
    }

    private func card(title: String, preview: String) -> NotesBoardCard {
        let row = AtticNoteRowModel(id: UUID(), title: title, time: "09:40", needsAttention: false, hasProposal: false,
                                    preview: preview, spoken: title)
        return NotesBoardCard(details: NotesLibraryModel.RowDetails(row: row, tag: nil,
                                  thumbnail: NoteThumbnailContent(title: title, text: preview, hasImages: false)),
                              pinned: false, commands: { [] }, anchors: AtticNoteRowAnchors(), onShowActions: {}, onOpen: {})
    }

    func testALongLinkWrapsInsteadOfWideningTheCard() {
        let width: CGFloat = 140
        func fit(_ view: NotesBoardCard) -> CGSize {
            NSHostingController(rootView: view.atticDesign(.default))
                .sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        let link = "https://example.com/" + String(repeating: "averyveryverylongpathsegment", count: 3)
        let short = fit(card(title: "Links", preview: "x"))
        let long = fit(card(title: "Links", preview: link))
        XCTAssertLessThanOrEqual(long.width, width + 0.5, "the card keeps its column's width")
        XCTAssertGreaterThan(long.height, short.height + NotesBoardMetrics.snippetLine, "the link wraps onto more lines")
        let longTitle = fit(card(title: link, preview: ""))
        XCTAssertLessThanOrEqual(longTitle.width, width + 0.5)
    }

    // MARK: Updates

    func testScrollingTheBoardKeepsCardUpdatesBounded() throws {
        for index in 0..<240 {
            try create("Note \(index)", index.isMultiple(of: 3) ? String(repeating: "Some writing. ", count: index % 7) : "")
        }
        let controller = controller()
        XCTAssertTrue(controller.showLibrary())
        let model = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        model.layout = .board
        let (host, window) = host(library(model, controller))
        defer { window.contentView = nil; window.close() }
        NotesBoardCard.bodyEvaluations = 0
        spin(0.3)
        host.layoutSubtreeIfNeeded()
        let mounted = NotesBoardCard.bodyEvaluations
        XCTAssertGreaterThan(mounted, 0)
        XCTAssertLessThan(mounted, 80, "lazy: only the cards near the screen are built (\(mounted))")

        // At rest nothing redraws: no layout feeds back into state.
        let rest = NotesBoardCard.bodyEvaluations
        spin(0.5)
        XCTAssertEqual(NotesBoardCard.bodyEvaluations, rest, "a settled board stays settled")

        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        let list = try XCTUnwrap(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        var y: CGFloat = 0
        for _ in 0..<12 {
            let before = NotesBoardCard.bodyEvaluations
            y += 300
            list.contentView.scroll(to: CGPoint(x: 0, y: y))
            list.reflectScrolledClipView(list.contentView)
            spin(0.05)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThan(NotesBoardCard.bodyEvaluations - before, 60, "one scroll step builds a screenful, not the board")
        }
        let settled = NotesBoardCard.bodyEvaluations
        spin(0.5)
        XCTAssertEqual(NotesBoardCard.bodyEvaluations, settled, "after scrolling, the board settles")
        XCTAssertLessThan(settled, 600, "bounded over the whole scroll (\(settled))")
    }
}

/// A small seeded generator, so the balance test's heights never change.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int(truncatingIfNeeded: (z ^ (z >> 31)) >> 1)
    }
}
