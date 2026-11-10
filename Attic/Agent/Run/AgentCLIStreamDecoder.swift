import Foundation

enum AgentBackend: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var title: String { self == .claude ? "Claude Code" : "Codex" }
    var loginCommand: String { self == .claude ? "claude auth login" : "codex login" }
}

/// One transition from a recorded CLI JSON line. Keeping protocol translation
/// separate from the process and MCP transport makes it possible to test the
/// agent's state machine without invoking either signed-in CLI.
struct AgentCLITransition {
    var outbound: [String] = []
    var events: [AgentEvent] = []
    var sessionID: String?
    var turnEnded = false
    var failure: String?
}

struct AgentCLIStreamDecoder {
    let backend: AgentBackend
    let instructions: String
    let workingDirectory: String
    private(set) var sessionID: String?

    private var codexInitialized = false
    private var codexThreadReady = false
    private var pendingPrompt = ""
    private var streamedClaudeText = false
    private var steps: [String: AgentStep] = [:]
    private var toolNames: [String: String] = [:]
    private var toolInputs: [String: [String: Any]] = [:]
    private var claudeInputs: [Int: (id: String, name: String, json: String)] = [:]
    private var finishedStepIDs = Set<String>()
    private var pendingApprovals: [UUID: (backendID: String, input: [String: Any])] = [:]

    init(backend: AgentBackend, instructions: String, sessionID: String? = nil,
         workingDirectory: String) {
        self.backend = backend
        self.instructions = instructions
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
    }

    mutating func beginTurn(_ prompt: String) -> AgentCLITransition {
        pendingPrompt = prompt
        streamedClaudeText = false
        steps.removeAll()
        toolNames.removeAll()
        toolInputs.removeAll()
        claudeInputs.removeAll()
        finishedStepIDs.removeAll()
        if backend == .claude {
            return AgentCLITransition(outbound: [Self.json([
                "type": "user", "message": ["role": "user", "content": prompt]
            ])])
        }
        if !codexInitialized {
            return AgentCLITransition(outbound: [Self.json([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["clientInfo": ["name": "attic", "title": "Attic", "version": "1.0"]]
            ])])
        }
        return AgentCLITransition(outbound: [codexTurn()])
    }

    mutating func accept(_ line: String) -> AgentCLITransition {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AgentCLITransition(failure: "The agent sent an invalid response.")
        }
        return backend == .claude ? acceptClaude(message) : acceptCodex(message)
    }

    mutating func answer(approval id: UUID, allow: Bool) -> AgentCLITransition {
        guard let request = pendingApprovals.removeValue(forKey: id) else { return AgentCLITransition() }
        let response: [String: Any]
        if backend == .claude {
            let decision: [String: Any] = allow
                ? ["behavior": "allow", "updatedInput": request.input]
                : ["behavior": "deny", "message": "The owner declined."]
            let details: [String: Any] = ["subtype": "success",
                                          "request_id": request.backendID,
                                          "response": decision]
            response = ["type": "control_response", "response": details]
        } else {
            response = ["jsonrpc": "2.0", "id": request.backendID,
                        "result": ["decision": allow ? "accept" : "decline"]]
        }
        return AgentCLITransition(outbound: [Self.json(response)])
    }

    private mutating func acceptClaude(_ message: [String: Any]) -> AgentCLITransition {
        var update = AgentCLITransition()
        switch message["type"] as? String {
        case "system":
            if message["subtype"] as? String == "init", let id = message["session_id"] as? String {
                sessionID = id
                update.sessionID = id
            }
        case "stream_event":
            if let event = message["event"] as? [String: Any] {
                switch event["type"] as? String {
                case "content_block_start":
                    if let block = event["content_block"] as? [String: Any],
                       block["type"] as? String == "tool_use",
                       let name = block["name"] as? String, let id = block["id"] as? String {
                        guard name.hasPrefix("mcp__attic__") else {
                            update.failure = "Claude Code tried a tool outside Attic."
                            return update
                        }
                        let toolName = String(name.dropFirst("mcp__attic__".count))
                        let input = block["input"] as? [String: Any] ?? [:]
                        startStep(id: id, name: toolName, arguments: input, into: &update)
                        if let index = event["index"] as? Int {
                            claudeInputs[index] = (id: id, name: toolName, json: "")
                        }
                    }
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any] {
                        if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                            streamedClaudeText = true
                            update.events.append(.textDelta(text))
                        } else if delta["type"] as? String == "input_json_delta",
                                  let part = delta["partial_json"] as? String,
                                  let index = event["index"] as? Int, var input = claudeInputs[index] {
                            input.json += part
                            claudeInputs[index] = input
                        }
                    }
                case "content_block_stop":
                    if let index = event["index"] as? Int,
                       let input = claudeInputs.removeValue(forKey: index),
                       let data = input.json.data(using: .utf8),
                       let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        rewordStep(id: input.id, name: input.name, arguments: args, into: &update)
                    }
                default: break
                }
            }
        case "assistant":
            if message["is_api_error_message"] as? Bool == true || message["error"] != nil {
                update.failure = "Claude Code could not answer."
                break
            }
            let blocks = ((message["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if !streamedClaudeText, let text = block["text"] as? String {
                        update.events.append(.textDelta(text))
                    }
                case "tool_use":
                    guard let name = block["name"] as? String, let id = block["id"] as? String else { continue }
                    guard name.hasPrefix("mcp__attic__") else {
                        update.failure = "Claude Code tried a tool outside Attic."
                        return update
                    }
                    let toolName = String(name.dropFirst("mcp__attic__".count))
                    let args = block["input"] as? [String: Any] ?? [:]
                    startStep(id: id, name: toolName, arguments: args, into: &update)
                    rewordStep(id: id, name: toolName, arguments: args, into: &update)
                default: break
                }
            }
            streamedClaudeText = false
        case "user":
            let blocks = ((message["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                finishStep(id: id, failed: block["is_error"] as? Bool == true,
                           result: block["content"], into: &update)
            }
        case "control_request":
            guard let id = message["request_id"] as? String,
                  let request = message["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool",
                  let name = request["tool_name"] as? String,
                  name.hasPrefix("mcp__attic__") else {
                update.failure = "Claude Code requested an unsupported permission."
                return update
            }
            let input = request["input"] as? [String: Any] ?? [:]
            // Claude's own permission gate is not the owner approval policy.
            // Only the run-scoped MCP action server can authorize store writes.
            update.outbound.append(Self.json(["type": "control_response", "response": [
                "subtype": "success", "request_id": id,
                "response": ["behavior": "allow", "updatedInput": input]
            ]]))
        case "result":
            if message["is_error"] as? Bool == true {
                update.failure = "Claude Code could not complete the request."
            } else {
                completeTurn(&update)
            }
        default: break
        }
        return update
    }

    private mutating func acceptCodex(_ message: [String: Any]) -> AgentCLITransition {
        var update = AgentCLITransition()
        if message["method"] == nil, let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                update.failure = (error["message"] as? String) ?? "Codex rejected the request."
                return update
            }
            let result = message["result"] as? [String: Any] ?? [:]
            switch id {
            case 1:
                codexInitialized = true
                var threadParams: [String: Any] = [
                    "cwd": workingDirectory, "approvalPolicy": "never",
                    "sandbox": "read-only", "developerInstructions": instructions
                ]
                let method: String
                if let sessionID, !sessionID.isEmpty {
                    method = "thread/resume"
                    threadParams["threadId"] = sessionID
                } else {
                    method = "thread/start"
                }
                update.outbound = [Self.json(["jsonrpc": "2.0", "method": "initialized"]),
                                   Self.json(["jsonrpc": "2.0", "id": 2, "method": method,
                                              "params": threadParams])]
            case 2:
                guard let thread = result["thread"] as? [String: Any],
                      let id = thread["id"] as? String, !id.isEmpty else {
                    update.failure = "Codex did not open its thread."
                    return update
                }
                sessionID = id
                update.sessionID = id
                codexThreadReady = true
                update.outbound = [codexTurn()]
            case 3: break // Turn accepted; wait for its stream and turn/completed.
            default: break
            }
            return update
        }
        guard let method = message["method"] as? String else { return update }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "item/agentMessage/delta":
            if let text = params["delta"] as? String { update.events.append(.textDelta(text)) }
        case "item/started", "item/completed":
            let item = params["item"] as? [String: Any] ?? [:]
            let type = item["type"] as? String ?? ""
            guard type == "mcpToolCall" else {
                if ["commandExecution", "fileChange", "webSearch"].contains(type) {
                    update.failure = "Codex requested a tool outside Attic."
                }
                return update
            }
            guard item["server"] as? String == "attic",
                  let id = item["id"] as? String,
                  let name = item["tool"] as? String else {
                update.failure = "Codex requested an unapproved MCP tool."
                return update
            }
            if method == "item/started" {
                startStep(id: id, name: name, arguments: Self.toolArguments(item), into: &update)
            } else {
                if steps[id] == nil { startStep(id: id, name: name, arguments: Self.toolArguments(item), into: &update) }
                rewordStep(id: id, name: name, arguments: Self.toolArguments(item), into: &update)
                let status = item["status"] as? String ?? "completed"
                finishStep(id: id, failed: status == "failed" || item["error"] != nil,
                           result: item["result"], into: &update)
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String ?? ""
            if status == "failed" || status == "interrupted" {
                update.failure = (turn["error"] as? [String: Any])?["message"] as? String
                    ?? (status == "interrupted" ? "Codex was interrupted." : "Codex could not complete the request.")
            } else { completeTurn(&update) }
        case "error":
            if params["willRetry"] as? Bool != true {
                update.failure = (params["error"] as? [String: Any])?["message"] as? String
                    ?? "Codex could not answer."
            }
        default:
            if message["id"] != nil {
                // CLI permissions are never a substitute for the trusted
                // AgentActionsMCP approval path. This runner grants none.
                update.failure = "Codex requested a permission outside Attic."
            }
        }
        return update
    }

    private func codexTurn() -> String {
        Self.json(["jsonrpc": "2.0", "id": 3, "method": "turn/start", "params": [
            "threadId": sessionID ?? "",
            "input": [["type": "text", "text": pendingPrompt]],
            "approvalPolicy": "never"
        ]])
    }

    private static func toolArguments(_ item: [String: Any]) -> [String: Any] {
        if let args = item["arguments"] as? [String: Any] { return args }
        if let args = item["input"] as? [String: Any] { return args }
        if let raw = item["arguments"] as? String,
           let data = raw.data(using: .utf8),
           let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return args }
        return [:]
    }

    private mutating func startStep(id: String, name: String, arguments: [String: Any] = [:],
                                    into update: inout AgentCLITransition) {
        guard steps[id] == nil else { return }
        let kind: AgentStepKind
        if name.contains("delete") { kind = .delete }
        else if name.contains("create") || name.contains("add_") { kind = .create }
        else if name.contains("move") { kind = .move(toDay: nil) }
        else if name.contains("update") || name.contains("edit") { kind = .update }
        else if name.contains("open") { kind = .openPage }
        else { kind = .read }
        let step = AgentStep(id: UUID(), title: AgentActionWords.running(name, arguments), kind: kind,
                             targets: [], state: .running)
        steps[id] = step
        toolNames[id] = name
        toolInputs[id] = arguments
        update.events.append(.stepStarted(step))
        update.events.append(.progress(done: finishedStepIDs.count, total: steps.count))
    }

    private mutating func rewordStep(id: String, name: String, arguments: [String: Any],
                                     into update: inout AgentCLITransition) {
        guard !arguments.isEmpty, var step = steps[id], !finishedStepIDs.contains(id) else { return }
        let title = AgentActionWords.running(name, arguments)
        toolInputs[id] = arguments
        guard title != step.title else { return }
        step.title = title
        steps[id] = step
        update.events.append(.stepReworded(step))
    }

    private mutating func finishStep(id: String, failed: Bool, result: Any? = nil,
                                     into update: inout AgentCLITransition) {
        guard var step = steps[id], finishedStepIDs.insert(id).inserted else { return }
        if let action = Self.actionEnvelope(result), let details = action["step"] as? [String: Any] {
            if let title = details["title"] as? String { step.title = title }
            if let kind = details["kind"] as? String {
                switch kind {
                case "read": step.kind = .read
                case "create": step.kind = .create
                case "update": step.kind = .update
                case "delete": step.kind = .delete
                case "openPage": step.kind = .openPage
                case "move":
                    let date = (details["to_day"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    step.kind = .move(toDay: date)
                default: break
                }
            }
            if let rawTargets = details["targets"] as? [[String: Any]] {
                step.targets = rawTargets.compactMap { value in
                    guard let rawPage = value["page"] as? String,
                          let page = AgentPage(rawValue: rawPage) else { return nil }
                    let id = (value["item_id"] as? String).flatMap(UUID.init(uuidString:))
                    let container = (value["container_id"] as? String).flatMap(UUID.init(uuidString:))
                    return AgentTarget(page: page, itemID: id, title: value["title"] as? String,
                                       externalID: value["external_id"] as? String,
                                       containerID: container)
                }
            }
            if details["state"] as? String == "partial" || action["status"] as? String == "partial" {
                let failures = ((action["data"] as? [String: Any])?["results"] as? [[String: Any]] ?? [])
                    .compactMap { row -> String? in
                        guard row["status"] as? String == "failed" else { return nil }
                        let number = (row["index"] as? Int ?? 0) + 1
                        return "Item \(number): \(row["error"] as? String ?? "Unknown error")"
                    }
                let message = details["reason"] as? String ?? action["message"] as? String ?? "Some operations failed."
                step.state = .partial(failures.isEmpty || failures.allSatisfy { message.contains($0) }
                    ? message : message + " " + failures.joined(separator: " "))
            } else if let state = details["state"] as? String, state == "failed" {
                step.state = .failed(details["reason"] as? String ?? "The tool returned an error.")
            } else if action["status"] as? String == "failed" {
                step.state = .failed(action["message"] as? String ?? "The tool returned an error.")
            } else {
                step.state = failed ? .failed("The tool returned an error.") : .done
            }
        } else if let action = Self.actionEnvelope(result), let status = action["status"] as? String {
            let approvalTitle = (action["approval_title"] as? String)
                ?? ((action["approvalNeeded"] as? [String: Any])?["title"] as? String)
            switch status {
            case "waiting":
                let detail = approvalTitle?.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
                    ?? AgentActionWords.running(toolNames[id] ?? "", toolInputs[id] ?? [:])
                step.title = AgentActionWords.clip("Awaiting approval: \(detail)")
                step.kind = .read // No mutation has occurred yet.
                step.state = .done
            case "refused", "failed":
                let detail = approvalTitle?.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
                    ?? AgentActionWords.running(toolNames[id] ?? "", toolInputs[id] ?? [:])
                step.title = AgentActionWords.clip("\(status == "refused" ? "Refused" : "Failed"): \(detail)")
                step.kind = .read
                step.state = .failed(action["message"] as? String ?? "The action was not performed.")
            default:
                step.title = AgentActionWords.finishedWithoutReceipt(step.title)
                step.state = failed ? .failed("The tool returned an error.") : .done
            }
        } else {
            if let raw = result as? String, let name = toolNames[id],
               let data = raw.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                step.title = AgentActionWords.completed(name, toolInputs[id] ?? [:],
                                                        response: raw, targets: step.targets)
            } else {
                step.title = AgentActionWords.finishedWithoutReceipt(step.title)
            }
            step.state = failed ? .failed("The tool returned an error.") : .done
        }
        steps[id] = step
        update.events.append(.stepFinished(step))
        update.events.append(.progress(done: finishedStepIDs.count, total: steps.count))
    }

    /// Claude prints MCP results as tool_result text; Codex wraps the same
    /// result in a result.content array. Recover the trusted action metadata
    /// so the chat can highlight the *actual* target and day without a lookup.
    private static func actionEnvelope(_ value: Any?, depth: Int = 0) -> [String: Any]? {
        guard depth < 8 else { return nil }
        if let text = value as? String, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return actionEnvelope(object, depth: depth + 1)
        }
        if let array = value as? [[String: Any]] {
            for part in array {
                if let nested = actionEnvelope(part, depth: depth + 1) { return nested }
            }
        }
        if let object = value as? [String: Any] {
            if object["step"] is [String: Any] || object["status"] is String { return object }
            if let content = object["content"],
               let nested = actionEnvelope(content, depth: depth + 1) { return nested }
            if let text = object["text"],
               let nested = actionEnvelope(text, depth: depth + 1) { return nested }
            if let result = object["result"] {
                return actionEnvelope(result, depth: depth + 1)
            }
        }
        return nil
    }

    private mutating func completeTurn(_ update: inout AgentCLITransition) {
        // Only AgentActionsMCP can issue a real, undoable change-set ID.
        // The runner emits .finished after reading that change set. The chat
        // treats .finished as terminal, so it must always be the last event.
        update.turnEnded = true
    }

    private static func displayName(_ name: String) -> String {
        let segment = name.replacingOccurrences(of: "mcp__attic__", with: "")
        return segment.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func json(_ value: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
