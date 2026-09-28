import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// The note text view: a stock TextKit 2 `NSTextView` with narrow hooks.
///
/// - Marks the entry points that are a person's own editing (typing, IME,
///   dictation, delete commands, cut, paste, drag), so the engine's object
///   guard can tell them from Find and Replace, Services and Writing Tools.
/// - Routes Undo and Redo to the engine's own history (`allowsUndo` is off).
/// - Announces an input-method composition that replaces a selection
///   before the storage changes, so its undo step knows the replaced text.
/// - Clicking a checkbox ticks it without moving the caret.
/// - Exposes objects to VoiceOver.
/// - Marks keystroke-to-commit for the performance trace.
final class NoteEditorTextView: NSTextView {
    weak var engine: NoteEditorEngine?
    private(set) lazy var undoShim = NoteUndoManagerShim(textView: self)
    /// After each layout pass: the page keeps the title's accessories (the
    /// note menu button and the tag line) on the title's lines.
    var onLayout: (() -> Void)?
    /// Views laid over the text (the title's accessories), read by
    /// VoiceOver after the text.
    var accessoryViews: [NSView] = []

    // MARK: A person's own editing

    private func asUserEdit<T>(_ body: () -> T) -> T {
        engine?.userEditDepth += 1
        defer { engine?.userEditDepth -= 1 }
        return body()
    }

    override func keyDown(with event: NSEvent) {
        let typing = event.charactersIgnoringModifiers?.isEmpty == false
            && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)
        guard typing else { return asUserEdit { super.keyDown(with: event) } }
        // Keystroke to the commit of the frame that shows it: TextKit 2 draws
        // text in layout-fragment layers, so the end marker is the Core
        // Animation commit that carries the change, not a view draw call.
        PerformanceSignposts.beginNoteKey()
        CATransaction.begin()
        CATransaction.setCompletionBlock { PerformanceSignposts.noteDidDraw() }
        asUserEdit { super.keyDown(with: event) }
        CATransaction.commit()
    }

    /// Keystroke-to-layout end marker. The macOS 26 SDK does not expose
    /// NSTextView's viewport-controller delegate method for overriding, so
    /// the marker closes after the view's own layout or pre-draw pass,
    /// where TextKit 2 lays out the viewport.
    override func layout() {
        super.layout()
        PerformanceSignposts.noteDidLayout()
        onLayout?()
    }

    /// "Title" on a new note's empty first line.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let engine, engine.textStorage.length == 0, !hasMarkedText() else { return }
        let origin = textContainerOrigin
        let placeholder = NSAttributedString(string: String(localized: "Title"), attributes: [
            .font: engine.style.titleFont,
            .foregroundColor: engine.style.placeholderColor
        ])
        placeholder.draw(at: NSPoint(x: origin.x + (textContainer?.lineFragmentPadding ?? 0), y: origin.y))
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        PerformanceSignposts.noteDidLayout()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let engine, !engine.isWritingToolsSessionActive else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        // A typed Space after `#word` in the title takes the tag (the space
        // itself is not inserted). A paste never reaches here.
        if text == " ", !hasMarkedText(), range == selectedRange(), engine.takeTitleHashtag() { return }
        let wrap = hasMarkedText() ? (before: false, after: false) : engine.adjustedInsertion(text, at: range)
        var payload: Any = string
        if wrap.before || wrap.after {
            let attributed = (string as? NSAttributedString).map(NSMutableAttributedString.init(attributedString:))
                ?? NSMutableAttributedString(string: text, attributes: typingAttributes)
            if wrap.before { attributed.insert(NSAttributedString(string: "\n", attributes: typingAttributes), at: 0) }
            if wrap.after { attributed.append(NSAttributedString(string: "\n", attributes: typingAttributes)) }
            payload = attributed
        }
        asUserEdit { super.insertText(payload, replacementRange: replacementRange) }
        if wrap.after {
            setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            let replaced = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            engine?.history.beginComposition(replacing: replaced)
        }
        asUserEdit { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
    }

    /// A list the keys reach first (the title's tag suggestions): ↑ ↓,
    /// Return, Tab and Esc go to it while it shows.
    var suggestionCommand: ((Selector) -> Bool)?

    override func doCommand(by selector: Selector) {
        if !hasMarkedText(), suggestionCommand?(selector) == true { return }
        asUserEdit { super.doCommand(by: selector) }
    }

    override func insertNewline(_ sender: Any?) {
        // Return after `#word` in the title takes the tag, then moves on.
        if !hasMarkedText() { engine?.takeTitleHashtag() }
        if engine?.handleNewline() == true { return }
        asUserEdit { super.insertNewline(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        if engine?.handleDeleteBackward() == true { return }
        asUserEdit { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if engine?.handleDeleteForward() == true { return }
        asUserEdit { super.deleteForward(sender) }
    }

    /// Where Esc goes when the note has nothing left to close (the panel
    /// hides). Tests set it; in the panel it is the window's own route.
    var escapeFallback: (() -> Void)?

    /// The Esc chain from the note (UX plan § 4.9): an input-method
    /// composition keeps Esc; the tag suggestions (handled before this, in
    /// `doCommand`) close; `#word` in the title stays text; the Find bar
    /// closes; then, with nothing left to close, the panel hides. The text
    /// view's own completion list is not used in notes.
    override func cancelOperation(_ sender: Any?) {
        // NSTextView has no cancelOperation of its own (calling super would
        // raise): what it doesn't take goes up the responder chain.
        guard engine != nil else { return passEscapeOn(sender) }
        // The input method owns Esc during a composition.
        if hasMarkedText() { return }
        if engine?.keepTitleHashtagLiteral() == true { return }
        if let scrollView = enclosingScrollView, scrollView.isFindBarVisible {
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(hide)
            window?.makeFirstResponder(self)
            return
        }
        if let escapeFallback { return escapeFallback() }
        if let panel = window as? AtticPanel, let hide = panel.onUnhandledEscape { return hide() }
        passEscapeOn(sender)
    }

    private func passEscapeOn(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
    }

    override func cut(_ sender: Any?) { asUserEdit { super.cut(sender) } }
    override func delete(_ sender: Any?) { asUserEdit { super.delete(sender) } }
    override func paste(_ sender: Any?) { asUserEdit { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { asUserEdit { super.pasteAsPlainText(sender) } }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let isSelfMove = (sender.draggingSource as AnyObject?) === self
            && sender.draggingSourceOperationMask.contains(.move)
        engine?.isPerformingSelfMove = isSelfMove
        engine?.history.beginGroup()
        defer {
            engine?.history.endGroup()
            engine?.isPerformingSelfMove = false
        }
        return asUserEdit { super.performDragOperation(sender) }
    }

    // MARK: Pasteboard

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        engine == nil ? super.writablePasteboardTypes : [NoteEditorEngine.fragmentType, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let engine else { return super.writeSelection(to: pboard, types: types) }
        return engine.writeSelection(selectedRange(), to: pboard, types: types)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [NoteEditorEngine.fragmentType, .string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let engine else { return super.readSelection(from: pboard, type: type) }
        let target = rangeForUserTextChange
        guard target.location != NSNotFound else { return false }
        if type == NoteEditorEngine.fragmentType, let data = pboard.data(forType: type) {
            return engine.paste(fragmentData: data, at: target)
        }
        if let text = pboard.string(forType: .string) {
            return engine.pastePlainText(text, at: target)
        }
        return false
    }

    // MARK: Undo route (editor-owned)

    override var undoManager: UndoManager? { engine == nil ? super.undoManager : undoShim }

    @objc func undo(_ sender: Any?) {
        guard let engine, !hasMarkedText() else { return }
        engine.history.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let engine, !hasMarkedText() else { return }
        engine.history.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let engine {
            if item.action == #selector(undo(_:)) {
                let name = engine.history.undoActionName
                (item as? NSMenuItem)?.title = name.isEmpty ? String(localized: "Undo") : String(localized: "Undo \(name)")
                return isEditable && engine.history.canUndo
            }
            if item.action == #selector(redo(_:)) {
                let name = engine.history.redoActionName
                (item as? NSMenuItem)?.title = name.isEmpty ? String(localized: "Redo") : String(localized: "Redo \(name)")
                return isEditable && engine.history.canRedo
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Checkbox clicks

    override func mouseDown(with event: NSEvent) {
        guard let engine, isEditable else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        if let location = checkboxLocation(at: point) {
            engine.toggleCheckbox(atLineOf: location)
            return
        }
        super.mouseDown(with: event)
    }

    func checkboxLocation(at point: NSPoint) -> Int? {
        guard let engine else { return nil }
        if let range = engine.checkboxRange(near: point), let rect = engine.rect(for: range) {
            let hit = NSRect(x: rect.minX - 4, y: rect.minY - 4,
                             width: NoteChecklistAttachment.boxSize + 8, height: rect.height + 8)
            if hit.contains(point) { return range.location }
        }
        let index = characterIndexForInsertion(at: point)
        let candidates = [index, max(0, index - 1)]
        for location in candidates {
            let line = engine.lineRange(at: location)
            guard engine.checklistBox(inParagraphAt: location) != nil else { continue }
            let range = NSRange(location: line.location, length: 1)
            guard let rect = engine.rect(for: range) else { continue }
            let hit = NSRect(x: rect.minX - 4, y: rect.minY - 4,
                             width: NoteChecklistAttachment.boxSize + 8, height: rect.height + 8)
            if hit.contains(point) { return range.location }
        }
        return nil
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard engine != nil, isEditable else { return menu }
        menu.insertItem(.separator(), at: 0)
        let insert = NSMenuItem(title: String(localized: "Insert"), action: nil, keyEquivalent: "")
        insert.submenu = NoteEditorTextView.insertMenu(target: self)
        menu.insertItem(insert, at: 0)
        return menu
    }

    static func insertMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        let checklist = NSMenuItem(title: String(localized: "Checklist"), action: #selector(insertChecklistLine(_:)), keyEquivalent: "")
        checklist.target = target
        let date = NSMenuItem(title: String(localized: "Today’s Date"), action: #selector(insertTodaysDate(_:)), keyEquivalent: "")
        date.target = target
        menu.items = [checklist, date]
        return menu
    }

    @objc func insertChecklistLine(_ sender: Any?) {
        guard let engine else { return }
        let selection = selectedRange()
        engine.applyParagraphFormat(engine.paragraphFormat(in: selection) == .checklist ? .body : .checklist, to: selection)
    }
    @objc func insertTodaysDate(_ sender: Any?) { engine?.insertDate(NoteDay(date: Date())) }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        let base = super.accessibilityChildren() ?? []
        guard let engine else { return base }
        let accessories = accessoryViews.filter { view in !view.isHidden && !base.contains { ($0 as AnyObject) === view } }
        return base + engine.accessibilityElements(for: self) + accessories
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let base = super.accessibilityAttributedString(for: range), let engine,
              let storage = textStorage else { return super.accessibilityAttributedString(for: range) }
        let result = NSMutableAttributedString(attributedString: base)
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        let elements = engine.accessibilityElements(for: self).compactMap { $0 as? NoteObjectAccessibilityElement }
        storage.enumerateAttribute(.attachment, in: clamped) { value, objectRange, _ in
            guard let object = value as? NoteObjectAttachment,
                  let element = elements.first(where: { $0.objectID == object.objectID }) else { return }
            let local = NSRange(location: objectRange.location - range.location, length: objectRange.length)
            guard local.location >= 0, NSMaxRange(local) <= result.length else { return }
            result.addAttribute(.accessibilityAttachment, value: element, range: local)
        }
        return result
    }
}

/// The text view's `undoManager`: menu validation and any caller that asks
/// the responder chain's undo manager reach the engine's own history.
/// Registrations made on it by the system are accepted and ignored: every
/// change they describe is already a step in the engine's history.
final class NoteUndoManagerShim: UndoManager {
    private weak var textView: NoteEditorTextView?

    init(textView: NoteEditorTextView) {
        self.textView = textView
        super.init()
        // Registrations are grouped per event as usual and kept to one
        // level: they are never run (undo and redo go to the history).
        levelsOfUndo = 1
    }

    private var history: NoteUndoHistory? {
        MainActor.assumeIsolated { textView?.engine?.history }
    }

    override var canUndo: Bool { MainActor.assumeIsolated { history?.canUndo ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { history?.canRedo ?? false } }
    override var undoActionName: String { MainActor.assumeIsolated { history?.undoActionName ?? "" } }
    override var redoActionName: String { MainActor.assumeIsolated { history?.redoActionName ?? "" } }

    override func undo() {
        MainActor.assumeIsolated { _ = history?.undo() }
    }

    override func redo() {
        MainActor.assumeIsolated { _ = history?.redo() }
    }
}
