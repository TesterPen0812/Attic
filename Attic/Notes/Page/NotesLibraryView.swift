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
    /// The top row's search field has the keyboard (the field is the
    /// Notes page's, in the panel's top row).
    @Binding var searchFocused: Bool
    /// The search was opened (the top row's magnifier, ⌘F, typing): the
    /// field shows first, then takes the keyboard (a focus set on a field
    /// that isn't there yet is lost).
    @Binding var searchOpen: Bool
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
    /// The search field's keyboard, as the top row's field reports it.
    private var fieldFocused: Bool {
        get { searchFocused }
        nonmutating set { searchFocused = newValue }
    }
    @StateObject var keys = NotesLibraryKeys()
    @State private var keyOwner = UUID()
    /// Board | list: the notes move between their rows and cards.
    @Namespace private var layoutMotion
    /// Where the rows' ⋯ are: ⇧⌘I opens the menu under the highlighted one.
    @State private var anchors = AtticNoteRowAnchors()
    @State private var reveal = NotesLibraryReveal()
    @State private var recoveryReview: WorkspaceOperationCoordinator.RecoveryIssue?
    @State private var recoveryActionRunning = false
    @State private var confirmRecoveryDiscard = false
    @State private var recoveryActionMessage: String?

    static let space = NamedCoordinateSpace.named("AtticNotesLibrary")

    private var pageEdge: CGFloat { AtticNoteMetrics.libraryPageEdge(chromeInset: layout.chromeInsets.leading) }

    /// The library's floating edges: the panel's top row above (search
    /// and tags moved to the top row and the bottom bar, Notes Page v2),
    /// the bottom bar below.
    static func edges(layout: PanelPageLayout, bottomControls: CGFloat) -> AtticFloatingEdges {
        AtticFloatingEdges(top: layout.headerBottom, bottom: bottomControls)
    }
    /// Where the list starts: right under the top row (the design's list
    /// padding, 100 px, is 15 px under the 85 px top row).
    static func restTop(layout: PanelPageLayout) -> CGFloat { layout.headerBottom + listTopGap }
    static let listTopGap: CGFloat = 7.5
    private var restTop: CGFloat { Self.restTop(layout: layout) }

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
        let groups = model.groups(store: store, drafts: controller.failedDrafts, prepareSummaries: false)
        let selected = controller.librarySelectionID
        // A15 (owner, 2026-10-04): the rows run under the label line and the
        // header, faintly, as on Tasks; the line floats over them.
        ZStack(alignment: .top) {
            list(groups, selected: selected)
            // The variable blur, its own layer under the label line (the
            // bottom row has none; never an overlay of the list).
            AtticEdgeBlurBackdrops(Self.edges(layout: layout, bottomControls: bottomControls))
            // The top row's band owns its clicks, as Tasks' header: a row
            // scrolled under it is not clickable through it.
            Color.clear
                .frame(height: layout.headerBottom)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, pageEdge)
        .background(NotesWindowReader(keys: keys).frame(width: 0, height: 0).accessibilityHidden(true))
        .onAppear {
            keys.start(owner: keyOwner, handler: { event in handle(event) })
            if searchFocused { beginSearch() }
        }
        .onDisappear { keys.stop(owner: keyOwner) }
        .onChange(of: searchFocused) { _, focused in
            if focused {
                if !searchOpen { beginSearch() }
            } else if model.query.isEmpty {
                // Leaving an empty search gives the button back.
                searchOpen = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-library")
        .sheet(item: $recoveryReview) { issue in
            VStack(alignment: .leading, spacing: 16) {
                Text("Recovery copy kept").font(.headline)
                Text(issue.preIntentAbort
                     ? "An interrupted change stopped before it could save. Its recovery files are kept. Your notes and tasks can still save."
                     : "An interrupted change has damaged recovery data. Its files are kept, and changes to known affected items wait for recovery. Other notes and tasks can still save.")
                ScrollView {
                    Text(issue.previewText ?? String(localized: "No readable interrupted text is available. The original recovery files are kept."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(maxHeight: 200)
                    .accessibilityIdentifier("notes-workspace-recovery-preview")
                if let recoveryActionMessage { Text(recoveryActionMessage).font(.caption) }
                HStack {
                    Button("Restore as New Note") { resolveRecovery(issue, restoring: true) }
                        .disabled(recoveryActionRunning || issue.previewText == nil)
                    Button("Discard…", role: .destructive) { confirmRecoveryDiscard = true }
                        .disabled(recoveryActionRunning)
                }
                HStack {
                    Button("Show Recovery Files") { NSWorkspace.shared.activateFileViewerSelecting([issue.directory]) }
                    Spacer()
                    Button("Done") { recoveryReview = nil }.keyboardShortcut(.defaultAction)
                        .disabled(recoveryActionRunning)
                }
            }.padding(24).frame(width: 420)
                .alert("Discard interrupted change?", isPresented: $confirmRecoveryDiscard) {
                    Button("Discard", role: .destructive) { resolveRecovery(issue, restoring: false) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes this recovery entry and moves its files to Attic’s quarantine trash. Saved notes, legacy files and other recovery copies are kept.")
                }
        }
        .onChange(of: recoveryReview?.id) { _, _ in recoveryActionMessage = nil }
    }

    private func resolveRecovery(_ issue: WorkspaceOperationCoordinator.RecoveryIssue, restoring: Bool) {
        recoveryActionRunning = true
        recoveryActionMessage = nil
        Task { @MainActor in
            defer { recoveryActionRunning = false }
            do {
                if restoring { _ = try await controller.restoreWorkspaceRecoveryAsNewNote(issue) }
                else { try await controller.discardWorkspaceRecovery(issue) }
                guard recoveryReview?.id == issue.id else { return }
                if controller.workspaceRecoveryIssues.contains(issue) {
                    recoveryActionMessage = String(localized: "A new note was saved. Its interrupted recovery copy remains until its earlier save can be confirmed.")
                } else { recoveryReview = nil }
            } catch {
                if recoveryReview?.id == issue.id { recoveryActionMessage = error.localizedDescription }
            }
        }
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
        // The library slides away when a note opens, and this view (and its
        // monitor) outlives that slide by a moment: a key pressed in the
        // note is the note's, never the library's.
        guard controller.isLibraryPresented else { return false }
        let all = model.groups(store: store, drafts: controller.failedDrafts, prepareSummaries: false)
        // A folded section's rows are not in the list (the board folds none).
        let groups = model.navigable(all, layout: model.layout, store: store)
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
            if let id = model.openTarget(in: groups) ?? (event.modifierFlags.contains(.command) ? model.commandTarget(in: groups, selected: selected) : nil) {
                onOpen(id)
            } else if !event.modifierFlags.contains(.command), fieldFocused, let title = model.queryForNewNote(in: all) {
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

    /// A row's Filter by Tag ▸ (right-click): the note's tags, since rows
    /// don't repeat them. In All notes a tag filters (D3); the active one is
    /// ticked and choosing it again shows every note. Dimmed with none. It
    /// says it filters, since the task menu's Tags › edits (Dropdown
    /// content: answers, owner, 2026-10-24, sheet 2).
    static func tagsSubmenu(tags: [String], activeTag: String?, hue: (String) -> AtticTagHue? = { _ in nil },
                            onSelect: @escaping (String?) -> Void) -> AtticMenuCommand {
        var command = AtticMenuCommand.submenu(String(localized: "Filter by Tag"), width: AtticMenuMetrics.wideWidth, tags.map { tag in
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

    /// A section header's leading shift: Tasks' header text sits on its
    /// rows' 9 pt padding; the notes rows' is 8.
    static let headerShift: CGFloat = AtticNoteMetrics.libraryHighlightInset + NotesLibraryRowMetrics.paddingX
        - TasksDesignMetrics.groupHeaderX

    enum ActionsMenu { case hover, full }

    /// The short ••• menu uses the same producers as the full row menu:
    /// Pin, Add to / Remove from Tasks, Delete, with their live eligibility.
    static func hoverMenu(_ commands: [AtticMenuCommand], pinned: Bool) -> [AtticMenuCommand] {
        var menu: [AtticMenuCommand] = []
        if let pin = commands.first(where: { $0.identifier == "notes-row-pin" }) {
            var item = AtticMenuCommand(verbatim: pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                systemImage: pin.systemImage, shortcut: pin.shortcut, isDisabled: pin.isDisabled, action: pin.action)
            item.identifier = pin.identifier
            item.disabledReason = pin.disabledReason
            menu.append(item)
        }
        menu += commands.filter {
            $0.identifier == "one-item-add-to-tasks" || $0.identifier == "one-item-remove-from-tasks"
        }
        if var delete = commands.first(where: { $0.identifier == "notes-row-delete" }) {
            delete.startsSection = !menu.isEmpty
            menu.append(delete)
        }
        return menu
    }

    private func hoverMenu(for id: UUID) -> [AtticMenuCommand] {
        Self.hoverMenu(rowCommands(id), pinned: store.note(withID: id)?.isPinned ?? false)
    }

    /// The row's actions menu under its ⋯ (or under the pointer when the
    /// row is not on screen). Opened on the next turn: the menu tracks
    /// events itself and must not start inside the key monitor. The •••
    /// opens the design's short menu; ⇧⌘I the row's full list.
    private func showActions(for id: UUID, menu: ActionsMenu = .full) {
        let commands = menu == .hover ? hoverMenu(for: id) : rowCommands(id)
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
        case 36 where chord.isEmpty || chord == .command, 76 where chord.isEmpty || chord == .command: return .open
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

    private func list(_ groups: [NotesLibraryModel.Group], selected: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                if model.layout == .board {
                    // The board's columns are lazy themselves.
                    VStack(alignment: .leading, spacing: 0) {
                        preamble(groups)
                        board(groups, selected: selected)
                    }
                    .animation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion),
                               value: model.orderedIDs(groups))
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        preamble(groups)
                        // Foldable sections that work and look like Tasks' date
                        // groups (the owner's panel design, 2026-10-27).
                        ForEach(groups) { group in
                            let folded = model.foldedGroups.contains(group.id)
                            TasksGroupHeader(title: group.title, count: group.rows.count, folded: folded) {
                                withAnimation(design.reduceMotion ? nil : TasksDesignMetrics.curve(0.26)) {
                                    model.toggleGroup(group.id, in: groups)
                                }
                            }
                            // The header's text on the rows' thumbnails.
                            .padding(.leading, Self.headerShift)
                            .id("group:" + group.id)
                            .accessibilityIdentifier("notes-library-group-\(group.id)")
                            if !folded {
                                ForEach(group.rows) { row in
                                    PreparedNotesLibraryRow(library: model, store: store, revision: store.revision, row: row,
                                        isSelected: row.id == selected && model.highlightedID == nil,
                                        isHighlighted: row.id == model.highlightedID,
                                        commands: { rowCommands(row.id) }, anchors: anchors,
                                        onShowActions: { showActions(for: row.id, menu: .hover) }, onOpen: { onOpen(row.id) })
                                        // Rows sit 2 apart, no dividers.
                                        .padding(.top, row.id == group.rows.first?.id ? 0 : NotesLibraryRowMetrics.rowGap)
                                        .padding(.horizontal, AtticNoteMetrics.libraryHighlightInset)
                                        .matchedGeometryEffect(id: row.id, in: layoutMotion)
                                        .id(row.id)
                                        .background { NotesRevealAnchor(id: row.id, reveal: reveal) }
                                        .atticContextMenu { rowCommands(row.id) }
                                        // Delete and restore: the row folds away or springs back.
                                        .transition(design.reduceMotion ? .opacity
                                            : .opacity.combined(with: .move(edge: .leading)))
                                        .accessibilityIdentifier("notes-library-row")
                                }
                            }
                        }
                    }
                    .animation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion),
                               value: model.orderedIDs(model.unfolded(groups)))
                }
            }
            .contentMargins(.top, restTop, for: .scrollContent)
            .contentMargins(.bottom, bottomControls + bottomClearance, for: .scrollContent)
            .contentMargins(.top, restTop, for: .scrollIndicators)
            .contentMargins(.bottom, bottomControls, for: .scrollIndicators)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectHidden(true, for: .all)
            // Floating controls (owner, 2026-10-14), as on Tasks: rows run
            // on under the label line, visible through the variable blur
            // (owner, 2026-10-17), and under the bottom row, sharp (10-22).
            .overlay { AtticFloatingControlsBand(height: bottomControls) }
            .coordinateSpace(Self.space)
            // Right-click anywhere the rows are not (all of it, with none):
            // the library's history, so Undo never depends on a row.
            .contentShape(Rectangle())
            .atticContextMenu { libraryCommands() }
            .onAppear {
                if let selected { proxy.scrollTo(selected, anchor: .center) }
            }
            // ↑ ↓: never an animated `scrollTo` over the lazy stacks (the
            // list hang, 2026-10-28). A row or card laid out glides there
            // by the clip view; one not built yet is jumped to.
            .onChange(of: model.highlightedID) { _, id in
                guard let id else { return }
                if !reveal.reveal(id, clearTop: restTop, clearBottom: bottomControls + bottomClearance,
                                  reduceMotion: design.reduceMotion) {
                    var jump = Transaction()
                    jump.disablesAnimations = true
                    withTransaction(jump) { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// Search failure or emptiness, then any recovery or proposal waiting:
    /// above the list or the board.
    @ViewBuilder
    private func preamble(_ groups: [NotesLibraryModel.Group]) -> some View {
        status(groups)
        ForEach(controller.workspaceRecoveryIssues) { issue in
            Button("Review interrupted change") { recoveryReview = issue }
                .font(Font(AtticTextStyle.rowMeta.nsFont))
                .padding(.vertical, 8)
                .buttonStyle(.plain)
                .accessibilityIdentifier("notes-workspace-recovery-\(issue.directory.lastPathComponent)")
        }
        ForEach(controller.workspaceProposals, id: \.id) { proposal in
            Button {
                Task { @MainActor in _ = await controller.beginProposalReview(id: proposal.id) }
            } label: {
                Text("Review proposed workspace change")
                    .font(Font(AtticTextStyle.rowMeta.nsFont))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }.buttonStyle(.plain)
            .accessibilityIdentifier("notes-workspace-proposal-\(proposal.id)")
        }
    }

    /// The board (Accepted 2026-10-30, "Notes board"): one flowing board in
    /// two columns, no headings, pinned first; each card in the shorter
    /// column by its estimated height (`NotesBoardLayout`).
    private func board(_ groups: [NotesLibraryModel.Group], selected: UUID?) -> some View {
        let columns = model.boardColumns(groups, store: store)
        return HStack(alignment: .top, spacing: NotesBoardMetrics.columnGap) {
            ForEach(columns.indices, id: \.self) { index in
                LazyVStack(alignment: .leading, spacing: NotesBoardMetrics.cardGap) {
                    ForEach(columns[index]) { row in
                        PreparedNotesBoardCard(library: model, store: store, revision: store.revision,
                            tagFilter: model.tagFilter, row: row,
                            isSelected: row.id == selected && model.highlightedID == nil,
                            isHighlighted: row.id == model.highlightedID,
                            commands: { rowCommands(row.id) }, anchors: anchors,
                            onShowActions: { showActions(for: row.id, menu: .hover) }, onOpen: { onOpen(row.id) })
                            .equatable()
                            // Board | list (owner, 2026-10-31): each note moves
                            // from its row to its card and back.
                            .matchedGeometryEffect(id: row.id, in: layoutMotion)
                            .id(row.id)
                            .background { NotesRevealAnchor(id: row.id, reveal: reveal) }
                            .atticContextMenu { rowCommands(row.id) }
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notes-board-column-\(index)")
            }
        }
        .padding(.top, NotesBoardMetrics.topPadding)
        .padding(.horizontal, AtticNoteMetrics.libraryHighlightInset)
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
    private var owner: UUID?

    func start(owner: UUID, handler: @escaping (NSEvent) -> Bool) {
        self.owner = owner
        self.handler = handler
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      let handler = self.handler else { return event }
                return handler(event) ? nil : event
            }
        }
    }

    func stop(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        handler = nil
        window = nil
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

private struct PreparedNotesLibraryRow: View {
    let library: NotesLibraryModel
    let store: NoteStore
    let revision: UInt64
    let row: AtticNoteRowModel
    let isSelected: Bool
    let isHighlighted: Bool
    let commands: () -> [AtticMenuCommand]
    let anchors: AtticNoteRowAnchors
    let onShowActions: () -> Void
    let onOpen: () -> Void
    var body: some View {
        NotesLibraryRow(details: library.libraryRow(row, store: store), thumbnails: library.thumbnails,
                        isSelected: isSelected, isHighlighted: isHighlighted,
                        commands: commands, anchors: anchors, onShowActions: onShowActions, onOpen: onOpen)
    }
}

/// Equal (its card not drawn again) while what the card shows is the same:
/// ↑ ↓ redraw the two cards whose marks change, not every card built
/// (fix round 1). The callbacks only name the card's note.
private struct PreparedNotesBoardCard: View, Equatable {
    let library: NotesLibraryModel
    let store: NoteStore
    let revision: UInt64
    /// The first tag a card shows is never the one the list is filtered by.
    let tagFilter: String?
    let row: AtticNoteRowModel
    let isSelected: Bool
    let isHighlighted: Bool
    let commands: () -> [AtticMenuCommand]
    let anchors: AtticNoteRowAnchors
    let onShowActions: () -> Void
    let onOpen: () -> Void
    var body: some View {
        NotesBoardCard(details: library.libraryRow(row, store: store),
                       pinned: store.note(withID: row.id)?.isPinned ?? false,
                       isSelected: isSelected, isHighlighted: isHighlighted,
                       commands: commands, anchors: anchors, onShowActions: onShowActions, onOpen: onOpen)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.library === rhs.library && lhs.store === rhs.store && lhs.revision == rhs.revision
                && lhs.tagFilter == rhs.tagFilter && lhs.row == rhs.row
                && lhs.isSelected == rhs.isSelected && lhs.isHighlighted == rhs.isHighlighted
                && lhs.anchors === rhs.anchors
        }
    }
}

// MARK: - Keyboard reveal

/// Brings the keyboard's row or card into the clear part of the list (↑
/// ↓) the way Tasks reveals a row since the list hang (`hang-report.md`):
/// never an animated `ScrollViewProxy.scrollTo` over the lazy stacks. One
/// laid out glides there on the settle spring, moved by the AppKit clip
/// view (`TasksScrollGlide`), so SwiftUI only sees a plain scroll; Reduce
/// Motion puts it there at once. One not laid out yet is the caller's to
/// jump to. Not observed: nothing here redraws.
@MainActor
final class NotesLibraryReveal {
    private struct Weak { weak var view: NSView? }
    private var views: [UUID: Weak] = [:]
    let glide = TasksScrollGlide()

    func register(_ view: NSView, for id: UUID) { views[id] = Weak(view: view) }

    /// How far the list moves (positive: its content moves up) to bring
    /// `frame` between `clearTop` and `clearBottom`, as little as it can;
    /// nil when it is there already. Taller than the clear part: its top.
    static func delta(frame: CGRect, clearTop: CGFloat, clearBottom: CGFloat) -> CGFloat? {
        if frame.minY < clearTop - 0.5 { return frame.minY - clearTop }
        if frame.maxY > clearBottom + 0.5 { return min(frame.maxY - clearBottom, frame.minY - clearTop) }
        return nil
    }

    /// Reveals `id`'s row when it is laid out in its list (true), else
    /// leaves it to the caller (false). `clearTop` and `clearBottom` are
    /// what the header and the bottom controls cover of the list's view.
    func reveal(_ id: UUID, clearTop: CGFloat, clearBottom: CGFloat, reduceMotion: Bool) -> Bool {
        guard let view = views[id]?.view, view.window != nil, let scroll = view.enclosingScrollView,
              let document = scroll.documentView, view.isDescendant(of: document) else {
            glide.stop()
            return false
        }
        let clip = scroll.contentView
        let frame = clip.convert(view.bounds, from: view)
        guard let delta = Self.delta(frame: frame, clearTop: clip.bounds.minY + clearTop,
                                     clearBottom: clip.bounds.maxY - clearBottom) else { return true }
        if reduceMotion {
            glide.stop()
            var origin = clip.bounds.origin
            origin.y = TasksScrollKeeper.clampedOriginY(origin.y + delta, in: scroll)
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        } else {
            let settle = AtticMotionPreset.settle.spring(in: .current)
            glide.run(by: delta, in: scroll, spring: Spring(duration: settle.response, bounce: settle.bounce))
        }
        return true
    }
}

/// A click-through view behind a library row or board card that
/// registers it for the keyboard's reveal.
struct NotesRevealAnchor: NSViewRepresentable {
    let id: UUID
    let reveal: NotesLibraryReveal

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        reveal.register(view, for: id)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        reveal.register(view, for: id)
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
