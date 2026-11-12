import Foundation

/// A run gets its own bearer credential and one change set. Existing MCP
/// clients use the server's original credential and never enter this adapter.
/// A waiting approval is kept in memory until the owner answers or ends the run.
/// MCP waits briefly for a response, then returns a poll receipt before the
/// socket's 30-second deadline; an unattended owner never loses the request.
@MainActor
final class AgentActionsMCP {
    private enum ApprovalState {
        case waiting
        case resolving
        case completed(AgentActionResult)
        case refused(String)
        case failed(String)
    }

    private struct Pending {
        let approval: AgentApproval
        let actionName: String
        let argumentsJSON: String
        var state: ApprovalState = .waiting
    }

    private struct Run {
        let requestID: UUID
        var watching: Bool
        var mode: AgentChatMode = .askFirst
        var pending: [UUID: Pending] = [:]
    }

    private let actions: AgentActions
    private var runs: [String: Run] = [:]

    init(actions: AgentActions) { self.actions = actions }

    var hasRuns: Bool { !runs.isEmpty }
    func contains(token: String) -> Bool { runs[token] != nil }

    var definitions: [[String: Any]] {
        actions.definitions + [[
            "name": "agent_approval_status",
            "description": "Poll an owner approval returned by a tool. Wait and poll again while its status is waiting.",
            "inputSchema": ["type": "object", "properties": ["approval_id": ["type": "string"]],
                            "required": ["approval_id"], "additionalProperties": false]
        ]]
    }

    func definitions(token: String) -> [[String: Any]] {
        guard let run = runs[token] else { return [] }
        return run.mode == .readOnly
            ? definitions.filter { def in
                guard let name = def["name"] as? String else { return false }
                return AgentActions.isReadOnlyAction(name) || name == "agent_approval_status"
            }
            : definitions
    }

    /// Called only by the trusted app/run coordinator; never exposed as MCP.
    func beginRun(title: String, watching: Bool, requestID: UUID? = nil) -> String {
        let token = UUID().uuidString + UUID().uuidString
        runs[token] = Run(requestID: actions.beginRequest(title: title, id: requestID ?? UUID()), watching: watching)
        return token
    }

    func setWatching(_ watching: Bool, token: String) throws {
        guard runs[token] != nil else { throw AgentActionsError.invalid("Unknown agent run.") }
        runs[token]?.watching = watching
    }

    func setMode(_ mode: AgentChatMode, token: String) throws {
        guard let run = runs[token] else { throw AgentActionsError.invalid("Unknown agent run.") }
        try actions.setMode(mode, for: run.requestID)
        runs[token]?.mode = mode
        if mode == .readOnly {
            for id in run.pending.keys {
                switch runs[token]?.pending[id]?.state {
                case .waiting?, .resolving?:
                    runs[token]?.pending[id]?.state = .refused("Read only: that action was refused. Nothing was changed.")
                default: break
                }
            }
        }
    }

    @discardableResult
    func finishRun(token: String) -> UUID? {
        guard let run = runs.removeValue(forKey: token) else { return nil }
        actions.sealRequest(run.requestID)
        return run.requestID
    }

    func drainedChangeSet(requestID: UUID) async -> AgentChangeSet? {
        await actions.drainRequest(requestID)
    }

    func finishAllRuns() {
        for token in Array(runs.keys) { finishRun(token: token) }
    }

    /// Uses the same host and constant-time bearer check as existing clients.
    func authorizedRunToken(headers: [String: String]) -> String? {
        runs.keys.first { AgentRequestSecurity.isAuthorized(headers: headers, bearerToken: $0) }
    }

    func pendingApprovals(token: String) -> [AgentApproval] {
        guard let run = runs[token] else { return [] }
        return run.pending.values.compactMap { pending in
            if case .waiting = pending.state { return pending.approval }
            return nil
        }
    }

    func changeSet(token: String) -> AgentChangeSet? {
        guard let run = runs[token] else { return nil }
        return actions.changeSet(for: run.requestID)
    }

    /// The owner invokes Undo through the trusted chat view.
    func undo(changeSet id: UUID, token: String) async throws -> AgentUndoReport {
        guard let run = runs[token], run.requestID == id else {
            throw AgentActionsError.invalid("Change set does not belong to this run.")
        }
        return await actions.undo(changeSet: id)
    }

    /// The owner may undo from the chat thread after its CLI run has ended.
    /// This trusted app-only API is not advertised over MCP.
    func undoFinishedChangeSet(_ id: UUID) async -> AgentUndoReport {
        await actions.undo(changeSet: id)
    }

    func call(name: String, arguments: [String: Any], token: String) async throws -> [String: Any] {
        guard let run = runs[token] else { throw AgentActionsError.invalid("Unknown agent run.") }
        if name == "agent_approval_status" {
            guard arguments.count == 1, let raw = arguments["approval_id"] as? String,
                  let id = UUID(uuidString: raw), let pending = run.pending[id] else {
                throw AgentActionsError.invalid("Unknown approval for this run.")
            }
            return Self.status(pending)
        }

        // A repeated call while approval is pending must not create another
        // prompt, and cannot get past the owner's decision by retrying.
        let argumentsJSON = try AgentActions.json(arguments)
        if let pending = run.pending.values.first(where: { pending in
            guard pending.actionName == name, pending.argumentsJSON == argumentsJSON else { return false }
            switch pending.state { case .waiting, .resolving: return true; default: return false }
        }) {
            return Self.status(pending)
        }

        let outcome: AgentActionCall
        do {
            outcome = try await actions.call(name: name, arguments: arguments, watching: run.watching,
                                              requestID: run.requestID)
        } catch let AgentActionsError.refused(message) {
            return ["status": "refused", "message": message,
                    "step": Self.step(actions.refusalStep(name: name, arguments: arguments, reason: message))]
        }
        guard runs[token]?.requestID == run.requestID else {
            throw AgentActionsError.invalid("Agent run ended before the action finished.")
        }
        switch outcome {
        case let .performed(result): return Self.result(result)
        case let .approvalNeeded(approval):
            runs[token]?.pending[approval.id] = Pending(approval: approval, actionName: name,
                                                       argumentsJSON: argumentsJSON)
            return Self.status(Pending(approval: approval, actionName: name,
                                       argumentsJSON: argumentsJSON))
        }
    }

    /// The pending result is durable across calls and is never an approval.
    /// Hold an initial MCP request briefly when possible, with a bounded poll
    /// fallback for unattended owners and clients with request deadlines.
    func awaitApproval(_ id: UUID, token: String, maximumWait: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(max(0, maximumWait))
        while true {
            guard let pending = runs[token]?.pending[id] else {
                throw AgentActionsError.invalid("Agent run or approval expired.")
            }
            switch pending.state {
            case .waiting, .resolving:
                if Date() >= deadline { return Self.status(pending) }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            case .completed, .refused, .failed:
                return Self.status(pending)
            }
        }
    }

    /// Only called by the owner-facing app. The MCP model has no resolution tool.
    func resolve(approval id: UUID, allow: Bool, token: String) async throws {
        guard let pending = runs[token]?.pending[id], case .waiting = pending.state else {
            throw AgentActionsError.invalid("Unknown or already resolved approval for this run.")
        }
        runs[token]?.pending[id]?.state = .resolving
        do {
            let result = try await actions.resolve(approval: id, allow: allow)
            // An ended run cannot publish an old resolution to a new run.
            guard runs[token]?.pending[id] != nil else { return }
            if let result { runs[token]?.pending[id]?.state = .completed(result) }
            else { runs[token]?.pending[id]?.state = .refused("The owner refused this action.") }
        } catch {
            if runs[token]?.pending[id] != nil {
                if runs[token]?.mode == .readOnly {
                    runs[token]?.pending[id]?.state = .refused("Read only: that action was refused. Nothing was changed.")
                } else {
                    runs[token]?.pending[id]?.state = .failed(error.localizedDescription)
                }
            }
            throw error
        }
    }

    private static func status(_ pending: Pending) -> [String: Any] {
        switch pending.state {
        case .waiting, .resolving:
            return ["status": "waiting", "approvalNeeded": [
                "id": pending.approval.id.uuidString, "title": pending.approval.title,
                "targets": pending.approval.targets.map(target)
            ], "approval_id": pending.approval.id.uuidString,
                    "poll_tool": "agent_approval_status",
                    "message": "Waiting for the owner. Call agent_approval_status with approval_id to poll."]
        case let .completed(result): return self.result(result)
        case let .refused(message):
            return ["status": "refused", "message": message, "approval_title": pending.approval.title]
        case let .failed(message):
            return ["status": "failed", "message": message, "approval_title": pending.approval.title]
        }
    }

    private static func result(_ value: AgentActionResult) -> [String: Any] {
        var output: [String: Any] = [
            "status": "done", "text": value.text, "step": step(value.step)
        ]
        // Keep the text response for existing consumers, and expose parsed
        // result fields so a coding agent can reuse IDs without parsing JSON twice.
        if let data = value.text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            output["data"] = object
            if let rows = object as? [String: Any], let failed = rows["failed"] as? Int,
               failed > 0, let count = rows["count"] as? Int, failed < count {
                output["status"] = "partial"
                output["message"] = "\(failed) of \(count) operations failed; inspect data.results for individual errors. Successful changes remain undoable."
            }
        }
        switch value.step.state {
        case let .partial(reason):
            output["status"] = "partial"
            output["message"] = reason
        case let .failed(reason):
            output["status"] = "failed"
            output["error"] = reason
        case .running, .done: break
        }
        if let changeSet = value.changeSet {
            output["change_set"] = [
                "id": changeSet.id.uuidString, "title": changeSet.title,
                "pages": changeSet.pages.map(\.rawValue).sorted(), "count": changeSet.count
            ]
        }
        return output
    }

    private static func step(_ step: AgentStep) -> [String: Any] {
        let kind: String
        switch step.kind {
        case .read: kind = "read"
        case .create: kind = "create"
        case .update: kind = "update"
        case .move: kind = "move"
        case .delete: kind = "delete"
        case .openPage: kind = "openPage"
        }
        var output: [String: Any] = ["id": step.id.uuidString, "title": step.title,
                                    "kind": kind, "targets": step.targets.map(target)]
        if case let .move(toDay) = step.kind, let toDay {
            output["to_day"] = ISO8601DateFormatter().string(from: toDay)
        }
        switch step.state {
        case .running: output["state"] = "running"
        case .done: output["state"] = "done"
        case let .partial(reason): output["state"] = "partial"; output["reason"] = reason
        case let .failed(reason): output["state"] = "failed"; output["reason"] = reason
        }
        return output
    }

    private static func target(_ target: AgentTarget) -> [String: Any] {
        var data: [String: Any] = ["page": target.page.rawValue]
        if let id = target.itemID { data["item_id"] = id.uuidString }
        if let title = target.title { data["title"] = title }
        if let id = target.externalID { data["external_id"] = id }
        if let id = target.containerID { data["container_id"] = id.uuidString }
        return data
    }
}
