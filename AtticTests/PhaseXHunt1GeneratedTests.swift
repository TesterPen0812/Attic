import AppKit
import XCTest
@testable import Attic

/// Independent semantic oracle: no TextKit attributes, product parsing, or product
/// table mutations are used to calculate expected text, styles or cell contents.
@MainActor
final class PhaseXHunt1GeneratedTests: XCTestCase {
    private struct Line: Equatable {
        var text: String
        var style: String? = nil
        var level: Int? = nil
        var checklist = false
        var checked = false
        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.text.utf16.elementsEqual(rhs.text.utf16) && lhs.style == rhs.style && lhs.level == rhs.level
                && lhs.checklist == rhs.checklist && lhs.checked == rhs.checked
        }
    }
    private struct State: Equatable {
        var lines = [Line(text: "Title"), Line(text: "alpha"), Line(text: "beta")]
        var cells = [["h1", "h2"], ["v1", "v2"]]
        static func == (lhs: State, rhs: State) -> Bool {
            lhs.lines == rhs.lines && lhs.cells.count == rhs.cells.count
                && zip(lhs.cells, rhs.cells).allSatisfy { left, right in
                    left.count == right.count && zip(left, right).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
                }
        }
    }
    private struct Step: CustomStringConvertible {
        let kind: Int
        let a: Int
        let b: Int
        var description: String { "\(kind):\(a):\(b)" }
    }
    private struct RNG {
        var value: UInt64
        mutating func next() -> Int {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Int((value >> 32) & 0x7fff_ffff)
        }
    }
    private struct Mismatch {
        let index: Int
        let expected: State
        let actual: State
    }

    private func read(_ editor: NoteEditorEngine) -> State {
        let document = editor.document()
        return State(lines: document.blocks.filter { $0.kind == .text || $0.kind == .checklist }.map {
            Line(text: $0.text, style: $0.style == "body" ? nil : $0.style,
                 level: $0.level, checklist: $0.kind == .checklist, checked: $0.checked)
        }, cells: document.blocks.first { $0.kind == .table }?.table?.texts ?? [])
    }

    private func replace(_ text: String, _ range: NSRange, with value: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: value)
    }

    /// Operation indices are normalized against the reference, so deletion-based
    /// shrinking still produces legal editor commands without reading actual state.
    private func replay(_ steps: [Step]) -> Mismatch? {
        let table = NoteTable(texts: [["h1", "h2"], ["v1", "v2"]])
        let editor = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
            [.text("Title"), .text("alpha"), .text("beta"), .table(table)]))
        var model = State()
        var undo: [State] = [], redo: [State] = []
        let styles: [NoteParagraphStyle] = [.body, .heading(2), .heading(3), .bullet, .number, .quote, .mono, .checklist]
        for (index, step) in steps.enumerated() {
            let before = model
            var recordsIdentityMove = false
            let lineIndex = 1 + step.a % (model.lines.count - 1)
            let line = model.lines[lineIndex]
            let lineStart = model.lines.prefix(lineIndex).reduce(0) { $0 + ($1.text as NSString).length + ($1.checklist ? 1 : 0) + 1 }
            let rawOffset = step.b % ((line.text as NSString).length + 1)
            let offset = rawOffset < (line.text as NSString).length
                ? (line.text as NSString).rangeOfComposedCharacterSequence(at: rawOffset).location : rawOffset
            let location = lineStart + (line.checklist ? 1 : 0) + offset
            let attachment = editor.objects().compactMap { $0.0 as? NoteTableAttachment }.first!
            switch step.kind {
            case 0: // insert, including composed UTF-16 text
                let text = ["x", "é", "e\u{301}", "👩🏽‍💻"][step.a % 4]
                // Never split a composed character in the reference or the editor.
                let safe = offset < (line.text as NSString).length
                    ? (line.text as NSString).rangeOfComposedCharacterSequence(at: offset).location : offset
                model.lines[lineIndex].text = replace(line.text, NSRange(location: safe, length: 0), with: text)
                _ = editor.performEdit(NSRange(location: lineStart + (line.checklist ? 1 : 0) + safe, length: 0),
                    with: NSAttributedString(string: text, attributes: editor.attributes(forParagraphAt: lineStart)), name: "Insert")
            case 1: // delete one whole composed character
                if offset < (line.text as NSString).length {
                    let range = (line.text as NSString).rangeOfComposedCharacterSequence(at: offset)
                    model.lines[lineIndex].text = replace(line.text, range, with: "")
                    _ = editor.performEdit(NSRange(location: lineStart + (line.checklist ? 1 : 0) + range.location, length: range.length),
                        with: NSAttributedString(), name: "Delete")
                }
            case 2: // styles, lists, Mono and checklist
                let style = styles[step.b % styles.count]
                model.lines[lineIndex].style = style.storageName
                model.lines[lineIndex].level = style.level
                model.lines[lineIndex].checklist = style == .checklist
                model.lines[lineIndex].checked = style == .checklist && line.checklist ? line.checked : false
                // Request real format changes; a repeated style command can
                // legitimately record an attributes-only Undo step.
                if model != before { _ = editor.perform(.paragraph(style), selection: NSRange(location: lineStart, length: 0)) }
            case 3: // checkbox state
                if line.checklist {
                    model.lines[lineIndex].checked.toggle()
                    editor.toggleCheckbox(atLineOf: lineStart)
                }
            case 4: // paste, line-break normalization and split-tail semantics
                let value = step.b % 2 == 0 ? "P" : "P\r\nQ"
                if value == "P" {
                    model.lines[lineIndex].text = replace(line.text, NSRange(location: offset, length: 0), with: value)
                } else {
                    let head = (line.text as NSString).substring(to: offset)
                    let tail = (line.text as NSString).substring(from: offset)
                    model.lines[lineIndex].text = head + "P"
                    model.lines.insert(Line(text: "Q" + tail), at: lineIndex + 1)
                }
                _ = editor.pastePlainText(value, at: NSRange(location: location, length: 0))
            case 5: // table cell edit
                let row = step.a % model.cells.count, column = step.b % model.cells[0].count
                model.cells[row][column] += "c"
                _ = editor.changeTable(attachment, name: "Cell") { $0.rows[row].cells[column].text += "c" }
            case 6: // insert row
                if model.cells.count < 6 {
                    let row = step.a % (model.cells.count + 1)
                    model.cells.insert(Array(repeating: "", count: model.cells[0].count), at: row)
                    _ = editor.addRow(to: attachment, at: row, focusing: 0)
                }
            case 7: // insert column
                if model.cells[0].count < 6 {
                    let column = step.b % (model.cells[0].count + 1)
                    for row in model.cells.indices { model.cells[row].insert("", at: column) }
                    _ = editor.addColumn(to: attachment, at: column, focusingRow: 0)
                }
            case 8: // delete row / column, retaining at least one
                if step.a % 2 == 0 && model.cells.count > 1 {
                    let row = step.b % model.cells.count
                    model.cells.remove(at: row)
                    _ = editor.deleteRow(of: attachment, at: row)
                } else if step.a % 2 == 1 && model.cells[0].count > 1 {
                    let column = step.b % model.cells[0].count
                    for row in model.cells.indices { model.cells[row].remove(at: column) }
                    _ = editor.deleteColumn(of: attachment, at: column)
                }
            case 9:
                if let prior = undo.popLast() { redo.append(model); model = prior }
                _ = editor.history.undo()
            case 10:
                if let next = redo.popLast() { undo.append(model); model = next }
                _ = editor.history.redo()
            case 11: // two edits in a single explicit group
                editor.history.beginGroup()
                for text in ["g", "h"] {
                    let at = lineStart + (line.checklist ? 1 : 0) + (model.lines[lineIndex].text as NSString).length
                    model.lines[lineIndex].text += text
                    _ = editor.performEdit(NSRange(location: at, length: 0),
                        with: NSAttributedString(string: text, attributes: editor.attributes(forParagraphAt: lineStart)), name: "Grouped")
                }
                editor.history.endGroup()
            case 12: // remove a paragraph boundary between ordinary Body lines
                if model.lines.count > 2, lineIndex + 1 < model.lines.count,
                   !line.checklist, line.style == nil,
                   !model.lines[lineIndex + 1].checklist, model.lines[lineIndex + 1].style == nil {
                    model.lines[lineIndex].text += model.lines[lineIndex + 1].text
                    model.lines.remove(at: lineIndex + 1)
                    _ = editor.performEdit(NSRange(location: lineStart + (line.text as NSString).length, length: 1),
                        with: NSAttributedString(), name: "Join")
                }
            case 13: // split a prose paragraph, preserving its style on both sides
                if !line.checklist {
                    var tail = line
                    tail.text = (line.text as NSString).substring(from: offset)
                    model.lines[lineIndex].text = (line.text as NSString).substring(to: offset)
                    model.lines.insert(tail, at: lineIndex + 1)
                    _ = editor.performEdit(NSRange(location: location, length: 0),
                        with: NSAttributedString(string: "\n", attributes: editor.attributes(forParagraphAt: lineStart)), name: "Split")
                }
            case 14: // stable row move
                let source = step.a % model.cells.count, destination = step.b % model.cells.count
                if source != destination {
                    recordsIdentityMove = true
                    let row = model.cells.remove(at: source); model.cells.insert(row, at: destination)
                    _ = editor.moveRow(of: attachment, from: source, to: destination)
                }
            default: // stable column move
                let source = step.a % model.cells[0].count, destination = step.b % model.cells[0].count
                if source != destination {
                    recordsIdentityMove = true
                    for row in model.cells.indices {
                        let cell = model.cells[row].remove(at: source); model.cells[row].insert(cell, at: destination)
                    }
                    _ = editor.moveColumn(of: attachment, from: source, to: destination)
                }
            }
            if step.kind != 9 && step.kind != 10 && (model != before || recordsIdentityMove) { undo.append(before); redo.removeAll() }
            let actual = read(editor)
            if actual != model { return Mismatch(index: index, expected: model, actual: actual) }
        }
        return nil
    }

    /// First cut the suffix after the first mismatch, then repeatedly delete
    /// chunks and single steps until no deletion still reproduces a failure.
    private func shrink(_ original: [Step], mismatch: Mismatch) -> [Step] {
        var result = Array(original.prefix(mismatch.index + 1))
        var chunk = max(1, result.count / 2)
        while chunk >= 1 {
            var start = 0
            while start < result.count {
                var candidate = result
                candidate.removeSubrange(start..<min(start + chunk, result.count))
                if !candidate.isEmpty, let failure = replay(candidate) {
                    result = Array(candidate.prefix(failure.index + 1)); start = 0
                } else { start += chunk }
            }
            if chunk == 1 { break }; chunk = max(1, chunk / 2)
        }
        return result
    }

    func testSeededEditorSequencesAgreeAfterEveryOperation() {
        let long = ProcessInfo.processInfo.environment["ATTIC_PHASEX_LONG"] == "1"
        let count = long ? 20_000 : 3_000
        let length = long ? 120 : 24
        let started = Date()
        for seed in 0..<count {
            if long, seed > 0, seed % 1_000 == 0 {
                print("PHASEX_LONG_PROGRESS sequences=\(seed) seconds=\(Date().timeIntervalSince(started))")
            }
            let failure: (Mismatch, [Step])? = autoreleasepool {
                var rng = RNG(value: UInt64(seed) + 0xA771C)
                let steps = (0..<length).map { _ in Step(kind: rng.next() % 16, a: rng.next(), b: rng.next()) }
                guard let mismatch = replay(steps) else { return nil }
                return (mismatch, shrink(steps, mismatch: mismatch))
            }
            if let (failure, minimal) = failure {
                XCTFail("Seed \(seed), step \(failure.index); minimized=\(minimal); expected=\(failure.expected); actual=\(failure.actual)")
                return
            }
        }
        print("PHASEX_GENERATED sequences=\(count) steps=\(count * length) seconds=\(Date().timeIntervalSince(started))")
    }

    func testMovingIdenticalEmptyColumnsStillRecordsAnUndoStep() {
        // Seed 383 minimized to four steps. The original mismatch was in
        // the reference: equal cell texts do not make a column-ID move a no-op.
        let steps = [Step(kind: 7, a: 0, b: 0), Step(kind: 7, a: 0, b: 0),
                     Step(kind: 15, a: 0, b: 1), Step(kind: 9, a: 0, b: 0)]
        XCTAssertNil(replay(steps))
    }
    /// Generated endpoint checks complement the independent text/style model.
    /// Each seed changes the selection and command order; no window is created.
    func testHunt2GeneratedSelectionUndoAcrossAllEditKinds() throws {
        for seed in 0..<80 {
            try autoreleasepool {
                var rng = RNG(value: UInt64(seed) + 0xF175)
                let editor = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
                    [.text("Title"), .text("abcdefghij"), .text("tail"), .table(NoteTable(texts: [["a", "b"], ["c", "d"]]))]))
                let (scroll, view) = editor.makeView()
                defer { editor.detachView(); withExtendedLifetime(scroll) {} }
                for step in 0..<24 {
                    let body = (editor.textStorage.string as NSString).range(of: "abcdefghij")
                    guard body.location != NSNotFound else { return XCTFail("seed=\(seed) missing body") }
                    let offset = rng.next() % 8
                    let selection = NSRange(location: body.location + offset, length: rng.next() % 3)
                    view.setSelectedRange(selection)
                    let before = editor.document(), tags = editor.tags
                    let generation = editor.history.recordingGeneration
                    let kind = (step + seed) % 19
                    let table = try XCTUnwrap(editor.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
                    switch kind {
                    case 0: view.insertText("XY", replacementRange: selection)
                    case 1: view.deleteBackward(nil)
                    case 2: _ = editor.performEdit(selection, with: NSAttributedString(string: "Z"), name: "Replace", selection: NSRange(location: body.location, length: 2))
                    case 3: _ = editor.perform(.mark(.bold), selection: selection)
                    case 4: _ = editor.perform(.paragraph(.bullet), selection: selection)
                    case 5: _ = editor.perform(.paragraph(.checklist), selection: selection)
                    case 6: editor.setTagsFromPicker(["tag\(seed)"])
                    case 7: _ = editor.insertDate(NoteDay(year: 2026, month: 10, day: 10)!, at: selection)
                    case 8: _ = editor.pastePlainText("P\r\nQ", at: selection)
                    case 9: _ = editor.changeTable(table, name: "Cell") { $0.rows[1].cells[0].text += "X" }
                    case 10: _ = editor.addRow(to: table, at: 1, focusing: 0)
                    case 11: _ = editor.addColumn(to: table, at: 1, focusingRow: 0)
                    case 12: _ = editor.deleteRow(of: table, at: 1)
                    case 13: _ = editor.moveColumn(of: table, from: 0, to: 1)
                    case 14: _ = editor.perform(.divider, selection: selection)
                    case 15: _ = editor.perform(.moveDown, selection: selection)
                    case 16: view.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0), replacementRange: selection); view.unmarkText()
                    case 17:
                        editor.history.beginGroup()
                        view.insertText("g", replacementRange: selection)
                        view.insertText("h", replacementRange: view.selectedRange())
                        editor.history.endGroup()
                    default: _ = editor.perform(.link("https://example.com"), selection: selection)
                    }
                    guard editor.history.recordingGeneration != generation else { continue }
                    let after = editor.document(), afterTags = editor.tags, afterSelection = view.selectedRange()
                    let label = "seed=\(seed) step=\(step) kind=\(kind)"
                    view.setSelectedRange(NSRange(location: 0, length: 0))
                    XCTAssertTrue(editor.history.undo(), label)
                    XCTAssertEqual(editor.document(), before, label)
                    XCTAssertEqual(editor.tags, tags, label)
                    XCTAssertEqual(view.selectedRange(), selection, label)
                    view.setSelectedRange(NSRange(location: 1, length: 0))
                    XCTAssertTrue(editor.history.redo(), label)
                    XCTAssertEqual(editor.document(), after, label)
                    XCTAssertEqual(editor.tags, afterTags, label)
                    XCTAssertEqual(view.selectedRange(), afterSelection, label)
                    // Return to the independent starting note for the next command.
                    XCTAssertTrue(editor.history.undo(), label)
                    editor.history.reset()
                }
            }
        }
    }

    func testHunt2GeneratedMarkdownCellLiteralsAndMarksRoundTrip() throws {
        let tokens = ["plain", " ", "  ", "\t", "|", "\\", "*", "_", "<br>", "&lt;br&gt;", "😀", "e\u{301}", "\n", "[x](y)", "`", "=="]
        for seed in 0..<256 {
            var rng = RNG(value: UInt64(seed) + 0xCA11)
            let text = (0..<6).map { _ in tokens[rng.next() % tokens.count] }.joined()
            var table = NoteTable(texts: [["Header"], [text]])
            if seed % 2 == 0, !text.isEmpty {
                table.rows[1].cells[0].marks = [NoteMark(.bold, offset: 0, length: text.utf16.count)]
            }
            let markdown = NoteTableText.markdown(table, cellText: NoteEditorEngine.markdownCellText)
            let copy = try XCTUnwrap(NoteTableText.parseMarkdown(markdown), "seed=\(seed) \(markdown)")
            XCTAssertEqual(copy.texts, table.texts, "seed=\(seed) \(markdown)")
            XCTAssertEqual(copy.rows[1].cells[0].marks, table.rows[1].cells[0].marks, "seed=\(seed)")
        }
    }

    func testH4_03MarkdownTableEdgeWhitespaceSurvivesEveryExporter() throws {
        for text in [" a ", "\t", "  ", "\ta\t", "\u{00a0}a\u{00a0}", " \n ", " \u{2003}x\t"] {
            let table = NoteTable(texts: [["Header"], [text]])
            let document = NoteDocument(blocks: [.table(table)])
            for markdown in [NoteTableText.markdown(table),
                             NoteTableText.markdown(table, cellText: NoteEditorEngine.markdownCellText),
                             NoteMarkdownExport.markdown(document),
                             NoteTableText.markdown(table) { NoteTableText.plainCellMarkdown($0.displayText) }] {
                let copy = try XCTUnwrap(NoteTableText.parseMarkdown(markdown))
                XCTAssertTrue(copy.texts[1][0].utf16.elementsEqual(text.utf16), "\(text.debugDescription) via \(markdown)")
            }
        }
    }

}
