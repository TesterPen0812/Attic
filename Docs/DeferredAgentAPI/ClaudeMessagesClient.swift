import Foundation

enum AgentRunnerError: Error, LocalizedError {
    case noKey
    case protocolViolation
    case server(String)
    case http(Int)
    case interrupted(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "Add a Claude API key in Settings."
        case .protocolViolation: "The model returned an incomplete response."
        case let .server(message): message
        case let .http(status):
            switch status {
            case 401: "The Claude API key was rejected."
            case 402: "Claude API billing needs attention."
            case 403: "Claude API access was denied."
            case 429: "Claude is busy. Try again shortly."
            default: "Claude request failed (HTTP \(status))."
            }
        case let .interrupted(message): message
        }
    }
}

struct AgentWireMessage: Codable, Sendable {
    let role: String
    let content: AgentJSON
}

struct AgentClaudeTurn: Sendable {
    let content: [AgentJSON]
    let stopReason: String
}

/// Raw Messages API transport. URLSession is injected for recorded SSE tests;
/// credentials are supplied per request and never retained on the client.
actor ClaudeMessagesClient {
    static let model = "claude-opus-5-5"
    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = .shared,
         endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.session = session
        self.endpoint = endpoint
    }

    func stream(messages: [AgentWireMessage], tools: [AgentToolDefinition],
                systemPrompt: String, key: String,
                onText: @MainActor @Sendable (String) -> Void) async throws -> AgentClaudeTurn {
        let cache: AgentJSON = .object(["type": .string("ephemeral")])
        var toolValues = tools.map(\.apiValue)
        if !toolValues.isEmpty, case var .object(last) = toolValues[toolValues.count - 1] {
            last["cache_control"] = cache
            toolValues[toolValues.count - 1] = .object(last)
        }
        var body: [String: AgentJSON] = [
            "model": .string(Self.model),
            "max_tokens": .number(64000),
            "stream": .bool(true),
            "fallbacks": .string("default"),
            "output_config": .object(["effort": .string("medium")]),
            "system": .array([.object(["type": .string("text"), "text": .string(systemPrompt),
                                        "cache_control": cache])]),
            "messages": .array(messages.map { .object(["role": .string($0.role), "content": $0.content]) })
        ]
        if !toolValues.isEmpty { body["tools"] = .array(toolValues) }
        let encoded = try JSONEncoder().encode(AgentJSON.object(body))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = encoded
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentRunnerError.protocolViolation }
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                if attempt < 2 {
                    let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
                    let delay = min(30, max(Double(1 << attempt), retryAfter ?? 0))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw AgentRunnerError.http(http.statusCode)
            }
            guard (200...299).contains(http.statusCode) else { throw AgentRunnerError.http(http.statusCode) }
            var accumulator = ClaudeSSEAccumulator()
            var payload: [String] = []
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.isEmpty {
                    if !payload.isEmpty {
                        let data = Data(payload.joined(separator: "\n").utf8)
                        let delta = try accumulator.accept(data)
                        if let delta { await onText(delta) }
                        payload.removeAll(keepingCapacity: true)
                    }
                    if accumulator.stopped { break }
                } else if line.hasPrefix("data:") {
                    payload.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }
            // Some SSE producers omit the final blank line.
            if !payload.isEmpty {
                let delta = try accumulator.accept(Data(payload.joined(separator: "\n").utf8))
                if let delta { await onText(delta) }
            }
            guard accumulator.stopped, let reason = accumulator.stopReason else {
                throw AgentRunnerError.protocolViolation
            }
            return AgentClaudeTurn(content: accumulator.content, stopReason: reason)
        }
        throw AgentRunnerError.protocolViolation
    }
}

/// Accumulate all content blocks (including signed thinking and fallbacks)
/// verbatim in order. Replayed assistant messages must retain these blocks.
private struct ClaudeSSEAccumulator {
    private var blocks: [Int: AgentJSON] = [:]
    private var inputs: [Int: String] = [:]
    private(set) var stopReason: String?
    private(set) var stopped = false

    var content: [AgentJSON] { blocks.keys.sorted().compactMap { blocks[$0] } }

    mutating func accept(_ data: Data) throws -> String? {
        guard let event = try JSONDecoder().decode(AgentJSON.self, from: data).object else {
            throw AgentRunnerError.protocolViolation
        }
        switch event["type"]?.string {
        case "content_block_start":
            guard let index = integer(event["index"]), let block = event["content_block"] else {
                throw AgentRunnerError.protocolViolation
            }
            blocks[index] = block
        case "content_block_delta":
            guard let index = integer(event["index"]),
                  var block = blocks[index]?.object, let delta = event["delta"]?.object else {
                throw AgentRunnerError.protocolViolation
            }
            let type = delta["type"]?.string
            if type == "text_delta", let text = delta["text"]?.string {
                block["text"] = .string((block["text"]?.string ?? "") + text)
                blocks[index] = .object(block)
                return text
            }
            if type == "input_json_delta", let fragment = delta["partial_json"]?.string {
                inputs[index, default: ""] += fragment
            } else if type == "thinking_delta", let text = delta["thinking"]?.string {
                block["thinking"] = .string((block["thinking"]?.string ?? "") + text)
            } else if type == "signature_delta", let signature = delta["signature"]?.string {
                block["signature"] = .string(signature)
            }
            blocks[index] = .object(block)
        case "content_block_stop":
            guard let index = integer(event["index"]) else { throw AgentRunnerError.protocolViolation }
            if let raw = inputs[index], var block = blocks[index]?.object {
                // Invalid input is still returned to the model as an is_error
                // tool result; never pass a guessed partial object to a tool.
                block["input"] = (try? JSONDecoder().decode(AgentJSON.self, from: Data(raw.utf8)))
                    ?? .object(["_invalid_json": .string(raw)])
                blocks[index] = .object(block)
            }
        case "message_delta":
            stopReason = event["delta"]?.object?["stop_reason"]?.string ?? stopReason
        case "message_stop":
            stopped = true
        case "error":
            throw AgentRunnerError.server("Claude stopped the stream unexpectedly.")
        default: break // message_start, ping and future non-content events
        }
        return nil
    }

    private func integer(_ value: AgentJSON?) -> Int? {
        if case let .number(number)? = value, number.isFinite, number >= 0,
           number <= Double(Int.max), number.rounded() == number { return Int(number) }
        return nil
    }
}
