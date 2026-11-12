import Combine
import Foundation
import Network
import os

/// Loopback-only HTTP server that exposes the MCP endpoint at /mcp so local
/// AI agents (Claude Code, Codex, Synara, …) can read and update tasks.
@MainActor
final class AgentServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    static let defaultPort: UInt16 = 7335
    nonisolated private static let maxRequestBytes = 1_048_576
    /// How long an accepted socket may stay open without a complete request
    /// and answer. A client that opened a connection and then sent nothing —
    /// or half a request — otherwise held it for as long as it liked, and
    /// `stop()` left it behind.
    nonisolated static let defaultRequestDeadline: TimeInterval = 30

    @Published private(set) var state: State = .stopped
    @Published private(set) var setupToken = ""

    private let port: UInt16
    private let tokenProvider: (@Sendable () throws -> String)?
    private let configuredBearerToken: String?
    private let handler: MCPRequestHandler
    /// Overridden only by tests, which cannot wait out the real deadline.
    private let requestDeadline: TimeInterval
    private let queue = DispatchQueue(label: "com.taha.Attic.AgentServer")
    private let logger = Logger(subsystem: "com.taha.Attic", category: "AgentServer")
    private var listener: NWListener?
    /// The connections this listener generation accepted. A new generation gets
    /// its own registry, so a socket accepted while the old listener was being
    /// cancelled can never be served or counted by the next one.
    private var connections: AcceptedConnections?
    private var credentialTask: Task<Void, Never>?
    private var pendingCredentialLoad: Task<String, Error>?
    private var generation = UUID()
    /// Existing Settings opt-in remains independent of a temporary chat run.
    private var externalAccessEnabled = false
    private var usingRunCredential = false

    var boundPort: UInt16? { listener?.port?.rawValue }

    /// Accepted sockets still open for the current listener.
    var openConnectionCount: Int { connections?.count ?? 0 }

    /// The installed Claude Code/Codex client uses this run-specific bearer
    /// instead of the external Settings credential. The listener is started
    /// only once the trusted run coordinator explicitly begins a run.
    func beginAgentRun(title: String, watching: Bool, requestID: UUID? = nil) throws -> String {
        let token = try handler.beginAgentRun(title: title, watching: watching, requestID: requestID)
        // A chat-only run must not open Keychain or request a persistent
        // external-agent credential. Its own bearer authenticates every call.
        if !externalAccessEnabled && listener == nil {
            do {
                credentialTask?.cancel()
                credentialTask = nil
                generation = UUID()
                startListener(bearerToken: try AgentAccessTokenStore.generateToken())
                guard listener != nil else {
                    throw AgentActionsError.invalid("Could not start the agent listener.")
                }
                usingRunCredential = true
            } catch {
                handler.finishAgentRun(token: token)
                throw error
            }
        } else { start() }
        return token
    }

    func setRunWatching(_ watching: Bool, token: String) throws {
        try handler.setWatching(watching, runToken: token)
    }

    func setRunMode(_ mode: AgentChatMode, token: String) throws {
        try handler.setMode(mode, runToken: token)
    }

    func pendingRunApprovals(token: String) -> [AgentApproval] {
        handler.runApprovals(token: token)
    }

    func runChangeSet(token: String) -> AgentChangeSet? {
        handler.runChangeSet(token: token)
    }

    func resolveRunApproval(id: UUID, allow: Bool, token: String) async throws {
        try await handler.resolveRunApproval(id: id, allow: allow, token: token)
    }

    func undoRunChangeSet(id: UUID, token: String) async throws -> AgentUndoReport {
        try await handler.undoRunChangeSet(id: id, token: token)
    }

    func undoFinishedAgentChangeSet(id: UUID) async throws -> AgentUndoReport {
        try await handler.undoFinishedAgentChangeSet(id: id)
    }

    @discardableResult
    func finishAgentRun(token: String) -> UUID? {
        let requestID = handler.finishAgentRun(token: token)
        if !handler.hasActiveAgentRuns && !externalAccessEnabled { stop() }
        return requestID
    }

    func drainedRunChangeSet(requestID: UUID) async -> AgentChangeSet? {
        await handler.drainedRunChangeSet(requestID: requestID)
    }

    func setExternalAccessEnabled(_ enabled: Bool) {
        externalAccessEnabled = enabled
        if enabled {
            if listener != nil && usingRunCredential { loadExternalCredentialForRunningListener() }
            else { start() }
        } else {
            // Cancel any external-credential upgrade without ending a chat run.
            if usingRunCredential {
                credentialTask?.cancel()
                credentialTask = nil
            }
            if !handler.hasActiveAgentRuns { stop() }
        }
    }

    /// Enabling Settings access during a run upgrades the legacy bearer in
    /// place. Restarting the listener here would invalidate the run's socket.
    private func loadExternalCredentialForRunningListener() {
        guard credentialTask == nil else { return }
        guard let tokenProvider else {
            if let configuredBearerToken, AgentAccessTokenStore.isValid(configuredBearerToken) {
                setupToken = configuredBearerToken
                usingRunCredential = false
            }
            return
        }
        let requestedGeneration = generation
        let load = pendingCredentialLoad ?? Task.detached(operation: tokenProvider)
        pendingCredentialLoad = load
        credentialTask = Task { [weak self] in
            let result = await load.result
            guard let self, !Task.isCancelled, generation == requestedGeneration else { return }
            credentialTask = nil
            pendingCredentialLoad = nil
            guard externalAccessEnabled else { return }
            switch result {
            case let .success(token) where AgentAccessTokenStore.isValid(token):
                setupToken = token
                usingRunCredential = false
            default:
                // The private run still works. Failed Keychain access must
                // never make its temporary bearer an external credential.
                externalAccessEnabled = false
                logger.error("External agent credential could not be loaded during a run")
            }
        }
    }

    init(port: UInt16, bearerToken: String, handler: MCPRequestHandler,
         requestDeadline: TimeInterval = defaultRequestDeadline) {
        self.port = port
        self.setupToken = bearerToken
        self.configuredBearerToken = bearerToken
        self.tokenProvider = nil
        self.handler = handler
        self.requestDeadline = requestDeadline
    }

    init(port: UInt16, handler: MCPRequestHandler,
         tokenProvider: @escaping @Sendable () throws -> String = { try AgentAccessTokenStore().loadOrCreate() },
         requestDeadline: TimeInterval = defaultRequestDeadline) {
        self.port = port
        self.handler = handler
        self.tokenProvider = tokenProvider
        self.configuredBearerToken = nil
        self.requestDeadline = requestDeadline
    }

    func start() {
        guard listener == nil, credentialTask == nil else { return }
        generation = UUID()
        guard let tokenProvider else {
            startListener(bearerToken: setupToken)
            return
        }
        state = .starting
        let requestedGeneration = generation
        // A cancelled opt-in may still be waiting on a system prompt. Reuse
        // that one load on a rapid retry instead of creating more prompts.
        let load = pendingCredentialLoad ?? Task.detached(operation: tokenProvider)
        pendingCredentialLoad = load
        credentialTask = Task { [weak self] in
            // Keychain may ask the user to unlock or grant access. Never block
            // the app's main thread or open a listener while that is pending.
            let result = await load.result
            guard let self, !Task.isCancelled, generation == requestedGeneration else { return }
            credentialTask = nil
            pendingCredentialLoad = nil
            switch result {
            case let .success(token):
                startListener(bearerToken: token)
            case .failure:
                setupToken = ""
                state = .failed("The private agent credential could not be loaded. Check Keychain access, then retry.")
            }
        }
    }

    private func startListener(bearerToken: String) {
        guard AgentAccessTokenStore.isValid(bearerToken) else {
            setupToken = ""
            state = .failed("A private agent credential could not be loaded. Check Keychain access, then retry.")
            return
        }
        setupToken = bearerToken
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
                logger.info("Agent MCP server listening on http://127.0.0.1:\(port)/mcp")
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    self.state = .running
                }
            case let .failed(error):
                logger.error("Agent MCP server failed: \(error.localizedDescription)")
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    self.handleListenerFailure(error.localizedDescription)
                }
            default:
                break
            }
        }
        let listenerGeneration = generation
        let connections = AcceptedConnections()
        let queue = queue
        let requestDeadline = requestDeadline
        listener.newConnectionHandler = { [weak self] connection in
            // A socket accepted after `stop()` drained this registry is closed
            // straight away rather than served or tracked. `track` also
            // installs the close observation, so the registry and the handler
            // that empties it cannot disagree.
            guard let self, connections.track(connection, on: queue,
                                             deadline: requestDeadline) else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            self.receive(on: connection, buffer: Data(), generation: listenerGeneration)
        }

        listener.start(queue: queue)
        self.listener = listener
        self.connections = connections
    }

    /// Closes the listener and every socket it accepted. Cancellation itself is
    /// handed to Network.framework and never waited on, so this returns without
    /// blocking the main actor; the per-connection deadline is the backstop for
    /// a peer that never finishes its request.
    func stop() {
        credentialTask?.cancel()
        credentialTask = nil
        handler.finishAllAgentRuns()
        releaseListenerGeneration()
        usingRunCredential = false
        setupToken = configuredBearerToken ?? ""
        state = .stopped
    }

    /// A failed listener accepts nothing more, so the sockets it already
    /// accepted are closed now rather than held for up to the request
    /// deadline. Shares `stop()`'s teardown so the two cannot drift.
    private func handleListenerFailure(_ message: String) {
        releaseListenerGeneration()
        state = .failed(message)
    }

    /// Test seam: performs exactly what the listener's `.failed` state does,
    /// without asking the system to fail a real listener.
    func failListenerForTesting(_ message: String) {
        guard listener != nil else { return }
        handleListenerFailure(message)
    }

    /// Releases this listener generation: the listener itself, every socket it
    /// accepted, and their deadlines. The new generation makes a request still
    /// in flight refuse rather than answer for a server that is gone.
    private func releaseListenerGeneration() {
        generation = UUID()
        listener?.cancel()
        listener = nil
        connections?.shutDown()
        connections = nil
    }

    nonisolated private func receive(on connection: NWConnection, buffer: Data, searchedBytes: Int = 0,
                                    generation: UUID) {
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
                self.route(request, on: connection, generation: generation)
            case .invalid:
                self.send(status: 400, reason: "Bad Request", body: nil, on: connection)
            case let .incomplete(searchedBytes):
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, searchedBytes: searchedBytes, generation: generation)
                }
            }
        }
    }

    nonisolated private func route(_ request: AgentHTTPRequest, on connection: NWConnection, generation: UUID) {
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
        Task { @MainActor [weak self] in
            guard let self, self.listener != nil, self.generation == generation else {
                connection.cancel()
                return
            }
            let runToken = self.handler.runActions?.authorizedRunToken(headers: request.headers)
            // Starting a chat run makes MCP reachable for that run. It does
            // not silently opt external clients back into Settings access.
            guard runToken != nil || (self.externalAccessEnabled || !self.handler.hasActiveAgentRuns) &&
                AgentRequestSecurity.isAuthorized(
                    headers: request.headers, bearerToken: self.setupToken
            ) else {
                self.send(status: 401, reason: "Unauthorized", body: nil, on: connection,
                          extraHeaders: "WWW-Authenticate: Bearer\r\n")
                return
            }
            let result = await self.handler.handleAsync(
                body: request.body,
                protocolVersion: request.headers["mcp-protocol-version"],
                runToken: runToken
            )
            guard self.listener != nil, self.generation == generation else {
                connection.cancel()
                return
            }
            self.send(status: result.status, reason: result.reason, body: result.body, on: connection)
        }
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

/// The accepted sockets of one listener generation. The listener queue inserts
/// and removes entries while the main actor drains them on `stop()`, so every
/// access is locked. Each entry owns the work item that closes a connection
/// which never completed its request.
///
/// Internal rather than private so a test can drive it directly and prove
/// that a closed connection is released by everything this registry put in
/// place for it.
final class AcceptedConnections: @unchecked Sendable {
    /// A connection's registry identity, so a connection's own handler can
    /// remove it without capturing — and therefore retaining — the
    /// connection that owns that handler.
    struct Key: Hashable, Sendable {
        private let identifier: ObjectIdentifier

        init(_ connection: NWConnection) {
            identifier = ObjectIdentifier(connection)
        }
    }

    private let lock = NSLock()
    private var deadlines: [Key: DispatchWorkItem] = [:]
    private var connections: [Key: NWConnection] = [:]
    private var isShutDown = false

    var count: Int { lock.withLock { connections.count } }

    /// Registers `connection`, observes its close, and schedules its deadline.
    /// Returns false once the registry has been shut down, meaning the caller
    /// must close the connection instead of serving it.
    func track(_ connection: NWConnection, on queue: DispatchQueue, deadline: TimeInterval) -> Bool {
        let key = Key(connection)
        // A cancelled work item stays on the queue until its scheduled time,
        // so holding the connection here would keep a closed socket alive for
        // the rest of the deadline. The registry entry is the owner; the
        // deadline only acts while that entry exists.
        let timeout = DispatchWorkItem { [weak connection] in connection?.forceCancel() }
        let accepted: Bool = lock.withLock {
            guard !isShutDown else { return false }
            connections[key] = connection
            deadlines[key] = timeout
            return true
        }
        guard accepted else { return false }
        // The connection owns this handler, so the handler must not own the
        // connection back. Capturing it strongly made a real cycle for as long
        // as the socket was open (connection → handler → connection); whether
        // that cycle outlived the close depended on Network releasing the
        // handler at a final state, which nothing promises. The key is a value
        // instead, and the connection is alive whenever its own handler runs,
        // so removal still happens exactly once. The registry is captured
        // weakly for the same reason: it holds the connection, so a strong
        // capture would close the loop through this entry instead.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.forget(key)
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + deadline, execute: timeout)
        return true
    }

    /// Drops a closed connection and the deadline that was watching it.
    func forget(_ key: Key) {
        let timeout: DispatchWorkItem? = lock.withLock {
            connections.removeValue(forKey: key)
            return deadlines.removeValue(forKey: key)
        }
        timeout?.cancel()
    }

    /// Closes every accepted connection and refuses any further one. Cancelling
    /// a connection fires its state handler, which would re-enter the lock, so
    /// the entries are taken out first and cancelled outside it.
    func shutDown() {
        let (open, timeouts): ([NWConnection], [DispatchWorkItem]) = lock.withLock {
            isShutDown = true
            let open = Array(connections.values)
            let timeouts = Array(deadlines.values)
            connections.removeAll()
            deadlines.removeAll()
            return (open, timeouts)
        }
        timeouts.forEach { $0.cancel() }
        open.forEach { $0.forceCancel() }
    }
}

enum AgentRequestSecurity {
    static func isAuthorized(headers: [String: String], bearerToken: String) -> Bool {
        guard let host = headers["host"]?.lowercased() else { return false }
        if host != "127.0.0.1" {
            let parts = host.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "127.0.0.1",
                  !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = UInt16(parts[1]), port > 0 else { return false }
        }
        guard let authorization = headers["authorization"] else { return false }
        return constantTimeEquals(authorization, "Bearer \(bearerToken)")
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhsBytes, rhsBytes) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
