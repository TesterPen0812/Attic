import Foundation

enum AgentToolError: Error {
    case unknownTool(String)
    case invalidArguments(String)
    case notFound(String)
    case storeFailure(String)
    /// The request was valid but Attic could not carry it out (the panel
    /// refused to change page, for example); the details say why.
    case notPerformed(String)

    var message: String {
        switch self {
        case let .unknownTool(name): "Unknown tool: \(name)"
        case let .invalidArguments(details): details
        case let .notFound(id): "No task exists with id \(id)."
        case let .storeFailure(details): "The change could not be saved: \(details)"
        case let .notPerformed(details): details
        }
    }
}

/// Executes MCP tool calls against the app's task store so agent edits follow
/// the same rules (ordering, timestamps, cleanup) as edits made in the UI.
@MainActor
final class AgentTaskTools {
    private let store: TaskStore

    private let noteStore: NoteStore?
    /// The command layer every change goes through, so agent edits are
    /// undoable and deletes land in Recently Deleted like a person's.
    private let library: AtticLibrary
    /// Understands `due` ("tomorrow", "fri", "sep 30", ISO dates).
    private let parser: TaskTextParser
    /// `get_settings` and `update_settings` (Phase 1 Settings).
    private let settingsTools: AgentSettingsTools?

    init(
        store: TaskStore,
        noteStore: NoteStore? = nil,
        library: AtticLibrary? = nil,
        parser: TaskTextParser = TaskTextParser(),
        settingsTools: AgentSettingsTools? = nil
    ) {
        self.settingsTools = settingsTools
        self.store = store
        self.noteStore = noteStore
        self.library = library ?? AtticLibrary(tasks: store, notes: noteStore)
        self.parser = parser
    }

    static let taskDefinitions: [[String: Any]] = [
        [
            "name": "list_tasks",
            "title": "List Attic Tasks",
            "description": "Read main tasks and subtasks directly from Attic, in list order (in progress, to do, done, then backlog; manual order within each). Results include parent_id for subtasks; filter by parent_id to read a main task's steps, including completed ones. Optional filters combine: state (backlog is its own list), tag, due_before / due_after (inclusive days), text (in the title). Finished tasks from earlier days live in the Done log: add include_done_log to list them too (they carry done_logged_at).",
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "status": [
                        "type": "string",
                        "enum": TaskStatus.allCases.map(\.rawValue),
                        "description": "Only return tasks with this status."
                    ],
                    "state": [
                        "type": "string",
                        "enum": TaskStatus.allCases.map(\.rawValue),
                        "description": "Same as status (the name the app uses)."
                    ],
                    "parent_id": [
                        "type": "string",
                        "description": "Main task UUID. Only return its subtasks."
                    ],
                    "tag": [
                        "type": "string",
                        "description": "Only tasks carrying this tag (a leading # is ignored)."
                    ],
                    "due_before": [
                        "type": "string",
                        "description": "Only tasks due on or before this day. " + dueDescription
                    ],
                    "due_after": [
                        "type": "string",
                        "description": "Only tasks due on or after this day. " + dueDescription
                    ],
                    "text": [
                        "type": "string",
                        "description": "Only tasks whose title contains this text (case and accents ignored)."
                    ],
                    "include_done_log": [
                        "type": "boolean",
                        "description": "Also list finished tasks the daily cleanup moved to the Done log (most recently finished first). Defaults to false."
                    ]
                ],
                "additionalProperties": false
            ]
        ],
        [
            "name": "create_task",
            "title": "Create Attic Task",
            "description": "Create a task directly in Attic. Supply parent_id to create a subtask of an unfinished main task. One level only. Completing all subtasks does not automatically complete the parent. Use backlog for ideas. Optional tags, due date and priority. The title is used as given.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "Short task title. Whitespace is collapsed."
                    ],
                    "status": [
                        "type": "string",
                        "enum": ["todo", "inProgress", "backlog"],
                        "description": "Initial status. Defaults to todo (the Now list); backlog puts it in Backlog."
                    ],
                    "state": [
                        "type": "string",
                        "enum": ["todo", "inProgress", "backlog"],
                        "description": "Same as status."
                    ],
                    "priority": [
                        "type": "string",
                        "enum": TaskPriority.allCases.map(\.rawValue),
                        "description": "Priority. Defaults to none."
                    ],
                    "parent_id": [
                        "type": "string",
                        "description": "Optional unfinished main task UUID. Creates an indented subtask."
                    ],
                    "tags": tagsSchema,
                    "due": [
                        "type": "string",
                        "description": dueDescription
                    ]
                ],
                "required": ["title"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "update_task",
            "title": "Update Attic Task",
            "description": "Update a main task or subtask. Change title, status (state), priority, tags (replaces the list) or due date (null or an empty string clears it). backlog moves a task to Backlog; todo brings it back to Now. Finish all subtasks before completing a parent; reopen a completed parent before reopening a child. Parent completion stays manual. A task in the Done log (include_done_log in list_tasks) comes back to Now as to do when its status is set to todo, inProgress or backlog.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Task id returned by list_tasks or create_task."
                    ],
                    "title": ["type": "string"],
                    "status": [
                        "type": "string",
                        "enum": TaskStatus.allCases.map(\.rawValue)
                    ],
                    "state": [
                        "type": "string",
                        "enum": TaskStatus.allCases.map(\.rawValue),
                        "description": "Same as status."
                    ],
                    "priority": [
                        "type": "string",
                        "enum": TaskPriority.allCases.map(\.rawValue)
                    ],
                    "tags": tagsSchema,
                    "due": [
                        "type": ["string", "null"],
                        "description": dueDescription + " Null or an empty string clears it."
                    ]
                ],
                "required": ["id"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "delete_task",
            "title": "Delete Attic Task",
            "description": "Move a task AND all its subtasks to Recently Deleted, where they can be restored for 30 days (restore_item). Deleting a subtask leaves the parent intact. Prefer update_task with status done for finished work.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Task id returned by list_tasks or create_task."
                    ]
                ],
                "required": ["id"],
                "additionalProperties": false
            ]
        ]
    ]

    static let noteDefinitions: [[String: Any]] = [
        [
            "name": "list_notes",
            "title": "List Attic Notes",
            "description": "Read notes directly from Attic. Use this instead of opening the Attic app with Computer Use. Notes are returned newest first.",
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false
            ]
        ],
        [
            "name": "create_note",
            "title": "Create Attic Note",
            "description": "Create a note directly in Attic without using its graphical interface. Provide a body and an optional title; either a non-empty title or body is required.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "Optional short title. Whitespace is collapsed."
                    ],
                    "body": [
                        "type": "string",
                        "description": "Note body. Meaningful leading and trailing whitespace is preserved."
                    ]
                ],
                "additionalProperties": false
            ]
        ],
        [
            "name": "update_note",
            "title": "Update Attic Note",
            "description": "Update a Attic note directly without using its graphical interface. Change its title, body, or both; a title or body must remain non-empty.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Note id returned by list_notes or create_note."
                    ],
                    "title": ["type": "string"],
                    "body": ["type": "string"]
                ],
                "required": ["id"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "delete_note",
            "title": "Delete Attic Note",
            "description": "Move a note (with its attachments) to Recently Deleted, where it can be restored for 30 days (restore_item).",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "Note id returned by list_notes or create_note."
                    ]
                ],
                "required": ["id"],
                "additionalProperties": false
            ]
        ]
    ]

    static let tagsSchema: [String: Any] = [
        "type": "array",
        "items": ["type": "string"],
        "description": "Tags: lowercase letters, numbers and hyphens. A leading # is ignored; other text is normalised (\"Big Idea\" becomes big-idea)."
    ]

    static let dueDescription = "Due date: an ISO day (2026-09-30) or English such as today, tomorrow, fri, next week, sep 30, 30/9, in 3 days."

    static let itemSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": AtticItemKind.allCases.map(\.rawValue)],
            "id": ["type": "string", "description": "The item's UUID."]
        ],
        "required": ["kind", "id"],
        "additionalProperties": false
    ]

    static let libraryDefinitions: [[String: Any]] = [
        [
            "name": "delete_item",
            "title": "Delete Attic Item",
            "description": "Move a task (with its subtasks), note or canvas to Recently Deleted. It stays restorable for 30 days with restore_item. Agents cannot delete anything permanently.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": AtticItemKind.allCases.map(\.rawValue)],
                    "id": ["type": "string", "description": "The item's UUID."]
                ],
                "required": ["kind", "id"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "restore_item",
            "title": "Restore Attic Item",
            "description": "Bring an item back from Recently Deleted to where it was, with its subtasks, attachments and links.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": AtticItemKind.allCases.map(\.rawValue)],
                    "id": ["type": "string", "description": "The item's UUID, from list_deleted."]
                ],
                "required": ["kind", "id"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "list_deleted",
            "title": "List Recently Deleted",
            "description": "List what is in Recently Deleted, newest first, with when each item will be removed for good.",
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false
            ]
        ],
        [
            "name": "list_tags",
            "title": "List Attic Tags",
            "description": "List every tag in use on tasks, notes and canvases, with how many items carry it. Reuse existing spellings.",
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false
            ]
        ],
        [
            "name": "update_tags",
            "title": "Rename or Merge Attic Tags",
            "description": "Rename a tag on every item (action rename, from a tag), or merge several tags into one (action merge, from a list). Renaming onto an existing tag merges them.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["rename", "merge"]],
                    "from": [
                        "description": "rename: the tag to rename. merge: the tags to merge.",
                        "oneOf": [
                            ["type": "string"],
                            ["type": "array", "items": ["type": "string"]]
                        ]
                    ],
                    "to": ["type": "string", "description": "The resulting tag."]
                ],
                "required": ["action", "from", "to"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "link",
            "title": "Link Attic Items",
            "description": "With target: link item to target (a card in a note, a canvas attached to a task, or a reference), then list item's links. Without target: list item's links and backlinks (what links to it).",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "item": itemSchema,
                    "target": itemSchema,
                    "link_kind": [
                        "type": "string",
                        "enum": ItemLinkKind.allCases.map(\.rawValue),
                        "description": "card, attachment or reference. Defaults to reference."
                    ]
                ],
                "required": ["item"],
                "additionalProperties": false
            ]
        ]
    ]

    var definitions: [[String: Any]] {
        Self.taskDefinitions + (noteStore != nil ? Self.noteDefinitions : []) + Self.libraryDefinitions
            + (settingsTools != nil ? AgentSettingsTools.definitions : [])
    }

    func call(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "list_tasks": try listTasks(arguments)
        case "create_task": try createTask(arguments)
        case "update_task": try updateTask(arguments)
        case "delete_task": try deleteTask(arguments)
        case "list_notes": try listNotes(arguments)
        case "create_note": try createNote(arguments)
        case "update_note": try updateNote(arguments)
        case "delete_note": try deleteNote(arguments)
        case "delete_item": try deleteItem(arguments)
        case "restore_item": try restoreItem(arguments)
        case "list_deleted": try listDeleted(arguments)
        case "list_tags": try listTags(arguments)
        case "update_tags": try updateTags(arguments)
        case "link": try link(arguments)
        default: try callSettingsTool(name, arguments)
        }
    }

    private func callSettingsTool(_ name: String, _ arguments: [String: Any]) throws -> String {
        guard let settingsTools, AgentSettingsTools.toolNames.contains(name) else {
            throw AgentToolError.unknownTool(name)
        }
        return try settingsTools.call(name: name, arguments: arguments)
    }

    private func listTasks(_ arguments: [String: Any]) throws -> String {
        let arguments = try withStateAlias(arguments)
        let statuses: [TaskStatus]
        if arguments["status"] != nil {
            statuses = [try status(from: arguments, allowed: TaskStatus.allCases)]
        } else {
            statuses = [.inProgress, .todo, .done, .backlog]
        }
        let parentID = try parentID(from: arguments)
        var tasks = parentID.map { id in store.subtasks(of: id).filter { statuses.contains($0.status) } }
            ?? statuses.flatMap(store.orderedTasks(for:))
        if try bool(arguments, "include_done_log"), statuses.contains(.done) {
            tasks += parentID.map { store.doneLogSubtasks(of: $0) } ?? doneLogTasks()
        }
        if let raw = arguments["tag"] {
            guard let string = raw as? String, let tag = AtticTag.normalize(string) else {
                throw AgentToolError.invalidArguments("tag must be a tag (letters, numbers and hyphens).")
            }
            tasks = tasks.filter { $0.tags.contains(tag) }
        }
        if let before = try dayFilter(arguments, "due_before") {
            tasks = tasks.filter { $0.dueDay.map { $0 <= before } == true }
        }
        if let after = try dayFilter(arguments, "due_after") {
            tasks = tasks.filter { $0.dueDay.map { $0 >= after } == true }
        }
        if let raw = arguments["text"] {
            guard let text = raw as? String else { throw AgentToolError.invalidArguments("text must be a string.") }
            let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !needle.isEmpty { tasks = tasks.filter { $0.title.localizedStandardContains(needle) } }
        }
        return try encode(["count": tasks.count, "tasks": tasks.map(serialize)])
    }

    /// Every main task and subtask in the Done log, most recently finished
    /// first, read a page at a time.
    private func doneLogTasks() -> [TaskItem] {
        var result: [TaskItem] = []
        var shown = Set<UUID>()
        var cursor = TaskStore.DoneLogCursor()
        while true {
            let page = store.doneLogPage(from: cursor, limit: 500, excluding: shown)
            for task in page.tasks {
                shown.insert(task.id)
                result.append(task)
                result += store.doneLogSubtasks(of: task.id)
            }
            guard page.hasMore else { return result }
            cursor = page.next
        }
    }

    /// `state` is the name the app uses for `status`; either may be given,
    /// not both with different values.
    private func withStateAlias(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let state = arguments["state"] else { return arguments }
        var copy = arguments
        copy.removeValue(forKey: "state")
        if let status = arguments["status"] {
            guard (status as? String) == (state as? String) else {
                throw AgentToolError.invalidArguments("Give status or state, not both.")
            }
            return copy
        }
        copy["status"] = state
        return copy
    }

    private func bool(_ arguments: [String: Any], _ key: String) throws -> Bool {
        guard let raw = arguments[key] else { return false }
        guard let value = raw as? Bool else { throw AgentToolError.invalidArguments("\(key) must be true or false.") }
        return value
    }

    private func dayFilter(_ arguments: [String: Any], _ key: String) throws -> DueDay? {
        guard let raw = arguments[key] else { return nil }
        guard let phrase = raw as? String, let day = parser.parseDueDay(phrase) else {
            throw AgentToolError.invalidArguments("\(key) must be a day such as 2026-09-30, today, fri or sep 30.")
        }
        return day
    }

    private func createTask(_ arguments: [String: Any]) throws -> String {
        let arguments = try withStateAlias(arguments)
        guard let title = arguments["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArguments("A non-empty title is required.")
        }
        let status = arguments["status"] == nil
            ? .todo
            : try status(from: arguments, allowed: [.todo, .inProgress, .backlog])
        let priority = try priority(from: arguments)
        let parentID = try parentID(from: arguments)
        let tags = try tags(from: arguments) ?? []
        let due = try dueDay(from: arguments, allowingClear: false) ?? nil
        // The title is kept literally (agents' titles are not shorthand); the
        // draft step applies the same creation rules as every other path.
        let draft = TaskDraft(
            title: title,
            tags: tags,
            dueDay: due,
            priority: priority,
            status: status,
            parentID: parentID
        )
        guard let task = library.createTasks([draft])?.first else {
            throw AgentToolError.storeFailure(store.lastErrorMessage ?? "Unknown error.")
        }
        return try encode(["task": serialize(task)])
    }

    private func updateTask(_ arguments: [String: Any]) throws -> String {
        // Validate every argument before mutating so an invalid one
        // doesn't leave the task half-updated.
        let arguments = try withStateAlias(arguments)
        let task = try findTask(arguments, includingDoneLog: true)
        var newTitle: String?
        if let rawTitle = arguments["title"] {
            guard let title = rawTitle as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentToolError.invalidArguments("The title must be a non-empty string.")
            }
            newTitle = title
        }
        let newPriority = arguments["priority"] == nil ? nil : try priority(from: arguments)
        let newStatus = arguments["status"] == nil
            ? nil
            : try status(from: arguments, allowed: TaskStatus.allCases)
        let newTags = try tags(from: arguments)
        let newDue = try dueDay(from: arguments, allowingClear: true)

        // A task in the Done log comes back to Now first (as to do), then
        // takes the rest of the edit; each is its own undoable step.
        if store.task(withID: task.id) == nil {
            guard let newStatus, newStatus != .done else {
                throw AgentToolError.invalidArguments("This task is in the Done log. Set status to todo (or inProgress, backlog) to bring it back to Now first.")
            }
            try perform { library.restoreToNow(task.id) }
        }
        try perform {
            library.updateTask(
                task.id,
                title: newTitle,
                priority: newPriority,
                status: newStatus,
                tags: newTags,
                dueDay: newDue
            )
        }
        return try encode(["task": serialize(store.task(withID: task.id) ?? task)])
    }

    private func deleteTask(_ arguments: [String: Any]) throws -> String {
        let task = try findTask(arguments)
        let id = task.id.uuidString
        try performLibrary { library.delete(AtticItemRef(.task, task.id)) }
        return try encode(["deleted": id])
    }

    private func findTask(_ arguments: [String: Any], includingDoneLog: Bool = false) throws -> TaskItem {
        guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID) else {
            throw AgentToolError.invalidArguments("A task id (UUID) is required.")
        }
        guard let task = store.tasks.first(where: { $0.id == id })
            ?? (includingDoneLog ? store.listedTask(withID: id) : nil) else {
            throw AgentToolError.notFound(rawID)
        }
        return task
    }

    private func parentID(from arguments: [String: Any]) throws -> UUID? {
        guard let raw = arguments["parent_id"] else { return nil }
        guard let string = raw as? String, let id = UUID(uuidString: string) else {
            throw AgentToolError.invalidArguments("parent_id must be a main task UUID.")
        }
        guard store.tasks.contains(where: { $0.id == id && $0.parentID == nil }) else {
            throw AgentToolError.invalidArguments("parent_id must identify an existing main task.")
        }
        return id
    }

    private func status(from arguments: [String: Any], allowed: [TaskStatus]) throws -> TaskStatus {
        guard let raw = arguments["status"] as? String,
              let status = TaskStatus(rawValue: raw),
              allowed.contains(status) else {
            let options = allowed.map(\.rawValue).joined(separator: ", ")
            throw AgentToolError.invalidArguments("Invalid status. Use one of: \(options).")
        }
        return status
    }

    private func priority(from arguments: [String: Any]) throws -> TaskPriority {
        guard let raw = arguments["priority"] else { return .none }
        guard let rawString = raw as? String, let priority = TaskPriority(rawValue: rawString) else {
            let options = TaskPriority.allCases.map(\.rawValue).joined(separator: ", ")
            throw AgentToolError.invalidArguments("Invalid priority. Use one of: \(options).")
        }
        return priority
    }

    private func perform(_ change: () throws -> Bool) throws {
        guard try change() else {
            throw AgentToolError.storeFailure(store.lastErrorMessage ?? "Unknown error.")
        }
    }

    // MARK: - Notes

    private func listNotes(_ arguments: [String: Any]) throws -> String {
        guard let noteStore else { throw AgentToolError.unknownTool("list_notes") }
        let notes = noteStore.orderedNotes()
        return try encode(["count": notes.count, "notes": notes.map(serializeNote)])
    }

    private func createNote(_ arguments: [String: Any]) throws -> String {
        guard let noteStore else { throw AgentToolError.unknownTool("create_note") }
        let title = (arguments["title"] as? String) ?? ""
        let body = (arguments["body"] as? String) ?? ""
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
            throw AgentToolError.invalidArguments("A non-empty title or body is required.")
        }
        guard let note = noteStore.create(title: title, body: body) else {
            throw AgentToolError.storeFailure(noteStore.lastErrorMessage ?? "Unknown error.")
        }
        return try encode(["note": serializeNote(note)])
    }

    private func updateNote(_ arguments: [String: Any]) throws -> String {
        guard let noteStore else { throw AgentToolError.unknownTool("update_note") }
        let note = try findNote(arguments)
        var newTitle: String?
        var newBody: String?
        if let rawTitle = arguments["title"] {
            guard let title = rawTitle as? String else {
                throw AgentToolError.invalidArguments("The title must be a string.")
            }
            newTitle = title
        }
        if let rawBody = arguments["body"] {
            guard let body = rawBody as? String else {
                throw AgentToolError.invalidArguments("The body must be a string.")
            }
            newBody = body
        }
        guard newTitle != nil || newBody != nil else {
            throw AgentToolError.invalidArguments("Provide a title or body to update.")
        }
        let destinationTitle = newTitle.map(NoteStore.normalizedTitle) ?? note.title
        let destinationBody = newBody ?? note.body
        guard !destinationTitle.isEmpty || NoteStore.hasMeaningfulBody(destinationBody) else {
            throw AgentToolError.invalidArguments("A title or body must remain non-empty.")
        }
        try performNote {
            noteStore.update(note, title: newTitle, body: newBody)
        }
        return try encode(["note": serializeNote(note)])
    }

    private func deleteNote(_ arguments: [String: Any]) throws -> String {
        guard noteStore != nil else { throw AgentToolError.unknownTool("delete_note") }
        let note = try findNote(arguments)
        let id = note.id.uuidString
        try performLibrary { library.delete(AtticItemRef(.note, note.id)) }
        return try encode(["deleted": id])
    }

    private func findNote(_ arguments: [String: Any]) throws -> NoteItem {
        guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID) else {
            throw AgentToolError.invalidArguments("A note id (UUID) is required.")
        }
        guard let noteStore, let note = noteStore.notes.first(where: { $0.id == id }) else {
            throw AgentToolError.invalidArguments("No note exists with id \(rawID).")
        }
        return note
    }

    private func performNote(_ change: () throws -> Bool) throws {
        guard try change() else {
            throw AgentToolError.storeFailure(noteStore?.lastErrorMessage ?? "Unknown error.")
        }
    }

    private func serializeNote(_ note: NoteItem) -> [String: Any] {
        [
            "id": note.id.uuidString,
            "title": note.title,
            "body": note.body,
            "createdAt": Self.dateFormatter.string(from: note.createdAt),
            "updatedAt": Self.dateFormatter.string(from: note.updatedAt),
            "tags": note.tags
        ]
    }

    private func serialize(_ task: TaskItem) -> [String: Any] {
        var payload: [String: Any] = [
            "id": task.id.uuidString,
            "title": task.title,
            "status": task.status.rawValue,
            "priority": task.priority.rawValue,
            "createdAt": Self.dateFormatter.string(from: task.createdAt),
            "updatedAt": Self.dateFormatter.string(from: task.updatedAt)
        ]
        if let completedAt = task.completedAt {
            payload["completedAt"] = Self.dateFormatter.string(from: completedAt)
        }
        if let parentID = task.parentID { payload["parent_id"] = parentID.uuidString }
        payload["tags"] = task.tags
        if let due = task.dueDay { payload["due"] = due.rawValue }
        if let logged = task.doneLoggedAt { payload["done_logged_at"] = Self.dateFormatter.string(from: logged) }
        return payload
    }

    // MARK: - Tags and dates

    /// nil when absent; every entry must be a string that normalises to a tag.
    private func tags(from arguments: [String: Any]) throws -> [String]? {
        guard let raw = arguments["tags"] else { return nil }
        guard let list = raw as? [Any] else {
            throw AgentToolError.invalidArguments("tags must be an array of strings.")
        }
        return try list.map { entry in
            guard let string = entry as? String, let tag = AtticTag.normalize(string) else {
                throw AgentToolError.invalidArguments("Invalid tag \(entry). Use letters, numbers and hyphens.")
            }
            return tag
        }
    }

    /// nil when absent; `.some(nil)` clears (update only).
    private func dueDay(from arguments: [String: Any], allowingClear: Bool) throws -> DueDay?? {
        guard let raw = arguments["due"] else { return nil }
        if raw is NSNull || (raw as? String)?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            guard allowingClear else {
                throw AgentToolError.invalidArguments("due must be a date such as 2026-09-30 or tomorrow.")
            }
            return .some(nil)
        }
        guard let phrase = raw as? String, let day = parser.parseDueDay(phrase) else {
            throw AgentToolError.invalidArguments("Couldn’t understand the due date. Use an ISO day such as 2026-09-30, or today, tomorrow, fri, next week, sep 30, in 3 days.")
        }
        return .some(day)
    }

    // MARK: - Recently Deleted, tags and links

    private func itemRef(from object: Any?, field: String) throws -> AtticItemRef {
        guard let object = object as? [String: Any],
              let rawKind = object["kind"] as? String, let kind = AtticItemKind(rawValue: rawKind),
              let rawID = object["id"] as? String, let id = UUID(uuidString: rawID) else {
            let kinds = AtticItemKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw AgentToolError.invalidArguments("\(field) needs a kind (\(kinds)) and an id (UUID).")
        }
        return AtticItemRef(kind, id)
    }

    private func deleteItem(_ arguments: [String: Any]) throws -> String {
        let ref = try itemRef(from: arguments, field: "The item")
        guard library.state(of: ref) == .live else {
            throw AgentToolError.invalidArguments("No \(ref.kind.rawValue) exists with id \(ref.id.uuidString).")
        }
        try performLibrary { library.delete(ref) }
        let restorableUntil = RecentlyDeletedPolicy.expiry(deletedAt: Date(), calendar: .autoupdatingCurrent)
        return try encode([
            "deleted": ref.id.uuidString,
            "kind": ref.kind.rawValue,
            "restorable_until": Self.dateFormatter.string(from: restorableUntil)
        ])
    }

    private func restoreItem(_ arguments: [String: Any]) throws -> String {
        let ref = try itemRef(from: arguments, field: "The item")
        guard library.state(of: ref) == .deleted else {
            throw AgentToolError.invalidArguments("No \(ref.kind.rawValue) with id \(ref.id.uuidString) is in Recently Deleted.")
        }
        try performLibrary { library.restore(ref) }
        return try encode(["restored": ref.id.uuidString, "kind": ref.kind.rawValue])
    }

    private func listDeleted(_ arguments: [String: Any]) throws -> String {
        let items = library.recentlyDeleted()
        return try encode([
            "count": items.count,
            "items": items.map { item -> [String: Any] in
                [
                    "kind": item.ref.kind.rawValue,
                    "id": item.ref.id.uuidString,
                    "title": item.title,
                    "deletedAt": Self.dateFormatter.string(from: item.deletedAt),
                    // null: kept until removed by hand (a canvas deleted
                    // before Recently Deleted existed).
                    "expiresAt": item.expiresAt(calendar: .autoupdatingCurrent)
                        .map { Self.dateFormatter.string(from: $0) as Any } ?? NSNull(),
                    "included": item.includedCount
                ]
            }
        ])
    }

    private func listTags(_ arguments: [String: Any]) throws -> String {
        let counts = library.tags.counts()
        return try encode([
            "count": counts.count,
            "tags": counts.map { ["name": $0.name, "count": $0.count] as [String: Any] }
        ])
    }

    private func updateTags(_ arguments: [String: Any]) throws -> String {
        guard let action = arguments["action"] as? String, ["rename", "merge"].contains(action) else {
            throw AgentToolError.invalidArguments("action must be rename or merge.")
        }
        guard let rawTarget = arguments["to"] as? String, let target = AtticTag.normalize(rawTarget) else {
            throw AgentToolError.invalidArguments("to must be a tag (letters, numbers and hyphens).")
        }
        let sources: [String]
        switch (action, arguments["from"]) {
        case let ("rename", source as String):
            sources = [source]
        case let ("merge", list as [Any]) where !list.isEmpty:
            sources = try list.map { entry in
                guard let string = entry as? String else {
                    throw AgentToolError.invalidArguments("from must list tags as strings.")
                }
                return string
            }
        default:
            throw AgentToolError.invalidArguments(action == "rename"
                ? "rename needs from: the tag to rename."
                : "merge needs from: a non-empty list of tags.")
        }
        guard sources.allSatisfy({ AtticTag.normalize($0) != nil }) else {
            throw AgentToolError.invalidArguments("Every tag in from must use letters, numbers and hyphens.")
        }
        try performLibrary { library.mergeTags(sources, into: target) }
        let counts = library.tags.counts()
        return try encode([
            "action": action,
            "tag": target,
            "tags": counts.map { ["name": $0.name, "count": $0.count] as [String: Any] }
        ])
    }

    private func link(_ arguments: [String: Any]) throws -> String {
        let item = try itemRef(from: arguments["item"], field: "item")
        guard library.state(of: item) == .live else {
            throw AgentToolError.invalidArguments("No \(item.kind.rawValue) exists with id \(item.id.uuidString).")
        }
        var payload: [String: Any] = [:]
        if arguments["target"] != nil {
            let target = try itemRef(from: arguments["target"], field: "target")
            let kind: ItemLinkKind
            if let raw = arguments["link_kind"] {
                guard let string = raw as? String, let parsed = ItemLinkKind(rawValue: string) else {
                    let kinds = ItemLinkKind.allCases.map(\.rawValue).joined(separator: ", ")
                    throw AgentToolError.invalidArguments("link_kind must be one of: \(kinds).")
                }
                kind = parsed
            } else {
                kind = .reference
            }
            guard let created = library.link(item, to: target, kind: kind) else {
                throw AgentToolError.invalidArguments(library.links.lastErrorMessage ?? "The items could not be linked.")
            }
            payload["link"] = serializeLink(created)
        } else if arguments["link_kind"] != nil {
            throw AgentToolError.invalidArguments("link_kind needs a target.")
        }
        payload["links"] = library.links.links(from: item).map(serializeLink)
        payload["backlinks"] = library.links.backlinks(to: item).map(serializeLink)
        return try encode(payload)
    }

    private func serializeLink(_ link: ItemLinkRecord) -> [String: Any] {
        func endpoint(_ ref: AtticItemRef) -> [String: Any] {
            var value: [String: Any] = ["kind": ref.kind.rawValue, "id": ref.id.uuidString]
            if let title = library.title(of: ref) { value["title"] = title }
            return value
        }
        return [
            "id": link.id.uuidString,
            "kind": link.kind.rawValue,
            "source": endpoint(link.source),
            "target": endpoint(link.target),
            "createdAt": Self.dateFormatter.string(from: link.createdAt)
        ]
    }

    private func performLibrary(_ change: () -> Bool) throws {
        guard change() else {
            throw AgentToolError.storeFailure(library.lastErrorMessage ?? store.lastErrorMessage ?? "Unknown error.")
        }
    }

    private func encode(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static let dateFormatter = ISO8601DateFormatter()
}
