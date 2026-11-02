import SwiftData
import SwiftUI
import UIKit

/// Edits only native plain-text documents that the shared codec can round-trip.
/// Tables, attachments, unknown requirements, and task-owned writing remain
/// read-only; the original content bytes are never rewritten in that case.
struct PhoneNotePage: View {
    @ObservedObject var state: PhoneAppState
    let noteID: UUID
    @State private var opened: PhoneLibrary.OpenNote?
    @State private var title = ""
    @State private var bodyText = ""
    @State private var editable = false
    @State private var pinned = false
    @State private var localError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let note = opened {
                    HStack {
                        Spacer()
                        if editable {
                            Button {
                                if state.change({
                                    let saved = try state.library.updateNote(note, title: title, body: bodyText)
                                    opened = saved
                                }) { load() }
                            } label: {
                                Label("Done", systemImage: "checkmark").font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                            .accessibilityIdentifier("phone-note-save")
                        }
                        Menu {
                            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                                if state.change({ _ = try state.library.updateNoteMetadata(id: noteID, pinned: !pinned) }) {
                                    load()
                                }
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("Note options")
                    }
                    if editable {
                        TextField("Title", text: $title, axis: .vertical)
                            .font(.system(size: 30, weight: .bold))
                            .lineLimit(1...4)
                            .accessibilityIdentifier("phone-note-title")
                    } else {
                        Text(title.isEmpty ? "Untitled note" : title)
                            .font(.system(size: 30, weight: .bold))
                            .textSelection(.enabled)
                    }
                    if !note.note.tags.isEmpty {
                        Text(note.note.tags.map { "#" + $0 }.joined(separator: "  "))
                            .font(.subheadline).foregroundStyle(.tint)
                    }
                    Text("Edited " + note.note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if editable {
                        PhoneTextKitEditor(text: $bodyText)
                            .frame(minHeight: 240)
                            .accessibilityIdentifier("phone-note-body")
                    } else {
                        Text(bodyText).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Label("Rich content is preserved and read-only on iPhone.", systemImage: "lock.doc")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let localError {
                    ContentUnavailableView("Note unavailable", systemImage: "doc.questionmark",
                                           description: Text(localError))
                } else {
                    ProgressView()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: noteID) { load() }
    }

    private func load() {
        do {
            let note = try state.library.openNote(id: noteID)
            opened = note
            title = note.note.title
            bodyText = note.note.body
            pinned = note.note.pinnedAt != nil
            editable = Self.isPlainEditable(note)
            localError = nil
        } catch {
            opened = nil
            localError = error.localizedDescription
        }
    }

    /// Do not interpret cached previews of unsupported blocks as editable body.
    private static func isPlainEditable(_ note: PhoneLibrary.OpenNote) -> Bool {
        guard note.note.taskID == nil, note.contentFormat == NoteDocument.currentFormat,
              let bytes = note.content,
              case let .editable(document) = NoteContentCodec.decode(bytes),
              document.extras.isEmpty,
              document.requires.allSatisfy({ $0 == "text" }) else { return false }
        return document.blocks.allSatisfy { $0 == .text($0.text) }
    }
}

/// UITextView(usingTextLayoutManager:) selects TextKit 2 while retaining native
/// selection, dictation and IME behavior. The shared codec remains the save gate.
private struct PhoneTextKitEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = .init(top: 6, left: 0, bottom: 12, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.keyboardDismissMode = .interactive
        view.text = text
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PhoneTextKitEditor
        init(_ parent: PhoneTextKitEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}

struct PhoneTaskPage: View {
    @ObservedObject var state: PhoneAppState
    let taskID: UUID
    @State private var title = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .none
    @State private var tags = ""
    @State private var dueEnabled = false
    @State private var dueDate = Date()
    @State private var current: PhoneLibrary.TaskRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let current {
                    HStack {
                        Text("Task").foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { save(current) }.fontWeight(.semibold)
                            .accessibilityIdentifier("phone-task-save")
                    }
                    TextField("Task title", text: $title, axis: .vertical)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1...4)
                    Picker("List", selection: $status) {
                        Text("Now").tag(TaskStatus.todo)
                        Text("In progress").tag(TaskStatus.inProgress)
                        Text("Later").tag(TaskStatus.backlog)
                        Text("Done").tag(TaskStatus.done)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Priority").font(.headline)
                        Spacer()
                        Picker("Priority", selection: $priority) {
                            ForEach(TaskPriority.allCases) { level in Text(level.title).tag(level) }
                        }
                        .labelsHidden()
                    }
                    Toggle("Due date", isOn: $dueEnabled)
                    if dueEnabled {
                        DatePicker("Date", selection: $dueDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }
                    HStack {
                        Text("#").foregroundStyle(.secondary)
                        TextField("Tags", text: $tags)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 7)
                    Divider()
                    Text("Created " + current.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Task unavailable", systemImage: "checkmark.circle")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .task(id: taskID) { load() }
    }

    private func load() {
        guard let row = state.tasks.first(where: { $0.id == taskID }) else { current = nil; return }
        current = row
        title = row.title
        status = row.status
        priority = row.priority
        tags = row.tags.map { "#" + $0 }.joined(separator: " ")
        dueEnabled = row.dueDay != nil
        dueDate = row.dueDay?.startDate(in: .autoupdatingCurrent) ?? Date()
    }

    private func save(_ previous: PhoneLibrary.TaskRow) {
        let baseline = MobileTaskEditBaseline(title: previous.title, priority: previous.priority, status: previous.status)
        let edit = baseline.patch(title: title, priority: priority, status: status)
        let changedDay: DueDay?? = {
            let chosen = dueEnabled ? DueDay(date: dueDate, calendar: .autoupdatingCurrent) : nil
            return chosen != previous.dueDay ? .some(chosen) : nil
        }()
        let proposedTags = tags.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        if state.change({
            _ = try state.library.updateTask(id: taskID, patch: edit, dueDay: changedDay,
                                             tags: proposedTags == previous.tags ? nil : proposedTags)
        }) { load() }
    }
}

/// The shell exposes stored canvases without altering Draw's document format.
/// Touch/Pencil object creation is provided by the later Draw page wave.
struct PhoneCanvasPage: View {
    @ObservedObject var state: PhoneAppState
    let canvasID: UUID
    @State private var board: DrawSnapshot?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let board {
                Text(board.canvas.name)
                    .font(.system(size: 30, weight: .bold))
                    .padding(.horizontal, 20)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        Color(uiColor: .secondarySystemBackground)
                        Canvas { context, size in
                            var dots = Path()
                            for x in stride(from: CGFloat(10), through: size.width, by: 20) {
                                for y in stride(from: CGFloat(10), through: size.height, by: 20) {
                                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                                }
                            }
                            context.fill(dots, with: .color(.secondary.opacity(0.24)))
                        }
                        if !board.objects.isEmpty {
                            Text("\(board.objects.count) saved objects")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .accessibilityLabel("Canvas: \(board.canvas.name)")
            } else {
                ContentUnavailableView("Canvas unavailable", systemImage: "scribble.variable",
                                       description: Text(problem ?? "The canvas could not be opened."))
            }
        }
        .padding(.top, 16)
        .task(id: canvasID) {
            do {
                board = try state.draw.open(canvasID)
                problem = nil
            } catch {
                board = nil
                problem = error.localizedDescription
            }
        }
    }
}
