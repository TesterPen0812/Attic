import AppKit
import Darwin
import Foundation
import Network
import os

struct AgentHelperFrame: Sendable {
    let type: String
    let line: String?
    let message: String?
    let backend: String?
    let status: Int?
    let claudeInstalled: Bool?
    let codexInstalled: Bool?
    let claudeSignedIn: Bool?
    let codexSignedIn: Bool?

    init(_ frame: [String: Any]) {
        type = frame["type"] as? String ?? ""
        line = frame["line"] as? String
        message = frame["message"] as? String
        backend = frame["backend"] as? String
        status = frame["status"] as? Int
        claudeInstalled = frame["claude"] as? Bool
        codexInstalled = frame["codex"] as? Bool
        claudeSignedIn = frame["claudeSignedIn"] as? Bool
        codexSignedIn = frame["codexSignedIn"] as? Bool
    }
}

/// A sandboxed owner app opens the separately signed helper through Launch
/// Services. There is no Process launch from inside the sandbox: Launch
/// Services starts the background helper as an independent application.
///
/// A new random token authenticates the helper on an ephemeral IPv4 loopback
/// listener for each launch. Only authenticated frames reach the run engine.
@MainActor
final class AgentHelperClient {
    // Launch Services can coalesce concurrent opens of the same nested app,
    // even with createsNewApplicationInstance set. Serialize only the brief
    // invitation-and-handshake phase; authenticated helpers run concurrently.
    private static var launchBusy = false
    private static var launchWaiters: [CheckedContinuation<Void, Never>] = []

    private static func enterLaunchQueue() async {
        if !launchBusy {
            launchBusy = true
            return
        }
        await withCheckedContinuation { launchWaiters.append($0) }
    }

    private static func leaveLaunchQueue() {
        if launchWaiters.isEmpty {
            launchBusy = false
        } else {
            launchWaiters.removeFirst().resume()
        }
    }

    private let logger = Logger(subsystem: "com.taha.Attic", category: "AgentHelperLaunch")
    private let queue = DispatchQueue(label: "com.taha.Attic.AgentHelperClient")
    private let token: String
    private let helperURL: URL
    private var listener: NWListener?
    private var connection: NWConnection?
    private var application: NSRunningApplication?
    private var portWaiter: CheckedContinuation<UInt16, Error>?
    private var helloWaiter: CheckedContinuation<Void, Error>?
    private var incoming = Data()
    private var authenticated = false
    private var authenticatedHelperPID: pid_t?
    private var isStopped = false
    private var invitationURL: URL?

    var launchAppIsTerminated: Bool? { application?.isTerminated }

    let events: AsyncStream<AgentHelperFrame>
    private let continuation: AsyncStream<AgentHelperFrame>.Continuation

    init(helperURL: URL? = nil, token: String? = nil) throws {
        self.token = try token ?? AgentAccessTokenStore.generateToken()
        self.helperURL = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/AtticAgentHelper.app")
        (events, continuation) = AsyncStream.makeStream(of: AgentHelperFrame.self)
    }

    func start() async throws {
        guard listener == nil, !isStopped else { throw AgentHelperConnectionError.disconnected }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] newConnection in
            Task { @MainActor [weak self] in self?.accept(newConnection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        self.fail(AgentHelperConnectionError.disconnected); return
                    }
                    self.logger.info("Agent helper listener ready")
                    self.portWaiter?.resume(returning: port)
                    self.portWaiter = nil
                case .failed:
                    self.fail(AgentHelperConnectionError.disconnected)
                default: break
                }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            portWaiter = continuation
            listener.start(queue: queue)
        }
        await Self.enterLaunchQueue()
        var launchQueueHandedOff = false
        defer { if !launchQueueHandedOff { Self.leaveLaunchQueue() } }
        guard !isStopped else { throw AgentHelperConnectionError.disconnected }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            stop()
            throw AgentHelperConnectionError.missingHelper
        }
        do { try makeLaunchInvitation(port: port) }
        catch { stop(); throw error }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        // AppKit explicitly ignores arguments from sandboxed callers. Pass
        // environment for hosts that support it and use the expiring sandbox
        // invitation for Launch Services implementations that omit it too.
        configuration.environment = ["ATTIC_HELPER_PORT": String(port),
                                     "ATTIC_HELPER_TOKEN": token]
        // Install the handshake waiter before Launch Services can connect.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            helloWaiter = continuation
            Task { @MainActor [weak self] in
                // Launch Services can finish substantially later than the
                // authenticated handshake. Only then may the next caller
                // open another instance of this bundled helper.
                defer { Self.leaveLaunchQueue() }
                guard let self else { return }
                do {
                    self.logger.info("Opening bundled agent helper")
                    self.application = try await NSWorkspace.shared.openApplication(at: self.helperURL,
                                                                                   configuration: configuration)
                    self.logger.info("Launch Services returned helper process")
                } catch {
                    self.logger.error("Launch Services could not open helper: \(error.localizedDescription, privacy: .public)")
                    self.fail(error)
                }
            }
            launchQueueHandedOff = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self, self.helloWaiter != nil else { return }
                self.logger.error("Agent helper handshake timed out; terminated: \(String(describing: self.application?.isTerminated), privacy: .public)")
                self.fail(AgentHelperConnectionError.timeout)
            }
        }
    }

    func probe() { send(["type": "probe"]) }

    func startBackend(_ backend: String, instructions: String, mcpURL: String,
                      mcpToken: String, sessionID: String?) {
        var frame: [String: Any] = ["type": "start", "backend": backend,
                                    "instructions": instructions, "mcpURL": mcpURL,
                                    "mcpToken": mcpToken]
        if let sessionID { frame["sessionID"] = sessionID }
        send(frame)
    }

    func writeLine(_ line: String) { send(["type": "input", "line": line]) }

    func interrupt() { send(["type": "interrupt"]) }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        discardLaunchInvitation()
        send(["type": "stop"])
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        // Launch Services can return before a helper chooses its invitation.
        // Only terminate the process which authenticated on *this* socket;
        // concurrent Settings discovery must not kill an active chat helper.
        if let application, let authenticatedHelperPID,
           application.processIdentifier == authenticatedHelperPID {
            application.terminate()
        }
        application = nil
        fail(AgentHelperConnectionError.disconnected)
        continuation.finish()
    }

    private func send(_ frame: [String: Any]) {
        guard authenticated, let connection,
              let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        connection.send(content: data + Data([10]), completion: .contentProcessed { _ in })
    }

    private func accept(_ newConnection: NWConnection) {
        guard connection == nil, !isStopped else { newConnection.cancel(); return }
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in self?.fail(AgentHelperConnectionError.disconnected) }
            }
        }
        newConnection.start(queue: queue)
        receive(on: newConnection, pending: Data())
    }

    private func receive(on connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = pending
            if let bytes { buffer.append(bytes) }
            guard buffer.count < 2_000_000 else {
                Task { @MainActor [weak self] in self?.fail(AgentHelperConnectionError.invalidFrame) }
                return
            }
            var frames = [[String: Any]]()
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    Task { @MainActor [weak self] in self?.fail(AgentHelperConnectionError.invalidFrame) }
                    return
                }
                frames.append(frame)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for frame in frames { self.received(frame) }
                if complete || error != nil { self.fail(AgentHelperConnectionError.disconnected) }
            }
            if !complete && error == nil { self.receive(on: connection, pending: buffer) }
        }
    }

    private func received(_ frame: [String: Any]) {
        guard !isStopped else { return }
        if !authenticated {
            guard frame["type"] as? String == "hello", frame["token"] as? String == token else {
                fail(AgentHelperConnectionError.authentication); return
            }
            authenticated = true
            authenticatedHelperPID = frame["pid"] as? pid_t
            logger.info("Agent helper handshake succeeded")
            discardLaunchInvitation()
            send(["type": "ready", "token": token])
            helloWaiter?.resume()
            helloWaiter = nil
            listener?.cancel() // Only the one authenticated connection may remain.
            listener = nil
            return
        }
        continuation.yield(AgentHelperFrame(frame))
    }

    private func fail(_ error: Error) {
        discardLaunchInvitation()
        portWaiter?.resume(throwing: error)
        portWaiter = nil
        helloWaiter?.resume(throwing: error)
        helloWaiter = nil
        // An authenticated helper can crash without sending an exit frame.
        // Closing the stream releases the runner and Chat's Working state.
        if authenticated && !isStopped {
            isStopped = true
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
            continuation.finish()
        }
    }

    private func makeLaunchInvitation(port: UInt16) throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AtticAgentInvitations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Each launch gets an independent invitation. Helpers atomically claim
        // one, so simultaneous backend discovery and chat cannot race over a
        // fixed token file. A claimed ticket is removed by the helper itself.
        let file = directory.appendingPathComponent("\(UUID().uuidString).ticket")
        let payload: [String: Any] = ["port": String(port), "token": token,
                                      "expires": Date().addingTimeInterval(20).timeIntervalSince1970]
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentHelperConnectionError.invitation }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fchmod(fd, 0o600) == 0 else { throw AgentHelperConnectionError.invitation }
        try handle.write(contentsOf: bytes)
        invitationURL = file
    }

    private func discardLaunchInvitation() {
        guard let file = invitationURL else { return }
        invitationURL = nil
        try? FileManager.default.removeItem(at: file)
    }
}

enum AgentHelperConnectionError: Error, LocalizedError {
    case missingHelper, disconnected, authentication, invalidFrame, timeout, invitation

    var errorDescription: String? {
        switch self {
        case .missingHelper: "The Attic agent helper is missing."
        case .disconnected: "The agent helper disconnected."
        case .authentication: "The agent helper could not be authenticated."
        case .invalidFrame: "The agent helper sent invalid data."
        case .timeout: "The agent helper did not start."
        case .invitation: "The agent helper could not prepare its connection."
        }
    }
}
