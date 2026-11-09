import AppKit
import Darwin
import Foundation
import Network
import os
import Security

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
    let claudeStatus: String?
    let codexStatus: String?
    let claudeIssue: String?
    let codexIssue: String?

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
        claudeStatus = frame["claudeStatus"] as? String
        codexStatus = frame["codexStatus"] as? String
        claudeIssue = frame["claudeIssue"] as? String
        codexIssue = frame["codexIssue"] as? String
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
    private var candidates: [ObjectIdentifier: NWConnection] = [:]
    private var application: NSRunningApplication?
    private var portWaiter: CheckedContinuation<UInt16, Error>?
    private var helloWaiter: CheckedContinuation<Void, Error>?
    private var incoming = Data()
    private var authenticated = false
    private var authenticatedHelperPID: pid_t?
    private var verifiedHelperPID: pid_t?
    private let helperProof = UUID().uuidString + UUID().uuidString
    private var identityPath: URL?
    private var identityListener: DispatchSourceRead?
    private var pendingIdentityPeers: [(fd: Int32, pid: pid_t)] = []
    private var isStopped = false
    private var invitationURL: URL?

    #if DEBUG
    // Hosted tests can connect a forged peer before Launch Services opens the
    // genuine helper, exercising the authentication boundary deterministically.
    var onInvitationReadyForTests: ((UInt16, String, String) -> Void)?
    #endif

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
        do {
            try prepareIdentitySocket()
            try makeLaunchInvitation(port: port)
        }
        catch { stop(); throw error }
        #if DEBUG
        onInvitationReadyForTests?(port, token, identityPath?.path ?? "")
        #endif
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        // AppKit explicitly ignores arguments from sandboxed callers. Pass
        // environment for hosts that support it and use the expiring sandbox
        // invitation for Launch Services implementations that omit it too.
        configuration.environment = ["ATTIC_HELPER_PORT": String(port),
                                     "ATTIC_HELPER_TOKEN": token,
                                     "ATTIC_HELPER_ID_SOCKET": identityPath?.path ?? ""]
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
                    if let verifiedPID = self.verifiedHelperPID,
                       self.application?.processIdentifier != verifiedPID {
                        self.logger.error("Launch Services returned a different helper process")
                        self.fail(AgentHelperConnectionError.authentication)
                        return
                    }
                    self.authorizeIdentityPeers()
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

    func discoverInstalledBackends() { send(["type": "discover"]) }

    #if DEBUG
    func configureTestCLIs(claude: [String], codex: [String]) {
        send(["type": "testCLIs", "claude": claude, "codex": codex])
    }
    #endif

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
        stopIdentitySocket()
        for candidate in candidates.values { candidate.cancel() }
        candidates.removeAll()
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
        // Unauthenticated sockets are disposable candidates, never the sole
        // helper connection. A stray local caller cannot occupy the run slot.
        guard !authenticated, !isStopped, candidates.count < 8 else { newConnection.cancel(); return }
        let key = ObjectIdentifier(newConnection)
        candidates[key] = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in
                    self?.connectionFailed(newConnection, error: AgentHelperConnectionError.disconnected)
                }
            }
        }
        newConnection.start(queue: queue)
        receive(on: newConnection, pending: Data())
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.dropCandidate(newConnection)
        }
    }

    private func receive(on connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = pending
            if let bytes { buffer.append(bytes) }
            guard buffer.count < 2_000_000 else {
                Task { @MainActor [weak self] in
                    self?.connectionFailed(connection, error: AgentHelperConnectionError.invalidFrame)
                }
                return
            }
            var frames = [[String: Any]]()
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    Task { @MainActor [weak self] in
                        self?.connectionFailed(connection, error: AgentHelperConnectionError.invalidFrame)
                    }
                    return
                }
                frames.append(frame)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for frame in frames { self.received(frame, on: connection) }
                if complete || error != nil {
                    self.connectionFailed(connection, error: AgentHelperConnectionError.disconnected)
                }
            }
            if !complete && error == nil { self.receive(on: connection, pending: buffer) }
        }
    }

    private func received(_ frame: [String: Any], on peer: NWConnection) {
        guard !isStopped else { return }
        if !authenticated {
            guard candidates[ObjectIdentifier(peer)] != nil else { return }
            // A stolen invitation does not establish identity. The proof is
            // delivered separately over a Unix socket to the kernel-attested,
            // signed process returned by Launch Services.
            guard frame["type"] as? String == "hello", frame["token"] as? String == token,
                  frame["proof"] as? String == helperProof,
                  let pid = frame["pid"] as? pid_t, pid == verifiedHelperPID else {
                dropCandidate(peer); return
            }
            authenticated = true
            connection = peer
            candidates[ObjectIdentifier(peer)] = nil
            for candidate in candidates.values { candidate.cancel() }
            candidates.removeAll()
            authenticatedHelperPID = pid
            logger.info("Agent helper handshake succeeded")
            discardLaunchInvitation()
            send(["type": "ready", "token": token])
            helloWaiter?.resume()
            helloWaiter = nil
            listener?.cancel() // Only the one authenticated connection may remain.
            listener = nil
            stopIdentitySocket()
            return
        }
        guard connection === peer else { return }
        continuation.yield(AgentHelperFrame(frame))
    }

    private func dropCandidate(_ peer: NWConnection) {
        guard candidates.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        peer.cancel()
    }

    private func connectionFailed(_ peer: NWConnection, error: Error) {
        if candidates[ObjectIdentifier(peer)] != nil { dropCandidate(peer) }
        else if connection === peer { fail(error) }
        else { peer.cancel() }
    }

    /// The TCP connection has no peer audit token. Bind its hello to a second,
    /// kernel-attested local Unix socket before accepting any agent bearer.
    private func prepareIdentitySocket() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ah-\(UUID().uuidString.prefix(12))")
        let bytes = path.path.utf8CString.map { UInt8(bitPattern: $0) }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw AgentHelperConnectionError.invitation }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentHelperConnectionError.invitation }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.chmod(path.path, 0o600) == 0,
              Darwin.listen(fd, 8) == 0 else {
            _ = Darwin.close(fd)
            _ = Darwin.unlink(path.path)
            throw AgentHelperConnectionError.invitation
        }
        identityPath = path
        let flags = Darwin.fcntl(fd, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let peer = Darwin.accept(fd, nil, nil)
            guard peer >= 0 else { return }
            var pid: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            guard Darwin.getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
                  size == socklen_t(MemoryLayout<pid_t>.size) else {
                _ = Darwin.close(peer)
                return
            }
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { _ = Darwin.close(peer); return }
                self.pendingIdentityPeers.append((peer, pid))
                self.authorizeIdentityPeers()
            }
        }
        source.setCancelHandler { _ = Darwin.close(fd) }
        identityListener = source
        source.resume()
    }

    private func authorizeIdentityPeers() {
        guard !isStopped else { return }
        let peers = pendingIdentityPeers
        pendingIdentityPeers.removeAll()
        for peer in peers {
            defer { _ = Darwin.close(peer.fd) }
            // Launch Services can leave openApplication suspended until the
            // helper finishes this handshake. Verify the kernel-attested PID
            // against the exact bundled executable and signature immediately.
            // Once Launch Services returns, also check its reported PID.
            guard (application == nil || peer.pid == application?.processIdentifier),
                  helperExecutableMatches(pid: peer.pid), helperSignatureMatches(pid: peer.pid),
                  verifiedHelperPID == nil else { continue }
            let bytes = Array(helperProof.utf8)
            let written = bytes.withUnsafeBytes { Darwin.write(peer.fd, $0.baseAddress, $0.count) }
            if written == bytes.count { verifiedHelperPID = peer.pid }
        }
    }

    private func helperExecutableMatches(pid: pid_t) -> Bool {
        guard let expected = Bundle(url: helperURL)?.executableURL else { return false }
        // macOS libproc defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN
        // (4096); the C macro is not exported through Swift's Darwin module.
        var path = [CChar](repeating: 0, count: 4_096)
        let length = path.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return false }
        let launched = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().standardizedFileURL
        return launched == expected.resolvingSymlinksInPath().standardizedFileURL
    }

    private func helperSignatureMatches(pid: pid_t) -> Bool {
        var launched: SecCode?
        let pidAttribute = [kSecGuestAttributePid as String: Int(pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, pidAttribute, SecCSFlags(), &launched) == errSecSuccess,
              let launched, SecCodeCheckValidity(launched, SecCSFlags(), nil) == errSecSuccess else {
            return false
        }
        var launchedStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(launched, SecCSFlags(), &launchedStatic) == errSecSuccess,
              let launchedStatic else { return false }
        var expected: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helperURL as CFURL, SecCSFlags(), &expected) == errSecSuccess,
              let expected, SecStaticCodeCheckValidity(expected, SecCSFlags(), nil) == errSecSuccess else {
            return false
        }
        var actualInfo: CFDictionary?
        var expectedInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(launchedStatic, flags, &actualInfo) == errSecSuccess,
              SecCodeCopySigningInformation(expected, flags, &expectedInfo) == errSecSuccess,
              let actual = actualInfo as? [String: Any], let bundled = expectedInfo as? [String: Any],
              let actualHash = actual[kSecCodeInfoUnique as String] as? Data,
              let bundledHash = bundled[kSecCodeInfoUnique as String] as? Data else { return false }
        // A code-directory hash is available for ad-hoc signatures as well as
        // Developer ID signatures. Match the exact bundled helper, not a team.
        return actualHash == bundledHash
    }

    private func stopIdentitySocket() {
        identityListener?.cancel()
        identityListener = nil
        for peer in pendingIdentityPeers { _ = Darwin.close(peer.fd) }
        pendingIdentityPeers.removeAll()
        if let path = identityPath { _ = Darwin.unlink(path.path) }
        identityPath = nil
    }

    private func fail(_ error: Error) {
        discardLaunchInvitation()
        portWaiter?.resume(throwing: error)
        portWaiter = nil
        helloWaiter?.resume(throwing: error)
        helloWaiter = nil
        // Failed launches also need to release the listener, identity socket
        // and any untrusted peers. Otherwise a timed-out handshake leaks them.
        if !isStopped {
            isStopped = true
            stopIdentitySocket()
            for candidate in candidates.values { candidate.cancel() }
            candidates.removeAll()
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
                                      "identitySocket": identityPath?.path ?? "",
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
