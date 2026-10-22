import Foundation
import SwiftData

/// Phase 3 slice 2: the agent tools that run a coordinator operation (UX
/// plan § 5.9). They are asynchronous, go through the same producers people
/// use (the task's page, its session and its workspace history), and refuse
/// for the same reasons. A task whose page is not open gets an engine-only
/// page for the call, closed durably afterwards.
@MainActor
extension AgentTaskTools {
    static let asyncToolNames: Set<String> = ["make_subtask", "make_note_checkbox", "make_task_from_note",
                                              "restore", "move_files_into_note"]

    static let workspaceDefinitions: [[String: Any]] = [
        definition("make_subtask", title: "Make Subtasks from a Task's Note",
                   description: "Makes subtasks from consecutive lines of a task's note body (§ 2.3.3), in one operation with one Undo step. Lines with links or formatting a subtask can't keep are refused as rich_content unless keep_original is true (they then stay in the writing).",
                   properties: ["task_id": ["type": "string", "description": "The task's id (UUID)."],
                                "lines": ["type": "array", "items": ["type": "string"], "description": "The body's lines to promote, exactly as written, consecutive."],
                                "keep_original": ["type": "boolean", "description": "Make subtasks of the plain lines and keep rich lines in the writing."]],
                   required: ["task_id", "lines"], destructive: false),
        definition("make_note_checkbox", title: "Turn a Subtask into a Note Checkbox",
                   description: "Puts a subtask's title at the top of its task's note as a note checkbox (ticked as it was) and moves the subtask to Recently Deleted, in one operation. Creates the note when the task has none.",
                   properties: ["subtask_id": ["type": "string", "description": "The subtask's id (UUID)."]],
                   required: ["subtask_id"], destructive: false),
        definition("make_task_from_note", title: "Make a Task from a Note",
                   description: "Turns an ordinary note into a task's own note: the task takes the note's title and tags, in one operation.",
                   properties: ["note_id": ["type": "string", "description": "The note's id (UUID)."]],
                   required: ["note_id"], destructive: false),
        definition("restore", title: "Restore a Task's Note",
                   description: "Restores a note from Recently Deleted by the task-note rules (§ 2.7.2): it returns as the task's own note, or as a separate ordinary note when the task has a newer one. Other items use restore_item.",
                   properties: ["id": ["type": "string", "description": "The note's id (UUID)."]],
                   required: ["id"], destructive: false),
        definition("move_files_into_note", title: "Move a Task's Earlier Files into Its Note",
                   description: "Moves a task's earlier (legacy) files into its own note in one operation (§ 13), creating the note if needed. Refused with the reason when the note's limits or the data don't allow it, or while the note is open.",
                   properties: ["task_id": ["type": "string", "description": "The top-level task's id (UUID)."]],
                   required: ["task_id"], destructive: false),
    ]

    private static func definition(_ name: String, title: String, description: String, properties: [String: Any],
                                   required: [String], destructive: Bool) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "annotations": ["readOnlyHint": false, "destructiveHint": destructive, "idempotentHint": false, "openWorldHint": false],
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    func callAsync(name: String, arguments: [String: Any]) async throws -> String {
        guard let notes = notesController?() else { throw AgentToolError.notPerformed("Task notes aren't available.") }
        switch name {
        case "make_subtask": return try await makeSubtask(arguments, notes: notes)
        case "make_note_checkbox": return try await makeNoteCheckbox(arguments, notes: notes)
        case "make_task_from_note": return try await makeTaskFromNote(arguments, notes: notes)
        case "restore": return try await restoreNote(arguments, notes: notes)
        case "move_files_into_note": return try await moveFilesIntoNote(arguments)
        default: throw AgentToolError.unknownTool(name)
        }
    }

    private func uuid(_ arguments: [String: Any], _ key: String) throws -> UUID {
        guard let raw = arguments[key] as? String, let id = UUID(uuidString: raw) else {
            throw AgentToolError.invalidArguments("\(key) must be a UUID string.")
        }
        return id
    }

    /// The task's page: the open one, or an engine-only one for this call.
    private func withPage<T>(_ taskID: UUID, notes: NotesPageController,
                             _ body: (TaskNotePresenter) async throws -> T) async throws -> T {
        if let open = TaskNotePresenter.open(for: taskID) { return try await body(open) }
        let presenter: TaskNotePresenter
        do {
            presenter = try TaskNotePresenter(taskID: taskID, tasks: store, library: library, notes: notes,
                                              design: .default, columnInset: AtticNoteMetrics.columnInset, defaults: nil)
        } catch {
            throw AgentToolError.notPerformed("The task's note can't be opened now.")
        }
        do {
            let result = try await body(presenter)
            _ = await presenter.close()
            return result
        } catch {
            _ = await presenter.close()
            throw error
        }
    }

    private func outcomeText(_ result: TaskNotePresenter.OperationResult) throws -> String {
        switch result {
        case let .made(_, count, kept):
            return try encodeJSON(["ok": true, "made": count, "kept_in_writing": kept])
        case let .madeCheckbox(_, recovery):
            var payload: [String: Any] = ["ok": true]
            if let recovery { payload["recovery"] = recovery }
            return try encodeJSON(payload)
        case let .refused(reason):
            throw AgentToolError.notPerformed(reason)
        }
    }

    private func makeSubtask(_ arguments: [String: Any], notes: NotesPageController) async throws -> String {
        let taskID = try uuid(arguments, "task_id")
        guard let lines = arguments["lines"] as? [String], !lines.isEmpty else {
            throw AgentToolError.invalidArguments("lines must be a non-empty array of strings.")
        }
        let keepOriginal = arguments["keep_original"] as? Bool ?? false
        guard store.task(withID: taskID) != nil else { throw AgentToolError.notFound(taskID.uuidString) }
        return try await withPage(taskID, notes: notes) { presenter in
            guard let session = presenter.session else { throw AgentToolError.notPerformed("The task has no note to make subtasks from.") }
            let text = session.engine.textStorage
            let string = text.string as NSString
            // The body's paragraphs; the requested lines must be one run.
            var paragraphs: [(String, NSRange)] = []
            var location = 0
            while location < string.length {
                let range = string.paragraphRange(for: NSRange(location: location, length: 0))
                var body = string.substring(with: range)
                while body.hasSuffix("\n") || body.hasSuffix("\u{2029}") { body.removeLast() }
                paragraphs.append((body, range))
                location = NSMaxRange(range)
            }
            guard let first = paragraphs.firstIndex(where: { $0.0 == lines[0] }),
                  first + lines.count <= paragraphs.count,
                  zip(paragraphs[first..<(first + lines.count)], lines).allSatisfy({ $0.0.0 == $0.1 }) else {
                throw AgentToolError.invalidArguments("lines must match consecutive lines of the task's note exactly.")
            }
            let start = paragraphs[first].1.location
            let last = paragraphs[first + lines.count - 1]
            var end = NSMaxRange(last.1)
            if end > start, string.character(at: end - 1) == 10 { end -= 1 }
            let analysis = TaskNoteSubtaskSelection.analyse(text, selection: NSRange(location: start, length: end - start))
            if analysis.richCount > 0, !keepOriginal {
                throw AgentToolError.notPerformed("rich_content: \(analysis.richCount) line(s) have links or formatting a subtask can't keep. Pass keep_original: true to make subtasks of the rest and keep those lines.")
            }
            return try outcomeText(await presenter.makeSubtasks(analysis, tasks: store, notes: notes))
        }
    }

    private func makeNoteCheckbox(_ arguments: [String: Any], notes: NotesPageController) async throws -> String {
        let subtaskID = try uuid(arguments, "subtask_id")
        guard let subtask = store.task(withID: subtaskID), let parentID = subtask.parentID else {
            throw AgentToolError.notPerformed("No subtask exists with id \(subtaskID.uuidString).")
        }
        return try await withPage(parentID, notes: notes) { presenter in
            try outcomeText(await presenter.makeNoteCheckbox(subtaskID: subtaskID, tasks: store, notes: notes))
        }
    }

    private func makeTaskFromNote(_ arguments: [String: Any], notes: NotesPageController) async throws -> String {
        let noteID = try uuid(arguments, "note_id")
        // The conversion runs on the note's open session (as from its ⋯):
        // the note is opened for the call, and the one open before returns.
        let previous = notes.active?.noteID
        if previous != noteID {
            notes.store.refresh()
            guard notes.open(noteID: noteID) else { throw AgentToolError.notPerformed("The note can't be opened now.") }
        }
        let outcome = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: store)
        if let previous, previous != noteID { _ = notes.open(noteID: previous) }
        switch outcome {
        case let .made(taskID): return try encodeJSON(["ok": true, "task_id": taskID.uuidString])
        case let .refused(reason): throw AgentToolError.notPerformed(reason)
        }
    }

    private func restoreNote(_ arguments: [String: Any], notes: NotesPageController) async throws -> String {
        let noteID = try uuid(arguments, "id")
        let rows = (try? ModelContext(store.container).fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))) ?? []
        guard let row = rows.first, rows.allSatisfy({ $0.deletedAt != nil }) else {
            throw AgentToolError.notPerformed("No note in Recently Deleted has id \(noteID.uuidString).")
        }
        if let taskID = row.taskID, TaskNotePresenter.open(for: taskID) != nil {
            throw AgentToolError.notPerformed("The task's note is open; restore it there.")
        }
        guard let restored = notes.restoreTaskNote(noteID: noteID) else {
            throw AgentToolError.notPerformed("The note couldn't be restored.")
        }
        return try encodeJSON(["ok": true, "restored_as": restored.separate ? "separate_note" : "own_note"])
    }

    private func moveFilesIntoNote(_ arguments: [String: Any]) async throws -> String {
        let taskID = try uuid(arguments, "task_id")
        guard store.task(withID: taskID)?.parentID == nil || store.task(withID: taskID) == nil else {
            throw AgentToolError.invalidArguments("Files belong to the top-level task: use its id.")
        }
        guard TaskNotePresenter.open(for: taskID) == nil, let notes = notesController?(),
              let coordinator = try? WorkspaceLegacyBridge.coordinator(for: store.container),
              !TaskFilesState.noteIsOpen(taskID, notes: notes, coordinator: coordinator) else {
            throw AgentToolError.notPerformed("The task's note is open; use Earlier files › Move into Note there.")
        }
        switch await store.fileMigration.moveIntoNote(taskID, tasks: store) {
        case let .migrated(noteID, created):
            return try encodeJSON(["ok": true, "note_id": noteID.uuidString, "created_note": created])
        case .reconciled, .unchanged: return try encodeJSON(["ok": true])
        case let .refused(refusal): throw AgentToolError.notPerformed("Not moved: \(refusal.reason).")
        case .deferred: throw AgentToolError.notPerformed("Not moved now: the task changed or is in Recently Deleted.")
        }
    }

    private func encodeJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
