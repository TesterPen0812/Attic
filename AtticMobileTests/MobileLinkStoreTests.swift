import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class MobileLinkStoreTests: XCTestCase {
    func testDivergentReplicaPreventsPurgeAndUnlinkReachesEveryCopy() throws {
        let db = try PersistenceController.makeContainer(inMemory: true)
        let first = AtticItemRef(.note, UUID()), other = AtticItemRef(.note, UUID())
        let task = AtticItemRef(.task, UUID()), id = UUID()
        let seed = ModelContext(db)
        seed.insert(ItemLink(id: id, source: first, target: task, kind: .card))
        seed.insert(ItemLink(id: id, source: other, target: task, kind: .card))
        try seed.save()
        let store = LinkStore(container: db)
        XCTAssertEqual(store.purgeLinks(touching: [first]), 0)
        XCTAssertTrue(store.unlink(id))
        let removed = try ModelContext(db).fetch(FetchDescriptor<ItemLink>())
        XCTAssertEqual(removed.count, 2)
        XCTAssertTrue(removed.allSatisfy { $0.deletedAt != nil })
        XCTAssertTrue(store.backlinks(to: task).isEmpty)
        XCTAssertTrue(store.restoreLink(id))
        XCTAssertEqual(store.backlinks(to: task).map(\.id), [id])
        let copies = try ModelContext(db).fetch(FetchDescriptor<ItemLink>())
        XCTAssertEqual(Set(copies.compactMap(\.source)), [first, other])
        XCTAssertTrue(copies.allSatisfy { $0.deletedAt == nil })
    }

    func testUnavailableEndpointAndFailedSaveCreateNoLink() throws {
        let db = try PersistenceController.makeContainer(inMemory: true)
        let note = AtticItemRef(.note, UUID()), task = AtticItemRef(.task, UUID())
        let store = LinkStore(container: db, persist: { _ in throw CocoaError(.fileWriteOutOfSpace) },
                              endpointState: { $0 == task ? .deleted : .live })
        XCTAssertNil(store.link(note, to: task, kind: .card))
        store.endpointState = { _ in .live }
        XCTAssertNil(store.link(note, to: task, kind: .card))
        XCTAssertEqual(store.revision, 0)
        XCTAssertEqual(try ModelContext(db).fetchCount(FetchDescriptor<ItemLink>()), 0)
    }
}
