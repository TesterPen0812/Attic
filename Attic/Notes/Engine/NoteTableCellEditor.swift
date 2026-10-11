import AppKit
import QuartzCore

/// The one live editor of a table: a stock TextKit 2 `NSTextView` laid over
/// the active cell, so typing, input methods, dictation, spelling and
/// Writing Tools work in a cell exactly as in the note.
///
/// - Its text is one paragraph (a line break inside the cell is U+2028),
///   in the body's 14 / 21 lines, the header row semibold.
/// - Each change becomes the model's at once (`NoteTableView.editorTextDidChange`),
///   one coalescing Undo step per cell in the note's own history; a
///   composition becomes a change when it is committed.
/// - Keys that cross a cell's edge go to the table: arrows at the text's
///   ends, Tab, Return, ⌥Return (a line break), Esc, ⌘A.
@MainActor
final class NoteTableCellEditor: NSTextView, NSTextViewDelegate {
    weak var table: NoteTableView?
    /// True while the editor's own text is being written to the model (the
    /// model's echo must not reload the editor).
    var isApplyingOwnEdit = false
    private var selectionBeforeEdit = NSRange(location: 0, length: 0)
    private var isHeader = false

    static func make(table: NoteTableView) -> NoteTableCellEditor {
        let content = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        content.addTextLayoutManager(layoutManager)
        content.primaryTextLayoutManager = layoutManager
        let editor = NoteTableCellEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 21), textContainer: container)
        editor.table = table
        editor.configure()
        return editor
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        table?.edgeCursor(atWindowPoint: event.locationInWindow)?.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        table?.edgeCursor(atWindowPoint: event.locationInWindow)?.set()
    }

    private func configure() {
        delegate = self
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = true
        isAutomaticTextReplacementEnabled = true
        isAutomaticQuoteSubstitutionEnabled = true
        isAutomaticDashSubstitutionEnabled = true
        smartInsertDeleteEnabled = true
        usesFindBar = false
        writingToolsBehavior = .complete
        allowedWritingToolsResultOptions = [.plainText]
        setAccessibilityIdentifier("note-table-cell")
        isHidden = true
    }

    /// Fonts and inks for the cell about to be edited.
    func prepare(header: Bool) {
        isHeader = header
        guard let table else { return }
        let style = table.style
        insertionPointColor = style.bodyColor
        typingAttributes = style.tableCellAttributes(header: header, alignment: alignment(for: table))
        isEditable = table.engine?.isReadOnly == false
        if let engine = table.engine {
            writingToolsBehavior = engine.isWritingToolsAvailableForCells ? .complete : .none
        }
    }

    private func alignment(for table: NoteTableView) -> NoteTable.Alignment {
        guard let cell = table.activeCell, table.table.columns.indices.contains(cell.column) else { return .left }
        return table.table.columns[cell.column].align
    }

    /// Shows `string`; keeps the caret where it was when asked (an Undo or
    /// an agent's change to the cell being edited).
    func load(_ string: NSAttributedString, keepingSelection: Bool) {
        let selection = selectedRange()
        guard let storage = textStorage else { return }
        if !keepingSelection || !storage.isEqual(to: string) {
            storage.setAttributedString(string)
        }
        if keepingSelection {
            let location = min(selection.location, storage.length)
            setSelectedRange(NSRange(location: location, length: min(selection.length, storage.length - location)))
        } else {
            setSelectedRange(NSRange(location: storage.length, length: 0))
        }
        textLayoutManager?.ensureLayout(for: textLayoutManager!.documentRange)
        needsDisplay = true
    }

    func place(_ caret: NoteTableCaret) {
        let length = textStorage?.length ?? 0
        switch caret {
        case .start: setSelectedRange(NSRange(location: 0, length: 0))
        case .end: setSelectedRange(NSRange(location: length, length: 0))
        case .all: setSelectedRange(NSRange(location: 0, length: length))
        case let .range(range):
            let location = min(range.location, length)
            setSelectedRange(NSRange(location: location, length: min(range.length, length - location)))
        case let .firstLine(x):
            let lines = lineFrames()
            let y = lines.first.map { $0.midY } ?? 10
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: NSPoint(x: max(0, x), y: y)), length: 0))
        case let .lastLine(x):
            let lines = lineFrames()
            let y = lines.last.map { $0.midY } ?? 10
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: NSPoint(x: max(0, x), y: y)), length: 0))
        }
    }

    // MARK: Geometry

    /// The laid-out text's height: whole lines, at least one.
    var contentHeight: CGFloat {
        let lineHeight = AtticNoteType.body.lineHeight
        let count = max(1, lineFrames().count)
        return CGFloat(count) * lineHeight
    }

    /// Each line's frame in the editor's coordinates, top to bottom.
    func lineFrames() -> [CGRect] {
        guard let layoutManager = textLayoutManager else { return [] }
        var frames: [CGRect] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                frames.append(bounds.offsetBy(dx: origin.x, dy: origin.y))
            }
            return true
        }
        return frames
    }

    /// The character ranges of the laid-out lines.
    private func lineRanges() -> [NSRange] {
        guard let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager else { return [] }
        var ranges: [NSRange] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let base = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                ranges.append(NSRange(location: base + line.characterRange.location, length: line.characterRange.length))
            }
            return true
        }
        return ranges
    }

    /// Whether the caret is on the cell's first (or last) line.
    func caretIsOnFirstLine() -> Bool {
        let ranges = lineRanges()
        guard ranges.count > 1 else { return true }
        let caret = selectedRange().location
        return caret < ranges[1].location || (caret == ranges[1].location && selectionAffinity == .upstream)
    }

    func caretIsOnLastLine() -> Bool {
        let ranges = lineRanges().filter { $0.length > 0 || $0.location > 0 }
        guard let last = ranges.last, ranges.count > 1 else { return true }
        return NSMaxRange(selectedRange()) >= last.location
    }

    /// The caret's x in the editor's coordinates.
    var caretX: CGFloat {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: selectedRange().location) else { return 0 }
        var x: CGFloat = 0
        layoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .selection,
                                            options: [.rangeNotRequired]) { _, frame, _, _ in
            x = frame.minX
            return false
        }
        return x
    }

    func characterIndex(atWindowPoint point: NSPoint) -> Int {
        characterIndexForInsertion(at: convert(point, from: nil))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if table?.engine?.find.handleKey(event) == true { return }
        if let table, let engine = table.engine, !hasMarkedText(), engine.handleTableShortcut(event, in: table) { return }
        let typing = event.charactersIgnoringModifiers?.isEmpty == false
            && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)
        guard typing else { return super.keyDown(with: event) }
        PerformanceSignposts.beginNoteKey()
        CATransaction.begin()
        CATransaction.setCompletionBlock { PerformanceSignposts.noteDidDraw() }
        super.keyDown(with: event)
        CATransaction.commit()
    }

    override func doCommand(by selector: Selector) {
        guard !hasMarkedText(), let table else { return super.doCommand(by: selector) }
        let selection = selectedRange()
        let length = textStorage?.length ?? 0
        switch selector {
        case #selector(insertTab(_:)): return table.tab(backward: false)
        case #selector(insertBacktab(_:)): return table.tab(backward: true)
        case #selector(insertNewline(_:)): return table.returnKey()
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            // ⌥Return: a line break inside the cell.
            return insertText(String(NoteTextCodec.cellLineBreak), replacementRange: selectedRange())
        case #selector(moveLeft(_:)), #selector(moveBackward(_:)):
            if selection.length == 0, selection.location == 0 { return table.cross(.left) }
        case #selector(moveRight(_:)), #selector(moveForward(_:)):
            if selection.length == 0, selection.location >= length { return table.cross(.right) }
        case #selector(moveUp(_:)):
            if caretIsOnFirstLine() { return table.cross(.up) }
        case #selector(moveDown(_:)):
            if caretIsOnLastLine() { return table.cross(.down) }
        case #selector(moveLeftAndModifySelection(_:)), #selector(moveBackwardAndModifySelection(_:)):
            if selection.location == 0, selection.length == 0 || selectionAffinity == .upstream { return table.extendSelection(.left) }
        case #selector(moveRightAndModifySelection(_:)), #selector(moveForwardAndModifySelection(_:)):
            if NSMaxRange(selection) >= length { return table.extendSelection(.right) }
        case #selector(moveUpAndModifySelection(_:)):
            if caretIsOnFirstLine(), selection.location == 0 || selection.length == 0 { return table.extendSelection(.up) }
        case #selector(moveDownAndModifySelection(_:)):
            if caretIsOnLastLine(), NSMaxRange(selection) >= length || selection.length == 0 { return table.extendSelection(.down) }
        case #selector(cancelOperation(_:)):
            // Esc: the cell, then the table.
            if let cell = table.activeCell { table.selectCells(NoteTableCellRange(anchor: cell, head: cell)) }
            return
        case #selector(selectAll(_:)):
            // ⌘A: the cell's text, then the whole table.
            if selection.location == 0, selection.length == length, let attachment = table.attachment {
                table.engine?.selectWholeTable(attachment)
                return
            }
        default:
            break
        }
        super.doCommand(by: selector)
    }

    override func insertNewline(_ sender: Any?) { doCommand(by: #selector(insertNewline(_:))) }
    override func insertTab(_ sender: Any?) { doCommand(by: #selector(insertTab(_:))) }
    override func insertBacktab(_ sender: Any?) { doCommand(by: #selector(insertBacktab(_:))) }
    override func cancelOperation(_ sender: Any?) { doCommand(by: #selector(cancelOperation(_:))) }
    override func selectAll(_ sender: Any?) {
        let selection = selectedRange()
        if selection.location == 0, selection.length == (textStorage?.length ?? 0), let table, let attachment = table.attachment {
            table.engine?.selectWholeTable(attachment)
            return
        }
        super.selectAll(sender)
    }

    // MARK: Changes

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        guard let engine = table?.engine, engine.allowsTableCellEdit else { return false }
        if !hasMarkedText() { selectionBeforeEdit = selectedRange() }
        return true
    }

    func textDidChange(_ notification: Notification) {
        table?.editorTextDidChange(selectionBefore: selectionBeforeEdit)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { selectionBeforeEdit = self.selectedRange() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // The row grows with a composition; the model waits for its commit.
        table?.refreshEditorHeight()
    }

    override func unmarkText() {
        super.unmarkText()
        table?.editorTextDidChange(selectionBefore: selectionBeforeEdit)
    }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        newTypingAttributes.filter { $0.key != .attachment && !NSAttributedString.Key.noteBookkeeping.contains($0.key) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        table?.engine?.tableSelectionDidChange(table)
    }

    // MARK: Writing Tools (the note's safety copy first, as in the note)

    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        table?.engine?.writingToolsWillBegin()
    }

    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        table?.engine?.writingToolsDidEnd()
        table?.editorTextDidChange(selectionBefore: selectionBeforeEdit)
    }

    // MARK: Pasteboard

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.html, .string] }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let table, let engine = table.engine, let cell = table.activeCell else { return false }
        if NoteTablePaste.table(from: pboard) != nil {
            return engine.pasteIntoTable(table, at: cell, from: pboard)
        }
        guard let text = pboard.string(forType: .string) else { return false }
        // Plain text goes into the cell; its line breaks stay inside it.
        let normalized = NoteLineBreaks.normalizeLineBreaks(text).0
            .replacingOccurrences(of: "\n", with: String(NoteTextCodec.cellLineBreak))
            .replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
        insertText(normalized, replacementRange: rangeForUserTextChange)
        return true
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return false }
        let cell = NoteTextCodec.cell(from: storage.attributedSubstring(from: range))
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(cell.displayText, forType: .string)
    }

    // MARK: Undo goes to the note's history

    override var undoManager: UndoManager? { table?.engine?.textView?.undoShim ?? super.undoManager }

    @objc func undo(_ sender: Any?) {
        guard !hasMarkedText(), let engine = table?.engine else { return }
        engine.undoCommand()
    }

    @objc func redo(_ sender: Any?) {
        guard !hasMarkedText(), let engine = table?.engine else { return }
        engine.redoCommand()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let engine = table?.engine {
            if item.action == #selector(undo(_:)) { return isEditable && engine.canUndoCommand }
            if item.action == #selector(redo(_:)) { return isEditable && engine.canRedoCommand }
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let table { table.engine?.tableFocusDidChange(table) }
        return became
    }

    /// The caret, fitted to the glyphs (F-03).
    private(set) lazy var caretFitter = NoteCaretFitter(textView: self)

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        caretFitter.refresh()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        caretFitter.refresh()
    }

    override func layout() {
        super.layout()
        caretFitter.refresh()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let table {
            DispatchQueue.main.async { [weak table] in
                guard let table, !table.isFocused, table.cellSelection == nil, !table.keepsFocusThroughRehost else { return }
                // The keyboard went to text elsewhere (the note's text,
                // another table, a field): the table is drawn whole again.
                // A control taking it for a moment (Aa's row) keeps the cell.
                if table.window != nil, table.keyboardLeftForText { table.deactivate() }
            }
        }
        return resigned
    }

    // MARK: Right-click

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let table, let engine = table.engine, let cell = table.activeCell else { return menu }
        let commands = engine.tableContextCommands(for: table, at: cell)
        guard !commands.isEmpty else { return menu }
        let item = NSMenuItem(title: String(localized: "Table"), action: nil, keyEquivalent: "")
        item.submenu = AtticNativeMenu.make(commands, title: String(localized: "Table"))
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }

    // MARK: Accessibility

    override func accessibilityParent() -> Any? {
        guard let table, let cell = table.activeCell else { return super.accessibilityParent() }
        return table.axCell(cell) ?? super.accessibilityParent()
    }
}
