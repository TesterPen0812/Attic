import Foundation
import SwiftData

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
    case refused(String)
    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .refused(message): return message
        }
    }
}

/// Approval is a code policy, never inferred from tool output or model text.
enum AgentActionApprovalPolicy {
    static let names: Set<String> = [
        "delete_task", "delete_note", "delete_item", "make_note_checkbox",
        "remove_from_tasks", "calendar_create", "calendar_update", "calendar_delete",
        "draw_delete_canvas", "draw_delete_object"
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

/// The owner sees the intended effect and the resolved item titles, never an
/// internal MCP tool name. The approval card lists every named target below it.
enum AgentApprovalWords {
    static func title(_ name: String, arguments: [String: Any], targets: [AgentTarget]) -> String {
        let names = targets.compactMap(\.title).filter { !$0.isEmpty }
        let subject = names.first ?? (arguments["_resolved_title"] as? String)
            ?? (arguments["title"] as? String)
        let count = targets.count
        func phrase(_ verb: String, _ kind: String) -> String {
            if count > 1 { return "\(verb) \(count) \(kind == "canvas" ? "canvases" : "\(kind)s")?" }
            return "\(verb) \(subject ?? "this \(kind)")?"
        }
        switch name {
        case "delete_task": return phrase("Delete", "task")
        case "delete_note": return phrase("Delete", "note")
        case "delete_item":
            let kind = (arguments["kind"] as? String) ?? "item"
            return phrase("Delete", kind)
        case "make_note_checkbox": return "Move \(subject ?? "this subtask") into its note?"
        case "remove_from_tasks": return "Move \(subject ?? "this task") into Notes?"
        case "calendar_create": return "Add \(subject ?? "this event") to Calendar?"
        case "calendar_update": return "Change \(subject ?? "this event") in Calendar?"
        case "calendar_delete": return "Delete \(subject ?? "this event") from Calendar?"
        case "draw_delete_canvas": return phrase("Delete", "canvas")
        case "draw_delete_object": return "Delete an object from \(subject ?? "this canvas")?"
        case "update_note_table":
            let deletions = (arguments["operations"] as? [[String: Any]] ?? [])
                .compactMap { $0["op"] as? String }.filter { $0.hasPrefix("delete_") }
            let kind = Set(deletions.map { String($0.dropFirst("delete_".count)) })
            let what = kind.count == 1 ? kind.first!.replacingOccurrences(of: "_", with: " ") : "table part"
            let quantity = deletions.count == 1 ? "a \(what)" : "\(deletions.count) \(what)s"
            return "Delete \(quantity) from \(subject ?? "this note")?"
        default: return "Approve change to \(subject ?? "this item")?"
        }
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
        case draw(UUID, DrawSnapshot, UUID, String)
        case durableDraw(UUID, DrawSnapshot, UUID, Data, String)
        case taskEdit(before: TaskEditableState, after: TaskEditableState,
                      proof: WorkspaceModelToken, name: String)
        case createdTask(UUID, TaskEditableState, WorkspaceModelToken, String)
        case calendar(UUID, before: CalendarEventDraft?, after: CalendarEventDraft?, name: String)
        case createdNote(UUID, revision: String, metadata: String, name: String)
        case updatedNote(UUID, document: NoteDocument?, title: String, body: String,
                         revision: String, metadata: String, name: String)
        case proposal(noteID: UUID, editID: UUID, name: String)
        case unavailable(String)

        var title: String {
            switch self {
            case let .history(_, _, name), let .draw(_, _, _, name), let .durableDraw(_, _, _, _, name),
                 let .createdNote(_, _, _, name),
                 let .taskEdit(_, _, _, name), let .calendar(_, _, _, name),
                 let .createdTask(_, _, _, name),
                 let .proposal(_, _, name),
                 let .updatedNote(_, _, _, _, _, _, name), let .unavailable(name): name
            }
        }
    }

    struct Journal {
        var changeSet: AgentChangeSet
        var entries: [UndoEntry] = []
    }

    /// Only inverses whose complete proof can be reconstructed are offered
    /// after relaunch. Closure-only history steps are recorded as unavailable.
    private enum StoredInverse: Codable {
        case draw(id: UUID, saved: DrawSnapshot, step: UUID, proof: Data, name: String)
        case taskEdit(before: TaskEditableState, after: TaskEditableState,
                      proof: WorkspaceModelToken, name: String)
        case createdTask(id: UUID, state: TaskEditableState, proof: WorkspaceModelToken, name: String)
        case calendar(id: UUID, before: CalendarEventDraft?, after: CalendarEventDraft?, name: String)
        case createdNote(id: UUID, revision: String, metadata: String, name: String)
        case updatedNote(id: UUID, document: Data?, title: String, body: String, revision: String, metadata: String, name: String)
        case proposal(id: UUID, edit: UUID, name: String)
        case unavailable(String)
    }
    private struct StoredRequest: Codable {
        let changeSet: AgentChangeSet
        let entries: [StoredInverse]
        /// Saved before an agent store call. Nil means every known call has
        /// either completed its receipt or was explicitly refused.
        var pendingAction: PendingAction?
        /// Saved before an inverse begins, and cleared only after its new
        /// physical proof and the shortened receipt reach disk.
        var undoInFlight: UndoInFlight?
    }
    private struct PendingAction: Codable {
        let name: String
        let targetID: String?
        var description: String {
            "\(name)\(targetID.map { " (\($0))" } ?? "")"
        }
    }
    private struct UndoInFlight: Codable {
        let entryIndex: Int
        let name: String
    }
    private struct StoredUndo: Codable {
        let version: Int
        let requests: [StoredRequest]
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
    private var requestModes: [UUID: AgentChatMode] = [:]
    private var activeCalls: [UUID: Int] = [:]
    private var closedRequests = Set<UUID>()
    private var idleWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let journalURL: URL?
    private var journalWritable = true
    private var journalIssue: String?
    private var pendingActions: [UUID: PendingAction] = [:]
    private var undoInFlight: [UUID: UndoInFlight] = [:]
    private var reconciliationIssues: [UUID: String] = [:]

    init(tasks: AgentTaskTools, calendarSource: (any CalendarEventSource)? = nil,
         calendarWriter: (any CalendarEventWriter)? = nil,
         draw: (any DrawStoreProtocol)? = nil,
         openPage: ((AgentPage) -> Bool)? = nil,
         journalURL: URL? = nil) {
        self.tasks = tasks
        self.calendarSource = calendarSource
        self.calendarWriter = calendarWriter
        self.draw = draw
        self.openPage = openPage
        self.journalURL = journalURL
        if let journalURL, FileManager.default.fileExists(atPath: journalURL.path) {
            guard let data = try? Data(contentsOf: journalURL),
                  let saved = try? JSONDecoder().decode(StoredUndo.self, from: data), saved.version == 1 else {
                journalWritable = false
                journalIssue = "the saved Undo journal is damaged or incompatible; it has been kept for diagnosis"
                return
            }
            for request in saved.requests {
                let entries = request.entries.map(Self.restoreInverse)
                journals[request.changeSet.id] = Journal(changeSet: request.changeSet, entries: entries)
                order.append(request.changeSet.id)
                closedRequests.insert(request.changeSet.id)
                if let pending = request.pendingAction { pendingActions[request.changeSet.id] = pending }
                if let checkpoint = request.undoInFlight { undoInFlight[request.changeSet.id] = checkpoint }
            }
            reconcileInterruptedUndo()
        }
    }

    private static func restoreInverse(_ stored: StoredInverse) -> UndoEntry {
        switch stored {
        case let .draw(id, saved, step, proof, name):
            return .durableDraw(id, saved, step, proof, name)
        case let .taskEdit(before, after, proof, name):
            return .taskEdit(before: before, after: after, proof: proof, name: name)
        case let .createdTask(id, state, proof, name):
            return .createdTask(id, state, proof, name)
        case let .calendar(id, before, after, name):
            return .calendar(id, before: before, after: after, name: name)
        case let .createdNote(id, revision, metadata, name):
            return .createdNote(id, revision: revision, metadata: metadata, name: name)
        case let .updatedNote(id, bytes, title, body, revision, metadata, name):
            let document: NoteDocument?
            if let bytes {
                guard case let .editable(decoded) = NoteContentCodec.decode(bytes) else {
                    return .unavailable("\(name): the previous document cannot be restored")
                }
                document = decoded
            } else {
                // Legacy plain-text notes have no structured document yet.
                // Their guarded title/body inverse is still durable.
                document = nil
            }
            return .updatedNote(id, document: document, title: title, body: body, revision: revision,
                                metadata: metadata, name: name)
        case let .proposal(id, edit, name): return .proposal(noteID: id, editID: edit, name: name)
        case let .unavailable(reason): return .unavailable(reason)
        }
    }

    private static func storeInverse(_ entry: UndoEntry) -> StoredInverse {
        switch entry {
        case let .durableDraw(id, saved, step, proof, name):
            return .draw(id: id, saved: saved, step: step, proof: proof, name: name)
        case let .taskEdit(before, after, proof, name):
            return .taskEdit(before: before, after: after, proof: proof, name: name)
        case let .createdTask(id, state, proof, name):
            return .createdTask(id: id, state: state, proof: proof, name: name)
        case let .calendar(id, before, after, name):
            return .calendar(id: id, before: before, after: after, name: name)
        case let .createdNote(id, revision, metadata, name):
            return .createdNote(id: id, revision: revision, metadata: metadata, name: name)
        case let .updatedNote(id, document, title, body, revision, metadata, name):
            let bytes: Data?
            if let document {
                guard let encoded = try? NoteContentCodec.encode(document) else {
                    return .unavailable("\(name): previous document could not be saved")
                }
                bytes = encoded
            } else {
                bytes = nil
            }
            return .updatedNote(id: id, document: bytes, title: title, body: body, revision: revision,
                                metadata: metadata, name: name)
        case let .proposal(id, edit, name): return .proposal(id: id, edit: edit, name: name)
        default: return .unavailable("\(entry.title): Undo requires the original session history")
        }
    }

    private func saveJournal() throws {
        guard let journalURL else { return }
        guard journalWritable else { throw AgentActionsError.refused(journalIssue ?? "the Undo journal is unavailable") }
        let requests = order.compactMap { id -> StoredRequest? in
            guard let journal = journals[id],
                  !journal.entries.isEmpty || pendingActions[id] != nil || undoInFlight[id] != nil else { return nil }
            return StoredRequest(changeSet: journal.changeSet,
                                 entries: journal.entries.map(Self.storeInverse),
                                 pendingAction: pendingActions[id], undoInFlight: undoInFlight[id])
        }
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(StoredUndo(version: 1, requests: Array(requests.suffix(100))))
                .write(to: journalURL, options: .atomic)
        } catch {
            journalWritable = false
            journalIssue = error.localizedDescription
            throw AgentActionsError.refused("Attic couldn't finish saving Undo: \(error.localizedDescription)")
        }
    }

    private func requireDurableUndoBeforeMutation() throws {
        guard journalURL != nil else { return }
        guard journalWritable else {
            throw AgentActionsError.refused("Attic can't save Undo for this change, so it didn't make it: \(journalIssue ?? "journal unavailable")")
        }
        if let pending = pendingActions.values.first {
            throw AgentActionsError.refused("Attic can't safely record another change while \(pending.description) has an unfinished Undo receipt. Review that step first.")
        }
        if let checkpoint = undoInFlight.values.first {
            throw AgentActionsError.refused("Attic can't safely record another change while Undo of \(checkpoint.name) is unfinished. Review that step first.")
        }
        do { try saveJournal() } catch {
            throw AgentActionsError.refused("Attic can't save Undo for this change, so it didn't make it: \(journalIssue ?? error.localizedDescription)")
        }
    }

    private func recordMutationIntent(_ name: String, arguments: [String: Any], requestID: UUID) throws {
        guard journalURL != nil else { return }
        let target = (arguments["id"] as? String) ?? (arguments["canvas_id"] as? String)
        pendingActions[requestID] = PendingAction(name: name, targetID: target)
        do { try saveJournal() } catch {
            pendingActions[requestID] = nil
            throw AgentActionsError.refused("Attic can't save Undo for this change, so it didn't make it: \(journalIssue ?? error.localizedDescription)")
        }
    }

    private func pendingExplanation(_ id: UUID) -> String? {
        if let pending = pendingActions[id] {
            return "Attic was interrupted during \(pending.description). Its store result is uncertain and its Undo receipt is unfinished; review that exact step before reversing this request."
        }
        return reconciliationIssues[id]
    }

    private func latestUnfinishedRequest() -> UUID? {
        order.last { (journals[$0]?.changeSet.count ?? 0) > 0 || pendingActions[$0] != nil || undoInFlight[$0] != nil }
    }

    /// After an inverse changes the store, the preceding step's expected
    /// physical token may be new (SwiftData updates its revision on save).
    /// Persist those new proofs with the completed-step checkpoint.
    private func refreshRemainingProofs(_ journal: inout Journal,
                                        taskProofs: [UUID: WorkspaceModelToken] = [:],
                                        noteRevisions: [UUID: String] = [:],
                                        noteMetadata: [UUID: String] = [:]) {
        journal.entries = journal.entries.map { entry in
            switch entry {
            case let .taskEdit(before, after, proof, name):
                return .taskEdit(before: before, after: after,
                                 proof: taskProofs[after.id] ?? proof, name: name)
            case let .createdTask(id, state, proof, name):
                return .createdTask(id, state, taskProofs[id] ?? proof, name)
            case let .createdNote(id, revision, metadata, name):
                return .createdNote(id, revision: noteRevisions[id] ?? revision,
                                    metadata: noteMetadata[id] ?? metadata, name: name)
            case let .updatedNote(id, document, title, body, revision, metadata, name):
                return .updatedNote(id, document: document, title: title, body: body,
                                    revision: noteRevisions[id] ?? revision,
                                    metadata: noteMetadata[id] ?? metadata, name: name)
            default: return entry
            }
        }
    }

    /// A checkpoint may describe either an inverse whose save never happened,
    /// or one whose store save finished before the receipt rewrite. Never
    /// guess from the presentation winner. If the full family cannot prove a
    /// task transition, retain the checkpoint and identify the blocked step.
    private func reconcileInterruptedUndo() {
        for (id, checkpoint) in undoInFlight {
            guard var journal = journals[id], checkpoint.entryIndex == journal.entries.count - 1,
                  let entry = journal.entries.last else {
                reconciliationIssues[id] = "Undo of \(checkpoint.name) stopped with an inconsistent receipt; review this step."
                continue
            }
            switch entry {
            case let .taskEdit(before, after, proof, _):
                guard let current = taskSnapshot(after.id) else {
                    reconciliationIssues[id] = "Undo of \(checkpoint.name) stopped: the task family is missing or divergent."
                    continue
                }
                if current.state == after && current.proof == proof {
                    // No inverse was committed: retry against the original seal.
                    undoInFlight[id] = nil
                } else if current.state == before &&
                          current.proof.replicas.map(\.physicalID) == proof.replicas.map(\.physicalID) {
                    journal.entries.removeLast()
                    refreshRemainingProofs(&journal, taskProofs: [after.id: current.proof])
                    journal.changeSet.count = journal.entries.count
                    if journal.entries.isEmpty {
                        journals[id] = nil
                        order.removeAll { $0 == id }
                    } else { journals[id] = journal }
                    undoInFlight[id] = nil
                } else {
                    reconciliationIssues[id] = "Undo of \(checkpoint.name) stopped at a changed physical task family."
                    continue
                }
            default:
                // External Calendar saves, Draw, and note history do not
                // expose an unambiguous post-crash commit proof here.
                reconciliationIssues[id] = "Undo of \(checkpoint.name) was interrupted. Its completion cannot be confirmed; review this exact step."
                continue
            }
            do { try saveJournal() }
            catch { reconciliationIssues[id] = "Undo of \(checkpoint.name): \(error.localizedDescription)" }
        }
    }

    func canRecoverUndo(_ id: UUID) -> Bool {
        guard latestUnfinishedRequest() == id, pendingActions[id] == nil, undoInFlight[id] == nil,
              reconciliationIssues[id] == nil,
              let journal = journals[id], !journal.entries.isEmpty, journalWritable else { return false }
        return journal.entries.allSatisfy { entry in
            if case .unavailable = Self.storeInverse(entry) { return false }
            return true
        }
    }

    #if DEBUG && ATTIC_LOCAL_ONLY
    /// Simulate the exact crash windows without killing the hosted test runner.
    var testInterruptAfterStoreSave: (() throws -> Void)?
    var testInterruptAfterInverseSave: (() -> Bool)?
    #endif

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

    /// Keep the allowlist closed: every current or future write tool must be
    /// explicitly reviewed before Read only can offer or execute it.
    static func isReadOnlyAction(_ name: String) -> Bool {
        ["list_tasks", "get_task_workspace", "list_notes", "list_deleted", "list_tags",
         "get_settings", "search_items", "calendar_search", "calendar_read",
         "calendar_list_calendars", "draw_list_canvases", "draw_read_canvas"].contains(name)
    }

    func setMode(_ mode: AgentChatMode, for requestID: UUID) throws {
        try checkOpen(requestID)
        requestModes[requestID] = mode
        if mode == .readOnly { cancelApprovals(for: requestID) }
    }

    func guardMode(_ name: String, requestID: UUID) throws {
        if requestModes[requestID] == .readOnly && !Self.isReadOnlyAction(name) {
            throw AgentActionsError.refused("Read only: \(name.replacingOccurrences(of: "_", with: " ")) would change something. Nothing was changed.")
        }
    }

    func refusalStep(name: String, arguments: [String: Any], reason: String) -> AgentStep {
        let targets = targetsForArguments(name, arguments)
        let title = targets.compactMap(\.title).first ?? AgentActionWords.running(name, arguments)
        return AgentStep(id: UUID(), title: AgentActionWords.clip("Refused: \(title)"),
                         kind: .read, targets: targets, state: .failed(reason))
    }

    @discardableResult
    func beginRequest(title: String, id: UUID = UUID()) -> UUID {
        journals[id] = Journal(changeSet: AgentChangeSet(id: id, title: title, pages: [], count: 0))
        requestModes[id] = .askFirst
        order.append(id)
        return id
    }

    func changeSet(for requestID: UUID) -> AgentChangeSet? {
        guard let set = journals[requestID]?.changeSet, set.count > 0 else { return nil }
        return set
    }

    /// Finished mutations saved to the independent Undo journal. The chat
    /// runner uses these to recover receipts after a rejected thread write.
    func durableChangeSets() -> [AgentChangeSet] {
        guard journalURL != nil, journalWritable else { return [] }
        return order.compactMap { changeSet(for: $0) }
    }

    /// `watching` comes from the host run, never from the model's JSON.
    func call(name: String, arguments: [String: Any], watching: Bool, requestID: UUID) async throws -> AgentActionCall {
        try checkOpen(requestID)
        try guardMode(name, requestID: requestID)
        activeCalls[requestID, default: 0] += 1
        defer { callEnded(requestID) }
        try validate(name, arguments)
        let localArguments = try preparedArguments(name: name, arguments: arguments)
        let prepared = try await preparedCalendarArguments(name: name, arguments: localArguments)
        try checkOpen(requestID)
        try guardMode(name, requestID: requestID)
        if requestModes[requestID] != .auto && AgentActionApprovalPolicy.requiresApproval(name, arguments: prepared) {
            let id = UUID()
            let targets = targetsForArguments(name, prepared)
            let approval = AgentApproval(id: id,
                                         title: AgentApprovalWords.title(name, arguments: prepared, targets: targets),
                                         targets: targets)
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
        try guardMode(pending.name, requestID: pending.requestID)
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
        requestModes[id] = nil
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
        try guardMode(name, requestID: requestID)
        if Self.isMutation(name) { try requireDurableUndoBeforeMutation() }
        let route = tasks.library.undo
        let before = Dictionary(uniqueKeysWithValues: route.retainedHistories.map {
            ($0, route.steps(in: $0, redo: false).map(\.id))
        })
        let priorTargets = targetsForArguments(name, arguments)
        let noteBefore = ["update_note", "update_note_table"].contains(name)
            ? noteSnapshot(for: arguments) : nil
        let taskBefore = name == "update_task"
            ? (arguments["id"] as? String).flatMap(UUID.init(uuidString:)).flatMap(taskSnapshot)
            : nil
        var batchTaskBefore: [UUID: (state: TaskEditableState, proof: WorkspaceModelToken)] = [:]
        if name == "update_tasks", let operations = arguments["updates"] as? [[String: Any]] {
            for operation in operations {
                guard let prepared = try? preparedArguments(name: "update_task", arguments: operation),
                      let raw = prepared["id"] as? String, let id = UUID(uuidString: raw),
                      let snapshot = taskSnapshot(id) else { continue }
                batchTaskBefore[id] = snapshot
            }
        }
        if Self.isMutation(name) {
            try recordMutationIntent(name, arguments: arguments, requestID: requestID)
        }
        var step: AgentStep
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
            (text, step) = try await calendarAction(name, arguments, requestID: requestID)
            if ["calendar_create", "calendar_update", "calendar_delete"].contains(name),
               let id = step.targets.first?.itemID {
                let old = (arguments["_expected_draft"] as? String)
                    .flatMap { Data(base64Encoded: $0) }
                    .flatMap { try? JSONDecoder().decode(CalendarEventDraft.self, from: $0) }
                let after = name == "calendar_delete" ? nil : try await calendarWriter?.ownedEvent(id: id)?.draft
                if name == "calendar_create" || old != nil {
                    if name == "calendar_delete" || after != nil {
                        extraEntries.append(.calendar(id, before: old, after: after, name: step.title))
                    }
                }
            }
        } else if name.hasPrefix("draw_") {
            let result = try drawAction(name, arguments)
            text = result.0; step = result.1
            if let snapshot = result.2 {
                if let undoID = draw?.undoStepID(on: snapshot.canvas.id) {
                    if let proof = draw?.agentUndoProof(on: snapshot.canvas.id, stepID: undoID) {
                        extraEntries.append(.durableDraw(snapshot.canvas.id, snapshot, undoID, proof, step.title))
                    } else {
                        extraEntries.append(.draw(snapshot.canvas.id, snapshot, undoID, step.title))
                    }
                } else {
                    extraEntries.append(.unavailable("\(step.title): Draw's Undo step is unavailable"))
                }
            }
        } else {
            text = if AgentTaskTools.asyncToolNames.contains(name), tasks.notesController != nil {
                try await tasks.callAsync(name: name, arguments: arguments)
            } else {
                try tasks.call(name: name, arguments: arguments)
            }
            let targets = Self.targetsFromResponse(text, name: name, arguments: arguments)
            step = AgentStep(id: UUID(), title: Self.stepTitle(name, arguments),
                             kind: Self.stepKind(name, arguments), targets: targets, state: .done)
            if name == "create_note", let id = targets.first?.itemID {
                if let revision = tasks.noteStore?.note(withID: id)?.revisionToken,
                   let metadata = tasks.noteStore?.agentCreatedNoteMetadata(id) {
                    extraEntries.append(.createdNote(id, revision: revision, metadata: metadata, name: step.title))
                } else {
                    extraEntries.append(.unavailable("\(step.title): the created note could not be read back"))
                }
            }
            if let before = noteBefore,
               let response = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
               response["status"] as? String == "applied",
               let note = response["note"] as? [String: Any],
               let revision = note["revision"] as? String,
               let metadata = tasks.noteStore?.agentCreatedNoteMetadata(before.id) {
                extraEntries.append(.updatedNote(before.id, document: before.document,
                                                 title: before.title, body: before.body,
                                                 revision: revision, metadata: metadata, name: step.title))
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
        #if DEBUG && ATTIC_LOCAL_ONLY
        if Self.isMutation(name) { try testInterruptAfterStoreSave?() }
        #endif
        step.targets = step.targets.map { target in
            guard target.title == nil else { return target }
            var enriched = target
            enriched.title = priorTargets.first(where: {
                $0.itemID != nil && $0.itemID == target.itemID && $0.page == target.page
            })?.title
            return enriched
        }
        step.title = AgentActionWords.completed(name, arguments, response: text, targets: step.targets,
                                               previousNoteBody: noteBefore?.body)
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
        // An editable task transition can be replayed after the session's
        // closure-only UndoRoute is gone. Seal the full physical replica set
        // and use the same TaskStore transition that normal Undo uses.
        if name == "update_task", entries.count == 1, let taskBefore,
           let taskAfter = taskSnapshot(taskBefore.state.id),
           case .history = entries[0] {
            entries = [.taskEdit(before: taskBefore.state, after: taskAfter.state,
                                 proof: taskAfter.proof, name: step.title)]
        }
        if name == "update_tasks" {
            let ids = step.targets.compactMap(\.itemID)
            if !ids.isEmpty, Set(ids).count == ids.count, entries.count == ids.count,
               entries.allSatisfy({ if case .history = $0 { return true }; return false }) {
                let updated = ids.compactMap { id -> UndoEntry? in
                    guard let prior = batchTaskBefore[id], let current = taskSnapshot(id),
                          prior.state != current.state else { return nil }
                    return .taskEdit(before: prior.state, after: current.state,
                                     proof: current.proof, name: step.title)
                }
                if updated.count == ids.count { entries = updated }
            }
        }
        if ["create_task", "create_tasks"].contains(name) {
            let ids = step.targets.compactMap(\.itemID)
            if !ids.isEmpty, entries.count == ids.count,
               entries.allSatisfy({ if case .history = $0 { return true }; return false }) {
                let created = ids.compactMap { id -> UndoEntry? in
                    guard let snapshot = taskSnapshot(id) else { return nil }
                    return .createdTask(id, snapshot.state, snapshot.proof, step.title)
                }
                if created.count == ids.count { entries = created }
            }
        }
        if ["calendar_create", "calendar_update", "calendar_delete"].contains(name),
           entries.count == 1, extraEntries.count == 1, case .history = entries[0] {
            entries = extraEntries
            // The executable Calendar inverse replaces its session history
            // entry; recording both would replay the same write twice.
            extraEntries.removeAll()
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
        if Self.isMutation(name) { pendingActions[requestID] = nil }
        if !entries.isEmpty || (Self.isMutation(name) && journalURL != nil) { try saveJournal() }
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
        if let reason = pendingExplanation(id) {
            return AgentUndoReport(undone: 0, failures: [reason], remaining: changeSet(for: id))
        }
        if let checkpoint = undoInFlight[id] {
            return AgentUndoReport(undone: 0, failures: ["Undo was interrupted at \(checkpoint.name); review that exact step before retrying."],
                                   remaining: changeSet(for: id))
        }
        if !journalWritable {
            return AgentUndoReport(undone: 0, failures: ["Attic can't read or save Undo: \(journalIssue ?? "journal unavailable")"],
                                   remaining: changeSet(for: id))
        }
        guard latestUnfinishedRequest() == id,
              var journal = journals[id], journal.changeSet.count > 0 else {
            return AgentUndoReport(undone: 0, failures: ["Only the newest nonempty change set can be undone."], remaining: changeSet(for: id))
        }
        var failures: [String] = []
        var undone = 0
        var remaining: [UndoEntry] = []
        // Reverting a second edit creates a fresh revision token, so the
        // first edit in the same request must use that restored revision.
        var noteRevisions: [UUID: String] = [:]
        // Reversing an agent edit may itself refresh note metadata (including
        // version bookkeeping). That new state is a confirmed result of our
        // own Undo, so earlier entries must compare against it. An owner edit
        // still fails the before-write guard for the newest entry.
        var noteMetadata: [UUID: String] = [:]
        var taskProofs: [UUID: WorkspaceModelToken] = [:]
        let route = tasks.library.undo
        for entry in journal.entries.reversed() {
            if journalURL != nil {
                undoInFlight[id] = UndoInFlight(entryIndex: journal.entries.count - 1, name: entry.title)
                do { try saveJournal() }
                catch {
                    failures.append("Couldn't checkpoint Undo before \(entry.title): \(error.localizedDescription)")
                    break
                }
            }
            var success = false
            switch entry {
            case let .createdTask(id, expected, proof, _):
                // A task created in a previous process is still ours only if
                // every physical replica matches the exact post-create seal.
                // New child tasks or task notes are also owner changes: do
                // not allow their cascade deletion through a stale receipt.
                let context = ModelContext(tasks.store.container)
                let linkedNotes = (try? context.fetch(FetchDescriptor<NoteItem>()))?
                    .contains(where: { $0.taskID == id && $0.deletedAt == nil }) ?? true
                if !linkedNotes, let current = taskSnapshot(id), current.state == expected,
                   current.proof == proof,
                   (try? tasks.store.liveSubtaskIDs(of: id).isEmpty) == true {
                    success = tasks.store.delete(taskIDs: [id])
                }
                if !success { failures.append("\(entry.title): a newer edit or missing undo step prevents reversal") }
            case let .taskEdit(before, after, proof, _):
                if let current = taskSnapshot(after.id), current.state == after,
                   current.proof == (taskProofs[after.id] ?? proof),
                   tasks.store.applyEditableTransition(from: [after], to: [before]) == .applied {
                    success = true
                    if let updated = taskSnapshot(after.id) { taskProofs[after.id] = updated.proof }
                }
                if !success { failures.append("\(entry.title): a newer edit or missing undo step prevents reversal") }
            case let .calendar(id, before, after, _):
                if let writer = calendarWriter {
                    do {
                        try await writer.undoAgentChange(id, expected: after, restore: before)
                        success = true
                    } catch {
                        failures.append("\(entry.title): event changed or refused restoration")
                    }
                } else { failures.append("\(entry.title): Calendar writer unavailable") }
            case let .history(history, expectedID, _):
                if route.undoStepID(in: history) != expectedID {
                    failures.append("\(entry.title): a newer edit or missing undo step prevents reversal")
                } else {
                    let result = await route.replay(in: history, redo: false)
                    success = result == .applied
                    if !success { failures.append("\(entry.title): \(String(describing: result))") }
                }
            case let .draw(canvasID, snapshot, expectedStepID, _):
                if let draw, let current = try? draw.open(canvasID),
                   current.objects == snapshot.objects && current.canvas.name == snapshot.canvas.name,
                   draw.undoStepID(on: canvasID) == expectedStepID {
                    success = draw.undo(on: canvasID).isSaved
                }
                if !success { failures.append("\(entry.title): Draw has changed or refused Undo") }
            case let .durableDraw(canvasID, snapshot, _, proof, _):
                if let draw, let current = try? draw.open(canvasID), current == snapshot {
                    success = draw.undoAgentStep(on: canvasID, proof: proof).isSaved
                }
                if !success { failures.append("\(entry.title): Draw has changed or refused Undo") }
            case let .createdNote(noteID, revision, metadata, _):
                success = tasks.noteStore?.undoAgentCreatedNote(
                    noteID, revision: noteRevisions[noteID] ?? revision,
                    metadata: noteMetadata[noteID] ?? metadata
                ) == true
                if !success { failures.append("\(entry.title): the note changed or could not be removed") }
            case let .updatedNote(noteID, document, title, body, revision, metadata, _):
                if let noteStore = tasks.noteStore, let document,
                   noteStore.agentCreatedNoteMetadata(noteID) == (noteMetadata[noteID] ?? metadata) {
                    // A note the chat wrote in while watched is on screen: a
                    // clean editor there is put back too, and reloads.
                    success = noteStore.agentRestore(noteID: noteID, document: document,
                                                     revision: noteRevisions[noteID] ?? revision)
                    if success { noteRevisions[noteID] = noteStore.note(withID: noteID)?.revisionToken }
                } else if let noteStore = tasks.noteStore, let current = noteStore.note(withID: noteID),
                   current.revisionToken == (noteRevisions[noteID] ?? revision),
                   noteStore.agentCreatedNoteMetadata(noteID) == (noteMetadata[noteID] ?? metadata),
                   noteStore.agentWriteDisposition(noteID) == .direct {
                    if let result = try? tasks.call(name: "update_note", arguments: [
                        "id": noteID.uuidString, "base_revision": current.revisionToken,
                        "title": title, "body": body
                    ]), let payload = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] {
                        success = payload["status"] as? String == "applied"
                    }
                    if success { noteRevisions[noteID] = noteStore.note(withID: noteID)?.revisionToken }
                }
                if success { noteMetadata[noteID] = tasks.noteStore?.agentCreatedNoteMetadata(noteID) }
                else { failures.append("\(entry.title): note changed or refused restoration") }
            case let .proposal(noteID, editID, _):
                success = tasks.noteStore?.discardProposal(editID, noteID: noteID) == true
                if !success { failures.append("\(entry.title): proposal already applied, changed or unavailable") }
            case let .unavailable(reason):
                failures.append(reason)
            }
            #if DEBUG && ATTIC_LOCAL_ONLY
            if success && testInterruptAfterInverseSave?() == true {
                return AgentUndoReport(undone: undone, failures: ["Injected interruption after inverse save"],
                                       remaining: changeSet(for: id))
            }
            #endif
            if journalURL != nil {
                if success {
                    undone += 1
                    journal.entries.removeLast()
                    refreshRemainingProofs(&journal, taskProofs: taskProofs,
                                           noteRevisions: noteRevisions, noteMetadata: noteMetadata)
                    journal.changeSet.count = journal.entries.count
                    if journal.entries.isEmpty {
                        journals[id] = nil
                        order.removeAll { $0 == id }
                    } else { journals[id] = journal }
                }
                undoInFlight[id] = nil
                do { try saveJournal() }
                catch { failures.append("Undo reached \(entry.title), but its completion checkpoint could not be saved: \(error.localizedDescription)") }
                // An earlier inverse is never tried while the newest one is
                // unresolved, or while a checkpoint cannot reach disk.
                if !success || !journalWritable { break }
                continue
            }
            if success { undone += 1 } else { remaining.insert(entry, at: 0) }
        }
        if journalURL != nil {
            return AgentUndoReport(undone: undone, failures: failures, remaining: changeSet(for: id))
        }
        journal.entries = remaining.map { entry in
            if case let .updatedNote(id, document, title, body, revision, metadata, name) = entry,
               let restoredRevision = noteRevisions[id] {
                return .updatedNote(id, document: document, title: title, body: body,
                                    revision: restoredRevision, metadata: metadata, name: name)
            }
            return entry
        }
        journal.changeSet.count = journal.entries.count
        if remaining.isEmpty {
            journals[id] = nil
            order.removeAll { $0 == id }
        } else { journals[id] = journal }
        do { try saveJournal() }
        catch { failures.append("Undo was applied, but its journal checkpoint failed: \(error.localizedDescription)") }
        return AgentUndoReport(undone: undone, failures: failures, remaining: changeSet(for: id))
    }

    /// Read the entire physical UUID family. If its editable values already
    /// diverge, a single logical inverse cannot safely restore every copy.
    private func taskSnapshot(_ id: UUID) -> (state: TaskEditableState, proof: WorkspaceModelToken)? {
        let context = ModelContext(tasks.store.container)
        guard let rows = try? context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })),
              let first = rows.first, first.deletedAt == nil else { return nil }
        let state = TaskEditableState(first)
        guard rows.allSatisfy({ $0.deletedAt == nil && TaskEditableState($0) == state }),
              let proof = try? WorkspaceModelToken.read(WorkspaceOwner(entity: .task, id: id), in: context)
        else { return nil }
        return (state, proof)
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
        name.hasPrefix("draw_add_") || ["draw_edit_text", "draw_move_object", "draw_rename_canvas", "draw_delete_canvas",
                                         "draw_create_canvas", "draw_duplicate_canvas", "draw_delete_object",
                                         "draw_restyle_object", "draw_resize_object"].contains(name)
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
        Self.targetsFromResponse("{}", name: name, arguments: arguments).map { target in
            guard target.title == nil, let id = target.itemID else { return target }
            var enriched = target
            switch target.page {
            case .tasks: enriched.title = tasks.store.task(withID: id)?.title
            case .notes: enriched.title = tasks.noteStore?.note(withID: id)?.title
            case .draw: enriched.title = (try? draw?.open(id))?.canvas.name
            case .calendar: enriched.title = arguments["_resolved_title"] as? String
            }
            return enriched
        }
    }

    private static func targetsFromResponse(_ text: String, name: String, arguments: [String: Any]) -> [AgentTarget] {
        let payload = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? [:]
        if name.hasPrefix("draw_") {
            let canvasID = ((payload["canvas_id"] ?? arguments["canvas_id"]) as? String)
                .flatMap(UUID.init(uuidString:))
            let objectID = ((payload["object_id"] ?? arguments["object_id"]) as? String)
                .flatMap(UUID.init(uuidString:))
            if let id = objectID ?? canvasID {
                return [AgentTarget(page: .draw, itemID: id,
                                    title: (payload["canvas_name"] ?? arguments["canvas_name"]) as? String,
                                    containerID: canvasID)]
            }
            return []
        }
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
