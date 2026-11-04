import Foundation
import Darwin
import XCTest

/// Instruments-style XCTest metrics are recorded, not compared to a laptop's
/// numbers on a different CI runner. The probe's phase markers identify the
/// same real panel and 2,000-object canvas used by the local baseline script.
@MainActor
final class PerformanceUITests: XCTestCase {
    private var identifier: String!
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        identifier = UUID().uuidString
        let seeder = makeApp(seedOnly: true)
        seeder.launch()
        seeder.terminate()
        XCTAssertTrue(seeder.wait(for: .notRunning, timeout: 15))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if identifier != nil {
            // Cleanup runs inside the app sandbox and only accepts this UUID.
            let cleanup = makeApp(seedOnly: true)
            cleanup.launchEnvironment["ATTIC_PERF_UI_CLEANUP"] = "1"
            cleanup.launch()
            cleanup.terminate()
        }
    }

    private func makeApp(seedOnly: Bool = false, probe: Bool = false) -> XCUIApplication {
        let result = XCUIApplication()
        result.launchEnvironment["ATTIC_UI_TESTING"] = "1"
        result.launchEnvironment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] = "1"
        // The old Canvas page: Draw has its place unless the hidden switch is off.
        result.launchArguments += ["-AtticDraw.enabled", "NO"]
        result.launchEnvironment["ATTIC_PERF_UI_TEST"] = "1"
        result.launchEnvironment["ATTIC_PERF_UI_IDENTIFIER"] = identifier
        result.launchEnvironment["ATTIC_PERF_SEED_ONLY"] = seedOnly ? "1" : "0"
        result.launchEnvironment["ATTIC_PERF_PROBE"] = probe ? "1" : "0"
        return result
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
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

    private func diagnoseTasksReadiness(_ application: XCUIApplication) {
        // Read only this test's UUID-owned diagnostics, never a normal store.
        if let identifier, let account = getpwuid(getuid()) {
            let containers = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
                .appendingPathComponent("Library/Containers")
            for bundle in ["com.taha.Attic.perf.ui", "com.taha.Attic.ci.ui", "com.taha.Attic.preview.bugs3.perf"] {
                let root = containers.appendingPathComponent(bundle)
                    .appendingPathComponent("Data/Library/Application Support/AtticPerformanceStores/attic-perf-\(identifier)")
                guard let owner = try? String(contentsOf: root.appendingPathComponent(".attic-perf-owner"), encoding: .utf8),
                      owner == identifier else { continue }
                for file in ["phase.json", "phase-markers/hidden_idle.json", "phase-markers/tasks_open.json", "phase-markers/canvas_open.json"] {
                    if let data = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) {
                        print("PERF_PHASE_DIAG bundle=\(bundle) marker=\(file) \(data)")
                    }
                }
            }
        }
        let pins = application.buttons.matching(identifier: "panel-pin-button")
        let pin = pins.firstMatch
        let tasks = application.buttons.matching(identifier: "panel-section-tasks").firstMatch
        let selection = tasks.exists ? String(tasks.isSelected) : "absent"
        print("PERF_TASKS_DIAG appState=\(application.state.rawValue) pins=\(pins.count) exists=\(pin.exists) tasksSelected=\(selection)")
        if pin.exists { print("PERF_TASKS_DIAG pinFrame=\(pin.frame) hittable=\(pin.isHittable)") }
        print("PERF_TASKS_DIAG AX_TREE \(application.debugDescription)")
    }

    func testSeededLaunchMetricAndNavigation() throws {
        let visible = makeApp()
        app = visible
        let launchOptions = XCTMeasureOptions()
        launchOptions.iterationCount = 3
        launchOptions.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()],
                options: launchOptions) {
            // XCTest's launch signpost intermittently returns "0 metrics".
            // Measure the real cold launch through visible readiness with a
            // clock metric instead; automation latency is included and recorded.
            // Termination is outside the measurement.
            if visible.state != .notRunning {
                visible.terminate()
                XCTAssertTrue(visible.wait(for: .notRunning, timeout: 15))
            }
            startMeasuring()
            visible.launch()
            XCTAssertTrue(visible.descendants(matching: .any)["panel-section-picker"]
                .waitForExistence(timeout: 20), "seeded launch never became ready")
            stopMeasuring()
        }
        XCTAssertTrue(visible.descendants(matching: .any)["panel-section-picker"]
            .waitForExistence(timeout: 20))
        // Real controls and real seeded content. XCTest's automation latency
        // makes this a functional/metric check; the 50 ms budget is read from
        // the in-process PageSwitch signpost, not from XCUI click duration.
        visible.activate()
        let picker = visible.descendants(matching: .any)["panel-section-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        let tasks = visible.buttons["panel-section-tasks"]
        XCTAssertTrue(tasks.waitForExistence(timeout: 5))
        // The page button opens under the pointer; the other pages take
        // clicks once it has.
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let canvas = visible.buttons["panel-section-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { canvas.isHittable }, "the page button did not open under the pointer")
        canvas.click()
        XCTAssertTrue(visible.descendants(matching: .any)["canvas-surface"]
            .waitForExistence(timeout: 10))
        visible.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(waitUntil { tasks.isSelected }, "Tasks page was not selected")
    }

    func testHiddenIdleMemoryAndCPU() {
        let probe = makeApp(probe: true)
        app = probe
        probe.launch()
        let picker = probe.descendants(matching: .any)["panel-section-picker"]
        XCTAssertFalse(picker.isHittable)
        Thread.sleep(forTimeInterval: 30)
        XCTAssertFalse(picker.isHittable)
        measureState("hidden idle", application: probe)
        XCTAssertFalse(picker.isHittable)
    }

    func testTasksOpenMemoryAndCPU() {
        let probe = makeApp(probe: true)
        app = probe
        probe.launch()
        let tasks = probe.buttons["panel-section-tasks"]
        // D4's resting island is dots, and the Pages group's centre can
        // be empty. Read the actual Tasks page rather than that group.
        let pin = probe.buttons["panel-pin-button"]
        let opened = waitUntil(timeout: 90) { pin.isHittable }
        if !opened { diagnoseTasksReadiness(probe) }
        XCTAssertTrue(opened, "Tasks panel did not open")
        XCTAssertTrue(tasks.isSelected, "Tasks was not selected before the sample")
        measureState("Tasks open", application: probe)
        XCTAssertTrue(pin.isHittable, "Tasks panel hid during the sample")
        XCTAssertTrue(tasks.isSelected, "Tasks sample overlapped the Canvas switch")
    }

    func testLargeCanvasMemoryAndCPU() {
        let probe = makeApp(probe: true)
        app = probe
        probe.launch()
        let canvas = probe.descendants(matching: .any)["canvas-surface"]
        XCTAssertTrue(waitUntil(timeout: 120) { canvas.isHittable }, "Large canvas did not open")
        XCTAssertTrue(probe.buttons["panel-section-canvas"].isSelected)
        measureState("large canvas open", application: probe)
        XCTAssertTrue(canvas.isHittable, "Canvas panel hid during the sample")
        XCTAssertTrue(probe.buttons["panel-section-canvas"].isSelected)
    }

    func testAfterHideMemoryAndCPU() {
        let probe = makeApp(probe: true)
        app = probe
        probe.launch()
        let canvas = probe.descendants(matching: .any)["canvas-surface"]
        XCTAssertTrue(waitUntil(timeout: 120) { canvas.isHittable }, "Large canvas did not open")
        XCTAssertTrue(waitUntil(timeout: 180) { !canvas.isHittable }, "Canvas panel did not hide")
        Thread.sleep(forTimeInterval: 30)
        XCTAssertFalse(canvas.isHittable, "Canvas panel reappeared during the settle")
        measureState("after hiding canvas", application: probe)
        XCTAssertFalse(canvas.isHittable)
    }
}
