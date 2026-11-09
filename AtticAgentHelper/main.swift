import Foundation
import Network
import Darwin
import os

// This background app is deliberately outside the Attic app sandbox. Its only
// interface is one authenticated loopback connection to its launching Attic.
// It can locate and run one of two installed agent CLIs, relay JSON lines, and
// terminate the child. It never handles Attic data or invokes model tools.
private final class HelperService {
    private let logger = Logger(subsystem: "com.taha.Attic.AgentHelper", category: "Lifecycle")
    private let queue = DispatchQueue(label: "com.taha.Attic.AgentHelper")
    private let connection: NWConnection
    private let token: String
    private var incoming = Data()
    private var authenticated = false
    private var cli: Process?
    private var cliInput: Pipe?
    private var cliOutput: Pipe?
    private var cliError: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var backend = ""
    private let maximumLineSize = 2_000_000

    init?(arguments: [String]) {
        // NSWorkspace drops argv from sandboxed callers. Some Launch Services
        // hosts discard custom environment too; atomically claim a short-lived
        // invitation from the embedding app's sandbox in that case.
        let env = ProcessInfo.processInfo.environment
        let launch: (port: String, token: String)?
        if let port = env["ATTIC_HELPER_PORT"], let token = env["ATTIC_HELPER_TOKEN"] {
            launch = (port, token)
        } else {
            launch = Self.sandboxInvitation()
        }
        guard let launch,
              let port = UInt16(launch.port), port > 0,
              launch.token.count >= 32,
              let endpoint = NWEndpoint.Port(rawValue: port) else { return nil }
        token = launch.token
        connection = NWConnection(host: .ipv4(.loopback), port: endpoint, using: .tcp)
    }

    private static func sandboxInvitation() -> (port: String, token: String)? {
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
                  let port = json["port"] as? String, let token = json["token"] as? String else {
                continue
            }
            return (port, token)
        }
        return nil
    }

    func start() {
        logger.info("Attic helper started")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Attic helper loopback connected")
                self.queue.async {
                    self.send(["type": "hello", "token": self.token,
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
        case "probe":
            let env = loginEnvironment()
            let claude = find("claude", environment: env)
            let codex = find("codex", environment: env)
            send(["type": "availability", "claude": claude != nil, "codex": codex != nil,
                  "claudeSignedIn": claude.map { isSignedIn("claude", executable: $0, environment: env) } ?? false,
                  "codexSignedIn": codex.map { isSignedIn("codex", executable: $0, environment: env) } ?? false])
        case "start":
            guard cli == nil, let name = message["backend"] as? String,
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
        let env = loginEnvironment()
        guard let executable = find(name, environment: env) else {
            send(["type": "failed", "message": "Install \(name == "claude" ? "Claude Code" : "Codex") to use this agent."])
            return
        }
        // The owner signs in using the CLI itself. We never read auth files or
        // collect credentials; only the exit status of its own status command.
        guard isSignedIn(name, executable: executable, environment: env) else {
            let login = name == "claude" ? "claude auth login" : "codex login"
            send(["type": "failed", "message": "Sign in with \(login)."])
            return
        }
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
        var environment = env
        let arguments: [String]
        if name == "claude" {
            let mcp: [String: Any] = ["mcpServers": ["attic": ["type": "http", "url": server,
                           "headers": ["Authorization": "Bearer \(mcpToken)"]]]]
            guard let data = try? JSONSerialization.data(withJSONObject: mcp),
                  let config = String(data: data, encoding: .utf8) else { return }
            var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                        "--verbose", "--include-partial-messages", "--restricted", "--tools", "",
                        "--strict-mcp-config", "--disable-slash-commands", "--mcp-config", config,
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
        cli.interrupt()
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self, weak cli] in
            guard let cli, cli.isRunning else { return }
            cli.terminate()
            self?.send(["type": "interrupted"])
        }
    }

    private func stop() {
        interruptCLI()
        connection.cancel()
        // The child is reaped before exiting. Do not leave an agent alive when
        // the owner app quits or the authenticated socket closes.
        if let cli, cli.isRunning { cli.terminate(); cli.waitUntilExit() }
        exit(0)
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
        guard (try? process.run()) != nil else { return ProcessInfo.processInfo.environment }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return ProcessInfo.processInfo.environment }
        var environment: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let equals = entry.firstIndex(of: 61), let key = String(data: entry[..<equals], encoding: .utf8),
                  let value = String(data: entry[entry.index(after: equals)...], encoding: .utf8) else { continue }
            environment[key] = value
        }
        return environment
    }

    private func find(_ name: String, environment: [String: String]) -> String? {
        var fallback: String?
        for folder in (environment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(folder)).appendingPathComponent(name).path
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if name != "codex" { return path }
            // Some standalone Codex binaries lack the companion host needed
            // to invoke MCP tools. Prefer a complete installation on PATH.
            fallback = fallback ?? path
            if bundledCodexHost(executable: path) != nil { return path }
        }
        return fallback
    }

    private func bundledCodexHost(executable: String) -> URL? {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        let sibling = resolved.deletingLastPathComponent().appendingPathComponent("codex-code-mode-host")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
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
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    private func configureBundledCodexHost(executable: String, environment: inout [String: String]) {
        guard let bundled = bundledCodexHost(executable: executable) else { return }
        // Make the companion discoverable to both PATH and explicit-host
        // implementations without changing the user's shell or CLI install.
        environment["CODEX_CODE_MODE_HOST_PATH"] = bundled.path
        environment["PATH"] = bundled.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "")
    }

    private func isSignedIn(_ name: String, executable: String, environment: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = name == "claude" ? ["auth", "status"] : ["login", "status"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
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
