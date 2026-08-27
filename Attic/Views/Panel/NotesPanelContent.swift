import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The notes surface shown in the panel when the Notes section is selected.
struct NotesPanelContent: View {
    @ObservedObject var noteStore: NoteStore
    let noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notes = noteStore.orderedNotes()

        Group {
            if notes.isEmpty {
                VStack(spacing: 5) {
                    Text(uiState.selectedSection.emptyStateTitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Text("Write a note and it stays close by.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                ScrollView {
                    LazyVStack(spacing: AtticStyle.taskSpacing) {
                        ForEach(notes) { note in
                            NoteRowView(
                                noteStore: noteStore,
                                noteDraft: noteDraft,
                                uiState: uiState,
                                note: note
                            )
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .scale(scale: 0.96).combined(with: .opacity)
                                )
                            )
                        }
                    }
                    .padding(.horizontal, AtticStyle.horizontalPadding - 4)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.never)
            }
        }
        .animation(reduceMotion ? nil : AtticMotion.spring, value: notes.map(\.id))
    }
}

/// Edits the app-owned draft. The AppKit-backed body editor keeps Cocoa text
/// selection, marked-text, undo, link, and keyboard behavior while routing
/// actual Finder items into the attachment transaction before generic strings.
struct NoteComposerView: View {
    private enum FocusedField: Hashable {
        case title
        case body
    }

    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var uiState: PanelUIState

    @FocusState private var focusedField: FocusedField?
    @State private var isImporterPresented = false
    @State private var isFileTargeted = false
    @State private var attachmentImportTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TextField("Title (optional)", text: $noteDraft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .focused($focusedField, equals: .title)
                    .onSubmit { focusedField = .body }
                    .onExitCommand {
                        // Escape is not an implicit save, close, or discard.
                    }
                    .accessibilityIdentifier("note-title")

                Button {
                    isImporterPresented = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.05), in: Circle())
                .disabled(isImporting)
                .help("Attach files")
                .accessibilityLabel("Attach files")
                .accessibilityIdentifier("add-note-attachment")

                Button(action: saveAndClose) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(
                            noteDraft.canPersist
                                ? Color.accentColor
                                : Color.secondary.opacity(0.3),
                            in: Circle()
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!noteDraft.canPersist)
                .help(saveLabel)
                .accessibilityLabel(saveLabel)
                .accessibilityIdentifier("save-note")
            }

            AttachmentAwareTextEditor(
                text: $noteDraft.body,
                isFileTargeted: $isFileTargeted,
                isFocused: focusedField == .body,
                onFocusChange: updateBodyFocus,
                onImportFiles: importURLs,
                onImportError: noteStore.setAttachmentError
            )
            .frame(minHeight: 60, idealHeight: 78, maxHeight: 90)
            .overlay {
                if isFileTargeted {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.055))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    Color.accentColor.opacity(0.38),
                                    lineWidth: 1
                                )
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : AtticMotion.quick, value: isFileTargeted)

            NoteAttachmentTray(
                noteStore: noteStore,
                noteDraft: noteDraft,
                onCancelImport: cancelAttachmentImport
            )

            if let conflictMessage = noteDraft.conflictMessage {
                conflictControls(message: conflictMessage)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .onAppear {
            DispatchQueue.main.async { focusedField = .body }
        }
        .onDisappear {
            // Section/panel controllers flush before their transitions. This is
            // a final durability boundary, not a request to discard the draft.
            _ = noteDraft.flush()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
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
        .animation(reduceMotion ? nil : AtticMotion.quick, value: noteDraft.conflict)
    }

    private var isImporting: Bool {
        if case .importing = noteStore.attachmentImportState { return true }
        return false
    }

    private func updateBodyFocus(_ isFocused: Bool) {
        if isFocused {
            focusedField = .body
        } else if focusedField == .body {
            focusedField = nil
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
        guard noteDraft.flush() else {
            removeTemporaryDirectories(cleanupDirectories)
            return
        }

        let previousNoteID = noteDraft.activeNoteID
        attachmentImportTask = Task { @MainActor in
            defer {
                removeTemporaryDirectories(cleanupDirectories)
                attachmentImportTask = nil
            }
            let noteID = await noteStore.importAttachments(
                from: urls,
                noteID: previousNoteID
            )
            guard !Task.isCancelled else { return }
            if previousNoteID == nil,
               noteDraft.isActive,
               let noteID {
                noteDraft.adoptAttachmentOnlyNote(noteID)
                uiState.reconcileNoteEditor(
                    activeNoteID: noteID,
                    isActive: true
                )
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

    private func conflictControls(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                switch noteDraft.conflict {
                case .remoteChange:
                    conflictButton(
                        "Use Remote",
                        identifier: "use-remote-note",
                        action: useRemoteVersion
                    )
                    conflictButton(
                        "Keep Mine",
                        identifier: "keep-local-note",
                        action: overwriteRemoteVersion
                    )
                    conflictButton(
                        "Save Copy",
                        identifier: "save-note-copy",
                        action: saveAsNew
                    )
                case .missingOriginal:
                    conflictButton(
                        "Save as New",
                        identifier: "recover-note-as-new",
                        action: saveAsNew
                    )
                    conflictButton(
                        "Discard",
                        role: .destructive,
                        identifier: "discard-note-draft",
                        action: discardDraft
                    )
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(7)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
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

    private var saveLabel: String {
        noteDraft.activeNoteID == nil ? "Add note" : "Save note"
    }

    private func saveAndClose() {
        guard noteDraft.close() else { return }
        uiState.endNoteEditing()
    }

    private func useRemoteVersion() {
        _ = noteDraft.useRemoteVersion()
    }

    private func overwriteRemoteVersion() {
        _ = noteDraft.overwriteRemoteVersion()
    }

    private func saveAsNew() {
        _ = noteDraft.saveAsNew()
    }

    private func discardDraft() {
        noteDraft.discardDraft()
        uiState.endNoteEditing()
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
                    Text(preview)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0.38)
            .help("Edit note")
            .accessibilityLabel("Edit note")
            .accessibilityIdentifier("note-actions-\(note.id.uuidString)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(minHeight: AtticStyle.rowHeight)
        .background(
            Color.primary.opacity(isHovering ? 0.055 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
            Text("This permanently removes the note and its attachments from synced devices.")
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
            uiState.endNoteEditing()
        }
    }

    private var displayTitle: String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let firstBodyLine = note.body
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return firstBodyLine
        }
        return noteStore.attachments(for: note.id).first?.originalFilename
            ?? "Untitled note"
    }

    private var preview: String {
        let bodyLines = note.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !bodyLines.isEmpty {
            if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rest = bodyLines.dropFirst().joined(separator: " ")
                if !rest.isEmpty { return rest }
            } else if let first = bodyLines.first {
                return first
            }
        }

        let count = noteStore.attachments(for: note.id).count
        if count == 1 { return "1 attachment" }
        if count > 1 { return "\(count) attachments" }
        return "No additional text"
    }

    private func copyNote() {
        let text = note.title.isEmpty ? note.body : "\(note.title)\n\n\(note.body)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
