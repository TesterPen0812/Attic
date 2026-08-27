import AppKit
import SwiftUI

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

/// Edits the app-owned draft. The draft outlives this SwiftUI view, so a panel
/// transition or model-context refresh cannot discard pending text.
struct NoteComposerView: View {
    private enum FocusedField: Hashable {
        case title
        case body
    }

    @ObservedObject var noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState

    @FocusState private var focusedField: FocusedField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                TextField("Title (optional)", text: $noteDraft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .focused($focusedField, equals: .title)
                    .onSubmit { focusedField = .body }
                    .onExitCommand(perform: finishKeyboardInteraction)
                    .accessibilityIdentifier("note-title")

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

            TextEditor(text: $noteDraft.body)
                .font(.system(size: 12, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, idealHeight: 78, maxHeight: 90)
                .focused($focusedField, equals: .body)
                .onExitCommand(perform: finishKeyboardInteraction)
                .accessibilityIdentifier("note-body")

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
        .onChange(of: focusedField) { previousField, newField in
            if previousField != nil, newField == nil {
                _ = noteDraft.flush()
            }
        }
        .onDisappear { _ = noteDraft.flush() }
        .animation(reduceMotion ? nil : AtticMotion.quick, value: noteDraft.conflict)
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

    private func finishKeyboardInteraction() {
        focusedField = nil
        _ = noteDraft.flush()
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
            Text("This permanently removes the note from synced devices.")
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
        return note.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? "Untitled note"
    }

    private var preview: String {
        let bodyLines = note.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !bodyLines.isEmpty else { return "No additional text" }
        if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rest = bodyLines.dropFirst().joined(separator: " ")
            return rest.isEmpty ? "No additional text" : rest
        }
        return bodyLines.first ?? "No additional text"
    }

    private func copyNote() {
        let text = note.title.isEmpty ? note.body : "\(note.title)\n\n\(note.body)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
