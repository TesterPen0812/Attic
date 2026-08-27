import SwiftUI

struct MobileNoteEditorConfiguration: Identifiable {
    enum Mode {
        case create
        case edit(NoteItem)
    }

    let mode: Mode

    var id: String {
        switch mode {
        case .create: "create-note"
        case let .edit(note): "edit-\(note.id.uuidString)"
        }
    }

    static let create = Self(mode: .create)

    static func edit(_ note: NoteItem) -> Self {
        Self(mode: .edit(note))
    }
}

struct MobileNotesScreen: View {
    @ObservedObject var noteStore: NoteStore
    let iCloudAvailability: ICloudAvailability
    let refresh: () async -> Void

    @State private var editor: MobileNoteEditorConfiguration?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notes = noteStore.orderedNotes()

        VStack(spacing: 0) {
            header(noteCount: notes.count)
            noteList(notes: notes)
            footer
        }
        .background(Color(uiColor: .systemBackground))
        .animation(reduceMotion ? nil : AtticMotion.spring, value: noteStore.notes.map(\.id))
        .sheet(item: $editor) { configuration in
            MobileNoteEditor(noteStore: noteStore, configuration: configuration)
        }
    }

    // MARK: Header

    private func header(noteCount: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Attic")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(noteCount == 1 ? "1 Note" : "\(noteCount) Notes")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : AtticMotion.quick, value: noteCount)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    // MARK: List

    private func noteList(notes: [NoteItem]) -> some View {
        List {
            if notes.isEmpty {
                VStack(spacing: 5) {
                    Text("Nothing saved yet")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                    Text("Write a note and it appears on your Mac too.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(notes) { note in
                    MobileNoteRow(note: note) {
                        editor = .edit(note)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            noteStore.delete(note)
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.never)
        .refreshable { await refresh() }
        .safeAreaInset(edge: .bottom) { addNoteButton }
    }

    private var addNoteButton: some View {
        Button {
            editor = .create
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 60, height: 60)
                .background(Color.primary.opacity(0.9), in: Circle())
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .accessibilityLabel("New Note")
        .accessibilityIdentifier("add-note-button")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 4) {
            if let message = noteStore.lastErrorMessage {
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if case .available = iCloudAvailability,
               let message = noteStore.cloudSyncStatus.lastErrorMessage {
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 5) {
                Image(systemName: syncSymbol)
                    .font(.system(size: 10, weight: .medium))
                Text(syncTitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var syncSymbol: String {
        switch iCloudAvailability {
        case .available: noteStore.cloudSyncStatus.symbolName
        case .checking: "icloud"
        case .noAccount, .restricted, .temporarilyUnavailable, .unavailable:
            "exclamationmark.icloud"
        }
    }

    private var syncTitle: String {
        switch iCloudAvailability {
        case .available: noteStore.cloudSyncStatus.title
        case .checking, .noAccount, .restricted, .temporarilyUnavailable, .unavailable:
            iCloudAvailability.title
        }
    }
}

struct MobileNoteRow: View {
    let note: NoteItem
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(preview)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(note.updatedAt, style: .relative)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .accessibilityIdentifier("note-row-\(note.id.uuidString)")
        .accessibilityAction(named: "Edit", edit)
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
}

struct MobileNoteEditor: View {
    @ObservedObject var noteStore: NoteStore
    let configuration: MobileNoteEditorConfiguration

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @FocusState private var bodyIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(noteStore: NoteStore, configuration: MobileNoteEditorConfiguration) {
        self.noteStore = noteStore
        self.configuration = configuration

        switch configuration.mode {
        case .create:
            _title = State(initialValue: "")
            _bodyText = State(initialValue: "")
        case let .edit(note):
            _title = State(initialValue: note.title)
            _bodyText = State(initialValue: note.body)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            TextField("Title (optional)", text: $title, axis: .vertical)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1...2)
                .submitLabel(.done)
                .accessibilityIdentifier("note-title-field")

            TextEditor(text: $bodyText)
                .font(.system(size: 16, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .focused($bodyIsFocused)
                .accessibilityIdentifier("note-body-field")

            if let message = noteStore.lastErrorMessage {
                Text(message)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .fontDesign(.rounded)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { bodyIsFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(editorTitle)
                .font(.system(size: 17, weight: .semibold, design: .rounded))

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")

            Button(action: save) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        canSave ? Color.accentColor : Color.secondary.opacity(0.35),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityLabel("Save")
            .accessibilityIdentifier("save-note")
        }
    }

    private var editorTitle: String {
        switch configuration.mode {
        case .create: "New Note"
        case .edit: "Edit Note"
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let succeeded = withAnimation(reduceMotion ? nil : AtticMotion.spring) {
            switch configuration.mode {
            case .create:
                return noteStore.create(title: title, body: bodyText) != nil
            case let .edit(note):
                return noteStore.update(note, title: title, body: bodyText)
            }
        }

        if succeeded { dismiss() }
    }
}
