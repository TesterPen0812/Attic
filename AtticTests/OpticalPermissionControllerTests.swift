import XCTest
@testable import Attic

final class OpticalPermissionControllerTests: XCTestCase {
    @MainActor
    func testInitializationAndRefreshNeverRequestPermission() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestCount = 0
        let controller = OpticalPermissionController(
            defaults: defaults,
            preflight: { false },
            request: {
                requestCount += 1
                return true
            },
            openSettings: {}
        )

        XCTAssertEqual(controller.state, .notRequested)
        XCTAssertEqual(requestCount, 0)

        controller.refresh()

        XCTAssertEqual(controller.state, .notRequested)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testExplicitRequestRecordsAndPublishesAuthorization() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestCount = 0
        let controller = OpticalPermissionController(
            defaults: defaults,
            preflight: { false },
            request: {
                requestCount += 1
                return true
            },
            openSettings: {}
        )

        controller.requestAccess()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(controller.state, .authorized)
        XCTAssertTrue(defaults.bool(forKey: "hasRequestedOpticalScreenCaptureAccess"))
    }

    @MainActor
    func testDeniedRequestPersistsWithoutRequestingAgainOnNextLaunch() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requestCount = 0
        let controller = OpticalPermissionController(
            defaults: defaults,
            preflight: { false },
            request: {
                requestCount += 1
                return false
            },
            openSettings: {}
        )
        controller.requestAccess()
        XCTAssertEqual(controller.state, .denied)
        XCTAssertEqual(requestCount, 1)

        let reloaded = OpticalPermissionController(
            defaults: defaults,
            preflight: { false },
            request: {
                requestCount += 1
                return true
            },
            openSettings: {}
        )

        XCTAssertEqual(reloaded.state, .denied)
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testPreflightAuthorizationOverridesPreviousDenial() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "hasRequestedOpticalScreenCaptureAccess")

        let controller = OpticalPermissionController(
            defaults: defaults,
            preflight: { true },
            request: { false },
            openSettings: {}
        )

        XCTAssertEqual(controller.state, .authorized)
    }

    @MainActor
    func testOpenSettingsUsesInjectedExplicitAction() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var openCount = 0
        let controller = OpticalPermissionController(
            defaults: defaults,
            preflight: { false },
            request: { false },
            openSettings: { openCount += 1 }
        )

        controller.openSystemSettings()

        XCTAssertEqual(openCount, 1)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "OpticalPermissionControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
