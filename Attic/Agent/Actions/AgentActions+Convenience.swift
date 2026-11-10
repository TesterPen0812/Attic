import Foundation

/// One vocabulary for CLI progress and the trusted action receipt. Running
/// words use only supplied inputs; completed words use the actual store result.
enum AgentActionWords {
    static let coveredNames: Set<String> = [
        "list_tasks", "create_task", "update_task", "delete_task", "duplicate_task",
        "move_subtask", "get_task_workspace", "list_notes", "create_note", "update_note",
        "update_note_table", "delete_note", "delete_item", "restore_item", "restore_items",
        "list_deleted", "list_tags", "update_tags", "link", "get_settings", "update_settings",
        "make_subtask", "make_note_checkbox", "add_to_tasks", "remove_from_tasks",
        "make_task_from_note", "restore", "move_files_into_note", "search_items",
        "create_tasks", "update_tasks", "open_page", "calendar_search", "calendar_read",
        "calendar_list_calendars", "calendar_create", "calendar_update", "calendar_delete",
        "draw_list_canvases", "draw_add_text", "draw_add_shape", "draw_add_strokes",
        "agent_approval_status"
    ]

    static func running(_ name: String, _ args: [String: Any] = [:]) -> String {
        let title = subject(args)
        let day = destination(name, args)
        let batch = (name == "create_tasks" ? args["tasks"] : args["updates"]) as? [[String: Any]]
        switch name {
        case "list_tasks": return clip("Reading \(taskFilter(args))")
        case "list_notes": return "Reading notes"
        case "list_deleted": return "Reading recently deleted items"
        case "list_tags": return "Reading tags"
        case "get_settings": return "Reading settings"
        case "get_task_workspace": return clip("Reading \(title ?? "task") workspace")
        case "search_items": return clip("Finding \(subject(args, key: "query") ?? "items")")
        case "calendar_search": return clip("Finding \(subject(args, key: "query") ?? "events") in Calendar")
        case "calendar_read": return "Reading calendar event"
        case "calendar_list_calendars": return "Reading calendars"
        case "draw_list_canvases": return "Reading sketches"
        case "agent_approval_status": return "Checking approval"
        case "create_tasks": return clip("Creating \(quantity(batch?.count, "task", "tasks"))")
        case "update_tasks":
            return clip("\(day == nil ? "Updating" : "Moving") \(quantity(batch?.count, "task", "tasks"))\(day.map { " to \($0)" } ?? "")")
        case "create_task": return clip("Adding \(title ?? "a task")")
        case "update_task": return clip("\(day == nil ? "Updating" : "Moving") \(title ?? "a task")\(day.map { " to \($0)" } ?? "")")
        case "delete_task", "delete_item", "delete_note":
            return clip("Deleting \(title ?? (name == "delete_note" ? "a note" : "an item"))")
        case "duplicate_task": return clip("Duplicating \(title ?? "a task")")
        case "move_subtask": return clip("Moving \(title ?? "a subtask")")
        case "create_note": return clip("Creating \(title ?? "a note")")
        case "update_note": return clip("Writing in \(title ?? "your note")")
        case "update_note_table": return clip("Editing a table in \(title ?? "your note")")
        case "restore_item", "restore_items", "restore": return clip("Restoring \(title ?? "items")")
        case "update_tags": return "Updating tags"
        case "link": return "Linking items"
        case "update_settings": return "Updating settings"
        case "make_subtask": return clip("Making \(quantity((args["lines"] as? [String])?.count, "subtask", "subtasks"))")
        case "make_note_checkbox": return "Moving a subtask into its note"
        case "add_to_tasks", "make_task_from_note": return "Adding a note to Tasks"
        case "remove_from_tasks": return "Moving a task into Notes"
        case "move_files_into_note": return "Moving files into a note"
        case "open_page": return clip("Opening \(subject(args, key: "page") ?? "a page")")
        case "calendar_create": return clip("Adding \(title ?? "an event") to Calendar")
        case "calendar_update": return clip("Updating \(title ?? "a calendar event")")
        case "calendar_delete": return clip("Deleting \(title ?? "a calendar event")")
        case "draw_add_text", "draw_add_shape", "draw_add_strokes":
            let object = name == "draw_add_text" ? subject(args, key: "text") :
                name == "draw_add_shape" ? subject(args, key: "shape") : "strokes"
            let canvas = subject(args, key: "canvas_name")
            return clip(canvas.map { "Sketching on \($0)" } ?? "Sketching \(object ?? "on your sketch")")
        default: return clip(name.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    static func completed(_ name: String, _ args: [String: Any],
                          response: String, targets: [AgentTarget], previousNoteBody: String? = nil) -> String {
        let row = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any] ?? [:]
        let actualName = targets.first?.title ?? (row["title"] as? String) ?? subject(args)
        let day = destination(name, args)
        let count = (row["count"] as? Int)
            ?? ((row["tasks"] as? [Any])?.count)
            ?? ((row["notes"] as? [Any])?.count)
            ?? ((row["events"] as? [Any])?.count)
            ?? targets.count
        switch name {
        case "list_tasks":
            let filter = taskFilter(args)
            if filter == "overdue tasks" { return clip("Read \(count) overdue tasks") }
            return clip("Read \(quantity(count, "task", "tasks"))\(filter == "tasks" ? "" : " · \(filter)")")
        case "list_notes": return clip("Read \(quantity(count, "note", "notes"))")
        case "list_deleted": return clip("Read \(quantity(count, "deleted item", "deleted items"))")
        case "list_tags": return clip("Read \(quantity(count, "tag", "tags"))")
        case "get_settings": return "Read settings"
        case "get_task_workspace": return clip("Read \(actualName ?? "task") workspace")
        case "search_items": return clip("Found \(quantity(count, "item", "items"))")
        case "calendar_search": return clip("Found \(quantity(count, "calendar event", "calendar events"))")
        case "calendar_read": return clip("Read \(actualName ?? "calendar event")")
        case "calendar_list_calendars": return clip("Read \(quantity(count, "calendar", "calendars"))")
        case "draw_list_canvases": return clip("Read \(quantity(count, "sketch", "sketches"))")
        case "agent_approval_status": return "Checked approval"
        case "create_tasks":
            return clip("Added \(quantity(row["created"] as? Int ?? count, "task", "tasks"))")
        case "update_tasks":
            return clip("\(day == nil ? "Updated" : "Moved") \(quantity(row["updated"] as? Int ?? count, "task", "tasks"))\(day.map { " to \($0)" } ?? "")")
        case "create_task": return clip("Added \(actualName ?? "a task")")
        case "update_task": return clip("\(day == nil ? "Updated" : "Moved") \(actualName ?? "task")\(day.map { " to \($0)" } ?? "")")
        case "delete_task", "delete_note", "delete_item": return clip("Deleted \(actualName ?? "item")")
        case "duplicate_task": return clip("Duplicated \(actualName ?? "task")")
        case "move_subtask": return clip("Moved \(actualName ?? "subtask")")
        case "create_note": return clip("Created \(actualName ?? "note")")
        case "update_note":
            if row["status"] as? String == "pending" { return clip("Proposed an edit to \(actualName ?? "your note")") }
            if let body = args["body"] as? String, let previousNoteBody,
               body.contains("- [ ]"), !previousNoteBody.contains("- [ ]") {
                return clip("Added a checklist to \(actualName ?? "your note")")
            }
            return clip("Updated \(actualName ?? "your note")")
        case "update_note_table":
            return clip("\(row["status"] as? String == "pending" ? "Proposed a table edit for" : "Updated a table in") \(actualName ?? "your note")")
        case "restore_item", "restore_items", "restore": return clip("Restored \(actualName ?? quantity(count, "item", "items"))")
        case "update_tags": return "Updated tags"
        case "link": return "Linked items"
        case "update_settings": return "Updated settings"
        case "make_subtask": return clip("Made \(quantity((args["lines"] as? [String])?.count, "subtask", "subtasks"))")
        case "make_note_checkbox": return "Added a checkbox to your note"
        case "add_to_tasks", "make_task_from_note": return "Added a note to Tasks"
        case "remove_from_tasks": return "Moved a task to Notes"
        case "move_files_into_note": return "Moved files into a note"
        case "open_page": return clip("Opened \(subject(args, key: "page") ?? "page")")
        case "calendar_create": return clip("Added \(actualName ?? "event")\(day.map { " to \($0)" } ?? "")")
        case "calendar_update": return clip("Updated \(actualName ?? "event")\(day.map { " on \($0)" } ?? "")")
        case "calendar_delete": return clip("Deleted \(actualName ?? "event")")
        case "draw_add_text", "draw_add_shape", "draw_add_strokes":
            let saved = row["object"] as? [String: Any] ?? [:]
            let object = name == "draw_add_text" ? (saved["text"] as? String)
                : name == "draw_add_shape" ? subject(args, key: "shape") : "strokes"
            let canvas = (saved["canvas_name"] as? String) ?? targets.first?.title
                ?? subject(args, key: "canvas_name")
            return clip("Added \(object ?? "drawing") to \(canvas ?? "your sketch")")
        default: return clip(running(name, args))
        }
    }

    private static func subject(_ args: [String: Any], key: String = "title") -> String? {
        for candidate in [key, "query"] {
            if let value = args[candidate] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func quantity(_ number: Int?, _ singular: String, _ plural: String) -> String {
        guard let number else { return plural }
        return "\(number) \(number == 1 ? singular : plural)"
    }

    private static func taskFilter(_ args: [String: Any]) -> String {
        if let text = subject(args, key: "text"), args["text"] != nil { return "tasks matching \(text)" }
        if let before = args["due_before"] as? String,
           let day = date(before), day < Calendar.current.startOfDay(for: Date()) {
            return "overdue tasks"
        }
        if let status = (args["status"] ?? args["state"]) as? String { return "\(status) tasks" }
        return "tasks"
    }

    private static func destination(_ name: String, _ args: [String: Any]) -> String? {
        var input: Any? = args["due"]
        if name == "update_tasks", let updates = args["updates"] as? [[String: Any]],
           !updates.isEmpty, updates.allSatisfy({ "\($0["due"] ?? "")" == "\(updates[0]["due"] ?? "")" }) {
            input = updates[0]["due"]
        }
        if name.hasPrefix("calendar_") { input = args["start"] }
        guard let input = input as? String, !input.isEmpty else { return nil }
        if let date = date(input) { return weekday(date) }
        if Calendar.current.weekdaySymbols.contains(where: { $0.localizedCaseInsensitiveCompare(input) == .orderedSame }) {
            return input.capitalized
        }
        return nil
    }

    private static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: value) { return d }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: value)
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    static func clip(_ words: String) -> String {
        let clean = words.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 43 ? clean : String(clean.prefix(42)) + "…"
    }

    static func finishedWithoutReceipt(_ running: String) -> String {
        for (prefix, past) in [
            ("Reading", "Read"), ("Moving", "Moved"), ("Creating", "Created"),
            ("Adding", "Added"), ("Updating", "Updated"), ("Deleting", "Deleted"),
            ("Duplicating", "Duplicated"), ("Finding", "Found"), ("Sketching", "Sketched"),
            ("Writing", "Wrote"), ("Editing", "Edited"), ("Restoring", "Restored"),
            ("Checking", "Checked"), ("Opening", "Opened"), ("Linking", "Linked"),
            ("Making", "Made")
        ] where running.hasPrefix(prefix + " ") {
            return clip(past + running.dropFirst(prefix.count))
        }
        return running
    }
}

/// Run-only conveniences. The original AgentTaskTools contracts remain intact
/// for long-lived external MCP clients.
extension AgentActions {
    static func runDefinition(_ original: [String: Any]) -> [String: Any] {
        guard let name = original["name"] as? String,
              var schema = original["inputSchema"] as? [String: Any],
              var properties = schema["properties"] as? [String: Any] else { return original }
        var required = schema["required"] as? [String] ?? []
        let taskTargets: Set<String> = ["update_task", "delete_task", "duplicate_task", "move_subtask", "get_task_workspace"]
        let noteTargets: Set<String> = ["update_note", "update_note_table", "delete_note"]
        if taskTargets.contains(name) || noteTargets.contains(name) || name == "delete_item" {
            properties["query"] = ["type": "string", "description": "Match an item by its name, including loose wording. A unique match is required; use id if several match."]
            required.removeAll { $0 == "id" }
        }
        if noteTargets.contains(name) || name == "delete_item" {
            required.removeAll { $0 == "base_revision" }
            if let description = original["description"] as? String {
                var replacement = original
                replacement["description"] = "For an Attic run, id or query identifies the note; revision and task-note safeguards are resolved automatically. " + description
                return finishDefinition(replacement, schema: schema, properties: properties, required: required)
            }
        }
        if name == "create_task" || name == "move_subtask" {
            properties["parent_query"] = ["type": "string", "description": "Use a main task's title instead of looking up parent_id."]
            if name == "move_subtask" { required.removeAll { $0 == "parent_id" } }
        }
        return finishDefinition(original, schema: schema, properties: properties, required: required)
    }

    private static func finishDefinition(_ original: [String: Any], schema: [String: Any],
                                         properties: [String: Any], required: [String]) -> [String: Any] {
        var schema = schema
        schema["properties"] = properties
        schema["required"] = required
        var definition = original
        definition["inputSchema"] = schema
        return definition
    }

    func preparedArguments(name: String, arguments: [String: Any]) throws -> [String: Any] {
        var args = arguments
        let taskTargets: Set<String> = ["update_task", "delete_task", "duplicate_task", "move_subtask", "get_task_workspace"]
        let noteTargets: Set<String> = ["update_note", "update_note_table", "delete_note"]

        if taskTargets.contains(name), args["id"] == nil {
            args["id"] = try uniqueTask(named: args["query"], mainOnly: false).id.uuidString
        }
        if noteTargets.contains(name), args["id"] == nil {
            args["id"] = try uniqueNote(named: args["query"]).id.uuidString
        }
        if name == "delete_item", args["id"] == nil {
            switch args["kind"] as? String {
            case "task": args["id"] = try uniqueTask(named: args["query"], mainOnly: false).id.uuidString
            case "note": args["id"] = try uniqueNote(named: args["query"]).id.uuidString
            case "canvas": args["id"] = try uniqueCanvas(named: args["query"]).id.uuidString
            default: throw AgentActionsError.invalid("Specify kind as task, note or canvas, then supply id or query.")
            }
        }
        if taskTargets.contains(name) || noteTargets.contains(name) || name == "delete_item" {
            args.removeValue(forKey: "query")
        }
        if ["create_task", "move_subtask"].contains(name), args["parent_id"] == nil,
           let parentQuery = args["parent_query"] {
            args["parent_id"] = try uniqueTask(named: parentQuery, mainOnly: true).id.uuidString
        }
        if ["create_task", "move_subtask"].contains(name) { args.removeValue(forKey: "parent_query") }

        let needsNote = noteTargets.contains(name) || (name == "delete_item" && args["kind"] as? String == "note")
        if needsNote, let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)),
           let note = tasks.noteStore?.note(withID: id) {
            if args["base_revision"] == nil { args["base_revision"] = note.revisionToken }
            if let owner = note.taskID, args["base_note_token"] == nil || args["base_association_token"] == nil {
                let data = try tasks.call(name: "get_task_workspace", arguments: ["id": owner.uuidString])
                let workspace = (try JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
                if args["base_note_token"] == nil { args["base_note_token"] = workspace["note_token"] }
                if args["base_association_token"] == nil { args["base_association_token"] = workspace["association_token"] }
            }
        }
        if name == "delete_item", let kind = args["kind"] as? String, kind == "task",
           args["base_workspace_token"] == nil, let id = args["id"] as? String {
            // The paired task/writing lifecycle requires an atomic workspace snapshot.
            if let data = try? tasks.call(name: "get_task_workspace", arguments: ["id": id]),
               let workspace = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] {
                args["base_workspace_token"] = workspace["workspace_token"]
            }
        }
        if name.hasPrefix("draw_add_"), args["canvas_id"] == nil {
            args["canvas_id"] = try uniqueCanvas(named: args["canvas_name"]).id.uuidString
        }
        if name.hasPrefix("draw_add_") { args.removeValue(forKey: "canvas_name") }
        return args
    }

    private func uniqueTask(named value: Any?, mainOnly: Bool) throws -> TaskItem {
        guard let name = value as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentActionsError.invalid("Provide id, or query with the task's name. Use search_items to discover tasks.")
        }
        let entries = taskCandidates().filter { !mainOnly || $0.parentID == nil }
        return try uniqueMatch(name, from: entries, title: { $0.title }, id: { $0.id.uuidString }, kind: "task")
    }

    private func uniqueNote(named value: Any?) throws -> NoteItem {
        guard let name = value as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentActionsError.invalid("Provide id, or query with the note's name. Use search_items to discover notes.")
        }
        return try uniqueMatch(name, from: tasks.noteStore?.orderedNotes() ?? [],
                               title: { $0.title }, id: { $0.id.uuidString }, kind: "note")
    }

    private func uniqueCanvas(named value: Any?) throws -> DrawCanvas {
        guard let draw else { throw AgentActionsError.invalid("Draw is unavailable in this run.") }
        let canvases = try draw.library(deleted: false)
        if let name = value as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try uniqueMatch(name, from: canvases, title: { $0.name }, id: { $0.id.uuidString }, kind: "canvas")
        }
        if canvases.count == 1 { return canvases[0] }
        if canvases.isEmpty { throw AgentActionsError.invalid("No Draw canvases exist. Create one on the Draw page first.") }
        throw AgentActionsError.invalid("Specify canvas_id or canvas_name. Available: " +
            canvases.prefix(8).map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: "; "))
    }

    private func uniqueMatch<T>(_ name: String, from entries: [T], title: (T) -> String,
                                id: (T) -> String, kind: String) throws -> T {
        let ranked = entries.compactMap { item -> (T, Int)? in
            guard let score = Self.matchScore(query: name, in: title(item)) else { return nil }
            return (item, score)
        }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first else {
            throw AgentActionsError.invalid("No \(kind) matches '\(name)'. Call search_items with query to find available names and ids.")
        }
        if ranked.count > 1 && ranked[1].1 == first.1 {
            let candidates = ranked.prefix(5).map { "\(title($0.0)) (\(id($0.0)))" }.joined(separator: "; ")
            throw AgentActionsError.invalid("Ambiguous \(kind) '\(name)': \(candidates). Retry with the exact id.")
        }
        return first.0
    }

    private func taskCandidates() -> [TaskItem] {
        var seen = Set<UUID>()
        return [TaskStatus.inProgress, .todo, .done, .backlog]
            .flatMap { tasks.store.orderedTasks(for: $0) }
            .filter { seen.insert($0.id).inserted }
    }

    private static func words(_ string: String) -> [String] {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    static func matchScore(query: String, in candidate: String) -> Int? {
        let text = words(candidate).joined(separator: " ")
        let normalized = words(query).filter { !["the", "a", "an", "my", "please", "task", "note", "to"].contains($0) }
        guard !normalized.isEmpty else { return nil }
        let needle = normalized.joined(separator: " ")
        if text == needle { return 1000 }
        if text.contains(needle) { return 700 }
        let tokens = words(candidate)
        guard normalized.allSatisfy({ word in tokens.contains(where: { token in
            token == word || token.hasPrefix(word) || (token.count > 3 && word.hasPrefix(token)) || nearWord(word, token)
        }) }) else { return nil }
        return 300 + normalized.count * 10
    }

    private static func nearWord(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard min(x.count, y.count) >= 4, abs(x.count - y.count) <= 1 else { return false }
        var i = 0, j = 0, differences = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            differences += 1
            if differences > 1 { return false }
            if x.count >= y.count { i += 1 }
            if y.count >= x.count { j += 1 }
        }
        return differences + max(x.count - i, y.count - j) <= 1
    }

    static func message(for error: Error) -> String {
        if let failure = error as? AgentToolError { return failure.message }
        return error.localizedDescription
    }

    func taskBatchAction(_ name: String, _ args: [String: Any]) throws -> (String, AgentStep) {
        let key = name == "create_tasks" ? "tasks" : "updates"
        guard let operations = args[key] as? [[String: Any]], !operations.isEmpty, operations.count <= 50 else {
            throw AgentActionsError.invalid("\(key) must contain 1 to 50 task objects.")
        }
        let allowed: Set<String> = name == "create_tasks"
            ? ["title", "status", "state", "priority", "parent_id", "parent_query", "tags", "due"]
            : ["id", "query", "title", "status", "state", "priority", "tags", "due"]
        var results: [[String: Any]] = []
        var targets: [AgentTarget] = []
        for (index, operation) in operations.enumerated() {
            do {
                let extras = Set(operation.keys).subtracting(allowed)
                guard extras.isEmpty else { throw AgentActionsError.invalid("Unknown task fields: \(extras.sorted().joined(separator: ", ")).") }
                let single = name == "create_tasks" ? "create_task" : "update_task"
                let prepared = try preparedArguments(name: single, arguments: operation)
                let text = try tasks.call(name: single, arguments: prepared)
                guard let payload = (try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      let task = payload["task"] as? [String: Any], let idString = task["id"] as? String,
                      let id = UUID(uuidString: idString) else {
                    throw AgentActionsError.invalid("The task changed but no saved task state was returned. Inspect list_tasks before retrying.")
                }
                results.append(["index": index, "status": "done", "task": task])
                targets.append(AgentTarget(page: .tasks, itemID: id, title: task["title"] as? String))
            } catch {
                results.append(["index": index, "status": "failed", "error": Self.message(for: error)])
            }
        }
        let successes = targets.count
        var response: [String: Any] = ["results": results, "failed": operations.count - successes,
                                        "count": operations.count]
        response[name == "create_tasks" ? "created" : "updated"] = successes
        let text = try Self.json(response)
        let failureCount = operations.count - successes
        let failures = results.compactMap { result -> String? in
            guard result["status"] as? String == "failed" else { return nil }
            let index = (result["index"] as? Int ?? 0) + 1
            return "Item \(index): \(result["error"] as? String ?? "Unknown error")"
        }
        let state: AgentStepState = successes == 0
            ? .failed("All task operations failed; see results.")
            : failureCount > 0
                ? .partial("\(failureCount) of \(operations.count) operations failed. \(failures.joined(separator: " "))")
                : .done
        let step = AgentStep(id: UUID(), title: name == "create_tasks" ? "Create tasks" : "Update tasks",
                             kind: name == "create_tasks" ? .create : .update,
                             targets: targets, state: state)
        return (text, step)
    }

    func searchItems(_ args: [String: Any]) throws -> (String, AgentStep) {
        guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentActionsError.invalid("Provide query to search tasks, notes and canvases.")
        }
        let pages = (args["pages"] as? [String]) ?? ["tasks", "notes", "draw"]
        guard Set(pages).isSubset(of: ["tasks", "notes", "draw"]) else {
            throw AgentActionsError.invalid("pages must contain tasks, notes or draw.")
        }
        let limit = (args["limit"] as? Int) ?? 20
        guard (1...100).contains(limit) else { throw AgentActionsError.invalid("limit must be 1 to 100.") }
        var matches: [(Int, [String: Any], AgentTarget)] = []
        if pages.contains("tasks") {
            for task in taskCandidates() {
                guard let score = Self.matchScore(query: query, in: task.title) else { continue }
                var row: [String: Any] = ["page": "tasks", "id": task.id.uuidString, "title": task.title,
                                           "status": task.status.rawValue, "priority": task.priority.rawValue,
                                           "tags": task.tags]
                if let day = task.dueDay { row["due"] = day.rawValue }
                if let parent = task.parentID { row["parent_id"] = parent.uuidString }
                matches.append((score, row, AgentTarget(page: .tasks, itemID: task.id, title: task.title)))
            }
        }
        if pages.contains("notes") {
            for note in tasks.noteStore?.orderedNotes() ?? [] {
                guard let score = Self.matchScore(query: query, in: note.title) ??
                        Self.matchScore(query: query, in: note.body) else { continue }
                let row: [String: Any] = ["page": "notes", "id": note.id.uuidString,
                                          "title": note.title, "revision": note.revisionToken,
                                          "excerpt": String(note.body.prefix(160))]
                matches.append((score, row, AgentTarget(page: .notes, itemID: note.id, title: note.title)))
            }
        }
        if pages.contains("draw"), let draw {
            for canvas in try draw.library(deleted: false) {
                guard let score = Self.matchScore(query: query, in: canvas.name) else { continue }
                let row: [String: Any] = ["page": "draw", "id": canvas.id.uuidString, "title": canvas.name]
                matches.append((score, row, AgentTarget(page: .draw, itemID: canvas.id, title: canvas.name)))
            }
        }
        matches.sort { $0.0 > $1.0 }
        let returned = Array(matches.prefix(limit))
        let text = try Self.json(["items": returned.map { $0.1 }, "count": matches.count,
                                  "returned": returned.count, "query": query])
        let step = AgentStep(id: UUID(), title: "Search items", kind: .read,
                             targets: returned.map { $0.2 }, state: .done)
        return (text, step)
    }
}
