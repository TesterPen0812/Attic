import AppKit
import XCTest
@testable import Attic

/// Notes v2 tables, the feature (spec § 4.1–4.7): the model and its
/// formats, inserting, the Aa row's table mode, editing and structure,
/// keys, paste and copy, marks, agents, print and the look's tokens.
@MainActor
final class NotesV2TablesFeatureTests: XCTestCase {
    private typealias P = NoteTable.Position
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    // MARK: Harness

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
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        textView.layoutSubtreeIfNeeded()
    }

    private var pillars: NoteTable {
        NoteTable(texts: [["Pillar", "What happened"], ["Confidentiality", "Data taken from the IT network"],
                          ["Integrity", "Systems encrypted by ransomware"], ["Availability", "Pipeline shut down"]])
    }

    private func blocks(_ table: NoteTable? = nil) -> [NoteBlock] {
        [.text("CIA impact"), .text("Before the table"), .table(table ?? pillars), .text("After the table")]
    }

    private func table(_ engine: NoteEditorEngine) throws -> NoteTableAttachment {
        try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
    }

    private func view(_ engine: NoteEditorEngine) throws -> NoteTableView {
        try XCTUnwrap(try table(engine).hostedView)
    }

    private func type(_ text: String, into editor: NSTextView) {
        for character in text {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// V-05 (recording 1937): dragging a column by its grip lifts it onto
    /// a card that follows the pointer while the other columns slide apart
    /// to open its landing gap; the release settles it there and makes the
    /// move (one Undo step); the live table shows again.
    func testV05AColumnDragLiftsItOpensItsGapAndLandsThere() throws {
        let wide = NoteTable(texts: [["A", "B", "C", "D"], ["1", "2", "3", "4"]])
        let (engine, textView) = makeEngine(blocks(wide))
        let view = try view(engine)
        view.activate(P(row: 1, column: 3), caret: .end)
        settle(engine, textView)
        let widths = view.grid.columnWidths
        let reorder = try XCTUnwrap(NoteTableReorder(table: view, textView: textView, axis: .column, source: 3,
                                                     tokens: AtticColorTokens.resolve(.default), animated: false, below: nil))
        XCTAssertEqual(view.canvas.alphaValue, 0, "the strips stand in for the cells while dragging")
        let card = try XCTUnwrap(textView.subviews.compactMap { $0 as? NoteDragLiftView }.first, "the lifted column")
        XCTAssertNotNil(card.layer?.backgroundColor, "the card has a backing")
        // From the grip over column 3 to over column 0.
        let canvas = view.canvas
        let start = CGPoint(x: widths.prefix(3).reduce(0, +) + widths[3] / 2, y: 10)
        reorder.update(windowPoint: canvas.convert(start, to: nil))
        XCTAssertEqual(reorder.target, 3)
        reorder.update(windowPoint: canvas.convert(CGPoint(x: widths[0] / 2, y: 10), to: nil))
        XCTAssertEqual(reorder.target, 0, "over the first column: it lands first")
        let starts = NoteTableReorder.starts(sizes: widths, source: 3, target: 0)
        XCTAssertEqual(starts[3], 0)
        XCTAssertEqual(starts[0], widths[3], "column A slid over to open the gap")
        var landed: Int?
        reorder.finish { target in
            landed = target
            _ = engine.moveColumn(of: view.attachment!, from: 3, to: target)
        }
        XCTAssertEqual(landed, 0)
        XCTAssertEqual(view.canvas.alphaValue, 1, "the live table is back")
        XCTAssertTrue(textView.subviews.allSatisfy { !($0 is NoteDragLiftView) }, "the card is gone")
        XCTAssertEqual(try table(engine).table.columns.count, 4)
        XCTAssertEqual(view.cellString(P(row: 0, column: 0)).string, "D", "D moved first")
        XCTAssertTrue(engine.undoCommand())
        XCTAssertEqual(view.cellString(P(row: 0, column: 0)).string, "A", "one Undo step")
    }

    /// V-05: rows reorder the same way. A strip before the card gives way
    /// once the card's leading edge passes its middle, one after it once the
    /// trailing edge does; at rest the card is in its own slot.
    func testV05TheLandingSlotFollowsTheCardsMiddle() {
        let sizes: [CGFloat] = [40, 30, 50, 20]
        XCTAssertEqual(NoteTableReorder.target(sizes: sizes, source: 1, start: 40), 1, "at rest")
        XCTAssertEqual(NoteTableReorder.target(sizes: sizes, source: 1, start: 25), 1, "its top not yet past A's middle")
        XCTAssertEqual(NoteTableReorder.target(sizes: sizes, source: 1, start: 19), 0, "its top past A's middle")
        XCTAssertEqual(NoteTableReorder.target(sizes: sizes, source: 1, start: 64), 1, "its end not yet past C's middle")
        XCTAssertEqual(NoteTableReorder.target(sizes: sizes, source: 1, start: 66), 2, "its end past C's middle")
        XCTAssertEqual(NoteTableReorder.target(sizes: sizes, source: 1, start: 200), 3)
        XCTAssertEqual(NoteTableReorder.starts(sizes: sizes, source: 1, target: 3), [0: 0, 2: 40, 3: 90, 1: 110])
        // F5a (Air): pushed against the top, a row taller than the header
        // lands first; pushed against the end, a wide column lands last.
        XCTAssertEqual(NoteTableReorder.target(sizes: [30, 31, 31, 31], source: 3, start: 0), 0)
        XCTAssertEqual(NoteTableReorder.target(sizes: [30, 80, 20], source: 1, start: 50), 2)
    }

    /// O4-04 (Air, 2/2): switching Light to Dark while Note options' menu
    /// was open left the note's text almost black on the dark panel until
    /// the menu closed: the design reached the editor only through the
    /// page's SwiftUI `onChange`, which waits for the menu. The text and
    /// the table's cells now follow the window's appearance at once, in
    /// the menu's tracking mode, with no SwiftUI update at all.
    func testO4_04TheNoteFollowsTheWindowsAppearanceWhileAMenuTracks() throws {
        let (engine, textView) = makeEngine(blocks())
        let window = try XCTUnwrap(textView.window)
        window.appearance = NSAppearance(named: .aqua)
        RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.style.design.mode, .light)
        func titleLuminance() -> CGFloat {
            let ink = engine.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            var white: CGFloat = 0
            textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                white = ink?.usingColorSpace(.genericGray)?.whiteComponent ?? 0
            }
            return white
        }
        XCTAssertLessThan(titleLuminance(), 0.4, "Light: dark ink")
        window.appearance = NSAppearance(named: .darkAqua)
        // A native menu's tracking loop runs the run loop in this mode only.
        RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        XCTAssertEqual(engine.style.design.mode, .dark, "the editor follows the window behind the menu")
        XCTAssertGreaterThan(titleLuminance(), 0.6, "Dark: the existing title is light ink")
        XCTAssertEqual(engine.objectDesign.mode, .dark, "the table's cells are drawn in Dark too")
    }

    /// F6 (decided 10-18): the lifted row or column follows the pointer
    /// along its axis, not its landing slot, held inside the table, while
    /// the others open the gap where it will land.
    func testF6TheLiftedRowOrColumnFollowsThePointerInsideTheTable() throws {
        let wide = NoteTable(texts: [["Pillar", "What happened", "When"], ["Confidentiality", "Data taken", "May"],
                                     ["Integrity", "Systems encrypted", "June"], ["Availability", "Shut down", "July"]])
        let (engine, textView) = makeEngine(blocks(wide))
        let view = try view(engine)
        view.activate(P(row: 1, column: 1), caret: .end)
        settle(engine, textView)
        let canvas = view.canvas
        let grid = view.grid
        for axis in [NoteTableReorder.Axis.row, .column] {
            let sizes = axis == .row ? grid.rowHeights : grid.columnWidths
            let total = sizes.reduce(0, +)
            let reorder = try XCTUnwrap(NoteTableReorder(table: view, textView: textView, axis: axis, source: 1,
                                                         tokens: AtticColorTokens.resolve(.default), animated: false, below: nil))
            let card = try XCTUnwrap(textView.subviews.compactMap { $0 as? NoteDragLiftView }.first)
            let home = sizes[0]
            let grab = home + sizes[1] / 2
            func point(_ along: CGFloat) -> CGPoint {
                canvas.convert(axis == .row ? CGPoint(x: 12, y: along) : CGPoint(x: along, y: 12), to: nil)
            }
            func cardStart() -> (along: CGFloat, across: CGFloat) {
                let frame = canvas.convert(card.frame, from: textView)
                return axis == .row ? (frame.minY, frame.minX) : (frame.minX, frame.minY)
            }
            reorder.update(windowPoint: point(grab))
            var targets: Set<Int> = []
            for offset in stride(from: CGFloat(2), through: sizes[2], by: 5) {
                reorder.update(windowPoint: point(grab + offset))
                targets.insert(reorder.target)
                XCTAssertEqual(cardStart().along, home + offset, accuracy: 0.5, "\(axis) +\(offset): at the pointer, not its slot")
                XCTAssertEqual(cardStart().across, 0, accuracy: 0.5, "\(axis): along its axis only")
            }
            XCTAssertEqual(targets, [1, 2], "\(axis): the gap opened ahead of it on the way")
            reorder.update(windowPoint: point(grab + 2_000))
            XCTAssertEqual(cardStart().along, total - sizes[1], accuracy: 0.5, "\(axis): held inside the table's end")
            reorder.update(windowPoint: point(grab - 2_000))
            XCTAssertEqual(cardStart().along, 0, accuracy: 0.5, "\(axis): held inside the table's start")
            XCTAssertEqual(reorder.target, 0)
            reorder.finish { _ in }
        }
    }

    private func location(of text: String, in engine: NoteEditorEngine) -> Int {
        (engine.textStorage.string as NSString).range(of: text).location
    }

    private func keyEvent(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags, window: NSWindow?) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    // MARK: Model

    func testTheModelAddsRemovesMovesAndFillsWithinItsLimits() {
        var table = NoteTable.blank()
        XCTAssertEqual([table.columnCount, table.rowCount], [2, 3])
        XCTAssertTrue(table.headerRow, "the header row is on by default")
        table.insertColumn(at: 1)
        table.insertRow(at: 0)
        XCTAssertTrue(table.isRectangular)
        XCTAssertEqual([table.columnCount, table.rowCount], [3, 4])
        table[P(row: 0, column: 0)] = NoteTable.Cell("a")
        table[P(row: 0, column: 2)] = NoteTable.Cell("c")
        XCTAssertTrue(table.moveColumn(from: 0, to: 2))
        XCTAssertEqual(table.rows[0].cells.map(\.text), ["", "c", "a"])
        XCTAssertTrue(table.moveRow(from: 0, to: 3))
        XCTAssertEqual(table.rows[3].cells.map(\.text), ["", "c", "a"])
        XCTAssertTrue(table.removeRow(at: 3))
        XCTAssertTrue(table.removeColumn(at: 0))
        var single = NoteTable.blank(columns: 1, rows: 1)
        XCTAssertFalse(single.removeRow(at: 0), "the last row stays (delete the table instead)")
        XCTAssertFalse(single.removeColumn(at: 0))
        // Fill grows the table from the anchor.
        XCTAssertTrue(single.fill([[NoteTable.Cell("1"), NoteTable.Cell("2")], [NoteTable.Cell("3")]], at: P(row: 0, column: 0)))
        XCTAssertEqual(single.texts, [["1", "2"], ["3", ""]])
        XCTAssertFalse(single.fill([[NoteTable.Cell("x")]], at: P(row: 0, column: NoteTable.maxColumns)), "past 30 columns")
        XCTAssertFalse(single.fill([[NoteTable.Cell("x")]], at: P(row: NoteTable.maxRows, column: 0)), "past 500 rows")
        let copy = pillars.withFreshIDs()
        XCTAssertEqual(copy.texts, pillars.texts)
        XCTAssertTrue(zip(copy.rows, pillars.rows).allSatisfy { $0.id != $1.id })
    }

    func testTheStoredTableKeepsIdsMarksDatesAndUnknownFieldsAndRefusesARaggedOne() throws {
        var table = pillars
        table.columns[1].width = 140
        table.columns[1].align = .right
        table.extras = ["future": .string("kept")]
        table.rows[1].extras = ["rowFuture": .int(3)]
        table.rows[1].cells[1] = NoteTable.Cell("Due \u{FFFC} now", marks: [NoteMark(.bold, offset: 0, length: 3)],
                                                inlines: [NoteInline(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 9)!))],
                                                extras: ["cellFuture": .bool(true)])
        let document = NoteDocument(blocks: [.text("T"), .table(table, id: UUID())])
        let data = try NoteContentCodec.encode(document)
        guard case let .editable(decoded) = NoteContentCodec.decode(data) else { return XCTFail("readable") }
        XCTAssertEqual(decoded.blocks[1].table, table)
        XCTAssertEqual(decoded.requires, ["table-v1"])
        XCTAssertTrue(decoded.objectIDs.contains(table.rows[1].cells[1].inlines[0].id), "dates in cells are objects")
        // A ragged table on disk is kept opaque and the note read-only, never repaired.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var blocks = try XCTUnwrap(json["blocks"] as? [[String: Any]])
        var rows = try XCTUnwrap(blocks[1]["rows"] as? [[String: Any]])
        rows[0]["cells"] = [["text": "only one"]]
        blocks[1]["rows"] = rows
        json["blocks"] = blocks
        let ragged = try JSONSerialization.data(withJSONObject: json)
        guard case let .readOnly(original, _, _) = NoteContentCodec.decode(ragged) else { return XCTFail("kept read-only") }
        XCTAssertEqual(original, ragged)
        // A build that doesn't know tables opens the note read-only (capability).
        XCTAssertTrue(NoteDocument.editableCapabilities.contains("table-v1"))
    }

    // MARK: Markdown, TSV, HTML

    func testMarkdownExportEscapesAndAlignsAndReadsBack() throws {
        var table = NoteTable(texts: [["Name", "Note"], ["a|b", "one\ntwo"]], alignments: [.center, .right])
        var markdown = NoteTableText.markdown(table)
        XCTAssertEqual(markdown, """
        | Name | Note |
        | :---: | ---: |
        | a\\|b | one<br>two |
        """)
        var read = try XCTUnwrap(NoteTableText.parseMarkdown(markdown))
        XCTAssertEqual(read.texts, table.texts)
        XCTAssertEqual(read.columns.map(\.align), [.center, .right])
        XCTAssertTrue(read.headerRow)
        table.headerRow = false
        markdown = NoteTableText.markdown(table)
        XCTAssertTrue(markdown.hasPrefix(NoteTableText.headerOffComment))
        read = try XCTUnwrap(NoteTableText.parseMarkdown(markdown))
        XCTAssertFalse(read.headerRow, "the comment keeps the header row off through a round trip")
        XCTAssertEqual(NoteTableText.tsv(pillars).components(separatedBy: "\n")[2], "Integrity\tSystems encrypted by ransomware")
    }

    func testTabularTextAndHtmlAreRecognisedButProseIsNot() throws {
        XCTAssertEqual(NoteTableText.parseTSV("a\tb\nc\td\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(NoteTableText.parseTSV("x\t\"quoted\t\"\"cell\"\"\"\ny\tz"), [["x", "quoted\t\"cell\""], ["y", "z"]])
        XCTAssertNil(NoteTableText.parseTSV("one line with\ta tab\nand two lines\nof prose"), "most lines need the same tabs")
        XCTAssertNil(NoteTableText.parseTSV("no tabs at all"))
        let html = """
        <html><body><table><thead><tr><th>Pillar</th><th>What&nbsp;happened</th></tr></thead>
        <tr><td>Integrity</td><td>Systems<br>encrypted &amp; held</td></tr><tr><td colspan="2">Note</td></tr></table></body></html>
        """
        let parsed = try XCTUnwrap(NoteTableText.parseHTML(html))
        XCTAssertTrue(parsed.header)
        XCTAssertEqual(parsed.rows, [["Pillar", "What happened"], ["Integrity", "Systems\nencrypted & held"], ["Note", ""]])
        XCTAssertNotNil(NoteTablePaste.table(fromHTML: html))
        XCTAssertNil(NoteTablePaste.table(fromHTML: "<p>Read this:</p>" + html), "a page with prose stays rich text")
        XCTAssertEqual(NoteTablePaste.table(fromText: "| a | b |\n| --- | --- |\n| 1 | 2 |")?.texts, [["a", "b"], ["1", "2"]])
    }

    // MARK: Inserting

    func testSlashTableInsertsATwoByThreeTableWithItsHeaderAndTheCaretInIt() throws {
        let (engine, textView) = makeEngine([.text("Note"), .text("")])
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type("/table", into: textView)
        let session = try XCTUnwrap(engine.slashSession)
        XCTAssertEqual(session.items.first?.kind, .table)
        XCTAssertEqual(NoteCommandCatalog.slashHint(.table), "2 × 3")
        XCTAssertTrue(engine.acceptSlashItem(.table))
        settle(engine, textView)
        let attachment = try table(engine)
        XCTAssertEqual([attachment.table.columnCount, attachment.table.rowCount], [2, 3])
        XCTAssertTrue(attachment.table.headerRow)
        XCTAssertFalse(engine.textStorage.string.contains("/table"))
        let view = try view(engine)
        XCTAssertEqual(view.activeCell, P(row: 0, column: 0))
        XCTAssertTrue(textView.window?.firstResponder === view.editor)
        // A paragraph always follows the table.
        let range = try XCTUnwrap(engine.range(ofTable: attachment))
        XCTAssertLessThan(NSMaxRange(range), engine.textStorage.length)
        // One Undo takes it back to the typed command.
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.textStorage.string.hasSuffix("/table"))
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
    }

    func testTableIsOnTheFormatRowAndInEveryInsertAndFormatMenu() {
        XCTAssertEqual(NoteCommandCatalog.lists, [.paragraph(.bullet), .paragraph(.number), .paragraph(.checklist), .table],
                       "Table takes Quote's cell")
        XCTAssertTrue(NoteCommandCatalog.styles.contains(.paragraph(.quote)), "Quote joins the style list")
        let styles = NoteCommandCatalog.styles
        XCTAssertEqual(styles.firstIndex(of: .paragraph(.callout(icon: "💡"))), styles.firstIndex(of: .paragraph(.quote)).map { $0 + 1 },
                       "R14: Callout after Quote")
        XCTAssertTrue(NoteCommandCatalog.formatSections.flatMap { $0 }.contains(.table), "Format › Table")
        XCTAssertTrue(NoteInsertAction.allCases.contains(.table), "Insert › Table (⋯, right-click, menu bar)")
        XCTAssertEqual(NoteFormatCommand.table.shortcut, "⌥⌘T")
        XCTAssertEqual(NoteFormatRowItem.table, [.tableMenu, .tableTool(.addRow), .tableTool(.addColumn),
                                                 .tableTool(.deleteRow), .tableTool(.deleteColumn), .close])
    }

    func testTheFormatRowCommandAndInsertMenuInsertATable() throws {
        let (engine, textView) = makeEngine([.text("Note"), .text("A line")])
        textView.setSelectedRange(NSRange(location: location(of: "A line", in: engine) + 2, length: 0))
        let router = NoteCommandRouter(engine: engine)
        XCTAssertTrue(router.canInsert(.table))
        router.insert(.table, from: .noteMenu)
        settle(engine, textView)
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text, .table, .text], "after the caret's line")
        XCTAssertEqual(engine.document().blocks[1].text, "A line")
        XCTAssertEqual(engine.validate(.table).state, .on, "on while the caret is in the table")
        XCTAssertFalse(router.canInsert(.table), "no table inside a table")
    }

    func testAPipeRowThenReturnBecomesATableAndUndoGivesTheTextBack() throws {
        let (engine, textView) = makeEngine([.text("Note"), .text("")])
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type("| Pillar | What happened |", into: textView)
        textView.insertNewline(nil)
        settle(engine, textView)
        let attachment = try table(engine)
        XCTAssertEqual(attachment.table.texts, [["Pillar", "What happened"], ["", ""], ["", ""]])
        XCTAssertEqual((try view(engine)).activeCell, P(row: 1, column: 0))
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.textStorage.string.contains("| Pillar | What happened |\n"))
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
    }

    // MARK: Aa's row in a table and the selection bar

    func testTheFormatRowTurnsIntoTableToolsAndTheyEditTheTable() throws {
        let (engine, _) = makeEngine(blocks())
        let attachment = try table(engine)
        let router = NoteCommandRouter(engine: engine)
        XCTAssertNil(NoteFormatSnapshot.make(router: router, selection: NSRange(location: 0, length: 0)).table)
        try view(engine).activate(P(row: 1, column: 1), caret: .end)
        let snapshot = NoteFormatSnapshot.make(router: router, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(snapshot.table, NoteTableToolsState(headerRow: true, rows: 4, columns: 2))
        XCTAssertTrue(snapshot.isEnabled(.mark(.bold)), "the cell's marks stay on the selection bar")
        XCTAssertFalse(snapshot.isEnabled(.paragraph(.heading(1))), "no block styles in cells")
        XCTAssertTrue(router.runTable(.addRow, from: .formatBar))
        XCTAssertEqual(attachment.table.rowCount, 5)
        XCTAssertEqual(try view(engine).activeCell, P(row: 2, column: 1))
        XCTAssertTrue(router.runTable(.addColumn, from: .formatBar))
        XCTAssertEqual(attachment.table.columnCount, 3)
        XCTAssertTrue(router.runTable(.deleteColumn, from: .formatBar))
        XCTAssertTrue(router.runTable(.deleteRow, from: .formatBar))
        XCTAssertEqual(attachment.table.texts, pillars.texts)
        XCTAssertTrue(router.runTableMenu(.headerRow, from: .formatBar))
        XCTAssertFalse(attachment.table.headerRow)
        let pasteboard = NSPasteboard(name: .init("table-md-\(UUID())"))
        engine.copyTableAsMarkdown(attachment, to: pasteboard)
        XCTAssertTrue(pasteboard.string(forType: .string)?.hasPrefix(NoteTableText.headerOffComment) == true)
        XCTAssertTrue(router.runTableMenu(.convertToText, from: .formatBar))
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
        XCTAssertTrue(engine.textStorage.string.contains("Integrity\tSystems encrypted by ransomware"))
        XCTAssertTrue(engine.history.undo(), "Convert to Text is one step")
        XCTAssertTrue(engine.document().blocks.contains { $0.kind == .table })
    }

    func testAppearanceChangeKeepsAFocusedTableBelowItsPrecedingText() throws {
        let (engine, textView) = makeEngine(blocks(.blank()))
        let view = try view(engine)
        view.activate(P(row: 1, column: 1), caret: .end)
        let before = view.convert(view.bounds, to: textView)
        engine.update(design: AtticDesignContext(mode: .dark))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let after = view.convert(view.bounds, to: textView)
        XCTAssertEqual(after.minX, before.minX, accuracy: 0.5)
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.5)
        XCTAssertTrue(textView.window?.firstResponder === view.editor)
    }

    func testTableControlsFollowTheAttachmentsFinalFrameAfterAWidthChange() throws {
        let (engine, textView) = makeEngine(blocks(.blank()))
        let view = try view(engine)
        let chrome = NoteTableChrome(engine: engine, textView: textView, design: engine.style.design)
        defer { chrome.invalidate() }
        view.activate(P(row: 1, column: 1), caret: .end)
        chrome.place()
        // The note's layout callback has already run when TextKit resizes
        // its attachment. Its own layout must update the overlay controls.
        for width: CGFloat in [364, 264] {
            view.setFrameSize(NSSize(width: width, height: view.bounds.height))
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            let rect = view.convert(view.bounds, to: textView)
            // U-26: on the card's right and bottom edges.
            XCTAssertEqual(chrome.addColumnChip.frame.midX, rect.maxX, accuracy: 0.5)
            XCTAssertEqual(chrome.addRowChip.frame.midX, rect.midX, accuracy: 0.5)
            XCTAssertEqual(chrome.addRowChip.frame.midY, rect.minY + view.grid.height, accuracy: 0.5)
            XCTAssertLessThanOrEqual(chrome.addColumnChip.frame.midX + AtticNoteTableMetrics.addChipSize / 2,
                                     rect.maxX + AtticNoteTableMetrics.addChipSize / 2 + 0.5, "half its disc past the card, no more")
        }
    }

    func testRedoOfDeletingTheLastRowOrColumnKeepsTypingInTheSurvivingCell() throws {
        for deletingRow in [true, false] {
            let (engine, textView) = makeEngine(blocks())
            let attachment = try table(engine)
            let view = try view(engine)
            let original = P(row: attachment.table.rowCount - 1, column: attachment.table.columnCount - 1)
            view.activate(original, caret: .end)
            XCTAssertTrue(deletingRow ? engine.deleteRow(of: attachment, at: original.row)
                                      : engine.deleteColumn(of: attachment, at: original.column))
            let surviving = try XCTUnwrap(view.activeCell)
            let text = attachment.table[surviving].text
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(view.activeCell, original)
            XCTAssertTrue(engine.history.redo())
            settle(engine, textView)
            XCTAssertEqual(view.activeCell, surviving)
            XCTAssertTrue(textView.window?.firstResponder === view.editor)
            XCTAssertEqual(view.editor.selectedRange(), NSRange(location: text.utf16.count, length: 0))
            type(" continued", into: view.editor)
            XCTAssertEqual(attachment.table[surviving].text, text + " continued")
        }
    }

    func testJTableDefaultHighlightHasNoKeyAndGreyIsExplicit() throws {
        let (engine, _) = makeEngine(blocks())
        let attachment = try table(engine)
        let view = try view(engine)
        let position = P(row: 2, column: 1)
        let router = NoteCommandRouter(engine: engine)
        view.activate(position, caret: .range(NSRange(location: 0, length: 7)))
        XCTAssertTrue(router.run(.mark(.highlight), from: .formatBar))
        XCTAssertEqual(attachment.table[position].marks, [NoteMark(.highlight, offset: 0, length: 7)])
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.applyCellMark(.highlight, in: view))
        XCTAssertEqual(attachment.table[position].marks, [NoteMark(.highlight, offset: 0, length: 7)])
        XCTAssertTrue(router.highlight(.grey, from: .formatBar))
        XCTAssertEqual(attachment.table[position].marks, [NoteMark(.highlight, offset: 0, length: 7, colour: "grey")])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(attachment.table[position].marks, [NoteMark(.highlight, offset: 0, length: 7)])
    }

    func testMarksApplyToACellsTextAndToEverySelectedCell() throws {
        let (engine, _) = makeEngine(blocks())
        let attachment = try table(engine)
        let view = try view(engine)
        let router = NoteCommandRouter(engine: engine)
        view.activate(P(row: 2, column: 1), caret: .range(NSRange(location: 0, length: 7)))
        XCTAssertEqual(engine.tableMarkState(.italic), .off)
        XCTAssertTrue(router.run(.mark(.italic), from: .selectionBar))
        XCTAssertEqual(attachment.table[P(row: 2, column: 1)].marks, [NoteMark(.italic, offset: 0, length: 7)])
        XCTAssertEqual(engine.tableMarkState(.italic), .on)
        XCTAssertEqual(view.editor.selectedRange(), NSRange(location: 0, length: 7), "the selection stays")
        // Whole cells: every selected cell's text.
        view.selectCells(NoteTableCellRange(anchor: P(row: 1, column: 0), head: P(row: 3, column: 0)))
        XCTAssertTrue(router.run(.mark(.bold), from: .selectionBar))
        for row in 1...3 {
            let cell = attachment.table[P(row: row, column: 0)]
            XCTAssertEqual(cell.marks, [NoteMark(.bold, offset: 0, length: (cell.text as NSString).length)])
        }
        XCTAssertEqual(engine.tableMarkState(.bold), .on)
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(attachment.table[P(row: 1, column: 0)].marks.isEmpty)
        // A link on a cell's text through the link card's path.
        var requested: NoteCellLinkTarget?
        engine.onCellLinkRequest = { requested = $0 }
        view.activate(P(row: 3, column: 1), caret: .range(NSRange(location: 0, length: 8)))
        XCTAssertTrue(router.run(.mark(.link), from: .selectionBar))
        let target = try XCTUnwrap(requested)
        XCTAssertFalse(engine.commitCellLink("not a url", target: target))
        XCTAssertTrue(engine.commitCellLink("https://example.com", target: target))
        XCTAssertEqual(attachment.table[P(row: 3, column: 1)].marks, [NoteMark(.link, offset: 0, length: 8, url: "https://example.com")])
    }

    /// Whole cells selected: the bar holds the columns' alignment, B I U S,
    /// highlight, and copy, cut and clear (spec § 4.3).
    func testTheCellsBarAlignsCopiesCutsAndClears() throws {
        let (engine, _) = makeEngine(blocks())
        let attachment = try table(engine)
        let view = try view(engine)
        let router = NoteCommandRouter(engine: engine)
        view.selectCells(NoteTableCellRange(anchor: P(row: 1, column: 0), head: P(row: 2, column: 1)))
        let snapshot = NoteFormatSnapshot.make(router: router, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(snapshot.cells, NoteCellSelectionState(alignment: .left))
        XCTAssertEqual(NoteFormatBarItem.items(cells: true), [.align] + (NoteCommandCatalog.barMarks + [.mark(.highlight)]).map { .command($0) }
                       + [.cellAction(.copy), .cellAction(.cut), .cellAction(.clear)])
        XCTAssertTrue(router.alignCells(.center, from: .selectionBar))
        XCTAssertEqual(attachment.table.columns.map(\.align), [.center, .center], "alignment applies to the selected columns")
        let pasteboard = NSPasteboard(name: .init("cells-bar-\(UUID())"))
        XCTAssertTrue(engine.perform(cellAction: .cut, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: NoteTablePaste.tsvType),
                       "Confidentiality\tData taken from the IT network\nIntegrity\tSystems encrypted by ransomware")
        XCTAssertEqual(attachment.table.rows[1].cells.map(\.text), ["", ""], "cut clears the cells")
        XCTAssertEqual(attachment.table.rowCount, 4, "and keeps the grid")
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.perform(cellAction: .clear, pasteboard: pasteboard))
        XCTAssertEqual(attachment.table.rows[2].cells.map(\.text), ["", ""])
    }

    func testTheSelectionBarSitsOverTheCellsSelection() throws {
        let (engine, textView) = makeEngine(blocks())
        let view = try view(engine)
        view.activate(P(row: 2, column: 1), caret: .range(NSRange(location: 0, length: 7)))
        let rects = try XCTUnwrap(engine.tableSelectionRects(in: textView))
        let cell = view.canvas.convert(view.grid.cellRect(P(row: 2, column: 1)), to: textView)
        XCTAssertTrue(cell.insetBy(dx: -1, dy: -1).contains(rects.first), "the bar's anchor is the cell's selected text")
    }

    // MARK: Keys

    func testOptionCommandArrowsAddRowsAndColumnsAroundTheCell() throws {
        let (engine, _) = makeEngine(blocks())
        let attachment = try table(engine)
        let view = try view(engine)
        view.activate(P(row: 1, column: 0), caret: .end)
        let window = view.window
        XCTAssertTrue(engine.handleTableShortcut(keyEvent(126, "\u{F700}", [.command, .option], window: window), in: view))
        XCTAssertEqual(attachment.table.rowCount, 5)
        XCTAssertEqual(view.activeCell, P(row: 1, column: 0), "the new row above, the caret in it")
        XCTAssertTrue(engine.handleTableShortcut(keyEvent(124, "\u{F703}", [.command, .option], window: window), in: view))
        XCTAssertEqual(attachment.table.columnCount, 3)
        XCTAssertEqual(view.activeCell, P(row: 1, column: 1))
        XCTAssertTrue(engine.handleTableShortcut(keyEvent(11, "b", [.command], window: window), in: view), "⌘B in a cell")
    }

    func testH13SelectAllFromTitleBodyAndObjectIncludesTheWholeNote() throws {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 80, pixelHeight: 40)
        let (engine, text) = makeEngine(blocks() + [image])
        let all = NSRange(location: 0, length: engine.textStorage.length)
        for selection in [NSRange(location: 2, length: 0), NSRange(location: 15, length: 0),
                          try XCTUnwrap(engine.range(ofTable: table(engine))),
                          try XCTUnwrap(engine.objectPlacement(image.id!)?.1)] {
            text.setSelectedRange(selection)
            text.selectAll(nil)
            XCTAssertEqual(text.selectedRange(), all)
        }
    }

    func testCommandAOnceSelectsTheCellsTextThenTheWholeTable() throws {
        let (engine, textView) = makeEngine(blocks())
        let attachment = try table(engine)
        let view = try view(engine)
        view.activate(P(row: 1, column: 1), caret: .start)
        view.editor.selectAll(nil)
        XCTAssertEqual(view.editor.selectedRange(), NSRange(location: 0, length: ("Data taken from the IT network" as NSString).length))
        view.editor.selectAll(nil)
        XCTAssertTrue(textView.window?.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange(), engine.range(ofTable: attachment))
        // ⌫ on a selected table deletes it, as one Undo step.
        textView.deleteBackward(nil)
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.document().blocks.contains { $0.kind == .table })
    }

    func testEmptyCellSelectAllRequiresTwoPresses() throws {
        let (engine, textView) = makeEngine([.text("Title"), .table(.blank()), .text("After")])
        let attachment = try table(engine)
        engine.enterTable(attachment, at: .init(row: 1, column: 0), caret: .start)
        let tableView = try view(engine)
        XCTAssertEqual(tableView.editor.string, "")
        tableView.editor.selectAll(nil)
        XCTAssertTrue(textView.window?.firstResponder === tableView.editor, "the first press keeps the keyboard in the empty cell")
        tableView.editor.selectAll(nil)
        XCTAssertTrue(textView.window?.firstResponder === textView)
        XCTAssertNil(tableView.activeCell)
        XCTAssertEqual(textView.selectedRange(), engine.range(ofTable: attachment))
    }

    func testBackspaceIntoATableFromBelowSelectsItFirst() throws {
        let (engine, textView) = makeEngine(blocks())
        let attachment = try table(engine)
        textView.setSelectedRange(NSRange(location: location(of: "After the table", in: engine), length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.selectedRange(), engine.range(ofTable: attachment), "selected, not joined or deleted")
        XCTAssertTrue(engine.document().blocks.contains { $0.kind == .table })
    }

    // MARK: Structure and widths

    func testEachStructureChangeIsOneUndoStepAndADraggedWidthIsOne() throws {
        let (engine, _) = makeEngine(blocks())
        let attachment = try table(engine)
        let view = try view(engine)
        view.activate(P(row: 1, column: 0), caret: .end)
        let start = engine.history.undoOps.count
        XCTAssertTrue(engine.moveRow(of: attachment, from: 1, to: 2))
        XCTAssertEqual(attachment.table.rows[2].cells[0].text, "Confidentiality")
        XCTAssertTrue(engine.moveColumn(of: attachment, from: 0, to: 1))
        XCTAssertEqual(attachment.table.rows[0].cells.map(\.text), ["What happened", "Pillar"])
        XCTAssertTrue(engine.setAlignment(.center, of: attachment, columns: 0...1))
        // A drag of a column's edge: many previews, one step.
        let before = attachment.table
        for width in stride(from: 90, through: 150, by: 10) {
            engine.previewColumnWidth(attachment, column: 0, width: CGFloat(width))
        }
        engine.commitColumnWidth(attachment, from: before)
        XCTAssertEqual(attachment.table.columns[0].width, 150)
        XCTAssertEqual(engine.history.undoOps.count, start + 4)
        XCTAssertTrue(engine.history.undo())
        XCTAssertNil(attachment.table.columns[0].width)
        XCTAssertTrue(engine.distributeColumns(attachment) == false, "nothing to distribute now")
        while engine.history.undoOps.count > start { XCTAssertTrue(engine.history.undo()) }
        XCTAssertEqual(attachment.table.texts, pillars.texts)
    }

    func testAWideTableScrollsInsideTheColumnAndKeepsTheActiveCellInView() throws {
        let wide = NoteTable(texts: [["Pillar", "What happened", "Control that failed", "Source"],
                                     ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"]])
        let (engine, textView) = makeEngine(blocks(wide))
        let view = try view(engine)
        XCTAssertTrue(view.grid.scrolls)
        XCTAssertEqual(view.frame.width, 264, accuracy: 0.5, "the page never scrolls sideways")
        XCTAssertTrue(view.scrollView.ownsHorizontalScrolling, "the panel leaves sideways gestures over it to the table")
        XCTAssertLessThanOrEqual(textView.frame.width, 320)
        view.activate(P(row: 1, column: 3), caret: .end)
        XCTAssertGreaterThan(view.scrollOffset, 0)
        let rect = view.grid.cellRect(P(row: 1, column: 3))
        XCTAssertLessThanOrEqual(rect.maxX - view.scrollOffset, view.bounds.width + 0.5, "the cell is in view")
        // The fade marks the cut edge (the left one, now).
        XCTAssertNotNil(view.scrollView.layer?.mask)
        // U-25: the card keeps its rounded outline, fixed over the scrolled
        // cells and outside the fade; the cells clip to its corners.
        XCTAssertFalse(view.frameView.isHidden)
        XCTAssertFalse(view.canvas.strokesCard)
        XCTAssertEqual(view.frameView.frame, CGRect(x: 0, y: 0, width: view.bounds.width, height: view.grid.height))
        XCTAssertFalse(view.frameView.isDescendant(of: view.scrollView), "not faded with the cells")
        XCTAssertEqual(view.scrollView.layer?.cornerRadius, AtticNoteTableMetrics.radius)
    }

    /// U-25: a table that fits draws its own outline with its grid.
    func testATableThatFitsDrawsItsOwnOutline() throws {
        let (engine, _) = makeEngine(blocks(NoteTable(texts: [["A", "B"], ["C", "D"]])))
        let view = try view(engine)
        XCTAssertFalse(view.grid.scrolls)
        XCTAssertTrue(view.frameView.isHidden)
        XCTAssertTrue(view.canvas.strokesCard)
    }

    /// A39: a `---` rule above a wide table. The note's owner saw the rule
    /// and the table run off the panel's right edge; the column must stay the
    /// text's 264 pt and the rule must span it and no more.
    func testARuleAboveAWideTableStaysInTheColumn() throws {
        let wide = NoteTable(texts: [["Pillar", "What happened", "Control that failed", "Source"],
                                     ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"]])
        let long = "The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication"
        let (engine, textView) = makeEngine([.text("CIA impact"), .text(long), .divider(), .text("Below the rule"), .table(wide), .text("After")])
        for _ in 0..<3 { settle(engine, textView) }
        try view(engine).setScrollOffset(80)
        for _ in 0..<3 { settle(engine, textView) }
        XCTAssertLessThanOrEqual(textView.frame.width, 320.5, "the text view keeps the panel's width")
        let container = try XCTUnwrap(textView.textContainer)
        XCTAssertLessThanOrEqual(container.size.width, 264 + 2 * container.lineFragmentPadding + 0.5, "the text container is the column")
        let table = try view(engine)
        XCTAssertEqual(table.frame.width, 264, accuracy: 0.5)
        let rule = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteDividerAttachment }.first)
        let bounds = rule.attachmentBounds(for: [:], location: engine.contentStorage.documentRange.location, textContainer: container,
                                           proposedLineFragment: CGRect(x: 0, y: 0, width: container.size.width, height: 21),
                                           position: .zero)
        XCTAssertLessThanOrEqual(bounds.width, 264.5, "a rule spans the text column and no more")
        var lineRights: [CGFloat] = []
        engine.layoutManager?.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location, options: [.ensuresLayout]) { fragment in
            lineRights.append(fragment.layoutFragmentFrame.maxX)
            return true
        }
        XCTAssertLessThanOrEqual(lineRights.max() ?? 0, 264 + 2 * container.lineFragmentPadding + 0.5, "nothing is laid out past the column")
    }

    /// The same, built as the owner typed it: `---` and Return, more text,
    /// then a wide table, then scrolled sideways.
    func testATypedRuleAboveAWideTableAlsoStaysInTheColumn() throws {
        let wide = NoteTable(texts: [["Pillar", "What happened", "Control that failed", "Source"],
                                     ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"]])
        let long = "The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication"
        let (engine, textView) = makeEngine([.text("CIA impact"), .text(long), .text("")])
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type("---", into: textView)
        textView.insertNewline(nil)
        type("Below the rule", into: textView)
        textView.insertNewline(nil)
        XCTAssertTrue(engine.insertTable(wide, replacing: textView.selectedRange(), name: "Insert Table", entering: false))
        for _ in 0..<3 { settle(engine, textView) }
        try view(engine).setScrollOffset(80)
        for _ in 0..<3 { settle(engine, textView) }
        let container = try XCTUnwrap(textView.textContainer)
        XCTAssertNotNil(engine.objects().compactMap { $0.0 as? NoteDividerAttachment }.first, "the rule was made")
        XCTAssertLessThanOrEqual(textView.frame.width, 320.5, "the text view keeps the panel's width")
        XCTAssertLessThanOrEqual(container.size.width, 264 + 2 * container.lineFragmentPadding + 0.5)
        XCTAssertEqual(try view(engine).frame.width, 264, accuracy: 0.5)
    }

    // MARK: Paste and copy

    func testTabularPasteBecomesATableInOneStepWithPasteAsText() throws {
        let (engine, textView) = makeEngine([.text("Note"), .text("Intro")])
        var notices: [String] = []
        engine.onNotice = { notices.append($0.detail) }
        let end = engine.textStorage.length
        XCTAssertTrue(engine.pastePlainText("Pillar\tWhat happened\nIntegrity\tEncrypted\n", at: NSRange(location: end, length: 0)))
        settle(engine, textView)
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text, .table, .text])
        XCTAssertEqual(engine.document().blocks[1].text, "Intro", "the text before stays on its line")
        XCTAssertEqual(notices.last, NoteTablePasteOffer.notice)
        XCTAssertNotNil(engine.tablePasteOffer)
        XCTAssertTrue(engine.pasteLastTableAsText())
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
        XCTAssertTrue(engine.textStorage.string.contains("Pillar\tWhat happened"))
        // ⌥⇧⌘V keeps tabular text as text.
        engine.isPastingAsPlainText = true
        XCTAssertTrue(engine.pastePlainText("a\tb\nc\td", at: NSRange(location: engine.textStorage.length, length: 0)))
        engine.isPastingAsPlainText = false
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
        // Over the limits: text, and the note says so.
        let huge = (0..<(NoteTable.maxRows + 1)).map { "r\($0)\tx" }.joined(separator: "\n")
        XCTAssertTrue(engine.pastePlainText(huge, at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
        XCTAssertTrue(notices.last?.contains("pasted as text") == true)
    }

    func testCopiedCellsPasteIntoAnotherCellAndGrowTheTable() throws {
        let (engine, _) = makeEngine(blocks())
        let attachment = try table(engine)
        let view = try view(engine)
        let pasteboard = NSPasteboard(name: .init("cells-\(UUID())"))
        engine.copyCells(in: view, range: NoteTableCellRange(anchor: P(row: 1, column: 0), head: P(row: 2, column: 1)), to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: NoteTablePaste.tsvType),
                       "Confidentiality\tData taken from the IT network\nIntegrity\tSystems encrypted by ransomware")
        XCTAssertTrue(pasteboard.string(forType: .html)?.contains("<td>Integrity</td>") == true)
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("| Confidentiality | Data taken from the IT network |") == true)
        XCTAssertNotNil(pasteboard.data(forType: NoteTablePaste.tableType))
        // Into the last row's second cell: one more column and row.
        XCTAssertTrue(engine.pasteIntoTable(view, at: P(row: 3, column: 1), from: pasteboard))
        XCTAssertEqual([attachment.table.columnCount, attachment.table.rowCount], [3, 5])
        XCTAssertEqual(attachment.table[P(row: 4, column: 2)].text, "Systems encrypted by ransomware")
        XCTAssertTrue(engine.history.undo(), "one step")
        XCTAssertEqual(attachment.table.texts, pillars.texts)
        // Cut clears the cells and keeps the grid.
        view.selectCells(NoteTableCellRange(anchor: P(row: 1, column: 0), head: P(row: 1, column: 1)))
        engine.clearCells(in: view, range: view.cellSelection!, name: "Cut")
        XCTAssertEqual(attachment.table.rows[1].cells.map(\.text), ["", ""])
        XCTAssertEqual(attachment.table.rowCount, 4)
    }

    func testPRB1PrivateBlockPasteSeparatesAndFormatsItsSurvivingTail() throws {
        for block in [NoteBlock.table(.blank()), NoteBlock.divider()] {
            let (source, _) = makeEngine([.text("Source"), block])
            let board = NSPasteboard(name: .init("PRB1-block-\(UUID())"))
            defer { board.releaseGlobally() }
            let object = try XCTUnwrap(source.objects().first)
            XCTAssertTrue(source.writeSelection(object.1, to: board, types: [NoteEditorEngine.fragmentType]))
            let data = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
            let (engine, text) = makeEngine([.text("T"), .text("abcd")])
            text.setSelectedRange(NSRange(location: 4, length: 0))
            XCTAssertTrue(engine.paste(fragmentData: data, at: text.selectedRange()))
            XCTAssertEqual(engine.textStorage.string, "T\nab\n\u{FFFC}\ncd")
            let pasted = engine.document()
            let tail = (text.string as NSString).range(of: "cd")
            XCTAssertTrue(engine.validate(.paragraph(.heading(2)), selection: tail).enabled)
            XCTAssertTrue(engine.perform(.paragraph(.heading(2)), selection: tail))
            XCTAssertEqual(engine.document().blocks.last?.style, "heading")
            let saved = try NoteContentCodec.encode(engine.document())
            let reopened = NoteEditorEngine(noteID: UUID(), document: try XCTUnwrap(NoteContentCodec.decode(saved).document))
            XCTAssertEqual(reopened.document(), engine.document())
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), pasted)
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.textStorage.string, "T\nabcd")
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.textStorage.string, "T\nab\n\u{FFFC}\ncd")
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), reopened.document())
        }
    }

    func testAWholeTableCopiesAsATableAndPastesBackWithNewIds() throws {
        let (engine, textView) = makeEngine(blocks())
        let attachment = try table(engine)
        let range = try XCTUnwrap(engine.range(ofTable: attachment))
        let pasteboard = NSPasteboard(name: .init("table-\(UUID())"))
        XCTAssertTrue(engine.writeSelection(range, to: pasteboard, types: [NoteEditorEngine.fragmentType, .rtf, .string]))
        XCTAssertNotNil(pasteboard.data(forType: NoteEditorEngine.fragmentType))
        XCTAssertNotNil(pasteboard.string(forType: .html))
        let data = try XCTUnwrap(pasteboard.data(forType: NoteEditorEngine.fragmentType))
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertTrue(engine.paste(fragmentData: data, at: textView.selectedRange()))
        let tables = engine.document().blocks.filter { $0.kind == .table }
        XCTAssertEqual(tables.count, 2)
        XCTAssertNotEqual(tables[0].id, tables[1].id)
        XCTAssertEqual(tables[0].table?.texts, tables[1].table?.texts)
        XCTAssertNotEqual(tables[0].table?.rows.first?.id, tables[1].table?.rows.first?.id, "row ids are fresh too")
        // Rich text from a selection reads the table's rows.
        let rich = NSPasteboard(name: .init("rich-\(UUID())"))
        XCTAssertTrue(engine.writeSelection(NSRange(location: 0, length: NSMaxRange(range) + 1), to: rich, types: [.rtf, .string]))
        let rtf = try XCTUnwrap(rich.data(forType: .rtf))
        let text = try NSAttributedString(data: rtf, documentAttributes: nil).string
        XCTAssertTrue(text.contains("Integrity\tSystems encrypted by ransomware"))
    }

    // MARK: Agents

    func testAgentsReadATableAsATokenAndAPipeTable() {
        let id = UUID()
        let document = NoteDocument(blocks: [.text("T"), .text("Intro"), .table(pillars, id: id)])
        let body = NoteTextExport.agentBody(document)
        XCTAssertEqual(body, """
        Intro
        <!-- attic:table id=\(id.uuidString) -->
        | Pillar | What happened |
        | --- | --- |
        | Confidentiality | Data taken from the IT network |
        | Integrity | Systems encrypted by ransomware |
        | Availability | Pipeline shut down |
        """)
    }

    func testAnAgentsTableEditMergesIntoTheTableKeepingIdsAndMarks() throws {
        let id = UUID()
        var table = pillars
        table[P(row: 1, column: 0)].marks = [NoteMark(.bold, offset: 0, length: 15)]
        let base = NoteDocument(blocks: [.text("T"), .table(table, id: id), .text("End")])
        var lines = NoteTextExport.agentBody(base).components(separatedBy: "\n")
        // Edit one cell and add a row.
        lines[4] = "| Integrity | Systems encrypted, then restored |"
        lines.insert("| Safety | None |", at: 6)
        let edited = try NoteAgentTextParser.document(title: "T", body: lines.joined(separator: "\n"), base: base)
        let merged = try XCTUnwrap(edited.blocks[1].table)
        XCTAssertEqual(edited.blocks[1].id, id)
        XCTAssertEqual(merged.rowCount, 5)
        XCTAssertEqual(merged.rows.prefix(4).map(\.id), table.rows.map(\.id), "kept rows keep their ids")
        XCTAssertEqual(merged.columns.map(\.id), table.columns.map(\.id))
        XCTAssertEqual(merged[P(row: 1, column: 0)].marks, table[P(row: 1, column: 0)].marks, "an unchanged cell keeps its marks")
        XCTAssertEqual(merged[P(row: 2, column: 1)].text, "Systems encrypted, then restored")
        XCTAssertEqual(merged[P(row: 4, column: 0)].text, "Safety")
        // The token alone removed: the table stays (same id).
        let withoutToken = NoteTextExport.agentBody(base).components(separatedBy: "\n").filter { !$0.hasPrefix("<!--") }
        let kept = try NoteAgentTextParser.document(title: "T", body: withoutToken.joined(separator: "\n"), base: base)
        XCTAssertEqual(kept.blocks[1].id, id)
        // The whole table removed: deleted.
        let gone = try NoteAgentTextParser.document(title: "T", body: "End", base: base)
        XCTAssertFalse(gone.blocks.contains { $0.kind == .table })
        // A new pipe table: a new table.
        let added = try NoteAgentTextParser.document(title: "T", body: NoteTextExport.agentBody(base) + "\n| a | b |\n| --- | --- |\n| 1 | 2 |", base: base)
        XCTAssertEqual(added.blocks.filter { $0.kind == .table }.count, 2)
        // Ragged rows and unknown tokens are refused.
        var ragged = NoteTextExport.agentBody(base).components(separatedBy: "\n")
        ragged[4] = "| Integrity |"
        XCTAssertThrowsError(try NoteAgentTextParser.document(title: "T", body: ragged.joined(separator: "\n"), base: base)) {
            XCTAssertEqual($0 as? NoteAgentTextError, .raggedTable)
        }
        let unknown = "<!-- attic:table id=\(UUID().uuidString) -->\n| a | b |\n| --- | --- |"
        XCTAssertThrowsError(try NoteAgentTextParser.document(title: "T", body: unknown, base: base))
    }

    func testUpdateNoteTableOperationsByIdAreValidated() throws {
        var table = pillars
        let rowID = table.rows[2].id, columnID = table.columns[1].id
        table = try NoteTableAgentEdit.apply([
            ["op": "set_cell", "row_id": rowID.uuidString, "column_id": columnID.uuidString, "text": "Held on [date:2026-10-09]"],
            ["op": "insert_row", "after_row_id": rowID.uuidString, "cells": ["Safety", "None"]],
            ["op": "insert_column", "after_column_id": columnID.uuidString, "cells": ["Control", "", "", "", ""], "align": "center"],
            ["op": "set_alignment", "column_id": columnID.uuidString, "align": "right"],
            ["op": "set_header_row", "value": false]
        ], to: table)
        XCTAssertEqual(table[P(row: 2, column: 1)].inlines.count, 1, "a date token becomes a date")
        XCTAssertEqual(table[P(row: 3, column: 0)].text, "Safety")
        XCTAssertEqual(table.columns.map(\.align), [.left, .right, .center])
        XCTAssertFalse(table.headerRow)
        XCTAssertThrowsError(try NoteTableAgentEdit.apply([["op": "insert_row", "cells": ["one"]]], to: table), "ragged")
        XCTAssertThrowsError(try NoteTableAgentEdit.apply([["op": "delete_row", "row_id": UUID().uuidString]], to: table), "unknown id")
        XCTAssertThrowsError(try NoteTableAgentEdit.apply([["op": "explode"]], to: table))
        let serialized = NoteTableAgentEdit.serialize(.table(table))
        XCTAssertEqual((serialized["rows"] as? [[String: Any]])?.count, 5)
    }

    // MARK: Print, look, accessibility details

    func testPrintDrawsTheTableToThePagesWidth() throws {
        let wide = NoteTable(texts: [(0..<8).map { "Column \($0) heading" }, (0..<8).map { "value \($0)" }])
        let view = NotePrint.printView(document: NoteDocument(blocks: [.text("T"), .table(wide)]))
        var found: NoteTableAttachment?
        view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage?.length ?? 0)) { value, _, _ in
            if let table = value as? NoteTableAttachment { found = table }
        }
        let attachment = try XCTUnwrap(found)
        let image = try XCTUnwrap(attachment.renderedImage)
        XCTAssertEqual(image.size.width, NotePrint.columnWidth, accuracy: 0.5, "no sideways scrolling on paper")
        XCTAssertGreaterThan(image.size.height, 2 * 29, "shrunk columns wrap their text")
    }

    func testTheLookComesFromTokensInLightDarkAndIncreasedContrast() {
        let light = AtticColorTokens.resolve(AtticDesignContext.default)
        let dark = AtticColorTokens.resolve(AtticDesignContext(mode: .dark))
        let contrast = AtticColorTokens.resolve(AtticDesignContext(increaseContrast: true))
        XCTAssertGreaterThan(contrast.tableGrid.alpha, light.tableGrid.alpha, "Increase Contrast firms the grid (drawn 1 pt)")
        XCTAssertNotEqual(light.tableGrid, dark.tableGrid)
        XCTAssertEqual(light.tableHeaderFill.alpha, 0.035, accuracy: 0.001, "Light black 3.5 %")
        XCTAssertEqual(light.tableGrid.alpha, 0.13, accuracy: 0.001)
        // R14 B.4: cells 8 × 6 (Codex's 13 / 10 × 0.6).
        XCTAssertEqual([AtticNoteTableMetrics.cellPaddingH, AtticNoteTableMetrics.cellPaddingV,
                        AtticNoteTableMetrics.minColumnWidth, AtticNoteTableMetrics.maxColumnWidth,
                        AtticNoteTableMetrics.radius, AtticNoteTableMetrics.hairline, AtticNoteTableMetrics.edgeFade,
                        AtticNoteTableMetrics.indicatorHeight], [8, 6, 56, 168, 10, 0.5, 16, 3])
    }

    func testAReadOnlyNotesTableCannotBeEdited() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks()), readOnly: true)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        textView.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        settle(engine, textView)
        let attachment = try table(engine)
        XCTAssertFalse(engine.addRow(to: attachment, at: 1, focusing: 0))
        XCTAssertFalse(engine.changeTable(attachment, name: "x") { $0.headerRow = false })
        XCTAssertEqual(attachment.table.texts, pillars.texts)
        XCTAssertEqual([attachment.table.rowCount, attachment.table.columnCount], [4, 2])
        XCTAssertTrue(attachment.table.headerRow)
    }

    func testTheGripsAndChipsShowOnlyWhileTheCaretIsInATable() throws {
        let (engine, textView) = makeEngine(blocks())
        let chrome = NoteTableChrome(engine: engine, textView: textView, design: .default)
        defer { chrome.invalidate() }
        chrome.place()
        XCTAssertTrue(chrome.columnGrip.isHidden && chrome.rowGrip.isHidden && chrome.addRowChip.isHidden)
        let view = try view(engine)
        view.activate(P(row: 2, column: 1), caret: .end)
        chrome.place()
        XCTAssertFalse(chrome.columnGrip.isHidden || chrome.rowGrip.isHidden || chrome.addColumnChip.isHidden || chrome.addRowChip.isHidden)
        let table = view.convert(view.bounds, to: textView)
        XCTAssertEqual(chrome.rowGrip.frame.midX, table.minX - 12 + 2.5, accuracy: 0.5, "the row grip in the margin")
        XCTAssertLessThan(chrome.columnGrip.frame.midY, table.minY, "the column grip above the table")
        XCTAssertEqual(chrome.columnGrip.frame.width, AtticNoteTableMetrics.gripHitTarget, "a 28 pt target")
        // "+" under the last row adds a row.
        XCTAssertTrue(chrome.addRowChip.accessibilityPerformPress())
        XCTAssertEqual(try self.table(engine).table.rowCount, 5)
        textView.window?.makeFirstResponder(textView)
        view.deactivate()
        chrome.place()
        XCTAssertTrue(chrome.columnGrip.isHidden)
    }
}
