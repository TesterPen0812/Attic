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
