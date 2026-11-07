import Foundation

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
        let step = AgentStep(id: UUID(), title: name == "create_tasks" ? "Create tasks" : "Update tasks",
                             kind: name == "create_tasks" ? .create : .update,
                             targets: targets, state: successes == 0 ? .failed("All task operations failed; see results.") : .done)
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
