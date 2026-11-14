import AppKit
import ObjectiveC
import SwiftUI

/// One Find session for the shared note engine, including table-cell text.
/// Highlights are rendering attributes only: searching never changes the
/// document, its save state or its Undo history.
@MainActor
final class NoteFindController: ObservableObject {
    struct Match: Equatable {
        let noteRange: NSRange
        var tableID: UUID? = nil
        var cell: NoteTable.Position? = nil
        var cellRange: NSRange? = nil
    }
    weak var engine: NoteEditorEngine?
    @Published private(set) var isShown = false
    @Published var query = "" { didSet { refresh(selectFirst: true) } }
    @Published private(set) var matches: [Match] = [] {
        didSet {
            noteHighlightsNeedUpdate = true
            tableHighlights.removeAll()
            for match in matches {
                if let id = match.tableID, let cell = match.cell, let range = match.cellRange {
                    tableHighlights[id, default: [:]][cell, default: []].append(range)
                }
            }
        }
    }
    @Published private(set) var index: Int? = nil
    @Published var fieldFocused = false
    private var noteHighlightsNeedUpdate = false
    private var tableHighlights: [UUID: [NoteTable.Position: [NSRange]]] = [:]
    private var paintedNoteRanges: [NSRange] = []
    private var dirtyHighlights: NSRange?
    private var pendingSearchRange: NSRange?
    private var pendingMatches: [Match]?
    private var pendingOldMatch: Match?
    private var pendingFullSearch = false
    private var monitor: Any?
    private var host: NSHostingView<AnyView>?
    private let keyboardFocus = AtticKeyboardFocusTracker()
    /// The Notes page puts Find in its top row (N4, Idea B, 2026-11-01):
    /// the page's field takes the query, Pin, the title and ••• fold away,
    /// and the note never moves. Elsewhere (a task's page) Find keeps its
    /// own card in the note's scroll view.
    var inTopRow = false
    /// How the open Find shows: decided when it opens.
    private(set) var shownInTopRow = false
    /// Keys typed after ⌘F before the top row's field exists go to the
    /// query, never the note (first-key speed), until this moment.
    private var typeAheadDeadline: TimeInterval?
    /// A reopened Find's last query is selected: the first key replaces it.
    private var replacesQuery = false
    /// The top row's field has not had the keyboard yet in this Find.
    private var awaitingField = false
    /// Retain real key events through the field-mount interval so an input
    /// method can compose across the handoff. `query` is updated eagerly for
    /// ordinary keys to keep the accepted first-key response immediate, but
    /// the native field editor replays these events from the original query.
    private var pendingInputEvents: [NSEvent] = []
    private var pendingInputBaseQuery: String?
    private var pendingInputReplacesQuery = false
    private var pendingInputComposition = false
    /// The top row's field identity; the page registers its actual native view.
    static let fieldIdentifier = "note-find"
    let topRowFieldClaim = AtticFieldClaim()
    /// A quick reopen may reuse the top row during its closing animation.
    /// Each session still needs a newly mounted native editor and replay.
    private(set) var fieldSessionID: UInt = 0
    private var topInset: CGFloat = 0
    private var columnInset: CGFloat = 16
    /// Work counters for the headless performance gates.
    private(set) var searchedUTF16Count = 0
    private(set) var invalidatedUTF16Count = 0
    private(set) var objectSearchPassCount = 0
    private(set) var highlightLayoutPassCount = 0
    /// How many searches the query's changes started (a plain key typed
    /// ahead of the field is one).
    private(set) var refreshCount = 0
    /// The keyboard input source in use (an identifier such as
    /// `com.apple.keylayout.ABC`); a test seam over the text input context.
    var inputSourceIdentifier: () -> String? = { nil }
    static var height: CGFloat { AtticControlSize.smallHeight * 2 + AtticSpacing.s4 + AtticSpacing.s8 * 2 }
    /// The room the card takes above the note: none in the top row.
    var clearance: CGFloat { isShown && !shownInTopRow ? Self.height : 0 }
    let highlight = NSColor.systemYellow.withAlphaComponent(0.4)

    init(engine: NoteEditorEngine) { self.engine = engine }

    func attach() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.routeKeyDown(event)
            }
        }
        layoutBar()
    }

    /// What the local key monitor does with a key-down: nil when Find took
    /// it (the typed-ahead query, an editing command meant for the field
    /// that is still mounting, a Find shortcut), else the event itself.
    func routeKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let view = engine?.textView, let window = view.window,
              event.window === window, window.isKeyWindow else { return event }
        let responder = window.firstResponder
        let inNote = responder === view || engine?.activeTableView?.isFocused == true
        let inFind = isFindField(responder)
        // The native field can take focus before its onAppear
        // callback. Replay pending keys before its next real key.
        if inFind, awaitingField { topRowFieldAppeared() }
        if inFind, !awaitingField { typeAheadDeadline = nil }
        // The outgoing field can remain first responder during a reopen.
        // Until the new field owns the session, it shares the same queue as
        // the note and the window's temporary responder.
        let inHandoff = awaitingField && fieldFocused && (inNote || inFind || responder === window || responder == nil)
        if inHandoff, typeAhead(event) { return nil }
        if inFind, replacesQuery, Self.isTyping(event), let editor = responder as? NSTextView {
            // The last query, still selected, gives way to the key.
            editor.selectAll(nil)
            replacesQuery = false
        }
        return (inNote || inFind) && handleKey(event) ? nil : event
    }

    /// The field editor of Find's own field: the card's, or the top row's.
    private func isFindField(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView else { return false }
        if let host, field.isDescendant(of: host) { return true }
        return shownInTopRow && isShown && field.accessibilityIdentifier() == Self.fieldIdentifier
    }

    /// The top row's field, once the page has drawn it.
    private func topRowField() -> NSTextField? {
        guard let field = topRowFieldClaim.field, field.isEditable,
              field.window === engine?.textView?.window else { return nil }
        return field
    }

    /// A plain typing key: characters, with no ⌘ or ⌃.
    private static func isTyping(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    /// The input source composes text (a Japanese, Chinese or Korean input
    /// method): its key-downs carry raw letters that are not the text, so
    /// they never become a provisional query. A plain keyboard layout does not.
    private var inputSourceComposes: Bool {
        let identifier = inputSourceIdentifier() ?? engine?.textView?.inputContext?.selectedKeyboardInputSource
        guard let identifier else { return false }
        return !identifier.contains(".keylayout.")
    }

    /// Resolve Cocoa's current key bindings without performing the command.
    /// Replay still interprets the real event in the field, including bindings
    /// which expand to several selectors. This view never enters a window.
    private final class KeyBindingProbe: NSTextView {
        private static let standardCommands = NSProtocolFromString("NSStandardKeyBindingResponding")
        var foundCommand = false
        override func doCommand(by selector: Selector) {
            guard let commands = Self.standardCommands,
                  protocol_getMethodDescription(commands, selector, false, true).name != nil else { return }
            foundCommand = true
        }
        override func insertText(_ insertString: Any, replacementRange: NSRange) { foundCommand = true }
        override func insertText(_ insertString: Any) { foundCommand = true }
    }
    private static let keyBindings = KeyBindingProbe(usingTextLayoutManager: false)

    private static func isNativeEditingKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Find's own shortcuts and navigation retain their controller routing.
        if flags == .command, event.keyCode == 3 || event.keyCode == 5 { return false }
        if flags == [.command, .shift], event.keyCode == 5 { return false }
        if flags.isEmpty || flags == .shift {
            if event.keyCode == 36 || event.keyCode == 53 { return false }
            // Keep the ordinary type-ahead fast path and its one search/key.
            if event.keyCode == 51 || event.keyCode == 117 || isTyping(event) { return false }
        }
        guard !isTyping(event),
              flags.contains(.command) || flags.contains(.control) || !(event.characters?.isEmpty ?? true) else { return false }
        keyBindings.foundCommand = false
        keyBindings.interpretKeyEvents([event])
        return keyBindings.foundCommand
    }

    /// The editing commands a search field takes (⌘V ⌘A ⌘Z ⇧⌘Z ⌘X ⌘C): while
    /// the field mounts they belong to it, never to the note.
    private static func editingCommand(_ event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "v": return #selector(NSText.paste(_:))
            case "a": return #selector(NSText.selectAll(_:))
            case "x": return #selector(NSText.cut(_:))
            case "c": return #selector(NSText.copy(_:))
            case "z": return #selector(UndoManager.undo)
            default: return nil
            }
        }
        if flags == [.command, .shift], key == "z" { return #selector(UndoManager.redo) }
        if flags == [.command, .option, .shift], key == "v" { return #selector(NSText.paste(_:)) }
        return nil
    }

    /// Capture keys before the field appears. Early plain-text feedback is
    /// provisional; the field editor remains the authority for composition
    /// and for editing commands.
    @discardableResult
    func typeAhead(_ event: NSEvent) -> Bool {
        guard shownInTopRow, isShown, fieldFocused, awaitingField else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if Self.editingCommand(event) != nil || Self.isNativeEditingKey(event) {
            // ⌘V and the like would reach the note's own selection: queue
            // them for the field and replay them there, in order.
            if pendingInputEvents.isEmpty {
                pendingInputBaseQuery = query
                pendingInputReplacesQuery = replacesQuery
            }
            pendingInputEvents.append(event)
            pendingInputComposition = true
            replacesQuery = false
            return true
        }
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        let isPlainTyping = Self.isTyping(event)
        // Dead keys and early IME key-downs may have no `characters`. They
        // must still be delivered to NSTextInputClient, even before a glyph
        // exists. Never consume navigation keys as text.
        let isComposingKey = (event.characters?.isEmpty ?? true) && event.keyCode <= 50
            && event.keyCode != 36 && event.keyCode != 48
        guard isDelete || isPlainTyping || isComposingKey else { return false }
        if pendingInputEvents.isEmpty {
            pendingInputBaseQuery = query
            pendingInputReplacesQuery = replacesQuery
        }
        pendingInputEvents.append(event)
        pendingInputComposition = pendingInputComposition || isComposingKey || modifiers.contains(.option) || event.keyCode == 117
            || inputSourceComposes
        if !pendingInputComposition {
            if isDelete {
                if replacesQuery { query = "" } else if !query.isEmpty { query.removeLast() }
            } else if let characters = event.characters {
                if replacesQuery { query = characters } else { query += characters }
            }
        }
        replacesQuery = false
        return true
    }

    private func replayPendingInput(to editor: NSTextView, field: NSTextField) {
        guard !pendingInputEvents.isEmpty else { return }
        let original = pendingInputBaseQuery ?? query
        // SwiftUI may already have drawn our provisional ASCII query. Reset
        // the field editor to the original selection before native replay;
        // otherwise those keystrokes would be inserted twice.
        if field.stringValue != original { field.stringValue = original }
        if editor.string != original { editor.string = original }
        let length = (original as NSString).length
        editor.setSelectedRange(pendingInputReplacesQuery
            ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0))
        let events = pendingInputEvents
        pendingInputEvents.removeAll()
        pendingInputBaseQuery = nil
        pendingInputReplacesQuery = false
        pendingInputComposition = false
        for event in events {
            guard let command = Self.editingCommand(event) else { editor.interpretKeyEvents([event]); continue }
            switch command {
            case #selector(UndoManager.undo): editor.undoManager?.undo()
            case #selector(UndoManager.redo): editor.undoManager?.redo()
            default: _ = editor.tryToPerform(command, with: nil)
            }
        }
        if !editor.hasMarkedText(), query != editor.string { query = editor.string }
    }

    /// Plain keys typed ahead already stand in the query, one search each:
    /// the field takes that text as it is (no second pass over the keys).
    private func commitTypedAheadQuery(to editor: NSTextView, field: NSTextField) {
        pendingInputEvents.removeAll()
        pendingInputBaseQuery = nil
        pendingInputReplacesQuery = false
        pendingInputComposition = false
        if field.stringValue != query { field.stringValue = query }
        if editor.string != query { editor.string = query }
        editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
    }

    /// The top row's field has appeared: it takes the keyboard (unless the
    /// keyboard went elsewhere meanwhile), the last query selected, or the
    /// caret after what was typed ahead.
    func topRowFieldAppeared() {
        guard shownInTopRow, isShown, fieldFocused, awaitingField,
              let field = topRowField(), let window = field.window else { return }
        let editor = field.currentEditor() as? NSTextView
        if editor == nil || window.firstResponder !== editor {
            guard typeAheadDeadline != nil || window.firstResponder === engine?.textView
                    || window.firstResponder === window || window.firstResponder == nil,
                  window.makeFirstResponder(field) else { return }
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        typeAheadDeadline = nil
        awaitingField = false
        if pendingInputEvents.isEmpty {
            let length = (editor.string as NSString).length
            editor.selectedRange = replacesQuery ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        } else if pendingInputComposition {
            replayPendingInput(to: editor, field: field)
        } else {
            commitTypedAheadQuery(to: editor, field: field)
        }
        replacesQuery = false
    }

    func detach() {
        close(returnFocus: false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        host?.removeFromSuperview()
        host = nil
    }

    func setGeometry(top: CGFloat, column: CGFloat) {
        topInset = top
        columnInset = column
        layoutBar()
    }

    func layoutBar() {
        guard let scroll = engine?.scrollView, let host else { return }
        let y = scroll.isFlipped ? topInset : scroll.bounds.height - topInset - Self.height
        host.frame = NSRect(x: columnInset, y: y, width: max(0, scroll.bounds.width - 2 * columnInset), height: Self.height)
        host.isHidden = !isShown
    }

    func show() {
        guard let engine, let scroll = engine.scrollView else { return }
        fieldFocused = true
        if inTopRow || (isShown && shownInTopRow) {
            if !isShown {
                shownInTopRow = true
                fieldSessionID &+= 1
                topRowFieldClaim.cancelFocusRequest()
                topRowFieldClaim.field = nil
                pendingInputEvents.removeAll()
                pendingInputBaseQuery = nil
                pendingInputReplacesQuery = false
                pendingInputComposition = false
                replacesQuery = !query.isEmpty
                typeAheadDeadline = ProcessInfo.processInfo.systemUptime + 1
                awaitingField = true
                isShown = true
                refresh(selectFirst: false)
            } else if let field = topRowField() {
                // ⌘F again: the field takes the keyboard back, the query
                // selected.
                field.window?.makeFirstResponder(field)
                replacesQuery = false
            }
            return
        }
        shownInTopRow = false
        if host == nil {
            let host = NSHostingView(rootView: AnyView(NoteFindBar(find: self)
                .atticDesign(engine.style.design).atticKeyboardFocusTracking(keyboardFocus)))
            self.host = host
            scroll.addSubview(host)
        }
        if !isShown {
            topInset = scroll.contentInsets.top
            isShown = true
            // The note makes room at once (one layout change, never
            // animated over a long document); only the bar moves.
            scroll.contentInsets.top = topInset + Self.height
            layoutBar()
            refresh(selectFirst: false)
            if let host { Self.appear(host) }
        }
        // Finish mounting and take the keyboard in this key event. Waiting
        // for SwiftUI's focus update lets fast typing after ⌘F edit the note.
        host?.layoutSubtreeIfNeeded()
        if let host, let field = AtticTabsSearchField.searchField(in: host, placeholder: String(localized: "Find in note")) {
            field.window?.makeFirstResponder(field)
        }
    }

    /// A change of look reaches an open bar (H10-01): its host is built
    /// once, with the design the note had when Find opened.
    func update(design: AtticDesignContext) {
        host?.rootView = AnyView(NoteFindBar(find: self)
            .atticDesign(design).atticKeyboardFocusTracking(keyboardFocus))
    }

    func close(returnFocus: Bool = true) {
        guard isShown else { return }
        topRowFieldClaim.cancelFocusRequest()
        topRowFieldClaim.field = nil
        let selected = index.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        isShown = false
        fieldFocused = false
        typeAheadDeadline = nil
        replacesQuery = false
        awaitingField = false
        pendingInputEvents.removeAll()
        pendingInputBaseQuery = nil
        pendingInputReplacesQuery = false
        pendingInputComposition = false
        matches = []
        index = nil
        if !shownInTopRow { engine?.scrollView?.contentInsets.top = topInset }
        shownInTopRow = false
        if let host { Self.disappear(host) }
        host = nil
        updateHighlights(clear: true)
        if returnFocus, let engine {
            if let id = selected?.tableID, let cell = selected?.cell, let range = selected?.cellRange,
               let (table, _) = engine.tableAttachment(id: id) {
                engine.enterTable(table, at: cell, caret: .range(range))
            } else { engine.textView?.window?.makeFirstResponder(engine.textView) }
        }
    }

    /// The bar's appearance (A4: Find had none): it fades in and comes
    /// down its last 4 pt, M/E; Reduced, the F/E fade alone. The keyboard
    /// is the field's at once, whatever the motion.
    private static func appear(_ host: NSView) {
        let reduce = AtticMotionPreference.reducesMotion
        let rest = host.frame.origin
        let rise = reduce ? 0 : AtticMotionScale.overlayRise
        host.alphaValue = 0
        host.setFrameOrigin(NSPoint(x: rest.x, y: rest.y + (host.superview?.isFlipped == false ? rise : -rise)))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? AtticMotionScale.fast : AtticMotionScale.standard
            context.timingFunction = AtticMotionScale.easeOutTimingFunction
            context.allowsImplicitAnimation = false
            host.animator().alphaValue = 1
            host.animator().setFrameOrigin(rest)
        }
    }

    /// The bar's exit: it leaves the view (and VoiceOver's tree) at once,
    /// and a still picture of it fades out, F/E.
    private static func disappear(_ host: NSView) {
        guard let superview = host.superview, host.bounds.width > 0, host.bounds.height > 0,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            host.removeFromSuperview()
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let picture = NSImageView(frame: host.frame)
        picture.image = image
        picture.imageScaling = .scaleNone
        picture.setAccessibilityElement(false)
        superview.addSubview(picture, positioned: .above, relativeTo: host)
        host.removeFromSuperview()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AtticMotionScale.fast
            context.timingFunction = AtticMotionScale.easeOutTimingFunction
            picture.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { picture.removeFromSuperview() }
        }
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 3, flags == .command { show(); return true }
        if event.keyCode == 5, flags == .command || flags == [.command, .shift] {
            if !isShown { show() }
            next(backward: flags.contains(.shift))
            return true
        }
        if isShown, event.keyCode == 53, flags.isEmpty { close(); return true }
        if isShown, fieldFocused, event.keyCode == 36, flags.isEmpty || flags == .shift {
            next(backward: flags.contains(.shift)); return true
        }
        return false
    }

    private func ranges(in string: String, within scope: NSRange? = nil) -> [NSRange] {
        let text = string as NSString
        let scope = scope ?? NSRange(location: 0, length: text.length)
        var result: [NSRange] = [], start = scope.location
        guard !query.isEmpty else { return [] }
        searchedUTF16Count += scope.length
        while start < NSMaxRange(scope) {
            let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: start, length: NSMaxRange(scope) - start))
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range)
            start = NSMaxRange(range)
        }
        return result
    }

    /// TextKit rebases rendering locations with the edit. Keep our painted
    /// spans in the same coordinates, then repaint the edited paragraphs too
    /// so a removed match cannot leave stale fragment-layer pixels behind.
    func charactersChanged(in edited: NSRange, delta: Int) {
        guard isShown, !query.isEmpty, let engine else { return }
        let oldEnd = NSMaxRange(edited) - delta
        func rebased(_ range: NSRange) -> NSRange {
            if NSMaxRange(range) <= edited.location { return range }
            if range.location >= oldEnd {
                return NSRange(location: max(0, range.location + delta), length: range.length)
            }
            let start = min(range.location, edited.location)
            let end = max(NSMaxRange(edited), NSMaxRange(range) + delta)
            return NSRange(location: start, length: max(0, end - start))
        }
        noteHighlightsNeedUpdate = true
        paintedNoteRanges = paintedNoteRanges.map(rebased)
        let string = engine.textStorage.string as NSString
        let affected = string.paragraphRange(for: NSIntersectionRange(edited, NSRange(location: 0, length: string.length)))
        dirtyHighlights = dirtyHighlights.map { NSUnionRange(rebased($0), affected) } ?? affected
        if pendingMatches != nil || pendingFullSearch || query.contains(where: \.isNewline) {
            pendingFullSearch = true
            pendingSearchRange = nil
            return
        }
        pendingOldMatch = index.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        let oldAffected = NSRange(location: affected.location, length: max(0, affected.length - delta))
        pendingMatches = matches.compactMap { match in
            if NSIntersectionRange(match.noteRange, oldAffected).length > 0 { return nil }
            return Match(noteRange: rebased(match.noteRange), tableID: match.tableID, cell: match.cell, cellRange: match.cellRange)
        }
        pendingSearchRange = affected
    }

    func refresh(selectFirst: Bool = false, changedTable: NoteTableAttachment? = nil) {
        guard isShown, let engine else { return }
        refreshCount += 1
        defer {
            pendingSearchRange = nil; pendingMatches = nil; pendingOldMatch = nil; pendingFullSearch = false
        }
        // An empty bar has nothing to search or highlight. Clear a previous
        // search once; subsequent edits need no document-wide layout pass.
        if query.isEmpty {
            guard !matches.isEmpty || index != nil else { return }
            matches = []
            index = nil
            updateHighlights(clear: true)
            return
        }
        let old = pendingMatches != nil ? pendingOldMatch : index.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        // A cell edit changes no note characters. Retain every other match
        // and search only that grid, including table Undo/Redo notifications.
        let tableScope = pendingMatches == nil && !pendingFullSearch && !selectFirst
            ? changedTable.flatMap { engine.range(ofTable: $0) } : nil
        let incremental = !selectFirst && !pendingFullSearch && pendingSearchRange != nil
        let requested = tableScope ?? (incremental ? pendingSearchRange! : NSRange(location: 0, length: engine.textStorage.length))
        let text = engine.textStorage.string as NSString
        let bodyStart = engine.isBodyOnly || text.length == 0 ? 0 : NSMaxRange(text.paragraphRange(for: NSRange(location: 0, length: 0)))
        let scope = NSIntersectionRange(requested, NSRange(location: bodyStart, length: max(0, text.length - bodyStart)))
        var found = tableScope != nil ? matches.filter { $0.tableID != changedTable?.objectID || $0.noteRange != tableScope! }
            : (incremental ? (pendingMatches ?? []) : [])
        if tableScope == nil {
            found += ranges(in: engine.textStorage.string, within: scope).map { Match(noteRange: $0) }
        }
        objectSearchPassCount += 1
        var objects: [(NoteObjectAttachment, NSRange)] = []
        engine.textStorage.enumerateAttribute(.attachment, in: scope) { value, range, _ in
            if let object = value as? NoteObjectAttachment { objects.append((object, range)) }
        }
        for (object, range) in objects {
            guard let table = object as? NoteTableAttachment else { continue }
            for row in table.table.rows.indices {
                for column in table.table.columns.indices {
                    let cell = NoteTable.Position(row: row, column: column)
                    found += ranges(in: table.table[cell].text).map {
                        Match(noteRange: range, tableID: table.objectID, cell: cell, cellRange: $0)
                    }
                }
            }
        }
        found.sort {
            if $0.noteRange.location != $1.noteRange.location { return $0.noteRange.location < $1.noteRange.location }
            if $0.cell?.row != $1.cell?.row { return ($0.cell?.row ?? -1) < ($1.cell?.row ?? -1) }
            if $0.cell?.column != $1.cell?.column { return ($0.cell?.column ?? -1) < ($1.cell?.column ?? -1) }
            return ($0.cellRange?.location ?? 0) < ($1.cellRange?.location ?? 0)
        }
        matches = found
        index = selectFirst ? found.indices.first : old.flatMap { found.firstIndex(of: $0) }
        updateHighlights()
        if selectFirst { reveal(activateCell: false) }
    }

    func next(backward: Bool = false) {
        guard !matches.isEmpty else { return }
        index = index.map { ($0 + (backward ? matches.count - 1 : 1)) % matches.count }
            ?? (backward ? matches.count - 1 : 0)
        reveal(activateCell: true)
    }

    private func reveal(activateCell: Bool) {
        guard let engine, let index, matches.indices.contains(index) else { return }
        let match = matches[index]
        engine.unfoldHeadings(containing: match.noteRange)
        if let id = match.tableID, let cell = match.cell, let range = match.cellRange,
           match.noteRange.location >= 0, match.noteRange.location < engine.textStorage.length,
           let table = engine.tableAttachment(at: match.noteRange.location), table.objectID == id {
            if activateCell {
                engine.enterTable(table, at: cell, caret: .range(range))
                fieldFocused = false
            } else {
                engine.textView?.scrollRangeToVisible(match.noteRange)
            }
        } else {
            engine.activeTableView?.deactivate()
            if activateCell && !fieldFocused {
                engine.textView?.window?.makeFirstResponder(engine.textView)
            }
            engine.textView?.setSelectedRange(match.noteRange)
            engine.textView?.scrollFindMatchToVisible(match.noteRange)
        }
        // Navigation changes only the selection. The cached match ink stays
        // identical; entering a table refreshes its editor through enterTable.
    }

    func decorate(_ string: NSMutableAttributedString, tableID: UUID, cell: NoteTable.Position) {
        for range in tableHighlights[tableID]?[cell] ?? [] {
            if NSMaxRange(range) <= string.length {
                string.addAttribute(.backgroundColor, value: highlight, range: range)
            }
        }
    }

    func updateHighlights(clear: Bool = false) {
        guard isShown || clear else { return }
        guard let engine else { return }
        if noteHighlightsNeedUpdate, let layout = engine.layoutManager {
            // Keep the existing refresh-pass counter, including clearing a
            // table-only query; invalidatedUTF16Count records actual note work.
            highlightLayoutPassCount += 1
            let desired = matches.filter { $0.tableID == nil }.map(\.noteRange)
            let old = Set(paintedNoteRanges), new = Set(desired)
            var changed = Array(old.symmetricDifference(new))
            if let dirtyHighlights { changed.append(dirtyHighlights) }
            let whole = NSRange(location: 0, length: engine.textStorage.length)
            changed = changed.map { NSIntersectionRange($0, whole) }.filter { $0.length > 0 }.sorted { $0.location < $1.location }
            var spans: [NSRange] = []
            for range in changed {
                if let last = spans.last, NSMaxRange(last) >= range.location {
                    spans[spans.count - 1] = NSUnionRange(last, range)
                } else { spans.append(range) }
            }
            var firstMatch = 0
            for span in spans {
                guard let textRange = engine.textRange(for: span) else { continue }
                layout.removeRenderingAttribute(.backgroundColor, for: textRange)
                while firstMatch < desired.count, NSMaxRange(desired[firstMatch]) <= span.location { firstMatch += 1 }
                var cursor = firstMatch
                while cursor < desired.count, desired[cursor].location < NSMaxRange(span) {
                    if let range = engine.textRange(for: desired[cursor]) {
                        layout.addRenderingAttribute(.backgroundColor, value: highlight, for: range)
                    }
                    cursor += 1
                }
                // Attribute removal alone leaves cached yellow pixels. Keep
                // the layout invalidation, limited to the changed ink spans.
                invalidatedUTF16Count += span.length
                layout.invalidateLayout(for: textRange)
            }
            if !spans.isEmpty { engine.textView?.needsDisplay = true }
            paintedNoteRanges = desired
            dirtyHighlights = nil
            noteHighlightsNeedUpdate = false
        }
        for view in engine.tableViews() { updateTableHighlights(in: view, clear: clear) }
    }

    /// A focus change affects this editor's ink, not every table in the note.
    func updateTableHighlights(in view: NoteTableView, clear: Bool = false) {
        guard isShown || clear else { return }
        view.canvas.needsDisplay = true
        if view.hasEditor, let cell = view.activeCell, let id = view.attachment?.objectID,
           let layout = view.editor.textLayoutManager, let content = layout.textContentManager {
            layout.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
            if !clear {
                for range in tableHighlights[id]?[cell] ?? [] {
                    if let start = content.location(content.documentRange.location, offsetBy: range.location),
                       let end = content.location(start, offsetBy: range.length),
                       let textRange = NSTextRange(location: start, end: end) {
                        layout.addRenderingAttribute(.backgroundColor, value: highlight, for: textRange)
                    }
                }
            }
        }
    }
}

private struct NoteFindBar: View {
    @ObservedObject var find: NoteFindController
    var body: some View {
        VStack(spacing: 4) {
            AtticTabsSearchField(placeholder: String(localized: "Find in note"), text: $find.query,
                                 isFocused: $find.fieldFocused, nativeInputIdentifier: "note-find", onEscape: { find.close() })
            HStack(spacing: 4) {
                AtticText(verbatim: find.matches.isEmpty ? String(localized: "No matches") : "\((find.index ?? -1) + 1) / \(find.matches.count)",
                          style: .rowMeta, ink: .helper)
                    .accessibilityIdentifier("note-find-count")
                Spacer()
                AtticSmallButton(systemName: "chevron.up", label: "Previous match") { find.next(backward: true) }
                    .accessibilityIdentifier("note-find-previous")
                    .disabled(find.matches.isEmpty)
                AtticSmallButton(systemName: "chevron.down", label: "Next match") { find.next() }
                    .accessibilityIdentifier("note-find-next")
                    .disabled(find.matches.isEmpty)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-find-bar")
        .padding(AtticSpacing.s8)
        .background(AtticPopoverBackground(cornerRadius: AtticRadius.contentCard))
    }
}

/// Find in the panel's top row (N4, Idea B): the header's round field fills
/// the row, with "2/7 ‹ ›", All notes and × at its end. Return and ⇧Return
/// step (the controller's keys), Escape or × end it.
struct NoteFindTopRowField: View {
    @ObservedObject var find: NoteFindController
    /// All notes at the field's end: the query goes on to the notes' search
    /// (nil on a task's page, which lives in Tasks: no pill).
    let onAllNotes: (() -> Void)?

    @Environment(\.atticDesign) private var design

    /// The draft's tail, design px halved (`adaptive-drafts-notes.html`, N4).
    enum Metrics {
        static let countFont: CGFloat = 10
        static let countLeading: CGFloat = 4
        static let countTrailing: CGFloat = 3
        static let step: CGFloat = 22
        static let stepGlyph: CGFloat = 10
        static let allNotesHeight: CGFloat = 20
        static let allNotesPadding: CGFloat = 6
        static let allNotesFont: CGFloat = 9.5
        static let allNotesLeading: CGFloat = 1
    }

    /// "2/7", "7" before a match is current, "No matches"; nothing while
    /// the field is empty.
    static func count(query: String, matches: Int, index: Int?) -> String {
        guard !query.isEmpty else { return "" }
        guard matches > 0 else { return String(localized: "No matches") }
        return index.map { "\($0 + 1)/\(matches)" } ?? "\(matches)"
    }

    var body: some View {
        AtticTabsSearchField(placeholder: String(localized: "Find in note"), text: $find.query,
                             isFocused: $find.fieldFocused, nativeInputIdentifier: NoteFindController.fieldIdentifier,
                             nativeFocusClaim: find.topRowFieldClaim, floating: true, onEscape: { find.close() }, header: true, accessory: AnyView(tail))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("note-find-bar")
            .onAppear {
                // The field takes the keyboard the moment it is in the window.
                for delay in [0.0, 0.05, 0.15, 0.4] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { find.topRowFieldAppeared() }
                }
            }
            .id(find.fieldSessionID)
    }

    private var tail: some View {
        let tokens = design.tokens
        let count = Self.count(query: find.query, matches: find.matches.count, index: find.index)
        return HStack(spacing: 0) {
            if !count.isEmpty {
                Text(verbatim: count)
                    .font(.system(size: Metrics.countFont).monospacedDigit())
                    .foregroundStyle(tokens.color(.helper))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, Metrics.countLeading)
                    .padding(.trailing, Metrics.countTrailing)
                    .accessibilityLabel(Text(verbatim: count))
                    .accessibilityIdentifier("note-find-count")
            }
            step("chevron.left", label: String(localized: "Previous match"), identifier: "note-find-previous") {
                find.next(backward: true)
            }
            step("chevron.right", label: String(localized: "Next match"), identifier: "note-find-next") {
                find.next()
            }
            if let onAllNotes {
            Button(action: onAllNotes) {
                Text("All notes")
                    .font(.system(size: Metrics.allNotesFont))
                    .foregroundStyle(tokens.color(.label))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Metrics.allNotesPadding)
                    .frame(height: Metrics.allNotesHeight)
                    .background(Capsule(style: .continuous).fill(tokens.color(.heading).opacity(0.05)))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(String(localized: "Search all notes (⇧⌘F)"))
            .accessibilityIdentifier("note-find-all-notes")
            .padding(.leading, Metrics.allNotesLeading)
            }
        }
    }

    private func step(_ systemName: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AtticIcon(systemName: systemName, size: Metrics.stepGlyph, weight: AtticIconWeight.outline, ink: .glyph)
                .frame(width: Metrics.step, height: Metrics.step)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(find.matches.isEmpty)
        .opacity(find.matches.isEmpty ? 0.4 : 1)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Mirrors the open note's Find into its page, so the top row folds for it;
/// the page's Find goes to the top row while the note shows.
struct NoteFindTopRowObserver: View {
    @ObservedObject var find: NoteFindController
    @Binding var shown: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear { find.inTopRow = true }
            .onChange(of: find.isShown, initial: true) { _, now in if shown != now { shown = now } }
            .onDisappear {
                find.close(returnFocus: false)
                find.inTopRow = false
                if shown { shown = false }
            }
    }
}

extension NoteEditorEngine {
    /// A library search opens the writing at its paragraph without opening
    /// Find or changing its query/highlights. Structured fields stay outside
    /// the editor's in-page Find, including on a task page.
    func searchParagraph(matching query: String) -> NSRange? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let text = textStorage.string as NSString
        let start = isBodyOnly || text.length == 0 ? 0
            : NSMaxRange(text.paragraphRange(for: NSRange(location: 0, length: 0)))
        let scope = NSRange(location: start, length: max(0, text.length - start))
        let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: scope)
        if match.location != NSNotFound {
            return NSRange(location: text.paragraphRange(for: match).location, length: 0)
        }
        var tableRange: NSRange?
        textStorage.enumerateAttribute(.attachment, in: scope) { value, range, stop in
            guard let table = value as? NoteTableAttachment,
                  table.table.texts.flatMap({ $0 }).contains(where: { $0.localizedStandardContains(query) }) else { return }
            tableRange = range; stop.pointee = true
        }
        return tableRange
    }

    func revealSearchParagraph(_ range: NSRange) {
        unfoldHeadings(containing: range)
        textView?.setSelectedRange(range)
        textView?.scrollRangeToVisible(range)
    }
}
