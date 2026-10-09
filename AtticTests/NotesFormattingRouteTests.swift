import AppKit
import XCTest
@testable import Attic

/// A22: no windows, focus changes, app launches or attribute injection. Commands
/// enter through the models/menu actions/router and text is typed by NSTextView.
@MainActor
final class NotesFormattingRouteTests: XCTestCase {
    enum State: String, CaseIterable {
        case empty, end, middle, twoLines, lastEmpty, lastText, firstAfterTitle
        var document: NoteDocument {
            switch self {
            case .empty: NoteDocument(blocks: [.text("T"), .text("Before"), .text(""), .text("After")])
            case .lastEmpty: NoteDocument(blocks: [.text("T"), .text("Before"), .text("")])
            default: NoteDocument(blocks: [.text("T"), .text("First"), .text("Second"), .text("Last")])
            }
        }
        var selection: NSRange {
            switch self {
            case .empty, .lastEmpty: NSRange(location: 9, length: 0)
            case .end: NSRange(location: 7, length: 0)
            case .middle: NSRange(location: 4, length: 0)
            case .twoLines: NSRange(location: 3, length: 8)
            case .lastText: NSRange(location: 19, length: 0)
            case .firstAfterTitle: NSRange(location: 2, length: 0)
            }
        }
    }

    private func make(_ state: State) -> (NoteEditorEngine, NoteEditorTextView, NoteCommandRouter) {
        let engine = NoteEditorEngine(noteID: UUID(), document: state.document)
        let (_, view) = engine.makeView()
        view.setSelectedRange(state.selection)
        return (engine, view, NoteCommandRouter(engine: engine))
    }

    private func type(_ text: String, into view: NoteEditorTextView) {
        for character in text {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func run(_ command: NoteFormatCommand, surface: NoteCommandSurface,
                     router: NoteCommandRouter) -> Bool {
        switch surface {
        case .selectionBar, .formatBar:
            let model = NoteFormatModel(); model.router = router
            model.run(command, from: surface)
            return true
        case .noteMenu, .contextMenu, .menuBar:
            guard let row = router.formatMenuCommands(from: surface).first(where: {
                $0.identifier == NoteCommandRouter.identifier(command)
            }), !row.isDisabled else { return false }
            row.action()
            return true
        case .shortcut:
            guard let shortcut = NoteCommandCatalog.keyboardShortcut(command) else { return false }
            let codes: [String: UInt16] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
                "7": 26, "8": 28, "9": 25, "b": 11, "i": 34, "u": 32, "x": 7, "k": 40,
                "[": 33, "]": 30, "\r": 36, "\u{F700}": 126, "\u{F701}": 125]
            let key = String(shortcut.key.character)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: NoteCommandCatalog.modifierFlags(shortcut.modifiers), timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: codes[key] ?? 0)!
            return router.engine.handleShortcut(event)
        default: return router.run(command, from: surface)
        }
    }

    private var routes: [(NoteCommandSurface, [NoteFormatCommand])] {
        [(.selectionBar, NoteCommandCatalog.styles + NoteCommandCatalog.barMarks + NoteCommandCatalog.barInline),
         (.formatBar, NoteCommandCatalog.styles + NoteCommandCatalog.lists + NoteCommandCatalog.indents),
         (.noteMenu, NoteCommandCatalog.formatSections.flatMap { $0 }),
         (.contextMenu, NoteCommandCatalog.formatSections.flatMap { $0 }),
         (.menuBar, NoteCommandCatalog.formatSections.flatMap { $0 }),
         (.shortcut, NoteCommandCatalog.allCommands.filter { NoteCommandCatalog.keyboardShortcut($0) != nil })]
    }

    private func checkTyping(_ expected: NoteParagraphStyle, engine: NoteEditorEngine,
                             view: NoteEditorTextView, label: String) {
        let typed = view.selectedRange().location - 1
        XCTAssertEqual(engine.paragraphStyle(at: typed), expected, "\(label) typed block")
        let actual = engine.textStorage.attribute(.font, at: typed, effectiveRange: nil) as? NSFont
        let base = engine.style.paragraphAttributes(style: expected.storageName, level: expected.level, indent: nil)
        XCTAssertEqual(actual?.fontName, (base[.font] as? NSFont)?.fontName, "\(label) typed font")
        XCTAssertEqual(actual?.pointSize, (base[.font] as? NSFont)?.pointSize, "\(label) typed size")
        if expected == .quote {
            XCTAssertEqual(engine.textStorage.attribute(.foregroundColor, at: typed, effectiveRange: nil) as? NSColor,
                           engine.style.quoteColor, "\(label) typed quote ink")
        }
    }

    private func checkReturn(_ style: NoteParagraphStyle, engine: NoteEditorEngine,
                             view: NoteEditorTextView, label: String) {
        let before = engine.document().blocks
        let marks = Set(NoteMark.Kind.allCases.filter { $0 != .link && view.typingAttributes[.noteMark($0)] != nil })
        engine.history.breakCoalescing() // Isolate Return from the native typing run.
        view.insertNewline(nil)
        let expected: NoteParagraphStyle = if case .heading = style { .body } else { style }
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), expected, "\(label) Return block")
        if style == .quote || style == .mono {
            XCTAssertEqual(engine.history.undoActionName, style == .quote ? "Continue Quote" : "Continue Mono", label)
        }
        engine.history.breakCoalescing()
        type("R", into: view)
        let at = view.selectedRange().location - 1
        XCTAssertEqual(engine.paragraphStyle(at: at), expected, "\(label) typing after Return")
        for mark in marks {
            XCTAssertNotNil(engine.textStorage.attribute(.noteMark(mark), at: at, effectiveRange: nil),
                "\(label) mark after Return: \(mark)")
        }
        XCTAssertTrue(engine.history.undo(), "\(label) after-Return typing Undo")
        XCTAssertTrue(engine.history.undo(), "\(label) Return Undo")
        XCTAssertEqual(engine.document().blocks, before, "\(label) Return Undo restores")
    }

    func testEveryBlockRouteRestylesTypesReturnsAndUndoesInEveryState() {
        for (surface, commands) in routes {
            for command in commands {
                guard case let .paragraph(style) = command else { continue }
                for state in State.allCases {
                    let label = "\(surface.rawValue)/\(command.title)/\(state.rawValue)"
                    let (engine, view, router) = make(state)
                    if style == .body {
                        XCTAssertTrue(router.run(.paragraph(.heading(2)), from: surface))
                        engine.history.reset()
                    }
                    let original = engine.document().blocks
                    XCTAssertTrue(run(command, surface: surface, router: router), label)
                    let applied = engine.document().blocks
                    let appliedSelection = view.selectedRange()
                    for line in engine.formattableParagraphs(in: view.selectedRange()) {
                        XCTAssertEqual(engine.paragraphStyle(at: line.location), style, "\(label) current line")
                    }
                    XCTAssertTrue(engine.history.undo(), "\(label) command Undo")
                    XCTAssertEqual(engine.document().blocks, original, "\(label) one command Undo")
                    XCTAssertTrue(engine.history.redo(), label)
                    XCTAssertEqual(engine.document().blocks, applied, "\(label) command Redo")
                    view.setSelectedRange(appliedSelection)
                    type("XYZ", into: view)
                    checkTyping(style, engine: engine, view: view, label: label)
                    checkReturn(style, engine: engine, view: view, label: label)
                    print("A22_BLOCK route=\(label) line=\(style) typed=\(engine.document().blocks.map { $0.style ?? "body" })")
                }
            }
        }
    }

    func testEveryInlineRouteMarksSelectionOrNextTypingAndHasOneUndoStep() {
        for (surface, commands) in routes {
            for command in commands {
                guard case let .mark(kind) = command, kind != .link else { continue }
                for state in State.allCases {
                    let label = "\(surface.rawValue)/\(command.title)/\(state.rawValue)"
                    let (engine, view, router) = make(state)
                    let original = engine.document().blocks
                    let target = view.selectedRange()
                    XCTAssertTrue(run(command, surface: surface, router: router), label)
                    if state == .twoLines {
                        XCTAssertEqual(engine.validate(command, selection: view.selectedRange()).state, .on, label)
                    } else {
                        XCTAssertNotNil(view.typingAttributes[.noteMark(kind)], "\(label) pending mark")
                    }
                    XCTAssertTrue(engine.history.undo(), "\(label) command Undo")
                    XCTAssertEqual(engine.document().blocks, original, "\(label) one Undo")
                    XCTAssertEqual(engine.validate(command, selection: view.selectedRange()).state, .off, label)
                    XCTAssertTrue(engine.history.redo(), label)
                    if target.length > 0 { view.setSelectedRange(target) }
                    type("XYZ", into: view)
                    let at = view.selectedRange().location - 1
                    XCTAssertNotNil(engine.textStorage.attribute(.noteMark(kind), at: at, effectiveRange: nil), "\(label) typed mark")
                    checkReturn(.body, engine: engine, view: view, label: label)
                    print("A22_INLINE route=\(label) typed=\(kind)")
                }
            }
        }
    }

    func testEverySlashEntryInEveryStateThroughAcceptanceTypingReturnAndUndo() {
        let styles: [NoteSlashItem.Kind: NoteParagraphStyle] = [.title: .heading(1), .heading: .heading(2), .subheading: .heading(3),
            .body: .body, .bullet: .bullet,
            .number: .number, .checklist: .checklist, .quote: .quote, .mono: .mono]
        for kind in NoteSlashItem.Kind.allCases {
            for state in State.allCases {
                let label = "slash/\(kind.rawValue)/\(state.rawValue)"
                let (engine, view, _) = make(state)
                // A selection is replaced by typing; slash is permitted at line
                // start or after a space. Text in the middle/end stays on its line.
                if view.selectedRange().location != engine.lineRange(at: view.selectedRange().location).location {
                    type(" ", into: view)
                }
                type("/", into: view)
                XCTAssertTrue(engine.slashSession?.items.contains { $0.kind == kind } == true, label)
                let literal = engine.document().blocks
                XCTAssertTrue(engine.acceptSlashItem(kind), label)
                if kind == .date {
                    XCTAssertEqual(engine.document().blocks, literal, "\(label) picker leaves query")
                    XCTAssertTrue(engine.commitSlashDate(NoteDay(year: 2026, month: 10, day: 5)!), label)
                } else if kind == .imageOrFile {
                    XCTAssertEqual(engine.document().blocks, literal, "\(label) picker leaves query")
                    let request = engine.pendingSlashFile!
                    request.cancel()
                    XCTAssertEqual(engine.document().blocks, literal, "\(label) cancel leaves query")
                    // Re-open from the captured query, then commit a byte-backed file.
                    let next = engine.requestSlashFile(for: request.target)
                    let bytes = Data("A22 file contents".utf8)
                    let item = StagedNoteAttachment(id: UUID(), filename: "audit.txt", contentTypeIdentifier: "public.plain-text",
                        byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
                    XCTAssertTrue(engine.commitSlashObject(NoteImportedObject(staged: item, pixelSize: nil), for: next))
                }
                let applied = engine.document().blocks
                let appliedSelection = view.selectedRange()
                XCTAssertTrue(engine.history.undo(), "\(label) Undo")
                XCTAssertEqual(engine.document().blocks, literal, "\(label) one Undo restores slash")
                XCTAssertTrue(engine.history.redo(), label)
                XCTAssertEqual(engine.document().blocks, applied, "\(label) Redo")
                view.setSelectedRange(appliedSelection)
                type("XYZ", into: view)
                let style = styles[kind] ?? .body
                checkTyping(style, engine: engine, view: view, label: label)
                checkReturn(style, engine: engine, view: view, label: label)
                print("A22_SLASH route=\(label) typed=\(style)")
            }
        }
    }

    func testMarkdownRoutesTypeReturnAndLiteralUndoInEveryState() {
        let habits: [(String, NoteParagraphStyle?)] = [("# ", .heading(2)), ("## ", nil), ("- ", .bullet),
            ("* ", .bullet), ("1. ", .number), ("> ", .quote), ("-[] ", .checklist),
            ("- [ ] ", .checklist), ("- [x] ", .checklist), ("``` ", nil), ("[] ", nil)]
        for (prefix, expected) in habits {
            for state in State.allCases {
                let label = "markdown/\(prefix)/\(state.rawValue)"
                let (engine, view, _) = make(state)
                let atStart = view.selectedRange().location == engine.lineRange(at: view.selectedRange().location).location
                type(prefix, into: view)
                if let expected, atStart {
                    XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), expected, label)
                    let converted = engine.document().blocks
                    let convertedSelection = view.selectedRange()
                    XCTAssertTrue(engine.history.undo(), label)
                    XCTAssertTrue(engine.textStorage.string.contains(prefix), "\(label) literal Undo")
                    XCTAssertTrue(engine.history.redo(), label)
                    XCTAssertEqual(engine.document().blocks, converted, label)
                    view.setSelectedRange(convertedSelection)
                    type("XYZ", into: view)
                    checkTyping(expected, engine: engine, view: view, label: label)
                    checkReturn(expected, engine: engine, view: view, label: label)
                } else {
                    XCTAssertTrue(engine.textStorage.string.contains(prefix), "\(label) stays literal")
                    type("XYZ", into: view)
                    checkTyping(.body, engine: engine, view: view, label: label)
                    checkReturn(.body, engine: engine, view: view, label: label)
                }
                print("A22_MARKDOWN route=\(label) start=\(atStart) supported=\(expected != nil)")
            }
        }
    }

    func testInlineMarkdownAndDividerRoutesAcrossEveryState() {
        for state in State.allCases {
            for (literal, mark) in [("**bold**", NoteMark.Kind.bold), ("*italic*", .italic),
                                    ("_italic_", .italic), ("`code`", .code)] {
                let (engine, view, _) = make(state)
                type(literal, into: view)
                let formatted = engine.document().blocks
                XCTAssertTrue(formatted.contains { $0.marks.contains { $0.kind == mark } }, "\(literal)/\(state)")
                let caret = view.selectedRange()
                XCTAssertTrue(engine.history.undo())
                XCTAssertTrue(engine.textStorage.string.contains(literal), "literal Markdown Undo")
                XCTAssertTrue(engine.history.redo())
                XCTAssertEqual(engine.document().blocks, formatted)
                view.setSelectedRange(caret)
                type("XYZ", into: view)
                XCTAssertNotNil(engine.textStorage.attribute(.noteMark(mark), at: view.selectedRange().location - 1, effectiveRange: nil))
                checkReturn(.body, engine: engine, view: view, label: "markdown/\(literal)/\(state)")
                print("A22_INLINE_MARKDOWN route=markdown/\(literal)/\(state) typed=\(mark)")
            }
            let (engine, view, _) = make(state)
            type("---", into: view)
            engine.history.breakCoalescing()
            let eligible = state == .empty || state == .lastEmpty
            view.insertNewline(nil)
            XCTAssertEqual(engine.document().blocks.contains { $0.kind == .divider }, eligible, "divider/\(state)")
            if eligible {
                let converted = engine.document().blocks
                let caret = view.selectedRange()
                XCTAssertTrue(engine.history.undo())
                XCTAssertTrue(engine.textStorage.string.contains("---\n"))
                XCTAssertTrue(engine.history.redo())
                XCTAssertEqual(engine.document().blocks, converted)
                view.setSelectedRange(caret)
            }
            type("XYZ", into: view)
            checkTyping(.body, engine: engine, view: view, label: "markdown/divider/\(state)")
            checkReturn(.body, engine: engine, view: view, label: "markdown/divider/\(state)")
            print("A22_DIVIDER_MARKDOWN route=markdown/divider/\(state) converted=\(eligible)")
        }
    }

    func testOwnersExactSlashReturnTypingSequenceWithoutWindows() {
        for (query, expected) in [("/heading", NoteParagraphStyle.heading(2)), ("/quote", .quote), ("/list", .bullet)] {
            for state: State in [.empty, .lastEmpty] {
                let engine = NoteEditorEngine(noteID: UUID(), document: state.document)
                let (scroll, view) = engine.makeView()
                let controls = NoteFormatControls(engine: engine, textView: view, scrollView: scroll,
                    design: .default, noteID: engine.noteID, isNewDraft: false)
                defer { controls.invalidate() }
                view.setSelectedRange(state.selection)
                type(query, into: view)
                XCTAssertTrue(controls.slashModel.shown)
                // The same command selector delivered by AppKit's Return key.
                view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                XCTAssertNil(engine.slashSession)
                type("Styled text", into: view)
                checkTyping(expected, engine: engine, view: view, label: "owner/\(query)/\(state)")
                XCTAssertEqual(engine.paragraphStyle(at: state.selection.location), expected)
                XCTAssertTrue(engine.history.undo())
                XCTAssertEqual(engine.lineText(at: state.selection.location), "")
                XCTAssertTrue(engine.history.undo())
                XCTAssertTrue(engine.textStorage.string.contains(query), "one command Undo restores the query")
            }
        }
    }

    func testEveryAuxiliaryActionAndItsValidationTypingReturnUndo() {
        for (surface, commands) in routes {
            for command in commands where [.indent, .outdent, .toggleChecklist, .moveUp, .moveDown].contains(command) {
                for state in State.allCases {
                    let label = "\(surface)/\(command.title)/\(state)"
                    let (engine, view, router) = make(state)
                    if command == .indent || command == .outdent {
                        XCTAssertTrue(router.run(.paragraph(.bullet), from: surface))
                        if command == .outdent { XCTAssertTrue(router.run(.indent, from: surface)) }
                    } else if command == .toggleChecklist {
                        XCTAssertTrue(router.run(.paragraph(.checklist), from: surface))
                    }
                    engine.history.reset()
                    let before = engine.document().blocks
                    let enabled = router.validation(command).enabled
                    if !enabled {
                        XCTAssertFalse(engine.perform(command), label)
                        XCTAssertEqual(engine.document().blocks, before, label)
                        print("A22_ACTION route=\(label) disabled")
                        continue
                    }
                    XCTAssertTrue(run(command, surface: surface, router: router), label)
                    let after = engine.document().blocks
                    let caret = view.selectedRange()
                    switch command {
                    case .indent:
                        XCTAssertEqual(engine.formattingState(for: caret).indent, 1, label)
                    case .outdent:
                        XCTAssertEqual(engine.formattingState(for: caret).indent, 0, label)
                    case .toggleChecklist:
                        XCTAssertTrue(engine.checklistBox(inParagraphAt: caret.location)?.isChecked == true, label)
                    case .moveUp, .moveDown:
                        XCTAssertNotEqual(after, before, label)
                    default: break
                    }
                    XCTAssertTrue(engine.history.undo(), label)
                    XCTAssertEqual(engine.document().blocks, before, "\(label) one Undo")
                    XCTAssertTrue(engine.history.redo(), label)
                    XCTAssertEqual(engine.document().blocks, after, "\(label) Redo")
                    view.setSelectedRange(caret)
                    let style = engine.paragraphStyle(at: caret.location) ?? .body
                    type("XYZ", into: view)
                    checkTyping(style, engine: engine, view: view, label: label)
                    checkReturn(style, engine: engine, view: view, label: label)
                    print("A22_ACTION route=\(label) applied")
                }
            }
        }
    }

    func testChangingChecklistStylePreservesTheTwoLineSelectionAndNextReplacement() {
        for (surface, commands) in routes {
            for command in commands {
                guard case let .paragraph(style) = command else { continue }
                let label = "\(surface.rawValue)/\(command.title)/twoLines checklist transition"
                let (engine, view, router) = make(.twoLines)
                let selectedText = (view.string as NSString).substring(with: view.selectedRange())
                XCTAssertTrue(router.run(.paragraph(.checklist), from: surface))
                engine.history.reset()
                let checklist = engine.document().blocks
                XCTAssertTrue(run(command, surface: surface, router: router), label)
                let expectedStyle: NoteParagraphStyle = style == .checklist ? .body : style
                let selectedAfter = (view.string as NSString).substring(with: view.selectedRange())
                    .replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
                XCTAssertEqual(selectedAfter, selectedText, "\(label) selected text retained")
                let formatted = engine.document().blocks
                type("XYZ", into: view)
                XCTAssertEqual(engine.document().blocks[1].text, "FXYZond", "\(label) replacement scope")
                checkTyping(expectedStyle, engine: engine, view: view, label: label)
                XCTAssertTrue(engine.history.undo())
                XCTAssertEqual(engine.document().blocks, formatted, "\(label) typing Undo")
                XCTAssertTrue(engine.history.undo())
                XCTAssertEqual(engine.document().blocks, checklist, "\(label) command Undo")
            }
        }
    }

    func testListAndQuoteToggleOffConsistentlyIncludingFallbackShortcut() {
        for (surface, commands) in routes {
            for command in commands where NoteCommandCatalog.togglesOff(command) {
                for state in State.allCases {
                    let (engine, view, router) = make(state)
                    XCTAssertTrue(run(command, surface: surface, router: router))
                    let styled = engine.document().blocks
                    XCTAssertTrue(run(command, surface: surface, router: router))
                    XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .body,
                        "\(surface)/\(command.title)/\(state) toggle off")
                    XCTAssertTrue(engine.history.undo())
                    XCTAssertEqual(engine.document().blocks, styled, "one Undo restores the toggled style")
                }
            }
        }
    }

    func testLinkAndRemoveLinkAcrossRoutesAndStates() {
        for (surface, commands) in routes where commands.contains(.mark(.link)) {
            for state in State.allCases {
                let label = "\(surface)/Link/\(state)"
                let (engine, view, router) = make(state)
                if view.selectedRange().length == 0 {
                    // Link at a plain caret requires a selection, as in the
                    // actual card; the engine must refuse without changing text.
                    XCTAssertFalse(router.validation(.mark(.link)).enabled, label)
                    if engine.lineRange(at: view.selectedRange().location).length == 0 { continue }
                    let line = engine.lineRange(at: view.selectedRange().location)
                    view.setSelectedRange(NSRange(location: line.location, length: line.length))
                }
                let before = engine.document().blocks
                var target: NoteLinkTarget?
                engine.onLinkRequest = { target = $0 }
                XCTAssertTrue(run(.mark(.link), surface: surface, router: router), label)
                XCTAssertNotNil(target, label)
                guard let target else { continue }
                XCTAssertEqual(engine.document().blocks, before, "\(label) opening the card is not an edit")
                XCTAssertTrue(router.commitLink("https://example.com", target: target, from: surface))
                let applied = engine.document().blocks
                let selection = view.selectedRange()
                XCTAssertEqual(engine.validate(.removeLink, selection: selection).state, .on, label)
                XCTAssertTrue(engine.history.undo())
                XCTAssertEqual(engine.document().blocks, before, "\(label) one Undo")
                XCTAssertTrue(engine.history.redo())
                view.setSelectedRange(selection)
                XCTAssertTrue(router.run(.removeLink, from: surface))
                XCTAssertEqual(engine.document().blocks, before, label)
                XCTAssertTrue(engine.history.undo())
                XCTAssertEqual(engine.document().blocks, applied, "\(label) Remove Link Undo")
                view.setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
                type("XYZ", into: view)
                checkReturn(.body, engine: engine, view: view, label: label)
                print("A22_LINK route=\(label) applied")
            }
        }
    }

    func testInsertMenusDispatchDateFileAndDividerInEveryState() {
        for surface: NoteCommandSurface in [.noteMenu, .contextMenu, .menuBar] {
            for state in State.allCases {
                for action in NoteInsertAction.allCases {
                    let (engine, view, router) = make(state)
                    let before = engine.document().blocks
                    var dateRequested = false, fileRequested = false
                    router.requestDate = { dateRequested = true }
                    router.requestFile = { fileRequested = true }
                    let row = router.insertMenuCommands(from: surface).first { $0.identifier == "notes-menu-insert-" + action.rawValue }!
                    XCTAssertFalse(row.isDisabled)
                    row.action()
                    if action == .date {
                        XCTAssertTrue(dateRequested)
                        XCTAssertTrue(engine.perform(.date(NoteDay(year: 2026, month: 10, day: 5)!)))
                    } else if action == .imageOrFile {
                        XCTAssertTrue(fileRequested)
                        XCTAssertEqual(engine.document().blocks, before)
                        continue // Real file commit/cancel covered by the slash route.
                    }
                    let after = engine.document().blocks
                    let caret = view.selectedRange()
                    XCTAssertTrue(engine.history.undo())
                    XCTAssertEqual(engine.document().blocks, before)
                    XCTAssertTrue(engine.history.redo())
                    XCTAssertEqual(engine.document().blocks, after)
                    view.setSelectedRange(caret)
                    type("XYZ", into: view)
                    checkTyping(.body, engine: engine, view: view, label: "\(surface)/\(action)/\(state)")
                    checkReturn(.body, engine: engine, view: view, label: "\(surface)/\(action)/\(state)")
                }
            }
        }
    }

    func testEmptyListAndQuoteReturnExitsAndOneUndoRestores() {
        for style: NoteParagraphStyle in [.bullet, .number, .checklist, .quote] {
            for state: State in [.empty, .lastEmpty] {
                let (engine, view, router) = make(state)
                XCTAssertTrue(router.run(.paragraph(style), from: .formatBar))
                let styled = engine.document().blocks
                view.insertNewline(nil)
                XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .body, "\(style)/\(state)")
                XCTAssertTrue(engine.history.undo())
                XCTAssertEqual(engine.document().blocks, styled)
            }
        }
    }

    // MARK: A24 review fixes

    private func headingEngine(caret: Int) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("Plan")]))
        let (_, view) = engine.makeView()
        XCTAssertTrue(engine.perform(.paragraph(.heading(2)), selection: NSRange(location: 2, length: 0)))
        engine.history.reset()
        view.setSelectedRange(NSRange(location: caret, length: 0))
        return (engine, view)
    }

    func testReturnAtHeadingStartAddsABodyLineAboveAndKeepsTheHeading() {
        let (engine, view) = headingEngine(caret: 2)
        view.insertNewline(nil)
        let blocks = engine.document().blocks
        XCTAssertEqual(blocks.map(\.text), ["T", "", "Plan"])
        XCTAssertNil(blocks[1].style)
        XCTAssertEqual(blocks[2].style, "heading")
        XCTAssertEqual(view.selectedRange().location, 3, "the caret stays before the heading text")
        XCTAssertEqual(engine.paragraphStyle(at: 3), .heading(2))
        XCTAssertEqual(engine.paragraphStyle(at: 2), .body)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "Plan"])
        XCTAssertEqual(engine.document().blocks[1].style, "heading")
    }

    func testReturnInTheMiddleOfAHeadingSplitsIntoHeadingAndBody() {
        let (engine, view) = headingEngine(caret: 4)
        view.insertNewline(nil)
        let blocks = engine.document().blocks
        XCTAssertEqual(blocks.map(\.text), ["T", "Pl", "an"])
        XCTAssertEqual(blocks[1].style, "heading")
        XCTAssertNil(blocks[2].style)
        XCTAssertEqual(view.selectedRange().location, 5)
    }

    func testReturnAtTheEndOfAHeadingStartsABodyLine() {
        let (engine, view) = headingEngine(caret: 6)
        view.insertNewline(nil)
        let blocks = engine.document().blocks
        XCTAssertEqual(blocks.map(\.text), ["T", "Plan", ""])
        XCTAssertEqual(blocks[1].style, "heading")
        XCTAssertNil(blocks[2].style)
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .body)
    }

    /// Reloads `engine`'s document into a fresh engine, as a save and reopen does.
    private func reloaded(_ engine: NoteEditorEngine) -> NoteDocument {
        NoteEditorEngine(noteID: UUID(), document: engine.document()).document()
    }

    func testMultiLinePlainPasteIntoAChecklistItemKeepsOnlyTheFirstLineAChecklistItem() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .checklist("Item")]))
        _ = engine.makeView()
        XCTAssertTrue(engine.pastePlainText("a\nb\nc", at: NSRange(location: 7, length: 0)))
        for document in [engine.document(), reloaded(engine)] {
            XCTAssertEqual(document.blocks.map(\.text), ["T", "Itema", "b", "c"])
            XCTAssertEqual(document.blocks.map(\.kind), [.text, .checklist, .text, .text])
            XCTAssertNil(document.blocks[2].style)
            XCTAssertNil(document.blocks[3].style)
            let markdown = NoteMarkdownExport.markdown(document)
            XCTAssertEqual(markdown.components(separatedBy: "- [ ]").count - 1, 1, markdown)
        }
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "Item"])
    }

    func testMultiLinePlainPasteIntoHeadingQuoteAndBulletStylesOnlyTheFirstParagraph() {
        for style in ["heading", "quote", "bullet"] {
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("Plan", style: style)]))
            _ = engine.makeView()
            XCTAssertTrue(engine.pastePlainText("x\ny\nz", at: NSRange(location: 6, length: 0)), style)
            for document in [engine.document(), reloaded(engine)] {
                XCTAssertEqual(document.blocks.map(\.text), ["T", "Planx", "y", "z"], style)
                XCTAssertEqual(document.blocks[1].style, style)
                XCTAssertNil(document.blocks[2].style, style)
                XCTAssertNil(document.blocks[3].style, style)
            }
        }
    }

    func testReturnOnAnEmptyMonoLineExitsUnlessMoreCodeFollows() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("code", style: "mono")]))
        let (_, view) = engine.makeView()
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.map(\.style), [nil, "mono", "mono"], "the first Return continues the code")
        view.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["T", "code", ""])
        XCTAssertEqual(engine.paragraphStyle(at: view.selectedRange().location), .body, "an empty Mono line exits on Return")

        let inner = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks:
            [.text("T"), .text("a", style: "mono"), .text("", style: "mono"), .text("b", style: "mono")]))
        let (_, innerView) = inner.makeView()
        innerView.setSelectedRange(NSRange(location: 4, length: 0))
        innerView.insertNewline(nil)
        XCTAssertEqual(inner.document().blocks.map(\.style), [nil, "mono", "mono", "mono", "mono"],
                       "a blank line inside code stays code")
    }

    func testBoldTypedOnTheLineBreakDoesNotCarryOntoLaterLinesAfterOtherEdits() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("one"), .text("two")]))
        let (_, view) = engine.makeView()
        view.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(engine.perform(.mark(.bold)))
        view.insertNewline(nil)
        XCTAssertNotNil(view.typingAttributes[.noteMark(.bold)], "Return still carries bold onto the new line")
        // Moving to the start of the plain line by an edit that is not Return.
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.deleteBackward(nil)
        XCTAssertNil(view.typingAttributes[.noteMark(.bold)], "a backspace at a line start does not inherit bold")
    }
}
