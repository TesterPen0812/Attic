import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Phase 2 slice 4, find and organize: the tag filter and its top line
/// (recent tags, the active tag first), the filter's return rule, the
/// search's words inside a filter, query-created notes, the page's swipe
/// target, and the rows' derived summaries on a large library.
@MainActor
final class NotesLibraryOrganizeTests: XCTestCase {
    private var store: NoteStore!
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        directory = ownedTemporaryDirectory(prefix: "AtticOrganize")
        suiteName = "AtticOrganize-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeController() -> NotesPageController {
        NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                            defaults: defaults, saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
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

    private func settle(_ library: NotesLibraryModel) async {
        await library.waitForSearch()
    }

    private func ids(_ groups: [NotesLibraryModel.Group]) -> Set<UUID> { Set(groups.flatMap { $0.rows.map(\.id) }) }

    #if !ATTIC_GENERATED_TESTS
    func testSearchExcerptExplainsDeepBodyTitleAndTagMatches() async throws {
        let body = "A first paragraph that is irrelevant. Another section goes on and on. Finally orchid appears beside its context."
        let id = try create("Meeting notes", body, tags: ["botany"])
        let library = NotesLibraryModel(search: { [store] query in try await store!.searchNoteIDs(matching: query) }, store: store)
        library.query = "orchid"
        await library.waitForSearch()
        let result = try XCTUnwrap(library.groups(store: store, drafts: []).flatMap(\.rows).first { $0.id == id })
        XCTAssertTrue(result.preview.contains("orchid appears beside its context"))
        XCTAssertFalse(result.preview.hasPrefix("A first paragraph"))
        XCTAssertEqual(result.searchMatch, "orchid")
        XCTAssertTrue(result.spoken.contains("match:"), "VoiceOver explains why it matched")

        library.query = "Meeting"
        await library.waitForSearch()
        let title = try XCTUnwrap(library.groups(store: store, drafts: []).flatMap(\.rows).first { $0.id == id })
        XCTAssertTrue(title.preview.hasPrefix("Title: Meeting"))
        XCTAssertEqual(title.searchMatch, "Meeting")

        library.query = "botany"
        await library.waitForSearch()
        let tag = try XCTUnwrap(library.groups(store: store, drafts: []).flatMap(\.rows).first { $0.id == id })
        XCTAssertEqual(tag.preview, "#botany")
        XCTAssertEqual(tag.searchMatch, "botany")
        XCTAssertEqual(NoteSearchExcerpt.find(title: "", tags: [], body: "orchidology", files: [], query: "chid")?.text,
                       "orchidology", "substring matches keep their surrounding word")
    }
    #endif

    #if !ATTIC_GENERATED_TESTS
    func testSW03DeletedSummaryIsPrunedEvenWhenNoteCountIsUnchanged() throws {
        let first = try create("Old note", "Private old body")
        let controller = makeController()
        let model = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        _ = model.groups(store: store, drafts: [])
        XCTAssertNotNil(controller.librarySummaries.bodies[first])
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: first))))
        let replacement = try create("Replacement note", "Different body")
        _ = model.groups(store: store, drafts: [], prepareSummaries: false)
        XCTAssertNil(controller.librarySummaries.bodies[first], "Deletion must release old note bytes even if the note count stays equal")
        XCTAssertNotNil(store.note(withID: replacement))
    }
    #endif

    // MARK: The filter

    #if !ATTIC_GENERATED_TESTS
    func testATagFilterShowsOnlyItsNotesAndASearchLooksInsideIt() async throws {
        let launch = try create("Launch plan", "kyoto offsite", tags: ["launch"])
        let both = try create("Pricing", "kyoto pricing", tags: ["launch", "work"])
        let other = try create("Trip", "kyoto temples", tags: ["travel"])
        let untagged = try create("Groceries", "milk")
        let library = NotesLibraryModel(search: { [store] query in try await store!.searchNoteIDs(matching: query) },
                                        store: store)
        XCTAssertEqual(ids(library.groups(store: store, drafts: [])), [launch, both, other, untagged])

        library.tagPicks = TagPicks(["launch"])
        XCTAssertEqual(ids(library.groups(store: store, drafts: [])), [launch, both], "only the tag's notes")

        library.query = "kyoto"
        await settle(library)
        XCTAssertEqual(ids(library.groups(store: store, drafts: [])), [launch, both],
                       "a search inside a filter never shows a note outside it")
        library.tagPicks = .none
        XCTAssertEqual(ids(library.groups(store: store, drafts: [])), [launch, both, other],
                       "clearing the filter shows every match again, with no new search")
    }

    /// Review S4-R2: while the first search runs, the earlier rows stay,
    /// but never rows from another filter.
    func testAFilterChangeDuringTheFirstSearchNeverShowsTheOtherFiltersRows() throws {
        let tagged = try create("Tagged", tags: ["launch"])
        let plain = try create("Plain")
        let library = NotesLibraryModel(search: { _ in try await Task.sleep(for: .seconds(60)); return [] }, store: store)
        XCTAssertEqual(ids(library.groups(store: store, drafts: [])), [tagged, plain])
        library.query = "kyoto"
        XCTAssertEqual(ids(library.groups(store: store, drafts: [])), [tagged, plain], "earlier results stay meanwhile")
        library.tagPicks = TagPicks(["launch"])
        XCTAssertFalse(ids(library.groups(store: store, drafts: [])).contains(plain),
                       "a note outside the new filter is never shown")
        library.clearSearch()
    }

    func testChangingTheFilterDropsTheKeyboardsRow() throws {
        let a = try create("Alpha", tags: ["x"])
        try create("Beta")
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        library.highlightedID = a
        library.tagPicks = TagPicks(["x"])
        XCTAssertNil(library.highlightedID, "the rows change: ↑ ↓ start again")
    }

    func testTheTopLineLeadsWithTheActiveTagThenTheMostRecentOthers() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        store = try makeTestNoteStore(now: { clock }, attachmentFileStore: makeTestAttachmentFileStore())
        try create("Old", tags: ["archive"])
        clock += 60
        try create("Mid", tags: ["work", "home"])
        clock += 60
        try create("New", tags: ["launch"])
        let library = NotesLibraryModel(search: { _ in [] }, store: store)

        XCTAssertEqual(library.recentTags(store: store), ["launch", "home", "work", "archive"],
                       "by the latest edit of a note carrying the tag, ties by name")
        XCTAssertEqual(library.tagTabs(store: store, limit: 2), ["launch", "home"])
        library.tagPicks = TagPicks(["archive"])
        XCTAssertEqual(library.tagTabs(store: store, limit: 2), ["archive", "launch"],
                       "the active tag is always shown, right after All notes")
        library.toggleTag("archive")
        XCTAssertTrue(library.tagPicks.isEmpty, "choosing the active tag again shows every note")
        library.toggleTag("work")
        XCTAssertEqual(library.tagPicks, TagPicks(["work"]))
    }

    func testRecentTagsFollowAnEdit() throws {
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        let first = try create("First", tags: ["a"])
        try create("Second", tags: ["b"])
        XCTAssertEqual(library.recentTags(store: store).first, "b")
        let note = try XCTUnwrap(store.note(withID: first))
        XCTAssertTrue(store.setTags(["a", "c"], for: note))
        XCTAssertEqual(Set(library.recentTags(store: store)), ["a", "b", "c"], "a store change is read again")
    }

    func testOpeningAllNotesKeepsTheFilterOnlyWhenItShowsTheNoteYouCameFrom() throws {
        let tagged = try create("Tagged", tags: ["launch"])
        let plain = try create("Plain")
        let library = NotesLibraryModel(search: { _ in [] }, store: store)

        library.tagPicks = TagPicks(["launch"])
        library.reconcileFilter(store: store, selected: tagged)
        XCTAssertEqual(library.tagPicks, TagPicks(["launch"]), "the note you came from is shown: the filter stays")
        library.reconcileFilter(store: store, selected: nil)
        XCTAssertEqual(library.tagPicks, TagPicks(["launch"]), "from a new draft: the filter stays")
        library.reconcileFilter(store: store, selected: plain)
        XCTAssertTrue(library.tagPicks.isEmpty, "the filter would hide the note you came from: every note")

        library.tagPicks = TagPicks(["gone"])
        library.reconcileFilter(store: store, selected: nil)
        XCTAssertTrue(library.tagPicks.isEmpty, "no note carries the tag any more: every note")
    }

    func testShowingAllNotesFromAnUntaggedNoteResetsTheFilterBeforeTheListIsBuilt() async throws {
        let tagged = try create("Tagged", tags: ["launch"])
        let plain = try create("Plain")
        let controller = makeController()
        await controller.startAndWait()
        let library = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
        XCTAssertTrue(controller.open(noteID: tagged))
        XCTAssertTrue(controller.showLibrary())
        library.tagPicks = TagPicks(["launch"])
        controller.dismissLibrary()
        XCTAssertTrue(controller.showLibrary())
        XCTAssertEqual(library.tagPicks, TagPicks(["launch"]), "back from the tagged note: the filter is restored")
        controller.dismissLibrary()
        XCTAssertTrue(controller.open(noteID: plain))
        XCTAssertTrue(controller.showLibrary())
        XCTAssertTrue(library.tagPicks.isEmpty, "it would hide the note you came from: every note")
    }

    func testAFilterWithNoNotesLeftKeepsItsLineUntilYouLeave() throws {
        let only = try create("Only", tags: ["launch"])
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        library.tagPicks = TagPicks(["launch"])
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: only))))
        XCTAssertTrue(library.groups(store: store, drafts: []).isEmpty)
        XCTAssertEqual(library.tagPicks, TagPicks(["launch"]), "kept while All notes shows, so Undo brings the note back into it")
    }

    // MARK: Search reaches displayed dates

    /// A date chip shows a day ("1 Oct"), and the note stores it as an ISO
    /// day: a search that is a date finds the notes that carry that day.
    func testASearchThatIsADateFindsTheNotesWithThatDay() async throws {
        let day = try XCTUnwrap(NoteDay(year: 2026, month: 10, day: 1))
        var line = NoteBlock.text("Fly out \u{FFFC}")
        line.inlines = [NoteInline(id: UUID(), kind: .date(day))]
        let dated = NoteDocument(blocks: [.text("Offsite"), line])
        guard case let .success((withDate, _)) = store.createDocumentNote(id: UUID(), document: dated) else {
            return XCTFail("create")
        }
        let other = try create("Other", "nothing on 2 October")
        for query in ["1 October 2026", "October 1, 2026", "2026-10-01"] {
            let found = try await store.searchNoteIDs(matching: query)
            XCTAssertTrue(found.contains(withDate), "“\(query)” finds the note whose chip shows that day")
            XCTAssertFalse(found.contains(other), "“\(query)”: another day is not a match")
        }
        let words = try await store.searchNoteIDs(matching: "fly out")
        XCTAssertEqual(words, [withDate], "ordinary words still search the text")
    }

    /// Review S4-R4: a time reads as today, not a day searched for.
    func testATimeIsNotADaySearch() {
        for query in ["10:30", "2pm", "2 PM", "now", "noon", "tonight"] {
            XCTAssertNil(NoteStore.searchedDay(query), "“\(query)”")
        }
        XCTAssertEqual(NoteStore.searchedDay("1 October 2026")?.isoString, "2026-10-01")
        XCTAssertNotNil(NoteStore.searchedDay("tomorrow"))
        XCTAssertNil(NoteStore.searchedDay("meet on 1 October 2026"), "words around a date stay a text search")
    }

    func testARowsTagsMenuFiltersToATagAndTicksTheActiveOne() {
        var chosen: [String] = []
        let menu = NotesLibraryView.tagsSubmenu(tags: ["launch", "work"], picked: TagPicks(["work"])) { chosen.append($0) }
        XCTAssertEqual(menu.children.map(\.title), ["#launch", "#work"])
        XCTAssertEqual(menu.children.map(\.state), [nil, .on])
        menu.children[0].action()
        menu.children[1].action()
        // Several tags (Accepted 2026-11-13): each choice toggles its tag,
        // as its pill does.
        XCTAssertEqual(chosen, ["launch", "work"], "each choice toggles its tag in the pick")
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        library.tagPicks = TagPicks(["work"])
        for tag in chosen { library.toggleTag(tag) }
        XCTAssertEqual(library.tagPicks, TagPicks(["launch"]), "launch joins, the picked work leaves")
        XCTAssertTrue(NotesLibraryView.tagsSubmenu(tags: [], picked: .none) { _ in }.isDisabled, "no tags: dimmed")
    }

    // MARK: Words

    func testTheSearchWordsNameTheFilter() {
        XCTAssertEqual(NotesLibraryModel.placeholder(count: 13, tags: .none), "Search 13 notes")
        XCTAssertEqual(NotesLibraryModel.placeholder(count: 1, tags: .none), "Search 1 note")
        XCTAssertEqual(NotesLibraryModel.placeholder(count: 13, tags: TagPicks(["launch"])), "Search #launch")
        XCTAssertEqual(NotesLibraryModel.noMatches(query: "kyoto", tags: .none), "No notes match “kyoto”.")
        XCTAssertEqual(NotesLibraryModel.noMatches(query: "kyoto", tags: TagPicks(["launch"])), "No notes match “kyoto” in #launch.")
        XCTAssertEqual(NotesLibraryModel.newNoteTitle(query: "kyoto", tags: .none), "New note “kyoto”")
        XCTAssertEqual(NotesLibraryModel.newNoteTitle(query: "kyoto", tags: TagPicks(["launch"])), "New note “kyoto” in #launch")
        XCTAssertEqual(NotesLibraryModel.emptyFilter(tags: TagPicks(["launch"])), "No notes in #launch")
    }

    // MARK: Query-created notes

    func testANewNoteIsOfferedOnlyAfterASearchFinishedWithNothing() async throws {
        try create("Alpha")
        var fails = false
        let library = NotesLibraryModel(search: { query in
            if fails { throw NSError(domain: "search", code: 1) }
            return query == "alpha" ? Set(self.store.notes.map(\.id)) : []
        }, store: store)
        XCTAssertNil(library.queryForNewNote(in: []), "no search")
        library.query = "alpha"
        await settle(library)
        XCTAssertNil(library.queryForNewNote(in: library.groups(store: store, drafts: [])), "rows are shown")
        library.query = "  kyoto "
        await settle(library)
        XCTAssertEqual(library.queryForNewNote(in: library.groups(store: store, drafts: [])), "kyoto")
        fails = true
        library.query = "osaka"
        await settle(library)
        XCTAssertEqual(library.searchState, .failed(NSError(domain: "search", code: 1).localizedDescription))
        XCTAssertNil(library.queryForNewNote(in: library.groups(store: store, drafts: [])),
                     "Couldn't search is not No matches: never offer a note then")
    }

    func testANewNoteFromTheSearchHasItsTitleAndTheFiltersTagAndIsSaved() async throws {
        let controller = makeController()
        await controller.startAndWait()
        XCTAssertTrue(controller.showLibrary())
        XCTAssertTrue(controller.requestNewNote(title: "  kyoto ", tags: ["launch"]))
        XCTAssertFalse(controller.isLibraryPresented, "the new note shows")
        let session = try XCTUnwrap(controller.active)
        XCTAssertEqual(session.engine.document().title, "kyoto")
        XCTAssertEqual(session.engine.tags, ["launch"])
        XCTAssertFalse(session.isUntouchedDraft, "it is a real edit, never dropped as an empty draft")
        XCTAssertTrue(NoteSessionPolicy.hasPendingWork(session.state), "pending like typed text")

        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        let saved = try XCTUnwrap(store.note(withID: session.noteID))
        XCTAssertEqual(saved.title, "kyoto")
        XCTAssertEqual(saved.tags, ["launch"])
    }

    func testANewNoteFromTheSearchRefusesAnEmptyOrMultilineTitle() async {
        let controller = makeController()
        await controller.startAndWait()
        XCTAssertNotNil(controller.active)
        let before = controller.active?.noteID
        XCTAssertFalse(controller.requestNewNote(title: "   ", tags: []))
        XCTAssertFalse(controller.requestNewNote(title: "a\nb", tags: []))
        XCTAssertEqual(controller.active?.noteID, before, "nothing changed")
    }

    // MARK: Swipe

    func testThePageRegistersWithThePanelsSwipeRouter() {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var swipes = 0
        let view = NotesPageSwipeView(isLibraryPresented: false) { swipes += 1 }
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 332, height: 480))
        panel.contentView?.addSubview(view)
        XCTAssertTrue(panel.notesSwipeTarget === view)
        XCTAssertFalse(panel.notesSwipeTarget?.isNotesLibraryPresented ?? true)
        panel.notesSwipeTarget?.performNotesSwipe()
        XCTAssertEqual(swipes, 1)
        XCTAssertNil(view.hitTest(NSPoint(x: 1, y: 1)), "clicks go through to the page")
        view.removeFromSuperview()
        XCTAssertNil(panel.notesSwipeTarget, "a page that left unregisters")
    }

    /// Review S4-R5: another editor inside the Notes page registers over
    /// it; when it leaves, the page gets the slot back.
    func testAnInnerSwipeTargetHandsTheSlotBackWhenItLeaves() {
        let panel = AtticPanel(contentRect: CGRect(x: 0, y: 0, width: 332, height: 480),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 332, height: 480))
        let page = NotesPageSwipeView(isLibraryPresented: false) {}
        let inner = NotesPageSwipeView(isLibraryPresented: false) {}
        panel.contentView?.addSubview(page)
        panel.contentView?.addSubview(inner)
        XCTAssertTrue(panel.notesSwipeTarget === inner)
        inner.removeFromSuperview()
        XCTAssertTrue(panel.notesSwipeTarget === page, "the page swipes again")
        panel.contentView?.addSubview(inner)
        page.removeFromSuperview()
        XCTAssertTrue(panel.notesSwipeTarget === inner, "removing the covered page leaves the inner one")
        inner.removeFromSuperview()
        XCTAssertNil(panel.notesSwipeTarget, "a page no longer in the window never gets the slot back")
    }
    #endif

    // MARK: Derived summaries on a large library

    /// The rows' summaries are read once per note revision: a rebuild after
    /// one save decodes that note only, and the cached rows answer at once.
    /// Timings are printed for the report (a measured baseline, not a gate).
    #if ATTIC_GENERATED_TESTS
    func testALargeLibraryDecodesEachNoteOnceAndOneSaveRereadsOnlyItself() async throws {
        let count = 2_000
        let tags = ["launch", "work", "home", "travel", "reading", "ideas"]
        var first: UUID?
        for index in 0..<count {
            let id = try create("Note \(index)", "Body line for note \(index) with kyoto \(index % 7)",
                                tags: [tags[index % tags.count]])
            if first == nil { first = id }
        }
        XCTAssertEqual(store.notes.count, count)

        let library = NotesLibraryModel(search: { [store] query in try await store!.searchNoteIDs(matching: query) },
                                        store: store)
        let clock = ContinuousClock()
        var groups: [NotesLibraryModel.Group] = []
        let cold = clock.measure { groups = library.groups(store: store, drafts: []) }
        XCTAssertEqual(groups.reduce(0) { $0 + $1.rows.count }, count)
        XCTAssertEqual(library.bodyDecodeCount, count, "each note's body is decoded once")
        let warm = clock.measure { _ = library.groups(store: store, drafts: []) }
        XCTAssertEqual(library.bodyDecodeCount, count, "the cached rows decode nothing")

        let firstID = try XCTUnwrap(first)
        let note = try XCTUnwrap(store.note(withID: firstID))
        XCTAssertTrue(store.setTags(["launch", "edited"], for: note))
        let afterTags = clock.measure { _ = library.groups(store: store, drafts: []) }
        XCTAssertEqual(library.bodyDecodeCount, count, "a tag change re-reads no body")

        library.tagPicks = TagPicks(["launch"])
        let filtered = clock.measure { groups = library.groups(store: store, drafts: []) }
        XCTAssertEqual(groups.reduce(0) { $0 + $1.rows.count }, count / tags.count + (count % tags.count > 0 ? 1 : 0))
        let recent = clock.measure { _ = library.recentTags(store: store) }

        let searchStart = clock.now
        library.query = "kyoto 3"
        await library.waitForSearch()
        let search = clock.now - searchStart
        XCTAssertNotNil(library.matches)

        print("ATTIC-S4-PROFILE notes=\(count) cold=\(cold) warm=\(warm) afterTagChange=\(afterTags) "
              + "filtered=\(filtered) recentTags=\(recent) searchIncludingDebounce=\(search)")
    }
    #endif
}
