import Foundation

enum AgentToolError: Error {
    case unknownTool(String)
    case invalidArguments(String)
    case notFound(String)
    case storeFailure(String)

    var message: String {
        switch self {
        case let .unknownTool(name): "Unknown tool: \(name)"
        case let .invalidArguments(details): details
        case let .notFound(id): "No task exists with id \(id)."
        case let .storeFailure(details): "The change could not be saved: \(details)"
        }
    }
}

/// Executes MCP tool calls against the app's task store so agent edits follow
/// the same rules (ordering, timestamps, cleanup) as edits made in the UI.
@MainActor
final class AgentTaskTools {
    private let store: TaskStore

    private let noteStore: NoteStore?

    init(store: TaskStore, noteStore: NoteStore? = nil) {
        self.store = store
        self.noteStore = noteStore
    }

    static let taskDefinitions: [[String: Any]] = [
        [
            "name": "list_tasks",
            "title": "List Attic Tasks",
            "description": "Read tasks directly from Attic. Use this instead of opening the Attic app with Computer Use. Tasks are returned in display order and can be filtered by status.",
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
                    ]
                ],
                "additionalProperties": false
            ]
        ],
        [
            "name": "create_task",
            "title": "Create Attic Task",
            "description": "Create a task directly in Attic without using its graphical interface. Use status backlog for ideas that are not ready to work on.",
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
                        "description": "Initial status. Defaults to todo."
                    ],
                    "priority": [
                        "type": "string",
                        "enum": TaskPriority.allCases.map(\.rawValue),
                        "description": "Priority. Defaults to none."
                    ]
                ],
                "required": ["title"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "update_task",
            "title": "Update Attic Task",
            "description": "Update a Attic task directly without using its graphical interface. Change its title, status, or priority; set status to done to complete it or todo to reopen it.",
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
                    "priority": [
                        "type": "string",
                        "enum": TaskPriority.allCases.map(\.rawValue)
                    ]
                ],
                "required": ["id"],
                "additionalProperties": false
            ]
        ],
        [
            "name": "delete_task",
            "title": "Delete Attic Task",
            "description": "Permanently delete a task directly from Attic. Prefer update_task with status done for finished work.",
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
            "description": "Permanently delete a note directly from Attic.",
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

    var definitions: [[String: Any]] {
        Self.taskDefinitions + (noteStore != nil ? Self.noteDefinitions : [])
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
        default: throw AgentToolError.unknownTool(name)
        }
    }

    private func listTasks(_ arguments: [String: Any]) throws -> String {
        let statuses: [TaskStatus]
        if arguments["status"] != nil {
            statuses = [try status(from: arguments, allowed: TaskStatus.allCases)]
        } else {
            statuses = [.inProgress, .todo, .done, .backlog]
        }
        let tasks = statuses.flatMap(store.orderedTasks(for:))
        return try encode(["count": tasks.count, "tasks": tasks.map(serialize)])
    }

    private func createTask(_ arguments: [String: Any]) throws -> String {
        guard let title = arguments["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArguments("A non-empty title is required.")
        }
        let status = arguments["status"] == nil
            ? .todo
            : try status(from: arguments, allowed: [.todo, .inProgress, .backlog])
        let priority = try priority(from: arguments)
        guard let task = store.create(title: title, priority: priority, status: status) else {
            throw AgentToolError.storeFailure(store.lastErrorMessage ?? "Unknown error.")
        }
        return try encode(["task": serialize(task)])
    }

    private func updateTask(_ arguments: [String: Any]) throws -> String {
        // Validate every argument before mutating so an invalid one
        // doesn't leave the task half-updated.
        let task = try findTask(arguments)
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

        try perform {
            store.update(
                task,
                title: newTitle,
                priority: newPriority,
                status: newStatus
            )
        }
        return try encode(["task": serialize(task)])
    }

    private func deleteTask(_ arguments: [String: Any]) throws -> String {
        let task = try findTask(arguments)
        let id = task.id.uuidString
        try perform { store.delete(task) }
        return try encode(["deleted": id])
    }

    private func findTask(_ arguments: [String: Any]) throws -> TaskItem {
        guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID) else {
            throw AgentToolError.invalidArguments("A task id (UUID) is required.")
        }
        guard let task = store.tasks.first(where: { $0.id == id }) else {
            throw AgentToolError.notFound(rawID)
        }
        return task
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
        try performNote {
            noteStore.update(note, title: newTitle, body: newBody)
        }
        return try encode(["note": serializeNote(note)])
    }

    private func deleteNote(_ arguments: [String: Any]) throws -> String {
        guard let noteStore else { throw AgentToolError.unknownTool("delete_note") }
        let note = try findNote(arguments)
        let id = note.id.uuidString
        try performNote { noteStore.delete(note) }
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
            "updatedAt": Self.dateFormatter.string(from: note.updatedAt)
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
        return payload
    }

    private func encode(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static let dateFormatter = ISO8601DateFormatter()
}
