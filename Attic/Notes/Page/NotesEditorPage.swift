import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Phase 2 Notes page (slice 2, "Everyday capture and return"; mockups
/// p2-01, p2-04, p2-05, p2-09, p2-12, p2-15, p2-02).
///
/// Only the text, the tag line and the two bottom buttons: All notes
/// (`rectangle.stack`) on the left, New note on the right, and the status
/// slot between them. The note's rarer actions sit behind the ⋯ at the end
/// of the title's first line, which returns as a glass title in the header
/// once the title has scrolled away. Everything goes through the page's
/// controller and its session rules.
struct NotesEditorPage: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    /// Set when the switch is off: All notes returns to the old page.
    var exitToOldPage: (() -> Void)?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticPanelToasts) private var toasts
    @StateObject private var chrome = NotesPageChrome()
    @StateObject private var library: NotesLibraryModel
    @State private var isImporterPresented = false
    @State private var searchFocused = false
    @State private var postedToastID: UUID?

    init(controller: NotesPageController, noteStore: NoteStore, noteDraft: NoteDraftController,
         uiState: PanelUIState, layout: PanelPageLayout, exitToOldPage: (() -> Void)? = nil,
         librarySearch: ((String) async throws -> Set<UUID>)? = nil) {
        self.controller = controller
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.uiState = uiState
        self.layout = layout
        self.exitToOldPage = exitToOldPage
        let store = noteStore
        _library = StateObject(wrappedValue: NotesLibraryModel(search: librarySearch ?? { query in
            try await store.searchNoteIDs(matching: query)
        }))
    }

    // MARK: Direction

    /// The note is to the right of All notes: the library comes in from the
    /// left and leaves to the left, the note from the right; the button in
    /// the bottom-left corner shows the stack, then points back at the note.
    static let libraryEdge: Edge = .leading
    static let noteEdge: Edge = .trailing

    static func libraryButtonGlyph(libraryShown: Bool) -> String {
        libraryShown ? "chevron.right" : "rectangle.stack"
    }

    // MARK: Geometry

    private var buttonHeight: CGFloat { AtticControlSize.panelButton.height }
    /// The note's column: 4 inside the chrome's line (28 in a 320 pt panel).
    private var columnInset: CGFloat { layout.chromeInsets.leading + AtticNoteMetrics.columnInset }
    /// The title's first line 16 under the header.
    private var topInset: CGFloat { layout.headerBottom + AtticNoteMetrics.titleTopGap }
    /// The last line rests 12 above the bottom row.
    private var bottomInset: CGFloat { layout.chromeInsets.bottom + buttonHeight + AtticSpacing.s12 }
    private var noticeClearance: CGFloat {
        max(0, layout.chromeInsets.bottom + buttonHeight + AtticSpacing.s8 - layout.contentInsets.bottom)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsEditor {
                headerTitle
            }
            bottomRow
                .padding(.leading, layout.chromeInsets.leading)
                .padding(.trailing, layout.chromeInsets.trailing)
                .padding(.bottom, layout.chromeInsets.bottom)
            shortcuts
        }
        // Springy slides between the note and All notes, and for a new or
        // another note (keystrokes are never held back: the text view takes
        // the keyboard at once, and nothing here animates per keystroke).
        .animation(AtticMotionPreset.slide.springy(reduceMotion: design.reduceMotion), value: controller.isLibraryPresented)
        .animation(AtticMotionPreset.slide.springy(reduceMotion: design.reduceMotion), value: controller.active?.id)
        .onAppear {
            controller.update(design: design)
            controller.start()
            controller.present()
            chrome.menuCommands = { noteMenuCommands() }
            library.failedDraftText = { [controller, noteStore] id in
                guard noteStore.note(withID: id) == nil,
                      let draft = controller.failedDrafts.first(where: { $0.noteID == id }) else { return nil }
                return NoteTextExport.plainText(draft.engine.document())
            }
        }
        .onChange(of: design) { _, newValue in controller.update(design: newValue) }
        .onChange(of: controller.legacyNoteID) { _, id in openLegacy(id) }
        .onChange(of: controller.active?.id) { _, opened in
            chrome.tagEditor = nil
            // Opening or starting a note ends the delete's Undo toast: ⌘Z
            // belongs to the note's own text again. (Deleting the open note
            // leaves no note on screen, and its toast stays.)
            if opened != nil { dismissOwnToast() }
        }
        .onChange(of: controller.presentationCount) { _, _ in
            // Back on the page (a page switch, the panel shown again): the
            // keyboard returns to the note, where the caret was.
            guard showsEditor else { return }
            DispatchQueue.main.async { chrome.focusText() }
        }
        .onChange(of: controller.isLibraryPresented) { _, shown in
            if shown {
                // Typing searches (the library's own keys): the search
                // stays quiet on the label line until then.
                library.highlightedID = nil
            } else {
                searchFocused = false
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { controller.importImages(urls) }
        }
        .preference(key: PanelPageNoticeClearancePreferenceKey.self, value: noticeClearance)
        // A group, so its identifier never replaces its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-editor-page")
    }

    private var showsEditor: Bool {
        !controller.isLibraryPresented && controller.active != nil && controller.legacyNoteID == nil
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if controller.isLibraryPresented {
            NotesLibraryView(model: library, controller: controller, store: noteStore, layout: layout,
                             bottomClearance: bottomInset, searchFocused: $searchFocused,
                             rowCommands: { id in rowCommands(id) },
                             onOpen: { id in openFromLibrary(id) },
                             onDelete: { id in delete(id) },
                             onBack: { toggleLibrary() })
                .transition(slide(from: Self.libraryEdge))
        } else if let legacyID = controller.legacyNoteID, noteDraft.activeNoteID == legacyID {
            // A note not yet in the new format keeps the old editor.
            NoteComposerView(noteDraft: noteDraft, uiState: uiState,
                             topContentInset: topInset, bottomContentInset: bottomInset)
                .padding(.horizontal, layout.contentInsets.leading)
                .transition(slide(from: Self.noteEdge))
        } else if let session = controller.active {
            NoteEditorRepresentable(session: session, chrome: chrome, columnInset: columnInset,
                                    topInset: topInset, bottomInset: bottomInset, headerBottom: layout.headerBottom,
                                    design: design, tagEditor: { AnyView(tagEditor(for: session)) },
                                    tagCounts: { [noteStore] in
                                        var counts: [String: Int] = [:]
                                        for note in noteStore.notes { for tag in note.tags { counts[tag, default: 0] += 1 } }
                                        return counts
                                    })
                .id(ObjectIdentifier(session.engine))
                .overlay(alignment: .top) {
                    AtticEdgeVeil(edge: .top, height: AtticEdgeBlur.panelTop)
                }
                .overlay(alignment: .bottom) {
                    AtticEdgeVeil(edge: .bottom, height: AtticEdgeBlur.panelBottom)
                }
                .accessibilityIdentifier("note-editor")
                .accessibilitySortPriority(3)
                .transition(slide(from: Self.noteEdge))
        } else {
            Color.clear
        }
    }

    private func slide(from edge: Edge) -> AnyTransition {
        design.reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// The scrolled-away title, back between the pin and the page button.
    private var headerTitle: some View {
        let progress = chrome.headerTitleProgress
        let side = layout.chromeInsets.leading + AtticControlSize.headerControl + AtticSpacing.s8
        return AtticHeaderTitle(title: chrome.headerTitle) { chrome.presentMenu() }
            .frame(maxWidth: max(0, layout.panelSize.width - side * 2))
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, layout.chromeInsets.top)
            .opacity(progress)
            // It settles into the header as the title passes under it
            // (scroll-linked, so no animation runs while typing).
            .offset(y: design.reduceMotion ? 0 : (1 - progress) * -6)
            .scaleEffect(design.reduceMotion ? 1 : 0.94 + 0.06 * progress, anchor: .top)
            .allowsHitTesting(progress > 0.5)
            .accessibilityHidden(progress < 0.5)
            .accessibilityIdentifier("notes-header-title")
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        AtticControlGroup {
            HStack(spacing: 0) {
                AtticRaisedButton(systemName: Self.libraryButtonGlyph(libraryShown: controller.isLibraryPresented),
                                  label: controller.isLibraryPresented ? "Back" : "All notes",
                                  help: allNotesHelp) {
                    toggleLibrary()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .accessibilityIdentifier("notes-all-notes")
                .accessibilitySortPriority(1)
                Spacer(minLength: AtticSpacing.s12)
                if !controller.isLibraryPresented, let session = controller.active {
                    NoteStatusSlot(controller: controller, store: noteStore, session: session)
                        .accessibilitySortPriority(2)
                        .transition(.opacity)
                }
                Spacer(minLength: AtticSpacing.s12)
                AtticRaisedButton(systemName: "square.and.pencil", label: "New note", help: String(localized: "New note (⌘N)")) {
                    newNote()
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("notes-new-note")
            }
            .frame(height: buttonHeight)
        }
    }

    private var allNotesHelp: String {
        guard controller.isLibraryPresented else { return String(localized: "All notes (⇧⌘L)") }
        let title = controller.active.map { $0.engine.lineText(at: 0).trimmingCharacters(in: .whitespaces) } ?? ""
        return title.isEmpty ? String(localized: "Back (⇧⌘L)") : String(localized: "Back to \(title) (⇧⌘L)")
    }

    /// Keys whose commands live in the note's menu (the menu shows them;
    /// these make them work while it is closed).
    private var shortcuts: some View {
        ZStack {
            Button("") { chrome.presentMenu() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!showsEditor)
            Button("") { if let id = currentNoteID { controller.duplicateNote(noteID: id) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!showsEditor || !(controller.active?.isPersisted ?? false))
            Button("") { if let id = currentNoteID { controller.copyMarkdown(noteID: id) } }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(!showsEditor)
            Button("") { showLibrary(focusSearch: true) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    // MARK: Navigation

    private func toggleLibrary() {
        if let exitToOldPage {
            exitToOldPage()
            return
        }
        if controller.isLibraryPresented {
            library.clearSearch()
            controller.dismissLibrary()
        } else {
            showLibrary(focusSearch: false)
        }
    }

    private func showLibrary(focusSearch: Bool) {
        if !controller.isLibraryPresented {
            guard controller.showLibrary() else { return }
        }
        if focusSearch { searchFocused = true }
    }

    private func newNote() {
        library.clearSearch()
        guard controller.requestNewNote() else { return }
        // An untouched draft stays; only the caret moves to its title.
        DispatchQueue.main.async { chrome.focusText() }
    }

    private func openFromLibrary(_ id: UUID) {
        if let draft = controller.failedDrafts.first(where: { $0.noteID == id }), noteStore.note(withID: id) == nil {
            controller.openFailedDraft(sessionID: draft.id)
        } else if controller.open(noteID: id) {
            controller.dismissLibrary()
        }
        library.clearSearch()
    }

    private func openLegacy(_ id: UUID?) {
        guard let id, let note = noteStore.note(withID: id) else { return }
        if noteDraft.beginEditing(note) { uiState.beginEditingNote(note) }
    }

    private var currentNoteID: UUID? {
        guard let session = controller.active, controller.legacyNoteID == nil else { return nil }
        return session.noteID
    }

    // MARK: Delete and its Undo

    private func delete(_ id: UUID) {
        let reopen = controller.active?.noteID == id && !controller.isLibraryPresented
        guard controller.deleteNote(noteID: id) else { return }
        guard let toasts else { return }
        let toast = toasts.show(String(localized: "Note deleted")) { [controller] in
            controller.restoreDeletedNote(noteID: id, reopen: reopen)
        }
        postedToastID = toast.id
    }

    private func dismissOwnToast() {
        guard let toasts, let current = toasts.current, current.id == postedToastID else { return }
        toasts.dismiss()
        postedToastID = nil
    }

    // MARK: Menus

    /// The note's menu (⋯, ⇧⌘I, the header title): Insert and Format as far
    /// as this slice supports them, then the note's actions. What is not
    /// built yet is left out, except Version History (dimmed until slice 7).
    private func noteMenuCommands() -> [AtticMenuCommand] {
        guard let session = controller.active, controller.legacyNoteID == nil else { return [] }
        let id = session.noteID
        let engine = session.engine
        let editable = !session.isReadOnly
        var commands: [AtticMenuCommand] = []
        if editable {
            let selection = engine.textView?.selectedRange() ?? NSRange(location: engine.textStorage.length, length: 0)
            // Format acts on the paragraphs at the caret or selection only.
            let current = engine.paragraphFormat(in: selection)
            commands.append(AtticMenuCommand("Insert", identifier: "notes-menu-insert", submenu: [
                AtticMenuCommand("Image…", identifier: "notes-menu-insert-image") { isImporterPresented = true },
                AtticMenuCommand("Today’s Date", startsSection: true) { engine.perform(.date(NoteDay(date: Date()))) },
                AtticMenuCommand("Tomorrow’s Date") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                    engine.perform(.date(NoteDay(date: tomorrow)))
                }
            ]))
            commands.append(AtticMenuCommand("Format", identifier: "notes-menu-format", submenu: [
                AtticMenuCommand("Body", isDisabled: current == nil, isChecked: current == .body) {
                    engine.perform(.paragraph(.body), selection: selection)
                },
                AtticMenuCommand("Checklist", isDisabled: current == nil, isChecked: current == .checklist) {
                    engine.perform(.paragraph(.checklist), selection: selection)
                }
            ]))
        }
        let pinned = noteStore.note(withID: id)?.isPinned ?? false
        commands.append(AtticMenuCommand(pinned ? "Unpin from Top" : "Pin to Top", isDisabled: !session.isPersisted && session.isUntouchedDraft,
                                         startsSection: !commands.isEmpty, identifier: "notes-menu-pin") {
            controller.setPinned(!pinned, noteID: id)
        })
        if editable {
            commands.append(AtticMenuCommand("Tags…", identifier: "notes-menu-tags") { chrome.presentTagEditor() })
        }
        commands.append(AtticMenuCommand("Version History", isDisabled: true) {})
        commands.append(AtticMenuCommand("Copy as Markdown", shortcut: KeyboardShortcut("c", modifiers: [.command, .option, .shift]),
                                         startsSection: true, identifier: "notes-menu-copy-markdown") {
            controller.copyMarkdown(noteID: id)
        })
        if editable {
            commands.append(AtticMenuCommand("Duplicate", shortcut: KeyboardShortcut("d", modifiers: .command),
                                             isDisabled: !session.isPersisted, identifier: "notes-menu-duplicate") {
                controller.duplicateNote(noteID: id)
            })
        }
        commands.append(AtticMenuCommand("Delete Note", isDestructive: true, startsSection: true,
                                         identifier: "notes-menu-delete") { delete(id) })
        return commands
    }

    /// A row's right-click menu in All notes.
    private func rowCommands(_ id: UUID) -> [AtticMenuCommand] {
        let pinned = noteStore.note(withID: id)?.isPinned ?? false
        let stored = noteStore.note(withID: id)
        return [
            AtticMenuCommand("Open") { openFromLibrary(id) },
            AtticMenuCommand(pinned ? "Unpin from Top" : "Pin to Top", isDisabled: stored == nil, startsSection: true) {
                controller.setPinned(!pinned, noteID: id)
            },
            AtticMenuCommand("Copy as Markdown", startsSection: true) { controller.copyMarkdown(noteID: id) },
            AtticMenuCommand("Duplicate", isDisabled: stored?.usesDocumentFormat != true) { controller.duplicateNote(noteID: id) },
            AtticMenuCommand("Delete Note", shortcut: KeyboardShortcut(.delete, modifiers: .command), isDestructive: true,
                             isDisabled: stored == nil, startsSection: true) { delete(id) }
        ]
    }

    // MARK: Tags

    private func tagEditor(for session: NoteSession) -> some View {
        NoteTagEditor(session: session, store: noteStore) {
            chrome.tagEditor = nil
            chrome.focusText()
        }
        .atticDesign(design)
    }
}

/// ⋯ → Tags… (or a click on a tag): the note's tags, ticked, among every
/// tag in Notes with its count. A change is an edit of the note: it is
/// saved with the note's text, through the session.
private struct NoteTagEditor: View {
    @ObservedObject var session: NoteSession
    @ObservedObject var store: NoteStore
    let onClose: () -> Void

    @State private var query = ""
    @State private var revision = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        // The engine's tags are not observable: a change bumps `revision`.
        let _ = revision
        let current = Set(session.engine.tags)
        let counts = tagCounts(current)
        let typed = AtticTag.normalize(query)
        let create: String? = typed.flatMap { counts[$0] == nil ? $0 : nil }
        return AtticNoteTagList(query: $query, tags: rows(counts, current: current, typed: typed), create: create,
                                onToggle: { name in toggle(name, on: !current.contains(name)) },
                                onCreate: { name in
                                    toggle(name, on: true)
                                    query = ""
                                },
                                fieldFocused: $fieldFocused)
            .onAppear { fieldFocused = true }
            .onDisappear { onClose() }
            .onExitCommand { onClose() }
            .accessibilityIdentifier("notes-tag-editor")
    }

    private func tagCounts(_ current: Set<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for note in store.notes {
            for tag in note.tags { counts[tag, default: 0] += 1 }
        }
        for tag in current where counts[tag] == nil { counts[tag] = 1 }
        return counts
    }

    private func rows(_ counts: [String: Int], current: Set<String>, typed: String?) -> [AtticNoteTagList.Tag] {
        var rows: [AtticNoteTagList.Tag] = []
        for (name, count) in counts {
            if let typed, !name.localizedStandardContains(typed) { continue }
            rows.append(AtticNoteTagList.Tag(name: name, count: count, isOn: current.contains(name)))
        }
        rows.sort { lhs, rhs in
            if lhs.isOn != rhs.isOn { return lhs.isOn }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name < rhs.name
        }
        return rows
    }

    private func toggle(_ name: String, on: Bool) {
        var tags = session.engine.tags
        if on { tags.append(name) } else { tags.removeAll { $0 == name } }
        session.engine.setTagsFromPicker(tags)
        revision += 1
    }
}

/// The status slot between the bottom buttons (UX plan § 3.12): the most
/// urgent state in a pill, "+N" when there are more, and every state with
/// its reasons and actions in the details. Nothing shows when all is well.
private struct NoteStatusSlot: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var store: NoteStore
    @ObservedObject var session: NoteSession
    @State private var showingDetails = false
    @State private var showingProposal = false
    @Environment(\.atticDesign) private var design

    var body: some View {
        let items = controller.statusItems(for: session).map(item)
        // A change of state springs in; typing never changes this key.
        let key = items.map(\.id).joined(separator: ",")
        ZStack {
            if let primary = items.first {
                AtticStatusPill(item: primary, more: items.count - 1,
                                inlineAction: items.count == 1 ? inlineAction(for: primary) : nil,
                                onCancel: items.count == 1 ? cancel(for: primary) : nil) {
                    showingDetails = true
                }
                .id(key)
                .transition(design.reduceMotion ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.86)).combined(with: .offset(y: 8)))
            }
        }
        .animation(AtticMotionPreset.popover.springy(reduceMotion: design.reduceMotion), value: key)
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            AtticStatusDetails(items: items)
        }
        .sheet(isPresented: $showingProposal) {
            if let comparison = session.isConflict
                ? controller.conflictComparison(for: session) : controller.proposalComparison(for: session) {
                NoteProposalComparison(title: session.isConflict ? comparison.agent : "\(comparison.agent) has changes",
                                       current: comparison.current,
                                       proposed: comparison.proposed)
            }
        }
    }

    private func inlineAction(for item: AtticStatusItem) -> AtticStatusItem.Action? {
        item.id == "notSaved" ? item.actions.first : nil
    }

    private func cancel(for item: AtticStatusItem) -> (() -> Void)? {
        switch item.id {
        case "importing": controller.cancelActiveImport
        case "notice": { session.notice = nil }
        default: nil
        }
    }

    private func item(_ status: NoteStatusItem) -> AtticStatusItem {
        let details = { (action: @escaping () -> Void) in { showingDetails = false; action() } }
        switch status {
        case .onlyInMemory:
            return AtticStatusItem(id: "onlyInMemory", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .warning, actions: [
                                       .init(title: String(localized: "Retry"), handler: details(controller.retry)),
                                       .init(title: String(localized: "Copy Text"), identifier: "notes-copy-text",
                                             handler: details(controller.copyActiveText))
                                   ])
        case .notSaved:
            return AtticStatusItem(id: "notSaved", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .warning, actions: [
                                       .init(title: String(localized: "Retry"), identifier: "notes-retry",
                                             handler: details(controller.retry)),
                                       .init(title: String(localized: "Copy Text"), identifier: "notes-copy-text",
                                             handler: details(controller.copyActiveText))
                                   ])
        case .changedElsewhere, .deletedElsewhere:
            return AtticStatusItem(id: "conflict", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .warning, actions: [
                                       .init(title: String(localized: "Keep as new note"), identifier: "notes-keep-as-new",
                                             handler: details { _ = controller.keepAsNewNote() }),
                                       .init(title: String(localized: "Review"), identifier: "notes-review-conflict",
                                             handler: details { showingProposal = true })
                                   ])
        case .proposal:
            return AtticStatusItem(id: "proposal", systemName: "sparkle", title: status.label,
                                   explanation: status.explanation, actions: [
                                       .init(title: String(localized: "Review"), identifier: "notes-agent-has-changes",
                                             handler: details { showingProposal = true })
                                   ])
        case .importing:
            return AtticStatusItem(id: "importing", systemName: nil, title: status.label,
                                   explanation: status.explanation, actions: [
                                       .init(title: String(localized: "Cancel Batch"), identifier: "notes-cancel-import",
                                             handler: details(controller.cancelActiveImport))
                                   ])
        case .readOnly:
            return AtticStatusItem(id: "readOnly", systemName: "lock", title: status.label,
                                   explanation: status.explanation, tone: .quiet)
        case .notice:
            return AtticStatusItem(id: "notice", systemName: "info.circle", title: status.label, tone: .normal, actions: [
                .init(title: String(localized: "Dismiss"), identifier: "notes-notice-dismiss",
                      handler: details { session.notice = nil })
            ])
        }
    }
}

/// The proposal stays read-only until the person deliberately resolves it.
/// The transactional replacement controls arrive with the review slice.
private struct NoteProposalComparison: View {
    let title: String
    let current: String
    let proposed: String
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AtticText(verbatim: title, style: .panelHeading, ink: .heading)
            Picker("Version", selection: $selected) {
                Text("Current").tag(0)
                Text("Proposed").tag(1)
            }
            .pickerStyle(.segmented)
            ScrollView {
                AtticText(verbatim: selected == 0 ? current : proposed, style: .body, ink: .heading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Button("Back") { dismiss() }
                .accessibilityIdentifier("notes-proposal-back")
        }
        .padding(20)
        .frame(width: 440, height: 480)
        .accessibilityIdentifier("notes-proposal-comparison")
    }
}
