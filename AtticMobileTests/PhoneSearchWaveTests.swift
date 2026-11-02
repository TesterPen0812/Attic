import Foundation
import SwiftData
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneSearchWaveTests: XCTestCase {
    func testTaskGroupsUseListedStatusAndReportIndependentCounts() throws {
        let library = PhoneLibrary(container: try PersistenceController.makeContainer(inMemory: true))
        let now = try library.createTask(title: "Boiler quote", status: .todo)
        let inProgress = try library.createTask(title: "Boiler inspection", status: .inProgress)
        let later = try library.createTask(title: "Boiler service", status: .backlog)
        let done = try library.createTask(title: "Boiler approved", status: .done)
        _ = try library.createTask(title: "Unrelated task", status: .todo)

        let result = PhoneSearchWaveIndex.search(
            "boiler", tasks: try library.tasks(), notes: [], canvases: []
        )
        XCTAssertEqual(Set(result.now.map(\.id)), [now.id, inProgress.id])
        XCTAssertEqual(result.later.map(\.id), [later.id])
        XCTAssertEqual(result.done.map(\.id), [done.id])
        XCTAssertEqual(result.taskCount, 4)
        XCTAssertEqual(result.totalCount, 4)
        XCTAssertEqual(result.count(for: .now), 2)
        XCTAssertEqual(result.count(for: .later), 1)
        XCTAssertEqual(result.count(for: .done), 1)
    }

    func testNoteBodyTagAndCanvasBoardTextAreSearchableWithoutEdits() throws {
        let library = PhoneLibrary(container: try PersistenceController.makeContainer(inMemory: true))
        let written = try library.createNote(
            title: "Maintenance notes",
            body: "First line\nMove the BOILER beside the window.",
            tags: ["house"]
        )
        let original = try XCTUnwrap(library.notes().first)
        var canvas = DrawCanvas()
        canvas.name = "Kitchen layout"
        canvas.tags = ["house"]
        canvas.textIndex = "Measure the wall\nMove the boiler cupboard to the left"
        var deleted = DrawCanvas()
        deleted.name = "Boiler sketch"
        deleted.deletedAt = Date()

        let matches = PhoneSearchWaveIndex.search(
            "BoIlEr", tasks: [], notes: try library.notes(), canvases: [canvas, deleted]
        )
        XCTAssertEqual(matches.notes.map(\.id), [written.note.id])
        XCTAssertEqual(matches.canvases.map(\.id), [canvas.id])
        XCTAssertTrue(matches.notes[0].detail?.localizedStandardContains("boiler") == true)
        XCTAssertTrue(matches.canvases[0].detail?.localizedStandardContains("boiler") == true)
        XCTAssertEqual(try library.notes().first?.body, original.body)

        let tags = PhoneSearchWaveIndex.search(
            "#HOUSE", tasks: [], notes: try library.notes(), canvases: [canvas, deleted]
        )
        XCTAssertEqual(tags.notes.map(\.id), [written.note.id])
        XCTAssertEqual(tags.canvases.map(\.id), [canvas.id])
        XCTAssertTrue(tags.canvases[0].detail?.localizedStandardContains("#house") == true)
    }

    func testRelevancePrefersExactThenPrefixThenTagThenBody() throws {
        let library = PhoneLibrary(container: try PersistenceController.makeContainer(inMemory: true))
        _ = try library.createNote(title: "Unrelated note", body: "The boiler is below the window.")
        _ = try library.createNote(title: "House project", tags: ["boiler"])
        _ = try library.createNote(title: "Boiler parts")
        _ = try library.createNote(title: "Boiler")

        let result = PhoneSearchWaveIndex.search(
            "boiler", tasks: [], notes: try library.notes(), canvases: []
        )
        XCTAssertEqual(result.notes.map { $0.value.title },
                       ["Boiler", "Boiler parts", "House project", "Unrelated note"])
    }

    func testMultipleWordsRequireEveryTermAndHashTagsMatchOnlyTags() throws {
        let library = PhoneLibrary(container: try PersistenceController.makeContainer(inMemory: true))
        let house = try library.createNote(title: "Heating", body: "Boiler inspection", tags: ["house"])
        _ = try library.createNote(title: "Boiler invoice", body: "No house tag", tags: ["work"])
        _ = try library.createNote(title: "Unrelated", body: "Boiler inspection", tags: ["house"])

        let result = PhoneSearchWaveIndex.search(
            "boiler #Hou", tasks: [], notes: try library.notes(), canvases: []
        )
        XCTAssertEqual(Set(result.notes.map(\.id)), Set([
            house.note.id,
            try XCTUnwrap(library.notes().first(where: { $0.title == "Unrelated" })?.id)
        ]))
        XCTAssertEqual(PhoneSearchWaveIndex.search(
            "boiler #missing", tasks: [], notes: try library.notes(), canvases: []
        ).totalCount, 0)
    }

    func testEmptyQueriesAndUnmatchedQueriesHaveNoResults() throws {
        let library = PhoneLibrary(container: try PersistenceController.makeContainer(inMemory: true))
        _ = try library.createTask(title: "Boiler", status: .todo)
        let rows = try library.tasks()
        for query in ["", " \t ", "#", "unfindable"] {
            let results = PhoneSearchWaveIndex.search(query, tasks: rows, notes: [], canvases: [])
            XCTAssertEqual(results.totalCount, 0, query)
        }
    }

    func testHighlightsKeepOriginalSpellingAndUnicodeBoundaries() {
        let text = "☕️ Café and café. BOILER, boiler!"
        let fragments = PhoneSearchWaveHighlight.fragments(text, terms: ["cafe", "boiler"])
        XCTAssertEqual(fragments.map(\.text).joined(), text)
        XCTAssertEqual(fragments.filter(\.matched).map(\.text),
                       ["Café", "café", "BOILER", "boiler"])
        XCTAssertTrue(PhoneSearchWaveHighlight.fragments(text, terms: []).allSatisfy { !$0.matched })
    }
}
