import Foundation
import Network
import Darwin
import os
import Security

// This background app is deliberately outside the Attic app sandbox. Its only
// interface is one authenticated loopback connection to its launching Attic.
// It can locate and run one of two installed agent CLIs, relay JSON lines, and
// terminate the child. It never handles Attic data or invokes model tools.
private final class HelperService {
    private let logger = Logger(subsystem: "com.taha.Attic.AgentHelper", category: "Lifecycle")
    private let queue = DispatchQueue(label: "com.taha.Attic.AgentHelper")
    private let connection: NWConnection
    private let token: String
    private let identitySocket: String
    private var identityProof: String?
    private var incoming = Data()
    private var authenticated = false
    private var cli: Process?
    private var cliInput: Pipe?
    private var cliOutput: Pipe?
    private var cliError: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var backend = ""
    private var claudeConfigURL: URL?
    private let maximumLineSize = 2_000_000
    private var startingCLI = false
    private var stopping = false

    init?(arguments: [String]) {
        // NSWorkspace drops argv from sandboxed callers. Some Launch Services
        // hosts discard custom environment too; atomically claim a short-lived
        // invitation from the embedding app's sandbox in that case.
        let env = ProcessInfo.processInfo.environment
        let launch: (port: String, token: String, socket: String)?
        if let port = env["ATTIC_HELPER_PORT"], let token = env["ATTIC_HELPER_TOKEN"],
           let socket = env["ATTIC_HELPER_ID_SOCKET"], !socket.isEmpty {
            launch = (port, token, socket)
        } else {
            launch = Self.sandboxInvitation()
        }
        guard let launch,
              let port = UInt16(launch.port), port > 0,
              launch.token.count >= 32,
              !launch.socket.isEmpty,
              let endpoint = NWEndpoint.Port(rawValue: port) else { return nil }
        token = launch.token
        identitySocket = launch.socket
        connection = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .tcp)
    }

    private static func sandboxInvitation() -> (port: String, token: String, socket: String)? {
        let parentApp = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard parentApp.pathExtension == "app", let parentID = Bundle(url: parentApp)?.bundleIdentifier else {
            return nil
        }
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(parentID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent("AtticAgentInvitations", isDirectory: true)
        guard let tickets = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        for name in tickets.sorted() where name.hasSuffix(".ticket") {
            guard UUID(uuidString: String(name.dropLast(".ticket".count))) != nil else { continue }
            let invitation = directory.appendingPathComponent(name)
            let claimed = directory.appendingPathComponent("\(name).claimed-\(getpid())")
            // A successful rename removes the unclaimed name atomically. Two
            // helpers cannot consume the same token, even if they launch together.
            guard rename(invitation.path, claimed.path) == 0 else { continue }
            defer { try? FileManager.default.removeItem(at: claimed) }
            let fd = Darwin.open(claimed.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var stat = Darwin.stat()
            guard fstat(fd, &stat) == 0, stat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  stat.st_size > 0, stat.st_size < 2_048,
                  let bytes = try? handle.readToEnd(),
                  let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let expires = json["expires"] as? TimeInterval,
                  expires >= Date().timeIntervalSince1970,
                  expires <= Date().addingTimeInterval(30).timeIntervalSince1970,
                  let port = json["port"] as? String, let token = json["token"] as? String,
                  let socket = json["identitySocket"] as? String, !socket.isEmpty else {
                continue
            }
            return (port, token, socket)
        }
        return nil
    }

    func start() {
        logger.info("Attic helper started")
        queue.async { [weak self] in
            guard let self else { return }
            guard let proof = Self.obtainIdentityProof(socketPath: self.identitySocket) else {
                self.logger.error("Attic helper identity handshake failed")
                self.stop()
                return
            }
            self.identityProof = proof
            self.startTransport()
        }
    }

    private func startTransport() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Attic helper loopback connected")
                self.queue.async {
                    self.send(["type": "hello", "token": self.token,
                               "proof": self.identityProof ?? "",
                               "pid": ProcessInfo.processInfo.processIdentifier])
                    self.receive()
                }
            case .failed, .cancelled:
                self.logger.error("Attic helper loopback failed or cancelled")
                self.queue.async { self.stop() }
            default: break
            }
        }
        connection.start(queue: queue)
        // The parent must authenticate promptly. No unattended helper survives.
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.authenticated else { return }
            self.logger.error("Attic helper handshake timed out")
            self.stop()
        }
    }

    /// The proof arrives only if the app verified the kernel's real Unix peer
    /// PID and the launched helper's exact code signature. It never enters
    /// process arguments, tickets, environment variables or persistent files.
    private static func obtainIdentityProof(socketPath: String) -> String? {
        let bytes = socketPath.utf8CString.map { UInt8(bitPattern: $0) }
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var payload = Data()
        while payload.count < 128 {
            var buffer = [UInt8](repeating: 0, count: 128)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            payload.append(contentsOf: buffer.prefix(count))
        }
        let proof = String(decoding: payload, as: UTF8.self)
        return proof.count >= 32 && proof.count <= 80 ? proof : nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.incoming.append(data) }
            guard self.incoming.count < self.maximumLineSize else { self.stop(); return }
            while let end = self.incoming.firstIndex(of: 10) {
                let line = Data(self.incoming[..<end])
                self.incoming.removeSubrange(...end)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    self.stop(); return
                }
                self.handle(json)
            }
            if complete || error != nil { self.stop() }
            else { self.receive() }
        }
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        if !authenticated {
            guard type == "ready", message["token"] as? String == token else { stop(); return }
            authenticated = true
            logger.info("Attic helper handshake complete")
            send(["type": "ready"])
            return
        }
        switch type {
        case "discover":
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let env = self.loginEnvironment()
                let claudeInstalled = self.find("claude", environment: env) != nil
                let codexInstalled = self.find("codex", environment: env) != nil
                self.queue.async {
                    guard !self.stopping else { return }
                    self.send(["type": "availability", "claude": claudeInstalled,
                               "codex": codexInstalled])
                }
            }
        case "probe":
            // Login hooks and CLI auth probes must not stall the socket queue.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let env = self.loginEnvironment()
                let claude = self.find("claude", environment: env)
                let codex = self.find("codex", environment: env)
                let claudeLogin = claude.flatMap { self.isSignedIn("claude", executable: $0,
                    environment: self.childEnvironment(env, backend: "claude")) }
                let codexLogin = codex.flatMap { self.isSignedIn("codex", executable: $0,
                    environment: self.childEnvironment(env, backend: "codex")) }
                self.queue.async {
                    guard !self.stopping else { return }
                    var response: [String: Any] = ["type": "availability", "claude": claude != nil,
                        "codex": codex != nil, "claudeSignedIn": claudeLogin == true,
                        "codexSignedIn": codexLogin == true]
                    if claude != nil && claudeLogin == nil || codex != nil && codexLogin == nil {
                        response["message"] = "Checking agent sign-in timed out. Try again."
                    }
                    self.send(response)
                }
            }
        case "start":
            guard cli == nil, !startingCLI, let name = message["backend"] as? String,
                  name == "claude" || name == "codex" else { send(["type": "failed", "message": "Invalid agent request."]); return }
            startCLI(name: name, message: message)
        case "input":
            guard let line = message["line"] as? String, line.utf8.count < maximumLineSize,
                  let cliInput else { return }
            cliInput.fileHandleForWriting.write(Data((line + "\n").utf8))
        case "interrupt": interruptCLI()
        case "stop": stop()
        default: send(["type": "failed", "message": "Invalid helper command."])
        }
    }

    private func startCLI(name: String, message: [String: Any]) {
        startingCLI = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let env = self.loginEnvironment()
            let executable = self.find(name, environment: env)
            // Only ask the installed CLI whether its own sign-in works. Never
            // read its credentials, stdout or stderr for authentication data.
            let signedIn = executable.flatMap { self.isSignedIn(name, executable: $0,
                environment: self.childEnvironment(env, backend: name)) }
            self.queue.async {
                self.startingCLI = false
                guard !self.stopping else { return }
                guard let executable else {
                    self.send(["type": "failed", "message": "Install \(name == "claude" ? "Claude Code" : "Codex") to use this agent."])
                    return
                }
                guard signedIn == true else {
                    let login = name == "claude" ? "claude auth login" : "codex login"
                    let message = signedIn == nil ? "The \(name) sign-in check timed out." : "Sign in with \(login)."
                    self.send(["type": "failed", "message": message])
                    return
                }
                self.launchCLI(name: name, message: message, executable: executable,
                               environment: self.childEnvironment(env, backend: name))
            }
        }
    }

    private func launchCLI(name: String, message: [String: Any], executable: String,
                           environment loginEnv: [String: String]) {
        let prompt = message["instructions"] as? String ?? ""
        let server = message["mcpURL"] as? String ?? ""
        let mcpToken = message["mcpToken"] as? String ?? ""
        guard server.hasPrefix("http://127.0.0.1:"), server.hasSuffix("/mcp"),
              mcpToken.count >= 32 else {
            send(["type": "failed", "message": "Attic could not start its tools."])
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = loginEnv
        let arguments: [String]
        if name == "claude" {
            let mcp: [String: Any] = ["mcpServers": ["attic": ["type": "http", "url": server,
                           "headers": ["Authorization": "Bearer \(mcpToken)"]]]]
            guard let data = try? JSONSerialization.data(withJSONObject: mcp),
                  let config = try? Self.privateMCPConfig(data) else {
                send(["type": "failed", "message": "Attic could not prepare the agent tools."])
                return
            }
            claudeConfigURL = config
            var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                        "--verbose", "--include-partial-messages", "--restricted", "--tools", "",
                        "--strict-mcp-config", "--disable-slash-commands", "--mcp-config", config.path,
                        // Non-interactive Claude Code refuses any tool it has not
                        // been granted, before Attic hears of it. As with Codex,
                        // Attic alone authorizes protected actions, through the
                        // trusted chat approval path in AgentActionsMCP.
                        "--allowedTools", "mcp__attic",
                        "--system-prompt", prompt]
            if let session = message["sessionID"] as? String, !session.isEmpty {
                args += ["--resume", session]
            }
            arguments = args
        } else {
            // Codex obtains its MCP bearer credential from this process-only
            // environment variable; it is never written into config.toml.
            // Override the whole MCP table so a user's unrelated servers do
            // not enter this agent's context. Disable native execution,
            // browser, app and customization tool capabilities in addition to
            // read-only sandboxing and an explicit never-approve thread.
            guard bundledCodexHost(executable: executable) != nil else {
                send(["type": "failed", "message": "Codex's tool host is missing. Update Codex to use Attic tools."])
                return
            }
            environment["ATTIC_RUN_MCP_TOKEN"] = mcpToken
            // npm's launcher keeps its code-mode host inside the platform
            // package. Codex must be given that exact path to run MCP tools.
            configureBundledCodexHost(executable: executable, environment: &environment)
            // Codex's own MCP confirmation would be refused by this
            // noninteractive thread. Attic alone authorizes protected actions
            // through the trusted chat approval path.
            let mcpOnly = "mcp_servers={attic={url=\"\(server)\",bearer_token_env_var=\"ATTIC_RUN_MCP_TOKEN\",default_tools_approval_mode=\"approve\"}}"
            arguments = ["app-server", "--strict-config", "--config", mcpOnly]
                + ["shell_tool", "unified_exec", "browser_use", "computer_use", "apps",
                   "standalone_web_search", "hooks", "skill_search"].flatMap { ["--disable", $0] }
        }
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            cleanupClaudeConfig()
            send(["type": "failed", "message": "Could not start \(name)."])
            return
        }
        self.cli = process
        self.backend = name
        self.cliInput = input
        self.cliOutput = output
        self.cliError = error
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.receiveCLIOutput(data) }
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.receiveCLIError(data) }
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.async { self?.finishedCLI(status: process.terminationStatus) }
        }
        send(["type": "started", "backend": name])
    }

    private func receiveCLIOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        guard stdoutBuffer.count < maximumLineSize else { interruptCLI(); return }
        while let end = stdoutBuffer.firstIndex(of: 10) {
            let line = Data(stdoutBuffer[..<end])
            stdoutBuffer.removeSubrange(...end)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                send(["type": "line", "line": text])
            }
        }
    }

    private func receiveCLIError(_ data: Data) {
        // Stderr is kept in memory only for error classification; it may contain
        // account information, so never forward or log it verbatim.
        if !data.isEmpty { stderrBuffer = (stderrBuffer + data).suffix(2048) }
    }

    private func finishedCLI(status: Int32) {
        guard !stopping else { return }
        cleanupClaudeConfig()
        let name = backend
        cliOutput?.fileHandleForReading.readabilityHandler = nil
        cliError?.fileHandleForReading.readabilityHandler = nil
        cliInput = nil
        cliOutput = nil
        cliError = nil
        cli = nil
        if status != 0 {
            let message = String(decoding: stderrBuffer, as: UTF8.self).lowercased()
            let needsLogin = message.contains("not logged in") || message.contains("authentication required") || message.contains("unauthorized")
            let login = name == "claude" ? "claude auth login" : "codex login"
            send(["type": "failed", "message": needsLogin ? "Sign in with \(login)." : "\(name) exited with an error."])
        }
        send(["type": "exited", "status": Int(status)])
    }

    private func interruptCLI() {
        guard let cli, cli.isRunning else { return }
        Self.signal(cli, SIGINT)
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self, weak cli] in
            guard let cli, cli.isRunning else { return }
            Self.signal(cli, SIGTERM)
            if self?.stopping != true { self?.send(["type": "interrupted"]) }
        }
        queue.asyncAfter(deadline: .now() + 3.5) { [weak cli] in
            guard let cli, cli.isRunning else { return }
            Self.signal(cli, SIGKILL)
        }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        connection.cancel()
        // Never waitUntilExit on the transport queue. Interrupt, terminate,
        // then force kill on a worker with finite escalation windows.
        guard let cli, cli.isRunning else {
            cleanupClaudeConfig()
            exit(0)
        }
        let config = claudeConfigURL
        claudeConfigURL = nil
        Self.signal(cli, SIGINT)
        DispatchQueue.global(qos: .utility).async {
            if !Self.waitForExit(cli, seconds: 0.5) { Self.signal(cli, SIGTERM) }
            if !Self.waitForExit(cli, seconds: 1.5) { Self.signal(cli, SIGKILL) }
            if Self.waitForExit(cli, seconds: 1) { cli.waitUntilExit() }
            else { DispatchQueue.global(qos: .utility).async { cli.waitUntilExit() } }
            Self.removeMCPConfig(config)
            exit(0)
        }
    }

    /// Claude reads the MCP configuration from a private file. The bearer is
    /// never included in process arguments, diagnostic messages or logs.
    private static func privateMCPConfig(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticMCP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("mcp.json")
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            guard fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            try handle.write(contentsOf: data)
            try handle.close()
            return file
        } catch {
            try? handle.close()
            removeMCPConfig(file)
            throw error
        }
    }

    private func cleanupClaudeConfig() {
        let file = claudeConfigURL
        claudeConfigURL = nil
        Self.removeMCPConfig(file)
    }

    private static func removeMCPConfig(_ file: URL?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        connection.send(content: data + Data([10]), completion: .contentProcessed { _ in })
    }

    private func loginEnvironment() -> [String: String] {
        let shell: String
        if let account = getpwuid(getuid()), let pointer = account.pointee.pw_shell {
            shell = String(cString: pointer)
        } else {
            shell = "/bin/zsh"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/env -0"]
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        guard let result = Self.runBounded(process, output: output, seconds: 4, maximumBytes: 262_144),
              result.status == 0 else { return ProcessInfo.processInfo.environment }
        var environment: [String: String] = [:]
        for entry in result.output.split(separator: 0) {
            guard let equals = entry.firstIndex(of: 61), let key = String(data: entry[..<equals], encoding: .utf8),
                  let value = String(data: entry[entry.index(after: equals)...], encoding: .utf8) else { continue }
            environment[key] = value
        }
        return environment
    }

    private func find(_ name: String, environment: [String: String]) -> String? {
        for folder in (environment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(folder)).appendingPathComponent(name).path
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let validated = Self.verifiedExecutable(name: name, at: URL(fileURLWithPath: path)) else {
                continue
            }
            if name != "codex" { return validated.path }
            // Only a complete, signed installation can reach Attic tools.
            // Skip standalone CLI builds without the companion MCP host.
            if bundledCodexHost(executable: validated.path) != nil { return validated.path }
        }
        return nil
    }

    /// Resolve wrappers to the signed vendor binary before even running an
    /// auth-status command. Executable permission or PATH precedence is never
    /// sufficient to select code for the unsandboxed helper.
    private static func verifiedExecutable(name: String, at candidate: URL) -> URL? {
        let resolved = candidate.resolvingSymlinksInPath()
        if name == "claude" {
            return signed(resolved, identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW")
                ? resolved : nil
        }
        let native: URL
        if resolved.pathExtension == "js" {
            let package = resolved.deletingLastPathComponent().deletingLastPathComponent()
            guard resolved.lastPathComponent == "codex.js", package.lastPathComponent == "codex",
                  package.deletingLastPathComponent().lastPathComponent == "@openai" else { return nil }
            #if arch(arm64)
            let platform = "codex-darwin-arm64/vendor/aarch64-apple-darwin"
            #elseif arch(x86_64)
            let platform = "codex-darwin-x64/vendor/x86_64-apple-darwin"
            #else
            return nil
            #endif
            native = package.appendingPathComponent("node_modules/@openai/\(platform)/bin/codex")
        } else {
            native = resolved
        }
        return signed(native, identifier: "codex", team: "2DC432GLL2") ? native : nil
    }

    private static func signed(_ url: URL, identifier: String, team: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else {
            return false
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let properties = information as? [String: Any] else { return false }
        return properties[kSecCodeInfoIdentifier as String] as? String == identifier &&
               properties[kSecCodeInfoTeamIdentifier as String] as? String == team
    }

    private func childEnvironment(_ login: [String: String], backend: String) -> [String: String] {
        let common: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL",
            "LC_CTYPE", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"]
        let specific: Set<String> = backend == "claude"
            ? ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"]
            : ["CODEX_HOME", "OPENAI_API_KEY", "OPENAI_BASE_URL"]
        var clean = login.filter { common.contains($0.key) || specific.contains($0.key) }
        clean["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        clean["HOME"] = login["HOME"] ?? NSHomeDirectory()
        return clean
    }

    private func bundledCodexHost(executable: String) -> URL? {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let sibling = resolved.deletingLastPathComponent().appendingPathComponent("codex-code-mode-host")
        if Self.signedHost(sibling) { return sibling }
        let packageRoot = resolved.deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let platform = "codex-darwin-arm64/vendor/aarch64-apple-darwin"
        #elseif arch(x86_64)
        let platform = "codex-darwin-x64/vendor/x86_64-apple-darwin"
        #else
        return nil
        #endif
        let bundled = packageRoot.appendingPathComponent("node_modules/@openai/\(platform)/bin")
            .appendingPathComponent("codex-code-mode-host")
        return Self.signedHost(bundled) ? bundled : nil
    }

    private static func signedHost(_ url: URL) -> Bool {
        // Host builds have used more than one identifier; its signing team is
        // the invariant shared with the Codex binary, including npm installs.
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let properties = information as? [String: Any] else { return false }
        return properties[kSecCodeInfoTeamIdentifier as String] as? String == "2DC432GLL2"
    }

    private func configureBundledCodexHost(executable: String, environment: inout [String: String]) {
        guard let bundled = bundledCodexHost(executable: executable) else { return }
        // Make the companion discoverable to both PATH and explicit-host
        // implementations without changing the user's shell or CLI install.
        environment["CODEX_CODE_MODE_HOST_PATH"] = bundled.path
        environment["PATH"] = bundled.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "")
    }

    private func isSignedIn(_ name: String, executable: String, environment: [String: String]) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = name == "claude" ? ["auth", "status"] : ["login", "status"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard let result = Self.runBounded(process, output: nil, seconds: 6, maximumBytes: 0) else { return nil }
        return result.status == 0
    }

    /// Reads only bounded diagnostic-free bytes and imposes a deadline on the
    /// entire process, including shell initialization and child termination.
    /// This runs on a worker queue; the authenticated socket stays responsive.
    private static func runBounded(_ process: Process, output: Pipe?, seconds: TimeInterval,
                                   maximumBytes: Int) -> (status: Int32, output: Data)? {
        guard (try? process.run()) != nil else { return nil }
        let end = Date().addingTimeInterval(seconds)
        let fd = output?.fileHandleForReading.fileDescriptor
        if let fd {
            let flags = Darwin.fcntl(fd, F_GETFL)
            if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }
        var bytes = Data()
        var endedOutput = fd == nil
        while Date() < end {
            if let fd, !endedOutput {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 50)
                if ready > 0 {
                    var chunk = [UInt8](repeating: 0, count: 4096)
                    let count = chunk.withUnsafeMutableBytes {
                        Darwin.read(fd, $0.baseAddress, $0.count)
                    }
                    if count == 0 { endedOutput = true }
                    else if count > 0 {
                        guard bytes.count + count <= maximumBytes else { break }
                        bytes.append(contentsOf: chunk.prefix(count))
                    }
                }
            } else {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if !process.isRunning && endedOutput { break }
        }
        if !process.isRunning && endedOutput {
            process.waitUntilExit()
            return (process.terminationStatus, bytes)
        }
        // Even an account login hook may ignore SIGTERM. Reap without letting
        // a stalled child hold the worker indefinitely.
        if process.isRunning { signal(process, SIGTERM) }
        if !waitForExit(process, seconds: 0.35) { signal(process, SIGKILL) }
        if waitForExit(process, seconds: 0.5) { process.waitUntilExit() }
        else { DispatchQueue.global(qos: .utility).async { process.waitUntilExit() } }
        return nil
    }

    private static func signal(_ process: Process, _ value: Int32) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        // A child that established its own process group must be terminated
        // together with descendants; never signal the helper's process group.
        let target = Darwin.getpgid(pid) == pid ? -pid : pid
        _ = Darwin.kill(target, value)
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        return !process.isRunning
    }
}

guard let helper = HelperService(arguments: CommandLine.arguments) else {
    let env = ProcessInfo.processInfo.environment
    let launchPortPresent = env["ATTIC_HELPER_PORT"] != nil
    let launchTokenPresent = env["ATTIC_HELPER_TOKEN"] != nil
    Logger(subsystem: "com.taha.Attic.AgentHelper", category: "Lifecycle")
        .error("Attic helper missing valid launch configuration, port key present: \(launchPortPresent), token key present: \(launchTokenPresent)")
    exit(2)
}
helper.start()
dispatchMain()
