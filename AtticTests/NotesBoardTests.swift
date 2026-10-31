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
/// 24 pt surface squircle; long links wrap; the list keeps its sections.
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
        XCTAssertEqual(model.navigable(groups, layout: .board, store: store).flatMap { $0.rows.map(\.id) }.first, pinned)
        XCTAssertFalse(model.navigable(groups, layout: .list, store: store).flatMap { $0.rows.map(\.id) }.contains(pinned))
    }

    /// Fix round 1 (should-fix 2): a search's results on the board keep
    /// the pinned first (stable), while the list keeps them by date.
    func testBoardSearchResultsKeepThePinnedFirst() async throws {
        let pinned = try create("Kyoto pinned")
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let newer = try create("Kyoto newer")
        let newest = try create("Kyoto newest")
        let model = NotesLibraryModel(search: { _ in [pinned, newer, newest] }, store: store)
        model.query = "kyoto"
        await model.waitForSearch()
        let groups = model.groups(store: store, drafts: [], prepareSummaries: false)
        let listed = groups.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(Set(listed), [pinned, newer, newest])
        XCTAssertNotEqual(listed.first, pinned, "the list's results stay by date")
        let flow = listed.filter { $0 != pinned }
        let columns = model.boardColumns(groups, store: store)
        XCTAssertEqual(columns[0].first?.id, pinned, "the board's first card is the pinned one")
        XCTAssertEqual(columns.flatMap { $0 }.count, 3)
        // The rest keep their order across the columns (each column in flow).
        for column in columns {
            let rest = column.map(\.id).filter { $0 != pinned }
            XCTAssertEqual(rest, flow.filter(rest.contains), "stable")
        }
        XCTAssertEqual(model.navigable(groups, layout: .board, store: store).flatMap { $0.rows.map(\.id) },
                       [pinned] + flow, "↑ ↓ follow the board's flow")
        XCTAssertEqual(model.navigable(groups, layout: .list, store: store).flatMap { $0.rows.map(\.id) }, listed)
    }

    /// Fix round 1 (should-fix 3): a never-saved draft moves no store
    /// revision, so its title, text and images must re-estimate its card.
    func testADraftsEditReestimatesItsCard() throws {
        let first = try create("A")
        let second = try create("B")
        let draft = UUID()
        func draftRow(_ preview: String) -> AtticNoteRowModel {
            AtticNoteRowModel(id: draft, title: "Draft", time: "09:40", needsAttention: true, hasProposal: false,
                              preview: preview, spoken: "Draft")
        }
        func saved(_ id: UUID, _ title: String) -> AtticNoteRowModel {
            AtticNoteRowModel(id: id, title: title, time: "09:40", needsAttention: false, hasProposal: false,
                              preview: "", spoken: title)
        }
        let model = NotesLibraryModel(search: { _ in [] }, store: store)
        func columns(_ preview: String) -> [[UUID]] {
            let group = NotesLibraryModel.Group(id: "today", title: "Today",
                                                rows: [draftRow(preview), saved(first, "A"), saved(second, "B")])
            return model.boardColumns([group], store: store).map { $0.map(\.id) }
        }
        XCTAssertEqual(columns(""), [[draft, second], [first]], "three short cards")
        let revision = store.revision
        let long = String(repeating: "A draft that keeps growing. ", count: 8)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(columns(long), [[draft], [first, second]], "the draft's card is taller now")
        XCTAssertEqual(columns(""), [[draft, second], [first]], "and shorter again")
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

    private func library(_ model: NotesLibraryModel, _ controller: NotesPageController,
                         keys: NotesLibraryKeys? = nil) -> NotesLibraryView {
        NotesLibraryView(model: model, controller: controller, store: store,
            layout: PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 320, height: 460)),
            bottomClearance: 0, searchFocused: .constant(false), searchOpen: .constant(false),
            rowCommands: { _ in [] }, libraryCommands: { [] }, onOpen: { _ in },
            onDelete: { _ in }, onBack: {}, keys: keys ?? NotesLibraryKeys())
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

    private func card(title: String, preview: String, pinned: Bool = false, selected: Bool = false,
                      highlighted: Bool = false) -> NotesBoardCard {
        let row = AtticNoteRowModel(id: UUID(), title: title, time: "09:40", needsAttention: false, hasProposal: false,
                                    preview: preview, spoken: title)
        return NotesBoardCard(details: NotesLibraryModel.RowDetails(row: row, tag: nil,
                                  thumbnail: NoteThumbnailContent(title: title, text: preview, hasImages: false)),
                              pinned: pinned, isSelected: selected, isHighlighted: highlighted,
                              commands: { [] }, anchors: AtticNoteRowAnchors(), onShowActions: {}, onOpen: {})
    }

    /// The opaque raised surface (Reduce Transparency): glass draws as
    /// artefacts off screen, the solid surface does not.
    private var solid: AtticDesignContext {
        var context = AtticDesignContext.default
        context.reduceTransparency = true
        return context
    }

    private static let backdrop = AtticRGBA(red: 1, green: 0, blue: 1)

    /// `view` at 2×, `size` points, on a magenta backdrop.
    private func render<V: View>(_ view: V, size: CGSize, context: AtticDesignContext) throws -> NSBitmapImageRep {
        let content = view
            .frame(width: size.width, height: size.height)
            .background(Self.backdrop.color)
            .atticDesign(context)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func pixel(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) throws -> AtticRGBA {
        let colour = try XCTUnwrap(bitmap.colorAt(x: Int((x * 2).rounded(.down)), y: Int((y * 2).rounded(.down)))?
            .usingColorSpace(.sRGB))
        return AtticRGBA(red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent)
    }

    private func distance(_ a: AtticRGBA, _ b: AtticRGBA) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255
    }

    private func fit<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view.atticDesign(.default)).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    func testCardsAreTwentyFourPointSurfaceSquircles() throws {
        XCTAssertEqual(NotesBoardMetrics.radius, AtticRadius.card)
        XCTAssertEqual(NotesBoardMetrics.radius, 24, "48 px (owner, 2026-10-31)")
        XCTAssertEqual(NotesBoardMetrics.columnGap, 6)
        XCTAssertEqual(NotesBoardMetrics.cardGap, 6)

        // A drawn card: where its corner is surface and where it is the
        // backdrop matches the 24 pt surface squircle, point by point.
        let width: CGFloat = 140
        let height = fit(card(title: "Shape", preview: "A card"), width: width).height
        let bitmap = try render(card(title: "Shape", preview: "A card"), size: CGSize(width: width, height: height), context: solid)
        let shape = Squircle(cornerRadius: 24, exponent: AtticShape.surfaceExponent)
            .path(in: CGRect(x: 0, y: 0, width: width, height: height))
        let surface = try pixel(bitmap, width / 2, height - 3)
        // The backdrop as this render draws it (its colour space), from
        // the corner pixel, outside any 24 pt corner.
        let backdrop = try pixel(bitmap, 0, 0)
        XCTAssertGreaterThan(distance(surface, backdrop), 100, "the card is drawn")
        var checked = 0
        for step in stride(from: CGFloat(0.5), through: 12, by: 0.5) {
            let inner = CGPoint(x: step + 0.75, y: step + 0.75), outer = CGPoint(x: step - 0.75, y: step - 0.75)
            let inside = shape.contains(CGPoint(x: step, y: step))
            // Skip the anti-aliased edge.
            guard shape.contains(inner) == inside, shape.contains(outer) == inside else { continue }
            let colour = try pixel(bitmap, step, step)
            if inside {
                XCTAssertLessThan(distance(colour, surface), 24, "(\(step), \(step)) is the card")
            } else {
                XCTAssertLessThan(distance(colour, backdrop), 8, "(\(step), \(step)) is outside the squircle")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 8)
        // Not a plain 24 pt circle-cornered rectangle: the squircle reaches
        // further into the corner along the diagonal.
        let circle = Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 24, style: .circular)
        XCTAssertTrue((stride(from: CGFloat(0.5), through: 12, by: 0.5)).contains {
            shape.contains(CGPoint(x: $0, y: $0)) != circle.contains(CGPoint(x: $0, y: $0))
        }, "the surface exponent shapes the corner")
    }

    /// Fix round 1 (should-fix 4): the selected card and the keyboard's
    /// card take the design's 2 px (1 pt) ring, inset 0 0 0 2px
    /// rgba(29,29,31,0.45), not a fill.
    func testTheSelectedCardIsAOnePointRingNotAFill() throws {
        let width: CGFloat = 140
        let size = CGSize(width: width, height: fit(card(title: "Ring", preview: ""), width: width).height)
        let rest = try render(card(title: "Ring", preview: ""), size: size, context: solid)
        for (name, view) in [("selected", card(title: "Ring", preview: "", selected: true)),
                             ("keyboard", card(title: "Ring", preview: "", highlighted: true))] {
            let marked = try render(view, size: size, context: solid)
            // Inside: the surface as at rest (no fill).
            for point in [CGPoint(x: width / 2, y: size.height - 4), CGPoint(x: width * 0.6, y: size.height / 2)] {
                XCTAssertLessThan(distance(try pixel(marked, point.x, point.y), try pixel(rest, point.x, point.y)), 3,
                                  "\(name): no fill at \(point)")
            }
            // The edge, half a point in: the ring.
            let edge = try pixel(marked, 0.5, size.height / 2)
            let restEdge = try pixel(rest, 0.5, size.height / 2)
            XCTAssertGreaterThan(distance(edge, restEdge), 40, "\(name): a ring on the edge")
            // Two points in, it has ended (1 pt wide).
            XCTAssertLessThan(distance(try pixel(marked, 2.25, size.height / 2), try pixel(rest, 2.25, size.height / 2)), 3,
                              "\(name): the ring is 1 pt")
        }
    }

    /// The small pin is drawn in the see-through meta grey.
    func testThePinIsDrawnInTheMetaInk() throws {
        let width: CGFloat = 140
        let view = card(title: "Pinned", preview: "", pinned: true)
        let size = CGSize(width: width, height: fit(view, width: width).height)
        let bitmap = try render(view, size: size, context: solid)
        let surface = try pixel(bitmap, width / 2, size.height - 3)
        // The darkest point of the title line's trailing end is the pin.
        var darkest = surface
        for y in stride(from: CGFloat(8), through: 22, by: 0.5) {
            for x in stride(from: width - 30, through: width - 2, by: 0.5) {
                let colour = try pixel(bitmap, x, y)
                if distance(colour, surface) > distance(darkest, surface) { darkest = colour }
            }
        }
        // The ink on the same surface, drawn by the same renderer.
        let swatch = Color.clear
            .atticRaisedMaterial(cornerRadius: 0, interactive: false)
            .overlay { Rectangle().fill(TasksPanelDesign.toneInk(.meta, tokens: solid.tokens).color) }
        let ink = try pixel(try render(swatch, size: CGSize(width: 10, height: 10), context: solid), 5, 5)
        XCTAssertGreaterThan(distance(darkest, surface), 30, "a pin is drawn")
        XCTAssertLessThan(distance(darkest, ink), 6, "in toneInk(.meta): \(darkest) against \(ink)")
    }

    /// Fix round 1 (minor): the resting title takes the card's whole
    /// width, as the design's; "•••" on hover never changes the height.
    func testTheRestingTitleUsesTheFullWidthAndHoverKeepsTheHeight() throws {
        typealias M = NotesBoardMetrics
        let width: CGFloat = 160
        let inner = width - M.padding.leading - M.padding.trailing
        func title(_ string: String, width: CGFloat) -> CGFloat {
            fit(Text(verbatim: string)
                .font(.system(size: M.titleSize, weight: .semibold))
                .lineSpacing(M.lineSpacing(size: M.titleSize, weight: .semibold, line: M.titleLine))
                .lineLimit(M.titleLines)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true), width: width).height
        }
        // A title that fits on the card's whole width but would wrap if
        // "•••"'s room were kept.
        let words = "Weekly planning notes for the studio".split(separator: " ")
        var found: String?
        var string = ""
        for word in words {
            string += (string.isEmpty ? "" : " ") + word
            for extra in ["", "s", "es", " ab", " abc"] {
                let candidate = string + extra
                if title(candidate, width: inner) < title(candidate, width: inner - M.actionsSide), found == nil {
                    found = candidate
                }
            }
        }
        let long = try XCTUnwrap(found, "a title on the edge")
        let rest = fit(card(title: long, preview: ""), width: width).height
        let short = fit(card(title: "A", preview: ""), width: width).height
        XCTAssertEqual(rest - short, title(long, width: inner) - title("A", width: inner), accuracy: 0.5,
                       "the resting title wraps at the card's whole width")
        let hover = fit(card(title: long, preview: "").atticForcedState(.hover), width: width).height
        XCTAssertEqual(hover, rest, accuracy: 0.01, "hover shows ••• without changing the height")
    }

    /// Fix round 1 (coordinator's correction): the switch's marker
    /// crossfades in each cell, as Now · Later · Done's (160 ms ease-out,
    /// at once under Reduce Motion), never sliding: no frame of the change
    /// draws the marker over the 1 pt gap between the two cells.
    func testTheSwitchMarkerCrossfadesAndNeverSlides() throws {
        XCTAssertEqual(NotesLayoutSwitch.selectionAnimation(reduceMotion: false),
                       AtticSelectionMarker.animation(reduceMotion: false))
        XCTAssertNil(NotesLayoutSwitch.selectionAnimation(reduceMotion: true), "Reduce Motion: at once")

        let holder = LayoutHolder()
        let size = CGSize(width: NotesLayoutSwitchMetrics.width, height: AtticControlSize.headerControl)
        let host = NSHostingView(rootView: AnyView(LayoutSwitchHost(holder: holder)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .atticDesign(solid)
            .environment(\.colorScheme, .light)))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        spin(0.3)

        typealias S = NotesLayoutSwitchMetrics
        let gapX = S.inset + S.cell + S.gap / 2
        let boardX = S.inset + S.cell / 2
        let y = size.height / 2
        func capture() throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        func colour(_ rep: NSBitmapImageRep, _ x: CGFloat) throws -> AtticRGBA {
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            let c = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            return AtticRGBA(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
        }
        let rest = try capture()
        let gap = try colour(rest, gapX), boardAtRest = try colour(rest, boardX)
        holder.layout = .board
        for frame in 0..<14 {
            spin(0.012)
            let shot = try capture()
            XCTAssertLessThan(distance(try colour(shot, gapX), gap), 4, "frame \(frame): the marker never crosses the gap")
        }
        spin(0.4)
        XCTAssertGreaterThan(distance(try colour(try capture(), boardX), boardAtRest), 4, "the marker is on Board now")
    }

    func testTheSwitchGlyphsAreTheRowsIconSize() {
        XCTAssertEqual(NotesLayoutSwitchMetrics.glyph, AtticControlSize.raisedGlyph, "Accepted: 12.2 pt icons")
        XCTAssertEqual(AtticControlSize.raisedGlyph, 12.2)
    }

    func testALongLinkWrapsInsteadOfWideningTheCard() {
        let width: CGFloat = 140
        let link = "https://example.com/" + String(repeating: "averyveryverylongpathsegment", count: 3)
        let short = fit(card(title: "Links", preview: "x"), width: width)
        let long = fit(card(title: "Links", preview: link), width: width)
        XCTAssertLessThanOrEqual(long.width, width + 0.5, "the card keeps its column's width")
        XCTAssertGreaterThan(long.height, short.height + NotesBoardMetrics.snippetLine, "the link wraps onto more lines")
        let longTitle = fit(card(title: link, preview: ""), width: width)
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
        // Counted from the first layout (building the host lays it out).
        NotesBoardCard.bodyEvaluations = 0
        let (host, window) = host(library(model, controller))
        defer { window.contentView = nil; window.close() }
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

    /// Fix round 1 (minor): no helper text: the card's "•••" has its name
    /// for VoiceOver and no tooltip.
    func testTheCardsActionsHaveNoTooltip() throws {
        let note = try create("A note")
        let controller = controller()
        XCTAssertTrue(controller.showLibrary())
        let model = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        model.layout = .board
        model.highlightedID = note // the keyboard's card shows its •••
        try withAccessibility {
            let (host, window) = host(library(model, controller))
            defer { window.contentView = nil; window.close() }
            spin(0.3)
            host.layoutSubtreeIfNeeded()
            let actions = elements(host).filter { ($0.accessibilityIdentifier?() ?? "") == "notes-row-actions" }
            XCTAssertFalse(actions.isEmpty)
            for element in actions {
                XCTAssertEqual(element.accessibilityLabel?() ?? "", "Actions for A note")
                XCTAssertTrue((element.accessibilityHelp?() ?? "").isEmpty, "no tooltip: \(element.accessibilityHelp?() ?? "")")
            }
        }
    }

    // MARK: Keyboard reveal

    private func press(_ keys: NotesLibraryKeys, keyCode: UInt16) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: keyCode)!
        _ = keys.handler?(event)
    }

    private func boardScroll(_ host: NSView) throws -> NSScrollView {
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        return try XCTUnwrap(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    private func boardHost(notes count: Int) throws
        -> (host: NSHostingView<AnyView>, window: NSWindow, keys: NotesLibraryKeys, model: NotesLibraryModel) {
        for index in 0..<count {
            try create("Note \(index)", index.isMultiple(of: 3) ? String(repeating: "Some writing. ", count: index % 7) : "")
        }
        let controller = controller()
        XCTAssertTrue(controller.showLibrary())
        let model = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        model.layout = .board
        let keys = NotesLibraryKeys()
        let (host, window) = host(library(model, controller, keys: keys))
        spin(0.3)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(keys.handler, "the library listens for its keys")
        return (host, window, keys, model)
    }

    /// Fix round 1 (should-fix 1): ↑ from nothing goes to the last card,
    /// far below and not built yet. It is jumped to at once, never by an
    /// animated `scrollTo` over the lazy board (the list hang).
    func testRevealJumpsToACardNotBuiltYet() throws {
        let (host, window, keys, model) = try boardHost(notes: 240)
        defer { window.contentView = nil; window.close() }
        let scroll = try boardScroll(host)
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, 10)
        press(keys, keyCode: 126)
        XCTAssertNotNil(model.highlightedID)
        spin(0.03)
        host.layoutSubtreeIfNeeded()
        let jumped = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(jumped, 1_000, "the last card is far down the board")
        spin(0.8)
        host.layoutSubtreeIfNeeded()
        // A jump: there at once. The lazy board may still correct the
        // estimated heights of the cards it builds there by less than a
        // card; an animated scroll would still be on its way (≈ 6,600 pt).
        XCTAssertEqual(scroll.contentView.bounds.origin.y, jumped, accuracy: 200, "a jump, not an animation")
    }

    /// Fix round 1 (should-fix 1): ↓ through 240 cards, past cards not
    /// built yet, keeps card updates bounded and ends with the last card
    /// in view; the board then settles.
    func testArrowDownThroughTheBoardKeepsUpdatesBounded() throws {
        let (host, window, keys, model) = try boardHost(notes: 240)
        defer { window.contentView = nil; window.close() }
        let scroll = try boardScroll(host)
        NotesBoardCard.bodyEvaluations = 0
        var worst = 0
        for _ in 0..<240 {
            let before = NotesBoardCard.bodyEvaluations
            press(keys, keyCode: 125)
            spin(0.02)
            host.layoutSubtreeIfNeeded()
            worst = max(worst, NotesBoardCard.bodyEvaluations - before)
        }
        XCTAssertLessThan(worst, 60, "one ↓ builds at most a screenful")
        spin(1)
        host.layoutSubtreeIfNeeded()
        let total = NotesBoardCard.bodyEvaluations
        XCTAssertLessThan(total, 2_400, "bounded over the whole walk (\(total))")
        spin(0.5)
        XCTAssertEqual(NotesBoardCard.bodyEvaluations, total, "after the walk, the board settles")
        let ids = model.orderedIDs(model.navigable(model.groups(store: store, drafts: [], prepareSummaries: false),
                                                   layout: .board, store: store))
        XCTAssertEqual(model.highlightedID, ids.last)
        let clip = scroll.contentView
        let document = scroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(clip.bounds.maxY + clip.contentInsets.bottom, document - 400,
                             "the walk has brought the board to its end")
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

@MainActor
private final class LayoutHolder: ObservableObject {
    @Published var layout: NotesLibraryLayout = .list
}

private struct LayoutSwitchHost: View {
    @ObservedObject var holder: LayoutHolder
    var body: some View { NotesLayoutSwitch(selection: $holder.layout) }
}
