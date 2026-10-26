import AppKit
import SwiftData
import XCTest
@testable import Attic

/// The Reminders replica, slice R2 (owner, 2026-10-26: "add flag and link
/// field, skip urgent and sections, go ahead with rest"): the detail
/// panel's staged edits, photos, tags, editing a title in place and
/// Tab/⇧Tab.
@MainActor
final class RemindersReplicaR2Tests: XCTestCase {
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000)) // Mon 21 Sep 2026, UTC
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value },
            calendar: { calendar },
            locale: Locale(identifier: "en_GB"),
            doneHold: .seconds(3_600)
        ))
        model.toasts.holdDuration = 3_600
        model.setListStyle(.reminders)
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private var today: DueDay { DueDay(date: clock.value, calendar: calendar) }

    private func add(_ title: String) throws -> UUID {
        model.addBar.text = title
        return try XCTUnwrap(model.submitAddBar())
    }

    // MARK: The panel's staged edits

    func testThePanelOpensOnATaskWithWhatItHolds() throws {
        let a = try add("Send the invoice")
        XCTAssertTrue(model.setPriority(.medium, for: [a]).isApplied)
        model.openReplicaDetail(a)
        let detail = try XCTUnwrap(model.replicaDetail)
        XCTAssertEqual(detail.taskID, a)
        XCTAssertEqual(detail.draft.title, "Send the invoice")
        XCTAssertEqual(detail.draft.priority, .medium)
        XCTAssertEqual(detail.draft.list, .now)
        XCTAssertFalse(detail.notesExpanded, "Notes & URL starts collapsed (R2-08)")
    }

    func testThePanelOnlyOpensWhileTheReplicaDraws() throws {
        let a = try add("A")
        model.setListStyle(.attic)
        model.openReplicaDetail(a)
        XCTAssertNil(model.replicaDetail, "Attic's style keeps its item page")
    }

    func testClosingCommitsEveryStagedEditAsOneUndoStep() throws {
        let a = try add("Draft")
        model.openReplicaDetail(a)
        let detail = try XCTUnwrap(model.replicaDetail)
        detail.draft.title = "  Final   title "
        detail.draft.setHasDate(true, today: today)
        detail.draft.priority = .high
        detail.draft.list = .later
        detail.draft.addTag("#Home")
        XCTAssertEqual(store.task(withID: a)?.title, "Draft", "nothing is saved while the panel is open")
        XCTAssertTrue(model.closeReplicaDetail().isApplied)
        let task = try XCTUnwrap(store.task(withID: a))
        XCTAssertEqual(task.title, "Final title")
        XCTAssertEqual(task.dueDay, today, "the Date switch picks today")
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.status, .backlog, "List › Later")
        XCTAssertEqual(task.tags, ["home"])
        XCTAssertNil(model.replicaDetail)
        XCTAssertTrue(model.undo().isApplied)
        let undone = try XCTUnwrap(store.task(withID: a))
        XCTAssertEqual(undone.title, "Draft", "one Undo takes every field back")
        XCTAssertNil(undone.dueDay)
        XCTAssertEqual(undone.priority, .none)
        XCTAssertEqual(undone.status, .todo)
        XCTAssertEqual(undone.tags, [])
    }

    func testEscapeCancelsAndSavesNothing() throws {
        let a = try add("Keep me")
        model.openReplicaDetail(a)
        let detail = try XCTUnwrap(model.replicaDetail)
        detail.draft.title = "Changed"
        detail.draft.priority = .low
        model.cancelReplicaDetail()
        XCTAssertNil(model.replicaDetail)
        XCTAssertEqual(store.task(withID: a)?.title, "Keep me")
        XCTAssertEqual(store.task(withID: a)?.priority, TaskPriority.none)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertNil(store.task(withID: a), "the last step is still the add: the panel recorded none")
    }

    func testAnUnchangedPanelWritesNothing() throws {
        let a = try add("Same")
        let draft = RemindersReplicaDetailDraft(task: try XCTUnwrap(store.task(withID: a)))
        XCTAssertNil(draft.patch(from: draft))
        var blank = draft
        blank.title = "   "
        XCTAssertNil(blank.patch(from: draft), "an emptied title keeps the one it had")
    }

    func testEditsFlowBackToTheRow() throws {
        let a = try add("Row")
        model.openReplicaDetail(a)
        model.replicaDetail?.draft.priority = .high
        model.replicaDetail?.draft.setHasDate(true, today: today)
        model.closeReplicaDetail()
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == a })
        XCTAssertEqual(row.model.priority, .high)
        XCTAssertEqual(model.replicaDateLine(for: a)?.text, "Today")
    }

    func testOpeningAnotherTaskCommitsTheFirst() throws {
        let a = try add("A"), b = try add("B")
        model.openReplicaDetail(a)
        model.replicaDetail?.draft.title = "A2"
        model.openReplicaDetail(b)
        XCTAssertEqual(store.task(withID: a)?.title, "A2")
        XCTAssertEqual(model.replicaDetail?.taskID, b)
    }

    func testLeavingTheReplicaClosesThePanel() throws {
        let a = try add("A")
        model.openReplicaDetail(a)
        model.replicaDetail?.draft.title = "A2"
        model.setListStyle(.attic)
        XCTAssertNil(model.replicaDetail)
        XCTAssertEqual(store.task(withID: a)?.title, "A2", "closing by any route but Escape commits")
    }

    func testAFinishedTaskKeepsItsList() throws {
        let a = try add("Done one")
        XCTAssertTrue(model.complete(a).isApplied)
        model.openReplicaDetail(a)
        let detail = try XCTUnwrap(model.replicaDetail)
        XCTAssertTrue(detail.draft.isDone)
        detail.draft.list = .later
        model.closeReplicaDetail()
        XCTAssertEqual(store.task(withID: a)?.status, .done, "moving it would reopen it")
    }

    // MARK: Tags

    func testTagsAreEditedInThePanel() throws {
        var draft = RemindersReplicaDetailDraft(title: "T", dueDay: nil, priority: .none, status: .todo, tags: ["work"])
        XCTAssertTrue(draft.addTag("#Errands"))
        XCTAssertFalse(draft.addTag("errands"), "kept once")
        XCTAssertFalse(draft.addTag("   "))
        draft.removeTag("WORK")
        XCTAssertEqual(draft.tags, ["errands"])
    }

    func testATagFiltersTheListThroughFind() throws {
        let a = try add("Tagged #home")
        _ = try add("Other")
        model.openReplicaDetail(a)
        model.replicaDetail?.draft.title = "Tagged two"
        model.filterReplicaByTag("home")
        XCTAssertNil(model.replicaDetail, "the panel closes")
        XCTAssertEqual(store.task(withID: a)?.title, "Tagged two", "and its edits are kept")
        XCTAssertEqual(model.searchQuery(for: .now), "#home")
        XCTAssertEqual(model.sections(for: .now).open.map(\.id), [a], "only the tagged task shows")
    }

    // MARK: Links in the writing

    func testLinksInTheWritingAreFound() {
        let text = "Study notes https://example.com/notes and ftp://example.com/x"
        let links = RemindersReplicaText.links(in: text)
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://example.com/notes"], "only web links")
        let attributed = RemindersReplicaText.linkedNotes(text)
        XCTAssertTrue(attributed.runs.contains { $0.link?.absoluteString == "https://example.com/notes" })
    }

    // MARK: Photos

    func testThumbnailSizesFollowTheGenerator() {
        let s = RemindersReplicaPhotoSizing.self
        let image = CGSize(width: 800, height: 500)
        let detail = s.fillSize(original: image, box: s.detail)
        XCTAssertEqual(detail.width, 46.4, accuracy: 0.001)
        XCTAssertEqual(detail.height, 29, accuracy: 0.001)
        let list = s.fillSize(original: image, box: s.list)
        XCTAssertEqual(list.width, 492.8, accuracy: 0.001)
        XCTAssertEqual(list.height, 308, accuracy: 0.001)
        XCTAssertEqual(s.generatedSize(original: image, box: s.detail, scale: 2), CGSize(width: 46, height: 29), "truncated to the 2x grid")
        XCTAssertEqual(s.generatedSize(original: image, box: s.list, scale: 2), CGSize(width: 492.5, height: 308))
        XCTAssertEqual(s.generatedSize(original: image, box: s.detail, scale: 0), CGSize(width: 46, height: 29), "a zero scale counts as 1")
        let tall = s.fillSize(original: CGSize(width: 100, height: 10_000), box: s.detail)
        XCTAssertEqual(max(tall.width, tall.height), 100, accuracy: 0.001, "the longest edge is capped")
    }

    func testTheRowCarriesTheWritingsPhotoCountOnlyWhileOn() throws {
        let a = try add("With a photo")
        model.setNotePhotoCounts([a: 2])
        XCTAssertEqual(model.rows(for: .now).first?.model.photos, 2)
        model.setListStyle(.attic)
        XCTAssertEqual(model.rows(for: .now).first?.model.photos, 0, "Attic's rows are unchanged")
    }

    func testPhotosComeFromTheWritingThroughItsServices() async throws {
        let a = try add("Photos")
        let photo = RemindersReplicaPhoto(id: UUID(), filename: "neutral.png", source: .note(UUID()))
        var removed: [(UUID, UUID)] = []
        var chosen: [UUID] = []
        model.services.notePhotos = { id in id == a ? [photo] : [] }
        model.services.removeNotePhoto = { task, attachment in removed.append((task, attachment)); return true }
        model.services.chooseImagesForNote = { chosen.append($0) }
        XCTAssertEqual(model.replicaPhotos(for: a), [photo])
        XCTAssertTrue(model.canAddReplicaPhoto)
        model.addReplicaPhoto(to: a)
        XCTAssertEqual(chosen, [a], "Add Photo… goes through Add Files…' producer")
        let done = await model.removeReplicaPhoto(photo, from: a)
        XCTAssertTrue(done)
        XCTAssertEqual(removed.first?.0, a)
        if case let .note(attachment) = photo.source { XCTAssertEqual(removed.first?.1, attachment) }
    }

    // MARK: Editing a title in place

    func testClickingATitleEditsItInPlace() throws {
        let a = try add("Rename me")
        XCTAssertTrue(model.editReplicaTitle(a))
        XCTAssertEqual(model.editingTitleID, a)
        XCTAssertEqual(model.selection, [a])
        model.titleEdit.text = "Renamed"
        XCTAssertTrue(model.commitTitle())
        XCTAssertEqual(store.task(withID: a)?.title, "Renamed")
        model.setListStyle(.attic)
        XCTAssertFalse(model.editReplicaTitle(a), "only while the replica draws")
    }

    // MARK: Tab and ⇧Tab

    func testTabKeys() {
        XCTAssertEqual(RemindersReplicaIndent.command(keyCode: 48, modifiers: []), .indent)
        XCTAssertEqual(RemindersReplicaIndent.command(keyCode: 48, modifiers: .shift), .outdent)
        XCTAssertNil(RemindersReplicaIndent.command(keyCode: 48, modifiers: .command))
        XCTAssertNil(RemindersReplicaIndent.command(keyCode: 36, modifiers: []))
    }

    func testShiftTabMakesASubtaskATaskAgain() throws {
        let parent = try add("Parent")
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", status: .todo, parentID: parent)])?.first?.id)
        model.replicaSubtaskSelection = child
        XCTAssertEqual(model.replicaIndent(.outdent, row: parent), .done(.applied))
        XCTAssertNil(store.task(withID: child)?.parentID, "Make Standalone Task")
        XCTAssertNil(model.replicaSubtaskSelection)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: child)?.parentID, parent, "one Undo puts it back")
    }

    func testTabSaysWhyItCantNest() throws {
        let above = try add("Above")
        let row = try add("Row")
        _ = above
        guard case .refused = model.replicaIndent(.indent, row: row) else { return XCTFail("a task can't become a subtask") }
        XCTAssertNil(store.task(withID: row)?.parentID)
        let child = try XCTUnwrap(library.createTasks([TaskDraft(title: "Child", status: .todo, parentID: above)])?.first?.id)
        model.replicaSubtaskSelection = child
        guard case .refused = model.replicaIndent(.indent, row: nil) else { return XCTFail("subtasks are one level") }
        XCTAssertEqual(store.task(withID: child)?.parentID, above)
    }

    // MARK: Flag and link (on the storage branch's fields)

    func testThePanelSavesTheFlagAndLinkWithTheRest() throws {
        let a = try add("Flag me")
        model.openReplicaDetail(a)
        let detail = try XCTUnwrap(model.replicaDetail)
        XCTAssertFalse(detail.draft.isFlagged)
        detail.draft.isFlagged = true
        detail.draft.url = "  HTTPS://Example.com/study-r2 "
        detail.draft.priority = .low
        XCTAssertEqual(detail.draft.urlHost, "example.com", "the chip's domain")
        XCTAssertTrue(model.closeReplicaDetail().isApplied)
        let task = try XCTUnwrap(store.task(withID: a))
        XCTAssertTrue(task.isFlagged)
        XCTAssertEqual(task.url, "https://example.com/study-r2")
        let row = try XCTUnwrap(model.rows(for: .now).first { $0.id == a })
        XCTAssertTrue(row.model.flagged, "the row's flag")
        XCTAssertEqual(row.model.linkHost, "example.com", "the row's link marker")
        XCTAssertTrue(model.undo().isApplied)
        let undone = try XCTUnwrap(store.task(withID: a))
        XCTAssertFalse(undone.isFlagged, "one Undo, flag and link included")
        XCTAssertNil(undone.url)
        XCTAssertEqual(undone.priority, .none)
    }

    func testARefusedLinkIsNotSavedButTheRestIs() throws {
        let a = try add("Bad link")
        model.openReplicaDetail(a)
        let detail = try XCTUnwrap(model.replicaDetail)
        detail.draft.url = "ftp://example.com/file"
        detail.draft.title = "Bad link kept"
        XCTAssertNotNil(detail.draft.urlProblem, "Attic's own refusal shows under the field")
        XCTAssertTrue(model.closeReplicaDetail().isApplied)
        XCTAssertEqual(store.task(withID: a)?.title, "Bad link kept")
        XCTAssertNil(store.task(withID: a)?.url)
        XCTAssertNotNil(model.toasts.current, "the toast says the link was not saved")
    }

    func testClearingTheLinkRemovesIt() throws {
        let a = try add("Linked")
        XCTAssertTrue(library.updateTask(a, url: .some("https://example.com")).isApplied)
        model.openReplicaDetail(a)
        model.replicaDetail?.draft.url = "  "
        model.closeReplicaDetail()
        XCTAssertNil(store.task(withID: a)?.url)
    }

    func testFlagFromTheMenuIsOneStepAndOnlyWhileOn() throws {
        let a = try add("Menu flag")
        XCTAssertTrue(model.setReplicaFlag(true, for: a).isApplied)
        XCTAssertEqual(store.task(withID: a)?.isFlagged, true)
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(store.task(withID: a)?.isFlagged, false)
        XCTAssertTrue(model.setReplicaFlag(true, for: a).isApplied)
        model.setListStyle(.attic)
        XCTAssertFalse(model.rows(for: .now).first { $0.id == a }?.model.flagged ?? true, "Attic's rows are unchanged")
    }

    // MARK: Menu

    func testShowInfoHeadsTheReplicaMenu() {
        XCTAssertEqual(RemindersReplicaMenu.commands(removeFromTasks: false),
                       [.showInfo, .complete, .date, .flag, .priority, .list, .tags, .copy, .delete],
                       "Flag in its measured place (CUA2-10)")
    }
}
