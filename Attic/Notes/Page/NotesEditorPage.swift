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
    /// Save Recovery Copy… (⇧⌘S, the note's menu and the status details):
    /// offered only while the note's text is held only here.
    static let saveRecoveryCopyIdentifier = "notes-save-recovery-copy"
    static let saveRecoveryCopyShortcut = KeyboardShortcut("s", modifiers: [.command, .shift])

    @ObservedObject var controller: NotesPageController
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout

    @Environment(\.atticDesign) private var design
    @Environment(\.atticPanelToasts) private var toasts
    @StateObject private var chrome = NotesPageChrome()
    @StateObject private var library: NotesLibraryModel
    @StateObject private var damagedRecovery: NoteDamagedRecoveryExit
    @State private var searchFocused = false
    /// The bottom row's control that has the keyboard after ⌃Tab or ⌃⇧Tab
    /// left the text (OD-7), and whether its controls are keyboard stops:
    /// only from then until the keyboard is back in the text, so a click
    /// never leaves a button holding it.
    @FocusState private var bottomFocus: NotesKeyboardOrder.Stop?
    @State private var bottomStops = false
    /// The stop to focus once the controls have become focusable.
    @State private var pendingStop: NotesKeyboardOrder.Stop?
    @State private var keyMonitor: Any?
    @State private var postedToastID: UUID?
    /// Whether this page has shown a note yet. The note that the page
    /// opens on arrives without a slide: the page switch moves the page
    /// (A20; before, the first visit's session start slid it in springily,
    /// so only that visit looked sprung).
    @State private var hasShownNote = false
    /// The history step the delete toast undoes: the toast answers only
    /// while that step is still the next Undo.
    @State private var postedToastStep: UUID?

    init(controller: NotesPageController, noteStore: NoteStore, noteDraft: NoteDraftController,
         uiState: PanelUIState, layout: PanelPageLayout,
         librarySearch: ((String) async throws -> Set<UUID>)? = nil) {
        self.controller = controller
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.uiState = uiState
        self.layout = layout
        let store = noteStore
        _damagedRecovery = StateObject(wrappedValue: NoteDamagedRecoveryExit(perform: { [controller] command in
            await controller.perform(command)
        }))
        _library = StateObject(wrappedValue: NotesLibraryModel(search: librarySearch ?? { query in
            try await store.searchNoteIDs(matching: query)
        }, store: store, controller: controller))
    }

    // MARK: Direction

    /// The note is to the right of All notes: the library comes in from the
    /// left and leaves to the left, the note from the right; the button in
    /// the bottom-left corner shows the stack, then points back at the note.
    static let libraryEdge: Edge = .leading
    static let noteEdge: Edge = .trailing

    /// The springy slide for a new or another note; nil for the note the
    /// page opens on (its session starting, at once or after recovery).
    static func noteSlideAnimation(hasShownNote: Bool, reduceMotion: Bool) -> Animation? {
        hasShownNote ? AtticMotionPreset.slide.springy(reduceMotion: reduceMotion) : nil
    }

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
    /// The bottom row's top, up from the panel's bottom edge.
    private var bottomControls: CGFloat { layout.chromeInsets.bottom + buttonHeight }
    private var noticeClearance: CGFloat {
        max(0, layout.chromeInsets.bottom + buttonHeight + AtticSpacing.s8 - layout.contentInsets.bottom)
    }

    private var pageContent: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsEditor, controller.proposalReview == nil, controller.historyBrowser == nil {
                headerTitle
            }
            if controller.proposalReview == nil, controller.historyBrowser == nil {
                bottomRow
                    .padding(.leading, layout.chromeInsets.leading)
                    .padding(.trailing, layout.chromeInsets.trailing)
                    .padding(.bottom, layout.chromeInsets.bottom)
            }
            if controller.historyBrowser == nil { shortcuts }
        }
        // A deliberate two-finger swipe goes to All notes and back (the
        // panel's swipe router: a pull past its threshold, never momentum;
        // it yields to sideways controls, a drag selection, and refuses
        // while text is being composed, as the button does).
        .background(NotesPageSwipeMonitor(isLibraryPresented: controller.isLibraryPresented) { toggleLibrary() }
            .accessibilityHidden(true))
        // Springy slides between the note and All notes, and for a new or
        // another note (keystrokes are never held back: the text view takes
        // the keyboard at once, and nothing here animates per keystroke).
        .animation(AtticMotionPreset.slide.springy(reduceMotion: design.reduceMotion), value: controller.isLibraryPresented)
        .animation(Self.noteSlideAnimation(hasShownNote: hasShownNote, reduceMotion: design.reduceMotion),
                   value: controller.active?.id)
        .onChange(of: controller.active?.id) { _, id in
            if id != nil { hasShownNote = true }
        }
    }

    var body: some View {
        pageContent
        .onAppear {
            hasShownNote = controller.active != nil
            controller.update(design: design)
            controller.start()
            controller.present()
            chrome.menuCommands = { noteMenuCommands() }
            chrome.leaveEditor = { forward in leaveEditor(forward: forward) }
            #if DEBUG
            chrome.captureToggleLibrary = { toggleLibrary() }
            #endif
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    bottomKeyPressed(event) ? nil : event
                }
            }
            library.failedDraftText = { [controller, noteStore] id in
                guard noteStore.note(withID: id) == nil,
                      let draft = controller.failedDrafts.first(where: { $0.noteID == id }) else { return nil }
                return NoteTextExport.plainText(draft.engine.document())
            }
        }
        .onDisappear {
            chrome.cancelKeyboardReturn()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: bottomFocus) { _, stop in
            // Back in the text (a click, ⌃Tab round): the buttons stop
            // being stops.
            if stop == nil, pendingStop == nil { bottomStops = false }
        }
        .onChange(of: bottomStops) { _, on in
            guard on, let stop = pendingStop else { return }
            DispatchQueue.main.async {
                pendingStop = nil
                bottomFocus = stop
            }
        }
        .onChange(of: design) { _, newValue in controller.update(design: newValue) }
        .task {
            #if DEBUG
            await NoteHistoryCaptureScene.seedIfRequested(controller)
            #endif
        }
        .onChange(of: controller.historyBrowser?.noteID) { _, _ in
            chrome.closeFormatBar()
            chrome.cancelKeyboardReturn()
        }
        .onChange(of: controller.active?.id) { _, opened in
            // Another note: the keyboard return belonged to the last one.
            chrome.cancelKeyboardReturn()
            chrome.tagEditor = nil
            // The format row belongs to the note it was opened on.
            chrome.closeFormatBar()
            // Opening or starting a note ends the delete's Undo toast: ⌘Z
            // belongs to the note's own text again. (Deleting the open note
            // leaves no note on screen, and its toast stays.)
            if opened != nil { dismissOwnToast() }
        }
        .onChange(of: controller.undoRevision) { _, _ in
            // Another action (or an Undo) moved the history on: a toast for
            // a delete that Undo no longer reaches goes away.
            if let step = postedToastStep, controller.libraryUndoStepID != step { dismissOwnToast() }
        }
        .onChange(of: controller.presentationCount) { _, _ in
            // Back on the page (a page switch, the panel shown again): the
            // keyboard returns to the note, where the caret was.
            guard showsEditor else { return }
            DispatchQueue.main.async { chrome.focusText() }
        }
        .onChange(of: controller.isLibraryPresented) { _, shown in
            chrome.cancelKeyboardReturn()
            if shown { chrome.closeFormatBar() }
            bottomFocus = nil
            pendingStop = nil
            bottomStops = false
            if shown {
                // Typing searches (the library's own keys): the search
                // stays quiet on the label line until then.
                library.highlightedID = nil
            } else {
                searchFocused = false
                // Back on a note (the one that was open included): a toast
                // for a delete made in the library does not follow you into
                // the text. The step itself stays in the library's history.
                dismissOwnToast()
            }
        }
        .fileImporter(isPresented: Binding(get: { chrome.fileRequest != nil },
                                           set: { if !$0 { chrome.fileRequest = nil } }),
                      allowedContentTypes: [.item], allowsMultipleSelection: chrome.fileRequest == .insert) { result in
            finishFileRequest(result)
        } onCancellation: {
            finishFileRequest(nil)
        }
        .preference(key: PanelPageNoticeClearancePreferenceKey.self, value: noticeClearance)
        // A group, so its identifier never replaces its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-editor-page")
    }

    private var showsEditor: Bool {
        !controller.isLibraryPresented && controller.proposalReview == nil && controller.active != nil
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let history = controller.historyBrowser {
            NoteHistoryPage(controller: controller, browser: history, layout: layout)
        } else if controller.isLibraryPresented {
            NotesLibraryView(model: library, controller: controller, store: noteStore, layout: layout,
                             bottomClearance: bottomInset, bottomControls: bottomControls, searchFocused: $searchFocused,
                             rowCommands: { id in rowCommands(id) },
                             libraryCommands: { Self.historyCommands(for: controller) },
                             onOpen: { id in openFromLibrary(id) },
                             onDelete: { id in delete(id) },
                             onBack: { toggleLibrary() },
                             onCreate: { title, tag in newNote(title: title, tag: tag) })
                .transition(slide(from: Self.libraryEdge))
        } else if let review = controller.proposalReview {
            NoteProposalComparison(controller: controller, store: noteStore, review: review,
                columnInset: columnInset, topInset: layout.headerBottom + 8, bottomInset: layout.chromeInsets.bottom,
                design: design)
        } else if let session = controller.active {
            NoteEditorRepresentable(session: session, chrome: chrome, columnInset: columnInset,
                                    topInset: topInset, bottomInset: bottomInset, headerBottom: layout.headerBottom,
                                    design: design, tagEditor: { AnyView(tagEditor(for: session)) },
                                    tagCounts: { [noteStore] in
                                        noteStore.tagCounts
                                    })
                .id(ObjectIdentifier(session.engine))
                // The text runs under the header's glass controls and the
                // bottom row at full strength (owner, 2026-10-06: no fade
                // behind glass), dissolving only into the panel's own top and
                // bottom edges. No native soft edge here.
                .atticScrollUnderFade(plainText: [], topEdge: layout.scrollEdgeFadeTop,
                                      bottomEdge: layout.scrollEdgeFadeBottom)
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

    /// The scrolled-away title, back between the pin and the page button; it
    /// slides left and truncates while the page switcher is open (OD-11).
    private var headerTitle: some View {
        let progress = chrome.headerTitleProgress
        return AtticHeaderTitleRoom(chromeInset: layout.chromeInsets.leading, switcherWidth: PanelHeaderLayout.pageSwitchWidth) {
            AtticHeaderTitle(title: chrome.headerTitle) { chrome.presentMenu() }
                .opacity(progress)
                // It settles into the header as the title passes under it
                // (scroll-linked, so no animation runs while typing).
                .offset(y: design.reduceMotion ? 0 : (1 - progress) * -6)
                .scaleEffect(design.reduceMotion ? 1 : 0.94 + 0.06 * progress, anchor: .top)
                .allowsHitTesting(progress > 0.5)
                .accessibilityHidden(progress < 0.5)
                .accessibilityIdentifier("notes-header-title")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, layout.chromeInsets.top)
    }

    // MARK: Bottom row

    /// The bottom row; while Aa's format row is open, the format row in its
    /// place (OD-14; p2-37 draft 1: Aa grows into it as the others make way).
    private var bottomRow: some View {
        AtticControlGroup {
            NoteFormatRowSwitch(state: chrome.formatRow, model: { [weak chrome] in chrome?.controls?.formatModel }) {
                bottomButtons
            }
        }
    }

    /// In Dark the bottom row's glyphs take the strong ink (A39 F13): the
    /// quiet icon grey read as disabled over the dark surface.
    private var darkGlyphs: Bool { design.tokens.context.mode == .dark }

    private var bottomButtons: some View {
        Group {
            HStack(spacing: 0) {
                AtticRaisedButton(systemName: Self.libraryButtonGlyph(libraryShown: controller.isLibraryPresented),
                                  label: controller.isLibraryPresented ? "Back" : "All notes",
                                  help: allNotesHelp, emphasisedGlyph: darkGlyphs) {
                    toggleLibrary()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .noteFormatRowLeaving(.allNotes)
                .modifier(NotesKeyboardStop(stop: .allNotes, enabled: bottomStops, focus: $bottomFocus))
                .accessibilityIdentifier("notes-all-notes")
                .accessibilitySortPriority(1)
                Spacer(minLength: AtticSpacing.s12)
                if !controller.isLibraryPresented, let session = controller.active {
                    NoteStatusSlot(controller: controller, store: noteStore, session: session, damaged: damagedRecovery,
                                   maxWidth: AtticNoteMetrics.pillMaxWidth(
                                       panelWidth: layout.panelSize.width, chromeInset: layout.chromeInsets.leading,
                                       showsFormat: showsEditor && controller.active?.isReadOnly == false))
                        .noteFormatRowLeaving(.status)
                        .accessibilitySortPriority(2)
                        .transition(.opacity)
                }
                Spacer(minLength: AtticSpacing.s12)
                if showsEditor, controller.active?.isReadOnly == false {
                    formatButton
                        .modifier(NotesKeyboardStop(stop: .format, enabled: bottomStops, focus: $bottomFocus))
                        .padding(.trailing, AtticNoteMetrics.formatButtonGap)
                        .transition(.opacity)
                }
                AtticRaisedButton(systemName: "square.and.pencil", label: "New note", help: String(localized: "New note (⌘N)"),
                                  emphasisedGlyph: darkGlyphs) {
                    newNote()
                }
                .keyboardShortcut("n", modifiers: .command)
                .noteFormatRowLeaving(.newNote)
                .modifier(NotesKeyboardStop(stop: .newNote, enabled: bottomStops, focus: $bottomFocus))
                .accessibilityIdentifier("notes-new-note")
            }
            .frame(height: buttonHeight)
        }
    }

    /// Aa (OD-14, p2-36 draft 1): the bottom row turns into the format row
    /// in place, until ✕ or Esc. ⌘T opens it too.
    private var formatButton: some View {
        AtticRaisedButton(systemName: NoteFormatRowSource.symbol, label: "Format", help: String(localized: "Format (⌘T)"),
                          emphasisedGlyph: darkGlyphs) {
            chrome.openFormatBar(keyboard: false)
        }
        .noteFormatRowSource()
        .accessibilityIdentifier("notes-format-button")
    }

    // MARK: Keyboard out of the text (OD-7)

    /// The stops in order: the text, then the bottom row's controls.
    private var keyboardStops: [NotesKeyboardOrder.Stop] {
        NotesKeyboardOrder.stops(format: showsEditor && controller.active?.isReadOnly == false)
    }

    /// ⌃Tab or ⌃⇧Tab with no selection bar: the next or previous control.
    private func leaveEditor(forward: Bool) {
        guard showsEditor, let stop = NotesKeyboardOrder.next(after: .text, in: keyboardStops, forward: forward) else { return }
        move(to: stop)
    }

    private func move(to stop: NotesKeyboardOrder.Stop) {
        if stop == .text {
            bottomFocus = nil
            pendingStop = nil
            bottomStops = false
            chrome.returnKeyboardToText()
            return
        }
        chrome.cancelKeyboardReturn()
        if bottomStops {
            bottomFocus = stop
        } else {
            // The controls become focusable first; the focus lands once
            // they are (`onChange(of: bottomStops)`).
            pendingStop = stop
            bottomStops = true
        }
    }

    /// While a bottom-row control has the keyboard: Tab, ⇧Tab, ⌃Tab and
    /// ⌃⇧Tab go round the stops (back into the text after the last), and
    /// Space or Return presses the control. Read at the key press only.
    private func bottomKeyPressed(_ event: NSEvent) -> Bool {
        guard let stop = bottomFocus, showsEditor, event.window?.isKeyWindow == true else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 48 where !flags.contains(.command) && !flags.contains(.option):
            guard let next = NotesKeyboardOrder.next(after: stop, in: keyboardStops, forward: !flags.contains(.shift)) else { return false }
            move(to: next)
            return true
        case 49, 36, 76:
            guard flags.isEmpty else { return false }
            switch stop {
            case .allNotes: toggleLibrary()
            case .format:
                move(to: .text)
                chrome.openFormatBar(keyboard: true)
            case .newNote: newNote()
            case .text: return false
            }
            return true
        default:
            return false
        }
    }

    private func finishFileRequest(_ result: Result<[URL], Error>?) {
        let request = chrome.takeFileRequest()
        let urls: [URL] = if case let .success(urls)? = result { urls } else { [] }
        switch request {
        case let .slash(ticket):
            if let url = urls.first { controller.importSlashImage(url, for: ticket) } else { ticket.request.cancel() }
        case .insert, nil:
            if !urls.isEmpty { controller.importFiles(urls) }
        case let .retry(id):
            // The chosen file replaces the failed one, checked against the
            // note's limits before it is read and again when it is added.
            if let url = urls.first { Task { _ = await controller.retryFailedFile(id, with: url) } }
        case let .locate(id):
            if let url = urls.first { chrome.objectControls?.locate(id, at: url) }
        }
    }

    private var allNotesHelp: String {
        guard controller.isLibraryPresented else { return String(localized: "All notes (⇧⌘L)") }
        let title = controller.active.map { $0.engine.lineText(at: 0).trimmingCharacters(in: .whitespaces) } ?? ""
        return title.isEmpty ? String(localized: "Back (⇧⌘L)") : String(localized: "Back to \(title) (⇧⌘L)")
    }

    /// Keys whose commands live in the note's menu (the menu shows them;
    /// these make them work while it is closed). They are the OPEN NOTE's
    /// scope and are off while All notes shows: there ⇧⌘I, ⌘D and ⌥⇧⌘C act
    /// on the library's row (`NotesLibraryView` handles them from
    /// `rowCommands`), so the two scopes never both answer one key.
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
            Button("") {
                if let engine = controller.active?.engine { Task { _ = await engine.printNote() } }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!showsEditor)
            Button("") { Task { await controller.saveRecoveryCopy() } }
                .keyboardShortcut(Self.saveRecoveryCopyShortcut)
                .disabled(!showsEditor || !controller.canSaveRecoveryCopy(controller.active))
            Button("") { showLibrary(focusSearch: true) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { chrome.openFormatBar(keyboard: true) }
                .keyboardShortcut(NoteCommandCatalog.formatBarShortcut)
                .disabled(!showsEditor || controller.active?.isReadOnly != false)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    // MARK: Navigation

    private func toggleLibrary() {
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

    /// "New note “kyoto”" (in #launch) from All notes: the note the search
    /// named, its caret at the end of the title.
    private func newNote(title: String, tag: String?) {
        guard controller.requestNewNote(title: title, tags: tag.map { [$0] } ?? []) else { return }
        library.clearSearch()
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

    private var currentNoteID: UUID? {
        guard let session = controller.active else { return nil }
        return session.noteID
    }

    // MARK: Delete and its Undo

    private func delete(_ id: UUID) {
        Task { @MainActor in
            guard await controller.deleteNoteDurably(noteID: id) else { return }
            guard let toasts, let step = controller.libraryUndoStepID else { return }
            // The toast is one way to Undo; the library's history is the other
            // (⌘Z, the menus), and it outlives the toast.
            // Its button answers the pointer and VoiceOver, never ⌘Z: the key
            // follows the focused text, then the library (NotesLibraryView).
            // Outcome-aware (control audit 16): the toast stays until the
            // restore is known; a failure says why and offers Retry while
            // retrying can help. Focus and VoiceOver hold it (the shared
            // AtticUndoToast), and it never claims ⌘Z (B2).
            let toast = toasts.show(String(localized: "Note deleted"), answersUndoKey: false,
                                    performingAsync: { [controller, noteStore] in
                await Self.undoDelete(noteID: id, step: step, controller: controller, store: noteStore)
            })
            postedToastID = toast.id
            postedToastStep = step
        }
    }

    /// The delete toast's Undo: the library's own step, and only while it
    /// is still the next Undo. A step already taken (⌘Z, the menu) is done;
    /// one that can never apply says so without Retry; anything else
    /// (a store refusal, a recovery write still going) can be retried.
    static func undoDelete(noteID: UUID, step: UUID, controller: NotesPageController,
                           store: NoteStore) async -> CommandOutcome {
        if await controller.undoLibraryDurably(expectedStepID: step) { return .applied }
        if controller.libraryUndoStepID != step {
            if store.note(withID: noteID) != nil { return .applied }
            return .failed(CommandFailure(String(localized: "This note can no longer be restored here. It is in Recently Deleted."),
                                          canRetry: false))
        }
        return .failed(CommandFailure(String(localized: "The note could not be restored.")))
    }

    private func dismissOwnToast() {
        guard let toasts, let current = toasts.current, current.id == postedToastID else { return }
        toasts.dismiss()
        postedToastID = nil
        postedToastStep = nil
    }

    // MARK: Menus

    /// The note's menu (⋯, ⇧⌘I, the header title): Insert and Format as far
    /// as this slice supports them, then the note's actions. What is not
    /// built yet is left out.
    private func noteMenuCommands() -> [AtticMenuCommand] {
        guard let session = controller.active else { return [] }
        let id = session.noteID
        let engine = session.engine
        let editable = !session.isReadOnly
        var commands: [AtticMenuCommand] = []
        // A selected image or file: its own commands first (Image ▸ or
        // File ▸), the same list as its right-click menu.
        if let objects = chrome.objectControls,
           let submenu = NoteObjectMenu.selectedObjectSubmenu(engine: engine,
                run: { [weak objects] id, command in objects?.run(command, objectID: id) },
                chooseApplication: { [weak objects] id in objects?.chooseApplication(for: id) }) {
            commands.append(submenu)
        }
        if editable {
            // Insert ▸ and Format ▸: the same command list as the selection
            // bar, Aa, the right-click menu and the menu bar.
            let router = chrome.controls?.router ?? NoteCommandRouter(engine: engine)
            commands += router.menuCommands(from: .noteMenu)
        }
        let pinned = noteStore.note(withID: id)?.isPinned ?? false
        commands.append(AtticMenuCommand(pinned ? "Unpin from Top" : "Pin to Top", isDisabled: !session.isPersisted && session.isUntouchedDraft,
                                         startsSection: !commands.isEmpty, identifier: "notes-menu-pin") {
            controller.setPinned(!pinned, noteID: id)
        })
        if editable {
            commands.append(AtticMenuCommand("Tags…", identifier: "notes-menu-tags") { chrome.presentTagEditor() })
        }
        commands.append(AtticMenuCommand("Version History", isDisabled: !session.isPersisted || !editable,
                                         identifier: "notes-menu-history") {
            Task { @MainActor in _ = await controller.openHistoryDurably() }
        })
        commands.append(AtticMenuCommand("Copy as Markdown", shortcut: KeyboardShortcut("c", modifiers: [.command, .option, .shift]),
                                         startsSection: true, identifier: "notes-menu-copy-markdown") {
            controller.copyMarkdown(noteID: id)
        })
        commands.append(AtticMenuCommand("Print…", shortcut: KeyboardShortcut("p", modifiers: .command),
                                         identifier: "notes-menu-print") {
            Task { _ = await engine.printNote() }
        })
        if editable {
            commands.append(AtticMenuCommand("Duplicate", shortcut: KeyboardShortcut("d", modifiers: .command),
                                             isDisabled: !session.isPersisted, identifier: "notes-menu-duplicate") {
                controller.duplicateNote(noteID: id)
            })
        }
        if controller.canSaveRecoveryCopy(session) {
            commands.append(AtticMenuCommand("Save Recovery Copy…", shortcut: Self.saveRecoveryCopyShortcut,
                                             startsSection: true, identifier: Self.saveRecoveryCopyIdentifier) {
                Task { await controller.saveRecoveryCopy(of: session) }
            })
        }
        commands.append(AtticMenuCommand("Delete Note", isDestructive: true, startsSection: true,
                                         identifier: "notes-menu-delete") { delete(id) })
        return commands
    }

    /// The library's command list: a row's right-click menu, its ⋯, ⇧⌘I
    /// and VoiceOver's named actions, and the source of the library's keys
    /// (⌘D, ⌥⇧⌘C, ⌘⌫ find their command here by identifier). ONE list per
    /// scope: this is the library row's; `noteMenuCommands` is the open
    /// note's. A command that cannot run is dimmed here, and its key does
    /// nothing.
    private func rowCommands(_ id: UUID) -> [AtticMenuCommand] {
        let stored = noteStore.note(withID: id)
        let pinned = stored?.isPinned ?? false
        return [
            AtticMenuCommand("Open", identifier: "notes-row-open") { openFromLibrary(id) },
            AtticMenuCommand(pinned ? "Unpin from Top" : "Pin to Top", isDisabled: stored == nil, startsSection: true,
                             identifier: "notes-row-pin") {
                controller.setPinned(!pinned, noteID: id)
            },
            NotesLibraryView.tagsSubmenu(tags: stored?.tags ?? [], activeTag: library.tagFilter) { [library] tag in
                library.tagFilter = tag
            },
            AtticMenuCommand("Copy as Markdown", shortcut: KeyboardShortcut("c", modifiers: [.command, .option, .shift]),
                             startsSection: true, identifier: NotesLibraryView.copyMarkdownIdentifier) {
                controller.copyMarkdown(noteID: id)
            },
            AtticMenuCommand("Duplicate", shortcut: KeyboardShortcut("d", modifiers: .command),
                             isDisabled: stored?.usesDocumentFormat != true,
                             identifier: NotesLibraryView.duplicateIdentifier) {
                controller.duplicateNote(noteID: id)
            },
            AtticMenuCommand("Delete Note", shortcut: KeyboardShortcut(.delete, modifiers: .command), isDestructive: true,
                             isDisabled: stored == nil, startsSection: true, identifier: "notes-row-delete") { delete(id) }
        ] + Self.historyCommands(for: controller)
    }

    /// The library's history (pin, duplicate, delete) as commands, named for
    /// the step each would reverse and dimmed when there is none. They are
    /// the tail of every row's menu and, on their own, the menu of the
    /// library's background: with no rows (the last note just deleted) there
    /// is no row menu, and Undo is still reachable here.
    static func historyCommands(for controller: NotesPageController) -> [AtticMenuCommand] {
        [
            AtticMenuCommand("\(historyTitle(String(localized: "Undo"), step: controller.libraryUndoName))",
                             shortcut: KeyboardShortcut("z", modifiers: .command),
                             isDisabled: !controller.canUndoLibrary, startsSection: true,
                             identifier: NotesLibraryView.undoIdentifier) { Task { @MainActor in _ = await controller.undoLibraryDurably() } },
            AtticMenuCommand("\(historyTitle(String(localized: "Redo"), step: controller.libraryRedoName))",
                             shortcut: KeyboardShortcut("z", modifiers: [.command, .shift]),
                             isDisabled: !controller.canRedoLibrary,
                             identifier: NotesLibraryView.redoIdentifier) { Task { @MainActor in _ = await controller.redoLibraryDurably() } }
        ]
    }

    /// "Undo Delete Note", or just "Undo" with nothing to reverse.
    private static func historyTitle(_ verb: String, step: String?) -> String {
        step.map { "\(verb) \($0)" } ?? verb
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
/// tag in Notes with its count, in the shared E1 tag picker (the Tasks
/// tag picker's card, highlight and keys; CU P2-03). A change is an edit of
/// the note: it is saved with the note's text, through the session.
struct NoteTagEditor: View {
    @ObservedObject var session: NoteSession
    @ObservedObject var store: NoteStore
    let onClose: () -> Void

    @State private var revision = 0

    var body: some View {
        // The engine's tags are not observable: a change bumps `revision`.
        let _ = revision
        let current = Set(session.engine.tags)
        let counts = tagCounts(current)
        AtticTagPickerCard(rows: { query in
            let typed = AtticTag.normalize(query)
            let create: String? = typed.flatMap { counts[$0] == nil ? $0 : nil }
            return (rows(counts, current: current, typed: typed), create)
        }, listRows: counts.count, onToggle: { name in
            toggle(name, on: !Set(session.engine.tags).contains(name))
        }, onCreate: { name, _ in
            toggle(name, on: true)
            return true
        })
        .onDisappear { onClose() }
        .accessibilityIdentifier("notes-tag-editor")
    }

    private func tagCounts(_ current: Set<String>) -> [String: Int] {
        // The attached library supplies the same inventory as Tasks and
        // both title/composer suggestions; keep unsaved engine tags too.
        var counts = store.tagCounts
        for tag in current where counts[tag] == nil { counts[tag] = 1 }
        return counts
    }

    private func rows(_ counts: [String: Int], current: Set<String>, typed: String?) -> [AtticTagPicker.Tag] {
        var rows: [(name: String, count: Int, isOn: Bool)] = []
        for (name, count) in counts {
            if let typed, !name.localizedStandardContains(typed) { continue }
            rows.append((name, count, current.contains(name)))
        }
        rows.sort { lhs, rhs in
            if lhs.isOn != rhs.isOn { return lhs.isOn }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name < rhs.name
        }
        return rows.map { AtticTagPicker.Tag(name: $0.name, state: $0.isOn ? .on : .off, detail: "\($0.count)") }
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
    @ObservedObject var damaged: NoteDamagedRecoveryExit
    /// The room between the bottom row's buttons.
    let maxWidth: CGFloat
    @State private var showingDetails = false
    @State private var showingProposal = false
    @Environment(\.atticDesign) private var design

    /// Every state, most urgent first: the controller's, with a damaged
    /// recovery's exit after the save states (it needs a decision) and
    /// its sentence taken out of the page's notice.
    private var items: [AtticStatusItem] {
        var list = controller.statusItems(for: session).compactMap(item)
        let exits = damaged.entries.map(damagedItem)
        let firstQuieter = list.firstIndex { !["onlyInMemory", "notSaved", "conflict"].contains($0.id) } ?? list.count
        list.insert(contentsOf: exits, at: firstQuieter)
        return list
    }

    var body: some View {
        let items = items
        // A change of state springs in; typing never changes this key.
        let key = items.map(\.id).joined(separator: ",")
        ZStack {
            if let primary = items.first {
                AtticStatusPill(item: primary, more: items.count - 1,
                                inlineAction: items.count == 1 ? inlineAction(for: primary) : nil,
                                onCancel: items.count == 1 ? cancel(for: primary) : nil, maxWidth: maxWidth) {
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
        // Damaged recovery is looked for only when the controller reports a
        // recovery problem (at launch, after a resolution): never polled,
        // and no journal read while all is well.
        .task(id: controller.recoveryWarnings) {
            guard !controller.recoveryWarnings.isEmpty || !damaged.entries.isEmpty else { return }
            await damaged.refresh()
        }
        .sheet(isPresented: $showingProposal) {
            if let comparison = session.isConflict
                ? controller.conflictComparison(for: session) : controller.proposalComparison(for: session) {
                NoteConflictComparison(title: session.isConflict ? comparison.agent : "\(comparison.agent) has changes",
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
        case "editedBy": { _ = store.acknowledgeExternalEdit(noteID: session.noteID) }
        default: nil
        }
    }

    /// Recovery data is damaged (fix round 4): Save Recovery Copy, then
    /// Discard Damaged Recovery…, which asks first and passes the token the
    /// details gave. An entry with unreadable items offers no Discard.
    private func damagedItem(_ details: NoteDamagedRecoveryDetails) -> AtticStatusItem {
        let close = { (action: @escaping () async -> Void) in { showingDetails = false; Task { await action() } } }
        var actions: [AtticStatusItem.Action] = [
            .init(title: String(localized: "Save Recovery Copy…"), identifier: "notes-damaged-save",
                  handler: close {
                      switch await damaged.saveCopy(details) {
                      case let .saved(url): session.notice = String(localized: "Recovery copy saved as “\(url.lastPathComponent)”.")
                      case let .refused(message): session.notice = message
                      default: break
                      }
                  })
        ]
        if details.confirmation.canDiscard {
            actions.append(.init(title: String(localized: "Discard Damaged Recovery…"), identifier: "notes-damaged-discard",
                                 handler: close {
                                     if case let .refused(message) = await damaged.discard(details) { session.notice = message }
                                 }))
        }
        return AtticStatusItem(id: "damaged-\(details.confirmation.checkpointFilename)", systemName: "exclamationmark.circle",
                               title: details.title, explanation: details.explanation, tone: .warning, actions: actions)
    }

    /// The same command as ⇧⌘S and the note's menu: one identifier, one
    /// controller method.
    private func saveRecoveryCopyAction(_ details: (@escaping () -> Void) -> () -> Void) -> AtticStatusItem.Action {
        .init(title: String(localized: "Save Recovery Copy…"), identifier: NotesEditorPage.saveRecoveryCopyIdentifier,
              handler: details { Task { await controller.saveRecoveryCopy(of: session) } })
    }

    private func item(_ status: NoteStatusItem) -> AtticStatusItem? {
        let details = { (action: @escaping () -> Void) in { showingDetails = false; action() } }
        switch status {
        case .onlyInMemory:
            return AtticStatusItem(id: "onlyInMemory", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .warning, actions: [
                                       .init(title: String(localized: "Retry"), handler: details(controller.retry)),
                                       .init(title: String(localized: "Copy Text"), identifier: "notes-copy-text",
                                             handler: details(controller.copyActiveText)),
                                       saveRecoveryCopyAction(details)
                                   ])
        case .notSaved:
            return AtticStatusItem(id: "notSaved", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .warning, actions: [
                                       .init(title: String(localized: "Retry"), identifier: "notes-retry",
                                             handler: details(controller.retry)),
                                       .init(title: String(localized: "Copy Text"), identifier: "notes-copy-text",
                                             handler: details(controller.copyActiveText)),
                                       saveRecoveryCopyAction(details)
                                   ])
        case .changedElsewhere, .deletedElsewhere:
            return AtticStatusItem(id: "conflict", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .warning, actions: [
                                       .init(title: String(localized: "Keep as new note"), identifier: "notes-keep-as-new",
                                             handler: details { Task { @MainActor in _ = await controller.keepAsNewNoteDurably() } }),
                                       .init(title: String(localized: "Review"), identifier: "notes-review-conflict",
                                             handler: details { showingProposal = true })
                                   ])
        case .deletionProposal:
            let displayedID = controller.proposalID(for: session, deletion: true)
            return AtticStatusItem(id: "deletionProposal", systemName: "exclamationmark.circle", title: status.label,
                explanation: status.explanation, tone: .warning, actions: [
                    .init(title: "Restore", identifier: "notes-restore-deletion", handler: details {
                        guard let id = displayedID else { return }
                        if !store.discardProposal(id, noteID: session.noteID) {
                            session.notice = store.lastErrorMessage ?? "The deletion proposal could not be restored."
                        }
                    }),
                    .init(title: "Save as New Note", identifier: "notes-deletion-save-new", handler: details {
                        guard let id = displayedID else { return }
                        Task {
                            if await controller.beginProposalReview(id: id) {
                                _ = await controller.saveReviewedProposalAsNew()
                            }
                        }
                    }),
                    .init(title: "Review", identifier: "notes-review-deletion", handler: details {
                        guard let id = displayedID else { return }
                        Task { _ = await controller.beginProposalReview(id: id) }
                    })
                ])
        case .editedBy:
            return AtticStatusItem(id: "editedBy", systemName: "info.circle", title: status.label,
                explanation: status.explanation, tone: .quiet, actions: [
                    .init(title: "Dismiss", identifier: "notes-attribution-dismiss", handler: details {
                        if !store.acknowledgeExternalEdit(noteID: session.noteID) {
                            session.notice = store.lastErrorMessage ?? "Attribution could not be acknowledged."
                        }
                    })
                ])
        case .proposal:
            let displayedID = controller.proposalID(for: session, deletion: false)
            return AtticStatusItem(id: "proposal", systemName: "sparkle", title: status.label,
                                   explanation: status.explanation, actions: [
                                       .init(title: String(localized: "Review"), identifier: "notes-agent-has-changes",
                                             handler: details {
                                                 guard let id = displayedID else { return }
                                                 Task { _ = await controller.beginProposalReview(id: id) }
                                             })
                                   ])
        case .importing:
            let progress = session.importProgress
            return AtticStatusItem(id: "importing", systemName: nil, title: NoteStatusPresentation.importLabel(progress),
                                   explanation: NoteStatusPresentation.importExplanation(progress), actions: [
                                       .init(title: String(localized: "Cancel Batch"), identifier: "notes-cancel-import",
                                             handler: details(controller.cancelActiveImport))
                                   ])
        case .readOnly:
            return AtticStatusItem(id: "readOnly", systemName: "lock", title: status.label,
                                   explanation: status.explanation, tone: .quiet)
        case let .notice(message):
            // Damaged recovery has its own items; its sentence leaves the notice.
            guard let message = NoteStatusPresentation.notice(message,
                    removingDamaged: damaged.entries.map(\.confirmation.checkpointFilename)) else { return nil }
            if NoteStatusPresentation.isProgress(message) {
                // Pending guidance: progress, quietly, clearing itself.
                return AtticStatusItem(id: "pending", systemName: nil, title: message, tone: .quiet)
            }
            var actions: [AtticStatusItem.Action] = []
            if message == NoteTablePasteOffer.notice, session.engine.tablePasteOffer != nil {
                // A tabular paste became a table: one click gives its text instead.
                actions.append(.init(title: String(localized: "Paste as Text"), identifier: "notes-paste-as-text",
                                     handler: details {
                                         session.notice = nil
                                         session.engine.pasteLastTableAsText()
                                     }))
            }
            actions.append(.init(title: String(localized: "Dismiss"), identifier: "notes-notice-dismiss",
                                 handler: details { session.notice = nil }))
            return AtticStatusItem(id: "notice", systemName: "info.circle", title: message, tone: .normal, actions: actions)
        }
    }
}

/// The proposal stays read-only until the person deliberately resolves it.
/// The transactional replacement controls arrive with the review slice.
private struct NoteConflictComparison: View {
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

/// Panel-sized review uses the shipping read-only engine, including tables and Mono.
private struct NoteProposalComparison: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var store: NoteStore
    let review: NoteProposalReview
    let columnInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let design: AtticDesignContext
    @State private var proposed = false
    @State private var scrollOffset: CGFloat = 0
    @State private var busy = false

    private var document: NoteDocument {
        guard proposed else { return review.current }
        if review.isDeletion { return NoteDocument(blocks: [.text("Proposed deletion"), .text("This note would move to Recently Deleted.")]) }
        return review.proposedPreview
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Version", selection: $proposed) {
                    Text("Current").tag(false)
                    Text("Proposed").tag(true)
                }.pickerStyle(.segmented)
                AtticText(verbatim: "\(review.agent) · \(review.createdAt.formatted(date: .omitted, time: .shortened)) · \(review.summary)",
                          style: .helper, ink: .helper)
                if controller.reviewProposals.count > 1 {
                    Menu("\(controller.reviewProposals.count) proposals") {
                        ForEach(controller.reviewProposals, id: \.id) { edit in
                            Button("\(edit.agentName.isEmpty ? "Agent" : edit.agentName) · \(edit.createdAt.formatted(date: .omitted, time: .shortened))\(edit.isDeletion ? " · Delete" : "")") {
                                Task { _ = await controller.beginProposalReview(id: edit.id) }
                            }
                        }
                    }.accessibilityIdentifier("notes-proposal-picker")
                }
            }.padding(.horizontal, columnInset)
            NoteComparisonPreview(document: document, noteID: review.noteID, design: design,
                                  imageProvider: controller, columnInset: columnInset, scrollOffset: $scrollOffset)
                .accessibilityIdentifier("notes-proposal-document")
            if let message = controller.proposalReviewNotice {
                AtticText(verbatim: message, style: .helper, ink: .helper)
                    .padding(.horizontal, columnInset)
                    .accessibilityIdentifier("notes-proposal-failure")
            }
            VStack(spacing: 8) {
                if review.isDeletion {
                    Button("Restore") { _ = controller.discardReviewedProposal() }
                        .accessibilityIdentifier("notes-proposal-restore")
                } else {
                    Button("Replace with proposal") { run { await controller.acceptProposal() } }
                        .accessibilityIdentifier("notes-proposal-replace")
                }
                HStack {
                    Button("Back") { controller.endProposalReview() }
                        .accessibilityIdentifier("notes-proposal-back")
                    Spacer(minLength: 4)
                    Menu {
                        Button(review.isDeletion ? "Save as New Note" : "Save Proposal as New Note") {
                            run { await controller.saveReviewedProposalAsNew() }
                        }.accessibilityIdentifier("notes-proposal-save-new")
                        Button("Discard Proposal") { _ = controller.discardReviewedProposal() }
                            .accessibilityIdentifier("notes-proposal-discard")
                        if review.isDeletion {
                            Button("Delete Note", role: .destructive) { run { await controller.acceptProposal() } }
                                .accessibilityIdentifier("notes-proposal-delete")
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Proposal actions")
                    .accessibilityIdentifier("notes-proposal-menu")
                }
            }.padding(.horizontal, columnInset).disabled(busy)
        }
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .font(.system(size: 12.5))
        .accessibilityIdentifier("notes-proposal-comparison")
    }

    private func run(_ action: @escaping @MainActor () async -> Bool) {
        busy = true
        Task { _ = await action(); busy = false }
    }
}

private struct NoteComparisonPreview: NSViewRepresentable {
    let document: NoteDocument
    let noteID: UUID
    let design: AtticDesignContext
    let imageProvider: NoteImageProviding
    let columnInset: CGFloat
    @Binding var scrollOffset: CGFloat

    final class Coordinator {
        var engine: NoteEditorEngine?
        var document: NoteDocument?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        install(in: host, coordinator: context.coordinator, offset: scrollOffset)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        guard context.coordinator.document != document else { return }
        let offset = (host.subviews.first as? NSScrollView)?.contentView.bounds.origin.y ?? scrollOffset
        install(in: host, coordinator: context.coordinator, offset: offset)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 300))
    }
    private func install(in host: NSView, coordinator: Coordinator, offset: CGFloat) {
        coordinator.engine?.detachView()
        host.subviews.forEach { $0.removeFromSuperview() }
        let engine = NoteEditorEngine(noteID: noteID, document: document, readOnly: true,
                                      design: design, imageProvider: imageProvider)
        coordinator.engine = engine
        coordinator.document = document
        let (scroll, text) = engine.makeView()
        text.textContainerInset = NSSize(width: columnInset, height: 0)
        scroll.frame = host.bounds
        scroll.autoresizingMask = [.width, .height]
        host.addSubview(scroll)
        DispatchQueue.main.async {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, offset)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) { coordinator.engine?.detachView() }
}

// MARK: - Keyboard order (OD-7)

/// The note page's keyboard order once ⌃Tab leaves the text (OD-7): the
/// text, then the bottom row left to right (All notes, Aa while the note
/// can be formatted, New note), and round again into the text. Every stop
/// is drawn: the text's caret, or the control's ring.
enum NotesKeyboardOrder {
    enum Stop: Hashable { case text, allNotes, format, newNote }

    static func stops(format: Bool) -> [Stop] {
        format ? [.text, .allNotes, .format, .newNote] : [.text, .allNotes, .newNote]
    }

    static func next(after current: Stop, in stops: [Stop], forward: Bool) -> Stop? {
        guard let index = stops.firstIndex(of: current) else { return stops.first }
        return stops[(index + (forward ? 1 : stops.count - 1)) % stops.count]
    }
}

/// A bottom-row control as a keyboard stop while the keyboard is out of
/// the text: focusable then (whatever the Mac's keyboard navigation
/// setting), and drawn with its ring by its own style.
private struct NotesKeyboardStop: ViewModifier {
    let stop: NotesKeyboardOrder.Stop
    let enabled: Bool
    var focus: FocusState<NotesKeyboardOrder.Stop?>.Binding

    func body(content: Content) -> some View {
        content
            .focusable(enabled)
            .focused(focus, equals: stop)
    }
}

/// Registers the Notes page with the panel's trackpad-swipe router (the
/// router decides direction and threshold; this only says whether All notes
/// shows and what a finished swipe does).
struct NotesPageSwipeMonitor: NSViewRepresentable {
    let isLibraryPresented: Bool
    let onSwipe: () -> Void

    func makeNSView(context: Context) -> NotesPageSwipeView {
        NotesPageSwipeView(isLibraryPresented: isLibraryPresented, onSwipe: onSwipe)
    }

    func updateNSView(_ view: NotesPageSwipeView, context: Context) {
        view.onSwipe = onSwipe
        view.isNotesLibraryPresented = isLibraryPresented
    }
}

final class NotesPageSwipeView: NSView, PanelNotesSwipeTarget {
    var onSwipe: () -> Void
    var isNotesLibraryPresented: Bool
    var swipeView: NSView { self }
    private weak var registeredPanel: AtticPanel?

    init(isLibraryPresented: Bool, onSwipe: @escaping () -> Void) {
        isNotesLibraryPresented = isLibraryPresented
        self.onSwipe = onSwipe
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Clicks go through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The page this one covered (another editor inside the Notes page):
    /// it gets the slot back when this one leaves (review S4-R5).
    private weak var coveredTarget: (any PanelNotesSwipeTarget)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let registeredPanel, registeredPanel.notesSwipeTarget === self {
            registeredPanel.notesSwipeTarget = coveredTarget.flatMap { $0.swipeView.window === registeredPanel ? $0 : nil }
        }
        coveredTarget = nil
        registeredPanel = window as? AtticPanel
        if let panel = registeredPanel, panel.notesSwipeTarget !== self {
            coveredTarget = panel.notesSwipeTarget
            panel.notesSwipeTarget = self
        }
    }

    func performNotesSwipe() { onSwipe() }
}
