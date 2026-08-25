import AppKit
import SwiftUI

/// The notes surface shown in the panel when the Notes section is selected.
/// Add and edit both reuse the composer slot so the panel reserves height for
/// a multi-line body instead of clipping an inline editor.
struct NotesPanelContent: View {
    @ObservedObject var noteStore: NoteStore
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
                            NoteRowView(noteStore: noteStore, uiState: uiState, note: note)
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

/// Single field for the note title (optional) plus a multi-line body. When
/// `uiState.editingNoteID` is set the composer edits that note; otherwise it
/// creates a new one.
struct NoteComposerView: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var uiState: PanelUIState

    @State private var title = ""
    @State private var bodyText = ""
    @FocusState private var isBodyFocused: Bool

    private var editingNote: NoteItem? {
        guard let id = uiState.editingNoteID else { return nil }
        return noteStore.notes.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                TextField("Title (optional)", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .onSubmit(save)
                    .onExitCommand(perform: cancel)
                    .accessibilityIdentifier("note-title")

                Button(action: save) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(canSave ? Color.accentColor : Color.secondary.opacity(0.3), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .help(saveLabel)
                .accessibilityLabel(saveLabel)
                .accessibilityIdentifier("save-note")
            }

            TextEditor(text: $bodyText)
                .font(.system(size: 12, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, idealHeight: 78, maxHeight: 90)
                .focused($isBodyFocused)
                .accessibilityIdentifier("note-body")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .onAppear { load() }
        .onChange(of: uiState.editingNoteID) { _, _ in load() }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var saveLabel: String { editingNote == nil ? "Add note" : "Save note" }

    private func load() {
        if let editing = editingNote {
            title = editing.title
            bodyText = editing.body
            DispatchQueue.main.async { isBodyFocused = true }
        } else {
            title = ""
            bodyText = ""
            DispatchQueue.main.async { isBodyFocused = true }
        }
    }

    private func save() {
        if let editing = editingNote {
            guard noteStore.update(editing, title: title, body: bodyText) else { return }
        } else {
            guard noteStore.create(title: title, body: bodyText) != nil else { return }
        }
        cancel()
    }

    private func cancel() {
        title = ""
        bodyText = ""
        uiState.endAdding()
    }
}

struct NoteRowView: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var uiState: PanelUIState
    let note: NoteItem

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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
            .onTapGesture { uiState.beginEditingNote(note) }

            Menu {
                Button("Edit", systemImage: "pencil") {
                    uiState.beginEditingNote(note)
                }
                Button("Copy", systemImage: "doc.on.doc", action: copyNote)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    noteStore.delete(note)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-row-\(note.id.uuidString)")
    }

    private var displayTitle: String {
        let titleTrimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleTrimmed.isEmpty { return titleTrimmed }
        return note.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? "Note"
    }

    private var preview: String {
        let titleTrimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyLines = note.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)

        if titleTrimmed.isEmpty {
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
