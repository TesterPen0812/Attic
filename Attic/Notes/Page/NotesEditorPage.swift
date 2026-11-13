import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The Phase 2 Notes page (slice 2, "Everyday capture and return"; mockups
/// p2-01, p2-04, p2-05, p2-09, p2-12, p2-15, p2-02).
///
/// Only the text, the tag line, the panel's shared top row (search beside
/// the page switch) and the bottom bar: on a note, Back on the left, Aa on
/// the right and the status slot between them; in All notes, the tag bar
/// and compose (Notes Page v2, 2026-10-27/28). The note's rarer actions sit behind the ⋯ at the end
/// of the title's first line, which returns as a glass title in the header
/// once the title has scrolled away. Everything goes through the page's
/// controller and its session rules.
struct NotesEditorPage: View {
    #if DEBUG
    /// Lifetime regression probes; never owns either observed object.
    static var lifetimeProbe: ((NotesPageChrome, NotesLibraryModel) -> Void)?
    #endif
    /// Save Recovery Copy… (⇧⌘S, the note's menu and the status details):
    /// offered only while the note's text is held only here.
    static let saveRecoveryCopyIdentifier = "notes-save-recovery-copy"
    static let saveRecoveryCopyShortcut = KeyboardShortcut("s", modifiers: [.command, .shift])

    @ObservedObject var controller: NotesPageController
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    private let taskStore: TaskStore?

    @Environment(\.atticDesign) private var design
    @Environment(\.atticPanelPageIsCurrent) private var isCurrent
    @Environment(\.atticTagColouring) private var tagColouring
    @Environment(\.atticPanelToasts) private var toasts
    /// In the panel the shell draws the library's switch, tag bar and "+"
    /// once for every page (owner, 2026-10-31); here they are a stand-in.
    @Environment(\.panelSharedChrome) private var sharedChrome
    @Environment(\.panelComposer) private var panelComposer
    @StateObject private var chrome = NotesPageChrome()
    @StateObject private var library: NotesLibraryModel
    @StateObject private var damagedRecovery: NoteDamagedRecoveryExit
    @State private var searchFocused = false
    /// The top row's search is open (its button, ⌘F, typing in All notes):
    /// the field shows first, then takes the keyboard.
    @State private var searchOpen = false
    /// The open note's Find is shown, in the top row (N4, Idea B).
    @State private var findOpen = false
    /// The bottom row's control that has the keyboard after ⌃Tab or ⌃⇧Tab
    /// left the text (OD-7), and whether its controls are keyboard stops:
    /// only from then until the keyboard is back in the text, so a click
    /// never leaves a button holding it.
    @FocusState private var bottomFocus: NotesKeyboardOrder.Stop?
    @State private var bottomStops = false
    /// The stop to focus once the controls have become focusable.
    @State private var pendingStop: NotesKeyboardOrder.Stop?
    @State private var commandOwner = UUID()
    @State private var filePickerOwner: UUID?
    @State private var postedToastID: UUID?
    /// Whether this page has shown a note yet. The note that the page
    /// opens on arrives without a slide: the page switch moves the page
    /// (A20; before, the first visit's session start slid it in springily,
    /// so only that visit looked sprung).
    @State private var hasShownNote = false
    /// A note opened from All notes grows from its card or row and shrinks
    /// back into it (Accepted 2026-11-13); other notes keep the slide.
    @State private var noteGrow = AtticGrowState()
    @State private var noteGrowNoteID: UUID?
    @State private var noteGrowStartedAt: CFTimeInterval = 0
    /// The history step the delete toast undoes: the toast answers only
    /// while that step is still the next Undo.
    @State private var postedToastStep: UUID?

    init(controller: NotesPageController, noteStore: NoteStore, noteDraft: NoteDraftController,
         uiState: PanelUIState, layout: PanelPageLayout, taskStore: TaskStore? = nil,
         librarySearch: ((String) async throws -> Set<UUID>)? = nil) {
        self.controller = controller
        self.noteStore = noteStore
        self.noteDraft = noteDraft
        self.uiState = uiState
        self.layout = layout
        self.taskStore = taskStore
        let store = noteStore
        _damagedRecovery = StateObject(wrappedValue: NoteDamagedRecoveryExit(perform: { [controller] command in
            await controller.perform(command)
        }))
        _library = StateObject(wrappedValue: NotesLibraryModel(search: librarySearch ?? { query in
            try await store.searchNoteIDs(matching: query)
        }, store: store, controller: controller, taskStore: taskStore))
    }

    // MARK: Direction

    /// The note is to the right of All notes: the library comes in from the
    /// left and leaves to the left, the note from the right; the button in
    /// the bottom-left corner shows the stack, then points back at the note.
    static let libraryEdge: Edge = .leading
    static let noteEdge: Edge = .trailing

    /// The slide (L/S, the app's navigation; Notes' slower spring is gone,
    /// A4 M-02) for a new or another note; nil for the note the page opens
    /// on (its session starting, at once or after recovery).
    static func noteSlideAnimation(hasShownNote: Bool, reduceMotion: Bool) -> Animation? {
        hasShownNote ? AtticMotionPreset.slide.animation(reduceMotion: reduceMotion) : nil
    }

    // MARK: Geometry

    /// The bottom bar's controls: the Tasks footer's 30.5 pt squircles.
    private var buttonHeight: CGFloat { NotesBarMetrics.control }
    /// The note's column: 4 inside the chrome's line (28 in a 320 pt panel).
    private var columnInset: CGFloat { layout.chromeInsets.leading + AtticNoteMetrics.columnInset }
    /// The title's first line 16 under the header.
    private var topInset: CGFloat { layout.headerBottom + AtticNoteMetrics.titleTopGap }
    /// The last line rests 12 above the bottom row.
    private var bottomInset: CGFloat { AtticSpacing.s12 }
    /// The bottom row's top, up from the panel's bottom edge.
    private var bottomControls: CGFloat { layout.chromeInsets.bottom + buttonHeight }
    /// The note's floating edges: the header above, the bottom row below.
    private var editorEdges: AtticFloatingEdges { AtticFloatingEdges(top: layout.headerBottom, bottom: bottomControls) }


    private var noticeClearance: CGFloat {
        max(0, layout.chromeInsets.bottom + buttonHeight + AtticSpacing.s8 - layout.contentInsets.bottom)
    }

    private var pageContent: some View {
        ZStack(alignment: .bottom) {
            PanelComposerClearance { extra in
                content(extraBottom: extra)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The card or row growing into the note, under the bars.
            AtticGrowLayer(state: noteGrow, onFinish: { $noteGrow.finish($0) })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // The note's variable blur behind the header (none behind the
            // bottom row, owner 2026-10-22), its own layer between the note and the controls (All notes and
            // history draw theirs under their own controls).
            if showsEditor || reviewsInPlace, controller.historyBrowser == nil { AtticEdgeBlurBackdrops(editorEdges) }
            if showsEditor, controller.proposalReview == nil, controller.historyBrowser == nil {
                // Find folds the title away with Pin and ••• (N4).
                headerTitle
                    .opacity(topFindShown ? 0 : 1)
                    .allowsHitTesting(!topFindShown)
                    .accessibilityHidden(topFindShown)
                    .animation(PanelTopRowLayout.searchAnimation(shown: topFindShown, reduceMotion: design.reduceMotion),
                               value: topFindShown)
            }
            if showsEditor, let find = controller.active?.engine.find {
                NoteFindTopRowObserver(find: find, shown: $findOpen)
                    .id(ObjectIdentifier(find))
            }
            // N5: a proposal reviewed inside the note keeps the note's rows;
            // the top row's note actions wait until the review ends.
            if !hidesRowsForReview, controller.historyBrowser == nil {
                topRow
                    .disabled(reviewsInPlace)
            }
            if !hidesRowsForReview, controller.historyBrowser == nil {
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
        .background(NotesPageSwipeMonitor(isLibraryPresented: controller.isLibraryPresented) { if isCurrent { toggleLibrary() } }
            .accessibilityHidden(true))
        // The app's navigation slide between the note and All notes, and
        // for a new or another note (keystrokes are never held back: the
        // text view takes the keyboard at once, and nothing here animates
        // per keystroke).
        .animation(AtticMotionPreset.slide.animation(reduceMotion: design.reduceMotion), value: controller.isLibraryPresented)
        .animation(Self.noteSlideAnimation(hasShownNote: hasShownNote, reduceMotion: design.reduceMotion),
                   value: controller.active?.id)
        .onChange(of: controller.active?.noteID) { _, noteID in
            // Another note took the page (a link, New Note): it is no
            // longer the one that grew from its card.
            if noteGrow.phase == .open, noteID != noteGrowNoteID { noteGrow.reset() }
        }
        .onChange(of: controller.active?.id) { _, id in
            if id != nil { hasShownNote = true }
        }
    }

    var body: some View {
        pageContent
        .atticTagColourOrigin(.page(.notesLibrary))
        .onAppear {
            #if DEBUG
            Self.lifetimeProbe?(chrome, library)
            #endif
            hasShownNote = controller.active != nil
            #if DEBUG
            runGrowCaptureSeam()
            #endif
            // A task's page opened from All notes grows from its row or card.
            uiState.growOriginProviders[.notes] = { [weak library, noteStore] taskID in
                guard let library, let note = noteStore.notes.first(where: { $0.taskID == taskID }) else { return nil }
                return library.reveal.growOrigin(for: note.id, board: library.layout == .board, title: note.title)
            }
            // Back from a task's page opened in All notes: its search is
            // still there (Phase 3 slice 1 carry-over).
            if let kept = controller.libraryQueryAcrossTaskPage {
                controller.libraryQueryAcrossTaskPage = nil
                library.query = kept
            }
            controller.update(design: design)
            if isCurrent {
                controller.start()
                controller.present()
                installPageCommands()
            }
            library.failedDraftText = { [controller, noteStore] id in
                guard noteStore.note(withID: id) == nil,
                      let draft = controller.failedDrafts.first(where: { $0.noteID == id }) else { return nil }
                return NoteTextExport.plainText(draft.engine.document())
            }
        }
        .onDisappear { releasePageCommands() }
        .onChange(of: isCurrent) { _, current in
            if current {
                controller.start()
                controller.present()
                installPageCommands()
            } else {
                releasePageCommands()
            }
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
            if let filePickerOwner { TaskAttachmentPickerSession.cancel(owner: filePickerOwner) }
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
            guard isCurrent, showsEditor else { return }
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
                searchOpen = false
                // Back on a note (the one that was open included): a toast
                // for a delete made in the library does not follow you into
                // the text. The step itself stays in the library's history.
                dismissOwnToast()
            }
        }
        .onChange(of: chrome.fileRequest, initial: true) { _, request in
            guard let request else {
                if let filePickerOwner { TaskAttachmentPickerSession.cancel(owner: filePickerOwner) }
                return
            }
            let owner = UUID()
            let sourceSession = controller.active?.id
            filePickerOwner = owner
            uiState.setInteractionLock(.notesFilePicker, isActive: true)
            TaskAttachmentPickerSession.present(owner: owner, parentWindow: controller.active?.engine.textView?.window,
                allowedTypes: [.item], allowsMultipleSelection: request == .insert) { urls in
                // A superseded picker must not consume a newer slash,
                // Retry or Locate ticket, or release its interaction hold.
                guard filePickerOwner == owner, chrome.presentedFileRequest == request else { return }
                filePickerOwner = nil
                uiState.setInteractionLock(.notesFilePicker, isActive: false)
                finishFileRequest(controller.active?.id == sourceSession && !urls.isEmpty ? .success(urls) : nil)
            }
        }
        .preference(key: PanelPageNoticeClearancePreferenceKey.self, value: noticeClearance)
        // A group, so its identifier never replaces its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-editor-page")
    }

    private var showsEditor: Bool {
        !controller.isLibraryPresented && controller.proposalReview == nil && controller.active != nil
    }

    private func installPageCommands() {
        chrome.claimPageCommands(owner: commandOwner, keyPressed: { bottomKeyPressed($0) })
        chrome.menuCommands = { noteMenuCommands() }
        chrome.leaveEditor = { forward in leaveEditor(forward: forward) }
        #if DEBUG
        chrome.captureToggleLibrary = { toggleLibrary() }
        chrome.captureImport = { [controller] urls in controller.importFiles(urls) }
        #endif
    }

    private func releasePageCommands() {
        if let filePickerOwner { TaskAttachmentPickerSession.cancel(owner: filePickerOwner) }
        uiState.setInteractionLock(.notesFilePicker, isActive: false)
        chrome.clearPageCommands(owner: commandOwner)
        chrome.controls?.cancelCard(refocus: false)
        chrome.closeFormatBar()
        chrome.tagEditor = nil
        findOpen = false
        searchFocused = false
        bottomFocus = nil
        pendingStop = nil
        bottomStops = false
    }

    /// A per-change review shows inside the note (N5, Idea B); a deletion or
    /// a workspace operation keeps its whole-page comparison.
    private var reviewsInPlace: Bool {
        !controller.isLibraryPresented && controller.isReviewingProposalInPlace
    }
    /// The review bar's room: the row less Back and Aa ("+" folds away)
    /// and the pill's least gaps on each side.
    private var reviewBarRoom: CGFloat {
        max(0, layout.panelSize.width - 2 * layout.chromeInsets.leading
            - 2 * AtticControlSize.panelButton.width - 2 * AtticNoteMetrics.pillMinGap)
    }
    private var hidesRowsForReview: Bool { controller.proposalReview != nil && !reviewsInPlace }

    // MARK: Content

    @ViewBuilder
    private func content(extraBottom: CGFloat) -> some View {
        if let history = controller.historyBrowser {
            NoteHistoryPage(controller: controller, browser: history, layout: layout)
        } else if controller.isLibraryPresented {
            NotesLibraryView(model: library, controller: controller, store: noteStore, layout: layout,
                             bottomClearance: bottomInset + extraBottom, bottomControls: bottomControls, searchFocused: $searchFocused,
                             searchOpen: $searchOpen,
                             rowCommands: { id in rowCommands(id) },
                             libraryCommands: { Self.historyCommands(for: controller) },
                             onOpen: { id in openFromLibrary(id) },
                             onDelete: { id in delete(id) },
                             onBack: { toggleLibrary() },
                             onCreate: { title, tag in newNote(title: title, tag: tag) })
                .opacity(growing && !noteGrow.showsOrigin ? 0 : 1)
                .animation(noteGrow.originAnimation(showing: noteGrow.showsOrigin), value: noteGrow.showsOrigin)
                .allowsHitTesting(!growing || noteGrow.phase == .idle)
                .transition(growing ? .asymmetric(insertion: .opacity.animation(noteGrow.originAnimation(showing: true)),
                                                  removal: .identity)
                                    : slide(from: Self.libraryEdge))
        } else if let review = controller.proposalReview, let changes = review.changes {
            NoteProposalInPlaceReview(controller: controller, review: review, changes: changes,
                columnInset: columnInset, topInset: topInset, bottomInset: bottomControls + bottomInset + extraBottom,
                design: design)
                .overlay { AtticFloatingControlsBand(height: bottomControls) }
                .accessibilitySortPriority(3)
        } else if let review = controller.proposalReview {
            NoteProposalComparison(controller: controller, store: noteStore, review: review,
                columnInset: columnInset, topInset: layout.headerBottom + 8, bottomInset: layout.chromeInsets.bottom + extraBottom,
                design: design)
        } else if let session = controller.active {
            NoteEditorRepresentable(session: session, chrome: chrome, columnInset: columnInset,
                                    topInset: topInset, bottomInset: bottomControls + bottomInset + extraBottom, headerBottom: layout.headerBottom,
                                    design: design, tagEditor: { AnyView(tagEditor(for: session)) },
                                    tagCounts: { [noteStore] in
                                        noteStore.tagCounts
                                    })
                .id(ObjectIdentifier(session.engine))
                // Floating controls (owner, 2026-10-14): the note runs on to
                // the panel's edges, under the header, visible through the
                // variable blur behind it (owner, 2026-10-17: no fade), and
                // under the bottom row, sharp (owner, 2026-10-22). The scroll insets keep the title's
                // and the last line's resting places clear. F-13 stays
                // fixed: the blur (`pageBackdrops`) and the band sit above
                // the text view and its attachment views, below the controls.
                .overlay { AtticFloatingControlsBand(height: bottomControls) }
                .accessibilityIdentifier("note-editor")
                .accessibilitySortPriority(3)
                .opacity(growing && !noteGrow.showsDestination ? 0 : 1)
                .animation(noteGrow.destinationAnimation(showing: noteGrow.showsDestination), value: noteGrow.showsDestination)
                .transition(growing ? .asymmetric(insertion: .opacity.animation(noteArrival), removal: .identity)
                                    : slide(from: Self.noteEdge))
        } else {
            Color.clear
        }
    }

    #if DEBUG
    nonisolated(unsafe) private static var growSeamRan = false

    /// Capture seam (`ATTIC_UI_TEST_GROW=note@<seconds>`, preview identity
    /// only; `ATTIC_UI_TEST_GROW_ROW=<n>` picks the card): All notes opens,
    /// then its first note opens, goes back, opens and is sent back 0.12 s
    /// in, opens and goes back again, 1.6 s apart.
    private func runGrowCaptureSeam() {
        let environment = ProcessInfo.processInfo.environment
        guard !Self.growSeamRan, environment["ATTIC_UI_TESTING"] == "1",
              AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier),
              let seam = environment["ATTIC_UI_TEST_GROW"], seam.hasPrefix("note") else { return }
        Self.growSeamRan = true
        let delay = seam.split(separator: "@").dropFirst().first.flatMap { Double($0) } ?? 4
        let index = environment["ATTIC_UI_TEST_GROW_ROW"].flatMap(Int.init) ?? 0
        // The demo seed has no notes: a few cards to grow from.
        if environment["ATTIC_UI_TEST_SEED"] != nil, !noteStore.notes.contains(where: { $0.taskID == nil }) {
            for (title, text) in [("Trip to Lisbon", "Flights, the tram, and a list of cafés."),
                                  ("Reading list", "Three novels and one about typography."),
                                  ("Ideas", "A quieter Done page; a smaller island."),
                                  ("Groceries", "Milk, lemons, rice, coffee.")] {
                _ = noteStore.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text(title), .text(text)]))
            }
        }
        func at(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
            RunLoop.main.add(Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }, forMode: .common)
        }
        let open: @MainActor () -> Void = {
            let notes = noteStore.notes.filter { $0.taskID == nil }.sorted { $0.updatedAt > $1.updatedAt }
            guard notes.indices.contains(index) else { return }
            openFromLibrary(notes[index].id)
        }
        let back: @MainActor () -> Void = { showLibrary(focusSearch: false) }
        at(max(0, delay - 2)) { back() }
        for (time, action) in [(0.0, open), (1.6, back), (3.2, open), (3.32, back), (4.8, open), (6.4, back)] {
            at(delay + time, action)
        }
    }
    #endif

    /// A grow (or its fade) is moving or holds the note it opened.
    private var growing: Bool { noteGrow.style != .instant && noteGrow.phase != .idle }

    /// The note arriving after the click: the rest of its delay, then M/E.
    private var noteArrival: Animation? {
        guard noteGrow.style == .grow else { return AtticMotionScale.reducedFade }
        let waited = CACurrentMediaTime() - noteGrowStartedAt
        return AtticMotionScale.easeOut(AtticMotionScale.standard).delay(max(0, AtticGrowState.destinationDelay - waited))
    }

    private func libraryGrowOrigin(_ noteID: UUID) -> AtticGrowOrigin? {
        library.reveal.growOrigin(for: noteID, board: library.layout == .board,
                                  title: noteStore.note(withID: noteID)?.title ?? "")
    }

    /// A note opening from its card or row: the card grows at the click.
    private func growNote(from noteID: UUID) {
        let origin = libraryGrowOrigin(noteID)
        // Another card mid-shrink starts afresh from that card.
        if noteGrow.phase != .idle, noteGrowNoteID != noteID { noteGrow.reset() }
        noteGrowNoteID = noteID
        noteGrowStartedAt = CACurrentMediaTime()
        noteGrow.open(from: origin, reduceMotion: design.reduceMotion, reducedStyle: AtticReducedMotionStyle.current)
        #if DEBUG
        AtticGrowTrace.mark("note-open", style: noteGrow.style)
        #endif
        AtticGrowDriver.settleWithoutShell($noteGrow)
    }

    /// The open didn't happen (refused, failed): back into the card.
    private func growNoteBack() {
        guard noteGrow.phase == .opening || noteGrow.phase == .open else { return }
        noteGrow.close(to: noteGrowNoteID.flatMap(libraryGrowOrigin), reduceMotion: design.reduceMotion,
                       reducedStyle: AtticReducedMotionStyle.current)
        #if DEBUG
        AtticGrowTrace.mark("note-close", style: noteGrow.style)
        #endif
        AtticGrowDriver.settleWithoutShell($noteGrow)
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
                // The faded-out native button can linger in the AppKit AX
                // tree after Home. Give accessibility a conditional button
                // whose lifetime follows the same visibility threshold.
                .accessibilityRepresentation {
                    if progress >= 0.5 {
                        Button(chrome.headerTitle) { chrome.presentMenu() }
                            .accessibilityHint(String(localized: "Opens the note’s menu"))
                            .accessibilityIdentifier("notes-header-title")
                    }
                }
        }
        // The search button stands between the title and the page switch:
        // the title's room ends a gap before it.
        .padding(.trailing, Self.headerTitleReserve)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, layout.chromeInsets.top)
        // The top row changes in place on a page switch (option A).
        .panelChangesInPlace()
    }

    /// What the top row's search button takes from the scrolled-away
    /// title's room: the button and its gap to the page switch.
    static let headerTitleReserve: CGFloat = AtticControlSize.headerControl + AtticPanelChromeMetrics.headerGap

    // MARK: Top row

    /// The search is on the top row while it is open, has the keyboard or
    /// a query, and only over All notes (opening it shows All notes).
    private var topSearchShown: Bool {
        controller.isLibraryPresented
            && NotesLibraryView.searchShown(open: searchOpen, focused: searchFocused, query: library.query)
    }

    /// Find in the open note has the top row (N4, Idea B, 2026-11-01).
    private var topFindShown: Bool { showsEditor && findOpen }

    /// The panel's top row on Notes (`PanelTopRow`, Tasks' places): the
    /// search button, or the field that filters All notes through its own
    /// search and tag filter, or, on an open note, Find's field. Notes has
    /// no middle-slot controls and no task-list filter button.
    private var topRow: some View {
        let shown = topSearchShown
        let finding = topFindShown
        // Board | list in the page-switch slot, only on the notes list
        // (Accepted 2026-10-30, "Notes board"); the search folds it.
        return PanelTopRow(page: .notes, layout: layout, searchOpen: shown || finding, moreCommands: { moreCommands() }) {
            if controller.isLibraryPresented {
                NotesLayoutSwitch(selection: $library.layout)
                    .atticDesignCorners()
                    .transition(.opacity)
            }
        } search: {
            if finding, let find = controller.active?.engine.find {
                NoteFindTopRowField(find: find, onAllNotes: searchAllNotes)
                    .transition(PanelTopRowLayout.fieldTransition)
            } else if shown {
                AtticTabsSearchField(placeholder: NotesLibraryModel.placeholder(count: noteStore.notes.count, tag: library.tagFilter),
                                     text: $library.query, isFocused: $searchFocused, floating: true,
                                     onEscape: endTopSearch, header: true)
                    .accessibilityIdentifier("notes-search")
                    .transition(PanelTopRowLayout.fieldTransition)
            } else {
                // On an open note the button finds in it; over All notes it
                // searches the notes. Its tooltip names which.
                PanelTopRowSearchButton(label: Self.searchButtonLabel(onNote: showsEditor), identifier: "notes-search-button",
                                        shared: false) { searchOrFind() }
                    .transition(.opacity)
            }
        }
        .animation(PanelTopRowLayout.searchAnimation(shown: shown || finding, reduceMotion: design.reduceMotion),
                   value: shown || finding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// ••• (Accepted 2026-11-05, "Page-specific options"): on an open note
    /// the note's own menu; over All notes the list's view and its history.
    private func moreCommands() -> [AtticMenuCommand] {
        if showsEditor { return noteMenuCommands() }
        return Self.libraryMoreCommands(layout: library.layout, history: Self.historyCommands(for: controller)) { layout in
            withAnimation(NotesLayoutSwitch.selectionAnimation(reduceMotion: design.reduceMotion)) { library.layout = layout }
        }
    }

    static func libraryMoreCommands(layout: NotesLibraryLayout, history: [AtticMenuCommand],
                                    choose: @escaping (NotesLibraryLayout) -> Void) -> [AtticMenuCommand] {
        [.header(String(localized: "View"))] + NotesLibraryLayout.allCases.map { choice in
            AtticMenuCommand(verbatim: choice.title, state: choice == layout ? .on : .off) { choose(choice) }
        } + history
    }

    /// The top row's Search button's name (and tooltip) on each page.
    static func searchButtonLabel(onNote: Bool) -> String {
        onNote ? String(localized: "Find in note (⌘F)") : String(localized: "Search notes (⌘F)")
    }

    /// The Search button: Find on an open note, else the notes' search.
    private func searchOrFind() {
        if showsEditor, let find = controller.active?.engine.find {
            find.inTopRow = true
            find.show()
        } else {
            showLibrary(focusSearch: true)
        }
    }

    /// All notes at Find's end, or ⇧⌘F: the query goes on to All notes'
    /// search and Find ends.
    private func searchAllNotes() {
        if let find = controller.active?.engine.find, find.isShown {
            let query = find.query
            find.close(returnFocus: false)
            if !query.isEmpty { library.query = query }
        }
        showLibrary(focusSearch: true)
    }

    /// Esc in the field: the search ends and the button returns.
    private func endTopSearch() {
        library.clearSearch()
        searchOpen = false
        searchFocused = false
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
        .panelRowGivesWayToCard()
        .panelBottomBar(.notes,
                        look: PanelBottomBarLook(middle: .tags(tags: library.recentTags(store: noteStore),
                                                               selection: library.tagFilter, idPrefix: "notes-tag-bar",
                                                               shown: true),
                                                 plus: PanelBottomBarLook.notesPlus, shown: controller.isLibraryPresented),
                        actions: PanelBottomBarActions(selectTag: { [library] tag in library.tagFilter = tag },
                                                       plus: { newNoteFromPlus() }))
    }

    /// In Dark the bottom row's glyphs take the strong ink (A39 F13): the
    /// quiet icon grey read as disabled over the dark surface.
    private var darkGlyphs: Bool { design.tokens.context.mode == .dark }

    /// All notes: the tag bar and "+". An open note: Back on the left,
    /// its status between, then Aa and "+" on the right (Notes Page v2; the
    /// "New note" field and the scope button it once had were replaced on
    /// 2026-10-28; N7, Adaptive picks 2026-11-01: "+" stays, Aa one place in).
    @ViewBuilder
    private var bottomButtons: some View {
        Group {
            if controller.isLibraryPresented {
                libraryBar
            } else {
                editorBar
            }
        }
        .frame(height: buttonHeight)
    }

    @ViewBuilder
    private var libraryBar: some View {
        if sharedChrome != nil {
            Color.clear
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else {
            ownLibraryBar
        }
    }

    private var ownLibraryBar: some View {
        HStack(spacing: NotesBarMetrics.gap) {
            // The page switch is the Tall island (Accepted 2026-10-31).
            NotesTagBar(tags: library.recentTags(store: noteStore), selection: library.tagFilter) { tag in
                library.tagFilter = tag
            }
            AtticRaisedButton(systemName: NotesBarMetrics.newNoteSymbol, label: "New note", size: NotesBarMetrics.size,
                              help: String(localized: "New note (⌘N)"),
                              emphasisedGlyph: darkGlyphs, cornerRadius: NotesBarMetrics.radius) {
                newNoteFromPlus()
            }
            .accessibilityIdentifier("notes-new-note")
        }
        .transition(.opacity)
    }

    private var editorBar: some View {
        HStack(spacing: 0) {
            // Back to All notes, which sits to the note's left (the pages
            // slide that way).
            AtticRaisedButton(systemName: "chevron.left", label: "All notes", size: NotesBarMetrics.size,
                              help: String(localized: "All notes (⇧⌘L)"),
                              emphasisedGlyph: darkGlyphs, cornerRadius: NotesBarMetrics.radius) {
                IdleLatencyTrace.controlDispatched(.noteLibrary)
                if sharedChrome?.plusHandedOver != true { toggleLibrary() }
            }
            .noteFormatRowLeaving(.allNotes)
            .modifier(NotesKeyboardStop(stop: .allNotes, enabled: bottomStops, focus: $bottomFocus))
            .accessibilityIdentifier("notes-all-notes")
            .accessibilitySortPriority(1)
            .modifier(NotesComposerChromeAccessibility(size: NotesBarMetrics.size))
            Spacer(minLength: AtticNoteMetrics.pillMinGap)
            if let session = controller.active {
                NoteStatusSlot(controller: controller, store: noteStore, session: session, damaged: damagedRecovery,
                               maxWidth: AtticNoteMetrics.pillMaxWidth(
                                   panelWidth: layout.panelSize.width, chromeInset: layout.chromeInsets.leading,
                                   showsFormat: showsFormatButton),
                               reviewBarMaxWidth: reviewBarRoom)
                    .noteFormatRowLeaving(.status)
                    .accessibilitySortPriority(2)
                    .transition(.opacity)
            }
            Spacer(minLength: AtticNoteMetrics.pillMinGap)
            if showsFormatButton {
                formatButton
                    .modifier(NotesKeyboardStop(stop: .format, enabled: bottomStops, focus: $bottomFocus))
                    .padding(.trailing, reviewsInPlace ? 0 : AtticNoteMetrics.formatButtonGap)
                    .transition(.opacity)
            }
            // N5 Idea C: "+" folds away while the pill is the review bar.
            if !reviewsInPlace {
                newNoteButton
                    .transition(.opacity)
            }
        }
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: reviewsInPlace)
        .transition(.opacity)
    }

    /// N7: "+" stays on an open note, in All notes' place and look (the
    /// shared bar's "+"), so it never moves or changes between the two. The
    /// format row takes the whole row, "+" included: it slides out past the
    /// row's trailing edge as Aa grows, and back as the row closes.
    private var newNoteButton: some View {
        let side = AtticControlSize.headerControl
        let plus = PanelBottomBarLook.notesPlus
        return AtticRaisedButton(systemName: NotesBarMetrics.newNoteSymbol, label: String.LocalizationValue(stringLiteral: plus.label),
                                 size: CGSize(width: side, height: side), help: plus.help, emphasisedGlyph: true,
                                 flat: design.effectiveControls != .liquidGlass, cornerRadius: AtticRadius.header) {
            if sharedChrome?.plusHandedOver != true { newNoteFromPlus() }
        }
        .atticDesignCorners()
        .noteFormatRowLeaving(.newNote)
        .accessibilityIdentifier(plus.identifier)
        .modifier(NotesKeyboardStop(stop: .newNote, enabled: bottomStops, focus: $bottomFocus))
        .modifier(NotesComposerChromeAccessibility(size: CGSize(width: side, height: side)))
    }

    /// Aa shows on an editable note with text under its title (owner,
    /// 2026-10-11: on a title-only note it waits for the body), or while its
    /// format row is open.
    private var showsFormatButton: Bool {
        // N5 Idea C: Aa keeps its place while a proposal is reviewed in the
        // note (dimmed: the review's text can't be formatted).
        (showsEditor || reviewsInPlace) && controller.active?.isReadOnly == false && (chrome.hasBody || chrome.formatRow.isOpen)
    }

    /// Aa (OD-14, p2-36 draft 1): the bottom row turns into the format row
    /// in place, until ✕ or Esc. ⌘T opens it too.
    private var formatButton: some View {
        AtticRaisedButton(systemName: NoteFormatRowSource.symbol, label: "Format", size: NotesBarMetrics.size,
                          help: String(localized: "Format (⌘T)"), emphasisedGlyph: darkGlyphs,
                          cornerRadius: NotesBarMetrics.radius) {
            IdleLatencyTrace.controlDispatched(.noteFormat)
            chrome.openFormatBar(keyboard: false)
        }
        .noteFormatRowSource()
        .disabled(reviewsInPlace)
        .accessibilityIdentifier("notes-format-button")
    }

    // MARK: Keyboard out of the text (OD-7)

    /// The stops in order: the text, then the bottom row's controls.
    private var keyboardStops: [NotesKeyboardOrder.Stop] {
        NotesKeyboardOrder.stops(format: showsFormatButton,
                                newNote: !reviewsInPlace && sharedChrome?.plusHandedOver != true)
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
            case .newNote: newNoteFromPlus()
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
            Button("") {
                if let id = currentNoteID { Task { @MainActor in _ = await controller.duplicateNote(noteID: id) } }
            }
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
            Button("") { searchAllNotes() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            // The bar's New note and All notes keys, wherever the page shows
            // (its buttons show on one side each).
            Button("") { newNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(controller.proposalReview != nil)
            Button("") { toggleLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(controller.proposalReview != nil)
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
        // All notes during an in-note review ends the review first (the
        // proposal waits; nothing decided is written).
        if reviewsInPlace {
            controller.endProposalReview()
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
            // The shrink starts with the click, from the note it grew into.
            let grown = noteGrow.phase != .idle && controller.active?.noteID == noteGrowNoteID
            if !grown { noteGrow.reset() }
            guard controller.showLibrary() else { return }
            if grown { growNoteBack() }
        }
        if focusSearch { searchFocused = true }
    }

    private func newNoteFromPlus() {
        if let panelComposer {
            panelComposer.open(on: .notes)
        } else {
            newNote()
        }
    }

    private func newNote() {
        guard Self.requestNewNoteAndPlayCue(controller) else { return }
        library.clearSearch()
        // An untouched draft stays; only the caret moves to its title.
        DispatchQueue.main.async { chrome.focusText() }
    }

    @discardableResult
    static func requestNewNoteAndPlayCue(_ controller: NotesPageController) -> Bool {
        let previousNoteID = controller.active?.noteID
        guard controller.requestNewNote() else { return false }
        if let newNoteID = controller.active?.noteID, newNoteID != previousNoteID {
            AtticSounds.play(.created)
        }
        return true
    }

    /// "New note “kyoto”" (in #launch) from All notes: the note the search
    /// named, its caret at the end of the title.
    private func newNote(title: String, tag: String?) {
        guard controller.requestNewNote(title: title, tags: tag.map { [$0] } ?? []) else { return }
        AtticSounds.play(.created)
        library.clearSearch()
        DispatchQueue.main.async { chrome.focusText() }
    }

    private func openFromLibrary(_ id: UUID) {
        IdleLatencyTrace.controlDispatched(.noteOpen)
        // A task's own note opens as its task's page (§ 5.3), over Notes.
        let query = library.query
        if TaskNoteWindows.shared.bringForward(noteID: id, searchQuery: query) {
            if library.query == query { library.clearSearch() }
            return
        }
        if let taskID = noteStore.note(withID: id)?.taskID {
            if controller.openTaskPage?(taskID) == true {
                controller.libraryQueryAcrossTaskPage = query.isEmpty ? nil : query
                controller.pendingLibraryTaskRoute = taskID
                TaskNotePresenter.open(for: taskID)?.revealSearchResult(query)
                return
            }
        }
        if let draft = controller.failedDrafts.first(where: { $0.noteID == id }), noteStore.note(withID: id) == nil {
            if controller.openFailedDraft(sessionID: draft.id), library.query == query {
                library.clearSearch()
            }
        } else {
            growNote(from: id)
            let style = noteGrow.style
            Task { @MainActor in
                // The click's first frame goes out before the note is built.
                await AtticGrowDriver.yieldFirstFrame(style)
                if await controller.openFromLibrary(noteID: id, searchQuery: query) {
                    library.dismissAfterOpenedNote(controller, requestedQuery: query)
                    if noteGrowNoteID == id { noteGrow.destinationArrived() }
                    #if DEBUG
                    AtticGrowTrace.mark("note-arrived", style: noteGrow.style)
                    #endif
                } else {
                    growNoteBack()
                }
            }
            return
        }
    }

    private var currentNoteID: UUID? {
        guard let session = controller.active else { return nil }
        return session.noteID
    }

    // MARK: Delete and its Undo

    private func delete(_ id: UUID) {
        Task { @MainActor in
            guard await controller.deleteNoteDurably(noteID: id) else { return }
            AtticSounds.play(.trashed)
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

    /// The note's menu (⋯, ⇧⌘I, the header title). Page commands first,
    /// an icon on every row (Dropdown content: answers, owner, 2026-10-24,
    /// sheet 5): Add to Tasks, Pin to Top, Tags…, Version History │ Copy
    /// as Markdown, Print…, Duplicate, Save Recovery Copy… │ a selected
    /// image's or file's own menu, Insert ›, Format › │ Delete. Format › is
    /// split into short submenus (answer 5 B). What is not built yet is
    /// left out.
    private func noteMenuCommands() -> [AtticMenuCommand] {
        guard let session = controller.active else { return [] }
        let id = session.noteID
        let engine = session.engine
        let editable = !session.isReadOnly
        var commands: [AtticMenuCommand] = []
        // Add to Tasks first, from the shared producer (an open ordinary
        // note: an item in Tasks shows its own page instead).
        // A draft not saved yet is an ordinary note too (slice B's rule).
        if editable, let makeTask = controller.makeTaskFromNote {
            commands += noteStore.note(withID: id) == nil
                ? TaskNoteConversion.commands(taskID: nil, hasWriting: true, isSubtask: false, add: { makeTask(id) }, remove: {})
                : Self.oneItemCommands(noteID: id, noteStore: noteStore, controller: controller, taskStore: taskStore) {
                    makeTask(id)
                }
        }
        let pinned = noteStore.note(withID: id)?.isPinned ?? false
        commands.append(AtticMenuCommand(pinned ? "Unpin from Top" : "Pin to Top", isDisabled: !session.isPersisted && session.isUntouchedDraft,
                                         identifier: "notes-menu-pin") {
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
                Task { @MainActor in _ = await controller.duplicateNote(noteID: id) }
            })
        }
        if controller.canSaveRecoveryCopy(session) {
            commands.append(AtticMenuCommand("Save Recovery Copy…", shortcut: Self.saveRecoveryCopyShortcut,
                                             identifier: Self.saveRecoveryCopyIdentifier) {
                Task { await controller.saveRecoveryCopy(of: session) }
            })
        }
        var editing: [AtticMenuCommand] = []
        // A selected image or file: its own commands (Image ▸ or File ▸),
        // the same list as its right-click menu.
        if let objects = chrome.objectControls,
           let submenu = NoteObjectMenu.selectedObjectSubmenu(engine: engine,
                run: { [weak objects] id, command in objects?.run(command, objectID: id) },
                chooseApplication: { [weak objects] id in objects?.chooseApplication(for: id) }) {
            editing.append(submenu)
        }
        if editable {
            // Insert ▸ and Format ▸: the same commands as the selection bar,
            // Aa, the right-click menu and the menu bar.
            let router = chrome.controls?.router ?? NoteCommandRouter(engine: engine)
            editing += router.menuCommands(from: .noteMenu)
        }
        if var first = editing.first {
            first.startsSection = true
            editing[0] = first
            commands += editing
        }
        commands.append(AtticMenuCommand(verbatim: Self.deleteTitle, isDestructive: true, startsSection: true) {
            delete(id)
        }.identified("notes-menu-delete"))
        return commands
    }

    /// The library's command list: a row's right-click menu, its ⋯, ⇧⌘I
    /// and VoiceOver's named actions, and the source of the library's keys
    /// (⌘D, ⌥⇧⌘C, ⌘⌫ find their command here by identifier). ONE list per
    /// scope: this is the library row's; `noteMenuCommands` is the open
    /// note's. A command that cannot run is dimmed here, and its key does
    /// nothing.
    ///
    /// Its content (Dropdown content: answers, owner, 2026-10-24, sheet 2
    /// and answer 2 A): Open Page, Add to Tasks (or Remove from Tasks for
    /// an item in Tasks with writing) │ Pin to Top, Filter by
    /// Tag › │ Copy as Markdown, Duplicate │ Delete, an icon on every row.
    /// Undo and Redo leave the row menu: ⌘Z and the Edit menu keep them,
    /// and the library's background menu (`historyCommands`) still has them.
    private func rowCommands(_ id: UUID) -> [AtticMenuCommand] {
        Self.libraryRowCommands(id, noteStore: noteStore, controller: controller, taskStore: taskStore,
                                activeTag: library.tagFilter, hue: tagColouring.hue(for:),
                                filter: { [library] tag in library.tagFilter = tag },
                                open: { openFromLibrary($0) }, delete: { delete($0) })
    }

    /// The word both note menus use for deleting the whole item.
    /// The word both note menus use for deleting the whole item: Delete
    /// (One item: owner answers, 2026-10-23, answer 3), replacing the
    /// draft's "Delete Note".
    static var deleteTitle: String { String(localized: "Delete") }

    /// Add to Tasks, or Remove from Tasks for an item in Tasks with writing:
    /// the shared producer (slice B), so both note menus and the task row
    /// offer the same command under the same rule. `add` runs Add to Tasks
    /// for an ordinary note.
    static func oneItemCommands(noteID: UUID, noteStore: NoteStore, controller: NotesPageController,
                                taskStore: TaskStore?, add: @escaping () -> Void) -> [AtticMenuCommand] {
        guard let stored = noteStore.note(withID: noteID) else { return [] }
        if let taskID = stored.taskID {
            guard let remove = controller.removeFromTasks else { return [] }
            return TaskNoteConversion.commands(taskID: taskID,
                hasWriting: TaskNoteConversion.hasWriting(taskID, in: ModelContext(noteStore.container)),
                isSubtask: taskStore?.listedTask(withID: taskID)?.parentID != nil, add: {}, remove: { remove(taskID) })
        }
        guard controller.makeTaskFromNote != nil else { return [] }
        return TaskNoteConversion.commands(taskID: nil, hasWriting: true, isSubtask: false, add: add, remove: {})
    }

    static func libraryRowCommands(_ id: UUID, noteStore: NoteStore, controller: NotesPageController, taskStore: TaskStore?,
                                   activeTag: String?, hue: @escaping (String) -> AtticTagHue?,
                                   filter: @escaping (String?) -> Void, open: @escaping (UUID) -> Void,
                                   delete: @escaping (UUID) -> Void) -> [AtticMenuCommand] {
        let stored = noteStore.note(withID: id)
        let pinned = stored?.isPinned ?? false
        let conversion = oneItemCommands(noteID: id, noteStore: noteStore, controller: controller, taskStore: taskStore) {
            guard let add = controller.makeTaskFromNote else { return }
            Task { @MainActor in
                if await controller.openFromLibrary(noteID: id) { controller.dismissLibrary(); add(id) }
            }
        }
        // An item in Tasks filters by its task's live tags (the plan's
        // effective item tags); an ordinary note by its own.
        let tags = stored?.taskID.flatMap { taskStore?.listedTask(withID: $0)?.tags } ?? stored?.tags ?? []
        // A dimmed row says why (one-item plan, "Menus and keyboard").
        let notSaved = String(localized: "Not saved yet")
        var pin = AtticMenuCommand(pinned ? "Unpin from Top" : "Pin to Top", startsSection: true, identifier: "notes-row-pin") {
            controller.setPinned(!pinned, noteID: id)
        }
        if stored == nil { pin = pin.disabled(because: notSaved) }
        var filterByTag = NotesLibraryView.tagsSubmenu(tags: tags, activeTag: activeTag, hue: hue, onSelect: filter)
        if tags.isEmpty { filterByTag.disabledReason = String(localized: "No tags") }
        var duplicate = AtticMenuCommand("Duplicate", shortcut: KeyboardShortcut("d", modifiers: .command),
                                         identifier: NotesLibraryView.duplicateIdentifier) {
            Task { @MainActor in _ = await controller.duplicateNote(noteID: id) }
        }
        if stored?.usesDocumentFormat != true {
            duplicate = duplicate.disabled(because: stored == nil ? notSaved : String(localized: "This note's format can't be copied"))
        }
        var remove = AtticMenuCommand(verbatim: deleteTitle,
                                      shortcut: KeyboardShortcut(.delete, modifiers: .command), isDestructive: true,
                                      startsSection: true) { delete(id) }.identified("notes-row-delete")
        if stored == nil { remove = remove.disabled(because: notSaved) }
        return [AtticMenuCommand("Open Page", shortcut: AtticTaskShortcut.openPage, identifier: "notes-row-open") { open(id) }] + conversion + [
            pin,
            filterByTag,
            AtticMenuCommand("Copy as Markdown", shortcut: KeyboardShortcut("c", modifiers: [.command, .option, .shift]),
                             startsSection: true, identifier: NotesLibraryView.copyMarkdownIdentifier) {
                controller.copyMarkdown(noteID: id)
            },
            duplicate,
            remove
        ]
    }

    /// The library's history (pin, duplicate, delete) as commands, named for
    /// the step each would reverse and dimmed when there is none: the menu
    /// of the library's background, so with no rows (the last note just
    /// deleted) Undo is still reachable here. Row menus no longer repeat
    /// them (Dropdown content: answers, owner, 2026-10-24, answer 2 A).
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

    /// The tag line's editor (N6, `NoteTagLineEditor.swift`). Return or Esc
    /// give the keyboard back to the text; a click elsewhere leaves it there.
    private func tagEditor(for session: NoteSession) -> some View {
        NoteTagEditor(session: session, store: noteStore) { returnKeyboard in
            chrome.tagEditor = nil
            if returnKeyboard { chrome.returnKeyboardToText() }
        }
        .atticDesign(design)
    }
}

/// The status slot between the bottom buttons (UX plan § 3.12): the most
/// urgent state in a pill, "+N" when there are more, and every state with
/// its reasons and actions in the details. Nothing shows when all is well.
struct NoteStatusSlot: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var store: NoteStore
    @ObservedObject var session: NoteSession
    @ObservedObject var damaged: NoteDamagedRecoveryExit
    /// The room between the bottom row's buttons.
    let maxWidth: CGFloat
    /// States from outside the note's session, most urgent first (a task's
    /// note: a task command that changed nothing, § 5.6; OD-4 keeps them in
    /// this slot rather than a Retry line of their own).
    var leadingItems: [AtticStatusItem] = []
    /// N5: the room the proposal's pill has once it grows into the review bar.
    var reviewBarMaxWidth: CGFloat = .infinity
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
        return leadingItems + list
    }

    var body: some View {
        let items = items
        // A change of state springs in; typing never changes this key.
        let key = items.map(\.id).joined(separator: ",")
        ZStack {
            if let primary = items.first, items.count == 1, primary.id == "proposal",
               let proposalID = controller.proposalID(for: session, deletion: false) {
                // N5 Idea C: the proposal's pill grows into the review bar.
                NoteProposalReviewBar(controller: controller, item: primary, proposalID: proposalID, maxWidth: maxWidth,
                                      openMaxWidth: reviewBarMaxWidth)
                    .id(key)
                    .transition(AtticMotionScale.overlayTransition(reduceMotion: design.reduceMotion, from: .bottom))
            } else if let primary = items.first {
                AtticStatusPill(item: primary, more: items.count - 1,
                                inlineAction: items.count == 1 || primary.id == "workspaceSave" ? inlineAction(for: primary) : nil,
                                onCancel: items.count == 1 ? cancel(for: primary) : nil, maxWidth: maxWidth) {
                    showingDetails = true
                }
                .id(key)
                // The overlays' one recipe (A4 M-03): a 4 pt rise and a
                // 0.96 grow (M/S), leaving by opacity (F/E).
                .transition(AtticMotionScale.overlayTransition(reduceMotion: design.reduceMotion, from: .bottom))
            }
        }
        .atticAnnounceErrors(items.filter { $0.tone == .error }.map {
            [$0.title, $0.explanation].compactMap { $0 }.joined(separator: ". ")
        })
        .animation(AtticMotionScale.overlayAnimation(reduceMotion: design.reduceMotion), value: key)
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
        ["notSaved", "taskFailure", "workspaceSave"].contains(item.id) ? item.actions.first : nil
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
                      case let .saved(url): session.showNotice(NoteNotice(kind: .copySaved, detail: String(localized: "Recovery copy saved as “\(url.lastPathComponent)”.")))
                      case let .refused(message): session.showNotice(NoteNotice(kind: .copyFailed, detail: message))
                      default: break
                      }
                  })
        ]
        if details.confirmation.canDiscard {
            actions.append(.init(title: String(localized: "Discard Damaged Recovery…"), identifier: "notes-damaged-discard",
                                 handler: close {
                                     if case let .refused(message) = await damaged.discard(details) { session.showNotice(NoteNotice(kind: .notSaved, detail: message)) }
                                 }))
        }
        return AtticStatusItem(id: "damaged-\(details.confirmation.checkpointFilename)", systemName: "exclamationmark.circle",
                               title: details.title, explanation: details.explanation, tone: .error, actions: actions)
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
        case .couldntFinishSaving:
            return AtticStatusItem(id: "workspaceSave", systemName: "exclamationmark.circle", title: status.label,
                explanation: status.explanation, tone: .error, actions: [
                    .init(title: String(localized: "Retry"), identifier: "notes-retry-workspace",
                          handler: details { controller.retry(session) })
                ])
        case .onlyInMemory:
            return AtticStatusItem(id: "onlyInMemory", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .error, actions: [
                                       .init(title: String(localized: "Retry"), handler: details { controller.retry(session) }),
                                       .init(title: String(localized: "Copy Text"), identifier: "notes-copy-text",
                                             handler: details(controller.copyActiveText)),
                                       saveRecoveryCopyAction(details)
                                   ])
        case .notSaved:
            return AtticStatusItem(id: "notSaved", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .error, actions: [
                                       .init(title: String(localized: "Retry"), identifier: "notes-retry",
                                             handler: details { controller.retry(session) }),
                                       .init(title: String(localized: "Copy Text"), identifier: "notes-copy-text",
                                             handler: details(controller.copyActiveText)),
                                       saveRecoveryCopyAction(details)
                                   ])
        case .changedElsewhere, .deletedElsewhere:
            return AtticStatusItem(id: "conflict", systemName: "exclamationmark.circle", title: status.label,
                                   explanation: status.explanation, tone: .caution, actions: [
                                       .init(title: String(localized: "Keep as new note"), identifier: "notes-keep-as-new",
                                             handler: details { Task { @MainActor in _ = await controller.keepAsNewNoteDurably() } }),
                                       .init(title: String(localized: "Review"), identifier: "notes-review-conflict",
                                             handler: details { showingProposal = true })
                                   ])
        case .deletionProposal:
            let displayedID = controller.proposalID(for: session, deletion: true)
            return AtticStatusItem(id: "deletionProposal", systemName: "exclamationmark.circle", title: status.label,
                explanation: status.explanation, tone: .caution, actions: [
                    .init(title: "Restore", identifier: "notes-restore-deletion", handler: details {
                        guard let id = displayedID else { return }
                        if !store.discardProposal(id, noteID: session.noteID) {
                            session.showNotice(NoteNotice(kind: .notRestored, detail: store.lastErrorMessage ?? "The deletion proposal could not be restored."))
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
                            session.showNotice(NoteNotice(kind: .notCleared, detail: store.lastErrorMessage ?? "Attribution could not be acknowledged."))
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
        case let .notice(notice):
            // Damaged recovery has its own items; its sentence leaves the notice.
            guard let message = NoteStatusPresentation.notice(notice.detail,
                    removingDamaged: damaged.entries.map(\.confirmation.checkpointFilename)) else { return nil }
            if notice.severity == .progress {
                // Pending guidance: progress, quietly, clearing itself.
                return AtticStatusItem(id: "pending", systemName: nil, title: notice.kind.headline, explanation: message, tone: .quiet)
            }
            var actions: [AtticStatusItem.Action] = []
            if let action = NoteStatusPresentation.pasteAsTextAction(for: notice, engine: session.engine, handler: details {
                session.notice = nil
                session.engine.pasteLastTableAsText()
            }) { actions.append(action) }
            actions.append(.init(title: String(localized: "Dismiss"), identifier: "notes-notice-dismiss",
                                 handler: details { session.notice = nil }))
            // The pill says the headline; the details say the sentence (D-05).
            return AtticStatusItem(id: "notice", systemName: "info.circle",
                                   title: notice.kind.headline,
                                   explanation: message, tone: notice.severity == .error ? .error : (notice.severity == .caution ? .caution : .normal),
                                   actions: actions)
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
            NoteHistoryVersionSwitch(choices: [(false, String(localized: "Current")), (true, String(localized: "Proposed"))],
                selection: Binding(get: { selected == 1 }, set: { selected = $0 ? 1 : 0 }),
                trackHeight: AtticRadius.reviewBar * 2, trackInset: 7)
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
struct NoteProposalComparison: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var store: NoteStore
    let review: NoteProposalReview
    let columnInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let design: AtticDesignContext
    @State private var proposed = false
    @State private var busy = false

    private var document: NoteDocument {
        guard proposed else { return review.current }
        if review.isDeletion { return NoteDocument(blocks: [.text("Proposed deletion"), .text("This note would move to Recently Deleted.")]) }
        return review.proposedPreview
    }

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                NoteHistoryVersionSwitch(choices: [(false, String(localized: "Current")), (true, String(localized: "Proposed"))],
                    selection: $proposed, trackHeight: AtticRadius.reviewBar * 2, trackInset: 7)
                AtticText(verbatim: "\(review.agent) · \(review.createdAt.formatted(date: .omitted, time: .shortened)) · \(review.summary)",
                          style: .helper, ink: .helper)
                if controller.reviewProposals.count > 1 {
                    AtticCommandMenu(commands: controller.reviewProposals.map { edit in
                        AtticMenuCommand(verbatim: "\(edit.agentName.isEmpty ? "Agent" : edit.agentName) · \(edit.createdAt.formatted(date: .omitted, time: .shortened))\(edit.isDeletion ? " · Delete" : "")") {
                            Task { _ = await controller.beginProposalReview(id: edit.id) }
                        }
                    }, accessibilityLabel: String(localized: "Proposals")) {
                        Text("\(controller.reviewProposals.count) proposals")
                    }
                    .accessibilityIdentifier("notes-proposal-picker")
                }
            }.padding(.horizontal, columnInset)
            NoteComparisonPreview(document: document, noteID: review.noteID, design: design,
                                  imageProvider: controller, columnInset: columnInset)
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
                    Button(review.workspaceIntent == nil ? "Replace with proposal" : "Apply Workspace Operation") { run { await controller.acceptProposal() } }
                        .accessibilityIdentifier("notes-proposal-replace")
                }
                HStack {
                    Button("Back") { controller.endProposalReview() }
                        .accessibilityIdentifier("notes-proposal-back")
                    Spacer(minLength: 4)
                    AtticCommandMenu(commands: {
                        var save = AtticMenuCommand(verbatim: review.isDeletion ? String(localized: "Save as New Note") : String(localized: "Save Proposal as New Note"),
                                                    isDisabled: review.workspaceIntent != nil) {
                            run { await controller.saveReviewedProposalAsNew() }
                        }
                        save.identifier = "notes-proposal-save-new"
                        var discard = AtticMenuCommand("Discard Proposal") { _ = controller.discardReviewedProposal() }
                        discard.identifier = "notes-proposal-discard"
                        var items = [save, discard]
                        if review.isDeletion {
                            items.append(AtticMenuCommand("Delete Note", isDestructive: true, identifier: "notes-proposal-delete") {
                                run { await controller.acceptProposal() }
                            })
                        }
                        return items
                    }(), accessibilityLabel: String(localized: "Proposal actions")) {
                        Image(systemName: "ellipsis")
                    }
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

/// N5 (Planning.md, Accepted "2026-11-01 · Adaptive picks"; draft
/// `adaptive-drafts-notes.html`, N5 Idea C): an agent's proposal is
/// reviewed inside the note. Each change shows in place, removed lines
/// struck through on red above their added lines on green, with its own
/// Reject and Accept; the bottom row's status pill grows into the review
/// bar (`NoteProposalReviewBar`). Decisions stay in memory (⌘Z, ⇧⌘Z) until
/// the last one writes the note from the accepted changes only. Esc ends
/// the review; the proposal waits.
struct NoteProposalInPlaceReview: View {
    @ObservedObject var controller: NotesPageController
    let review: NoteProposalReview
    let changes: NoteProposalChangeSet
    let columnInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let design: AtticDesignContext

    var body: some View {
        let display = changes.display(decisions: controller.proposalDecisions)
        ZStack(alignment: .bottom) {
            NoteProposalReviewDocument(display: display, noteID: review.noteID, design: design,
                                       imageProvider: controller, columnInset: columnInset,
                                       topInset: topInset, bottomInset: bottomInset) { [controller] id, accept in
                controller.performProposalReviewAction { await controller.decideProposalChange(id, accept: accept) }
            }
            .accessibilityIdentifier("notes-proposal-document")
            if let message = controller.proposalReviewNotice {
                // A refused or failed write says why, just above the bar.
                Text(message)
                    .font(.system(size: NoteProposalReviewMetrics.noticeFont))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .atticGlassControl(in: Squircle(cornerRadius: AtticRadius.row, exponent: AtticShape.surfaceExponent),
                                       interactive: false)
                    .padding(.horizontal, columnInset)
                    .padding(.bottom, bottomInset + 6)
                    .transition(AtticMotionScale.overlayTransition(reduceMotion: design.reduceMotion, from: .bottom))
                    .accessibilityIdentifier("notes-proposal-failure")
            }
            keys
        }
        .animation(AtticMotionScale.overlayAnimation(reduceMotion: design.reduceMotion), value: controller.proposalReviewNotice)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-proposal-review")
    }

    /// Esc folds the bar back into the pill and ends the review (the
    /// proposal waits); ⌘Z and ⇧⌘Z step through the decisions.
    private var keys: some View {
        ZStack {
            Button("") { controller.endProposalReview() }
                .keyboardShortcut(.cancelAction)
            Button("") { _ = controller.undoProposalDecision() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!controller.canUndoProposalDecision)
            Button("") { _ = controller.redoProposalDecision() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!controller.canRedoProposalDecision)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// N5 Idea C: the bottom row's "Claude has changes" pill, which grows in
/// place into the review bar. Its ✦ stays put; the words become the count
/// of undecided changes; •••, Reject and Accept come in at its end. A click
/// on the words (or Esc) folds it back. Once every change is decided the
/// proposal is resolved, so the status (and the pill) goes.
struct NoteProposalReviewBar: View {
    @ObservedObject var controller: NotesPageController
    let item: AtticStatusItem
    let proposalID: UUID
    var maxWidth: CGFloat = AtticNoteMetrics.pillMaxWidth
    var openMaxWidth: CGFloat = .infinity
    @Environment(\.atticDesign) private var design

    private var isOpen: Bool { controller.isReviewingProposalInPlace }
    private var count: String {
        let n = controller.remainingProposalChanges
        return n == 1 ? String(localized: "1 change") : String(localized: "\(n) changes")
    }

    var body: some View {
        let m = AtticNoteMetrics.self
        let radius = AtticRadius.control(height: m.pillHeight)
        HStack(spacing: 0) {
            Button {
                if isOpen { controller.endProposalReview() } else {
                    Task { _ = await controller.beginProposalReview(id: proposalID) }
                }
            } label: {
                HStack(spacing: m.pillGap) {
                    AtticIcon(systemName: item.systemName ?? "sparkle", size: m.pillIconSize, weight: .medium,
                              ink: item.tone.iconInk)
                    AtticText(verbatim: isOpen ? count : item.title, style: .toast, ink: .body, truncates: true)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("notes-proposal-count")
                }
                .frame(height: m.pillHeight)
                .padding(.leading, m.pillPadding)
                .padding(.trailing, isOpen ? 0 : m.pillPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(AtticUndimmedButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel(isOpen ? count : item.title)
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .accessibilityIdentifier("notes-proposal-pill")
            if isOpen {
                NoteProposalReviewActions(controller: controller)
                    .padding(.leading, NoteProposalReviewMetrics.actionsLead)
                    .padding(.trailing, NoteProposalReviewMetrics.actionsTrail)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: isOpen ? openMaxWidth : min(m.pillMaxWidth, maxWidth))
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: m.pillHeight)
        .atticRaisedMaterial(cornerRadius: radius, interactive: false)
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: isOpen)
        .animation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion), value: controller.remainingProposalChanges)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-proposal-bar")
    }
}

/// The review bar's actions: ••• (Save as New Note, Discard Proposal, any
/// other proposals), then Reject and Accept for every change still open.
/// All state is the controller's.
struct NoteProposalReviewActions: View {
    @ObservedObject var controller: NotesPageController

    var body: some View {
        HStack(spacing: NoteProposalReviewMetrics.buttonGap) {
            actionsMenu
            pill("Reject", dark: false, id: "notes-proposal-reject-all") {
                controller.performProposalReviewAction { await controller.decideRemainingProposalChanges(accept: false) }
            }
            pill("Accept", dark: true, id: "notes-proposal-accept-all") {
                controller.performProposalReviewAction { await controller.decideRemainingProposalChanges(accept: true) }
            }
        }
        .disabled(controller.isProposalReviewBusy)
        .fixedSize()
    }

    private var actionsMenu: some View {
        AtticCommandMenu(commands: {
            let save = AtticMenuCommand("Save as New Note", identifier: "notes-proposal-save-new") {
                controller.performProposalReviewAction { await controller.saveReviewedProposalAsNew() }
            }
            let discard = AtticMenuCommand("Discard Proposal", identifier: "notes-proposal-discard") {
                _ = controller.discardReviewedProposal()
            }
            // A change in another proposal is a new menu section, as in the native menu.
            var items = [save, discard]
            if controller.reviewProposals.count > 1 {
                items.append(contentsOf: controller.reviewProposals.enumerated().map { index, edit in
                    AtticMenuCommand(verbatim: "\(edit.agentName.isEmpty ? "Agent" : edit.agentName) · \(edit.createdAt.formatted(date: .omitted, time: .shortened))\(edit.isDeletion ? " · Delete" : "")",
                                     startsSection: index == 0) {
                        Task { _ = await controller.beginProposalReview(id: edit.id) }
                    }
                })
            }
            return items
        }(), accessibilityLabel: String(localized: "Proposal actions")) {
            Image(systemName: "ellipsis")
                .font(.system(size: NoteProposalReviewMetrics.menuGlyph, weight: .medium))
                .frame(width: NoteProposalReviewMetrics.menuSize, height: NoteProposalReviewMetrics.menuSize)
                .contentShape(Circle())
        }
        .help("Proposal actions")
        .accessibilityLabel("Proposal actions")
        .accessibilityIdentifier("notes-proposal-menu")
    }

    private func pill(_ title: LocalizedStringKey, dark: Bool, id: String, action: @escaping () -> Void) -> some View {
        let metrics = NoteProposalReviewMetrics.self
        return Button(action: action) {
            Text(title)
                .font(.system(size: metrics.pillFont, weight: dark ? .semibold : .medium))
                .foregroundStyle(dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .labelColor))
                .padding(.horizontal, dark ? metrics.pillPadding : metrics.softPillPadding)
                .frame(height: metrics.pillHeight)
                .background(AtticControlShape.shape(cornerRadius: metrics.pillHeight / 2, exponent: AtticShape.controlExponent)
                    .fill(dark ? Color(nsColor: .labelColor) : Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// Draft N5 Idea C's values, design px halved.
enum NoteProposalReviewMetrics {
    static let actionsLead: CGFloat = 4       // .gact margin-left 12 px, less 2 to fit 320 pt
    static let actionsTrail: CGFloat = 3.5    // 7 px
    static let noticeFont: CGFloat = 9.5
    static let pillHeight: CGFloat = 20       // .pillbtn 40 px
    static let pillFont: CGFloat = 9.5        // 19 px
    static let pillPadding: CGFloat = 8       // 16 px
    static let softPillPadding: CGFloat = 7   // 14 px
    static let buttonGap: CGFloat = 3         // 6 px
    static let menuSize: CGFloat = 20         // .tiny 44 px, less 2 to fit 320 pt
    static let menuGlyph: CGFloat = 11
    static let changeButton: CGFloat = 17     // .chg button, 34 px
    static let changeInset: CGFloat = 4       // right: 8 px
}

/// One change's Reject and Accept, at the end of its last line.
private struct NoteProposalChangeControls: View {
    let change: Int
    let onDecide: (Bool) -> Void

    var body: some View {
        let size = NoteProposalReviewMetrics.changeButton
        HStack(spacing: NoteProposalReviewMetrics.buttonGap) {
            Button { onDecide(false) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: size, height: size)
                    .background(AtticControlShape.shape(cornerRadius: size / 2, exponent: AtticShape.controlExponent).fill(Color.primary.opacity(0.06)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reject change")
            .accessibilityLabel("Reject change")
            .accessibilityIdentifier("notes-proposal-change-reject-\(change)")
            Button { onDecide(true) } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: size, height: size)
                    .background(AtticControlShape.shape(cornerRadius: size / 2, exponent: AtticShape.controlExponent).fill(Color(nsColor: .labelColor)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Accept change")
            .accessibilityLabel("Accept change")
            .accessibilityIdentifier("notes-proposal-change-accept-\(change)")
        }
        .fixedSize()
    }
}

/// The review's note: the shipping read-only engine with the review's
/// marks (`NoteBlockLayoutFragment.reviewMark`), and each open change's
/// Reject and Accept as subviews of the text, so they scroll with it.
struct NoteProposalReviewDocument: NSViewRepresentable {
    let display: NoteProposalDisplay
    let noteID: UUID
    let design: AtticDesignContext
    let imageProvider: NoteImageProviding
    let columnInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onDecide: (Int, Bool) -> Void

    final class Host: NSView {
        var onLayout: (@MainActor () -> Void)?
        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    @MainActor final class Coordinator {
        var engine: NoteEditorEngine?
        var display: NoteProposalDisplay?
        var controls: [(block: Int, view: NSView)] = []
        var columnInset: CGFloat = 0
        var frameObserver: NSObjectProtocol?
        var onDecide: (Int, Bool) -> Void = { _, _ in }


        /// Each control sits 4 pt inside the band's trailing end, centred
        /// on its block (draft: `right: 8px; top: 50%`).
        func positionControls() {
            guard let engine, let text = engine.textView, !controls.isEmpty else { return }
            if let layout = text.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
            let ranges = engine.paragraphRanges(forBlocks: controls.map(\.block))
            guard ranges.count == controls.count else { return }
            let trailing = text.bounds.width - columnInset + 3 - NoteProposalReviewMetrics.changeInset
            for (control, range) in zip(controls, ranges) {
                let size = control.view.fittingSize
                let rect = engine.rect(for: NSRange(location: range.location, length: max(range.length, 1)))
                    ?? engine.caretRect(at: range.location)
                guard let rect else { control.view.isHidden = true; continue }
                control.view.isHidden = false
                control.view.frame = NSRect(x: trailing - size.width, y: rect.midY - size.height / 2,
                                            width: size.width, height: size.height).integral
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let host = Host()
        host.onLayout = { [weak coordinator = context.coordinator] in coordinator?.positionControls() }
        context.coordinator.onDecide = onDecide
        install(in: host, coordinator: context.coordinator, offset: nil)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        context.coordinator.onDecide = onDecide
        guard context.coordinator.display != display else {
            context.coordinator.engine?.update(design: design)
            if let scroll = context.coordinator.engine?.scrollView,
               scroll.contentInsets.top != topInset || scroll.contentInsets.bottom != bottomInset {
                scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
            }
            if let text = context.coordinator.engine?.textView, text.textContainerInset.width != columnInset {
                text.textContainerInset = NSSize(width: columnInset, height: 0)
                context.coordinator.columnInset = columnInset
                context.coordinator.positionControls()
            }
            return
        }
        // A decision redraws the note as it will read; the scroll position stays.
        let offset = context.coordinator.engine?.scrollView?.contentView.bounds.origin.y
        install(in: host, coordinator: context.coordinator, offset: offset)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 300))
    }

    private func install(in host: NSView, coordinator: Coordinator, offset: CGFloat?) {
        coordinator.engine?.detachView()
        coordinator.frameObserver.map(NotificationCenter.default.removeObserver)
        coordinator.frameObserver = nil
        host.subviews.forEach { $0.removeFromSuperview() }
        let engine = NoteEditorEngine(noteID: noteID, document: display.document, readOnly: true,
                                      design: design, imageProvider: imageProvider)
        engine.applyReviewMarks(display.marks, controls: Set(display.controls.keys))
        coordinator.engine = engine
        coordinator.display = display
        coordinator.columnInset = columnInset
        let (scroll, text) = engine.makeView()
        text.textContainerInset = NSSize(width: columnInset, height: 0)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        scroll.frame = host.bounds
        scroll.autoresizingMask = [.width, .height]
        host.addSubview(scroll)
        coordinator.controls = display.controls.sorted { $0.key < $1.key }.map { block, change in
            let view = NSHostingView(rootView: NoteProposalChangeControls(change: change) { [weak coordinator] accept in
                coordinator?.onDecide(change, accept)
            })
            view.setFrameSize(view.fittingSize)
            text.addSubview(view)
            return (block, view)
        }
        text.postsFrameChangedNotifications = true
        coordinator.frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
            object: text, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.positionControls() }
        }
        coordinator.positionControls()
        DispatchQueue.main.async { [weak coordinator] in
            if let offset {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            coordinator?.positionControls()
        }
    }

    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) {
        coordinator.frameObserver.map(NotificationCenter.default.removeObserver)
        coordinator.frameObserver = nil
        coordinator.engine?.detachView()
    }
}

private struct NoteComparisonPreview: NSViewRepresentable {
    let document: NoteDocument
    let noteID: UUID
    let design: AtticDesignContext
    let imageProvider: NoteImageProviding
    let columnInset: CGFloat

    final class Coordinator {
        var engine: NoteEditorEngine?
        var document: NoteDocument?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        install(in: host, coordinator: context.coordinator, offset: 0)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        guard context.coordinator.document != document else {
            // A change of look or of the panel's width reaches the shown
            // comparison, as it reaches the note and History (H10-02).
            context.coordinator.engine?.update(design: design)
            if let text = context.coordinator.engine?.textView, text.textContainerInset.width != columnInset {
                text.textContainerInset = NSSize(width: columnInset, height: 0)
            }
            return
        }
        let offset = (host.subviews.first as? NSScrollView)?.contentView.bounds.origin.y ?? 0
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
/// text, then the bottom row left to right (All notes, then Aa while the
/// note can be formatted), and round again into the text. Every stop is
/// drawn: the text's caret, or the control's ring.
enum NotesKeyboardOrder {
    enum Stop: Hashable { case text, allNotes, format, newNote }

    static func stops(format: Bool, newNote: Bool = true) -> [Stop] {
        [.text, .allNotes] + (format ? [.format] : []) + (newNote ? [.newNote] : [])
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
            .focusEffectDisabled()
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

/// Only the two page navigation/creation buttons leave accessibility when
/// the composer takes their row. The surrounding format row must not gain an
/// accessibility modifier: doing so changes the frames it reports to AX.
private struct NotesComposerChromeAccessibility: ViewModifier {
    let size: CGSize
    @Environment(\.panelSharedChrome) private var chrome
    @Environment(\.atticControlGone) private var rowGone

    func body(content: Content) -> some View {
        if let chrome {
            Observing(chrome: chrome, size: size, rowGone: rowGone) { content }
        } else {
            content
        }
    }

    private struct Observing<Row: View>: View {
        @ObservedObject var chrome: PanelSharedChrome
        let size: CGSize
        let rowGone: Bool
        @ViewBuilder var row: () -> Row

        var body: some View {
            if chrome.plusHandedOver && rowGone {
                // Hidden AX modifiers on a native glass button still leave
                // its button node exposed inside the row's control group.
                // After the existing fade completes, retire the button view
                // itself while retaining its footprint for Aa's layout.
                Color.clear.frame(width: size.width, height: size.height)
            } else {
                row().accessibilityHidden(chrome.plusHandedOver)
            }
        }
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
