import AppKit
import Foundation
import XCTest
@testable import Attic

final class FirstTouchLogTests: XCTestCase {
    func testFeatureIsCompileTimeRestrictedToLocalARMPreviews() {
        #if ATTIC_FIRST_TOUCH_LOG && ATTIC_LOCAL_ONLY && arch(arm64)
        XCTAssertTrue(FirstTouchLogAvailability.enabled)
        #else
        XCTAssertFalse(FirstTouchLogAvailability.enabled)
        #endif
    }

    #if ATTIC_FIRST_TOUCH_LOG && ATTIC_LOCAL_ONLY && arch(arm64)
    func testRecordIsNumericTimingWithoutUserContent() throws {
        var record = FirstTouchLogRecord(id: 42, event: "input", atNS: 10_000_000_000)
        record.originNS = 9_999_000_000
        record.kind = "panel_control"
        record.idleMS = 22_000
        record.firstAfterIdle = true
        record.hiddenMS = 301_000
        record.released = true
        record.napActivity = false
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "input")
        XCTAssertEqual(object["kind"] as? String, "panel_control")
        XCTAssertEqual(object["idleMS"] as? Double, 22_000)
        XCTAssertEqual(object["firstAfterIdle"] as? Bool, true)
        XCTAssertNil(object["title"])
        XCTAssertNil(object["content"])
        XCTAssertNil(object["environment"])
    }

    func testRollingFileKeepsWholeRecordsWithinCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-first-touch-\(UUID().uuidString)")
            .appendingPathComponent("first-touch.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = FirstTouchRollingFile(url: url, maximumBytes: 400)
        for i in 0..<55 {
            let line = try JSONEncoder().encode(FirstTouchLogRecord(id: i, event: "stage", atNS: UInt64(i)))
            try file.append(line + Data([10]))
        }
        try file.close()
        let contents = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(contents.count, 400)
        XCTAssertTrue(contents.last == 10)
        let lines = contents.split(separator: 10)
        XCTAssertFalse(lines.isEmpty)
        let records = try lines.map { try JSONDecoder().decode(FirstTouchLogRecord.self, from: Data($0)) }
        XCTAssertEqual(records.last?.id, 54)
        XCTAssertGreaterThan(records.first?.id ?? 0, 0)
    }

    func testRollingFileNeverExceedsCapWhenNextRecordIsLarge() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-first-touch-large-\(UUID().uuidString)")
            .appendingPathComponent("first-touch.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = FirstTouchRollingFile(url: url, maximumBytes: 400)
        let first = Data(("{\"pad\":\"" + String(repeating: "x", count: 330) + "\"}\n").utf8)
        let second = Data(("{\"pad\":\"" + String(repeating: "y", count: 270) + "\"}\n").utf8)
        try file.append(first)
        try file.append(second)
        try file.close()
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 400)
        XCTAssertTrue(data.last == 10)
        for line in data.split(separator: 10) {
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(line)) as? [String: String])
        }
    }

    @MainActor
    func testMainThreadEnqueueOverheadMeasuredOnHost() {
        let count = 1_000
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<count {
            FirstTouchLogWriter.shared.submit(FirstTouchLogRecord(id: i, event: "stage", atNS: UInt64(i)))
        }
        let duration = DispatchTime.now().uptimeNanoseconds - start
        let microseconds = Double(duration) / Double(count) / 1_000
        print(String(format: "FIRST_TOUCH_MAIN_ENQUEUE_US_AVG %.3f n=%d", microseconds, count))
        XCTAssertGreaterThan(duration, 0)
    }

    /// Opt-in Air run: the actual NSPanel.sendEvent -> NSView.mouseDown path,
    /// with the invisible unit host and no visible UI or global HID injection.
    @MainActor
    func testAirIdleFirstPressAndRepeatUseTheRealPanelEventPath() throws {
        guard ProcessInfo.processInfo.environment["TEST_RUNNER_ATTIC_IDLE_FIRST_TOUCH"] == "1" else {
            throw XCTSkip("Only run for the requested Air idle capture")
        }
        guard TestPresentationPolicy.isInvisible else { throw XCTSkip("Invisible test host required") }
        final class Target: NSView {
            var pressed = 0
            override func mouseDown(with event: NSEvent) { pressed += 1 }
        }
        let panel = AtticPanel(contentRect: CGRect(x: -4_000, y: -4_000, width: 200, height: 140),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let target = Target(frame: CGRect(x: 0, y: 0, width: 200, height: 140))
        panel.contentView = target
        panel.onIdleTraceContext = {
            IdleLatencyTrace.Context(page: .tasks, released: false, snapshot: false,
                                     mode: .slide, activity: false)
        }
        IdleLatencyTrace.startMonitoring()
        func press() throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 80, y: 70),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                panel.sendEvent(event)
            }
        }
        Thread.sleep(forTimeInterval: 20.2)
        try press()
        XCTAssertEqual(target.pressed, 1)
        XCTAssertTrue(try XCTUnwrap(IdleLatencyTrace.lastClassificationForTesting).first)
        Thread.sleep(forTimeInterval: 1.1) // preserve the existing 1-second press sampling gate
        try press()
        XCTAssertEqual(target.pressed, 2)
        XCTAssertFalse(try XCTUnwrap(IdleLatencyTrace.lastClassificationForTesting).first)
        print("FIRST_TOUCH_AIR_OFFSCREEN first_and_repeat=delivered; pixels=not_measured; app_nap=not_measured")
    }
    #endif
}
