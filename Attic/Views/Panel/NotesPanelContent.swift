import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotesComposerInteractionSnapshot: Equatable {
    let isTitleFocused: Bool
    let isBodyFocused: Bool
    let isLibraryPresented: Bool
    let isImporterPresented: Bool
    let isBlockingSave: Bool

    var lockReasons: Set<PanelInteractionLockReason> {
        var reasons: Set<PanelInteractionLockReason> = []
        if isTitleFocused || isBodyFocused {
            reasons.insert(.notesEditorFocus)
        }
        if isLibraryPresented || isImporterPresented {
            reasons.insert(.notesPopover)
        }
        if isBlockingSave {
            reasons.insert(.blockingSave)
        }
        return reasons
    }
}

/// The saved-note library is contextual: while an editor is active the library
/// lives in the editor's overlay so the writing surface keeps all available
/// panel height.
struct NotesPanelContent: View {
    @ObservedObject var noteStore: NoteStore
    let noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if uiState.isComposerPresented {
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
        } else {
            savedNotes
        }
    }

    @ViewBuilder
    private var savedNotes: some View {
        let notes = noteStore.orderedNotes()

        if notes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .atticClearGlassForegroundReadability()
                Text("A quiet place for the next thought.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .atticClearGlassForegroundReadability()
                Button("New Note", action: beginNew)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("new-note-empty-state")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 28)
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(notes) { note in
                        NoteRowView(
                            noteStore: noteStore,
                            noteDraft: noteDraft,
                            uiState: uiState,
                            note: note
                        )
                    }
                }
                .padding(.horizontal, AtticStyle.horizontalPadding - 4)
                .padding(.top, 2)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.never)
            .animation(reduceMotion ? nil : AtticMotion.spring, value: notes.map(\.id))
        }
    }

    private func beginNew() {
        guard noteDraft.beginNew() else { return }
        uiState.beginAdding()
    }
}
/// A focused note remains mounted while the temporary library slides above it.
/// That preserves Cocoa selection, the body editor's scroll position, marked
/// text, undo state, and the app-owned draft while browsing saved notes.
struct NoteComposerView: View {
    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject private var noteStore: NoteStore
    @ObservedObject var uiState: PanelUIState

    /// The title participates in SwiftUI's focus system, while the wrapped
    /// NSTextView owns body focus through AppKit's responder chain. Treating
    /// the body as an unregistered `FocusState` value lets SwiftUI clear it on
    /// the next render, which made the editor surrender first responder after
    /// every draft publication.
    @FocusState private var isTitleFocused: Bool
    @State private var isBodyFocused = false
    @State private var isImporterPresented = false
    @State private var isFileTargeted = false
    @State private var isLibraryPresented = false
    @State private var isBlockingSave = false
    @State private var attachmentImportTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(noteDraft: NoteDraftController, uiState: PanelUIState) {
        self.noteDraft = noteDraft
        _noteStore = ObservedObject(wrappedValue: noteDraft.noteStore)
        self.uiState = uiState
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                editorSurface(availableHeight: proxy.size.height)
                    .allowsHitTesting(!isLibraryPresented)
                    .accessibilityHidden(isLibraryPresented)

                if isLibraryPresented {
                    SavedNotesDrawer(
                        noteStore: noteStore,
                        selectedNoteID: noteDraft.activeNoteID,
                        onSelect: selectNote,
                        onNew: beginNewNote,
                        onClose: closeLibrary
                    )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
                    .zIndex(2)
                }
            }
            .overlay {
                if isFileTargeted, !isLibraryPresented {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    Color.primary.opacity(0.32),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                )
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(
                NotesHorizontalSwipeMonitor {
                    withAnimation(reduceMotion ? nil : AtticMotion.spring) {
                        if isLibraryPresented {
                            closeLibrary()
                        } else {
                            openLibrary()
                        }
                    }
                }
            )
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, !isLibraryPresented else { return false }
                importURLs(files, [])
                return true
            } isTargeted: { targeted in
                isFileTargeted = targeted && !isLibraryPresented
            }
        }
        .frame(minHeight: 230)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleImporterResult
        )
        .onAppear {
            syncComposerInteractionLocks()
            DispatchQueue.main.async { focusBody() }
        }
        .onChange(of: isTitleFocused) { _, _ in
            syncComposerInteractionLocks()
        }
        .onChange(of: isBodyFocused) { _, _ in
            syncComposerInteractionLocks()
        }
        .onChange(of: isLibraryPresented) { _, _ in
            syncComposerInteractionLocks()
        }
        .onChange(of: isImporterPresented) { _, _ in
            syncComposerInteractionLocks()
        }
        .onChange(of: isBlockingSave) { _, _ in
            syncComposerInteractionLocks()
        }
        .onDisappear {
            attachmentImportTask?.cancel()
            // Shared section/panel controllers flush before their transitions.
            // This is the final durability boundary, never an implicit discard.
            _ = withBlockingSave { noteDraft.flush() }
            clearComposerInteractionLocks()
        }
        .animation(reduceMotion ? nil : AtticMotion.quick, value: noteDraft.conflict)
        .animation(reduceMotion ? nil : AtticMotion.quick, value: isFileTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-note-workspace")
    }

    private func editorSurface(availableHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            noteHeader

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    AttachmentAwareTextEditor(
                        text: $noteDraft.body,
                        isFileTargeted: $isFileTargeted,
                        isFocused: isBodyFocused,
                        session: noteDraft.editorSession,
                        onFocusChange: updateBodyFocus,
                        onImportFiles: importURLs,
                        onImportError: noteStore.setAttachmentError
                    )
                    .frame(height: editorHeight(for: availableHeight))
                    .padding(.horizontal, 2)

                    NoteAttachmentTray(
                        noteStore: noteStore,
                        noteDraft: noteDraft,
                        onCancelImport: cancelAttachmentImport,
                        onImportFiles: importURLs
                    )

                    if let conflictMessage = noteDraft.conflictMessage {
                        conflictControls(message: conflictMessage)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            bottomComposer
        }
    }

    private var noteHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Untitled note", text: $noteDraft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.96))
                .atticClearGlassForegroundReadability()
                .focused($isTitleFocused)
                .onChange(of: isTitleFocused) { _, focused in
                    if focused { isBodyFocused = false }
                }
                .onSubmit(focusBody)
                .onExitCommand {
                    // Escape only releases the title field. It never saves,
                    // closes, or discards the durable draft.
                    isTitleFocused = false
                }
                .accessibilityIdentifier("note-title")

            HStack(spacing: 5) {
                Circle()
                    .fill(saveStatusColor)
                    .frame(width: 4, height: 4)
                    .atticClearGlassForegroundReadability()
                Text(saveStatus)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .atticClearGlassForegroundReadability()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(saveStatus)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private var bottomComposer: some View {
        HStack(spacing: 2) {
            Button(action: beginNewNote) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .atticClearGlassForegroundReadability()
                    .frame(width: AtticStyle.composerActionSize, height: AtticStyle.composerActionSize)
                    .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("New note")
            .accessibilityLabel("New note")
            .accessibilityIdentifier("new-note-from-editor")

            Button {
                isImporterPresented = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .medium))
                    .atticClearGlassForegroundReadability()
                    .frame(width: AtticStyle.composerActionSize, height: AtticStyle.composerActionSize)
                    .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isImporting)
            .help("Attach files")
            .accessibilityLabel("Attach files")
            .accessibilityIdentifier("add-note-attachment")

            Button(action: openLibrary) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 10, weight: .medium))
                    Text(libraryLabel)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.primary.opacity(0.74))
                .atticClearGlassForegroundReadability()
                .frame(maxWidth: .infinity)
                .frame(height: AtticStyle.entryControlHeight)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Browse saved notes")
            .accessibilityLabel(libraryLabel)
            .accessibilityIdentifier("browse-saved-notes")

            Button(action: saveInPlace) {
                Image(systemName: noteDraft.isDirty ? "arrow.up" : "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(noteDraft.canPersist ? 0.92 : 0.34))
                    .atticClearGlassForegroundReadability()
                    .frame(width: AtticStyle.composerActionSize, height: AtticStyle.composerActionSize)
                    .background(
                        Color.primary.opacity(noteDraft.canPersist ? 0.08 : 0.035),
                        in: Circle()
                    )
                    .overlay {
                        Circle().stroke(Color.primary.opacity(0.07), lineWidth: 0.75)
                    }
                    .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!noteDraft.canPersist)
            .help("Save note")
            .accessibilityLabel("Save note")
            .accessibilityIdentifier("save-note")
        }
        .padding(.horizontal, 2)
        .frame(height: AtticStyle.composerControlHeight)
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
        .contentShape(Capsule(style: .continuous))
        .padding(.horizontal, 2)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note controls")
        .accessibilityIdentifier("note-entry-bar")
    }

    private var libraryLabel: String {
        let count = noteStore.notes.count
        return count == 1 ? "1 saved note" : "\(count) saved notes"
    }

    private var isImporting: Bool {
        if case .importing = noteStore.attachmentImportState { return true }
        return false
    }

    private var saveStatusColor: Color {
        if noteDraft.conflict != nil { return .orange }
        if noteDraft.isDirty { return Color.primary.opacity(0.42) }
        return Color.primary.opacity(0.28)
    }

    private var saveStatus: String {
        if noteDraft.conflict != nil { return "Needs your attention" }
        if noteDraft.isDirty { return "Saving…" }
        guard let noteID = noteDraft.activeNoteID,
              let note = noteStore.notes.first(where: { $0.id == noteID }) else {
            return "New note"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: note.updatedAt, relativeTo: Date())
        return relative == "now" ? "Saved just now" : "Saved \(relative)"
    }

    private func editorHeight(for availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.28, 96), 170)
    }

    private func updateBodyFocus(_ isFocused: Bool) {
        if isFocused {
            isTitleFocused = false
        }
        isBodyFocused = isFocused
    }

    private func focusBody() {
        isTitleFocused = false
        isBodyFocused = true
    }

    private func openLibrary() {
        isTitleFocused = false
        isBodyFocused = false
        withAnimation(reduceMotion ? nil : AtticMotion.spring) {
            isLibraryPresented = true
        }
    }

    private func closeLibrary() {
        withAnimation(reduceMotion ? nil : AtticMotion.spring) {
            isLibraryPresented = false
        }
        DispatchQueue.main.async { focusBody() }
    }

    private func beginNewNote() {
        guard withBlockingSave({ noteDraft.beginNew() }) else { return }
        uiState.beginAdding()
        isLibraryPresented = false
        DispatchQueue.main.async { focusBody() }
    }

    private func selectNote(_ note: NoteItem) {
        guard withBlockingSave({ noteDraft.beginEditing(note) }) else { return }
        uiState.beginEditingNote(note)
        isLibraryPresented = false
        DispatchQueue.main.async { focusBody() }
    }

    private func saveInPlace() {
        _ = withBlockingSave { noteDraft.flush() }
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            importURLs(urls, [])
        case let .failure(error):
            let cocoaError = error as NSError
            guard cocoaError.domain != NSCocoaErrorDomain
                    || cocoaError.code != CocoaError.Code.userCancelled.rawValue else {
                return
            }
            noteStore.setAttachmentError(
                "Unable to choose attachments: \(error.localizedDescription)"
            )
        }
    }

    private func importURLs(_ urls: [URL], _ cleanupDirectories: [URL]) {
        guard !urls.isEmpty else {
            removeTemporaryDirectories(cleanupDirectories)
            return
        }
        guard !isImporting else {
            removeTemporaryDirectories(cleanupDirectories)
            noteStore.setAttachmentError(
                "Finish or cancel the current attachment import before adding more files."
            )
            return
        }
        guard let request = withBlockingSave({
            noteDraft.prepareAttachmentImport(from: urls)
        }) else {
            removeTemporaryDirectories(cleanupDirectories)
            return
        }

        attachmentImportTask = Task { @MainActor in
            defer {
                removeTemporaryDirectories(cleanupDirectories)
                attachmentImportTask = nil
            }
            let outcome = await noteStore.importAttachments(request)
            let completion = noteDraft.completeAttachmentImport(
                outcome,
                for: request
            )
            if case let .adopted(noteID) = completion {
                uiState.editingNoteID = noteID
            }
        }
    }

    private func cancelAttachmentImport() {
        attachmentImportTask?.cancel()
    }

    private func removeTemporaryDirectories(_ directories: [URL]) {
        guard !directories.isEmpty else { return }
        Task.detached(priority: .utility) {
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private var interactionSnapshot: NotesComposerInteractionSnapshot {
        NotesComposerInteractionSnapshot(
            isTitleFocused: isTitleFocused,
            isBodyFocused: isBodyFocused,
            isLibraryPresented: isLibraryPresented,
            isImporterPresented: isImporterPresented,
            isBlockingSave: isBlockingSave
        )
    }

    private func syncComposerInteractionLocks() {
        let reasons = interactionSnapshot.lockReasons
        for reason in [
            PanelInteractionLockReason.notesEditorFocus,
            .notesPopover,
            .blockingSave
        ] {
            uiState.setInteractionLock(reason, isActive: reasons.contains(reason))
        }
    }

    private func clearComposerInteractionLocks() {
        uiState.setInteractionLock(.notesEditorFocus, isActive: false)
        uiState.setInteractionLock(.notesPopover, isActive: false)
        uiState.setInteractionLock(.blockingSave, isActive: false)
    }

    private func withBlockingSave<Result>(
        _ operation: () -> Result
    ) -> Result {
        isBlockingSave = true
        syncComposerInteractionLocks()
        defer {
            isBlockingSave = false
            syncComposerInteractionLocks()
        }
        return operation()
    }

    private func conflictControls(message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.orange)
                .atticClearGlassForegroundReadability()
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                switch noteDraft.conflict {
                case .remoteChange:
                    conflictButton("Use Remote", identifier: "use-remote-note") {
                        _ = noteDraft.useRemoteVersion()
                    }
                    conflictButton("Keep Mine", identifier: "keep-local-note") {
                        _ = noteDraft.overwriteRemoteVersion()
                    }
                    conflictButton("Save Copy", identifier: "save-note-copy") {
                        _ = noteDraft.saveAsNew()
                    }
                case .missingOriginal:
                    conflictButton("Save as New", identifier: "recover-note-as-new") {
                        _ = noteDraft.saveAsNew()
                    }
                    conflictButton(
                        "Discard",
                        role: .destructive,
                        identifier: "discard-note-draft"
                    ) {
                        noteDraft.discardDraft()
                        uiState.endAdding()
                    }
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-conflict")
    }

    private func conflictButton(
        _ title: String,
        role: ButtonRole? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, role: role, action: action)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .accessibilityIdentifier(identifier)
    }
}

private struct SavedNotesDrawer: View {
    @ObservedObject var noteStore: NoteStore
    let selectedNoteID: UUID?
    let onSelect: (NoteItem) -> Void
    let onNew: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved Notes")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .atticClearGlassForegroundReadability()
                    Text(summary)
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(.secondary)
                        .atticClearGlassForegroundReadability()
                }

                Spacer()

                Button(action: onNew) {
                    Image(systemName: "square.and.pencil")
                        .atticClearGlassForegroundReadability()
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New note")
                .accessibilityLabel("New note")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .atticClearGlassForegroundReadability()
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Return to note")
                .accessibilityLabel("Return to note")
                .accessibilityIdentifier("close-saved-notes")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .opacity(0.28)

            if noteStore.notes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.secondary)
                        .atticClearGlassForegroundReadability()
                    Text("No saved notes yet")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .atticClearGlassForegroundReadability()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(noteStore.orderedNotes()) { note in
                            SavedNoteRow(
                                noteStore: noteStore,
                                note: note,
                                isSelected: note.id == selectedNoteID,
                                onSelect: { onSelect(note) }
                            )
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
            }

            Button(action: onClose) {
                Label("Return to writing", systemImage: "arrow.left")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .atticClearGlassForegroundReadability()
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.045), in: Capsule())
            .padding(10)
            .accessibilityIdentifier("return-to-writing")
        }
        .atticGlassControl(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            interactive: false
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
        .padding(2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-notes-drawer")
    }

    private var summary: String {
        let count = noteStore.notes.count
        return count == 1 ? "1 note · swipe to return" : "\(count) notes · swipe to return"
    }
}

private struct SavedNoteRow: View {
    @ObservedObject var noteStore: NoteStore
    let note: NoteItem
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @State private var isConfirmingDeletion = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .atticClearGlassForegroundReadability()
                    HStack(spacing: 5) {
                        Text(preview)
                            .lineLimit(1)
                        if attachmentCount > 0 {
                            Label("\(attachmentCount)", systemImage: "paperclip")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .atticClearGlassForegroundReadability()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Open", systemImage: "arrow.right", action: onSelect)
                Button("Copy", systemImage: "doc.on.doc", action: copyNote)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isConfirmingDeletion = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .atticClearGlassForegroundReadability()
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0.38)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            Color.primary.opacity(isSelected ? 0.105 : (isHovering ? 0.06 : 0.025)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(isSelected ? 0.13 : 0.04), lineWidth: 0.75)
        }
        .onHover { isHovering = $0 }
        .alert("Delete note?", isPresented: $isConfirmingDeletion) {
            Button("Delete", role: .destructive) {
                _ = noteStore.delete(note)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the local note and its attachments.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayTitle), \(preview)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var displayTitle: String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return note.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? noteStore.attachments(for: note.id).first?.originalFilename
            ?? "Untitled note"
    }

    private var preview: String {
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            return body.replacingOccurrences(of: "\n", with: " ")
        }
        return attachmentCount == 1 ? "1 attachment" : "\(attachmentCount) attachments"
    }

    private var attachmentCount: Int {
        noteStore.attachments(for: note.id).count
    }

    private func copyNote() {
        let text = note.title.isEmpty ? note.body : "\(note.title)\n\n\(note.body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct NoteRowView: View {
    @ObservedObject var noteStore: NoteStore
    let noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    let note: NoteItem

    @State private var isHovering = false
    @State private var isConfirmingDeletion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: beginEditing) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .atticClearGlassForegroundReadability()
                    Text(preview)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.secondary)
                        .atticClearGlassForegroundReadability()
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit note, \(displayTitle)")
            .accessibilityIdentifier("edit-note-\(note.id.uuidString)")

            Menu {
                Button("Edit", systemImage: "pencil", action: beginEditing)
                Button("Copy", systemImage: "doc.on.doc", action: copyNote)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isConfirmingDeletion = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .atticClearGlassForegroundReadability()
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0.38)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            Color.primary.opacity(isHovering ? 0.06 : 0.025),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : AtticMotion.quick) {
                isHovering = hovering
            }
        }
        .alert("Delete note?", isPresented: $isConfirmingDeletion) {
            Button("Delete", role: .destructive, action: deleteNote)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the local note and its attachments.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-row-\(note.id.uuidString)")
    }

    private func beginEditing() {
        guard noteDraft.beginEditing(note) else { return }
        uiState.beginEditingNote(note)
    }

    private func deleteNote() {
        guard noteStore.delete(note) else { return }
        noteDraft.discardDeletedNote(note.id)
        if uiState.editingNoteID == note.id {
            uiState.endAdding()
        }
    }

    private var displayTitle: String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return note.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? noteStore.attachments(for: note.id).first?.originalFilename
            ?? "Untitled note"
    }

    private var preview: String {
        let text = note.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !text.isEmpty { return text }

        let count = noteStore.attachments(for: note.id).count
        if count == 1 { return "1 attachment" }
        if count > 1 { return "\(count) attachments" }
        return "No additional text"
    }

    private func copyNote() {
        let text = note.title.isEmpty ? note.body : "\(note.title)\n\n\(note.body)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Observes horizontal trackpad scrolling inside the Notes workspace without
/// consuming it. A single deliberate swipe toggles the contextual library.
private struct NotesHorizontalSwipeMonitor: NSViewRepresentable {
    let onSwipe: () -> Void

    func makeNSView(context: Context) -> NotesHorizontalSwipeView {
        NotesHorizontalSwipeView(onSwipe: onSwipe)
    }

    func updateNSView(_ nsView: NotesHorizontalSwipeView, context: Context) {
        nsView.onSwipe = onSwipe
    }
}

private final class NotesHorizontalSwipeView: NSView {
    var onSwipe: () -> Void
    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var hasTriggered = false

    init(onSwipe: @escaping () -> Void) {
        self.onSwipe = onSwipe
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitorIfNeeded()
        }
    }

    deinit {
        removeMonitor()
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            self?.observe(event)
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func observe(_ event: NSEvent) {
        guard event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        if event.hasPreciseScrollingDeltas,
           !event.phase.isEmpty,
           let panel = event.window as? AtticPanel,
           PanelTrackpadDismissTracker.isTowardDockedSide(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice,
                dockedCorner: panel.trackpadDismissCorner
           ) {
            accumulatedX = 0
            hasTriggered = false
            return
        }

        if event.phase == .began {
            accumulatedX = 0
            hasTriggered = false
        }

        let horizontal = CGFloat(event.scrollingDeltaX)
        let vertical = CGFloat(event.scrollingDeltaY)
        if abs(horizontal) > abs(vertical) * 1.15 {
            accumulatedX += horizontal
        }

        if abs(accumulatedX) >= 42, !hasTriggered {
            hasTriggered = true
            DispatchQueue.main.async { [weak self] in self?.onSwipe() }
        }

        if event.phase == .ended
            || event.phase == .cancelled
            || event.momentumPhase == .ended {
            accumulatedX = 0
            hasTriggered = false
        }
    }
}
