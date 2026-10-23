import Foundation
import SwiftData

/// A single snapshot carries all task, note and association tokens, including
/// membership/absence. Packing them prevents callers combining different reads.
struct AgentWorkspaceReadSet: Codable, Equatable, Sendable {
    #if DEBUG
    @MainActor static var captureCount = 0
    #endif
    let taskID: UUID?
    let noteID: UUID?
    let tokens: [WorkspaceModelToken]
    let scopes: [WorkspaceScopeToken]

    @MainActor static func capture(taskID: UUID?, noteID: UUID?, in context: ModelContext) throws -> Self {
        #if DEBUG
        captureCount += 1
        #endif
        var scopes: Set<WorkspaceScope> = []
        var owners: Set<WorkspaceOwner> = []
        var noteIDs = Set<UUID>()
        if let taskID {
            let tasks = try context.fetch(FetchDescriptor<TaskItem>())
            let family = Set(tasks.filter { $0.id == taskID || $0.parentID == taskID }.map(\.id)).union([taskID])
            owners.formUnion(family.map { .init(entity: .task, id: $0) })
            for id in family { scopes.formUnion([.children(id), .taskNotes(id), .taskAssociations(id), .preservations(id)]) }
            noteIDs.formUnion(try WorkspaceItemLifecycle.writing(taskIDs: family, in: context).map(\.id))
        }
        if let noteID { noteIDs.insert(noteID); owners.insert(.init(entity: .note, id: noteID)) }
        owners.formUnion(noteIDs.map { .init(entity: .note, id: $0) })
        for id in noteIDs { scopes.formUnion([.attachments(id), .versions(id), .noteAssociations(id), .proposals(id)]) }
        let scopeTokens = try scopes.map { try WorkspaceScopeToken.read($0, in: context) }
            .sorted { String(describing: $0.scope) < String(describing: $1.scope) }
        owners.formUnion(scopeTokens.flatMap(\.members).map(\.owner))
        let tokens = try owners.sorted { ($0.entity.rawValue, $0.id.uuidString) < ($1.entity.rawValue, $1.id.uuidString) }
            .map { try WorkspaceModelToken.read($0, in: context) }
        return Self(taskID: taskID, noteID: noteID, tokens: tokens, scopes: scopeTokens)
    }
    @MainActor func isCurrent(in context: ModelContext) throws -> Bool {
        try self == Self.capture(taskID: taskID, noteID: noteID, in: context)
    }
}

struct AgentWorkspaceIntent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case make_subtask, make_note_checkbox, make_task_from_note, add_to_tasks, remove_from_tasks, restore, move_files_into_note, delete_item, restore_item }
    let kind: Kind
    let taskID: UUID?
    let noteID: UUID?
    let subtaskID: UUID?
    let lines: [String]
    let keepOriginal: Bool
    var summary: String {
        switch kind {
        case .make_subtask: "Make subtasks from these consecutive lines: " + lines.joined(separator: " · ") + (keepOriginal ? ". Keep rich lines in the writing." : ". Remove the promoted lines from the writing.")
        case .make_note_checkbox: "In task \(taskID?.uuidString ?? ""), turn subtask \(subtaskID?.uuidString ?? "") into a note checkbox and move the subtask to Recently Deleted."
        case .make_task_from_note, .add_to_tasks: "Add this note to Tasks in Now, keeping its writing and files."
        case .remove_from_tasks: "Remove from Tasks, keeping the writing and materializing subtasks as checkboxes. Drop task-only details; Undo restores them."
        case .restore: "Restore note \(noteID?.uuidString ?? ""). If its task has a newer note, restore it as a separate note."
        case .delete_item: "Delete the whole item, including its writing, subtasks and files."
        case .restore_item: "Restore the whole item to its exact previous placement."
        case .move_files_into_note: "Move this task family's Earlier files into its note, creating the note if needed."
        }
    }
    @MainActor var arguments: [String: Any] {
        var result: [String: Any] = [:]
        if let taskID { result["task_id"] = taskID.uuidString }
        if let noteID { result[kind == .restore ? "id" : "note_id"] = noteID.uuidString }
        if let subtaskID { result["subtask_id"] = subtaskID.uuidString }
        if kind == .make_subtask { result["lines"] = lines; result["keep_original"] = keepOriginal }
        return result
    }
}

/// Explicitly attached to forward producers only. Autosaves and history replays
/// never inherit an agent's guards or consume its proposal.
@MainActor
final class AgentWorkspaceCall {
    @TaskLocal static var current: AgentWorkspaceCall?
    #if DEBUG
    static var beforePreparing: (() async -> Void)?
    #endif
    let readSet: AgentWorkspaceReadSet
    let intent: AgentWorkspaceIntent
    let resolving: NoteProposalSignature?
    weak var presenter: TaskNotePresenter?
    weak var session: NoteSession?
    weak var notes: NotesPageController?
    var conflicted = false
    init(readSet: AgentWorkspaceReadSet, intent: AgentWorkspaceIntent, notes: NotesPageController, resolving: NoteProposalSignature? = nil) {
        self.readSet = readSet; self.intent = intent; self.notes = notes; self.resolving = resolving
    }
    func valid() -> Bool {
        guard let notes, !notes.hasAgentWorkspaceEditor(taskID: intent.taskID, noteID: intent.noteID,
                                                        allowing: presenter, session: session, reviewed: resolving != nil) else {
            conflicted = true; return false
        }
        return true
    }
    func observe(_ outcome: WorkspaceOperationCoordinator.Outcome) {
        if outcome == .conflict { conflicted = true }
    }
    func guarded(_ envelope: WorkspaceOperationEnvelope, coordinator: WorkspaceOperationCoordinator) throws -> WorkspaceOperationEnvelope {
        var reads = envelope.tokens, writes = envelope.writes
        for token in readSet.tokens where !reads.contains(where: { $0.owner == token.owner }) { reads.append(token) }
        if let resolving {
            let owner = WorkspaceOwner(entity: .proposal, id: resolving.id)
            if !reads.contains(where: { $0.owner == owner }) { reads += try coordinator.capture([owner]) }
            writes.insert(owner)
        }
        return .init(id: envelope.id, intent: envelope.intent, tokens: reads, scopes: envelope.scopes + readSet.scopes,
            writes: writes, inverseGuards: envelope.inverseGuards + readSet.tokens,
            preDraft: envelope.preDraft, afterDocuments: envelope.afterDocuments, selection: envelope.selection,
            draftGeneration: envelope.draftGeneration, checkpointClaim: envelope.checkpointClaim, payloads: envelope.payloads,
            historyEffect: envelope.historyEffect, replayOf: envelope.replayOf, compensationOf: envelope.compensationOf)
    }
    func stageResolution(in context: ModelContext) throws {
        if let resolving {
            let id = resolving.id
            let rows = try context.fetch(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.id == id }))
            guard NotePhysicalFamilyRetention.proposalEligible(rows, noteIDs: [resolving.noteID]),
                  rows.first.map(NoteProposalSignature.init) == resolving else { throw WorkspaceFoundationError.conflict }
            for row in rows { WorkspaceLegacyBridge.delete(row, in: context) }
        }
        let timestamp = Date()
        for row in (context.changedModelsArray + context.insertedModelsArray).compactMap({ $0 as? NoteItem }) {
            row.externalEditorName = "Agent"; row.externalEditedAt = timestamp
        }
    }
}

/// Phase 3 slice 2: the agent tools that run a coordinator operation (UX
/// plan § 5.9). They are asynchronous, go through the same producers people
/// use (the task's page, its session and its workspace history), and refuse
/// for the same reasons. A task whose page is not open gets an engine-only
/// page for the call, closed durably afterwards.
@MainActor
extension AgentTaskTools {
    static let asyncToolNames: Set<String> = ["make_subtask", "make_note_checkbox", "make_task_from_note",
                                              "add_to_tasks", "remove_from_tasks", "restore", "move_files_into_note", "delete_task", "delete_note", "delete_item", "restore_item"]

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
        definition("add_to_tasks", title: "Add to Tasks",
                   description: "Adds an ordinary note to Tasks in Now as a fresh task. Keeps note identity, writing, files and versions; leading checkboxes stay writing. A blank title commits immediately.",
                   properties: ["note_id": ["type": "string", "description": "The ordinary note's id (UUID)."]],
                   required: ["note_id"], destructive: false),
        definition("remove_from_tasks", title: "Remove from Tasks",
                   description: "Retires a top-level task with writing, keeping the same ordinary note. Subtasks become leading checkboxes; task-only date, priority and completion details are dropped. Refuses divergent copies, unresolved writing and unproven Earlier files: use move_files_into_note then retry. One guarded Undo restores the exact task family.",
                   properties: ["task_id": ["type": "string", "description": "The top-level task's id (UUID)."]],
                   required: ["task_id"], destructive: false),
        definition("make_task_from_note", title: "Add to Tasks (Compatibility Alias)",
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
        var properties = properties
        properties["base_workspace_token"] = ["type": "string", "description": "The workspace_token from get_task_workspace, or list_notes/list_deleted with include_workspace_token: true; includes task, note and association tokens from the same snapshot."]
        return ["name": name, "title": title, "description": description,
         "annotations": ["readOnlyHint": false, "destructiveHint": destructive, "idempotentHint": false, "openWorldHint": false],
         "inputSchema": ["type": "object", "properties": properties, "required": required + ["base_workspace_token"], "additionalProperties": false]]
    }

    func callAsync(name: String, arguments: [String: Any]) async throws -> String {
        guard let notes = notesController?() else { throw AgentToolError.notPerformed("Task notes aren't available.") }
        notes.workspaceTaskStore = store
        if ["delete_task", "delete_note", "delete_item", "restore_item"].contains(name) {
            return try await wholeItemLifecycle(name: name, arguments: arguments, notes: notes)
        }
        let intent = try workspaceIntent(name: name, arguments: arguments)
        guard let raw = arguments["base_workspace_token"] as? String, let bytes = Data(base64Encoded: raw),
              let readSet = try? JSONDecoder().decode(AgentWorkspaceReadSet.self, from: bytes),
              readSet.noteID == intent.noteID else {
            throw AgentToolError.invalidArguments("base_workspace_token is required: pass workspace_token from get_task_workspace, or list_notes/list_deleted with include_workspace_token: true for this item.")
        }
        let historicalChild = intent.subtaskID.map { id in readSet.tokens.contains { $0.owner == .init(entity: .task, id: id) } } ?? false
        guard readSet.taskID == intent.taskID || intent.noteID != nil || historicalChild else {
            throw AgentToolError.invalidArguments("The workspace token belongs to a different task.")
        }
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: store.container)
        let call = AgentWorkspaceCall(readSet: readSet, intent: intent, notes: notes)
        guard readSet.taskID == intent.taskID, try readSet.isCurrent(in: coordinator.freshContext()), call.valid() else {
            return try await keepWorkspaceProposal(intent, readSet: readSet, notes: notes)
        }
        do {
            return try await AgentWorkspaceCall.$current.withValue(call) { try await executeWorkspaceIntent(intent, notes: notes) }
        } catch {
            if call.conflicted { return try await keepWorkspaceProposal(intent, readSet: readSet, notes: notes) }
            throw error
        }
    }

    func workspaceIntent(name: String, arguments: [String: Any]) throws -> AgentWorkspaceIntent {
        guard let kind = AgentWorkspaceIntent.Kind(rawValue: name) else { throw AgentToolError.unknownTool(name) }
        let context = ModelContext(store.container)
        var taskID: UUID?, noteID: UUID?, subtaskID: UUID?, lines: [String] = []
        switch kind {
        case .make_subtask, .move_files_into_note, .remove_from_tasks:
            taskID = try uuid(arguments, "task_id")
            if kind == .make_subtask {
                guard let value = arguments["lines"] as? [String], !value.isEmpty else { throw AgentToolError.invalidArguments("lines must be non-empty.") }
                lines = value
            }
        case .make_note_checkbox:
            let id = try uuid(arguments, "subtask_id"); subtaskID = id
            let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
            guard let parent = rows.first?.parentID, rows.allSatisfy({ $0.parentID == parent }) else { throw AgentToolError.notPerformed("The subtask's parent is unavailable or disagrees.") }
            taskID = parent
        case .delete_item, .restore_item:
            throw AgentToolError.invalidArguments("Use a whole-item lifecycle alias.")
        case .make_task_from_note, .add_to_tasks, .restore:
            let id = try uuid(arguments, kind == .restore ? "id" : "note_id"); noteID = id
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
            guard let first = rows.first, rows.allSatisfy({ $0.taskID == first.taskID }) else { throw AgentToolError.notPerformed("The note is unavailable or its copies disagree.") }
            taskID = first.taskID
        }
        return .init(kind: kind, taskID: taskID, noteID: noteID, subtaskID: subtaskID, lines: lines, keepOriginal: arguments["keep_original"] as? Bool ?? false)
    }

    func executeWorkspaceIntent(_ intent: AgentWorkspaceIntent, notes: NotesPageController) async throws -> String {
        #if DEBUG
        await AgentWorkspaceCall.beforePreparing?()
        #endif
        switch intent.kind {
        case .delete_item, .restore_item: return try executeWholeItemLifecycle(intent, notes: notes)
        case .make_subtask: return try await makeSubtask(intent.arguments, notes: notes)
        case .make_note_checkbox: return try await makeNoteCheckbox(intent.arguments, notes: notes)
        case .make_task_from_note, .add_to_tasks: return try await makeTaskFromNote(intent.arguments, notes: notes)
        case .remove_from_tasks:
            return try await withPage(try uuid(intent.arguments, "task_id"), notes: notes) { presenter in
                switch await TaskNoteConversion.removeTask(presenter.taskID, notes: notes, tasks: store, workspaceSession: presenter.session) {
                case let .removed(noteID): return try encodeJSON(["ok": true, "note_id": noteID.uuidString])
                case let .refused(reason): throw AgentToolError.notPerformed(reason)
                }
            }
        case .restore: return try await restoreNote(intent.arguments, notes: notes)
        case .move_files_into_note: return try await moveFilesIntoNote(intent.arguments)
        }
    }

    private func wholeItemLifecycle(name: String, arguments: [String: Any], notes: NotesPageController) async throws -> String {
        if arguments["kind"] as? String == "canvas" { return try call(name: name, arguments: arguments) }
        let id = try uuid(arguments, "id")
        let isNote = name == "delete_note" || arguments["kind"] as? String == "note"
        let context = ModelContext(store.container)
        let taskID: UUID?
        if isNote {
            taskID = try WorkspaceItemLifecycle.taskOwner(noteID: id, in: context, includingDeleted: name == "restore_item")
        } else { taskID = id }
        let intent = AgentWorkspaceIntent(kind: name == "restore_item" ? .restore_item : .delete_item,
            taskID: taskID, noteID: isNote ? id : nil, subtaskID: nil, lines: [], keepOriginal: false)
        let paired = try taskID.map { !(try WorkspaceItemLifecycle.writing(taskIDs: [$0], in: context)).isEmpty } ?? false
        guard let raw = arguments["base_workspace_token"] as? String, let data = Data(base64Encoded: raw),
              let readSet = try? JSONDecoder().decode(AgentWorkspaceReadSet.self, from: data) else {
            if !paired, !notes.hasAgentWorkspaceEditor(taskID: taskID, noteID: intent.noteID, allowing: nil, session: nil) {
                return try call(name: name, arguments: arguments)
            }
            throw AgentToolError.invalidArguments("Deleting or restoring a whole item requires base_workspace_token from get_task_workspace or list_deleted with include_workspace_token: true.")
        }
        guard readSet.taskID == taskID,
              readSet.noteID == intent.noteID || (isNote && readSet.noteID == nil && readSet.tokens.contains { $0.owner == .init(entity: .note, id: id) }) else {
            throw AgentToolError.invalidArguments("The workspace token belongs to a different item.")
        }
        let call = AgentWorkspaceCall(readSet: readSet, intent: intent, notes: notes)
        guard try readSet.isCurrent(in: ModelContext(store.container)), call.valid() else {
            return try await keepWorkspaceProposal(intent, readSet: readSet, notes: notes)
        }
        do {
            return try AgentWorkspaceCall.$current.withValue(call) { try executeWholeItemLifecycle(intent, notes: notes) }
        } catch {
            if call.conflicted { return try await keepWorkspaceProposal(intent, readSet: readSet, notes: notes) }
            throw error
        }
    }

    private func executeWholeItemLifecycle(_ intent: AgentWorkspaceIntent, notes: NotesPageController) throws -> String {
        guard AgentWorkspaceCall.current?.valid() == true else { throw AgentToolError.notPerformed("Review the whole operation first.") }
        let ref: AtticItemRef
        if let id = intent.noteID { ref = .init(.note, id) }
        else if let id = intent.taskID { ref = .init(.task, id) }
        else { throw AgentToolError.invalidArguments("An item is required.") }
        let history: UndoHistoryID = intent.taskID.map { .taskWorkspace($0) } ?? .note(ref.id)
        let succeeded: Bool
        if intent.kind == .restore_item { succeeded = library.restore(ref, in: history) }
        else if ref.kind == .task { succeeded = library.deleteListedTasks([ref.id], in: history).isApplied }
        else { succeeded = library.delete(ref, in: history) }
        guard succeeded else { throw AgentToolError.notPerformed(library.lastErrorMessage ?? "The whole item couldn't be changed.") }
        return try encodeJSON(["status": "applied", intent.kind == .restore_item ? "restored" : "deleted": ref.id.uuidString])
    }

    private func keepWorkspaceProposal(_ intent: AgentWorkspaceIntent, readSet: AgentWorkspaceReadSet, notes: NotesPageController) async throws -> String {
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: store.container)
        let ownID = intent.taskID.flatMap { try? coordinator.sessions.resolve(.task($0)).1 }
        let noteID = intent.noteID ?? ownID ?? UUID()
        let preview = try NoteDocument(blocks: [.text("Proposed workspace change"), .text(intent.summary)])
        let proposal = NotePendingEdit(noteID: noteID, baseRevisionToken: "workspace", proposedContent: try NoteContentCodec.encode(preview), agentName: "Agent", createdAt: Date())
        proposal.workspaceOperationData = try WorkspaceModelFields.encode(intent)
        proposal.workspaceReadSetData = try WorkspaceModelFields.encode(readSet)
        proposal.workspaceTaskID = intent.taskID
        proposal.needsReview = true
        let owner = WorkspaceOwner(entity: .proposal, id: proposal.id)
        let envelope = try coordinator.newEnvelope(intent: "Keep Proposed Workspace Operation", reads: coordinator.capture([owner]), writes: [owner])
        let outcome = await coordinator.execute(envelope, stage: { commit in commit.insert(proposal) })
        guard outcome == .committed || outcome == .publicationPending else { throw AgentToolError.notPerformed("The proposal couldn't be kept. Retry after storage recovers.") }
        notes.store.refresh()
        return try encodeJSON(["status": "pending", "proposal_id": proposal.id.uuidString, "summary": intent.summary])
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
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: store.container)
        await coordinator.sessions.retryHeadlessClosures()
        if let open = TaskNotePresenter.open(for: taskID) {
            guard AgentWorkspaceCall.current?.resolving != nil else {
                AgentWorkspaceCall.current?.conflicted = true
                throw AgentToolError.notPerformed("The note is open; the operation needs review.")
            }
            AgentWorkspaceCall.current?.presenter = open
            return try await body(open)
        }
        let presenter: TaskNotePresenter
        do {
            presenter = try TaskNotePresenter(taskID: taskID, tasks: store, library: library, notes: notes,
                                              design: .default, columnInset: AtticNoteMetrics.columnInset, defaults: nil)
        } catch {
            throw AgentToolError.notPerformed("The task's note can't be opened now.")
        }
        AgentWorkspaceCall.current?.presenter = presenter
        do {
            let result = try await body(presenter)
            if !(await presenter.close()), let lease = presenter.lease {
                _ = await coordinator.sessions.closeHeadless(presenter.page, lease: lease)
            }
            return result
        } catch {
            if !(await presenter.close()), let lease = presenter.lease {
                _ = await coordinator.sessions.closeHeadless(presenter.page, lease: lease)
            }
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
        if let call = AgentWorkspaceCall.current, call.intent.taskID != parentID {
            call.conflicted = true
            throw AgentToolError.notPerformed("The subtask moved to another task. Review a new proposal from its current task.")
        }
        return try await withPage(parentID, notes: notes) { presenter in
            try outcomeText(await presenter.makeNoteCheckbox(subtaskID: subtaskID, tasks: store, notes: notes))
        }
    }

    private func makeTaskFromNote(_ arguments: [String: Any], notes: NotesPageController) async throws -> String {
        let noteID = try uuid(arguments, "note_id")
        notes.store.refresh()
        guard let session = notes.workspaceSession(noteID: noteID) else { throw AgentToolError.notPerformed("The note can't be opened now.") }
        AgentWorkspaceCall.current?.session = session
        let outcome = await TaskNoteConversion.makeTask(fromNote: noteID, notes: notes, tasks: store, workspaceSession: session)
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
        if let taskID = row.taskID, TaskNotePresenter.open(for: taskID) != nil, AgentWorkspaceCall.current?.resolving == nil {
            AgentWorkspaceCall.current?.conflicted = true
            throw AgentToolError.notPerformed("The task's note is open; restore it there.")
        }
        let call = AgentWorkspaceCall.current
        let coordinator = try WorkspaceLegacyBridge.coordinator(for: store.container)
        let admission = try await coordinator.ownership.admit(Set((call?.readSet.tokens ?? []).map(\.owner.id)).union([noteID, coordinator.ownership.unknownID]))
        defer { admission.release() }
        guard call?.valid() != false else { throw AgentToolError.notPerformed("The note needs review.") }
        if let call, !(try call.readSet.isCurrent(in: ModelContext(store.container))) {
            call.conflicted = true; throw AgentToolError.notPerformed("The workspace changed.")
        }
        let restored = try WorkspaceLegacyBridge.withDeclaredReadSet(tokens: call?.readSet.tokens ?? [], scopes: call?.readSet.scopes ?? [], in: notes.store.modelContext) {
            return notes.restoreTaskNote(noteID: noteID, staging: { try call?.stageResolution(in: $0) })
        }
        guard let restored else {
            throw AgentToolError.notPerformed("The note couldn't be restored.")
        }
        return try encodeJSON(["ok": true, "restored_as": restored.separate ? "separate_note" : "own_note"])
    }

    private func moveFilesIntoNote(_ arguments: [String: Any]) async throws -> String {
        let taskID = try uuid(arguments, "task_id")
        guard store.task(withID: taskID)?.parentID == nil || store.task(withID: taskID) == nil else {
            throw AgentToolError.invalidArguments("Files belong to the top-level task: use its id.")
        }
        if AgentWorkspaceCall.current?.resolving != nil, let presenter = TaskNotePresenter.open(for: taskID) {
            guard await presenter.close() else { throw AgentToolError.notPerformed("The note can't be closed durably.") }
        }
        guard TaskNotePresenter.open(for: taskID) == nil, let notes = notesController?(),
              let coordinator = try? WorkspaceLegacyBridge.coordinator(for: store.container),
              !TaskFilesState.noteIsOpen(taskID, notes: notes, coordinator: coordinator) else {
            AgentWorkspaceCall.current?.conflicted = true
            throw AgentToolError.notPerformed("The task's note is open; use Earlier files › Move into Note there.")
        }
        switch await store.fileMigration.moveIntoNote(taskID, tasks: store, notes: notes) {
        case let .migrated(noteID, created):
            return try encodeJSON(["ok": true, "note_id": noteID.uuidString, "created_note": created])
        case .reconciled: return try encodeJSON(["ok": true])
        case .unchanged:
            if AgentWorkspaceCall.current?.resolving != nil { throw AgentToolError.notPerformed("The files are already up to date. Discard this proposal when you have reviewed them.") }
            return try encodeJSON(["ok": true])
        case let .refused(refusal): throw AgentToolError.notPerformed("Not moved: \(refusal.reason).")
        case .deferred: throw AgentToolError.notPerformed("Not moved now: the task changed or is in Recently Deleted.")
        }
    }

    private func encodeJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
