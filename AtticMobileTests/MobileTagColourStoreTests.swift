import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class MobileTagColourStoreTests: XCTestCase {
    func testRecolouringUpdatesPhysicalReplicasWithoutRenamingAliasesAndRollsBackOnFailure() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let id = UUID()
        seed.insert(TagColour(id: id, name: "projects", hue: .green))
        seed.insert(TagColour(id: id, name: "studio", hue: .yellow))
        seed.insert(TagColour(name: "projects", hue: .blue))
        try seed.save()

        let working = TagColourStore(container: container)
        XCTAssertTrue(working.setHue(.pink, for: "Projects"))
        let failing = TagColourStore(container: container, persist: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertFalse(failing.setHue(.purple, for: "projects"))
        let reopened = try ModelContext(container).fetch(FetchDescriptor<TagColour>())
        XCTAssertEqual(reopened.map(\.name).sorted(), ["projects", "projects", "studio"])
        XCTAssertEqual(reopened.filter { $0.id == id }.count, 2)
        XCTAssertTrue(reopened.allSatisfy { $0.hue == .pink })
    }

    func testReadingThePaletteDoesNotReplaceAnUnknownStoredHue() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let seed = ModelContext(container)
        let row = TagColour(name: "future", hue: nil)
        row.colourKey = "not-in-this-version"
        seed.insert(row)
        try seed.save()
        let store = TagColourStore(container: container)
        XCTAssertTrue(store.refresh(inUse: ["future", "new"]))
        let rows = try ModelContext(container).fetch(FetchDescriptor<TagColour>())
        XCTAssertEqual(rows.first { $0.name == "future" }?.colourKey, "not-in-this-version")
        XCTAssertNotNil(rows.first { $0.name == "new" }?.hue)
    }
}
