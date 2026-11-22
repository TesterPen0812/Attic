#if ATTIC_GLOSS_LAB
// Ported for the Gloss lab preview from attic-redesign-assets/phaseX/panel-design/improvements-build/hunt-13nov/tools/tracker-seed/GlossLabTrackerSeed.swift (sample data only).
// GlossLabTrackerSeed.swift: the one shared, deterministic seed for the everyday-size
// speed measurements (write-path and speed sessions, 17 Nov 2026). It is a
// test-side file: copy it into AtticTests (or a probe target) as it is. It is
// never committed to the product.
//
// WHAT IT BUILDS
//
// Two shapes from one generator, so the only differences between the two runs
// are the ones the shapes name (RULES "Measure first", 17 Nov):
//
//   GlossLabTrackerSeed.tracker: the shape of the owner's Attic Progress copy, from the
//   counts the lead wrote in ops/design/write-path.md ("The measurement that
//   now decides builds 4 and 6"). The copy's own store was never read or
//   copied. Everything below that the lead did not give is a choice made here
//   and marked CHOICE.
//
//   GlossLabTrackerSeed.ordinary: the ordinary everyday seed (RULES: 40 Now, 30 Later,
//   300 Done, 8 notes). If the speed session already has its own ordinary
//   seed, align on one before comparing numbers.
//
// TAB MAPPING (TaskStatus → tab, as in TasksPageModel at a7a11552 and bba63fb0)
//
//   Now   = .inProgress + .todo
//   Later = .backlog
//   Done  = .done with doneLoggedAt == nil (finished today)
//   Done log (Done's query) = .done with doneLoggedAt != nil
//   Recently Deleted = deletedAt != nil
//
// TRACKER SHAPE
//
//   Open, 83: 9 in progress, 29 to do (Now 38), 45 backlog (Later 45).
//   Done, 147. CHOICE: 6 finished today (on the Done tab) and 141 in the
//     Done log, finished 1 to 60 days ago, logged the day after finishing,
//     so launch-time Done cleanup has nothing to move.
//   Deleted, 1: a backlog task deleted 3 days ago, in its own deletion group
//     (deletionRootID = its id, deletionMembersRaw = its id), as TaskStore
//     writes a single delete. No subtasks anywhere.
//   Tags on open tasks: 82 of 83 tagged (the untagged one is in backlog);
//     25 carry 3 tags and 57 carry 2 (189 / 82 = 2.30 each); 44 different
//     tags, every one of them on at least one open task. After that first
//     use, tags are drawn with a Zipf-like weight (1 / rank^0.9), so a few
//     tags are common and most are rare, as a real tracker's are (CHOICE).
//   Titles of open tasks: exactly mean 96 characters, 29 over 120, the
//     longest exactly 215. The others run from 16 to 120.
//   CHOICE, done tasks: 140 of 147 tagged from the same 44 with the same
//     2-or-3 split; titles mean 96 with 51 over 120 (the open tasks'
//     proportion) and the longest 198. The lead's title figures are read
//     here as the open tasks' figures. If they were the whole list's, the
//     done titles are a little long; open rows are what the controls touch.
//   CHOICE, the rest: priority none 60%, medium 25%, high 15% (all tasks).
//     25% of open tasks have a due day from 3 days ago to 14 days ahead.
//     Created 0 to 90 days ago (logged done ones 61 to 151, so before they
//     finished). Manual order follows list order.
//   Notes, 133 (CHOICE, all three):
//     Length: 40% short (1 to 3 sentences); 45% medium (a heading and 5
//       to 13 lines of bullets, checklists and sentences); 15% long (2 to 4
//       headed sections of 8 to 14 lines each). Measured on the plan: bodies
//       42 to 3,699 characters, median 477, 105,736 in all; 36 with web
//       addresses; 81 tagged.
//     Links:
//       - 25 notes are task writing (the task's own note), each on a
//         different open task, through createDocumentNote's taskOwner.
//       - 40 reference links (ItemLinkKind.reference), note → task, from
//         30 different notes: 30 to open tasks, 10 to done tasks.
//       - 35% of note bodies contain 1 to 3 web addresses (example.com) as
//         plain text. The note parser has no link syntax, so they stay text.
//     Tags: 60% of notes carry 1 or 2 of the same 44 tags.
//
// ORDINARY SHAPE (CHOICE beyond RULES' four counts)
//
//   Now 40 (4 in progress, 36 to do), Later 30, Done 300 (6 today, 294 in the
//   log), 8 notes (3 task writing, 2 reference links, all short or medium, no
//   web addresses, no tags), no deleted item. 23 of 70 open tasks and 100
//   of 300 done carry 1 or 2 of 6 tags (8 and 33 of them carry 2). Titles
//   mean 38 characters, none over 120, the longest 72. Same priority,
//   due-day and date rules.
//
// DETERMINISM
//
//   SplitMix64 with fixed seeds, one stream per purpose (ids, structure,
//   text), and no use of the standard library's random(in:using:) or
//   shuffle(using:), whose algorithms are not promised to stay fixed. The
//   same shape gives the same ids, titles, tags, bodies, links and orders
//   on every run and every build. Only dates move: they are offsets from the
//   `now` you pass, so "finished today" stays today.
//
// USE
//
//   let plan = GlossLabTrackerSeed.plan(.tracker)                 // pure data
//   try GlossLabTrackerSeed.insertTasks(plan, in: container)       // before the stores
//   ... build TaskStore / NoteStore / finishLaunch as the probe's rig does ...
//   try GlossLabTrackerSeed.createNotes(plan, notes: noteStore, container: container)
//   XCTAssertEqual(try GlossLabTrackerSeed.census(in: container), plan.census)
//
// The API used (TaskItem's init and fields, NoteStore.createDocumentNote,
// NoteAgentTextParser.document, ItemLink, AtticTag) is identical in a7a11552
// (the trunk tip on 17 Nov) and bba63fb0 (the build the owner's copy runs).

import Foundation
import SwiftData


enum GlossLabTrackerSeed {

    // MARK: Shapes

    struct Shape: Sendable {
        let name: String
        let seed: UInt64
        let inProgress: Int, todo: Int, backlog: Int
        let doneToday: Int, doneLogged: Int, deleted: Int
        // Tags: `openTagged` open tasks carry `baseTags` each, `openExtraTag` of them one more (same for done).
        let tagPool: Int, openTagged: Int, openExtraTag: Int, baseTags: Int
        let doneTagged: Int, doneExtraTag: Int
        // Titles: (count is the group's), exact mean, how many over 120, the longest.
        let openTitleMean: Int, openOver120: Int, openLongest: Int
        let doneTitleMean: Int, doneOver120: Int, doneLongest: Int
        let shortTitleRange: ClosedRange<Int>
        let notes: Int, taskWritingNotes: Int, referenceLinks: Int, referencingNotes: Int, referencesToDone: Int
        let longNotesAllowed: Bool, webAddresses: Bool, noteTagShare: Double

        var open: Int { inProgress + todo + backlog }
        var done: Int { doneToday + doneLogged }
    }

    static let tracker = Shape(
        name: "tracker", seed: 0x4154_5449_435F_5452,  // "ATTIC_TR"
        inProgress: 9, todo: 29, backlog: 45,
        doneToday: 6, doneLogged: 141, deleted: 1,
        tagPool: 44, openTagged: 82, openExtraTag: 25, baseTags: 2,
        doneTagged: 140, doneExtraTag: 43,
        openTitleMean: 96, openOver120: 29, openLongest: 215,
        doneTitleMean: 96, doneOver120: 51, doneLongest: 198,
        shortTitleRange: 16...120,
        notes: 133, taskWritingNotes: 25, referenceLinks: 40, referencingNotes: 30, referencesToDone: 10,
        longNotesAllowed: true, webAddresses: true, noteTagShare: 0.6)

    static let ordinary = Shape(
        name: "ordinary", seed: 0x4154_5449_435F_4F52,  // "ATTIC_OR"
        inProgress: 4, todo: 36, backlog: 30,
        doneToday: 6, doneLogged: 294, deleted: 0,
        tagPool: 6, openTagged: 23, openExtraTag: 8, baseTags: 1,
        doneTagged: 100, doneExtraTag: 33,
        openTitleMean: 38, openOver120: 0, openLongest: 72,
        doneTitleMean: 38, doneOver120: 0, doneLongest: 72,
        shortTitleRange: 12...70,
        notes: 8, taskWritingNotes: 3, referenceLinks: 2, referencingNotes: 2, referencesToDone: 0,
        longNotesAllowed: false, webAddresses: false, noteTagShare: 0)

    // MARK: Plan (pure data)

    struct TaskSpec {
        let id: UUID
        let title: String
        let status: TaskStatus
        let priority: TaskPriority
        let createdDaysAgo: Int, createdSecondsAgo: Int
        /// nil: not done. Days ago (0 = today, then `completedMinutesAgo` applies).
        let completedDaysAgo: Int?, completedMinutesAgo: Int
        let logged: Bool
        let dueDayOffset: Int?
        let tags: [String]
        let deleted: Bool
        let deletionGroupID: UUID?
        let manualOrder: Int64
    }

    struct NoteSpec {
        let id: UUID
        let title: String
        let body: String
        let tags: [String]
        let taskOwner: UUID?
    }

    struct LinkSpec { let id: UUID; let note: UUID; let task: UUID }

    struct Census: Equatable, CustomStringConvertible {
        var inProgress = 0, todo = 0, backlog = 0, doneToday = 0, doneLogged = 0, deleted = 0
        var taggedOpen = 0, openTagSlots = 0, distinctOpenTags = 0, distinctTags = 0
        var openTitleCharacters = 0, openOver120 = 0, openLongest = 0
        var notes = 0, taskWritingNotes = 0, referenceLinks = 0
        var description: String {
            "now \(inProgress)+\(todo) later \(backlog) done \(doneToday)+\(doneLogged)log deleted \(deleted) "
            + "tagged \(taggedOpen) slots \(openTagSlots) openTags \(distinctOpenTags) allTags \(distinctTags) "
            + "titleChars \(openTitleCharacters) >120 \(openOver120) longest \(openLongest) "
            + "notes \(notes) writing \(taskWritingNotes) refs \(referenceLinks)"
        }
    }

    struct Plan {
        let shape: Shape
        let tasks: [TaskSpec]
        let notes: [NoteSpec]
        let links: [LinkSpec]

        var census: Census {
            var c = Census()
            var openTags = Set<String>(), allTags = Set<String>()
            for task in tasks {
                if task.deleted { c.deleted += 1; continue }
                allTags.formUnion(task.tags)
                switch task.status {
                case .inProgress: c.inProgress += 1
                case .todo: c.todo += 1
                case .backlog: c.backlog += 1
                case .done: if task.logged { c.doneLogged += 1 } else { c.doneToday += 1 }
                }
                guard task.status != .done else { continue }
                if !task.tags.isEmpty { c.taggedOpen += 1 }
                c.openTagSlots += task.tags.count
                openTags.formUnion(task.tags)
                c.openTitleCharacters += task.title.count
                if task.title.count > 120 { c.openOver120 += 1 }
                c.openLongest = max(c.openLongest, task.title.count)
            }
            for note in notes { allTags.formUnion(note.tags) }
            c.distinctOpenTags = openTags.count
            c.distinctTags = allTags.count
            c.notes = notes.count
            c.taskWritingNotes = notes.filter { $0.taskOwner != nil }.count
            c.referenceLinks = links.count
            return c
        }
    }

    static func plan(_ shape: Shape) -> Plan {
        var ids = SplitMix64(seed: shape.seed ^ 0x1D5)
        var structure = SplitMix64(seed: shape.seed ^ 0x57C)
        var text = SplitMix64(seed: shape.seed ^ 0x7E7)
        let pool = Array(tagNames.prefix(shape.tagPool))
        precondition(pool.count == shape.tagPool, "not enough tag names")

        // Statuses in list order: Now (in progress first), Later, then Done.
        var statuses: [TaskStatus] = Array(repeating: .inProgress, count: shape.inProgress)
            + Array(repeating: .todo, count: shape.todo) + Array(repeating: .backlog, count: shape.backlog)
        let openCount = statuses.count
        statuses += Array(repeating: .done, count: shape.done)

        let openLengths = titleLengths(count: openCount, mean: shape.openTitleMean, over120: shape.openOver120,
                                       longest: shape.openLongest, short: shape.shortTitleRange, rng: &structure)
        let doneLengths = titleLengths(count: shape.done, mean: shape.doneTitleMean, over120: shape.doneOver120,
                                       longest: shape.doneLongest, short: shape.shortTitleRange, rng: &structure)

        // Open tags: which tasks, how many each, every pool tag used once first.
        let backlogStart = shape.inProgress + shape.todo
        // Untagged tasks come from backlog first, then from Now.
        var backlogIndices = Array(backlogStart..<openCount), nowIndices = Array(0..<backlogStart)
        shuffle(&backlogIndices, &structure)
        shuffle(&nowIndices, &structure)
        let untaggedOpen = Set((backlogIndices + nowIndices).prefix(openCount - shape.openTagged))
        var taggedOpen = (0..<openCount).filter { !untaggedOpen.contains($0) }
        shuffle(&taggedOpen, &structure)
        let extraTagOpen = Set(taggedOpen.prefix(shape.openExtraTag))
        var uncovered = pool
        shuffle(&uncovered, &structure)
        var openTags = [Int: [String]]()
        for index in taggedOpen.sorted() {
            let count = shape.baseTags + (extraTagOpen.contains(index) ? 1 : 0)
            var chosen: [String] = []
            if let first = uncovered.popLast() { chosen.append(first) }
            while chosen.count < count { let tag = zipf(pool, &structure); if !chosen.contains(tag) { chosen.append(tag) } }
            openTags[index] = chosen
        }
        precondition(uncovered.isEmpty, "more pool tags than tagged open tasks")

        var doneOrder = Array(0..<shape.done)
        shuffle(&doneOrder, &structure)
        let taggedDone = Set(doneOrder.prefix(shape.doneTagged))
        let extraTagDone = Set(doneOrder.prefix(shape.doneExtraTag))

        var tasks: [TaskSpec] = []
        var order: Int64 = 10_000_000
        for (index, status) in statuses.enumerated() {
            order -= 1_024
            let isOpen = index < openCount
            let doneIndex = index - openCount
            let length = isOpen ? openLengths[index] : doneLengths[doneIndex]
            var tags: [String] = []
            if isOpen { tags = openTags[index] ?? [] }
            else if taggedDone.contains(doneIndex) {
                let count = shape.baseTags + (extraTagDone.contains(doneIndex) ? 1 : 0)
                while tags.count < count { let tag = zipf(pool, &structure); if !tags.contains(tag) { tags.append(tag) } }
            }
            let roll = structure.unit()
            let priority: TaskPriority = roll < 0.60 ? .none : roll < 0.85 ? .medium : .high
            let due: Int? = isOpen && structure.unit() < 0.25 ? Int(structure.below(18)) - 3 : nil
            let createdDays = Int(structure.below(91)), createdSeconds = Int(structure.below(86_400))
            let today = !isOpen && doneIndex < shape.doneToday
            tasks.append(TaskSpec(
                id: uuid(&ids), title: title(length: length, &text), status: status, priority: priority,
                createdDaysAgo: !isOpen && !today ? createdDays + 61 : createdDays, createdSecondsAgo: createdSeconds,
                completedDaysAgo: isOpen ? nil : (today ? 0 : 1 + Int(structure.below(60))),
                completedMinutesAgo: today ? 1 + doneIndex * 7 : 0,
                logged: !isOpen && !today, dueDayOffset: due, tags: AtticTag.normalizedSet(tags),
                deleted: false, deletionGroupID: nil, manualOrder: order))
        }
        for _ in 0..<shape.deleted {
            order -= 1_024
            tasks.append(TaskSpec(
                id: uuid(&ids), title: title(length: 64, &text), status: .backlog, priority: .none,
                createdDaysAgo: 20, createdSecondsAgo: 3_600, completedDaysAgo: nil, completedMinutesAgo: 0,
                logged: false, dueDayOffset: nil, tags: [pool[0]], deleted: true,
                deletionGroupID: uuid(&ids), manualOrder: order))
        }

        // Notes: owners are distinct open tasks; references from the first notes after the writing ones.
        var openIDs = tasks.prefix(openCount).map(\.id)
        shuffle(&openIDs, &structure)
        let owners = Array(openIDs.prefix(shape.taskWritingNotes))
        let doneIDs = tasks.dropFirst(openCount).prefix(shape.done).map(\.id)
        var notes: [NoteSpec] = []
        for index in 0..<shape.notes {
            let band = structure.unit()
            let kind: NoteLength = !shape.longNotesAllowed ? (band < 0.5 ? .short : .medium)
                : band < 0.40 ? .short : band < 0.85 ? .medium : .long
            let links = shape.webAddresses && structure.unit() < 0.35 ? 1 + Int(structure.below(3)) : 0
            var tags: [String] = []
            if structure.unit() < shape.noteTagShare {
                let count = 1 + Int(structure.below(2))
                while tags.count < count { let tag = zipf(pool, &structure); if !tags.contains(tag) { tags.append(tag) } }
            }
            notes.append(NoteSpec(
                id: uuid(&ids), title: title(length: 20 + Int(structure.below(51)), &text),
                body: body(kind, webAddresses: links, &text, &structure), tags: AtticTag.normalizedSet(tags),
                taskOwner: index < owners.count ? owners[index] : nil))
        }
        var links: [LinkSpec] = []
        let referencing = Array(notes.dropFirst(shape.taskWritingNotes).prefix(shape.referencingNotes))
        precondition(referencing.count == shape.referencingNotes, "not enough notes to reference from")
        var openTargets = openIDs.reversed().map { $0 }   // the other end of the shuffled open list
        var doneTargets = doneIDs
        shuffle(&doneTargets, &structure)
        var used = Set<String>()
        for index in 0..<shape.referenceLinks {
            let note = referencing[index % referencing.count].id
            let toDone = index >= shape.referenceLinks - shape.referencesToDone
            var target: UUID
            repeat {
                target = toDone ? doneTargets.removeFirst() : openTargets.removeFirst()
            } while used.contains("\(note)\(target)")
            used.insert("\(note)\(target)")
            links.append(LinkSpec(id: uuid(&ids), note: note, task: target))
        }
        return Plan(shape: shape, tasks: tasks, notes: notes, links: links)
    }

    // MARK: Writing the store

    struct SeedError: Error, CustomStringConvertible { let description: String }

    /// Inserts every task (and the deleted one) in one save. Call before any store reads the container.
    static func insertTasks(_ plan: Plan, in container: ModelContainer, now: Date = Date(),
                            calendar: Calendar = .autoupdatingCurrent) throws {
        let context = ModelContext(container)
        let startOfToday = calendar.startOfDay(for: now)
        for spec in plan.tasks {
            let created = now.addingTimeInterval(-Double(spec.createdDaysAgo * 86_400 + spec.createdSecondsAgo))
            var completed: Date?
            if let days = spec.completedDaysAgo {
                completed = days == 0
                    ? max(startOfToday.addingTimeInterval(1), now.addingTimeInterval(-Double(spec.completedMinutesAgo * 60)))
                    : calendar.date(byAdding: .day, value: -days, to: now)
            }
            let item = TaskItem(id: spec.id, title: spec.title, status: spec.status, priority: spec.priority,
                                createdAt: min(created, completed ?? created), completedAt: completed,
                                manualOrder: spec.manualOrder, parentID: nil)
            if let offset = spec.dueDayOffset, let date = calendar.date(byAdding: .day, value: offset, to: now) {
                item.dueDay = DueDay(date: date, calendar: calendar)
            }
            item.tags = spec.tags
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if spec.logged, let completed {
                let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: completed)) ?? completed
                item.doneLoggedAt = min(nextDay, startOfToday)
            }
            if spec.deleted {
                item.deletedAt = now.addingTimeInterval(-3 * 86_400)
                item.deletionGroupID = spec.deletionGroupID
                item.deletionRootID = spec.id
                item.deletionMembersRaw = spec.id.uuidString
            }
            context.insert(item)
        }
        try context.save()
    }

    /// Creates the notes through the notes store (the format, task writing and associations come out as
    /// the app writes them), then the reference links. Call once the stores exist and launch has finished.
    @MainActor
    static func createNotes(_ plan: Plan, notes store: NoteStore, container: ModelContainer, now: Date = Date()) throws {
        for spec in plan.notes {
            let document = try NoteAgentTextParser.document(title: spec.title, body: spec.body, base: .blank)
            let result = store.createDocumentNote(id: spec.id, document: document,
                                                  tags: spec.tags.isEmpty ? nil : spec.tags, taskOwner: spec.taskOwner)
            if case let .failure(error) = result { throw SeedError(description: "note \(spec.id): \(error)") }
        }
        guard !plan.links.isEmpty else { return }
        let context = ModelContext(container)
        for (index, link) in plan.links.enumerated() {
            let stamp = now.addingTimeInterval(-Double((index + 1) * 3_600))
            context.insert(ItemLink(id: link.id, source: AtticItemRef(.note, link.note),
                                    target: AtticItemRef(.task, link.task), kind: .reference, createdAt: stamp))
        }
        try context.save()
    }

    /// What the store holds, counted the way `Plan.census` counts the plan.
    static func census(in container: ModelContainer) throws -> Census {
        let context = ModelContext(container)
        var c = Census()
        var openTags = Set<String>(), allTags = Set<String>()
        for task in try context.fetch(FetchDescriptor<TaskItem>()) {
            if task.deletedAt != nil { c.deleted += 1; continue }
            allTags.formUnion(task.tags)
            switch task.status {
            case .inProgress: c.inProgress += 1
            case .todo: c.todo += 1
            case .backlog: c.backlog += 1
            case .done: if task.doneLoggedAt != nil { c.doneLogged += 1 } else { c.doneToday += 1 }
            }
            guard task.status != .done else { continue }
            if !task.tags.isEmpty { c.taggedOpen += 1 }
            c.openTagSlots += task.tags.count
            openTags.formUnion(task.tags)
            c.openTitleCharacters += task.title.count
            if task.title.count > 120 { c.openOver120 += 1 }
            c.openLongest = max(c.openLongest, task.title.count)
        }
        let notes = try context.fetch(FetchDescriptor<NoteItem>()).filter { $0.deletedAt == nil }
        for note in notes { allTags.formUnion(note.tags) }
        c.distinctOpenTags = openTags.count
        c.distinctTags = allTags.count
        c.notes = Set(notes.map(\.id)).count
        c.taskWritingNotes = Set(notes.filter { $0.taskID != nil }.map(\.id)).count
        c.referenceLinks = try context.fetch(FetchDescriptor<ItemLink>())
            .filter { $0.deletedAt == nil && $0.kindRaw == ItemLinkKind.reference.rawValue }.count
        return c
    }

    // MARK: Text

    private enum NoteLength { case short, medium, long }

    static let tagNames = [
        "panel", "tasks", "notes", "composer", "glass", "motion", "keyboard", "done-log", "later", "now",
        "search", "tags", "undo", "delete", "scroll", "speed", "layout", "sidebar", "settings", "agent",
        "calendar", "canvas", "sync", "data", "save", "tests", "ci", "review", "design", "accessibility",
        "menus", "drag", "images", "files", "tables", "iphone", "launch", "memory", "focus", "preview",
        "docs", "bugs", "polish", "release",
    ]

    private static let words = [
        "panel", "row", "title", "glass", "tick", "card", "menu", "tag", "chip", "list", "scroll", "edge",
        "keyboard", "focus", "undo", "delete", "restore", "note", "writing", "composer", "search", "query",
        "done", "later", "now", "backlog", "progress", "layout", "frame", "motion", "spring", "fade", "shadow",
        "sidebar", "toolbar", "window", "sheet", "popover", "field", "caret", "selection", "drag", "drop",
        "check", "review", "merge", "branch", "build", "preview", "measure", "trace", "seed", "store", "save",
        "reload", "context", "replica", "sync", "launch", "settings", "agent", "calendar", "canvas", "image",
        "table", "file", "link", "date", "priority", "due", "today", "lag", "fix", "keep", "make", "move",
        "show", "hide", "open", "close", "stay", "after", "before", "when", "while", "with", "without",
        "into", "from", "under", "over", "the", "a", "on", "in", "of", "for", "and", "so", "it",
    ]

    private static func title(length: Int, _ rng: inout SplitMix64) -> String {
        var text = ""
        while text.count < length + 12 {
            let word = words[Int(rng.below(UInt64(words.count)))]
            text += text.isEmpty ? word.prefix(1).uppercased() + word.dropFirst() : " " + word
        }
        var cut = String(text.prefix(length))
        if cut.last == " " { cut = String(cut.dropLast()) + "s" }
        return cut
    }

    private static func sentence(_ length: Int, _ rng: inout SplitMix64) -> String {
        title(length: max(12, length - 1), &rng) + "."
    }

    private static func body(_ kind: NoteLength, webAddresses: Int, _ text: inout SplitMix64,
                             _ structure: inout SplitMix64) -> String {
        var lines: [String] = []
        func line(_ rng: inout SplitMix64, _ s: inout SplitMix64) -> String {
            switch s.below(10) {
            case 0...3: return sentence(60 + Int(s.below(80)), &rng)
            case 4...6: return "- " + title(length: 20 + Int(s.below(60)), &rng)
            default: return (s.below(3) == 0 ? "- [x] " : "- [ ] ") + title(length: 18 + Int(s.below(50)), &rng)
            }
        }
        switch kind {
        case .short:
            for _ in 0..<(1 + Int(structure.below(3))) { lines.append(sentence(40 + Int(structure.below(80)), &text)) }
        case .medium:
            lines.append("## " + title(length: 14 + Int(structure.below(24)), &text))
            for _ in 0..<(5 + Int(structure.below(9))) { lines.append(line(&text, &structure)) }
        case .long:
            for _ in 0..<(2 + Int(structure.below(3))) {
                lines.append("## " + title(length: 14 + Int(structure.below(24)), &text))
                for _ in 0..<(8 + Int(structure.below(7))) { lines.append(line(&text, &structure)) }
            }
        }
        for index in 0..<webAddresses {
            let slug = title(length: 10 + Int(structure.below(14)), &text).lowercased()
                .replacingOccurrences(of: " ", with: "-")
            let at = Int(structure.below(UInt64(lines.count + 1)))
            lines.insert("See https://example.com/attic/\(slug)-\(index + 1) for the details.", at: at)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Numbers

    /// Exactly `count` lengths with exactly `mean`, exactly `over120` above 120 (one of them `longest` when
    /// it is above 120), the rest inside `short`, in a fixed shuffled order.
    private static func titleLengths(count: Int, mean: Int, over120: Int, longest: Int,
                                     short: ClosedRange<Int>, rng: inout SplitMix64) -> [Int] {
        var lengths = [longest]
        let longestIsOver = longest > 120
        for _ in 0..<(over120 - (longestIsOver ? 1 : 0)) { lengths.append(121 + Int(rng.below(60))) }
        let fixed = lengths.count
        let span = UInt64(short.upperBound - short.lowerBound + 1)
        while lengths.count < count { lengths.append(short.lowerBound + Int(rng.below(span))) }
        var difference = mean * count - lengths.reduce(0, +)
        var index = 0, stalled = 0
        while difference != 0 {
            let at = fixed + index % (count - fixed)
            let ceiling = min(short.upperBound, longestIsOver ? 120 : longest)
            if difference > 0, lengths[at] < ceiling { lengths[at] += 1; difference -= 1; stalled = 0 }
            else if difference < 0, lengths[at] > short.lowerBound { lengths[at] -= 1; difference += 1; stalled = 0 }
            else { stalled += 1; precondition(stalled <= count, "title lengths cannot reach the mean") }
            index += 1
        }
        shuffle(&lengths, &rng)
        return lengths
    }

    private static func zipf(_ pool: [String], _ rng: inout SplitMix64) -> String {
        let weights = pool.indices.map { 1 / pow(Double($0 + 1), 0.9) }
        var pick = rng.unit() * weights.reduce(0, +)
        for (index, weight) in weights.enumerated() { pick -= weight; if pick < 0 { return pool[index] } }
        return pool[pool.count - 1]
    }

    private static func shuffle<T>(_ values: inout [T], _ rng: inout SplitMix64) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, to: 0, by: -1) {
            values.swapAt(index, Int(rng.below(UInt64(index + 1))))
        }
    }

    private static func uuid(_ rng: inout SplitMix64) -> UUID {
        let a = rng.next(), b = rng.next()
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> (8 * $0)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: b >> (8 * $0)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    struct SplitMix64: RandomNumberGenerator, Sendable {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// 0 ..< bound, by multiply-shift (fixed, no rejection loop).
        mutating func below(_ bound: UInt64) -> UInt64 { bound.multipliedFullWidth(by: next()).high }
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    }
}
#endif

#if ATTIC_GLOSS_LAB
import OSLog

extension GlossLabTrackerSeed {
    static let glossBundleID = "com.taha.Attic.preview.gloss"
    static let seededKey = "GlossLab.trackerSeeded"

    /// Inserts the tracker-shaped tasks into the Gloss preview's own store,
    /// once: only under the Gloss bundle identifier, only when the store
    /// holds no task and no note, and only if this preview never seeded.
    /// Returns the plan so the notes can follow once the stores exist.
    static func seedTasksIfNeeded(in container: ModelContainer) -> Plan? {
        guard Bundle.main.bundleIdentifier == glossBundleID,
              !UserDefaults.standard.bool(forKey: seededKey) else { return nil }
        let context = ModelContext(container)
        guard (try? context.fetchCount(FetchDescriptor<TaskItem>())) == 0,
              (try? context.fetchCount(FetchDescriptor<NoteItem>())) == 0 else { return nil }
        let plan = plan(tracker)
        do {
            try insertTasks(plan, in: container)
            UserDefaults.standard.set(true, forKey: seededKey)
            return plan
        } catch {
            Logger(subsystem: glossBundleID, category: "GlossLab").error("tracker seed failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @MainActor
    static func seedNotes(_ plan: Plan, notes: NoteStore, container: ModelContainer) {
        do {
            try createNotes(plan, notes: notes, container: container)
        } catch {
            Logger(subsystem: glossBundleID, category: "GlossLab").error("tracker notes failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
