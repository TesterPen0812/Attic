import Foundation
import XCTest
@testable import Attic

final class OpticalEnvironmentMonitorTests: XCTestCase {
    @MainActor
    func testRefreshPublishesInjectedEventDrivenSnapshot() {
        var supplied = OpticalEnvironmentSnapshot(
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            isOnBatteryPower: false
        )
        let monitor = OpticalEnvironmentMonitor(snapshotProvider: { supplied })
        XCTAssertEqual(monitor.snapshot, supplied)

        supplied = OpticalEnvironmentSnapshot(
            isLowPowerModeEnabled: true,
            thermalState: .serious,
            isOnBatteryPower: true
        )
        monitor.refresh()

        XCTAssertEqual(monitor.snapshot, supplied)
    }

    @MainActor
    func testPowerSourceChangesRefreshWithoutPollingAndStopCleanly() {
        var supplied = OpticalEnvironmentSnapshot(
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            isOnBatteryPower: false
        )
        let observer = TestOpticalPowerSourceObserver()
        let monitor = OpticalEnvironmentMonitor(
            snapshotProvider: { supplied },
            powerSourceObserver: observer
        )

        monitor.start()
        XCTAssertEqual(observer.startCount, 1)

        supplied = OpticalEnvironmentSnapshot(
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            isOnBatteryPower: true
        )
        observer.trigger()
        XCTAssertEqual(monitor.snapshot, supplied)

        monitor.stop()
        XCTAssertEqual(observer.stopCount, 1)
        XCTAssertNil(observer.changeHandler)
    }

    @MainActor
    func testEnvironmentSnapshotContainsNoFocusSignal() {
        let labels = Set(
            Mirror(reflecting: OpticalEnvironmentSnapshot(
                isLowPowerModeEnabled: false,
                thermalState: .nominal,
                isOnBatteryPower: false
            )).children.compactMap(\.label)
        )

        XCTAssertEqual(
            labels,
            ["isLowPowerModeEnabled", "thermalState", "isOnBatteryPower"]
        )
        XCTAssertFalse(labels.contains("isFocused"))
        XCTAssertFalse(labels.contains("isKeyWindow"))
    }
}

@MainActor
private final class TestOpticalPowerSourceObserver: OpticalPowerSourceObserving {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var changeHandler: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        startCount += 1
        changeHandler = onChange
    }

    func stop() {
        stopCount += 1
        changeHandler = nil
    }

    func trigger() {
        changeHandler?()
    }
}
