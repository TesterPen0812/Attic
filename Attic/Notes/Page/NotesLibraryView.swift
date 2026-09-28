import AppKit
import SwiftUI

/// All notes, plain (slice 2): the fixed "All notes" label on the tabs'
/// line with a quiet magnifier at its end, then the notes in date groups.
/// The filters and More tags… arrive with slice 4. Typing, ⌘F or the
/// magnifier turn the label line into the search field (a springy
/// take-over); ↑ ↓ move through the rows, Return opens, ⌘⌫ deletes; Esc
/// ends the search, then goes back to the note.
struct NotesLibraryView: View {
    @ObservedObject var model: NotesLibraryModel
    @ObservedObject var controller: NotesPageController
    @ObservedObject var store: NoteStore
    let layout: PanelPageLayout
    let bottomClearance: CGFloat
    @Binding var searchFocused: Bool
    let rowCommands: (UUID) -> [AtticMenuCommand]
    let onOpen: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onBack: () -> Void

    @Environment(\.atticDesign) private var design
    @FocusState private var fieldFocused: Bool
    /// The search was opened (the magnifier, ⌘F, typing): the field shows
    /// first, then takes the keyboard (a focus set on a field that isn't
    /// there yet is lost).
    @State private var searchOpen = false
    @StateObject private var keys = NotesLibraryKeys()
    /// Where the rows' ⋯ are: ⇧⌘I opens the menu under the highlighted one.
    @State private var anchors = AtticNoteRowAnchors()

    static let space = NamedCoordinateSpace.named("AtticNotesLibrary")

    private var pageEdge: CGFloat { max(0, layout.chromeInsets.leading - AtticSpacing.panelMargin) }

    /// The search holds the label line from when it is opened, and while it
    /// has the keyboard or a query.
    static func searchShown(open: Bool, focused: Bool, query: String) -> Bool { open || focused || !query.isEmpty }

    /// What a key typed in the list starts a search with: a printable,
    /// non-blank character without ⌘, ⌃ or ⌥ (never an arrow or a shortcut).
    static func typedSearchText(_ key: KeyEquivalent, modifiers: EventModifiers) -> String? {
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let character = key.character
        guard !character.isWhitespace, !character.isNewline,
              character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol,
              character.unicodeScalars.allSatisfy({ !(0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return String(character)
    }

    var body: some View {
        let groups = model.groups(store: store, drafts: controller.failedDrafts)
        let selected = controller.librarySelectionID
        let shown = Self.searchShown(open: searchOpen, focused: fieldFocused, query: model.query)
        VStack(alignment: .leading, spacing: 0) {
            AtticNoteLibraryLine(title: String(localized: "All notes"), placeholder: placeholder, query: $model.query,
                                 searchShown: shown, fieldFocused: $fieldFocused,
                                 onBeginSearch: { beginSearch() }, onEndSearch: endSearch)
                // Centred on the tabs' line, as on Tasks.
                .padding(.top, layout.headerBottom + AtticLayout.pageTabsTop
                    - (AtticControlSize.smallHeight - AtticLayout.pageTabsHeight) / 2)
                .padding(.bottom, AtticLayout.pageTabsToList
                    - (AtticControlSize.smallHeight - AtticLayout.pageTabsHeight) / 2)
            list(groups, selected: selected)
        }
        .padding(.horizontal, pageEdge)
        .background(NotesWindowReader(keys: keys).frame(width: 0, height: 0).accessibilityHidden(true))
        .onAppear {
            keys.handler = { event in handle(event) }
            keys.start()
            if searchFocused { beginSearch() }
        }
        .onDisappear { keys.stop() }
        .onChange(of: searchFocused) { _, wanted in if wanted { beginSearch() } }
        .onChange(of: fieldFocused) { _, focused in
            if searchFocused != focused { searchFocused = focused }
            // Leaving an empty search gives the line back.
            if !focused, model.query.isEmpty { searchOpen = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-library")
    }

    // MARK: Search

    /// Opens the search. `replaying` is the keystroke that opened it by
    /// typing: once the field has the keyboard it is delivered through the
    /// text-input system (so an input method composes it), never inserted
    /// as raw characters.
    private func beginSearch(replaying event: NSEvent? = nil) {
        searchOpen = true
        var pending = event
        var placedCaret = false
        // Once the field is there it takes the keyboard. A focused field
        // selects all its text: the first time only, the insertion point
        // goes after it, as if typed; a selection the person makes after
        // that is left alone.
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard searchOpen || !model.query.isEmpty else { return }
                if !fieldFocused { fieldFocused = true }
                guard let editor = keys.window?.firstResponder as? NSTextView else { return }
                if !placedCaret {
                    placedCaret = true
                    let length = (editor.string as NSString).length
                    if length > 0, editor.selectedRange() == NSRange(location: 0, length: length) {
                        editor.setSelectedRange(NSRange(location: length, length: 0))
                    }
                }
                if let event = pending {
                    pending = nil
                    NotesLibraryKeys.deliver(event, to: editor)
                }
            }
        }
    }

    private func endSearch() {
        model.clearSearch()
        searchOpen = false
        fieldFocused = false
        searchFocused = false
    }

    /// The library's keys, in its own window only: Esc, ⌘F, ↑ ↓, Return,
    /// ⌘⌫, the row's actions (⇧⌘I, ⌘D, ⌥⇧⌘C), ⌘Z / ⇧⌘Z and type-to-search.
    /// Returns true when the key was used.
    ///
    /// Scope: while All notes shows, these keys act on its row (the
    /// keyboard's, else the selected note); the open note's own shortcuts
    /// (the page's hidden buttons) are off then. Every row command comes
    /// from `rowCommands`, the one list the menu shows.
    private func handle(_ event: NSEvent) -> Bool {
        let groups = model.groups(store: store, drafts: controller.failedDrafts)
        let selected = controller.librarySelectionID
        let editor = keys.window?.firstResponder as? NSTextView
        let action = Self.keyAction(keyCode: event.keyCode, modifiers: EventModifiers(event.modifierFlags),
                                    characters: event.charactersIgnoringModifiers,
                                    composing: editor?.hasMarkedText() == true, fieldFocused: fieldFocused,
                                    fieldCanUndo: fieldFocused && editor?.undoManager?.canUndo == true,
                                    fieldCanRedo: fieldFocused && editor?.undoManager?.canRedo == true)
        switch action {
        case .passThrough:
            return false
        case .escape:
            if Self.searchShown(open: searchOpen, focused: fieldFocused, query: model.query) { endSearch() } else { onBack() }
        case .find:
            beginSearch()
        case let .move(step):
            model.moveHighlight(by: step, in: groups, from: selected)
        case .open:
            guard let id = model.openTarget(in: groups) else { return false }
            onOpen(id)
        case .delete:
            // In the search field ⌘⌫ edits the text until ↑ ↓ picked a row.
            guard let id = model.deleteTarget(in: groups, selected: selected, inField: fieldFocused) else { return false }
            onDelete(id)
        case .actions:
            guard let id = model.commandTarget(in: groups, selected: selected) else { return false }
            showActions(for: id)
        case .duplicate:
            guard let id = model.commandTarget(in: groups, selected: selected) else { return false }
            _ = Self.run(Self.duplicateIdentifier, in: rowCommands(id))
        case .copyMarkdown:
            guard let id = model.commandTarget(in: groups, selected: selected) else { return false }
            _ = Self.run(Self.copyMarkdownIdentifier, in: rowCommands(id))
        case .undo:
            // The library's own history; with nothing to undo the key goes on.
            guard controller.canUndoLibrary else { return false }
            controller.undoLibrary()
        case .redo:
            guard controller.canRedoLibrary else { return false }
            controller.redoLibrary()
        case .startSearch:
            beginSearch(replaying: event)
        }
        return true
    }

    static let duplicateIdentifier = "notes-row-duplicate"
    static let copyMarkdownIdentifier = "notes-row-copy-markdown"
    static let undoIdentifier = "notes-row-undo"
    static let redoIdentifier = "notes-row-redo"

    /// Runs the command with this identifier if the list has it and it is
    /// enabled; a disabled command is swallowed, never run. False when the
    /// list has no such command.
    @discardableResult
    static func run(_ identifier: String, in commands: [AtticMenuCommand]) -> Bool {
        guard let command = commands.first(where: { $0.identifier == identifier }) else { return false }
        if !command.isDisabled { command.action() }
        return true
    }

    /// The row's actions menu under its ⋯ (or under the pointer when the
    /// row is not on screen). Opened on the next turn: the menu tracks
    /// events itself and must not start inside the key monitor.
    private func showActions(for id: UUID) {
        let commands = rowCommands(id)
        let anchor = anchors.view(for: id)
        DispatchQueue.main.async { [keys] in
            if let anchor, anchor.window != nil {
                AtticNativeMenu.popUp(commands, below: anchor.bounds, in: anchor)
            } else if let window = keys.window, let content = window.contentView {
                let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                AtticNativeMenu.popUp(commands, below: NSRect(origin: point, size: .zero), in: content)
            }
        }
    }

    enum KeyAction: Equatable {
        case passThrough, escape, find, move(Int), open, delete, startSearch
        /// ⇧⌘I, ⌘D and ⌥⇧⌘C on the row.
        case actions, duplicate, copyMarkdown
        /// ⌘Z / ⇧⌘Z: the library's history (pin, duplicate, delete).
        case undo, redo
    }

    /// What a key does in All notes. While an input method is composing in
    /// the search field every key is its own (Esc cancels the composition,
    /// the arrows choose a candidate, Return confirms it).
    ///
    /// ⌘Z / ⇧⌘Z: text typed in the search field is undone first (the field
    /// editor's own manager, `fieldCanUndo` / `fieldCanRedo`); when it has
    /// nothing, the library's history answers.
    static func keyAction(keyCode: UInt16, modifiers: EventModifiers, characters: String?,
                          composing: Bool, fieldFocused: Bool,
                          fieldCanUndo: Bool = false, fieldCanRedo: Bool = false) -> KeyAction {
        guard !composing else { return .passThrough }
        let chord = modifiers.intersection([.command, .control, .option, .shift])
        switch keyCode {
        case 53 where chord.isEmpty: return .escape
        case 3 where chord == .command: return .find
        case 125 where chord.isEmpty: return .move(1)
        case 126 where chord.isEmpty: return .move(-1)
        case 36 where chord.isEmpty, 76 where chord.isEmpty: return .open
        case 51 where chord == .command: return .delete
        case 6 where chord == .command: return fieldCanUndo ? .passThrough : .undo
        case 6 where chord == [.command, .shift]: return fieldCanRedo ? .passThrough : .redo
        case 34 where chord == [.command, .shift]: return .actions
        case 2 where chord == .command: return .duplicate
        case 8 where chord == [.command, .option, .shift]: return .copyMarkdown
        default:
            guard !fieldFocused, let first = characters?.first,
                  typedSearchText(KeyEquivalent(first), modifiers: modifiers) != nil else { return .passThrough }
            return .startSearch
        }
    }

    private var placeholder: String {
        let count = store.notes.count
        return count == 1 ? String(localized: "Search 1 note") : String(localized: "Search \(count) notes")
    }

    private func list(_ groups: [NotesLibraryModel.Group], selected: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    status(groups)
                    ForEach(groups) { group in
                        AtticNoteGroupHeading(title: group.title)
                            .modifier(AtticScrollEdgeFade(space: Self.space, top: TasksPage.listTopFade, bottom: AtticEdgeBlur.panelBottom))
                        ForEach(group.rows) { row in
                            AtticNoteRow(model: row, isSelected: row.id == selected && model.highlightedID == nil,
                                         isHighlighted: row.id == model.highlightedID,
                                         commands: { rowCommands(row.id) }, anchors: anchors,
                                         onShowActions: { showActions(for: row.id) },
                                         onOpen: { onOpen(row.id) })
                                .id(row.id)
                                .contextMenu { AtticMenuItems(commands: rowCommands(row.id)) }
                                // Delete and restore: the row folds away or springs back.
                                .transition(design.reduceMotion ? .opacity
                                    : .opacity.combined(with: .move(edge: .leading)))
                                .accessibilityIdentifier("notes-library-row")
                                .modifier(AtticScrollEdgeFade(space: Self.space, top: TasksPage.listTopFade, bottom: AtticEdgeBlur.panelBottom))
                        }
                    }
                }
                .animation(AtticMotionPreset.settle.springy(reduceMotion: design.reduceMotion),
                           value: model.orderedIDs(groups))
            }
            .contentMargins(.bottom, bottomClearance, for: .scrollContent)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectHidden(true, for: .all)
            .coordinateSpace(Self.space)
            .onAppear {
                if let selected { proxy.scrollTo(selected, anchor: .center) }
            }
            .onChange(of: model.highlightedID) { _, id in
                guard let id else { return }
                withAnimation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    /// Empty, no matches, searching and failure: one quiet line where the
    /// first row would be; a failure keeps the earlier results under it.
    @ViewBuilder
    private func status(_ groups: [NotesLibraryModel.Group]) -> some View {
        if case .failed = model.searchState {
            AtticErrorLine(message: String(localized: "Couldn’t search"), onRetry: model.retry)
                .padding(.leading, AtticNoteMetrics.rowTextX)
                .frame(height: AtticLayout.rowPitch)
                .accessibilityIdentifier("notes-library-search-failed")
        } else if groups.isEmpty {
            if model.isSearching {
                if model.matches == nil || model.showsLoading {
                    if model.showsLoading {
                        AtticLoadingRows(count: 2).accessibilityIdentifier("notes-library-searching")
                    }
                } else {
                    emptyLine(String(localized: "No notes match “\(model.matchedQuery)”"))
                }
            } else {
                emptyLine(String(localized: "No notes yet"))
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        AtticText(verbatim: text, style: .listBody, ink: .helper)
            .frame(height: AtticLayout.rowPitch)
            .padding(.leading, AtticNoteMetrics.rowTextX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("notes-library-empty")
    }
}

/// The library's key monitor: active while All notes shows, and only for
/// key events in its own window (never Settings, never a menu).
@MainActor
final class NotesLibraryKeys: ObservableObject {
    weak var window: NSWindow?
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      let handler = self.handler else { return event }
                return handler(event) ? nil : event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Gives a keystroke to a text view through the text-input system
    /// (its input method composes it), as if it had been typed there.
    static func deliver(_ event: NSEvent, to editor: NSTextView) {
        editor.interpretKeyEvents([event])
    }
}

private struct NotesWindowReader: NSViewRepresentable {
    let keys: NotesLibraryKeys

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.keys = keys
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        keys.window = view.window
    }

    private final class ReaderView: NSView {
        weak var keys: NotesLibraryKeys?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated { keys?.window = window }
        }
    }
}

extension EventModifiers {
    /// The SwiftUI form of an AppKit event's modifier flags.
    init(_ flags: NSEvent.ModifierFlags) {
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}
