import Darwin
import Foundation
import XCTest

/// Instruments-style XCTest metrics are recorded, not compared to a laptop's
/// numbers on a different CI runner. The probe's phase markers identify the
/// same real panel and 2,000-object canvas used by the local baseline script.
@MainActor
final class PerformanceUITests: XCTestCase {
    private var root: URL!
    private var token: String!
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Launch once with an in-memory store so macOS creates the sandbox
        // before this test writes its disposable root inside that container.
        let initializer = XCUIApplication()
        initializer.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        initializer.launchEnvironment["ATTIC_PERF_SEED_ONLY"] = "1"
        initializer.launch()
        initializer.terminate()
        XCTAssertTrue(initializer.wait(for: .notRunning, timeout: 15))
        let account = try XCTUnwrap(getpwuid(getuid()))
        let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
        root = home.appendingPathComponent(
            "Library/Containers/com.taha.Attic/Data/Library/Application Support/AtticPerformanceStores",
            isDirectory: true
        )
            .appendingPathComponent("attic-perf-ui-\(UUID().uuidString)", isDirectory: true)
        token = UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(token.utf8).write(to: root.appendingPathComponent(".attic-perf-owner"))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func makeApp(seedOnly: Bool = false, probe: Bool = false) -> XCUIApplication {
        let result = XCUIApplication()
        result.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        result.launchEnvironment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] = "1"
        result.launchEnvironment["ATTIC_PERF_STORE_ROOT"] = root.path
        result.launchEnvironment["ATTIC_PERF_OWNER_TOKEN"] = token
        result.launchEnvironment["ATTIC_PERF_SEED_ONLY"] = seedOnly ? "1" : "0"
        result.launchEnvironment["ATTIC_PERF_PROBE"] = probe ? "1" : "0"
        return result
    }

    private func waitForPhase(_ expected: String, timeout: TimeInterval = 180) -> Int32 {
        let marker = root.appendingPathComponent("phase.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: marker),
               let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               record["phase"] as? String == expected,
               let pid = record["pid"] as? Int {
                return Int32(pid)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Performance phase \(expected) was not reached")
        return 0
    }

    private func measureState(_ name: String, application: XCUIApplication) {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: application),
                          XCTCPUMetric(application: application)], options: options) {
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(application.state == .runningForeground || application.state == .runningBackground,
                      "App exited during \(name)")
    }

    func testSeededLaunchAndLifecycleMetrics() throws {
        let seeder = makeApp(seedOnly: true)
        seeder.launch()
        XCTAssertGreaterThan(waitForPhase("seed_complete", timeout: 900), 0)
        seeder.terminate()
        XCTAssertTrue(seeder.wait(for: .notRunning, timeout: 15))
        try FileManager.default.removeItem(at: root.appendingPathComponent("phase.json"))

        let visible = makeApp()
        app = visible
        let launchOptions = XCTMeasureOptions()
        launchOptions.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)],
                options: launchOptions) {
            if visible.state != .notRunning { visible.terminate() }
            visible.launch()
        }
        XCTAssertTrue(visible.descendants(matching: .any)["panel-section-picker"]
            .waitForExistence(timeout: 20))
        visible.terminate()

        let probe = makeApp(probe: true)
        app = probe
        probe.launch()
        XCTAssertGreaterThan(waitForPhase("hidden_idle"), 0)
        measureState("hidden idle", application: probe)

        XCTAssertGreaterThan(waitForPhase("tasks_open"), 0)
        XCTAssertTrue(probe.descendants(matching: .any)["panel-section-picker"]
            .waitForExistence(timeout: 5))
        measureState("Tasks open", application: probe)

        XCTAssertGreaterThan(waitForPhase("canvas_open"), 0)
        XCTAssertTrue(probe.descendants(matching: .any)["canvas-surface"]
            .waitForExistence(timeout: 5))
        measureState("large canvas open", application: probe)

        XCTAssertGreaterThan(waitForPhase("after_hide"), 0)
        measureState("after hiding canvas", application: probe)
        probe.terminate()

        // Real controls and real seeded content. XCTest's automation latency
        // makes this a functional/metric check; the 50 ms budget is read from
        // the in-process PageSwitch signpost, not from XCUI click duration.
        let navigation = makeApp()
        app = navigation
        navigation.launch()
        navigation.activate()
        let picker = navigation.descendants(matching: .any)["panel-section-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        let canvas = navigation.buttons["panel-section-canvas"]
        canvas.hover()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.click()
        XCTAssertTrue(navigation.descendants(matching: .any)["canvas-surface"]
            .waitForExistence(timeout: 10))
        let tasks = navigation.buttons["panel-section-tasks"]
        tasks.hover()
        tasks.click()
        XCTAssertTrue(navigation.descendants(matching: .any)["quick-entry-title"]
            .waitForExistence(timeout: 5))
    }
}
