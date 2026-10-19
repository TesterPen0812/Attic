import AppKit
import SwiftUI
import XCTest
@testable import Attic

@MainActor
final class RoundFX4Tests: XCTestCase {
    func testFX4PasteAndMatchStyleInsertsPlainClipboardAsOneUndoStep() throws {
        withClipboard { board in
            board.clearContents()
            board.setString("PASTE FX4", forType: .string)
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Before|")]))
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            let before = view.string
            view.pasteAsPlainText(nil)
            XCTAssertEqual(view.string, before + "PASTE FX4")
            XCTAssertEqual(engine.history.undoOps.count, 1)
            engine.undoCommand()
            XCTAssertEqual(view.string, before)
            engine.redoCommand()
            XCTAssertEqual(view.string, before + "PASTE FX4")
        }
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.close() }
        windows.removeAll()
    }

    private func makeEngine(_ document: NoteDocument) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: document)
        let (scroll, view) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        mount(scroll, responder: view)
        view.layoutSubtreeIfNeeded()
        return (engine, view)
    }

    @discardableResult
    private func mount(_ view: NSView, responder: NSResponder? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        if let responder { XCTAssertTrue(window.makeFirstResponder(responder)) }
        windows.append(window)
        return window
    }

    private func withClipboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            board.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        try body(board)
    }

    private enum Format: CaseIterable { case plain, rich, html, markdown }

    private func fill(_ board: NSPasteboard, _ format: Format, text: String) throws {
        board.clearContents()
        board.setString(text, forType: .string)
        switch format {
        case .plain: break
        case .rich:
            let source = NSAttributedString(string: text, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 32), .foregroundColor: NSColor.red])
            board.setData(try source.data(from: NSRange(location: 0, length: source.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        case .html:
            board.setString("<table><tr><td><b>\(text)</b></td></tr></table>", forType: .html)
        case .markdown:
            board.setString(text, forType: TasksTextExport.markdownType)
        }
    }

    func testMatchingStyleKeepsDestinationStyleAndLiteralMarkdownInTitleAndBody() throws {
        try withClipboard { board in
            for format in Format.allCases {
                for title in [true, false] {
                    try fill(board, format, text: "**literal** _FX4_")
                    var heading = NoteBlock.text("Before|", style: "heading")
                    heading.level = 2
                    let (engine, view) = makeEngine(NoteDocument(blocks: [.text("Title|"), heading]))
                    defer { engine.detachView() }
                    let location = title ? 6 : view.string.utf16.count
                    view.setSelectedRange(NSRange(location: location, length: 0))
                    let before = try NoteContentCodec.encode(engine.document())
                    let beforeText = view.string
                    let paragraphStyle = engine.paragraphStyle(at: location - 1)
                    let attributes = engine.textStorage.attributes(at: location - 1, effectiveRange: nil)
                    view.pasteAsPlainText(nil)
                    XCTAssertEqual(view.string, (beforeText as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "**literal** _FX4_"), "\(format), title=\(title)")
                    XCTAssertEqual(engine.paragraphStyle(at: location), paragraphStyle)
                    XCTAssertEqual(engine.textStorage.attribute(.font, at: location, effectiveRange: nil) as? NSFont, attributes[.font] as? NSFont)
                    XCTAssertTrue(engine.document().blocks[title ? 0 : 1].marks.isEmpty)
                    XCTAssertEqual(engine.history.undoOps.count, 1)
                    let after = try NoteContentCodec.encode(engine.document())
                    engine.undoCommand()
                    XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
                    engine.redoCommand()
                    XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
                }
            }
        }
    }

    func testExplicitNoteShortcutUsesMatchingStyleAction() throws {
        try withClipboard { board in
            try fill(board, .markdown, text: "**literal**")
            let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .text("Before|")]))
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .option, .shift], timestamp: 0,
                windowNumber: view.window!.windowNumber, context: nil, characters: "V",
                charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
            view.keyDown(with: event)
            XCTAssertEqual(view.string, "T\nBefore|**literal**")
            XCTAssertEqual(engine.history.undoOps.count, 1)
        }
    }

    func testCellMatchingStyleKeepsTabularTextInOneCellAndOneUndoStep() throws {
        try withClipboard { board in
            for format in Format.allCases {
                try fill(board, format, text: "a\tb\nc\td")
                let initial = NoteTable(texts: [["Header", "Other"], ["Before|", "Keep"]])
                let (engine, _) = makeEngine(NoteDocument(blocks: [.text("T"), .table(initial)]))
                defer { engine.detachView() }
                let attachment = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
                let position = NoteTable.Position(row: 1, column: 0)
                engine.enterTable(attachment, at: position, caret: .end)
                let editor = attachment.tableView.editor
                editor.insertText("x", replacementRange: editor.selectedRange())
                let before = attachment.table
                editor.pasteAsPlainText(nil)
                XCTAssertEqual(attachment.table[position].text, "Before|xa\tb\nc\td", "\(format)")
                XCTAssertEqual(editor.string, "Before|xa\tb\u{2028}c\td", "the live cell keeps one paragraph")
                XCTAssertEqual(attachment.table.rowCount, 2)
                XCTAssertEqual(attachment.table.columnCount, 2)
                XCTAssertTrue(attachment.table[position].marks.isEmpty)
                let after = attachment.table
                engine.undoCommand()
                XCTAssertEqual(attachment.table, before, "paste must not merge with earlier typing")
                engine.redoCommand()
                XCTAssertEqual(attachment.table, after)
            }
        }
    }

    func testSubtaskAndNativeRenameFieldPasteMatchesStyleAndUndoesOnce() throws {
        try withClipboard { board in
            for format in Format.allCases {
                try fill(board, format, text: "**literal**")
                let rename = NSTextField(string: "Before|")
                mount(rename, responder: rename)
                let renameEditor = try XCTUnwrap(rename.currentEditor() as? NSTextView)
                for view in [AtticSubtaskFieldEditor(), renameEditor] {
                    view.isRichText = false
                    view.allowsUndo = true
                    view.string = "Before|"
                    view.font = NSFont.systemFont(ofSize: 14)
                    if view !== renameEditor { mount(view, responder: view) }
                    view.setSelectedRange(NSRange(location: 7, length: 0))
                    view.pasteAsPlainText(nil)
                    XCTAssertEqual(view.string, "Before|**literal**", "\(format) \(type(of: view))")
                    XCTAssertEqual(view.font?.pointSize, 14)
                    view.breakUndoCoalescing()
                    view.undoManager?.undo()
                    XCTAssertEqual(view.string, "Before|")
                    view.undoManager?.redo()
                    XCTAssertEqual(view.string, "Before|**literal**")
                }
            }
        }
    }

    private struct LiveComposer {
        let state: TasksAddBarState
        let view: AtticTokenFieldView
        let coordinator: AtticTokenField.Coordinator
    }

    private func composer() -> LiveComposer {
        let state = TasksAddBarState()
        state.text.text = "Before|"
        state.selection = NSRange(location: 7, length: 0)
        let field = AtticTokenField(
            text: Binding(get: { state.text.text }, set: { state.text.text = $0 }),
            chips: [], isFocused: .constant(true), accessibilityLabel: "Add a task",
            actions: AtticTokenFieldActions(submit: { _ in }, dismissChip: { _ in },
                multilinePaste: { _ in XCTFail("matching style inserts text into the draft"); return false },
                escape: { false }, edited: { range, replacement in
                    state.history.willEdit(state.text, selection: state.currentSelection, range: range, replacement: replacement)
                    state.text.edited(range, replacement: replacement)
                }, caretMoved: { state.caret = $0 }, undoDraft: { state.undoDraft() },
                redoDraft: { state.redoDraft() }, selectionMoved: { state.selection = $0 }))
        let coordinator = field.makeCoordinator()
        let view = AtticTokenFieldView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        view.textView.delegate = coordinator
        view.textView.owner = coordinator
        coordinator.view = view
        view.textView.string = state.text.text
        mount(view, responder: view.textView)
        view.textView.setSelectedRange(NSRange(location: 7, length: 0))
        return LiveComposer(state: state, view: view, coordinator: coordinator)
    }

    func testTaskComposerPlainPasteIsOneDraftUndoStepForEveryClipboardFlavour() throws {
        try withClipboard { board in
            for format in Format.allCases {
                try fill(board, format, text: "**literal**")
                let bar = composer()
                withExtendedLifetime(bar.coordinator) {
                    bar.view.textView.pasteAsPlainText(nil)
                    XCTAssertEqual(bar.state.text.text, "Before|**literal**", "\(format)")
                    bar.view.textView.undo(nil)
                    XCTAssertEqual(bar.state.text.text, "Before|")
                    XCTAssertFalse(bar.state.history.canUndo)
                    bar.view.textView.redo(nil)
                    XCTAssertEqual(bar.state.text.text, "Before|**literal**")
                }
            }
        }
    }

    /// FX5: use the shipping panel's key-equivalent entry point. FX4's
    /// replacement Edit menu supplied a route the MenuBarExtra app lacks.
    func testFX5PanelKeyEquivalentReachesEveryTextInputWithoutAnEditMenu() throws {
        try withClipboard { board in
            let savedMenu = NSApp.mainMenu
            NSApp.mainMenu = NSMenu()
            defer { NSApp.mainMenu = savedMenu }

            @MainActor func check(_ root: NSView, responder: NSResponder, label: String) throws {
                let panel = AtticPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = root
                windows.append(panel)
                XCTAssertTrue(panel.makeFirstResponder(responder))
                let view = try XCTUnwrap(panel.firstResponder as? NSTextView, label)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
                let before = view.string
                let action = #selector(NSTextView.pasteAsPlainText(_:))
                let item = NSMenuItem(title: "Paste and Match Style", action: action, keyEquivalent: "V")
                XCTAssertTrue(view.validateMenuItem(item), label)
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command, .option, .shift], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "◊",
                    charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
                XCTAssertTrue(panel.performKeyEquivalent(with: event), label)
                XCTAssertEqual(view.string, before + "**FX5**", label)
                XCTAssertTrue(panel.firstResponder === view, label)
            }

            for format in Format.allCases {
                try fill(board, format, text: "**FX5**")
                for title in [false, true] {
                    let (engine, view) = makeEngine(NoteDocument(blocks: title
                        ? [.text("Title")] : [.text("Title"), .text("Body")]))
                    defer { engine.detachView() }
                    try check(view.enclosingScrollView!, responder: view, label: "\(format) title=\(title)")
                    XCTAssertEqual(engine.history.undoOps.count, 1)
                }
                let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"),
                    .table(NoteTable(texts: [["A", "B"], ["C", "D"]]))]))
                defer { engine.detachView() }
                let attachment = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
                engine.enterTable(attachment, at: NoteTable.Position(row: 1, column: 0), caret: .end)
                let before = attachment.table
                try check(view.enclosingScrollView!, responder: attachment.tableView.editor, label: "\(format) cell")
                XCTAssertEqual(attachment.table.texts, [["A", "B"], ["C**FX5**", "D"]])
                engine.undoCommand()
                XCTAssertEqual(attachment.table, before)
                engine.redoCommand()
                XCTAssertEqual(attachment.table.texts, [["A", "B"], ["C**FX5**", "D"]])
                let bar = composer()
                try withExtendedLifetime(bar.coordinator) {
                    try check(bar.view, responder: bar.view.textView, label: "\(format) composer")
                    XCTAssertEqual(bar.state.text.text, "Before|**FX5**")
                }
                let subtask = AtticSubtaskFieldEditor()
                subtask.isRichText = false
                subtask.string = "Subtask"
                try check(subtask, responder: subtask, label: "\(format) subtask")
                for field in [NSTextField(string: "Rename"), NSSearchField(string: "Search")] {
                    try check(field, responder: field, label: "\(format) \(type(of: field))")
                }
            }
        }
    }

    func testFX5MatchingStyleShortcutRespectsFocusEditabilityAndModifiers() throws {
        try withClipboard { board in
            try fill(board, .plain, text: "FX5")
            let panel = AtticPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            windows.append(panel)
            let view = NSTextView()
            view.string = "Before"
            panel.contentView = view
            XCTAssertTrue(panel.makeFirstResponder(view))
            let chord: NSEvent.ModifierFlags = [.command, .option, .shift]
            func event(_ flags: NSEvent.ModifierFlags, window: NSWindow? = nil, key: String = "V") throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: flags, timestamp: 0, windowNumber: (window ?? panel).windowNumber,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 9))
            }
            for flags: NSEvent.ModifierFlags in [[.command, .option], [.command, .shift], chord.union(.control)] {
                _ = panel.performKeyEquivalent(with: try event(flags))
                XCTAssertEqual(view.string, "Before")
            }
            _ = panel.performKeyEquivalent(with: try event(chord, key: "B"))
            XCTAssertEqual(view.string, "Before")
            let other = mount(NSView())
            XCTAssertFalse(panel.performKeyEquivalent(with: try event(chord, window: other)))
            XCTAssertEqual(view.string, "Before")
            view.isEditable = false
            XCTAssertFalse(panel.performKeyEquivalent(with: try event(chord)))
            XCTAssertEqual(view.string, "Before")
            view.isEditable = true
            XCTAssertTrue(panel.makeFirstResponder(panel))
            XCTAssertFalse(panel.performKeyEquivalent(with: try event(chord)))
            XCTAssertEqual(view.string, "Before")
            XCTAssertTrue(panel.makeFirstResponder(view))
            view.setSelectedRange(NSRange(location: 0, length: 6))
            XCTAssertTrue(panel.performKeyEquivalent(with: try event(chord)))
            XCTAssertEqual(view.string, "FX5", "the focused selection is replaced exactly once")
            board.clearContents()
            XCTAssertFalse(panel.performKeyEquivalent(with: try event(chord)))
            XCTAssertEqual(view.string, "FX5")
        }
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func testNativeMenuValidationActionAndKeyEquivalentReachEveryTextResponder() throws {
        try requireKeyWindowTests()
        try withClipboard { board in
            let savedMenu = NSApp.mainMenu
            let main = NSMenu()
            let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Edit")
            edit.submenu = menu
            main.addItem(edit)
            let action = #selector(NSTextView.pasteAsPlainText(_:))
            let item = NSMenuItem(title: "Paste and Match Style", action: action, keyEquivalent: "V")
            item.keyEquivalentModifierMask = [.command, .option, .shift]
            menu.addItem(item)
            NSApp.mainMenu = main
            defer { NSApp.mainMenu = savedMenu }

            @MainActor func check(_ initialView: NSTextView, root: NSView) throws {
                var view = initialView
                let panel = KeyPanel(contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 500),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.ignoresMouseEvents = true
                panel.contentView = root
                windows.append(panel)
                panel.orderFront(nil)
                panel.makeKey()
                let deadline = Date().addingTimeInterval(2)
                while NSApp.keyWindow !== panel, Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                    panel.makeKey()
                }
                if let field = root as? NSTextField {
                    XCTAssertTrue(panel.makeFirstResponder(field))
                    view = try XCTUnwrap(field.currentEditor() as? NSTextView)
                } else {
                    XCTAssertTrue(panel.makeFirstResponder(view))
                }
                XCTAssertTrue(NSApp.keyWindow === panel)
                XCTAssertTrue(NSApp.target(forAction: action) as? NSTextView === view)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
                let before = view.string
                menu.update()
                XCTAssertTrue(item.isEnabled, "\(type(of: view)) must validate the native action")
                menu.performActionForItem(at: 0)
                XCTAssertEqual(view.string, before + "FX4", "targetless Edit menu action")
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command, .option, .shift], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "V",
                    charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
                XCTAssertTrue(main.performKeyEquivalent(with: event))
                XCTAssertEqual(view.string, before + "FX4FX4", "native menu key equivalent")
                panel.orderOut(nil)
            }

            for format in Format.allCases {
                try fill(board, format, text: "FX4")
                for title in [false, true] {
                    let (engine, view) = makeEngine(NoteDocument(blocks: title ? [.text("Title")] : [.text("Title"), .text("Body")]))
                    defer { engine.detachView() }
                    try check(view, root: view.enclosingScrollView!)
                }
                let bar = composer()
                try withExtendedLifetime(bar.coordinator) { try check(bar.view.textView, root: bar.view) }
                let subtask = AtticSubtaskFieldEditor()
                subtask.isRichText = false
                try check(subtask, root: subtask)
                let (engine, view) = makeEngine(NoteDocument(blocks: [.text("T"), .table(NoteTable(texts: [["A", "B"], ["C", "D"]]))]))
                defer { engine.detachView() }
                let attachment = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
                engine.enterTable(attachment, at: NoteTable.Position(row: 1, column: 0), caret: .end)
                try check(attachment.tableView.editor, root: view.enclosingScrollView!)
                let rename = NSTextField(string: "Rename")
                mount(rename, responder: rename)
                let editor = try XCTUnwrap(rename.currentEditor() as? NSTextView)
                try check(editor, root: rename)
            }
        }
    }
}
