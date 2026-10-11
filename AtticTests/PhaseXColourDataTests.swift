import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

/// Stored tag colours (colour pass, owner 2026-10-10): the additive
/// `TagColour` entity, colours given once and kept, renames, replicas and
/// failed saves.
@MainActor
final class PhaseXColourDataTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = ownedTemporaryDirectory(prefix: "AtticTagColour")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeLibrary(persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> AtticLibrary {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        return AtticLibrary(tasks: TaskStore(container: container), persist: persist)
    }

    private func tag(_ library: AtticLibrary, _ title: String, _ tags: [String], created: Date) throws {
        let task = try XCTUnwrap(library.tasks.create(title: title))
        let context = ModelContext(library.tasks.container)
        let id = task.id
        for row in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })) {
            row.createdAt = created
            row.tags = tags
        }
        try context.save()
        library.tasks.refresh()
        library.tags.invalidateInventory()
    }

    private func rows(_ container: ModelContainer, named name: String? = nil) throws -> [TagColour] {
        let all = try ModelContext(container).fetch(FetchDescriptor<TagColour>())
        return name.map { name in all.filter { $0.name == name } } ?? all
    }

    // MARK: Schema

    func testTagColourIsAdditiveAndCloudKitCompatible() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let entity = try XCTUnwrap(container.schema.entities.first { $0.name == "TagColour" })
        XCTAssertTrue(entity.uniquenessConstraints.isEmpty)
        XCTAssertEqual(Set(entity.attributes.map(\.name)), ["id", "name", "colourKey", "createdAt", "modifiedAt"])
        for attribute in entity.attributes {
            XCTAssertFalse(attribute.options.contains(.unique))
            XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil, attribute.name)
        }
    }

    /// A store written before tag colours opens in place; its tags get their
    /// colours once, oldest first, and keep them.
    func testExistingStoreOpensAndItsTagsAreGivenColoursOnce() throws {
        let storeDirectory = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let url = PersistenceController.makeConfiguration(cloudSyncEnabled: false, storeDirectory: storeDirectory).url
        let before = PersistenceController.appModelTypes.filter { ObjectIdentifier($0) != ObjectIdentifier(TagColour.self) }
        do {
            let old = try ModelContainer(for: Schema(before), configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            let context = ModelContext(old)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            for (offset, (title, tags)) in [("Finalize", ["launch"]), ("Ship", ["design"]), ("Email", ["pricing", "launch"])].enumerated() {
                let task = TaskItem(title: title)
                task.createdAt = start.addingTimeInterval(Double(offset) * 60)
                task.tags = tags
                context.insert(task)
            }
            try context.save()
            XCTAssertFalse(old.schema.entities.contains { $0.name == "TagColour" })
        }

        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: storeDirectory)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()), 3)
        let library = AtticLibrary(tasks: TaskStore(container: container))
        library.refreshTagColours()
        // The sheet: launch teal, design blue, pricing (also teal) olive.
        XCTAssertEqual(library.tagColours.palette.hues, ["launch": .teal, "design": .blue, "pricing": .olive])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try rows(container).map { ($0.name, $0.hue) }),
                       ["launch": .teal, "design": .blue, "pricing": .olive])
        // Given once: another refresh, or a new tag, writes nothing more
        // for them and changes no colour.
        library.refreshTagColours()
        XCTAssertEqual(try rows(container).count, 3)
        try tag(library, "Health", ["health"], created: .now)
        library.refreshTagColours()
        XCTAssertEqual(try rows(container).count, 4)
        XCTAssertEqual(library.tagColours.palette.hue(for: "pricing"), .olive)
        XCTAssertNotEqual(library.tagColours.palette.hue(for: "health"), .grey)
    }

    // MARK: Changing, renaming, merging

    func testAR01BackToBackRenamesKeepStoredColourWithoutRefreshing() throws {
        let library = try makeLibrary()
        try tag(library, "One", ["launch"], created: .now)
        library.refreshTagColours()
        XCTAssertTrue(library.setTagHue(.pink, for: "launch"))
        XCTAssertTrue(library.renameTag("launch", to: "release"))
        XCTAssertTrue(library.renameTag("release", to: "final"))
        XCTAssertEqual(try rows(library.tasks.container, named: "final").map(\.hue), [.pink])
    }

    func testAR01ColdLibraryRenameAndImmediateMergeUseAuthoritativeRows() throws {
        let library = try makeLibrary()
        try tag(library, "One", ["launch"], created: .now)
        try tag(library, "Two", ["design"], created: .now)
        let context = ModelContext(library.tasks.container)
        context.insert(TagColour(name: "launch", hue: .pink))
        context.insert(TagColour(name: "design", hue: .grey))
        try context.save()
        let cold = AtticLibrary(tasks: TaskStore(container: library.tasks.container))
        XCTAssertTrue(cold.renameTag("launch", to: "release"))
        XCTAssertEqual(try rows(library.tasks.container, named: "release").map(\.hue), [.pink])
        XCTAssertTrue(cold.mergeTags(["release"], into: "design"))
        XCTAssertEqual(try rows(library.tasks.container, named: "design").map(\.hue), [.grey])
    }

    func testAR01ColdColourChangeAndUndoReadTheStoredValue() throws {
        let library = try makeLibrary()
        let context = ModelContext(library.tasks.container)
        context.insert(TagColour(name: "launch", hue: .pink))
        try context.save()
        XCTAssertTrue(library.setTagHue(.teal, for: "launch"))
        XCTAssertEqual(try rows(library.tasks.container, named: "launch").map(\.hue), [.teal])
        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertEqual(try rows(library.tasks.container, named: "launch").map(\.hue), [.pink])
    }

    func testAR03AutomaticAssignmentReachesColourlessUUIDReplicas() throws {
        let library = try makeLibrary()
        let context = ModelContext(library.tasks.container), id = UUID()
        context.insert(TagColour(id: id, name: "launch", hue: nil))
        context.insert(TagColour(id: id, name: "release", hue: nil))
        try context.save()
        XCTAssertTrue(library.tagColours.refresh(inUse: ["launch"]))
        let all = try rows(library.tasks.container)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.hue == .teal })
    }

    func testAR01UnstoredRenameIgnoresDormantColoursAndUsesLiveAssignment() throws {
        let library = try makeLibrary()
        try tag(library, "One", ["pricing"], created: .now)
        let context = ModelContext(library.tasks.container)
        context.insert(TagColour(name: "launch", hue: .teal))
        try context.save()
        XCTAssertTrue(library.renameTag("pricing", to: "quote"))
        XCTAssertEqual(try rows(library.tasks.container, named: "quote").map(\.hue), [.teal])
    }

    func testAR03AutomaticAssignmentUsesKnownUUIDHueAndPreservesUnknownKeys() throws {
        for names in [["launch"], ["launch", "release"]] {
            let library = try makeLibrary()
            let context = ModelContext(library.tasks.container), knownID = UUID(), unknownID = UUID()
            context.insert(TagColour(id: knownID, name: "launch", hue: nil))
            context.insert(TagColour(id: knownID, name: "release", hue: .pink))
            context.insert(TagColour(id: unknownID, name: "future", hue: nil))
            let unknown = TagColour(id: unknownID, name: "future-alias", hue: nil)
            unknown.colourKey = "future-magenta"
            context.insert(unknown)
            try context.save()
            XCTAssertTrue(library.tagColours.refresh(inUse: names + ["future"]))
            let all = try rows(library.tasks.container)
            XCTAssertTrue(all.filter { $0.id == knownID }.allSatisfy { $0.hue == .pink })
            XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .pink)
            XCTAssertEqual(all.first { $0.name == "future-alias" }?.colourKey, "future-magenta")
            XCTAssertNil(all.first { $0.name == "future" }?.colourKey)
        }
    }

    private final class ColourProbeState {
        var colouring = AtticTagColouring()
    }
    private struct ColourProbe: View {
        @Environment(\.atticTagColouring) var colouring
        let state: ColourProbeState
        var body: some View {
            let _ = state.colouring = colouring
            Color.clear.frame(width: 10, height: 10)
        }
    }

    func testAR07ColourMenuUsesTheOriginatingPagesUndoAndRedo() throws {
        for history: UndoHistoryID in [.tasks, .notesLibrary] {
            let library = try makeLibrary()
            try tag(library, "One", ["launch"], created: .now)
            library.refreshTagColours()
            let state = ColourProbeState()
            let host = NSHostingView(rootView: ColourProbe(state: state)
                .atticTagColourOrigin(.page(history)).atticTagColours(library))
            host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let colour = try XCTUnwrap(state.colouring.colourCommands(for: "launch").first?.children.first { $0.swatch == .pink })
            colour.action()
            XCTAssertEqual(library.undo.undoCount(in: .library), 0)
            if history == .tasks {
                let model = TasksPageModel(library: library)
                XCTAssertEqual(model.undo(), .applied)
                XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .teal)
                XCTAssertEqual(model.redo(), .applied)
            } else {
                XCTAssertTrue(library.undo.undo(in: history))
                XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .teal)
                XCTAssertTrue(library.undo.redo(in: history))
            }
            XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .pink)
        }
    }

    func testAR07NoteColourMenuSharesTextHistoryAndFailedUndoCanRetry() throws {
        let gate = PersistenceGate()
        let library = try makeLibrary(persist: gate.save)
        try tag(library, "One", ["launch"], created: .now)
        library.refreshTagColours()
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("Body")]))
        let state = ColourProbeState()
        let host = NSHostingView(rootView: ColourProbe(state: state)
            .atticTagColourOrigin(.editor(engine.history)).atticTagColours(library))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let colour = try XCTUnwrap(state.colouring.colourCommands(for: "launch").first?.children.first { $0.swatch == .pink })
        colour.action()
        XCTAssertEqual(engine.history.undoActionName, "Tag Colour")
        XCTAssertEqual(library.undo.undoCount(in: .library), 0)
        let doc = engine.document()
        gate.shouldFail = true
        XCTAssertFalse(engine.history.undo())
        XCTAssertEqual(engine.history.undoOps.count, 1)
        XCTAssertTrue(engine.history.redoOps.isEmpty)
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .pink)
        gate.shouldFail = false
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .teal)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .pink)
        XCTAssertEqual(engine.document(), doc, "metadata history never changes text or selection")
    }

    func testAR02EqualIdentityAndTimeResolvePayloadIndependentlyOfFetchOrder() {
        let id = UUID(), date = Date(timeIntervalSince1970: 1000)
        let a = TagColour(id: id, name: "launch", hue: .pink, at: date)
        let b = TagColour(id: id, name: "launch", hue: .blue, at: date)
        XCTAssertEqual(TagColourStore.storedHues([a, b]), TagColourStore.storedHues([b, a]))
        XCTAssertEqual(TagColourStore.storedHues([a, b])["launch"], .blue)
    }

    func testAR03ColourWriteReachesDivergentNameUUIDReplicas() throws {
        let library = try makeLibrary()
        let context = ModelContext(library.tasks.container), id = UUID()
        context.insert(TagColour(id: id, name: "launch", hue: .pink))
        context.insert(TagColour(id: id, name: "release", hue: .blue))
        context.insert(TagColour(name: "launch", hue: .teal))
        context.insert(TagColour(name: "unrelated", hue: .olive))
        try context.save()
        XCTAssertTrue(library.tagColours.setHue(.grey, for: "launch"))
        let all = try rows(library.tasks.container)
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(all.filter { $0.name == "launch" || $0.id == id }.allSatisfy { $0.hue == .grey })
        XCTAssertEqual(all.first { $0.name == "unrelated" }?.hue, .olive)
        XCTAssertEqual(library.tagColours.palette.hue(for: "release"), .grey)
    }

    func testChangingAColourIsOneUndoStepAndRenamingKeepsIt() throws {
        let library = try makeLibrary()
        try tag(library, "One", ["launch"], created: .now)
        try tag(library, "Two", ["design"], created: .now.addingTimeInterval(1))
        library.refreshTagColours()
        let steps = library.undo.undoCount(in: .library)

        XCTAssertTrue(library.setTagHue(.pink, for: "launch"))
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .pink)
        XCTAssertEqual(library.undo.undoCount(in: .library), steps + 1)
        XCTAssertTrue(library.undo.undo(in: .library))
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .teal)
        XCTAssertTrue(library.undo.redo(in: .library))
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .pink)

        // Rename: the new name keeps the colour; undo brings the old name
        // back in its colour.
        XCTAssertTrue(library.renameTag("launch", to: "release"))
        library.refreshTagColours()
        XCTAssertEqual(library.tagColours.palette.hue(for: "release"), .pink)
        XCTAssertTrue(library.undo.undo(in: .library))
        library.refreshTagColours()
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .pink)
        XCTAssertTrue(library.undo.redo(in: .library))
        library.refreshTagColours()
        XCTAssertEqual(library.tagColours.palette.hue(for: "release"), .pink)

        // Merging into a tag in use: the target keeps its own colour.
        XCTAssertTrue(library.mergeTags(["release"], into: "design"))
        library.refreshTagColours()
        XCTAssertEqual(library.tagColours.palette.hue(for: "design"), .blue)
        XCTAssertEqual(library.tags.names, ["design"])
    }

    /// Every physical row of a tag's name is a replica: presentation picks
    /// the newest change (then the lowest id), and a change writes them all.
    func testAColourChangeAppliesToEveryReplica() throws {
        let library = try makeLibrary()
        let container = library.tasks.container
        let shared = UUID()
        let old = Date(timeIntervalSince1970: 1_000), newer = Date(timeIntervalSince1970: 2_000)
        let context = ModelContext(container)
        context.insert(TagColour(id: shared, name: "launch", hue: .teal, at: old))
        context.insert(TagColour(id: shared, name: "launch", hue: .indigo, at: newer))
        context.insert(TagColour(name: "launch", hue: .violet, at: old))
        context.insert(TagColour(name: "design", hue: .blue, at: old))
        try context.save()
        XCTAssertEqual(TagColourStore.storedHues(try rows(container))["launch"], .indigo)

        try tag(library, "One", ["launch", "design"], created: .now)
        library.refreshTagColours()
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .indigo)
        XCTAssertEqual(try rows(container).count, 4, "replicas are never deleted or duplicated")

        XCTAssertTrue(library.setTagHue(.ochre, for: "launch"))
        let launch = try rows(container, named: "launch")
        XCTAssertEqual(launch.count, 3)
        XCTAssertTrue(launch.allSatisfy { $0.hue == .ochre })
        XCTAssertEqual(try rows(container, named: "design").first?.hue, .blue)

        // Ties on time resolve by id, the same way everywhere.
        let a = TagColour(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "x", hue: .pink, at: old)
        let b = TagColour(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "x", hue: .olive, at: old)
        XCTAssertEqual(TagColourStore.storedHues([b, a])["x"], .pink)
        XCTAssertEqual(TagColourStore.storedHues([a, b])["x"], .pink)
    }

    /// A colour a newer Attic stored is kept, never rewritten; a colourless
    /// replica is filled in rather than duplicated.
    func testUnknownAndMissingColoursAreHandledWithoutDuplicates() throws {
        let library = try makeLibrary()
        let container = library.tasks.container
        let context = ModelContext(container)
        let future = TagColour(name: "launch", hue: nil)
        future.colourKey = "magenta"
        context.insert(future)
        context.insert(TagColour(name: "design", hue: nil))
        try context.save()
        try tag(library, "One", ["launch", "design"], created: .now)
        library.refreshTagColours()
        XCTAssertEqual(try rows(container, named: "launch").map(\.colourKey), ["magenta"])
        XCTAssertNotEqual(library.tagColours.palette.hue(for: "launch"), .grey)
        let design = try rows(container, named: "design")
        XCTAssertEqual(design.count, 1)
        XCTAssertEqual(design.first?.hue, library.tagColours.palette.hue(for: "design"))
    }

    // MARK: Failed saves

    func testFailedColourSavesRollBackAndChangeNothing() throws {
        let gate = PersistenceGate()
        let library = try makeLibrary(persist: gate.save)
        let container = library.tasks.container
        try tag(library, "One", ["launch"], created: .now)
        library.refreshTagColours()
        XCTAssertEqual(try rows(container, named: "launch").first?.hue, .teal)
        let steps = library.undo.undoCount(in: .library)

        gate.shouldFail = true
        XCTAssertFalse(library.setTagHue(.pink, for: "launch"))
        XCTAssertEqual(library.tagColours.palette.hue(for: "launch"), .teal)
        XCTAssertEqual(try rows(container, named: "launch").map(\.hue), [.teal])
        XCTAssertEqual(library.undo.undoCount(in: .library), steps)

        // A failed rename leaves no colour behind for the new name.
        XCTAssertFalse(library.renameTag("launch", to: "release"))
        XCTAssertTrue(try rows(container, named: "release").isEmpty)
        XCTAssertEqual(library.tags.names, ["launch"])

        // A failed assignment stores nothing but still shows the colour;
        // the next refresh stores it.
        gate.shouldFail = false
        try tag(library, "Two", ["design"], created: .now)
        gate.shouldFail = true
        XCTAssertFalse(library.tagColours.refresh(inUse: library.tags.namesOldestFirst))
        XCTAssertTrue(try rows(container, named: "design").isEmpty)
        XCTAssertEqual(library.tagColours.palette.hue(for: "design"), .blue)
        gate.shouldFail = false
        XCTAssertTrue(library.tagColours.refresh(inUse: library.tags.namesOldestFirst))
        XCTAssertEqual(try rows(container, named: "design").map(\.hue), [.blue])
    }

    /// Tags made anywhere (a store, an agent) get their colour after the
    /// save that made them, without being asked.
    func testNewTagsAreGivenColoursAfterTheirSave() throws {
        let library = try makeLibrary()
        let task = try XCTUnwrap(library.tasks.create(title: "One"))
        XCTAssertTrue(library.tasks.setTags(["launch"], for: task))
        let given = expectation(description: "colour stored")
        DispatchQueue.main.async { given.fulfill() }
        wait(for: [given], timeout: 2)
        XCTAssertEqual(try rows(library.tasks.container, named: "launch").map(\.hue), [.teal])
        XCTAssertEqual(library.tagColours.palette.hues["launch"], .teal)
    }
}
