import SwiftData
import XCTest
@testable import AtticMobile

final class NoteStoreMobileTests: XCTestCase {
    @MainActor
    func testMobileNoteStoreSharesSemanticsWithoutCloudKitInTests() throws {
        let configuration = PersistenceController.makeConfiguration(inMemory: true)
        XCTAssertNil(configuration.cloudKitContainerIdentifier)

        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container)
        let note = try XCTUnwrap(store.create(title: "  From   iPhone ", body: "  sync me "))

        XCTAssertEqual(note.title, "From iPhone")
        XCTAssertEqual(note.body, "sync me")

        XCTAssertTrue(store.update(note, body: "updated"))
        XCTAssertEqual(note.body, "updated")
    }
}
