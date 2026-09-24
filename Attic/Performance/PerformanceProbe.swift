import Darwin
import Foundation

/// Test-only control plane. Marker writes are event-driven and outside samples.
enum PerformanceProbe {
    static func validatedRoot(environment: [String: String]) -> URL? {
        guard environment["ATTIC_UI_TESTING"] == "1",
              environment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] == "1",
              let path = environment["ATTIC_PERF_STORE_ROOT"],
              let token = environment["ATTIC_PERF_OWNER_TOKEN"], !token.isEmpty else { return nil }
        guard let account = getpwuid(getuid()),
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let bundlePerformanceStores = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/AtticPerformanceStores",
                                isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(bundlePerformanceStores.path + "/"),
              root.lastPathComponent.hasPrefix("attic-perf-"),
              let data = try? Data(contentsOf: root.appendingPathComponent(".attic-perf-owner")),
              String(data: data, encoding: .utf8) == token else { return nil }
        return root
    }

    static func writePhase(_ phase: String, root: URL) {
        let record: [String: Any] = [
            "phase": phase,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "timestamp": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: root.appendingPathComponent("phase.json"), options: .atomic)
    }
}
