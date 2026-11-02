import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneShellPersistenceTests: XCTestCase {
    func testOvernightSeedIsPersistentIdempotentAndOptInOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-phone-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "attic.phone.seed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let day = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z"))

        let container = try PersistenceController.makeContainer(storeDirectory: root)
        try PhoneSampleSeed.installIfNeeded(container: container, enabled: false,
                                             defaults: defaults, clock: day)
        XCTAssertTrue(try PhoneLibrary(container: container).tasks().isEmpty)
        XCTAssertTrue(try PhoneLibrary(container: container).notes().isEmpty)

        try PhoneSampleSeed.installIfNeeded(container: container, enabled: true,
                                             defaults: defaults, clock: day)
        let writer = PhoneLibrary(container: container)
        XCTAssertEqual(try writer.tasks().count, 8)
        XCTAssertEqual(try writer.notes().count, 4)
        XCTAssertTrue(defaults.bool(forKey: PhoneSampleSeed.markerKey))
        XCTAssertEqual(try writer.tasks(status: .backlog).map(\.title), ["Read about SwiftUI"])

        // A second process opens the same saved model files. The first app
        // launch marker must avoid clobbering the user's subsequent changes.
        let sampleID = try XCTUnwrap(writer.tasks().first?.id)
        _ = try writer.updateTask(id: sampleID, patch: .init(title: "Saved on disk", priority: nil, status: nil))
        let reopened = try PersistenceController.makeContainer(storeDirectory: root)
        try PhoneSampleSeed.installIfNeeded(container: reopened, enabled: true,
                                             defaults: defaults, clock: day)
        let reader = PhoneLibrary(container: reopened)
        XCTAssertEqual(try reader.tasks().count, 8)
        XCTAssertEqual(try reader.notes().count, 4)
        XCTAssertTrue(try reader.tasks().contains { $0.title == "Saved on disk" })
    }

    func testExistingLocalLibraryIsNeverOverwrittenBySampleInstaller() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let existing = PhoneLibrary(container: container)
        let entry = try existing.createNote(title: "Real local item", body: "Keep this")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "attic.phone.seed.existing.\(UUID().uuidString)"))

        try PhoneSampleSeed.installIfNeeded(container: container, enabled: true, defaults: defaults)
        XCTAssertEqual(try existing.notes().map(\.id), [entry.note.id])
        XCTAssertTrue(try existing.tasks().isEmpty)
        XCTAssertTrue(defaults.bool(forKey: PhoneSampleSeed.markerKey))
    }
}
