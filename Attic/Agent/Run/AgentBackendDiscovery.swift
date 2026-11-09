import Foundation

/// Launch readiness comes from the same verified CLI checks used by Chat.
/// A Settings view never launches either model or reads a credential file.
@MainActor
enum AgentBackendDiscovery {
    static func statuses() async -> [AgentBackend: String]? {
        guard let helper = try? AgentHelperClient() else { return nil }
        do {
            try await helper.start()
        } catch {
            helper.stop()
            return nil
        }
        defer { helper.stop() }
        let timeout = Task { @MainActor [weak helper] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            helper?.stop()
        }
        defer { timeout.cancel() }
        helper.probe()
        for await frame in helper.events where frame.type == "availability" {
            return [.claude: frame.claudeStatus ?? "timedOut",
                    .codex: frame.codexStatus ?? "timedOut"]
        }
        return nil
    }
}
