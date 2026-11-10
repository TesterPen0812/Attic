import Foundation

/// The runner and the run-scoped MCP adapter share one action layer.
enum AgentActionCall {
    case performed(AgentActionResult)
    case approvalNeeded(AgentApproval)
}

struct AgentActionResult {
    let text: String
    let step: AgentStep
    let changeSet: AgentChangeSet?
}

struct AgentUndoReport {
    let undone: Int
    let failures: [String]
    let remaining: AgentChangeSet?
}

enum AgentActionsError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case let .invalid(message) = self { return message }
        return nil
    }
}

/// Approval is a code policy, never inferred from tool output or model text.
enum AgentActionApprovalPolicy {
    static let names: Set<String> = [
        "delete_task", "delete_note", "delete_item", "make_note_checkbox",
        "remove_from_tasks", "calendar_create", "calendar_update", "calendar_delete"
    ]

    static func requiresApproval(_ name: String, arguments: [String: Any]) -> Bool {
        if names.contains(name) { return true }
        // Table edits can remove rows and columns while still called update_note_table.
        if name == "update_note_table", let operations = arguments["operations"] as? [[String: Any]] {
            return operations.contains { ($0["op"] as? String)?.hasPrefix("delete_") == true }
        }
        return false
    }
}

@MainActor
final class AgentActions {
    let tasks: AgentTaskTools
    let calendarSource: (any CalendarEventSource)?
    let calendarWriter: (any CalendarEventWriter)?
    let draw: (any DrawStoreProtocol)?
    /// Injected by the panel, not by model arguments. Must never take focus in background.
    var openPage: ((AgentPage) -> Bool)?

    enum UndoEntry {
        case history(UndoHistoryID, UUID, String)
        case draw(UUID, DrawSnapshot, String)
        case createdNote(UUID, String)
        case updatedNote(UUID, document: NoteDocument?, title: String, body: String,
                         revision: String, name: String)
        case proposal(noteID: UUID, editID: UUID, name: String)
        case unavailable(String)

        var title: String {
            switch self {
            case let .history(_, _, name), let .draw(_, _, name), let .createdNote(_, name),
                 let .proposal(_, _, name),
                 let .updatedNote(_, _, _, _, _, name), let .unavailable(name): name
            }
        }
    }

    struct Journal {
        var changeSet: AgentChangeSet
        var entries: [UndoEntry] = []
    }

    struct AwaitingApproval {
        let name: String
        let arguments: [String: Any]
        let watching: Bool
        let requestID: UUID
    }

    private(set) var journals: [UUID: Journal] = [:]
    private var order: [UUID] = []
    private var approvals: [UUID: AwaitingApproval] = [:]
    private var activeCalls: [UUID: Int] = [:]
    private var closedRequests = Set<UUID>()
    private var idleWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(tasks: AgentTaskTools, calendarSource: (any CalendarEventSource)? = nil,
         calendarWriter: (any CalendarEventWriter)? = nil,
         draw: (any DrawStoreProtocol)? = nil,
         openPage: ((AgentPage) -> Bool)? = nil) {
        self.tasks = tasks
        self.calendarSource = calendarSource
        self.calendarWriter = calendarWriter
        self.draw = draw
        self.openPage = openPage
    }

    var definitions: [[String: Any]] {
        (tasks.definitions + Self.extraDefinitions).filter { def in
            guard let name = def["name"] as? String else { return false }
            if name.hasPrefix("calendar_") {
                return name == "calendar_search" || name == "calendar_read" ? calendarSource != nil : calendarWriter != nil
            }
            if name.hasPrefix("draw_") { return draw != nil }
            return true
        }.map(Self.runDefinition)
    }

    @discardableResult
    func beginRequest(title: String) -> UUID {
        let id = UUID()
        journals[id] = Journal(changeSet: AgentChangeSet(id: id, title: title, pages: [], count: 0))
        order.append(id)
        return id
    }

    func changeSet(for requestID: UUID) -> AgentChangeSet? {
        guard let set = journals[requestID]?.changeSet, set.count > 0 else { return nil }
        return set
    }

    /// `watching` comes from the host run, never from the model's JSON.
    func call(name: String, arguments: [String: Any], watching: Bool, requestID: UUID) async throws -> AgentActionCall {
        try checkOpen(requestID)
        activeCalls[requestID, default: 0] += 1
        defer { callEnded(requestID) }
        try validate(name, arguments)
        let localArguments = try preparedArguments(name: name, arguments: arguments)
        let prepared = try await preparedCalendarArguments(name: name, arguments: localArguments)
        try checkOpen(requestID)
        if AgentActionApprovalPolicy.requiresApproval(name, arguments: prepared) {
            let id = UUID()
            let targets = targetsForArguments(name, prepared)
            let approval = AgentApproval(id: id, title: "Allow \(name.replacingOccurrences(of: "_", with: " "))?", targets: targets)
            approvals[id] = AwaitingApproval(name: name, arguments: prepared, watching: watching, requestID: requestID)
            return .approvalNeeded(approval)
        }
        return .performed(try await execute(name: name, arguments: prepared, watching: watching, requestID: requestID))
    }

    /// Only the trusted UI/runner can resolve the opaque ID issued by call().
    func resolve(approval id: UUID, allow: Bool) async throws -> AgentActionResult? {
        guard let pending = approvals[id], !closedRequests.contains(pending.requestID) else {
            throw AgentActionsError.invalid("Approval expired or unknown.")
        }
        approvals[id] = nil
        guard allow else { return nil }
        activeCalls[pending.requestID, default: 0] += 1
        defer { callEnded(pending.requestID) }
        return try await execute(name: pending.name, arguments: pending.arguments,
                                 watching: pending.watching, requestID: pending.requestID)
    }

    /// Ending a run invalidates outstanding owner prompts without executing them.
    func cancelApprovals(for requestID: UUID) {
        approvals = approvals.filter { $0.value.requestID != requestID }
    }

    /// Revocation closes the admission gate at once. An action that already
    /// entered an asynchronous store commit is allowed to finish journaling;
    /// its receipt is drained before the runner publishes a terminal event.
    func sealRequest(_ id: UUID) {
        closedRequests.insert(id)
        cancelApprovals(for: id)
    }

    func drainRequest(_ id: UUID) async -> AgentChangeSet? {
        if (activeCalls[id] ?? 0) > 0 {
            await withCheckedContinuation { idleWaiters[id, default: []].append($0) }
        }
        return changeSet(for: id)
    }

    private func checkOpen(_ id: UUID) throws {
        guard journals[id] != nil, !closedRequests.contains(id) else {
            throw AgentActionsError.invalid("This agent run has ended.")
        }
    }

    private func callEnded(_ id: UUID) {
        let remaining = (activeCalls[id] ?? 1) - 1
        if remaining > 0 { activeCalls[id] = remaining; return }
        activeCalls[id] = nil
        let waiters = idleWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.resume() }
    }

    /// Failed calls keep previously committed steps in the same request.
    private func execute(name: String, arguments: [String: Any], watching: Bool,
                         requestID: UUID) async throws -> AgentActionResult {
        try checkOpen(requestID)
        let route = tasks.library.undo
        let before = Dictionary(uniqueKeysWithValues: route.retainedHistories.map {
            ($0, route.steps(in: $0, redo: false).map(\.id))
        })
        let step: AgentStep
        let text: String
        var extraEntries: [UndoEntry] = []
        if name == "open_page" {
            guard let raw = arguments["page"] as? String, let page = AgentPage(rawValue: raw) else {
                throw AgentActionsError.invalid("page must be tasks, notes, calendar or draw.")
            }
            guard watching else { throw AgentActionsError.invalid("Opening a page requires the owner to be watching.") }
            guard openPage?(page) == true else { throw AgentActionsError.invalid("The page could not be opened.") }
            text = try Self.json(["opened": page.rawValue])
            step = AgentStep(id: UUID(), title: "Open \(page.rawValue.capitalized)", kind: .openPage,
                             targets: [AgentTarget(page: page)], state: .done)
        } else if name == "create_tasks" || name == "update_tasks" {
            (text, step) = try taskBatchAction(name, arguments)
        } else if name == "search_items" {
            (text, step) = try searchItems(arguments)
        } else if name.hasPrefix("calendar_") {
            (text, step) = try await calendarAction(name, arguments)
        } else if name.hasPrefix("draw_") {
            let result = try drawAction(name, arguments)
            text = result.0; step = result.1
            if let snapshot = result.2 { extraEntries.append(.draw(snapshot.canvas.id, snapshot, step.title)) }
        } else {
            let noteBefore = ["update_note", "update_note_table"].contains(name)
                ? noteSnapshot(for: arguments) : nil
            text = if AgentTaskTools.asyncToolNames.contains(name), tasks.notesController != nil {
                try await tasks.callAsync(name: name, arguments: arguments)
            } else {
                try tasks.call(name: name, arguments: arguments)
            }
            let targets = Self.targetsFromResponse(text, name: name, arguments: arguments)
            step = AgentStep(id: UUID(), title: Self.stepTitle(name, arguments),
                             kind: Self.stepKind(name, arguments), targets: targets, state: .done)
            if name == "create_note", let id = targets.first?.itemID {
                extraEntries.append(.createdNote(id, step.title))
            }
            if let before = noteBefore,
               let response = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
               response["status"] as? String == "applied",
               let note = response["note"] as? [String: Any],
               let revision = note["revision"] as? String {
                extraEntries.append(.updatedNote(before.id, document: before.document,
                                                 title: before.title, body: before.body,
                                                 revision: revision, name: step.title))
            }
            if let response = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
               response["status"] as? String == "pending",
               let raw = response["pending_edit"] as? String, let editID = UUID(uuidString: raw),
               let noteID = (arguments["id"] as? String).flatMap(UUID.init(uuidString:)) {
                // An on-screen note has a real persisted proposal. Undo must
                // discard that proposal rather than silently omit the change.
                extraEntries.append(.proposal(noteID: noteID, editID: editID, name: step.title))
            }
        }
        var entries: [UndoEntry] = []
        for history in route.retainedHistories {
            let current = route.steps(in: history, redo: false)
            let old = before[history] ?? []
            let ids = current.map(\.id)
            if ids.starts(with: old) {
                for added in current.dropFirst(old.count) {
                    entries.append(.history(history, added.id, step.title))
                }
            } else if ids != old {
                entries.append(.unavailable("\(step.title): history changed during the action"))
            }
        }
        // A note created through NoteStore has no ordinary undo step.
        if !entries.contains(where: { if case .history = $0 { return true }; return false }) {
            entries.append(contentsOf: extraEntries)
        }
        let actionFailed: Bool
        if case .failed = step.state { actionFailed = true } else { actionFailed = false }
        if entries.isEmpty && Self.isMutation(name) && !actionFailed {
            // Never silently promise Undo for a store change without a confirmed history.
            entries.append(.unavailable("\(step.title): no reversible store step was recorded"))
        }
        if !entries.isEmpty {
            guard var journal = journals[requestID] else {
                throw AgentActionsError.invalid("The request was closed while an action finished.")
            }
            journal.entries.append(contentsOf: entries)
            journal.changeSet.count += entries.count
            journal.changeSet.pages.formUnion(step.targets.map(\.page))
            journals[requestID] = journal
        }
        return AgentActionResult(text: text, step: step, changeSet: changeSet(for: requestID))
    }

    /// Reverse the newest request, and within it reverse changes in commit order.
    /// Each step checks its own current history head to avoid undoing user edits.
    func undo(changeSet id: UUID) async -> AgentUndoReport {
        if (activeCalls[id] ?? 0) > 0 || approvals.values.contains(where: { $0.requestID == id }) {
            return AgentUndoReport(undone: 0,
                                   failures: ["Finish or refuse the request's active action and approvals before Undo."],
                                   remaining: changeSet(for: id))
        }
        guard order.last(where: { journals[$0]?.changeSet.count ?? 0 > 0 }) == id,
              var journal = journals[id], journal.changeSet.count > 0 else {
            return AgentUndoReport(undone: 0, failures: ["Only the newest nonempty change set can be undone."], remaining: changeSet(for: id))
        }
        var failures: [String] = []
        var undone = 0
        var remaining: [UndoEntry] = []
        // Reverting a second edit creates a fresh revision token, so the
        // first edit in the same request must use that restored revision.
        var noteRevisions: [UUID: String] = [:]
        let route = tasks.library.undo
        for entry in journal.entries.reversed() {
            var success = false
            switch entry {
            case let .history(history, expectedID, _):
                if route.undoStepID(in: history) != expectedID {
                    failures.append("\(entry.title): a newer edit or missing undo step prevents reversal")
                } else {
                    let result = await route.replay(in: history, redo: false)
                    success = result == .applied
                    if !success { failures.append("\(entry.title): \(String(describing: result))") }
                }
            case let .draw(canvasID, snapshot, _):
                if let draw, let current = try? draw.open(canvasID),
                   current.objects == snapshot.objects && current.canvas.name == snapshot.canvas.name,
                   draw.canUndo(on: canvasID) {
                    success = draw.undo(on: canvasID).isSaved
                }
                if !success { failures.append("\(entry.title): Draw has changed or refused Undo") }
            case let .createdNote(noteID, _):
                if tasks.noteStore?.note(withID: noteID) != nil {
                    success = tasks.library.delete(AtticItemRef(.note, noteID))
                }
                if !success { failures.append("\(entry.title): the note could not be removed") }
            case let .updatedNote(noteID, document, title, body, revision, _):
                if let noteStore = tasks.noteStore, let document {
                    // A note the chat wrote in while watched is on screen: a
                    // clean editor there is put back too, and reloads.
                    success = noteStore.agentRestore(noteID: noteID, document: document,
                                                     revision: noteRevisions[noteID] ?? revision)
                    if success { noteRevisions[noteID] = noteStore.note(withID: noteID)?.revisionToken }
                } else if let noteStore = tasks.noteStore, let current = noteStore.note(withID: noteID),
                   current.revisionToken == (noteRevisions[noteID] ?? revision),
                   noteStore.agentWriteDisposition(noteID) == .direct {
                    if let result = try? tasks.call(name: "update_note", arguments: [
                        "id": noteID.uuidString, "base_revision": current.revisionToken,
                        "title": title, "body": body
                    ]), let payload = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] {
                        success = payload["status"] as? String == "applied"
                    }
                    if success { noteRevisions[noteID] = noteStore.note(withID: noteID)?.revisionToken }
                }
                if !success { failures.append("\(entry.title): note changed or refused restoration") }
            case let .proposal(noteID, editID, _):
                success = tasks.noteStore?.discardProposal(editID, noteID: noteID) == true
                if !success { failures.append("\(entry.title): proposal already applied, changed or unavailable") }
            case let .unavailable(reason):
                failures.append(reason)
            }
            if success { undone += 1 } else { remaining.insert(entry, at: 0) }
        }
        journal.entries = remaining.map { entry in
            if case let .updatedNote(id, document, title, body, revision, name) = entry,
               let restoredRevision = noteRevisions[id] {
                return .updatedNote(id, document: document, title: title, body: body,
                                    revision: restoredRevision, name: name)
            }
            return entry
        }
        journal.changeSet.count = journal.entries.count
        if remaining.isEmpty {
            journals[id] = nil
            order.removeAll { $0 == id }
        } else { journals[id] = journal }
        return AgentUndoReport(undone: undone, failures: failures, remaining: changeSet(for: id))
    }

    private func validate(_ name: String, _ arguments: [String: Any]) throws {
        guard let definition = definitions.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              schema["additionalProperties"] as? Bool == false else {
            throw AgentActionsError.invalid("Unknown action: \(name)")
        }
        let unknown = Set(arguments.keys).subtracting(properties.keys)
        guard unknown.isEmpty else {
            throw AgentActionsError.invalid("Unknown arguments: \(unknown.sorted().joined(separator: ", ")). Allowed fields for \(name): \(properties.keys.sorted().joined(separator: ", ")).")
        }
        for required in schema["required"] as? [String] ?? [] where arguments[required] == nil {
            throw AgentActionsError.invalid("Missing \(required) for \(name). Allowed fields: \(properties.keys.sorted().joined(separator: ", ")).")
        }
    }

    static func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func stepTitle(_ name: String, _ arguments: [String: Any]) -> String {
        let verb = name.replacingOccurrences(of: "_", with: " ").capitalized
        return (arguments["title"] as? String).map { "\(verb): \($0)" } ?? verb
    }

    private static func stepKind(_ name: String, _ arguments: [String: Any]) -> AgentStepKind {
        if name.hasPrefix("delete_") || name == "make_note_checkbox" { return .delete }
        if name.hasPrefix("create_") || name.hasPrefix("duplicate_") { return .create }
        if name == "update_task", arguments["due"] != nil { return .move(toDay: nil) }
        if name.hasPrefix("update_") || name.hasPrefix("move_") || name == "link" ||
            name.hasPrefix("restore_") || AgentTaskTools.asyncToolNames.contains(name) { return .update }
        return .read
    }

    private static func isMutation(_ name: String) -> Bool {
        name.hasPrefix("create_") || name.hasPrefix("update_") || name.hasPrefix("delete_") ||
        name.hasPrefix("duplicate_") || name.hasPrefix("move_") || name.hasPrefix("restore_") ||
        name == "link" || AgentTaskTools.asyncToolNames.contains(name) ||
        name.hasPrefix("draw_add_")
    }

    private func noteSnapshot(for arguments: [String: Any]) -> (
        id: UUID, title: String, body: String, document: NoteDocument?
    )? {
        guard let id = (arguments["id"] as? String).flatMap(UUID.init(uuidString:)),
              let note = tasks.noteStore?.note(withID: id) else { return nil }
        let body: String
        var document: NoteDocument?
        if note.usesDocumentFormat, let load = tasks.noteStore?.loadDocument(noteID: id),
           case let .editable(value) = load.content {
            body = NoteTextExport.agentBody(value)
            document = value
        } else { body = note.body }
        return (id, note.title, body, document)
    }

    private func targetsForArguments(_ name: String, _ arguments: [String: Any]) -> [AgentTarget] {
        Self.targetsFromResponse("{}", name: name, arguments: arguments)
    }

    private static func targetsFromResponse(_ text: String, name: String, arguments: [String: Any]) -> [AgentTarget] {
        let payload = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
        if name.hasPrefix("calendar_") {
            let id = ((payload["id"] ?? arguments["id"]) as? String).flatMap(UUID.init(uuidString:))
            let occurrence = (payload["occurrence_id"] ?? arguments["occurrence_id"]) as? String
            let title = (payload["title"] ?? arguments["_resolved_title"] ?? arguments["title"]) as? String
            return [AgentTarget(page: .calendar, itemID: id, title: title, externalID: occurrence)]
        }
        let kind = arguments["kind"] as? String
        let page: AgentPage = kind == "note" || name.contains("note") ? .notes :
            (kind == "canvas" ? .draw : .tasks)
        var targets: [AgentTarget] = []
        func add(_ value: Any?, page: AgentPage) {
            if let row = value as? [String: Any] {
                if let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)) {
                    targets.append(AgentTarget(page: page, itemID: id, title: row["title"] as? String))
                }
            } else if let array = value as? [[String: Any]] {
                for item in array.prefix(40) { add(item, page: page) }
            }
        }
        add(payload["task"], page: .tasks); add(payload["tasks"], page: .tasks)
        add(payload["note"], page: .notes); add(payload["notes"], page: .notes)
        for (key, targetPage) in [("task_id", AgentPage.tasks), ("subtask_id", .tasks), ("note_id", .notes)] {
            if let id = ((payload[key] ?? arguments[key]) as? String).flatMap(UUID.init(uuidString:)),
               !targets.contains(where: { $0.itemID == id && $0.page == targetPage }) {
                targets.append(AgentTarget(page: targetPage, itemID: id))
            }
        }
        if targets.isEmpty {
            let id = (arguments["id"] as? String).flatMap(UUID.init(uuidString:))
                ?? (payload["deleted"] as? String).flatMap(UUID.init(uuidString:))
            if let id { targets.append(AgentTarget(page: page, itemID: id)) }
        }
        return targets
    }
}
