import Combine
import Foundation
import Network
import os

/// Loopback-only HTTP server that exposes the MCP endpoint at /mcp so local
/// AI agents (Claude Code, Codex, Synara, …) can manage tasks and notes.
@MainActor
final class AgentServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    static let defaultPort: UInt16 = 7335
    nonisolated private static let maxRequestBytes =
        AgentHTTPRequest.maximumHeaderBytes + AgentHTTPRequest.maximumBodyBytes + 4

    @Published private(set) var state: State = .stopped
    @Published private(set) var listeningPort: UInt16?

    private let port: UInt16
    private let bearerToken: String
    private let handler: MCPRequestHandler
    private let queue = DispatchQueue(label: "com.emanueledipietro.Attic.AgentServer")
    private let logger = Logger(subsystem: "com.emanueledipietro.Attic", category: "AgentServer")
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeRequestTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(port: UInt16, bearerToken: String, handler: MCPRequestHandler) {
        self.port = port
        self.bearerToken = bearerToken
        self.handler = handler
    }

    func start() {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            logger.error("Invalid agent server port \(self.port)")
            state = .failed("Invalid port \(port).")
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpointPort)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("Unable to create agent server listener: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return
        }

        state = .starting
        listener.stateUpdateHandler = { [weak self, weak listener, logger, port] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    let resolvedPort = listener.port?.rawValue ?? port
                    self.listeningPort = resolvedPort
                    self.state = .running
                    logger.info("Agent MCP server listening on http://127.0.0.1:\(resolvedPort)/mcp")
                }
            case let .failed(error):
                logger.error("Agent MCP server failed: \(error.localizedDescription)")
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    listener.cancel()
                    self.listener = nil
                    self.listeningPort = nil
                    self.cancelActiveConnections()
                    self.state = .failed(error.localizedDescription)
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        cancelActiveConnections()
        listener?.cancel()
        listener = nil
        listeningPort = nil
        state = .stopped
    }

    private func cancelActiveConnections() {
        activeRequestTasks.values.forEach { $0.cancel() }
        activeRequestTasks.removeAll()
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        activeConnections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in
                    self?.connectionDidEnd(id)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func connectionDidEnd(_ id: ObjectIdentifier) {
        activeRequestTasks.removeValue(forKey: id)?.cancel()
        activeConnections.removeValue(forKey: id)
    }

    nonisolated private func receive(on connection: NWConnection, buffer: Data, searchedBytes: Int = 0) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            guard buffer.count <= Self.maxRequestBytes else {
                self.send(status: 413, reason: "Content Too Large", body: nil, on: connection)
                return
            }
            switch AgentHTTPRequest.parse(buffer, searchedBytes: searchedBytes) {
            case let .request(request):
                self.route(request, on: connection)
            case .invalid:
                self.send(status: 400, reason: "Bad Request", body: nil, on: connection)
            case let .incomplete(searchedBytes):
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, searchedBytes: searchedBytes)
                }
            }
        }
    }

    nonisolated private func route(_ request: AgentHTTPRequest, on connection: NWConnection) {
        // Native agents never send an Origin header; a browser reaching this
        // endpoint through DNS rebinding would, so refuse any that appears.
        guard request.headers["origin"] == nil else {
            send(status: 403, reason: "Forbidden", body: nil, on: connection)
            return
        }
        guard request.path == "/mcp" else {
            send(status: 404, reason: "Not Found", body: nil, on: connection)
            return
        }
        guard request.method == "POST" else {
            send(status: 405, reason: "Method Not Allowed", body: nil, on: connection, extraHeaders: "Allow: POST\r\n")
            return
        }
        guard AgentRequestSecurity.isAuthorized(
            headers: request.headers,
            bearerToken: bearerToken
        ) else {
            send(
                status: 401,
                reason: "Unauthorized",
                body: nil,
                on: connection,
                extraHeaders: "WWW-Authenticate: Bearer\r\n"
            )
            return
        }
        guard Self.isJSONContentType(request.headers["content-type"]) else {
            send(status: 415, reason: "Unsupported Media Type", body: nil, on: connection)
            return
        }
        Task { @MainActor [weak self] in
            self?.beginHandling(request, on: connection)
        }
    }

    private func beginHandling(_ request: AgentHTTPRequest, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard listener != nil, activeConnections[id] != nil else {
            connection.cancel()
            return
        }

        let requestTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.listener != nil,
                  self.activeConnections[id] != nil else {
                connection.cancel()
                return
            }
            let result = self.handler.handle(
                body: request.body,
                protocolVersion: request.headers["mcp-protocol-version"]
            )
            guard !Task.isCancelled, self.activeConnections[id] != nil else {
                connection.cancel()
                return
            }
            self.activeRequestTasks.removeValue(forKey: id)
            self.send(
                status: result.status,
                reason: result.reason,
                body: result.body,
                on: connection
            )
        }
        activeRequestTasks[id]?.cancel()
        activeRequestTasks[id] = requestTask
    }

    nonisolated private static func isJSONContentType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let mediaType = rawValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/json"
    }

    nonisolated private func send(
        status: Int,
        reason: String,
        body: Data?,
        on connection: NWConnection,
        extraHeaders: String = ""
    ) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Connection: close\r\n"
        head += extraHeaders
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        } else {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"

        var response = Data(head.utf8)
        if let body {
            response.append(body)
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum AgentRequestSecurity {
    static func isAuthorized(headers: [String: String], bearerToken: String) -> Bool {
        guard let host = headers["host"]?.lowercased(), isLoopbackHost(host) else {
            return false
        }
        guard let authorization = headers["authorization"] else { return false }
        return constantTimeEquals(authorization, "Bearer \(bearerToken)")
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let count = max(lhsBytes.count, rhsBytes.count)
        var difference = UInt(lhsBytes.count ^ rhsBytes.count)
        for index in 0..<count {
            let left = index < lhsBytes.count ? lhsBytes[index] : 0
            let right = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= UInt(left ^ right)
        }
        return difference == 0
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "127.0.0.1" { return true }
        let pieces = host.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces[0] == "127.0.0.1",
              !pieces[1].isEmpty,
              UInt16(pieces[1]) != nil else {
            return false
        }
        return true
    }
}
