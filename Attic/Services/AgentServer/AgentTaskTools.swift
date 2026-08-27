import Foundation

enum AgentToolError: Error {
    case unknownTool(String)
    case invalidArguments(String)
    case notFound(resource: String, id: String)
    case conflict(resource: String, id: String, currentRevision: String)
    case contentTooLarge(resource: String, id: String)
    case storeFailure

    var code: String {
        switch self {
        case .unknownTool: "unknown_tool"
        case .invalidArguments: "invalid_arguments"
        case .notFound: "not_found"
        case .conflict: "conflict"
        case .contentTooLarge: "content_too_large"
        case .storeFailure: "persistence_failure"
        }
    }

    var message: String {
        switch self {
        case .unknownTool: "Unknown tool."
        case let .invalidArguments(details): details
        case let .notFound(resource, id): "No \(resource) exists with id \(id)."
        case let .conflict(resource, id, _):
            "The \(resource) \(id) changed after it was read. Fetch it again and retry with the new revision."
        case let .contentTooLarge(resource, id):
            "The \(resource) \(id) exceeds the MCP plain-text limits and cannot be returned safely."
        case .storeFailure: "The change could not be saved."
        }
    }

    var structuredContent: [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if case let .conflict(_, _, currentRevision) = self {
            error["currentRevision"] = currentRevision
        }
        return ["error": error]
    }
}

/// Executes MCP task calls against the authoritative `TaskStore` and composes
/// the separately validated Notes surface when a `NoteStore` exists.
@MainActor
final class AgentTaskTools {
    private static let maximumTaskTitleUTF8Bytes = 4_096

    private let store: TaskStore
    private let noteTools: AgentNoteTools?

    init(store: TaskStore, noteStore: NoteStore? = nil) {
        self.store = store
        noteTools = noteStore.map { AgentNoteTools(store: $0) }
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
                        "maxLength": maximumTaskTitleUTF8Bytes,
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
            "description": "Update an Attic task directly without using its graphical interface. Change its title, status, or priority; set status to done to complete it or todo to reopen it.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": taskIDSchema,
                    "title": ["type": "string", "maxLength": maximumTaskTitleUTF8Bytes],
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
                "properties": ["id": taskIDSchema],
                "required": ["id"],
                "additionalProperties": false
            ]
        ]
    ]

    var definitions: [[String: Any]] {
        Self.taskDefinitions + (noteTools == nil ? [] : AgentNoteTools.definitions)
    }

    func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        switch name {
        case "list_tasks": try listTasks(arguments)
        case "create_task": try createTask(arguments)
        case "update_task": try updateTask(arguments)
        case "delete_task": try deleteTask(arguments)
        default:
            guard let noteTools else { throw AgentToolError.unknownTool(name) }
            return try noteTools.call(name: name, arguments: arguments)
        }
    }

    private func listTasks(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["status"])
        let statuses: [TaskStatus]
        if arguments["status"] != nil {
            statuses = [try status(from: arguments, allowed: TaskStatus.allCases)]
        } else {
            statuses = [.inProgress, .todo, .done, .backlog]
        }
        let tasks = statuses.flatMap(store.orderedTasks(for:))
        return ["count": tasks.count, "tasks": tasks.map(serialize)]
    }

    private func createTask(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["title", "status", "priority"])
        let title = try validatedTaskTitle(arguments["title"])
        let status = arguments["status"] == nil
            ? .todo
            : try status(from: arguments, allowed: [.todo, .inProgress, .backlog])
        let priority = try priority(from: arguments)
        guard let task = store.create(title: title, priority: priority, status: status) else {
            throw AgentToolError.storeFailure
        }
        return ["task": serialize(task)]
    }

    private func updateTask(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["id", "title", "status", "priority"])
        let task = try findTask(arguments)
        let hasTitle = arguments["title"] != nil
        let hasPriority = arguments["priority"] != nil
        let hasStatus = arguments["status"] != nil
        guard hasTitle || hasPriority || hasStatus else {
            throw AgentToolError.invalidArguments("Provide title, status, or priority to update.")
        }
        let newTitle = hasTitle ? try validatedTaskTitle(arguments["title"]) : nil
        let newPriority = hasPriority ? try priority(from: arguments) : nil
        let newStatus = hasStatus
            ? try status(from: arguments, allowed: TaskStatus.allCases)
            : nil

        guard store.update(
            task,
            title: newTitle,
            priority: newPriority,
            status: newStatus
        ) else {
            throw AgentToolError.storeFailure
        }
        return ["task": serialize(task)]
    }

    private func deleteTask(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["id"])
        let task = try findTask(arguments)
        let id = task.id.uuidString
        guard store.delete(task) else { throw AgentToolError.storeFailure }
        return ["deleted": id]
    }

    private func findTask(_ arguments: [String: Any]) throws -> TaskItem {
        guard let rawID = arguments["id"] as? String,
              Self.isCanonicalUUIDShape(rawID),
              let id = UUID(uuidString: rawID) else {
            throw AgentToolError.invalidArguments("id must be a UUID string.")
        }
        guard let task = store.tasks.first(where: { $0.id == id }) else {
            throw AgentToolError.notFound(resource: "task", id: rawID)
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

    private func validatedTaskTitle(_ raw: Any?) throws -> String {
        guard let title = raw as? String,
              !title.contains("\0"),
              title.utf8.count <= Self.maximumTaskTitleUTF8Bytes,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArguments(
                "The title must be a non-empty string of at most \(Self.maximumTaskTitleUTF8Bytes) UTF-8 bytes without NUL."
            )
        }
        return title
    }

    private func validateKeys(_ arguments: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw AgentToolError.invalidArguments("Unknown argument fields are not allowed.")
        }
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

    private static func isCanonicalUUIDShape(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard bytes.count == 36 else { return false }
        let hyphens: Set<Int> = [8, 13, 18, 23]
        for (index, byte) in bytes.enumerated() {
            if hyphens.contains(index) {
                guard byte == 45 else { return false }
            } else {
                let isDigit = (48...57).contains(byte)
                let isUpperHex = (65...70).contains(byte)
                let isLowerHex = (97...102).contains(byte)
                guard isDigit || isUpperHex || isLowerHex else { return false }
            }
        }
        return true
    }

    private static let taskIDSchema: [String: Any] = [
        "type": "string",
        "format": "uuid",
        "minLength": 36,
        "maxLength": 36,
        "pattern": "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
        "description": "Task id returned by list_tasks or create_task."
    ]

    private static let dateFormatter = ISO8601DateFormatter()
}
/// Notes-specific MCP surface. All persistence stays in `NoteStore`; this type
/// owns protocol validation, bounded presentation, and safe error mapping only.
@MainActor
final class AgentNoteTools {
    private struct ListCursor {
        let updatedAtBits: UInt64
        let id: UUID
    }

    private let store: NoteStore

    init(store: NoteStore) {
        self.store = store
    }

    static let definitions: [[String: Any]] = [
        [
            "name": "list_notes",
            "title": "List Attic Notes",
            "description": "List bounded note summaries from Attic, newest first. Bodies are not returned; use get_note with an id. Results are presentation-deduplicated by app UUID and include the revision required for safe mutations. Example: {\"limit\":25}.",
            "annotations": annotations(readOnly: true, destructive: false, idempotent: true),
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 100,
                        "default": 50,
                        "description": "Maximum summaries to return."
                    ],
                    "cursor": [
                        "type": "string",
                        "maxLength": 256,
                        "description": "Opaque nextCursor returned by a previous list_notes call."
                    ]
                ],
                "additionalProperties": false
            ],
            "outputSchema": listOutputSchema
        ],
        [
            "name": "get_note",
            "title": "Get Attic Note",
            "description": "Get one complete note by the stable UUID returned by list_notes. Content is UTF-8 plain text; Markdown characters are returned literally and no attributed text or attachments are exposed.",
            "annotations": annotations(readOnly: true, destructive: false, idempotent: true),
            "inputSchema": objectSchema(
                properties: ["id": idSchema(description: "Note id returned by list_notes or create_note.")],
                required: ["id"]
            ),
            "outputSchema": noteOutputSchema
        ],
        [
            "name": "create_note",
            "title": "Create Attic Note",
            "description": "Create a UTF-8 plain-text note. Markdown is stored literally. A meaningful title or body is required; title whitespace is collapsed exactly as in the Attic editor, while body whitespace is preserved. Example: {\"title\":\"Release\",\"body\":\"Checklist\\n\"}.",
            "annotations": annotations(readOnly: false, destructive: false, idempotent: false),
            "inputSchema": objectSchema(properties: [
                "title": titleSchema,
                "body": bodySchema
            ]),
            "outputSchema": noteOutputSchema
        ],
        [
            "name": "update_note",
            "title": "Replace Attic Note Fields",
            "description": "Safely replace only the supplied note fields. An omitted field is unchanged; a supplied body replaces the entire plain-text body exactly. revision is mandatory and a stale value returns a conflict without writing. Example: {\"id\":\"<UUID>\",\"revision\":\"<REVISION>\",\"body\":\"replacement\"}.",
            "annotations": annotations(readOnly: false, destructive: false, idempotent: true),
            "inputSchema": objectSchema(
                properties: [
                    "id": idSchema(description: "Note id returned by list_notes, get_note, or create_note."),
                    "revision": revisionSchema,
                    "title": titleSchema,
                    "body": bodySchema
                ],
                required: ["id", "revision"]
            ),
            "outputSchema": noteOutputSchema
        ],
        [
            "name": "append_note",
            "title": "Append to Attic Note",
            "description": "Append content exactly to the current UTF-8 plain-text body. No newline or separator is inserted; include it in content when wanted. revision is mandatory and a stale value returns a conflict without writing. Example: {\"id\":\"<UUID>\",\"revision\":\"<REVISION>\",\"content\":\"\\nNext line\"}.",
            "annotations": annotations(readOnly: false, destructive: false, idempotent: false),
            "inputSchema": objectSchema(
                properties: [
                    "id": idSchema(description: "Note id returned by list_notes, get_note, or create_note."),
                    "revision": revisionSchema,
                    "content": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": NoteExternalAccessLimits.maximumBodyUTF8Bytes,
                        "description": "Non-empty text appended exactly. The resulting body may not exceed 262144 UTF-8 bytes."
                    ]
                ],
                required: ["id", "revision", "content"]
            ),
            "outputSchema": noteOutputSchema
        ],
        [
            "name": "delete_note",
            "title": "Delete Attic Note",
            "description": "Permanently delete the logical note and every physical CloudKit replica sharing its app UUID. revision is mandatory; stale revisions conflict instead of deleting newer content. Attachments and files are never accessed.",
            "annotations": annotations(readOnly: false, destructive: true, idempotent: false),
            "inputSchema": objectSchema(
                properties: [
                    "id": idSchema(description: "Note id returned by list_notes, get_note, or create_note."),
                    "revision": revisionSchema
                ],
                required: ["id", "revision"]
            ),
            "outputSchema": objectSchema(
                properties: ["deleted": idSchema(description: "Deleted app-level note id.")],
                required: ["deleted"]
            )
        ]
    ]

    func call(name: String, arguments: [String: Any]) throws -> [String: Any] {
        switch name {
        case "list_notes": try listNotes(arguments)
        case "get_note": try getNote(arguments)
        case "create_note": try createNote(arguments)
        case "update_note": try updateNote(arguments)
        case "append_note": try appendNote(arguments)
        case "delete_note": try deleteNote(arguments)
        default: throw AgentToolError.unknownTool(name)
        }
    }

    private func listNotes(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["limit", "cursor"])
        let limit = try integer(arguments["limit"], name: "limit", default: 50, range: 1...100)
        let cursor: ListCursor?
        if let rawCursor = arguments["cursor"] {
            cursor = try parseCursor(rawCursor)
        } else {
            cursor = nil
        }
        let records: [NoteExternalRecord]
        do {
            records = try store.recordsForExternalAccess()
        } catch {
            throw AgentToolError.storeFailure
        }

        let remaining = records.filter { record in
            guard let cursor else { return true }
            let bits = record.updatedAt.timeIntervalSinceReferenceDate.bitPattern
            if bits != cursor.updatedAtBits {
                return record.updatedAt < Date(
                    timeIntervalSinceReferenceDate: Double(bitPattern: cursor.updatedAtBits)
                )
            }
            return record.id.uuidString < cursor.id.uuidString
        }
        let page = Array(remaining.prefix(limit))
        var payload: [String: Any] = [
            "count": page.count,
            "notes": page.map(serializeSummary)
        ]
        if remaining.count > page.count, let last = page.last {
            payload["nextCursor"] = makeCursor(for: last)
        }
        return payload
    }

    private func getNote(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["id"])
        let id = try noteID(arguments)
        return ["note": serialize(try record(id: id))]
    }

    private func createNote(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["title", "body"])
        let title = try optionalString(
            arguments,
            key: "title",
            maximumUTF8Bytes: NoteExternalAccessLimits.maximumTitleUTF8Bytes
        ) ?? ""
        let body = try optionalString(
            arguments,
            key: "body",
            maximumUTF8Bytes: NoteExternalAccessLimits.maximumBodyUTF8Bytes
        ) ?? ""
        let created: NoteExternalRecord
        do {
            created = try store.createForExternalAccess(title: title, body: body)
        } catch {
            throw mapStoreError(error, id: nil)
        }
        return ["note": serialize(created)]
    }

    private func updateNote(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["id", "revision", "title", "body"])
        let id = try noteID(arguments)
        let revision = try expectedRevision(arguments)
        let title = try optionalString(
            arguments,
            key: "title",
            maximumUTF8Bytes: NoteExternalAccessLimits.maximumTitleUTF8Bytes
        )
        let body = try optionalString(
            arguments,
            key: "body",
            maximumUTF8Bytes: NoteExternalAccessLimits.maximumBodyUTF8Bytes
        )
        guard title != nil || body != nil else {
            throw AgentToolError.invalidArguments("Provide title or body to replace.")
        }
        do {
            let updated = try store.updateForExternalAccess(
                id: id,
                expectedRevision: revision,
                title: title,
                body: body
            )
            return ["note": serialize(updated)]
        } catch {
            throw mapStoreError(error, id: id)
        }
    }

    private func appendNote(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["id", "revision", "content"])
        let id = try noteID(arguments)
        let revision = try expectedRevision(arguments)
        let content = try requiredString(
            arguments,
            key: "content",
            maximumUTF8Bytes: NoteExternalAccessLimits.maximumBodyUTF8Bytes
        )
        guard !content.isEmpty else {
            throw AgentToolError.invalidArguments("content must not be empty.")
        }
        do {
            let updated = try store.appendForExternalAccess(
                id: id,
                expectedRevision: revision,
                content: content
            )
            return ["note": serialize(updated)]
        } catch {
            throw mapStoreError(error, id: id)
        }
    }

    private func deleteNote(_ arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["id", "revision"])
        let id = try noteID(arguments)
        let revision = try expectedRevision(arguments)
        do {
            try store.deleteForExternalAccess(id: id, expectedRevision: revision)
        } catch {
            throw mapStoreError(error, id: id)
        }
        return ["deleted": id.uuidString]
    }

    private func record(id: UUID) throws -> NoteExternalRecord {
        do {
            let record = try store.recordForExternalAccess(id: id)
            guard !record.title.contains("\0"),
                  !record.body.contains("\0"),
                  record.title.utf8.count <= NoteExternalAccessLimits.maximumTitleUTF8Bytes,
                  record.body.utf8.count <= NoteExternalAccessLimits.maximumBodyUTF8Bytes else {
                throw AgentToolError.contentTooLarge(resource: "note", id: id.uuidString)
            }
            return record
        } catch let error as AgentToolError {
            throw error
        } catch {
            throw mapStoreError(error, id: id)
        }
    }

    private func mapStoreError(_ error: Error, id: UUID?) -> AgentToolError {
        guard let storeError = error as? NoteExternalAccessError else {
            return .storeFailure
        }
        switch storeError {
        case .notFound:
            return .notFound(resource: "note", id: id?.uuidString ?? "unknown")
        case let .conflict(currentRevision):
            return .conflict(
                resource: "note",
                id: id?.uuidString ?? "unknown",
                currentRevision: currentRevision
            )
        case .invalidContent:
            return .invalidArguments(
                "The note must keep a meaningful title or body and stay within the documented plain-text limits."
            )
        case .persistenceFailure:
            return .storeFailure
        }
    }

    private func noteID(_ arguments: [String: Any]) throws -> UUID {
        guard let raw = arguments["id"] as? String,
              Self.isCanonicalUUIDShape(raw),
              let id = UUID(uuidString: raw) else {
            throw AgentToolError.invalidArguments("id must be a UUID string.")
        }
        return id
    }

    private func expectedRevision(_ arguments: [String: Any]) throws -> String {
        guard let revision = arguments["revision"] as? String,
              Self.isRevisionShape(revision) else {
            throw AgentToolError.invalidArguments(
                "revision must be the opaque value returned by list_notes, get_note, or a prior note mutation."
            )
        }
        return revision
    }

    private func requiredString(
        _ arguments: [String: Any],
        key: String,
        maximumUTF8Bytes: Int
    ) throws -> String {
        guard let value = try optionalString(
            arguments,
            key: key,
            maximumUTF8Bytes: maximumUTF8Bytes
        ) else {
            throw AgentToolError.invalidArguments("\(key) is required and must be a string.")
        }
        return value
    }

    private func optionalString(
        _ arguments: [String: Any],
        key: String,
        maximumUTF8Bytes: Int
    ) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value = raw as? String else {
            throw AgentToolError.invalidArguments("\(key) must be a string.")
        }
        guard !value.contains("\0"), value.utf8.count <= maximumUTF8Bytes else {
            throw AgentToolError.invalidArguments(
                "\(key) must not contain NUL and must be at most \(maximumUTF8Bytes) UTF-8 bytes."
            )
        }
        return value
    }

    private func integer(
        _ raw: Any?,
        name: String,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw else { return defaultValue }
        guard !(raw is Bool), let value = raw as? Int, range.contains(value) else {
            throw AgentToolError.invalidArguments(
                "\(name) must be an integer from \(range.lowerBound) through \(range.upperBound)."
            )
        }
        return value
    }

    private func validateKeys(_ arguments: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw AgentToolError.invalidArguments("Unknown argument fields are not allowed.")
        }
    }

    private func makeCursor(for record: NoteExternalRecord) -> String {
        let payload: [String: Any] = [
            "id": record.id.uuidString,
            "updatedAtBits": String(record.updatedAt.timeIntervalSinceReferenceDate.bitPattern)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return ""
        }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "v1.\(encoded)"
    }

    private func parseCursor(_ rawValue: Any) throws -> ListCursor {
        guard let raw = rawValue as? String,
              raw.count <= 256,
              raw.hasPrefix("v1.") else {
            throw AgentToolError.invalidArguments("cursor must be a nextCursor returned by list_notes.")
        }
        var encoded = String(raw.dropFirst(3))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["id", "updatedAtBits"],
              let rawID = object["id"] as? String,
              Self.isCanonicalUUIDShape(rawID),
              let id = UUID(uuidString: rawID),
              let rawBits = object["updatedAtBits"] as? String,
              let bits = UInt64(rawBits),
              Double(bitPattern: bits).isFinite else {
            throw AgentToolError.invalidArguments("cursor must be a nextCursor returned by list_notes.")
        }
        return ListCursor(updatedAtBits: bits, id: id)
    }

    private func serialize(_ note: NoteExternalRecord) -> [String: Any] {
        [
            "id": note.id.uuidString,
            "title": note.title,
            "body": note.body,
            "contentFormat": "plain_text",
            "createdAt": Self.dateFormatter.string(from: note.createdAt),
            "updatedAt": Self.dateFormatter.string(from: note.updatedAt),
            "revision": note.revision
        ]
    }

    private func serializeSummary(_ note: NoteExternalRecord) -> [String: Any] {
        let safeTitle = Self.boundedPlainText(
            note.title,
            maximumCharacters: 512,
            maximumUTF8Bytes: NoteExternalAccessLimits.maximumTitleUTF8Bytes
        )
        return [
            "id": note.id.uuidString,
            "title": safeTitle,
            "titleTruncated": safeTitle != note.title,
            "preview": Self.preview(note.body),
            "contentFormat": "plain_text",
            "createdAt": Self.dateFormatter.string(from: note.createdAt),
            "updatedAt": Self.dateFormatter.string(from: note.updatedAt),
            "revision": note.revision
        ]
    }

    private static func preview(_ body: String) -> String {
        boundedPlainText(body, maximumCharacters: 200, maximumUTF8Bytes: 512)
    }

    private static func boundedPlainText(
        _ value: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int
    ) -> String {
        var result = ""
        var utf8Bytes = 0
        for character in value.prefix(maximumCharacters) {
            if character == "\0" { continue }
            let text = String(character)
            guard utf8Bytes + text.utf8.count <= maximumUTF8Bytes else { break }
            result.append(character)
            utf8Bytes += text.utf8.count
        }
        return result
    }

    private static func isCanonicalUUIDShape(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard bytes.count == 36 else { return false }
        let hyphens: Set<Int> = [8, 13, 18, 23]
        for (index, byte) in bytes.enumerated() {
            if hyphens.contains(index) {
                guard byte == 45 else { return false }
            } else {
                let isDigit = (48...57).contains(byte)
                let isUpperHex = (65...70).contains(byte)
                let isLowerHex = (97...102).contains(byte)
                guard isDigit || isUpperHex || isLowerHex else { return false }
            }
        }
        return true
    }

    private static func isRevisionShape(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard bytes.count == 46, Array(bytes.prefix(3)) == [118, 49, 58] else {
            return false
        }
        return bytes.dropFirst(3).allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }

    private static func annotations(
        readOnly: Bool,
        destructive: Bool,
        idempotent: Bool
    ) -> [String: Any] {
        [
            "readOnlyHint": readOnly,
            "destructiveHint": destructive,
            "idempotentHint": idempotent,
            "openWorldHint": false
        ]
    }

    private static func objectSchema(
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func idSchema(description: String) -> [String: Any] {
        [
            "type": "string",
            "format": "uuid",
            "minLength": 36,
            "maxLength": 36,
            "pattern": "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
            "description": description
        ]
    }

    private static let revisionSchema: [String: Any] = [
        "type": "string",
        "minLength": 46,
        "maxLength": 46,
        "pattern": "^v1:[A-Za-z0-9_-]{43}$",
        "description": "Opaque optimistic revision returned by a note read or mutation."
    ]

    private static let titleSchema: [String: Any] = [
        "type": "string",
        "maxLength": NoteExternalAccessLimits.maximumTitleUTF8Bytes,
        "description": "Optional title, at most 512 UTF-8 bytes. Attic collapses whitespace when saving."
    ]

    private static let bodySchema: [String: Any] = [
        "type": "string",
        "maxLength": NoteExternalAccessLimits.maximumBodyUTF8Bytes,
        "description": "UTF-8 plain-text body, at most 262144 UTF-8 bytes. Whitespace and Markdown characters are stored literally."
    ]

    private static let dateSchema: [String: Any] = [
        "type": "string",
        "format": "date-time"
    ]

    private static let fullNoteSchema: [String: Any] = objectSchema(
        properties: [
            "id": idSchema(description: "Stable app-level note UUID."),
            "title": titleSchema,
            "body": bodySchema,
            "contentFormat": ["type": "string", "const": "plain_text"],
            "createdAt": dateSchema,
            "updatedAt": dateSchema,
            "revision": revisionSchema
        ],
        required: ["id", "title", "body", "contentFormat", "createdAt", "updatedAt", "revision"]
    )

    private static let summarySchema: [String: Any] = objectSchema(
        properties: [
            "id": idSchema(description: "Stable app-level note UUID."),
            "title": titleSchema,
            "titleTruncated": ["type": "boolean"],
            "preview": ["type": "string", "maxLength": 512],
            "contentFormat": ["type": "string", "const": "plain_text"],
            "createdAt": dateSchema,
            "updatedAt": dateSchema,
            "revision": revisionSchema
        ],
        required: [
            "id", "title", "titleTruncated", "preview", "contentFormat",
            "createdAt", "updatedAt", "revision"
        ]
    )

    private static let noteOutputSchema: [String: Any] = objectSchema(
        properties: ["note": fullNoteSchema],
        required: ["note"]
    )

    private static let listOutputSchema: [String: Any] = objectSchema(
        properties: [
            "count": ["type": "integer", "minimum": 0, "maximum": 100],
            "notes": ["type": "array", "items": summarySchema, "maxItems": 100],
            "nextCursor": ["type": "string", "maxLength": 256]
        ],
        required: ["count", "notes"]
    )

    private static let dateFormatter = ISO8601DateFormatter()
}
