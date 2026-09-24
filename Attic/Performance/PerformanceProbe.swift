import Darwin
import Foundation

/// Test-only control plane. Marker writes are event-driven and outside samples.
enum PerformanceProbe {
    /// XCTest's runner is sandboxed separately and cannot write the app's
    /// container. For the UI metrics lane, create the disposable root from
    /// inside the app, using only a validated identifier supplied by XCTest.
    static func uiTestRoot(environment: [String: String]) throws -> URL? {
        guard environment["ATTIC_UI_TESTING"] == "1",
              environment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] == "1",
              environment["ATTIC_PERF_UI_TEST"] == "1",
              let identifier = environment["ATTIC_PERF_UI_IDENTIFIER"],
              let uuid = UUID(uuidString: identifier),
              let bundleID = Bundle.main.bundleIdentifier,
              bundleID == "com.taha.Attic.perf.ui",
              let account = getpwuid(getuid()) else { return nil }
        let base = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/AtticPerformanceStores",
                                isDirectory: true)
        let root = base.appendingPathComponent("attic-perf-ui-\(uuid.uuidString)", isDirectory: true)
        if environment["ATTIC_PERF_UI_CLEANUP"] == "1" {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            return nil
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard root.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
            base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        ) else { throw CocoaError(.fileReadNoPermission) }
        try Data(identifier.utf8).write(to: root.appendingPathComponent(".attic-perf-owner"), options: .atomic)
        return root
    }

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

    static func writePhase(_ phase: String, root: URL, details: [String: Int] = [:]) {
        var record: [String: Any] = [
            "phase": phase,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "timestamp": Date().timeIntervalSince1970
        ]
        for (key, value) in details { record[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: root.appendingPathComponent("phase.json"), options: .atomic)
        let markers = root.appendingPathComponent("phase-markers", isDirectory: true)
        try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try? data.write(to: markers.appendingPathComponent("\(phase).json"), options: .atomic)
    }

    static func writeTiming(_ name: String, milliseconds: Double, root: URL) {
        let record: [String: Any] = [
            "name": name, "milliseconds": milliseconds,
            "timestamp": Date().timeIntervalSince1970
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(0x0A)
        let url = root.appendingPathComponent("timings.ndjson")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
