import SwiftData
import XCTest
@testable import Attic

/// Phase 1 Settings: the Recently Deleted page (its words, its model and
/// the store's Empty), Haptics, and the Settings agent tools.
@MainActor
final class SettingsPhase1Tests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()

    private struct Fixture {
        let clock: MutableNow
        let container: ModelContainer
        let tasks: TaskStore
        let notes: NoteStore
        let canvases: CanvasStore
        let library: AtticLibrary
    }

    private func makeFixture(start: Date = Date(timeIntervalSince1970: 1_000_000)) throws -> Fixture {
        let clock = MutableNow(start)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, now: { clock.value }, attachmentFileStore: makeTestAttachmentFileStore())
        let canvases = CanvasStore(container: container, now: { clock.value })
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        return Fixture(clock: clock, container: container, tasks: tasks, notes: notes, canvases: canvases, library: library)
    }

    // MARK: - Presentation

    func testDeletedPhrasesCountCalendarDaysNotHours() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 9))!
        let lateYesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 23))!
        let earlyToday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 0, minute: 5))!
        let lastWeek = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12))!
        XCTAssertEqual(RecentlyDeletedPresentation.deletedPhrase(earlyToday, now: now, calendar: calendar), "Deleted today")
        XCTAssertEqual(RecentlyDeletedPresentation.deletedPhrase(lateYesterday, now: now, calendar: calendar), "Deleted yesterday")
        XCTAssertEqual(RecentlyDeletedPresentation.deletedPhrase(lastWeek, now: now, calendar: calendar), "Deleted 7 days ago")
        // A clock that moved back never says "-1 days".
        XCTAssertEqual(RecentlyDeletedPresentation.deletedPhrase(now.addingTimeInterval(86_400), now: now, calendar: calendar), "Deleted today")

        XCTAssertNil(RecentlyDeletedPresentation.includedPhrase(kind: .task, count: 0))
        XCTAssertEqual(RecentlyDeletedPresentation.includedPhrase(kind: .task, count: 1), "with 1 subtask")
        XCTAssertEqual(RecentlyDeletedPresentation.includedPhrase(kind: .task, count: 3), "with 3 subtasks")
        XCTAssertEqual(RecentlyDeletedPresentation.includedPhrase(kind: .note, count: 2), "with 2 attachments")
        XCTAssertNil(RecentlyDeletedPresentation.includedPhrase(kind: .canvas, count: 4))
        XCTAssertEqual(RecentlyDeletedPresentation.displayTitle("  ", kind: .note), "Untitled note")
        XCTAssertEqual(RecentlyDeletedPresentation.countPhrase(1), "1 item")
        XCTAssertEqual(RecentlyDeletedPresentation.countPhrase(12), "12 items")
        XCTAssertEqual(RecentlyDeletedPresentation.emptyConfirmation(count: 3),
                       "3 items will be removed for good. You can’t undo this.")
        XCTAssertNil(RecentlyDeletedPresentation.keptMessage(kept: 0))
        XCTAssertTrue(RecentlyDeletedPresentation.keptMessage(kept: 2)?.hasPrefix("2 items were kept") == true)
    }

    func testSectionsGroupByKindNewestFirstAndSearchTitlesAndOwners() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let taskA = DeletedItemSummary(ref: AtticItemRef(.task, UUID()), title: "Email beta testers", deletedAt: now.addingTimeInterval(-60),
                                       includedCount: 2, retentionStart: now)
        let taskB = DeletedItemSummary(ref: AtticItemRef(.task, UUID()), title: "Book dentist", deletedAt: now.addingTimeInterval(-10),
                                       includedCount: 0, retentionStart: now)
        let note = DeletedItemSummary(ref: AtticItemRef(.note, UUID()), title: "", deletedAt: now.addingTimeInterval(-5),
                                      includedCount: 1, retentionStart: now)
        let canvas = DeletedItemSummary(ref: AtticItemRef(.canvas, UUID()), title: "Board", deletedAt: now,
                                        includedCount: 0, retentionStart: nil)
        let ownerID = UUID()
        let file = DeletedAttachmentSummary(attachmentID: UUID(), owner: AtticItemRef(.task, ownerID),
                                            filename: "brief.pdf", deletedAt: now.addingTimeInterval(-1))
        let entries = RecentlyDeletedPresentation.entries(
            items: [taskA, taskB, note, canvas], attachments: [file],
            ownerTitle: { $0.id == ownerID ? "Launch plan" : nil }, now: now, calendar: calendar
        )
        let sections = RecentlyDeletedPresentation.sections(entries, query: "")
        XCTAssertEqual(sections.map(\.kind), [.task, .note, .canvas, .attachment])
        XCTAssertEqual(sections[0].entries.map(\.title), ["Book dentist", "Email beta testers"], "newest deletion first")
        XCTAssertEqual(sections[0].entries[1].detail, "Deleted today · with 2 subtasks")
        XCTAssertEqual(sections[1].entries.first?.title, "Untitled note")
        XCTAssertEqual(sections[3].entries.first?.detail, "From “Launch plan” · Deleted today")

        XCTAssertEqual(RecentlyDeletedPresentation.sections(entries, query: "dentist").flatMap(\.entries).map(\.title), ["Book dentist"])
        XCTAssertEqual(RecentlyDeletedPresentation.sections(entries, query: "launch").flatMap(\.entries).map(\.title), ["brief.pdf"],
                       "a file is found by its task")
        XCTAssertEqual(RecentlyDeletedPresentation.sections(entries, query: "  BOARD ").flatMap(\.entries).map(\.kind), [.canvas])
        XCTAssertTrue(RecentlyDeletedPresentation.sections(entries, query: "nothing like this").isEmpty)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "every entry has its own identity")
    }

    // MARK: - Model

    func testModelListsRestoresAndUndoesARestore() throws {
        let fixture = try makeFixture()
        let task = try XCTUnwrap(fixture.tasks.create(title: "Plan the launch"))
        XCTAssertNotNil(fixture.tasks.create(title: "Write copy", parentID: task.id))
        let note = try XCTUnwrap(fixture.notes.create(title: "Meeting notes"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, task.id)))
        fixture.clock.value += 1
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.note, note.id)))

        let model = RecentlyDeletedModel(library: fixture.library, now: { fixture.clock.value }, calendar: calendar)
        model.start()
        defer { model.stop() }
        XCTAssertEqual(model.sections.map(\.kind), [.task, .note])
        XCTAssertEqual(model.entries.first { $0.kind == .task }?.detail, "Deleted today · with 1 subtask")

        let taskEntry = try XCTUnwrap(model.entries.first { $0.kind == .task })
        model.restore(taskEntry)
        XCTAssertNil(model.message)
        XCTAssertNotNil(fixture.tasks.task(withID: task.id), "the task is back in its list")
        XCTAssertEqual(fixture.tasks.subtasks(of: task.id).count, 1, "with its subtask")
        XCTAssertEqual(model.entries.map(\.kind), [.note])

        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertNil(fixture.tasks.task(withID: task.id), "⌘Z sends the restored task back")
        XCTAssertEqual(Set(model.entries.map(\.kind)), [.task, .note])
    }

    func testAFailedRestoreSaysWhyAndKeepsTheEntry() throws {
        let fixture = try makeFixture()
        let parent = try XCTUnwrap(fixture.tasks.create(title: "Parent"))
        let child = try XCTUnwrap(fixture.tasks.create(title: "Child", parentID: parent.id))
        // The subtask goes first on its own, then its parent: the subtask
        // can only come back under a live parent.
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, child.id)))
        fixture.clock.value += 1
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, parent.id)))

        let model = RecentlyDeletedModel(library: fixture.library, now: { fixture.clock.value }, calendar: calendar)
        model.reload()
        let childEntry = try XCTUnwrap(model.entries.first { $0.title == "Child" })
        model.restore(childEntry)
        XCTAssertEqual(model.message?.tone, .error)
        XCTAssertTrue(model.message?.text.contains("“Child” couldn’t be restored") == true)
        XCTAssertTrue(model.entries.contains { $0.title == "Child" })
        model.dismissMessage()
        XCTAssertNil(model.message)
    }

    func testEmptyRemovesWhatWasListedForGoodAndKeepsLaterDeletes() throws {
        let fixture = try makeFixture()
        let task = try XCTUnwrap(fixture.tasks.create(title: "Old task"))
        let note = try XCTUnwrap(fixture.notes.create(title: "Old note"))
        XCTAssertNotNil(fixture.canvases.createCanvas(name: "Keep"))
        let board = try XCTUnwrap(fixture.canvases.createCanvas(name: "Board"))
        for ref in [AtticItemRef(.task, task.id), AtticItemRef(.note, note.id), AtticItemRef(.canvas, board.id)] {
            XCTAssertTrue(fixture.library.delete(ref))
        }
        // A canvas deleted by a version before Recently Deleted existed:
        // Empty removes it too (the daily cleanup would only start its 30 days).
        let legacyID = UUID()
        let seed = ModelContext(fixture.container)
        seed.insert(CanvasBoardItem(id: legacyID, name: "Legacy", sortIndex: 9, tombstoned: true,
                                    deletedAt: Date(timeIntervalSince1970: 1)))
        try seed.save()

        let model = RecentlyDeletedModel(library: fixture.library, now: { fixture.clock.value }, calendar: calendar)
        model.reload()
        XCTAssertEqual(model.entries.count, 4)

        // The person confirms; something is deleted after that moment.
        fixture.clock.value += 10
        let confirmedAt = fixture.clock.value
        fixture.clock.value += 10
        let late = try XCTUnwrap(fixture.tasks.create(title: "Deleted after confirming"))
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, late.id)))

        model.empty(confirmedAt: confirmedAt)

        XCTAssertNil(model.message, "everything listed went")
        XCTAssertEqual(model.entries.map(\.title), ["Deleted after confirming"], "a later delete is never taken")
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, task.id)), .missing)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.note, note.id)), .missing)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.canvas, board.id)), .missing)
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.canvas, legacyID)), .missing)
        XCTAssertFalse(fixture.library.restore(AtticItemRef(.task, task.id)), "gone for good")
        XCTAssertEqual(fixture.library.state(of: AtticItemRef(.task, late.id)), .deleted)
    }

    func testEmptyKeepsItemsWhoseCopiesDisagreeAndSaysSo() throws {
        let fixture = try makeFixture()
        let seed = ModelContext(fixture.container)
        let task = TaskItem(title: "Twice")
        seed.insert(task)
        try seed.save()
        fixture.tasks.refresh()
        XCTAssertTrue(fixture.library.delete(AtticItemRef(.task, task.id)))
        // A second physical copy of the deleted task that differs (an old
        // sync leftover): the purge must not guess which one is right.
        let rows = try ModelContext(fixture.container).fetch(FetchDescriptor<TaskItem>())
        let deleted = try XCTUnwrap(rows.first)
        let replica = TaskItem(id: task.id, title: "Twice, edited elsewhere")
        replica.deletedAt = deleted.deletedAt
        replica.deletionRootID = deleted.deletionRootID
        replica.deletionMembersRaw = deleted.deletionMembersRaw
        let context = ModelContext(fixture.container)
        context.insert(replica)
        try context.save()

        let model = RecentlyDeletedModel(library: fixture.library, now: { fixture.clock.value }, calendar: calendar)
        model.reload()
        XCTAssertEqual(model.entries.count, 1)
        fixture.clock.value += 5
        model.empty(confirmedAt: fixture.clock.value)

        XCTAssertEqual(model.entries.count, 1, "kept")
        XCTAssertEqual(model.message?.tone, .warning)
        XCTAssertEqual(try ModelContext(fixture.container).fetchCount(FetchDescriptor<TaskItem>()), 2, "no copy removed")
    }

    func testRemovedTaskFilesAreListedUnderTheirTaskAndComeBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticSettingsRD-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("brief.txt")
        try Data("brief".utf8).write(to: source)
        let container = try PersistenceController.makeContainer(inMemory: true)
        let tasks = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("storage")))
        let library = AtticLibrary(tasks: tasks)
        let task = try XCTUnwrap(tasks.create(title: "Launch plan"))
        let attached = await tasks.attachFiles([source], to: task.id)
        XCTAssertTrue(attached)
        let file = try XCTUnwrap(tasks.task(withID: task.id)?.attachments.first)
        XCTAssertTrue(tasks.removeAttachment(file.id, from: task.id))

        let model = RecentlyDeletedModel(library: library, calendar: calendar)
        model.reload()
        let entry = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(entry.kind, .attachment)
        XCTAssertTrue(entry.detail.hasPrefix("From “Launch plan”"))
        XCTAssertEqual(model.sections(matching: "launch").count, 1)

        model.restore(entry)
        XCTAssertNil(model.message)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(tasks.task(withID: task.id)?.attachments.map(\.id), [file.id])
    }

    func testTheModelReadsNothingWithoutALibrary() {
        let model = RecentlyDeletedModel(library: nil)
        model.start()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.canUndo)
        model.empty(confirmedAt: Date())
        XCTAssertNil(model.message)
    }

    // MARK: - Haptics

    func testHapticsIsOnForFreshInstallsAndRemembered() throws {
        let suite = "SettingsPhase1Tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.hapticsEnabled)
        settings.hapticsEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).hapticsEnabled)
    }

    // MARK: - Agent tools

    private func makeSettingsTools(loginItem: AgentSettingsTools.LoginItem? = nil) throws -> (AgentSettingsTools, AppSettings, () -> Void) {
        let suite = "SettingsPhase1Tools-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        return (AgentSettingsTools(settings: settings, loginItem: loginItem), settings, { defaults.removePersistentDomain(forName: suite) })
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testGetSettingsReportsEverySettingButAgentAccess() throws {
        var launchAtLogin = false
        let (tools, settings, cleanUp) = try makeSettingsTools(loginItem: .init(
            isEnabled: { launchAtLogin }, setEnabled: { launchAtLogin = $0 }
        ))
        defer { cleanUp() }
        settings.isAgentAccessEnabled = true
        let result = try object(tools.call(name: "get_settings", arguments: [:]))
        XCTAssertEqual(Set(result.keys), [
            "appearance", "palette", "surface", "tint", "tint_length", "reveal_corner", "reveal_delay",
            "hide_delay", "corner_size", "panel_width", "haptics", "launch_at_login"
        ])
        XCTAssertEqual(result["corner_size"] as? Double, 52)
        XCTAssertEqual(result["haptics"] as? Bool, true)
        XCTAssertEqual(result["launch_at_login"] as? Bool, false)
        XCTAssertThrowsError(try tools.call(name: "get_settings", arguments: ["palette": "amethyst"]))
    }

    func testUpdateSettingsChangesWhatItIsGivenAndClampsLikeSettings() throws {
        var launchAtLogin = false
        let (tools, settings, cleanUp) = try makeSettingsTools(loginItem: .init(
            isEnabled: { launchAtLogin }, setEnabled: { launchAtLogin = $0 }
        ))
        defer { cleanUp() }
        let result = try object(tools.call(name: "update_settings", arguments: [
            "appearance": "dark", "palette": "seaGlass", "surface": "frosted", "tint": "vivid",
            "tint_length": 0.1, "reveal_corner": "bottomLeft", "reveal_delay": 9, "hide_delay": 0.5,
            "corner_size": 28, "panel_width": 360, "haptics": false, "launch_at_login": true
        ]))
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.panelTheme, .seaGlass)
        XCTAssertEqual(settings.panelSurfaceStyle, .frosted)
        XCTAssertEqual(settings.panelTint, .vivid)
        XCTAssertEqual(settings.panelTintLength, PanelTintLength.range.lowerBound, "clamped as the slider would")
        XCTAssertEqual(settings.corner, .bottomLeft)
        XCTAssertEqual(settings.revealDelay, 2.0, "clamped")
        XCTAssertEqual(settings.hideDelay, 0.5)
        XCTAssertEqual(settings.panelCornerSize, 28)
        XCTAssertEqual(settings.panelContentSize, 360)
        XCTAssertFalse(settings.hapticsEnabled)
        XCTAssertTrue(launchAtLogin)
        XCTAssertEqual(result["palette"] as? String, "seaGlass", "the answer is the settings after the change")
    }

    func testUpdateSettingsRefusesAgentAccessAndBadValuesWithoutChangingAnything() throws {
        let (tools, settings, cleanUp) = try makeSettingsTools()
        defer { cleanUp() }
        settings.isAgentAccessEnabled = true
        for bad: [String: Any] in [
            ["agent_access": false],
            ["palette": "seaGlass", "surface": "chrome"],
            ["palette": "seaGlass", "haptics": "no"],
            ["palette": "seaGlass", "corner_size": true],
            ["palette": "seaGlass", "colour": "red"],
            ["palette": "seaGlass", "launch_at_login": true],
            [:]
        ] {
            XCTAssertThrowsError(try tools.call(name: "update_settings", arguments: bad), "\(bad)")
        }
        XCTAssertTrue(settings.isAgentAccessEnabled)
        XCTAssertEqual(settings.panelTheme, .defaultTheme, "a refused call changes nothing")
        XCTAssertThrowsError(try tools.call(name: "delete_settings", arguments: [:]))
    }

    func testMCPListsAndRoutesTheSettingsTools() throws {
        let (settingsTools, settings, cleanUp) = try makeSettingsTools()
        defer { cleanUp() }
        let store = try makeTestStore()
        let tools = AgentTaskTools(store: store, settingsTools: settingsTools)
        let names = tools.definitions.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("get_settings"))
        XCTAssertTrue(names.contains("update_settings"))
        _ = try tools.call(name: "update_settings", arguments: ["haptics": false])
        XCTAssertFalse(settings.hapticsEnabled)
        XCTAssertFalse(AgentTaskTools(store: store).definitions.contains { ($0["name"] as? String) == "get_settings" },
                       "without Settings the tools are not offered")
        XCTAssertThrowsError(try AgentTaskTools(store: store).call(name: "get_settings", arguments: [:]))
    }
}

private extension RecentlyDeletedModel {
    func sections(matching query: String) -> [RecentlyDeletedPresentation.Section] {
        RecentlyDeletedPresentation.sections(entries, query: query)
    }
}
