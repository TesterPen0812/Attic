import AppKit
import SwiftUI

/// All notes: the fixed "All notes" label on the tabs' line, then the
/// recent tags as far as they fit and More tags… (a click filters), a quiet
/// magnifier at its end, then the notes in date groups. Typing, ⌘F or the
/// magnifier turn the label line into the search field (a springy
/// take-over); ↑ ↓ move through the rows, Return opens (or, when a search
/// found nothing, makes the note it names), ⌘⌫ deletes; Esc ends the
/// search, then goes back to the note.
struct NotesLibraryView: View {
    @ObservedObject var model: NotesLibraryModel
    @ObservedObject var controller: NotesPageController
    @ObservedObject var store: NoteStore
    let layout: PanelPageLayout
    let bottomClearance: CGFloat
    /// The bottom row's top, up from the page's bottom edge (A15's fade).
    var bottomControls: CGFloat = 0
    @Binding var searchFocused: Bool
    let rowCommands: (UUID) -> [AtticMenuCommand]
    /// The library's own commands (its history), for the page's background:
    /// the way to Undo with no row to right-click.
    let libraryCommands: () -> [AtticMenuCommand]
    let onOpen: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onBack: () -> Void
    /// "New note “kyoto”" after no matches: the title, and the filter's tag.
    var onCreate: (_ title: String, _ tag: String?) -> Void = { _, _ in }

    @Environment(\.atticDesign) private var design
    @FocusState private var fieldFocused: Bool
    /// The search was opened (the magnifier, ⌘F, typing): the field shows
    /// first, then takes the keyboard (a focus set on a field that isn't
    /// there yet is lost).
    @State private var searchOpen = false
    @StateObject private var keys = NotesLibraryKeys()
    /// Where the rows' ⋯ are: ⇧⌘I opens the menu under the highlighted one.
    @State private var anchors = AtticNoteRowAnchors()
    /// More tags…'s card is open (its keys are its own).
    @State private var moreTagsShown = false

    /// The most tags the top line tries to fit after "All notes".
    static let tagTabLimit = 4

    static let space = NamedCoordinateSpace.named("AtticNotesLibrary")

    private var pageEdge: CGFloat { AtticNoteMetrics.libraryPageEdge(chromeInset: layout.chromeInsets.leading) }

    /// The label line's text top: the tabs' line, as on Tasks.
    private var labelsTop: CGFloat { layout.headerBottom + AtticLayout.pageTabsTop }
    /// Where the first row rests: the label line, then 14 (Tasks' `listTop`).
    private var restTop: CGFloat { labelsTop + AtticLayout.pageTabsHeight + AtticLayout.pageTabsToList }

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
        // A15 (owner, 2026-10-04): the rows run under the label line and the
        // header, faintly, as on Tasks; the line floats over them.
        ZStack(alignment: .top) {
            list(groups, selected: selected)
            // The label line's band owns its clicks, as Tasks' tabs band: a
            // row scrolled under it is not clickable through it.
            Color.clear
                .frame(height: restTop - AtticLayout.pageTabsToList / 2)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            AtticNoteLibraryLine(title: String(localized: "All notes"), placeholder: placeholder, query: $model.query,
                                 searchShown: shown, fieldFocused: $fieldFocused,
                                 onBeginSearch: { beginSearch() }, onEndSearch: endSearch,
                                 tags: model.tagTabs(store: store, limit: Self.tagTabLimit), activeTag: model.tagFilter,
                                 onSelectTag: { tag in selectTag(tag) },
                                 moreTagsShown: $moreTagsShown, moreTagsCard: { AnyView(moreTagsCard) })
                // Centred on the tabs' line, as on Tasks.
                .padding(.top, labelsTop - (AtticControlSize.smallHeight - AtticLayout.pageTabsHeight) / 2)
                // Read before the rows, as when it stood above them.
                .accessibilitySortPriority(1)
        }
        .accessibilityElement(children: .contain)
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

    // MARK: Tags

    /// A tag in the top line, or "All notes" (nil). Clicking the active tag
    /// keeps it (the tabs' rule); the title goes back to every note.
    private func selectTag(_ tag: String?) {
        model.tagFilter = tag
    }

    /// More tags…: every tag with its count, a find field; the active tag
    /// is ticked. Choosing one filters to it (the active one: every note).
    private var moreTagsCard: some View {
        let counts = store.tagCounts
        let all = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return AtticTagPickerCard(rows: { query in
            let needle = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            let shown = needle.isEmpty ? all : all.filter { $0.localizedStandardContains(needle) }
            return (shown.map { AtticTagPicker.Tag(name: $0, state: $0 == model.tagFilter ? .on : .off,
                                                   detail: "\(counts[$0] ?? 0)") }, nil)
        }, listRows: all.count, onToggle: { name in
            model.toggleTag(name)
            moreTagsShown = false
        }, onCreate: { _, _ in false })
        .accessibilityIdentifier("notes-library-more-tags-card")
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
        // The library slides away when a note opens, and this view (and its
        // monitor) outlives that slide by a moment: a key pressed in the
        // note is the note's, never the library's.
        guard controller.isLibraryPresented, !moreTagsShown else { return false }
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
            if let id = model.openTarget(in: groups) {
                onOpen(id)
            } else if fieldFocused, let title = model.queryForNewNote(in: groups) {
                // Nothing matched: Return makes the note the search names.
                onCreate(title, model.tagFilter)
            } else {
                return false
            }
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
            Task { @MainActor in _ = await controller.undoLibraryDurably() }
        case .redo:
            guard controller.canRedoLibrary else { return false }
            Task { @MainActor in _ = await controller.redoLibraryDurably() }
        case .startSearch:
            beginSearch(replaying: event)
        }
        return true
    }

    /// A row's Tags ▸ (right-click): the note's tags, since rows don't
    /// repeat them. In All notes a tag filters (D3); the active one is
    /// ticked and choosing it again shows every note. Dimmed with none.
    static func tagsSubmenu(tags: [String], activeTag: String?, hue: (String) -> AtticTagHue? = { _ in nil },
                            onSelect: @escaping (String?) -> Void) -> AtticMenuCommand {
        var command = AtticMenuCommand.submenu(String(localized: "Tags"), tags.map { tag in
            AtticMenuCommand(verbatim: "#\(tag)", state: tag == activeTag ? .on : nil, swatch: hue(tag)) {
                onSelect(tag == activeTag ? nil : tag)
            }
        })
        command.identifier = "notes-row-tags"
        return command
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
        NotesLibraryModel.placeholder(count: store.notes.count, tag: model.tagFilter)
    }

    private func list(_ groups: [NotesLibraryModel.Group], selected: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    status(groups)
                    ForEach(groups) { group in
                        AtticNoteGroupHeading(title: group.title)
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
                        }
                    }
                }
                .animation(AtticMotionPreset.settle.springy(reduceMotion: design.reduceMotion),
                           value: model.orderedIDs(groups))
            }
            .contentMargins(.top, restTop, for: .scrollContent)
            .contentMargins(.bottom, bottomClearance, for: .scrollContent)
            .contentMargins(.top, restTop, for: .scrollIndicators)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectHidden(true, for: .all)
            // F-13: the library shares the editor's reserved footer band.
            .atticScrollUnderFade(plainText: [labelsTop...(labelsTop + AtticLayout.pageTabsHeight)],
                                  topEdge: layout.scrollEdgeFadeTop, bottomEdge: 0)
            .padding(.bottom, bottomControls)
            .coordinateSpace(Self.space)
            // Right-click anywhere the rows are not (all of it, with none):
            // the library's history, so Undo never depends on a row.
            .contentShape(Rectangle())
            .contextMenu { AtticMenuItems(commands: libraryCommands()) }
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
                    emptyLine(NotesLibraryModel.noMatches(query: model.matchedQuery, tag: model.tagFilter))
                    if let title = model.queryForNewNote(in: groups) {
                        newNoteButton(title: title, tag: model.tagFilter)
                    }
                }
            } else if let tag = model.tagFilter {
                emptyLine(NotesLibraryModel.emptyFilter(tag: tag))
            } else {
                emptyLine(String(localized: "No notes yet"))
            }
        }
    }

    /// The next step after no matches (Return does the same from the field).
    private func newNoteButton(title: String, tag: String?) -> some View {
        Button { onCreate(title, tag) } label: {
            HStack(spacing: AtticNoteMetrics.countGap + 2) {
                AtticIcon(systemName: "square.and.pencil", size: AtticNoteMetrics.countIconSize + 2,
                          weight: .regular, ink: .body)
                AtticText(verbatim: NotesLibraryModel.newNoteTitle(query: title, tag: tag), style: .listBody,
                          ink: .body, truncates: true)
            }
            .frame(height: AtticLayout.rowPitch)
            .padding(.leading, AtticNoteMetrics.rowTextX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .help(String(localized: "Make a note with this title (Return)"))
        .accessibilityIdentifier("notes-library-new-from-search")
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
