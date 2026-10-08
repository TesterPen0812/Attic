import AppKit
import XCTest
@testable import Attic

/// Notes v2, round 2: tables (spec § 4), in the real TextKit 2 editor.
///
/// The prototype's six risks first: the caret between text and cells,
/// input methods and Writing Tools in a cell, VoiceOver, Undo, save and
/// export, and a keystroke's cost in a long note. Then the feature.
@MainActor
final class NotesV2TablesTests: XCTestCase {
    private typealias M = AtticNoteTableMetrics
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    // MARK: Harness

    /// An editor in the draft's 264 pt column (a 320 pt panel, 28 in).
    private func makeEngine(_ blocks: [NoteBlock], height: CGFloat = 520) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        textView.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        window.makeFirstResponder(textView)
        settle(engine, textView)
        return (engine, textView)
    }

    private func settle(_ engine: NoteEditorEngine, _ textView: NoteEditorTextView) {
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        textView.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        spin()
        textView.layoutSubtreeIfNeeded()
    }

    private func spin(_ seconds: TimeInterval = 0.03) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var pillars: NoteTable {
        NoteTable(texts: [["Pillar", "What happened"],
                          ["Confidentiality", "Data taken from the IT network"],
                          ["Integrity", "Systems encrypted by ransomware"],
                          ["Availability", "Pipeline shut down"]])
    }

    private func ciaBlocks(_ table: NoteTable? = nil) -> [NoteBlock] {
        var heading = NoteBlock.text("Colonial Pipeline ransomware attack")
        heading.style = "heading"
        heading.level = 1
        var sources = NoteBlock.text("Sources:")
        sources.style = "heading"
        sources.level = 3
        return [.text("CIA impact"), heading,
                .text("The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication"),
                .table(table ?? pillars), sources, .text("After the table")]
    }

    private func tableAttachment(_ engine: NoteEditorEngine) throws -> NoteTableAttachment {
        try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
    }

    private func tableView(_ engine: NoteEditorEngine) throws -> NoteTableView {
        let attachment = try tableAttachment(engine)
        return try XCTUnwrap(attachment.hostedView, "TextKit hosted the table's view")
    }

    private func location(of text: String, in engine: NoteEditorEngine) -> Int {
        (engine.textStorage.string as NSString).range(of: text).location
    }

    private func type(_ text: String, into editor: NSTextView) {
        for character in text {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    // MARK: 1 · The table in the text (hosting and look)

    func testTheTableIsHostedAtTheColumnsWidthAndItsLineIsExactlyTheGrid() throws {
        let (engine, textView) = makeEngine(ciaBlocks())
        let view = try tableView(engine)
        XCTAssertNotNil(view.window, "the view is in the note's window")
        XCTAssertEqual(view.frame.width, 264, accuracy: 0.5, "the table spans the text column")
        // Rows: one 21 pt line and 4 + 4 padding = 29; the wrapped cells take two lines.
        XCTAssertEqual(view.grid.rowHeights.first ?? 0, 29, accuracy: 0.01)
        XCTAssertEqual(view.grid.width, 264, accuracy: 0.01, "a narrow table stretches to fill the column")
        XCTAssertEqual(view.frame.height, view.grid.height, accuracy: 0.5)
        // The table's line: 8 above it, nothing but the grid in its line box.
        let range = try XCTUnwrap(engine.range(ofTable: try tableAttachment(engine)))
        var fragments: [NSTextLayoutFragment] = []
        engine.layoutManager?.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location, options: [.ensuresLayout]) {
            fragments.append($0)
            return true
        }
        let tableFragment = try XCTUnwrap(fragments.first { fragment in
            engine.contentStorage.offset(from: engine.contentStorage.documentRange.location, to: fragment.rangeInElement.location) == range.location
        })
        let line = try XCTUnwrap(tableFragment.textLineFragments.first)
        XCTAssertEqual(line.typographicBounds.height, view.grid.height, accuracy: 0.5, "the line box is the grid")
        // 8 above the table, from the paragraph's line box as the draft (CSS) sets it.
        XCTAssertEqual(line.typographicBounds.minY, AtticNoteType.blockMargin + NoteTextStyle.baselineShift(AtticNoteType.body),
                       accuracy: 0.5, "8 above the table")
    }

    func testColumnsSizeFromTheirContentWithinTheirLimitsAndAWideTableScrolls() {
        let wide = NoteTable(texts: [["Pillar", "What happened", "Control that failed", "Source"],
                                     ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"]])
        let attachment = NoteTableAttachment(table: wide)
        let layout = attachment.layout(width: 264)
        XCTAssertTrue(layout.scrolls)
        XCTAssertTrue(layout.columnWidths.allSatisfy { $0 >= M.minColumnWidth && $0 <= M.maxColumnWidth })
        XCTAssertEqual(layout.columnWidths[1], M.maxColumnWidth, "a long column stops at 168")
        let narrow = NoteTableAttachment(table: .blank()).layout(width: 264)
        XCTAssertEqual(narrow.columnWidths, [132, 132], "empty columns share the column")
    }

    /// The grid draws cells with AppKit's string drawing; the live editor
    /// is TextKit 2. A cell must not jump when it starts or stops being
    /// edited: the same line breaks and the same baselines.
    func testDrawnCellsAndTheCellEditorBreakAndSitTheirLinesAlike() throws {
        let (engine, _) = makeEngine(ciaBlocks())
        let view = try tableView(engine)
        let samples = ["Data taken from the IT network", "Systems encrypted by ransomware", "Pipeline shut down",
                       "A considerably longer cell that wraps over several lines in a narrow column of the table",
                       "Confidentiality", "naïve café — ünïcödé ✓ 東京 emoji 🙂 mixed", "x"]
        for header in [false, true] {
            for width in [44.0, 84.0, 120.0, 156.0, 252.0] as [CGFloat] {
                for text in samples {
                    let attributed = NSAttributedString(string: text, attributes: engine.style.tableCellAttributes(header: header))
                    // AppKit's typesetter (string drawing and measuring).
                    let storage = NSTextStorage(attributedString: attributed)
                    let manager = NSLayoutManager()
                    let container = NSTextContainer(size: CGSize(width: width, height: 10_000))
                    container.lineFragmentPadding = 0
                    manager.addTextContainer(container)
                    storage.addLayoutManager(manager)
                    manager.ensureLayout(for: container)
                    var drawn: [(NSRange, CGFloat)] = []
                    manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, glyphs, _ in
                        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                        drawn.append((characters, rect.minY + manager.location(forGlyphAt: glyphs.location).y))
                    }
                    // The cell editor (TextKit 2).
                    let editor = view.editor
                    editor.frame.size.width = width
                    editor.textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
                    editor.load(attributed, keepingSelection: false)
                    var live: [(NSRange, CGFloat)] = []
                    editor.textLayoutManager?.enumerateTextLayoutFragments(from: editor.textLayoutManager!.documentRange.location,
                                                                           options: [.ensuresLayout]) { fragment in
                        for line in fragment.textLineFragments where line.characterRange.length > 0 {
                            live.append((line.characterRange, fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y))
                        }
                        return true
                    }
                    XCTAssertEqual(drawn.map(\.0), live.map(\.0), "line breaks of “\(text)” at \(width)")
                    for (a, b) in zip(drawn, live) {
                        XCTAssertEqual(a.1, b.1, accuracy: 0.5, "baselines of “\(text)” at \(width)")
                    }
                    XCTAssertEqual(NoteTableTextCache.measure(attributed, width: width), CGFloat(max(1, live.count)) * 21,
                                   "measured height of “\(text)” at \(width)")
                }
            }
        }
    }

    // MARK: 2 · The caret between text and cells

    func testArrowsCarryTheCaretIntoTheTableAndOutAgain() throws {
        let (engine, textView) = makeEngine(ciaBlocks())
        let view = try tableView(engine)
        let window = try XCTUnwrap(textView.window)
        // ↓ from the paragraph's last line: the first row, the column under the caret.
        textView.setSelectedRange(NSRange(location: location(of: "authentication", in: engine) + 3, length: 0))
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        settle(engine, textView)
        XCTAssertTrue(window.firstResponder === view.editor, "the cell editor has the keyboard")
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 0, column: 0))
        // ↓ moves down through the rows and out under the table.
        for row in 1...3 {
            view.editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            XCTAssertEqual(view.activeCell?.row, row)
        }
        view.editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        settle(engine, textView)
        XCTAssertTrue(window.firstResponder === textView, "↓ on the last row leaves the table")
        XCTAssertEqual(engine.lineText(at: textView.selectedRange().location), "Sources:")
        XCTAssertNil(view.activeCell)
        // ↑ from below: the last row.
        textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        settle(engine, textView)
        XCTAssertTrue(window.firstResponder === view.editor)
        XCTAssertEqual(view.activeCell?.row, 3)
        // ← at a cell's start crosses to the previous cell's end; → back.
        view.activate(NoteTable.Position(row: 1, column: 1), caret: .start)
        view.editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 1, column: 0))
        XCTAssertEqual(view.editor.selectedRange(), NSRange(location: ("Confidentiality" as NSString).length, length: 0))
        view.editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 1, column: 1))
        XCTAssertEqual(view.editor.selectedRange().location, 0)
        // → at the very last cell's end leaves the table to the paragraph after it.
        view.activate(NoteTable.Position(row: 3, column: 1), caret: .end)
        view.editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        settle(engine, textView)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange().location, location(of: "Sources:", in: engine))
        // ← from the next paragraph's start enters the last cell at its end.
        textView.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        settle(engine, textView)
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 3, column: 1))
        XCTAssertEqual(view.editor.selectedRange().location, ("Pipeline shut down" as NSString).length)
        // ↑ on the first row leaves above the table.
        view.activate(NoteTable.Position(row: 0, column: 0), caret: .start)
        view.editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        settle(engine, textView)
        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertTrue(engine.lineText(at: textView.selectedRange().location).hasPrefix("The attackers"))
    }

    func testTabReturnAndOptionReturnInCells() throws {
        let (engine, textView) = makeEngine(ciaBlocks(.blank()))
        let attachment = try tableAttachment(engine)
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 0, column: 0), caret: .start)
        type("Pillar", into: view.editor)
        view.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 0, column: 1))
        type("What", into: view.editor)
        view.editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 0, column: 0))
        // Tab in the last cell adds a row.
        view.activate(NoteTable.Position(row: 2, column: 1), caret: .end)
        view.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(attachment.table.rowCount, 4)
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 3, column: 0))
        // Return: the cell below; on the last row it adds one.
        view.activate(NoteTable.Position(row: 1, column: 1), caret: .end)
        view.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 2, column: 1))
        view.activate(NoteTable.Position(row: 3, column: 1), caret: .end)
        type("x", into: view.editor)
        view.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(attachment.table.rowCount, 5)
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 4, column: 1))
        // Return in an empty new last row removes it and leaves the table.
        view.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        settle(engine, textView)
        XCTAssertEqual(attachment.table.rowCount, 4)
        XCTAssertTrue(textView.window?.firstResponder === textView)
        // ⌥Return: a line break inside the cell, stored as "\n".
        view.activate(NoteTable.Position(row: 1, column: 0), caret: .end)
        type("one", into: view.editor)
        view.editor.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        type("two", into: view.editor)
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 0)].text, "one\ntwo")
        XCTAssertEqual(view.grid.rowHeights[1], 2 * 21 + 8, accuracy: 0.01, "the row grows with its cell")
    }

    func testShiftArrowsPastACellsEdgeSelectCellsAndEscSelectsTheCellThenTheTable() throws {
        let (engine, textView) = makeEngine(ciaBlocks())
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 1, column: 0), caret: .end)
        view.editor.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
        XCTAssertEqual(view.cellSelection, NoteTableCellRange(anchor: NoteTable.Position(row: 1, column: 0),
                                                              head: NoteTable.Position(row: 1, column: 1)))
        XCTAssertTrue(textView.window?.firstResponder === view.canvas)
        view.canvas.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        XCTAssertEqual(view.cellSelection?.positions.count, 4)
        // Delete clears the cells and keeps the grid (one Undo step).
        view.canvas.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        let attachment = try tableAttachment(engine)
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 2, column: 1)].text, "")
        XCTAssertEqual(attachment.table.rowCount, 4)
        engine.history.undo()
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 2, column: 1)].text, "Systems encrypted by ransomware")
        // Esc in a cell: the cell; Esc again: the whole table, in the text.
        view.activate(NoteTable.Position(row: 0, column: 1), caret: .end)
        view.editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(view.cellSelection?.positions, [NoteTable.Position(row: 0, column: 1)])
        view.canvas.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(textView.window?.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange(), engine.range(ofTable: attachment))
    }

    func testAnEditAboveTheTableKeepsTheKeyboardInTheCell() throws {
        let (engine, textView) = makeEngine(ciaBlocks())
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 2, column: 1), caret: .end)
        // An edit before the table (TextKit lays its line out again and may host the view anew).
        engine.performEdit(NSRange(location: location(of: "The attackers", in: engine), length: 0),
                           with: NSAttributedString(string: "Note: ", attributes: engine.style.bodyAttributes), name: "Typing")
        settle(engine, textView)
        spin(0.1)
        let current = try tableView(engine)
        XCTAssertTrue(current === view, "the same view is hosted again")
        XCTAssertTrue(textView.window?.firstResponder === current.editor, "the cell keeps the keyboard")
        XCTAssertEqual(current.activeCell, NoteTable.Position(row: 2, column: 1))
    }

    // MARK: 3 · Input methods and Writing Tools in a cell

    func testAnInputMethodComposesInACellAndCommitsAsOneStep() throws {
        let (engine, _) = makeEngine(ciaBlocks(.blank()))
        let attachment = try tableAttachment(engine)
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 1, column: 0), caret: .start)
        let editor = view.editor
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 0)].text, "", "the model waits for the commit")
        editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 0)].text, "日本")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 0)].text, "", "one Undo takes the composition back")
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 1, column: 0))
    }

    func testCellsOfferWritingToolsAndARewriteIsOneUndoableChange() throws {
        let (engine, _) = makeEngine(ciaBlocks())
        let attachment = try tableAttachment(engine)
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 2, column: 1), caret: .all)
        let editor = view.editor
        XCTAssertEqual(editor.writingToolsBehavior, .complete, "Writing Tools work inline in a cell (TextKit 2)")
        XCTAssertNotNil(editor.textLayoutManager, "the cell editor is TextKit 2")
        // A Writing Tools session: the note's safety copy first, then the rewrite.
        editor.delegate?.textViewWritingToolsWillBegin?(editor)
        XCTAssertEqual(engine.activity, .writingToolsSafe)
        editor.insertText("Ransomware encrypted the systems", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.delegate?.textViewWritingToolsDidEnd?(editor)
        XCTAssertEqual(engine.activity, .idle)
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 2, column: 1)].text, "Ransomware encrypted the systems")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 2, column: 1)].text, "Systems encrypted by ransomware")
    }

    // MARK: 4 · VoiceOver

    func testVoiceOverReadsATableWithRowsColumnsAndHeaders() throws {
        let (engine, textView) = makeEngine(ciaBlocks())
        let view = try tableView(engine)
        XCTAssertEqual(view.accessibilityRole(), .table)
        XCTAssertEqual(view.accessibilityLabel(), "Table, 2 columns, 4 rows")
        XCTAssertEqual(view.accessibilityRowCount(), 4)
        XCTAssertEqual(view.accessibilityColumnCount(), 2)
        XCTAssertEqual(view.accessibilityRows()?.count, 4)
        XCTAssertEqual(view.accessibilityColumns()?.count, 2)
        let headers = try XCTUnwrap(view.accessibilityColumnHeaderUIElements() as? [NoteTableAXCell])
        XCTAssertEqual(headers.map { $0.accessibilityValue() as? String }, ["Pillar", "What happened"])
        let cell = try XCTUnwrap(view.accessibilityCell(forColumn: 1, row: 2) as? NoteTableAXCell)
        XCTAssertEqual(cell.accessibilityRole(), .cell)
        XCTAssertEqual(cell.accessibilityRowIndexRange(), NSRange(location: 2, length: 1))
        XCTAssertEqual(cell.accessibilityColumnIndexRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(cell.accessibilityValue() as? String, "Systems encrypted by ransomware")
        XCTAssertNotEqual(cell.accessibilityFrame(), .zero)
        // The grips' and chips' actions are named actions on each cell.
        let actions = cell.accessibilityCustomActions()?.map(\.name) ?? []
        XCTAssertTrue(actions.contains("Add Row Below"))
        XCTAssertTrue(actions.contains("Delete Column"))
        // The table is one of the note's children, and a target of its Tables rotor.
        XCTAssertTrue(textView.accessibilityChildren()?.contains { ($0 as AnyObject) === view } == true)
        let rotor = try XCTUnwrap(textView.accessibilityCustomRotors().first { $0.type == .table })
        let found = rotor.itemSearchDelegate?.rotor(rotor, resultFor: NSAccessibilityCustomRotor.SearchParameters())
        XCTAssertTrue(found?.targetElement as AnyObject === view)
        // Editing a cell: the cell holds the live text editor.
        view.activate(NoteTable.Position(row: 2, column: 1), caret: .end)
        XCTAssertTrue(cell.accessibilityChildren()?.first as AnyObject === view.editor)
        XCTAssertTrue(view.editor.accessibilityParent() as AnyObject === view.axCell(NoteTable.Position(row: 2, column: 1)))
        XCTAssertTrue(cell.accessibilityPerformPress())
    }

    // MARK: 5 · Undo

    func testTypingInACellCoalescesAndUndoRestoresTheCellAndTheCaret() throws {
        let (engine, textView) = makeEngine(ciaBlocks(.blank()))
        let attachment = try tableAttachment(engine)
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 1, column: 0), caret: .start)
        type("Integrity", into: view.editor)
        let undoCount = engine.history.undoOps.count
        view.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        type("Systems", into: view.editor)
        XCTAssertEqual(engine.history.undoOps.count, undoCount + 1, "each cell's typing is one step")
        // A structure change between.
        XCTAssertTrue(engine.addColumn(to: attachment, at: 2, focusingRow: 1))
        XCTAssertEqual(attachment.table.columnCount, 3)
        // Text typed in the note after the table.
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Undo walks back through all of them, in order.
        XCTAssertTrue(engine.history.undo())
        XCTAssertFalse(engine.textStorage.string.hasSuffix("!"))
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(attachment.table.columnCount, 2)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 1)].text, "")
        XCTAssertEqual(view.activeCell, NoteTable.Position(row: 1, column: 1), "the keyboard returns to the cell")
        XCTAssertTrue(textView.window?.firstResponder === view.editor)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 0)].text, "")
        // Redo all.
        while engine.history.redo() {}
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 0)].text, "Integrity")
        XCTAssertEqual(attachment.table[NoteTable.Position(row: 1, column: 1)].text, "Systems")
        XCTAssertEqual(attachment.table.columnCount, 3)
        XCTAssertTrue(engine.textStorage.string.hasSuffix("!"))
    }

    func testDeletingAndRestoringAWholeTableKeepsItsLatestGrid() throws {
        let (engine, textView) = makeEngine(ciaBlocks())
        let attachment = try tableAttachment(engine)
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 3, column: 1), caret: .end)
        type(" fast", into: view.editor)
        XCTAssertTrue(engine.deleteTable(attachment))
        settle(engine, textView)
        XCTAssertNil(engine.range(ofTable: attachment))
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
        XCTAssertTrue(engine.history.undo())
        settle(engine, textView)
        let restored = try tableAttachment(engine)
        XCTAssertEqual(restored.table[NoteTable.Position(row: 3, column: 1)].text, "Pipeline shut down fast")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(restored.table[NoteTable.Position(row: 3, column: 1)].text, "Pipeline shut down")
    }

    // MARK: 6 · Save, reopen, export

    func testATableSavesReopensAndExportsAsMarkdown() throws {
        let (engine, _) = makeEngine(ciaBlocks())
        let view = try tableView(engine)
        view.activate(NoteTable.Position(row: 1, column: 1), caret: .all)
        engine.applyCellMark(.bold, in: view)
        let document = engine.document()
        XCTAssertTrue(document.requires.contains("table-v1"))
        let data = try NoteContentCodec.encode(document)
        guard case let .editable(decoded) = NoteContentCodec.decode(data) else { return XCTFail("the note reads back") }
        XCTAssertEqual(decoded, document)
        let table = try XCTUnwrap(decoded.blocks.first { $0.kind == .table }?.table)
        XCTAssertEqual(table.texts, pillars.texts)
        XCTAssertEqual(table[NoteTable.Position(row: 1, column: 1)].marks, [NoteMark(.bold, offset: 0, length: 30)])
        // Reopened in a new editor, the same grid.
        let (reopened, _) = makeEngine(decoded.blocks)
        XCTAssertEqual(reopened.document().blocks.first { $0.kind == .table }?.table, table)
        // Markdown: a GFM pipe table.
        let markdown = NoteMarkdownExport.markdown(decoded)
        XCTAssertTrue(markdown.contains("""
        | Pillar | What happened |
        | --- | --- |
        | Confidentiality | **Data taken from the IT network** |
        """), markdown)
        XCTAssertTrue(NoteTextExport.plainText(decoded).contains("Integrity\tSystems encrypted by ransomware"))
    }

    // MARK: 7 · A keystroke's cost

    func testTypingInACellOfALongNoteCostsWhatTypingInItsTextDoes() throws {
        var blocks: [NoteBlock] = [.text("Stress")]
        let big = NoteTable(texts: (0..<10).map { row in (0..<20).map { "r\(row)c\($0)" } })
        for index in 0..<5_000 {
            blocks.append(.text("Line \(index) with some ordinary words to wrap a little in a narrow panel."))
            if index == 2_500 { blocks.append(.table(big)) }
        }
        let (engine, textView) = makeEngine(blocks)
        let attachment = try tableAttachment(engine)
        let range = try XCTUnwrap(engine.range(ofTable: attachment))
        textView.scrollRangeToVisible(range)
        settle(engine, textView)
        let view = try tableView(engine)
        func measure(_ body: () -> Void) -> [Double] {
            var samples: [Double] = []
            for _ in 0..<40 {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
                textView.displayIfNeeded()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return samples.sorted()
        }
        view.activate(NoteTable.Position(row: 5, column: 3), caret: .end)
        let cell = measure { view.editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location(of: "Line 2501 ", in: engine), length: 0))
        let text = measure { textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let cellMedian = cell[cell.count / 2], textMedian = text[text.count / 2]
        let report = String(format: "TABLE-PERF cell keystroke median %.2f ms p90 %.2f; note text median %.2f ms p90 %.2f",
                            cellMedian, cell[cell.count * 9 / 10], textMedian, text[text.count * 9 / 10])
        print(report)
        XCTContext.runActivity(named: report) { _ in }
        XCTAssertLessThan(cellMedian, max(4, textMedian * 2), "a cell keystroke stays in the note's budget")
    }

    /// Opening a long note: a 20 × 10 table on screen against the same note
    /// without it (cold engine, view, layout and first display).
    func testOpeningALongNoteWithATwentyByTenTableOnScreen() throws {
        func note(withTable: Bool) -> [NoteBlock] {
            var blocks: [NoteBlock] = [.text("Heavy")]
            for index in 0..<400 {
                blocks.append(.text("Line \(index) with some ordinary words to wrap a little in a narrow panel."))
                if withTable, index == 2 {
                    blocks.append(.table(NoteTable(texts: (0..<20).map { row in (0..<10).map { "r\(row) c\($0)" } })))
                }
            }
            return blocks
        }
        func open(_ blocks: [NoteBlock]) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let (engine, textView) = makeEngine(blocks)
            textView.displayIfNeeded()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if blocks.contains(where: { $0.kind == .table }) {
                XCTAssertNotNil(engine.tableViews().first?.window, "the table is on screen")
            }
            windows.forEach { $0.close() }
            windows.removeAll()
            return elapsed
        }
        _ = open(note(withTable: true))
        var plain: [Double] = [], table: [Double] = []
        for _ in 0..<5 {
            plain.append(open(note(withTable: false)))
            table.append(open(note(withTable: true)))
        }
        plain.sort()
        table.sort()
        let report = String(format: "TABLE-OPEN long note median %.1f ms, with a 20 x 10 table on screen %.1f ms", plain[2], table[2])
        print(report)
        XCTContext.runActivity(named: report) { _ in }
    }

    /// Sideways scrolling over a wide table moves the table; scrolling up
    /// and down over it moves the note.
    func testScrollingOverAWideTableGoesSidewaysToItAndUpAndDownToTheNote() throws {
        let wide = NoteTable(texts: [["Pillar", "What happened", "Control that failed", "Source"],
                                     ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"]])
        var blocks = ciaBlocks(wide)
        for index in 0..<40 { blocks.append(.text("Filler line \(index) to give the note something to scroll.")) }
        let (engine, textView) = makeEngine(blocks, height: 300)
        let view = try tableView(engine)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        func scroll(dx: Int32, dy: Int32) throws {
            let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            view.scrollWheel(with: event)
            spin(0.05)
        }
        let noteBefore = scrollView.contentView.bounds.minY
        // A gesture is many events; AppKit settles the first.
        for _ in 0..<2 { try scroll(dx: -30, dy: 0) }

        XCTAssertEqual(view.scrollOffset, 60, accuracy: 0.5, "sideways: the table")
        for _ in 0..<40 { try scroll(dx: -30, dy: 0) }
        XCTAssertEqual(view.scrollOffset, view.maxScrollOffset, accuracy: 0.5, "until its end, and no further")
        XCTAssertEqual(scrollView.contentView.bounds.minY, noteBefore, accuracy: 0.5)
        let tableOffset = view.scrollOffset
        for _ in 0..<3 { try scroll(dx: 0, dy: -40) }
        XCTAssertEqual(view.scrollOffset, tableOffset, accuracy: 0.5)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, noteBefore, "up and down: the note")
    }
}
