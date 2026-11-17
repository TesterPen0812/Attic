import XCTest
@testable import Attic

/// The agent text is an exact round trip (brief `notes-agent-text-roundtrip`).
/// Every marker the parser reads (`NoteAgentTextParser`, `NoteAgentTableText`)
/// is put in as literal text, in every place text lives, at the start of a
/// block right after each kind of block. The legs:
///
/// - identity: `parse(export(d))` with `d` as the base is `d`, block for block
///   and id for id;
/// - title only: a new title leaves every body block as it was;
/// - another edit: changing an unrelated paragraph, or another cell of the
///   same plain table, leaves the literal as it was;
/// - the block itself: an agent appending to the literal's own paragraph or
///   checklist line keeps the literal as text;
/// - by id: `set_cell` with the cell's text as `list_notes` gives it, plus
///   more text, keeps the literal as text and every real object whole;
/// - apart: a literal and the object it looks like read differently.
///
/// Every failure is collected and reported at once.
final class NoteAgentTextRoundTripTests: XCTestCase {
    func testEveryMarkerTypedAsTextComesBackAsTheSameText() {
        let failures = NoteAgentRoundTripProperty.failures(seeds: [11, 12, 13], documentsPerSeed: 150)
        guard !failures.isEmpty else { return }
        print("ROUND TRIP FAILURES\n" + failures.joined(separator: "\n"))
        XCTFail("\(failures.count) round-trip failures:\n" + failures.joined(separator: "\n"))
    }

    /// Text an agent writes without escapes means what it always did; an
    /// escape makes the marker text.
    func testTextWithoutEscapesKeepsItsMeaningAndAnEscapeMakesItText() throws {
        let tableID = UUID()
        let base = NoteDocument(blocks: [.text("T"), .table(NoteTable(texts: [["a", "b"], ["1", "2"]]), id: tableID)])
        let table = NoteTextExport.agentTable(base.blocks[1])
        // (Dates go in a checklist line: a new date in a paragraph is refused
        // by `NoteAgentTextSafety.validate`, which compares date ids.)
        let body = ["- [ ] [date:2026-01-02] and \\[date:2026-01-02]", "- [ ] item", "- \\[ ] text", "C:\\Users\\me", "last\\", "next",
                    table, "x | y", "after \\| table"].joined(separator: "\n")
        let parsed = try NoteAgentTextParser.document(title: "T", body: body, base: base)
        let blocks = Array(parsed.blocks.dropFirst())
        XCTAssertEqual(blocks.count, 8, "\(blocks)")
        XCTAssertEqual(blocks[0].inlines.map(\.kind), [.date(NoteDay(isoString: "2026-01-02")!)])
        XCTAssertEqual(blocks[0].text, "\u{FFFC} and [date:2026-01-02]")
        XCTAssertEqual(blocks[0].kind, .checklist)
        XCTAssertEqual(blocks[1].kind, .checklist)
        XCTAssertEqual(blocks[2], .text("- [ ] text"))
        XCTAssertEqual(blocks[3], .text("C:\\Users\\me"), "a backslash before a letter is itself")
        XCTAssertEqual(blocks[4], .text("last\\"), "a backslash ending a line is itself")
        XCTAssertEqual(blocks[5], .text("next"))
        XCTAssertEqual(blocks[6].table?.texts, [["a", "b"], ["1", "2"], ["x", "y"]], "an unescaped pipe line after a table is still a row")
        XCTAssertEqual(blocks[7], .text("after | table"))
        // A line sent with CRLF keeps a trailing backslash as text, as before.
        let crlf = try NoteAgentTextParser.document(title: "T", body: "last\\\r\nnext", base: .blank)
        XCTAssertEqual(crlf.blocks.dropFirst().map(\.text), ["last\\", "next"])
    }

    /// The composer reads what a person typed as typed: backslashes are
    /// text and every line break ends a line.
    func testTypedTextKeepsItsBackslashesAndLines() throws {
        let body = "C:\\[x] \\| y\\\n- [ ] next \\[date:2026-01-02]"
        let parsed = try NoteAgentTextParser.document(title: "T", body: body, base: .blank, typed: true)
        XCTAssertEqual(parsed.blocks.dropFirst().map(\.text), ["C:\\[x] \\| y\\", "next \\\u{FFFC}"])
        XCTAssertEqual(parsed.blocks.last?.inlines.count, 1, "a date token is a date, as before")
        // A typed table reads as it always did: only `\|` and `\\` are
        // escapes, and any line with a pipe is a row.
        let table = "| a\\[x] | b\\|c\\\\d |\n| --- | --- |\n| \\<y \\&z | [date:2026-01-02] |\n\\| e | f"
        let typedTable = try NoteAgentTextParser.document(title: "T", body: table, base: .blank, typed: true)
        XCTAssertEqual(typedTable.blocks.count, 2, "\(typedTable.blocks)")
        XCTAssertEqual(typedTable.blocks.last?.table?.texts,
                       [["a\\[x]", "b|c\\d"], ["\\<y \\&z", "2026-01-02"], ["| e", "f"]])
        let column = try NoteAgentTextParser.document(title: "T", body: "| h |\n| --- |\nx \\| y", base: .blank, typed: true)
        XCTAssertEqual(column.blocks.last?.table?.texts, [["h"], ["x | y"]])
    }
}

/// The generator and the legs, kept apart from XCTest.
enum NoteAgentRoundTripProperty {
    enum Container: CaseIterable, CustomStringConvertible {
        case paragraph, heading, bullet, quote, code, checklist, checked, headerCell, bodyCell, formattedCell, fileName

        var description: String {
            switch self {
            case .paragraph: "paragraph"
            case .heading: "heading"
            case .bullet: "bullet"
            case .quote: "quote"
            case .code: "code block"
            case .checklist: "checklist"
            case .checked: "checked item"
            case .headerCell: "header cell"
            case .bodyCell: "body cell"
            case .formattedCell: "formatted-table cell"
            case .fileName: "file name"
            }
        }

        var isCell: Bool { [.headerCell, .bodyCell, .formattedCell].contains(self) }
        /// An agent may change this block's text through `update_note`.
        var editableByText: Bool { [.paragraph, .checklist, .checked].contains(self) }
    }

    enum Before: CaseIterable, CustomStringConvertible {
        case nothing, paragraph, checklist, plainTable, formattedTable, heading

        var description: String {
            switch self {
            case .nothing: "first"
            case .paragraph: "after a paragraph"
            case .checklist: "after a checklist"
            case .plainTable: "after a plain table"
            case .formattedTable: "after a formatted table"
            case .heading: "after a heading"
            }
        }
    }

    /// Text the parser reads specially somewhere. `{image}`, `{file}`,
    /// `{table}` and `{block}` stand for real objects in the same note.
    static let markers: [String] = [
        "[date:2026-01-02]", "x [date:2026-01-02] y", "[date:2026-13-45]", "[unsupported]",
        "[unsupported content](attic://block/{block})",
        "<!-- attic:table -->", "<!-- attic:table id={table} -->", "<!-- attic:table headerRow=false -->",
        "<br>", "a<br/>b", "a<br />b",
        "|", "a | b", "| a | b |", "--- | ---", "|---|", "a |", "| x", "a \\| b",
        "- [ ] x", "- [x] x", "- [X] x", "- [ ]", "- [x]",
        "# x", "---", "> x", "1. x", "- x", "    x",
        "![image](attic://image/{image})", "[file: f.pdf](attic://file/{file})",
        "![image](attic://image/00000000-0000-0000-0000-000000000001)",
        "\\", "a\\", "\\\\", "\\[date:2026-01-02]", "\\|", "C:\\Users\\[x]",
        "&amp;", "&lt;b&gt;", "&#124;", "&#32;", "&nbsp;",
        " x ", "\tx", "x ", "x\t", "a\nb", "a\r\nb", "x\r", "a\rb", "x\r\r", "a\u{2028}b",
        "&#91;date:2026-01-02&#93;", "&#38;#65;", "a & b"
    ]

    /// A line feed is only ever inside a cell or a file's name: the editor
    /// and every import make one block per line. A carriage return can be
    /// anywhere.
    static func fits(_ marker: String, _ container: Container) -> Bool {
        !marker.unicodeScalars.contains("\n") || [.headerCell, .bodyCell, .formattedCell, .fileName].contains(container)
    }

    static let day = NoteDay(isoString: "2026-01-02")!

    struct Case {
        var name: String
        var document: NoteDocument
        /// The block holding the literal, and (for a cell) where.
        var block: Int
        var cell: (row: Int, column: Int)?
        var container: Container
    }

    // MARK: Building

    static func table(_ texts: [[String]], formatted: Bool) -> NoteTable {
        var table = NoteTable(texts: texts)
        if formatted { table.columns[0].width = 140 }
        return table
    }

    static func before(_ kind: Before) -> [NoteBlock] {
        switch kind {
        case .nothing: []
        case .paragraph: [.text("before")]
        case .checklist: [.checklist("before")]
        case .plainTable: [.table(table([["p", "q"], ["1", "2"]], formatted: false))]
        case .formattedTable: [.table(table([["p", "q"], ["1", "2"]], formatted: true))]
        case .heading:
            [{ var block = NoteBlock.text("before", style: "heading"); block.level = 2; return block }()]
        }
    }

    /// The block holding `text` in `container`.
    static func holder(_ text: String, _ container: Container) -> (NoteBlock, (row: Int, column: Int)?) {
        switch container {
        case .paragraph: return (.text(text), nil)
        case .heading:
            var block = NoteBlock.text(text, style: "heading"); block.level = 2
            return (block, nil)
        case .bullet:
            var block = NoteBlock.text(text, style: "bullet"); block.indent = 1
            return (block, nil)
        case .quote: return (.text(text, style: "quote"), nil)
        case .code: return (.text(text, style: "mono"), nil)
        case .checklist: return (.checklist(text), nil)
        case .checked: return (.checklist(text, checked: true), nil)
        case .headerCell: return (.table(table([[text, "h"], ["a", "b"]], formatted: false)), (0, 0))
        case .bodyCell: return (.table(table([["h1", "h2"], ["a", text]], formatted: false)), (1, 1))
        case .formattedCell: return (.table(table([["h1", "h2"], ["a", text]], formatted: true)), (1, 1))
        case .fileName:
            return (.file(attachmentID: UUID(), filename: text, contentTypeIdentifier: "public.data", byteCount: 3), nil)
        }
    }

    /// `[title, before…, holder, tail, image, file, unreadable block, table]`,
    /// with the placeholders in `text` naming the real objects at the end.
    static func makeCase(_ text: String, _ container: Container, _ kind: Before) -> Case {
        let image = NoteBlock.image(attachmentID: UUID())
        let file = NoteBlock.file(attachmentID: UUID(), filename: "f.pdf", contentTypeIdentifier: "com.adobe.pdf", byteCount: 3)
        let unreadable = NoteBlock.opaque(.object(["type": .string("future"), "id": .string(UUID().uuidString)]))
        let realTable = NoteBlock.table(table([["z"]], formatted: false))
        let prefix = [NoteBlock.text("T")] + before(kind)
        let blockIndex = prefix.count + 4
        let literal = text.replacingOccurrences(of: "{image}", with: image.id!.uuidString)
            .replacingOccurrences(of: "{file}", with: file.id!.uuidString)
            .replacingOccurrences(of: "{table}", with: realTable.id!.uuidString)
            .replacingOccurrences(of: "{block}", with: String(blockIndex))
        let (holder, cell) = holder(literal, container)
        let blocks = prefix + [holder, .text("tail"), image, file, unreadable, realTable]
        return Case(name: "\(container) \(kind)", document: NoteDocument(blocks: blocks),
                    block: prefix.count, cell: cell, container: container)
    }

    /// Literals beside the real object they look like.
    static func objectCases() -> [Case] {
        func date(extras: [String: NoteJSON] = [:]) -> NoteInline { NoteInline(id: UUID(), kind: .date(day), extras: extras) }
        let o = String(NoteDocument.objectCharacter)
        var cases: [Case] = []
        for (text, inlines) in [("[date:2026-01-02] then \(o)", [date()]), ("\(o) then [date:2026-01-02]", [date()])] {
            var paragraph = NoteBlock.text(text); paragraph.inlines = inlines
            cases.append(Case(name: "paragraph with a real date", document: NoteDocument(blocks: [.text("T"), paragraph, .text("tail")]),
                              block: 1, cell: nil, container: .paragraph))
            var item = NoteBlock.checklist(text); item.inlines = inlines
            cases.append(Case(name: "checklist with a real date", document: NoteDocument(blocks: [.text("T"), item, .text("tail")]),
                              block: 1, cell: nil, container: .checklist))
            for formatted in [false, true] {
                for extras in [[:], ["hint": NoteJSON.string("start")]] as [[String: NoteJSON]] {
                    var grid = table([["h1", "h2"], ["a", "b"]], formatted: formatted)
                    grid.rows[1].cells[1] = NoteTable.Cell(text, inlines: [date(extras: extras)])
                    cases.append(Case(name: "cell with a real date\(extras.isEmpty ? "" : " with extras")\(formatted ? ", formatted" : "")",
                                      document: NoteDocument(blocks: [.text("T"), .table(grid), .text("tail")]),
                                      block: 1, cell: (1, 1), container: formatted ? .formattedCell : .bodyCell))
                }
            }
        }
        return cases
    }

    // MARK: Legs

    static func parse(_ title: String, _ body: String, base: NoteDocument) -> Result<NoteDocument, Error> {
        Result { try NoteAgentTextParser.document(title: title, body: body, base: base) }
    }

    static func title(_ document: NoteDocument) -> String {
        NoteTextExport.agentLine(document.blocks[0], index: 0)
    }

    /// What a block means to a person: everything but ids, and a table's
    /// cells and shape without row and column ids.
    static func meaning(_ block: NoteBlock) -> String {
        var copy = block
        copy.id = nil
        copy.inlines = copy.inlines.map { NoteInline(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, kind: $0.kind, extras: $0.extras) }
        if var table = copy.table {
            let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            for index in table.columns.indices { table.columns[index].id = zero }
            for row in table.rows.indices {
                table.rows[row].id = zero
                for column in table.rows[row].cells.indices {
                    table.rows[row].cells[column].inlines = table.rows[row].cells[column].inlines.map {
                        NoteInline(id: zero, kind: $0.kind, extras: $0.extras)
                    }
                }
            }
            copy.table = table
        }
        return String(describing: copy)
    }

    static func show(_ block: NoteBlock) -> String {
        switch block.kind {
        case .table:
            let cells = block.table?.rows.map { $0.cells.map { $0.text.debugDescription + ($0.inlines.isEmpty ? "" : "+\($0.inlines.count) objects") } } ?? []
            return "table \(cells)"
        case .text: return "\(block.style ?? "paragraph") \(block.text.debugDescription)" + (block.inlines.isEmpty ? "" : " +\(block.inlines.count) objects")
        case .checklist: return "checklist \(block.text.debugDescription)" + (block.inlines.isEmpty ? "" : " +\(block.inlines.count) objects")
        case .file: return "file \(block.filename.debugDescription)"
        default: return "\(block.kind)"
        }
    }

    /// The first difference between two block lists, or nil.
    static func difference(_ got: [NoteBlock], _ expected: [NoteBlock], meaningOnly: Set<Int> = []) -> String? {
        for index in 0..<max(got.count, expected.count) {
            guard index < got.count else { return "\(show(expected[index])) is gone" }
            guard index < expected.count else { return "an extra \(show(got[index]))" }
            let same = meaningOnly.contains(index) ? meaning(got[index]) == meaning(expected[index]) : got[index] == expected[index]
            if !same {
                if meaning(got[index]) == meaning(expected[index]) { return "\(show(expected[index])) has new ids" }
                return "\(show(expected[index])) became \(show(got[index]))"
            }
        }
        return nil
    }

    static func check(_ result: Result<NoteDocument, Error>, _ expected: NoteDocument, meaningOnly: Set<Int> = []) -> String? {
        switch result {
        case let .failure(error): return "refused: \(error.localizedDescription.prefix(90))"
        case let .success(document): return difference(document.blocks, expected.blocks, meaningOnly: meaningOnly)
        }
    }

    static func legs(_ item: Case) -> [(String, String)] {
        var failures: [(String, String)] = []
        let d = item.document
        let body = NoteTextExport.agentBody(d)
        if let problem = check(parse(title(d), body, base: d), d) { failures.append(("identity", problem)) }
        // Title only.
        var renamed = d
        renamed.blocks[0] = .text("Renamed")
        if let problem = check(parse("Renamed", body, base: d), renamed) { failures.append(("title only", problem)) }
        // Another edit: the tail paragraph; and another cell of a plain table.
        if let tail = d.blocks.firstIndex(of: .text("tail")) {
            var edited = d
            edited.blocks[tail] = .text("tail edited")
            if let problem = check(parse(title(d), NoteTextExport.agentBody(edited), base: d), edited) {
                failures.append(("another paragraph edited", problem))
            }
        }
        // (A table carrying what the text can't show is refused when its
        // text changes: the owner's rule, not a round-trip failure.)
        if item.container == .bodyCell || item.container == .headerCell, let grid = d.blocks[item.block].table,
           !NoteAgentTableText.carriesHidden(d.blocks[item.block]) {
            var edited = d
            var changed = grid
            let other = item.cell! == (0, 0) ? (1, 0) : (0, 0)
            changed.rows[other.0].cells[other.1] = NoteTable.Cell("edited")
            edited.blocks[item.block].table = changed
            if let problem = check(parse(title(d), NoteTextExport.agentBody(edited), base: d), edited, meaningOnly: [item.block]) {
                failures.append(("another cell edited", problem))
            }
        }
        // The block itself, edited through the text. (A line holding a real
        // date is left out: an edited line's dates get new ids, so the edit
        // is refused whatever the literal does.)
        if item.container.editableByText, d.blocks[item.block].inlines.isEmpty {
            // The agent appends to the block's own line, wherever it wraps.
            let edited = d.blocks.enumerated().dropFirst().map { index, block in
                NoteTextExport.bodyLine(NoteTextExport.agentLine(block, index: index) + (index == item.block ? " +" : ""))
            }.joined(separator: "\n")
            var expected = d
            expected.blocks[item.block].text += " +"
            if let problem = check(parse(title(d), edited, base: d), expected, meaningOnly: [item.block]) {
                failures.append(("its own line edited", problem))
            }
        }
        // By id: the cell's text as list_notes gives it, plus more.
        if let cell = item.cell, let grid = d.blocks[item.block].table {
            let listed = NoteTableAgentEdit.serialize(d.blocks[item.block])
            let rows = listed["rows"] as? [[String: Any]] ?? []
            let text = (rows[cell.row]["cells"] as? [String] ?? [])[cell.column]
            var expected = grid
            expected.rows[cell.row].cells[cell.column].text += " +"
            do {
                let result = try NoteTableAgentEdit.apply([["op": "set_cell", "row_id": grid.rows[cell.row].id.uuidString,
                                                            "column_id": grid.columns[cell.column].id.uuidString, "text": text + " +"]], to: grid)
                if result != expected {
                    let got = result.rows[cell.row].cells[cell.column], want = expected.rows[cell.row].cells[cell.column]
                    failures.append(("set_cell", "the cell \(want.text.debugDescription) (\(want.inlines.count) objects) became \(got.text.debugDescription) (\(got.inlines.count) objects)"
                                     + (got.inlines.map(\.id) == want.inlines.map(\.id) || got.inlines.count != want.inlines.count ? "" : ", objects moved or renewed")))
                }
            } catch {
                failures.append(("set_cell", "refused: \(error.localizedDescription.prefix(90))"))
            }
        }
        return failures
    }

    /// A literal and the object it looks like must read differently.
    static func apartFailures() -> [String] {
        let image = NoteBlock.image(attachmentID: UUID())
        let file = NoteBlock.file(attachmentID: UUID(), filename: "f.pdf", contentTypeIdentifier: "com.adobe.pdf", byteCount: 3)
        var dated = NoteBlock.text(String(NoteDocument.objectCharacter))
        dated.inlines = [NoteInline(id: UUID(), kind: .date(day))]
        let pairs: [(String, NoteBlock, NoteBlock)] = [
            ("a date", .text("[date:2026-01-02]"), dated),
            ("a checklist item", .text("- [ ] x"), .checklist("x")),
            ("a ticked item", .text("- [x] x"), .checklist("x", checked: true)),
            ("an image", .text("![image](attic://image/\(image.id!.uuidString))"), image),
            ("a file", .text("[file: f.pdf](attic://file/\(file.id!.uuidString))"), file)
        ]
        var failures: [String] = []
        for (name, literal, object) in pairs where NoteTextExport.agentLine(literal, index: 1) == NoteTextExport.agentLine(object, index: 1) {
            failures.append("apart · paragraph · \(name): its literal text reads the same as the object")
        }
        let real = NoteTable.Cell(String(NoteDocument.objectCharacter), inlines: [NoteInline(id: UUID(), kind: .date(day))])
        let cells: [(String, NoteTable.Cell, NoteTable.Cell)] = [("a date", NoteTable.Cell("[date:2026-01-02]"), real),
                                                              ("a line break", NoteTable.Cell("a<br>b"), NoteTable.Cell("a\nb"))]
        for (name, literal, object) in cells {
            let read: (NoteTable.Cell) -> String = { cell in
                var grid = NoteTable(texts: [["h"], ["x"]]); grid.rows[1].cells[0] = cell
                return NoteTextExport.agentTable(.table(grid, id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!))
            }
            if read(literal) == read(object) { failures.append("apart · cell · \(name): its literal text reads the same as the object") }
        }
        return failures
    }

    /// Every failure, grouped: one line per leg, place and marker, naming
    /// the blocks it came after.
    static func failures(seeds: [UInt64], documentsPerSeed: Int) -> [String] {
        var grouped: [String: [String]] = [:]
        var order: [String] = []
        func record(_ key: String, _ context: String) {
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(context)
        }
        for marker in markers {
            for container in Container.allCases where fits(marker, container) {
                for kind in Before.allCases {
                    let item = makeCase(marker, container, kind)
                    for (leg, problem) in legs(item) {
                        record("\(leg) · \(container) · \(marker.debugDescription) → \(problem)", "\(kind)")
                    }
                }
            }
        }
        for item in objectCases() {
            for (leg, problem) in legs(item) { record("\(leg) · \(item.name) → \(problem)", "") }
        }
        // A note whose body is one empty paragraph.
        let empty = NoteDocument(blocks: [.text("T"), .text("")])
        if let problem = check(parse("T", NoteTextExport.agentBody(empty), base: empty), empty) {
            record("identity · a body of one empty paragraph → \(problem)", "")
        }
        // Seeded notes: several literals and objects in a row.
        for seed in seeds {
            var generator = SplitMix(seed: seed)
            for _ in 0..<documentsPerSeed {
                var blocks = [NoteBlock.text("T")]
                for _ in 0..<generator.next(upTo: 6) + 2 {
                    let marker = markers[generator.next(upTo: markers.count)]
                    var container = Container.allCases[generator.next(upTo: Container.allCases.count)]
                    if !fits(marker, container) { container = .bodyCell }
                    let kind = Before.allCases[generator.next(upTo: Before.allCases.count)]
                    let item = makeCase(marker, container, kind)
                    blocks += item.document.blocks.dropFirst().filter { $0.kind != .opaque }
                }
                let d = NoteDocument(blocks: blocks)
                if let problem = check(parse(title(d), NoteTextExport.agentBody(d), base: d), d) {
                    record("identity · seeded note → \(problem)", "seed \(seed)")
                }
            }
        }
        var lines = order.map { key -> String in
            let contexts = Array(Set(grouped[key] ?? [])).filter { !$0.isEmpty }.sorted()
            return key + (contexts.isEmpty ? "" : "  [" + contexts.joined(separator: ", ") + "]")
        }
        lines += apartFailures()
        return lines
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(upTo bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }
}
