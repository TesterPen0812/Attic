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

    func testEditorPatchOmitsUnchangedBodySoAnImportedEditIsPreserved() {
        let baseline = MobileNoteEditBaseline(
            title: "Original title",
            body: "Body imported from Mac"
        )

        let patch = baseline.patch(
            title: "Renamed on iPhone",
            body: "Body imported from Mac"
        )

        XCTAssertEqual(patch.title, "Renamed on iPhone")
        XCTAssertNil(patch.body)
    }
}
