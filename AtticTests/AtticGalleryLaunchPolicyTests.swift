import XCTest
@testable import Attic

/// The design-system gallery never touches the owner's data: it opens only
/// under a preview identity or in UI tests, and never opens the persistent
/// store or shows the menu-bar item.
final class AtticGalleryLaunchPolicyTests: XCTestCase {
    private func runtime(_ arguments: [String], bundle: String?, environment: [String: String] = [:]) -> AppRuntimeEnvironment {
        AppRuntimeEnvironment(environment: environment, processIdentifier: 1, testRunIdentifier: "t", arguments: ["Attic"] + arguments, bundleIdentifier: bundle)
    }

    func testTheGalleryIsRefusedUnderTheOfficialIdentity() {
        let official = runtime(["--attic-gallery"], bundle: "com.taha.Attic")
        XCTAssertEqual(official.galleryLaunch, .refused)
        XCTAssertTrue(official.usesInMemoryStore, "A refused gallery launch still never opens the persistent store")
        XCTAssertFalse(official.showsMenuBarItem)
        // Look-alikes are not preview identities.
        XCTAssertEqual(runtime(["--attic-gallery"], bundle: "com.taha.Attic.").galleryLaunch, .refused)
        XCTAssertEqual(runtime(["--attic-gallery"], bundle: "com.taha.AtticDaily").galleryLaunch, .refused)
        XCTAssertEqual(runtime(["--attic-gallery"], bundle: nil).galleryLaunch, .refused)
    }

    func testTheGalleryOpensUnderAPreviewIdentityOrInUITests() {
        for launch in [
            runtime(["--attic-gallery"], bundle: "com.taha.Attic.p0design"),
            runtime(["--attic-gallery", "--capture", "/tmp/x"], bundle: "com.taha.Attic.ui.p0design"),
            runtime(["--attic-gallery"], bundle: "com.taha.Attic", environment: ["ATTIC_UI_TESTING": "1"])
        ] {
            XCTAssertEqual(launch.galleryLaunch, .allowed)
            XCTAssertTrue(launch.usesInMemoryStore, "The gallery never opens, migrates or writes the persistent store")
            XCTAssertFalse(launch.showsMenuBarItem, "The gallery shows no menu-bar item")
        }
    }

    func testANormalLaunchIsUnchanged() {
        let normal = runtime([], bundle: "com.taha.Attic")
        XCTAssertEqual(normal.galleryLaunch, .none)
        XCTAssertFalse(normal.usesInMemoryStore, "The real app keeps its persistent store")
        XCTAssertTrue(normal.showsMenuBarItem)
        let preview = runtime([], bundle: "com.taha.Attic.p0design")
        XCTAssertEqual(preview.galleryLaunch, .none)
        XCTAssertFalse(preview.usesInMemoryStore)
    }
}
