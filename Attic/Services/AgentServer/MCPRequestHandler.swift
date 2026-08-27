import CoreFoundation
import Foundation

struct MCPHTTPResult: Sendable {
    let status: Int
    let reason: String
    let body: Data?

    static let accepted = MCPHTTPResult(status: 202, reason: "Accepted", body: nil)
}

/// Implements the server side of the MCP Streamable HTTP transport: a single
/// JSON-RPC message per POST, answered with a plain JSON response. The server
/// is stateless, so no session ids or SSE streams are needed.
@MainActor
final class MCPRequestHandler {
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    nonisolated static let maximumBodyBytes = 1_048_576

    private let tools: AgentTaskTools
    private let serverVersion: String

    init(tools: AgentTaskTools, serverVersion: String = MCPRequestHandler.appVersion) {
        self.tools = tools
        self.serverVersion = serverVersion
    }

    func handle(body: Data, protocolVersion: String? = nil) -> MCPHTTPResult {
        guard body.count <= Self.maximumBodyBytes else {
            return MCPHTTPResult(status: 413, reason: "Content Too Large", body: nil)
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            return errorResponse(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let message = json as? [String: Any] else {
            return errorResponse(id: NSNull(), code: -32600, message: "Batch requests are not supported")
        }
        guard message["jsonrpc"] as? String == "2.0" else {
            return errorResponse(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request")
        }

        let method = message["method"] as? String
        if method != "initialize" {
            let resolvedVersion = protocolVersion ?? "2025-03-26"
            guard Self.supportedProtocolVersions.contains(resolvedVersion) else {
                return badRequest("Unsupported MCP protocol version")
            }
        }

        guard let method else {
            // Clients may send JSON-RPC responses over the same transport.
            if message["result"] != nil || message["error"] != nil {
                return .accepted
            }
            return errorResponse(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request")
        }
        guard method.utf8.count <= 128, !method.contains("\0"),
              Set(message.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]) else {
            return errorResponse(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request")
        }
        guard message.keys.contains("id") else {
            // Notifications (initialized, cancelled, …) expect no body.
            return .accepted
        }
        let id = message["id"] ?? NSNull()
        guard Self.isValidRequestID(id) else {
            return errorResponse(id: NSNull(), code: -32600, message: "Invalid request id")
        }
        let params: [String: Any]
        if let rawParams = message["params"] {
            guard let objectParams = rawParams as? [String: Any] else {
                return errorResponse(id: id, code: -32602, message: "Params must be an object")
            }
            params = objectParams
        } else {
            params = [:]
        }

        switch method {
        case "initialize":
            guard Self.hasOnlyKeys(
                params,
                allowed: ["protocolVersion", "capabilities", "clientInfo", "_meta"]
            ) else {
                return errorResponse(id: id, code: -32602, message: "Unknown initialize params")
            }
            return resultResponse(id: id, result: initializeResult(params: params))
        case "ping":
            guard Self.hasOnlyKeys(params, allowed: ["_meta"]) else {
                return errorResponse(id: id, code: -32602, message: "Unknown ping params")
            }
            return resultResponse(id: id, result: [:])
        case "tools/list":
            guard Self.hasOnlyKeys(params, allowed: ["cursor", "_meta"]) else {
                return errorResponse(id: id, code: -32602, message: "Unknown tools/list params")
            }
            return resultResponse(id: id, result: ["tools": tools.definitions])
        case "tools/call":
            return callTool(id: id, params: params)
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found")
        }
    }

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { requestedVersion in
            Self.supportedProtocolVersions.contains(requestedVersion)
                ? requestedVersion
                : nil
        } ?? Self.supportedProtocolVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": [
                "name": "attic",
                "title": "Attic Tasks and Notes",
                "version": serverVersion
            ],
            "instructions": "When the user asks to manage Attic tasks or notes, use these MCP tools directly. Do not open or control the Attic GUI with Computer Use unless the user explicitly asks for UI interaction. Discover current ids first with list_tasks or list_notes. Read a full note with get_note. Notes are plain text: update_note replaces only supplied fields, append_note adds content exactly with no implicit separator, and every note mutation requires the latest revision so conflicts never overwrite newer edits. Keep task titles short; use backlog for ideas, inProgress for active work, and done to complete."
        ]
    }

    private func callTool(id: Any, params: [String: Any]) -> MCPHTTPResult {
        guard Self.hasOnlyKeys(params, allowed: ["name", "arguments", "_meta"]) else {
            return errorResponse(id: id, code: -32602, message: "Unknown tools/call params")
        }
        guard let name = params["name"] as? String,
              !name.isEmpty,
              name.utf8.count <= 128,
              !name.contains("\0") else {
            return errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        let arguments: [String: Any]
        if let rawArguments = params["arguments"] {
            guard let objectArguments = rawArguments as? [String: Any] else {
                return errorResponse(id: id, code: -32602, message: "Tool arguments must be an object")
            }
            arguments = objectArguments
        } else {
            arguments = [:]
        }
        do {
            let payload = try tools.call(name: name, arguments: arguments)
            return toolResponse(id: id, payload: payload, isError: false)
        } catch let error as AgentToolError {
            if case .unknownTool = error {
                return errorResponse(id: id, code: -32602, message: error.message)
            }
            return toolErrorResponse(id: id, error: error)
        } catch {
            return toolErrorResponse(id: id, error: .storeFailure)
        }
    }

    private func badRequest(_ message: String) -> MCPHTTPResult {
        let error = errorResponse(id: NSNull(), code: -32600, message: message)
        return MCPHTTPResult(status: 400, reason: "Bad Request", body: error.body)
    }

    private static func isValidRequestID(_ id: Any) -> Bool {
        if let string = id as? String {
            return string.utf8.count <= 128 && !string.contains("\0")
        }
        if id is NSNull { return true }
        guard let number = id as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private static func hasOnlyKeys(
        _ object: [String: Any],
        allowed: Set<String>
    ) -> Bool {
        Set(object.keys).isSubset(of: allowed)
    }

    private func toolResponse(
        id: Any,
        payload: [String: Any],
        isError: Bool
    ) -> MCPHTTPResult {
        guard let text = Self.jsonText(payload) else {
            return toolErrorResponse(id: id, error: .storeFailure)
        }
        return resultResponse(id: id, result: [
            "content": [["type": "text", "text": text]],
            "structuredContent": payload,
            "isError": isError
        ])
    }

    private func toolErrorResponse(id: Any, error: AgentToolError) -> MCPHTTPResult {
        resultResponse(id: id, result: [
            "content": [["type": "text", "text": error.message]],
            "structuredContent": error.structuredContent,
            "isError": true
        ])
    }

    private static func jsonText(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func resultResponse(id: Any, result: [String: Any]) -> MCPHTTPResult {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func errorResponse(id: Any, code: Int, message: String) -> MCPHTTPResult {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ payload: [String: Any]) -> MCPHTTPResult {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            let fallback = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
            return MCPHTTPResult(status: 200, reason: "OK", body: fallback)
        }
        return MCPHTTPResult(status: 200, reason: "OK", body: data)
    }

    nonisolated private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
