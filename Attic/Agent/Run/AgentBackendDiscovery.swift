import Foundation

/// Installation status comes from the unsandboxed helper's login-shell PATH.
/// A Settings view never launches either model or reads a credential file.
@MainActor
enum AgentBackendDiscovery {
    static func installed() async -> Set<AgentBackend>? {
        guard let helper = try? AgentHelperClient() else { return nil }
        do {
            try await helper.start()
        } catch {
            helper.stop()
            return nil
        }
        defer { helper.stop() }
        let timeout = Task { @MainActor [weak helper] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            helper?.stop()
        }
        defer { timeout.cancel() }
        helper.probe()
        for await frame in helper.events where frame.type == "availability" {
            var found = Set<AgentBackend>()
            if frame.claudeInstalled == true { found.insert(.claude) }
            if frame.codexInstalled == true { found.insert(.codex) }
            return found
        }
        return nil
    }
}
