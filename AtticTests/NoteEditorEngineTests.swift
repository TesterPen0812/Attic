import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import Attic

/// The TextKit 2 engine: editor-owned undo (requirement 4), the object
/// guard for Find and Writing Tools (requirements 3 and 9), stable object
/// identity, IME over a selection, VoiceOver elements.
@MainActor
final class NoteEditorEngineTests: XCTestCase {
    #if !ATTIC_GENERATED_TESTS
    func testB02RichCopyPreservesNumberedListStartsAndRestarts() throws {
        var first = NoteBlock.text("first", style: "number"); first.start = 7
        var restart = NoteBlock.text("restart", style: "number"); restart.start = 12
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), first, .text("second", style: "number"), restart, .text("last", style: "number")]))
        defer { engine.detachView() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        for offset in [2, location(of: "second", in: engine)] {
            XCTAssertTrue(engine.writeSelection(NSRange(location: offset, length: engine.textStorage.length - offset), to: board, types: [.rtf]))
            let data = try XCTUnwrap(board.data(forType: .rtf))
            let copied = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            var starts: [Int] = []
            var previous: NSTextList?
            (copied.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: copied.length), options: .byParagraphs) { _, range, _, _ in
                let list = (copied.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last
                XCTAssertNotNil(list)
                if let list, list !== previous { starts.append(list.startingItemNumber) }
                previous = list
            }
            XCTAssertEqual(starts, offset == 2 ? [7, 12] : [8, 12])
        }
    }

    func testB02InAppCopyContinuesNumbering() async throws {
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("a", style: "number"), .text("b", style: "number"), .text("c", style: "number")]))
        defer { engine.detachView() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(engine.writeSelection(NSRange(location: 2, length: 3), to: board,
                                             types: [NoteEditorEngine.fragmentType, .string, TasksTextExport.markdownType, .rtf]))
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        view.insertNewline(nil)
        let didPaste = await engine.pasteDurably(fragmentData: try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType)), at: view.selectedRange())
        XCTAssertTrue(didPaste)
        XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text), ["a", "b", "c", "a", "b"])
        let pasted = location(of: "c", in: engine) + 2
        XCTAssertEqual(engine.listMarker(at: pasted), .number("4."))
        XCTAssertEqual(engine.listMarker(at: pasted + 2), .number("5."))
        XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.start == nil })
    }

    func testB02InAppCutToReorderContinuesNumbering() async throws {
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("a", style: "number"), .text("b", style: "number"), .text("c", style: "number")]))
        defer { engine.detachView() }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let moved = NSRange(location: location(of: "b", in: engine), length: 2)
        // The cut path writes the same selection before deleting it. A unique
        // board exercises those operations without replacing the user's clipboard.
        XCTAssertTrue(engine.writeSelection(moved, to: board,
                                             types: [NoteEditorEngine.fragmentType, .string, TasksTextExport.markdownType, .rtf]))
        XCTAssertEqual(board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "1. b")
        XCTAssertEqual(board.string(forType: TasksTextExport.markdownType)?.trimmingCharacters(in: .whitespacesAndNewlines), "1. b\n\n<br>")
        view.setSelectedRange(moved)
        view.deleteBackward(nil)
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        view.insertNewline(nil)
        let didPaste = await engine.pasteDurably(fragmentData: try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType)), at: view.selectedRange())
        XCTAssertTrue(didPaste)
        XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text), ["a", "c", "b", ""])
        XCTAssertEqual(engine.listMarker(at: location(of: "b", in: engine)), .number("3."))
        XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.start == nil })
    }

    func testB03PairedInlineHTMLAcrossExternalContinuations() throws {
        for (source, expected, style, mark) in [
            ("<u>first\nsecond</u>", "first second", nil, NoteMark.Kind.underline),
            ("> <u>first\n> second</u>", "first second", "quote", .underline),
            ("- <u>first\n  second</u>", "first second", "bullet", .underline),
            ("<strong>first\nsecond</strong>", "first second", nil, .bold),
            ("> <u>first  \n> second</u>", "first\u{2028}second", "quote", .underline),
            ("> <strong>é **literal**\n> second</strong>", "é **literal** second", "quote", .bold),
            ("> <u>first\r\n> second</u>", "first second", "quote", .underline)
        ] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("Target"), .text("")]))
            defer { engine.detachView() }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString(source, forType: .string)
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            let before = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.handlePaste(board), source)
            let blocks = Array(engine.document().blocks.dropFirst())
            XCTAssertEqual(blocks.map(\.text), [expected], source)
            XCTAssertEqual(blocks.first?.style, style, source)
            XCTAssertEqual(blocks.first?.marks, [NoteMark(mark, offset: 0, length: expected.utf16.count)], source)
            let after = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
        }
    }

    func testB03PairedHTMLKeepsLiteralBackslashBeforeSpaceBreak() throws {
        for (source, expected, paste) in [
            ("<u>a\\  \nb</u>", "a\\\u{2028}b", true),
            ("> <u>a\\  \n> b</u>", "a\\\u{2028}b", true),
            ("<u>a\\\nb</u>", "a\u{2028}b", true),
            ("<u>a\\\\\nb</u>", "a\\\\\nb", false)
        ] {
            let document = try NoteMarkdownImport.document(source, forPaste: paste)
            XCTAssertEqual(document.blocks.map(\.text), [expected], source)
            XCTAssertEqual(document.blocks.first?.marks, [NoteMark(.underline, offset: 0, length: expected.utf16.count)], source)
        }
    }

    func testB03PairedHTMLMultilineLeavesDiscardQuotePrefixes() throws {
        for (content, expected) in [
            ("`a\n> b`", "`a b`"),
            ("<span\n> title=\"x\">a</span>", "<span title=\"x\">a</span>"),
            ("[\n> a](https://example.com)", "[ a](https://example.com)"),
            ("`é\r\n> b`", "`é b`")
        ] {
            let source = "> <u>" + content + "</u>"
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("Target"), .text("")]))
            defer { engine.detachView() }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString(source, forType: .string)
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            let before = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.handlePaste(board), source)
            let blocks = Array(engine.document().blocks.dropFirst())
            XCTAssertEqual(blocks.map(\.text), [expected], source)
            XCTAssertEqual(blocks.first?.style, "quote", source)
            XCTAssertEqual(blocks.first?.marks, [NoteMark(.underline, offset: 0, length: expected.utf16.count)], source)
            let after = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
        }
    }

    func testPRB12InlineMeasurementsReuseWarmCache() throws {
        let style = NoteTextStyle(), renderer = NoteObjectRenderer(design: NoteTextStyle().design)
        let today = NoteDay(date: Date())
        let cells = (0..<300).map { index in
            NoteTable.Cell("Due \u{FFFC} item \(index)", inlines: [NoteInline(id: UUID(), kind: .date(today))])
        }
        let cache = NoteTableTextCache()
        var renders = 0
        func pass() {
            for cell in cells {
                func text() -> NSAttributedString {
                    renders += 1
                    return NoteTextCodec.cellString(cell, attributes: style.tableCellAttributes(header: false), style: style) {
                        renderer.apply(to: $0, today: today)
                    }
                }
                _ = cache.natural(cell, header: false, string: text)
                _ = cache.minimum(cell, header: false, string: text)
                _ = cache.height(cell, header: false, width: 120, string: text)
            }
        }
        pass()
        let coldRenders = renders
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 { pass() }
        print("PRB12_300_DATE_CHIPS_MS_PER_PASS=\((CFAbsoluteTimeGetCurrent() - start) * 1000 / 10)")
        XCTAssertEqual(coldRenders, 900)
        XCTAssertEqual(renders, coldRenders, "warm natural/minimum/height must not render the 300 unchanged date chips again")
        let plainCache = NoteTableTextCache()
        let plain = (0..<300).map { NoteTable.Cell("Due item \($0)") }
        func plainPass() {
            for cell in plain {
                func text() -> NSAttributedString { NSAttributedString(string: cell.text, attributes: style.tableCellAttributes(header: false)) }
                _ = plainCache.natural(cell, header: false, string: text)
                _ = plainCache.minimum(cell, header: false, string: text)
                _ = plainCache.height(cell, header: false, width: 120, string: text)
            }
        }
        plainPass()
        let plainStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 { plainPass() }
        print("PRB12_300_PLAIN_CELLS_MS_PER_PASS=\((CFAbsoluteTimeGetCurrent() - plainStart) * 1000 / 10)")
    }

    func testPRB1TableMeasurementsDistinguishDatePayloadAndPresentation() throws {
        let today = try XCTUnwrap(NoteDay(year: 2026, month: 10, day: 20))
        let later = try XCTUnwrap(NoteDay(year: 2030, month: 12, day: 31))
        let id = UUID(), style = NoteTextStyle()
        let renderer = NoteObjectRenderer(design: style.design)
        func cell(_ day: NoteDay) -> NoteTable.Cell {
            .init("Due \u{FFFC} now", inlines: [NoteInline(id: id, kind: .date(day))])
        }
        func attributed(_ cell: NoteTable.Cell, today: NoteDay) -> NSAttributedString {
            NoteTextCodec.cellString(cell, attributes: style.tableCellAttributes(header: false), style: style) {
                renderer.apply(to: $0, today: today)
            }
        }
        let first = cell(today), second = cell(later)
        let firstText = attributed(first, today: today), secondText = attributed(second, today: today)
        let freshFirst = NoteTableTextCache().natural(first, header: false) { firstText }
        let freshSecond = NoteTableTextCache().natural(second, header: false) { secondText }
        XCTAssertNotEqual(freshFirst, freshSecond, "precondition: the real date chips have different widths")
        let width = CGFloat(try XCTUnwrap((56...152).first { width in
            NoteTableTextCache.measure(firstText, width: CGFloat(width)) != NoteTableTextCache.measure(secondText, width: CGFloat(width))
        }, "precondition: real chips wrap into different native heights"))
        var measurementDate = today.date()
        let shared = NoteTableTextCache(today: { measurementDate })
        _ = shared.natural(first, header: false) { firstText }
        _ = shared.minimum(first, header: false) { firstText }
        _ = shared.height(first, header: false, width: width) { firstText }
        var measurements = 0
        XCTAssertEqual(shared.natural(second, header: false) { measurements += 1; return secondText }, freshSecond)
        XCTAssertEqual(shared.minimum(second, header: false) { measurements += 1; return secondText },
                       NoteTableTextCache().minimum(second, header: false) { secondText })
        let height = NoteTableTextCache.measure(secondText, width: width)
        XCTAssertEqual(shared.height(second, header: false, width: width) { measurements += 1; return secondText }, height)
        XCTAssertEqual(measurements, 3)
        // The same semantic cell changes geometry when its relative-day label changes.
        measurementDate = later.date()
        let changedText = attributed(first, today: later)
        let freshChanged = NoteTableTextCache().natural(first, header: false) { changedText }
        XCTAssertNotEqual(freshChanged, freshFirst)
        XCTAssertEqual(shared.natural(first, header: false) { changedText }, freshChanged)
        measurementDate = today.date()
        var table = NoteTable(texts: [[""], [""]], headerRow: false)
        table[.init(row: 0, column: 0)] = first; table[.init(row: 1, column: 0)] = second
        table.columns[0].width = Double(width + 2 * AtticNoteTableMetrics.cellPaddingH)
        let layout = NoteTableLayout.make(table, viewport: CGFloat(table.columns[0].width!), natural: { position in
            shared.natural(table[position], header: false) { position.row == 0 ? firstText : secondText }
        }, minimum: { position in
            shared.minimum(table[position], header: false) { position.row == 0 ? firstText : secondText }
        }, height: { position, width in
            shared.height(table[position], header: false, width: width) { position.row == 0 ? firstText : secondText }
        })
        XCTAssertGreaterThanOrEqual(layout.rowHeights[1], height + 2 * AtticNoteTableMetrics.cellPaddingV)
    }

    func testPRB1NativeShiftReturnKeepsParagraphTypingMarks() throws {
        var body = NoteBlock.text("ab"); body.marks = [NoteMark(.bold, offset: 0, length: 2)]
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), body]), window: true)
        let window = try XCTUnwrap(view.window)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 3, length: 0))
        for (characters, code, flags) in [("\r", UInt16(36), NSEvent.ModifierFlags.shift), ("x", UInt16(7), [])] {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        XCTAssertEqual(view.string, "T\na\nxb", "AppKit maps Shift-Return to a paragraph break")
        XCTAssertEqual(engine.document().blocks[2].marks, [NoteMark(.bold, offset: 0, length: 2)])
    }

    func testPRB1SoftBreakThroughWindowKeepsActiveMarks() throws {
        for kind in [NoteMark.Kind.bold, .italic, .underline, .strikethrough, .code, .highlight] {
            var body = NoteBlock.text("ab")
            body.marks = [NoteMark(kind, offset: 0, length: 2)]
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), body]), window: true)
            defer { engine.detachView() }
            let window = try XCTUnwrap(view.window)
            XCTAssertTrue(window.makeFirstResponder(view))
            view.setSelectedRange(NSRange(location: 3, length: 0))
            XCTAssertNotNil(view.typingAttributes[.noteMark(kind)])
            let original = engine.document()
            func key(_ value: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
                window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: value,
                    charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)))
            }
            try key("\r", code: 36, flags: .control)
            XCTAssertEqual(view.string, "T\na\u{2028}b", "Control-Return traversed native soft-break interpretation")
            XCTAssertNotNil(view.typingAttributes[.noteMark(kind)], kind.rawValue)
            try key("x", code: 7)
            XCTAssertEqual(engine.document().blocks[1].text, "a\u{2028}xb")
            XCTAssertEqual(engine.document().blocks[1].marks, [NoteMark(kind, offset: 0, length: 4)])
            let typed = engine.document()
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.document().blocks[1].text, "a\u{2028}b")
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), original)
            XCTAssertTrue(engine.history.redo()); XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(engine.document(), typed)
        }
    }

    func testPRB1RestartAtOneKeepsAdjacentNumberedSegmentsSeparate() throws {
        var first = NoteBlock.text("one", style: "number"); first.start = 5
        var second = NoteBlock.text("seven", style: "number"); second.start = 7
        let original = NoteDocument(blocks: [.text("T"), first, second, .text("next", style: "number")], requires: ["structure-v1"])
        let (engine, _) = makeEngine(original)
        let at = location(of: "seven", in: engine)
        XCTAssertEqual(engine.listMarker(at: at), .number("7."))
        XCTAssertTrue(engine.setListStart(1, at: at))
        XCTAssertEqual(engine.listMarker(at: at), .number("1."))
        XCTAssertEqual(engine.listMarker(at: location(of: "next", in: engine)), .number("2."))
        XCTAssertEqual(engine.listMarker(at: 2), .number("5."))
        let restarted = engine.document()
        XCTAssertEqual(restarted.blocks[2].start, 1)
        let saved = try NoteContentCodec.encode(restarted)
        let loaded = try XCTUnwrap(NoteContentCodec.decode(saved).document)
        let reopened = NoteEditorEngine(noteID: UUID(), document: loaded)
        XCTAssertEqual(reopened.listMarker(at: at), .number("1."))
        XCTAssertEqual(reopened.listMarker(at: location(of: "next", in: reopened)), .number("2."))
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), original)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), restarted)
    }

    func testPRB1TypedURLKeepsPunctuationAndWhitespaceOutsideItsMark() throws {
        for suffix in [", ", ". ", "; ", "! ", "? ", ",   "] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: 2, length: 0))
            type("😀 https://example.com" + suffix, view)
            let expected = [NoteMark(.link, offset: 3, length: 19, url: "https://example.com")]
            XCTAssertEqual(engine.document().blocks[1].marks, expected, suffix)
            let saved = try NoteContentCodec.encode(engine.document())
            let reopened = try XCTUnwrap(NoteContentCodec.decode(saved).document)
            XCTAssertEqual(reopened.blocks[1].marks, expected, suffix)
            let beforeUndo = engine.document()
            XCTAssertTrue(engine.history.undo())
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(engine.document(), beforeUndo)
            XCTAssertEqual(engine.document().blocks[1].marks, expected)
        }
    }

    #endif

    // Owner decision 2026-10-16: plain highlights stay yellow, with no saved key.
    #if !ATTIC_GENERATED_TESTS
    func testJPlainHighlightRendersYellowAndDefaultWritesNoColourKey() throws {
        for mode in [AtticDesignContext.Mode.light, .dark] {
            let style = NoteTextStyle(design: AtticDesignContext(mode: mode))
            XCTAssertEqual(style.highlightColor(for: nil), style.highlightColor(for: "yellow"))
            XCTAssertEqual(style.highlightColor(for: true), style.highlightColor(for: "yellow"))
            XCTAssertNotEqual(style.highlightColor(for: "grey"), style.highlightColor(for: "yellow"))
        }
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("body")]))
        defer { engine.detachView() }
        let words = (view.string as NSString).range(of: "body")
        XCTAssertTrue(engine.perform(.mark(.highlight), selection: words))
        let saved = try NoteContentCodec.encode(engine.document())
        let loaded = try XCTUnwrap(NoteContentCodec.decode(saved).document)
        let mark = try XCTUnwrap(loaded.blocks[1].marks.first)
        XCTAssertEqual(mark.kind, .highlight)
        XCTAssertNil(mark.colour)
        XCTAssertEqual(engine.highlightColour(selection: words), .yellow)
    }

    func testG10TypingHighlightHistoryKeepsExactSerializedPayload() throws {
        let values: [Any?] = [nil, true, "future-amber"] + NoteHighlightColour.allCases.compactMap(\.storedKey)
        for before in values {
            for colour in NoteHighlightColour.allCases {
                let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("body")]))
                defer { engine.detachView() }
                view.setSelectedRange(NSRange(location: 6, length: 0))
                view.typingAttributes[.noteMark(.highlight)] = before
                view.typingAttributes[.noteMark(.bold)] = true
                let unchanged = try NoteContentCodec.encode(engine.document())
                XCTAssertTrue(engine.setHighlight(colour))
                let after: Any = colour.storedKey as Any? ?? true
                let changed = !NSDictionary(dictionary: ["value": before ?? NSNull()]).isEqual(to: ["value": after])
                XCTAssertEqual(engine.history.undoOps.count, changed ? 1 : 0, "colour changes need their own step")
                XCTAssertEqual(try NoteContentCodec.encode(engine.document()), unchanged, "a typing mark never rewrites existing text")
                if changed {
                    XCTAssertTrue(engine.history.undo())
                    XCTAssertEqual(NSDictionary(dictionary: ["value": view.typingAttributes[.noteMark(.highlight)] ?? NSNull()]),
                                   NSDictionary(dictionary: ["value": before ?? NSNull()]))
                    XCTAssertTrue(engine.history.redo())
                }
                XCTAssertEqual(NSDictionary(dictionary: ["value": view.typingAttributes[.noteMark(.highlight)] ?? NSNull()]),
                               NSDictionary(dictionary: ["value": after]))
                XCTAssertEqual(view.typingAttributes[.noteMark(.bold)] as? Bool, true)
                type("x", view)
                let saved = try NoteContentCodec.encode(engine.document())
                let loaded = try XCTUnwrap(NoteContentCodec.decode(saved).document)
                let mark = try XCTUnwrap(loaded.blocks[1].marks.first { $0.kind == .highlight })
                XCTAssertEqual(mark.colour, colour.storedKey, "serialized colour after Redo then typing")
                XCTAssertEqual(mark.offset, 4); XCTAssertEqual(mark.length, 1)
            }
        }
        // Undo to a future colour, then type: the unknown stored key stays verbatim.
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("body")]))
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.typingAttributes[.noteMark(.highlight)] = "future-amber"
        XCTAssertTrue(engine.setHighlight(nil)); XCTAssertTrue(engine.history.undo())
        type("x", view)
        let saved = try NoteContentCodec.encode(engine.document())
        let loaded = try XCTUnwrap(NoteContentCodec.decode(saved).document)
        XCTAssertEqual(loaded.blocks[1].marks.first { $0.kind == .highlight }?.colour, "future-amber")
    }

    // Owner decision 2026-10-16: the palette owns a visible input client.
    // Selection notifications and native palette focus handoff do not cancel it.
    func testG05NativePaletteFocusHandoffKeepsTheRequestAndText() throws {
        let (engine, view) = g05Engine()
        defer { engine.detachView() }
        let selection = NSRange(location: 2, length: 3)
        view.setSelectedRange(selection)
        var receiver: NSTextView?
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {
            receiver = view.window?.firstResponder as? NSTextView
            XCTAssertFalse(receiver === view, "the palette must never target the note body")
        })
        let input = try XCTUnwrap(receiver)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: view.window)
        view.setSelectedRange(NSRange(location: 6, length: 0)) // native selection bookkeeping
        input.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document().blocks[1].text, "tip", "a valid pick must not replace selected callout text")
        XCTAssertEqual(engine.document().blocks[1].callout, "🌻")
        XCTAssertEqual(engine.document().blocks[2].text, "body")
        XCTAssertEqual(view.selectedRange(), selection)
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let next = try XCTUnwrap(view.window?.firstResponder as? NSTextView)
        input.insertText("🌹", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.window?.firstResponder === next, "an old delivery cannot cancel a new request")
        XCTAssertFalse(next === input)
        view.window?.makeFirstResponder(view) // explicit keyboard/VoiceOver return
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertText("🌷", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document().blocks[1].callout, "🌻")
        XCTAssertEqual(engine.document().blocks[2].text, "🌷body")
    }

    func testG05CalloutPaletteSelectionExpiresOnCaretChangeAndDismissal() throws {
        for cancellation in ["selection", "dismissal", "focus", "engine", "edit", "identity", "same caret", "right click", "accessibility", "detach", "close", "hide", "read only"] {
            let (engine, view) = g05Engine()
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: 6, length: 0))
            view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
            let input = try XCTUnwrap(view.window?.firstResponder as? NSTextView)
            XCTAssertFalse(input === view)
            var replacement: NoteEditorEngine?
            switch cancellation {
            case "selection":
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: 7, length: 0))
            case "dismissal": input.cancelOperation(nil)
            case "focus": view.window?.makeFirstResponder(view)
            case "accessibility": view.setAccessibilityFocused(true)
            case "engine":
                replacement = NoteEditorEngine(noteID: UUID(), document: engine.document())
                view.engine = replacement
                input.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertEqual(replacement?.document().blocks[1].callout, "💡")
                view.engine = engine
            case "edit":
                XCTAssertTrue(engine.performEdit(NSRange(location: 8, length: 0), with: NSAttributedString(string: "!"), name: "Edit"))
            case "identity":
                engine.textStorage.addAttribute(.noteBlockID, value: UUID(), range: NSRange(location: 2, length: 3))
            case "same caret", "right click":
                let point = view.engine?.caretRect(at: 6)?.origin ?? .zero
                let type: NSEvent.EventType = cancellation == "same caret" ? .leftMouseDown : .rightMouseDown
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: view.window!.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                // Exercise explicit editing intent without entering AppKit's tracking loop.
                _ = view.menu(for: event)
                view.window?.makeFirstResponder(view)
            case "detach": engine.detachView()
            case "close": NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: view.window)
            case "hide": NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: view.window)
            default: view.isEditable = false
            }
            let before = engine.document()
            input.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(engine.document(), before, "a late callback is consumed after " + cancellation)
            XCTAssertEqual(engine.document().blocks[1].callout, "💡", cancellation)
            view.isEditable = true
            view.window?.makeFirstResponder(view)
            let caret = view.selectedRange().location
            if cancellation != "detach" {
                view.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertEqual((view.string as NSString).substring(with: NSRange(location: caret, length: 2)), "🌻", cancellation)
                XCTAssertNotEqual(engine.document(), before, "ordinary text resumes after " + cancellation)
            }
            withExtendedLifetime(replacement) {}
        }
    }

    func testG05ValidCalloutPalettePickIsOneUndoStepAndConsumesOnlyOnce() throws {
        let (engine, view) = g05Engine()
        defer { engine.detachView() }
        let selection = NSRange(location: 2, length: 3)
        view.setSelectedRange(selection)
        let before = engine.document()
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let input = try XCTUnwrap(view.window?.firstResponder as? NSTextView)
        XCTAssertFalse(input === view)
        input.insertText(NSAttributedString(string: "🌻"), replacementRange: NSRange(location: NSNotFound, length: 0))
        let picked = engine.document()
        XCTAssertEqual(picked.blocks[1].text, "tip")
        XCTAssertEqual(picked.blocks[1].callout, "🌻")
        XCTAssertEqual(view.selectedRange(), selection)
        input.insertText("🌹", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document(), picked)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(engine.history.canUndo)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), picked)
        XCTAssertEqual(view.selectedRange(), selection)
        view.insertText("🌷", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(engine.document().blocks[1].text.contains("🌷"))
        XCTAssertEqual(engine.document().blocks[1].callout, "🌻")
    }

    func testG05EmojiPredicateAcceptsCompleteEmojiGraphemesOnly() {
        for emoji in ["🌻", "👍🏽", "👨‍👩‍👧‍👦", "🏳️‍🌈", "🇬🇧", "1️⃣", "©️", "#️⃣", "☀️"] {
            XCTAssertTrue(NoteCalloutIconSession.isSingleEmoji(emoji), emoji)
        }
        for other in ["", "a", "Café", "1", "©", "∑", "🌷🌻", "🏽", "🇬", "🌻\u{301}", "a️", "1️"] {
            XCTAssertFalse(NoteCalloutIconSession.isSingleEmoji(other), other)
        }
    }

    func testG05InvalidAndCurrentIconPicksNeverInsertOrRecordHistory() throws {
        for payload in ["💡", "text", "∑", "🌻🌷", "", "1"] {
            let (engine, view) = g05Engine()
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: 2, length: 3))
            let before = engine.document()
            view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
            let session = try XCTUnwrap(view.calloutIconSession)
            let receiver = session.receiver
            XCTAssertFalse(receiver.textStorage === engine.textStorage)
            receiver.insertText(payload, replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(session.outcome, payload == "💡" ? .unchanged : .invalid)
            XCTAssertEqual(session.state, .ended)
            XCTAssertEqual(engine.document(), before)
            XCTAssertFalse(engine.history.canUndo)
            XCTAssertTrue(view.window?.firstResponder === view)
            receiver.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(engine.document(), before)
        }
    }

    func testG05UnexpectedBodyDeliveryFailsClosedAndCompositionCannotEscape() throws {
        let (engine, view) = g05Engine()
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: 2, length: 3))
        let before = engine.document()
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let session = try XCTUnwrap(view.calloutIconSession)
        view.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document(), before)
        XCTAssertEqual(session.state, .active)
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document(), before)
        XCTAssertFalse(view.hasMarkedText())
        session.receiver.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        session.receiver.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document(), before)
        XCTAssertFalse(engine.history.canUndo)
        XCTAssertNil(view.calloutIconSession)
    }

    func testG05EmptyFinalAndMultiParagraphCalloutsKeepTextAndSelectionThroughReplay() throws {
        for texts in [[""], ["tip", "more", ""]] {
            let blocks = texts.map { text -> NoteBlock in
                var box = NoteBlock.text(text, id: UUID(), style: "quote"); box.callout = "💡"; return box
            }
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T")] + blocks), window: true)
            defer { engine.detachView() }
            let selection = NSRange(location: 2, length: texts.joined(separator: "\n").utf16.count)
            view.setSelectedRange(selection)
            let before = engine.document()
            // Resolve the empty final paragraph through the engine, not storage.length - 1.
            view.pickCalloutIconFromPalette(forBlockAt: engine.textStorage.length, showPalette: {})
            let input = try XCTUnwrap(view.calloutIconSession?.receiver)
            input.insertText(NSAttributedString(string: "1️⃣", attributes: [.foregroundColor: NSColor.red]), replacementRange: NSRange(location: 0, length: 99))
            let after = engine.document()
            XCTAssertEqual(after.blocks.dropFirst().map(\.text), texts)
            XCTAssertTrue(after.blocks.dropFirst().allSatisfy { $0.callout == "1️⃣" })
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertFalse(engine.history.canUndo)
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), after)
            XCTAssertEqual(view.selectedRange(), selection)
        }
    }

    func testG05IconHasItsOwnUndoStepAfterTypingAndReplayExpiresARequest() throws {
        let (engine, view) = g05Engine()
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type("!", view)
        let typed = engine.document()
        let selection = NSRange(location: 2, length: 3)
        view.setSelectedRange(selection)
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        try XCTUnwrap(view.calloutIconSession?.receiver).insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
        let picked = engine.document()
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), typed)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document().blocks[2].text, "body")
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), typed)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), picked)
        XCTAssertEqual(view.selectedRange(), selection)
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let stale = try XCTUnwrap(view.calloutIconSession?.receiver)
        XCTAssertTrue(engine.history.undo())
        stale.insertText("🌹", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document(), typed)
        XCTAssertNil(view.calloutIconSession)
    }

    func testG05FixedIconsNoIconAndAnotherCalloutExpireOldReceivers() throws {
        for icon in NoteCalloutIcons.menu + [""] {
            let (engine, view) = g05Engine()
            defer { engine.detachView() }
            view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
            let stale = try XCTUnwrap(view.calloutIconSession?.receiver)
            let command = try XCTUnwrap(view.calloutIconCommands(forBlockAt: 2).first { $0.title == (icon.isEmpty ? "No Icon" : icon) })
            command.action()
            stale.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(engine.document().blocks[1].callout, icon)
            XCTAssertNil(view.calloutIconSession)
        }
        var first = NoteBlock.text("one", style: "quote"); first.callout = "💡"
        var second = NoteBlock.text("two", style: "quote"); second.callout = "⚠️"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), first, .text("gap"), second]), window: true)
        defer { engine.detachView() }
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let stale = try XCTUnwrap(view.calloutIconSession?.receiver)
        view.pickCalloutIconFromPalette(forBlockAt: 10, showPalette: {})
        let current = try XCTUnwrap(view.calloutIconSession?.receiver)
        stale.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.window?.firstResponder === current)
        current.insertText("🌷", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document().blocks[1].callout, "💡")
        XCTAssertEqual(engine.document().blocks[3].callout, "🌷")
    }

    func testG05DifferentCalloutAtOldOffsetAndNoteIdentityCannotReceiveOldPick() throws {
        for change in ["replacement", "note id", "format"] {
            let (engine, view) = g05Engine()
            defer { engine.detachView() }
            view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
            let stale = try XCTUnwrap(view.calloutIconSession?.receiver)
            switch change {
            case "replacement":
                var other = NoteBlock.text("new", id: UUID(), style: "quote"); other.callout = "⚠️"
                let text = NoteTextCodec.attributedString(from: NoteDocument(blocks: [other]), style: engine.style, firstBlockIsTitle: false)
                XCTAssertTrue(engine.performEdit(NSRange(location: 2, length: 3), with: text, name: "Replace callout"))
            case "note id": engine.noteID = UUID()
            default: XCTAssertTrue(engine.perform(.paragraph(.body), selection: NSRange(location: 2, length: 0)))
            }
            let changed = engine.document()
            stale.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(engine.document(), changed)
            XCTAssertNil(view.calloutIconSession)
        }
    }

    func testG05AppearanceResignAndSelectionBookkeepingKeepSessionButTabExits() throws {
        for backward in [false, true] {
            let (engine, view) = g05Engine()
            defer { engine.detachView() }
            view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
            let session = try XCTUnwrap(view.calloutIconSession)
            // Use NSWindow's responder transition; directly invoking
            // resignFirstResponder violates AppKit's responder transaction.
            view.window?.makeFirstResponder(nil)
            XCTAssertEqual(session.state, .active)
            view.window?.makeFirstResponder(session.receiver)
            view.setSelectedRange(NSRange(location: 6, length: 0))
            engine.update(design: AtticDesignContext(mode: .dark))
            _ = engine.history.canUndo
            _ = engine.history.canRedo
            _ = engine.canUndoCommand
            XCTAssertEqual(session.state, .active, "menu eligibility queries cannot cancel a picker")
            if backward { session.receiver.insertBacktab(nil) } else { session.receiver.insertTab(nil) }
            XCTAssertNil(view.calloutIconSession)
            XCTAssertTrue(view.window?.firstResponder === view)
            XCTAssertFalse(engine.history.canUndo)
            view.insertText("Café", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.string.contains("Café"))
            XCTAssertEqual(engine.document().blocks[1].callout, "💡")
        }
    }

    func testG05HistoryEligibilityKeepsTheInputClientAndCancelReleasesIt() async throws {
        let (engine, view) = g05Engine()
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("!", view)
        weak var releasedSession: NoteCalloutIconSession?
        weak var releasedReceiver: NSTextView?
        let released = XCTestExpectation(description: "AppKit releases the receiver after its deferred text work")
        try autoreleasepool {
            view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
            let session = try XCTUnwrap(view.calloutIconSession)
            releasedSession = session; releasedReceiver = session.receiver
            objc_setAssociatedObject(session.receiver, &Self.calloutReleaseKey, CalloutReceiverReleaseNotice(released: released), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            XCTAssertTrue(engine.history.canUndo)
            XCTAssertTrue(engine.canUndoCommand)
            XCTAssertEqual(session.state, .active)
            XCTAssertTrue(view.window?.firstResponder === session.receiver)
            XCTAssertEqual(session.receiver.accessibilityLabel(), "Callout icon")
            XCTAssertTrue((view.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === session.receiver })
            XCTAssertTrue(session.receiver.accessibilityCancelIcon())
            XCTAssertFalse(session.receiver.accessibilityCancelIcon(), "teardown is idempotent")
            XCTAssertEqual(engine.history.undoOps.count, 1, "Cancel adds no history")
        }
        XCTAssertNil(releasedSession)
        let result = await XCTWaiter.fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(releasedReceiver)
        XCTAssertTrue(view.window?.firstResponder === view)
    }

    func testG05CompleteEmojiPicksReachOnlyTheCallout() throws {
        for emoji in ["🌻", "👍🏽", "👨‍👩‍👧‍👦", "🇬🇧", "1️⃣", "©️"] {
            let (engine, view) = g05Engine()
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: 2, length: 3))
            view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
            let receiver = try XCTUnwrap(view.window?.firstResponder as? NSTextView)
            receiver.insertText(emoji, replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(engine.document().blocks[1].callout, emoji)
            XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "tip", "body"])
            XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 3))
            XCTAssertTrue(engine.history.undo()); XCTAssertFalse(engine.history.canUndo)
        }
    }

    func testG05MovingAnotherCalloutIntoTheOldOffsetCannotTakeThePick() throws {
        var first = NoteBlock.text("one", id: UUID(), style: "quote"); first.callout = "💡"
        var second = NoteBlock.text("two", id: UUID(), style: "quote"); second.callout = "⚠️"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), first, .text("gap"), second]), window: true)
        defer { engine.detachView() }
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let old = try XCTUnwrap(view.calloutIconSession?.receiver)
        XCTAssertTrue(engine.moveBlock(engine.blockRange(at: 10), to: 2))
        let moved = engine.document()
        XCTAssertEqual(moved.blocks[1].id, second.id)
        old.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document(), moved)
        XCTAssertEqual(engine.document().blocks[1].callout, "⚠️")
        XCTAssertNil(view.calloutIconSession)
    }

    func testG05OpeningAPickerCannotDiscardAnExistingNoteComposition() {
        let (engine, view) = g05Engine()
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = engine.document()
        var opened = false
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: { opened = true })
        XCTAssertFalse(opened)
        XCTAssertNil(view.calloutIconSession)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(engine.document(), composing)
        view.insertText("日", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(engine.document().blocks[2].text.contains("日"))
        XCTAssertEqual(engine.document().blocks[1].callout, "💡")
    }
    #endif

    /// An associated notice follows the receiver itself. A view child can
    /// be retained independently by AppKit's accessibility/layout work.
    private static var calloutReleaseKey: UInt8 = 0
    private final class CalloutReceiverReleaseNotice: NSObject {
        let released: XCTestExpectation
        init(released: XCTestExpectation) { self.released = released }
        deinit { released.fulfill() }
    }

    #if !ATTIC_GENERATED_TESTS
    func testG05AutomaticPageFocusRestorationPreservesThePaletteInputClient() throws {
        let (engine, view) = g05Engine()
        defer { engine.detachView() }
        let chrome = NotesPageChrome()
        let accessories = NoteTitleAccessories(engine: engine, textView: view, scrollView: try XCTUnwrap(view.enclosingScrollView),
            chrome: chrome, design: .default, headerBottom: 40, isUntouched: { false }, tagEditor: { AnyView(EmptyView()) })
        view.setSelectedRange(NSRange(location: 2, length: 3))
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let session = try XCTUnwrap(view.calloutIconSession)
        chrome.focusText() // real page presentation/activation restoration boundary
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(view.window?.firstResponder === session.receiver)
        session.receiver.insertText("🌻", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "tip", "body"])
        XCTAssertEqual(engine.document().blocks[1].callout, "🌻")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 3))
        view.pickCalloutIconFromPalette(forBlockAt: 2, showPalette: {})
        let abandoned = try XCTUnwrap(view.calloutIconSession)
        let beforeReturn = engine.document()
        chrome.returnKeyboardToText()
        XCTAssertNil(view.calloutIconSession, "an explicit footer keyboard return leaves icon mode")
        abandoned.receiver.insertText("🌹", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document(), beforeReturn)
        withExtendedLifetime(accessories) {}
    }

    func testFLDetachedEditorsCannotRestoreFocusOverTheirReplacement() throws {
        let (engine, old) = makeEngine(window: true)
        let window = try XCTUnwrap(old.window)
        // Keep the outgoing view attached, as SwiftUI can until dismantle.
        let (scroll, live) = engine.makeView()
        window.contentView?.addSubview(scroll)
        XCTAssertTrue(window.makeFirstResponder(live))
        XCTAssertNil(old.engine)
        old.restoreInputFocus() // the outgoing presentation's queued callback
        XCTAssertTrue(window.firstResponder === live)
        live.restoreInputFocus()
        XCTAssertTrue(window.firstResponder === live, "the live editor can still restore focus")
        engine.detachView()
    }
    #endif

    private func mountFLPresentation(_ session: NoteSession, chrome: NotesPageChrome, in existingWindow: NSWindow? = nil) -> NSWindow {
        let root = NoteEditorRepresentable(session: session, chrome: chrome, columnInset: 20,
                                           topInset: 60, bottomInset: 60, headerBottom: 40,
                                           design: .default, tagEditor: { AnyView(EmptyView()) }, tagCounts: { [:] })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        let window = existingWindow ?? NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if existingWindow == nil {
            window.contentView = NSView(frame: host.frame)
            windows.append(window)
        }
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        return window // No run-loop turn: presentation's queued callback is still pending.
    }

    #if !ATTIC_GENERATED_TESTS
    func testFL3AnUnattachedPresentationDoesNotRetainItsSession() throws {
        weak var releasedSession: NoteSession?
        try autoreleasepool {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = UUID()
            guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Alpha")])) else {
                return XCTFail("seed note")
            }
            let controller = NotesPageController(store: store, journal: nil)
            XCTAssertTrue(controller.open(noteID: id))
            let session = try XCTUnwrap(controller.active)
            releasedSession = session
            let root = NoteEditorRepresentable(session: session, chrome: NotesPageChrome(), columnInset: 20,
                topInset: 60, bottomInset: 60, headerBottom: 40, design: .default,
                tagEditor: { AnyView(EmptyView()) }, tagCounts: { [:] }, scrollOverride: 12)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(session.engine.textView)
            XCTAssertNil(session.engine.textView?.window)
        }
        waitForTestOperation("an abandoned unattached presentation releasing its session") {
            releasedSession == nil
        }
        XCTAssertNil(releasedSession)
    }

    func testFL3PresentationWaitsForActualWindowAttachmentBeforeRestoringFocus() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Alpha")])) else {
            return XCTFail("seed note")
        }
        let controller = NotesPageController(store: store, journal: nil)
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let root = NoteEditorRepresentable(session: session, chrome: NotesPageChrome(), columnInset: 20,
            topInset: 60, bottomInset: 60, headerBottom: 40, design: .default,
            tagEditor: { AnyView(EmptyView()) }, tagCounts: { [:] })
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(session.engine.textView)
        XCTAssertNil(editor.window, "native creation need not coincide with window attachment")
        let end = NSRange(location: 5, length: 0)
        editor.setSelectedRange(end)
        let drained = expectation(description: "early presentation callback drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertNil(editor.window)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let attached = expectation(description: "attachment presentation drained")
        DispatchQueue.main.async { attached.fulfill() }
        wait(for: [attached], timeout: 2)
        XCTAssertTrue(editor.window === window)
        XCTAssertTrue(window.firstResponder === editor, "late attachment must still deliver the opening caret")
        XCTAssertEqual(editor.selectedRange(), end, "attachment preserves a newer live selection")
        let input = try XCTUnwrap(window.firstResponder as? NoteEditorTextView)
        input.insertText(" typed", replacementRange: input.selectedRange())
        XCTAssertEqual(session.engine.plainText, "Alpha typed")
        input.undo(nil)
        XCTAssertEqual(session.engine.plainText, "Alpha")
    }

    func testFL3LateOutgoingAttachmentCannotTakeTheLiveEditorsFocus() throws {
        for reuseSession in [false, true] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let controller = NotesPageController(store: store, journal: nil)
            let ids = [UUID(), UUID()]
            for id in ids {
                guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Alpha")])) else {
                    return XCTFail("seed note")
                }
            }
            XCTAssertTrue(controller.open(noteID: ids[0]))
            let outgoing = try XCTUnwrap(controller.active)
            let chrome = NotesPageChrome()
            let root = NoteEditorRepresentable(session: outgoing, chrome: chrome, columnInset: 20,
                topInset: 60, bottomInset: 60, headerBottom: 40, design: .default,
                tagEditor: { AnyView(EmptyView()) }, tagCounts: { [:] })
            let oldHost = NSHostingView(rootView: root)
            oldHost.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
            oldHost.layoutSubtreeIfNeeded()
            let old = try XCTUnwrap(outgoing.engine.textView)
            XCTAssertNil(old.window)
            if !reuseSession { XCTAssertTrue(controller.open(noteID: ids[1])) }
            let current = try XCTUnwrap(controller.active)
            let window = mountFLPresentation(current, chrome: chrome)
            let live = try XCTUnwrap(current.engine.textView)
            XCTAssertTrue(window.makeFirstResponder(live))
            let selection = NSRange(location: 4, length: 0)
            live.setSelectedRange(selection)
            window.contentView?.addSubview(oldHost)
            let drained = expectation(description: "late outgoing and live presentations drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
            XCTAssertTrue(old.window === window)
            XCTAssertTrue(window.firstResponder === live)
            XCTAssertEqual(live.selectedRange(), selection)
        }
    }

    func testFLPresentationRestoresSavedSelectionBeforeTheEditorCanReceiveInput() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Alpha")]), tags: nil) else {
            return XCTFail("create note")
        }
        let controller = NotesPageController(store: store, journal: nil)
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let saved = NSRange(location: 2, length: 2)
        session.engine.onSelectionChange?(saved)
        let window = mountFLPresentation(session, chrome: NotesPageChrome())
        let editor = try XCTUnwrap(session.engine.textView)
        XCTAssertTrue(editor.window === window)
        XCTAssertEqual(editor.selectedRange(), saved, "saved selection is ready before focus or a run-loop turn")
        XCTAssertTrue(window.makeFirstResponder(editor))
        let drained = expectation(description: "presentation callback drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(editor.selectedRange(), saved)
        XCTAssertEqual(session.selection, saved)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testFLQueuedPresentationCannotResetAnAlreadyFocusedLiveCaret() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Alpha")]), tags: nil) else {
            return XCTFail("create note")
        }
        let controller = NotesPageController(store: store, journal: nil)
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let window = mountFLPresentation(session, chrome: NotesPageChrome())
        let editor = try XCTUnwrap(session.engine.textView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let end = NSRange(location: editor.string.utf16.count, length: 0)
        editor.setSelectedRange(end)
        let drained = expectation(description: "presentation callback drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(editor.selectedRange(), end, "queued geometry/focus work must preserve a newer live caret")
        XCTAssertEqual(session.selection, end)
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText(" typed", replacementRange: editor.selectedRange())
        XCTAssertEqual(session.engine.plainText, "Alpha typed")
    }

    func testFLNewNoteFromSearchKeepsItsDefaultCaretAtTheEndOfTheTitle() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: nil)
        await controller.startAndWait()
        XCTAssertTrue(controller.requestNewNote(title: "Alpha", tags: []))
        let session = try XCTUnwrap(controller.active)
        let end = NSRange(location: 5, length: 0)
        XCTAssertEqual(session.selection, end, "the search-to-new-note rule places the caret after the title")
        let window = mountFLPresentation(session, chrome: NotesPageChrome())
        let editor = try XCTUnwrap(session.engine.textView)
        XCTAssertEqual(editor.selectedRange(), end)
        let drained = expectation(description: "new-note presentation drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(editor.selectedRange(), end)
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText(" typed", replacementRange: editor.selectedRange())
        XCTAssertEqual(session.engine.plainText, "Alpha typed")
    }

    func testFLQueuedOutgoingPresentationsCannotMoveSelectionOrFocus() throws {
        for reuseSession in [false, true] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let controller = NotesPageController(store: store, journal: nil)
            let ids = [UUID(), UUID()]
            for id in ids {
                guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Alpha")]), tags: nil) else {
                    return XCTFail("create note")
                }
            }
            XCTAssertTrue(controller.open(noteID: ids[0]))
            let outgoing = try XCTUnwrap(controller.active)
            let chrome = NotesPageChrome()
            let window = mountFLPresentation(outgoing, chrome: chrome)
            let old = try XCTUnwrap(outgoing.engine.textView)
            if !reuseSession { XCTAssertTrue(controller.open(noteID: ids[1])) }
            let current = try XCTUnwrap(controller.active)
            _ = mountFLPresentation(current, chrome: chrome, in: window)
            let live = try XCTUnwrap(current.engine.textView)
            XCTAssertFalse(old === live)
            // A replaced engine client has been detached from its storage;
            // a different note's outgoing client still has its own text.
            XCTAssertEqual(old.string.utf16.count, reuseSession ? 0 : 5)
            let oldSelection = NSRange(location: reuseSession ? 0 : 1, length: reuseSession ? 0 : 1)
            old.setSelectedRange(oldSelection)
            XCTAssertTrue(window.makeFirstResponder(live))
            let liveSelection = NSRange(location: 4, length: 0)
            live.setSelectedRange(liveSelection)
            let drained = expectation(description: "outgoing and live callbacks drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
            XCTAssertEqual(old.selectedRange(), oldSelection, "outgoing callback cannot change even its own selection")
            XCTAssertEqual(live.selectedRange(), liveSelection)
            XCTAssertTrue(window.firstResponder === live)
        }
    }
    #endif

    private func g05Engine() -> (NoteEditorEngine, NoteEditorTextView) {
        var box = NoteBlock.text("tip", id: UUID(), style: "quote"); box.callout = "💡"
        return makeEngine(NoteDocument(blocks: [.text("T"), box, .text("body")]), window: true)
    }

    #if !ATTIC_GENERATED_TESTS
    func testG07LineSeparatorTokensUseLFLineRulesAndOriginalUTF16Offsets() throws {
        let fixtures = [
            ("javascript", "// 💡 comment\nconst answer = 42;"),
            ("swift", "// comment\nlet answer = 42"),
            ("python", "# comment\nreturn 42"),
            ("sql", "-- comment\nSELECT answer"),
            ("diff", "--- old\n+++ new\n@@ rows\n+added\n-removed"),
            ("yaml", "first\nsecond: 42"),
            ("javascript", "const\nanswer = 42;"),
            ("json", "\"value\"\n: 42")
        ]
        for (language, lf) in fixtures {
            let source = lf.replacingOccurrences(of: "\n", with: "\u{2028}")
            let expected = NoteSyntaxHighlighter.tokens(in: lf, language: language)
            let actual = NoteSyntaxHighlighter.tokens(in: source, language: language)
            XCTAssertEqual(actual.map { $0.0 }, expected.map { $0.0 }, language)
            XCTAssertEqual(actual.map { $0.1 }, expected.map { $0.1 }, language)
        }
        var block = NoteBlock.text("// 💡 comment\u{2028}const answer = 42;", style: "mono")
        block.language = "javascript"
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), block]))
        let before = try NoteContentCodec.encode(engine.document())
        let tokens = engine.codeTokens(in: engine.blockRange(at: 2))
        let keyword = (engine.textStorage.string as NSString).range(of: "const")
        XCTAssertTrue(tokens.contains { $0.0 == keyword && $0.1 == .keyword })
        XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
        XCTAssertTrue(engine.textStorage.string.contains("\u{2028}"))
        XCTAssertFalse(engine.history.canUndo)
    }

    func testG02FootnotePrepassKeepsFencedIndentedAndInlineCodeVerbatim() throws {
        for source in ["```swift\n[^a] \\[^b]\n```", "~~~\n[^a] \\[^b]\n~~~", "    [^a] \\[^b]", "`[^a] \\[^b]`", "``tick ` [^a] \\[^b]``", "> ```\n> [^a] \\[^b]\n> ```"] {
            let first = try XCTUnwrap(NoteMarkdownImport.document(source).blocks.first)
            let expected = source.contains("tick") ? "tick ` [^a] \\[^b]" : "[^a] \\[^b]"
            XCTAssertEqual(first.text, expected, source)
            var document = NoteDocument(blocks: [.text("T"), first])
            for _ in 0..<4 {
                document = try NoteMarkdownImport.document(NoteMarkdownExport.markdown(document))
                XCTAssertEqual(document.blocks[1].text, expected, "code escapes cannot accumulate")
                XCTAssertEqual(document.blocks[1].style, first.style)
                XCTAssertEqual(document.blocks[1].marks, first.marks)
            }
        }
    }

    func testG02FootnoteProseRemainsLiteralWithoutEscapeAccumulation() throws {
        let source = "Reference [^a] and `[^code]`\n\n[^a]: keep definition\n\n    [^indent]"
        var document = try NoteMarkdownImport.document(source)
        XCTAssertEqual(document.blocks.map(\.text), ["Reference [^a] and [^code]", "[^a]: keep definition", "[^indent]"])
        let before = document.blocks
        document.blocks.insert(.text("T"), at: 0)
        for _ in 0..<4 {
            document = try NoteMarkdownImport.document(NoteMarkdownExport.markdown(document))
            XCTAssertEqual(document.blocks.dropFirst().map(\.text), before.map(\.text))
            XCTAssertEqual(document.blocks.dropFirst().map(\.marks), before.map(\.marks))
        }
    }

    func testG03EscapedListAndQuoteMarkersRoundTripAsLiteralText() throws {
        for marker in ["[ ] ", "[x] ", "[X] "] {
            let bullet = NoteBlock.text(marker + "literal marker", style: "bullet")
            var document = NoteDocument(blocks: [.text("T"), bullet])
            for _ in 0..<3 {
                document = try NoteMarkdownImport.document(NoteMarkdownExport.markdown(document))
                XCTAssertEqual(document.blocks[1].text, bullet.text)
                XCTAssertEqual(document.blocks[1].kind, .text)
                XCTAssertEqual(document.blocks[1].style, "bullet")
            }
        }
        for marker in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
            let quote = NoteBlock.text("[!" + marker + "] literal marker", style: "quote")
            let restored = try NoteMarkdownImport.document(NoteMarkdownExport.markdown(NoteDocument(blocks: [.text("T"), quote])))
            XCTAssertEqual(restored.blocks[1].text, quote.text)
            XCTAssertEqual(restored.blocks[1].style, "quote")
            XCTAssertNil(restored.blocks[1].callout)
        }
    }

    func testG03OnlyOriginalUnescapedBlockStartHasStructuralMarkers() throws {
        for source in [#"- \[ ] literal"#, #"- [ \] literal"#, "- **[ ] literal**", "- `[ ] literal`", "- &#91; &#93; literal"] {
            let block = try XCTUnwrap(NoteMarkdownImport.document(source).blocks.first)
            XCTAssertEqual(block.kind, .text, source)
            XCTAssertEqual(block.style, "bullet", source)
            XCTAssertEqual(block.text, "[ ] literal", source)
        }
        for source in [#"> \[!NOTE] literal"#, #"> [\!NOTE] literal"#, "> **[!NOTE] literal**", "> `[!NOTE] literal`", "> &#91;!NOTE&#93; literal", "> first\n>\n> [!NOTE] literal"] {
            let block = try XCTUnwrap(NoteMarkdownImport.document(source).blocks.last)
            XCTAssertNil(block.callout, source)
            XCTAssertEqual(block.text, "[!NOTE] literal", source)
        }
        for marker in ["[ ]", "[x]", "[X]"] {
            let block = try XCTUnwrap(NoteMarkdownImport.document("- " + marker + " task").blocks.first)
            XCTAssertEqual(block.kind, .checklist)
            XCTAssertEqual(block.text, "task")
            XCTAssertEqual(block.checked, marker != "[ ]")
        }
        let alert = try XCTUnwrap(NoteMarkdownImport.document("> [!TIP] tip").blocks.first)
        XCTAssertEqual(alert.text, "tip"); XCTAssertEqual(alert.callout, "💡")
    }

    func testG04CodeExportFlattensDatesWithoutMarksOrMutation() throws {
        let day = NoteDay(year: 2026, month: 10, day: 15)!
        var dated = NoteBlock.text("Due \u{FFFC} **literal** `ticks`", style: "mono")
        dated.language = "swift"
        dated.inlines = [NoteInline(id: UUID(), kind: .date(day))]
        dated.marks = [NoteMark(.bold, offset: 0, length: 3)]
        var second = dated; second.text = "Next \u{FFFC}"; second.marks = []
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), dated, second]))
        defer { engine.detachView() }
        let before = try NoteContentCodec.encode(engine.document())
        let calendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_GB")
        let readable = NoteMarkdownExport.dateText(day, calendar: calendar, locale: locale)
        let exported = NoteMarkdownExport.markdown(engine.document(), calendar: calendar, locale: locale)
        XCTAssertFalse(exported.contains("\u{FFFC}"))
        XCTAssertTrue(exported.contains("Due " + readable + " **literal** `ticks`"))
        XCTAssertTrue(exported.contains("Next " + readable))
        XCTAssertFalse(exported.contains("**Due**"), "stored marks do not become code delimiters")
        XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
        XCTAssertFalse(engine.history.canUndo)
        let imported = try NoteMarkdownImport.document(exported)
        XCTAssertEqual(imported.blocks.dropFirst().map(\.text), ["Due " + readable + " **literal** `ticks`", "Next " + readable])
        XCTAssertEqual(imported.blocks.dropFirst().map(\.style), ["mono", "mono"])
    }

    func testG01ChecklistShorthandKeepsAttributedSuffixAndTrueUndoPayload() throws {
        for prefix in ["[ ] ", "[x] ", "[X] "] {
            let suffix = "Due \u{FFFC} styled tail"
            var bullet = NoteBlock.text(String(prefix.dropLast()) + suffix, id: UUID(), style: "bullet")
            bullet.indent = 1
            bullet.extras = ["future": .string("keep")]
            bullet.inlines = [NoteInline(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 15)!))]
            bullet.marks = [NoteMark(.bold, offset: 3 + 6, length: 11)]
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), bullet]))
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: 5, length: 0))
            view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
            let converted = engine.document()
            var expected = bullet
            expected.kind = .checklist; expected.style = nil; expected.text = suffix
            expected.checked = prefix != "[ ] "
            expected.marks = [NoteMark(.bold, offset: 6, length: 11)]
            XCTAssertEqual(converted.blocks[1], expected, prefix)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
            XCTAssertTrue(engine.history.undo())
            var restored = bullet
            restored.text = prefix + suffix
            restored.marks = [NoteMark(.bold, offset: 4 + 6, length: 11)]
            XCTAssertEqual(engine.document().blocks[1], restored, "one Undo restores the actual bullet before conversion")
            XCTAssertEqual(view.selectedRange(), NSRange(location: 6, length: 0))
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(engine.document(), converted)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        }
    }

    func testFix14MovingLastTextKeepsItsEmptyCodePredecessorAndUndoRedo() {
        var emptyCode = NoteBlock.text("", style: "mono"); emptyCode.language = "swift"
        var heading = NoteBlock.text("Q", style: "heading"); heading.level = 4
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("alpha"), emptyCode, heading]))
        let before = engine.document()
        XCTAssertTrue(engine.moveBlock(engine.blockRange(at: engine.textStorage.length), to: 2))
        let moved = engine.document()
        XCTAssertEqual(moved.blocks.map(\.text), ["T", "Q", "alpha", ""])
        XCTAssertEqual(moved.blocks.last?.language, "swift")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        XCTAssertFalse(engine.history.canUndo)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), moved)
    }

    func testFix14MovingFinalEmptyHeadingKeepsThePrecedingEmptyBodyAndUndoRedo() {
        var heading = NoteBlock.text("", style: "heading"); heading.level = 4
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("alpha"), .text(""), heading]))
        let before = engine.document()
        XCTAssertTrue(engine.moveBlock(engine.blockRange(at: engine.textStorage.length), to: 2))
        let moved = engine.document()
        XCTAssertEqual(moved.blocks.map(\.text), ["T", "", "alpha", ""])
        XCTAssertEqual(moved.blocks.map(\.style), [nil, "heading", nil, nil])
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        XCTAssertFalse(engine.history.canUndo)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), moved)
    }

    func testFix14NumberStartTransferAcrossChildrenUndoAndRedo() {
        var parent = NoteBlock.text("parent", style: "number"); parent.start = 12
        var child = NoteBlock.text("child", style: "number"); child.indent = 1
        var document = NoteDocument(blocks: [.text("T"), parent, child, .text("next", style: "number")])
        document.refreshRequiredCapabilities()
        let (engine, view) = makeEngine(document)
        defer { engine.detachView() }
        view.setSelectedRange(engine.paragraphRange(at: 2)); view.deleteBackward(nil)
        let deleted = engine.document()
        XCTAssertEqual(deleted.blocks.map(\.text), ["T", "child", "next"])
        XCTAssertEqual(deleted.blocks.last?.start, 12)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), document)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), deleted)
    }

    func testFix14LeavingCodeTransfersMissingHintInOneUndoStep() {
        var first = NoteBlock.text("first", style: "mono"); first.language = "swift"
        var document = NoteDocument(blocks: [.text("T"), first, .text("second", style: "mono")])
        document.refreshRequiredCapabilities()
        let (engine, view) = makeEngine(document)
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: 2, length: 0)); view.deleteBackward(nil)
        let lifted = engine.document()
        XCTAssertEqual(lifted.blocks.last?.language, "swift")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), document)
        XCTAssertFalse(engine.history.canUndo)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), lifted)
    }

    func testFix14TerminalCalloutCommandAndSubtreeOutdentUndoTogether() {
        var box = NoteBlock.text("tip", style: "quote"); box.callout = "💡"
        var empty = box; empty.text = ""
        var document = NoteDocument(blocks: [.text("T"), box, empty])
        document.refreshRequiredCapabilities()
        let (engine, _) = makeEngine(document)
        defer { engine.detachView() }
        XCTAssertTrue(engine.setCalloutIcon("⚠️", at: 2))
        let changed = engine.document()
        XCTAssertEqual(changed.blocks.dropFirst().map(\.callout), ["⚠️", "⚠️"])
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), document)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), changed)
        var parent = NoteBlock.text("parent", style: "bullet"); parent.indent = 1
        var child = NoteBlock.text("", style: "bullet"); child.indent = 2
        var list = NoteDocument(blocks: [.text("T"), .text("root", style: "bullet"), parent, child])
        list.refreshRequiredCapabilities()
        let (listEngine, _) = makeEngine(list)
        defer { listEngine.detachView() }
        XCTAssertTrue(listEngine.perform(.outdent, selection: NSRange(location: 7, length: 0)))
        XCTAssertEqual(listEngine.document().blocks.last?.indent, 1)
        XCTAssertTrue(listEngine.history.undo()); XCTAssertEqual(listEngine.document(), list)
        XCTAssertTrue(listEngine.history.redo()); XCTAssertEqual(listEngine.document().blocks.last?.indent, 1)
    }

    func testFix14OrdinarySelectionEndingAtSeparatorExcludesPendingParagraph() {
        var first = NoteBlock.text("first", style: "bullet")
        first.indent = 1
        var document = NoteDocument(blocks: [.text("T"), first, .text("", style: "bullet")])
        document.refreshRequiredCapabilities()
        let engine = NoteEditorEngine(noteID: UUID(), document: document)
        XCTAssertTrue(engine.perform(.paragraph(.heading(4)), selection: engine.paragraphRange(at: 2)))
        XCTAssertEqual(engine.document().blocks.last?.style, "bullet")
    }

    func testR14AdjacentCodeLanguagesKeepSeparateRunsThroughSaveAndMarkdown() throws {
        let markdown = "```\nplain\n```\n```diff\n+added\n-removed\n```"
        let fragment = try NoteMarkdownImport.document(markdown)
        XCTAssertEqual(fragment.blocks.map(\.text), ["plain", "+added", "-removed"])
        XCTAssertEqual(fragment.blocks.map(\.language), [nil, "diff", "diff"])
        let document = NoteDocument(blocks: [.text("T")] + fragment.blocks)
        let bytes = try NoteContentCodec.encode(document)
        let loaded = try XCTUnwrap(NoteContentCodec.decode(bytes).document)
        for doc in [document, loaded] {
            let (engine, _) = makeEngine(doc)
            let diff = location(of: "+added", in: engine)
            XCTAssertEqual(engine.blockRange(at: 2), NSRange(location: 2, length: 6))
            XCTAssertEqual(engine.blockRange(at: diff), NSRange(location: diff, length: 15))
            XCTAssertEqual(engine.monoBlockText(at: 2), "plain")
            XCTAssertEqual(engine.monoBlockText(at: diff), "+added\n-removed")
            XCTAssertNil(engine.codeLanguage(at: 2))
            XCTAssertEqual(engine.codeLanguage(at: diff), "diff")
            let spacing = engine.textStorage.attribute(.paragraphStyle, at: diff, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(spacing?.paragraphSpacingBefore, AtticNoteType.blockMargin)
            XCTAssertEqual(engine.decoration(forParagraphAt: 2), .mono(starts: true, ends: true, exitsAtEnd: false))
            XCTAssertEqual(engine.decoration(forParagraphAt: diff), .mono(starts: true, ends: false, exitsAtEnd: false))
            XCTAssertTrue(engine.codeTokens(in: NSRange(location: 2, length: 1)).isEmpty)
            XCTAssertTrue(engine.codeTokens(in: NSRange(location: diff, length: 1)).contains { $0.1 == .added })
            XCTAssertEqual(try NoteContentCodec.encode(engine.checkpointDocument()), bytes)
            let exported = NoteMarkdownExport.markdown(engine.document())
            XCTAssertEqual(exported, "# T\n\n```\nplain\n```\n\n```diff\n+added\n-removed\n```")
            XCTAssertEqual(try NoteMarkdownImport.document(exported).blocks.map(\.language), [nil, nil, "diff", "diff"])
        }
    }

    func testR14LanguageChangeAndPlainPasteAffectOnlyTheirCodeRunAndUndo() {
        var swift = NoteBlock.text("let a = 1", style: "mono"); swift.language = "swift"
        var diff = NoteBlock.text("+added", style: "mono"); diff.language = "diff"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), swift, swift, diff]))
        let before = engine.document()
        let at = location(of: "+added", in: engine)
        XCTAssertTrue(engine.setCodeLanguage("python", at: at))
        XCTAssertEqual(engine.document().blocks.map(\.language), [nil, "swift", "swift", "python"])
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document().blocks.last?.language, "python")
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertTrue(engine.pastePlainText("\nmore", at: view.selectedRange()))
        XCTAssertEqual(engine.document().blocks.map(\.language), [nil, "swift", "swift", "python", "python"])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.map(\.text), before.blocks.map(\.text))
    }

    func testR14ReturnAtLanguageBoundaryContinuesOnlyTheCurrentRun() {
        var swift = NoteBlock.text("swift", style: "mono"); swift.language = "swift"
        var diff = NoteBlock.text("+diff", style: "mono"); diff.language = "diff"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), swift, diff]))
        let before = engine.document()
        view.setSelectedRange(NSRange(location: 7, length: 0)); view.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.map(\.language), [nil, "swift", "swift", "diff"])
        XCTAssertEqual(engine.monoBlockText(at: 2), "swift\n")
        XCTAssertEqual(engine.codeLanguage(at: location(of: "+diff", in: engine)), "diff")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0)); view.insertNewline(nil)
        XCTAssertEqual(engine.paragraphStyle(at: engine.textStorage.length), .mono(language: "diff"))
        XCTAssertTrue(engine.setCodeLanguage(nil, at: engine.textStorage.length))
        XCTAssertEqual(engine.document().blocks.map(\.language), [nil, "swift", nil, nil])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.map(\.language), [nil, "swift", "diff", "diff"])
    }

    func testR14ReturnOnEmptyCodeLineBeforeAnotherLanguageLeavesOnlyItsRun() {
        var swift = NoteBlock.text("swift", style: "mono"); swift.language = "swift"
        var blank = NoteBlock.text("", style: "mono"); blank.language = "swift"
        var diff = NoteBlock.text("+diff", style: "mono"); diff.language = "diff"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), swift, blank, diff]))
        let before = engine.document()
        view.setSelectedRange(NSRange(location: 8, length: 0)); view.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "swift", "", "+diff"])
        XCTAssertEqual(engine.paragraphStyle(at: 8), .body)
        XCTAssertEqual(engine.document().blocks.last?.language, "diff")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
    }

    func testR14MarkdownPasteKeepsAdjacentFencesAndIsOneUndoStep() throws {
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        let before = engine.document()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let board = NSPasteboard.withUniqueName()
        board.setString("```\nplain\n```\n```diff\n+added\n```", forType: .string)
        XCTAssertTrue(engine.handlePaste(board))
        let pasted = engine.document()
        XCTAssertEqual(engine.monoBlockText(at: 2), "plain")
        XCTAssertEqual(engine.monoBlockText(at: location(of: "+added", in: engine)), "+added")
        XCTAssertEqual(pasted.blocks.map(\.language), [nil, nil, "diff"])
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        XCTAssertFalse(engine.history.canUndo)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document(), pasted)
    }

    func testR14MovingFinalDifferentLanguageDoesNotCarryTheNextEmptyRun() {
        var swift = NoteBlock.text("swift", style: "mono"); swift.language = "swift"
        var empty = NoteBlock.text("", style: "mono"); empty.language = "diff"
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body"), swift, empty]))
        let before = engine.document()
        XCTAssertTrue(engine.moveBlock(engine.blockRange(at: 7), to: 2))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "swift", "Body", ""])
        XCTAssertEqual(engine.document().blocks.last?.language, "diff")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
    }

    func testR14MermaidLabelContentsArePlainAndOutsideKeywordsStillColour() {
        for label in ["[Launch and learn]", "(loop and learn)", "{true or false}", "|and 42 end|", "[\"and [learn]\"]", "([Launch and learn])", "[💡 and learn]", "[Launch\nand learn]"] {
            let source = "flowchart LR\nE" + label + "\nend"
            let text = source as NSString
            let interior = NSRange(location: ("flowchart LR\nE" as NSString).length + 1, length: (label as NSString).length - 2)
            let tokens = NoteSyntaxHighlighter.tokens(in: source, language: "mermaid")
            XCTAssertTrue(tokens.filter { NSIntersectionRange($0.0, interior).length > 0 }.allSatisfy { $0.1 == .plain || (text.substring(with: $0.0).allSatisfy { "[](){}|".contains($0) } && $0.1 == .operator) }, label)
            XCTAssertTrue(tokens.contains { $0.1 == .keyword && text.substring(with: $0.0) == "flowchart" })
            XCTAssertTrue(tokens.contains { $0.1 == .keyword && text.substring(with: $0.0) == "end" })
        }
    }

    func testR14ContractUsesReadableStylesAndSemanticQueries() {
        XCTAssertEqual(NoteParagraphStyle.callout(icon: "💡").storageName, "quote")
        XCTAssertEqual(NoteParagraphStyle.mono(language: "swift").storageName, "mono")
        XCTAssertEqual(NoteParagraphStyle.heading(6).level, 6)
        XCTAssertEqual(NoteFormatCommand.paragraph(.heading(4)).title, "Small Heading")
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("item", style: "bullet")]))
        XCTAssertEqual(engine.listMarker(at: 6), .disc)
        XCTAssertEqual(engine.blockRange(at: 6), NSRange(location: 6, length: 4))
        XCTAssertTrue(engine.codeTokens(in: NSRange(location: 6, length: 4)).isEmpty)
    }

    func testR14StorageFieldsRoundTripAndStayInInt12Extras() throws {
        let raw = Data(#"{"blocks":[{"kind":"text","text":"T"},{"kind":"text","language":"swift","style":"mono","text":"a b"},{"callout":"💡","kind":"text","style":"quote","text":"Tip"},{"kind":"text","start":12,"style":"number","text":"Item"},{"kind":"text","level":6,"style":"heading","text":"Small"}],"format":1,"requires":["structure-v1"]}"#.utf8)
        guard case let .editable(doc) = NoteContentCodec.decode(raw) else { return XCTFail("R14 must remain editable") }
        XCTAssertEqual(doc.blocks[1].language, "swift")
        XCTAssertEqual(doc.blocks[2].callout, "💡")
        XCTAssertEqual(doc.blocks[3].start, 12)
        XCTAssertEqual(doc.blocks[4].level, 6)
        XCTAssertEqual(try NoteContentCodec.encode(doc), raw)
        for block in doc.blocks.dropFirst() {
            XCTAssertTrue(["body", "heading", "bullet", "number", "quote", "mono"].contains(block.style!))
            XCTAssertTrue(Set(block.extras.keys).isSubset(of: ["start", "language", "callout"]))
        }
        let text = NoteTextCodec.attributedString(from: doc, style: NoteTextStyle())
        XCTAssertEqual(NoteTextCodec.document(from: text), doc)
        let restored = NoteEditorEngine(noteID: UUID(), document: doc).checkpointDocument()
        XCTAssertEqual(try NoteContentCodec.encode(restored), raw)
    }

    func testR14Int12FixturesRemainByteIdenticalThroughEngine() throws {
        // Canonical int12 bytes, including explicit defaults and unknown fields.
        let fixtures = [
            #"{"blocks":[{"kind":"text","text":"T"},{"kind":"text","style":"body","text":"Body"}],"format":1}"#,
            #"{"blocks":[{"kind":"text","text":"T"},{"future":true,"kind":"text","level":5,"style":"heading","text":"H"}],"format":1,"requires":["structure-v1"]}"#,
            #"{"blocks":[{"kind":"text","text":"T"},{"indent":2,"kind":"text","style":"number","text":"One"},{"kind":"text","style":"mono","text":"Code"},{"kind":"text","style":"quote","text":"Quote"}],"format":1,"requires":["structure-v1"]}"#
        ]
        for fixture in fixtures {
            let raw = Data(fixture.utf8)
            guard case let .editable(doc) = NoteContentCodec.decode(raw) else { return XCTFail() }
            XCTAssertEqual(try NoteContentCodec.encode(doc), raw)
            let engine = NoteEditorEngine(noteID: UUID(), document: doc)
            XCTAssertEqual(try NoteContentCodec.encode(engine.checkpointDocument()), raw)
        }
    }

    func testR14NumberMarkersUseStartsLettersAndRoman() {
        var first = NoteBlock.text("one", style: "number"); first.start = 12
        var letter = NoteBlock.text("letter", style: "number"); letter.indent = 1
        var roman = NoteBlock.text("roman", style: "number"); roman.indent = 2
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), first, letter, roman, .text("two", style: "number")]))
        XCTAssertEqual(engine.listMarker(at: 2), .number("12."))
        XCTAssertEqual(engine.listMarker(at: location(of: "letter", in: engine)), .letter("a."))
        XCTAssertEqual(engine.listMarker(at: location(of: "roman", in: engine)), .roman("i."))
        XCTAssertEqual(engine.listMarker(at: location(of: "two", in: engine)), .number("13."))
    }

    func testR14EmptyNestedItemsLiftAndIndentCarriesChildren() {
        for name in ["bullet", "number", "quote"] {
            var empty = NoteBlock.text("", style: name); empty.indent = 2
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), empty]))
            view.setSelectedRange(NSRange(location: 2, length: 0)); view.insertNewline(nil)
            XCTAssertEqual(engine.document().blocks[1].indent, 1, name)
            XCTAssertEqual(engine.document().blocks[1].style, name)
        }
        var child = NoteBlock.text("child", style: "bullet"); child.indent = 1
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("first", style: "bullet"), .text("parent", style: "bullet"), child]))
        XCTAssertFalse(engine.perform(.indent, selection: NSRange(location: 2, length: 0)))
        let at = location(of: "parent", in: engine)
        view.setSelectedRange(NSRange(location: at, length: 0))
        XCTAssertTrue(engine.perform(.indent))
        XCTAssertEqual(engine.document().blocks.map(\.indent), [nil, nil, 1, 2])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.last?.indent, 1)
    }

    func testR14NewInputRulesAndBackspaceRestoreLiteral() {
        let rules: [(String, NoteParagraphStyle)] = [("# ", .heading(1)), ("#### ", .heading(4)), ("###### ", .heading(6)), ("+ ", .bullet), ("12. ", .number), ("```js ", .mono(language: "javascript"))]
        for (literal, expected) in rules {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
            view.setSelectedRange(NSRange(location: 2, length: 0)); type(literal, view)
            XCTAssertEqual(engine.paragraphStyle(at: 2), expected, literal)
            if literal == "12. " { XCTAssertEqual(engine.document().blocks[1].start, 12) }
            view.deleteBackward(nil)
            XCTAssertEqual(engine.document().blocks[1].text, literal, literal)
            XCTAssertNil(engine.document().blocks[1].style, literal)
        }
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        view.setSelectedRange(NSRange(location: 2, length: 0)); type("~~gone~~", view)
        XCTAssertEqual(engine.document().blocks[1].marks, [NoteMark(.strikethrough, offset: 0, length: 4)])
    }

    func testR14RunHintsSurviveReturnSplitJoinAndUndo() throws {
        for (style, fields) in [("mono", ["language": NoteJSON.string("swift")]), ("quote", ["callout": .string("💡")]), ("number", ["start": .int(5)])] {
            var block = NoteBlock.text("abcd", style: style); block.extras = fields
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), block]))
            view.setSelectedRange(NSRange(location: 4, length: 0)); view.insertNewline(nil)
            var blocks = engine.document().blocks
            XCTAssertEqual(blocks.map(\.text), ["T", "ab", "cd"], style)
            XCTAssertEqual(blocks[1].extras, fields)
            XCTAssertEqual(blocks[2].language, block.language)
            XCTAssertEqual(blocks[2].callout, block.callout)
            XCTAssertNil(blocks[2].start)
            view.setSelectedRange(NSRange(location: 4, length: 0)); view.deleteForward(nil)
            blocks = engine.document().blocks
            XCTAssertEqual(blocks[1].text, "abcd")
            XCTAssertEqual(blocks[1].extras, fields)
            XCTAssertTrue(engine.history.undo()); XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.document().blocks[1], block)
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0)); view.insertNewline(nil); type("end", view)
            XCTAssertEqual(engine.document().blocks.last?.language, block.language)
            XCTAssertEqual(engine.document().blocks.last?.callout, block.callout)
            XCTAssertNil(engine.document().blocks.last?.start)
        }
    }

    func testR14MarkdownIntentMappingKeepsBlocksMarksAndText() throws {
        let doc = try NoteMarkdownImport.document("###### Small\n\n5. first\n   - nested\n\n- [x] done\n\n> [!TIP]\n> 📌 Advice\n\n```js\nconst x = 4;\n```\n\n---\n\n| Left | Right |\n|:---|---:|\n| **a** | b |\n\n**bold** *italic* ~~strike~~ `code` [link](https://example.com) ![alt](never-fetch)\n\nsoft\nline  \nhard")
        XCTAssertEqual(doc.blocks[0].level, 6)
        XCTAssertEqual(doc.blocks[1].start, 5)
        XCTAssertEqual(doc.blocks[2].indent, 1)
        XCTAssertEqual(doc.blocks[3].kind, .checklist); XCTAssertTrue(doc.blocks[3].checked)
        XCTAssertEqual(doc.blocks[4].callout, "📌"); XCTAssertEqual(doc.blocks[4].text, "Advice")
        XCTAssertEqual(doc.blocks[5].language, "javascript")
        XCTAssertEqual(doc.blocks[6].kind, .divider)
        XCTAssertEqual(doc.blocks[7].table?.columns.map(\.align), [.left, .right])
        XCTAssertEqual(doc.blocks[7].table?.rows[1].cells[0].marks.first?.kind, .bold)
        XCTAssertEqual(Set(doc.blocks[8].marks.map(\.kind)), [.bold, .italic, .strikethrough, .code, .link])
        XCTAssertTrue(doc.blocks[8].text.hasSuffix(" alt"))
        XCTAssertEqual(doc.blocks[9].text, "soft line\u{2028}hard")
        let literals = try NoteMarkdownImport.document("<div>raw</div>\n\nhi[^1]\n\n[^1]: footnote")
        XCTAssertTrue(NoteTextExport.plainText(literals).contains("hi[^1]"))
        XCTAssertTrue(NoteTextExport.plainText(literals).contains("[^1]: footnote"))
        XCTAssertTrue(NoteTextExport.plainText(literals).contains("<div>raw</div>"))
    }

    func testR14MarkdownPasteUsesOnlyPlainBoardAndOneUndoStep() {
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let board = NSPasteboard.withUniqueName(); board.setString("## Heading\n\n**Body**", forType: .string)
        XCTAssertTrue(engine.handlePaste(board))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "Heading", "Body"])
        XCTAssertEqual(engine.history.undoActionName, "Paste")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.textStorage.string, "T\n")
        board.setString("<b>Body</b>", forType: .html)
        XCTAssertFalse(engine.handlePaste(board))
        engine.isPastingAsPlainText = true
        XCTAssertFalse(engine.handlePaste(board)); engine.isPastingAsPlainText = false
        var code = NoteBlock.text("", style: "mono"); code.language = "swift"
        let (codeEngine, codeView) = makeEngine(NoteDocument(blocks: [.text("T"), code]))
        codeView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(codeEngine.handlePaste(board))
        XCTAssertEqual(codeEngine.document().blocks[1].text, "## Heading")
        XCTAssertTrue(codeEngine.document().blocks.dropFirst().allSatisfy { $0.style == "mono" && $0.language == "swift" })
    }

    func testR14LineBreakAndRunCommandsAreUndoable() throws {
        for format: NoteParagraphStyle in [.body, .heading(4), .bullet, .quote, .callout(icon: "💡"), .mono(language: "swift")] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("ab")]))
            XCTAssertTrue(engine.perform(.paragraph(format), selection: NSRange(location: 2, length: 0)))
            view.setSelectedRange(NSRange(location: 3, length: 0))
            view.doCommand(by: #selector(NSTextView.insertLineBreak(_:)))
            XCTAssertEqual(engine.document().blocks[1].text, format.isCode ? "a" : "a\u{2028}b")
            let saved = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(NoteContentCodec.decode(saved).isEditable)
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.document().blocks[1].text, "ab")
        }
        var code = NoteBlock.text("a", style: "mono"); code.language = "swift"
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), code, code]))
        XCTAssertTrue(engine.setCodeLanguage("js", at: 4))
        XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.language == "javascript" })
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.language == "swift" })
        var callout = NoteBlock.text("tip", style: "quote"); callout.callout = "💡"
        let (tip, _) = makeEngine(NoteDocument(blocks: [.text("T"), callout, callout]))
        XCTAssertTrue(tip.setCalloutIcon("⚠️", at: 6))
        XCTAssertTrue(tip.document().blocks.dropFirst().allSatisfy { $0.callout == "⚠️" })
        XCTAssertTrue(tip.history.undo())
        XCTAssertTrue(tip.document().blocks.dropFirst().allSatisfy { $0.callout == "💡" })
    }

    func testR14MarkdownExportRoundTripsCodeCalloutsStartsAndBreaks() throws {
        var code = NoteBlock.text("const n = 4;", style: "mono"); code.language = "javascript"
        var nextCode = NoteBlock.text("``` inside", style: "mono"); nextCode.language = "javascript"
        var tip = NoteBlock.text("Advice\u{2028}Next", style: "quote"); tip.callout = "💡"
        var tip2 = NoteBlock.text("Other paragraph", style: "quote"); tip2.callout = "💡"
        var item = NoteBlock.text("Step\u{2028}Continuation", style: "number"); item.start = 12
        var child = NoteBlock.text("Child", style: "number"); child.indent = 1
        var heading = NoteBlock.text("Small", style: "heading"); heading.level = 6
        let document = NoteDocument(blocks: [.text("T"), code, nextCode, tip, tip2, item, child, .text("Next", style: "number"), heading])
        let markdown = NoteMarkdownExport.markdown(document)
        XCTAssertTrue(markdown.contains("````javascript\nconst n = 4;\n``` inside\n````"))
        XCTAssertTrue(markdown.contains("> [!NOTE]\n> 💡 Advice\\\n> Next\n>\n> Other paragraph"))
        XCTAssertTrue(markdown.contains("12. Step\\\n    Continuation\n    1. Child\n13. Next"))
        XCTAssertTrue(markdown.contains("###### Small"))
        let imported = try NoteMarkdownImport.document(markdown)
        XCTAssertEqual(imported.blocks.map(\.text), document.blocks.map(\.text))
        XCTAssertEqual(imported.blocks[1].language, "javascript")
        XCTAssertEqual(imported.blocks[3].callout, "💡")
        XCTAssertEqual(imported.blocks[5].start, 12)
        XCTAssertEqual(imported.blocks[6].indent, 1)
        XCTAssertEqual(NoteTextExport.plainLine(tip), "💡 Advice\u{2028}Next")
        XCTAssertEqual(NoteTextExport.plainLine(code), "const n = 4;")
    }

    func testR14TokenizerCoversEveryLanguageAndDoesNotChangeStorageOrUndo() throws {
        let samples: [(String, String, NoteSyntaxToken)] = [("javascript", "const x = 1", .keyword), ("typescript", "interface Point {}", .keyword), ("json", "{\"key\":true}", .property), ("swift", "let a = 1 // comment", .comment), ("python", "def f(): return 'hi'", .string), ("shell", "echo hi # comment", .comment), ("html", "<!-- comment -->", .comment), ("css", "color: red;", .property), ("sql", "SELECT count(*) FROM t", .keyword), ("yaml", "name: value", .property), ("diff", "+added\n-removed", .added), ("mermaid", "flowchart LR\nA-->B", .operator)]
        for (language, source, expected) in samples {
            var block = NoteBlock.text(source, style: "mono"); block.language = language
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), block]))
            let bytes = try NoteContentCodec.encode(engine.document())
            let tokens = engine.codeTokens(in: NSRange(location: 2, length: 1))
            XCTAssertTrue(tokens.contains { $0.1 == expected }, language)
            XCTAssertTrue(tokens.allSatisfy { $0.0.location >= 2 && NSMaxRange($0.0) <= engine.textStorage.length })
            XCTAssertEqual(try NoteContentCodec.encode(engine.document()), bytes)
            XCTAssertFalse(engine.history.canUndo)
        }
        XCTAssertTrue(NoteSyntaxHighlighter.tokens(in: "plain", language: nil).isEmpty)
        XCTAssertTrue(NoteSyntaxHighlighter.tokens(in: "unknown", language: "future").isEmpty)
        let tokens = NoteSyntaxHighlighter.tokens(in: "let emoji = \"💡\"", language: "swift")
        let string = try XCTUnwrap(tokens.first { $0.1 == .string })
        XCTAssertEqual(("let emoji = \"💡\"" as NSString).substring(with: string.0), "\"💡\"")
    }

    func testR14SyntaxCostVisitsOnlyTheEditedBlockInALongNote() {
        var code = NoteBlock.text("const x = 4;", style: "mono"); code.language = "javascript"
        let blocks = [.text("T")] + (0..<5000).map { NoteBlock.text("Body \($0) with words") } + [code, .text("End")]
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        let range = (engine.textStorage.string as NSString).range(of: "const x")
        for _ in 0..<40 {
            XCTAssertTrue(engine.performEdit(NSRange(location: range.location + 6, length: 0), with: NSAttributedString(string: "x", attributes: engine.attributes(forParagraphAt: range.location)), name: "Typing"))
            XCTAssertFalse(engine.codeTokens(in: NSRange(location: range.location, length: 1)).isEmpty)
            XCTAssertLessThan(engine.lastSyntaxScannedUTF16Count, 100)
            XCTAssertLessThan(engine.lastUpkeepMilliseconds, 5, "existing Notes upkeep budget")
        }
        print("R14_SYNTAX_COST note_blocks=5003 scanned_utf16=\(engine.lastSyntaxScannedUTF16Count) upkeep_ms=\(engine.lastUpkeepMilliseconds)")
    }

    func testR14BlockMoveCarriesChildrenAndRunsAndUndoesInOneStep() throws {
        var child = NoteBlock.text("child", style: "bullet"); child.indent = 1
        var callout = NoteBlock.text("tip", style: "quote"); callout.callout = "💡"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("parent", style: "bullet"), child, .text("Body"), callout, callout]))
        let before = engine.document()
        let parent = engine.blockRange(at: 2)
        XCTAssertEqual((engine.textStorage.string as NSString).substring(with: parent), "parent\nchild\n")
        let box = engine.blockRange(at: location(of: "tip", in: engine))
        XCTAssertEqual((engine.textStorage.string as NSString).substring(with: box), "tip\ntip")
        view.setSelectedRange(parent)
        XCTAssertTrue(engine.moveBlock(parent, to: engine.textStorage.length))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "Body", "tip", "tip", "parent", "child"])
        XCTAssertEqual(engine.history.undoActionName, "Move Block")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document().blocks.last?.indent, 1)
        XCTAssertFalse(engine.moveBlock(engine.blockRange(at: 0), to: engine.textStorage.length))
    }

    func testR14NumberStartTransfersWhenFirstItemMovesOrIsDeleted() {
        var first = NoteBlock.text("one", style: "number"); first.start = 12
        let doc = NoteDocument(blocks: [.text("T"), first, .text("two", style: "number"), .text("three", style: "number")])
        let (engine, view) = makeEngine(doc)
        let range = engine.blockRange(at: 2)
        XCTAssertTrue(engine.moveBlock(range, to: engine.textStorage.length))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "two", "three", "one"])
        XCTAssertEqual(engine.document().blocks[1].start, 12)
        XCTAssertNil(engine.document().blocks[3].start)
        XCTAssertEqual(engine.listMarker(at: location(of: "one", in: engine)), .number("14."))
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document().blocks, doc.blocks)
        view.setSelectedRange(range); view.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks[1].text, "two")
        XCTAssertEqual(engine.document().blocks[1].start, 12)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document().blocks, doc.blocks)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document().blocks[1].start, 12)
    }

    func testR14BlockDropPositionsRejectInteriorsAndAdjustListDepth() {
        var nested = NoteBlock.text("nested", style: "bullet"); nested.indent = 1
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("root", style: "bullet"), nested, .text("move", style: "bullet")]))
        let moving = engine.blockRange(at: location(of: "move", in: engine))
        XCTAssertFalse(engine.moveBlock(moving, to: 3))
        let drop = engine.blockDropPosition(at: location(of: "nested", in: engine), after: true)
        XCTAssertEqual(drop?.depth, 1)
        XCTAssertTrue(engine.moveBlock(moving, to: location(of: "nested", in: engine)))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "root", "move", "nested"])
        XCTAssertEqual(engine.document().blocks[2].indent, nil)
    }

    func testR14ContainerInteriorBackspaceJoinsAndFinalCodeBreakCarriesLanguage() {
        for format: NoteParagraphStyle in [.quote, .callout(icon: "💡"), .mono(language: "swift")] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("a"), .text("b")]))
            XCTAssertTrue(engine.perform(.paragraph(format), selection: NSRange(location: 2, length: 3)))
            view.setSelectedRange(NSRange(location: 4, length: 0)); view.deleteBackward(nil)
            XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "ab"], "\(format)")
            XCTAssertEqual(engine.paragraphStyle(at: 2), format)
        }
        var code = NoteBlock.text("a", style: "mono"); code.language = "swift"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), code]))
        view.setSelectedRange(NSRange(location: 3, length: 0)); view.doCommand(by: #selector(NSTextView.insertLineBreak(_:)))
        XCTAssertEqual(engine.document().blocks.last?.style, "mono")
        XCTAssertEqual(engine.document().blocks.last?.language, "swift")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document().blocks, [.text("T"), code])
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(engine.pastePlainText("\nx\n", at: view.selectedRange()))
        XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.style == "mono" && $0.language == "swift" })
    }

    func testR14ContinueAndRestartNumberingUseTheFirstItemOfTheRun() {
        var first = NoteBlock.text("one", style: "number"); first.start = 5
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), first, .text("two", style: "number"), .text("gap"), .text("three", style: "number"), .text("four", style: "number")]))
        XCTAssertTrue(engine.continueNumbering(at: location(of: "four", in: engine)))
        XCTAssertEqual(engine.document().blocks[4].start, 7)
        XCTAssertNil(engine.document().blocks[5].start)
        XCTAssertTrue(engine.setListStart(1, at: location(of: "four", in: engine)))
        XCTAssertNil(engine.document().blocks[4].start)
        XCTAssertEqual(engine.listMarker(at: location(of: "four", in: engine)), .number("2."))
    }

    func testR14NewSlashVocabularyIncludesWorkingDiagramTemplate() {
        XCTAssertEqual(NoteSlashItem.Kind.mono, .codeBlock)
        for kind: NoteSlashItem.Kind in [.smallHeading, .callout, .codeBlock, .diagram] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
            view.setSelectedRange(NSRange(location: 2, length: 0)); type("/", view)
            XCTAssertTrue(engine.slashSession?.items.contains { $0.kind == kind } == true)
            XCTAssertTrue(engine.acceptSlashItem(kind))
            if kind == .diagram {
                XCTAssertEqual(engine.document().blocks.dropFirst().count, 3)
                XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.language == "mermaid" })
                XCTAssertTrue(engine.document().blocks[1].text.hasPrefix("flowchart LR"))
            }
        }
    }

    func testR14MarkdownInsideCalloutAndNestedQuoteKeepsTextAsParagraphs() throws {
        var callout = NoteBlock.text("", style: "quote"); callout.callout = "💡"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), callout]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let board = NSPasteboard.withUniqueName(); board.setString("- item\n\n```swift\nlet x = 1\n```", forType: .string)
        XCTAssertTrue(engine.handlePaste(board))
        XCTAssertTrue(engine.document().blocks.dropFirst().allSatisfy { $0.style == "quote" && $0.callout == "💡" })
        XCTAssertEqual(engine.document().blocks[1].text, "• item")
        let imported = try NoteMarkdownImport.document("> [!TIP]\n>\n> Advice\n>\n> - [x] done\n>\n> ```js\n> const x = 1;\n> ```")
        XCTAssertEqual(imported.blocks.map(\.text), ["Advice", "• [x] done", "const x = 1;"])
        XCTAssertTrue(imported.blocks.allSatisfy { $0.callout == "💡" && $0.style == "quote" })
    }

    func testR14MarkdownEmptyTasksAndRawHTMLKeepParagraphBoundaries() throws {
        let document = try NoteMarkdownImport.document("- [ ]\n- [x]\n\n<div>\nraw\n</div>\n\n```swift\na\n\nb\n```")
        XCTAssertEqual(document.blocks[0].kind, .checklist)
        XCTAssertEqual(document.blocks[1].kind, .checklist)
        XCTAssertFalse(document.blocks[0].checked); XCTAssertTrue(document.blocks[1].checked)
        XCTAssertEqual(document.blocks[0].text, "")
        XCTAssertEqual(document.blocks[1].text, "")
        XCTAssertFalse(document.blocks.contains { $0.text.contains("\n") })
        XCTAssertEqual(document.blocks.suffix(3).map(\.text), ["a", "", "b"])
        let attributed = NoteTextCodec.attributedString(from: document, style: NoteTextStyle(), firstBlockIsTitle: false)
        XCTAssertEqual(NoteTextCodec.document(from: attributed, firstBlockIsTitle: false).blocks.map(\.text), document.blocks.map(\.text))
    }

    func testR14NativeListTabAndTerminalArrowRespectEngineRules() {
        let (list, listView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("first", style: "bullet")]))
        listView.setSelectedRange(NSRange(location: 2, length: 0))
        listView.doCommand(by: #selector(NSTextView.insertTab(_:)))
        XCTAssertEqual(list.textStorage.string, "T\nfirst")
        XCTAssertNil(list.document().blocks[1].indent)
        var callout = NoteBlock.text("tip", style: "quote"); callout.callout = "💡"
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), callout]))
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        view.doCommand(by: #selector(NSTextView.moveDown(_:)))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "tip", ""])
        XCTAssertEqual(engine.paragraphStyle(at: engine.textStorage.length), .body)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document().blocks, [.text("T"), callout])
    }

    func testR14NewParagraphKindsHaveBodyPlaceholders() {
        var heading = NoteBlock.text("Small", style: "heading"); heading.level = 4
        var tip = NoteBlock.text("Tip", style: "quote"); tip.callout = "💡"
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), heading, tip]))
        XCTAssertEqual(engine.paragraphKind(at: 2), .smallHeading)
        XCTAssertEqual(engine.paragraphKind(at: 8), .callout(icon: "💡"))
        XCTAssertEqual((engine.attributes(forParagraphAt: 2)[.font] as? NSFont)?.pointSize, engine.style.bodyFont.pointSize)
        XCTAssertEqual((engine.attributes(forParagraphAt: 8)[.font] as? NSFont)?.pointSize, engine.style.bodyFont.pointSize)
        // R14 visible pass: the callout draws its box and icon.
        XCTAssertEqual(engine.decoration(forParagraphAt: 8), .callout(icon: "💡", starts: true, ends: true, exitsAtEnd: false))
    }

    func testR14BackspaceImmediatelyAfterInlineRuleRestoresTypedText() {
        for literal in ["**bold**", "*italic*", "_italic_", "`code`", "~~strike~~"] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
            view.setSelectedRange(NSRange(location: 2, length: 0)); type(literal, view)
            XCTAssertFalse(engine.document().blocks[1].marks.isEmpty)
            view.deleteBackward(nil)
            XCTAssertEqual(engine.document().blocks[1].text, literal)
            XCTAssertTrue(engine.document().blocks[1].marks.isEmpty)
        }
    }

    func testR14ParagraphInputRulesDoNotReplaceStyledLines() {
        for format: NoteParagraphStyle in [.heading(2), .quote, .callout(icon: "💡"), .bullet] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
            XCTAssertTrue(engine.perform(.paragraph(format), selection: NSRange(location: 2, length: 0)))
            view.setSelectedRange(NSRange(location: 2, length: 0)); type("# ", view)
            XCTAssertEqual(engine.paragraphStyle(at: 2), format)
            XCTAssertEqual(engine.document().blocks[1].text, "# ")
        }
    }

    func testR14PlainCodeAfterNamedLanguageKeepsReturnAndPastePlain() {
        var first = NoteBlock.text("first", style: "mono"); first.language = "swift"
        // R14 follow-up: an absent hint is Plain text, not an inherited language.
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), first, .text("old edit", style: "mono")]))
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0)); view.insertNewline(nil)
        XCTAssertNil(engine.document().blocks.last?.language)
        type("next", view)
        XCTAssertNil(engine.document().blocks.last?.language)
        XCTAssertTrue(engine.pastePlainText("\npasted", at: view.selectedRange()))
        XCTAssertNil(engine.document().blocks.last?.language)
    }

    func testR14BlockMovesKeepEmptyHeadingAndFinalEmptyCodeParagraph() {
        var emptyHeading = NoteBlock.text("", id: UUID(), style: "heading"); emptyHeading.level = 4
        let (heading, _) = makeEngine(NoteDocument(blocks: [.text("T"), emptyHeading, .text("Body")]))
        let original = heading.document()
        XCTAssertTrue(heading.moveBlock(heading.blockRange(at: 2), to: heading.textStorage.length))
        XCTAssertEqual(heading.document().blocks.last, emptyHeading)
        XCTAssertTrue(heading.history.undo()); XCTAssertEqual(heading.document(), original)
        var code = NoteBlock.text("a", style: "mono"); code.language = "swift"
        var blankCode = NoteBlock.text("", style: "mono"); blankCode.language = "swift"
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body"), code, blankCode]))
        let before = engine.document()
        XCTAssertTrue(engine.moveBlock(engine.blockRange(at: 7), to: 2))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "a", "", "Body"])
        XCTAssertEqual(engine.document().blocks[2].language, "swift")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "a", "", "Body"])
    }

    func testR14AnEmptyFinalCodeBlockCanMoveBeforeBody() {
        var code = NoteBlock.text("", style: "mono"); code.language = "swift"
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body"), code]))
        let before = engine.document()
        XCTAssertTrue(engine.moveBlock(engine.blockRange(at: engine.textStorage.length), to: 2))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "", "Body"])
        XCTAssertEqual(engine.document().blocks[1].language, "swift")
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), before)
    }

    func testR14SyntaxCacheKeepsUneditedBlocksWarmWhenBodyOffsetsMove() {
        var swift = NoteBlock.text("let x = 1", style: "mono"); swift.language = "swift"
        var javascript = NoteBlock.text("const y = 2", style: "mono"); javascript.language = "javascript"
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("Body"), swift, .text("Gap"), javascript]))
        let first = (engine.textStorage.string as NSString).range(of: "let x")
        let second = (engine.textStorage.string as NSString).range(of: "const y")
        let before = engine.codeTokens(in: first)
        _ = engine.codeTokens(in: second)
        _ = engine.codeTokens(in: first)
        XCTAssertEqual(engine.lastSyntaxScannedUTF16Count, 0, "another visible block must not evict this block on every frame")
        XCTAssertTrue(engine.performEdit(NSRange(location: 2, length: 0), with: NSAttributedString(string: "X"), name: "Edit Body"))
        let shifted = (engine.textStorage.string as NSString).range(of: "let x")
        let after = engine.codeTokens(in: shifted)
        XCTAssertEqual(engine.lastSyntaxScannedUTF16Count, 0, "body typing only rebases cached token offsets")
        XCTAssertEqual(after.map { $0.0.location }, before.map { $0.0.location + 1 })
        XCTAssertEqual(after.map { $0.1 }, before.map { $0.1 })
        XCTAssertEqual(engine.history.undoActionName, "Edit Body")
    }

    func testR14PunctuationIsPlainExceptMermaidOperators() {
        let tokens = NoteSyntaxHighlighter.tokens(in: "const x = { a: 1 };", language: "javascript")
        XCTAssertFalse(tokens.contains { $0.1 == .operator })
        XCTAssertTrue(NoteSyntaxHighlighter.tokens(in: "A-->B", language: "mermaid").contains { $0.1 == .operator })
    }

    func testR14QuotedAndDestinationCalloutTasksAreCanonicalTextBlocks() throws {
        let quoted = try NoteMarkdownImport.document("> [!TIP]\n> - [x] **done**")
        let destination = NoteMarkdownImport.calloutParagraphs(try NoteMarkdownImport.document("- [x] **done**").blocks, icon: "💡")
        for blocks in [quoted.blocks, destination] {
            XCTAssertTrue(blocks.allSatisfy { $0.kind == .text && !$0.checked })
            let bytes = try NoteContentCodec.encode(NoteDocument(blocks: blocks), context: .fragment)
            XCTAssertEqual(NoteContentCodec.decode(bytes, context: .fragment).document?.blocks, blocks)
        }
    }

    func testR14IndentedMarkdownPasteAndCodePlainURLs() throws {
        XCTAssertTrue(NoteMarkdownImport.shouldImport("    print(1)"))
        XCTAssertEqual(try NoteMarkdownImport.document("    print(1)").blocks.first?.style, "mono")
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("", style: "mono")]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(engine.pastePlainText("https://example.com", at: view.selectedRange()))
        XCTAssertTrue(engine.document().blocks[1].marks.isEmpty, "plain code paste never adds semantic links")
    }

    func testR14EmptyCalloutMarkdownRoundTripKeepsItsIcon() throws {
        for icon in ["", "💡"] {
            var box = NoteBlock.text("", style: "quote"); box.callout = icon
            let exported = NoteMarkdownExport.markdown(NoteDocument(blocks: [.text("T"), box]))
            let imported = try NoteMarkdownImport.document(exported)
            XCTAssertEqual(imported.blocks.last?.style, "quote")
            XCTAssertEqual(imported.blocks.last?.callout, icon)
            XCTAssertEqual(imported.blocks.last?.text, "")
        }
    }

    func testR14NumberAndLanguageShortcutsAtStartKeepExistingTail() {
        for (literal, expected): (String, NoteParagraphStyle) in [("12. ", .number), ("```js ", .mono(language: "javascript"))] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Tail")]))
            view.setSelectedRange(NSRange(location: 2, length: 0)); type(literal, view)
            XCTAssertEqual(engine.paragraphStyle(at: 2), expected)
            XCTAssertEqual(engine.document().blocks[1].text, "Tail")
            view.deleteBackward(nil)
            XCTAssertEqual(engine.document().blocks[1].text, literal + "Tail")
        }
    }
    #endif

    private let checklistID = UUID()
    private let dateID = UUID()
    private let imageID = UUID()
    private let attachmentID = UUID()

    private func sample() -> NoteDocument {
        var dated = NoteBlock.text("Due \u{FFFC} for sure")
        dated.inlines = [NoteInline(id: dateID, kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        return NoteDocument(blocks: [
            .text("Title"),
            .text("Hello world"),
            .checklist("Buy cake", id: checklistID),
            dated,
            .image(id: imageID, attachmentID: attachmentID, pixelWidth: 800, pixelHeight: 400),
            .text("End")
        ])
    }

    #if !ATTIC_GENERATED_TESTS
    func testFX2WindowResignationEndsTypingEvenWhenEditorStaysFirstResponder() throws {
        try checkFX2TypingBoundary { _, view in
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: view.window)
        }
    }

    func testFX2AppDeactivationEndsTypingEvenWhenEditorStaysFirstResponder() throws {
        try checkFX2TypingBoundary { _, _ in
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        }
    }

    func testFX2ResponderDepartureEndsTyping() throws {
        try checkFX2TypingBoundary { _, view in
            XCTAssertTrue(view.window!.makeFirstResponder(nil))
            XCTAssertTrue(view.window!.makeFirstResponder(view))
        }
    }

    func testFX2HiddenEditorEndsTyping() throws {
        try checkFX2TypingBoundary { _, view in
            view.isHidden = true
            view.isHidden = false
        }
    }

    func testFX2WindowDetachmentEndsTyping() throws {
        try checkFX2TypingBoundary { _, view in
            let window = view.window!
            let scroll = view.enclosingScrollView!
            window.contentView = nil
            window.contentView = scroll
            XCTAssertTrue(window.makeFirstResponder(view))
        }
    }

    func testFX2CaretReturnEndsTypingInsideTheOpenStep() throws {
        try checkFX2TypingBoundary { _, view in
            let end = view.selectedRange()
            view.moveLeft(nil)
            XCTAssertEqual(view.selectedRange().location, end.location - 1)
            view.moveRight(nil)
            XCTAssertEqual(view.selectedRange(), end)
        }
    }

    func testFX2NativeArrowKeyReturnEndsTypingInsideTheOpenStep() throws {
        try checkFX2TypingBoundary { _, view in
            let end = view.selectedRange()
            for (code, characters) in [(UInt16(123), "\u{F702}"), (UInt16(124), "\u{F703}")] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                view.keyDown(with: event)
            }
            XCTAssertEqual(view.selectedRange(), end)
        }
    }

    func testFX2OtherWindowNotificationDoesNotSplitContinuousTyping() throws {
        let (engine, view) = makeEngine(NoteDocument(blocks: []), window: true)
        defer { engine.detachView() }
        type("before", view)
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        type("after", view)
        XCTAssertEqual(engine.history.undoOps.count, 1)
        view.undo(nil)
        XCTAssertEqual(engine.plainText, "")
    }
    #endif

    private func checkFX2TypingBoundary(_ depart: (NoteEditorEngine, NoteEditorTextView) throws -> Void) throws {
        let (engine, view) = makeEngine(NoteDocument(blocks: []), window: true)
        defer { engine.detachView() }
        XCTAssertTrue(view.window!.makeFirstResponder(view))
        for character in "Focus trial" { type(String(character), view) }
        view.insertNewline(nil)
        for character in "Earlier body" { type(String(character), view) }
        let earlier = engine.plainText
        XCTAssertEqual(earlier, "Focus trial\nEarlier body")
        XCTAssertEqual(engine.history.undoOps.count, 1)
        try depart(engine, view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        for character in " later" { type(String(character), view) }
        let latest = engine.plainText
        view.undo(nil)
        XCTAssertEqual(engine.plainText, earlier, "first Undo preserves title and the earlier run")
        view.undo(nil)
        XCTAssertEqual(engine.plainText, "")
        view.redo(nil)
        XCTAssertEqual(engine.plainText, earlier)
        view.redo(nil)
        XCTAssertEqual(engine.plainText, latest)
    }

    private func makeEngine(_ document: NoteDocument? = nil, window: Bool = false, staged: [StagedNoteAttachment] = []) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: document ?? sample(), stagedAttachments: staged)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        if window {
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled],
                                backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = scrollView
            windows.append(host)
        }
        return (engine, textView)
    }

    #if !ATTIC_GENERATED_TESTS
    func testPerf3OpeningFiftyImagesWithoutAViewportReadsNoFiles() async {
        let provider = StubImages(bytes: [:])
        let blocks = [NoteBlock.text("Image heavy")] + (0..<50).map { _ in
            NoteBlock.image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)
        }
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks), imageProvider: provider)
        try? await Task.sleep(for: .milliseconds(200))
        print("PERF3_IMAGE_OPEN images=50 file_requests=\(provider.fileRequests)")
        XCTAssertEqual(provider.fileRequests, 0, "opening without a viewport must not request or decode all images")
        XCTAssertEqual(engine.document().blocks.count, 51)
    }

    func testR12FoldedViewportImagesReadNoFilesUntilUnfolded() async throws {
        let provider = StubImages(bytes: [:])
        let id = UUID()
        var heading = NoteBlock.text("Hidden", id: id, style: "heading")
        heading.level = 2
        var peer = NoteBlock.text("Visible", style: "heading")
        peer.level = 2
        let document = NoteDocument(blocks: [.text("Title"), heading,
            .image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400), peer, .text("Body")],
            extras: ["foldedHeadings": .array([.string(id.uuidString)])])
        let engine = NoteEditorEngine(noteID: UUID(), document: document, imageProvider: provider)
        let (scroll, text) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let host = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = scroll
        windows.append(host)
        text.layoutSubtreeIfNeeded()
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        text.viewWillDraw()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.fileRequests, 0, "a hidden image inside the viewport's storage range is not visible")
        XCTAssertTrue(engine.toggleHeadingFold(at: 6))
        text.layoutSubtreeIfNeeded()
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        text.viewWillDraw()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(provider.fileRequests, 0, "unfolding admits the now-visible image")
    }

    func testPerf3OnlyViewportImagesDecodeAndScrollingLoadsTheLastImage() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.systemBlue, atX: 0, y: 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let items = (0..<50).map { index in
            StagedNoteAttachment(id: UUID(), filename: "viewport-\(index).png", contentTypeIdentifier: "public.png",
                byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        }
        let document = NoteDocument(blocks: [.text("Viewport images")] + items.map {
            .image(attachmentID: $0.id, pixelWidth: 800, pixelHeight: 400)
        })
        let (engine, view) = makeEngine(document, window: true, staged: items)
        var imageTrace: [String] = []
        engine.onImageLoadTrace = { imageTrace.append($0) }
        defer { engine.onImageLoadTrace = nil }
        let initial = expectation(description: "initial viewport work reached a terminal state")
        initial.assertForOverFulfill = false
        engine.onImageLoadEvent = { if case .viewportSettled = $0 { initial.fulfill() } }
        view.layoutSubtreeIfNeeded()
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        await fulfillment(of: [initial], timeout: 5)
        XCTAssertFalse(view.needsLayout, "initial settlement includes the native layout invalidated by image installation")
        print("ROUND_F_IMAGE_SETTLED native_layout_pending=\(view.needsLayout)")
        let images = engine.objects().compactMap { $0.0 as? NoteImageAttachment }
        let loaded = images.filter { $0.renderedImage != nil && !$0.isMissing }
        print("PERF3_IMAGE_VIEWPORT images=50 initial_decoded=\(loaded.count)")
        XCTAssertGreaterThan(loaded.count, 0, "the visible image decodes without an edit")
        XCTAssertLessThanOrEqual(loaded.count, 6, "only the viewport and TextKit overdraw decode")
        let last = try XCTUnwrap(images.last)
        XCTAssertNil(last.renderedImage, "the last image is still offscreen")
        let range = try XCTUnwrap(engine.range(of: last))
        let installed = expectation(description: "last attachment preview installed")
        engine.onImageLoadEvent = { if case .installed(let key) = $0, key == ObjectIdentifier(last) { installed.fulfill() } }
        view.scrollRangeToVisible(range)
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        await fulfillment(of: [installed], timeout: 5)
        if last.renderedImage == nil || last.isMissing {
            let trace = imageTrace.joined(separator: "\n")
            print("ROUND_F_IMAGE_TRACE\n" + trace)
            let attachment = XCTAttachment(string: trace)
            attachment.name = "Viewport image admission trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertNotNil(last.renderedImage, "scrolling loads an image that has never been drawn")
        XCTAssertFalse(last.isMissing)
        XCTAssertEqual(last.pixelSize, CGSize(width: 800, height: 400))
        XCTAssertEqual(last.filename, items.last?.filename)
        XCTAssertEqual(engine.checkpointDocument().attachmentIDs, document.attachmentIDs, "lazy previews never remove recovery payload references")
        let beforeDetach = images.filter { $0.renderedImage != nil }.count
        let detached = expectation(description: "view detach acknowledged")
        engine.onImageLoadEvent = { if case .detached = $0 { detached.fulfill() } }
        engine.detachView()
        await fulfillment(of: [detached], timeout: 5)
        XCTAssertEqual(images.filter { $0.renderedImage != nil }.count, beforeDetach)
        let printed = await engine.preparedPrintView()
        let printedImages = try XCTUnwrap(printed.textStorage).length
        XCTAssertGreaterThan(printedImages, 50, "printing still projects the complete document")
        var printCount = 0
        printed.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: printedImages)) { value, _, _ in
            if let image = value as? NoteImageAttachment {
                XCTAssertNotNil(image.renderedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                XCTAssertEqual(image.renderedImage?.size, CGSize(width: 800, height: 400), "print has the decoded pixels, including offscreen images")
                printCount += 1
            }
        }
        XCTAssertEqual(printCount, 50, "print decoding is independent of viewport loading")
    }

    func testRoundFTailDecodeKeepsItsViewportAfterSiblingImageRedraw() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let items = (0..<50).map { index in
            StagedNoteAttachment(id: UUID(), filename: "tail-\(index).png", contentTypeIdentifier: "public.png",
                byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        }
        let document = NoteDocument(blocks: [.text("Viewport images")] + items.map {
            .image(attachmentID: $0.id, pixelWidth: 800, pixelHeight: 400)
        })
        let (engine, view) = makeEngine(document, window: true, staged: items)
        let decoder = HeldPreviewDecoder(heldIDs: Set(items.suffix(3).map(\.id)))
        engine.previewDecoder = decoder
        var imageTrace: [String] = []
        engine.onImageLoadTrace = { imageTrace.append($0) }
        defer {
            engine.onImageLoadTrace = nil
            engine.onImageLoadEvent = nil
            decoder.onHeld = nil
            engine.detachView()
            decoder.releaseAll()
        }
        let initial = expectation(description: "initial viewport work settled")
        initial.assertForOverFulfill = false
        engine.onImageLoadEvent = { if case .viewportSettled = $0 { initial.fulfill() } }
        view.layoutSubtreeIfNeeded()
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        await fulfillment(of: [initial], timeout: 5)
        let images = engine.objects().compactMap { $0.0 as? NoteImageAttachment }
        let target = try XCTUnwrap(images.last)
        let sibling = images[48]
        let held = expectation(description: "tail thumbnails held")
        held.expectedFulfillmentCount = 3
        held.assertForOverFulfill = false
        decoder.onHeld = { _ in held.fulfill() }
        let installed = expectation(description: "last preview installed after sibling redraw")
        let settled = expectation(description: "tail viewport remains settled after installation")
        settled.assertForOverFulfill = false
        var targetInstalled = false
        engine.onImageLoadEvent = { event in
            switch event {
            case .installed(let key) where key == ObjectIdentifier(sibling):
                // CI can run the pending native layout before the target resumes.
                view.layoutSubtreeIfNeeded()
                decoder.release(target.attachmentID)
            case .installed(let key) where key == ObjectIdentifier(target):
                targetInstalled = true
                installed.fulfill()
            case .viewportSettled where targetInstalled: settled.fulfill()
            default: break
            }
        }
        view.scrollRangeToVisible(try XCTUnwrap(engine.range(of: target)))
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        await fulfillment(of: [held], timeout: 5)
        engine.refreshViewportImages()
        decoder.release(items[47].id)
        decoder.release(sibling.attachmentID)
        await fulfillment(of: [installed, settled], timeout: 5)
        if target.renderedImage == nil { print("ROUND_F_TAIL_TRACE\n" + imageTrace.joined(separator: "\n")) }
        XCTAssertNotNil(target.renderedImage)
        XCTAssertFalse(target.isMissing)
        XCTAssertEqual(decoder.requests[target.attachmentID], 1, "the held target is not decoded again")
        let viewport = try XCTUnwrap(engine.layoutManager?.textViewportLayoutController.viewportRange)
        let targetRange = try XCTUnwrap(engine.textRange(for: try XCTUnwrap(engine.range(of: target))))
        XCTAssertTrue(viewport.intersects(targetRange), "sibling presentation changes must not move the viewport away from the requested tail")
        XCTAssertEqual(engine.checkpointDocument().attachmentIDs, document.attachmentIDs)
        XCTAssertFalse(engine.history.canUndo)
    }
    #endif

    private func roundFViewportFixture() throws -> (NoteDocument, [StagedNoteAttachment]) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let items = (0..<50).map { index in
            StagedNoteAttachment(id: UUID(), filename: "interleaving-\(index).png", contentTypeIdentifier: "public.png",
                byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        }
        return (NoteDocument(blocks: [.text("Viewport images")] + items.map {
            .image(attachmentID: $0.id, pixelWidth: 800, pixelHeight: 400)
        }), items)
    }

    #if !ATTIC_GENERATED_TESTS
    func testRoundFImageReconciliationRespectsNavigationAwayFromTheHeldTail() async throws {
        let (document, items) = try roundFViewportFixture()
        let (engine, view) = makeEngine(document, window: true, staged: items)
        let decoder = HeldPreviewDecoder(heldIDs: Set(items.suffix(3).map(\.id)))
        engine.previewDecoder = decoder
        defer {
            engine.onImageLoadEvent = nil; decoder.onHeld = nil
            engine.detachView(); decoder.releaseAll()
        }
        let initial = expectation(description: "initial image layout settled")
        initial.assertForOverFulfill = false
        engine.onImageLoadEvent = { if case .viewportSettled = $0 { initial.fulfill() } }
        view.layoutSubtreeIfNeeded(); engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        await fulfillment(of: [initial], timeout: 5)
        let images = engine.objects().compactMap { $0.0 as? NoteImageAttachment }
        let target = try XCTUnwrap(images.last)
        let held = expectation(description: "tail images pending")
        held.expectedFulfillmentCount = 3
        held.assertForOverFulfill = false
        decoder.onHeld = { _ in held.fulfill() }
        let settled = expectation(description: "navigation and pending images settled")
        settled.assertForOverFulfill = false
        var navigated = false
        var targetInstalled = false
        engine.onImageLoadEvent = { event in
            switch event {
            case .installed(let key) where key == ObjectIdentifier(images[48]) && !navigated:
                navigated = true
                view.scrollRangeToVisible(NSRange(location: 0, length: 0))
                view.layoutSubtreeIfNeeded()
                decoder.release(target.attachmentID)
            case .installed(let key) where key == ObjectIdentifier(target): targetInstalled = true
            case .viewportSettled where navigated: settled.fulfill()
            default: break
            }
        }
        view.scrollRangeToVisible(try XCTUnwrap(engine.range(of: target)))
        engine.layoutManager?.textViewportLayoutController.layoutViewport(); view.viewWillDraw()
        await fulfillment(of: [held], timeout: 5)
        engine.refreshViewportImages()
        decoder.release(items[47].id); decoder.release(items[48].id)
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertFalse(targetInstalled, "a real navigation cancels the previous image anchor")
        XCTAssertNil(target.renderedImage)
        let viewport = try XCTUnwrap(engine.layoutManager?.textViewportLayoutController.viewportRange)
        XCTAssertEqual(engine.contentStorage.offset(from: engine.contentStorage.documentRange.location, to: viewport.location), 0)
        XCTAssertEqual(decoder.requests[target.attachmentID], 1)
        XCTAssertEqual(engine.checkpointDocument().attachmentIDs, document.attachmentIDs)
        XCTAssertFalse(engine.history.canUndo)
    }

    func testRoundFMountedExplicitRetryPreservesThePendingViewport() async throws {
        let (document, items) = try roundFViewportFixture()
        let (engine, view) = makeEngine(document, window: true, staged: items)
        let decoder = HeldPreviewDecoder(heldIDs: Set(items.suffix(3).map(\.id)))
        engine.previewDecoder = decoder
        defer {
            engine.onImageLoadEvent = nil; decoder.onHeld = nil
            engine.detachView(); decoder.releaseAll()
        }
        let initial = expectation(description: "initial image layout settled")
        initial.assertForOverFulfill = false
        engine.onImageLoadEvent = { if case .viewportSettled = $0 { initial.fulfill() } }
        view.layoutSubtreeIfNeeded(); engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        await fulfillment(of: [initial], timeout: 5)
        let images = engine.objects().compactMap { $0.0 as? NoteImageAttachment }
        let target = try XCTUnwrap(images.last)
        let first = try XCTUnwrap(images.first)
        let held = expectation(description: "tail images pending during explicit retry")
        held.expectedFulfillmentCount = 3
        held.assertForOverFulfill = false
        decoder.onHeld = { _ in held.fulfill() }
        let retried = expectation(description: "explicit retry installed")
        let installed = expectation(description: "pending tail installed after explicit retry redraw")
        let settled = expectation(description: "pending viewport settled after retry")
        settled.assertForOverFulfill = false
        var targetInstalled = false
        engine.onImageLoadEvent = { event in
            switch event {
            case .installed(let key) where key == ObjectIdentifier(first):
                view.layoutSubtreeIfNeeded()
                items.suffix(3).forEach { decoder.release($0.id) }
                retried.fulfill()
            case .installed(let key) where key == ObjectIdentifier(target):
                targetInstalled = true; installed.fulfill()
            case .viewportSettled where targetInstalled: settled.fulfill()
            default: break
            }
        }
        view.scrollRangeToVisible(try XCTUnwrap(engine.range(of: target)))
        engine.layoutManager?.textViewportLayoutController.layoutViewport(); view.viewWillDraw()
        await fulfillment(of: [held], timeout: 5)
        engine.markPreviewUnavailable(first.objectID)
        let accepted = await engine.perform(.retryPreview, objectID: first.objectID)
        XCTAssertTrue(accepted)
        await fulfillment(of: [retried, installed, settled], timeout: 5)
        XCTAssertNotNil(target.renderedImage)
        XCTAssertFalse(target.isMissing)
        XCTAssertEqual(decoder.requests[first.attachmentID], 2)
        XCTAssertEqual(decoder.requests[target.attachmentID], 1)
        let viewport = try XCTUnwrap(engine.layoutManager?.textViewportLayoutController.viewportRange)
        XCTAssertTrue(viewport.intersects(try XCTUnwrap(engine.textRange(for: try XCTUnwrap(engine.range(of: target))))))
        XCTAssertEqual(engine.checkpointDocument().attachmentIDs, document.attachmentIDs)
        XCTAssertFalse(engine.history.canUndo)
    }

    func testRoundFExplicitPreviewRetryStillWorksWithoutAMountedView() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let item = StagedNoteAttachment(id: UUID(), filename: "retry.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        let block = NoteBlock.image(attachmentID: item.id, pixelWidth: 80, pixelHeight: 40)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Retry"), block]),
            stagedAttachments: [item])
        let image = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteImageAttachment }.first)
        engine.markPreviewUnavailable(image.objectID)
        let installed = expectation(description: "explicit retry installed without a viewport")
        engine.onImageLoadEvent = { if case .installed(let key) = $0, key == ObjectIdentifier(image) { installed.fulfill() } }
        let accepted = await engine.perform(.retryPreview, objectID: image.objectID)
        XCTAssertTrue(accepted)
        await fulfillment(of: [installed], timeout: 5)
        XCTAssertNil(engine.textView)
        XCTAssertNotNil(image.renderedImage)
        XCTAssertFalse(image.isMissing)
        XCTAssertEqual(image.renderedImage?.size, CGSize(width: 80, height: 40))
        XCTAssertEqual(engine.checkpointDocument().attachmentIDs, [item.id])
        XCTAssertFalse(engine.history.canUndo)
    }

    /// The target is already decoded but held across a sibling's layout invalidation.
    /// Neither a second scroll nor repeated test-driven refreshes may rescue it.
    func testRoundFDeferredViewportInstallsHeldDecodeAfterSiblingInvalidatesLayout() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let items = (0..<2).map { index in
            StagedNoteAttachment(id: UUID(), filename: "held-\(index).png", contentTypeIdentifier: "public.png",
                byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        }
        let document = NoteDocument(blocks: [.text("Held previews")] + items.map {
            .image(attachmentID: $0.id, pixelWidth: 800, pixelHeight: 400)
        })
        let (engine, view) = makeEngine(document, window: true, staged: items)
        let images = engine.objects().compactMap { $0.0 as? NoteImageAttachment }
        let target = try XCTUnwrap(images.first)
        let sibling = try XCTUnwrap(images.last)
        let decoder = HeldPreviewDecoder()
        engine.previewDecoder = decoder
        let started = expectation(description: "both real staged thumbnails decoded and held")
        started.expectedFulfillmentCount = 2
        started.assertForOverFulfill = false
        var events: [String] = []
        decoder.onHeld = { id in
            events.append(id == target.attachmentID ? "target-held" : "sibling-held")
            started.fulfill()
        }
        var deferNextAdmission = false
        engine.imageAdmissionViewport = {
            if deferNextAdmission {
                deferNextAdmission = false
                events.append("viewport-unavailable")
                return nil
            }
            return engine.layoutManager?.textViewportLayoutController.viewportRange
        }
        defer {
            engine.onImageLoadEvent = nil
            engine.imageAdmissionViewport = nil
            decoder.onHeld = nil
            engine.detachView()
            decoder.releaseAll()
        }
        let installed = expectation(description: "target installed without another scroll")
        engine.onImageLoadEvent = { event in
            guard case .installed(let key) = event else { return }
            if key == ObjectIdentifier(sibling) {
                events.append("sibling-installed")
                // TextKit may retain a stale range or expose nil after invalidation.
                // Supply the unavailable observation once at the async admission boundary.
                deferNextAdmission = true
                events.append("target-released")
                decoder.release(target.attachmentID)
            } else if key == ObjectIdentifier(target) {
                events.append("target-installed")
                installed.fulfill()
            }
        }
        view.layoutSubtreeIfNeeded()
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        await fulfillment(of: [started], timeout: 5)
        engine.refreshViewportImages()
        events.append("refresh-while-pending")
        decoder.release(sibling.attachmentID)
        await fulfillment(of: [installed], timeout: 5)
        decoder.releaseAll()
        XCTAssertEqual(decoder.thumbnailRequests, 2, "one decode per image despite refresh and reconciliation")
        XCTAssertEqual(Array(events.suffix(5)), ["refresh-while-pending", "sibling-installed", "target-released", "viewport-unavailable", "target-installed"])
        XCTAssertNotNil(target.renderedImage)
        XCTAssertFalse(target.isMissing)
        XCTAssertEqual(target.pixelSize, CGSize(width: 800, height: 400))
        XCTAssertEqual(target.filename, items[0].filename)
        XCTAssertEqual(engine.checkpointDocument().attachmentIDs, document.attachmentIDs)
        print("ROUND_F_IMAGE_INTERLEAVING \(events)")
    }

    func testPerf3DetachedViewportDropsPendingPreviewAndCanRetryOnReturn() async throws {
        let provider = GatedViewportImages()
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Pending"),
            .image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)]), imageProvider: provider)
        func present() {
            let (scroll, view) = engine.makeView()
            scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
            let host = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = scroll
            windows.append(host)
            view.layoutSubtreeIfNeeded()
            engine.layoutManager?.textViewportLayoutController.layoutViewport()
            view.viewWillDraw()
        }
        present()
        for _ in 0..<50 {
            if provider.requested { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(provider.requested)
        let image = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteImageAttachment }.first)
        engine.detachView()
        provider.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(image.renderedImage, "a departed viewport must not install a late preview or missing-image placeholder")
        present()
        for _ in 0..<50 {
            if image.renderedImage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(image.renderedImage, "cancelled requests do not block loading when the note returns")
        XCTAssertTrue(image.isMissing, "the missing file still has a recoverable placeholder")
        XCTAssertTrue(image.accessibilityDescription.contains("pending.png"))
    }
    #endif

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func location(of text: String, in engine: NoteEditorEngine) -> Int {
        (engine.textStorage.string as NSString).range(of: text).location
    }

    /// Typing as a person does (the sanctioned path).
    private func type(_ text: String, _ textView: NoteEditorTextView) {
        for character in text { textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    // H12-02: normal slash insertion and typing, in an unshown window.
    #if !ATTIC_GENERATED_TESTS
    func testH12_02TypingAfterDividerKeepsTheWholeLineAboveFooter() throws {
        for withImage in [false, true] {
            var blocks: [NoteBlock] = [.text("Long note")]
            if withImage { blocks.append(.image(id: UUID(), attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)) }
            blocks += (0..<28).map { .text("Body line \($0)") }
            let (engine, view) = makeEngine(NoteDocument(blocks: blocks), window: true)
            let scroll = try XCTUnwrap(engine.scrollView)
            scroll.frame.size = NSSize(width: 320, height: 464)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 80, left: 0, bottom: 92, right: 0)
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            view.insertNewline(nil)
            type("/divider", view)
            XCTAssertTrue(engine.acceptSlashItem(.divider), "the same acceptance used by slash Return")
            XCTAssertTrue(engine.document().blocks.contains { $0.kind == .divider })
            type("Text after divider", view)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            view.layoutSubtreeIfNeeded()
            let line = (engine.textStorage.string as NSString).range(of: "Text after divider")
            let rect = try XCTUnwrap(engine.rect(for: line))
            let clip = view.convert(scroll.contentView.bounds, from: scroll.contentView)
            print("H12_02 image=\(withImage) line=\(rect) clip=\(clip) inset=\(scroll.contentInsets) frame=\(view.frame)")
            XCTAssertGreaterThanOrEqual(rect.minY, clip.minY + scroll.contentInsets.top - 1)
            XCTAssertLessThanOrEqual(rect.maxY, clip.maxY - scroll.contentInsets.bottom + 1,
                                     "the whole typed line clears the footer, image=\(withImage)")
            XCTAssertFalse(view.window!.isVisible)
            XCTAssertFalse(view.window!.isKeyWindow)
            engine.detachView()
        }
    }

    func testH12_02SiblingBlocksKeepTypingAboveFooter() throws {
        let siblings: [NoteBlock] = [
            .text("Ordinary body"), .divider(),
            .image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400),
            .file(attachmentID: UUID(), filename: "plan.txt", contentTypeIdentifier: "public.plain-text", byteCount: 77),
            .table(NoteTable(texts: [["A", "B"], ["C", "D"]])), .checklist("Check this")
        ]
        for sibling in siblings {
            let document = NoteDocument(blocks: [.text("Long note")] + (0..<28).map { .text("Body line \($0)") } + [sibling, .text("")])
            let (engine, view) = makeEngine(document, window: true)
            let scroll = try XCTUnwrap(engine.scrollView)
            scroll.frame.size = NSSize(width: 320, height: 464)
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 80, left: 0, bottom: 92, right: 0)
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            for character in "Text after block" {
                type(String(character), view)
                view.layoutSubtreeIfNeeded()
                let line = engine.lineRange(at: view.selectedRange().location)
                let rect = try XCTUnwrap(engine.rect(for: line))
                let clip = view.convert(scroll.contentView.bounds, from: scroll.contentView)
                XCTAssertLessThanOrEqual(rect.maxY, clip.maxY - scroll.contentInsets.bottom + 1, "\(sibling.kind) / \(character)")
            }
            XCTAssertFalse(view.window!.isVisible)
            XCTAssertFalse(view.window!.isKeyWindow)
            engine.detachView()
        }
    }

    func testH12_02TypingAfterDividerWithALoadedPNGKeepsTheLineAboveFooter() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.systemBlue, atX: 0, y: 0)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let item = StagedNoteAttachment(id: UUID(), filename: "h12.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        let document = NoteDocument(blocks: [.text("Long note"),
            .image(attachmentID: item.id, pixelWidth: 800, pixelHeight: 400)] + (0..<28).map { .text("Body line \($0)") })
        let (engine, view) = makeEngine(document, window: true, staged: [item])
        let scroll = try XCTUnwrap(engine.scrollView)
        scroll.frame.size = NSSize(width: 320, height: 464)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 80, left: 0, bottom: 92, right: 0)
        view.layoutSubtreeIfNeeded()
        engine.layoutManager?.textViewportLayoutController.layoutViewport()
        view.viewWillDraw()
        let image = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteImageAttachment }.first)
        let deadline = Date().addingTimeInterval(3)
        while image.renderedImage == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNotNil(image.renderedImage)
        XCTAssertFalse(image.isMissing, "real PNG decoded")
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        view.layoutSubtreeIfNeeded()
        let imageRange = try XCTUnwrap(engine.range(of: image))
        let imageRect = try XCTUnwrap(engine.rect(for: imageRange))
        XCTAssertGreaterThan(imageRect.height, 100, "the image contributes its real height")
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        view.insertNewline(nil)
        type("/divider", view)
        XCTAssertTrue(engine.acceptSlashItem(.divider))
        type("Text after divider", view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        let rect = try XCTUnwrap(engine.rect(for: (engine.textStorage.string as NSString).range(of: "Text after divider")))
        let clip = view.convert(scroll.contentView.bounds, from: scroll.contentView)
        print("H12_02 loadedPNG image=\(imageRect) line=\(rect) clip=\(clip)")
        XCTAssertLessThanOrEqual(rect.maxY, clip.maxY - scroll.contentInsets.bottom + 1)
        XCTAssertFalse(view.window!.isVisible)
        XCTAssertFalse(view.window!.isKeyWindow)
        engine.detachView()
    }
    #endif

    // MARK: Drawing

    private final class WeakEngine {
        weak var value: NoteEditorEngine?
        init(_ value: NoteEditorEngine) { self.value = value }
    }

    private final class WeakObject {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    /// These heavy retention gates run in the CI costs lane (including full CI).
    private func requireSoakTests() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_SOAK_TESTS"] == "1" else {
            throw XCTSkip("Heavy retention gate: opt in with ATTIC_SOAK_TESTS=1 (TEST_RUNNER_ATTIC_SOAK_TESTS=1 for xcodebuild)")
        }
    }

    /// Sixty compressed minutes: rotate twelve notes, type 40 characters,
    /// save/leave, and add/rename/complete a task per minute. No visible UI.
    #if !ATTIC_GENERATED_TESTS
    func testPerf2SimulatedHourRetainsOnlyTheWarmNoteSessions() async throws {
        try requireSoakTests()
        let notes = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let tasks = try makeTestStore()
        let controller = NotesPageController(store: notes, journal: nil, saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await controller.startAndWait()
        var ids: [UUID] = []
        for index in 0..<12 {
            var blocks = (0..<(index == 0 ? 5_000 : 200)).map { NoteBlock.text("Note \(index), line \($0)") }
            blocks.insert(.table(NoteTable(texts: [["Task", "Date"], ["Write", "Monday"]])), at: 10)
            guard case let .success((id, _)) = notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks)) else {
                return XCTFail("could not create soak fixture")
            }
            ids.append(id)
        }
        var engines: [WeakEngine] = []
        var views: [WeakObject] = []
        var layouts: [WeakObject] = []
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }
        for minute in 0..<60 {
            await XCTAssertTrueAsync(await controller.openDurably(noteID: ids[minute % ids.count]))
            let session = try XCTUnwrap(controller.active)
            engines.append(WeakEngine(session.engine))
            autoreleasepool {
                let (_, view) = session.engine.makeView()
                views.append(WeakObject(view))
                if let layout = session.engine.layoutManager { layouts.append(WeakObject(layout)) }
                view.setSelectedRange(NSRange(location: session.engine.textStorage.length, length: 0))
                let extractions = session.engine.documentExtractionCount
                type(String(repeating: "a", count: 40), view)
                XCTAssertEqual(session.engine.documentExtractionCount, extractions,
                               "typing does not extract the whole document before the save boundary")
                session.engine.detachView()
            }
            await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.quit))
            let task = try XCTUnwrap(tasks.create(title: "Minute \(minute)"))
            XCTAssertTrue(tasks.update(task, title: "Renamed minute \(minute)"))
            XCTAssertTrue(tasks.setStatus(.done, for: task))
            if (minute + 1).isMultiple(of: 15) {
                await Task.yield()
                let alive = engines.compactMap(\.value).count
                print("PERF2_SOAK minutes=\(minute + 1) engines=\(alive) footprint_bytes=\(footprint())")
                print("SMOOTH_LIFETIME views=\(views.compactMap(\.value).count) layouts=\(layouts.compactMap(\.value).count) undo_ops=\(session.engine.history.undoOps.count) pid=\(ProcessInfo.processInfo.processIdentifier)")
                XCTAssertLessThanOrEqual(alive, 8, "clean sessions beyond the warm-cache limit must be released")
                XCTAssertEqual(layouts.compactMap(\.value).count, 0,
                               "the measured detached baseline retains no editor layout managers")
                if ProcessInfo.processInfo.environment["ATTIC_SMOOTH_ALLOCATION_PAUSE"] == "1" {
                    try await Task.sleep(for: .seconds(45))
                }
            }
        }
        XCTAssertEqual(tasks.tasks.count, 60)
        // Let AppKit's deferred layout and autorelease work drain. Raw
        // snapshots during a compressed workload are not steady idle cost.
        try await Task.sleep(for: .seconds(1))
        print("PERF2_SOAK quiescent_footprint_bytes=\(footprint()) engines=\(engines.compactMap(\.value).count)")
    }

    /// Compressed workload, not one hour of wall time: ten cell revisions
    /// per second for 60 minutes. Measures retention without timing gates.
    func testPerf2TableMeasurementRetentionOverAnHourOfEdits() throws {
        try requireSoakTests()
        let cache = NoteTableTextCache()
        let style = NoteTextStyle()
        for minute in 0..<60 {
            autoreleasepool {
                for key in 0..<600 {
                    let cell = NoteTable.Cell("Edit \(minute * 600 + key)")
                    let string = NSAttributedString(string: cell.text, attributes: style.bodyAttributes)
                    _ = cache.natural(cell, header: false) { string }
                    _ = cache.minimum(cell, header: false) { string }
                    _ = cache.height(cell, header: false, width: 120) { string }
                }
            }
            if (minute + 1).isMultiple(of: 15) {
                print("PERF2_TABLE_CACHE minutes=\(minute + 1) entries=\(cache.retainedMeasurementCount)")
            }
        }
        XCTAssertLessThanOrEqual(cache.retainedMeasurementCount, 45_000)
        cache.clear()
        XCTAssertEqual(cache.retainedMeasurementCount, 0)
    }

    func testPerf2TableCacheKeepsAMaximumTableWarmAndRemeasuresEvictedText() throws {
        try requireSoakTests()
        let cache = NoteTableTextCache()
        let string = NSAttributedString(string: "same measured text")
        var measurements = 0
        func read(_ index: Int) -> CGFloat {
            cache.height(NoteTable.Cell("Cell \(index)"), header: false, width: 100) {
                measurements += 1
                return string
            }
        }
        let first = read(0)
        for index in 1..<15_000 { _ = read(index) }
        let warm = measurements
        for index in 0..<15_000 { XCTAssertEqual(read(index), first) }
        XCTAssertEqual(measurements, warm, "a maximum table still fits without cache thrashing")
        _ = read(15_000)
        XCTAssertEqual(cache.retainedMeasurementCount, 15_000)
        let beforeMiss = measurements
        XCTAssertEqual(read(0), first, "an evicted entry is recomputed with the same result")
        XCTAssertEqual(measurements, beforeMiss + 1)
        let beforeHit = measurements
        XCTAssertEqual(read(0), first)
        XCTAssertEqual(measurements, beforeHit)
        cache.clear()
        XCTAssertEqual(cache.retainedMeasurementCount, 0)
        XCTAssertEqual(read(0), first)
        XCTAssertEqual(measurements, beforeHit + 1)

        // A full grid editing its last cell must keep its other cells hot.
        cache.clear()
        for index in 0..<15_000 { _ = read(index) }
        let beforeEdits = measurements
        for edit in 0..<5 {
            for index in 0..<14_999 { _ = read(index) }
            _ = read(20_000 + edit)
        }
        XCTAssertEqual(measurements - beforeEdits, 5, "only the five changed cells are measured")
    }

    func testPerf2EmptyFindDoesNoSearchOrLayoutWorkWhileTyping() throws {
        var blocks = (0..<5_000).map { NoteBlock.text("Line \($0) with ordinary text") }
        blocks.insert(.table(NoteTable(texts: [["needle", "cell"], ["other", "value"]])), at: 100)
        blocks.insert(.image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400), at: 200)
        let (engine, view) = makeEngine(NoteDocument(blocks: blocks), window: true)
        engine.find.show()
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        let searches = engine.find.objectSearchPassCount
        let layouts = engine.find.highlightLayoutPassCount
        type("twenty five ordinary keys", view)
        print("PERF2_EMPTY_FIND searches=\(engine.find.objectSearchPassCount - searches) layouts=\(engine.find.highlightLayoutPassCount - layouts)")
        XCTAssertEqual(engine.find.objectSearchPassCount, searches)
        XCTAssertEqual(engine.find.highlightLayoutPassCount, layouts)
        XCTAssertTrue(engine.find.matches.isEmpty)
        // Clearing a real search must still remove its highlights once.
        engine.find.query = "needle"
        XCTAssertEqual(engine.find.matches.count, 1)
        XCTAssertNotNil(engine.find.matches.first?.tableID)
        let beforeClear = engine.find.highlightLayoutPassCount
        engine.find.query = ""
        XCTAssertTrue(engine.find.matches.isEmpty)
        XCTAssertNil(engine.find.index)
        XCTAssertEqual(engine.find.highlightLayoutPassCount, beforeClear + 1)
        let cleared = engine.find.highlightLayoutPassCount
        engine.find.refresh()
        XCTAssertEqual(engine.find.highlightLayoutPassCount, cleared)
    }

    func testPerf2TableRowOriginsDoNotResumPrefixesPerFrame() {
        let heights = (0..<500).map { CGFloat(21 + $0 % 7) }
        let layout = NoteTableLayout(columnWidths: [56, 72], rowHeights: heights, viewportWidth: 128)
        NoteTableLayout.rowOriginAdditionCount = 0
        var expected: CGFloat = 0
        for row in heights.indices {
            XCTAssertEqual(layout.rowY(row), expected)
            expected += heights[row]
        }
        XCTAssertEqual(layout.rowY(-1), 0)
        XCTAssertEqual(layout.rowY(heights.count + 1), expected)
        print("PERF2_ROW_ORIGINS additions=\(NoteTableLayout.rowOriginAdditionCount)")
        XCTAssertEqual(NoteTableLayout.rowOriginAdditionCount, 0,
                       "a draw reads existing row origins; it never sums prefixes again")
    }

    func testObjectsAreDrawnFromTheDesignSystem() {
        let (engine, _) = makeEngine()
        for (object, _) in engine.objects() where !(object is NoteImageAttachment) {
            let image = object.image
            XCTAssertNotNil(image, "\(String(describing: Swift.type(of: object))) has an image TextKit 2 can draw")
            XCTAssertGreaterThan(image?.size.width ?? 0, 4)
            XCTAssertGreaterThan(image?.size.height ?? 0, 4)
            XCTAssertNotNil(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    // MARK: Round trip

    func testDocumentSurvivesTheTextSystem() {
        let document = sample()
        XCTAssertEqual(NoteTextKitRoundTrip.document(afterRoundTrip: document), document)
        let (engine, _) = makeEngine()
        XCTAssertEqual(engine.document(), document)
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
    }

    func testCachedFinalParagraphMatchesFullExtractionAndInvalidatesForObjectsAndNewlines() {
        let document = NoteDocument(blocks: (0..<500).map { .text("Line \($0)") })
        let (engine, _) = makeEngine(document)
        XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
        for _ in 0..<10 {
            engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                               with: NSAttributedString(string: "x"), name: "Typing")
            XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
        }
        engine.insertDate(NoteDay(year: 2026, month: 10, day: 2)!)
        XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                           with: NSAttributedString(string: "\nAnother line"), name: "Typing")
        XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
    }

    func testTitleStyleFollowsTheFirstParagraph() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.insertNewline(nil)
        let titleFont = engine.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let secondFont = engine.textStorage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertEqual(titleFont?.pointSize, AtticTextStyle.noteTitle.nsFont.pointSize)
        XCTAssertEqual(secondFont?.pointSize, AtticTextStyle.noteBody.nsFont.pointSize)
        XCTAssertEqual(engine.document().blocks.prefix(2).map(\.text), ["Ti", "tle"])
    }

    // MARK: Editor-owned undo

    func testTypingCoalescesAndUndoesInOneStep() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        type(" of note", textView)
        XCTAssertEqual(engine.document().blocks.last?.text, "End of note")
        XCTAssertEqual(engine.history.undoOps.count, 1)
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
        engine.history.redo()
        XCTAssertEqual(engine.document().blocks.last?.text, "End of note")
    }

    func testLongUninterruptedTypingRemainsOneUndoStep() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        let started = DispatchTime.now().uptimeNanoseconds
        type(String(repeating: "x", count: 2_000), textView)
        print("NOTE_LONG_TYPING_MS=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
        XCTAssertEqual(engine.history.undoOps.count, 1)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document(), sample())
    }

    func testCheckboxHitTestingDeepInALargeDocument() throws {
        var blocks = [NoteBlock.text("Title")]
        blocks += (0..<2_000).map { NoteBlock.text("Line \($0)") }
        blocks.append(.checklist("Deep item"))
        let (engine, textView) = makeEngine(NoteDocument(blocks: blocks))
        let index = (engine.textStorage.string as NSString).range(of: "\u{FFFC}Deep item").location
        XCTAssertNotEqual(index, NSNotFound)
        let range = NSRange(location: index, length: 1)
        engine.contentStorage.primaryTextLayoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        let rect = try XCTUnwrap(engine.rect(for: range))
        let point = NSPoint(x: rect.minX + 4, y: rect.midY)
        XCTAssertEqual(textView.checkboxLocation(at: point), index)
    }

    /// Finding D: a composition that replaces a selection undoes back to the
    /// selected text, and redoes to the committed text.
    func testCompositionReplacingASelectionUndoesAndRedoes() {
        let (engine, textView) = makeEngine()
        let world = NSRange(location: location(of: "world", in: engine), length: 5)
        textView.setSelectedRange(world)
        textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(engine.document().blocks[1].text, "Hello 日本")
        engine.history.undo()
        XCTAssertEqual(engine.document().blocks[1].text, "Hello world")
        engine.history.redo()
        XCTAssertEqual(engine.document().blocks[1].text, "Hello 日本")
        XCTAssertEqual(engine.document().objectIDs, sample().objectIDs, "objects untouched throughout")
    }

    func testCompositionOverAnObjectRemovesItAndUndoBringsTheSameObjectBack() {
        let (engine, textView) = makeEngine()
        let dateLocation = location(of: "\u{FFFC} for", in: engine)
        textView.setSelectedRange(NSRange(location: dateLocation, length: 1))
        textView.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("明日", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(engine.objectIDs().contains(dateID))
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
    }

    /// Autocorrect parity. AppKit applies a correction as a change through
    /// `shouldChangeText` + a storage replacement + `didChangeText` (the
    /// step stock NSTextView records as "Undo Correction"). The same change
    /// on this editor and on a stock NSTextView with built-in undo gives the
    /// same text after the correction, after Undo and after Redo. The real
    /// text-checking entry point is exercised too when AppKit applies it
    /// headlessly (it does not always without a spelling server session).
    func testAutocorrectParityWithStockTextView() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("teh cat")]))
        let stockUndo = UndoManager()
        let stockDelegate = StockUndoDelegate(undoManager: stockUndo)
        let stock = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        stock.delegate = stockDelegate
        stock.allowsUndo = true
        stock.string = "Title\nteh cat"
        let range = NSRange(location: 6, length: 3)
        for view in [textView as NSTextView, stock] {
            view.setSelectedRange(NSRange(location: 9, length: 0))
            XCTAssertTrue(view.shouldChangeText(in: range, replacementString: "the"))
            view.textStorage?.replaceCharacters(in: range, with: "the")
            view.didChangeText()
        }
        XCTAssertEqual(stock.string, "Title\nthe cat")
        XCTAssertEqual(engine.textStorage.string, stock.string)
        stockUndo.undo()
        engine.history.undo()
        XCTAssertEqual(stock.string, "Title\nteh cat")
        XCTAssertEqual(engine.textStorage.string, stock.string)
        stockUndo.redo()
        engine.history.redo()
        XCTAssertEqual(engine.textStorage.string, stock.string)

        // The real entry point, when AppKit applies it here.
        let (engine2, textView2) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("teh cat")]))
        let stock2 = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let stock2Undo = UndoManager()
        let stock2Delegate = StockUndoDelegate(undoManager: stock2Undo)
        stock2.delegate = stock2Delegate
        stock2.allowsUndo = true
        stock2.string = "Title\nteh cat"
        let correction = NSTextCheckingResult.correctionCheckingResult(range: range, replacementString: "the")
        for view in [textView2 as NSTextView, stock2] {
            view.isAutomaticSpellingCorrectionEnabled = true
            view.setSelectedRange(NSRange(location: 9, length: 0))
            view.handleTextCheckingResults([correction], forRange: NSRange(location: 6, length: 7),
                                           types: NSTextCheckingResult.CheckingType.correction.rawValue,
                                           options: [:], orthography: NSOrthography.defaultOrthography(forLanguage: "en"),
                                           wordCount: 2)
        }
        if stock2.string == "Title\nthe cat" {
            XCTAssertEqual(engine2.textStorage.string, stock2.string)
            stock2Undo.undo()
            engine2.history.undo()
            XCTAssertEqual(engine2.textStorage.string, stock2.string)
        }
    }

    func testOutsideEditRebasesHistoryInsteadOfCorruptingText() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        type(" typed", textView)
        // An edit from outside the history, above the typing (e.g. a rename).
        engine.history.performUnrecorded {
            engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Renamed title")
        }
        engine.history.rebase(editAt: NSRange(location: 0, length: 5), newLength: 13)
        engine.history.undo()
        XCTAssertEqual(engine.document().blocks.first?.text, "Renamed title")
        XCTAssertEqual(engine.document().blocks.last?.text, "End")
    }

    // MARK: Object guard: Find and Replace (requirement 9)

    func testReplaceThroughTheFindClientCannotRemoveAnObject() {
        let (engine, textView) = makeEngine()
        let date = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        // What NSTextFinder's single Replace does to its client.
        XCTAssertFalse(textView.shouldChangeText(in: date, replacementString: ""))
        // Replace All asks for every match at once.
        let box = NSRange(location: location(of: "\u{FFFC}Buy", in: engine), length: 1)
        XCTAssertFalse(textView.shouldChangeText(inRanges: [NSValue(range: box), NSValue(range: date)], replacementStrings: ["", ""]))
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        XCTAssertEqual(engine.refusals.count, 2)
        // Plain text is still replaceable that way.
        XCTAssertTrue(textView.shouldChangeText(in: NSRange(location: location(of: "world", in: engine), length: 5), replacementString: "there"))
    }

    func testRealFindBarReplaceAndReplaceAllCannotRemoveObjects() throws {
        let (engine, textView) = makeEngine(window: true)
        textView.window?.makeFirstResponder(textView)
        let date = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        textView.setSelectedRange(date)
        func perform(_ action: NSTextFinder.Action) {
            let item = NSMenuItem()
            item.tag = action.rawValue
            textView.performTextFinderAction(item)
        }
        perform(.showReplaceInterface)
        // Control: the same flow replaces plain text, so the harness really
        // drives Replace (with the find bar's empty replacement).
        let world = NSRange(location: location(of: "world", in: engine), length: 5)
        textView.setSelectedRange(world)
        perform(.setSearchString)
        textView.setSelectedRange(world)
        perform(.replace)
        XCTAssertFalse(engine.textStorage.string.contains("world"), "control: Replace ran")
        let movedDate = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        XCTAssertEqual((engine.textStorage.string as NSString).substring(with: movedDate), "\u{FFFC}")
        textView.setSelectedRange(movedDate)
        perform(.setSearchString)        // ⌘E with the date selected: the find string is its U+FFFC
        textView.setSelectedRange(movedDate)
        XCTAssertEqual((engine.textStorage.string as NSString).substring(with: textView.selectedRange()), "\u{FFFC}")
        perform(.replace)                // single Replace (empty replacement)
        perform(.replaceAll)
        perform(.replaceAndFind)
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID], "no object removed by Find")
    }

    func testNativeRichTextCommandsAreDisabledUntilTheFormatStoresMarks() {
        let (engine, textView) = makeEngine()
        XCTAssertFalse(textView.isRichText)
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
    }

    func testImageWidthFollowsTheTextColumn() {
        let image = NoteImageAttachment(attachmentID: UUID(), preferredWidthFraction: 0.5,
                                        pixelSize: CGSize(width: 2_000, height: 1_000))
        XCTAssertEqual(image.displaySize(columnWidth: 200).width, 100)
        XCTAssertEqual(image.displaySize(columnWidth: 400).width, 200)
    }

    func testPersonsOwnEditingMayRemoveObjectsAndUndoRestoresTheSameIDs() {
        let (engine, textView) = makeEngine()
        let date = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        textView.setSelectedRange(date)
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(engine.objectIDs().contains(dateID))
        engine.history.undo()
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        textView.setSelectedRange(NSRange(location: 0, length: engine.textStorage.length))
        textView.delete(nil)
        XCTAssertTrue(engine.objectIDs().isEmpty)
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
        engine.history.redo()
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
    }

    // MARK: Writing Tools (requirement 3)

    func testStockTextViewDoesNotExposeAWritingToolsCoordinator() {
        let (_, textView) = makeEngine()
        XCTAssertNil(textView.writingToolsCoordinator)
    }

    func testWritingToolsCannotRemoveObjectsDuringASession() {
        let (engine, textView) = makeEngine()
        engine.writingToolsWillBegin()
        let box = NSRange(location: location(of: "\u{FFFC}Buy", in: engine), length: 1)
        textView.setSelectedRange(box)
        textView.insertText("rewritten", replacementRange: box)
        XCTAssertTrue(engine.objectIDs().contains(checklistID))
        // Prose changes are allowed.
        textView.insertText("Hi", replacementRange: NSRange(location: location(of: "Hello", in: engine), length: 5))
        engine.writingToolsDidEnd()
        XCTAssertEqual(engine.document().blocks[1].text, "Hi world")
        XCTAssertEqual(engine.writingToolsRecoveries, 0)
        XCTAssertTrue(engine.writingToolsProtectedRanges(in: NSRange(location: 0, length: engine.textStorage.length))
            .contains { engine.rangeContainsObject($0) })
    }

    /// Layer 2: a removal that slipped past the guard is recovered, and
    /// neither Undo nor Redo can bring the loss back.
    func testWritingToolsRecoveryCannotBeUndoneOrRedoneIntoObjectLoss() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        type("!", textView)                                     // an earlier step of the person's own
        let before = engine.document()
        engine.writingToolsWillBegin()
        let whole = NSRange(location: location(of: "Hello", in: engine), length: engine.textStorage.length - location(of: "Hello", in: engine))
        // A rewrite that reaches the storage without asking (bypassing the guard).
        engine.textStorage.replaceCharacters(in: whole, with: NSAttributedString(string: "All prose now."))
        XCTAssertTrue(engine.objectIDs().isEmpty)
        engine.writingToolsDidEnd()
        XCTAssertEqual(engine.document(), before, "objects and text restored")
        XCTAssertEqual(engine.writingToolsRecoveries, 1)
        XCTAssertFalse(engine.history.canRedo)
        engine.history.redo()
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        engine.history.undo()                                   // undoes the person's "!", nothing else
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        XCTAssertEqual(engine.document().blocks.last?.text, "End")
        engine.history.redo()
        XCTAssertEqual(engine.document(), before)
    }

    func testRefusedWritingToolsSessionIsFrozenAndRestoresExactly() throws {
        let (engine, textView) = makeEngine()
        type("!", textView)
        let before = engine.document()
        let undoBefore = engine.history.canUndo
        engine.onWritingToolsWillBegin = { false }
        engine.writingToolsWillBegin()
        XCTAssertEqual(engine.activity, .writingToolsRefused)
        let box = try XCTUnwrap(engine.objects().first?.1)
        engine.toggleCheckbox(atLineOf: box.location)
        engine.insertDate(NoteDay(year: 2026, month: 10, day: 2)!)
        XCTAssertFalse(engine.history.undo())
        XCTAssertFalse(engine.history.redo())
        XCTAssertFalse(engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "typed"), name: "Typing"))
        engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Rewrite")
        XCTAssertEqual(engine.checkpointDocument(), before)
        engine.writingToolsDidEnd()
        XCTAssertEqual(engine.document(), before)
        XCTAssertEqual(engine.history.canUndo, undoBefore)
        XCTAssertFalse(engine.history.canRedo)
        XCTAssertEqual(engine.activity, .idle)
    }

    func testImportedBatchIsOneUndoStepAndAnchorFollowsTyping() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Body")]))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        engine.beginImageImport()
        type(" plus", textView)
        let first = StagedNoteAttachment(id: UUID(), filename: "one.png", contentTypeIdentifier: "public.png",
                                         byteCount: 1, digest: String(repeating: "a", count: 64), data: Data([1]))
        let second = StagedNoteAttachment(id: UUID(), filename: "two.png", contentTypeIdentifier: "public.png",
                                          byteCount: 1, digest: String(repeating: "b", count: 64), data: Data([2]))
        XCTAssertTrue(engine.insertImportedImages([(first, nil), (second, nil)]))
        XCTAssertEqual(engine.document().title, "Title plus")
        XCTAssertEqual(engine.document().attachmentIDs, [first.id, second.id])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().title, "Title plus")
        XCTAssertTrue(engine.document().attachmentIDs.isEmpty)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document().attachmentIDs, [first.id, second.id])
    }

    func testImportAnchorClampsWhenItsParagraphIsDeleted() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Middle"), .text("After")]))
        let middle = location(of: "Middle", in: engine)
        textView.setSelectedRange(NSRange(location: middle + 3, length: 0))
        engine.beginImageImport()
        XCTAssertTrue(engine.performEdit(NSRange(location: middle, length: 6),
                                         with: NSAttributedString(string: ""), name: "Delete Middle"))
        let image = StagedNoteAttachment(id: UUID(), filename: "image.png", contentTypeIdentifier: "public.png",
                                         byteCount: 1, digest: String(repeating: "a", count: 64), data: Data([1]))
        XCTAssertTrue(engine.insertImportedImages([(image, nil)]))
        let blocks = engine.document().blocks
        let imageIndex = try? XCTUnwrap(blocks.firstIndex { $0.attachmentID == image.id })
        let afterIndex = try? XCTUnwrap(blocks.firstIndex { $0.text == "After" })
        XCTAssertNotNil(imageIndex)
        XCTAssertNotNil(afterIndex)
        if let imageIndex, let afterIndex { XCTAssertLessThan(imageIndex, afterIndex) }
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.document().attachmentIDs.isEmpty)
        XCTAssertFalse(engine.document().blocks.contains { $0.text == "Middle" })
    }

    // MARK: Object identity

    func testChecklistTickKeepsIdentityAndUndoes() {
        let (engine, _) = makeEngine()
        engine.toggleCheckbox(atLineOf: location(of: "Buy", in: engine))
        XCTAssertEqual(engine.document().blocks[2].id, checklistID)
        XCTAssertTrue(engine.document().blocks[2].checked)
        engine.history.undo()
        XCTAssertFalse(engine.document().blocks[2].checked)
        XCTAssertEqual(engine.document().blocks[2].id, checklistID)
    }

    func testCopyPasteMintsNewIDsAndCutPasteKeepsThem() {
        let (engine, textView) = makeEngine()
        let lines = NSRange(location: location(of: "\u{FFFC}Buy", in: engine),
                            length: location(of: "End", in: engine) - location(of: "\u{FFFC}Buy", in: engine))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-test-\(UUID().uuidString)"))
        XCTAssertTrue(engine.writeSelection(lines, to: pasteboard, types: [NoteEditorEngine.fragmentType, .string]))
        let data = pasteboard.data(forType: NoteEditorEngine.fragmentType)!

        // Copy then paste: new objects beside the originals.
        let end = engine.textStorage.length
        XCTAssertTrue(engine.paste(fragmentData: data, at: NSRange(location: end, length: 0)))
        let ids = engine.objectIDs()
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, 6, "no duplicate ids")
        XCTAssertEqual(Array(ids.prefix(3)), [checklistID, dateID, imageID])
        XCTAssertEqual(engine.document().attachmentIDs, [attachmentID, attachmentID], "same note: the same stored image")
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())

        // Cut then paste: the same objects.
        textView.setSelectedRange(lines)
        textView.delete(nil)
        XCTAssertTrue(engine.objectIDs().isEmpty)
        XCTAssertTrue(engine.paste(fragmentData: data, at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertEqual(Set(engine.objectIDs()), [checklistID, dateID, imageID])
        engine.history.undo()
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
        engine.history.redo()
        engine.history.redo()
        XCTAssertEqual(Set(engine.objectIDs()), [checklistID, dateID, imageID])
    }

    func testPasteIntoAnotherNoteCopiesImagesAndARefusedPasteLeavesNothingStaged() {
        let (source, _) = makeEngine()
        let all = NSRange(location: 0, length: source.textStorage.length)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-test-\(UUID().uuidString)"))
        XCTAssertTrue(source.writeSelection(all, to: pasteboard, types: [NoteEditorEngine.fragmentType]))
        let data = pasteboard.data(forType: NoteEditorEngine.fragmentType)!

        let provider = StubImages(bytes: [attachmentID: Data([9, 9])])
        let (destination, _) = makeEngine(NoteDocument(blocks: [.text("Other")]))
        destination.imageProvider = provider
        XCTAssertTrue(destination.paste(fragmentData: data, at: NSRange(location: destination.textStorage.length, length: 0)))
        let pasted = destination.document()
        XCTAssertTrue(Set(pasted.objectIDs).isDisjoint(with: [checklistID, dateID, imageID]))
        XCTAssertNotEqual(pasted.attachmentIDs.first, attachmentID, "copied into a new attachment for this note")
        XCTAssertEqual(destination.stagedAttachments(for: pasted).count, 1)

        // Read-only: the paste is refused and nothing is staged.
        let readOnly = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("RO")]), readOnly: true)
        readOnly.imageProvider = provider
        XCTAssertFalse(readOnly.paste(fragmentData: data, at: NSRange(location: 2, length: 0)))
        XCTAssertTrue(readOnly.staged.isEmpty)
    }

    func testChecklistReturnContinuesAndBackspaceRemovesTheBoxFirst() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "Buy cake", in: engine) + 8, length: 0))
        textView.insertNewline(nil)
        type("Milk", textView)
        let blocks = engine.document().blocks
        XCTAssertEqual(blocks[3].kind, .checklist)
        XCTAssertEqual(blocks[3].text, "Milk")
        XCTAssertNotEqual(blocks[3].id, checklistID)
        textView.setSelectedRange(NSRange(location: location(of: "Milk", in: engine), length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks[3].kind, .text)
        XCTAssertEqual(engine.document().blocks[3].text, "Milk")
    }

    // MARK: VoiceOver

    func testObjectsAreAccessibilityElements() {
        let (engine, textView) = makeEngine(window: true)
        let elements = engine.accessibilityElements(for: textView)
        XCTAssertEqual(elements.map { $0.accessibilityRole() }, [.checkBox, .button, .image])
        XCTAssertEqual(elements.first?.accessibilityLabel(), "Buy cake")
        XCTAssertEqual(elements.first?.accessibilityValue() as? Int, 0)
        XCTAssertTrue(elements[1].accessibilityLabel()?.hasPrefix("Date,") ?? false)
        XCTAssertTrue(textView.accessibilityChildren()?.contains { ($0 as AnyObject) === elements[0] } == false,
                      "elements are made per request")
        XCTAssertTrue(elements.first?.accessibilityPerformPress() ?? false)
        XCTAssertTrue(engine.document().blocks[2].checked)
        let spoken = textView.accessibilityAttributedString(for: NSRange(location: 0, length: engine.textStorage.length))
        var attached = 0
        spoken?.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: spoken?.length ?? 0)) { value, _, _ in
            if value != nil { attached += 1 }
        }
        XCTAssertEqual(attached, 3)
    }

    // MARK: Performance (5,000 lines, 100 objects)

    func testKeystrokeUpkeepOnAStressNote() throws {
        var blocks: [NoteBlock] = [.text("Stress")]
        for index in 0..<5_000 {
            guard index % 50 == 10 else {
                blocks.append(.text("Line \(index) with some ordinary words to wrap a little in a narrow panel."))
                continue
            }
            switch (index / 50) % 3 {
            case 0: blocks.append(.checklist("Item \(index)"))
            case 1:
                var line = NoteBlock.text("Due \u{FFFC} line \(index)")
                line.inlines = [NoteInline(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
                blocks.append(line)
            default: blocks.append(.image(attachmentID: UUID(), pixelWidth: 1200, pixelHeight: 600))
            }
        }
        let document = NoteDocument(blocks: blocks)
        XCTAssertEqual(document.objectIDs.count, 100)
        let (engine, textView) = makeEngine(document, window: true)
        textView.layoutSubtreeIfNeeded()
        let middle = location(of: "Line 2501 ", in: engine)
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.displayIfNeeded()
        var samples: [Double] = []
        var upkeep: [Double] = []
        for character in "the quick brown fox jumps over the lazy dog again and again!" {
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            textView.displayIfNeeded()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            upkeep.append(engine.lastUpkeepMilliseconds)
        }
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        let encoded = try NoteContentCodec.encode(engine.document())
        let encodeMs = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1_000_000
        func pct(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        let report = String(format: "NOTE-PERF keystroke median %.2f ms p95 %.2f ms max %.2f ms; upkeep median %.3f ms; document+encode %.1f ms (%d bytes)",
                            pct(samples, 0.5), pct(samples, 0.95), samples.max() ?? 0, pct(upkeep, 0.5), encodeMs, encoded.count)
        print(report)
        XCTContext.runActivity(named: report) { _ in }
        XCTAssertLessThan(pct(upkeep, 0.5), 5, "per-edit upkeep stays local")
    }

    func testTypingWithFiftyImagesAndFiles() {
        var blocks: [NoteBlock] = [.text("Objects")]
        for index in 0..<50 {
            blocks.append(.text("Paragraph \(index) with ordinary writing."))
            if index.isMultiple(of: 2) {
                blocks.append(.image(attachmentID: UUID(), pixelWidth: 1200, pixelHeight: 600))
            } else {
                blocks.append(.file(attachmentID: UUID(), filename: "plan-\(index).pdf",
                    contentTypeIdentifier: "com.adobe.pdf", byteCount: 1024))
            }
        }
        let (engine, textView) = makeEngine(NoteDocument(blocks: blocks), window: true)
        textView.layoutSubtreeIfNeeded()
        let location = location(of: "Paragraph 24", in: engine)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        var milliseconds: [Double] = []
        for character in "Typing while fifty note objects remain in the document." {
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            textView.displayIfNeeded()
            milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let sorted = milliseconds.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let report = String(format: "NOTE-50-OBJECTS keystroke median %.2f ms p95 %.2f ms max %.2f ms",
            median, p95, sorted.last ?? 0)
        print(report)
        XCTContext.runActivity(named: report) { _ in }
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .image }.count, 25)
        XCTAssertEqual(engine.document().blocks.filter { $0.kind == .file }.count, 25)
    }
    func testStructureCommandsValidationAndUndo() {
        let original = NoteDocument(blocks: [.text("Title"), .text("Hello world"), .text("Second")])
        let (engine, textView) = makeEngine(original)
        let hello = NSRange(location: location(of: "Hello", in: engine), length: 5)
        XCTAssertFalse(engine.validate(.paragraph(.heading(2)), selection: NSRange(location: 1, length: 0)).enabled)
        XCTAssertTrue(engine.validate(.paragraph(.heading(2)), selection: hello).enabled)
        XCTAssertTrue(engine.perform(.paragraph(.heading(2)), selection: hello))
        XCTAssertEqual(engine.document().blocks[1].style, "heading")
        XCTAssertEqual(engine.document().blocks[1].level, 2)
        XCTAssertEqual(engine.formattingState(for: hello).paragraph, .heading(2))
        XCTAssertTrue(engine.perform(.mark(.bold), selection: hello))
        XCTAssertEqual(engine.document().blocks[1].marks, [NoteMark(.bold, offset: 0, length: 5)])
        XCTAssertEqual(engine.formattingState(for: hello).marks[.bold], .on)
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.document().blocks[1].marks.isEmpty)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks[1].style, nil)
        textView.setSelectedRange(NSRange(location: hello.location, length: 0))
        XCTAssertTrue(engine.perform(.mark(.italic)))
        XCTAssertEqual(engine.history.undoActionName, "Italic")
        type("x", textView)
        XCTAssertEqual(engine.document().blocks[1].marks.first?.kind, .italic)
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.formattingState(for: NSRange(location: hello.location, length: 0)).marks[.italic], .off)
    }

    func testLargeSelectionFormattingStateTiming() {
        let blocks = [.text("Title")] + (0..<5_000).map { NoteBlock.text("Line \($0)") }
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        let selection = NSRange(location: 0, length: engine.textStorage.length)
        let start = CFAbsoluteTimeGetCurrent()
        let state = engine.formattingState(for: selection)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("formattingState 5,000 lines: \(elapsed)s")
        XCTContext.runActivity(named: String(format: "formattingState 5,000 lines: %.3f s", elapsed)) { _ in }
        XCTAssertEqual(state.marks[.bold], .off)
        XCTAssertLessThan(elapsed, 0.45, "formattingState took \(elapsed)s for 5,000 lines")
        let firstLine = (engine.textStorage.string as NSString).range(of: "Line 0")
        XCTAssertTrue(engine.perform(.mark(.bold), selection: firstLine))
        XCTAssertEqual(engine.formattingState(for: selection).marks[.bold], .mixed)
    }

    func testMarkdownHabitsAndLiteralUndo() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Hello")]))
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        type("# ", textView)
        XCTAssertEqual(engine.document().blocks[1].text, "Hello")
        XCTAssertEqual(engine.document().blocks[1].style, "heading")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks[1].text, "# Hello")
        let second = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        second.1.setSelectedRange(NSRange(location: 2, length: 0))
        type("**bold**", second.1)
        XCTAssertEqual(second.0.document().blocks[1].text, "bold")
        XCTAssertEqual(second.0.document().blocks[1].marks, [NoteMark(.bold, offset: 0, length: 4)])
        XCTAssertTrue(second.0.history.undo())
        XCTAssertEqual(second.0.document().blocks[1].text, "**bold**")
    }

    func testSlashDateAcceptCancelAndAliases() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        type("/da", textView)
        XCTAssertEqual(engine.slashSession?.query, "da")
        XCTAssertEqual(engine.slashSession?.items.map(\.kind), [.date])
        XCTAssertTrue(engine.acceptSlashItem(.date))
        XCTAssertEqual(engine.document().blocks[1].text, "/da")
        engine.cancelSlashDate()
        XCTAssertEqual(engine.document().blocks[1].text, "/da")
        let dateEngine = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        dateEngine.1.setSelectedRange(NSRange(location: 2, length: 0))
        type("/da", dateEngine.1)
        XCTAssertTrue(dateEngine.0.acceptSlashItem(.date))
        XCTAssertTrue(dateEngine.0.commitSlashDate(NoteDay(year: 2026, month: 10, day: 1)!))
        XCTAssertEqual(dateEngine.0.document().blocks[1].inlines.count, 1)
        XCTAssertTrue(dateEngine.0.history.undo())
        XCTAssertEqual(dateEngine.0.document().blocks[1].text, "/da")
        textView.setSelectedRange(NSRange(location: 2, length: 3))
        XCTAssertTrue(engine.pastePlainText("/num", at: textView.selectedRange()))
        XCTAssertNil(engine.slashSession, "paste is literal")
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type(" /num", textView)
        XCTAssertEqual(engine.slashSession?.items.map(\.kind), [.number])
    }

    func testEmptyBodyHeadingPersistsWhenTypingBeginsAndUndoes() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(engine.perform(.paragraph(.heading(2))))
        XCTAssertEqual(engine.document().blocks[1].style, "heading")
        type("A", textView)
        XCTAssertEqual(engine.document().blocks[1].style, "heading")
        XCTAssertEqual(engine.document().blocks[1].text, "A")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks[1].text, "")
        XCTAssertTrue(engine.history.undo())
        XCTAssertNil(engine.document().blocks[1].style)
    }

    func testFinalEmptyParagraphMetadataSurvivesSaveReopenTypingAndUndoRedo() throws {
        for (name, level, indent) in [("bullet", nil, 2), ("number", nil, 1), ("heading", 3, nil),
                                      ("quote", nil, 2), ("mono", nil, nil), ("body", nil, nil)] as [(String, Int?, Int?)] {
            var empty = NoteBlock.text("")
            empty.style = name; empty.level = level; empty.indent = indent
            empty.id = UUID(); empty.extras = ["future": .string("kept")]
            var original = NoteDocument(blocks: [.text("T"), empty]); original.refreshRequiredCapabilities()
            let saved = try NoteContentCodec.encode(original)
            let loaded = try XCTUnwrap(NoteContentCodec.decode(saved).document)
            let (engine, view) = makeEngine(loaded)
            XCTAssertEqual(engine.document(), loaded, name)
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            type("A", view)
            var written = empty; written.text = "A"
            XCTAssertEqual(engine.document().blocks.last, written, name)
            let typed = engine.document()
            let again = try XCTUnwrap(NoteContentCodec.decode(try NoteContentCodec.encode(typed)).document)
            XCTAssertEqual(makeEngine(again).0.document(), typed, name)
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.document(), loaded, "Undo restores empty metadata: \(name)")
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(engine.document(), typed, name)
        }
    }

    func testReopenedEmptyParagraphFormattingAndIndentAreUndoableWithoutLosingMetadata() throws {
        var empty = NoteBlock.text(""); empty.style = "bullet"; empty.indent = 1
        empty.id = UUID(); empty.extras = ["future": .string("kept")]
        var sibling = NoteBlock.text("Sibling", style: "bullet"); sibling.indent = 1
        var original = NoteDocument(blocks: [.text("T"), sibling, empty]); original.refreshRequiredCapabilities()
        let (engine, view) = makeEngine(original)
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        XCTAssertTrue(engine.perform(.indent))
        XCTAssertEqual(engine.document().blocks.last?.indent, 2)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), original)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document().blocks.last?.indent, 2)
        XCTAssertTrue(engine.perform(.paragraph(.heading(2))))
        XCTAssertEqual(engine.document().blocks.last?.style, "heading")
        XCTAssertEqual(engine.document().blocks.last?.id, empty.id)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document().blocks.last?.style, "bullet")
        XCTAssertEqual(engine.document().blocks.last?.indent, 2)
        XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.document().blocks.last?.level, 2)
        type("Hello", view)
        XCTAssertEqual(engine.document().blocks.last?.extras, empty.extras)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.last?.level, 2)
        XCTAssertEqual(engine.document().blocks.last?.text, "")
    }

    func testFinalEmptyParagraphFollowsEarlierEditsAndDisappearsWhenItsSeparatorIsRemoved() {
        var empty = NoteBlock.text(""); empty.style = "number"; empty.indent = 1
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Before"), empty]))
        let original = engine.document()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        type("More ", view)
        XCTAssertEqual(engine.document().blocks.last, empty)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), original)
        let end = engine.textStorage.length
        XCTAssertTrue(engine.performEdit(NSRange(location: end - 1, length: 1), with: NSAttributedString(), name: "Delete"))
        XCTAssertEqual(engine.document().blocks.count, 2)
        XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.document(), original)
    }

    func testTagPickerEditIsAnEditorUndoStep() {
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body")]))
        engine.setTagsFromPicker(["work"])
        XCTAssertEqual(engine.tags, ["work"])
        XCTAssertEqual(engine.history.undoActionName, "Edit Tags")
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.tags.isEmpty)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.tags, ["work"])
    }

    func testTagPickerUndoReplaysOnlyItsDeltaAfterExternalRefresh() {
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body")]))
        engine.setTags(["base"])
        engine.setTagsFromPicker(["base", "picker"])
        engine.setTags(["base", "picker", "external"])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(Set(engine.tags), ["base", "external"])
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(Set(engine.tags), ["base", "picker", "external"])
    }

    func testIndentedChecklistMarkerRemovalNormalizesAndRoundTripsThroughUndo() throws {
        var item = NoteBlock.checklist("Read")
        item.indent = 2
        item.marks = [NoteMark(.bold, offset: 0, length: 4)]
        for route in 0..<3 {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), item]))
            let line = location(of: String(NoteDocument.objectCharacter), in: engine)
            if route == 0 { view.setSelectedRange(NSRange(location: line + 1, length: 0)); view.deleteBackward(nil) }
            if route == 1 { view.setSelectedRange(NSRange(location: line + 1, length: 0)); engine.toggleChecklistLine() }
            if route == 2 { view.setSelectedRange(NSRange(location: line, length: 1)); view.deleteBackward(nil) }
            let block = engine.document().blocks[1]
            XCTAssertEqual(block.kind, route == 0 ? .checklist : .text)
            XCTAssertEqual(block.indent, route == 0 ? 1 : nil)
            XCTAssertEqual(block.marks, item.marks)
            XCTAssertNoThrow(try NoteContentCodec.encode(engine.document()))
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.document().blocks[1], item)
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(engine.document().blocks[1].indent, route == 0 ? 1 : nil)
        }
        let (empty, view) = makeEngine(NoteDocument(blocks: [.text("T"), {
            var block = NoteBlock.checklist("")
            block.indent = 2
            return block
        }()]))
        view.setSelectedRange(NSRange(location: empty.textStorage.length, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(empty.document().blocks[1].kind, .checklist)
        XCTAssertEqual(empty.document().blocks[1].indent, 1)
        XCTAssertNoThrow(try NoteContentCodec.encode(empty.document()))
    }

    func testStyledFragmentCopyAndPastePreservesMarksDatesAndImageIdentity() throws {
        var heading = NoteBlock.text("Head \u{FFFC}", style: "heading")
        heading.level = 2
        heading.marks = [NoteMark(.bold, offset: 0, length: 5)]
        heading.inlines = [NoteInline(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        let image = NoteBlock.image(attachmentID: UUID())
        let (source, _) = makeEngine(NoteDocument(blocks: [.text("T"), heading, image]))
        let range = NSRange(location: 2, length: source.textStorage.length - 2)
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(source.writeSelection(range, to: board, types: [NoteEditorEngine.fragmentType, .string]))
        let bytes = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
        guard case let .editable(fragment) = NoteContentCodec.decode(bytes, context: .fragment) else { return XCTFail() }
        XCTAssertEqual(fragment.blocks.first?.style, "heading")
        XCTAssertEqual(fragment.blocks.first?.marks, heading.marks)
        XCTAssertEqual(fragment.blocks.first?.inlines.count, 1)
        let (target, _) = makeEngine(NoteDocument(blocks: [.text("Other"), .text("")]))
        let provider = StubImages(bytes: [image.attachmentID!: Data([9, 9])])
        target.imageProvider = provider
        XCTAssertTrue(target.paste(fragmentData: bytes, at: NSRange(location: 6, length: 0)))
        XCTAssertTrue(target.document().blocks.contains { $0.style == "heading" && !$0.marks.isEmpty })
        let partial = NSPasteboard.withUniqueName()
        XCTAssertTrue(source.writeSelection(NSRange(location: 2, length: 4), to: partial,
                                            types: [NoteEditorEngine.fragmentType]))
        let partialBytes = try XCTUnwrap(partial.data(forType: NoteEditorEngine.fragmentType))
        guard case let .editable(partialDocument) = NoteContentCodec.decode(partialBytes, context: .fragment) else { return XCTFail() }
        XCTAssertEqual(partialDocument.blocks.first?.text, "Head")
        XCTAssertEqual(partialDocument.blocks.first?.style, "heading")
    }

    func testSlashTargetsInvalidateOnDeletionSelectionAndUndo() {
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        type("/da", view)
        view.deleteBackward(nil)
        XCTAssertEqual(engine.slashSession?.query, "d")
        type("a", view)
        XCTAssertTrue(engine.acceptSlashItem(.date))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(engine.commitSlashDate(NoteDay(year: 2026, month: 10, day: 1)!))
        XCTAssertEqual(engine.document().blocks[1].text, "/da")
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type(" /da", view)
        XCTAssertNotNil(engine.slashSession)
        XCTAssertTrue(engine.history.undo())
        XCTAssertFalse(engine.acceptSlashItem(.date))
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        type(" /im", view)
        var request: NoteSlashFileRequest?
        engine.onSlashFileRequest = { request = $0 }
        XCTAssertTrue(engine.acceptSlashItem(.imageOrFile))
        let image = StagedNoteAttachment(id: UUID(), filename: "x.png", contentTypeIdentifier: "public.png",
                                         byteCount: 0, digest: "", data: Data())
        XCTAssertTrue(engine.performEdit(NSRange(location: 2, length: 0),
                                         with: NSAttributedString(string: "before "), name: "Edit"))
        let before = engine.textStorage.string
        XCTAssertFalse(engine.commitSlashImage(image, pixelSize: nil, for: try XCTUnwrap(request)))
        XCTAssertEqual(engine.textStorage.string, before)
    }

    func testDateUsesCapturedRangeAndLinkTargetRevalidatesCaretEdit() {
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Visit site")]))
        let body = NSRange(location: location(of: "site", in: engine), length: 4)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(engine.perform(.date(NoteDay(year: 2026, month: 10, day: 1)!), selection: body))
        XCTAssertEqual(engine.document().blocks[0].text, "Title")
        XCTAssertEqual(engine.document().blocks[1].inlines.count, 1)
        XCTAssertFalse(engine.perform(.date(NoteDay(year: 2026, month: 10, day: 1)!),
                                      selection: NSRange(location: 0, length: 0)))
        XCTAssertFalse(engine.perform(.date(NoteDay(year: 2026, month: 10, day: 1)!), selection: NSRange(location: 999, length: 0)))
        XCTAssertFalse(engine.perform(.date(NoteDay(year: 2026, month: 10, day: 1)!),
                                      selection: NSRange(location: NSNotFound, length: 1)))
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.perform(.link("https://one.example"), selection: body))
        view.setSelectedRange(NSRange(location: body.location + 2, length: 0))
        var captured: NoteLinkTarget?
        engine.onLinkRequest = { captured = $0 }
        XCTAssertTrue(engine.perform(.mark(.link)))
        let target = captured!
        XCTAssertEqual(target.range, body)
        XCTAssertEqual(target.url, "https://one.example")
        XCTAssertTrue(engine.commitLink("https://two.example", target: target))
        XCTAssertEqual(engine.document().blocks[1].marks.first(where: { $0.kind == .link })?.url, "https://two.example")
        XCTAssertTrue(engine.perform(.mark(.link)))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(engine.commitLink("https://three.example", target: captured!))
    }

    func testChecklistTypingBoldDelimiterRunsAndDividerReturnUndo() {
        for literal in ["-[] ", "- [ ] ", "- [x] "] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
            view.setSelectedRange(NSRange(location: 2, length: 0))
            type(literal, view)
            XCTAssertEqual(engine.document().blocks[1].kind, .checklist, literal)
            XCTAssertEqual(engine.document().blocks[1].checked, literal.contains("x"), literal)
            XCTAssertTrue(engine.history.undo())
            // Owner's Fix G-01: restore the real pre-conversion bullet, not
            // invented body text (phase2/owner-decisions.md, 2026-10-15).
            let wasBullet = literal.hasPrefix("- ")
            XCTAssertEqual(engine.document().blocks[1].text, wasBullet ? String(literal.dropFirst(2)) : literal, literal)
            XCTAssertEqual(engine.document().blocks[1].style, wasBullet ? "bullet" : nil, literal)
            XCTAssertEqual(engine.document().blocks[1].kind, .text, literal)
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(engine.document().blocks[1].kind, .checklist, literal)
        }
        let (bold, boldView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        boldView.setSelectedRange(NSRange(location: 2, length: 0))
        type("say **bold**", boldView)
        XCTAssertEqual(bold.document().blocks[1].text, "say bold")
        XCTAssertEqual(bold.document().blocks[1].marks, [NoteMark(.bold, offset: 4, length: 4)])
        let (divider, dividerView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("---")]))
        dividerView.setSelectedRange(NSRange(location: divider.textStorage.length, length: 0))
        dividerView.insertNewline(nil)
        XCTAssertEqual(divider.document().blocks[1].kind, .divider)
        XCTAssertTrue(divider.history.undo())
        XCTAssertTrue(divider.textStorage.string.contains("---\n"))
        XCTAssertTrue(divider.history.redo())
        let (mono, monoView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("---", style: "mono")]))
        monoView.setSelectedRange(NSRange(location: mono.textStorage.length, length: 0))
        monoView.insertNewline(nil)
        XCTAssertFalse(mono.document().blocks.contains { $0.kind == .divider })
        var codeLine = NoteBlock.text("---")
        codeLine.marks = [NoteMark(.code, offset: 0, length: 3)]
        let (code, codeView) = makeEngine(NoteDocument(blocks: [.text("T"), codeLine]))
        codeView.setSelectedRange(NSRange(location: code.textStorage.length, length: 0))
        codeView.insertNewline(nil)
        XCTAssertFalse(code.document().blocks.contains { $0.kind == .divider })
    }

    func testListIdentityNumberingAndPendingIndent() {
        var child = NoteBlock.text("Child", style: "number")
        child.indent = 1
        let blocks: [NoteBlock] = [.text("T"), .text("Parent", style: "number"), child, .text("Again", style: "number")]
        let (engine, view) = makeEngine(NoteDocument(blocks: blocks))
        let first = location(of: "Parent", in: engine)
        let middle = location(of: "Child", in: engine)
        let last = location(of: "Again", in: engine)
        let rootLists = (engine.textStorage.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle)?.textLists
        let childLists = (engine.textStorage.attribute(.paragraphStyle, at: middle, effectiveRange: nil) as? NSParagraphStyle)?.textLists
        let lastLists = (engine.textStorage.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle)?.textLists
        XCTAssertTrue(rootLists?.first === childLists?.first)
        XCTAssertTrue(rootLists?.first === lastLists?.first)
        XCTAssertEqual(childLists?.count, 2)
        XCTAssertEqual(engine.accessibilityParagraphs(in: NSRange(location: last, length: 5)).first?.listOrdinal, 2)
        view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.last?.style, "number")
        XCTAssertTrue(engine.perform(.indent))
        XCTAssertEqual(engine.document().blocks.last?.indent, 1)
        XCTAssertEqual(engine.formattingState(for: NSRange(location: engine.textStorage.length, length: 0)).indent, 1)
        XCTAssertTrue(engine.history.undo())
        XCTAssertNil(engine.document().blocks.last?.indent)
        XCTAssertTrue(engine.history.redo())
        type("Next", view)
        XCTAssertEqual(engine.document().blocks.last?.indent, 1)
    }

    func testReturnAndPendingTabDepthAtEverySupportedListLevel() {
        for depth in 0...2 {
            var number = NoteBlock.text("Parent", style: "number")
            number.indent = depth == 0 ? nil : depth
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), number]))
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            view.insertNewline(nil)
            XCTAssertEqual(engine.document().blocks.last?.indent ?? 0, depth)
            if depth < 2 {
                XCTAssertTrue(engine.perform(.indent))
                XCTAssertEqual(engine.document().blocks.last?.indent, depth + 1)
                XCTAssertTrue(engine.perform(.outdent))
                XCTAssertEqual(engine.document().blocks.last?.indent ?? 0, depth)
            }
            type("Child", view)
            XCTAssertEqual(engine.document().blocks.last?.style, "number")
            XCTAssertEqual(engine.document().blocks.last?.indent ?? 0, depth)

            var checklist = NoteBlock.checklist("Item")
            checklist.indent = depth == 0 ? nil : depth
            let (boxes, boxView) = makeEngine(NoteDocument(blocks: [.text("T"), checklist]))
            boxView.setSelectedRange(NSRange(location: boxes.textStorage.length, length: 0))
            boxView.insertNewline(nil)
            XCTAssertEqual(boxes.document().blocks.last?.kind, .checklist)
            XCTAssertEqual(boxes.document().blocks.last?.indent ?? 0, depth)
        }
    }

    func testOverlappingMarksComposeActualFontTraits() {
        var block = NoteBlock.text("Bold Italic Code")
        block.marks = [NoteMark(.bold, offset: 0, length: 16), NoteMark(.italic, offset: 0, length: 16),
                       NoteMark(.code, offset: 12, length: 4)]
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), block]))
        let start = location(of: "Bold", in: engine)
        func traits(_ at: Int) -> NSFontDescriptor.SymbolicTraits {
            (engine.textStorage.attribute(.font, at: at, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits
        }
        XCTAssertTrue(traits(start).contains(.bold))
        XCTAssertTrue(traits(start).contains(.italic))
        XCTAssertTrue(traits(start + 12).contains(.monoSpace))
        engine.restyle(NSRange(location: start, length: block.text.utf16.count))
        XCTAssertTrue(traits(start).contains(.bold))
        XCTAssertTrue(traits(start).contains(.italic))
        XCTAssertTrue(engine.perform(.mark(.italic), selection: NSRange(location: start, length: 4)))
        XCTAssertTrue(traits(start).contains(.bold))
        XCTAssertFalse(traits(start).contains(.italic))
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(traits(start).contains(.italic))
        let (plain, plainView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Plain")]))
        plainView.setSelectedRange(NSRange(location: plain.textStorage.length, length: 0))
        XCTAssertTrue(plain.perform(.mark(.bold)))
        XCTAssertTrue(plain.perform(.mark(.italic)))
        let typing = plainView.typingAttributes[.font] as? NSFont
        XCTAssertTrue(typing?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(typing?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        XCTAssertTrue(plain.history.undo())
        let afterUndo = plainView.typingAttributes[.font] as? NSFont
        XCTAssertTrue(afterUndo?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertFalse(afterUndo?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        let (inline, inlineView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        inlineView.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(inline.perform(.mark(.italic)))
        type("**word**", inlineView)
        let word = location(of: "word", in: inline)
        let inlineFont = inline.textStorage.attribute(.font, at: word, effectiveRange: nil) as? NSFont
        XCTAssertTrue(inlineFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(inlineFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    func testRichPasteKeepsLargeBodyAndUnsupportedListKindsLiteral() throws {
        let source = NSMutableAttributedString(string: "Large small\nAlpha\nRoman\nDeep")
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 24), range: NSRange(location: 0, length: 5))
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 6, length: 5))
        let alpha = NSMutableParagraphStyle()
        alpha.textLists = [NSTextList(markerFormat: .lowercaseAlpha, options: 0)]
        source.addAttribute(.paragraphStyle, value: alpha, range: NSRange(location: 12, length: 6))
        let roman = NSMutableParagraphStyle()
        roman.textLists = [NSTextList(markerFormat: .uppercaseRoman, options: 0)]
        source.addAttribute(.paragraphStyle, value: roman, range: NSRange(location: 18, length: 6))
        let deep = NSMutableParagraphStyle()
        deep.textLists = (0..<4).map { _ in NSTextList(markerFormat: .decimal, options: 0) }
        source.addAttribute(.paragraphStyle, value: deep, range: NSRange(location: 24, length: 4))
        let rtf = try source.data(from: NSRange(location: 0, length: source.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        XCTAssertTrue(engine.pasteRichText(rtf, type: .rtf, at: NSRange(location: 2, length: 0)))
        let blocks = engine.document().blocks
        XCTAssertFalse(blocks.contains { $0.style == "heading" || $0.style == "bullet" || $0.style == "number" })
        XCTAssertTrue(blocks.map(\.text).contains { $0.contains("Large small") })
        XCTAssertTrue(blocks.map(\.text).contains { $0.contains("Alpha") && $0.contains("a") })
        XCTAssertTrue(blocks.map(\.text).contains { $0.contains("Roman") && $0.contains("I") })
        XCTAssertTrue(blocks.map(\.text).contains { $0.contains("Deep") && $0.contains("1") })
    }

    func testShiftedNumericShortcutsUseRealKeyEventsAndReservedChordsAreAbsent() {
        for (code, shifted, style) in [(UInt16(26), "&", NoteParagraphStyle.bullet),
                                       (UInt16(28), "*", .number), (UInt16(25), "(", .checklist)] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body")]))
            view.setSelectedRange(NSRange(location: 2, length: 0))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: shifted, charactersIgnoringModifiers: shifted,
                                        isARepeat: false, keyCode: code)!
            XCTAssertTrue(engine.handleShortcut(event))
            XCTAssertEqual(engine.paragraphStyle(at: 2), style)
        }
        XCTAssertEqual(NoteFormatCommand.paragraph(.quote).shortcut, "⌥⌘4")
        XCTAssertEqual(NoteFormatCommand.paragraph(.mono).shortcut, "⌥⌘5")
        for (code, key, modified, style) in [(UInt16(21), "4", "¢", NoteParagraphStyle.quote),
                                            (UInt16(23), "5", "∞", .mono)] {
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body"), .text("Untouched")]))
            view.setSelectedRange(NSRange(location: 2, length: 0))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: modified, charactersIgnoringModifiers: key,
                                        isARepeat: false, keyCode: code)!
            XCTAssertTrue(engine.handleShortcut(event))
            XCTAssertEqual(engine.paragraphStyle(at: 2), style)
            XCTAssertNil(engine.document().blocks[2].style)
        }
        let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body")]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        for (key, code) in [("q", UInt16(12)), ("m", UInt16(46))] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: key, charactersIgnoringModifiers: key,
                                        isARepeat: false, keyCode: code)!
            XCTAssertFalse(engine.handleShortcut(event))
        }
    }
    #endif

    #if ATTIC_GENERATED_TESTS
    func testEditingSequenceFuzzRoundTripsAfterSplitsJoinsMovesAndMarks() throws {
        let (engine, _) = makeEngine(NoteDocument(blocks: [
            .text("T"), .text("abcdefgh"), .checklist("object"), .text("tail")
        ]))
        var seed: UInt64 = 0xA771C
        func next() -> Int {
            seed = 2862933555777941757 &* seed &+ 3037000493
            return Int((seed >> 32) % 4)
        }
        for step in 0..<96 {
            switch next() {
            case 0:
                let joined = (engine.textStorage.string as NSString).range(of: "abc\ndefgh")
                let whole = (engine.textStorage.string as NSString).range(of: "abcdefgh")
                if joined.location != NSNotFound {
                    let location = joined.location + 3
                    XCTAssertTrue(engine.performEdit(NSRange(location: location, length: 1), with: NSAttributedString(), name: "Join"))
                } else if whole.location != NSNotFound {
                    let location = whole.location + 3
                    XCTAssertTrue(engine.performEdit(NSRange(location: location, length: 0),
                                                     with: NSAttributedString(string: "\n"), name: "Split"))
                }
            case 1, 2:
                let box = location(of: String(NoteDocument.objectCharacter), in: engine)
                _ = engine.perform(next() == 1 ? .moveUp : .moveDown,
                                   selection: NSRange(location: box, length: 0))
            default:
                let target = next() == 0 ? "bc" : "ef"
                let at = location(of: target, in: engine)
                XCTAssertTrue(engine.perform(.mark(next() == 0 ? .bold : .italic),
                                             selection: NSRange(location: at, length: 2)))
            }
            let document = engine.document()
            let bytes = try NoteContentCodec.encode(document)
            guard case let .editable(decoded) = NoteContentCodec.decode(bytes) else { return XCTFail("step \(step)") }
            XCTAssertEqual(decoded.blocks, document.blocks, "step \(step)")
            XCTAssertEqual(NoteTextKitRoundTrip.document(afterRoundTrip: document).blocks, document.blocks, "step \(step)")
        }
    }
    #endif

    #if !ATTIC_GENERATED_TESTS
    func testListContinuationIndentMarkerFirstBackspaceAndMove() {
        let initial = NoteDocument(blocks: [.text("T"), .text("Previous", style: "bullet"), .text("First"), .text("Second")])
        let (engine, textView) = makeEngine(initial)
        let first = location(of: "First", in: engine)
        XCTAssertTrue(engine.perform(.paragraph(.bullet), selection: NSRange(location: first, length: 0)))
        XCTAssertEqual(engine.document().blocks[2].style, "bullet")
        XCTAssertTrue(engine.perform(.indent, selection: NSRange(location: first, length: 0)))
        XCTAssertEqual(engine.document().blocks[2].indent, 1)
        textView.setSelectedRange(NSRange(location: first + 5, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks[3].style, "bullet")
        textView.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks[3].style, "bullet")
        XCTAssertNil(engine.document().blocks[3].indent, "First Backspace lifts one level")
        textView.deleteBackward(nil)
        XCTAssertNil(engine.document().blocks[3].style, "Next Backspace removes the marker")
        XCTAssertTrue(engine.perform(.moveDown, selection: NSRange(location: first, length: 0)))
        XCTAssertEqual(engine.document().blocks[2].text, "")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks[2].text, "First")
    }

    func testListContinuationAtEndKeepsStyleForNextTypedCharacter() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Item")]))
        XCTAssertTrue(engine.perform(.paragraph(.number), selection: NSRange(location: 2, length: 0)))
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.last?.style, "number")
        type("Next", textView)
        XCTAssertEqual(engine.document().blocks.last?.style, "number")
        XCTAssertEqual(engine.document().blocks.last?.text, "Next")
    }

    func testMoveAcrossFinalParagraphPreservesSeparatorAndIdentity() {
        let dateID = UUID()
        var last = NoteBlock.text("Due \u{FFFC}")
        last.inlines = [NoteInline(id: dateID, kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Above"), last]))
        let due = location(of: "Due", in: engine)
        XCTAssertTrue(engine.perform(.moveUp, selection: NSRange(location: due, length: 0)))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", last.text, "Above"])
        XCTAssertEqual(engine.document().blocks[1].inlines.first?.id, dateID)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks[2].inlines.first?.id, dateID)
    }

    func testPlainPasteKeepsMarkdownLiteralAndLinkIsMarked() {
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        XCTAssertTrue(engine.pastePlainText("**raw** https://example.com", at: NSRange(location: 2, length: 0)))
        let block = engine.document().blocks[1]
        XCTAssertEqual(block.text, "**raw** https://example.com")
        XCTAssertFalse(block.marks.contains(where: { $0.kind == .bold }))
        XCTAssertEqual(block.marks.first(where: { $0.kind == .link })?.url, "https://example.com")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks[1].text, "")
    }

    func testRichPasteMapsSupportedMarksAndKeepsText() throws {
        let source = NSMutableAttributedString(string: "Source")
        source.addAttributes([.font: NSFont.boldSystemFont(ofSize: 14),
                              .link: URL(string: "https://example.com")!],
                             range: NSRange(location: 0, length: source.length))
        let rtf = try source.data(from: NSRange(location: 0, length: source.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        XCTAssertTrue(engine.pasteRichText(rtf, type: .rtf, at: NSRange(location: 2, length: 0)))
        let block = engine.document().blocks[1]
        XCTAssertTrue(block.text.contains("Source"))
        XCTAssertTrue(block.marks.contains(where: { $0.kind == .bold }))
        XCTAssertTrue(block.marks.contains(where: { $0.kind == .link && $0.url == "https://example.com" }))
    }

    func testAccessibilityHeadingAndListValues() {
        var heading = NoteBlock.text("Heading", style: "heading")
        heading.level = 3
        let list = NoteBlock.text("Item", style: "bullet")
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), heading, list]))
        XCTAssertEqual(engine.headingRanges().map(\.headingLevel), [1, 3])
        let bodyRange = NSRange(location: location(of: "Heading", in: engine), length: 7)
        let spoken = textView.accessibilityAttributedString(for: bodyRange)
        let headingKey = NSAttributedString.Key(NSAccessibility.Attribute.headingLevelAttribute.rawValue)
        XCTAssertEqual(spoken?.attribute(headingKey, at: 0, effectiveRange: nil) as? Int, 3)
        let item = NSRange(location: location(of: "Item", in: engine), length: 4)
        let listSpoken = textView.accessibilityAttributedString(for: item)
        XCTAssertNotNil(listSpoken?.attribute(.accessibilityListItemPrefix, at: 0, effectiveRange: nil))
        let (numberEngine, numberView) = makeEngine(NoteDocument(blocks: [
            .text("Title"), .text("First", style: "number"), .text("Second", style: "number")
        ]))
        let second = NSRange(location: location(of: "Second", in: numberEngine), length: 6)
        let numbered = numberView.accessibilityAttributedString(for: second)
        let prefix = numbered?.attribute(.accessibilityListItemPrefix, at: 0, effectiveRange: nil) as? NSAttributedString
        XCTAssertEqual(prefix?.string, "2.")
    }

    func testEveryParagraphStyleUsesTheSameValidationAndUndo() {
        let choices: [NoteParagraphStyle] = [.heading(1), .heading(2), .heading(3),
                                             .bullet, .number, .checklist, .quote, .mono]
        for choice in choices {
            let original = NoteDocument(blocks: [.text("T"), .text("Body")])
            let (engine, _) = makeEngine(original)
            let selection = NSRange(location: 2, length: 0)
            XCTAssertTrue(engine.validate(.paragraph(choice), selection: selection).enabled, "\(choice)")
            XCTAssertTrue(engine.perform(.paragraph(choice), selection: selection), "\(choice)")
            XCTAssertEqual(engine.formattingState(for: selection).paragraph, choice, "\(choice)")
            XCTAssertTrue(engine.history.undo(), "\(choice)")
            XCTAssertEqual(engine.document().blocks, original.blocks, "\(choice)")
        }
    }

    func testEveryInlineMarkAndLinkUndo() {
        for kind in [NoteMark.Kind.bold, .italic, .underline, .strikethrough, .code, .highlight] {
            let original = NoteDocument(blocks: [.text("T"), .text("Body")])
            let (engine, _) = makeEngine(original)
            let selection = NSRange(location: 2, length: 4)
            XCTAssertTrue(engine.perform(.mark(kind), selection: selection), "\(kind)")
            XCTAssertEqual(engine.document().blocks[1].marks.first?.kind, kind, "\(kind)")
            XCTAssertTrue(engine.history.undo(), "\(kind)")
            XCTAssertEqual(engine.document().blocks, original.blocks, "\(kind)")
        }
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Body")]))
        let selection = NSRange(location: 2, length: 4)
        var requestedLink = false
        engine.onLinkRequest = { _ in requestedLink = true }
        XCTAssertEqual(NoteFormatCommand.mark(.link).shortcut, "⇧⌘K")
        XCTAssertTrue(engine.perform(.mark(.link), selection: selection))
        XCTAssertTrue(requestedLink)
        XCTAssertFalse(engine.validate(.link("javascript:bad"), selection: selection).enabled)
        XCTAssertTrue(engine.perform(.link("https://example.com"), selection: selection))
        XCTAssertEqual(engine.formattingState(for: selection).linkURL, "https://example.com")
        XCTAssertTrue(engine.perform(.removeLink, selection: selection))
        XCTAssertFalse(engine.document().blocks[1].marks.contains(where: { $0.kind == .link }))
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks[1].marks.first?.kind, .link)
    }

    func testMarkdownConversionExcludesTitleMonoPasteAndComposition() {
        let (titleEngine, titleView) = makeEngine(NoteDocument(blocks: [.text(""), .text("")]))
        titleView.setSelectedRange(NSRange(location: 0, length: 0))
        type("# ", titleView)
        XCTAssertEqual(titleEngine.document().blocks[0].text, "# ")
        let (monoEngine, monoView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("code", style: "mono")]))
        XCTAssertEqual(monoEngine.paragraphStyle(at: 2), .mono)
        monoView.setSelectedRange(NSRange(location: 2, length: 0))
        type("#", monoView)
        XCTAssertEqual(monoEngine.textStorage.attribute(.noteBlockStyle, at: 2, effectiveRange: nil) as? String, "mono", "new first char")
        XCTAssertEqual(monoEngine.textStorage.attribute(.noteBlockStyle, at: 3, effectiveRange: nil) as? String, "mono", "old first char")
        XCTAssertEqual(monoEngine.paragraphStyle(at: 2), .mono, "typing at the paragraph start keeps its style")
        type(" ", monoView)
        XCTAssertEqual(monoEngine.document().blocks[1].text, "# code")
        XCTAssertEqual(monoEngine.document().blocks[1].style, "mono")
        let (pasteEngine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        XCTAssertTrue(pasteEngine.pastePlainText("# ", at: NSRange(location: 2, length: 0)))
        XCTAssertEqual(pasteEngine.document().blocks[1].text, "# ")
        XCTAssertNil(pasteEngine.document().blocks[1].style)
        let (imeEngine, imeView) = makeEngine(NoteDocument(blocks: [.text("T"), .text("")]))
        imeView.setSelectedRange(NSRange(location: 2, length: 0))
        imeView.setMarkedText("#", selectedRange: NSRange(location: 1, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        imeView.insertText("# ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(imeEngine.document().blocks[1].text, "# ")
        XCTAssertNil(imeEngine.document().blocks[1].style)
    }
    #endif
}

private final class StockUndoDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(undoManager: UndoManager) { manager = undoManager }
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

@MainActor
private final class StubImages: NoteImageProviding {
    let bytes: [UUID: Data]
    init(bytes: [UUID: Data]) { self.bytes = bytes }
    private(set) var fileRequests = 0
    func fileURL(forAttachment id: UUID) async -> URL? { fileRequests += 1; return nil }
    func filename(forAttachment id: UUID) -> String? { bytes[id] == nil ? nil : "shot.png" }
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment? {
        bytes[id].map { StagedNoteAttachment(id: id, filename: "shot.png", contentTypeIdentifier: "public.png",
                                             byteCount: Int64($0.count), digest: NotePayloadDigest.sha256($0), data: $0) }
    }
}

@MainActor
private final class HeldPreviewDecoder: NotePreviewDecoding {
    var onHeld: ((UUID) -> Void)?
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var thumbnailRequests = 0
    private(set) var requests: [UUID: Int] = [:]
    private let heldIDs: Set<UUID>?
    private var releasedAll = false

    init(heldIDs: Set<UUID>? = nil) { self.heldIDs = heldIDs }

    func header(id: UUID, data: Data?, url: URL?) async -> CGSize? {
        await NotePreviewDecoder().header(id: id, data: data, url: url)
    }

    func thumbnail(id: UUID, data: Data?, url: URL?, maxPixel: Int) async -> CGImage? {
        thumbnailRequests += 1
        requests[id, default: 0] += 1
        let image = await NotePreviewDecoder().thumbnail(id: id, data: data, url: url, maxPixel: maxPixel)
        if releasedAll { return image }
        if let heldIDs, !heldIDs.contains(id) { return image }
        await withCheckedContinuation { continuation in
            held[id] = continuation
            onHeld?(id)
        }
        return image
    }

    func release(_ id: UUID) { held.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        releasedAll = true
        let continuations = held.values
        held.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private final class GatedViewportImages: NoteImageProviding {
    private var continuation: CheckedContinuation<URL?, Never>?
    private var released = false
    private(set) var requested = false
    func fileURL(forAttachment id: UUID) async -> URL? {
        requested = true
        if released { return nil }
        return await withCheckedContinuation { continuation = $0 }
    }
    func filename(forAttachment id: UUID) -> String? { "pending.png" }
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment? { nil }
    func release() {
        released = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}


/// H14 find-only regressions. Unmounted views and fixture documents only.
@MainActor
final class PhaseXHunt14Tests: XCTestCase {
    private var scrollViews: [NSScrollView] = []

    private func editor(_ blocks: [NoteBlock]) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T")] + blocks))
        let (scroll, view) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        scrollViews.append(scroll)
        return (engine, view)
    }

    private func at(_ text: String, in engine: NoteEditorEngine) -> Int {
        (engine.textStorage.string as NSString).range(of: text).location
    }

    private func roundTrip(_ blocks: [NoteBlock]) throws -> [NoteBlock] {
        let markdown = NoteMarkdownExport.markdown(NoteDocument(blocks: [.text("T")] + blocks))
        return Array(try NoteMarkdownImport.document(markdown).blocks.dropFirst())
    }

    #if !ATTIC_GENERATED_TESTS
    func testH14_01MarkdownRoundTripKeepsLiteralDelimiters() throws {
        let literal = "Keep **these stars** and [this](https://example.com) literally"
        let restored = try roundTrip([.text(literal)])
        XCTAssertEqual(restored.map(\.text), [literal], "H14-01: export/import must not consume literal text as Markdown")
        XCTAssertEqual(restored.first?.marks, [], "H14-01: literal text must not acquire marks")
    }

    func testH14_02MarkdownRoundTripKeepsEmptyChecklistItems() throws {
        let blocks: [NoteBlock] = [.checklist("", checked: false), .checklist("", checked: true), .checklist("next")]
        let restored = try roundTrip(blocks)
        XCTAssertEqual(restored.map(\.text), blocks.map(\.text), "H14-02: empty tasks are real items")
        XCTAssertEqual(restored.map(\.kind), blocks.map(\.kind), "H14-02")
        XCTAssertEqual(restored.map(\.checked), blocks.map(\.checked), "H14-02")
    }

    func testH14_03PlainCalloutRoundTripKeepsLeadingEmojiAsText() throws {
        var box = NoteBlock.text("💡 Keep this emoji in the text", style: "quote"); box.callout = ""
        let restored = try roundTrip([box])
        XCTAssertEqual(restored.first?.text, box.text, "H14-03: a plain box must not consume its first text character as an icon")
        XCTAssertEqual(restored.first?.callout, "", "H14-03")
    }

    func testH14_04InlineCodeRoundTripKeepsEmbeddedBackticks() throws {
        var block = NoteBlock.text("Use `x` here")
        block.marks = [NoteMark(.code, offset: 0, length: (block.text as NSString).length)]
        let restored = try roundTrip([block])
        XCTAssertEqual(restored.first?.text, block.text, "H14-04: an inline code fence must exceed its content's backticks")
        XCTAssertEqual(restored.first?.marks, block.marks, "H14-04")
    }

    func testH14_05DeleteNumberedParentTransfersStartPastChildren() {
        var parent = NoteBlock.text("parent", style: "number"); parent.start = 12
        var child = NoteBlock.text("child", style: "number"); child.indent = 1
        let (engine, view) = editor([parent, child, .text("next", style: "number")])
        view.setSelectedRange(engine.paragraphRange(at: 2)); view.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "child", "next"])
        XCTAssertEqual(engine.listMarker(at: at("next", in: engine)), .number("12."), "H14-05: removing the first item must retain its run's start")
    }

    func testH14_06OutdentParentCarriesFinalEmptyChild() {
        var parent = NoteBlock.text("parent", style: "bullet"); parent.indent = 1
        var child = NoteBlock.text("", style: "bullet"); child.indent = 2
        let (engine, view) = editor([.text("root", style: "bullet"), parent, child])
        view.setSelectedRange(NSRange(location: at("parent", in: engine), length: 0))
        view.doCommand(by: #selector(NSTextView.insertBacktab(_:)))
        XCTAssertEqual(engine.document().blocks.map(\.indent), [nil, nil, nil, 1], "H14-06: terminal empty children belong to the subtree")
    }

    func testH14_07LeavingFirstCodeLineTransfersLanguageToRemainingRun() {
        var first = NoteBlock.text("first", style: "mono"); first.language = "swift"
        let (engine, view) = editor([first, .text("second", style: "mono")])
        view.setSelectedRange(NSRange(location: 2, length: 0)); view.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "first", "second"])
        XCTAssertNil(engine.document().blocks[1].style)
        XCTAssertEqual(engine.codeLanguage(at: at("second", in: engine)), "swift", "H14-07: D.1 #9 moves the run label to the next code line, including old-reader splits")
    }

    func testH14_08AdjacentCodeLanguagesSurviveExportImport() throws {
        let imported = try NoteMarkdownImport.document("# T\n\n```swift\nlet a = 1\n```\n\n```python\nprint(a)\n```")
        let exported = NoteMarkdownExport.markdown(imported)
        let restored = try NoteMarkdownImport.document(exported)
        XCTAssertEqual(restored.blocks.map(\.text), imported.blocks.map(\.text))
        XCTAssertEqual(restored.blocks.map(\.language), imported.blocks.map(\.language), "H14-08: separately pasted code blocks must keep their language")
    }
    #endif

    private struct H14Line: Equatable, CustomStringConvertible {
        var text: String
        var format: NoteParagraphStyle = .body
        var description: String { "\(format):\(text.debugDescription)" }
    }
    private struct H14Step: CustomStringConvertible {
        var kind: Int
        var a: Int
        var b: Int
        var description: String { "\(kind):\(a):\(b)" }
    }
    private struct H14RNG {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) & 0x7fffffff)
        }
    }
    private func h14Read(_ engine: NoteEditorEngine) -> [H14Line] {
        engine.document().blocks.dropFirst().map { block in
            let format: NoteParagraphStyle
            switch block.style {
            case "heading": format = .heading(block.level ?? 2)
            case "bullet": format = .bullet
            case "number": format = .number
            case "mono": format = .mono(language: block.language)
            case "quote": format = block.callout.map { .callout(icon: $0) } ?? .quote
            default: format = .body
            }
            return H14Line(text: block.text, format: format)
        }
    }
    /// The oracle holds only text and block kinds. It does not parse or use
    /// TextKit attributes to compute a new state. Coordinates come from it.
    private func h14Replay(_ steps: [H14Step]) -> (index: Int, reason: String)? {
        let (engine, view) = editor([.text("alpha"), .text("beta"), .text("")])
        defer { engine.detachView(); scrollViews.removeLast() }
        var model = [H14Line(text: "alpha"), H14Line(text: "beta"), H14Line(text: "")]
        var undo: [[H14Line]] = [], redo: [[H14Line]] = []
        let formats: [NoteParagraphStyle] = [.body, .bullet, .number, .heading(4), .callout(icon: "💡"), .mono(language: "swift")]
        func start(_ index: Int) -> Int { 2 + model.prefix(index).reduce(0) { $0 + ($1.text as NSString).length + 1 } }
        func run(_ index: Int) -> Range<Int> {
            let format = model[index].format
            guard format.isCode || format.isCallout else { return index..<(index + 1) }
            var lower = index, upper = index + 1
            func matches(_ other: NoteParagraphStyle) -> Bool { other == format }
            while lower > 0, matches(model[lower - 1].format) { lower -= 1 }
            while upper < model.count, matches(model[upper].format) { upper += 1 }
            return lower..<upper
        }
        for (index, step) in steps.enumerated() {
            let before = model
            let line = step.a % model.count
            let offset = step.b % ((model[line].text as NSString).length + 1)
            let caret = start(line) + offset
            view.setSelectedRange(NSRange(location: caret, length: 0))
            engine.history.breakCoalescing()
            let generation = engine.history.recordingGeneration
            switch step.kind {
            case 0:
                model[line].text = (model[line].text as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "x")
                _ = engine.performEdit(NSRange(location: caret, length: 0), with: NSAttributedString(string: "x", attributes: engine.attributes(forParagraphAt: caret)), name: "Insert")
            case 1:
                if offset < (model[line].text as NSString).length {
                    model[line].text = (model[line].text as NSString).replacingCharacters(in: NSRange(location: offset, length: 1), with: "")
                    _ = engine.performEdit(NSRange(location: caret, length: 1), with: NSAttributedString(), name: "Delete")
                }
            case 2:
                let format = formats[step.b % formats.count]
                let affected = (format.isCode && model[line].format.isCode) || (format.isCallout && model[line].format.isCallout) ? run(line) : line..<(line + 1)
                for row in affected { model[row].format = format }
                _ = engine.perform(.paragraph(format), selection: NSRange(location: caret, length: 0))
            case 3:
                if model[line].format.isCode {
                    let affected = run(line)
                    for row in affected { model[row].format = .mono(language: step.b % 2 == 0 ? "python" : "swift") }
                    _ = engine.setCodeLanguage(step.b % 2 == 0 ? "python" : "swift", at: caret)
                } else if model[line].format.isCallout {
                    let affected = run(line)
                    for row in affected { model[row].format = .callout(icon: step.b % 2 == 0 ? "" : "⚠️") }
                    _ = engine.setCalloutIcon(step.b % 2 == 0 ? "" : "⚠️", at: caret)
                }
            case 4:
                let source = run(line), target = run(step.b % model.count).lowerBound
                if target < source.lowerBound || target > source.upperBound {
                    let from = start(source.lowerBound), to = source.upperBound < model.count ? start(source.upperBound) : engine.textStorage.length
                    let destination = start(target)
                    let moved = Array(model[source])
                    model.removeSubrange(source)
                    model.insert(contentsOf: moved, at: target < source.lowerBound ? target : target - source.count)
                    _ = engine.moveBlock(NSRange(location: from, length: to - from), to: destination)
                }
            case 5:
                let old = model[line]
                let prefix = (old.text as NSString).substring(to: offset), suffix = (old.text as NSString).substring(from: offset)
                model[line].text = prefix + "P"
                let continuation: NoteParagraphStyle = old.format.isCode ? model[run(line).lowerBound].format : (old.format.isCallout ? old.format : .body)
                model.insert(H14Line(text: "Q" + suffix, format: continuation), at: line + 1)
                _ = engine.pastePlainText("P\nQ", at: NSRange(location: caret, length: 0))
            case 6:
                if let prior = undo.popLast() { redo.append(model); model = prior }
                _ = engine.history.undo()
            default:
                if let next = redo.popLast() { undo.append(model); model = next }
                _ = engine.history.redo()
            }
            if step.kind < 6, engine.history.recordingGeneration != generation { undo.append(before); redo.removeAll() }
            let actual = h14Read(engine)
            if actual != model {
                return (index, "command=\(step) requestedSelection=\(NSRange(location: caret, length: 0)) selections=\(view.selectedRanges) " +
                    "blockIDs=\(engine.document().blocks.map(\.id)) undo=\(engine.history.canUndo) redo=\(engine.history.canRedo) " +
                    "generation=\(engine.history.recordingGeneration) previousGeneration=\(generation) expectedUndoDepth=\(undo.count) expectedRedoDepth=\(redo.count); " +
                    "expected \(model), actual \(actual)")
            }
        }
        return nil
    }
    private func h14Shrink(_ steps: [H14Step], firstMismatch: Int) -> [H14Step] {
        var result = Array(steps.prefix(firstMismatch + 1))
        var size = max(1, result.count / 2)
        while size > 0 {
            var at = 0
            while at < result.count {
                var candidate = result
                candidate.removeSubrange(at..<min(result.count, at + size))
                if !candidate.isEmpty, h14Replay(candidate) != nil { result = candidate; at = 0 }
                else { at += size }
            }
            size /= 2
        }
        return result
    }
    #if ATTIC_GENERATED_TESTS
    func testH14_09GeneratedTextAndBlockKindsAgreeAfterEditingUndoAndRedo() {
        for seed in 1...128 {
            var random = H14RNG(state: UInt64(seed))
            let steps = (0..<40).map { _ in H14Step(kind: random.next() % 8, a: random.next(), b: random.next()) }
            if let failure = h14Replay(steps) {
                let first = "S24_FIRST_DIVERGENCE seed=\(seed) index=\(failure.index) steps=\(steps): \(failure.reason)"
                print(first)
                let attachment = XCTAttachment(string: first)
                attachment.name = "S24-first-divergent-state-before-shrinking"
                attachment.lifetime = .keepAlways
                add(attachment)
                let minimal = h14Shrink(steps, firstMismatch: failure.index)
                let reason = h14Replay(minimal)?.reason ?? failure.reason
                XCTFail("H14-09 (also covers H14-06/H14-10) seed \(seed), shrunk \(minimal): \(reason)")
                return
            }
        }
    }
    #endif


    #if !ATTIC_GENERATED_TESTS
    func testH14_09MultilinePlainPasteIntoEmptyNumberEndsInBody() {
        let (engine, view) = editor([.text("")])
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(engine.perform(.paragraph(.number)))
        XCTAssertTrue(engine.pastePlainText("P\nQ", at: view.selectedRange()))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "P", "Q"])
        XCTAssertEqual(engine.document().blocks.map(\.style), [nil, "number", nil], "H14-09: only the first plain-pasted paragraph inherits a list style")
    }

    func testH14_06CodeLanguageChangeIncludesFinalEmptyRunParagraph() {
        var code = NoteBlock.text("let a = 1", style: "mono"); code.language = "swift"
        var empty = NoteBlock.text("", style: "mono"); empty.language = "swift"
        let (engine, _) = editor([code, empty])
        XCTAssertTrue(engine.setCodeLanguage("python", at: 2))
        XCTAssertEqual(engine.document().blocks.dropFirst().map(\.language), ["python", "python"], "H14-06: whole-run commands include the pending terminal block")
    }

    func testH14_06CalloutIconChangeIncludesFinalEmptyRunParagraph() {
        var box = NoteBlock.text("Tip", style: "quote"); box.callout = "💡"
        var empty = NoteBlock.text("", style: "quote"); empty.callout = "💡"
        let (engine, _) = editor([box, empty])
        XCTAssertTrue(engine.setCalloutIcon("⚠️", at: 2))
        XCTAssertEqual(engine.document().blocks.dropFirst().map(\.callout), ["⚠️", "⚠️"], "H14-06: changing a box icon must not detach its empty final paragraph")
    }

    func testH14_10DeletingLastCharacterKeepsFinalBlockKind() {
        for format: NoteParagraphStyle in [.heading(4), .bullet, .number, .quote, .callout(icon: "💡"), .mono(language: "swift")] {
            let (engine, view) = editor([.text("")])
            view.setSelectedRange(NSRange(location: 2, length: 0))
            XCTAssertTrue(engine.perform(.paragraph(format)))
            view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            engine.history.breakCoalescing()
            view.deleteBackward(nil)
            XCTAssertEqual(engine.document().blocks.map(\.text), ["T", ""])
            XCTAssertEqual(engine.paragraphStyle(at: 2), format, "H14-10: deleting content must leave an empty \(format) until its exit key is pressed")
            let empty = engine.document().blocks[1]
            XCTAssertEqual(empty.style, format.storageName, "H14-10: save/reopen must retain the empty block kind")
            let reopened = NoteEditorEngine(noteID: UUID(), document: engine.document())
            XCTAssertEqual(reopened.paragraphStyle(at: 2), format, "H14-10: reopened empty block keeps its kind and hints")
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.document().blocks[1].text, "x")
            XCTAssertEqual(engine.paragraphStyle(at: 2), format)
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(engine.paragraphStyle(at: 2), format, "H14-10: Redo must retain the emptied block's kind")
        }
    }
    #endif

}

/// Additional coverage against the already-shipped language-boundary rules.
/// The retained hunt oracle above is unchanged pending orchestrator direction.
@MainActor
final class PhaseXFix14GeneratedTests: XCTestCase {
    private var scrollViews: [NSScrollView] = []
    private func editor(_ blocks: [NoteBlock]) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T")] + blocks))
        let (scroll, view) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        scrollViews.append(scroll)
        return (engine, view)
    }
    private struct Fix14Line: Equatable, CustomStringConvertible {
        var text: String
        var format: NoteParagraphStyle = .body
        var description: String { "\(format):\(text.debugDescription)" }
    }
    private struct Fix14Step: CustomStringConvertible {
        var kind: Int
        var a: Int
        var b: Int
        var description: String { "\(kind):\(a):\(b)" }
    }
    private struct Fix14RNG {
        var state: UInt64
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) & 0x7fffffff)
        }
    }
    private func fix14Read(_ engine: NoteEditorEngine) -> [Fix14Line] {
        engine.document().blocks.dropFirst().map { block in
            let format: NoteParagraphStyle
            switch block.style {
            case "heading": format = .heading(block.level ?? 2)
            case "bullet": format = .bullet
            case "number": format = .number
            case "mono": format = .mono(language: block.language)
            case "quote": format = block.callout.map { .callout(icon: $0) } ?? .quote
            default: format = .body
            }
            return Fix14Line(text: block.text, format: format)
        }
    }
    /// The oracle holds only text and block kinds. It does not parse or use
    /// TextKit attributes to compute a new state. Coordinates come from it.
    private func fix14Replay(_ steps: [Fix14Step]) -> (index: Int, reason: String)? {
        let (engine, view) = editor([.text("alpha"), .text("beta"), .text("")])
        defer { engine.detachView(); scrollViews.removeLast() }
        var model = [Fix14Line(text: "alpha"), Fix14Line(text: "beta"), Fix14Line(text: "")]
        var undo: [[Fix14Line]] = [], redo: [[Fix14Line]] = []
        let formats: [NoteParagraphStyle] = [.body, .bullet, .number, .heading(4), .callout(icon: "💡"), .mono(language: "swift")]
        func start(_ index: Int) -> Int { 2 + model.prefix(index).reduce(0) { $0 + ($1.text as NSString).length + 1 } }
        func run(_ index: Int) -> Range<Int> {
            let format = model[index].format
            guard format.isCode || format.isCallout else { return index..<(index + 1) }
            var lower = index, upper = index + 1
            func matches(_ other: NoteParagraphStyle) -> Bool { other == format }
            while lower > 0, matches(model[lower - 1].format) { lower -= 1 }
            while upper < model.count, matches(model[upper].format) { upper += 1 }
            return lower..<upper
        }
        for (index, step) in steps.enumerated() {
            let before = model
            let line = step.a % model.count
            let offset = step.b % ((model[line].text as NSString).length + 1)
            let caret = start(line) + offset
            view.setSelectedRange(NSRange(location: caret, length: 0))
            engine.history.breakCoalescing()
            let generation = engine.history.recordingGeneration
            switch step.kind {
            case 0:
                model[line].text = (model[line].text as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: "x")
                _ = engine.performEdit(NSRange(location: caret, length: 0), with: NSAttributedString(string: "x", attributes: engine.attributes(forParagraphAt: caret)), name: "Insert")
            case 1:
                if offset < (model[line].text as NSString).length {
                    model[line].text = (model[line].text as NSString).replacingCharacters(in: NSRange(location: offset, length: 1), with: "")
                    _ = engine.performEdit(NSRange(location: caret, length: 1), with: NSAttributedString(), name: "Delete")
                }
            case 2:
                let format = formats[step.b % formats.count]
                let affected = (format.isCode && model[line].format.isCode) || (format.isCallout && model[line].format.isCallout) ? run(line) : line..<(line + 1)
                for row in affected { model[row].format = format }
                _ = engine.perform(.paragraph(format), selection: NSRange(location: caret, length: 0))
            case 3:
                if model[line].format.isCode {
                    let affected = run(line)
                    for row in affected { model[row].format = .mono(language: step.b % 2 == 0 ? "python" : "swift") }
                    _ = engine.setCodeLanguage(step.b % 2 == 0 ? "python" : "swift", at: caret)
                } else if model[line].format.isCallout {
                    let affected = run(line)
                    for row in affected { model[row].format = .callout(icon: step.b % 2 == 0 ? "" : "⚠️") }
                    _ = engine.setCalloutIcon(step.b % 2 == 0 ? "" : "⚠️", at: caret)
                }
            case 4:
                let source = run(line), target = run(step.b % model.count).lowerBound
                if target < source.lowerBound || target > source.upperBound {
                    let from = start(source.lowerBound), to = source.upperBound < model.count ? start(source.upperBound) : engine.textStorage.length
                    let destination = start(target)
                    let moved = Array(model[source])
                    model.removeSubrange(source)
                    model.insert(contentsOf: moved, at: target < source.lowerBound ? target : target - source.count)
                    _ = engine.moveBlock(NSRange(location: from, length: to - from), to: destination)
                }
            case 5:
                let old = model[line]
                let prefix = (old.text as NSString).substring(to: offset), suffix = (old.text as NSString).substring(from: offset)
                model[line].text = prefix + "P"
                let continuation: NoteParagraphStyle = old.format.isCode ? model[run(line).lowerBound].format : (old.format.isCallout ? old.format : .body)
                model.insert(Fix14Line(text: "Q" + suffix, format: continuation), at: line + 1)
                _ = engine.pastePlainText("P\nQ", at: NSRange(location: caret, length: 0))
            case 6:
                if let prior = undo.popLast() { redo.append(model); model = prior }
                _ = engine.history.undo()
            default:
                if let next = redo.popLast() { undo.append(model); model = next }
                _ = engine.history.redo()
            }
            if step.kind < 6, engine.history.recordingGeneration != generation { undo.append(before); redo.removeAll() }
            let actual = fix14Read(engine)
            if actual != model { return (index, "expected \(model), actual \(actual)") }
        }
        return nil
    }
    private func fix14Shrink(_ steps: [Fix14Step], firstMismatch: Int) -> [Fix14Step] {
        var result = Array(steps.prefix(firstMismatch + 1))
        var size = max(1, result.count / 2)
        while size > 0 {
            var at = 0
            while at < result.count {
                var candidate = result
                candidate.removeSubrange(at..<min(result.count, at + size))
                if !candidate.isEmpty, fix14Replay(candidate) != nil { result = candidate; at = 0 }
                else { at += size }
            }
            size /= 2
        }
        return result
    }
    #if ATTIC_GENERATED_TESTS
    func testFix14GeneratedEditingWithLanguageBoundariesUndoAndRedo() {
        for seed in 1...1024 {
            var random = Fix14RNG(state: UInt64(seed))
            let steps = (0..<40).map { _ in Fix14Step(kind: random.next() % 8, a: random.next(), b: random.next()) }
            if let failure = fix14Replay(steps) {
                let minimal = fix14Shrink(steps, firstMismatch: failure.index)
                let reason = fix14Replay(minimal)?.reason ?? failure.reason
                XCTFail("Fix14 language-boundary replay seed \(seed), shrunk \(minimal): \(reason)")
                return
            }
        }
    }
    #endif


}
