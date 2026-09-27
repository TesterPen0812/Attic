import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Phase 2 Notes page, slice 1: deliberately plain. The note fills the
/// page; the bottom row holds All notes, the status slot, Insert and New
/// note. Structure, the `/` menu, the ⋯ menu and the real All notes arrive
/// in later slices.
struct NotesEditorPage: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let layout: PanelPageLayout
    /// Set when the switch is off: All notes returns to the old page.
    var exitToOldPage: (() -> Void)?

    @Environment(\.atticDesign) private var design
    @State private var isImporterPresented = false

    private var bottomRowHeight: CGFloat { AtticControlSize.panelButton.height }
    private var topInset: CGFloat { layout.headerBottom + 8 }
    private var bottomInset: CGFloat { layout.chromeInsets.bottom + bottomRowHeight + 12 }

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomRow
                .padding(.leading, layout.chromeInsets.leading)
                .padding(.trailing, layout.chromeInsets.trailing)
                .padding(.bottom, layout.chromeInsets.bottom)
        }
        .onAppear {
            controller.update(design: design)
            controller.start()
            controller.panelDidShow()
        }
        .onChange(of: design) { _, newValue in controller.update(design: newValue) }
        .onChange(of: controller.legacyNoteID) { _, id in openLegacy(id) }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { controller.importImages(urls) }
        }
        .accessibilityIdentifier("notes-editor-page")
    }

    @ViewBuilder
    private var content: some View {
        if controller.isLibraryPresented {
            NotesPlainLibrary(noteStore: noteStore, failedDrafts: controller.failedDrafts,
                              selectedID: controller.active?.noteID ?? controller.legacyNoteID,
                              onOpen: { id in
                                  if controller.open(noteID: id) { controller.dismissLibrary() }
                              }, onOpenDraft: { id in _ = controller.openFailedDraft(sessionID: id) })
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.horizontal, layout.contentInsets.leading)
        } else if let legacyID = controller.legacyNoteID, noteDraft.activeNoteID == legacyID {
            // A note not yet in the new format keeps the old editor.
            NoteComposerView(noteDraft: noteDraft, uiState: uiState,
                             topContentInset: topInset, bottomContentInset: bottomInset)
                .padding(.horizontal, layout.contentInsets.leading)
        } else if let session = controller.active {
            NoteEditorRepresentable(session: session, topInset: topInset, bottomInset: bottomInset,
                                    horizontalInset: layout.contentInsets.leading)
                .id(ObjectIdentifier(session.engine))
                .accessibilityIdentifier("note-editor")
        } else {
            Color.clear
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            AtticRaisedButton(systemName: controller.isLibraryPresented ? "chevron.left" : "rectangle.stack",
                              label: controller.isLibraryPresented ? "Back" : "All notes",
                              help: controller.isLibraryPresented ? "Back (⇧⌘L)" : "All notes (⇧⌘L)") {
                toggleLibrary()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .accessibilityIdentifier("notes-all-notes")
            Spacer(minLength: 0)
            NoteStatusSlot(controller: controller, noteStore: noteStore, session: controller.active)
            Spacer(minLength: 0)
            if let session = controller.active, !session.isReadOnly, !controller.isLibraryPresented {
                insertMenu(session)
            }
            AtticRaisedButton(systemName: "square.and.pencil", label: "New note", help: "New note (⌘N)") {
                if controller.newNote() { controller.isLibraryPresented = false }
            }
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("notes-new-note")
        }
        .frame(height: bottomRowHeight)
    }

    private func insertMenu(_ session: NoteSession) -> some View {
        let radius = AtticRadius.control(height: AtticControlSize.panelButton.height)
        return Menu {
            Button("Checklist") { session.engine.toggleChecklistLine() }
            Button("Image…") { isImporterPresented = true }
            Button("Today’s Date") { session.engine.insertDate(NoteDay(date: Date())) }
            Button("Tomorrow’s Date") {
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                session.engine.insertDate(NoteDay(date: tomorrow))
            }
        } label: {
            AtticIcon(systemName: "plus", size: AtticControlSize.raisedGlyph, weight: AtticIconWeight.outline, ink: .icon)
                .frame(width: AtticControlSize.panelButton.width, height: AtticControlSize.panelButton.height)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: radius))
        .fixedSize()
        .help("Insert")
        .accessibilityLabel("Insert")
        .accessibilityIdentifier("notes-insert")
    }

    private func toggleLibrary() {
        if let exitToOldPage {
            exitToOldPage()
            return
        }
        if controller.isLibraryPresented {
            controller.dismissLibrary()
        } else {
            _ = controller.showLibrary()
        }
    }

    private func openLegacy(_ id: UUID?) {
        guard let id, let note = noteStore.note(withID: id) else { return }
        if noteDraft.beginEditing(note) { uiState.beginEditingNote(note) }
    }
}

/// The status slot shows the most urgent state and keeps the rest in a
/// keyboard-accessible details pop-over. Nothing appears when all is well.
private struct NoteStatusSlot: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var noteStore: NoteStore
    let session: NoteSession?

    var body: some View {
        if let session {
            SessionSlot(controller: controller, store: noteStore, session: session)
        }
    }

    private struct SessionSlot: View {
        @ObservedObject var controller: NotesPageController
        @ObservedObject var store: NoteStore
        @ObservedObject var session: NoteSession
        @State private var showingProposal = false
        @State private var showingDetails = false

        var body: some View {
            let items = controller.statusItems(for: session)
            HStack(spacing: 4) {
                if let primary = items.first {
                    Button { showingDetails = true } label: {
                        AtticText(verbatim: primary.label, style: .rowMeta, ink: .heading, truncates: true)
                    }
                    .buttonStyle(.plain)
                    .help(primary.explanation ?? primary.label)
                    .accessibilityIdentifier("notes-status-primary")
                    if items.count > 1 {
                        Button("+\(items.count - 1)") { showingDetails = true }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(items.count - 1) more note statuses")
                            .accessibilityIdentifier("notes-status-more")
                    }
                }
            }
            .frame(maxWidth: 200)
            .popover(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        VStack(alignment: .leading, spacing: 4) {
                            AtticText(verbatim: item.label, style: .rowMeta, ink: .heading)
                            if let explanation = item.explanation {
                                AtticText(verbatim: explanation, style: .rowMeta, ink: .helper)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            actions(for: item)
                        }
                    }
                }
                .padding(16)
                .frame(width: 280)
                .accessibilityIdentifier("notes-status-details")
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

        @ViewBuilder
        private func actions(for item: NoteStatusItem) -> some View {
            switch item {
            case .onlyInMemory:
                HStack {
                    Button("Retry", action: controller.retry)
                    Button("Copy Text", action: controller.copyActiveText)
                        .accessibilityIdentifier("notes-copy-text")
                }
            case .notSaved:
                Button("Retry", action: controller.retry)
            case .changedElsewhere, .deletedElsewhere:
                HStack {
                    Button("Keep as new note") { _ = controller.keepAsNewNote() }
                        .accessibilityIdentifier("notes-keep-as-new")
                    Button("Review") { showingDetails = false; showingProposal = true }
                        .accessibilityIdentifier("notes-review-conflict")
                }
            case .proposal:
                Button("Review") { showingDetails = false; showingProposal = true }
                    .accessibilityIdentifier("notes-agent-has-changes")
            case .importing:
                Button("Cancel Batch", action: controller.cancelActiveImport)
                    .accessibilityIdentifier("notes-cancel-import")
            case .readOnly:
                EmptyView()
            case .notice:
                Button("Dismiss") { session.notice = nil }
                    .accessibilityIdentifier("notes-notice-dismiss")
            }
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

/// All notes, plain (the real library is slice 4).
private struct NotesPlainLibrary: View {
    @ObservedObject var noteStore: NoteStore
    let failedDrafts: [NoteSession]
    let selectedID: UUID?
    let onOpen: (UUID) -> Void
    let onOpenDraft: (UUID) -> Void

    var body: some View {
        let notes = noteStore.orderedNotes()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                AtticText(verbatim: String(localized: "All notes"), style: .panelHeading, ink: .heading)
                    .padding(.bottom, 6)
                if notes.isEmpty {
                    if failedDrafts.isEmpty {
                        AtticText(verbatim: String(localized: "No notes yet"), style: .body, ink: .helper)
                    }
                }
                ForEach(failedDrafts) { draft in
                    let status = switch draft.problem {
                    case .some(.onlyInMemory): String(localized: "Only in memory")
                    case .some(.changedElsewhere): String(localized: "Changed elsewhere")
                    case .some(.deletedElsewhere): String(localized: "Deleted elsewhere")
                    default: String(localized: "Not saved · Recovery copy")
                    }
                    Button { onOpenDraft(draft.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            AtticText(verbatim: draft.engine.document().title.isEmpty ? String(localized: "Untitled draft")
                                      : draft.engine.document().title, style: .rowTitle, ink: .heading, truncates: true)
                            AtticText(verbatim: status,
                                      style: .rowMeta, ink: .helper)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notes-failed-draft-row")
                }
                ForEach(notes) { note in
                    Button { onOpen(note.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            AtticText(verbatim: note.title.isEmpty ? String(localized: "Untitled note") : note.title,
                                      style: .rowTitle, ink: .heading, truncates: true)
                            AtticText(verbatim: note.updatedAt.formatted(date: .abbreviated, time: .shortened)
                                      + (note.usesDocumentFormat ? "" : " · " + String(localized: "old editor")),
                                      style: .rowMeta, ink: .helper)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notes-library-row")
                    .accessibilityAddTraits(note.id == selectedID ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// Hosts the session's text view. The view is made per appearance and
/// released on dismantle; the text, caret and undo history stay in the
/// session.
struct NoteEditorRepresentable: NSViewRepresentable {
    let session: NoteSession
    let topInset: CGFloat
    let bottomInset: CGFloat
    let horizontalInset: CGFloat

    final class Coordinator {
        var engine: NoteEditorEngine?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let engine = session.engine
        context.coordinator.engine = engine
        let (scrollView, textView) = engine.makeView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        textView.textContainerInset = NSSize(width: horizontalInset, height: 8)
        let selection = session.selection
        DispatchQueue.main.async {
            let length = engine.textStorage.length
            textView.setSelectedRange(NSRange(location: min(selection.location, length),
                                              length: min(selection.length, max(0, length - selection.location))))
            textView.scrollRangeToVisible(textView.selectedRange())
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: session.scrollOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let insets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        if scrollView.contentInsets.top != insets.top || scrollView.contentInsets.bottom != insets.bottom {
            scrollView.contentInsets = insets
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if coordinator.engine?.scrollView === scrollView { coordinator.engine?.detachView() }
    }
}
