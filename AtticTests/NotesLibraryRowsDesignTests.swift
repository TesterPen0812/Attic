import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The owner's panel design for All notes (2026-10-27/28, Notes rows
/// option 4a): rows with a page thumbnail, time · first #tag · snippet,
/// no task status; foldable sections; the "•••" menu; thumbnails drawn
/// once per note revision.
@MainActor
final class NotesLibraryRowsDesignTests: XCTestCase {
    private var store: NoteStore!

    override func setUp() async throws {
        store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
    }

    @discardableResult
    private func create(_ title: String, _ body: String = "", tags: [String] = []) throws -> UUID {
        let blocks: [NoteBlock] = body.isEmpty ? [.text(title)] : [.text(title), .text(body)]
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks),
                                                                   tags: tags.isEmpty ? nil : tags) else {
            throw NSError(domain: "create", code: 1)
        }
        return id
    }

    private func library() -> NotesLibraryModel { NotesLibraryModel(search: { _ in [] }, store: store) }

    // MARK: Line two

    func testTheRowShowsTheFirstTagSkippingTheFilteredOne() throws {
        XCTAssertEqual(NotesLibraryModel.firstTag(["launch", "work"], filter: nil), "launch")
        XCTAssertEqual(NotesLibraryModel.firstTag(["launch", "work"], filter: "launch"), "work")
        XCTAssertNil(NotesLibraryModel.firstTag(["launch"], filter: "launch"))
        XCTAssertNil(NotesLibraryModel.firstTag([], filter: nil))

        let id = try create("Launch plan", "Kyoto offsite agenda", tags: ["launch", "work"])
        let model = library()
        let row = try XCTUnwrap(model.groups(store: store, drafts: []).flatMap(\.rows).first { $0.id == id })
        var details = model.libraryRow(row, store: store)
        XCTAssertEqual(details.tag, "launch")
        XCTAssertEqual(details.row.preview, "Kyoto offsite agenda")
        XCTAssertEqual(details.thumbnail, NoteThumbnailContent(title: "Launch plan", text: "Kyoto offsite agenda", hasImages: false))
        model.tagFilter = "launch"
        details = model.libraryRow(row, store: store)
        XCTAssertEqual(details.tag, "work")
    }

    // MARK: Sections

    func testAFoldedSectionKeepsItsHeaderAndLeavesTheKeyboardsList() throws {
        let pinned = try create("Pinned note")
        let today = try create("Today note")
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let model = library()
        let groups = model.groups(store: store, drafts: [])
        XCTAssertEqual(groups.map(\.id), ["pinned", "today"])
        XCTAssertEqual(model.unfolded(groups).map(\.id), ["pinned", "today"])

        model.highlightedID = pinned
        model.toggleGroup("pinned", in: groups)
        XCTAssertEqual(model.foldedGroups, ["pinned"])
        XCTAssertNil(model.highlightedID, "a folded row can't keep the keyboard")
        XCTAssertEqual(model.unfolded(groups).map(\.id), ["today"])
        // The header still counts its rows.
        XCTAssertEqual(model.groups(store: store, drafts: []).map(\.id), ["pinned", "today"])

        model.moveHighlight(by: 1, in: model.unfolded(groups), from: nil)
        XCTAssertEqual(model.highlightedID, today)
        model.moveHighlight(by: -1, in: model.unfolded(groups), from: nil)
        XCTAssertEqual(model.highlightedID, today, "↑ never reaches a folded row")

        model.toggleGroup("pinned", in: groups)
        XCTAssertTrue(model.foldedGroups.isEmpty)
        XCTAssertEqual(model.highlightedID, today)
        XCTAssertEqual(model.orderedIDs(model.unfolded(groups)), [pinned, today])
    }

    // MARK: The "•••" menu

    func testTheHoverMenuUsesTheLibrarysOneItemCommands() {
        var ran: [String] = []
        let commands = [
            AtticMenuCommand("Open", identifier: "notes-row-open") { ran.append("open") },
            AtticMenuCommand("Pin to Top", identifier: "notes-row-pin") { ran.append("pin") },
            AtticMenuCommand("Add to Tasks", identifier: "one-item-add-to-tasks") { ran.append("convert") },
            AtticMenuCommand("Duplicate", identifier: NotesLibraryView.duplicateIdentifier) { ran.append("duplicate") },
            AtticMenuCommand("Delete", isDestructive: true, identifier: "notes-row-delete") { ran.append("delete") }
        ]
        let menu = NotesLibraryView.hoverMenu(commands, pinned: false)
        XCTAssertEqual(menu.map(\.title), ["Pin", "Add to Tasks", "Delete"])
        XCTAssertEqual(menu.map(\.identifier), ["notes-row-pin", "one-item-add-to-tasks", "notes-row-delete"])
        XCTAssertEqual(menu.map(\.isDestructive), [false, false, true])
        XCTAssertTrue(menu[2].startsSection)
        menu.forEach { $0.action() }
        XCTAssertEqual(ran, ["pin", "convert", "delete"], "each item runs the row's own command")

        let remove = AtticMenuCommand("Remove from Tasks", identifier: "one-item-remove-from-tasks") { ran.append("remove") }
        let task = NotesLibraryView.hoverMenu(commands.filter { $0.identifier != "one-item-add-to-tasks" } + [remove], pinned: true)
        XCTAssertEqual(task.map(\.title), ["Unpin", "Remove from Tasks", "Delete"])
        task[1].action()
        XCTAssertEqual(ran.last, "remove")
        let bare = NotesLibraryView.hoverMenu(commands.filter { $0.identifier != "one-item-add-to-tasks" }, pinned: false)
        XCTAssertEqual(bare.map(\.title), ["Pin", "Delete"])
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 36, modifiers: .command, characters: "\r",
                                                composing: false, fieldFocused: false), .open)
        XCTAssertEqual(NotesLibraryView.keyAction(keyCode: 36, modifiers: .command, characters: "\r",
                                                composing: true, fieldFocused: true), .passThrough)
    }

    // MARK: Thumbnails

    func testAThumbnailIsDrawnOncePerRevisionAndAppearance() throws {
        let cache = NoteThumbnailCache()
        let id = UUID()
        let content = NoteThumbnailContent(title: "Launch plan", text: "Kyoto offsite agenda and more", hasImages: true)
        let key = NoteThumbnailCache.Key(content: content, dark: false, scale: 2)
        XCTAssertNil(cache.cached(id, key: key), "a body only looks up")
        let image = try XCTUnwrap(cache.image(id, key: key))
        let m = NoteThumbnailMetrics.self
        XCTAssertEqual(image.width, Int((m.size.width + 2 * m.margin) * 2))
        XCTAssertEqual(image.height, Int((m.size.height + 2 * m.margin) * 2))
        XCTAssertEqual(cache.renderCount, 1)
        cache.image(id, key: key)
        XCTAssertNotNil(cache.cached(id, key: key))
        XCTAssertEqual(cache.renderCount, 1, "the same revision is never drawn again")

        let edited = NoteThumbnailCache.Key(content: NoteThumbnailContent(title: "Launch plan", text: "Changed", hasImages: true),
                                            dark: false, scale: 2)
        XCTAssertNil(cache.cached(id, key: edited))
        cache.image(id, key: edited)
        cache.image(id, key: NoteThumbnailCache.Key(content: edited.content, dark: true, scale: 2))
        XCTAssertEqual(cache.renderCount, 3)

        cache.keep(only: [])
        XCTAssertNil(cache.cached(id, key: edited), "a gone note's thumbnail goes")
    }

    // MARK: Geometry

    func testARowIsTheDesignsHeightWithItsThumbnailAndTwoLines() throws {
        let id = try create("Launch plan", "Kyoto offsite agenda", tags: ["launch"])
        let model = library()
        let row = try XCTUnwrap(model.groups(store: store, drafts: []).flatMap(\.rows).first { $0.id == id })
        let view = NotesLibraryRow(details: model.libraryRow(row, store: store), thumbnails: model.thumbnails,
                                   commands: { [] }, anchors: AtticNoteRowAnchors(), onShowActions: {}, onOpen: {})
            .frame(width: 300)
            .atticDesign(.default)
        let hosting = NSHostingView(rootView: view)
        // 12 px padding, the 60 px thumbnail, 12 px: 84 px.
        XCTAssertEqual(NotesLibraryRowMetrics.height, 42)
        XCTAssertEqual(hosting.fittingSize.height, 42, accuracy: 0.5)
    }
}
