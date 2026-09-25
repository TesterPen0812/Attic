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

    // MARK: - Files (final review finding 1)

    private let old = Date(timeIntervalSince1970: 1_000_000)

    /// An Application Support directory holding one note attachment, one
    /// task attachment and a note draft-recovery file, as a preview identity
    /// that was used before would. Every file and directory is old, so any
    /// cleanup that considered them unreferenced would remove them.
    private func usedApplicationSupport() throws -> (root: URL, sentinels: [URL]) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AtticGallerySentinels-\(UUID().uuidString)", isDirectory: true)
        let digest = String(repeating: "ab", count: 32)
        let sentinels = [
            root.appendingPathComponent("Attic/Attachments/v1/\(UUID().uuidString)/\(digest)/note.txt"),
            root.appendingPathComponent("Attic/TaskImages/\(UUID().uuidString)/\(digest)/task.txt"),
            root.appendingPathComponent("Attic/Notes/draft-recovery.json")
        ]
        for file in sentinels {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("sentinel \(file.lastPathComponent)".utf8).write(to: file)
        }
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try fileManager.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: url.path)
            }
        }
        return (root, sentinels)
    }

    /// Builds the item stores exactly as the coordinator does for `launch`
    /// and lets their launch-time file cleanup run to completion.
    @MainActor
    private func runFileCleanup(for launch: AppRuntimeEnvironment) async throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let (tasks, notes) = launch.makeItemStores(container: container)
        await notes.waitForAttachmentReconciliation()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtticGalleryStaging-\(UUID().uuidString)", isDirectory: true)
        _ = await tasks.sweepUnreferencedAttachmentStorage(minimumAge: 0, dropStagingRoot: staging)
        try? FileManager.default.removeItem(at: staging)
    }

    @MainActor
    func testAllowedAndRefusedGalleryLaunchesLeaveTheIdentitysFilesAlone() async throws {
        for (label, bundle) in [("allowed", "com.taha.Attic.p0design"), ("refused", "com.taha.Attic")] {
            let (support, sentinels) = try usedApplicationSupport()
            defer { try? FileManager.default.removeItem(at: support) }
            let launch = AppRuntimeEnvironment(
                environment: [:], processIdentifier: 1, testRunIdentifier: UUID().uuidString,
                arguments: ["Attic", "--attic-gallery"], bundleIdentifier: bundle,
                applicationSupportURL: support
            )
            defer { try? FileManager.default.removeItem(at: launch.galleryScratchRoot) }
            XCTAssertEqual(launch.galleryLaunch, label == "allowed" ? .allowed : .refused)
            XCTAssertTrue(launch.usesInMemoryStore, label)
            XCTAssertNil(launch.noteRecoveryURL, "\(label): no draft recovery is read or written")
            XCTAssertTrue(launch.usesEphemeralAgentCredential, "\(label): the identity's credential is never loaded")
            XCTAssertFalse(launch.makeSettingsDefaults() === UserDefaults.standard, "\(label): scratch settings")
            XCTAssertTrue(launch.galleryScratchRoot.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path), label)

            try await runFileCleanup(for: launch)

            for file in sentinels {
                XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), "sentinel \(file.lastPathComponent)",
                               "\(label) gallery launch removed \(file.path)")
            }
        }
    }

    /// The control: the same cleanup under a normal launch of the same
    /// directory does remove unreferenced files, so the sentinels above are
    /// ones a gallery launch would have destroyed without its isolation.
    @MainActor
    func testTheSameCleanupUnderANormalLaunchWouldRemoveTheSentinels() async throws {
        let (support, sentinels) = try usedApplicationSupport()
        defer { try? FileManager.default.removeItem(at: support) }
        let normal = AppRuntimeEnvironment(
            environment: [:], processIdentifier: 1, testRunIdentifier: "t",
            arguments: ["Attic"], bundleIdentifier: "com.taha.Attic.p0design", applicationSupportURL: support
        )
        XCTAssertEqual(normal.noteRecoveryURL?.standardizedFileURL, sentinels[2].standardizedFileURL)
        try await runFileCleanup(for: normal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinels[0].path), "note attachment reconciled away")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinels[1].path), "task attachment swept away")
    }
}
