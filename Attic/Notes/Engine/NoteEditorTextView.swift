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
final class NoteEditorTextView: NSTextView, NSAccessibilityCustomRotorItemSearchDelegate {
    weak var engine: NoteEditorEngine?
    private(set) lazy var undoShim = NoteUndoManagerShim(textView: self)
    /// After each layout pass: the page keeps the title's accessories (the
    /// note menu button and the tag line) on the title's lines.
    var onLayout: (() -> Void)?
    /// Set in the composed task-note host (UX plan § 9.1), where this view
    /// does not scroll on its own: caret visibility, the selection bar,
    /// Find and accessibility frames use the shared scroll's one mapper.
    var coordinateMapper: NoteCoordinateMapper?

    /// Caret visibility (typing, arrows, Find's scroll-to-match) scrolls the
    /// shared view by the least amount, clear of the header and bottom row.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let coordinateMapper else { return super.scrollRangeToVisible(range) }
        coordinateMapper.revealRange(range, margin: 4)
    }
    /// Views laid over the text (the title's accessories), read by
    /// VoiceOver after the text.
    var accessoryViews: [NSView] = []
    private lazy var headingsRotor = NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)

    func installHeadingsRotor() { setAccessibilityCustomRotors([headingsRotor]) }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let engine else { return nil }
        let headings = engine.headingRanges()
        let current = parameters.currentItem?.targetRange.location ?? (parameters.searchDirection == .next ? -1 : Int.max)
        let candidate = parameters.searchDirection == .next
            ? headings.first(where: { $0.range.location > current && ($0.text.localizedStandardContains(parameters.filterString) || parameters.filterString.isEmpty) })
            : headings.reversed().first(where: { $0.range.location < current && ($0.text.localizedStandardContains(parameters.filterString) || parameters.filterString.isEmpty) })
        guard let candidate else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = candidate.range
        result.customLabel = candidate.text
        return result
    }

    // MARK: A person's own editing

    private func asUserEdit<T>(_ body: () -> T) -> T {
        engine?.userEditDepth += 1
        defer { engine?.userEditDepth -= 1 }
        return body()
    }

    override func keyDown(with event: NSEvent) {
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if flags.isEmpty, event.charactersIgnoringModifiers == " " {
                Task { await engine.perform(.quickLook, objectID: object.objectID) }
                return
            }
        }
        if engine?.handleShortcut(event) == true { return }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == [.command, .option, .shift], event.charactersIgnoringModifiers?.lowercased() == "v" {
            pasteAsPlainText(nil)
            return
        }
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
        // The accessories and overlays placed from here move at once but
        // join or leave a parent only after this pass (P1-01 hypothesis).
        AtticOverlayHierarchy.layoutPass {
            super.layout()
            PerformanceSignposts.noteDidLayout()
            updatePlaceholder()
            onLayout?()
        }
    }

    // MARK: The title's placeholder

    /// "Title" is drawn by this view itself, on its own layer. TextKit 2
    /// draws the text in separate fragment views and the caret in its own
    /// view, so an edit never asks this view to draw again (CU P2-01: the
    /// first title typed or pasted into a new note was drawn over the stale
    /// "Title" until the editor was rebuilt). Whenever the placeholder comes
    /// or goes, its whole line is redrawn here.
    private var drawsPlaceholder = false

    private var showsPlaceholder: Bool {
        guard let engine else { return false }
        return engine.textStorage.length == 0 && !hasMarkedText()
    }

    /// The placeholder's line, the column's full width.
    var placeholderRect: NSRect {
        let font = engine?.isBodyOnly == true ? engine?.style.bodyFont : engine?.style.titleFont
        let height = max(NoteTextStyle.titleLineHeight, ceil(font.map { $0.ascender - $0.descender } ?? 0))
        return NSRect(x: 0, y: textContainerOrigin.y, width: bounds.width, height: height + 4)
    }

    /// Redraws the placeholder's line when it comes or goes. Cheap: one
    /// comparison per edit, layout pass and composition change.
    func updatePlaceholder() {
        let shows = showsPlaceholder
        guard shows != drawsPlaceholder else { return }
        drawsPlaceholder = shows
        setNeedsDisplay(placeholderRect)
    }

    override func didChangeText() {
        super.didChangeText()
        updatePlaceholder()
    }

    override func unmarkText() {
        super.unmarkText()
        updatePlaceholder()
    }

    /// "Title" on a new note's empty first line.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawsPlaceholder = showsPlaceholder
        guard drawsPlaceholder, let engine else { return }
        let origin = textContainerOrigin
        // A task's note has no title in its text (§ 2.12): its empty writing
        // invites writing instead (§ 5.5).
        let placeholder = NSAttributedString(string: engine.isBodyOnly ? String(localized: "Write, or drop a file")
                                                                       : String(localized: "Title"), attributes: [
            .font: engine.isBodyOnly ? engine.style.bodyFont : engine.style.titleFont,
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
        let wasComposing = hasMarkedText()
        asUserEdit { super.insertText(payload, replacementRange: replacementRange) }
        if wrap.after {
            setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        }
        if !wasComposing, wrap.before == false, wrap.after == false {
            engine.handleTypedText(text, wasComposing: wasComposing)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            let replaced = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            engine?.history.beginComposition(replacing: replaced)
        }
        asUserEdit { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange) }
        updatePlaceholder()
    }

    /// A list the keys reach first (the title's tag suggestions): ↑ ↓,
    /// Return, Tab and Esc go to it while it shows.
    var suggestionCommand: ((Selector) -> Bool)?

    override func doCommand(by selector: Selector) {
        if !hasMarkedText(), suggestionCommand?(selector) == true { return }
        if !hasMarkedText(), let engine {
            // OD-7: in the title Tab moves to the body; in the body it
            // indents (Apple Notes and Pages); ⌃Tab leaves the editor
            // (`NoteFormatControls.handleKey`).
            if selector == #selector(insertTab(_:)), engine.moveFromTitleToBody() { return }
            if selector == #selector(insertTab(_:)), engine.perform(.indent) { return }
            if selector == #selector(insertBacktab(_:)), engine.perform(.outdent) { return }
        }
        asUserEdit { super.doCommand(by: selector) }
    }

    override func insertNewline(_ sender: Any?) {
        // Return after `#word` in the title takes the tag, then moves on.
        if !hasMarkedText() { engine?.takeTitleHashtag() }
        if engine?.handleNewline() == true { return }
        asUserEdit { super.insertNewline(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            Task { await engine.perform(.delete, objectID: object.objectID) }
            return
        }
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
        if engine?.slashSession != nil { engine?.dismissSlashSession(); return }
        if engine?.pendingSlashDate != nil { engine?.cancelSlashDate(); return }
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
    override func delete(_ sender: Any?) {
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            Task { await engine.perform(.delete, objectID: object.objectID) }
            return
        }
        asUserEdit { super.delete(sender) }
    }
    override func copy(_ sender: Any?) {
        if let engine, selectedRange().length == 1,
           let object = engine.object(at: selectedRange().location),
           object is NoteImageAttachment || object is NoteFileAttachment {
            let command: NoteObjectCommand = object is NoteImageAttachment ? .copyImage : .copyFile
            Task { await engine.perform(command, objectID: object.objectID) }
            return
        }
        super.copy(sender)
    }
    @objc func printNote(_ sender: Any?) {
        guard let engine else { return }
        Task { _ = await engine.printNote() }
    }

    /// File › Print… (⌘P in the menu bar) prints the note as the engine
    /// lays it out for paper, never this view's own drawing.
    override func printView(_ sender: Any?) {
        guard engine != nil else { return super.printView(sender) }
        printNote(sender)
    }
    override func paste(_ sender: Any?) { asUserEdit { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { asUserEdit { super.pasteAsPlainText(sender) } }

    // MARK: Files dragged in (the page's object controls)

    /// The drop line, the carry card and the drop's block boundary belong
    /// to the object controls; everything else is the text view's own.
    weak var objectInteraction: NoteObjectInteraction?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let operation = objectInteraction?.fileDragUpdated(sender, entered: true) { return operation }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let operation = objectInteraction?.fileDragUpdated(sender, entered: false) { return operation }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        objectInteraction?.fileDragEnded()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        objectInteraction?.fileDragEnded()
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if objectInteraction?.isFileDrag(sender) == true { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let handled = objectInteraction?.performFileDrop(sender) { return handled }
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
        engine == nil ? super.writablePasteboardTypes : [NoteEditorEngine.fragmentType, .rtf, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let engine else { return super.writeSelection(to: pboard, types: types) }
        return engine.writeSelection(selectedRange(), to: pboard, types: types)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [NoteEditorEngine.fragmentType, .fileURL, .png, .tiff, .rtf, .html, .string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let engine else { return super.readSelection(from: pboard, type: type) }
        let target = rangeForUserTextChange
        guard target.location != NSNotFound else { return false }
        if type == NoteEditorEngine.fragmentType, let data = pboard.data(forType: type) {
            if engine.isPerformingSelfMove { return engine.paste(fragmentData: data, at: target) }
            // The private type owns this paste even if verification refuses it:
            // AppKit must not fall back to plain text and flatten its objects.
            Task { @MainActor [weak self, weak engine] in
                guard let self, let engine, self.engine === engine, self.rangeForUserTextChange == target else { return }
                _ = await engine.pasteDurably(fragmentData: data, at: target)
            }
            return true
        }
        if type == .fileURL,
           let urls = pboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            engine.onFileBatchRequest?(urls, pboard.string(forType: .string) ?? "", target)
            return engine.onFileBatchRequest != nil
        }
        if (type == .png || type == .tiff), let data = pboard.data(forType: type) {
            engine.onRawImageBatchRequest?(data, type == .png ? "png" : "tiff", target)
            return engine.onRawImageBatchRequest != nil
        }
        if (type == .rtf || type == .html), let data = pboard.data(forType: type) {
            return engine.pasteRichText(data, type: type, at: target)
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
        engine.history.requestReplay(redo: false)
    }

    @objc func redo(_ sender: Any?) {
        guard let engine, !hasMarkedText() else { return }
        engine.history.requestReplay(redo: true)
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
        guard let engine else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            let index = characterIndexForInsertion(at: point)
            for location in [index, max(0, index - 1)] {
                guard let object = engine.object(at: location),
                      object is NoteImageAttachment || object is NoteFileAttachment else { continue }
                setSelectedRange(NSRange(location: location, length: 1))
                Task { await engine.perform(.quickLook, objectID: object.objectID) }
                return
            }
        }
        // An image or a file: a click selects it, or runs the action drawn
        // under the pointer (the page's object controls).
        if objectInteraction?.handleMouseDown(event) == true { return }
        guard isEditable else { return super.mouseDown(with: event) }
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

    /// The page's format controls add their Format, Insert and link rows
    /// from the one command catalog (slice 3a UI); the rows below remain
    /// the fallback for a text view without them.
    var contextMenuProvider: ((NSMenu, NSEvent) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        // An image's or a file's own menu, read-only notes included.
        if let objectMenu = objectInteraction?.objectMenu(for: event) { return objectMenu }
        let menu = super.menu(for: event) ?? NSMenu()
        guard engine != nil, isEditable else { return menu }
        if let contextMenuProvider {
            contextMenuProvider(menu, event)
            return menu
        }
        menu.insertItem(.separator(), at: 0)
        let insert = NSMenuItem(title: String(localized: "Insert"), action: nil, keyEquivalent: "")
        insert.submenu = NoteEditorTextView.insertMenu(target: self)
        menu.insertItem(insert, at: 0)
        let format = NSMenuItem(title: String(localized: "Format"), action: nil, keyEquivalent: "")
        format.submenu = formatMenu()
        menu.insertItem(format, at: 0)
        return menu
    }

    private func formatMenu() -> NSMenu {
        let menu = NSMenu()
        let commands: [NoteFormatCommand] = [
            .paragraph(.body), .paragraph(.heading(1)), .paragraph(.heading(2)), .paragraph(.heading(3)),
            .paragraph(.mono), .paragraph(.bullet), .paragraph(.number), .paragraph(.checklist), .paragraph(.quote),
            .mark(.bold), .mark(.italic), .mark(.underline), .mark(.strikethrough), .mark(.code),
            .mark(.highlight), .mark(.link), .indent, .outdent, .removeLink
        ]
        for command in commands {
            if [.mark(.bold), .indent].contains(command) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: command.title, action: #selector(performFormatMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            item.image = NSImage(systemSymbolName: command.symbolName, accessibilityDescription: command.title)
            let state = engine?.validate(command, selection: selectedRange())
            item.isEnabled = state?.enabled ?? false
            item.state = switch state?.state {
            case .on: .on
            case .mixed: .mixed
            default: .off
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performFormatMenuItem(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? NoteFormatCommand else { return }
        _ = engine?.perform(command, selection: selectedRange())
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
        _ = engine.perform(.paragraph(engine.paragraphStyle(at: selection.location) == .checklist ? .body : .checklist), selection: selection)
    }
    @objc func insertTodaysDate(_ sender: Any?) { _ = engine?.perform(.date(NoteDay(date: Date()))) }

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
        for paragraph in engine.accessibilityParagraphs(in: clamped) {
            let local = NSIntersectionRange(paragraph.range, range)
            guard local.length > 0 else { continue }
            let target = NSRange(location: local.location - range.location, length: local.length)
            if let level = paragraph.headingLevel {
                result.addAttribute(NSAttributedString.Key(NSAccessibility.Attribute.headingLevelAttribute.rawValue),
                                    value: level, range: target)
            }
            if paragraph.style == "quote" {
                result.addAttribute(NSAttributedString.Key(NSAccessibility.Attribute.blockQuoteLevelAttribute.rawValue),
                                    value: 1 + paragraph.indent, range: target)
            }
            if paragraph.style == "bullet" || paragraph.style == "number" {
                let marker = paragraph.style == "number" ? "\(paragraph.listOrdinal ?? 1)." : "•"
                result.addAttribute(.accessibilityListItemPrefix, value: NSAttributedString(string: marker), range: target)
                result.addAttribute(.accessibilityListItemIndex, value: (paragraph.listOrdinal ?? 1) - 1, range: target)
                result.addAttribute(.accessibilityListItemLevel, value: paragraph.indent, range: target)
            }
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

/// What the page's object controls answer for the note's text view: object
/// clicks and menus, and files dragged in from elsewhere. nil or false
/// leaves the event to the text view.
@MainActor
protocol NoteObjectInteraction: AnyObject {
    func handleMouseDown(_ event: NSEvent) -> Bool
    func objectMenu(for event: NSEvent) -> NSMenu?
    func isFileDrag(_ info: any NSDraggingInfo) -> Bool
    /// The operation for a drag of files from elsewhere, or nil when it is
    /// not one (text, or a move within the note).
    func fileDragUpdated(_ info: any NSDraggingInfo, entered: Bool) -> NSDragOperation?
    func fileDragEnded()
    func performFileDrop(_ info: any NSDraggingInfo) -> Bool?
}
