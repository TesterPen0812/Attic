import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The owner's UI picks and the design-system batch (Phase X, 2026-10-11):
/// N-2's highlighter colours, N-4's dropdown card and reveal, N-5's active
/// cell, N-6's fade before the controls, and the design-review fixes.
@MainActor
final class PhaseXPicksTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func engine(_ document: NoteDocument) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: document, readOnly: false)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        window.makeFirstResponder(textView)
        scrollView.layoutSubtreeIfNeeded()
        return (engine, textView)
    }

    private func range(_ text: String, _ textView: NSTextView) -> NSRange {
        (textView.string as NSString).range(of: text)
    }

    // MARK: - N-2: the highlighter's colours

    /// A colour highlight is stored as its key on the mark, read back the
    /// same, and grey stores its explicit key; a colour on any other mark is refused.
    private func block(_ text: String, _ marks: [NoteMark]) -> NoteBlock {
        var block = NoteBlock.text(text)
        block.marks = marks
        return block
    }

    private func roundTrip(_ document: NoteDocument) throws -> NoteDocument {
        guard case let .editable(decoded) = NoteContentCodec.decode(try NoteContentCodec.encode(document)) else {
            throw XCTSkip("not editable")
        }
        return decoded
    }

    func testAHighlightsColourRoundTripsAndGreyStoresItsKey() throws {
        let document = NoteDocument(blocks: [
            .text("Title"),
            block("Two months free", [NoteMark(.highlight, offset: 0, length: 3, colour: "green"),
                                      NoteMark(.highlight, offset: 4, length: 6)])
        ])
        let decoded = try roundTrip(document)
        XCTAssertEqual(decoded.blocks[1].marks, document.blocks[1].marks)
        XCTAssertEqual(NoteHighlightColour(storedKey: decoded.blocks[1].marks[0].colour), .green)
        XCTAssertEqual(NoteHighlightColour(storedKey: decoded.blocks[1].marks[1].colour), .yellow)
        XCTAssertEqual(NoteHighlightColour.grey.storedKey, "grey")
        // A key from a newer Attic shows grey but is kept as it was.
        XCTAssertEqual(NoteHighlightColour(storedKey: "teal"), .grey)
        let unknown = NoteDocument(blocks: [.text("T"), block("abc", [NoteMark(.highlight, offset: 0, length: 3, colour: "teal")])])
        XCTAssertEqual(try roundTrip(unknown).blocks[1].marks[0].colour, "teal")
        // Only a highlight carries a colour.
        let wrong = NoteDocument(blocks: [.text("T"), block("abc", [NoteMark(.bold, offset: 0, length: 3, colour: "green")])])
        XCTAssertThrowsError(try NoteContentCodec.encode(wrong))
    }

    /// The chevron's colours: a colour replaces any other highlight on the
    /// selection in one undo step, the default click still toggles, None takes
    /// the highlight away, and the editor reads the colour back.
    func testTheHighlighterAppliesAColourAndNoneRemovesIt() throws {
        let (engine, textView) = engine(NoteDocument(blocks: [.text("Pricing"), .text("Lead with the free tier")]))
        let words = range("free tier", textView)
        XCTAssertTrue(engine.setHighlight(.yellow, selection: words))
        XCTAssertEqual(engine.highlightColour(selection: words), .yellow)
        XCTAssertEqual(engine.document().blocks[1].marks, [NoteMark(.highlight, offset: 14, length: 9, colour: "yellow")])
        XCTAssertTrue(engine.setHighlight(.blue, selection: words))
        XCTAssertEqual(engine.highlightColour(selection: words), .blue, "a colour replaces the other")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.highlightColour(selection: words), .yellow, "one undo step each")
        XCTAssertTrue(engine.setHighlight(nil, selection: words))
        XCTAssertNil(engine.highlightColour(selection: words))
        XCTAssertTrue(engine.document().blocks[1].marks.isEmpty)
        // The one click is the yellow highlight (T-10, owner 2026-10-15),
        // stored without a key (owner 2026-10-16), toggling as before.
        XCTAssertTrue(engine.perform(.mark(.highlight), selection: words))
        XCTAssertEqual(engine.highlightColour(selection: words), .yellow)
        XCTAssertNil(engine.document().blocks[1].marks.first?.colour)
        // Mixed colours read as none.
        XCTAssertTrue(engine.setHighlight(.pink, selection: range("free", textView)))
        XCTAssertNil(engine.highlightColour(selection: words))
    }

    /// Colour set 1 keeps the body text at 4.5 : 1 over every highlight
    /// colour, on every surface and palette, in Light and Dark.
    func testBodyTextKeepsItsFloorOverEveryHighlightColour() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for palette in AtticPanelTheme.allCases {
                for surface in PanelSurfaceStyle.allCases {
                    for increaseContrast in [false, true] {
                        let context = AtticDesignContext(mode: mode, palette: palette, surface: surface, increaseContrast: increaseContrast)
                        let tokens = context.tokens
                        // Solid over every desktop; Glass and Frosted over the
                        // mid-grey desktop, as the colours of meaning are judged
                        // (over black or white the translucency exception holds).
                        let desktops: [AtticSurfaceModel.Desktop] = surface == .solid ? AtticSurfaceModel.Desktop.allCases : [.midGrey]
                        let surfaces = [AtticSurfaceModel.contentTop, 1].flatMap { y in
                            desktops.map { tokens.panel.composite($0, at: y) }
                        }
                        for colour in NoteHighlightColour.allCases {
                            let worst = surfaces.map { tokens.ink(.heading).contrast(on: tokens.highlightMarker(colour).over($0)) }.min() ?? 0
                            XCTAssertGreaterThanOrEqual(worst, 4.5, "\(context.caption) \(colour): \(worst)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - N-4: the dropdown card

    /// The tick is after the item: a ticked row's tick column comes after
    /// its name, and a tag row has its colour dot before it.
    func testTheTagPickersRowsHaveTheirDotFirstAndTheirTickLast() {
        let m = AtticDropdownMetrics.self
        // Dropdown content: answers (owner, 2026-10-24), sheet 3: the card
        // is fixed at 224 pt; a long name is cut short, never widening it.
        XCTAssertEqual(AtticTagPicker.rowsWidth(tags: ["launch"], create: nil), m.fieldCardWidth - m.inset * 2)
        XCTAssertEqual(AtticTagPicker.rowsWidth(tags: ["launch-october-planning-and-the-rest"], create: nil),
                       m.fieldCardWidth - m.inset * 2)
        XCTAssertEqual(m.dotSize, 8, "draft C's 8 pt dot")
    }

    /// Native menus of choices draw their tick after the item and no
    /// leading tick column; the item keeps its state and its plain title
    /// for VoiceOver. A menu with no choice is untouched.
    func testNativeChoiceMenusTickAfterTheItem() throws {
        let menu = AtticNativeMenu.make([
            AtticMenuCommand(verbatim: "Manual Order", state: .on) {},
            AtticMenuCommand(verbatim: "Due Date", state: .off) {}
        ])
        XCTAssertFalse(menu.showsStateColumn)
        let ticked = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(ticked.state, .on)
        XCTAssertNil(ticked.onStateImage)
        XCTAssertTrue(ticked.attributedTitle?.string.hasSuffix("\t\u{2713}") == true)
        XCTAssertEqual(ticked.accessibilityTitle(), "Manual Order")
        XCTAssertNil(menu.items[1].attributedTitle, "an unticked choice is its plain title")
        let plain = AtticNativeMenu.make([AtticMenuCommand(verbatim: "Rename") {}])
        XCTAssertTrue(plain.showsStateColumn)
    }

    /// N-4 B (the mask reveal) was the owner's experiment; O14-02 (owner
    /// 2026-10-14) replaced it with the unfold, tested in
    /// `AtticDropdownTests.testR13TheUnfold…`. What stays: the motion opens
    /// from the anchor's edge, and Reduced is a fade.
    func testTheDropdownRevealOpensFromTheAnchorsEdge() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 300)
        XCTAssertEqual(AtticUnfoldShape(cornerRadius: 16, reveal: 0, fromTop: true).path(in: rect).boundingRect.minY, 0, accuracy: 0.01)
        XCTAssertEqual(AtticUnfoldShape(cornerRadius: 16, reveal: 0, fromTop: false).path(in: rect).boundingRect.maxY, 300, accuracy: 0.01)
        XCTAssertEqual(AtticDropdownReveal.revealAnimation, AtticDropdownReveal.openAnimation)
    }

    // N-6 D (content fades before the controls) was replaced by the
    // floating controls with the variable blur (owner, 2026-10-14; top
    // only since 2026-10-22): `FloatingControlsTests`.

    // MARK: - N-5: the active cell

    func testTheActiveCellIsASoftFill() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            let fill = AtticDesignContext(mode: mode).tokens.tableActiveFill
            XCTAssertLessThan(fill.alpha, 0.07, "soft")
            XCTAssertGreaterThan(fill.alpha, 0)
        }
    }

    // MARK: - Design review

    /// D-13 put a two-line row's title where a one-line row's is (8 in
    /// both). Spacing B (owner, 2026-10-20) supersedes it: the one-line
    /// title is centred in its 32 pt row (7) and the two-line block moves
    /// up, 3 into its 44 pt pill (5 in the row), 2 above the one-line one.
    func testATwoLineRowsTitleSitsWhereAOneLineRowsDoes() {
        XCTAssertEqual(AtticTaskRowMetrics.titleTop(twoLine: true), AtticTaskRowMetrics.titleTop(twoLine: false) - 2)
        XCTAssertEqual(AtticTaskRowMetrics.titleTop(twoLine: false), 7)
    }

    /// D-06: with text selected, Aa's row holds the marks in place of the
    /// lists and indents; the bar stays away.
    func testTheFormatRowTakesTheMarksWhileTextIsSelected() {
        XCTAssertEqual(NoteFormatRowItem.items(inTable: false, textSelected: true),
                       [.command(.mark(.bold)), .command(.mark(.italic)), .command(.mark(.underline)),
                        .command(.mark(.strikethrough)), .command(.mark(.link)), .command(.mark(.highlight)),
                        .command(.mark(.code)), .close])
        var selected = NoteFormatSnapshot.empty
        selected.hasTextSelection = true
        selected.paragraph = .heading(3)
        XCTAssertLessThanOrEqual(NoteFormatRowView.minimumWidth(snapshot: selected, toggleWidth: AtticNoteFormatMetrics.rowToggleWidth),
                                 288, "the marks row fits a 320 pt panel with 28 pt cells")
    }

    /// Aa waits for text under the title (owner, 2026-10-11).
    func testAaWaitsForTextUnderTheTitle() {
        func has(_ string: String) -> Bool {
            let text = string as NSString
            return NoteTitleAccessories.hasBody(text, title: text.lineRange(for: NSRange(location: 0, length: 0)))
        }
        XCTAssertFalse(has("Pricing"))
        XCTAssertFalse(has("Pricing\n"))
        XCTAssertFalse(has("Pricing\n \n\t"))
        XCTAssertTrue(has("Pricing\nLead"))
        XCTAssertTrue(has("Pricing\n\u{FFFC}"), "an image or a table counts")
    }

    /// D-02: Glass and Frosted's secondary text is a real step under the
    /// primary, and keeps its floor over every desktop.
    func testGlassSecondaryTextIsARealStepAndKeepsItsFloor() {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            for surface in [PanelSurfaceStyle.glass, .frosted] {
                for increaseContrast in [false, true] {
                    let context = AtticDesignContext(mode: mode, surface: surface, increaseContrast: increaseContrast)
                    let tokens = context.tokens
                    let backgrounds = [AtticSurfaceModel.contentTop, 1].flatMap { y in
                        AtticSurfaceModel.Desktop.allCases.map { tokens.panel.composite($0, at: y) }
                    }
                    let helper = tokens.ink(.helper)
                    let worst = backgrounds.map { helper.contrast(on: $0) }.min() ?? 0
                    XCTAssertGreaterThanOrEqual(worst, increaseContrast ? 4.5 : 3, "\(context.caption): \(worst)")
                    if !increaseContrast {
                        // As far as the floors allow over every desktop and a
                        // window the glass passes through (Light: about #333
                        // under #141414).
                        XCTAssertGreaterThan(helper.contrast(on: tokens.ink(.heading)), 1.4, "\(context.caption): a real step")
                    }
                }
            }
        }
    }
}
