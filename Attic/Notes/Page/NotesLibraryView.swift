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
    @StateObject private var keys = NotesLibraryKeys()

    static let space = NamedCoordinateSpace.named("AtticNotesLibrary")

    private var pageEdge: CGFloat { max(0, layout.chromeInsets.leading - AtticSpacing.panelMargin) }

    /// The search holds the label line while it has the keyboard or a query.
    static func searchShown(focused: Bool, query: String) -> Bool { focused || !query.isEmpty }

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
        let shown = Self.searchShown(focused: fieldFocused, query: model.query)
        VStack(alignment: .leading, spacing: 0) {
            AtticNoteLibraryLine(title: String(localized: "All notes"), placeholder: placeholder, query: $model.query,
                                 searchShown: shown, fieldFocused: $fieldFocused,
                                 onBeginSearch: beginSearch, onEndSearch: endSearch)
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
        .onChange(of: fieldFocused) { _, focused in if searchFocused != focused { searchFocused = focused } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-library")
    }

    // MARK: Search

    private func beginSearch() {
        fieldFocused = true
        // A focused field selects its text; the insertion point goes after
        // what is there, as if it had been typed.
        for delay in [0.0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard fieldFocused, let editor = keys.window?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    private func endSearch() {
        model.clearSearch()
        fieldFocused = false
        searchFocused = false
    }

    /// The library's keys, in its own window only: Esc, ⌘F, ↑ ↓, Return,
    /// ⌘⌫ and type-to-search. Returns true when the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        let groups = model.groups(store: store, drafts: controller.failedDrafts)
        let selected = controller.librarySelectionID
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 53 where modifiers.isEmpty:
            if Self.searchShown(focused: fieldFocused, query: model.query) { endSearch() } else { onBack() }
            return true
        case 3 where modifiers == .command: // ⌘F
            beginSearch()
            return true
        case 125 where modifiers.isEmpty:
            model.moveHighlight(by: 1, in: groups, from: selected)
            return true
        case 126 where modifiers.isEmpty:
            model.moveHighlight(by: -1, in: groups, from: selected)
            return true
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty:
            guard let id = model.openTarget(in: groups) else { return false }
            onOpen(id)
            return true
        case 51 where modifiers == .command:
            // In the search field ⌘⌫ edits the text until ↑ ↓ picked a row.
            guard let id = model.deleteTarget(in: groups, selected: selected, inField: fieldFocused) else { return false }
            onDelete(id)
            return true
        default:
            guard !fieldFocused, let characters = event.charactersIgnoringModifiers, let first = characters.first,
                  let typed = Self.typedSearchText(KeyEquivalent(first), modifiers: EventModifiers(event.modifierFlags))
            else { return false }
            model.query += event.characters ?? typed
            beginSearch()
            return true
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
                                         isHighlighted: row.id == model.highlightedID) { onOpen(row.id) }
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

private extension EventModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: EventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}
